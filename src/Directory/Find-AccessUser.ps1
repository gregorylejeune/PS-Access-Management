function Invoke-AccessGraph {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'PATCH', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        $Body
    )
    $token = Get-AccessGraphToken
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
    }
    $request = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }
    try {
        return Invoke-RestMethod @request
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = [string]$_.ErrorDetails.Message }
        throw "Graph $Method failed. $detail"
    }
}

function Get-PerUserMfaState {
    param([string]$EntraId)
    if ([string]::IsNullOrWhiteSpace($EntraId)) { return $null }
    foreach ($version in @('v1.0', 'beta')) {
        try {
            $response = Invoke-AccessGraph -Method GET -Uri "https://graph.microsoft.com/$version/users/$EntraId/authentication/requirements"
            if ($response -and $response.perUserMfaState) { return [string]$response.perUserMfaState }
        } catch { }
    }
    $null
}

function New-AccessUserRecord {
    param($Values)
    [pscustomobject]$Values
}

function ConvertTo-AccessUserFromAd {
    param($AdUser, $GraphUser)
    $proxy = @()
    if ($AdUser.proxyAddresses) { $proxy = @($AdUser.proxyAddresses) }
    $memberOf = @()
    if ($AdUser.memberOf) { $memberOf = @($AdUser.memberOf) }
    $uac = 0
    if ($null -ne $AdUser.userAccountControl) { $uac = [int]$AdUser.userAccountControl }
    $computed = $uac
    $computedRaw = $AdUser.'msDS-User-Account-Control-Computed'
    if ($null -ne $computedRaw -and [string]$computedRaw -ne '') { $computed = [int]$computedRaw }
    $locked = (($computed -band 16) -eq 16)
    if (-not $locked -and $null -ne $AdUser.lockoutTime) {
        try { if ([int64]$AdUser.lockoutTime -gt 0) { $locked = $true } } catch { }
    }
    $entraId = $null
    $sync = $false
    $entraEnabled = $null
    if ($GraphUser) {
        $entraId = [guid]$GraphUser.id
        $sync = [bool]$GraphUser.onPremisesSyncEnabled
        $entraEnabled = [bool]$GraphUser.accountEnabled
    }
    $extensions = @{}
    for ($i = 1; $i -le 15; $i++) {
        $name = "extensionAttribute$i"
        $extensions[$name] = [string]$AdUser.$name
    }
    New-AccessUserRecord @{
        DisplayName = [string]$AdUser.displayName
        UserPrincipalName = [string]$AdUser.UserPrincipalName
        SamAccountName = [string]$AdUser.SamAccountName
        GivenName = [string]$AdUser.givenName
        Surname = [string]$AdUser.Surname
        Mail = [string]$AdUser.mail
        MailNickname = [string]$AdUser.mailNickname
        ProxyAddresses = $proxy
        DistinguishedName = [string]$AdUser.DistinguishedName
        OrganizationalUnit = (Get-ParentDistinguishedName $AdUser.DistinguishedName)
        OnPremObjectGuid = [guid]$AdUser.ObjectGuid
        OnPremSid = [string]$AdUser.ObjectSid
        EntraObjectId = $entraId
        ImmutableId = (ConvertTo-ImmutableId -ObjectGuid $AdUser.ObjectGuid)
        OnPremisesSyncEnabled = $sync
        EnabledOnPrem = [bool]$AdUser.Enabled
        EnabledEntra = $entraEnabled
        LockedOut = $locked
        PasswordExpired = [bool]$AdUser.PasswordExpired
        AdminCount = $(if ($AdUser.adminCount) { [int]$AdUser.adminCount } else { 0 })
        MemberOf = $memberOf
        UserAccountControl = $uac
        UacFlags = (ConvertTo-UacFlagList $uac)
        ComputedUacFlags = (ConvertTo-UacFlagList $computed)
        ExtensionAttributes = $extensions
        PerUserMfaState = $null
        Source = 'OnPremAD'
    }
}

