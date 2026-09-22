function Add-CatalogIndex {
    param($Index, [string]$Key, $Value)
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    $name = $Key.ToLowerInvariant()
    if (-not $Index.ContainsKey($name)) {
        $Index[$name] = New-Object System.Collections.Generic.List[object]
    }
    $Index[$name].Add($Value)
}

function Get-EntraCatalogUsers {
    param([System.Collections.Generic.List[string]]$Warnings, [int]$MaxUsers)
    $select = @(
        'id', 'userPrincipalName', 'displayName', 'givenName', 'surname', 'mail', 'mailNickname', 'proxyAddresses',
        'otherMails', 'accountEnabled', 'createdDateTime', 'userType', 'onPremisesSamAccountName',
        'onPremisesUserPrincipalName', 'onPremisesDomainName', 'onPremisesDistinguishedName', 'onPremisesImmutableId',
        'onPremisesSyncEnabled', 'onPremisesLastSyncDateTime', 'onPremisesSecurityIdentifier',
        'onPremisesExtensionAttributes', 'jobTitle', 'department', 'companyName', 'officeLocation', 'city', 'state',
        'country', 'streetAddress', 'postalCode', 'mobilePhone', 'businessPhones', 'employeeId', 'employeeType',
        'usageLocation', 'preferredLanguage', 'faxNumber', 'imAddresses', 'assignedLicenses', 'assignedPlans'
    ) -join ','
    $extra = ''
    try {
        $available = Invoke-AccessGraph -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getAvailableExtensionProperties' -Body @{ isSyncedFromOnPremises = $false }
        $names = @($available.value | ForEach-Object { $_.name } | Where-Object { $_ })
        if ($names.Count -gt 0 -and $names.Count -le 20) { $extra = ',' + ($names -join ',') }
        elseif ($names.Count -gt 20) { $Warnings.Add('Directory extensions were discovered but left out of the main select because there are more than 20. extensionAttribute1-15 are still cataloged.') }
    } catch {
        $Warnings.Add('Directory extension discovery was skipped. Standard Graph properties and extensionAttribute1-15 are still cataloged.')
    }
    $users = New-Object System.Collections.Generic.List[object]
    $uri = 'https://graph.microsoft.com/v1.0/users?$select=' + [uri]::EscapeDataString($select + $extra) + '&$top=200'
    while ($uri) {
        $page = Invoke-AccessGraph -Method GET -Uri $uri
        foreach ($user in @($page.value)) {
            if ($user.id) { $users.Add($user) }
            if ($MaxUsers -gt 0 -and $users.Count -ge $MaxUsers) { return ,$users.ToArray() }
        }
        $uri = [string]$page.'@odata.nextLink'
    }
    ,$users.ToArray()
}

