param([string]$RegistrationToken)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2310011' -OutFile "$env:TEMP\AVDAgent.msi"
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2311028' -OutFile "$env:TEMP\AVDBootLoader.msi"
Start-Process msiexec.exe -Wait -ArgumentList @('/i', "$env:TEMP\AVDAgent.msi", '/quiet', '/norestart', "REGISTRATIONTOKEN=$RegistrationToken")
Start-Process msiexec.exe -Wait -ArgumentList @('/i', "$env:TEMP\AVDBootLoader.msi", '/quiet', '/norestart')
Get-Service -Name RDAgentBootLoader, RDAgent | Select-Object Name, Status
