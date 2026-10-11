/* ============================================================
   DEMO 2:  Auditing what you actually have.

   Run against any of the three instances from Scripts/Setup.

   The uncomfortable opening:  run Part 1 against these demo
   containers and the audit immediately flags the environment
   itself. Two of the three are Developer editions. If this were
   a production estate, that is a licensing violation -- and it is
   exactly the kind of thing that drifts in when a "temporary"
   dev box quietly becomes load-bearing.

   The single-instance version is below. For a real estate, see
   Scripts/Estate/Invoke-SqlEditionAudit.ps1, which runs this
   collection across many instances via dbatools and grades the
   findings.
   ============================================================ */


/* ------------------------------------------------------------
   PART 1  --  Inventory, and the first finding

   Start here on every instance you own. Two questions at once:
   what is it, and is it licensed for what it is doing?
   ------------------------------------------------------------ */

SELECT
    MachineName   = SERVERPROPERTY('MachineName'),
    InstanceName  = ISNULL(SERVERPROPERTY('InstanceName'), 'MSSQLSERVER'),
    Edition       = SERVERPROPERTY('Edition'),
    EngineEdition = SERVERPROPERTY('EngineEdition'),
    Version       = SERVERPROPERTY('ProductVersion'),
    PatchLevel    = SERVERPROPERTY('ProductLevel'),
    IsClustered   = SERVERPROPERTY('IsClustered'),
    IsHadrEnabled = SERVERPROPERTY('IsHadrEnabled'),
    LicenseFlag   =
        CASE
            WHEN CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) LIKE '%Developer%'
                THEN 'NON-PRODUCTION ONLY -- a production workload here is a violation'
            WHEN CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) LIKE '%Evaluation%'
                THEN 'EXPIRES 180 DAYS AFTER INSTALL -- the instance will stop'
            WHEN CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) LIKE '%Express%'
                THEN 'Free for any use, but check the 50 GB per-database ceiling'
            ELSE 'Paid edition -- confirm core count and Software Assurance status'
        END;
GO


/* ------------------------------------------------------------
   PART 2  --  What are we paying for, and what are we using?

   Walk every database and collect persisted edition-restricted
   features. The Contoso / ContosoStaging contrast is the lesson:
   one of them is stuffed with features people associate with
   Enterprise, the other has none, and this DMV can barely tell
   them apart.
   ------------------------------------------------------------ */

DROP TABLE IF EXISTS #SkuFeatures;
CREATE TABLE #SkuFeatures
(
    DatabaseName SYSNAME,
    FeatureID    INT,
    FeatureName  NVARCHAR(255)
);

-- A documented cursor rather than sp_MSforeachdb.  sp_MSforeachdb is
-- undocumented and is known to silently skip databases under some
-- conditions -- not what you want in an audit, and not what you want
-- running on stage.
DECLARE @db SYSNAME, @sql NVARCHAR(MAX);

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
        INSERT INTO #SkuFeatures (DatabaseName, FeatureID, FeatureName)
        EXEC (@sql);
    END TRY
    BEGIN CATCH
        -- Unreadable secondary, missing permission, or a database that went
        -- offline mid-loop.  Skip it rather than abandoning the audit.
    END CATCH

    FETCH NEXT FROM dbs INTO @db;
END

CLOSE dbs;
DEALLOCATE dbs;
GO

-- Every online user database, and what it reports.
SELECT
    d.name                      AS DatabaseName,
    ISNULL(f.FeatureName, '--') AS RestrictedFeature
FROM sys.databases AS d
    LEFT OUTER JOIN #SkuFeatures AS f
        ON f.DatabaseName = d.name
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
ORDER BY d.name, RestrictedFeature;
GO

-- The summary that goes in front of a manager.
SELECT
    FeatureName,
    DatabaseCount = COUNT(*),
    Databases     = STRING_AGG(DatabaseName, ', ')
FROM #SkuFeatures
GROUP BY FeatureName
ORDER BY DatabaseCount DESC;
GO

/* If this comes back empty or nearly empty, resist the obvious conclusion.
   It means these databases can be RESTORED onto a lower edition. It does
   not mean the workload will still work there. Demo 3 makes that concrete. */


/* ------------------------------------------------------------
   PART 3  --  Headroom:  would Standard actually fit?

   Compare current usage against the Standard 2025 ceilings. On the
   demo containers there is enormous headroom, which is the normal
   case and worth saying out loud.
   ------------------------------------------------------------ */

SELECT
    Metric       = 'Cores',
    CurrentValue = CONVERT(varchar(20), scheduler_count),
    StandardCap  = '32',
    Verdict      = CASE WHEN scheduler_count > 32 THEN 'EXCEEDS Standard' ELSE 'fits' END
