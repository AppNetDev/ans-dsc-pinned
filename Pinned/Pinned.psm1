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

Function New-PinnedAppResult {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [String]
        $Action,

        [Parameter(Mandatory)]
        [String]
        $Name,

        [Parameter(Mandatory)]
        [String]
        $DesiredEnsure,

        [Parameter(Mandatory)]
        [String]
        $DesiredVersion,

        [Parameter(Mandatory)]
        [Boolean]
        $PatchOnly,

        [Parameter(Mandatory)]
        [Boolean]
        $WasInDesiredState,

        [Parameter(Mandatory)]
        [Boolean]
        $IsInDesiredState,

        [Parameter(Mandatory)]
        [Hashtable]
        $State
    )

    $installed = If ($State.ContainsKey('Installed')) {
        [Boolean]$State.Installed
    }
    Else {
        $State.Ensure -eq 'Present'
    };

    $currentVersion = If ($State.ContainsKey('Version') -and $Null -ne $State.Version) {
        [String]$State.Version
    }
    Else {
        ''
    };

    $displayName = If ($State.ContainsKey('Name') -and -not [String]::IsNullOrWhiteSpace([String]$State.Name)) {
        [String]$State.Name
    }
    Else {
        $Name
    };

    $status = If ($WasInDesiredState) {
        If ($PatchOnly -and -not $installed) {
            'Skipped'
        }
        Else {
            'AlreadyInDesiredState'
        }
    }
    ElseIf ($IsInDesiredState) {
        'Changed'
    }
    Else {
        'NotInDesiredState'
    };

    [PSCustomObject]@{
        PSTypeName            = 'Pinned.App.Result'
        Name                  = $displayName
        Action                = $Action
        Status                = $status
        Changed               = (-not $WasInDesiredState) -and $IsInDesiredState
        WasInDesiredState     = $WasInDesiredState
        IsInDesiredState      = $IsInDesiredState
        DesiredEnsure         = $DesiredEnsure
        CurrentEnsure         = [String]$State.Ensure
        DesiredVersion        = $DesiredVersion
        CurrentVersion        = $currentVersion
        Installed             = $installed
        PatchOnly             = $PatchOnly
        ProductId             = If ($State.ContainsKey('ProductId')) { [String]$State.ProductId } Else { '' }
        Publisher             = If ($State.ContainsKey('Publisher')) { [String]$State.Publisher } Else { '' }
        UninstallString       = If ($State.ContainsKey('UninstallString')) { [String]$State.UninstallString } Else { '' }
    }
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

    $wasInDesiredState = Test-TargetResource @resourceParameters

    If ((-not $wasInDesiredState) -and $PSCmdlet.ShouldProcess($Name, $Action)) {
        Set-TargetResource @resourceParameters
    };

    $state = Get-TargetResource `
        -Ensure $ensure `
        -Name $Name `
        -InstallerPath $InstallerUri `
        -Version $Version

    $isInDesiredState = Test-TargetResource @resourceParameters

    New-PinnedAppResult `
        -Action $Action `
        -Name $Name `
        -DesiredEnsure $ensure `
        -DesiredVersion $Version `
        -PatchOnly ($Action -eq 'Update') `
        -WasInDesiredState $wasInDesiredState `
        -IsInDesiredState $isInDesiredState `
        -State $state
};

Export-ModuleMember -Function Set-PinnedApp
