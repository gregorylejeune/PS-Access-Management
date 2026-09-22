function Update-AwsSecretString {
    param(
        [Parameter(Mandatory = $true)][string]$SecretId,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$SecretString
    )

    if (Get-Module -ListAvailable -Name AWS.Tools.SecretsManager) {
        Import-Module AWS.Tools.SecretsManager -ErrorAction Stop
        Update-SECSecret -SecretId $SecretId -Region $Region -SecretString $SecretString | Out-Null
        return
    }

    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $aws) {
        throw 'Install AWS.Tools.SecretsManager or the AWS CLI before repairing a secret.'
    }

    $temp = Join-Path $env:TEMP ('psaccess-' + [guid]::NewGuid().ToString('n') + '.json')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($temp, $SecretString, $utf8)
        & aws secretsmanager put-secret-value --secret-id $SecretId --region $Region --secret-string "file://$temp" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'AWS CLI could not write the repaired secret. The secret value was not logged.'
        }
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AwsSecretString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SecretId,
        [Parameter(Mandatory = $true)][string]$Region
    )

    if (Get-Module -ListAvailable -Name AWS.Tools.SecretsManager) {
        Import-Module AWS.Tools.SecretsManager -ErrorAction Stop
        $response = Get-SECSecretValue -SecretId $SecretId -Region $Region
        if ([string]::IsNullOrEmpty($response.SecretString)) {
            throw "Secret $SecretId does not have a SecretString. Binary secrets are not supported."
        }
        return [string]$response.SecretString
    }

    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $aws) {
        throw 'Install AWS.Tools.SecretsManager (Install-Module AWS.Tools.SecretsManager) or the AWS CLI.'
    }

    $json = & aws secretsmanager get-secret-value --secret-id $SecretId --region $Region --query SecretString --output text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json) -or $json -eq 'None') {
        throw "Could not read secret $SecretId in $Region. The secret value was not logged."
    }
    return [string]$json
}
