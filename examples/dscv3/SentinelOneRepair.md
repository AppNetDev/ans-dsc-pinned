# SentinelOne repair / re-enrollment (DSC v3)

For no-parameter MSI recovery, run this in elevated 64-bit PowerShell or as SYSTEM:

```powershell
iwr 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Repair-SentinelOneAgent.ps1' -UseBasicParsing | iex
```

This uses the current signed MSI from the default ConnectWise URL and bootstraps
DSC if needed. It preserves enrollment, returns health/restart/log information,
and never restarts Windows automatically. A healthy target/newer agent is
unchanged; an unhealthy same/newer agent requires provider-assisted recovery.
No token or passphrase is needed. This entry point does not re-enroll the agent.
If Windows has a pending servicing or Windows Update restart, it reports
`Outcome: WindowsRestartPending` and `RestartRequired: True`, explains that you
must restart and rerun, and skips recovery before downloading files. This is a
normal result, not a DSC failure. The MSI resource also checks before installation.
For a version/hash-pinned package, use the parameterized runner below.

For an existing unhealthy agent or denied service-configuration access, use the
MSI upgrade mode. It delegates recovery to the vendor MSI without directly changing
service startup or service ACLs. It requires an approved package newer than the
installed version when the agent is unhealthy; it does not force a same-version repair.

```powershell
$baseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master'
$runner = (Invoke-WebRequest -Uri "$baseUri/examples/dscv3/Invoke-DscV3SentinelOneRepair.ps1" -UseBasicParsing).Content
$test = & ([scriptblock]::Create($runner)) -Mode Upgrade -TestOnly -SourceBaseUri $baseUri
$test | Format-List

# After validating the selected version is approved and newer, pin the tested package:
& ([scriptblock]::Create($runner)) -Mode Upgrade -ExpectedSha256 $test.PackageSha256 -SourceBaseUri $baseUri
```

Override the default ConnectWise MSI URL with `-InstallerUri`, or supply
`-InstallerPath` for a local MSI. `-Mode Upgrade` preserves enrollment and cannot be
combined with `-Reenroll`. Its result includes `Healthy`, `UpgradeAvailable`,
`RestartRequired`, actual package/installed versions, and configuration/result/error
paths. See [MSI recovery details](../../dscv3/README.md). Existing service/bind behavior
remains the default `-Mode Repair`, described below.

Run from an elevated PowerShell session or RMM SYSTEM context. No local checkout is
required. After these files are published to GitHub, fetch and execute the runner:

```powershell
$baseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master'
$runner = (Invoke-WebRequest -Uri "$baseUri/examples/dscv3/Invoke-DscV3SentinelOneRepair.ps1" -UseBasicParsing).Content
& ([scriptblock]::Create($runner)) -SiteToken $SiteToken -Reenroll -SourceBaseUri $baseUri
```

Omit `-Reenroll` for service recovery/install only. Add
`-AgentPassphrase $AgentPassphrase` when the existing agent requires it (SecureString).
Use `-TestOnly` for a read-only agent check. You can use the `iwr` alias interactively;
the example spells out `Invoke-WebRequest` for automation. Passing parameters via
the call operator avoids interpolating secrets into executable script text.

When fetched as text, the runner downloads its configuration, resource, and DSC
bootstrap helper to a unique protected directory under `C:\ANS\SentinelOneDsc`.
It installs standalone DSC to `C:\ANS\DSC` if no `dsc.exe` is available. Preview modes
may download companion files; `-TestOnly` can also install missing DSC. `-WhatIf`
requires DSC to be installed already. Staged files are retained for troubleshooting.
The runner's URL and `-SourceBaseUri` must use the same branch/tag/commit; replace
`master` in `$baseUri` to select a revision. A commit SHA gives repeatable source.

Local checkout execution remains supported. The runner registers the resource
directory for discovery in its process only. This resource is included automatically
in packages built by `Build-DscV3Release.ps1`; existing published packages do not contain it.

