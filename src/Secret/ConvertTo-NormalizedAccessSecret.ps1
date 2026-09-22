function ConvertTo-PlainHashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $Object }
    if ($Object -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Object.Keys)) {
            $copy[[string]$key] = ConvertTo-PlainHashtable $Object[$key]
        }
        return $copy
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $items = @()
        foreach ($item in $Object) { $items += ,(ConvertTo-PlainHashtable $item) }
        return $items
    }
    $copy = [ordered]@{}
    foreach ($prop in $Object.PSObject.Properties) {
        $copy[$prop.Name] = ConvertTo-PlainHashtable $prop.Value
    }
    return $copy
}

function Get-HashtableValue {
    param($Table, [string[]]$Names)
    if ($null -eq $Table) { return $null }
    if ($Table -is [string] -or $Table -is [ValueType]) { return $null }
    if (-not ($Table -is [System.Collections.IDictionary])) { return $null }
    foreach ($name in $Names) {
        foreach ($key in @($Table.Keys)) {
            if ([string]$key -eq $name) { return $Table[$key] }
        }
    }
    foreach ($name in $Names) {
        foreach ($key in @($Table.Keys)) {
            if ([string]$key -ieq $name) { return $Table[$key] }
        }
    }
    return $null
}

function Get-HashtableSection {
    param($Root, [string[]]$Names)
    $value = Get-HashtableValue -Table $Root -Names $Names
    if ($null -eq $value) { return $null }
    if ($value -is [string]) { return $value }
    return $value
}

function Copy-UnknownKeys {
    param($Source, [string[]]$Consumed, $Target)
    if ($null -eq $Source -or -not ($Source -is [System.Collections.IDictionary])) { return }
    foreach ($key in @($Source.Keys)) {
        $name = [string]$key
        $skip = $false
        foreach ($used in $Consumed) {
            if ($name -ieq $used) { $skip = $true; break }
        }
        if ($skip) { continue }
        if (-not $Target.Contains($name)) {
            $Target[$name] = $Source[$key]
        }
    }
}

