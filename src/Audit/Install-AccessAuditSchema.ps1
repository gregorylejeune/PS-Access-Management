function Add-AccessSqlParameter {
    param($Command, [string]$Name, $Value)
    $parameter = $Command.CreateParameter()
    $parameter.ParameterName = "@$Name"
    if ($null -eq $Value) {
        $parameter.SqlDbType = [System.Data.SqlDbType]::NVarChar
        $parameter.Size = -1
        $parameter.Value = [DBNull]::Value
    } elseif ($Value -is [guid]) {
        $parameter.SqlDbType = [System.Data.SqlDbType]::UniqueIdentifier
        $parameter.Value = $Value
    } elseif ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        $parameter.SqlDbType = [System.Data.SqlDbType]::DateTime2
        $parameter.Value = [datetime]$Value
    } elseif ($Value -is [bool]) {
        $parameter.SqlDbType = [System.Data.SqlDbType]::Bit
        $parameter.Value = $Value
    } elseif ($Value -is [int] -or $Value -is [int64] -or $Value -is [long]) {
        $parameter.SqlDbType = [System.Data.SqlDbType]::BigInt
        $parameter.Value = [int64]$Value
    } else {
        $parameter.SqlDbType = [System.Data.SqlDbType]::NVarChar
        $parameter.Size = -1
        $parameter.Value = [string]$Value
    }
    [void]$Command.Parameters.Add($parameter)
}

function Invoke-AccessSql {
    param(
        [Parameter(Mandatory = $true)][string]$ConnectionString,
        [Parameter(Mandatory = $true)][string]$Sql,
        [hashtable]$Parameters,
        [switch]$Scalar,
        [switch]$NonQuery
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        $command.CommandTimeout = 180
        if ($Parameters) {
            foreach ($key in @($Parameters.Keys)) {
                Add-AccessSqlParameter -Command $command -Name $key -Value $Parameters[$key]
            }
        }
        if ($Scalar) { return $command.ExecuteScalar() }
        if ($NonQuery) { return $command.ExecuteNonQuery() }
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        return ,$table
    } finally {
        $connection.Close()
    }
}

function Invoke-AccessSqlBatch {
    param(
        [Parameter(Mandatory = $true)][string]$ConnectionString,
        [Parameter(Mandatory = $true)][string]$Sql
    )
    $batches = [regex]::Split($Sql, '(?m)^\s*GO\s*$')
    foreach ($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }
        Invoke-AccessSql -ConnectionString $ConnectionString -Sql $batch -NonQuery | Out-Null
    }
}

function Install-AccessAuditSchema {
    <#
    .SYNOPSIS
        Creates the audit and identity-catalog schema when it is missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConnectionString
    )

    $sqlRoot = Join-Path $script:ModuleRoot 'sql'
    $files = @(
        '001_audit.sql'
        '002_identity_catalog.sql'
    )
    foreach ($file in $files) {
        $path = Join-Path $sqlRoot $file
        $applied = Invoke-AccessSql -ConnectionString $ConnectionString -Scalar -Sql "IF OBJECT_ID(N'dbo.SchemaMigration', N'U') IS NULL SELECT 0 ELSE SELECT COUNT(1) FROM dbo.SchemaMigration WHERE MigrationId = @Id;" -Parameters @{ Id = $file }
        if ([int]$applied -gt 0) { continue }
        $sql = [IO.File]::ReadAllText($path)
        Invoke-AccessSqlBatch -ConnectionString $ConnectionString -Sql $sql
        Invoke-AccessSql -ConnectionString $ConnectionString -NonQuery -Sql "IF NOT EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE MigrationId = @Id) INSERT INTO dbo.SchemaMigration (MigrationId) VALUES (@Id);" -Parameters @{ Id = $file } | Out-Null
    }
}
