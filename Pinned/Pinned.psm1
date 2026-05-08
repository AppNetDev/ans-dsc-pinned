#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Function ConvertTo-PinnedDscEnsure {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Update', 'Uninstall')]
        [String] 
        $Action
    )

    If ($Action -eq 'Uninstall') {
        Return 'Absent'
    };

    Return 'Present'
};

Function Import-PinnedAppResource {
    [CmdletBinding()]
    Param()

    $resourceModulePath = Join-Path $PSScriptRoot 'DSCResources\App\App.psm1'
    Import-Module -Name $resourceModulePath -Force -ErrorAction Stop
};

Function Set-PinnedApp {
    <#
    .SYNOPSIS
        Installs, updates, or uninstalls an app with the Pinned DSC resource.
    .EXAMPLE
        Set-PinnedApp -Action Install -Name 'Notepad++ (64-bit x64)' -InstallerUri 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe' -Version '8.9.4' -Arguments '/S'
    .EXAMPLE
        Set-PinnedApp -Action Update -Name 'Notepad++ (64-bit x64)' -InstallerUri 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe' -Version '8.9.4' -Arguments '/S'
    .EXAMPLE
        Set-PinnedApp -Action Uninstall -Name 'Notepad++ (64-bit x64)' -InstallerUri 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe' -Version '8.9.4' -Arguments '/S'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    Param(
        [Parameter()]
        [ValidateSet('Install', 'Update', 'Uninstall')]
        [String] 
        $Action = 'Install',

        [Parameter(Mandatory)]
        [String] 
        $Name,

        [Parameter(Mandatory)]
        [String] 
        $InstallerUri,

        [Parameter(Mandatory)]
        [String] 
        $Version,

        [Parameter(Mandatory)]
        [String] 
        $Arguments
    )

    Import-PinnedAppResource

    $ensure = ConvertTo-PinnedDscEnsure -Action $Action
    $resourceParameters = @{
        Ensure        = $ensure
        Name          = $Name
        InstallerPath = $InstallerUri
        Version       = $Version
        Arguments     = $Arguments
        PatchOnly     = $Action -eq 'Update'
    };

    If ($Action -eq 'Uninstall') {
        $resourceParameters.ArgumentsForUninstall = $Arguments
    };

    If (-not $PSCmdlet.ShouldProcess($Name, $Action)) {
        Return
    };

    If (-not (Test-TargetResource @resourceParameters)) {
        Set-TargetResource @resourceParameters
    };

    Get-TargetResource `
        -Ensure $ensure `
        -Name $Name `
        -InstallerPath $InstallerUri `
        -Version $Version
};

Export-ModuleMember -Function Set-PinnedApp