function ConvertTo-AccessUserFromGraph {
    param($GraphUser)
    $proxy = @()
    if ($GraphUser.proxyAddresses) { $proxy = @($GraphUser.proxyAddresses) }
    $onPremGuid = ConvertFrom-ImmutableId ([string]$GraphUser.onPremisesImmutableId)
    New-AccessUserRecord @{
        DisplayName = [string]$GraphUser.displayName
        UserPrincipalName = [string]$GraphUser.userPrincipalName
        SamAccountName = [string]$GraphUser.onPremisesSamAccountName
        GivenName = [string]$GraphUser.givenName
        Surname = [string]$GraphUser.surname
        Mail = [string]$GraphUser.mail
        MailNickname = [string]$GraphUser.mailNickname
        ProxyAddresses = $proxy
        DistinguishedName = [string]$GraphUser.onPremisesDistinguishedName
        OrganizationalUnit = (Get-ParentDistinguishedName ([string]$GraphUser.onPremisesDistinguishedName))
        OnPremObjectGuid = $onPremGuid
        OnPremSid = [string]$GraphUser.onPremisesSecurityIdentifier
        EntraObjectId = [guid]$GraphUser.id
        ImmutableId = [string]$GraphUser.onPremisesImmutableId
        OnPremisesSyncEnabled = [bool]$GraphUser.onPremisesSyncEnabled
        EnabledOnPrem = $null
        EnabledEntra = [bool]$GraphUser.accountEnabled
        LockedOut = $false
        PasswordExpired = $false
        AdminCount = 0
        MemberOf = @()
        UserAccountControl = $null
        UacFlags = @()
        ComputedUacFlags = @()
        ExtensionAttributes = @{}
        PerUserMfaState = $null
        Source = 'Entra'
    }
}

function Get-AccessAdPropertyList {
    $names = @(
        'givenName', 'sn', 'displayName', 'mail', 'mailNickname', 'proxyAddresses', 'userPrincipalName',
        'sAMAccountName', 'distinguishedName', 'userAccountControl', 'lockoutTime', 'pwdLastSet',
        'msDS-User-Account-Control-Computed', 'adminCount', 'memberOf', 'canonicalName', 'targetAddress',
        'PasswordExpired'
    )
    for ($i = 1; $i -le 15; $i++) { $names += "extensionAttribute$i" }
    ,$names
}

function Get-GraphUserByFilter {
    param([Parameter(Mandatory = $true)][string]$Filter)
    $select = 'id,userPrincipalName,displayName,givenName,surname,mail,mailNickname,proxyAddresses,accountEnabled,onPremisesSyncEnabled,onPremisesImmutableId,onPremisesSamAccountName,onPremisesDistinguishedName,onPremisesSecurityIdentifier'
    $uri = 'https://graph.microsoft.com/v1.0/users?$filter=' + [uri]::EscapeDataString($Filter) + '&$select=' + $select + '&$top=25'
    $response = Invoke-AccessGraph -Method GET -Uri $uri
    @($response.value)
}

function Find-GraphUserForAd {
    param($AdUser)
    $immutable = ConvertTo-ImmutableId -ObjectGuid $AdUser.ObjectGuid
    $safeImmutable = $immutable.Replace("'", "''")
    $safeUpn = ([string]$AdUser.UserPrincipalName).Replace("'", "''")
    try {
        $byImmutable = @(Get-GraphUserByFilter "onPremisesImmutableId eq '$safeImmutable'")
        if ($byImmutable.Count -gt 0) { return $byImmutable[0] }
    } catch { }
    if ($safeUpn) {
        try {
            $byUpn = @(Get-GraphUserByFilter "userPrincipalName eq '$safeUpn'")
            if ($byUpn.Count -gt 0) { return $byUpn[0] }
        } catch { }
    }
    $null
}

