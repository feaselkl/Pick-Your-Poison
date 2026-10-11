#Requires -Modules dbatools

<#
.SYNOPSIS
    Estate-wide SQL Server edition and licensing audit.

.DESCRIPTION
    Collects edition, capacity, feature usage, and licensing-exposure data across
    many SQL Server instances, then writes CSVs and a prioritized findings list.

    This is the estate-wide companion to the single-instance demos in
    "01 - Edition and Capacity Discovery.sql" and "02 - Estate Audit and Compliance.sql".

    dbatools handles connection management and orchestration. The collection itself
    is plain T-SQL against DMVs, which keeps it portable -- it works identically
    against Windows, Linux, and containers. Hardware enrichment via WMI is opt-in
    through -IncludeHardwareDetail because it only works against Windows hosts.

    Nothing here writes to your instances. It is read-only.

.PARAMETER SqlInstance
    One or more instances to audit.

.PARAMETER InputFile
    Path to a text file with one instance per line. Blank lines and lines starting
    with # are ignored.

.PARAMETER CmsServer
    A Central Management Server to pull the instance list from.

.PARAMETER RegisteredServerGroup
    Optional group name within the CMS, to scope the pull.

.PARAMETER SqlCredential
    Credential for SQL authentication. Omit to use Windows authentication.

.PARAMETER OutputPath
    Directory for the CSV output. Created if missing. Defaults to a timestamped
    folder under the current location.

.PARAMETER TrustServerCertificate
    Skip certificate validation from the outset. You do not normally need this:
    if a connection fails because the certificate is self-signed or untrusted,
    the script retries automatically with validation disabled and warns that it
    did so. Pass this to skip the first attempt and silence the warning.

.PARAMETER NoCertificateFallback
    Disable the automatic retry. A target presenting an untrusted certificate is
    then recorded as a connection failure instead of being audited. Use this when
    you want certificate problems to be errors rather than warnings.

.PARAMETER IncludeHardwareDetail
    Also collect host-level detail via WMI (Get-DbaComputerSystem). Windows only,
    and it needs remote WMI access. Failures are non-fatal.

.PARAMETER ExpressWarnGB
    Database size at which an Express database is flagged as approaching its 50 GB
    ceiling. Defaults to 40.

.EXAMPLE
    .\Invoke-SqlEditionAudit.ps1 -SqlInstance sql01, sql02, 'sql03\PROD'

.EXAMPLE
    .\Invoke-SqlEditionAudit.ps1 -InputFile .\instances.txt -OutputPath C:\Audit

.EXAMPLE
    .\Invoke-SqlEditionAudit.ps1 -CmsServer cms01 -RegisteredServerGroup Production

