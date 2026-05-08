# Pinned

A PowerShell DSC resource that enforces Windows desktop applications at an exact version number. Install from local paths, UNC shares, or HTTP/HTTPS URLs — and guarantee the installed version never drifts.

This repo ships two products built on the same core:

| | **Classic DSC** | **DSC v3** |
|---|---|---|
| **Runtime** | PowerShell 5.1 + LCM / winget configure | Standalone `dsc.exe` |
| **Best for** | Interactive sessions, winget configure | System context (RMM, scheduled tasks, SYSTEM) |
| **Distribution** | GitHub Packages (NuGet) | GitHub Release zip |

---

## Quick Start

### Classic DSC

```powershell
# 1. Install the module (manual — run from repo root as Administrator)
Copy-Item -Recurse '.\Pinned' "$env:ProgramFiles\WindowsPowerShell\Modules\"

# 2. Declare a configuration
Configuration EnsureApps {
    Import-DscResource -ModuleName Pinned

    Node 'localhost' {
        App Firefox {
            Ensure        = 'Present'
            Name          = 'Mozilla Firefox (x64 en-US)'
            InstallerPath = 'https://download-installer.cdn.mozilla.net/pub/firefox/releases/150.0.1/win64/en-US/Firefox%20Setup%20150.0.1.msi'
            Version       = '150.0.1'
            Arguments     = '/quiet REBOOT=ReallySuppress'
        }
    }
}

# 3. Compile to MOF and apply
EnsureApps
Start-DscConfiguration -Path .\EnsureApps -Wait -Verbose -Force
```

Or call `Set-PinnedApp` directly without a DSC configuration:

```powershell
Import-Module Pinned

$result = Set-PinnedApp `
    -Name          'Mozilla Firefox (x64 en-US)' `
    -InstallerPath 'https://download-installer.cdn.mozilla.net/pub/firefox/releases/150.0.1/win64/en-US/Firefox%20Setup%20150.0.1.msi' `
    -Version       '150.0.1' `
    -Action        'Update'

$result  # Pinned.App.Result — shows Status, Changed, CurrentVersion, etc.
```

### DSC v3

```powershell
# 1. Download and install dsc.exe + the Pinned resource in one step
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1" | iex

# 2. Write a configuration file
@'
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: Firefox
    type: AppNetOnline.Pinned/App
    properties:
      Ensure: Present
      Name: Mozilla Firefox (x64 en-US)
      InstallerPath: https://download-installer.cdn.mozilla.net/pub/firefox/releases/150.0.1/win64/en-US/Firefox%20Setup%20150.0.1.msi
      Version: 150.0.1
      Arguments: /quiet REBOOT=ReallySuppress
      PatchOnly: true
'@ | Set-Content "$env:TEMP\apps.yaml"

# 3. Test (dry run) then apply
dsc config test --file "$env:TEMP\apps.yaml"
dsc config set  --file "$env:TEMP\apps.yaml"
```

Or use a ready-made example configuration from this repo:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/dscv3/firefox-dscv3.yaml'"
```

---

## Classic DSC

### Requirements

- PowerShell 5.1+
- Windows with DSC support
- Optional: [`pspm`](https://www.powershellgallery.com/packages/pspm) for SemVer range expressions (`UseSemVer`)

### Installation

**Option 1 — winget configure (recommended)**

Installs the Pinned module and applies your app configuration in one step:

```powershell
$wingetArgs = @(
    'configure'
    '--file', 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/classic/winget-configure.yaml'
    '--accept-configuration-agreements'
    '--verbose-logs'
)
winget @wingetArgs
```

Customise which applications are installed by editing [`.configurations/classic/winget-configure.yaml`](.configurations/classic/winget-configure.yaml).

**Option 2 — NuGet package (restricted)**

Published to the [AppNetOnline GitHub Packages](https://github.com/orgs/AppNetOnline/packages) NuGet feed. Access requires a GitHub PAT with `read:packages` scope — contact [@Sir-Jigston](https://github.com/Sir-Jigston) to request access.

Requires `Microsoft.PowerShell.PSResourceGet` (included with PowerShell 7.4+):

```powershell
$Cred = Get-Credential -UserName 'your-github-username' -Message 'Enter your read:packages PAT as the password'

Register-PSResourceRepository -Name 'AppNetOnline' `
    -Uri 'https://nuget.pkg.github.com/AppNetOnline/index.json' `
    -Trusted

