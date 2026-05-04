#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the standalone DSC v3 executable and provides a URL-based config wrapper.
.DESCRIPTION
    Downloads the Windows standalone DSC zip from the PowerShell/DSC GitHub
    releases, extracts it to a local folder, adds that folder to PATH for the
    current process, and defines Invoke-DscConfigSetFromUrl.

    The wrapper downloads YAML from a URL to a temporary local file before
    invoking `dsc config set --file`, because DSC expects --file to reference a
    local path.
.EXAMPLE
    . .\examples\Install-DscV3Standalone.ps1
    Install-DscV3Standalone
    Invoke-DscConfigSetFromUrl -Uri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/firefox-dscv3.yaml' -ResourcePath 'C:\Program Files\WindowsPowerShell\Modules\Pinned\DSCv3'
.EXAMPLE
    .\examples\Install-DscV3Standalone.ps1 -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/firefox-dscv3.yaml' -ResourcePath 'C:\Program Files\WindowsPowerShell\Modules\Pinned\DSCv3'
#>
[CmdletBinding()]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [string] $Version = 'latest',

    [string] $InstallDirectory,

    [string] $ConfigurationUri,

    [string] $ResourcePath,

    [switch] $PersistPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-DscDefaultInstallDirectory {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope
    )

    if ($Scope -eq 'AllUsers') {
        return Join-Path $env:ProgramFiles 'DSC'
    }

    return Join-Path $env:LOCALAPPDATA 'Microsoft\DSC'
}

function Get-DscWindowsAssetPattern {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        return 'aarch64-pc-windows-msvc\.zip$'
    }

    return 'x86_64-pc-windows-msvc\.zip$'
}

function Add-DirectoryToPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('Process', 'User', 'Machine')]
        [string] $Target = 'Process'
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

    if ($Target -eq 'Process') {
        $pathParts = @($env:PATH -split ';' | Where-Object { $_ })
        if ($pathParts -notcontains $resolvedPath) {
            $env:PATH = "$resolvedPath;$env:PATH"
        }
        return
    }

    $currentPath = [Environment]::GetEnvironmentVariable('PATH', $Target)
    $pathParts = @($currentPath -split ';' | Where-Object { $_ })
    if ($pathParts -notcontains $resolvedPath) {
        [Environment]::SetEnvironmentVariable('PATH', "$resolvedPath;$currentPath", $Target)
    }
}

function Install-DscV3Standalone {
    [CmdletBinding()]
    param(
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope = 'CurrentUser',

        [string] $Version = 'latest',

        [string] $InstallDirectory = (Get-DscDefaultInstallDirectory -Scope $Scope),

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

    if (Test-Path $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }

    Write-Host "==> Extracting DSC"
    Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

    $dscExe = Get-ChildItem -Path $extractPath -Filter dsc.exe -Recurse | Select-Object -First 1
    if (-not $dscExe) {
        throw "The release asset '$($asset.name)' did not contain dsc.exe."
    }

    if (-not (Test-Path $InstallDirectory)) {
        New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Host "==> Installing to $InstallDirectory"
    Get-ChildItem -Path $dscExe.Directory.FullName -Force | Copy-Item -Destination $InstallDirectory -Recurse -Force

    Add-DirectoryToPath -Path $InstallDirectory -Target Process
    if ($PersistPath) {
        $target = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }
        Add-DirectoryToPath -Path $InstallDirectory -Target $target
        Write-Host "==> Added $InstallDirectory to $target PATH"
    }

    $installedDsc = Join-Path $InstallDirectory 'dsc.exe'
    Write-Host "==> Installed DSC: $installedDsc"
    & $installedDsc --version

    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    return $installedDsc
}

function Invoke-DscConfigSetFromUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [string] $DestinationPath = (Join-Path $env:TEMP 'ans-configure.yaml'),

        [string] $DscPath = 'dsc',

        [string] $ResourcePath
    )

    if ($ResourcePath) {
        $resolvedResourcePath = (Resolve-Path -LiteralPath $ResourcePath).Path
        $env:DSC_RESOURCE_PATH = $resolvedResourcePath
    }

    Write-Host "==> Downloading configuration"
    Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing

    Write-Host "==> Applying configuration: $DestinationPath"
    & $DscPath config set --file $DestinationPath
}

if ($InstallDirectory) {
    $installedDscPath = Install-DscV3Standalone -Scope $Scope -Version $Version -InstallDirectory $InstallDirectory -PersistPath:$PersistPath
} else {
    $installedDscPath = Install-DscV3Standalone -Scope $Scope -Version $Version -PersistPath:$PersistPath
}

if ($ConfigurationUri) {
    Invoke-DscConfigSetFromUrl -Uri $ConfigurationUri -DscPath $installedDscPath -ResourcePath $ResourcePath
}