function Find-SmtpConflict {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        $ExceptOnPremGuid,
        $ExceptEntraId
    )
    $safe = ConvertTo-LdapValue $Address
    if ($script:AccessSession -and $script:AccessSession.Credential) {
        $filter = "(|(proxyAddresses=smtp:$safe)(proxyAddresses=SMTP:$safe)(mail=$safe))"
        $search = @{
            LDAPFilter = $filter
            Server = $script:AccessSession.DomainController
            Credential = $script:AccessSession.Credential
        }
        if ($script:AccessSession.SearchBase) { $search.SearchBase = $script:AccessSession.SearchBase }
        $found = @(Get-ADUser @search -ErrorAction Stop)
        foreach ($user in $found) {
            if ($ExceptOnPremGuid -and ($user.ObjectGuid -eq $ExceptOnPremGuid)) { continue }
            return [string]$user.UserPrincipalName
        }
    }
    if ($script:AccessSession -and $script:AccessSession.GraphClientId) {
        $odata = $Address.Replace("'", "''")
        try {
            $cloud = @(Get-GraphUserByFilter "mail eq '$odata' or userPrincipalName eq '$odata'")
            foreach ($user in $cloud) {
                if ($ExceptEntraId -and ([guid]$user.id -eq $ExceptEntraId)) { continue }
                return [string]$user.userPrincipalName
            }
        } catch { }
    }
    $null
}

function Find-AccessUser {
    <#
    .SYNOPSIS
        Finds on-prem, Entra, or both representations of a person.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Query
    )
    if ($null -eq $script:AccessSession) { throw 'Connect first.' }
    $query = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) { throw 'Enter a name, username, or email.' }

    Import-Module ActiveDirectory -ErrorAction Stop
    Write-AccessInteraction -SystemName 'OnPremAD' -Action 'Search' -TargetRef $query -Detail 'Operator searched for a user.' -Outcome 'Succeeded'
    $adUsers = @()
    $guid = [guid]::Empty
    $properties = Get-AccessAdPropertyList
    $search = @{
        Server = $script:AccessSession.DomainController
        Credential = $script:AccessSession.Credential
        Properties = $properties
        ResultSetSize = 25
    }
    if ($script:AccessSession.SearchBase) { $search.SearchBase = $script:AccessSession.SearchBase }

    if ([guid]::TryParse($query, [ref]$guid)) {
        try { $adUsers = @(Get-ADUser -Identity $guid -Server $search.Server -Credential $search.Credential -Properties $properties) } catch { $adUsers = @() }
    } else {
        $safe = ConvertTo-LdapValue $query
        if ($query -match '@') {
            $filter = "(|(userPrincipalName=$safe)(mail=$safe)(proxyAddresses=smtp:$safe)(proxyAddresses=SMTP:$safe))"
        } else {
            $filter = "(|(sAMAccountName=$safe)(displayName=$safe)(cn=$safe)(anr=$safe))"
        }
        $adUsers = @(Get-ADUser -LDAPFilter $filter @search)
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($adUser in $adUsers) {
        $graphUser = Find-GraphUserForAd $adUser
        $record = ConvertTo-AccessUserFromAd -AdUser $adUser -GraphUser $graphUser
        if ($record.EntraObjectId) {
            $record.PerUserMfaState = Get-PerUserMfaState ([string]$record.EntraObjectId)
        }
        $results.Add($record)
    }

    if ($results.Count -eq 0) {
        $odata = $query.Replace("'", "''")
        $graphUsers = @()
        if ([guid]::TryParse($query, [ref]$guid)) {
            try { $graphUsers = @(Invoke-AccessGraph -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$guid") } catch { $graphUsers = @() }
        } else {
            try { $graphUsers = @(Get-GraphUserByFilter "userPrincipalName eq '$odata' or mail eq '$odata'") } catch { $graphUsers = @() }
        }
        foreach ($graphUser in $graphUsers) {
            if (-not $graphUser.id) { continue }
            $record = ConvertTo-AccessUserFromGraph $graphUser
            $record.PerUserMfaState = Get-PerUserMfaState ([string]$record.EntraObjectId)
            $results.Add($record)
        }
        if ($graphUsers.Count -gt 0) {
            Write-AccessInteraction -SystemName 'Entra' -Action 'Search' -TargetRef $query -Detail 'Cloud-only search.' -Outcome 'Succeeded'
        }
    }

    ,$results.ToArray()
}
