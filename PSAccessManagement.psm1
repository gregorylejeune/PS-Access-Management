Set-StrictMode -Version 2.0

$script:ModuleRoot = $PSScriptRoot
$script:AccessModuleVersion = '0.1.0'
$script:DefaultSecretId = 'HH_PS_AccessManagement'
$script:AccessSession = $null

$sourceFiles = @(
    'src/Secret/ConvertTo-NormalizedAccessSecret.ps1'
    'src/Secret/SecretIdentifier.ps1'
    'src/Secret/Get-AwsSecretString.ps1'
    'src/Secret/Get-GraphToken.ps1'
    'src/Secret/Connect-AccessManagement.ps1'
    'src/Config/Get-AccessEnvironmentChoice.ps1'
    'src/Audit/ConvertTo-AuditValue.ps1'
    'src/Audit/Install-AccessAuditSchema.ps1'
    'src/Audit/Write-AccessAudit.ps1'
    'src/Directory/DirectoryUtil.ps1'
    'src/Directory/Find-AccessUser.ps1'
    'src/Directory/AccessPlan.ps1'
    'src/Directory/Invoke-AccessOperation.ps1'
    'src/Catalog/CatalogValue.ps1'
    'src/Catalog/Sync-HybridIdentityCatalog.ps1'
    'src/Ui/Show-AccessManagementForm.ps1'
)

foreach ($relative in $sourceFiles) {
    $path = Join-Path $script:ModuleRoot $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "PS Access Management is missing $relative"
    }
    . $path
}

Export-ModuleMember -Function @(
    'ConvertTo-NormalizedAccessSecret'
    'Protect-AccessSecretIdentifier'
    'Unprotect-AccessSecretIdentifier'
    'Get-AccessEnvironmentChoice'
    'Connect-AccessManagement'
    'Disconnect-AccessManagement'
    'Install-AccessAuditSchema'
    'Find-AccessUser'
    'Get-AccessOperationPlan'
    'Invoke-AccessOperation'
    'Sync-HybridIdentityCatalog'
    'Show-AccessManagementForm'
)
