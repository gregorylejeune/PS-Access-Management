function Get-PlanParameter {
    param($Parameters, [string]$Name, $Default = $null)
    if ($null -eq $Parameters) { return $Default }
    if ($Parameters.Contains($Name) -and $null -ne $Parameters[$Name] -and -not ($Parameters[$Name] -is [string] -and [string]::IsNullOrWhiteSpace($Parameters[$Name]))) {
        return $Parameters[$Name]
    }
    $Default
}

function New-AccessPlan {
    param([string]$Operation, [string]$Error, [bool]$RequiresPrivilegedConfirm, [string[]]$Messages, $Changes, $Steps)
    [pscustomobject]@{
        Operation = $Operation
        Error = $Error
        RequiresPrivilegedConfirm = $RequiresPrivilegedConfirm
        Messages = @($Messages)
        Changes = @($Changes)
        Steps = @($Steps)
    }
}

function New-AccessChange {
    param([int]$Step, [string]$System, [string]$Attribute, $Before, $After, $FlagsBefore, $FlagsAfter)
    [pscustomobject]@{
        Step = $Step
        System = $System
        Attribute = $Attribute
        Before = $Before
        After = $After
        FlagsBefore = $FlagsBefore
        FlagsAfter = $FlagsAfter
    }
}

function Test-AccessPrivilegedUser {
    param($User)
    if ($User.AdminCount -ge 1) { return $true }
    foreach ($group in @($User.MemberOf)) {
        $name = [string]$group
        if ($name -match '(?i)^CN=([^,\\]+)') { $name = $Matches[1] }
        if ($script:PrivilegedGroupNames -contains $name) { return $true }
    }
    $false
}

function Test-AccessServiceAccountTarget {
    param($User)
    if ($null -eq $script:AccessSession) { return $false }
    $service = [string]$script:AccessSession.ServiceAccountUpn
    if ([string]::IsNullOrWhiteSpace($service)) { return $false }
    if ($User.UserPrincipalName -and ($User.UserPrincipalName -ieq $service)) { return $true }
    if ($User.SamAccountName -and ($service -match '\\(.+)$') -and ($User.SamAccountName -ieq $Matches[1])) { return $true }
    $false
}

function Get-DirectoryWriteSystem {
    param($User)
    if ($User.OnPremObjectGuid) { return 'OnPremAD' }
    'Entra'
}

function Add-DirectoryAttributeStep {
    param($User, [hashtable]$Replace, [System.Collections.Generic.List[object]]$Steps)
    $system = Get-DirectoryWriteSystem $User
    if ($system -eq 'OnPremAD') {
        $Steps.Add([pscustomobject]@{ Kind = 'SetAd'; Replace = $Replace })
        return
    }
    $body = @{}
    foreach ($key in @($Replace.Keys)) {
        switch ($key) {
            'givenName' { $body.givenName = $Replace[$key] }
            'sn' { $body.surname = $Replace[$key] }
            'displayName' { $body.displayName = $Replace[$key] }
            'mail' { $body.mail = $Replace[$key] }
            'mailNickname' { $body.mailNickname = $Replace[$key] }
            'proxyAddresses' { $body.proxyAddresses = @($Replace[$key]) }
            'sAMAccountName' { throw 'Cloud-only users do not have sAMAccountName. Change the user principal name instead.' }
            'userPrincipalName' { $body.userPrincipalName = $Replace[$key] }
            default { throw "Cloud write is not mapped for $key." }
        }
    }
    $Steps.Add([pscustomobject]@{ Kind = 'PatchGraph'; Body = $body })
}