.EXAMPLE
    # Against the demo containers from Scripts/Setup. Their certificates are
    # self-signed; the script retries past that on its own and says so.
    $cred = Get-Credential sa
    .\Invoke-SqlEditionAudit.ps1 -SqlInstance 'localhost,1433', 'localhost,1434', 'localhost,1435' `
        -SqlCredential $cred

.NOTES
    Accurate as of the talk delivery date. Licensing terms change monthly and the
    Microsoft Product Terms are the authority. This script finds questions worth
    asking; it does not answer them. Confirm with your licensing partner.
#>

[CmdletBinding(DefaultParameterSetName = 'Instance')]
param(
    [Parameter(ParameterSetName = 'Instance', Mandatory, Position = 0)]
    [string[]] $SqlInstance,

    [Parameter(ParameterSetName = 'File', Mandatory)]
    [string] $InputFile,

    [Parameter(ParameterSetName = 'Cms', Mandatory)]
    [string] $CmsServer,

    [Parameter(ParameterSetName = 'Cms')]
    [string] $RegisteredServerGroup,

    [pscredential] $SqlCredential,

    [string] $OutputPath = (Join-Path (Get-Location) ("EditionAudit-{0:yyyyMMdd-HHmmss}" -f (Get-Date))),

    [switch] $TrustServerCertificate,

    [switch] $NoCertificateFallback,

    [switch] $IncludeHardwareDetail,

    [int] $ExpressWarnGB = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Microsoft.Data.SqlClient v4+ defaults Encrypt to Mandatory, so an untrusted or
# self-signed certificate refuses the connection outright. That describes every
# SQL Server container and a great many on-premises instances, so the script
# treats it as a condition to recover from rather than a usage error.
$script:CertPattern = 'certificate|chain validation|UntrustedRoot|SSL|TLS'

function Set-TrustCertConfig {
    # Get-DbaRegServer has no -TrustServerCertificate parameter of its own, so
    # the dbatools-level config is the only way to cover the -CmsServer path.
    #
    # If a target still refuses, the heavier lever is
    #     Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false
    # which drops encryption entirely rather than just skipping validation.
    # Reach for that only in a lab.
    try   { Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -EnableException }
    catch { Write-Verbose "Could not set sql.connection.trustcert: $($_.Exception.Message)" }
}

function Connect-AuditInstance {
    param([string] $Target)

    $p = @{ SqlInstance = $Target; ErrorAction = 'Stop' }
    if ($SqlCredential)          { $p['SqlCredential'] = $SqlCredential }
    if ($TrustServerCertificate) { $p['TrustServerCertificate'] = $true }

    try {
        return Connect-DbaInstance @p
    }
    catch {
        $msg = $_.Exception.Message
        if ($TrustServerCertificate -or $NoCertificateFallback -or $msg -notmatch $script:CertPattern) {
            throw
        }
        Write-Warning "$Target -- untrusted or self-signed certificate. Retrying without certificate validation."
        Write-Warning "  Pass -TrustServerCertificate to skip this retry, or -NoCertificateFallback to treat it as an error."
        Set-TrustCertConfig
        $p['TrustServerCertificate'] = $true
        return Connect-DbaInstance @p
    }
}

if ($TrustServerCertificate) { Set-TrustCertConfig }

# Standard edition 2025 ceilings. Update these if you are auditing against a
# different target version.
$StandardCoreLimit     = 32
$StandardBufferPoolGB  = 256
$ExpressMaxDatabaseGB  = 50

#region T-SQL collection

$Q_Instance = @'
SELECT
    MachineName        = CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')),
    InstanceName       = CONVERT(nvarchar(128), ISNULL(SERVERPROPERTY('InstanceName'), N'MSSQLSERVER')),
    ServerName         = CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')),
    Edition            = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
    EngineEdition      = CONVERT(int,           SERVERPROPERTY('EngineEdition')),
    ProductVersion     = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductVersion')),
    ProductLevel       = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductLevel')),
    ProductUpdateLevel = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductUpdateLevel')),
    IsClustered        = CONVERT(int,           SERVERPROPERTY('IsClustered')),
    IsHadrEnabled      = CONVERT(int,           SERVERPROPERTY('IsHadrEnabled')),
    Collation          = CONVERT(nvarchar(128), SERVERPROPERTY('Collation')),
    LogicalCPUs        = si.cpu_count,
    HyperthreadRatio   = si.hyperthread_ratio,
    PhysicalSockets    = si.cpu_count / NULLIF(si.hyperthread_ratio, 0),
    PhysicalMemoryGB   = CONVERT(decimal(10,1), si.physical_memory_kb  / 1048576.0),
    CommittedTargetGB  = CONVERT(decimal(10,1), si.committed_target_kb / 1048576.0),
    VirtualMachineType = si.virtual_machine_type_desc,
    MaxServerMemoryMB  = (SELECT CONVERT(bigint, value_in_use) FROM sys.configurations WHERE name = 'max server memory (MB)'),
    MaxDop             = (SELECT CONVERT(int,    value_in_use) FROM sys.configurations WHERE name = 'max degree of parallelism')
FROM sys.dm_os_sys_info AS si;
'@

# Deliberately a documented cursor rather than sp_MSforeachdb, which is
# undocumented and silently skips databases in some conditions.
$Q_PersistedFeatures = @'
SET NOCOUNT ON;

DECLARE @Results TABLE (DatabaseName sysname, FeatureID int, FeatureName nvarchar(255));
DECLARE @db sysname, @sql nvarchar(max);

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state_desc = 'ONLINE'
      AND HAS_DBACCESS(name) = 1;

OPEN dbs;
FETCH NEXT FROM dbs INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@db) + N';
        SELECT ' + QUOTENAME(@db, '''') + N', feature_id, feature_name
        FROM sys.dm_db_persisted_sku_features;';

    BEGIN TRY
        INSERT INTO @Results (DatabaseName, FeatureID, FeatureName)
        EXEC (@sql);
    END TRY
    BEGIN CATCH
        -- Unreadable secondary, insufficient permission, or a database that went
        -- offline mid-loop. Skip it rather than abandoning the instance.
    END CATCH

    FETCH NEXT FROM dbs INTO @db;
END

CLOSE dbs;
DEALLOCATE dbs;

SELECT DatabaseName, FeatureID, FeatureName FROM @Results ORDER BY DatabaseName, FeatureName;
'@

$Q_Databases = @'
SELECT
    DatabaseName  = DB_NAME(mf.database_id),
    DataSizeGB    = CONVERT(decimal(12,2), SUM(CASE WHEN mf.type_desc = 'ROWS' THEN mf.size ELSE 0 END) * 8.0 / 1048576.0),
    LogSizeGB     = CONVERT(decimal(12,2), SUM(CASE WHEN mf.type_desc = 'LOG'  THEN mf.size ELSE 0 END) * 8.0 / 1048576.0),
    RecoveryModel = d.recovery_model_desc,
    CompatLevel   = d.compatibility_level,
    IsEncrypted   = d.is_encrypted,
    State         = d.state_desc
FROM sys.master_files AS mf
    INNER JOIN sys.databases AS d
        ON mf.database_id = d.database_id
WHERE mf.database_id > 4
GROUP BY mf.database_id, d.recovery_model_desc, d.compatibility_level, d.is_encrypted, d.state_desc;
'@

$Q_Replicas = @'
SELECT
    AvailabilityGroup           = ag.name,
    ReplicaServer               = ar.replica_server_name,
    AvailabilityMode            = ar.availability_mode_desc,
    FailoverMode                = ar.failover_mode_desc,
    SecondaryReadable           = ar.secondary_role_allow_connections_desc,
    PrimaryRoleAllowConnections = ar.primary_role_allow_connections_desc,
    SeedingMode                 = ar.seeding_mode_desc,
    CurrentRole                 = hars.role_desc
FROM sys.availability_groups AS ag
    INNER JOIN sys.availability_replicas AS ar
        ON ag.group_id = ar.group_id
    LEFT OUTER JOIN sys.dm_hadr_availability_replica_states AS hars
        ON ar.replica_id = hars.replica_id;
'@

#endregion

#region Resolve the instance list

$targets = switch ($PSCmdlet.ParameterSetName) {
    'Instance' { $SqlInstance }
    'File' {
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "Input file not found: $InputFile" }
        Get-Content -LiteralPath $InputFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    }
    'Cms' {
        $params = @{ SqlInstance = $CmsServer; ErrorAction = 'Stop' }
        if ($SqlCredential)         { $params['SqlCredential'] = $SqlCredential }
        if ($RegisteredServerGroup) { $params['Group'] = $RegisteredServerGroup }
        try {
            Get-DbaRegServer @params | Select-Object -ExpandProperty ServerName -Unique
        }
        catch {
            if ($NoCertificateFallback -or $_.Exception.Message -notmatch $script:CertPattern) { throw }
            Write-Warning "$CmsServer -- untrusted certificate on the CMS. Retrying without validation."
            Set-TrustCertConfig
            Get-DbaRegServer @params | Select-Object -ExpandProperty ServerName -Unique
        }
    }
}

$targets = @($targets | Where-Object { $_ } | Select-Object -Unique)
if (-not $targets) { throw 'No instances resolved. Nothing to audit.' }

Write-Host ''
Write-Host "Auditing $($targets.Count) instance(s)." -ForegroundColor Cyan
Write-Host ''

#endregion

#region Collect

$instances = [System.Collections.Generic.List[object]]::new()
$features  = [System.Collections.Generic.List[object]]::new()
$databases = [System.Collections.Generic.List[object]]::new()
$replicas  = [System.Collections.Generic.List[object]]::new()
$failures  = [System.Collections.Generic.List[object]]::new()

$i = 0
foreach ($target in $targets) {
    $i++
    Write-Progress -Activity 'Edition audit' -Status $target -PercentComplete (100 * $i / $targets.Count)

    try {
        $server = Connect-AuditInstance -Target $target
    }
    catch {
        $msg = $_.Exception.Message
        Write-Warning "$target -- connection failed: $msg"
        if ($NoCertificateFallback -and $msg -match $script:CertPattern) {
            Write-Warning "  Certificate validation failed and -NoCertificateFallback is set. Drop that switch to retry automatically."
        }
        $failures.Add([pscustomobject]@{ Instance = $target; Stage = 'Connect'; Error = $msg })
        continue
    }

    $queryBase = @{ SqlInstance = $server; EnableException = $true }

    # Instance-level facts. If this fails there is nothing useful to record.
    try {
        $info = Invoke-DbaQuery @queryBase -Query $Q_Instance -As PSObject
    }
    catch {
        Write-Warning "$target -- instance query failed: $($_.Exception.Message)"
        $failures.Add([pscustomobject]@{ Instance = $target; Stage = 'Instance'; Error = $_.Exception.Message })
        continue
    }

    $row = [ordered]@{ Instance = $target }
    foreach ($p in $info.PSObject.Properties) { $row[$p.Name] = $p.Value }

    if ($IncludeHardwareDetail) {
        try {
            $cs = Get-DbaComputerSystem -ComputerName $info.MachineName -EnableException
            $row['HostManufacturer']  = $cs.Manufacturer
            $row['HostModel']         = $cs.Model
            $row['HostTotalCores']    = $cs.NumberProcessors
            $row['HostLogicalCPUs']   = $cs.NumberLogicalProcessors
            $row['HostIsHyperthread'] = $cs.IsHyperThreading
        }
        catch {
            Write-Verbose "$target -- hardware detail unavailable: $($_.Exception.Message)"
        }
    }

    $instances.Add([pscustomobject]$row)

    # Everything below is best-effort. One failure should not lose the instance.
    foreach ($step in @(
        @{ Name = 'PersistedFeatures'; Query = $Q_PersistedFeatures; Sink = $features  },
        @{ Name = 'Databases';         Query = $Q_Databases;         Sink = $databases }
    )) {
        try {
            Invoke-DbaQuery @queryBase -Query $step.Query -As PSObject |
                ForEach-Object {
                    $o = [ordered]@{ Instance = $target }
                    foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
                    $step.Sink.Add([pscustomobject]$o)
                }
        }
        catch {
            Write-Warning "$target -- $($step.Name) failed: $($_.Exception.Message)"
            $failures.Add([pscustomobject]@{ Instance = $target; Stage = $step.Name; Error = $_.Exception.Message })
        }
    }

    if ($info.IsHadrEnabled -eq 1) {
        try {
            Invoke-DbaQuery @queryBase -Query $Q_Replicas -As PSObject |
                ForEach-Object {
                    $o = [ordered]@{ Instance = $target }
                    foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
                    $replicas.Add([pscustomobject]$o)
                }
        }
        catch {
            Write-Warning "$target -- Replicas failed: $($_.Exception.Message)"
            $failures.Add([pscustomobject]@{ Instance = $target; Stage = 'Replicas'; Error = $_.Exception.Message })
        }
    }
}

Write-Progress -Activity 'Edition audit' -Completed

#endregion

#region Findings

$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param($Instance, $Severity, $Finding, $Detail, $Action)
    $findings.Add([pscustomobject]@{
        Instance = $Instance; Severity = $Severity
        Finding  = $Finding;  Detail   = $Detail; Action = $Action
    })
}

foreach ($inst in $instances) {
    $name       = $inst.Instance
    $edition    = [string]$inst.Edition
    $isEnt      = $edition -like 'Enterprise*'
    $isStd      = $edition -like 'Standard*'
    $isExp      = $edition -like 'Express*'
    $isDev      = $edition -like '*Developer*'
    $isEval     = $edition -like 'Evaluation*'

    $instFeatures = @($features  | Where-Object Instance -eq $name)
    $instReplicas = @($replicas  | Where-Object Instance -eq $name)
    $instDbs      = @($databases | Where-Object Instance -eq $name)

    $cores    = [int]$inst.LogicalCPUs
    $targetGB = [decimal]$inst.CommittedTargetGB

    $overCores  = $cores    -gt $StandardCoreLimit
    $overMemory = $targetGB -gt $StandardBufferPoolGB
    $hasAg      = $instReplicas.Count -gt 0
    $isFci      = [int]$inst.IsClustered -eq 1

    # --- Cost opportunity: Enterprise with nothing requiring Enterprise ---------
    if ($isEnt -and -not $isDev -and -not $instFeatures -and -not $hasAg -and -not $overCores -and -not $overMemory) {
        Add-Finding $name 'Opportunity' 'Enterprise with no detected Enterprise dependency' `
            ("No persisted edition-restricted features, no availability group, {0} cores, {1} GB target." -f $cores, $targetGB) `
            'Candidate for Standard. Verify online index maintenance and batch mode DOP needs before deciding -- neither is visible here.'
    }

    # --- Downgrade blockers ----------------------------------------------------
    foreach ($g in $instFeatures | Group-Object FeatureName) {
        Add-Finding $name 'Blocker' "Persisted feature: $($g.Name)" `
            ("{0} database(s): {1}" -f $g.Count, (($g.Group.DatabaseName | Select-Object -Unique) -join ', ')) `
            'Reported as edition-restricted, but verify against your TARGET edition before calling it a blocker. On 2025, Compression, Partitioning, ColumnStoreIndex, InMemoryOLTP and ChangeCapture are all Standard-supported and do NOT block a move to Standard. TransparentDatabaseEncryption and ChangeCapture do block Express.'
    }

    # --- Licensing exposure: readable secondaries ------------------------------
    foreach ($r in $instReplicas | Where-Object { $_.SecondaryReadable -and $_.SecondaryReadable -ne 'NO' }) {
        Add-Finding $name 'Licensing' 'Readable secondary replica' `
            ("{0} / {1} -- secondary connections: {2}" -f $r.AvailabilityGroup, $r.ReplicaServer, $r.SecondaryReadable) `
            'A readable secondary needs its own license regardless of Software Assurance. Confirm it is licensed.'
    }

    # --- Licensing exposure: passive replicas need SA --------------------------
    if ($hasAg -or $isFci) {
        $what = if ($hasAg -and $isFci) { 'availability group and failover cluster' } elseif ($hasAg) { 'availability group' } else { 'failover cluster instance' }
        Add-Finding $name 'Licensing' 'Passive replicas present' `
            "Instance participates in a $what." `
            'The free passive secondary benefit requires active Software Assurance or a subscription. Confirm coverage.'
    }

    # --- Capacity: Enterprise justified by size -------------------------------
    if ($isEnt -and -not $isDev -and ($overCores -or $overMemory)) {
        Add-Finding $name 'Informational' 'Enterprise justified by capacity' `
            ("{0} cores (Standard caps at {1}), {2} GB target (Standard caps at {3})." -f $cores, $StandardCoreLimit, $targetGB, $StandardBufferPoolGB) `
            'Capacity alone justifies Enterprise here. No action.'
    }

    # --- Capacity: Standard at its ceiling ------------------------------------
    if ($isStd -and ($cores -ge $StandardCoreLimit -or $targetGB -ge ($StandardBufferPoolGB * 0.9))) {
        Add-Finding $name 'Warning' 'Standard at or near its ceiling' `
            ("{0} of {1} cores, {2} of {3} GB buffer pool." -f $cores, $StandardCoreLimit, $targetGB, $StandardBufferPoolGB) `
            'No headroom left. Note that columnstore and in-memory budgets are capped separately at 32 GB each.'
    }

    # --- Express approaching its database size limit ---------------------------
    if ($isExp) {
        foreach ($db in $instDbs | Where-Object { [decimal]$_.DataSizeGB -ge $ExpressWarnGB }) {
            Add-Finding $name 'Warning' 'Express database approaching size limit' `
                ("{0} is {1} GB of a {2} GB maximum." -f $db.DatabaseName, $db.DataSizeGB, $ExpressMaxDatabaseGB) `
                'Plan the move to Standard before it stops accepting writes.'
        }
    }

    # --- Non-production editions ----------------------------------------------
    if ($isDev) {
        Add-Finding $name 'Compliance' 'Developer edition' `
            "Edition reports as '$edition'." `
            'Licensed for development and test only. If this carries production workload it is a licensing violation.'
    }

    if ($isEval) {
        Add-Finding $name 'Compliance' 'Evaluation edition' `
            "Edition reports as '$edition'." `
            'Expires 180 days after installation and the instance stops. Confirm the install date and plan a real license.'
    }
}

foreach ($f in $failures) {
    Add-Finding $f.Instance 'Error' "Collection failed: $($f.Stage)" $f.Error `
        'Instance data is incomplete. Re-run against this instance before trusting the totals.'
}

