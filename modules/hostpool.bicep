// hostpool.bicep — Pooled, BreadthFirst host pool for the pilot
param namePrefix string
param location string
param maxSessionLimit int

@description('Registration token expiry — must be a param default, utcNow() is not valid inline in a resource property')
param registrationTokenExpiration string = dateTimeAdd(utcNow(), 'P7D')

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: '${namePrefix}-hp-pilot'
  location: location
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: maxSessionLimit
    startVMOnConnect: true
    validationEnvironment: false
    registrationInfo: {
      // 7-day expiry — short-lived, regenerate for production
      expirationTime: registrationTokenExpiration
      registrationTokenOperation: 'Update'
    }
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
// registrationToken is deliberately NOT output here — reading
// registrationInfo.token back in the same deployment that creates the host
// pool fails evaluation (ARM timing quirk). Fetch it via CLI in Phase 2
// instead: az desktopvirtualization hostpool show --query properties.registrationInfo.token
