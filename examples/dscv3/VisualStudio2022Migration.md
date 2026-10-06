# Visual Studio 2022 Enterprise to Professional

Use `.configurations/dscv3/migrate-visual-studio-2022-enterprise-to-pro-dscv3.yaml`
with `Invoke-VisualStudio2022Migration.ps1`. This migrates the machine's installed
workloads/components and the **executing Windows user's** exported IDE preferences.
The existing Professional-only installation YAML remains separate.

## Scope and prerequisites

- Run in an elevated, interactive session **as the user whose preferences you need**.
  Elevating with a different administrator account backs up that administrator's
  preferences. SYSTEM/service sessions are rejected. This is not an all-user migration.
- Targets `C:\Program Files\Microsoft Visual Studio\2022\Enterprise` and
  `C:\Program Files\Microsoft Visual Studio\2022\Professional`. Nondefault paths or
  multiple instances require updating the helper and YAML before applying.
- Close all Visual Studio sessions, complete pending restarts, and ensure Enterprise
  opens normally without first-run/modal prompts before starting.
- Requires installed Visual Studio Installer/`vswhere`, DSC v3, and the
  `AppNetOnline.Pinned/App` resource. Internet access is required for Microsoft
  bootstrappers and installation packages. Allow up to two hours per installer step.
- This changes editions and installs the latest VS **2022** Current-channel release;
  it does not preserve an exact servicing build. Professional licensing is separate.
- Exported settings/configurations are not a machine image: repositories, credentials,
  licenses, third-party extension binaries, and all-user settings are outside scope.
  Exported components unavailable in Professional cannot be reproduced. A comparison
  report identifies missing component IDs and prevents recording completion.

## Apply

From an elevated PowerShell session under the intended user, in the repository root:

```powershell
New-Item -Path 'C:\ANS\Scripts' -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath '.\examples\dscv3\Invoke-VisualStudio2022Migration.ps1' `
    -Destination 'C:\ANS\Scripts\Invoke-VisualStudio2022Migration.ps1' -Force

# Optional: perform and inspect the backups before applying the destructive config.
& 'C:\ANS\Scripts\Invoke-VisualStudio2022Migration.ps1' -Phase Backup -Confirm:$false

# Uses the repository bootstrap to register/install the Pinned resource and DSC if needed.
& '.\examples\dscv3\Install-PinnedDscV3.ps1' `
    -ConfigurationPath (Join-Path $PWD '.configurations\dscv3\migrate-visual-studio-2022-enterprise-to-pro-dscv3.yaml')
```

If DSC and the resource are already configured, use:

```powershell
dsc config set --file '.\.configurations\dscv3\migrate-visual-studio-2022-enterprise-to-pro-dscv3.yaml'
```

The backup phase downloads and checks Microsoft signatures on both bootstrappers,
exports workloads using Installer `export`, and exports IDE preferences through
`Tools.ImportandExportSettings`. It opens an isolated IDE process and requests a
graceful close after a valid export. If a modal dialog prevents export/closure, it
stops before removal and leaves the process available for inspection; close it and
rerun. It never forcibly terminates an IDE session.

The DSC dependencies then remove Enterprise, install Professional with the exported
`.vsconfig`, and run a separate `modify --config` step before applying `.vssettings`
using `/ResetSettings ... /Command File.Exit`. The separate final resource retries
configuration/import if installation succeeded but settings restoration failed.
First-run prompts in Professional may require opening/closing it once, then retrying.

## Validation and retry

- Backups, SHA-256 manifest, timestamped backup folders, and phase summary logs remain
  in `C:\ANS\VisualStudioMigration`, restricted to the originating user, Administrators,
  and SYSTEM. Settings contents are not copied into the phase summary logs.
- A validated existing `Backup.json` is reused on retry, preserving the original
  recovery point. To deliberately take a new snapshot, archive the **entire** migration
  directory elsewhere first, while Enterprise is still installed; do not mix files
  from different snapshots or users.
- Installer exit codes other than zero stop the chain, including `3010` (restart
  required). Reboot and rerun the same config; no automatic restart is requested.
- Check the DSC result, `Complete.json`, and the `Professional-*` verification folder.
  That folder contains Professional settings before/after import, its workload export,
  and `ComponentComparison.json`. `Complete.json` is written only after these succeed
  and no exported component IDs are missing.
- Open Professional as the original user and verify theme, shortcuts, editor options,
  relevant extensions, and a representative solution build. A successful import and
  readable re-export do not prove every Enterprise/extension-specific preference is
  supported in Professional. Extension and language parity need manual verification.
- If components are missing because they are Enterprise-only, review the comparison
  and select an acceptable Professional configuration before changing the workflow;
  the helper does not silently discard them or mark a partial migration complete.

## Recovery

Enterprise is removed only after both exports validate. There is no automatic rollback:
installation failure leaves backups intact and the configuration can be rerun. This
does not provide offline recovery if Microsoft downloads are unavailable.

To restore Enterprise instead, stop applying this migration config. Reinstall the
required Enterprise servicing build using its bootstrapper and the preserved
`Enterprise.vsconfig`, then launch that Enterprise instance as the original user with
`/ResetSettings C:\ANS\VisualStudioMigration\Enterprise.vssettings /Command File.Exit`.
The cached `vs_enterprise.exe` installs the current VS 2022 release, not necessarily
the original build. `Backup.json` records the original build for recovery planning.
Professional's pre-import preferences are also retained as `Before.vssettings` in
each `Professional-*` folder. Projects and source control working directories are
not deleted by this workflow. Shared SDKs/components remain under Installer control.

Microsoft references: [installer commands and .vsconfig](https://learn.microsoft.com/en-us/visualstudio/install/use-command-line-parameters-to-install-visual-studio?view=vs-2022),
[IDE settings export](https://learn.microsoft.com/en-us/visualstudio/ide/reference/import-and-export-settings-command?view=vs-2022),
[/ResetSettings and exit](https://learn.microsoft.com/en-us/visualstudio/ide/reference/resetsettings-devenv-exe?view=vs-2022).