#endregion

#region Output

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$exports = @{
    'Instances.csv'         = $instances
    'PersistedFeatures.csv' = $features
    'Databases.csv'         = $databases
    'Replicas.csv'          = $replicas
    'Findings.csv'          = $findings
}

foreach ($file in $exports.Keys | Sort-Object) {
    $data = $exports[$file]
    if ($data.Count) {
        $data | Export-Csv -LiteralPath (Join-Path $OutputPath $file) -NoTypeInformation -Encoding UTF8
    }
}

$order = @{ Error = 0; Blocker = 1; Licensing = 2; Compliance = 3; Warning = 4; Opportunity = 5; Informational = 6 }

Write-Host ''
Write-Host '=== Edition audit summary ===' -ForegroundColor Cyan
Write-Host ''
Write-Host ("Instances audited : {0} of {1}" -f $instances.Count, $targets.Count)
Write-Host ("Databases seen    : {0}" -f $databases.Count)
Write-Host ("Findings          : {0}" -f $findings.Count)
Write-Host ''

if ($instances.Count) {
    $instances |
        Select-Object Instance, Edition, ProductVersion, ProductLevel,
                      @{ n = 'Cores';    e = { $_.LogicalCPUs } },
                      @{ n = 'TargetGB'; e = { $_.CommittedTargetGB } },
                      @{ n = 'AG';       e = { if ($_.IsHadrEnabled -eq 1) { 'Yes' } else { '' } } },
                      @{ n = 'FCI';      e = { if ($_.IsClustered   -eq 1) { 'Yes' } else { '' } } } |
        Sort-Object Edition, Instance |
        Format-Table -AutoSize
}

