$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:AccessSession = $null
$script:ModuleRoot = $root
. (Join-Path $root 'src/Secret/ConvertTo-NormalizedAccessSecret.ps1')
. (Join-Path $root 'src/Audit/ConvertTo-AuditValue.ps1')
. (Join-Path $root 'src/Directory/DirectoryUtil.ps1')
. (Join-Path $root 'src/Directory/Find-AccessUser.ps1')
. (Join-Path $root 'src/Directory/AccessPlan.ps1')
. (Join-Path $root 'src/Secret/Connect-AccessManagement.ps1')
. (Join-Path $root 'src/Catalog/CatalogValue.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { $failures.Add($Name) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -ne $Expected) { $failures.Add("$Name expected [$Expected] actual [$Actual]") }
}

$raw = @'
{
  "OnPremAD": { "upn": "svc@example.com", "Pw": "secret-value", "Purpose": "bind" },
  "GraphApi": { "tenant": "tenant-id", "appId": "app-id", "ClientSecret": "graph-secret" },
  "ConnectionStrings": "Server=sql;Database=PSAccessAudit;"
}
'@
$normalized = ConvertTo-NormalizedAccessSecret -Json $raw
Assert-True $normalized.IsValid 'messy secret is valid'
Assert-True (-not $normalized.IsCanonical) 'messy secret is not canonical'
Assert-Equal $normalized.Canonical.OnPremAD.UserPrincipalName 'svc@example.com' 'upn mapped'
Assert-Equal $normalized.Canonical.OnPremAD.Password 'secret-value' 'password mapped'
Assert-Equal $normalized.Canonical.GraphApi.TenantId 'tenant-id' 'tenant mapped'
Assert-Equal $normalized.Canonical.ConnectionStrings.Audit 'Server=sql;Database=PSAccessAudit;' 'string connection mapped'
Assert-True (($normalized.Issues -join ' ') -match 'Password') 'rename is described'
Assert-True (($normalized.Issues -join ' ') -notmatch 'secret-value') 'issue text has no secret'

$broken = '{"OnPremAD":{"UserPrincipalName":"svc@example.com","Password":"x"}}'
$invalid = ConvertTo-NormalizedAccessSecret -Json $broken
Assert-True (-not $invalid.IsValid) 'incomplete secret is invalid'
Assert-True (($invalid.Missing -join ',') -match 'GraphApi.TenantId') 'missing tenant named'
Assert-True ($invalid.RepairedJson -eq $null) 'invalid secret does not emit repaired json'

$round = ConvertTo-NormalizedAccessSecret -Json $normalized.RepairedJson
Assert-True $round.IsCanonical 'repaired json is canonical'
Assert-Equal $round.Canonical.OnPremAD.Password 'secret-value' 'repair kept the password'

Assert-Equal (ConvertTo-AuditValue -AttributeName 'mail' -Value 'a@b.c') 'a@b.c' 'mail not redacted'
Assert-Equal (ConvertTo-AuditValue -AttributeName 'Password' -Value 'secret-value') '[REDACTED]' 'password redacted'
Assert-Equal (ConvertTo-AuditValue -AttributeName 'proxyAddresses' -Value @('SMTP:a@b.c', 'smtp:old@b.c')) 'SMTP:a@b.c; smtp:old@b.c' 'proxy joined'

$flags = ConvertTo-UacFlagList 514
Assert-True ($flags -contains 'NORMAL_ACCOUNT') 'normal account flag'
Assert-True ($flags -contains 'ACCOUNTDISABLE') 'disabled flag'
Assert-Equal (ConvertTo-LdapValue 'a*b(c)') 'a\2ab\28c\29' 'ldap escape'
Assert-Equal (Get-ParentDistinguishedName 'CN=Ada\, Lovelace,OU=People,DC=example,DC=com') 'OU=People,DC=example,DC=com' 'parent dn'
Assert-True (Test-SamAccountNameValue 'alovelace') 'sam ok'
Assert-True (-not (Test-SamAccountNameValue 'this-name-is-too-long')) 'sam length'
Assert-Equal (Get-EmailLocalPart -GivenName 'Ada' -Surname 'Lovelace' -Pattern 'GivenDotSurname') 'ada.lovelace' 'email pattern'

