/* ============================================================
   Seeds the demo databases for "Pick Your Poison."

   Runs at image build time, once per edition. It is edition-aware:
   Express cannot do CDC or TDE, so those steps are skipped there.

   Every feature step is independently wrapped in TRY/CATCH and
   reports its outcome. A single failure degrades the seed rather
   than failing the image build -- and the demo scripts inventory
   what is actually present rather than assuming.

   Two databases are created:
     Contoso         -- deliberately feature-heavy
     ContosoStaging  -- deliberately plain, for contrast
   ============================================================ */

SET NOCOUNT ON;
GO

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));

PRINT '===========================================================';
PRINT 'Seeding for: ' + @Edition;
PRINT 'EngineEdition: ' + CAST(@EngineEdition AS varchar(10))
    + CASE @EngineEdition WHEN 2 THEN ' (Standard)' WHEN 3 THEN ' (Enterprise)' WHEN 4 THEN ' (Express)' ELSE '' END;
PRINT '===========================================================';
GO


/* ------------------------------------------------------------
   Databases
   ------------------------------------------------------------ */

-- A plain DROP fails if a session is connected, so kick them first. This
-- matters when running the seed by hand against an instance you are already
-- querying, not at image build time.
IF DB_ID('Contoso') IS NOT NULL
BEGIN
    ALTER DATABASE Contoso SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE Contoso;
END
IF DB_ID('ContosoStaging') IS NOT NULL
BEGIN
    ALTER DATABASE ContosoStaging SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ContosoStaging;
END
GO

CREATE DATABASE Contoso;
ALTER DATABASE Contoso SET RECOVERY FULL;
GO

CREATE DATABASE ContosoStaging;
GO

-- ContosoStaging stays deliberately boring: one heap, no edition-restricted
-- features. It is the control case in the audit output.
USE ContosoStaging;
GO
CREATE TABLE dbo.ImportQueue
(
    ImportID    int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceFile  nvarchar(260) NOT NULL,
    LoadedAt    datetime2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    RowCountRaw int           NULL
);
INSERT INTO dbo.ImportQueue (SourceFile, RowCountRaw)
SELECT TOP (500) CONCAT(N'sales_', ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), N'.csv'),
                 ABS(CHECKSUM(NEWID())) % 100000
FROM sys.all_objects;
GO
PRINT 'ContosoStaging: created (no edition-restricted features, by design).';
GO


USE Contoso;
GO

/* ------------------------------------------------------------
   1. Memory-optimized filegroup  (In-Memory OLTP)
   ------------------------------------------------------------ */
BEGIN TRY
    -- Express defaults AUTO_CLOSE to ON, which is incompatible with a
    -- MEMORY_OPTIMIZED_DATA filegroup. Turn it off first or the filegroup
    -- fails to attach -- a genuine Express default worth knowing about.
    ALTER DATABASE Contoso SET AUTO_CLOSE OFF;

    ALTER DATABASE Contoso ADD FILEGROUP ContosoMemory CONTAINS MEMORY_OPTIMIZED_DATA;
    ALTER DATABASE Contoso ADD FILE
        (NAME = 'ContosoMemory', FILENAME = '/var/opt/mssql/data/ContosoMemory')
        TO FILEGROUP ContosoMemory;
    PRINT '  [ok]   In-Memory OLTP filegroup';
END TRY
BEGIN CATCH
    PRINT '  [skip] In-Memory OLTP filegroup: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   2. Partitioning
   ------------------------------------------------------------ */
BEGIN TRY
    CREATE PARTITION FUNCTION pfSalesYear (date)
        AS RANGE RIGHT FOR VALUES
        ('2022-01-01', '2023-01-01', '2024-01-01', '2025-01-01', '2026-01-01');

    CREATE PARTITION SCHEME psSalesYear
        AS PARTITION pfSalesYear ALL TO ([PRIMARY]);

    PRINT '  [ok]   Partition function and scheme';
END TRY
BEGIN CATCH
    PRINT '  [skip] Partitioning: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   3. Tables and data
   ------------------------------------------------------------ */