if ($findings.Count) {
    Write-Host 'Findings by severity:' -ForegroundColor Yellow
    $findings |
        Group-Object Severity |
        Sort-Object { $order[$_.Name] } |
        Select-Object @{ n = 'Severity'; e = { $_.Name } }, Count |
        Format-Table -AutoSize

    $opportunities = @($findings | Where-Object Severity -eq 'Opportunity')
    if ($opportunities.Count) {
        Write-Host 'Downgrade candidates:' -ForegroundColor Green
        $opportunities | Select-Object Instance, Detail | Format-Table -AutoSize -Wrap
    }

    $exposure = @($findings | Where-Object Severity -in 'Licensing', 'Compliance')
    if ($exposure.Count) {
        Write-Host 'Licensing and compliance items to confirm:' -ForegroundColor Magenta
        $exposure | Select-Object Instance, Finding, Detail | Format-Table -AutoSize -Wrap
    }
}
else {
    Write-Host 'No findings.' -ForegroundColor Green
}

Write-Host ''
Write-Host "CSVs written to: $OutputPath" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Reminder: persisted-feature rows are NOT automatically blockers. On SQL Server'  -ForegroundColor DarkYellow
Write-Host '2025, Compression, Partitioning, ColumnStoreIndex, InMemoryOLTP and ChangeCapture' -ForegroundColor DarkYellow
Write-Host 'all run on Standard and do not block a move there.'                                -ForegroundColor DarkYellow
Write-Host ''
Write-Host 'And an empty result is not permission either. Capacity, availability groups,'      -ForegroundColor DarkYellow
Write-Host 'online index maintenance and batch mode DOP are not persisted anywhere this'       -ForegroundColor DarkYellow
Write-Host 'script can see them.'                                                              -ForegroundColor DarkYellow
Write-Host ''

#endregion