```powershell
# Repair service startup/running state; install if service or binaries are missing.
# Retrieve $SiteToken from your approved secret source.
.\examples\dscv3\Invoke-DscV3SentinelOneRepair.ps1 -SiteToken $SiteToken

# Preview only; does not download, install, start services, or bind.
.\examples\dscv3\Invoke-DscV3SentinelOneRepair.ps1 -TestOnly

# Explicit re-enrollment request, after checking the endpoint's console association.
$parameters = @{
    SiteToken = $SiteToken
    Reenroll = $true
    # Optional: supply a stable ID to reuse across retries; otherwise a GUID is generated.
    # RequestId = 'CHG-12345'
    # Optional SecureString, obtained from your approved secret source:
    AgentPassphrase = $AgentPassphrase
}
.\examples\dscv3\Invoke-DscV3SentinelOneRepair.ps1 @parameters
```

The site token defaults to the process environment variable `SENTINELONE_SITE_TOKEN`.
The optional agent passphrase defaults to `SENTINELONE_AGENT_PASSPHRASE`.
The runner restores both variables when it exits. Neither secret is placed in
YAML, parameter files, bind receipts, DSC state, or our operation logs. MSI and
SentinelCtl require native command-line secrets: privileged process inspection,
auditing, transcripts of the caller, or vendor MSI logging policy can capture them.

Default installer: `https://cwa.connectwise.com/tools/sentinelone/SentinelOneAgent-Windows_64bit.msi`.
Override using `-InstallerUri`. The URL is not version-pinned. The resource downloads
it only when the service, registered executable, or adjacent `SentinelCtl.exe` is
missing; validates its Authenticode signature against SentinelOne / Sentinel Labs;
then invokes `msiexec /i` with `SITE_TOKEN`, quiet mode, and reboot suppression.
An intact but stopped/disabled agent receives service recovery, not an MSI install.
This does not force MSI repair, downgrade, uninstall, bypass tamper protection, unload
protection, or reboot. A damaged installed product may reject `/i` and require the
agent version's supported repair procedure. Exit 3010 fails the current application
with an explicit reboot-required message; reboot in an approved window and rerun.
A timeout stops orchestration without killing the native operation; inspect the
agent/Windows Installer before retrying.

`-Reenroll` calls `SentinelCtl.exe bind <SiteToken> [-k <passphrase>]` once per
non-secret `RequestId`. The runner generates a GUID when the ID is omitted, null,
or blank. Each such invocation requests a new bind. Supply the same explicit ID
to skip an already accepted bind on retries, or a new ID for another intentional
bind, including a token/site change. Successful command receipts are stored
under `C:\ANS\SentinelOne\BindRequests`; operation logs under `C:\ANS\SentinelOne\Logs`.
The resource restricts this working directory to Administrators and SYSTEM.
Keep request IDs free of customer secrets. Bind receipts persist across agent reinstallations;
use a new ID if a replacement agent needs a fresh bind. Concurrent applies are rejected.
As with other external operations, if bind succeeds but the process dies before the
receipt is saved, a retry can issue the bind again; verify portal state before retrying.

`Ready: true` means service/files are locally healthy and any explicit bind request
has been accepted. Enrollment always returns `NotVerified`. Confirm protection and
a fresh check-in in the intended portal/site. A successful exit code does not prove
re-enrollment. **Verify before acting:** bind syntax, passphrase requirements, and
restart/reload requirements for the installed release. The supplied script's
[Guardz reference](https://support.guardz.com/en/articles/14004202-migrating-from-bring-your-own-byo-to-sentinelone-managed-licenses)
specifically describes cross-console migration and warns that same-console tokens
or an existing target UUID can prevent migration silently. This configuration preserves
the script's scope and does not automate that reference's protection unload/load steps.

The companion [YAML](../../.configurations/dscv3/sentinelone-repair-dscv3.yaml) exposes
`Reenroll`, `RequestId`, and `InstallerUri` as DSC parameters. Site token and passphrase
are deliberately runtime secrets supplied by the runner rather than DSC properties,
because DSC returns resource properties in its results.

Validation: `powershell.exe -NoProfile -File .\tests\Test-SentinelOneRepair.ps1`.
These tests simulate service/files/receipts and never modify the installed agent.
