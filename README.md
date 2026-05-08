# Pinned

[![Version](https://img.shields.io/badge/version-4.1.0-blue?style=flat-square)](https://github.com/AppNetOnline/ans-dsc-pinned/releases)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square&logo=windows&logoColor=white)](https://github.com/AppNetOnline/ans-dsc-pinned)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/license-Proprietary-red?style=flat-square)](https://github.com/AppNetOnline/ans-dsc-pinned)

**Install Windows applications that WinGet can't. Built for RMM tools, SYSTEM context, and exact version enforcement.**

Install from local paths, UNC shares, or HTTP/HTTPS URLs — lock to an exact version — run from any account including `NT AUTHORITY\SYSTEM`.

---

## Why Pinned?

WinGet is a user-space tool. It breaks in exactly the scenarios where automated deployment matters most.

| Capability | WinGet | Manual Deploy | **Pinned** |
|---|:---:|:---:|:---:|
| Runs as `NT AUTHORITY\SYSTEM` | ❌ | ✅ | ✅ |
| Works from RMM (NinjaRMM, Datto, etc.) | ❌ | ✅ | ✅ |
| Install from UNC share | ❌ | ✅ | ✅ |
| Install from HTTP/HTTPS URL | ⚠️ Limited | ❌ | ✅ |
| Installer hash verification | ❌ | ❌ | ✅ |
| Exact version pinning | ⚠️ Limited | ❌ | ✅ |
| Detect via file, GUID, or registry | ❌ | ❌ | ✅ |
| Uninstall support | ✅ | ❌ | ✅ |
| Pre/post install script hooks | ❌ | ❌ | ✅ |
| PatchOnly (update without fresh install) | ❌ | ❌ | ✅ |
| No user profile or App Installer required | ❌ | ✅ | ✅ |
| Declarative, idempotent configuration | ❌ | ❌ | ✅ |

---

## Which Product?

Pinned ships two runtimes built on the same core install engine.

| | **DSC v3** | **Classic DSC** |
|---|---|---|
| **Best for** | RMM tools, scheduled tasks, SYSTEM context | Interactive sessions, `winget configure` |
| **Runtime** | Standalone `dsc.exe` — no WinGet, no LCM, no user profile | PowerShell 5.1 + LCM |
| **Distribution** | GitHub Release zip | GitHub Packages (NuGet) |
| **Resource type** | `AppNetOnline.Pinned/App` | `Pinned\App` |

> **Not sure?** If you're deploying from an RMM or running as SYSTEM, use **DSC v3**. If you're using `winget configure` or the PowerShell LCM interactively, use **Classic DSC**.

---

## Quick Start — DSC v3

DSC v3 is purpose-built for unattended, SYSTEM-context deployment. It has no dependency on WinGet, the Microsoft Store, App Installer, or any user-profile state.

### 1. Install

Download and install `dsc.exe` and the Pinned resource in a single step:

```powershell
irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1" | iex
```

Or install and immediately apply a configuration:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/dscv3/firefox-dscv3.yaml'"
```

Additional install options:

```powershell
# Install for all users and persist dsc.exe on PATH
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -Scope AllUsers -PersistDscPath"

# Pin to a specific release
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ResourcePackageUri 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/download/v4.0.6-dscv3/Pinned.DSCv3.4.0.6.zip'"
```

Default install locations:

| Scope | `dsc.exe` | Pinned resource |
|---|---|---|
| `CurrentUser` (default) | `%LOCALAPPDATA%\Microsoft\DSC` | `%LOCALAPPDATA%\Microsoft\DSC\Resources\AppNetOnline.Pinned` |
| `AllUsers` | `%ProgramFiles%\DSC` | `%ProgramFiles%\DSC\Resources\AppNetOnline.Pinned` |

Verify the resource is discoverable after install:

```powershell
dsc resource list AppNetOnline.Pinned/App
```

### 2. Write a configuration

```yaml
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
```

### 3. Test and apply

```powershell
dsc config test --file "$env:TEMP\apps.yaml"
dsc config set  --file "$env:TEMP\apps.yaml"
```

---

## Quick Start — Classic DSC

### Installation

**Option 1 — winget configure (recommended)**

Installs the Pinned module and applies your configuration in one step:

```powershell
$wingetArgs = @(
    'configure'
    '--file', 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/.configurations/classic/winget-configure.yaml'
    '--accept-configuration-agreements'
    '--ignore-warnings'
)
winget @wingetArgs
```

Customise which applications are installed by editing [`.configurations/classic/winget-configure.yaml`](.configurations/classic/winget-configure.yaml).

**Option 2 — NuGet package**

Published to the [AppNetOnline GitHub Packages](https://github.com/orgs/AppNetOnline/packages) feed. Requires a GitHub PAT with `read:packages` scope — contact [@Sir-Jigston](https://github.com/Sir-Jigston) to request access.

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

EnsureApps
Start-DscConfiguration -Path .\EnsureApps -Wait -Verbose -Force
```

Or call `Set-PinnedApp` directly without a DSC configuration:

```powershell
Import-Module Pinned

$result = Set-PinnedApp `
    -Action       'Update' `
    -Name         'Mozilla Firefox (x64 en-US)' `
    -InstallerUri 'https://download-installer.cdn.mozilla.net/pub/firefox/releases/150.0.1/win64/en-US/Firefox%20Setup%20150.0.1.msi' `
    -Version      '150.0.1' `
    -Arguments    '/quiet REBOOT=ReallySuppress'

$result  # Pinned.App.Result — shows Status, Changed, CurrentVersion, etc.
```

---

## Reference

### Parameters

| Parameter | Type | Required | Description |
|---|---|:---:|---|
| `Name` | String | **Yes** | Display name of the application (used for registry lookup) |
| `InstallerPath` | String | **Yes** | Local path, UNC share, or HTTP/HTTPS URL to the installer |
| `Ensure` | String | No | `Present` (default) or `Absent` |
| `Version` | String | No | Exact version to enforce (e.g. `124.0.6367.82`) |
| `ProductId` | String | No | MSI Product GUID for detection instead of display name |
| `InstalledCheckFilePath` | String | No | Path to a file whose `ProductVersion` metadata is used for detection |
| `InstalledCheckScript` | String | No | PowerShell script block string that returns `$true` if installed |
| `Arguments` | String | No | Arguments passed to the installer |
| `ArgumentsForUninstall` | String | No | Arguments passed to the uninstaller |
| `NoRestart` | Boolean | No | Suppress automatic reboot after install |
| `UseUninstallString` | Boolean | No | Use the registry uninstall string instead of re-running the installer |
| `WorkingDirectory` | String | No | Working directory for the installer process |
| `Credential` | PSCredential | No | Credential for UNC share access or authenticated downloads |
| `ReturnCode` | UInt32[] | No | Additional exit codes to treat as success |
| `ProcessTimeout` | UInt32 | No | Installer process timeout in seconds |
| `DownloadTimeout` | UInt32 | No | HTTP download timeout in seconds |
| `PatchOnly` | Boolean | No | Skip install if the application is not already present |
| `ForceVersion` | Boolean | No | After install, forcibly write `DisplayVersion` to registry |
| `UseSemVer` | Boolean | No | Use SemVer range expressions for version comparison (requires `pspm`) |
| `FileHash` | String | No | Expected hash of the installer file |
| `HashAlgorithm` | String | No | `SHA1`, `SHA256` (default), `SHA384`, `SHA512`, `MD5`, `RIPEMD160` |
| `PreAction` | String | No | PowerShell script block string to run before install |
| `PostAction` | String | No | PowerShell script block string to run after install |
| `PreCopyFrom` | String | No | Source path for a file to copy before install |
| `PreCopyTo` | String | No | Destination path for `PreCopyFrom` |
| `LogLevel` | String | No | `None`, `Minimal`, `Moderate`, or `All` (default) |

### Installer Support

| Type | Extension | Notes |
|---|---|---|
| MSI | `.msi` | Runs via `msiexec.exe` |
| MSP | `.msp` | Runs via `msiexec.exe /p` |
| EXE | `.exe` | Runs directly with `Arguments` |

### Version Detection Priority

When multiple detection methods are configured, Pinned evaluates them in this order:

1. `InstalledCheckFilePath` — reads the file's `ProductVersion` metadata
2. `ProductId` — registry lookup by MSI GUID
3. `Name` — registry lookup by display name

### PatchOnly

When `PatchOnly = $true`, Pinned skips installation entirely if the application is not already present — it only enforces the version on existing installs. Use this when you want to update an app across a fleet without performing first-time installs on machines that legitimately don't have it.

```powershell
App Chrome {
    Ensure        = 'Present'
    Name          = 'Google Chrome'
    InstallerPath = '\\share\Chrome\126.0.0.0\ChromeSetup.exe'
    Version       = '126.0.0.0'
    PatchOnly     = $true
}
```

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

**Download from HTTPS with hash verification**

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

**Detect version via installed file**

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

**Uninstall an application**

```powershell
App OldApp {
    Ensure             = 'Absent'
    Name               = 'Legacy Application'
    InstallerPath      = ''
    UseUninstallString = $true
}
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
  classic/                      Example YAML for winget configure / Classic DSC
  dscv3/                        Example YAML for dsc.exe
```

---

## Author

Jarod Roberts — [@Sir-Jigston](https://github.com/Sir-Jigston)

## License

Copyright (c) 2022 Jarod Roberts. All rights reserved.