Install-PSResource -Name Pinned -Repository 'AppNetOnline' -Credential $Cred -TrustRepository
```

**Option 3 — Manual**

```powershell
Copy-Item -Recurse .\Pinned 'C:\Program Files\WindowsPowerShell\Modules\'
```

### Usage

```powershell
Configuration MyApps {
    Import-DscResource -ModuleName Pinned

    Node 'localhost' {
        App GoogleChrome {
            Ensure        = 'Present'
            Name          = 'Google Chrome'
            InstallerPath = 'https://dl.google.com/release2/chrome/...'
            Version       = '124.0.6367.82'
        }
    }
}
```

### Parameters

| Parameter               | Type         | Required | Description |
|-------------------------|--------------|----------|-------------|
| `Name`                  | String       | **Yes**  | Display name of the application (used for registry lookup) |
| `InstallerPath`         | String       | **Yes**  | Local path, UNC share, or HTTP/HTTPS URL to the installer |
| `Ensure`                | String       | No       | `Present` (default) or `Absent` |
| `Version`               | String       | No       | Exact version to enforce (e.g. `124.0.6367.82`) |
| `ProductId`             | String       | No       | MSI Product GUID for detection instead of display name |
| `InstalledCheckFilePath`| String       | No       | Path to a file whose `ProductVersion` metadata is used for detection |
| `InstalledCheckScript`  | String       | No       | PowerShell script block string that returns `$true` if installed |
| `Arguments`             | String       | No       | Arguments passed to the installer |
| `ArgumentsForUninstall` | String       | No       | Arguments passed to the uninstaller |
| `NoRestart`             | Boolean      | No       | Suppress automatic reboot after install |
| `UseUninstallString`    | Boolean      | No       | Use the registry uninstall string instead of re-running the installer |
| `WorkingDirectory`      | String       | No       | Working directory for the installer process |
| `Credential`            | PSCredential | No       | Credential for UNC share access or authenticated downloads |
| `ReturnCode`            | UInt32[]     | No       | Additional exit codes to treat as success |
| `ProcessTimeout`        | UInt32       | No       | Installer process timeout in seconds |
| `DownloadTimeout`       | UInt32       | No       | HTTP download timeout in seconds |
| `PatchOnly`             | Boolean      | No       | Skip install if the application is not already present |
| `ForceVersion`          | Boolean      | No       | After install, forcibly write `DisplayVersion` to registry |
| `UseSemVer`             | Boolean      | No       | Use SemVer range expressions for version comparison (requires `pspm`) |
| `FileHash`              | String       | No       | Expected hash of the installer file |
| `HashAlgorithm`         | String       | No       | Hash algorithm: `SHA1`, `SHA256` (default), `SHA384`, `SHA512`, `MD5`, `RIPEMD160` |
| `PreAction`             | String       | No       | PowerShell script block string to run before install |
| `PostAction`            | String       | No       | PowerShell script block string to run after install |
| `PreCopyFrom`           | String       | No       | Source path for a file to copy before install |
| `PreCopyTo`             | String       | No       | Destination path for `PreCopyFrom` |
| `LogLevel`              | String       | No       | `None`, `Minimal`, `Moderate`, or `All` (default) |

### Examples

**Install from a UNC share at an exact version**

```powershell
App SevenZip {
    Ensure        = 'Present'
    Name          = '7-Zip 24.08 (x64)'
    InstallerPath = '\\fileserver\installers\7z2408-x64.msi'
    Version       = '24.8.0.0'
    ProductId     = '{00000000-0000-0000-0000-000000000000}'
}
```

**Download from HTTP/HTTPS with hash verification**

```powershell
App VsCode {
    Ensure        = 'Present'
    Name          = 'Microsoft Visual Studio Code'
    InstallerPath = 'https://update.code.visualstudio.com/1.89.0/win32-x64/stable'
    Version       = '1.89.0'
    Arguments     = '/VERYSILENT /NORESTART'
    FileHash      = 'ABC123...'
    HashAlgorithm = 'SHA256'
}
```

**Uninstall an application**

```powershell
App OldApp {
    Ensure             = 'Absent'
    Name               = 'Legacy Application'
    InstallerPath      = ''
    UseUninstallString = $true
}
```

**Enforce version via file detection**

```powershell
App Chrome {
    Ensure                 = 'Present'
    Name                   = 'Google Chrome'
    InstallerPath          = '\\share\Chrome\124.0.6367.82\ChromeSetup.exe'
    Version                = '124.0.6367.82'
    InstalledCheckFilePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    Arguments              = '/silent /install'
}
```

### PatchOnly

When `PatchOnly = $true`, the resource skips installation entirely if the application is not already present — it only enforces the version on existing installs. Useful when you want to update an app across a fleet without performing first-time installs on machines that legitimately don't have it.

```powershell
App Chrome {
    Ensure        = 'Present'
    Name          = 'Google Chrome'
    InstallerPath = '\\share\Chrome\126.0.0.0\ChromeSetup.exe'
    Version       = '126.0.0.0'
    PatchOnly     = $true
}
```

### Version Detection Priority

1. `InstalledCheckFilePath` — reads the file's `ProductVersion` metadata
2. `ProductId` — registry lookup by MSI GUID
3. `Name` — registry lookup by display name

### Installer Support

| Type | Extension | Notes |
|------|-----------|-------|
| MSI  | `.msi`    | Runs via `msiexec.exe` |
| MSP  | `.msp`    | Runs via `msiexec.exe /p` |
| EXE  | `.exe`    | Runs directly with `Arguments` |

---

## DSC v3

### Why DSC v3?

`winget configure` can be unreliable from the Windows system context (RMM tools, scheduled tasks, `NT AUTHORITY\SYSTEM`). In that context:

- `winget.exe` may not be on `PATH`
- App Installer may not be available to SYSTEM
- Microsoft Store/AppX registration is user-scoped
- Package cache and source state can differ per account
- Module discovery can depend on user profile paths

The DSC v3 path avoids those moving parts. It downloads the official Microsoft standalone `dsc.exe`, installs a self-contained command resource package, and runs a local YAML file — no winget, no LCM, no user profile dependencies.

### Installation

Install the resource only (uses latest release):

```powershell
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1" | iex
```

Install and immediately apply a configuration:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/dscv3/firefox-dscv3.yaml'"
```

