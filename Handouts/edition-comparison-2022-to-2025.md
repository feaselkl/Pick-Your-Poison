# SQL Server Editions: What Changed from 2022 to 2025

Companion reference for [Pick Your Poison: Choosing the Right Edition of SQL Server](https://csmore.info/on/editions).

**Accurate as of:** _2026-10-10_
**Authoritative source:** [Editions and supported features of SQL Server 2025](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2025)

---

## The lineup

| Edition | 2022 | 2025 |
|---|---|---|
| Enterprise | Yes | Yes |
| Standard | Yes | Yes |
| Developer | Yes | **Renamed to Enterprise Developer** |
| Standard Developer | — | **New** |
| Evaluation | Yes (180 days) | Yes (180 days) |
| Express | Yes | Yes |
| Express with Advanced Services | Yes | **Discontinued** (folded into Express) |
| Web | Yes | **Discontinued** |
| Business Intelligence | Already gone | Gone |

---

## Capacity limits

| Limit | 2022 Standard | 2025 Standard | Changed? |
|---|---|---|---|
| Max compute | Lesser of 4 sockets or **24 cores** | Lesser of 4 sockets or **32 cores** | **Yes** |
| Buffer pool | **128 GB** | **256 GB** | **Yes** |
| Columnstore segment cache | 32 GB | 32 GB | No |
| Memory-optimized data per DB | 32 GB | 32 GB | No |
| Max relational database size | 524 PB | 524 PB | No |

> **The asterisk that matters.** The 256 GB applies to the *buffer pool only*. The
> columnstore segment cache and memory-optimized data budgets are separate and did
> not move. Doubling your buffer pool does not double your columnstore headroom.

| Limit | 2022 Express | 2025 Express | Changed? |
|---|---|---|---|
| Max compute | Lesser of 1 socket or 4 cores | Lesser of 1 socket or 4 cores | No |
| Buffer pool | 1,410 MB | 1,410 MB | No |
| **Max relational database size** | **10 GB** | **50 GB** | **Yes** |

> The Linux editions page currently still lists 10 GB for Express while the Windows
> page and the What's New page say 50 GB. Verify against a live instance before
> relying on this in a design.

Enterprise remains at operating-system maximum for compute and memory, with one
carve-out: Enterprise under **Server + CAL** is capped at 20 cores per instance and
is **not available for new agreements**.

---

## Features that moved to Standard in 2025

Short list. This is the complete set of engine features the official What's New
edition-changes section calls out:

| Feature | 2022 | 2025 |
|---|---|---|
| Resource Governor | Enterprise only | **Standard** (full Enterprise functionality) |

Plus one licensing change with outsized practical value:

| Right | 2022 | 2025 |
|---|---|---|
| Power BI Report Server use rights | Enterprise **with active SA** only | **Standard and Enterprise, any license type** |

If you came expecting a long list of Enterprise features to have moved down, this is
it. The capacity increases and the PBIRS rights are the story; the feature matrix
barely moved.

---

## Still Enterprise-only in 2025

None of the following changed. If one of these is why you bought Enterprise, 2025
gives you no reason to reconsider.

**High availability**
- Always On availability groups (Standard gets *basic* AGs: 2 replicas, 1 database, non-readable secondary)
- Contained availability groups
- Distributed availability groups
- Automatic read-write connection rerouting
- Failover cluster instances beyond 2 nodes (Enterprise supports 16)
- Online page and file restore
- Fast recovery
- Mirrored backups
- Hot add memory

**Maintenance**
- Online index create and rebuild
- Resumable online index create and rebuild
- Resumable online `ADD CONSTRAINT`
- Online schema change
- Online nonclustered columnstore index rebuild
- Parallel index maintenance operations
- Parallel consistency check (`DBCC`)

**Performance and scale**
- Read-ahead
- Advanced scanning
- AVX-512 support
- Integrated acceleration and offloading (hardware)
- Memory-optimized TempDB metadata
- Hybrid buffer pool support for direct write
- NUMA-aware large page memory and buffer array allocation

**Data warehouse**
- Star join query optimizations
- Parallel query processing on partitioned tables and indexes
- Global batch aggregation
- Distributed partitioned views
- Automatic use of indexed views by the query optimizer

**Other**
- Query Store on secondary replicas
- Oracle publishing
- Peer-to-peer transactional replication
- Advanced R and Python integration

---

## The limits that do not appear as "No" in any table

These are footnotes, and they cause more surprises than the matrix does.

| Constraint | Enterprise | Standard | Express |
|---|---|---|---|
| Batch mode degree of parallelism | Unrestricted | **2** | **1** |
| Columnstore index build DOP | Unrestricted | **2** | **1** |
| Basic R / Python integration | Full | 2 cores, in-memory datasets | 2 cores, in-memory datasets |
| Indexed view querying | Automatic | Requires `NOEXPAND` | Requires `NOEXPAND` |

The batch mode DOP cap is the one that turns into a support call. Same hardware,
same data, same query, half the parallelism.

---

## AI features are not edition-gated

Every one of these is available in **Enterprise, Standard, and Express**:

- Native vector data type
- DiskANN-based vector indexing ¹
- External models support
- Local ONNX models support ¹
- Embedding generation
- Chunking

¹ Requires the `PREVIEW_FEATURES` database-scoped configuration, as do fuzzy string
matching and change event streaming. That flag, not your edition, is the real gate —
and it is the thing to raise in a production-readiness conversation.

---

## Reporting and adjacent services

- On-premises reporting consolidates under **Power BI Report Server**. No new SSRS versions will ship.
- **SSRS 2022 is the final release**, security-supported through **January 11, 2033**.
- SSRS 2022 can continue to use a later Database Engine version to host its catalog.
- **DQS, MDS, and Reporting Services upgrades are all unsupported on SQL Server 2025.**

---

## Upgrade paths into 2025

Supported source versions: SQL Server 2014 SP3, 2016 SP3, 2017, 2019, 2022.

| From | To |
|---|---|
| Enterprise | Enterprise |
| Standard | Enterprise, Standard |
| **Web** | Enterprise, Standard |
| Developer | Enterprise Developer, Standard Developer, Enterprise |
| Evaluation | Evaluation, Enterprise Developer, Standard Developer, Enterprise, Standard |
| Express | Enterprise, Standard, Express |
| **Business Intelligence** | Enterprise only |
