# SentinelOne MSI recovery with DSC v3

Run in an elevated **64-bit** PowerShell session on the affected endpoint. The
existing GitHub runner now supports `-Mode Upgrade` and bootstraps DSC if missing.
The resource does not require Pinned or a PowerShell DSC LCM.

```powershell
$baseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master'
$runner = (Invoke-WebRequest -Uri "$baseUri/examples/dscv3/Invoke-DscV3SentinelOneRepair.ps1" -UseBasicParsing).Content

# Downloads/validates the MSI and checks health; never runs the MSI.
$test = & ([scriptblock]::Create($runner)) -Mode Upgrade -TestOnly -SourceBaseUri $baseUri
$test | Format-List

# After checking PackageVersion is approved and newer than InstalledVersion,
# apply the same package hash evaluated in the test. Use your trusted hash if available.
& ([scriptblock]::Create($runner)) -Mode Upgrade -ExpectedSha256 $test.PackageSha256 -SourceBaseUri $baseUri
```

The default MSI URL is
`https://cwa.connectwise.com/tools/sentinelone/SentinelOneAgent-Windows_64bit.msi`.
Override `-InstallerUri` or supply `-InstallerPath` for a local approved package.
`-Mode Upgrade -Reenroll` is rejected: upgrade preserves the existing association.
No site token or passphrase is passed to MSI in this mode. Vendor authorization
requirements can still cause an upgrade to fail.

For local execution use `Install-SentinelOneAgentDscV3.ps1` at the repository root
with its adjacent `dscv3` directory. That standalone wrapper requires DSC already
installed (`dsc.exe` on PATH or `-DscPath`). It supports `-Operation Get`, `Test`, or
`Set` (default); the URL runner provides bootstrap and exposes `-TestOnly` for Test.

Select an approved MSI **newer than the installed agent**, with the correct OS and
architecture. For the affected `25.2.6.442` agent, select a newer SOC-approved build.
Do not assume the mutable download URL contains a suitable newer package.

```powershell
# Populate these variables from your approved package source.
# $ApprovedMsiPath: existing local MSI file; $ApprovedSha256: trusted SHA256.
.\Install-SentinelOneAgentDscV3.ps1 -InstallerPath $ApprovedMsiPath -Operation Test
.\Install-SentinelOneAgentDscV3.ps1 -InstallerPath $ApprovedMsiPath -ExpectedSha256 $ApprovedSha256
```

`-WhatIf` performs a DSC Test. Get, Test, and WhatIf stage files but never run MSI.
Each invocation produces a configuration and DSC JSON result under a unique,
Administrators/SYSTEM-only directory in `C:\ANS\SentinelOneDsc`. The configuration
contains the staged package path, actual MSI version, SHA256, and health target;
it contains no credentials or site token. Generated resource manifests use absolute
worker paths and are discoverable through the wrapper's temporary PATH entry.

The generated configuration has one resource:

```json
{
  "$schema": "https://aka.ms/dsc/schemas/v3/bundled/config/document.json",
  "resources": [{
    "name": "UpgradeSentinelOneAgent",
    "type": "AppNet.SentinelOne/MsiUpgrade",
    "properties": {
      "PackagePath": "C:\\ANS\\SentinelOneDsc\\<run>\\SentinelOne.msi",
      "PackageVersion": "26.1.1.100",
      "PackageSha256": "<SHA256 derived from the approved MSI>",
      "LogDirectory": "C:\\ANS\\SentinelOneDsc\\<run>\\Logs",
      "ReceiptPath": "C:\\ANS\\SentinelOneDsc\\State\\Reboot-<SHA256>.json",
      "HealthTimeoutSeconds": 60,
      "MsiTimeoutSeconds": 900,
      "Healthy": true
    }
  }]
}
```

This is an illustration; its version and placeholders are not an approved package.
Use the wrapper to generate a valid configuration from the actual MSI.

## Behavior and limits

- Verifies a valid SentinelOne/Sentinel Labs Authenticode signature, product
  metadata, and hash before installation. Unfamiliar signer subjects fail closed.
- Reads the target `SentinelAgent.exe` file version from the signed MSI's File
  table. `PackageVersion` remains MSI ProductVersion; `PackageAgentVersion` is
  the executable target. For example, MSI `26.1.177` can contain agent
  `26.1.2.177`; those layouts must not be compared directly. Missing, ambiguous,
  or nonnumeric target file versions are rejected before installation.
- Healthy means the installed executable file version is at least the target executable version, the
  service is Automatic and Running, SentinelCtl reports the agent loaded, and
  self-protection is On. Portal enrollment is always `NotVerified`.
- A healthy agent at the target version or newer is unchanged. An unhealthy agent
  at the same version or newer is rejected. No forced repair properties or downgrade.
- Requires an existing service and identifiable agent executable version. Does not
  install a missing agent or recover missing agent binaries. Does not query
  `Win32_Product`, modify service ACLs, directly configure/start protected services,
  unload protection, uninstall, or rebind.
- Uses `msiexec /i <package> /qn /norestart REBOOT=ReallySuppress`. MSI exit 0 must
  pass the health checks; 3010 returns `RebootRequired` with the actual health state.
  A boot-scoped receipt prevents another upgrade attempt for that package before
  restarting. Other MSI exit codes fail DSC Set. Vendor upgrade authorization or an
  agent passphrase may still be required; this resource does not bypass that requirement.
- Waits up to `MsiTimeoutSeconds` (default 900) for MSI. On timeout the native
  operation is not killed; inspect Windows Installer before retrying. Concurrent
  recovery applies are rejected using the same mutex as the service/bind resource.
- Blocks an upgrade when Windows CBS or Windows Update reports a pending restart.
  This is not an exhaustive detector of every vendor-specific pending action.
- Timestamped operation logs include target, versions, start/end, MSI exit code,
  outcome, and changed/unchanged/skipped/failed summary. Native vendor logs remain
  in their normal locations. No verbose MSI property logging is requested.
- The wrapper returns objects with result/configuration/diagnostic paths, inspected
  package hash/version, installed version, `UpgradeAvailable`, and local health. Test returning
  `Healthy=False` means drift, not a DSC engine failure. Inspect `Outcome` and
  `RestartRequired`; successful DSC execution alone does not mean convergence.
  With `RestartRequired=False`, `UpgradeAvailable=False` and `Healthy=False` call for another approved package
  or provider-assisted recovery. It does not authorize a same-version reinstall.

After a requested restart, rerun Test and confirm a fresh check-in under the correct
customer/site in the portal. If the upgraded agent is still disabled or unhealthy,
use provider-assisted recovery rather than repeatedly upgrading or replacing its ACL.
Plan any uninstall/reinstall separately with its passphrase, reboot window,
replacement package, and endpoint access/recovery arrangements.

## Validation

Run `tests\Test-SentinelOneMsiDsc.ps1` from the parent directory. It uses the real
DSC engine with copied resource files and isolated service/MSI fixtures. It never
runs msiexec or changes endpoint services. Native MSI execution and actual portal
enrollment require validation on the affected endpoint with the approved package.
`tests\Test-SentinelOneBootstrap.ps1` covers downloaded runner routing for both modes.

## References

- [SentinelOne MSI installation and upgrade guidance](https://support.guardz.com/en/articles/10366126-installing-the-windows-agent-using-an-msi-package): MSI upgrades are supported; SITE_TOKEN is ignored during upgrades.
- [DSC command resource contract](https://learn.microsoft.com/en-us/powershell/dsc/reference/schemas/resource/manifest/root?view=dsc-3.0)