function Get-AccessOperationPlan {
    <#
    .SYNOPSIS
        Builds the before/after plan for one operator action. This does not change the directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$User,
        [Parameter(Mandatory = $true)][ValidateSet(
            'AddAlias', 'ChangeName', 'ReEnable', 'Unblock', 'SetMfa', 'RegenerateEmail', 'MoveOu', 'ChangeUsername'
        )][string]$Operation,
        [hashtable]$Parameters = @{}
    )

    if (Test-AccessServiceAccountTarget $User) {
        return New-AccessPlan $Operation 'This tool will not change its own service account.' $false @() @() @()
    }

    $privileged = Test-AccessPrivilegedUser $User
    $messages = New-Object System.Collections.Generic.List[string]
    $changes = New-Object System.Collections.Generic.List[object]
    $steps = New-Object System.Collections.Generic.List[object]
    $system = Get-DirectoryWriteSystem $User

    switch ($Operation) {
        'AddAlias' {
            $alias = [string](Get-PlanParameter $Parameters 'Alias')
            $makePrimary = [bool](Get-PlanParameter $Parameters 'MakePrimary' $false)
            if ([string]::IsNullOrWhiteSpace($alias)) { return New-AccessPlan $Operation 'Enter an alias.' $privileged @() @() @() }
            $updated = Add-ProxyAliasAddress -ProxyAddresses @($User.ProxyAddresses) -Alias $alias -MakePrimary:$makePrimary
            $currentPrimary = Get-PrimarySmtpAddress @($User.ProxyAddresses) $User.Mail
            $nextPrimary = Get-PrimarySmtpAddress $updated $null
            if ($nextPrimary -and ($nextPrimary -ne $currentPrimary)) {
                $owner = Find-SmtpConflict -Address $nextPrimary -ExceptOnPremGuid $User.OnPremObjectGuid -ExceptEntraId $User.EntraObjectId
                if ($owner) { return New-AccessPlan $Operation "That address is already used by $owner." $privileged @() @() @() }
            } else {
                $owner = Find-SmtpConflict -Address $alias -ExceptOnPremGuid $User.OnPremObjectGuid -ExceptEntraId $User.EntraObjectId
                if ($owner) { return New-AccessPlan $Operation "That address is already used by $owner." $privileged @() @() @() }
            }
            if ((@($updated) -join '|') -eq (@($User.ProxyAddresses) -join '|')) {
                return New-AccessPlan $Operation 'That alias is already on the account.' $privileged @() @() @()
            }
            $changes.Add((New-AccessChange 0 $system 'proxyAddresses' (@($User.ProxyAddresses) -join '; ') (@($updated) -join '; ')))
            if ($nextPrimary -ne $currentPrimary) {
                $changes.Add((New-AccessChange 0 $system 'mail' $User.Mail $nextPrimary))
            }
            $replace = @{ proxyAddresses = $updated }
            if ($nextPrimary -ne $currentPrimary) { $replace.mail = $nextPrimary }
            Add-DirectoryAttributeStep -User $User -Replace $replace -Steps $steps
        }
        'ChangeName' {
            $given = [string](Get-PlanParameter $Parameters 'GivenName' $User.GivenName)
            $surname = [string](Get-PlanParameter $Parameters 'Surname' $User.Surname)
            $updateDisplay = [bool](Get-PlanParameter $Parameters 'UpdateDisplayName' $true)
            $renameCn = [bool](Get-PlanParameter $Parameters 'RenameCn' $false)
            if ($given -eq $User.GivenName -and $surname -eq $User.Surname -and -not $renameCn) {
                return New-AccessPlan $Operation 'The name is already set to those values.' $privileged @() @() @()
            }
            $replace = @{}
            if ($given -ne $User.GivenName) {
                $changes.Add((New-AccessChange 0 $system 'givenName' $User.GivenName $given))
                $replace.givenName = $given
            }
            if ($surname -ne $User.Surname) {
                $changes.Add((New-AccessChange 0 $system 'sn' $User.Surname $surname))
                $replace.sn = $surname
            }
            $display = ('{0} {1}' -f $given, $surname).Trim()
            if ($updateDisplay -and $display -and $display -ne $User.DisplayName) {
                $changes.Add((New-AccessChange 0 $system 'displayName' $User.DisplayName $display))
                $replace.displayName = $display
            }
            if ($replace.Count -gt 0) { Add-DirectoryAttributeStep -User $User -Replace $replace -Steps $steps }
            if ($renameCn) {
                if ($system -ne 'OnPremAD') { return New-AccessPlan $Operation 'Cloud-only accounts do not have an on-prem common name to rename.' $privileged @() @() @() }
                if ($display -match '[\\/,=+<>#;"]') { return New-AccessPlan $Operation 'The new common name contains a character AD will not accept.' $privileged @() @() @() }
                $changes.Add((New-AccessChange 1 'OnPremAD' 'cn' $User.DisplayName $display))
                $steps.Add([pscustomobject]@{ Kind = 'RenameAd'; NewName = $display })
            }
        }
        'ReEnable' {
            $messages.Add('The password is not changed. The person resets it in the self-service portal.')
            if ($User.PasswordExpired) { $messages.Add('The password is expired. Enabling the account does not clear that. The self-service portal still has to reset it.') }
            if ($system -eq 'OnPremAD') {
                if (-not $User.EnabledOnPrem) {
                    $afterFlags = ConvertTo-UacFlagList ($User.UserAccountControl -band (-bnot 2))
                    $changes.Add((New-AccessChange 0 'OnPremAD' 'userAccountControl' $User.UserAccountControl ($User.UserAccountControl -band (-bnot 2)) (ConvertTo-FlagJson $User.UacFlags) (ConvertTo-FlagJson $afterFlags)))
                    $steps.Add([pscustomobject]@{ Kind = 'EnableAd' })
                }
                if ($User.LockedOut) {
                    $changes.Add((New-AccessChange 1 'OnPremAD' 'lockoutTime' 'locked' 'unlocked' (ConvertTo-FlagJson $User.ComputedUacFlags) '[]'))
                    $steps.Add([pscustomobject]@{ Kind = 'UnlockAd' })
                }
                if ($User.OnPremisesSyncEnabled) { $messages.Add('This account is synced. Entra sign-in follows the on-prem account after the next sync.') }
            } elseif ($User.EnabledEntra -eq $false) {
                $changes.Add((New-AccessChange 0 'Entra' 'accountEnabled' 'false' 'true'))
                $steps.Add([pscustomobject]@{ Kind = 'PatchGraph'; Body = @{ accountEnabled = $true } })
            }
            if ($changes.Count -eq 0) { return New-AccessPlan $Operation 'The account is already enabled and unlocked.' $privileged @($messages) @() @() }
        }
        'Unblock' {
            if ($system -eq 'OnPremAD' -and -not $User.EnabledOnPrem) {
                return New-AccessPlan $Operation 'The account is disabled. Use Re-enable. Unblock only clears a lockout.' $privileged @() @() @()
            }
            if ($system -eq 'OnPremAD' -and $User.LockedOut) {
                $changes.Add((New-AccessChange 0 'OnPremAD' 'lockoutTime' 'locked' 'unlocked' (ConvertTo-FlagJson $User.ComputedUacFlags) '[]'))
                $steps.Add([pscustomobject]@{ Kind = 'UnlockAd' })
            } elseif ($system -eq 'Entra' -and $User.EnabledEntra -eq $false) {
                $changes.Add((New-AccessChange 0 'Entra' 'accountEnabled' 'false' 'true'))
                $steps.Add([pscustomobject]@{ Kind = 'PatchGraph'; Body = @{ accountEnabled = $true } })
                $messages.Add('Cloud-only sign-in block will be cleared. No password is set.')
            }
            if ($changes.Count -eq 0) { return New-AccessPlan $Operation 'The account is not locked.' $privileged @() @() @() }
        }
        'SetMfa' {
            $mode = [string](Get-PlanParameter $Parameters 'Mode' 'PerUserMfaState')
            if ($mode -eq 'ExtensionAttribute') {
                $attribute = [string](Get-PlanParameter $Parameters 'ExtensionAttribute')
                $value = [string](Get-PlanParameter $Parameters 'ExtensionValue')
                if ($attribute -notmatch '^extensionAttribute([1-9]|1[0-5])$') {
                    return New-AccessPlan $Operation 'Choose extensionAttribute1 through extensionAttribute15.' $privileged @() @() @()
                }
                if (-not $User.OnPremObjectGuid) { return New-AccessPlan $Operation 'Extension attributes are written on-prem. This user has no on-prem account.' $privileged @() @() @() }
                $before = $null
                if ($User.ExtensionAttributes.Contains($attribute)) { $before = [string]$User.ExtensionAttributes[$attribute] }
                if ($before -eq $value) { return New-AccessPlan $Operation 'That extension attribute is already set to that value.' $privileged @() @() @() }
                $changes.Add((New-AccessChange 0 'OnPremAD' $attribute $before $value))
                $steps.Add([pscustomobject]@{ Kind = 'SetAd'; Replace = @{ $attribute = $value } })
            } else {
                $state = [string](Get-PlanParameter $Parameters 'State')
                if (@('disabled', 'enabled', 'enforced') -notcontains $state) {
                    return New-AccessPlan $Operation 'Choose a per-user MFA state of disabled, enabled, or enforced.' $privileged @() @() @()
                }
                if (-not $User.EntraObjectId) { return New-AccessPlan $Operation 'This user is not in Entra, so there is no cloud MFA state to change.' $privileged @() @() @() }
                if ($User.PerUserMfaState -eq $state) { return New-AccessPlan $Operation 'Per-user MFA is already in that state.' $privileged @() @() @() }
                $changes.Add((New-AccessChange 0 'Entra' 'perUserMfaState' $User.PerUserMfaState $state))
                $steps.Add([pscustomobject]@{ Kind = 'PatchMfa'; State = $state })
                $messages.Add('This changes the legacy per-user MFA state. It does not remove registered authentication methods.')
            }
        }
        'RegenerateEmail' {
            $pattern = [string](Get-PlanParameter $Parameters 'Pattern' 'GivenDotSurname')
            $domain = [string](Get-PlanParameter $Parameters 'Domain')
            $keepOld = [bool](Get-PlanParameter $Parameters 'KeepOldAsAlias' $true)
            $current = Get-PrimarySmtpAddress @($User.ProxyAddresses) $User.Mail
            if ([string]::IsNullOrWhiteSpace($domain)) {
                if ($current -match '@(.+)$') { $domain = $Matches[1] } else { return New-AccessPlan $Operation 'Enter the email domain. This account has no primary SMTP address to copy it from.' $privileged @() @() @() }
            }
            $local = Get-EmailLocalPart -GivenName $User.GivenName -Surname $User.Surname -Pattern $pattern
            $candidate = "$local@$domain"
            $suffix = 2
            while ($owner = Find-SmtpConflict -Address $candidate -ExceptOnPremGuid $User.OnPremObjectGuid -ExceptEntraId $User.EntraObjectId) {
                if ($suffix -gt 50) { return New-AccessPlan $Operation "Could not find a free address based on $local@$domain." $privileged @() @() @() }
                $candidate = "$local$suffix@$domain"
                $suffix++
            }
            if ($candidate -eq $current) { return New-AccessPlan $Operation 'The generated address is already the primary SMTP address.' $privileged @() @() @() }
            $updated = Update-PrimarySmtpAddress -ProxyAddresses @($User.ProxyAddresses) -NewMail $candidate -KeepOldAsAlias $keepOld
            $nickname = ($candidate.Split('@')[0])
            $changes.Add((New-AccessChange 0 $system 'proxyAddresses' (@($User.ProxyAddresses) -join '; ') (@($updated) -join '; ')))
            $changes.Add((New-AccessChange 0 $system 'mail' $User.Mail $candidate))
            $changes.Add((New-AccessChange 0 $system 'mailNickname' $User.MailNickname $nickname))
            Add-DirectoryAttributeStep -User $User -Replace @{ proxyAddresses = $updated; mail = $candidate; mailNickname = $nickname } -Steps $steps
            $messages.Add('The old primary address stays as a secondary alias unless you turned that off. Profile paths are not renamed.')
        }
        'MoveOu' {
            $target = [string](Get-PlanParameter $Parameters 'TargetOu')
            if ($target -notmatch '(?i)DC=') { return New-AccessPlan $Operation 'Enter the target OU as a distinguished name.' $privileged @() @() @() }
            if ($system -ne 'OnPremAD') { return New-AccessPlan $Operation 'Cloud-only users do not have an on-prem OU.' $privileged @() @() @() }
            if ($target -eq $User.OrganizationalUnit) { return New-AccessPlan $Operation 'The user is already in that OU.' $privileged @() @() @() }
            $changes.Add((New-AccessChange 0 'OnPremAD' 'distinguishedName' $User.DistinguishedName $null))
            $steps.Add([pscustomobject]@{ Kind = 'MoveAd'; TargetPath = $target })
            $messages.Add('The new distinguished name is read back after the move and stored in the audit row.')
        }
        'ChangeUsername' {
            $newSam = [string](Get-PlanParameter $Parameters 'NewSamAccountName')
            $newUpn = [string](Get-PlanParameter $Parameters 'NewUserPrincipalName')
            $updateMail = [bool](Get-PlanParameter $Parameters 'UpdateMail' $false)
            $keepAlias = [bool](Get-PlanParameter $Parameters 'KeepOldUpnAsAlias' $true)
            if ([string]::IsNullOrWhiteSpace($newSam) -and [string]::IsNullOrWhiteSpace($newUpn)) {
                return New-AccessPlan $Operation 'Enter a new username, a new user principal name, or both.' $privileged @() @() @()
            }
            $replace = @{}
            if ($newSam -and ($newSam -ne $User.SamAccountName)) {
                if (-not (Test-SamAccountNameValue $newSam)) { return New-AccessPlan $Operation 'sAMAccountName must be 1-20 characters and cannot contain spaces or \/[]:;|=,+*?<>"@.' $privileged @() @() @() }
                if ($system -ne 'OnPremAD') { return New-AccessPlan $Operation 'Cloud-only users do not have sAMAccountName.' $privileged @() @() @() }
                $safeSam = ConvertTo-LdapValue $newSam
                if ($script:AccessSession -and $script:AccessSession.Credential) {
                    $taken = @(Get-ADUser -LDAPFilter "(sAMAccountName=$safeSam)" -Server $script:AccessSession.DomainController -Credential $script:AccessSession.Credential -ErrorAction Stop)
                    foreach ($existing in $taken) {
                        if ($existing.ObjectGuid -ne $User.OnPremObjectGuid) { return New-AccessPlan $Operation "sAMAccountName $newSam is already in use." $privileged @() @() @() }
                    }
                }
                $changes.Add((New-AccessChange 0 $system 'sAMAccountName' $User.SamAccountName $newSam))
                $replace.sAMAccountName = $newSam
            }
            if ($newUpn -and ($newUpn -ne $User.UserPrincipalName)) {
                if ($newUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return New-AccessPlan $Operation 'The new user principal name must look like a name@domain.' $privileged @() @() @() }
                $owner = Find-SmtpConflict -Address $newUpn -ExceptOnPremGuid $User.OnPremObjectGuid -ExceptEntraId $User.EntraObjectId
                if ($owner) { return New-AccessPlan $Operation "That user principal name is already used by $owner." $privileged @() @() @() }
                $changes.Add((New-AccessChange 0 $system 'userPrincipalName' $User.UserPrincipalName $newUpn))
                $replace.userPrincipalName = $newUpn
                if ($keepAlias -and $User.UserPrincipalName -match '@') {
                    $updated = Add-ProxyAliasAddress -ProxyAddresses @($User.ProxyAddresses) -Alias $User.UserPrincipalName
                    $changes.Add((New-AccessChange 0 $system 'proxyAddresses' (@($User.ProxyAddresses) -join '; ') (@($updated) -join '; ')))
                    $replace.proxyAddresses = $updated
                }
                if ($updateMail) {
                    $updatedMail = Update-PrimarySmtpAddress -ProxyAddresses $(if ($replace.proxyAddresses) { $replace.proxyAddresses } else { @($User.ProxyAddresses) }) -NewMail $newUpn -KeepOldAsAlias $true
                    $changes.Add((New-AccessChange 0 $system 'mail' $User.Mail $newUpn))
                    $replace.mail = $newUpn
                    $replace.proxyAddresses = $updatedMail
                }
            }
            if ($replace.Count -eq 0) { return New-AccessPlan $Operation 'The username is already set to those values.' $privileged @() @() @() }
            Add-DirectoryAttributeStep -User $User -Replace $replace -Steps $steps
            $messages.Add('Home folders, profile paths, and existing sessions are not renamed. The person will need to sign in with the new name.')
        }
    }

    if ($steps.Count -eq 0) {
        return New-AccessPlan $Operation 'Nothing would change.' $privileged @($messages) @() @()
    }
    New-AccessPlan $Operation $null $privileged @($messages) $changes.ToArray() $steps.ToArray()
}
