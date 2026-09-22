@{
    RootModule = 'PSAccessManagement.psm1'
    ModuleVersion = '0.1.0'
    GUID = '95aa6ab4-26e4-46df-bca9-558e887ed591'
    Author = 'Greg LeJeune'
    Description = 'PS access management. Audited hybrid on-prem AD, Entra ID, and Exchange operator console.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
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
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('ActiveDirectory', 'Entra', 'Exchange', 'Audit')
            ProjectUri = 'https://github.com/gregorylejeune/PS-Access-Management'
            ReleaseNotes = 'Initial operator console, audit schema, and hybrid identity catalog.'
        }
    }
}
