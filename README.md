# Pinned

A PowerShell DSC resource that enforces Windows desktop applications at an exact version number. Install from local paths, UNC shares, or HTTP/HTTPS URLs — and guarantee the installed version never drifts.

## Requirements

- PowerShell 5.1+
- Windows with DSC support
- Optional: [`pspm`](https://www.powershellgallery.com/packages/pspm) module for SemVer range expressions (`UseSemVer`)

## Installation

### Option 1 — winget configure (recommended)

Installs the Pinned module and applies your app configuration in one step using [winget configure](https://learn.microsoft.com/en-us/windows/package-manager/configuration/):

```powershell
$wingetArgs = @(
    'configure'
    '--file', 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/winget-configure.yaml'
    '--accept-configuration-agreements'
    '--verbose-logs'
)
winget @wingetArgs
```

See [`.configurations/winget-configure.yaml`](.configurations/winget-configure.yaml) to customise which applications are installed.

### Option 2 — NuGet package (restricted)

The module is published to the [AppNetOnline GitHub Packages](https://github.com/orgs/AppNetOnline/packages) NuGet feed. Access requires a GitHub personal access token with `read:packages` scope — contact [@Sir-Jigston](https://github.com/Sir-Jigston) to request access.

Requires `Microsoft.PowerShell.PSResourceGet` (included with PowerShell 7.4+):

```powershell
$Cred = Get-Credential -UserName 'your-github-username' -Message 'Enter your read:packages PAT as the password'

Register-PSResourceRepository -Name 'AppNetOnline' `
    -Uri 'https://nuget.pkg.github.com/AppNetOnline/index.json' `
    -Trusted

Install-PSResource -Name Pinned -Repository 'AppNetOnline' -Credential $Cred -TrustRepository
```

### Option 3 — Manual

Copy the `Pinned` folder (containing `Pinned.psd1` and `DSCResources\`) into a PSModulePath location:

```powershell
Copy-Item -Recurse .\Pinned 'C:\Program Files\WindowsPowerShell\Modules\'
```

## Repository Layout

The PowerShell module lives in [`Pinned/`](Pinned/). Repository-level files such as `.configurations/`, `README.md`, and local helper scripts are not part of the published module package.

## DSC v3

This repository also publishes a command-based DSC v3 resource for `AppNetOnline.Pinned/App`. The DSC v3 package is distributed as a GitHub Release asset named `Pinned.DSCv3.zip`. It contains the command resource wrapper plus the shared `App.psm1` implementation, so it does not require the classic PowerShell DSC module to be installed first.

### Why DSC v3?

The DSC v3 path exists because `winget configure` can be difficult to run reliably from the Windows system context, such as during device management, RMM, scheduled task, or service-based automation. In that context, `winget` often behaves differently than it does in an interactive user session:

- `winget.exe` may not be discoverable on `PATH`
- the App Installer package may not be available to `NT AUTHORITY\SYSTEM`
- Microsoft Store/AppX registration can be user-scoped
- winget source state and package cache can differ per account
- configuration module discovery can depend on user profile paths
- troubleshooting failures is harder because the process has no normal desktop session

The DSC v3 bootstrap avoids those moving parts. It downloads the official Microsoft standalone `dsc.exe` from the [PowerShell/DSC GitHub releases](https://github.com/PowerShell/DSC/releases), installs a self-contained command resource package, points `DSC_RESOURCE_PATH` at that package for the current process, and runs a local YAML file. That makes it better suited to system-context automation because the execution path is explicit, portable, and does not depend on the interactive user's winget/App Installer state.

The generic bootstrap:

- installs the official Microsoft standalone DSC v3 executable if `dsc.exe` is missing
- downloads and extracts `Pinned.DSCv3.zip`
- installs the resource under a predictable DSC resource directory
- sets `DSC_RESOURCE_PATH` for the current process
- optionally downloads and applies a DSC v3 YAML configuration URL

Install the DSC v3 resource only:

```powershell
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1" | iex
```

Default install locations:

| Scope | DSC executable | Pinned DSC v3 resource |
|-------|----------------|------------------------|
| `CurrentUser` | `%LOCALAPPDATA%\Microsoft\DSC` | `%LOCALAPPDATA%\Microsoft\DSC\Resources\AppNetOnline.Pinned` |
| `AllUsers` | `%ProgramFiles%\DSC` | `%ProgramFiles%\DSC\Resources\AppNetOnline.Pinned` |

Apply the Firefox DSC v3 example:

```powershell
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Invoke-DscV3Firefox.ps1" | iex
```

Apply any DSC v3 YAML configuration URL with the generic bootstrap:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/firefox-dscv3.yaml'"
```

Install for all users and persist the DSC executable path:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1') } -Scope AllUsers -PersistDscPath"
```

Pin a specific DSC v3 package asset:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1') } -ResourcePackageUri 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/download/v4.0.3-dscv3/Pinned.DSCv3.4.0.3.zip'"
```

After installation, the resource is discoverable for the current process:

```powershell
dsc resource list AppNetOnline.Pinned/App
```

Example DSC v3 configuration:

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

Build the release package locally:

```powershell
.\Build-DscV3Release.ps1
```

This creates:

```text
dist\Pinned.DSCv3.zip
dist\Pinned.DSCv3.<version>.zip
```

Upload `Pinned.DSCv3.zip` to a GitHub Release so the default bootstrap URL resolves:

```text
https://github.com/AppNetOnline/ans-dsc-pinned/releases/latest/download/Pinned.DSCv3.zip
```

## Usage

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

## Parameters

| Parameter               | Type       | Required | Description |
|-------------------------|------------|----------|-------------|
| `Name`                  | String     | **Yes**  | Display name of the application (used for registry lookup) |
| `InstallerPath`         | String     | **Yes**  | Local path, UNC share path, or HTTP/HTTPS URL to the installer |
| `Ensure`                | String     | No       | `Present` (default) or `Absent` |
| `Version`               | String     | No       | Exact version to enforce (e.g. `124.0.6367.82`) |
| `ProductId`             | String     | No       | MSI Product GUID for detection instead of display name |
| `InstalledCheckFilePath`| String     | No       | Path to a file (e.g. exe) whose version is used for detection |
| `InstalledCheckScript`  | String     | No       | PowerShell script block string that returns `$true` if installed |
| `Arguments`             | String     | No       | Arguments passed to the installer |
| `ArgumentsForUninstall` | String     | No       | Arguments passed to the uninstaller |
| `NoRestart`             | Boolean    | No       | Suppress automatic reboot after install |
| `UseUninstallString`    | Boolean    | No       | Use the registry uninstall string instead of re-running the installer |
| `WorkingDirectory`      | String     | No       | Working directory for the installer process |
| `Credential`            | PSCredential | No    | Credential for UNC share access or authenticated downloads |
| `ReturnCode`            | UInt32[]   | No       | Additional exit codes to treat as success |
| `ProcessTimeout`        | UInt32     | No       | Installer process timeout in seconds |
| `DownloadTimeout`       | UInt32     | No       | HTTP download timeout in seconds |
| `PatchOnly`             | Boolean    | No       | Skip install if application is not already present |
| `ForceVersion`          | Boolean    | No       | After install, forcibly write `DisplayVersion` to registry |
| `UseSemVer`             | Boolean    | No       | Use SemVer range expressions for version comparison (requires `pspm`) |
| `FileHash`              | String     | No       | Expected hash of the installer file |
| `HashAlgorithm`         | String     | No       | Hash algorithm: `SHA1`, `SHA256` (default), `SHA384`, `SHA512`, `MD5`, `RIPEMD160` |
| `PreAction`             | String     | No       | PowerShell script block string to run before install |
| `PostAction`            | String     | No       | PowerShell script block string to run after install |
| `PreCopyFrom`           | String     | No       | Source path for a file to copy before install |
| `PreCopyTo`             | String     | No       | Destination path for `PreCopyFrom` |
| `LogLevel`              | String     | No       | `None`, `Minimal`, `Moderate`, or `All` (default) |

## Examples

### Install from a UNC share at an exact version

```powershell
App SevenZip {
    Ensure        = 'Present'
    Name          = '7-Zip 24.08 (x64)'
    InstallerPath = '\\fileserver\installers\7z2408-x64.msi'
    Version       = '24.8.0.0'
    ProductId     = '{00000000-0000-0000-0000-000000000000}'
}
```

### Download from HTTP/HTTPS with hash verification

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

### Uninstall an application

```powershell
App OldApp {
    Ensure           = 'Absent'
    Name             = 'Legacy Application'
    InstallerPath    = ''
    UseUninstallString = $true
}
```

### Enforce version via file detection

```powershell
App Chrome {
    Ensure                = 'Present'
    Name                  = 'Google Chrome'
    InstallerPath         = '\\share\Chrome\124.0.6367.82\ChromeSetup.exe'
    Version               = '124.0.6367.82'
    InstalledCheckFilePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    Arguments             = '/silent /install'
}
```

## PatchOnly

When `PatchOnly = $true`, the resource skips installation entirely if the application is not already present on the machine — it only enforces the version on existing installs. This is useful in scenarios where you want to update an app across a fleet but never perform a first-time install (e.g. the app is optional and some machines legitimately don't have it).

**Requirements:**
- The application must already be installed for any action to be taken
- `PatchOnly` is `$false` by default — omit it for normal install + enforce behaviour
- Combine with `Version` to upgrade in-place without triggering installs on machines that don't have the app

```powershell
App Chrome {
    Ensure        = 'Present'
    Name          = 'Google Chrome'
    InstallerPath = '\\share\Chrome\126.0.0.0\ChromeSetup.exe'
    Version       = '126.0.0.0'
    PatchOnly     = $true   # skip machines where Chrome is not installed
}
```

## Version Detection Priority

1. `InstalledCheckFilePath` — reads the file's `ProductVersion` metadata
2. `ProductId` — registry lookup by MSI GUID
3. `Name` — registry lookup by display name

## Installer Support

| Type | Extension | Detection |
|------|-----------|-----------|
| MSI  | `.msi`    | Runs via `msiexec.exe` |
| MSP  | `.msp`    | Runs via `msiexec.exe /p` |
| EXE  | `.exe`    | Runs directly with `Arguments` |

## Author

Jarod Roberts — [@Sir-Jigston](https://github.com/Sir-Jigston)

## License

Copyright (c) 2022 Jarod Roberts. All rights reserved.
