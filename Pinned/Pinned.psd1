@{
    ModuleVersion        = '4.0.3'
    GUID                 = 'a39e5014-b98f-4df3-ac52-feda586babe8'
    Author               = 'Jarod Roberts (github.com/Sir-Jigston)'
    CompanyName          = ''
    Copyright            = '(c) 2022 Jarod Roberts. All rights reserved.'
    Description          = 'PowerShell DSC Resource to ensure Windows Desktop Applications are at the desired version using local, UNC, or remote (HTTP/HTTPS) installers.'
    PowerShellVersion    = '5.0'

    FunctionsToExport    = @()
    CmdletsToExport      = @()
    AliasesToExport      = @()
    DscResourcesToExport = 'App'

    PrivateData          = @{
        PSData = @{
            Tags         = 'DesiredStateConfiguration', 'DSC', 'DSCResource'
            LicenseUri   = ''
            ProjectUri   = 'https://github.com/AppNetOnline/ans-dsc-pinned'
            ReleaseNotes = @'
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
