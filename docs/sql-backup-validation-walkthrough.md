# Azure SQL backup restore and validation demo

This optional example uses the **same accelerator ADF and resource group**. It adds a dedicated Azure SQL **logical server** and a small database, not a SQL Server VM or Managed Instance. It leaves the Blob pipelines and storage access settings unchanged.

The restore is real: Azure SQL's automatic point-in-time backups are restored into a new database on the same logical server. This is **not** a database copy, a mock restore, a `.bak` import, or a BACPAC import. Only the optional forced-failure rule and future-notification placeholder are mocked.

## Deploy the optional components

Complete the Blob quick start first so `.local/deployment.json` identifies your factory and resource group. Then, while signed in as an authorized Microsoft Entra user:

```powershell
.\scripts\Deploy-SqlRestoreDemo.ps1
```

The deployer needs permission to create SQL resources, assign the factory a server-scoped SQL DB Contributor role, approve the private endpoint, and set the SQL Entra administrator. It refuses live publication into Git-integrated factories.

The deployment adds:

| Component | Purpose |
|---|---|
| `sql-adfbackup-...` logical server | Dedicated, Entra-only demo server; public network access disabled |
| `acc_BackupSource` database | Basic tier, 5 DTUs, 2 GB maximum, invented records |
| Seven-day automatic-backup retention | Provides the point-in-time restore window |
| Locally redundant backup storage | Low-cost, same-region demo backups; not a geo-recovery example |
| ADF managed virtual network `default` | Private connectivity isolated from the Blob example's default runtime |
| `acc-SqlManagedIR` integration runtime | Runs the SQL Script activity through the managed network |
| `acc_SqlPrivateEndpoint` | Private link to the dedicated SQL server |
| `acc_AzureSql` linked service | Fixed server, parameterized database, factory managed identity |
| `acc_SeedSqlBackupDemo` helper | One-time source-table/user bootstrap |
| `acc_ValidateSqlBackup` pipeline | Restore, script validation, If Condition, pass/fail demonstration, cleanup |

The managed network is provisioned first because the SQL/private-endpoint what-if requires its parent to exist. Both deployment stages use Bicep, what-if, and Incremental mode. The factory itself and Blob resources are not redeployed.

For bootstrap only, the script temporarily makes the factory identity the dedicated SQL server's Entra administrator. The helper creates the invented table and a contained `acc_SqlValidator` user with **CONNECT and SELECT on that table only**. A `finally` block restores the signed-in operator as server administrator. The contained user survives point-in-time restore, so the normal validation run does not need SQL administrator privileges. No directory-wide role or SQL password is created. Do not run this bootstrap against a production server or replace another application's administrator.

The source seed is idempotent: it does not truncate or overwrite an existing sample table. A successful seed timestamp is saved locally. The initial automatic backup and log-backup window take time to become usable; the deployer polls with a 90-minute limit and prints status. It selects a point after seeding, performs a real passing restore/validation, and publishes that verified timestamp as the demonstration default. If the wait or initial validation fails, inspect the saved results and source backup/status rather than weakening networking.

Environment-specific addresses and operator IDs are saved in Git-ignored `.local/sql-restore-deployment.json`. Do not publish that file.

### Cost and cleanup

The source Basic database and private endpoint remain provisioned, even between demos. Basic is approximately US$5/month at retail and a private endpoint commonly adds roughly US$0.01/hour plus data processing; actual region, agreement, and FDPO charges can differ. ADF activities and temporary restored databases incur additional usage. There is no always-running custom VM or mapping-data-flow cluster.

