$script:PrivilegedGroupNames = @(
    'Domain Admins'
    'Enterprise Admins'
    'Schema Admins'
    'Administrators'
    'Account Operators'
    'Backup Operators'
    'Server Operators'
    'Print Operators'
    'DnsAdmins'
    'Group Policy Creator Owners'
)

function ConvertTo-LdapValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Value.ToCharArray()) {
        $code = [int]$char
        if ($char -eq '\' -or $char -eq '*' -or $char -eq '(' -or $char -eq ')' -or $code -eq 0) {
            [void]$builder.Append(('\{0:x2}' -f $code))
        } else {
            [void]$builder.Append($char)
        }
    }
    $builder.ToString()
}

function Get-ParentDistinguishedName {
    param([AllowNull()][string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return $null }
    $chars = $DistinguishedName.ToCharArray()
    $escaped = $false
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($escaped) { $escaped = $false; continue }
        if ($chars[$i] -eq '\') { $escaped = $true; continue }
        if ($chars[$i] -eq ',') { return $DistinguishedName.Substring($i + 1) }
    }
    $null
}

function ConvertTo-UacFlagList {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return @() }
    $number = [int]$Value
    $map = @{
        1 = 'SCRIPT'
        2 = 'ACCOUNTDISABLE'
        8 = 'HOMEDIR_REQUIRED'
        16 = 'LOCKOUT'
        32 = 'PASSWD_NOTREQD'
        64 = 'PASSWD_CANT_CHANGE'
        128 = 'ENCRYPTED_TEXT_PWD_ALLOWED'
        256 = 'TEMP_DUPLICATE_ACCOUNT'
        512 = 'NORMAL_ACCOUNT'
        2048 = 'INTERDOMAIN_TRUST_ACCOUNT'
        4096 = 'WORKSTATION_TRUST_ACCOUNT'
        8192 = 'SERVER_TRUST_ACCOUNT'
        65536 = 'DONT_EXPIRE_PASSWORD'
        131072 = 'MNS_LOGON_ACCOUNT'
        262144 = 'SMARTCARD_REQUIRED'
        524288 = 'TRUSTED_FOR_DELEGATION'
        1048576 = 'NOT_DELEGATED'
        2097152 = 'USE_DES_KEY_ONLY'
        4194304 = 'DONT_REQ_PREAUTH'
        8388608 = 'PASSWORD_EXPIRED'
        16777216 = 'TRUSTED_TO_AUTH_FOR_DELEGATION'
        33554432 = 'PARTIAL_SECRETS_ACCOUNT'
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($bit in $map.Keys) {
        if (($number -band [int]$bit) -eq [int]$bit) { $names.Add($map[$bit]) }
    }
    ,$names.ToArray()
}

function ConvertTo-ImmutableId {
    param([Parameter(Mandatory = $true)][guid]$ObjectGuid)
    [Convert]::ToBase64String($ObjectGuid.ToByteArray())
}

function ConvertFrom-ImmutableId {
    param([AllowNull()][string]$ImmutableId)
    if ([string]::IsNullOrWhiteSpace($ImmutableId)) { return $null }
    try { return [guid]([Convert]::FromBase64String($ImmutableId)) } catch { return $null }
}

function ConvertTo-FlagJson {
    param($Flags)
    if ($null -eq $Flags) { return $null }
    $names = @($Flags)
    if ($names.Count -eq 0) { return '[]' }
    ($names | ConvertTo-Json -Compress)
}

function Test-SamAccountNameValue {
    param([AllowNull()][string]$Sam)
    if ([string]::IsNullOrWhiteSpace($Sam)) { return $false }
    if ($Sam.Length -gt 20) { return $false }
    if ($Sam.EndsWith('.')) { return $false }
    if ($Sam -match '[\\/\[\]:;|=,+*?<>"@]') { return $false }
    $true
}

function Get-EmailLocalPart {
    param(
        [AllowNull()][string]$GivenName,
        [AllowNull()][string]$Surname,
        [ValidateSet('GivenDotSurname', 'SurnameDotGiven', 'FirstInitialSurname')]
        [string]$Pattern = 'GivenDotSurname'
    )
    $given = ([string]$GivenName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $surname = ([string]$Surname -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($given) -or [string]::IsNullOrWhiteSpace($surname)) {
        throw 'A first name and last name are required to build an email.'
    }
    switch ($Pattern) {
        'SurnameDotGiven' { return "$surname.$given" }
        'FirstInitialSurname' { return "$($given.Substring(0, 1))$surname" }
        default { return "$given.$surname" }
    }
}

function Get-PrimarySmtpAddress {
    param([string[]]$ProxyAddresses, [string]$Mail)
    foreach ($address in @($ProxyAddresses)) {
        if ($address -clike 'SMTP:*') { return $address.Substring(5) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Mail)) { return $Mail.Trim() }
    $null
}

function Update-PrimarySmtpAddress {
    param(
        [string[]]$ProxyAddresses,
        [Parameter(Mandatory = $true)][string]$NewMail,
        [bool]$KeepOldAsAlias = $true
    )
    $newMail = $NewMail.Trim()
    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$result.Add(('SMTP:' + $newMail))
    [void]$seen.Add($newMail)
    foreach ($address in @($ProxyAddresses)) {
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        if ($address -match '^(?i)smtp:(.+)$') {
            $mail = $Matches[1]
            if ($mail -eq $newMail) { continue }
            if (-not $KeepOldAsAlias -and $address -clike 'SMTP:*') { continue }
            if ($seen.Add(('smtp:' + $mail))) { [void]$result.Add(('smtp:' + $mail)) }
            continue
        }
        if ($seen.Add($address)) { [void]$result.Add($address) }
    }
    ,$result.ToArray()
}

function Add-ProxyAliasAddress {
    param(
        [string[]]$ProxyAddresses,
        [Parameter(Mandatory = $true)][string]$Alias,
        [switch]$MakePrimary
    )
    if ($Alias -notmatch '^(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$') {
        throw 'Alias must be an email address.'
    }
    $alias = $Alias.Trim()
    if ($MakePrimary) {
        return ,(Update-PrimarySmtpAddress -ProxyAddresses $ProxyAddresses -NewMail $alias -KeepOldAsAlias $true)
    }
    foreach ($address in @($ProxyAddresses)) {
        if ($address -match '^(?i)smtp:(.+)$' -and ($Matches[1] -eq $alias)) {
            return ,@($ProxyAddresses)
        }
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($address in @($ProxyAddresses)) {
        if (-not [string]::IsNullOrWhiteSpace($address)) { [void]$result.Add($address) }
    }
    [void]$result.Add(('smtp:' + $alias.ToLowerInvariant()))
    ,$result.ToArray()
}
