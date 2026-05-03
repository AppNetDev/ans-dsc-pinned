#Requires -Version 5.1
<#
.SYNOPSIS
    Lint, install, test, and optionally publish the Pinned DSC module.
.PARAMETER Publish
    After a successful build, publish to the AppNetOnline GitHub Packages feed.
.EXAMPLE
    .\Build.ps1              # lint + install + test
    .\Build.ps1 -Publish     # lint + install + test + publish
#>
[CmdletBinding()]
param(
    [Switch] $Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleRoot  = $PSScriptRoot
$ModuleName  = 'Pinned'
$ManifestPath = Join-Path $ModuleRoot "$ModuleName.psd1"
$InstallPath  = "$env:ProgramFiles\WindowsPowerShell\Modules\$ModuleName"
$Failed       = $false

function Write-Step  { Write-Host "`n==> $args" -ForegroundColor Cyan }
function Write-Pass  { Write-Host "    [PASS] $args" -ForegroundColor Green }
function Write-Fail  { Write-Host "    [FAIL] $args" -ForegroundColor Red; $script:Failed = $true }
function Write-Warn  { Write-Host "    [WARN] $args" -ForegroundColor Yellow }

# ── 1. Read version ──────────────────────────────────────────────────────────
Write-Step "Reading module manifest"
$manifest = Test-ModuleManifest -Path $ManifestPath
Write-Pass "Module: $($manifest.Name) v$($manifest.Version)"

# ── 2. Lint ───────────────────────────────────────────────────────────────────
Write-Step "Running PSScriptAnalyzer"
if (-not (Get-Module PSScriptAnalyzer -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Warn "PSScriptAnalyzer not installed — skipping lint (Install-Module PSScriptAnalyzer to enable)"
} else {
    Import-Module PSScriptAnalyzer
    $results = Invoke-ScriptAnalyzer -Path $ModuleRoot -Recurse -Severity Error, Warning `
        -ExcludeRule PSAvoidUsingWriteHost
    if ($results) {
        $results | Format-Table -AutoSize
        Write-Fail "$($results.Count) issue(s) found"
    } else {
        Write-Pass "No issues found"
    }
}

# ── 3. Install ────────────────────────────────────────────────────────────────
Write-Step "Installing module to $InstallPath"
if (Test-Path $InstallPath) { Remove-Item $InstallPath -Recurse -Force }
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
Get-ChildItem $ModuleRoot -Exclude '.git', '*.ps1', '*.yaml', '*.yml', 'README.md' |
    Copy-Item -Destination $InstallPath -Recurse -Force
Write-Pass "Copied to $InstallPath"

# ── 4. Verify manifest ────────────────────────────────────────────────────────
Write-Step "Verifying installed manifest"
$installed = Test-ModuleManifest -Path (Join-Path $InstallPath "$ModuleName.psd1")
if ($installed.Version -eq $manifest.Version) {
    Write-Pass "v$($installed.Version) installed correctly"
} else {
    Write-Fail "Version mismatch: source=$($manifest.Version) installed=$($installed.Version)"
}

# ── 5. Import and DSC check ───────────────────────────────────────────────────
Write-Step "Importing module and checking DSC resource"
Import-Module $ModuleName -Force
$resource = Get-DscResource -Module $ModuleName -Name App -ErrorAction SilentlyContinue
if ($resource) {
    Write-Pass "DSC resource '$ModuleName/App' loaded ($($resource.Properties.Count) properties)"
} else {
    Write-Fail "DSC resource '$ModuleName/App' not found after import"
}

# ── 6. Result ─────────────────────────────────────────────────────────────────
Write-Host ''
if ($Failed) {
    Write-Host "BUILD FAILED — fix the issues above before publishing." -ForegroundColor Red
    exit 1
}
Write-Host "BUILD PASSED — v$($manifest.Version) ready." -ForegroundColor Green

# ── 7. Publish ────────────────────────────────────────────────────────────────
if (-not $Publish) { exit 0 }

Write-Step "Publishing v$($manifest.Version) to AppNetOnline GitHub Packages"

$nugetPath = "$env:TEMP\nuget.exe"
if (-not (Test-Path $nugetPath)) {
    Write-Host "    Downloading nuget.exe..."
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
        -OutFile $nugetPath -UseBasicParsing
}
$env:PATH += ";$env:TEMP"

if (-not (Get-PSRepository -Name 'AppNetOnline' -ErrorAction SilentlyContinue)) {
    Register-PSRepository -Name 'AppNetOnline' `
        -SourceLocation 'https://nuget.pkg.github.com/AppNetOnline/index.json' `
        -PublishLocation 'https://nuget.pkg.github.com/AppNetOnline/' `
        -InstallationPolicy Trusted
}

Publish-Module -Path $InstallPath `
    -Repository 'AppNetOnline' `
    -NuGetApiKey (gh auth token) `
    -Force

Write-Pass "Published $ModuleName v$($manifest.Version)"
