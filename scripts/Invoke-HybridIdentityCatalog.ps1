#requires -Version 5.1
<#
.SYNOPSIS
    Catalogs on-prem and Entra accounts into one versioned person record.
.DESCRIPTION
    Matching user principal names become one row. The row stores the on-prem object GUID
    and the Entra object ID separately. Accounts that do not sync stay one-sided.
    Run this on a domain workstation. It uses the same AWS secret as the operator form.
#>
[CmdletBinding()]
param(
    [string]$SecretId,
    [string]$Region,
    [string]$AwsProfile,
    [string]$SearchBase,
    [int]$MaxUsers = 0,
    [switch]$WhatIf
)

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'PSAccessManagement.psd1') -Force
Connect-AccessManagement -SecretId $SecretId -Region $Region -AwsProfile $AwsProfile -NonInteractive
if ($WhatIf) {
    Sync-HybridIdentityCatalog -SearchBase $SearchBase -MaxUsers $MaxUsers -WhatIf
} else {
    Sync-HybridIdentityCatalog -SearchBase $SearchBase -MaxUsers $MaxUsers
}
