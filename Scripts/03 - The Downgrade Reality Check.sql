/* ============================================================
   DEMO 3:  The empty result set lies.

   The setup:  an Enterprise database stuffed with partitioning,
   compression, and columnstore.  The pre-flight DMV reports three
   edition-restricted features.  It looks welded to Enterprise.

   Twist one:  the restore to Standard SUCCEEDS anyway.  None of those
   three actually block Standard in 2025.

   Twist two:  the damage is real, and it is everywhere the DMV never
   looked -- maintenance windows and query parallelism.

   Run the ENTERPRISE sections against localhost,1434
   Run the STANDARD sections against localhost,1433
   ============================================================ */


/* ------------------------------------------------------------
   PART 1  --  ON ENTERPRISE  (localhost,1434)
   ------------------------------------------------------------ */

USE master;
GO

-- Re-runnable: a plain DROP fails with Msg 3702 if any session is still
-- connected, which is precisely what happens between a rehearsal and the
-- live run.  Kick connections first.
IF DB_ID('DowngradeDemo') IS NOT NULL
BEGIN
    ALTER DATABASE DowngradeDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DowngradeDemo;
END
GO
CREATE DATABASE DowngradeDemo;
GO

USE DowngradeDemo;
GO

-- Build something that looks expensive:  a partitioned, compressed,
-- columnstore-indexed table.  All three of these used to be Enterprise-only.
CREATE PARTITION FUNCTION pfDemo (INT)
    AS RANGE RIGHT FOR VALUES (250000, 500000, 750000);
GO
CREATE PARTITION SCHEME psDemo
    AS PARTITION pfDemo ALL TO ([PRIMARY]);
GO

CREATE TABLE dbo.Sales
(
    SaleID      INT           NOT NULL,
    SaleDate    DATE          NOT NULL,
    CustomerID  INT           NOT NULL,
    Amount      DECIMAL(19,4) NOT NULL,
    Notes       NVARCHAR(200) NULL
) ON psDemo (SaleID);
GO

-- Load enough rows that parallelism matters.
INSERT INTO dbo.Sales (SaleID, SaleDate, CustomerID, Amount, Notes)
SELECT TOP (1000000)
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
    DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 3650, '2016-01-01'),
    ABS(CHECKSUM(NEWID())) % 50000,
    (ABS(CHECKSUM(NEWID())) % 1000000) / 100.0,
    REPLICATE(N'x', 100)
FROM sys.all_columns AS a
    CROSS JOIN sys.all_columns AS b;
GO

CREATE CLUSTERED COLUMNSTORE INDEX CCI_Sales ON dbo.Sales;
GO
CREATE NONCLUSTERED INDEX IX_Sales_CustomerID
    ON dbo.Sales (CustomerID) WITH (DATA_COMPRESSION = PAGE);
GO


/* The pre-flight check everyone runs.  Ask it the question. */
SELECT feature_id, feature_name
FROM sys.dm_db_persisted_sku_features
ORDER BY feature_id;
GO

-- Three rows:
--
--     100  Compression
--     200  Partitioning
--     600  ColumnStoreIndex
--
-- Read literally, that is three blockers and a dead end.  This is where
-- most downgrade conversations stop -- "the DMV says we cannot."
--
-- Except all three have been Standard features since SQL Server 2016
-- SP1.  The DMV reports what is persisted and historically
-- edition-sensitive; it has never been updated to say which editions
-- still restrict it.
--
-- So let us just try the restore and see who is right.


/* A plain rowstore table as well.

   RESUMABLE is not supported on a table carrying a columnstore index --
   Msg 35397, and nothing to do with edition -- so the resumable beat
   needs its own table. */
CREATE TABLE dbo.SalesAudit
(
    AuditID   bigint       IDENTITY(1,1) NOT NULL,
    SaleID    bigint       NOT NULL,
    ChangedAt datetime2(0) NOT NULL CONSTRAINT DF_SalesAudit DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_SalesAudit PRIMARY KEY CLUSTERED (AuditID)
);
GO
INSERT INTO dbo.SalesAudit (SaleID)
SELECT TOP (200000) SaleID FROM dbo.Sales;
GO
CREATE NONCLUSTERED INDEX IX_SalesAudit_SaleID ON dbo.SalesAudit (SaleID);
GO


