$script:StandardAttributeNames = @(
    'accountnamehistory', 'admincount', 'badpasswordtime', 'badpwdcount', 'c', 'canonicalname', 'cn', 'co', 'codepage',
    'company', 'countrycode', 'department', 'description', 'directreports', 'displayname', 'distinguishedname',
    'division', 'employeeid', 'employeenumber', 'employeetype', 'enabled', 'facsimiletelephonenumber', 'givenname',
    'homedirectory', 'homedrive', 'homephone', 'info', 'initials', 'instancetype', 'ipphone', 'l', 'lastknownparent',
    'lastlogoff', 'lastlogon', 'lastlogontimestamp', 'lockouttime', 'logoncount', 'mail', 'mailnickname', 'managedobjects',
    'manager', 'memberof', 'mobile', 'name', 'objectcategory', 'objectclass', 'objectguid', 'objectsid', 'ou',
    'pager', 'physicaldeliveryofficename', 'postalcode', 'postofficebox', 'primarygroupid', 'profilepath',
    'proxyaddresses', 'pwdlastset', 'samaccountname', 'samaccounttype', 'scriptpath', 'sidhistory', 'sn', 'st',
    'streetaddress', 'telephonenumber', 'title', 'useraccountcontrol', 'userprincipalname', 'usnchanged', 'usncreated',
    'whenchanged', 'whencreated', 'wwwhomepage', 'targetaddress', 'legacyexchangedn', 'showinaddressbook',
    'msexchhidefromaddresslists', 'msexchmailboxguid', 'msexchrecipientdisplaytype', 'msexchrecipienttypedetails',
    'msexchremoterecipienttype', 'msexchversion', 'msexchumdtmfmap', 'msds-user-account-control-computed',
    'passwordexpired', 'passwordneverexpires', 'passwordnotrequired', 'cannotchangepassword', 'lockedout',
    'accountenabled', 'accountenabled', 'businessphones', 'city', 'companyname', 'country', 'createddatetime',
    'employeehiredate', 'employeeleavedatetime', 'employeetype', 'faxnumber', 'id', 'identities', 'imaddresses',
    'jobtitle', 'mailnickname', 'mobilephone', 'officelocation', 'onpremisesdistinguishedname', 'onpremisesdomainname',
    'onpremisesimmutableid', 'onpremiseslastsyncdatetime', 'onpremisessamaccountname', 'onpremisessecurityidentifier',
    'onpremisessyncenabled', 'onpremisesuserprincipalname', 'othermails', 'postalcode', 'preferredlanguage',
    'provisionedplans', 'assignedlicenses', 'assignedplans', 'state', 'streetaddress', 'surname', 'usagelocation',
    'usertype', 'perusermfastate'
)

$script:SensitiveAttributePattern = '(?i)password|passwd|unicodePwd|userPassword|clientSecret|secret|token|\bpin\b|supplementalCredentials|unixUserPassword'
$script:BinaryAttributePattern = '(?i)^(thumbnailPhoto|thumbnailLogo|jpegPhoto|userCertificate|userSMIMECertificate|mSMQSignCertificates|mSMQDigests|msExchSafeSendersHash|msExchBlockedSendersHash|msExchUMSpokenName|nTSecurityDescriptor|msDS-Cached-Membership|msDS-Site-Affinity|replPropertyMetaData|dnsRecord)$'

function Get-CatalogAttributeClass {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -match '^(?i)extensionAttribute\d+$' -or $Name -match '^(?i)^extension_') { return 'Extension' }
    if ($Name -match '^(?i)^(msExch|msDS-|ms-DS-|msRTCSIP|msTS|terminalServices)') { return 'Extended' }
    if ($script:StandardAttributeNames -contains $Name.ToLowerInvariant()) { return 'Standard' }
    'Custom'
}

function ConvertTo-StableJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [ValueType] -or $Value -is [datetime] -or $Value -is [guid]) {
        return ($Value | ConvertTo-Json -Compress -Depth 4)
    }
    $items = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [datetime]) { $items += $item.ToUniversalTime().ToString('o') }
        elseif ($item -is [byte[]]) { $items += ('binary:' + $item.Length) }
        else { $items += [string]$item }
    }
    if ($items.Count -eq 1) { return '[' + ($items[0] | ConvertTo-Json -Compress) + ']' }
    return ($items | ConvertTo-Json -Compress -Depth 4)
}

function New-CatalogAttribute {
    param([string]$Name, [string]$Class, [string]$Json)
    $hash = Get-Sha256Text $Json
    [pscustomobject]@{
        Name = $Name
        Class = $Class
        ValueJson = $Json
        ValueSha256 = $hash
    }
}

function ConvertTo-CatalogAttributes {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    $class = Get-CatalogAttributeClass $Name
    if ($Name -match $script:SensitiveAttributePattern) {
        if ($null -eq $Value -or [string]::IsNullOrEmpty([string]$Value)) { return @() }
        return ,@(New-CatalogAttribute $Name $class '"[REDACTED]"')
    }
    if ($Name -match $script:BinaryAttributePattern -or $Value -is [byte[]]) {
        $length = 0
        $digest = ''
        if ($Value -is [byte[]]) {
            $length = $Value.Length
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $digest = (($sha.ComputeHash($Value) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
        }
        $json = (@{ kind = 'binary-omitted'; byteLength = $length; sha256 = $digest } | ConvertTo-Json -Compress)
        return ,@(New-CatalogAttribute $Name $class $json)
    }
    if ($null -eq $Value) { return @() }
    if ($Value -is [datetime]) {
        return ,@(New-CatalogAttribute $Name $class (ConvertTo-StableJson $Value.ToUniversalTime().ToString('o')))
    }
    $json = ConvertTo-StableJson $Value
    ,@(New-CatalogAttribute $Name $class $json)
}

function Get-AdCatalogAttributes {
    param($User)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($User.PropertyNames)) {
        foreach ($row in @(ConvertTo-CatalogAttributes -Name $name -Value $User.$name)) {
            if ($row) { $rows.Add($row) }
        }
    }
    ,$rows.ToArray()
}

function Get-GraphCatalogAttributes {
    param($User)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($prop in $User.PSObject.Properties) {
        if ($prop.Name -eq '@odata.context' -or $prop.Name -eq '@odata.id' -or $prop.Name -eq 'onPremisesExtensionAttributes') { continue }
        foreach ($row in @(ConvertTo-CatalogAttributes -Name $prop.Name -Value $prop.Value)) {
            if ($row) { $rows.Add($row) }
        }
    }
    if ($User.onPremisesExtensionAttributes) {
        foreach ($prop in $User.onPremisesExtensionAttributes.PSObject.Properties) {
            if ($prop.Name -like '@*') { continue }
            foreach ($row in @(ConvertTo-CatalogAttributes -Name $prop.Name -Value $prop.Value)) {
                if ($row) { $rows.Add($row) }
            }
        }
    }
    ,$rows.ToArray()
}
