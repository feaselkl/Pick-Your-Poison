# Edition Change Runbooks

Companion reference for [Pick Your Poison: Choosing the Right Edition of SQL Server](https://csmore.info/on/editions).

**Accurate as of:** _2026-10-10_

This runbook demonstrates the process to upgrade or downgrade a version of SQL Server. Upgrading is supported in place. Downgrading is not.

---

## Upgrading an edition (in place)

Supported by Setup against a defined matrix. See the upgrade paths table in
`edition-comparison-2022-to-2025.md`.

### Wizard

1. Run `setup.exe` from the installation media for the **target** edition.
2. Choose **Maintenance** → **Edition Upgrade**.
3. Supply the product key for the target edition (or select a free edition).
4. Accept license terms.
5. Select the instance to upgrade.
6. Let the Edition Upgrade Rules check pass.
7. Confirm on **Ready to Upgrade Edition** and run it.
8. Restart if instructed. Review the summary log.

### Command line

```
setup.exe /q /ACTION=EditionUpgrade /INSTANCENAME=<instance> ^
          /PID=<product key> /IACCEPTSQLSERVERLICENSETERMS
```

### Notes

- **Services restart.** Budget application downtime even though the operation itself is quick.
- **On a failover cluster instance**, running the upgrade on one node is sufficient. It can be the active or passive node, and the Database Engine does not take resources offline. Afterward you must restart the instance or fail over to a different node.
- Review [compute capacity limits by edition](https://learn.microsoft.com/sql/sql-server/compute-capacity-limits-by-edition-of-sql-server) first — an upgrade that raises your ceiling changes nothing until the instance restarts.

---

## Downgrading an edition

**There is no in-place downgrade.** Setup does not support it. The only path is a
full uninstall and reinstall.

### Before you commit — the pre-flight that actually matters

Run these, in this order. The first one is necessary but nowhere near sufficient.

**1. Can the databases be restored onto the target edition?**

```sql
SELECT feature_name FROM sys.dm_db_persisted_sku_features;
```

Run it in every user database. Any rows returned are hard blockers — the database
will not attach or restore on an edition that lacks those features.

> **This DMV misleads in both directions.** Verified on SQL Server 2025: a database
> using partitioning, compression, columnstore, In-Memory OLTP, change data capture
> and TDE returns **all six** as edition-restricted features.
>
> ```
> 100  Compression        500  TransparentDatabaseEncryption
> 200  Partitioning       600  ColumnStoreIndex
> 400  ChangeCapture      800  InMemoryOLTP
> ```
>
> **Not one of them blocks a move to Standard.** All six became cross-edition
> in SQL Server 2016 SP1 (TDE in 2019), and the DMV was never updated to say so. The
> restore succeeds without a warning.
>
> So do not read rows as blockers. And do not read zero rows as safety either: the
> DMV answers *"will it restore,"* never *"will it work."* The only rows that
> genuinely restrict anything restrict **Express**, which has neither TDE nor CDC.

**2. Will the workload still fit?** None of these are persisted, so none of them
appear above.

- [ ] **Capacity.** Does the instance currently exceed 32 cores or 256 GB buffer pool? Standard will cap it silently.
- [ ] **Availability groups.** Standard gets basic AGs only — two replicas, one database, non-readable secondary. Contained and distributed AGs are gone. An FCI beyond two nodes is gone.
- [ ] **Maintenance windows.** Online and resumable index operations are Enterprise-only. Every rebuild becomes a blocking operation. Will the window still fit?
- [ ] **Columnstore and DW workloads.** Batch mode DOP drops to 2. Star join optimization, partitioned-table parallelism, and global batch aggregation disappear.
- [ ] **Consistency checks.** Parallel `DBCC` is Enterprise-only. `CHECKDB` gets slower.
- [ ] **Recovery.** Fast recovery and online page/file restore are Enterprise-only. Failover and crash recovery take longer.
- [ ] **Reporting.** Confirm PBIRS rights under the target edition and license type.

Microsoft maintains a guide for the aftermath at
[Troubleshoot performance problems after changing the SQL Server edition](https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-performance-edition-change).

This exists precisely because the restore is the easy part.

**3. Test it.** Restore a production-sized copy onto the target edition and run your
actual maintenance jobs and heaviest queries against it. `Scripts/03 - The Downgrade
Reality Check.sql` is a worked example of exactly this.

### The procedure

1. **Back up everything**, including system databases (`master`, `model`, `msdb`) and all user databases.
2. Script out server-level objects: logins, server roles, credentials, linked servers, SQL Agent jobs, alerts, operators, server triggers, certificates, and audit specifications.
3. Record the instance configuration: `sp_configure` output, trace flags, startup parameters, service accounts, collation, and file paths.
4. **Move the system database files** (`master`, `model`, `msdb`) to a separate directory. Do not skip this.
5. **Completely uninstall** SQL Server and all associated services.
6. **Restart the computer.** A fresh installation requires it.
7. **Install the target edition**, using the **same instance name** and the **same collation** as before.
8. Apply the latest cumulative update to match the prior patch level.
9. Replace the newly created system databases with the ones you moved aside in step 4.
10. Restore user databases if they were not left in place.
11. Reapply server-level objects from step 2.
12. Validate: application connectivity, Agent jobs, maintenance plans, and a `DBCC CHECKDB` pass.

### Budget

Real downtime, meaning hours, not minutes. Unlike an edition upgrade, this is a rebuild of
the instance. Schedule it like one.

---

## The alternative: side-by-side migration

Often less risky than an in-place downgrade, and it gives you a rollback.

1. Build a new instance at the target edition on separate hardware.
2. Migrate databases and server-level objects.
3. Cut over with DNS or a connection-string change.
4. Keep the original instance intact until you are satisfied.

Costs you a second machine and a second license for the overlap window. Buys you the
ability to change your mind.