/* Establish the baseline while we still have Enterprise.

   No success messages here on purpose.  A PRINT after GO runs in its own
   batch and fires even when the statement above it failed, which would
   put "succeeded" on screen directly under a red error.  Silence means
   it worked. */

-- (a) Online index maintenance.
ALTER INDEX IX_Sales_CustomerID ON dbo.Sales
    REBUILD WITH (ONLINE = ON);
GO

-- (b) Resumable online maintenance, on the rowstore table.
ALTER INDEX IX_SalesAudit_SaleID ON dbo.SalesAudit
    REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 1);
GO

/* (c) Batch mode parallelism.

   The hint is deliberate and it matters.  At one million rows this
   aggregate costs well under the default cost threshold of 5, so the
   optimizer picks a SERIAL plan on BOTH editions and you measure DOP 1
   twice -- which demonstrates nothing.  Lowering the cost threshold does
   not help; the query is simply too cheap.

   ENABLE_PARALLEL_PLAN_PREFERENCE is an undocumented (but widely used)
   USE HINT that forces a parallel plan, which is what lets the ceiling
   become visible.  It is not in Microsoft's query hint documentation and
   does not appear in sys.dm_exec_valid_use_hints, so treat it as a demo
   and testing tool, not something to ship in production code.  In a real
   warehouse with hundreds of millions of rows you hit this cap without
   asking for it.  Here we have to ask. */

SELECT
    YEAR(SaleDate)  AS SaleYear,
    COUNT_BIG(*)    AS Transactions,
    SUM(Amount)     AS TotalAmount
FROM dbo.Sales
GROUP BY YEAR(SaleDate)
ORDER BY SaleYear
OPTION (USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'));
GO

-- Read the ACTUAL degree of parallelism. Do not try to eyeball this from the
-- plan shape -- read the number.
SELECT
    Edition   = CONVERT(varchar(40), SERVERPROPERTY('Edition')),
    LastDOP   = qs.last_dop,
    ElapsedMS = qs.last_elapsed_time / 1000,
    Executions= qs.execution_count
FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE t.text LIKE '%YEAR(SaleDate)%'
  AND t.text NOT LIKE '%dm_exec_query_stats%'
ORDER BY qs.last_execution_time DESC;
GO

-- VERIFIED on Enterprise Developer, 16 logical processors:  LastDOP = 16.


/* Back it up to the shared volume. */
BACKUP DATABASE DowngradeDemo
    TO DISK = '/var/opt/mssql/backup/DowngradeDemo.bak'
    WITH INIT, COMPRESSION, STATS = 10;
GO



/* ------------------------------------------------------------
   PART 2  --  ON STANDARD  (localhost,1433)
   ------------------------------------------------------------ */

USE master;
GO

-- Re-runnable: a plain DROP fails with Msg 3702 if any session is still
-- connected, which is precisely what happens between a rehearsal and the
-- live run.  Kick connections first.
IF DB_ID('DowngradeDemo') IS NOT NULL
BEGIN
    ALTER DATABASE DowngradeDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DowngradeDemo;
END
GO

/* The moment of truth. */
RESTORE DATABASE DowngradeDemo
    FROM DISK = '/var/opt/mssql/backup/DowngradeDemo.bak'
    WITH MOVE 'DowngradeDemo'     TO '/var/opt/mssql/data/DowngradeDemo.mdf',
         MOVE 'DowngradeDemo_log' TO '/var/opt/mssql/data/DowngradeDemo_log.ldf',
         RECOVERY, STATS = 10;
GO

-- It worked.
--
-- No error, no warning, no complaint.  The database is online on Standard
-- and every row is present.  If your downgrade checklist stopped at
-- "does it restore," you would call this a success and go home.

USE DowngradeDemo;
GO

SELECT COUNT_BIG(*) AS RowsPresent FROM dbo.Sales;
SELECT COUNT(*)     AS PartitionsPresent
FROM sys.partitions
WHERE object_id = OBJECT_ID('dbo.Sales') AND index_id = 1;
GO


/* Now find out what we actually lost. */

-- (a) Online index maintenance:  gone.
--     Expect an edition-restriction error here.  This is the point of
--     the demo -- let it fail on screen.
ALTER INDEX IX_Sales_CustomerID ON dbo.Sales
    REBUILD WITH (ONLINE = ON);
GO

-- (b) Resumable maintenance:  also gone, for the same reason.
ALTER INDEX IX_SalesAudit_SaleID ON dbo.SalesAudit
    REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 1);
