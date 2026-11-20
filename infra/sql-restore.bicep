targetScope = 'resourceGroup'

@description('Existing live-mode accelerator factory with a system-assigned identity.')
param factoryName string

@description('Microsoft Entra user or group to administer this dedicated demo SQL server.')
param administratorLogin string
param administratorObjectId string
@allowed(['User', 'Group'])
param administratorType string = 'User'
param tenantId string = tenant().tenantId
param location string = resourceGroup().location

var serverName = 'sql-adfbackup-${uniqueString(resourceGroup().id)}'
var tags = {
  project: 'adf-parameterized-pipeline-accelerator'
  environment: 'demo'
  dataClassification: 'synthetic-only'
  feature: 'sql-backup-validation'
}

resource factory 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: factoryName
}

resource server 'Microsoft.Sql/servers@2025-01-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: administratorLogin
      principalType: administratorType
      sid: administratorObjectId
      tenantId: tenantId
    }
  }
}

resource sourceDatabase 'Microsoft.Sql/servers/databases@2025-01-01' = {
  parent: server
  name: 'acc_BackupSource'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    maxSizeBytes: 2147483648
    requestedBackupStorageRedundancy: 'Local'
  }
}

resource retention 'Microsoft.Sql/servers/databases/backupShortTermRetentionPolicies@2025-01-01' = {
  parent: sourceDatabase
  name: 'default'
  properties: {
    retentionDays: 7
  }
}

resource managedNetwork 'Microsoft.DataFactory/factories/managedVirtualNetworks@2018-06-01' existing = {
  parent: factory
  name: 'default'
}

var runtimeDefinition = loadJsonContent('../adf/integrationRuntime/acc_SqlManagedIR.json')
resource runtime 'Microsoft.DataFactory/factories/integrationRuntimes@2018-06-01' = {
  parent: factory
  name: runtimeDefinition.name
  properties: runtimeDefinition.properties
}

resource privateEndpoint 'Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01' = {
  parent: managedNetwork
  name: 'acc_SqlPrivateEndpoint'
  properties: {
    privateLinkResourceId: server.id
    groupId: 'sqlServer'
  }
}

resource databaseRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(server.id, factory.id, 'sql-db-contributor')
  scope: server
  properties: {
    principalId: factory.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9b7fa17d-e63e-47b0-bb0a-15c516ac86ec')
  }
}

output sqlServerName string = server.name
output sqlServerResourceId string = server.id
output sqlServerFqdn string = server.properties.fullyQualifiedDomainName
output sourceDatabaseName string = sourceDatabase.name
output sourceDatabaseResourceId string = sourceDatabase.id
output location string = location
output privateEndpointResourceId string = privateEndpoint.id
