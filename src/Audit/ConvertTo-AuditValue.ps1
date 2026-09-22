function ConvertTo-AuditValue {
    <#
    .SYNOPSIS
        Renders a directory value for the audit log, redacting anything that looks like a password or token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AttributeName,
        $Value
    )

    if ($null -eq $Value) { return $null }
    if ($AttributeName -match '(?i)password|passwd|unicodePwd|userPassword|clientSecret|secret|token|\bpin\b|supplementalCredentials') {
        $text = [string]$Value
        if ([string]::IsNullOrEmpty($text)) { return $null }
        return '[REDACTED]'
    }
    if ($Value -is [System.Array] -or ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -ne $item) { $parts.Add([string]$item) }
        }
        return ($parts -join '; ')
    }
    [string]$Value
}
