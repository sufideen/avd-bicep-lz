<#
Tears down the pilot's billable resources — session host VMs (plus their OS
disks and NICs) and the FSLogix Premium Files storage account — while leaving
the free control-plane objects in place: host pool, workspace, application
group, scaling plan, VNet/NSG. Those cost nothing sitting idle, so the pilot
stays demoable and Phase 2 (session hosts) can be redeployed later without
redoing Phase 1.

Run the whole-resource-group teardown instead (az group delete) if you want
to remove everything, control plane included.

Usage:
  ./teardown-billable.ps1 -ResourceGroup rg-avd-poc
#>
param(
  [string]$ResourceGroup = 'rg-avd-poc'
)
$ErrorActionPreference = 'Stop'

Write-Host "Resolving session host VMs in $ResourceGroup..."
$vmNames = az vm list --resource-group $ResourceGroup --query "[?starts_with(name, 'avdpoc-avdhost')].name" -o tsv

if (-not $vmNames) {
  Write-Host "No session host VMs found - already torn down, or namePrefix differs from 'avdpoc'."
}

foreach ($vm in $vmNames) {
  Write-Host "Deleting VM $vm (and its OS disk + NIC)..."
  $osDiskName = az vm show --resource-group $ResourceGroup --name $vm --query "storageProfile.osDisk.name" -o tsv
  $nicId = az vm show --resource-group $ResourceGroup --name $vm --query "networkProfile.networkInterfaces[0].id" -o tsv

  # VM deletion does not cascade to the OS disk or NIC (no deleteOption set
  # on either in modules/sessionHosts.bicep) - both must be deleted explicitly
  # or they'll keep billing (disk) / linger (NIC) after the VM is gone.
  az vm delete --resource-group $ResourceGroup --name $vm --yes

  if ($nicId) {
    az network nic delete --ids $nicId
  }
  if ($osDiskName) {
    az disk delete --resource-group $ResourceGroup --name $osDiskName --yes
  }
}

Write-Host "Deleting FSLogix storage account (Premium Files bills for provisioned capacity, not usage)..."
$storageAccounts = az storage account list --resource-group $ResourceGroup --query "[?contains(name, 'fsl')].name" -o tsv

if (-not $storageAccounts) {
  Write-Host "No FSLogix storage account found - already torn down, or namePrefix differs from 'avdpoc'."
}

foreach ($sa in $storageAccounts) {
  az storage account delete --resource-group $ResourceGroup --name $sa --yes
}

Write-Host "`nDone. Remaining in ${ResourceGroup} (no ongoing cost): host pool, workspace, app group, scaling plan, VNet/NSG."
az resource list --resource-group $ResourceGroup -o table
