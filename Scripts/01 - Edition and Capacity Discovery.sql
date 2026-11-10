/* ============================================================
   DEMO 1:  What does this edition actually cost me?

   The setup:  three instances on ONE host, from Scripts/Setup.
       localhost,1433  -> Standard Developer   (EngineEdition 2)
       localhost,1434  -> Enterprise Developer (EngineEdition 3)
       localhost,1435  -> Express              (EngineEdition 4)

   And one database, Contoso, deliberately built out of six features
   that nearly everyone files mentally under "Enterprise":

       partitioning, data compression, clustered columnstore,
       In-Memory OLTP, change data capture, and TDE

   Question for the room:  how many of those six stop you from
   moving this database to SQL Server 2025 Standard?

   Collect guesses before Part 4. The DMV's answer and the real
   answer are both surprising, and they are not the same number.
   ============================================================ */


/* ------------------------------------------------------------
   PART 1  --  What are we running?

   Run this on all three. The interesting column is EngineEdition:
   it is what your deployment scripts should branch on, and it is
   why Standard Developer matters -- before 2025 there was no free
   edition that reported 2.
   ------------------------------------------------------------ */

SELECT
    Edition        = SERVERPROPERTY('Edition'),
    EngineEdition  = SERVERPROPERTY('EngineEdition'),
    EngineMeaning  = CASE CONVERT(int, SERVERPROPERTY('EngineEdition'))
                        WHEN 2 THEN 'Standard (also Web, historically)'
                        WHEN 3 THEN 'Enterprise, Evaluation, Enterprise Developer'
                        WHEN 4 THEN 'Express'
                        WHEN 5 THEN 'Azure SQL Database'
                        WHEN 8 THEN 'Azure SQL Managed Instance'
                        ELSE 'Something else'
                     END,
    ProductVersion = SERVERPROPERTY('ProductVersion'),
    ProductLevel   = SERVERPROPERTY('ProductLevel');
GO


/* ------------------------------------------------------------
   PART 2  --  What can this instance actually USE?

   Same host. Same silicon. Run this on all three and compare
   cpu_count.

   VERIFIED on a 16-logical-processor host:

       Standard    cpu_count = 16
       Enterprise  cpu_count = 16
       Express     cpu_count =  8   <-- capped

   Express is limited to the lesser of 1 socket or 4 cores, and on
   a host with simultaneous multithreading that lands at 8 logical
   processors. The engine simply refuses to see the rest. That is an
   edition ceiling being enforced in front of you.

   And Standard matches Enterprise exactly, which is the finding that
   actually matters. Standard's 32-core ceiling does not bind on this
   box, and it will not bind on most of yours either. The capacity gap
   people buy Enterprise to avoid is, for a great many workloads,
   imaginary.
   ------------------------------------------------------------ */

SELECT
    Edition          = CONVERT(nvarchar(40), SERVERPROPERTY('Edition')),
    EngineEdition    = SERVERPROPERTY('EngineEdition'),
    LogicalCPUs      = cpu_count,
    Schedulers       = scheduler_count,
    HyperthreadRatio = hyperthread_ratio,
    MachineType      = virtual_machine_type_desc
FROM sys.dm_os_sys_info;
GO

/* A note on what NOT to show here.

   The documented memory ceilings are real -- Standard 256 GB buffer
   pool, Express 1,410 MB -- but they are NOT observable at idle, and
   two obvious-looking queries will mislead you:

     - committed_target_kb reports a TARGET derived from max server
       memory, not the edition cap. On the demo containers it reads
       roughly 41 GB on all three, Express included.

     - The buffer pool memory clerk reads single-digit MB on an idle
       instance, and scanning the demo data does not grow it enough
       to approach any ceiling.

   Demonstrating the memory cap honestly needs sustained memory
   pressure, which is not a 3-minute demo. State the numbers, point at
   the documentation, and move on -- the CPU cap above is the one you
   can actually show.

   The asterisk worth saying out loud: Standard's 256 GB is the BUFFER
   POOL. Columnstore segment cache and memory-optimized data are capped
   separately at 32 GB each, and neither moved in 2025. */

/* ------------------------------------------------------------
   PART 3  --  The expensive-looking database

   Run on Standard (1433) or Enterprise (1434).

   First, prove the six features are genuinely present. This is not
   a contrived list -- it is what a decade-old "we needed Enterprise
   for this" database actually looks like.
   ------------------------------------------------------------ */

USE Contoso;
GO

SELECT
   Feature = 'Partitioning',
   Present = CASE WHEN EXISTS (SELECT 1 FROM sys.partition_schemes) THEN 'YES' ELSE 'no' END,
   Detail = (SELECT CONCAT(COUNT(DISTINCT p.partition_number), ' partitions on dbo.SalesFact')
                 FROM sys.partitions p WHERE p.object_id = OBJECT_ID('dbo.SalesFact'))
UNION ALL
SELECT
   Feature = 'Data compression',
   Present = CASE WHEN EXISTS (SELECT 1 FROM sys.partitions WHERE data_compression > 0 AND object_id > 100) THEN 'YES' ELSE 'no' END,
   Detail = (SELECT CONCAT(COUNT(*), ' compressed partition(s)') FROM sys.partitions WHERE data_compression > 0 AND object_id > 100)
UNION ALL
SELECT
   Feature = 'Clustered columnstore',
   Present = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE type = 5) THEN 'YES' ELSE 'no' END,
   Detail = (SELECT CONCAT(COUNT(*), ' rowgroup(s)') FROM sys.column_store_row_groups)
