targetScope = 'resourceGroup'

@description('Region for the demo resources.')
param location string = resourceGroup().location

@description('Short lowercase alphanumeric prefix used for globally unique resource names.')
@minLength(3)
@maxLength(9)
param namePrefix string = 'adfparam'

@description('Existing factory name, or leave empty to create an isolated demo factory.')
param existingFactoryName string = ''

@description('Enable synthetic seeding and grant the factory write access to landing. Disable when using preloaded customer data.')
param enableSampleSeeding bool = true

var suffix = uniqueString(resourceGroup().id)
var factoryName = empty(existingFactoryName) ? 'adf-${namePrefix}-${suffix}' : existingFactoryName
var storageName = 'st${namePrefix}${suffix}'
var tags = {
  project: 'adf-parameterized-pipeline-accelerator'
  environment: 'demo'
  dataClassification: 'synthetic-only'
}

module factory 'br/public:avm/res/data-factory/factory:0.13.0' = if (empty(existingFactoryName)) {
  name: 'factory'
  params: {
    name: factoryName
    location: location
    managedIdentities: {
      systemAssigned: true
    }
    publicNetworkAccess: 'Enabled'
    enableTelemetry: false
    tags: tags
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'storage'
  params: {
    name: storageName
    location: location
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    requireInfrastructureEncryption: true
    publicNetworkAccess: 'Disabled'
    // Trusted ADF requests still require managed identity and container-scoped RBAC.
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    blobServices: {
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 7
      isVersioningEnabled: true
      containers: [
        { name: 'landing', publicAccess: 'None' }
        { name: 'curated', publicAccess: 'None' }
      ]
    }
    enableTelemetry: false
    tags: tags
  }
}

module assets 'modules/adf-assets.bicep' = {
  name: 'adf-assets'
  params: {
    factoryName: factoryName
    storageAccountName: storage.outputs.name
    enableSampleSeeding: enableSampleSeeding
  }
  dependsOn: [
    factory
  ]
}

output factoryName string = factoryName
output factoryResourceId string = resourceId('Microsoft.DataFactory/factories', factoryName)
output storageAccountName string = storage.outputs.name
output blobServiceUrl string = 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}/'
output sourceContainer string = 'landing'
output sinkContainer string = 'curated'
output studioUrl string = 'https://adf.azure.com/en/authoring?factory=${uriComponent(resourceId('Microsoft.DataFactory/factories', factoryName))}'