The pipeline deletes its uniquely named temporary database after either validation result. The source server/database are **not** automatically deleted. Review and remove these dedicated SQL resources when finished; deleting the source destroys the sample and its future restore capability. See [SQL pricing](https://azure.microsoft.com/pricing/details/azure-sql-database/single/) and [Private Link pricing](https://azure.microsoft.com/pricing/details/private-link/).

## Run in ADF Studio

Refresh **Author > Pipelines > Accelerator**, open **acc_ValidateSqlBackup**, and select **Add trigger > Trigger now**.

| Parameter | Pass demo | Fail demo |
|---|---|---|
| `pForceFailure` | `false` | `true` |
| `pExpectedRowCount` | `3` | `3` |
| `pExpectedAmountTotal` | `600` | `600` |
| `pRestorePointInTime` | Keep deployed snapshot default | Keep the same default |
| `pSqlServerResourceId` | Keep the deployed default | Keep the deployed default |
| `pSqlLocation` | Keep the deployed default | Keep the deployed default |
| `pSourceDatabase` | `acc_BackupSource` | `acc_BackupSource` |

The deployed default is a **verified backup timestamp**, so pass and fail runs examine the same snapshot rather than different moving restore points. It expires when it falls outside the seven-day retention window; rerun the deployer to validate and publish a new snapshot. To examine another backup time, supply an ISO-8601 UTC timestamp within the available retention window and after seeding. Clearing the parameter explicitly selects UTC now minus 10 minutes, but recent log-backup availability can lag, especially on an idle demo database; use an older verified point if that request remains pending. Restoring before seeding can omit the table or validation identity.

From PowerShell:

```powershell
.\scripts\Run-SqlRestoreDemo.ps1
.\scripts\Run-SqlRestoreDemo.ps1 -ForceFailure
```

The second command intentionally reports a failed pipeline and exits with an error. It is not a deployment failure if the restore, validation activity, fail branch, and cleanup behaved as expected.

To demonstrate a **real rule failure** without the mock flag:

```powershell
.\scripts\Run-SqlRestoreDemo.ps1 -ExpectedRowCount 99
```

There are three actual rows, so that expectation fails. These examples do not corrupt the source, backup, or restored data.

## Follow the activities

```text
NameTemporaryDatabase -> ReadSourceDatabase -> CheckBackupAvailable
  -> SelectRestorePoint -> CheckRestoreWindow
  -> RestoreTemporaryDatabase (real PointInTimeRestore request)
  -> WaitForRestore (bounded polling of Azure-AsyncOperation)
  -> CheckRestoreSucceeded
  -> ValidateRestore (editable SQL Script activity)
  -> CaptureValidationSummary -> IfValidationPassed
       True:  MockValidationPass
       False: MockValidationFail_NoEmail
  -> DeleteTemporaryDatabase
  -> ReportDemoResult
       True:  DemoPassed
       False: DemoFailed (BACKUP_VALIDATION_FAILED)
```

The temporary name is `acc_restore_<pipeline run ID without hyphens>`. The pipeline never accepts an arbitrary cleanup database name, never overwrites the source, and creates a separate database per run.

In **Monitor > Pipeline runs > activity runs**:

1. Inspect `RestoreTemporaryDatabase` **Input**. Its body must specify `createMode: PointInTimeRestore`, the source database ID, and the restore timestamp.
2. Inspect `WaitForRestore` / `ReadRestoreStatus` to see the SQL operation move from `InProgress` to `Succeeded`. `CheckRestoreSucceeded` rejects failure/cancellation or polling errors. A database can temporarily be absent while Azure processes an accepted restore request; polling the operation avoids treating that expected delay as repeated database-not-found errors.
3. Open `ValidateRestore` **Output**. The first result set is one summary row: `ValidationPassed` (`1` or `0`), `RestoredDatabase`, actual row count/amount total, failed-rule count, and summary text. The second result set lists individual rule outcomes.
4. Follow `IfValidationPassed` to the appropriate mocked branch.
5. Confirm `DeleteTemporaryDatabase` succeeds on **both** branches.
6. The pass run is green. A fail run ends red with `BACKUP_VALIDATION_FAILED` **after** cleanup.

The exact condition is:

```text
@equals(activity('ValidateRestore').output.resultSets[0].rows[0].ValidationPassed,1)
```

An unexpected SQL error is **not** converted into a passing or false-shaped result. `ValidateRestore` fails, its downstream decision is skipped, cleanup still has Completed/Skipped dependencies, and the run explicitly reports an error. Restore errors are also visible. If cleanup itself fails, that activity remains failed.

Manual cancellation, permissions loss, or a restore/delete operation conflict can prevent cleanup. Inspect the original errors and list databases on this **specific demo server**; delete only the exact `acc_restore_...` database belonging to the affected run after verifying its name. Do not delete the source or use wildcard deletion.

## Edit the validation rules

The canonical script is [validate-restored-backup.sql](../sql/validate-restored-backup.sql). It checks:

- The required table exists.
- Row count matches the expected value.
- Amount total matches the expected value.
- Amounts are nonnegative and labels are not blank.
- When requested, an explicitly labeled `ForcedDemoFailure` rule fails.

Add more rules by inserting rows into `@checks` at the marked extension point. Keep the **first result set as exactly one summary row with integer `ValidationPassed` = 1 or 0**, and keep rule details in the second result set. Do not add diagnostic SELECTs before that summary. Use SQL parameters rather than concatenating untrusted inputs.

If new rules need different tables or metadata, grant the contained validator only those additional read permissions, before taking a restorable backup. The present identity is not `db_owner`.

After editing the script, publish the updated SQL text into the pipeline:

```powershell
.\scripts\Deploy-SqlRestoreDemo.ps1 -PublishOnly
```

This updates the dedicated linked service and two SQL pipelines only. It does not redeploy infrastructure, reseed data, change the SQL administrator, or wait for another backup.

The publisher embeds the SQL file into the ADF Script activity and binds deployment defaults. The checked-in JSON contains explicit template markers; use the generated definitions under `.local/sql-restore-assets` for manual imports. Git-integrated factories must import those generated definitions into their collaboration branch and publish through their normal process rather than using this live-mode deployer.

## Email later, not now

`MockValidationFail_NoEmail` is the placeholder for a future failure notification. There is **no** Logic App, email connector, recipient, credential, or outbound email in this demo. When adding notification, cover both content-rule failures and operational failures, and preserve cleanup before final failure reporting. Design retry/deduplication so reruns do not send duplicate alerts.

## Validate the demonstration

```powershell
.\tests\Test-Local.ps1
.\tests\Test-SqlRestoreDemo.ps1
```

Local validation checks source syntax, parameter bindings, cleanup dependencies, exact script embedding, and optional Bicep builds without SQL access. Cloud validation performs **four real restores**: pass, forced mock failure, a genuine row-count-rule failure, and an operational SQL error. The error case uses a temporary test-only pipeline, removed afterward, without changing the real demo pipeline. Tests verify the content came from the run's temporary database, the correct branch executed, errors surfaced, temporary databases were actually deleted even after script failure, and the source remains online. Evidence is saved locally in `.local/sql-restore-test-results.json`.

Passing these sample rules proves a selected backup can be restored and satisfies these rules. It does **not** prove every backup is healthy, full application consistency, complete business correctness, or a recovery-time SLA. This Basic 2-GB synthetic demo is not sized for production databases.

## References

- [Azure SQL automatic backups](https://learn.microsoft.com/azure/azure-sql/database/automated-backups-overview)
- [Restore using backups](https://learn.microsoft.com/azure/azure-sql/database/recovery-using-backups)
- [Database restore REST API](https://learn.microsoft.com/rest/api/sql/databases/create-or-update?view=rest-sql-2025-01-01)
- [ADF Script activity and output contract](https://learn.microsoft.com/azure/data-factory/transform-data-using-script)
- [ADF managed virtual networks and private endpoints](https://learn.microsoft.com/azure/data-factory/managed-virtual-network-private-endpoint)
- [SQL contained Entra users without directory validation](https://learn.microsoft.com/sql/t-sql/statements/create-user-transact-sql#k-create-a-contained-database-user-from-a-microsoft-entra-principal-without-validation)
