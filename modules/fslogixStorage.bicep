// fslogixStorage.bicep — Azure Files Premium share for FSLogix profile containers
// Pilot scope: single share, RBAC-based Entra Kerberos auth (no storage key usage by hosts).
param namePrefix string
param location string
param subnetId string

var storageAccountName = toLower('${take(namePrefix, 6)}fsl${uniqueString(resourceGroup().id)}')

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  // Full rationale in README "Security scanning suppressions" - keep skip
  // comments to one line each, see note in modules/sessionHosts.bicep.
  // checkov:skip=CKV_AZURE_43:False positive - computed name is always 22 valid chars.
  // checkov:skip=CKV_AZURE_206:LRS is deliberate for a same-day pilot to minimize cost.
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    // NOTE: for pilot simplicity, Private Endpoint wiring is left as a follow-on step —
    // documented in README as the production hardening item.
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
    networkAcls: {
      defaultAction: 'Deny'
      // Lets first-party Azure services (backup, Defender for Storage, etc.)
      // reach the account under their own RBAC/managed-identity auth even
      // though public/other-network access is denied — doesn't weaken the
      // subnet-only access control above (CKV_AZURE_36).
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: subnetId
          action: 'Allow'
        }
      ]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storage
  name: 'default'
}

resource profileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'fslogix-profiles'
  properties: {
    shareQuota: 1024
    enabledProtocols: 'SMB'
  }
}

output storageAccountName string = storage.name
output profileShareName string = profileShare.name
