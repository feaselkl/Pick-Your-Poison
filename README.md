# Pick Your Poison
## Choosing the Right Edition of SQL Server

This is the repository for my talk entitled [Pick Your Poison: Choosing the Right Edition of SQL Server](https://csmore.info/on/editions).

## Setting Up SQL Server

The demos compare edition behavior on identical hardware, so the Compose file
builds and starts **three** SQL Server 2025 instances, one per edition, each with
the demo databases baked into the image.

### Build and Run

From the repository root:

```bash
docker compose -f Scripts/Setup/docker-compose.yml up -d --build
```

The first build takes a few minutes per image: it pulls the SQL Server 2025 image,
then seeds, names, and verifies each instance at build time. After that, containers
start ready.

Each image gets a real server name rather than the `buildkitsandbox` that gets baked
in otherwise — without that, all three instances report the same `@@SERVERNAME` and
the estate audit demo looks broken.

### Connection Details

| Setting  | Standard Developer   | Enterprise Developer | Express              |
|----------|----------------------|----------------------|----------------------|
| Server   | `localhost`          | `localhost`          | `localhost`          |
| Port     | `1433`               | `1434`               | `1435`               |
| User     | `sa`                 | `sa`                 | `sa`                 |
| Password | `SqlServerDemo2025!` | `SqlServerDemo2025!` | `SqlServerDemo2025!` |
| EngineEdition | `2`             | `3`                  | `4`                  |
| `@@SERVERNAME` | `SQL2025-STD`  | `SQL2025-ENT`        | `SQL2025-EXP`        |

These defaults work directly with the VS Code mssql extension or any other SQL client.

### Why three editions

**Standard Developer** is new in SQL Server 2025, and it is the reason this pairing
is possible at all. Before 2025 there was no free edition matching the Standard
feature set, so certifying against Standard meant buying a license or guessing.

**Express** is there for a less obvious reason. Standard and Enterprise report
*identical* capacity on any host with fewer than 32 cores, because Standard's
ceiling never binds there. That is the talk's thesis, but it makes for a dull
demo on its own. Express is limited to the lesser of 1 socket or 4 cores, so it
is the only edition whose ceiling is observable on a laptop — compare `cpu_count`
across all three. Verified on a 16-logical-processor host: Standard 16,
Enterprise 16, **Express 8**.

The documented memory ceilings are real but are *not* observable at idle;
`committed_target_kb` reports a target, not the edition cap. Script 01 says so
explicitly rather than showing a misleading number.

### The demo databases

Both are created at image build time by `Scripts/Setup/seed-demo-database.sql`.

| Database | Contents |
|---|---|
| `Contoso` | Deliberately feature-heavy: partitioning, page compression, clustered columnstore, In-Memory OLTP, change data capture, and TDE — six features people file mentally under "Enterprise" |
| `ContosoStaging` | Deliberately plain, with no edition-restricted features. The control case |

The seed is edition-aware: Express skips CDC and TDE, which it cannot do. Every
feature step is independently wrapped in `TRY`/`CATCH` and reports its outcome,
so a single failure degrades the seed rather than breaking the image build — and
the demo scripts inventory what is actually present rather than assuming.

The point of `Contoso` is the gap between how expensive it looks and what
`sys.dm_db_persisted_sku_features` actually reports about it.

### Stopping and Removing the Containers

```bash
docker compose -f Scripts/Setup/docker-compose.yml down        # keep volumes
docker compose -f Scripts/Setup/docker-compose.yml down -v     # drop volumes too
```

### Without Docker

Any SQL Server 2025 instance works for the discovery and audit queries — run
`Scripts/Setup/seed-demo-database.sql` against it first. To see edition
differences you need instances at different editions; Standard Developer and
Enterprise Developer are free, and so is Express.

## Running the Code

All scripts are in the `Scripts` folder and can be run from SQL Server Management
Studio, VS Code with the mssql extension, or whatever your SQL Server query runner
of choice.

| Script | Covers |
|--------|--------|
| `01 - Edition and Capacity Discovery.sql` | Six "Enterprise" features in one database, and how few of them the DMV actually reports |
| `02 - Estate Audit and Compliance.sql` | Single-instance audit: inventory, feature usage, headroom, and licensing exposure. Opens by flagging the demo environment itself |
| `03 - The Downgrade Reality Check.sql` | Two-instance walkthrough showing why an empty `sys.dm_db_persisted_sku_features` result is not sufficient to downgrade |

Run script 01 against **all three** instances and compare. Parts 1 and 2 are the
capacity contrast; Parts 3 and 4 are the reveal, and work best on Standard or
Enterprise. Part 5 runs on Express deliberately.

## Auditing a Real Estate

`Scripts/Estate/Invoke-SqlEditionAudit.ps1` runs the same collection across many
instances and writes CSVs plus a prioritized findings list. It needs
[dbatools](https://dbatools.io).

```powershell
# Explicit list
.\Scripts\Estate\Invoke-SqlEditionAudit.ps1 -SqlInstance sql01, sql02, 'sql03\PROD'

# From a file, one instance per line
.\Scripts\Estate\Invoke-SqlEditionAudit.ps1 -InputFile .\instances.txt -OutputPath C:\Audit

# From a Central Management Server
.\Scripts\Estate\Invoke-SqlEditionAudit.ps1 -CmsServer cms01 -RegisteredServerGroup Production

# Against the demo containers above
$cred = Get-Credential sa
.\Scripts\Estate\Invoke-SqlEditionAudit.ps1 `
    -SqlInstance 'localhost,1433', 'localhost,1434', 'localhost,1435' `
    -SqlCredential $cred
```

**On certificates.** Microsoft.Data.SqlClient v4 and later default `Encrypt` to
`Mandatory`, so an untrusted or self-signed certificate refuses the connection
outright — which describes every SQL Server container and plenty of on-premises
instances.

The script handles this itself: when a connection fails certificate validation it
retries without validation and warns that it did so. You get the audit, and you
get told what happened. Two switches override that:

| Switch | Effect |
|---|---|
| `-TrustServerCertificate` | Skip validation from the outset, no warning |
| `-NoCertificateFallback` | Treat certificate failures as errors instead of retrying |

Use `-NoCertificateFallback` when auditing an estate that is supposed to have
properly trusted certificates and you want to find out where it does not.

These scripts are read-only, and because the scripts themselves are just plain T-SQL against DMVs, they will work across Windows, Linux, and containers. Host-level hardware detail via WMI is opt-in with
`-IncludeHardwareDetail` and this is Windows-only.

Output: `Instances.csv`, `PersistedFeatures.csv`, `Databases.csv`, `Replicas.csv`,
and `Findings.csv`. Findings are graded **Error**, **Blocker**, **Licensing**,
**Compliance**, **Warning**, **Opportunity**, **Informational**. Start with
Opportunity if you are hunting cost and Licensing if you have an audit coming.