function Save-CatalogIdentity {
    param($ConnectionString, $RunId, $Record)
    $existing = $null
    if ($Record.OnPremObjectGuid) {
        $existing = Invoke-AccessSql -ConnectionString $ConnectionString -Scalar -Sql 'SELECT IdentityId FROM dbo.IdentityRecord WHERE OnPremObjectGuid = @OnPremObjectGuid' -Parameters @{ OnPremObjectGuid = $Record.OnPremObjectGuid }
    }
    if (-not $existing -and $Record.EntraObjectId) {
        $existing = Invoke-AccessSql -ConnectionString $ConnectionString -Scalar -Sql 'SELECT IdentityId FROM dbo.IdentityRecord WHERE EntraObjectId = @EntraObjectId' -Parameters @{ EntraObjectId = $Record.EntraObjectId }
    }
    $parameters = @{
        MatchKey = $Record.MatchKey
        Alignment = $Record.Alignment
        UserPrincipalName = $Record.UserPrincipalName
        OnPremObjectGuid = $Record.OnPremObjectGuid
        EntraObjectId = $Record.EntraObjectId
        OnPremSid = $Record.OnPremSid
        ImmutableId = $Record.ImmutableId
        OnPremSam = $Record.OnPremSam
        DisplayName = $Record.DisplayName
        EnabledOnPrem = $Record.EnabledOnPrem
        EnabledEntra = $Record.EnabledEntra
        LastCatalogRunId = $RunId
        LastCatalogedUtc = [DateTime]::UtcNow
    }
    if ($existing) {
        $parameters.IdentityId = [int64]$existing
        Invoke-AccessSql -ConnectionString $ConnectionString -NonQuery -Sql @"
UPDATE dbo.IdentityRecord
SET MatchKey = @MatchKey, Alignment = @Alignment, UserPrincipalName = @UserPrincipalName,
    OnPremObjectGuid = @OnPremObjectGuid, EntraObjectId = @EntraObjectId, OnPremSid = @OnPremSid,
    ImmutableId = @ImmutableId, OnPremSam = @OnPremSam, DisplayName = @DisplayName,
    EnabledOnPrem = @EnabledOnPrem, EnabledEntra = @EnabledEntra,
    LastCatalogRunId = @LastCatalogRunId, LastCatalogedUtc = @LastCatalogedUtc
WHERE IdentityId = @IdentityId;
"@ -Parameters $parameters | Out-Null
        return [int64]$existing
    }
    $inserted = Invoke-AccessSql -ConnectionString $ConnectionString -Scalar -Sql @"
INSERT INTO dbo.IdentityRecord
    (MatchKey, Alignment, UserPrincipalName, OnPremObjectGuid, EntraObjectId, OnPremSid, ImmutableId, OnPremSam,
     DisplayName, EnabledOnPrem, EnabledEntra, LastCatalogRunId, LastCatalogedUtc)
OUTPUT INSERTED.IdentityId
VALUES
    (@MatchKey, @Alignment, @UserPrincipalName, @OnPremObjectGuid, @EntraObjectId, @OnPremSid, @ImmutableId, @OnPremSam,
     @DisplayName, @EnabledOnPrem, @EnabledEntra, @LastCatalogRunId, @LastCatalogedUtc);
"@ -Parameters $parameters
    [int64]$inserted
}

function Publish-CatalogAttributes {
    param($ConnectionString, [guid]$RunId, $Rows)
    $pending = @($Rows)
    if ($pending.Count -eq 0) { return }
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('CatalogRunId', [guid])
    [void]$table.Columns.Add('IdentityId', [int64])
    [void]$table.Columns.Add('SourceSystem', [string])
    [void]$table.Columns.Add('AttributeName', [string])
    [void]$table.Columns.Add('AttributeClass', [string])
    [void]$table.Columns.Add('ValueJson', [string])
    [void]$table.Columns.Add('ValueSha256', [string])
    foreach ($row in $pending) {
        $item = $table.NewRow()
        $item.CatalogRunId = $RunId
        $item.IdentityId = [int64]$row.IdentityId
        $item.SourceSystem = [string]$row.SourceSystem
        $item.AttributeName = [string]$row.AttributeName
        $item.AttributeClass = [string]$row.AttributeClass
        if ($null -eq $row.ValueJson) { $item.ValueJson = [DBNull]::Value } else { $item.ValueJson = [string]$row.ValueJson }
        $item.ValueSha256 = [string]$row.ValueSha256
        [void]$table.Rows.Add($item)
    }
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $connection.Open()
    try {
        $bulk = New-Object System.Data.SqlClient.SqlBulkCopy $connection
        $bulk.DestinationTableName = 'dbo.IdentityAttributeStage'
        $bulk.BulkCopyTimeout = 180
        foreach ($column in $table.Columns) { [void]$bulk.ColumnMappings.Add($column.ColumnName, $column.ColumnName) }
        $bulk.WriteToServer($table)
    } finally {
        $connection.Close()
    }
    $merge = @{
        ConnectionString = $ConnectionString
        Parameters = @{ RunId = $RunId }
        NonQuery = $true
    }
    Invoke-AccessSql @merge -Sql @"
MERGE dbo.IdentityAttribute AS tgt
USING (
    SELECT IdentityId, SourceSystem, AttributeName, AttributeClass, ValueJson, ValueSha256, CatalogRunId
    FROM dbo.IdentityAttributeStage
    WHERE CatalogRunId = @RunId
) AS src
ON tgt.IdentityId = src.IdentityId AND tgt.SourceSystem = src.SourceSystem AND tgt.AttributeName = src.AttributeName
WHEN MATCHED AND ISNULL(tgt.ValueSha256, '') <> ISNULL(src.ValueSha256, '') THEN
    UPDATE SET ValueJson = src.ValueJson, ValueSha256 = src.ValueSha256, AttributeClass = src.AttributeClass, LastCatalogRunId = src.CatalogRunId
WHEN NOT MATCHED THEN
    INSERT (IdentityId, SourceSystem, AttributeName, AttributeClass, ValueJson, ValueSha256, LastCatalogRunId)
    VALUES (src.IdentityId, src.SourceSystem, src.AttributeName, src.AttributeClass, src.ValueJson, src.ValueSha256, src.CatalogRunId);
"@ | Out-Null
    Invoke-AccessSql @merge -Sql @"
DELETE tgt
FROM dbo.IdentityAttribute AS tgt
WHERE EXISTS (
    SELECT 1 FROM dbo.IdentityAttributeStage AS s
    WHERE s.CatalogRunId = @RunId AND s.IdentityId = tgt.IdentityId AND s.SourceSystem = tgt.SourceSystem
)
AND NOT EXISTS (
    SELECT 1 FROM dbo.IdentityAttributeStage AS s2
    WHERE s2.CatalogRunId = @RunId AND s2.IdentityId = tgt.IdentityId AND s2.SourceSystem = tgt.SourceSystem AND s2.AttributeName = tgt.AttributeName
);
"@ | Out-Null
    Invoke-AccessSql @merge -Sql 'DELETE FROM dbo.IdentityAttributeStage WHERE CatalogRunId = @RunId;' | Out-Null
}

