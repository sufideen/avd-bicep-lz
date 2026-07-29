// workspace.bicep — Application Group + Workspace, wired to the pilot host pool
param namePrefix string
param location string
param hostPoolId string

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: '${namePrefix}-dag-pilot'
  location: location
  properties: {
    hostPoolArmPath: hostPoolId
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: '${namePrefix}-ws-pilot'
  location: location
  properties: {
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

output appGroupId string = appGroup.id
output workspaceName string = workspace.name
