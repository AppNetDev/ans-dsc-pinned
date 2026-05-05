#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Pinned DSC v3 resource package and optionally applies a config URL.
.DESCRIPTION
    Installs standalone DSC v3 when needed, downloads the Pinned DSC v3 release
    zip, extracts it to a predictable resource directory, sets DSC_RESOURCE_PATH
    for the current process, and can apply a remote YAML configuration.
.EXAMPLE
    irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1" | iex
.EXAMPLE
    iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/firefox-dscv3.yaml'"
#>
[CmdletBinding()]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [string] $DscVersion = 'latest',

    [string] $DscInstallDirectory,

    [string] $ResourcePackageUri = 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/latest/download/Pinned.DSCv3.zip',

    [string] $ResourcePackagePath,

    [string] $ResourceInstallDirectory,

    [string] $ConfigurationUri,

    [string] $DestinationPath = (Join-Path $env:TEMP 'ans-configure.yaml'),

    [switch] $PersistDscPath,

    [switch] $SkipDscInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Function Get-DefaultDscInstallDirectory {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope
    )

    if ($Scope -eq 'AllUsers') {
        return Join-Path $env:ProgramFiles 'DSC'
    }

    return Join-Path $env:LOCALAPPDATA 'Microsoft\DSC'
};

Function Get-DefaultPinnedResourceDirectory {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope
    )

    if ($Scope -eq 'AllUsers') {
        return Join-Path $env:ProgramFiles 'DSC\Resources\AppNetOnline.Pinned'
    }

    return Join-Path $env:LOCALAPPDATA 'Microsoft\DSC\Resources\AppNetOnline.Pinned'
};

Function Get-DscWindowsAssetPattern {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } elseif ($env:PROCESSOR_ARCHITECTURE) {
        $env:PROCESSOR_ARCHITECTURE
    } else {
        'AMD64'
    }

    if ($architecture -match 'ARM64|AARCH64') {
        return 'aarch64-pc-windows-msvc\.zip$'
    }

    return 'x86_64-pc-windows-msvc\.zip$'
};

Function Add-DirectoryToPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('Process', 'User', 'Machine')]
        [string] $Target = 'Process'
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $currentPath = if ($Target -eq 'Process') {
        $env:PATH
    } else {
        [Environment]::GetEnvironmentVariable('PATH', $Target)
    }

    $pathParts = @($currentPath -split ';' | Where-Object { $_ })
    if ($pathParts -contains $resolvedPath) {
        return
    }

    $updatedPath = if ([string]::IsNullOrWhiteSpace($currentPath)) {
        $resolvedPath
    } else {
        "$resolvedPath;$currentPath"
    }

    if ($Target -eq 'Process') {
        $env:PATH = $updatedPath
    } else {
        [Environment]::SetEnvironmentVariable('PATH', $updatedPath, $Target)
    }
};

Function Install-DscV3Standalone {
    [CmdletBinding()]
    param(
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope = 'CurrentUser',

        [string] $Version = 'latest',

        [string] $InstallDirectory = (Get-DefaultDscInstallDirectory -Scope $Scope),

        [switch] $PersistPath
    )

    $releaseUri = if ($Version -eq 'latest') {
        'https://api.github.com/repos/PowerShell/DSC/releases/latest'
    } else {
        'https://api.github.com/repos/PowerShell/DSC/releases/tags/{0}' -f $Version
    }

    Write-Host "==> Resolving DSC release: $Version"
    $release = Invoke-RestMethod -Uri $releaseUri -Headers @{ 'User-Agent' = 'ans-dsc-pinned-installer' }
    $assetPattern = Get-DscWindowsAssetPattern
    $asset = @($release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1)
    if (-not $asset) {
        throw "Could not find a Windows standalone DSC zip asset matching '$assetPattern' in release '$($release.tag_name)'."
    }

    $downloadPath = Join-Path $env:TEMP $asset.name
    $extractPath = Join-Path $env:TEMP ('dsc-{0}' -f ([guid]::NewGuid().ToString('N')))

    Write-Host "==> Downloading $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing

    Write-Host "==> Extracting DSC"
    Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

    $dscExe = Get-ChildItem -Path $extractPath -Filter dsc.exe -Recurse | Select-Object -First 1
    if (-not $dscExe) {
        throw "The release asset '$($asset.name)' did not contain dsc.exe."
    }

    if (-not (Test-Path -LiteralPath $InstallDirectory)) {
        New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Host "==> Installing DSC to $InstallDirectory"
    Get-ChildItem -Path $dscExe.Directory.FullName -Force | Copy-Item -Destination $InstallDirectory -Recurse -Force

    Add-DirectoryToPath -Path $InstallDirectory -Target Process
    if ($PersistPath) {
        $target = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }
        Add-DirectoryToPath -Path $InstallDirectory -Target $target
        Write-Host "==> Added $InstallDirectory to $target PATH"
    }

    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    return (Join-Path $InstallDirectory 'dsc.exe')
};