GO

-- (c) The offline rebuild does work -- but it takes a blocking lock
--     for its whole duration.  Your maintenance window just changed shape.
ALTER INDEX IX_Sales_CustomerID ON dbo.Sales
    REBUILD WITH (ONLINE = OFF);
GO
-- That one succeeds.  Only the OFFLINE rebuild is available here, and it
-- holds a blocking lock for its whole duration.

-- (d) Batch mode DOP is capped at 2.  Identical query, identical data,
--     identical hardware, same hint.
SELECT
    YEAR(SaleDate)  AS SaleYear,
    COUNT_BIG(*)    AS Transactions,
    SUM(Amount)     AS TotalAmount
FROM dbo.Sales
GROUP BY YEAR(SaleDate)
ORDER BY SaleYear
OPTION (USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'));
GO

-- Read the ACTUAL degree of parallelism. Do not try to eyeball this from the
-- plan shape -- read the number.
SELECT
    Edition   = CONVERT(varchar(40), SERVERPROPERTY('Edition')),
    LastDOP   = qs.last_dop,
    ElapsedMS = qs.last_elapsed_time / 1000,
    Executions= qs.execution_count
FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE t.text LIKE '%YEAR(SaleDate)%'
  AND t.text NOT LIKE '%dm_exec_query_stats%'
ORDER BY qs.last_execution_time DESC;
GO

-- VERIFIED on Standard Developer, same 16 logical processors:  LastDOP = 2.
--
-- Sixteen down to two. Not a config difference, not a hardware difference --
-- the edition's batch mode ceiling, which appears as a footnote under a
-- feature table and is worth more than most of the checkboxes above it.

-- (e) And the DMV still says everything is fine.
SELECT feature_id, feature_name
FROM sys.dm_db_persisted_sku_features;
GO


/* ------------------------------------------------------------
   THE POINT

   sys.dm_db_persisted_sku_features misleads in both directions.

   It reported three blockers that did not block anything.  Every one
   of them is a Standard feature in 2025, and the restore succeeded
   without a warning.

   And had it returned zero rows, that would not have meant safety
   either, because it cannot answer any of the questions that matter:
     - Will my maintenance window still fit?
     - Will my queries still run at the same parallelism?
     - Do I still have an availability group?
     - Do I still fit inside 32 cores and 256 GB?

   Those are the questions that decide whether a downgrade is survivable.
   None of them are persisted in the data files, so none of them can show
   up in this DMV at all.

   Treat it as one input to a checklist, never as the verdict.  The real
   pre-flight is in Handouts/edition-change-runbooks.md.

   Microsoft has an entire troubleshooting guide for the aftermath:
   "Troubleshoot performance problems after changing the SQL Server edition"
   -- which exists precisely because the restore is the easy part.
   ------------------------------------------------------------ */


/* Cleanup (run on both instances) */
USE master;
GO
-- Re-runnable: a plain DROP fails with Msg 3702 if any session is still
-- connected, which is precisely what happens between a rehearsal and the
-- live run.  Kick connections first.
IF DB_ID('DowngradeDemo') IS NOT NULL
BEGIN
    ALTER DATABASE DowngradeDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DowngradeDemo;
END
GO
