// main.bicep — AVD Pilot POC orchestrator
// Deploys a minimal, working AVD environment for a small pilot group.
// Scope: resource group deployment.

targetScope = 'resourceGroup'

@description('Short name used as a prefix for all resources, e.g. avdpoc')
param namePrefix string = 'avdpoc'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Address space for the pilot VNet')
param vnetAddressPrefix string = '10.50.0.0/24'

@description('Address space for the session host subnet')
param subnetAddressPrefix string = '10.50.0.0/25'

@description('Max session limit per host (pooled, BreadthFirst)')
param maxSessionLimit int = 4

// 1. Networking
module networking 'modules/networking.bicep' = {
  name: 'deploy-networking'
  params: {
    namePrefix: namePrefix
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
  }
}

// 2. FSLogix profile storage
module fslogix 'modules/fslogixStorage.bicep' = {
  name: 'deploy-fslogix'
  params: {
    namePrefix: namePrefix
    location: location
    subnetId: networking.outputs.subnetId
  }
}

// 3. Host pool
module hostpool 'modules/hostpool.bicep' = {
  name: 'deploy-hostpool'
  params: {
    namePrefix: namePrefix
    location: location
    maxSessionLimit: maxSessionLimit
  }
}

// 4. Workspace + Application Group
module workspace 'modules/workspace.bicep' = {
  name: 'deploy-workspace'
  params: {
    namePrefix: namePrefix
    location: location
    hostPoolId: hostpool.outputs.hostPoolId
  }
}

// 5. Scaling plan
module scalingPlan 'modules/scalingPlan.bicep' = {
  name: 'deploy-scalingplan'
  params: {
    namePrefix: namePrefix
    location: location
    hostPoolId: hostpool.outputs.hostPoolId
  }
}

output hostPoolName string = hostpool.outputs.hostPoolName
output workspaceName string = workspace.outputs.workspaceName
output fslogixStorageAccount string = fslogix.outputs.storageAccountName
output subnetId string = networking.outputs.subnetId
