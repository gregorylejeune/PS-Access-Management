function ConvertFrom-SecurePlainText {
    param([Security.SecureString]$Secure)
    if ($null -eq $Secure) { return $null }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    $text = [Convert]::ToBase64String($Bytes)
    $text.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GraphClientAssertion {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)]$Certificate
    )

    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $rsa) {
        throw 'The certificate does not have a private key this process can use.'
    }

    $header = [ordered]@{
        alg = 'RS256'
        typ = 'JWT'
        x5t = (ConvertTo-Base64Url $Certificate.GetCertHash())
    }
    $now = [int]([DateTime]::UtcNow - [datetime]'1970-01-01Z').TotalSeconds
    $payload = [ordered]@{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now
        exp = $now + 540
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $encodedHeader = ConvertTo-Base64Url $utf8.GetBytes(($header | ConvertTo-Json -Compress))
    $encodedPayload = ConvertTo-Base64Url $utf8.GetBytes(($payload | ConvertTo-Json -Compress))
    $signingInput = "$encodedHeader.$encodedPayload"
    $signature = $rsa.SignData(
        $utf8.GetBytes($signingInput),
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    "$signingInput.$(ConvertTo-Base64Url $signature)"
}

function Get-GraphCertificate {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    $clean = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        $cert = Get-Item -Path (Join-Path $store $clean) -ErrorAction SilentlyContinue
        if ($cert) { return $cert }
    }
    throw "Certificate $clean was not found in CurrentUser\My or LocalMachine\My."
}

function Get-GraphAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Security.SecureString]$ClientSecret,
        [string]$CertificateThumbprint
    )

    $body = @{
        client_id = $ClientId
        scope = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'
    }

    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $cert = Get-GraphCertificate -Thumbprint $CertificateThumbprint
        $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body.client_assertion = New-GraphClientAssertion -TenantId $TenantId -ClientId $ClientId -Certificate $cert
    } else {
        $plain = ConvertFrom-SecurePlainText $ClientSecret
        if ([string]::IsNullOrEmpty($plain)) { throw 'Graph client secret is empty.' }
        $body.client_secret = $plain
    }

    try {
        $token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
    } catch {
        throw 'Entra token request failed. The client secret was not included in this error.'
    } finally {
        if ($body.ContainsKey('client_secret')) { $body.client_secret = $null }
        if ($body.ContainsKey('client_assertion')) { $body.client_assertion = $null }
    }

    [pscustomobject]@{
        AccessToken = [string]$token.access_token
        ExpiresUtc = [DateTime]::UtcNow.AddSeconds(([int]$token.expires_in) - 120)
    }
}

function Get-AccessGraphToken {
    if ($null -eq $script:AccessSession) { throw 'Connect first.' }
    if ($script:AccessSession.GraphToken -and [DateTime]::UtcNow -lt $script:AccessSession.GraphTokenExpiresUtc) {
        return $script:AccessSession.GraphToken
    }
    $fresh = Get-GraphAccessToken -TenantId $script:AccessSession.GraphTenantId -ClientId $script:AccessSession.GraphClientId -ClientSecret $script:AccessSession.GraphClientSecret -CertificateThumbprint $script:AccessSession.GraphCertThumbprint
    $script:AccessSession.GraphToken = $fresh.AccessToken
    $script:AccessSession.GraphTokenExpiresUtc = $fresh.ExpiresUtc
    $fresh.AccessToken
}