function ConvertTo-NormalizedAccessSecret {
    <#
    .SYNOPSIS
        Normalizes the AWS secret JSON into the canonical PS Access Management shape.
    .DESCRIPTION
        Accepts the loose shape (upn / Pw) or the canonical shape. Returns issues and
        a repaired JSON string. The repaired JSON still contains secrets. Do not log it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    try {
        $parsed = ConvertFrom-Json -InputObject $Json
    } catch {
        return [pscustomobject]@{
            IsValid = $false
            IsCanonical = $false
            Issues = @('Secret payload is not valid JSON.')
            Missing = @()
            Canonical = $null
            RepairedJson = $null
        }
    }

    $root = ConvertTo-PlainHashtable $parsed
    if ($null -eq $root -or -not ($root -is [System.Collections.IDictionary])) {
        return [pscustomobject]@{
            IsValid = $false
            IsCanonical = $false
            Issues = @('Secret JSON must be an object.')
            Missing = @()
            Canonical = $null
            RepairedJson = $null
        }
    }

    $onPremSource = Get-HashtableSection -Root $root -Names @('OnPremAD', 'OnPremAd', 'ActiveDirectory', 'Ad')
    if ($onPremSource -is [string] -or $null -eq $onPremSource) {
        $issues.Add('OnPremAD must be an object.')
        $onPremSource = [ordered]@{}
    }

    $upn = [string](Get-HashtableValue -Table $onPremSource -Names @('UserPrincipalName', 'upn', 'UPN', 'UserName'))
    $password = [string](Get-HashtableValue -Table $onPremSource -Names @('Password', 'Pw', 'PW', 'pwd'))
    $purpose = [string](Get-HashtableValue -Table $onPremSource -Names @('Purpose', 'purpose', 'Description'))
    $server = [string](Get-HashtableValue -Table $onPremSource -Names @('Server', 'DomainController', 'Dc'))
    $searchBase = [string](Get-HashtableValue -Table $onPremSource -Names @('SearchBase', 'SearchRoot'))

    $hadUpnAlias = $false
    $hadPasswordAlias = $false
    foreach ($key in @($onPremSource.Keys)) {
        if ([string]$key -eq 'upn' -or [string]$key -eq 'UPN' -or [string]$key -eq 'UserName') { $hadUpnAlias = $true }
        if ([string]$key -eq 'Pw' -or [string]$key -eq 'PW' -or [string]$key -eq 'pwd') { $hadPasswordAlias = $true }
    }
    if ($hadUpnAlias) { $issues.Add('OnPremAD.upn was renamed to OnPremAD.UserPrincipalName.') }
    if ($hadPasswordAlias) { $issues.Add('OnPremAD.Pw was renamed to OnPremAD.Password.') }

    $onPrem = [ordered]@{
        UserPrincipalName = $upn.Trim()
        Password = $password
        Purpose = $purpose
        Server = $server.Trim()
        SearchBase = $searchBase.Trim()
    }
    Copy-UnknownKeys -Source $onPremSource -Consumed @(
        'UserPrincipalName', 'upn', 'UPN', 'UserName', 'Password', 'Pw', 'PW', 'pwd',
        'Purpose', 'purpose', 'Description', 'Server', 'DomainController', 'Dc', 'SearchBase', 'SearchRoot'
    ) -Target $onPrem

    $graphSource = Get-HashtableSection -Root $root -Names @('GraphApi', 'Graph', 'MicrosoftGraph')
    if ($graphSource -is [string]) {
        $issues.Add('GraphApi must be an object. The original string was not copied.')
        $graphSource = [ordered]@{}
    }
    if ($null -eq $graphSource) { $graphSource = [ordered]@{} }

    $tenantId = [string](Get-HashtableValue -Table $graphSource -Names @('TenantId', 'tenantId', 'tenant', 'Tenant'))
    $clientId = [string](Get-HashtableValue -Table $graphSource -Names @('ClientId', 'clientId', 'appId', 'AppId', 'ApplicationId'))
    $clientSecret = [string](Get-HashtableValue -Table $graphSource -Names @('ClientSecret', 'clientSecret', 'secret', 'Secret'))
    $thumb = [string](Get-HashtableValue -Table $graphSource -Names @('CertificateThumbprint', 'certificateThumbprint', 'thumbprint', 'Thumbprint'))
    $organization = [string](Get-HashtableValue -Table $graphSource -Names @('Organization', 'organization', 'ExchangeOrganization'))
    $authMode = 'None'
    if (-not [string]::IsNullOrWhiteSpace($thumb)) { $authMode = 'Certificate' }
    elseif (-not [string]::IsNullOrWhiteSpace($clientSecret)) { $authMode = 'ClientSecret' }

    $graph = [ordered]@{
        TenantId = $tenantId.Trim()
        ClientId = $clientId.Trim()
        ClientSecret = $clientSecret
        CertificateThumbprint = ($thumb -replace '\s', '').ToUpperInvariant()
        AuthMode = $authMode
        Organization = $organization.Trim()
    }
    Copy-UnknownKeys -Source $graphSource -Consumed @(
        'TenantId', 'tenantId', 'tenant', 'Tenant', 'ClientId', 'clientId', 'appId', 'AppId', 'ApplicationId',
        'ClientSecret', 'clientSecret', 'secret', 'Secret', 'CertificateThumbprint', 'certificateThumbprint',
        'thumbprint', 'Thumbprint', 'Organization', 'organization', 'ExchangeOrganization', 'AuthMode'
    ) -Target $graph

    $csSource = Get-HashtableSection -Root $root -Names @('ConnectionStrings', 'connectionStrings', 'Sql')
    $audit = ''
    $catalog = ''
    $csTable = $null
    if ($csSource -is [string]) {
        $issues.Add('ConnectionStrings was a string and was mapped to ConnectionStrings.Audit.')
        $audit = $csSource
        $csTable = [ordered]@{}
    } elseif ($null -eq $csSource) {
        $csTable = [ordered]@{}
    } else {
        $csTable = $csSource
        $audit = [string](Get-HashtableValue -Table $csTable -Names @('Audit', 'audit', 'Application', 'Default', 'ConnectionString', 'PSAccess'))
        $catalog = [string](Get-HashtableValue -Table $csTable -Names @('Catalog', 'catalog', 'IdentityCatalog'))
    }

    $connections = [ordered]@{
        Audit = $audit.Trim()
        Catalog = $catalog.Trim()
    }
    Copy-UnknownKeys -Source $csTable -Consumed @(
        'Audit', 'audit', 'Application', 'Default', 'ConnectionString', 'PSAccess', 'Catalog', 'catalog', 'IdentityCatalog'
    ) -Target $connections

    if ([string]::IsNullOrWhiteSpace($onPrem.UserPrincipalName)) { $missing.Add('OnPremAD.UserPrincipalName') }
    if ([string]::IsNullOrWhiteSpace($onPrem.Password)) { $missing.Add('OnPremAD.Password') }
    if ([string]::IsNullOrWhiteSpace($connections.Audit)) { $missing.Add('ConnectionStrings.Audit') }
    if ([string]::IsNullOrWhiteSpace($graph.TenantId)) { $missing.Add('GraphApi.TenantId') }
    if ([string]::IsNullOrWhiteSpace($graph.ClientId)) { $missing.Add('GraphApi.ClientId') }
    if ([string]::IsNullOrWhiteSpace($graph.ClientSecret) -and [string]::IsNullOrWhiteSpace($graph.CertificateThumbprint)) {
        $missing.Add('GraphApi.ClientSecret or GraphApi.CertificateThumbprint')
    }

    $canonical = [ordered]@{
        schemaVersion = 1
        OnPremAD = $onPrem
        GraphApi = $graph
        ConnectionStrings = $connections
    }
    Copy-UnknownKeys -Source $root -Consumed @(
        'schemaVersion', 'OnPremAD', 'OnPremAd', 'ActiveDirectory', 'Ad', 'GraphApi', 'Graph', 'MicrosoftGraph',
        'ConnectionStrings', 'connectionStrings', 'Sql'
    ) -Target $canonical

    $repaired = $null
    if ($missing.Count -eq 0) {
        $repaired = $canonical | ConvertTo-Json -Depth 8
    }
    $isCanonical = ($issues.Count -eq 0)

    [pscustomobject]@{
        IsValid = ($missing.Count -eq 0)
        IsCanonical = $isCanonical
        Issues = @($issues)
        Missing = @($missing)
        Canonical = $canonical
        RepairedJson = $repaired
    }
}
