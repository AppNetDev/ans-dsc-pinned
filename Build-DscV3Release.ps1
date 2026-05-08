#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Pinned DSC v3 release zip.
.DESCRIPTION
    Creates a self-contained DSC v3 resource package that includes the command
    resource wrapper and the shared App.psm1 implementation it imports.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'dist'),

    [string] $PackageRootName = 'AppNetOnline.Pinned'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleManifestPath = Join-Path $PSScriptRoot 'Pinned\Pinned.psd1'
$moduleManifest = Test-ModuleManifest -Path $moduleManifestPath
$version = $moduleManifest.Version.ToString()

$stagingRoot = Join-Path $OutputDirectory 'staging'
$packageRoot = Join-Path $stagingRoot $PackageRootName
$dscV3Source = Join-Path $PSScriptRoot 'dscv3'
$appSource = Join-Path $PSScriptRoot 'Pinned\DSCResources\App'
$dscV3Destination = Join-Path $packageRoot 'DSCv3'
$appDestination = Join-Path $packageRoot 'Pinned\DSCResources\App'
$latestZipPath = Join-Path $OutputDirectory 'Pinned.DSCv3.zip'
$versionedZipPath = Join-Path $OutputDirectory ("Pinned.DSCv3.{0}.zip" -f $version)

function Remove-DirectoryIfPresent {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $resolvedOutputDirectory = if (Test-Path -LiteralPath $OutputDirectory) {
        (Resolve-Path -LiteralPath $OutputDirectory).Path
    } else {
        $null
    }

    if ($resolvedOutputDirectory -and -not $resolvedPath.StartsWith($resolvedOutputDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside output directory: $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

Remove-DirectoryIfPresent -Path $stagingRoot
New-Item -Path $dscV3Destination -ItemType Directory -Force | Out-Null
New-Item -Path $appDestination -ItemType Directory -Force | Out-Null

Copy-Item -Path (Join-Path $dscV3Source '*') -Destination $dscV3Destination -Recurse -Force
Copy-Item -Path (Join-Path $appSource '*') -Destination $appDestination -Recurse -Force

@{
    Name = $PackageRootName
    Version = $version
    ResourcePath = "$PackageRootName\DSCv3"
    ResourceType = 'AppNetOnline.Pinned/App'
    BuiltAt = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $packageRoot 'release.json') -Encoding UTF8

foreach ($zipPath in @($latestZipPath, $versionedZipPath)) {
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
}

Compress-Archive -Path $packageRoot -DestinationPath $latestZipPath -Force
Copy-Item -Path $latestZipPath -Destination $versionedZipPath -Force

Write-Host "Built DSC v3 release package:"
Write-Host "  $latestZipPath"
Write-Host "  $versionedZipPath"
