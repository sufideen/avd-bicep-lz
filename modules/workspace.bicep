// workspace.bicep — Application Group + Workspace, wired to the pilot host pool
param namePrefix string
param location string
param hostPoolId string

@description('Entra object ID of the pilot user (or group) to grant feed access. Leave empty to skip — this only gets the desktop into the user\'s feed; it does NOT let them sign in to the host, see modules/sessionHosts.bicep pilotUserObjectId for the other required role.')
param pilotUserObjectId string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param pilotUserPrincipalType string = 'User'

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

// Desktop Virtualization User — built-in role ID, scoped to this app group only.
// Grants feed visibility; does not by itself grant sign-in to the session host.
resource pilotUserFeedAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(pilotUserObjectId)) {
  name: guid(appGroup.id, pilotUserObjectId, 'DesktopVirtualizationUser')
  scope: appGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
    principalId: pilotUserObjectId
    principalType: pilotUserPrincipalType
  }
}

output appGroupId string = appGroup.id
output workspaceName string = workspace.name
