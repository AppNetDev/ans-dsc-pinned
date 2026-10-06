#Requires -Version 5.1
<#
.SYNOPSIS
    Exercises migration backup guards without launching or changing Visual Studio.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples\dscv3\Invoke-VisualStudio2022Migration.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join [Environment]::NewLine) }
# Load only pure validation functions, never the helper's operational entry point.
foreach ($name in @('Assert-SettingsFile', 'Get-ValidatedBackup')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Rejected {
    param([scriptblock] $Operation, [string] $ExpectedMessage)
    $rejected = $false
    try { & $Operation | Out-Null } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected rejection: $ExpectedMessage" }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ANS-VisualStudioMigrationTest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $testRoot -ItemType Directory | Out-Null
$configPath = Join-Path $testRoot 'Enterprise.vsconfig'
$settingsPath = Join-Path $testRoot 'Enterprise.vssettings'
$manifestPath = Join-Path $testRoot 'Backup.json'
$userSid = 'S-1-5-21-100-200-300-1000'
$passed = 0
try {
    '{"version":"1.0","components":["Microsoft.VisualStudio.Component.CoreEditor"]}' | Set-Content -LiteralPath $configPath
    '<UserSettings><Category name="Environment_Group"><PropertyValue name="Test">true</PropertyValue></Category></UserSettings>' | Set-Content -LiteralPath $settingsPath
    $manifest = @{
        UserSid = $userSid
        ComputerName = $env:COMPUTERNAME
        ConfigHash = (Get-FileHash -LiteralPath $configPath).Hash
        SettingsHash = (Get-FileHash -LiteralPath $settingsPath).Hash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
    $null = Get-ValidatedBackup
    $passed++

    $manifest.UserSid = 'S-1-5-18'
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
    Assert-Rejected { Get-ValidatedBackup } 'another Windows user or computer'
    $passed++
    $manifest.UserSid = $userSid
    $manifest.ComputerName = 'DIFFERENT-COMPUTER'
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
    Assert-Rejected { Get-ValidatedBackup } 'another Windows user or computer'
    $passed++
    $manifest.ComputerName = $env:COMPUTERNAME
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath

    Add-Content -LiteralPath $settingsPath -Value 'changed'
    Assert-Rejected { Get-ValidatedBackup } 'integrity check failed'
    $passed++

    '<UserSettings />' | Set-Content -LiteralPath $settingsPath
    Assert-Rejected { Assert-SettingsFile -Path $settingsPath } 'empty or does not contain'
    $passed++
    '<!DOCTYPE UserSettings [<!ENTITY x SYSTEM "file:///should-never-be-read">]><UserSettings><Category>&x;</Category></UserSettings>' | Set-Content -LiteralPath $settingsPath
    Assert-Rejected { Assert-SettingsFile -Path $settingsPath } 'DTD'
    $passed++

    '<UserSettings><Category name="Environment_Group" /></UserSettings>' | Set-Content -LiteralPath $settingsPath
    '{"version":"1.0","components":[]}' | Set-Content -LiteralPath $configPath
    $manifest.ConfigHash = (Get-FileHash -LiteralPath $configPath).Hash
    $manifest.SettingsHash = (Get-FileHash -LiteralPath $settingsPath).Hash
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
    Assert-Rejected { Get-ValidatedBackup } 'workload export is empty or invalid'
    $passed++
    Remove-Item -LiteralPath $settingsPath
    Assert-Rejected { Get-ValidatedBackup } 'Missing migration backup file'
    $passed++
    [pscustomobject]@{ Passed = $passed; Failed = 0; VisualStudioModified = $false }
} finally {
    $resolvedRoot = [System.IO.Path]::GetFullPath($testRoot)
    $expectedParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-VisualStudioMigrationTest-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
