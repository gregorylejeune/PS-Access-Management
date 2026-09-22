function Write-AccessInteraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SystemName,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$TargetRef,
        [string]$Detail,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [string]$ErrorMessage
    )
    if ($null -eq $script:AccessSession) { return }
    Invoke-AccessSql -ConnectionString $script:AccessSession.AuditConnectionString -NonQuery -Sql @"
INSERT INTO dbo.InteractionLog
    (SessionId, OccurredUtc, SystemName, Action, TargetRef, Detail, Outcome, ErrorMessage)
VALUES
    (@SessionId, @OccurredUtc, @SystemName, @Action, @TargetRef, @Detail, @Outcome, @ErrorMessage);
"@ -Parameters @{
        SessionId = $script:AccessSession.SessionId
        OccurredUtc = [DateTime]::UtcNow
        SystemName = $SystemName
        Action = $Action
        TargetRef = $TargetRef
        Detail = $Detail
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
    } | Out-Null
}

function Add-AccessChangeRow {
    param(
        [Parameter(Mandatory = $true)][guid]$CorrelationId,
        [Parameter(Mandatory = $true)][string]$SystemName,
        [Parameter(Mandatory = $true)][string]$Operation,
        $User,
        [Parameter(Mandatory = $true)][string]$AttributeName,
        $ValueBefore,
        $ValueAfter,
        $FlagsBefore,
        $FlagsAfter,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [string]$ErrorMessage
    )
    $beforeText = ConvertTo-AuditValue -AttributeName $AttributeName -Value $ValueBefore
    $afterText = ConvertTo-AuditValue -AttributeName $AttributeName -Value $ValueAfter
    $id = Invoke-AccessSql -ConnectionString $script:AccessSession.AuditConnectionString -Scalar -Sql @"
INSERT INTO dbo.DirectoryChange
    (SessionId, CorrelationId, OccurredUtc, SystemName, Operation, TargetUpn, TargetOnPremGuid, TargetEntraId, TargetDn,
     AttributeName, ValueBefore, ValueAfter, FlagsBefore, FlagsAfter, Outcome, ErrorMessage)
OUTPUT INSERTED.ChangeId
VALUES
    (@SessionId, @CorrelationId, @OccurredUtc, @SystemName, @Operation, @TargetUpn, @TargetOnPremGuid, @TargetEntraId, @TargetDn,
     @AttributeName, @ValueBefore, @ValueAfter, @FlagsBefore, @FlagsAfter, @Outcome, @ErrorMessage);
"@ -Parameters @{
        SessionId = $script:AccessSession.SessionId
        CorrelationId = $CorrelationId
        OccurredUtc = [DateTime]::UtcNow
        SystemName = $SystemName
        Operation = $Operation
        TargetUpn = $User.UserPrincipalName
        TargetOnPremGuid = $User.OnPremObjectGuid
        TargetEntraId = $User.EntraObjectId
        TargetDn = $User.DistinguishedName
        AttributeName = $AttributeName
        ValueBefore = $beforeText
        ValueAfter = $afterText
        FlagsBefore = $FlagsBefore
        FlagsAfter = $FlagsAfter
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
    }
    [int64]$id
}

function Set-AccessChangeOutcome {
    param(
        [Parameter(Mandatory = $true)][int64]$ChangeId,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [string]$ErrorMessage,
        $ValueAfter,
        [string]$AttributeName,
        $FlagsAfter
    )
    $afterText = $ValueAfter
    if ($AttributeName) {
        $afterText = ConvertTo-AuditValue -AttributeName $AttributeName -Value $ValueAfter
    }
    Invoke-AccessSql -ConnectionString $script:AccessSession.AuditConnectionString -NonQuery -Sql @"
UPDATE dbo.DirectoryChange
SET Outcome = @Outcome,
    ErrorMessage = @ErrorMessage,
    ValueAfter = COALESCE(@ValueAfter, ValueAfter),
    FlagsAfter = COALESCE(@FlagsAfter, FlagsAfter)
WHERE ChangeId = @ChangeId;
"@ -Parameters @{
        ChangeId = $ChangeId
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
        ValueAfter = $afterText
        FlagsAfter = $FlagsAfter
    } | Out-Null
}
