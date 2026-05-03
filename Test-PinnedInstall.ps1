#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads and installs the Pinned DSC module from GitHub, then verifies import.
.DESCRIPTION
    Installs Pinned v4.0.0 from https://github.com/AppNetOnline/ans-dsc-pinned
    into the system-wide WindowsPowerShell module path and confirms the DSC resource loads.
.NOTES
    Run as Administrator to write to Program Files.
#>
[CmdletBinding()]
param(
    [string] $InstallPath = "$env:ProgramFiles\WindowsPowerShell\Modules\Pinned",
    [string] $SourcePath = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $SourcePath 'Pinned.psd1'))) {
    throw "Pinned.psd1 not found under '$SourcePath'. Run this script from the repo root or set -SourcePath."
}

Write-Host "==> Installing to $InstallPath (source: $SourcePath)..."
if (Test-Path $InstallPath) {
    Write-Warning "  Removing existing installation at $InstallPath"
    Remove-Item $InstallPath -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
Get-ChildItem $SourcePath -Exclude '.git', '*.ps1', '*.yaml', '*.yml', 'README.md' |
Copy-Item -Destination $InstallPath -Recurse -Force

Write-Host "==> Verifying module manifest..."
$manifest = Test-ModuleManifest -Path (Join-Path $InstallPath 'Pinned.psd1')
Write-Host "    Module:  $($manifest.Name)"
Write-Host "    Version: $($manifest.Version)"
Write-Host "    GUID:    $($manifest.Guid)"

Write-Host "==> Importing module..."
Import-Module Pinned -Force

Write-Host "==> Checking DSC resource availability..."
$resource = Get-DscResource -Module Pinned -Name App -ErrorAction SilentlyContinue
if ($resource) {
    Write-Host "    [PASS] DSC resource 'Pinned/App' loaded successfully."
    Write-Host "    Property count: $($resource.Properties.Count)"
}
else {
    Write-Error "[FAIL] DSC resource 'Pinned/App' was not found after import."
}