CREATE TABLE dbo.Customer
(
    CustomerID  int           NOT NULL PRIMARY KEY,
    CompanyName nvarchar(100) NOT NULL,
    Region      nvarchar(50)  NOT NULL,
    SignedUpOn  date          NOT NULL
);
GO

INSERT INTO dbo.Customer (CustomerID, CompanyName, Region, SignedUpOn)
SELECT TOP (5000)
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
    CONCAT(N'Customer ', ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
    CASE ABS(CHECKSUM(NEWID())) % 5
        WHEN 0 THEN N'North' WHEN 1 THEN N'South' WHEN 2 THEN N'East'
        WHEN 3 THEN N'West'  ELSE N'Central' END,
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 2000), CAST('2026-01-01' AS date))
FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO

-- The fact table, partitioned if partitioning succeeded above.
DECLARE @partitioned bit = 0;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'psSalesYear')
    SET @partitioned = 1;

DECLARE @sql nvarchar(max) = N'
CREATE TABLE dbo.SalesFact
(
    SaleID     bigint        NOT NULL,
    SaleDate   date          NOT NULL,
    CustomerID int           NOT NULL,
    ProductID  int           NOT NULL,
    Quantity   int           NOT NULL,
    Amount     decimal(19,4) NOT NULL
)';
SET @sql = @sql + CASE WHEN @partitioned = 1 THEN N' ON psSalesYear (SaleDate);' ELSE N';' END;

EXEC sys.sp_executesql @sql;

DECLARE @msg nvarchar(200) = '  [ok]   SalesFact created'
    + CASE WHEN @partitioned = 1 THEN ' (partitioned)' ELSE ' (not partitioned)' END;
PRINT @msg;
GO

-- 250k rows: enough for real columnstore rowgroups (the compressed-rowgroup
-- threshold is 102,400) without making the image build crawl.
INSERT INTO dbo.SalesFact (SaleID, SaleDate, CustomerID, ProductID, Quantity, Amount)
SELECT TOP (250000)
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
    DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 1460, CAST('2022-01-01' AS date)),
    1 + ABS(CHECKSUM(NEWID())) % 5000,
    1 + ABS(CHECKSUM(NEWID())) % 500,
    1 + ABS(CHECKSUM(NEWID())) % 20,
    CONVERT(decimal(19,4), (ABS(CHECKSUM(NEWID())) % 500000) / 100.0)
FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c;
GO

DECLARE @rows bigint;
SELECT @rows = COUNT_BIG(*) FROM dbo.SalesFact;
DECLARE @loadMsg nvarchar(200) = '  [ok]   SalesFact loaded: ' + CAST(@rows AS varchar(20)) + ' rows';
PRINT @loadMsg;
GO


/* ------------------------------------------------------------
   4. Clustered columnstore index
   ------------------------------------------------------------ */
BEGIN TRY
    CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesFact ON dbo.SalesFact;
    PRINT '  [ok]   Clustered columnstore index';
END TRY
BEGIN CATCH
    PRINT '  [skip] Columnstore: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   5. Data compression
   ------------------------------------------------------------ */
BEGIN TRY
    CREATE NONCLUSTERED INDEX IX_Customer_Region
        ON dbo.Customer (Region) INCLUDE (CompanyName)
        WITH (DATA_COMPRESSION = PAGE);
    PRINT '  [ok]   Page compression';
END TRY
BEGIN CATCH
    PRINT '  [skip] Compression: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   6. Memory-optimized table
   ------------------------------------------------------------ */
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.filegroups WHERE type = 'FX')
    BEGIN
        CREATE TABLE dbo.SessionCache
        (
            SessionID   uniqueidentifier NOT NULL
                PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 8192),
            CustomerID  int              NOT NULL,
            LastSeenAt  datetime2(0)     NOT NULL
        ) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);

        INSERT INTO dbo.SessionCache (SessionID, CustomerID, LastSeenAt)
        SELECT TOP (2000) NEWID(), 1 + ABS(CHECKSUM(NEWID())) % 5000, SYSUTCDATETIME()
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

        PRINT '  [ok]   Memory-optimized table';
    END
    ELSE
        PRINT '  [skip] Memory-optimized table: no MEMORY_OPTIMIZED_DATA filegroup';
