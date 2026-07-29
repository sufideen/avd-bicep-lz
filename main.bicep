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

@description('Entra object ID of a single pilot user (or group) to grant AVD feed access. Leave empty to skip — also see main-sessionhosts.bicep pilotUserObjectId, which grants the separate role needed to actually sign in to the host.')
param pilotUserObjectId string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param pilotUserPrincipalType string = 'User'

@description('Entra object ID of a security group whose members should all get AVD feed access — the recommended way to grant access once there\'s more than a couple of pilot users, since adding someone becomes an Entra group membership change instead of a redeploy. Leave empty to skip. Also see main-sessionhosts.bicep entraGroupObjectId for the matching VM sign-in role.')
param entraGroupObjectId string = ''

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
    pilotUserObjectId: pilotUserObjectId
    pilotUserPrincipalType: pilotUserPrincipalType
    entraGroupObjectId: entraGroupObjectId
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
output appGroupId string = workspace.outputs.appGroupId
output fslogixStorageAccount string = fslogix.outputs.storageAccountName
output subnetId string = networking.outputs.subnetId
