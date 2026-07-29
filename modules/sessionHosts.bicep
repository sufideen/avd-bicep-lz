// sessionHosts.bicep — Pilot session host VMs, Entra ID joined, marketplace Win11
// multi-session image (no custom golden image for the pilot — documented as a
// production follow-on in README).
param namePrefix string
param location string
param subnetId string
param vmCount int
param vmSize string
param adminUsername string
@secure()
param adminPassword string
param hostPoolName string
param hostPoolRegistrationToken string

@description('Entra object ID of the pilot user (or group) to grant sign-in rights on the session hosts. This is the role that actually lets an Entra-joined VM authenticate the user — Desktop Virtualization User (see modules/workspace.bicep) only controls feed visibility and is not sufficient on its own. Leave empty to skip.')
param pilotUserObjectId string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param pilotUserPrincipalType string = 'User'

@description('Current DSC configuration zip URL — Microsoft rotates this periodically. If deploy fails with BlobNotFound, get the current value from: Host pool > Session hosts > + Add > Review+create > Download a template for automation, then search that JSON for modulesUrl. Only used if registrationMethod is "dsc".')
param dscModulesUrl string = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_10-19-2022.zip'

@description('How to register the AVD agent. "msi" (default) installs via Microsoft.Compute/CustomScriptExtension pulling the agent MSI + bootloader MSI from Microsoft\'s stable go.microsoft.com/fwlink redirect links — these don\'t rot like the versioned DSC blob does. "dsc" uses the legacy DSC extension with dscModulesUrl if you need to fall back to the known-working manual-URL path.')
@allowed(['msi', 'dsc'])
param registrationMethod string = 'msi'

resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(0, vmCount): {
  name: '${namePrefix}-avdhost-${padLeft(i + 1, 2, '0')}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, vmCount): {
  // Full rationale for each skip below is in README "Security scanning
  // suppressions" - Checkov's Bicep grammar can't reliably parse multi-line
  // wrapped comments after a skip directive (confirmed: a wrapped
  // continuation line broke the parser silently), so keep each to one line.
  // checkov:skip=CKV_AZURE_50:Required for AVD - Entra join and agent install extensions.
  // checkov:skip=CKV_AZURE_178:Not applicable - Windows VM, not Linux.
  // checkov:skip=CKV_AZURE_1:Not applicable - Windows VM uses adminUsername/adminPassword by design.
  // checkov:skip=CKV_AZURE_97:Encryption at Host deferred - subscription feature not registered (owner decision).
  // checkov:skip=CKV_AZURE_151:Azure Disk Encryption deferred to production - see README.
  name: '${namePrefix}-avdhost-${padLeft(i + 1, 2, '0')}'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${namePrefix}h${padLeft(i + 1, 2, '0')}'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-23h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
  }
}]

// Virtual Machine User Login — built-in role ID, scoped per VM. Required for
// Entra-ID-joined hosts: without it, the user's desktop shows up in the feed
// (via Desktop Virtualization User, see modules/workspace.bicep) but sign-in
// to the host itself is denied. This is the piece that's easy to miss because
// AADLoginForWindows alone doesn't grant it.
resource pilotUserVmLoginAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, vmCount): if (!empty(pilotUserObjectId)) {
  name: guid(vms[i].id, pilotUserObjectId, 'VirtualMachineUserLogin')
  scope: vms[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
    principalId: pilotUserObjectId
    principalType: pilotUserPrincipalType
  }
}]

// Entra ID join
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): {
  parent: vms[i]
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
  }
}]

// AVD agent registration — MSI-based (default), avoids the DSC blob rotation problem
//
// IMPORTANT: PowerShell's -EncodedCommand does NOT support trailing named
// parameters the way -File does — anything after -EncodedCommand's base64
// blob is parsed by powershell.exe's own argument binder, not handed to the
// decoded script. Appending "-RegistrationToken ..." after -EncodedCommand
// fails immediately with exit code -196608: "Cannot process command because
// a command is already specified with -Command or -EncodedCommand." (This is
// exactly what broke registration on both pilot hosts — the installer never
// ran at all.) Fix: interpolate the token directly into the script text and
// invoke it with -Command instead of pre-encoding a static blob.
resource avdMsiInstall 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): if (registrationMethod == 'msi') {
  parent: vms[i]
  name: 'InstallAVDAgent'
  location: location
  dependsOn: [
    aadLogin[i]
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      // go.microsoft.com/fwlink links are Microsoft's own stable redirectors — they
      // don't rot the way the versioned DSC configuration zip filename does.
      commandToExecute: 'powershell -ExecutionPolicy Bypass -NonInteractive -Command "$ProgressPreference=\'SilentlyContinue\';$ErrorActionPreference=\'Stop\';Invoke-WebRequest -Uri \'https://go.microsoft.com/fwlink/?linkid=2310011\' -OutFile \'$env:TEMP\\AVDAgent.msi\';Invoke-WebRequest -Uri \'https://go.microsoft.com/fwlink/?linkid=2311028\' -OutFile \'$env:TEMP\\AVDBootLoader.msi\';Start-Process msiexec.exe -Wait -ArgumentList @(\'/i\',\'$env:TEMP\\AVDAgent.msi\',\'/quiet\',\'/norestart\',\'REGISTRATIONTOKEN=${hostPoolRegistrationToken}\');Start-Process msiexec.exe -Wait -ArgumentList @(\'/i\',\'$env:TEMP\\AVDBootLoader.msi\',\'/quiet\',\'/norestart\')"'
    }
  }
}]

// AVD agent registration — legacy DSC fallback (registrationMethod = 'dsc')
resource avdDsc 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, vmCount): if (registrationMethod == 'dsc') {
  parent: vms[i]
  name: 'AVD-DSC'
  location: location
  dependsOn: [
    aadLogin[i]
  ]
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.83'
    autoUpgradeMinorVersion: true
    settings: {
      // Microsoft rotates this URL periodically — passed as a parameter for
      // exactly that reason, see param description above.
      modulesUrl: dscModulesUrl
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        HostPoolName: hostPoolName
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: hostPoolRegistrationToken
      }
    }
  }
}]

output sessionHostNames array = [for i in range(0, vmCount): vms[i].name]
