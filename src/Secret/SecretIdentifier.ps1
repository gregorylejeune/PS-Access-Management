function Get-SecretIdentifierPath {
    $root = Join-Path $env:LOCALAPPDATA 'PSAccessManagement'
    Join-Path $root 'secret-identifier.dpapi'
}

function Protect-AccessSecretIdentifier {
    <#
    .SYNOPSIS
        Stores the AWS secret name, region, and environment-variable bindings with DPAPI.
    .DESCRIPTION
        The secret value is never written. Only the current Windows user on this machine can read the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretId,
        [Parameter(Mandatory = $true)]
        [string]$Region,
        [string]$SecretIdVariable,
        [string]$RegionVariable,
        [string]$ProfileVariable
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'The secret identifier can only be saved with Windows DPAPI.'
    }

    $payload = [ordered]@{
        version = 1
        secretId = $SecretId
        region = $Region
        secretIdVariable = $SecretIdVariable
        regionVariable = $RegionVariable
        profileVariable = $ProfileVariable
        savedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4

    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $entropy = [Text.Encoding]::UTF8.GetBytes('PSAccessManagement.SecretIdentifier.v1')
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )

    $path = Get-SecretIdentifierPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($path, $protected)
    $path
}

function Unprotect-AccessSecretIdentifier {
    [CmdletBinding()]
    param()

    $path = Get-SecretIdentifierPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if ($env:OS -ne 'Windows_NT') {
        throw 'The saved secret identifier can only be opened with Windows DPAPI.'
    }

    Add-Type -AssemblyName System.Security
    $protected = [IO.File]::ReadAllBytes($path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('PSAccessManagement.SecretIdentifier.v1')
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $json = [Text.Encoding]::UTF8.GetString($bytes)
    ConvertFrom-Json -InputObject $json
}