FROM sys.dm_os_sys_info
UNION ALL
SELECT
    'Buffer pool GB',
    CONVERT(varchar(20), CONVERT(decimal(10,1), committed_target_kb / 1048576.0)),
    '256',
    CASE WHEN committed_target_kb / 1048576.0 > 256 THEN 'EXCEEDS Standard' ELSE 'fits' END
FROM sys.dm_os_sys_info;
GO

-- Largest databases, for the Express 50 GB conversation.
SELECT TOP (10)
    DatabaseName = DB_NAME(database_id),
    DataSizeGB   = CONVERT(decimal(12,2), SUM(CASE WHEN type_desc = 'ROWS' THEN size ELSE 0 END) * 8.0 / 1048576.0),
    LogSizeGB    = CONVERT(decimal(12,2), SUM(CASE WHEN type_desc = 'LOG'  THEN size ELSE 0 END) * 8.0 / 1048576.0),
    ExpressFlag  = CASE WHEN SUM(CASE WHEN type_desc = 'ROWS' THEN size ELSE 0 END) * 8.0 / 1048576.0 > 50
                        THEN 'Over the Express ceiling' ELSE '' END
FROM sys.master_files
WHERE database_id > 4
GROUP BY database_id
ORDER BY DataSizeGB DESC;
GO


/* ------------------------------------------------------------
   PART 4  --  Where the licensing exposure sits

   These two queries return nothing on a standalone instance, and
   that is worth being honest about on stage: the demo containers
   have no availability group and no cluster. What matters is that
   you know to run them, and what a hit looks like.
   ------------------------------------------------------------ */

IF CONVERT(int, SERVERPROPERTY('IsHadrEnabled')) = 1
BEGIN
    SELECT
        AvailabilityGroup = ag.name,
        ReplicaServer     = ar.replica_server_name,
        AvailabilityMode  = ar.availability_mode_desc,
        SecondaryReadable = ar.secondary_role_allow_connections_desc,
        CurrentRole       = hars.role_desc,
        LicenseFlag       = CASE
                               WHEN ar.secondary_role_allow_connections_desc <> 'NO'
                                   THEN 'READABLE -- needs its own license, SA or not'
                               ELSE 'Passive -- free only with active Software Assurance'
                            END
    FROM sys.availability_groups AS ag
        INNER JOIN sys.availability_replicas AS ar
            ON ag.group_id = ar.group_id
        LEFT OUTER JOIN sys.dm_hadr_availability_replica_states AS hars
            ON ar.replica_id = hars.replica_id
    ORDER BY ag.name, ar.replica_server_name;
END
ELSE
    SELECT Note = 'No availability groups on this instance. On a real estate this '
                + 'is where the most common audit finding lives: a passive replica '
                + 'nobody confirmed Software Assurance for, or a secondary somebody '
                + 'made readable for reporting without realising it now needs a license.';
GO

IF CONVERT(int, SERVERPROPERTY('IsClustered')) = 1
    SELECT NodeName, status_description, is_current_owner
    FROM sys.dm_os_cluster_nodes;
ELSE
    SELECT Note = 'Not a failover cluster instance. Passive FCI nodes carry the same '
                + 'Software Assurance requirement as AG replicas.';
GO


/* ------------------------------------------------------------
   PART 5  --  Core counting inputs

   Establish physical versus virtual before you count anything,
   because the counting rule changes.
   ------------------------------------------------------------ */

SELECT
    LogicalCPUsSeen  = cpu_count,
    SchedulersUsable = scheduler_count,
    HyperthreadRatio = hyperthread_ratio,
    PhysicalSockets  = cpu_count / NULLIF(hyperthread_ratio, 0),
    MachineType      = virtual_machine_type_desc,
    CountingRule     = CASE
                          WHEN virtual_machine_type_desc <> 'NONE'
                              THEN 'Virtual: count logical processors. Hyperthreading COUNTS. 4-core minimum per VM.'
                          ELSE 'Physical: count physical cores. Hyperthreading does NOT count. 4-core minimum per socket.'
                       END
FROM sys.dm_os_sys_info;
GO


/* Cleanup */
DROP TABLE IF EXISTS #SkuFeatures;
GO


/* ------------------------------------------------------------
   One instance is a demo. An estate is the real problem.

   Scripts/Estate/Invoke-SqlEditionAudit.ps1 runs all of the above
   across every instance you point it at and grades the findings:

     Error         collection failed, totals are incomplete
     Blocker       persisted feature that blocks a restore
     Licensing     readable secondary, or passive replicas needing SA
     Compliance    Developer or Evaluation edition in the wrong place
     Warning       Standard at its ceiling, Express near 50 GB
     Opportunity   Enterprise with no detected Enterprise dependency
     Informational Enterprise justified by capacity

   Start with Opportunity if you are hunting cost. Start with
   Licensing if you have an audit coming.
   ------------------------------------------------------------ */
