SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;
IF OBJECT_ID(N'dbo.BackupDemoRecords', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BackupDemoRecords (
        RecordId int NOT NULL PRIMARY KEY,
        Label nvarchar(100) NOT NULL,
        Amount int NOT NULL,
        SeededAtUtc datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    INSERT INTO dbo.BackupDemoRecords (RecordId, Label, Amount)
    VALUES (1, N'DEMO-RECORD-A', 100),
           (2, N'DEMO-RECORD-B', 200),
           (3, N'DEMO-RECORD-C', 300);
END;

-- Azure SQL requires the application's client ID for SID-based Entra users.
DECLARE @sid varbinary(16) = CONVERT(varbinary(16), CONVERT(uniqueidentifier, @FactoryClientId));
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'acc_SqlValidator' AND (sid <> @sid OR type <> 'E'))
    THROW 51000, 'Existing acc_SqlValidator identity does not match the factory. No permissions changed.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'acc_SqlValidator')
BEGIN
    DECLARE @createUser nvarchar(max) =
        N'CREATE USER [acc_SqlValidator] WITH SID = ' + CONVERT(nvarchar(34), @sid, 1) + N', TYPE = E;';
    EXEC sys.sp_executesql @createUser;
END;
GRANT CONNECT TO [acc_SqlValidator];
GRANT SELECT ON OBJECT::dbo.BackupDemoRecords TO [acc_SqlValidator];
COMMIT TRANSACTION;

SELECT DB_NAME() AS DatabaseName, COUNT(*) AS SeededRows, SUM(Amount) AS AmountTotal,
       MAX(SeededAtUtc) AS SeededAtUtc
FROM dbo.BackupDemoRecords;
