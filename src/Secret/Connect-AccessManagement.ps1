function Get-OperatorIdentity {
    $windows = [Security.Principal.WindowsIdentity]::GetCurrent()
    $upn = $null
    $whoami = Get-Command whoami.exe -ErrorAction SilentlyContinue
    if ($whoami) {
        try {
            $raw = (& whoami.exe /upn 2>$null)
            if ($raw -and ($raw -notmatch '(?i)ERROR|unable')) { $upn = ([string]$raw).Trim() }
        } catch { }
    }
    [pscustomobject]@{
        Sam = $windows.Name
        Sid = $windows.User.Value
        Upn = $upn
        Machine = [Environment]::MachineName
    }
}

function Get-Sha256Text {
    param([AllowNull()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text))
        ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Resolve-AccessDomainController {
    param([pscredential]$Credential, [string]$Server)
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($Server)) {
        Get-ADDomain -Server $Server -Credential $Credential | Out-Null
        return $Server
    }
    $domain = Get-ADDomain -Credential $Credential
    $dc = [string]$domain.PDCEmulator
    if ([string]::IsNullOrWhiteSpace($dc)) { throw 'Could not resolve a domain controller.' }
    $dc
}

function Connect-AccessManagement {
    <#
    .SYNOPSIS
        Reads the AWS secret, normalizes it, and opens an audited operator session.
    .DESCRIPTION
        No directory write is allowed until the audit schema is installed and the operator session row exists.
        Pass -RepairChoice WriteBack only after the operator has confirmed the secret id. The secret value is not logged.
    #>
    [CmdletBinding()]
    param(
        [string]$SecretId,
        [string]$Region,
        [string]$AwsProfile,
        [ValidateSet('Memory', 'WriteBack')]
        [string]$RepairChoice = 'Memory',
        [switch]$NonInteractive,
        [switch]$AllowRepairWrite
    )

    $resolvedId = $null
    $resolvedRegion = $null
    if ($SecretId -and $Region) {
        $resolvedId = $SecretId
        $resolvedRegion = $Region
    } else {
        $saved = $null
        try { $saved = Unprotect-AccessSecretIdentifier } catch { if ($NonInteractive) { throw } }
        if (-not $SecretId -and $saved) { $resolvedId = [string]$saved.secretId }
        if (-not $Region -and $saved) { $resolvedRegion = [string]$saved.region }
        if (-not $resolvedId) { $resolvedId = $SecretId }
        if (-not $resolvedRegion) { $resolvedRegion = $Region }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedId)) { throw 'A secret identifier is required.' }
    if ([string]::IsNullOrWhiteSpace($resolvedRegion)) {
        $resolvedRegion = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { '' }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedRegion)) { throw 'An AWS region is required.' }
    if ($AwsProfile) { $env:AWS_PROFILE = $AwsProfile }
    $env:AWS_REGION = $resolvedRegion

    $secretJson = Get-AwsSecretString -SecretId $resolvedId -Region $resolvedRegion
    $normalized = ConvertTo-NormalizedAccessSecret -Json $secretJson
    $secretJson = $null

    if (-not $normalized.IsValid) {
        $names = ($normalized.Missing -join ', ')
        throw "The secret is missing required values: $names. Nothing secret was written to this error."
    }

    if (-not $normalized.IsCanonical) {
        if ($RepairChoice -eq 'WriteBack') {
            if (-not $AllowRepairWrite) {
                throw 'Refusing to rewrite the AWS secret without -AllowRepairWrite.'
            }
            Update-AwsSecretString -SecretId $resolvedId -Region $resolvedRegion -SecretString $normalized.RepairedJson
        }
    }

    $canonical = $normalized.Canonical
    $password = [string]$canonical.OnPremAD.Password
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $password = $null
    $canonical.OnPremAD.Password = $null
    $normalized.RepairedJson = $null

    $credential = New-Object System.Management.Automation.PSCredential($canonical.OnPremAD.UserPrincipalName, $securePassword)
    $dc = Resolve-AccessDomainController -Credential $credential -Server ([string]$canonical.OnPremAD.Server)

    $clientSecret = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$canonical.GraphApi.ClientSecret)) {
        $clientSecret = ConvertTo-SecureString ([string]$canonical.GraphApi.ClientSecret) -AsPlainText -Force
        $canonical.GraphApi.ClientSecret = $null
    }

    $operator = Get-OperatorIdentity
    $session = [pscustomobject]@{
        SessionId = [guid]::NewGuid()
        OperatorSam = $operator.Sam
        OperatorUpn = $operator.Upn
        OperatorSid = $operator.Sid
        MachineName = $operator.Machine
        ServiceAccountUpn = $credential.UserName
        SecretId = $resolvedId
        SecretIdHash = (Get-Sha256Text $resolvedId)
        Region = $resolvedRegion
        DomainController = $dc
        SearchBase = [string]$canonical.OnPremAD.SearchBase
        Credential = $credential
        AuditConnectionString = [string]$canonical.ConnectionStrings.Audit
        CatalogConnectionString = $(if ([string]::IsNullOrWhiteSpace([string]$canonical.ConnectionStrings.Catalog)) { [string]$canonical.ConnectionStrings.Audit } else { [string]$canonical.ConnectionStrings.Catalog })
        GraphTenantId = [string]$canonical.GraphApi.TenantId
        GraphClientId = [string]$canonical.GraphApi.ClientId
        GraphClientSecret = $clientSecret
        GraphCertThumbprint = [string]$canonical.GraphApi.CertificateThumbprint
        GraphOrganization = [string]$canonical.GraphApi.Organization
        GraphToken = $null
        GraphTokenExpiresUtc = [datetime]::MinValue
        ConnectedUtc = [DateTime]::UtcNow
        NormalizationIssues = @($normalized.Issues)
    }

    $script:AccessSession = $session
    try {
        Get-AccessGraphToken | Out-Null
        Install-AccessAuditSchema -ConnectionString $session.AuditConnectionString
        if ($session.CatalogConnectionString -ne $session.AuditConnectionString) {
            Install-AccessAuditSchema -ConnectionString $session.CatalogConnectionString
        }
        $inserted = Invoke-AccessSql -ConnectionString $session.AuditConnectionString -Sql @"
INSERT INTO dbo.OperatorSession
    (SessionId, OperatorSam, OperatorUpn, OperatorSid, MachineName, StartedUtc, AppVersion, ServiceAccountUpn, SecretIdentifierSha256, DomainController)
VALUES
    (@SessionId, @OperatorSam, @OperatorUpn, @OperatorSid, @MachineName, @StartedUtc, @AppVersion, @ServiceAccountUpn, @SecretIdentifierSha256, @DomainController);
"@ -Parameters @{
            SessionId = $session.SessionId
            OperatorSam = $session.OperatorSam
            OperatorUpn = $session.OperatorUpn
            OperatorSid = $session.OperatorSid
            MachineName = $session.MachineName
            StartedUtc = [DateTime]::UtcNow
            AppVersion = $script:AccessModuleVersion
            ServiceAccountUpn = $session.ServiceAccountUpn
            SecretIdentifierSha256 = $session.SecretIdHash
            DomainController = $session.DomainController
        }
        if ($null -eq $inserted) { }
        Write-AccessInteraction -SystemName 'Session' -Action 'Connect' -TargetRef $session.ServiceAccountUpn -Detail 'Operator session opened.' -Outcome 'Succeeded'
    } catch {
        $script:AccessSession = $null
        throw
    }

    [pscustomobject]@{
        SessionId = $session.SessionId
        OperatorSam = $session.OperatorSam
        ServiceAccountUpn = $session.ServiceAccountUpn
        SecretId = $session.SecretId
        Region = $session.Region
        DomainController = $session.DomainController
        NormalizationIssues = @($session.NormalizationIssues)
        AuditTarget = (Get-SqlTargetLabel $session.AuditConnectionString)
    }
}

function Disconnect-AccessManagement {
    [CmdletBinding()]
    param()
    if ($script:AccessSession) {
        try {
            Write-AccessInteraction -SystemName 'Session' -Action 'Disconnect' -TargetRef $script:AccessSession.ServiceAccountUpn -Detail 'Operator session closed.' -Outcome 'Succeeded'
        } catch { }
    }
    $script:AccessSession = $null
}

function Get-SqlTargetLabel {
    param([Parameter(Mandatory = $true)][string]$ConnectionString)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
    '{0} / {1}' -f $builder.DataSource, $builder.InitialCatalog
}