Install for all users and persist the DSC executable on `PATH`:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -Scope AllUsers -PersistDscPath"
```

Pin a specific release:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ResourcePackageUri 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/download/v4.0.6-dscv3/Pinned.DSCv3.4.0.6.zip'"
```

Apply the Firefox example directly:

```powershell
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Invoke-DscV3Firefox.ps1" | iex
```

Default install locations:

| Scope | DSC executable | Pinned DSC v3 resource |
|-------|----------------|------------------------|
| `CurrentUser` | `%LOCALAPPDATA%\Microsoft\DSC` | `%LOCALAPPDATA%\Microsoft\DSC\Resources\AppNetOnline.Pinned` |
| `AllUsers` | `%ProgramFiles%\DSC` | `%ProgramFiles%\DSC\Resources\AppNetOnline.Pinned` |

After installation, verify the resource is discoverable:

```powershell
dsc resource list AppNetOnline.Pinned/App
```

### Example configuration

```yaml
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: InstallFirefox
    type: AppNetOnline.Pinned/App
    properties:
      Ensure: Present
      Name: Mozilla Firefox (x64 en-US)
      InstallerPath: https://download-installer.cdn.mozilla.net/pub/firefox/releases/150.0.1/win64/en-US/Firefox%20Setup%20150.0.1.msi
      Version: 150.0.1
      Arguments: /quiet REBOOT=ReallySuppress
      PatchOnly: true
```

### Building the release package

`Build-DscV3Release.ps1` is a local development script (not committed to the repo). Run it from the repo root to produce the release zip:

```powershell
.\Build-DscV3Release.ps1
```

Output:

```
dist\Pinned.DSCv3.zip
dist\Pinned.DSCv3.<version>.zip
```

Upload `Pinned.DSCv3.zip` to a GitHub Release so the default bootstrap URL resolves:

```
https://github.com/AppNetOnline/ans-dsc-pinned/releases/latest/download/Pinned.DSCv3.zip
```

---

## Repository Layout

```
Pinned/                         Classic DSC module (published to GitHub Packages)
  Pinned.psd1                   Module manifest
  Pinned.psm1                   Set-PinnedApp function
  DSCResources/App/
    App.psm1                    Core install/detect/uninstall logic (shared by both products)
    App.schema.mof              Classic DSC schema

dscv3/                          DSC v3 command resource (distributed as Pinned.DSCv3.zip)
  Pinned.App.ps1                JSON stdin/stdout handler
  Pinned.App.cmd                Launcher (finds PowerShell, invokes Pinned.App.ps1)
  Pinned.App.dsc.resource.json  DSC v3 resource manifest

examples/dscv3/                 Bootstrap scripts for the DSC v3 product
.configurations/
  classic/                      Example YAML for winget configure / classic DSC
  dscv3/                        Example YAML for dsc.exe
```

---

## Author

Jarod Roberts — [@Sir-Jigston](https://github.com/Sir-Jigston)

## License

Copyright (c) 2022 Jarod Roberts. All rights reserved.
