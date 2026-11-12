@description('Factory must already exist and have a system-assigned managed identity.')
param factoryName string

param storageAccountName string
param enableSampleSeeding bool = true

resource factory 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: factoryName
}

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' existing = {
  parent: storage
  name: 'default'
}

resource landing 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' existing = {
  parent: blobService
  name: 'landing'
}

resource curated 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' existing = {
  parent: blobService
  name: 'curated'
}

resource sourceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(landing.id, factory.id, enableSampleSeeding ? 'blob-contributor' : 'blob-reader')
  scope: landing
  properties: {
    principalId: factory.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', enableSampleSeeding ? 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' : '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}

resource sinkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(curated.id, factory.id, 'blob-contributor')
  scope: curated
  properties: {
    principalId: factory.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

var linkedServiceDefinition = loadJsonContent('../../adf/linkedService/acc_BlobStorage.json')
var datasetDefinition = loadJsonContent('../../adf/dataset/acc_Csv.json')
var copyDefinition = loadJsonContent('../../adf/pipeline/acc_CopyCsv.json')
var batchDefinition = loadJsonContent('../../adf/pipeline/acc_ProcessBatch.json')
var seedDefinition = loadJsonContent('../../adf/pipeline/acc_SeedSamples.json')
var previewDefinition = loadJsonContent('../../adf/pipeline/acc_PreviewCsv.json')

resource linkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: factory
  name: linkedServiceDefinition.name
  properties: union(linkedServiceDefinition.properties, {
    typeProperties: {
      serviceEndpoint: storage.properties.primaryEndpoints.blob
      accountKind: 'StorageV2'
    }
  })
}

resource dataset 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: factory
  name: datasetDefinition.name
  properties: datasetDefinition.properties
  dependsOn: [linkedService]
}

resource copyPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: factory
  name: copyDefinition.name
  properties: copyDefinition.properties
  dependsOn: [dataset, sourceRole, sinkRole]
}

resource batchPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: factory
  name: batchDefinition.name
  properties: batchDefinition.properties
  dependsOn: [copyPipeline]
}

resource seedPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = if (enableSampleSeeding) {
  parent: factory
  name: seedDefinition.name
  properties: seedDefinition.properties
  dependsOn: [sourceRole]
}

resource previewPipeline 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = {
  parent: factory
  name: previewDefinition.name
  properties: previewDefinition.properties
  dependsOn: [dataset, sourceRole, sinkRole]
}
