targetScope = 'resourceGroup'
param factoryName string

resource factory 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: factoryName
}

resource managedNetwork 'Microsoft.DataFactory/factories/managedVirtualNetworks@2018-06-01' = {
  parent: factory
  name: 'default'
  properties: {}
}
