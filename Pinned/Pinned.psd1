@{
    ModuleVersion        = '4.1.3'
    GUID                 = 'a39e5014-b98f-4df3-ac52-feda586babe8'
    Author               = 'Jarod Roberts (github.com/Sir-Jigston)'
    CompanyName          = ''
    Copyright            = '(c) 2022 Jarod Roberts. All rights reserved.'
    Description          = 'PowerShell DSC Resource to ensure Windows Desktop Applications are installed or at the desired version using local, UNC, or remote (HTTP/HTTPS) installers.'
    PowerShellVersion    = '5.0'

    RootModule           = 'Pinned.psm1'

    FunctionsToExport    = @('Set-PinnedApp')
    CmdletsToExport      = @()
    AliasesToExport      = @()
    DscResourcesToExport = 'App'

    PrivateData          = @{
        PSData = @{
            Tags         = 'DesiredStateConfiguration', 'DSC', 'DSCResource'
            LicenseUri   = ''
            ProjectUri   = 'https://github.com/AppNetOnline/ans-dsc-pinned'
            ReleaseNotes = @'
4.1.3
- Added Version=latest support to install from latest installer URLs without pinning or enforcing an exact installed version.
- Set-PinnedApp Version is now optional for unpinned installs.

4.1.2
- Changed DSC v3 bootstrap to expose only the bundled Registry resource instead of the entire DSC install directory.
- Avoids noisy Microsoft.Windows.Appx discovery warnings while still supporting Microsoft.Windows/Registry configs.
- Made DSC settings repair best-effort so settings-file ACL issues do not block bootstrap.

4.1.1
- Updated DSC v3 bootstrap to repair DSC tracing settings without UTF-8 BOM issues.
- Updated DSC v3 bootstrap to preserve DSC bundled resources when setting DSC_RESOURCE_PATH.
- Updated DSC v3 bootstrap to require bundled Registry resources before reusing an existing dsc.exe.
- Added Windows PowerShell to process PATH before DSC discovery to quiet bundled Appx discovery warnings.
- Updated DSC v3 examples for Bitwarden browser extension dependencies, Office XML deployment, Visual Studio pinned versions, and quoted version values.

4.1.0
- Added DSC v3 command resource (AppNetOnline.Pinned/App) for system-context automation (RMM, scheduled tasks, SYSTEM account)
- Set-PinnedApp now returns a structured Pinned.App.Result object with Status, Changed, CurrentVersion, IsInDesiredState, and more
- Reorganized repository: dscv3/ at root, examples/dscv3/, .configurations/classic/ and .configurations/dscv3/

4.0.6
- Added Set-PinnedApp as a friendly module command for installing, updating, and uninstalling pinned applications without authoring DSC configuration YAML.
- Added Action-based app operations: Install, Update, and Uninstall.
- Added Install-PinnedAppDscV3.ps1 bootstrap for generating DSC v3 app configurations from parameters.
- Added ConfigurationPath support to Install-PinnedDscV3.ps1 so generated local configs can be applied by the existing bootstrap.
- Updated DSC v3 resource metadata and release package version to 4.0.6.

4.0.5
Fixed error propagation from Set-TargetResource
Improved did-not-reach-desired-state error to include desired version

4.0.4
- Fixed strict mode propagation into PreAction/PostAction scriptblocks causing failures in external scripts that use .Count on scalar objects
- Fixed Invoke-ScriptBlock null-Arguments guard (was always calling Invoke($null) instead of Invoke() when no arguments provided)

4.0.3
- Updated winget configuration bootstrap to prefer the local WinGet configuration module path.

4.0.0
- Added HTTP/HTTPS installer download support via BITS (with Invoke-WebRequest fallback)
- Fixed version enforcement: Test-TargetResource now requires an exact version match
- Fixed Get-TargetResource InstalledCheckFilePath branch (undefined MsiProductID bug)
- Removed application-specific hardcoding; ForceVersion is now a generic registry write
- Fixed Get-SemanticVersion crash when version string has fewer than 4 components
- ForceVersion is now a boolean in both psm1 and schema.mof (was untyped/string)
- Added UseSemVer to schema.mof
- Unified temp file cleanup (UNC copies and HTTP downloads are both removed after install)
- Fixed exit code 1603 check (exact int comparison instead of -like string match)
'@
        }
    }
}
