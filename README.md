# ADF Parameterized Pipeline Accelerator

**Deploy a working sample, change a parameter, and see the same pipeline produce a different output.**

This learning accelerator demonstrates parameterized **Azure Data Factory (ADF)** pipelines using small, invented utility inspection and mitigation CSVs. It is not a customer system, regulatory data model, or production-ready compliance solution.

**Start here:** [Quick start](#quick-start) -> [Post-deployment walkthrough](docs/post-deployment-walkthrough.md) -> [Optional metadata-driven batch](#next-step-metadata-driven-batch).

## What you will learn

- **Pipeline parameters** supply the source and destination for a particular run.
- **Dataset parameters** let one CSV dataset describe different files.
- **Expressions** pass those values between pipelines, activities, and datasets.
- **Metadata-driven orchestration** adds multiple jobs without duplicating pipelines.
- **Managed identity** provides access without storing keys or SAS tokens.

The inspection sample has **3 data rows / 7 columns**; the mitigation sample has **2 data rows / 6 columns**. You do not need a SQL database, Spark cluster, or real customer data.

## Quick start

Use a **new, dedicated demo resource group** first. Integrating an existing ADF is an advanced path below.

### 1. Check prerequisites

The documented command examples use **PowerShell 7.2+**, not Windows PowerShell 5.1. The automated validation runs on Windows.

- [Git](https://git-scm.com/downloads), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), and [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
- Bicep available through Azure CLI: run `az bicep version`. If missing, run `az bicep install`.
- An Azure subscription and permission to create resources **and assign Azure roles** in the target resource group. Contributor alone cannot assign roles; use an approved combination such as Contributor plus Role Based Access Control Administrator. Creating the resource group also requires subscription-level permission.
- Network access to Azure management endpoints and the Microsoft public Bicep registry.

**Enterprise subscription?** Arrange the required permissions and an approved region with your administrator before starting. This is the most common setup blocker.

### 2. Clone and choose your subscription

```powershell
git clone https://github.com/rayxfelipe/adf-parameterized-pipeline-accelerator.git
Set-Location adf-parameterized-pipeline-accelerator
az login
az account list --output table

$subscriptionId = '<paste-your-subscription-id>'
$resourceGroup = 'rg-adf-parameterized-demo'
```

Do not paste credentials into source files. The scripts explicitly target `$subscriptionId`; they do not change your global Azure CLI subscription.

The `Microsoft.DataFactory` and `Microsoft.Storage` providers must be registered. Check once:

```powershell
az provider show --namespace Microsoft.DataFactory --subscription $subscriptionId --query registrationState --output tsv
az provider show --namespace Microsoft.Storage --subscription $subscriptionId --query registrationState --output tsv
```

If either is not `Registered`, ask an authorized subscription administrator to register it, or run the corresponding command if you have permission:

```powershell
az provider register --namespace Microsoft.DataFactory --subscription $subscriptionId --wait
az provider register --namespace Microsoft.Storage --subscription $subscriptionId --wait
```

### 3. Deploy and load the synthetic data

```powershell
.\scripts\Deploy.ps1 `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroup `
  -Location 'westus2'
```

This creates the demo resources, shows an ARM **what-if**, deploys in **Incremental** mode, grants ADF access to the demo containers, and runs the synthetic-data seeder. Allow several minutes for deployment and initial RBAC propagation.

Deployment prints an **ADF Studio URL**. Its non-secret deployment settings are saved in the Git-ignored `.local/deployment.json`.

### 4. Run one copy and see its rows

```powershell
.\scripts\Run-Demo.ps1 -PreviewOutput
```

The default is **`acc_CopyCsv`**, using [copy.parameters.json](examples/copy.parameters.json). Expect:

```text
SUCCESS: acc_CopyCsv
Output: curated/single-copy/2026-01-15/demo-utility-a/renamed-inspections.csv
...
Readable output: 3 data rows (header not counted).
```

The console also shows the three invented inspection records and a run ID. `-PreviewOutput` runs a small ADF Lookup to read the output; it does not open storage to your workstation.

**Why not browse the blobs directly?** Storage public network access is intentionally disabled. Use the preview/Monitor experience or your own approved private connectivity.

### 5. Change only parameters, then run again

```powershell
$copy = Get-Content -Raw .\examples\copy.parameters.json | ConvertFrom-Json
$copy.pSinkFolder = 'my-second-run/2026-01-15/demo-utility-a'
$copy.pSinkFile = 'another-name.csv'
$copy | ConvertTo-Json | Set-Content .\.local\my-copy.parameters.json

.\scripts\Run-Demo.ps1 `
  -ParametersFile .\.local\my-copy.parameters.json `
  -PreviewOutput
```

Expect the **same three records** at `curated/my-second-run/2026-01-15/demo-utility-a/another-name.csv`. You did not edit or republish a pipeline or dataset.

**That is the core lesson: one reusable pipeline definition, different runtime values.**

### 6. Understand what was deployed

Continue with the **[post-deployment walkthrough](docs/post-deployment-walkthrough.md)**. It explains each resource, follows one parameter from a run to the physical blob, shows what to inspect in ADF Studio, and provides exercises and discussion checkpoints.

## Next step: metadata-driven batch

Once the single-copy example makes sense:

```powershell
.\scripts\Run-Demo.ps1 -PipelineName acc_ProcessBatch -PreviewOutput
```

[batch.parameters.json](examples/batch.parameters.json) supplies two job objects. The parent pipeline calls the **same** `acc_CopyCsv` pipeline for each job, using up to two concurrent jobs.

```text
curated/
  processed/2026-01-15/demo-utility-a/inspections/inspections.csv  (3 rows)
  processed/2026-01-15/demo-utility-b/mitigations/mitigations.csv  (2 rows)
```

The second CSV has a different schema. Neither needs a separate dataset or copy pipeline.

`pRunDate` controls the **destination partition only**. Source dates are supplied explicitly in each job's `sourceFolder`; changing the run date does not create new source files.

## What is deployed

| Component | Purpose |
|---|---|
| One ADF with system-assigned managed identity | Runs the pipelines without stored credentials |
| One Standard LRS Blob storage account | Holds invented source and output CSVs |
| `landing` and `curated` containers | Separate input from output |
| `acc_BlobStorage` linked service | Defines the account connection and managed-identity authentication |
| `acc_Csv` dataset | Reuses the same CSV definition with container/folder/file/delimiter parameters |
| `acc_CopyCsv` pipeline | Checks and copies one runtime-selected CSV |
| `acc_ProcessBatch` pipeline | Calls the reusable copy pipeline for a metadata list |
| `acc_SeedSamples` helper | Uploads only the tiny synthetic CSVs |
| `acc_PreviewCsv` helper | Makes small output datasets readable through ADF Lookup |
| Container-scoped RBAC grants | Authorizes the factory identity on the demo containers |

No scheduled triggers, custom compute cluster, or database is deployed. The default region is West US 2; choose an approved supported region.

## VS Code

Open [ADF-Parameterized-Pipeline.code-workspace](ADF-Parameterized-Pipeline.code-workspace), accept the recommended Bicep and PowerShell extensions, and use **Terminal > Run Task > Accelerator: ...**.

The tasks include deployment, **single copy and show rows**, and an explicitly optional batch. The CLI works without VS Code too.

## Advanced: existing ADF

For an existing **live-mode** factory in the target resource group:

```powershell
.\scripts\Deploy.ps1 `
  -SubscriptionId '<your-subscription-id>' `
  -ResourceGroupName '<existing-factory-resource-group>' `
  -ExistingFactoryName '<existing-factory-name>'
```

Enable the existing factory's system-assigned identity first. The factory itself is referenced, not redeployed; the script adds new demo storage and `acc_` assets. **Back up any pre-existing assets with the same names**: Incremental mode updates matching names. This path does not support a factory in another resource group or reuse an existing storage account.

For a **Git-integrated** ADF, the script deliberately refuses live deployment. Import [adf/](adf/) into its configured collaboration branch, update `acc_BlobStorage`'s service endpoint, grant the factory identity Blob Data Reader on the source container and Blob Data Contributor on the sink, then publish through your normal ADF process. The optional seeder also needs contributor access to `landing`.

The repository is source distribution, not an automatically configured ADF authoring repository. Use **Use this template** if you want your own source repository.

## Advanced: preview or automation

Preview requires an existing resource group:

```powershell
.\scripts\Deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -Preview
```

To obtain the pipeline result as JSON rather than the human-readable summary, use `.\scripts\Run-Demo.ps1 -Detailed`. `-Detailed` and `-PreviewOutput` are mutually exclusive. Explicitly pass `-PipelineName acc_ProcessBatch` for the batch; the default run is now the single-copy learning example.

Custom parameter files must include the complete keys from the applicable example, even where ADF itself has defaults.

## Optional validation for maintainers

You do **not** need the full test suite to complete the quick start.

```powershell
.\tests\Test-Local.ps1
.\tests\Test-Deployed.ps1
```

- Local validation checks source syntax, parameter bindings, sample paths, distinct CSV schemas, and Bicep compilation. GitHub Actions runs it without Azure credentials.
- Deployed validation checks every output field, file/byte metrics, renamed output, overwrite on rerun, missing-source failure, child-failure propagation, and empty-batch failure.
- **Expected failures:** cloud tests intentionally create failed runs for negative cases. A failed test scenario is not a broken installation when the test script reports PASS.
- Cloud tests incur Azure charges and save their evidence locally in `.local/test-results.json`.

## Security, cost, and limitations

- All sample records and utility identifiers are invented. Never use the seeder for real sensitive data: its content is supplied as pipeline parameters.
- Shared-key and anonymous blob access are disabled. Storage uses HTTPS/TLS 1.2 minimum, encryption, versioning, and seven-day soft delete.
- Storage public network access is **disabled**, its firewall defaults to deny, and there is no operator IP allowlist. The explicit `AzureServices` exception permits trusted ADF requests **only with authorized managed identity**. This exception is not private-endpoint-only isolation.
- ADF has container-scoped contributor access to `landing` for synthetic seeding and to `curated` for output. No storage-data role is granted to the operator.
- On a **fresh** deployment, `-SkipSeed` omits the seeder and gives ADF reader access to `landing`. Incremental mode does not remove previously created assets/grants; changing an existing demo requires explicitly reviewing/removing its old seeder and landing contributor grant.
- ADF's management/Studio access remains authenticated; the factory is not deployed with private endpoints. For sensitive workloads, use an approved managed-VNet/private-endpoint design and revisit the trusted-service exception.
- Preview is for small demo files: Lookup has a 5,000-row/4-MB output limit, and values are visible to authorized users in Monitor. Large production files need a different verification method.
- CSV headers/values are reused without a fixed dataset schema. Quoting, encoding, or line endings may be normalized. This is not a regulatory schema validator, deduplication engine, or guaranteed byte-for-byte binary copy.
- Different parallel jobs must have unique output paths. Reruns overwrite the current blob; older versions still consume storage.
- ADF orchestration/copy execution and storage capacity/transactions/versions incur charges. Copy uses four DIUs and at most two concurrent jobs. There is no fixed always-on compute charge, but deployed storage is not free.
- See current [ADF pricing](https://azure.microsoft.com/pricing/details/data-factory/data-pipeline/) and [Blob pricing](https://azure.microsoft.com/pricing/details/storage/blobs/). Standard LRS is a demo cost choice, not a disaster-recovery strategy.

## Troubleshooting

| Symptom | Action |
|---|---|
| Role-assignment authorization error | Contributor alone is insufficient; have your administrator approve the required RBAC permissions. |
| Provider not registered | Follow the registration commands in the prerequisites with subscription-level permission. |
| ADF storage 403 | Check the factory identity's container grants, trusted-service exception, and RBAC propagation. Do not enable public access as a workaround. |
| Linked-service **Test connection** returns 403 but pipeline runs succeed | The account-level test can exceed this sample's container-scoped permissions. If available, select **To file path** and enter an existing sample path, or verify using `acc_PreviewCsv`. See the [walkthrough](docs/post-deployment-walkthrough.md#studio-connection-tests-and-container-scoped-access). Do not broaden permissions just to pass an account-level test. |
| Copy sink returns 400 / `AzureBlobWriteOperationFailed` | Inspect the actual run parameters for tabs, newlines, or other control characters in folder/file values. Replace the entire affected value and start a new **Trigger now** run. A tab before `renamed-inspections.csv` makes the blob name invalid; rerunning the failed execution unchanged reuses the bad value. |
| Workstation storage browser/CLI is blocked | Expected. Use `-PreviewOutput` or ADF Monitor for synthetic data. |
| `SOURCE_FILE_NOT_FOUND` | Check case-sensitive source paths; rerun deployment if the samples need reseeding. |
| `EMPTY_JOB_LIST` | Supply at least one complete object in `pJobs`. |
| Existing factory Git integration error | Import into its collaboration branch and publish through the normal process. |
| Timeout | The runner requests recursive cancellation and throws; inspect Monitor before rerunning. |
| Deployment denied by policy | Use an approved region/network design. Do not bypass customer policy. |

## Cleanup

For a **dedicated demo resource group only**, review its contents before explicitly deleting it:

```powershell
az resource list --subscription $subscriptionId --resource-group $resourceGroup --output table
az group delete --subscription $subscriptionId --name $resourceGroup
```

Do **not** delete a shared/existing-factory resource group. Remove only reviewed demo assets, storage, and associated demo grants in that case. Deleting a GitHub repository does not remove Azure resources.

## License and references

Use, adapt, and redistribute under the [MIT License](LICENSE), without warranty. This community sample is not an official product or an endorsement by any customer.

- [Post-deployment walkthrough](docs/post-deployment-walkthrough.md)
- [ADF expressions and functions](https://learn.microsoft.com/azure/data-factory/control-flow-expression-language-functions)
- [ForEach activity](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity)
- [Execute Pipeline activity](https://learn.microsoft.com/azure/data-factory/control-flow-execute-pipeline-activity)
- [Blob connector and managed identity](https://learn.microsoft.com/azure/data-factory/connector-azure-blob-storage#system-assigned-managed-identity-authentication)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
