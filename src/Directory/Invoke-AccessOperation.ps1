function Invoke-AccessPlanStep {
    param($User, $Step)
    $identity = [string]$User.OnPremObjectGuid
    $server = $script:AccessSession.DomainController
    $credential = $script:AccessSession.Credential
    switch ($Step.Kind) {
        'SetAd' {
            $set = @{
                Identity = $identity
                Server = $server
                Credential = $credential
            }
            if ($Step.Replace) { $set.Replace = $Step.Replace }
            Set-ADUser @set
        }
        'EnableAd' { Enable-ADAccount -Identity $identity -Server $server -Credential $credential }
        'UnlockAd' { Unlock-ADAccount -Identity $identity -Server $server -Credential $credential }
        'MoveAd' {
            Get-ADOrganizationalUnit -Identity $Step.TargetPath -Server $server -Credential $credential | Out-Null
            Move-ADObject -Identity $identity -TargetPath $Step.TargetPath -Server $server -Credential $credential
        }
        'RenameAd' { Rename-ADObject -Identity $identity -NewName $Step.NewName -Server $server -Credential $credential }
        'PatchGraph' {
            if (-not $User.EntraObjectId) { throw 'This user has no Entra object id.' }
            Invoke-AccessGraph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($User.EntraObjectId)" -Body $Step.Body
        }
        'PatchMfa' {
            if (-not $User.EntraObjectId) { throw 'This user has no Entra object id.' }
            $body = @{ perUserMfaState = $Step.State }
            try {
                Invoke-AccessGraph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($User.EntraObjectId)/authentication/requirements" -Body $body
            } catch {
                Invoke-AccessGraph -Method PATCH -Uri "https://graph.microsoft.com/beta/users/$($User.EntraObjectId)/authentication/requirements" -Body $body
            }
        }
        default { throw "Unknown plan step $($Step.Kind)." }
    }
}

function Get-RefreshedAccessUser {
    param($User)
    $query = if ($User.OnPremObjectGuid) { [string]$User.OnPremObjectGuid } else { [string]$User.EntraObjectId }
    $found = @(Find-AccessUser -Query $query)
    foreach ($candidate in $found) {
        if ($User.OnPremObjectGuid -and $candidate.OnPremObjectGuid -eq $User.OnPremObjectGuid) { return $candidate }
        if ($User.EntraObjectId -and $candidate.EntraObjectId -eq $User.EntraObjectId) { return $candidate }
    }
    if ($found.Count -eq 1) { return $found[0] }
    throw 'The user could not be read back. No change was made for this attempt.'
}

function Invoke-AccessOperation {
    <#
    .SYNOPSIS
        Applies a previewed account change and writes a before/after audit row for every attribute.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]$User,
        [Parameter(Mandatory = $true)][string]$Operation,
        [hashtable]$Parameters = @{},
        [switch]$PrivilegedConfirmed
    )

    if ($null -eq $script:AccessSession) { throw 'Connect first.' }
    $live = Get-RefreshedAccessUser $User
    $plan = Get-AccessOperationPlan -User $live -Operation $Operation -Parameters $Parameters
    if ($plan.Error) { throw $plan.Error }
    if ($plan.RequiresPrivilegedConfirm -and -not $PrivilegedConfirmed) {
        throw 'This is a privileged account. Confirm it explicitly before applying.'
    }
    $target = if ($live.UserPrincipalName) { $live.UserPrincipalName } else { [string]$live.OnPremObjectGuid }
    if (-not $PSCmdlet.ShouldProcess($target, $Operation)) { return $plan }

    $correlationId = [guid]::NewGuid()
    $index = 0
    foreach ($step in @($plan.Steps)) {
        $rows = @($plan.Changes | Where-Object { $_.Step -eq $index })
        $ids = @()
        foreach ($change in $rows) {
            $ids += Add-AccessChangeRow -CorrelationId $correlationId -SystemName $change.System -Operation $Operation -User $live -AttributeName $change.Attribute -ValueBefore $change.Before -ValueAfter $change.After -FlagsBefore $change.FlagsBefore -FlagsAfter $change.FlagsAfter -Outcome 'Pending'
        }
        try {
            Invoke-AccessPlanStep -User $live -Step $step
            Write-AccessInteraction -SystemName $(if ($step.Kind -like 'Patch*') { 'Entra' } else { 'OnPremAD' }) -Action $Operation -TargetRef $target -Detail $step.Kind -Outcome 'Succeeded'
            $readBack = $null
            if ($step.Kind -eq 'MoveAd') { $readBack = Get-RefreshedAccessUser $live }
            $offset = 0
            foreach ($change in $rows) {
                $after = $change.After
                if ($readBack -and $change.Attribute -eq 'distinguishedName') { $after = $readBack.DistinguishedName }
                Set-AccessChangeOutcome -ChangeId $ids[$offset] -Outcome 'Succeeded' -AttributeName $change.Attribute -ValueAfter $after -FlagsAfter $change.FlagsAfter
                $offset++
            }
        } catch {
            $message = $_.Exception.Message
            Write-AccessInteraction -SystemName 'OnPremAD' -Action $Operation -TargetRef $target -Detail $step.Kind -Outcome 'Failed' -ErrorMessage $message
            $offset = 0
            foreach ($change in $rows) {
                Set-AccessChangeOutcome -ChangeId $ids[$offset] -Outcome 'Failed' -ErrorMessage $message -AttributeName $change.Attribute -ValueAfter $change.After
                $offset++
            }
            throw "The directory change failed after audit row $correlationId. $message"
        }
        $index++
    }

    [pscustomobject]@{
        CorrelationId = $correlationId
        Plan = $plan
        User = $live
    }
}
