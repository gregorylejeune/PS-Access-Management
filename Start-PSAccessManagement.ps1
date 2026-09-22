#requires -Version 5.1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $here 'PSAccessManagement.psd1'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = 'powershell.exe'
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $exe = 'pwsh.exe' }
    & $exe -NoProfile -STA -File $PSCommandPath
    exit $LASTEXITCODE
}
Import-Module $module -Force
Show-AccessManagementForm
