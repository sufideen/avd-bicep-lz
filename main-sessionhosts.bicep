// main-sessionhosts.bicep — Phase 2: deploy session hosts using a registration
// token fetched via CLI after the host pool exists (see README "Phase 2" section
// for why this is a separate deployment, not a limitation to work around later).

targetScope = 'resourceGroup'

@description('Must match namePrefix used in the phase 1 (main.bicep) deployment')
param namePrefix string = 'avdpoc'

param location string = resourceGroup().location

@description('Subnet resource ID — copy from phase 1 deployment output "subnetId"')
param subnetId string

@description('Host pool name — copy from phase 1 deployment output "hostPoolName"')
param hostPoolName string

@description('Registration token — fetch with: az desktopvirtualization hostpool show --query properties.registrationInfo.token -o tsv')
@secure()
param hostPoolRegistrationToken string

@description('Current DSC configuration zip URL — see modules/sessionHosts.bicep param description if this needs updating')
param dscModulesUrl string = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_10-19-2022.zip'

@allowed(['msi', 'dsc'])
param registrationMethod string = 'msi'

param sessionHostCount int = 2
param sessionHostSize string = 'Standard_D4s_v5'
param adminUsername string

@secure()
param adminPassword string

module sessionHosts 'modules/sessionHosts.bicep' = {
  name: 'deploy-sessionhosts'
  params: {
    namePrefix: namePrefix
    location: location
    subnetId: subnetId
    vmCount: sessionHostCount
    vmSize: sessionHostSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    hostPoolName: hostPoolName
    hostPoolRegistrationToken: hostPoolRegistrationToken
    dscModulesUrl: dscModulesUrl
    registrationMethod: registrationMethod
  }
}

output sessionHostNames array = sessionHosts.outputs.sessionHostNames
