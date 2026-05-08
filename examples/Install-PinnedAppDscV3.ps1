#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a Pinned app DSC v3 configuration from parameters and applies it.
.EXAMPLE
    iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedAppDscV3.ps1') } -Action Install -Name 'Notepad++ (64-bit x64)' -InstallerUri 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe' -Version '8.9.4' -Arguments '/S'"
.EXAMPLE
    iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedAppDscV3.ps1') } -Action Uninstall -Name 'Notepad++ (64-bit x64)' -InstallerUri 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe' -Version '8.9.4' -Arguments '/S'"
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall')]
    [string] $Action = 'Install',

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $InstallerUri,

    [Parameter(Mandatory)]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $Arguments,

    [string] $ResourceName = 'InstallPinnedApp',

    [string] $BootstrapUri = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1',

    [string] $ResourcePackageUri = 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/download/v4.0.6-dscv3/Pinned.DSCv3.4.0.6.zip',

    [string] $ResourcePackagePath,

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $PersistDscPath,

    [switch] $SkipDscInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Function ConvertTo-DscEnsure {
    Param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update', 'Uninstall')]
        [string] $Value
    )

    If ($Value -eq 'Install' -or $Value -eq 'Update') {
        Return 'Present'
    };

    If ($Value -eq 'Uninstall') {
        Return 'Absent'
    };

    Return 'Present'
};

Function ConvertTo-YamlScalar {
    Param(
        [AllowNull()]
        [string] $Value
    )

    If ($Null -eq $Value) {
        Return "''"
    };

    Return "'" + ($Value -replace "'", "''") + "'"
};

$dscEnsure = ConvertTo-DscEnsure -Value $Action
$patchOnly = $Action -eq 'Update'
$configurationPath = Join-Path $env:TEMP ('pinned-app-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))

$lines = @(
    '$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json',
    'resources:',
    ('  - name: {0}' -f $ResourceName),
    '    type: AppNetOnline.Pinned/App',
    '    properties:',
    ('      Ensure: {0}' -f $dscEnsure),
    ('      Name: {0}' -f (ConvertTo-YamlScalar -Value $Name)),
    ('      InstallerPath: {0}' -f (ConvertTo-YamlScalar -Value $InstallerUri))
);

If ($Version) {
    $lines += ('      Version: {0}' -f (ConvertTo-YamlScalar -Value $Version))
};

If ($Arguments) {
    $lines += ('      Arguments: {0}' -f (ConvertTo-YamlScalar -Value $Arguments))
};

$lines += ('      PatchOnly: {0}' -f $patchOnly.ToString().ToLowerInvariant())

Set-Content -Path $configurationPath -Value $lines -Encoding UTF8

$bootstrapParameters = @{
    ConfigurationPath  = $configurationPath
    ResourcePackageUri = $ResourcePackageUri
    Scope              = $Scope
    PersistDscPath     = $PersistDscPath
    SkipDscInstall     = $SkipDscInstall
};

If ($ResourcePackagePath) {
    $bootstrapParameters.ResourcePackagePath = $ResourcePackagePath
};

$localBootstrap = If (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Join-Path $PSScriptRoot 'Install-PinnedDscV3.ps1'
}
Else {
    $Null
}

Try {
    If ($localBootstrap -and (Test-Path -LiteralPath $localBootstrap)) {
        & $localBootstrap @bootstrapParameters
        Return
    };

    $bootstrapScript = Invoke-RestMethod -Uri $BootstrapUri
    & ([scriptblock]::Create($bootstrapScript)) @bootstrapParameters
}
Finally {
    Remove-Item -LiteralPath $configurationPath -Force -ErrorAction SilentlyContinue
};