function Add-StagedAttributes {
    param($Bucket, [int64]$IdentityId, [string]$SourceSystem, $Attributes)
    foreach ($attribute in @($Attributes)) {
        $Bucket.Add([pscustomobject]@{
            IdentityId = $IdentityId
            SourceSystem = $SourceSystem
            AttributeName = $attribute.Name
            AttributeClass = $attribute.Class
            ValueJson = $attribute.ValueJson
            ValueSha256 = $attribute.ValueSha256
        })
    }
}

function Sync-HybridIdentityCatalog {
    <#
    .SYNOPSIS
        Catalogs on-prem and Entra users into one versioned identity record per person.
    .DESCRIPTION
        People whose user principal names match become one row with both GUIDs.
        A match on immutable ID or sAMAccountName with a different UPN is still one row, labeled separately.
        Accounts that exist on only one side stay one row and say which side.
        Attribute history uses SQL Server system-versioned tables.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SearchBase,
        [int]$MaxUsers = 0
    )
    if ($null -eq $script:AccessSession) { throw 'Connect first.' }
    Import-Module ActiveDirectory -ErrorAction Stop
    $warnings = New-Object System.Collections.Generic.List[string]
    $connectionString = $script:AccessSession.CatalogConnectionString
    $runId = [guid]::NewGuid()
    $base = if ($SearchBase) { $SearchBase } else { $script:AccessSession.SearchBase }
    $entraUsers = @(Get-EntraCatalogUsers -Warnings $warnings -MaxUsers $MaxUsers)
    $byImmutable = @{}
    $byUpn = @{}
    $bySam = @{}
    foreach ($entraUser in $entraUsers) {
        Add-CatalogIndex $byImmutable ([string]$entraUser.onPremisesImmutableId) $entraUser
        Add-CatalogIndex $byUpn ([string]$entraUser.userPrincipalName) $entraUser
        Add-CatalogIndex $bySam ([string]$entraUser.onPremisesSamAccountName) $entraUser
    }
    $counts = @{
        OnPrem = 0; Entra = $entraUsers.Count; AlignedUpn = 0; OnPremOnly = 0; EntraOnly = 0; OtherAligned = 0
    }
    if ($PSCmdlet.ShouldProcess($connectionString, 'Catalog hybrid identities')) {
        Invoke-AccessSql -ConnectionString $connectionString -NonQuery -Sql @"
INSERT INTO dbo.CatalogRun (CatalogRunId, StartedUtc, StartedBy, EntraCount, Outcome)
VALUES (@CatalogRunId, @StartedUtc, @StartedBy, @EntraCount, @Outcome);
"@ -Parameters @{
            CatalogRunId = $runId
            StartedUtc = [DateTime]::UtcNow
            StartedBy = $script:AccessSession.OperatorSam
            EntraCount = $counts.Entra
            Outcome = 'Running'
        } | Out-Null
    }
    $consumed = @{}
    $bucket = New-Object System.Collections.Generic.List[object]
    $search = @{
        Filter = '*'
        ResultPageSize = 200
        Properties = '*'
        Server = $script:AccessSession.DomainController
        Credential = $script:AccessSession.Credential
    }
    if ($base) { $search.SearchBase = $base }
    if ($MaxUsers -gt 0) { $search.ResultSetSize = $MaxUsers }
    Get-ADUser @search | ForEach-Object {
        $adUser = $_
        $counts.OnPrem++
        $partner = $null
        $immutable = ConvertTo-ImmutableId -ObjectGuid $adUser.ObjectGuid
        if ($byImmutable.ContainsKey($immutable) -and $byImmutable[$immutable].Count -ge 1) {
            $partner = $byImmutable[$immutable][0]
        } elseif ($adUser.UserPrincipalName -and $byUpn.ContainsKey($adUser.UserPrincipalName.ToLowerInvariant())) {
            $matches = $byUpn[$adUser.UserPrincipalName.ToLowerInvariant()]
            if ($matches.Count -eq 1) { $partner = $matches[0] } else { $warnings.Add("More than one Entra user has UPN $($adUser.UserPrincipalName). That on-prem account was not merged.") }
        } elseif ($adUser.SamAccountName -and $bySam.ContainsKey($adUser.SamAccountName.ToLowerInvariant())) {
            $matches = $bySam[$adUser.SamAccountName.ToLowerInvariant()]
            if ($matches.Count -eq 1) { $partner = $matches[0] }
        }
        $alignment = 'OnPremOnly'
        if ($partner) {
            $entraUpn = [string]$partner.userPrincipalName
            $adUpn = [string]$adUser.UserPrincipalName
            if ($adUpn -and $entraUpn -and ($adUpn -ieq $entraUpn)) { $alignment = 'AlignedUpn'; $counts.AlignedUpn++ }
            elseif ([string]$partner.onPremisesImmutableId -eq $immutable) { $alignment = 'AlignedImmutableId'; $counts.OtherAligned++ }
            elseif ($adUser.SamAccountName -and ([string]$partner.onPremisesSamAccountName -ieq $adUser.SamAccountName)) { $alignment = 'AlignedSam'; $counts.OtherAligned++ }
            else { $alignment = 'Conflict'; $counts.OtherAligned++ }
            $consumed[[string]$partner.id] = $true
        } else { $counts.OnPremOnly++ }
        if (-not $PSCmdlet.ShouldProcess([string]$adUser.UserPrincipalName, 'Write catalog row')) { return }
        $record = @{
            MatchKey = "onprem:$($adUser.ObjectGuid)"
            Alignment = $alignment
            UserPrincipalName = [string]$adUser.UserPrincipalName
            OnPremObjectGuid = [guid]$adUser.ObjectGuid
            EntraObjectId = $(if ($partner) { [guid]$partner.id } else { $null })
            OnPremSid = [string]$adUser.ObjectSid
            ImmutableId = $immutable
            OnPremSam = [string]$adUser.SamAccountName
            DisplayName = [string]$adUser.DisplayName
            EnabledOnPrem = [bool]$adUser.Enabled
            EnabledEntra = $(if ($partner) { [bool]$partner.accountEnabled } else { $null })
        }
        $identityId = Save-CatalogIdentity -ConnectionString $connectionString -RunId $runId -Record $record
        Add-StagedAttributes $bucket $identityId 'OnPremAD' (Get-AdCatalogAttributes $adUser)
        if ($partner) { Add-StagedAttributes $bucket $identityId 'Entra' (Get-GraphCatalogAttributes $partner) }
        if ($bucket.Count -ge 4000) {
            Publish-CatalogAttributes -ConnectionString $connectionString -RunId $runId -Rows $bucket.ToArray()
            $bucket.Clear()
        }
    }
    foreach ($entraUser in $entraUsers) {
        if ($consumed.ContainsKey([string]$entraUser.id)) { continue }
        $counts.EntraOnly++
        if (-not $PSCmdlet.ShouldProcess([string]$entraUser.userPrincipalName, 'Write Entra-only catalog row')) { continue }
        $onPremGuid = ConvertFrom-ImmutableId ([string]$entraUser.onPremisesImmutableId)
        $record = @{
            MatchKey = "entra:$($entraUser.id)"
            Alignment = 'EntraOnly'
            UserPrincipalName = [string]$entraUser.userPrincipalName
            OnPremObjectGuid = $onPremGuid
            EntraObjectId = [guid]$entraUser.id
            OnPremSid = [string]$entraUser.onPremisesSecurityIdentifier
            ImmutableId = [string]$entraUser.onPremisesImmutableId
            OnPremSam = [string]$entraUser.onPremisesSamAccountName
            DisplayName = [string]$entraUser.displayName
            EnabledOnPrem = $null
            EnabledEntra = [bool]$entraUser.accountEnabled
        }
        $identityId = Save-CatalogIdentity -ConnectionString $connectionString -RunId $runId -Record $record
        Add-StagedAttributes $bucket $identityId 'Entra' (Get-GraphCatalogAttributes $entraUser)
        if ($bucket.Count -ge 4000) {
            Publish-CatalogAttributes -ConnectionString $connectionString -RunId $runId -Rows $bucket.ToArray()
            $bucket.Clear()
        }
    }
    if ($PSCmdlet.ShouldProcess('catalog', 'Flush staged attributes') -and $bucket.Count -gt 0) {
        Publish-CatalogAttributes -ConnectionString $connectionString -RunId $runId -Rows $bucket.ToArray()
    }
    $outcome = if ($warnings.Count -gt 0) { 'CompletedWithWarnings' } else { 'Succeeded' }
    $warningText = ($warnings | Select-Object -First 30) -join ' '
    if ($PSCmdlet.ShouldProcess('catalog run', 'Finish')) {
        Invoke-AccessSql -ConnectionString $connectionString -NonQuery -Sql @"
UPDATE dbo.CatalogRun
SET FinishedUtc = @FinishedUtc, OnPremCount = @OnPremCount, EntraCount = @EntraCount,
    AlignedUpnCount = @AlignedUpnCount, OnPremOnlyCount = @OnPremOnlyCount, EntraOnlyCount = @EntraOnlyCount,
    OtherAlignedCount = @OtherAlignedCount, Outcome = @Outcome, ErrorMessage = @ErrorMessage
WHERE CatalogRunId = @CatalogRunId;
"@ -Parameters @{
            FinishedUtc = [DateTime]::UtcNow
            OnPremCount = $counts.OnPrem
            EntraCount = $counts.Entra
            AlignedUpnCount = $counts.AlignedUpn
            OnPremOnlyCount = $counts.OnPremOnly
            EntraOnlyCount = $counts.EntraOnly
            OtherAlignedCount = $counts.OtherAligned
            Outcome = $outcome
            ErrorMessage = $(if ($warningText) { $warningText } else { $null })
            CatalogRunId = $runId
        } | Out-Null
    }
    [pscustomobject]@{
        CatalogRunId = $runId
        OnPremCount = $counts.OnPrem
        EntraCount = $counts.Entra
        AlignedUpnCount = $counts.AlignedUpn
        OnPremOnlyCount = $counts.OnPremOnly
        EntraOnlyCount = $counts.EntraOnly
        OtherAlignedCount = $counts.OtherAligned
        Outcome = $outcome
        Warnings = @($warnings)
    }
}
