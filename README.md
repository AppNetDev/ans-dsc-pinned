# Pinned

[![Version](https://img.shields.io/badge/version-4.1.5-blue?style=flat-square)](https://github.com/AppNetDev/ans-dsc-pinned/releases)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square&logo=windows&logoColor=white)](https://github.com/AppNetDev/ans-dsc-pinned)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/license-Proprietary-red?style=flat-square)](https://github.com/AppNetDev/ans-dsc-pinned)

**Install Windows applications that WinGet can't. Built for RMM tools, SYSTEM context, and version-aware enforcement.**

Install from local paths, UNC shares, or HTTP/HTTPS URLs — lock to an exact version or install unpinned latest releases — run from any account including `NT AUTHORITY\SYSTEM`.

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
irm "https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1" | iex
```

Or install and immediately apply a configuration:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ConfigurationUri 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/.configurations/dscv3/firefox-dscv3.yaml'"
```

Additional install options:

```powershell
# Install for all users and persist dsc.exe on PATH
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -Scope AllUsers -PersistDscPath"

# Pin to a specific release
iex "& { $(irm 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/examples/dscv3/Install-PinnedDscV3.ps1') } -ResourcePackageUri 'https://github.com/AppNetDev/ans-dsc-pinned/releases/download/v4.0.6-dscv3/Pinned.DSCv3.4.0.6.zip'"
```

Fresh installations resolve the latest stable DSC release from GitHub (currently **3.3.0**, released September 17, 2026). The bootstrap supports both the DSC 3.3 Registry manifest collection and the single-resource manifest used by earlier releases. It reuses an existing usable DSC installation; rerunning it does not automatically upgrade DSC. To install a newer runtime explicitly, use `Install-DscV3Standalone.ps1 -Version latest` first, then rerun the Pinned bootstrap. Use `-DscVersion v3.3.0` on the Pinned bootstrap to select that runtime when installation is needed.

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

### SentinelOne recovery

Use the [SentinelOne repair configuration](.configurations/dscv3/sentinelone-repair-dscv3.yaml)
and [runner instructions](examples/dscv3/SentinelOneRepair.md) to recover the service,
install missing agent binaries from the ConnectWise MSI, or explicitly request a bind
with a runtime site token.
For an existing unhealthy agent, `-Mode Upgrade -TestOnly` tests a signed MSI target;
`-Mode Upgrade` applies an approved newer package through the vendor installer.
See [MSI upgrade recovery](dscv3/README.md) for validation and reboot behavior.

### SentinelOne uninstall

Run [Uninstall-SentinelOneAgent.ps1](Uninstall-SentinelOneAgent.ps1) elevated or as
SYSTEM. It is standalone and can be executed directly from an `iwr` download:

```powershell
$uri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Uninstall-SentinelOneAgent.ps1'
$script = [scriptblock]::Create((iwr -Uri $uri -UseBasicParsing).Content)
& $script -UninstallPassword $AgentUninstallPassphrase -WhatIf
& $script -UninstallPassword $AgentUninstallPassphrase
```

`-UninstallToken`, `-AgentPassphrase`, and `-Passphrase` are aliases for
`-UninstallPassword`. Supply the **agent uninstall passphrase**, retrieved at
runtime from your approved secret store; site registration and API tokens do not
authorize removal. Arguments are passed to the script block as data, so spaces
and PowerShell metacharacters in the passphrase are preserved. Quotes, line
breaks, NUL, and a trailing backslash are rejected before native invocation.
For reviewed automation, pin the download URL to the approved commit SHA.

Local execution:

```powershell
.\Uninstall-SentinelOneAgent.ps1 -UninstallToken $AgentUninstallPassphrase -Confirm:$false
```

The target is the local SentinelOne agent. The script resolves `uninstall.exe`
beside the registered `SentinelAgent` service executable and requires a valid
SentinelOne/Sentinel Labs signature. If that binary is unavailable, it uses one
unambiguous registered SentinelOne MSI product code with `UNINSTALL_KEY`. It
does not execute arbitrary registry uninstall strings. Missing/ambiguous targets
fail with instructions to repair the agent or obtain its approved installer.
**Verify before acting:** validate the installed agent version's CLI support and
perform a pilot removal before fleet rollout. See the distributor's
[uninstall guidance](https://support.guardz.com/en/articles/11647145-sentinelone-agent-policies-installation)
for passphrase and MSI requirements.

Removal ends endpoint protection on this host. Coordinate replacement coverage
and retain an approved installer and enrollment token as the recovery path.
There is no automatic reinstall or reboot. Exit codes `3010` and `1641` produce
`Outcome = RestartRequired`; `1641` means the vendor reports a restart initiated
despite restart suppression. Reboot in the approved window and rerun to verify
absence. Exit `0` must also pass local service and product-registration checks
within `-VerificationTimeoutSeconds` (default 60). Remaining registrations make
the operation fail rather than claim successful removal. Absence means those
local registrations are gone; it does not verify console decommissioning or
removal of every driver or residual file.

Results include changed/unchanged/skipped/failed counts, native exit code,
`RestartRequired`, `RemovalVerified`, and `LogPath`. Already absent is a no-op.
Errors terminate execution. Timestamped start/end logs are written under
`C:\ANS\SentinelOne\Logs`; the passphrase and vendor output are excluded.
The native command line necessarily contains the passphrase and can be captured
by privileged process auditing; do not put literal secrets in command history or
transcripts. On timeout, the installer is left running; inspect its state before
retrying. `-WhatIf` performs detection and target validation without removal or
log creation. No DSC installation or companion download is needed.

Run `tests\Test-SentinelOneUninstall.ps1` for isolated checks that never execute
the vendor uninstaller or modify the installed agent.

#### Manual cleanup after incomplete uninstall (no passphrase)

The supplied incomplete-uninstall procedure is implemented separately in
[`Clear-SentinelOneAgentRemnants.ps1`](Clear-SentinelOneAgentRemnants.ps1).
It does not invoke the vendor uninstaller and does not require a passphrase:

```powershell
iwr 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Clear-SentinelOneAgentRemnants.ps1' -UseBasicParsing | iex
```

Run elevated in native 64-bit PowerShell. For a preview, download the script and
invoke it with `-WhatIf -Verbose`. This is destructive cleanup of the local agent
remnants, including the listed service/class/IFEO/autologger keys, named startup
values, verified SentinelOne GUID uninstall registrations, and the three listed
directories. Each target must be backed up before it can be deleted; folder
backups preserve vendor logs. Backups/manifests are restricted to Administrators
and SYSTEM under `C:\ANS\SentinelOne\CleanupBackups`; operational logs are under
`C:\ANS\SentinelOne\Logs`.

Registry backups normally use `reg.exe export`. If that executable fails but the
key is readable in-process, cleanup falls back to a verified `.registry.clixml`
snapshot. `Manifest.json` records `BackupFormat: RegistryClixml` and its path.
The snapshot contains the original registry path, each relative subkey, named and
default values with their registry kinds, raw expandable strings, and security
descriptors. A failed or incomplete snapshot still blocks deletion of that target.
Read snapshots with `Import-Clixml`; they are not files for `reg.exe import`.
For selective restoration, recreate only the required keys/values using their
recorded kinds and data; recorded SDDL describes the original permissions. Restore
only the named SentinelOne values in shared startup keys, not the entire shared key.

Locked/inaccessible targets are retained where backup cannot complete; failed
deletions may be partial. Backed-up files that resist immediate deletion are
queued using `MoveFileExW(MOVEFILE_DELAY_UNTIL_REBOOT)`, with files before
directories and directories deepest first. Existing deletion requests are reused;
unrelated rename/deletion requests are preserved. The native call passes a true
NULL destination (PowerShell `$null` alone becomes an empty string for a .NET
string parameter and does not request deletion). Queuing does not prove deletion.
`ScheduledForDeletion`, `AlreadyScheduled`, and `ScheduledTargets` report accepted
requests; `RebootDeletions.json` in the backup directory and the operational log
record them. `Outcome: RebootDeletionScheduled` requires a reboot and a verification
rerun before reinstalling, even if the queued paths have since disappeared.
To cancel before reboot, use that receipt to remove only the matching deletion
pairs from Session Manager's `PendingFileRenameOperations`; never clear the whole
value or overwrite unrelated pending operations. Retain the remnant backups for
selective restoration if needed.

The script also backs up/removes service and driver registration keys whose
SentinelOne-specific names and executable paths positively identify the product
inside one of the three cleanup directories. This includes registrations omitted
from the manual list, such as network monitor and ELAM. `RemainingComponents`
reports registrations still present; their directory is not queued until those
registrations are removed. No driver is forcibly unloaded.

Other eligible targets continue. `CleanupIncomplete` and `RemainingTargets`
identify unfinished work that could not be removed or fully queued. Follow the original ownership
and Full Control steps only for the affected registry keys; this script does not
change ownership or forcibly unload drivers. The supplied HKCU toast-value step
applies only to the caller's user hive; SYSTEM/service contexts skip that value.
Shared startup keys retain all unrelated values.

Reboot after cleanup, retry any remaining targets, then reinstall the approved
agent using the site token and confirm protection and destination-console check-in.
The MSI upgrade-only recovery command cannot install a fully removed agent.
Backups are remnants/logs, not a working-agent rollback; use the manifest for
selective restoration and never restore whole shared startup keys over newer data.
`tests\Test-SentinelOneManualCleanup.ps1` uses temporary fixtures only.

#### Force uninstall and remnant cleanup (passkey required)

Use the same standalone download with `-ForceCleanup` (`-Force` is an alias):

```powershell
$uri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Uninstall-SentinelOneAgent.ps1'
$script = [scriptblock]::Create((iwr -Uri $uri -UseBasicParsing).Content)
& $script -ForceCleanup -Passkey $AgentUninstallPassphrase -WhatIf -Verbose
& $script -ForceCleanup -Passkey $AgentUninstallPassphrase -Confirm:$false
```

Run in elevated native 64-bit PowerShell on 64-bit Windows. The passkey is
required even for a force preview, and must be accepted by the vendor uninstall
operation before any remnant deletion. A failed/timed-out uninstall blocks
cleanup; `3010`/`1641` defer cleanup for reboot. If registration is already gone,
the script cannot validate a passkey and stops; use vendor Support for that
orphaned-agent case. Merely supplying a nonempty parameter does not authorize
registry deletion.

After vendor exit `0`, stopped services/drivers are required before cleanup.
The fixed allowlist covers the pasted incomplete-uninstall procedure's
SentinelAgent/Monitor/HelperService/StaticEngine service keys, named autologgers,
machine class/IFEO entries, `Sentinel Agent` uninstall key and startup values,
plus these exact folders on the host's Windows/program-data/program-files drives:

- `%SystemRoot%\System32\drivers\SentinelOne`
- `%ProgramData%\Sentinel`
- `%ProgramW6432%\SentinelOne`

`-WhatIf -Verbose` lists the exact scope. Shared startup keys keep their other
values. `LogProcessorService` is eligible only if its ImagePath points inside a
`SentinelOne` folder. HKCU is excluded because SYSTEM/RMM's current-user hive is
not the interactive user's. There is no broad registry search, ownership
takeover, protection bypass, or forced driver unload. Access-denied and files-in-use
errors stop the operation. Reparse points in a cleanup directory or its ancestors
are rejected before recursive operations.

All existing eligible keys are exported with `reg.exe export`, and folders are
copied **before any remnant deletion**, into an Administrators/SYSTEM-only run
directory under `C:\ANS\SentinelOne\CleanupBackups`. Vendor logs are preserved
in those copies. `Manifest.json` maps each backup to its original target; the
operational log records the backup path and each completed deletion. A backup
failure blocks deletion; a later deletion failure can leave partial cleanup,
so inspect the log before retrying. `CleanupChanged`, `CleanupSkipped`,
`CleanupVerified`, and `BackupPath` describe completed cleanup in successful results.

Plan a reboot after any manual cleanup; the script reports `RestartRequired`
and never schedules one. Verify local removal after reboot, then reinstall an
approved agent and confirm console connectivity. The recovery path for endpoint
protection is the approved installer and enrollment token. Registry exports are
remnant backups, not a working-agent rollback or a system-state backup. If Support
requires restoration, use the manifest to restore only the affected keys/values
and files; a startup-key export contains other values and must not be imported
wholesale over newer configuration. Registry exports do not preserve registry ACLs.
See [Microsoft's registry export reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-export).

`tests\Test-SentinelOneForceCleanup.ps1` verifies the allowlist, active-component
blocks, real backup/deletion of temporary fixtures, backup failure, and junction
rejection. It never deletes live SentinelOne data.

## Quick Start — Classic DSC

### Installation

**Option 1 — winget configure (recommended)**

Installs the Pinned module and applies your configuration in one step:

```powershell
$wingetArgs = @(
    'configure'
    '--file', 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/.configurations/classic/winget-configure.yaml'
    '--accept-configuration-agreements'
    '--ignore-warnings'
)
winget @wingetArgs
```

Customise which applications are installed by editing [`.configurations/classic/winget-configure.yaml`](.configurations/classic/winget-configure.yaml).

**Option 2 — NuGet package**

Published to the [AppNetDev GitHub Packages](https://github.com/orgs/AppNetDev/packages) feed. Requires a GitHub PAT with `read:packages` scope — contact [@Sir-Jigston](https://github.com/Sir-Jigston) to request access.

```powershell
$Cred = Get-Credential -UserName 'your-github-username' -Message 'Enter your read:packages PAT as the password'

Register-PSResourceRepository -Name 'AppNetDev' `
    -Uri 'https://nuget.pkg.github.com/AppNetDev/index.json' `
    -Trusted

Install-PSResource -Name Pinned -Repository 'AppNetDev' -Credential $Cred -TrustRepository
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
| `Version` | String | No | Exact version to enforce (e.g. `124.0.6367.82`). Use `latest` or omit this property to install without version pinning. |
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

### Unpinned Latest Installs

Set `Version = 'latest'` or omit `Version` to install from a latest/stable installer URL without enforcing the installed version. Pinned will still ensure the application is present, but any detected installed version is considered compliant.

```powershell
App Chrome {
    Ensure        = 'Present'
    Name          = 'Google Chrome'
    InstallerPath = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    Version       = 'latest'
    Arguments     = '/quiet /norestart'
}
```

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

Copyright (c) 2026 Jarod Roberts. All rights reserved.
