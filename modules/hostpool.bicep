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
    // REQUIRED for Entra-ID-joined session hosts (these VMs use AADLoginForWindows,
    // not domain join). Without it, the RDP client has no signal that the target is
    // Azure-AD-joined, so it never invokes Azure AD auth for the session and instead
    // falls back to legacy NTLM — which cannot validate a cloud-only Entra identity
    // and fails with STATUS_NO_SUCH_USER (0xC0000064), surfaced to the user as a
    // generic "incorrect password." Confirmed on this exact pilot via the session
    // host's Security event log (4625, Logon Type 3, Authentication Package NTLM).
    customRdpProperty: 'targetisaadjoined:i:1'
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