$updated = Update-PrimarySmtpAddress -ProxyAddresses @('SMTP:old@example.com', 'smtp:alias@example.com') -NewMail 'ada.lovelace@example.com' -KeepOldAsAlias $true
Assert-Equal $updated[0] 'SMTP:ada.lovelace@example.com' 'new primary'
Assert-True ($updated -contains 'smtp:old@example.com') 'old primary kept'
Assert-True ($updated -contains 'smtp:alias@example.com') 'existing alias kept'

$added = Add-ProxyAliasAddress -ProxyAddresses @('SMTP:ada@example.com') -Alias 'alias@example.com'
Assert-True ($added -contains 'smtp:alias@example.com') 'alias added'

$guid = [guid]'00112233-4455-6677-8899-aabbccddeeff'
$immutable = ConvertTo-ImmutableId $guid
Assert-Equal (ConvertFrom-ImmutableId $immutable) $guid 'immutable id roundtrip'

$class = Get-CatalogAttributeClass 'extensionAttribute12'
Assert-Equal $class 'Extension' 'extension class'
Assert-Equal (Get-CatalogAttributeClass 'employeeBadgeCode') 'Custom' 'custom class'
$redacted = @(ConvertTo-CatalogAttributes -Name 'unicodePwd' -Value 'nope')
Assert-Equal $redacted[0].ValueJson '"[REDACTED]"' 'catalog redacts passwords'

$user = [pscustomobject]@{
    DisplayName = 'Ada Lovelace'
    UserPrincipalName = 'ada@example.com'
    SamAccountName = 'alovelace'
    GivenName = 'Ada'
    Surname = 'Lovelace'
    Mail = 'ada@example.com'
    MailNickname = 'ada'
    ProxyAddresses = @('SMTP:ada@example.com')
    DistinguishedName = 'CN=Ada Lovelace,OU=People,DC=example,DC=com'
    OrganizationalUnit = 'OU=People,DC=example,DC=com'
    OnPremObjectGuid = $guid
    EntraObjectId = $null
    OnPremisesSyncEnabled = $true
    EnabledOnPrem = $false
    EnabledEntra = $false
    LockedOut = $true
    PasswordExpired = $true
    AdminCount = 0
    MemberOf = @()
    UserAccountControl = 514
    UacFlags = @('ACCOUNTDISABLE', 'NORMAL_ACCOUNT')
    ComputedUacFlags = @('ACCOUNTDISABLE', 'LOCKOUT', 'NORMAL_ACCOUNT')
    ExtensionAttributes = @{ extensionAttribute1 = 'old' }
    PerUserMfaState = 'disabled'
}
$plan = Get-AccessOperationPlan -User $user -Operation 'ReEnable'
Assert-True ([string]::IsNullOrEmpty($plan.Error)) 'reenable has no error'
Assert-True (($plan.Messages -join ' ') -match 'self-service') 'sspr message'
Assert-True (@($plan.Steps).Count -ge 2) 'reenable unlocks and enables'
Assert-True ((@($plan.Changes) | ForEach-Object Attribute) -contains 'userAccountControl') 'uac audited'

$aliasPlan = Get-AccessOperationPlan -User $user -Operation 'AddAlias' -Parameters @{ Alias = 'lab@example.com' }
Assert-True ([string]::IsNullOrEmpty($aliasPlan.Error)) 'alias plan ok'
Assert-True ((@($aliasPlan.Changes).Attribute) -contains 'proxyAddresses') 'alias change listed'

$same = Get-AccessOperationPlan -User $user -Operation 'AddAlias' -Parameters @{ Alias = 'ada@example.com' }
Assert-True ($same.Error -match 'already') 'duplicate alias rejected'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL: $_" }
    exit 1
}
Write-Output "OK $($failures.Count) failures"
exit 0