Function Test-DscExecutable {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $null = & $Path --version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
};

Function Resolve-DscPath {
    $command = Get-Command dsc -ErrorAction SilentlyContinue
    if ($command -and (Test-DscExecutable -Path $command.Source)) {
        return $command.Source
    }

    $defaultPath = Join-Path (Get-DefaultDscInstallDirectory -Scope $Scope) 'dsc.exe'
    if (Test-DscExecutable -Path $defaultPath) {
        Add-DirectoryToPath -Path (Split-Path -Parent $defaultPath) -Target Process
        return $defaultPath
    }

    return $null
};

Function Install-PinnedDscV3Resource {
    [CmdletBinding()]
    param(
        [string] $PackageUri,

        [string] $PackagePath,

        [Parameter(Mandatory)]
        [string] $InstallDirectory
    )

    $downloadPath = Join-Path $env:TEMP 'Pinned.DSCv3.zip'
    $extractPath = Join-Path $env:TEMP ('Pinned.DSCv3-{0}' -f ([guid]::NewGuid().ToString('N')))

    if ($PackagePath) {
        $resolvedPackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
        Write-Host "==> Using Pinned DSC v3 resource package: $resolvedPackagePath"
        Copy-Item -Path $resolvedPackagePath -Destination $downloadPath -Force
    } else {
        Write-Host "==> Downloading Pinned DSC v3 resource"
        Invoke-WebRequest -Uri $PackageUri -OutFile $downloadPath -UseBasicParsing
    }

    Write-Host "==> Extracting Pinned DSC v3 resource"
    Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

    $packageRoot = Join-Path $extractPath 'AppNetOnline.Pinned'
    if (-not (Test-Path -LiteralPath $packageRoot)) {
        throw "The package '$PackageUri' did not contain an AppNetOnline.Pinned folder."
    }

    if (Test-Path -LiteralPath $InstallDirectory) {
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    }

    New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null
    Get-ChildItem -Path $packageRoot -Force | Copy-Item -Destination $InstallDirectory -Recurse -Force

    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    $resourcePath = Join-Path $InstallDirectory 'DSCv3'
    $manifestPath = Join-Path $resourcePath 'Pinned.App.dsc.resource.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Pinned DSC v3 resource manifest was not found at '$manifestPath'."
    }

    return $resourcePath
};

If (-not $DscInstallDirectory) {
    $DscInstallDirectory = Get-DefaultDscInstallDirectory -Scope $Scope
};

If (-not $ResourceInstallDirectory) {
    $ResourceInstallDirectory = Get-DefaultPinnedResourceDirectory -Scope $Scope
};

$dscPath = Resolve-DscPath
If (-not $dscPath) {
    If ($SkipDscInstall) {
        throw 'dsc.exe was not found and -SkipDscInstall was specified.'
    };

    $dscPath = Install-DscV3Standalone -Scope $Scope -Version $DscVersion -InstallDirectory $DscInstallDirectory -PersistPath:$PersistDscPath
};

$resourcePath = Install-PinnedDscV3Resource -PackageUri $ResourcePackageUri -PackagePath $ResourcePackagePath -InstallDirectory $ResourceInstallDirectory
$env:DSC_RESOURCE_PATH = $resourcePath

Write-Host "==> Installed Pinned DSC v3 resource: $resourcePath"
& $dscPath resource list AppNetOnline.Pinned/App

If ($ConfigurationUri) {
    Write-Host "==> Downloading configuration"
    Invoke-WebRequest -Uri $ConfigurationUri -OutFile $DestinationPath -UseBasicParsing

    Write-Host "==> Applying configuration: $DestinationPath"
    & $dscPath config set --file $DestinationPath
};