UNION ALL
SELECT
   Feature = 'In-Memory OLTP',
   Present = CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE is_memory_optimized = 1) THEN 'YES' ELSE 'no' END,
   Detail = (SELECT CONCAT(COUNT(*), ' memory-optimized table(s)') FROM sys.tables WHERE is_memory_optimized = 1)
UNION ALL
SELECT
   Feature = 'Change data capture',
   Present = CASE WHEN (SELECT is_cdc_enabled FROM sys.databases WHERE database_id = DB_ID()) = 1 THEN 'YES' ELSE 'no' END,
   -- sys.tables.is_tracked_by_cdc, not cdc.change_tables: the cdc schema
   -- does not exist at all where CDC was never enabled, and a direct
   -- reference to it fails at compile time on Express.
   Detail = (SELECT CONCAT(COUNT(*), ' captured table(s)') FROM sys.tables WHERE is_tracked_by_cdc = 1)
UNION ALL
SELECT
   Feature = 'TDE',
   Present = CASE WHEN (SELECT is_encrypted FROM sys.databases WHERE database_id = DB_ID()) = 1 THEN 'YES' ELSE 'no' END,
   Detail = (SELECT CONCAT('encryption_state = ', MAX(encryption_state)) FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID());
GO


/* ------------------------------------------------------------
   PART 4  --  The reveal

   Every one of those six features changes how data is stored, so
   every one is a candidate for blocking a move to a lower edition.
   This DMV is the canonical list of "edition-restricted features
   persisted in this database."

   Guesses first. Then run it.
   ------------------------------------------------------------ */

SELECT feature_id, feature_name
FROM sys.dm_db_persisted_sku_features
ORDER BY feature_id;
GO

/* All six come back:

     100  Compression
     200  Partitioning
     400  ChangeCapture
     500  TransparentDatabaseEncryption
     600  ColumnStoreIndex
     800  InMemoryOLTP

   Read literally, that says this database is welded to Enterprise.

   Now the actual answer to the question from Part 3:  how many of
   those six block a move to SQL Server 2025 Standard?

     ZERO.

   Every one of them is a Standard feature in 2025. Partitioning,
   compression, columnstore, In-Memory OLTP, and change data capture
   all became cross-edition in SQL Server 2016 SP1. TDE joined
   Standard in 2019.

   The DMV has not been updated to reflect any of that. It reports
   what is persisted and historically edition-sensitive -- not what
   blocks YOUR target edition. It is a starting point, not an answer.

   So it misleads in both directions:

     - Six rows look like six blockers. None of them block Standard.
     - And an empty result would not mean you are safe either, because
       capacity, availability groups, online index maintenance, and
       batch mode parallelism are not persisted anywhere it can see.

   The one row here that genuinely restricts something is
   TransparentDatabaseEncryption, and what it restricts is EXPRESS,
   which has no TDE. Same for ChangeCapture.

   Demo 3 shows what the DMV cannot. */


/* The clincher.  Run the exact same query on STANDARD (1433).

   Verified: Standard returns the SAME SIX ROWS. The database is sitting
   happily on Standard, using every one of those features, and the DMV
   still calls all six edition-restricted.

   So the output is not telling you anything about Enterprise dependency.
   It is a list of storage formats that were edition-sensitive at some
   point in history. Nothing more. */

-- And on EXPRESS (1435), the seed could not create TDE, CDC, or the
-- memory-optimized table, so you get a shorter list -- which is the only
-- case where this DMV's output actually tracks edition capability.
GO


/* Contrast case: ContosoStaging was built with none of this. */
USE ContosoStaging;
GO
SELECT DatabaseName = DB_NAME(), FeatureCount = COUNT(*)
FROM sys.dm_db_persisted_sku_features;
GO
-- Zero rows here, six in Contoso. So the DMV does separate them.
--
-- What it does NOT tell you is the thing that matters: both databases
-- restore onto Standard without complaint. The six rows are not six
-- obstacles, and no amount of staring at this DMV will tell you that.


/* ------------------------------------------------------------
   PART 5  --  NOT part of Demo 1.

   Keep this for Section 3's "AI is not an edition feature" slide.
   Demo 1 ends at Part 4 to stay inside its ~4 minutes.

   Run on Express (1435). All of it works.
   ------------------------------------------------------------ */

SELECT TypeName = name, MaxLengthBytes = max_length
FROM sys.types
WHERE name IN ('vector', 'json');
GO

-- Note the column names: this is the DATABASE-scoped view, which has
-- value / value_for_secondary / is_value_default.  There is no
-- value_in_use column -- that one belongs to the server-level
-- sys.configurations.
SELECT
    ConfigName   = name,
    Value        = value,
    ForSecondary = value_for_secondary,
    IsDefault    = is_value_default
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO

-- Verified: it comes back 0, and is_value_default = 1.
--
-- So the 2025 AI features that need this flag -- DiskANN vector indexing,
-- local ONNX models, fuzzy string matching, change event streaming -- are
-- OFF until somebody turns them on, on every edition including Enterprise.
-- Edition was never the gate.  This is.

-- Native vector type, DiskANN indexing, external models, local ONNX,
-- embedding generation, and chunking are available in Enterprise,
-- Standard, AND Express in 2025.
--
-- Edition is not what gates AI. PREVIEW_FEATURES is.