END TRY
BEGIN CATCH
    PRINT '  [skip] Memory-optimized table: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   7. Change data capture  (Enterprise and Standard only)
   ------------------------------------------------------------ */
BEGIN TRY
    IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 4
        PRINT '  [skip] Change data capture: not available in Express';
    ELSE
    BEGIN
        EXEC sys.sp_cdc_enable_db;

        EXEC sys.sp_cdc_enable_table
            @source_schema = N'dbo',
            @source_name   = N'Customer',
            @role_name     = NULL;

        PRINT '  [ok]   Change data capture on dbo.Customer';
    END
END TRY
BEGIN CATCH
    PRINT '  [skip] Change data capture: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   8. Transparent data encryption  (Enterprise and Standard only)

   This is the interesting one. Per the sys.dm_db_persisted_sku_features
   documentation, TDE is the ONE feature excluded from the 2016 SP1 change
   that made the rest of these available across editions. So this is what
   should still show up in the DMV -- and it blocks a move to Express,
   not a move to Standard.
   ------------------------------------------------------------ */
USE master;
GO

BEGIN TRY
    IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 4
        PRINT '  [skip] TDE: not available in Express';
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
            CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Dem0-M@sterKey-2025!';

        IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'DemoTDECert')
            CREATE CERTIFICATE DemoTDECert
                WITH SUBJECT = 'Pick Your Poison -- TDE demo certificate';

        EXEC sys.sp_executesql N'
            USE Contoso;
            CREATE DATABASE ENCRYPTION KEY
                WITH ALGORITHM = AES_256
                ENCRYPTION BY SERVER CERTIFICATE DemoTDECert;';

        ALTER DATABASE Contoso SET ENCRYPTION ON;

        PRINT '  [ok]   Transparent data encryption enabled on Contoso';
    END
END TRY
BEGIN CATCH
    PRINT '  [skip] TDE: ' + ERROR_MESSAGE();
END CATCH
GO


/* ------------------------------------------------------------
   Report what actually landed
   ------------------------------------------------------------ */
USE Contoso;
GO

PRINT '';
PRINT '--- Features present in Contoso ---';
GO

DECLARE @report TABLE (Feature nvarchar(60), Present bit);

INSERT INTO @report (Feature, Present)
SELECT * FROM (VALUES
    ('Partitioning',        CASE WHEN EXISTS (SELECT 1 FROM sys.partition_schemes) THEN 1 ELSE 0 END),
    ('Data compression',    CASE WHEN EXISTS (SELECT 1 FROM sys.partitions WHERE data_compression > 0 AND object_id > 100) THEN 1 ELSE 0 END),
    ('Columnstore index',   CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE type IN (5,6)) THEN 1 ELSE 0 END),
    ('In-Memory OLTP',      CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE is_memory_optimized = 1) THEN 1 ELSE 0 END),
    ('Change data capture', CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = 'Contoso' AND is_cdc_enabled = 1) THEN 1 ELSE 0 END),
    ('TDE',                 CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = 'Contoso' AND is_encrypted = 1) THEN 1 ELSE 0 END)
) AS v(Feature, Present);

DECLARE @line nvarchar(200);
DECLARE r CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('  ', CASE WHEN Present = 1 THEN '[x] ' ELSE '[ ] ' END, Feature) FROM @report;
OPEN r;
FETCH NEXT FROM r INTO @line;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT @line;
    FETCH NEXT FROM r INTO @line;
END
CLOSE r; DEALLOCATE r;
GO

PRINT '';
PRINT '--- What sys.dm_db_persisted_sku_features reports ---';
GO

DECLARE @n int;
SELECT @n = COUNT(*) FROM sys.dm_db_persisted_sku_features;
DECLARE @nMsg nvarchar(100) = '  Rows returned: ' + CAST(@n AS varchar(10));
PRINT @nMsg;
IF @n = 0
    PRINT '  (none -- which is the entire point of the demo)';
GO

SELECT feature_id, feature_name FROM sys.dm_db_persisted_sku_features;
GO

PRINT '';
PRINT 'Seed complete.';
GO
