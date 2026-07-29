<#
create-pilot-test-user.ps1 — creates a throwaway, non-admin Entra ID user,
licenses it, and grants it the two AVD roles this pilot needs
(Desktop Virtualization User + Virtual Machine User Login), so you can test
end-user sign-in without using a privileged/admin account.

Why this exists: an admin account's Conditional Access / Authentication
Methods policy can require phishing-resistant MFA that the session host's
embedded Windows sign-in prompt can't satisfy — so a correct password still
gets rejected. Testing with an ordinary user rules that out (or confirms it).

Prerequisites (separate from the Azure RBAC Owner/Contributor role used
elsewhere in this repo):
  - Your signed-in az CLI identity needs an Entra ID directory role that can
    create users and assign licenses (User Administrator / License
    Administrator / Global Administrator).
  - The domain in -UserPrincipalName must be verified in this tenant.
  - Run -ListLicensesOnly first if you don't already know which license SKU
    to assign — the script won't guess since assigning the wrong one could
    use up a seat you needed elsewhere.
#>

param(
  [string]$UserPrincipalName = 'avdpilot-test@ict-cloud.solutions',
  [string]$DisplayName = 'AVD Pilot Test User',
  [string]$UsageLocation = 'GB',
  [string]$LicenseSkuPartNumber,
  [switch]$ListLicensesOnly,
  [string]$ResourceGroupName = 'rg-avd-poc',
  [string]$NamePrefix = 'avdpoc',
  [int]$VmCount = 2
)

$ErrorActionPreference = 'Stop'

if ($ListLicensesOnly) {
  az rest --method get --uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
    --query "value[].{sku:skuPartNumber, skuId:skuId, total:prepaidUnits.enabled, consumed:consumedUnits}" -o table
  return
}

if (-not $LicenseSkuPartNumber) {
  Write-Host "No -LicenseSkuPartNumber given — showing available SKUs so you can pick one with spare seats:`n"
  az rest --method get --uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
    --query "value[].{sku:skuPartNumber, skuId:skuId, total:prepaidUnits.enabled, consumed:consumedUnits}" -o table
  Write-Host "`nRe-run with -LicenseSkuPartNumber <one of the 'sku' values above>."
  return
}

$skuId = az rest --method get --uri 'https://graph.microsoft.com/v1.0/subscribedSkus' `
  --query "value[?skuPartNumber=='$LicenseSkuPartNumber'] | [0].skuId" -o tsv

if (-not $skuId) {
  throw "No SKU named '$LicenseSkuPartNumber' found in this tenant. Run with -ListLicensesOnly to see valid values."
}

$tempPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | % { [char]$_ })

Write-Host "Creating $UserPrincipalName ..."
az ad user create `
  --display-name $DisplayName `
  --user-principal-name $UserPrincipalName `
  --password $tempPassword `
  --force-change-password-next-sign-in false | Out-Null

Write-Host "Setting usage location to $UsageLocation (required before license assignment) ..."
az rest --method patch `
  --uri "https://graph.microsoft.com/v1.0/users/$UserPrincipalName" `
  --headers 'Content-Type=application/json' `
  --body "{`"usageLocation`": `"$UsageLocation`"}"

Write-Host "Assigning license $LicenseSkuPartNumber ..."
az rest --method post `
  --uri "https://graph.microsoft.com/v1.0/users/$UserPrincipalName/assignLicense" `
  --headers 'Content-Type=application/json' `
  --body "{`"addLicenses`": [{`"skuId`": `"$skuId`"}], `"removeLicenses`": []}"

Write-Host "Granting Desktop Virtualization User + Virtual Machine User Login ..."
$appGroupId = az deployment group show --resource-group $ResourceGroupName --name main --query "properties.outputs.appGroupId.value" -o tsv

az role assignment create --assignee $UserPrincipalName --role 'Desktop Virtualization User' --scope $appGroupId | Out-Null

for ($i = 1; $i -le $VmCount; $i++) {
  $vmName = '{0}-avdhost-{1:D2}' -f $NamePrefix, $i
  $vmId = az vm show -g $ResourceGroupName -n $vmName --query id -o tsv
  az role assignment create --assignee $UserPrincipalName --role 'Virtual Machine User Login' --scope $vmId | Out-Null
}

Write-Host "`nDone. Sign in at https://client.wvd.microsoft.com/arm/webclient with:"
Write-Host "  User:     $UserPrincipalName"
Write-Host "  Password: $tempPassword"
Write-Host "`n(Nothing else prints this password again — copy it now.)"
