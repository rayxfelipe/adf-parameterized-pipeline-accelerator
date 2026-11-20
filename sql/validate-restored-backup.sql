SET NOCOUNT ON;

DECLARE @checks TABLE (
    RuleName nvarchar(100) NOT NULL,
    Passed bit NOT NULL,
    Details nvarchar(1000) NOT NULL
);
DECLARE @hasTable bit = CASE WHEN OBJECT_ID(N'dbo.BackupDemoRecords', N'U') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @rows int = 0, @total bigint = 0, @invalid int = 0;

INSERT INTO @checks VALUES
    (N'RequiredTable', @hasTable, N'dbo.BackupDemoRecords must exist in the restored database.');

IF @hasTable = 1
BEGIN
    EXEC sys.sp_executesql
        N'SELECT @Rows = COUNT(*), @Total = COALESCE(SUM(CONVERT(bigint, Amount)), 0),
                 @Invalid = COALESCE(SUM(CASE WHEN Amount < 0 OR LEN(LTRIM(RTRIM(Label))) = 0 THEN 1 ELSE 0 END), 0)
          FROM dbo.BackupDemoRecords;',
        N'@Rows int OUTPUT, @Total bigint OUTPUT, @Invalid int OUTPUT',
        @Rows = @rows OUTPUT, @Total = @total OUTPUT, @Invalid = @invalid OUTPUT;
END;

INSERT INTO @checks VALUES
    (N'ExpectedRowCount', CASE WHEN @hasTable = 1 AND @rows = @ExpectedRowCount THEN 1 ELSE 0 END,
     CONCAT(N'Expected ', @ExpectedRowCount, N'; actual ', @rows, N'.')),
    (N'ExpectedAmountTotal', CASE WHEN @hasTable = 1 AND @total = @ExpectedAmountTotal THEN 1 ELSE 0 END,
     CONCAT(N'Expected ', @ExpectedAmountTotal, N'; actual ', @total, N'.')),
    (N'ValidRecordValues', CASE WHEN @hasTable = 1 AND @invalid = 0 THEN 1 ELSE 0 END,
     CONCAT(N'Negative amounts or blank labels: ', @invalid, N'.'));

-- Add business rules here as more rows in @checks. Keep the two result sets below.
IF @ForceFailure = 1
    INSERT INTO @checks VALUES
        (N'ForcedDemoFailure', 0, N'Intentional demo failure; this does not imply the backup is corrupt.');

DECLARE @failed int = (SELECT COUNT(*) FROM @checks WHERE Passed = 0);
SELECT CASE WHEN @failed = 0 THEN 1 ELSE 0 END AS ValidationPassed,
       DB_NAME() AS RestoredDatabase,
       @rows AS ActualRowCount,
       @total AS ActualAmountTotal,
       @failed AS FailedRuleCount,
       CASE WHEN @failed = 0 THEN N'PASS: restored sample content matches all validation rules.'
            ELSE CONCAT(N'FAIL: ', @failed, N' validation rule(s) failed. Inspect the rule result set.') END AS Summary;

SELECT RuleName, Passed, Details FROM @checks ORDER BY RuleName;
