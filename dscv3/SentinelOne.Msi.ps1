#Requires -Version 5.1
<# .SYNOPSIS
    Implements the stdin/JSON command contract for AppNet.SentinelOne/MsiUpgrade.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateSet('Get', 'Test', 'Set')]
    [string] $Operation
)

$ErrorActionPreference = 'Stop'
try {
    # Avoid inheriting an inaccessible DSC executable/package working directory.
    [Environment]::CurrentDirectory = $PSScriptRoot
    $null = $ExecutionContext.SessionState.Path.SetLocation($PSScriptRoot)
    # The worker only uses Windows inbox modules. Isolate discovery from inherited
    # PowerShell 7 modules and unavailable redirected-profile/UNC module paths.
    $env:PSModulePath = "$PSHOME\Modules"
    foreach ($ModuleName in @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'CimCmdlets')) {
        Import-Module "$PSHOME\Modules\$ModuleName\$ModuleName.psd1" -ErrorAction Stop
    }
    . (Join-Path $PSScriptRoot 'SentinelOne.Msi.Functions.ps1')
    $InputProperties = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $Properties = @{}
    foreach ($Property in $InputProperties.PSObject.Properties) {
        $Properties[$Property.Name] = $Property.Value
    }
    $State = if ($Operation -eq 'Set') {
        Set-SentinelOneMsiState -Properties $Properties
    }
    else { Get-SentinelOneMsiState -Properties $Properties }
    if ($Operation -eq 'Test') { $State['_inDesiredState'] = [bool] $State.Healthy }
    $State | ConvertTo-Json -Depth 8 -Compress
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
