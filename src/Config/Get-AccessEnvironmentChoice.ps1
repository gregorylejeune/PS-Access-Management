function Get-AccessEnvironmentChoice {
    <#
    .SYNOPSIS
        Lists environment variables the operator can bind to, without revealing secret values.
    #>
    [CmdletBinding()]
    param()

    $safeToShow = @(
        'AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_PROFILE',
        'USERDNSDOMAIN', 'USERDOMAIN', 'COMPUTERNAME', 'LOGONSERVER'
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $target = [System.EnvironmentVariableTarget]$scope
        $table = [Environment]::GetEnvironmentVariables($target)
        foreach ($key in @($table.Keys)) {
            $name = [string]$key
            $display = "$scope\$name"
            if ($safeToShow -contains $name) {
                $display = "$scope\$name = $($table[$key])"
            }
            $rows.Add([pscustomobject]@{
                Scope = $scope
                Name = $name
                Display = $display
            })
        }
    }
    $rows | Sort-Object Display
}

function Import-AccessEnvironmentVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Process', 'User', 'Machine')][string]$Scope
    )
    $value = [Environment]::GetEnvironmentVariable($Name, [System.EnvironmentVariableTarget]$Scope)
    if ([string]::IsNullOrEmpty($value)) {
        throw "Environment variable $Name from $Scope is empty."
    }
    [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
}
