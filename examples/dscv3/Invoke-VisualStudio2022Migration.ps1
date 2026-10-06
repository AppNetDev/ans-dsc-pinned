#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up and restores Visual Studio 2022 configuration for the migration DSC config.
.DESCRIPTION
    Run elevated as the interactive user whose IDE preferences are being migrated.
    Backup exports Enterprise workloads and IDE settings before DSC removes Enterprise.
    Validate checks the preserved backup before installation. Restore applies IDE
    settings after DSC applies the installation config, then records completion.
    This helper does not uninstall Visual Studio. Fixed paths match the companion YAML.
.PARAMETER Phase
    Backup, Validate, or Restore. All phases stop on incomplete or mismatched backups.
.EXAMPLE
    .\Invoke-VisualStudio2022Migration.ps1 -Phase Backup -WhatIf
.NOTES
    Backups and concise operation logs are retained under C:\ANS\VisualStudioMigration.
    No credentials, keys, or settings contents are written to operation logs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Backup', 'Validate', 'Restore')]
    [string] $Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$migrationRoot = 'C:\ANS\VisualStudioMigration'
$enterprisePath = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise'
$professionalPath = 'C:\Program Files\Microsoft Visual Studio\2022\Professional'
$installerDirectory = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$setupPath = Join-Path $installerDirectory 'setup.exe'
$vswherePath = Join-Path $installerDirectory 'vswhere.exe'
$configPath = Join-Path $migrationRoot 'Enterprise.vsconfig'
$settingsPath = Join-Path $migrationRoot 'Enterprise.vssettings'
$manifestPath = Join-Path $migrationRoot 'Backup.json'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $identity.User.Value

function Assert-MigrationContext {
    [CmdletBinding()]
    param()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run elevated as the Windows user whose IDE settings are being migrated.'
    }
    if ($userSid -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or [System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw 'An interactive user session is required. SYSTEM/service sessions cannot migrate user IDE settings.'
    }
    if (Get-Process -Name devenv -ErrorAction SilentlyContinue) {
        throw 'Close all Visual Studio IDE sessions before continuing. No processes will be forcibly closed.'
    }
    foreach ($path in @($setupPath, $vswherePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required installer tool missing: $path" }
    }
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $key) { throw 'Windows has a pending reboot. Reboot, then rerun the same configuration.' }
    }
    $pending = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pending -and $pending.PendingFileRenameOperations) { throw 'Pending file operations require a reboot before migration can continue.' }
}

function Get-VisualStudioInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Enterprise', 'Professional')][string] $Edition)
    $json = & $vswherePath -all -products "Microsoft.VisualStudio.Product.$Edition" -version '[17.0,18.0)' -format json -utf8
    if ($LASTEXITCODE -ne 0) { throw "vswhere failed for $Edition." }
    $instances = @($json | ConvertFrom-Json)
    if ($instances.Count -gt 1) { throw "Multiple VS 2022 $Edition instances found; select a single instance before using this fixed-path configuration." }
    if ($instances.Count -eq 0) { return $null }
    $expectedPath = if ($Edition -eq 'Enterprise') { $enterprisePath } else { $professionalPath }
    if ($instances[0].installationPath.TrimEnd('\') -ne $expectedPath) {
        throw "Unexpected $Edition installation path. Update both the YAML and helper before migrating."
    }
    return $instances[0]
}

function Invoke-MigrationProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $Arguments,
        [ValidateRange(1, 7200)][int] $TimeoutSeconds = 600
    )
    $parameters = @{
        FilePath = $FilePath
        ArgumentList = $Arguments
        WorkingDirectory = $migrationRoot
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    $process = Start-Process @parameters
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Operation timed out (PID $($process.Id)). Inspect and close that process before retrying; it was not forcibly terminated."
        }
        if ($process.ExitCode -ne 0) { throw "Operation failed with exit code $($process.ExitCode). If reboot is required, reboot and rerun." }
    } finally { $process.Dispose() }
}

function Assert-SettingsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    # Prohibit DTD/external entity resolution when reading the exported XML.
    $options = New-Object System.Xml.XmlReaderSettings
    $options.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $options.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $options)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($document.DocumentElement.Name -ne 'UserSettings' -or -not $document.SelectSingleNode('/UserSettings/Category')) {
            throw 'The IDE settings export is empty or does not contain settings categories.'
        }
    } finally { $reader.Dispose() }
}

function Export-IdeSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $IdePath, [Parameter(Mandatory)][string] $Destination)
    # The fixed backup root contains no spaces, avoiding nested command quoting.
    $process = Start-Process -FilePath $IdePath -ArgumentList "/NoSplash /Command `"Tools.ImportandExportSettings /export:$Destination`"" -WorkingDirectory $migrationRoot -WindowStyle Hidden -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        $exportValid = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                try { Assert-SettingsFile -Path $Destination; $exportValid = $true; break } catch { }
            }
            if ($process.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        if (-not $exportValid) { throw 'IDE export did not produce valid settings within five minutes. Close any first-run/modal dialogs and retry; Enterprise has not been removed.' }
        # Allow the export command to return, then close only the IDE we launched.
        Start-Sleep -Seconds 2
        $process.Refresh()
        if (-not $process.HasExited) {
            if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(60000)) {
                throw "Exported settings, but could not close IDE PID $($process.Id). Close it manually and rerun before uninstalling."
            }
        }
        if ($process.ExitCode -ne 0) { throw "IDE export process failed with exit code $($process.ExitCode)." }
        Assert-SettingsFile -Path $Destination
    } finally { $process.Dispose() }
}

function Get-ValidatedBackup {
    [CmdletBinding()]
    param()
    foreach ($path in @($manifestPath, $configPath, $settingsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing migration backup file: $path" }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.UserSid -ne $userSid -or $manifest.ComputerName -ne $env:COMPUTERNAME) {
        throw 'The backup belongs to another Windows user or computer. Run as the original user; do not overwrite their backup.'
    }
    if ($manifest.ConfigHash -ne (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -or
        $manifest.SettingsHash -ne (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash) {
        throw 'Backup integrity check failed. Restore the original backup files before continuing.'
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.version -ne '1.0' -or @($config.components).Count -eq 0) { throw 'The workload export is empty or invalid.' }
    Assert-SettingsFile -Path $settingsPath
    return $manifest
}

function Save-MicrosoftBootstrapper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('enterprise', 'professional')][string] $Edition)
    $destination = Join-Path $migrationRoot "vs_$Edition.exe"
    if (-not (Test-Path -LiteralPath $destination)) {
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_$Edition.exe" -OutFile $destination -UseBasicParsing
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $destination
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Invalid Microsoft signature on $destination. Remove this bootstrapper and retry the Backup phase."
    }
}

Assert-MigrationContext
if (-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME / current user / Visual Studio 2022", "$Phase migration data")) { return }
New-Item -Path $migrationRoot -ItemType Directory -Force | Out-Null
# Restrict exported user preferences and migration state to this user, SYSTEM, and administrators.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($userSid, 'S-1-5-18', 'S-1-5-32-544')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $migrationRoot -AclObject $acl
$started = [DateTime]::UtcNow
$logPath = Join-Path $migrationRoot ("Invoke-VisualStudio2022Migration-{0}-{1}-{2}.json" -f $env:COMPUTERNAME, $Phase, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$outcome = 'Failed'
$changed = 0
$unchanged = 0
try {
    $enterprise = Get-VisualStudioInstance -Edition Enterprise
    $professional = Get-VisualStudioInstance -Edition Professional
    if ($Phase -eq 'Backup') {
        if (-not $enterprise -or -not $enterprise.isComplete -or -not $enterprise.isLaunchable) { throw 'A complete, launchable Enterprise 2022 installation is required for backup.' }
        Save-MicrosoftBootstrapper -Edition enterprise
        Save-MicrosoftBootstrapper -Edition professional
        if (Test-Path -LiteralPath $manifestPath) {
            $backup = Get-ValidatedBackup
            if ($backup.InstanceId -ne $enterprise.instanceId) { throw 'Backup instance does not match the current Enterprise installation.' }
            $unchanged = 1
        } else {
            $archive = Join-Path $migrationRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
            New-Item -Path $archive -ItemType Directory | Out-Null
            $exportConfig = Join-Path $archive 'Enterprise.vsconfig'
            $exportSettings = Join-Path $archive 'Enterprise.vssettings'
            Invoke-MigrationProcess -FilePath $setupPath -Arguments "export --installPath `"$enterprisePath`" --config `"$exportConfig`" --quiet"
            $config = Get-Content -LiteralPath $exportConfig -Raw | ConvertFrom-Json
            if ($config.version -ne '1.0' -or @($config.components).Count -eq 0) { throw 'Workload export is empty or invalid; removal blocked.' }
            Export-IdeSettings -IdePath (Join-Path $enterprisePath 'Common7\IDE\devenv.exe') -Destination $exportSettings
            Copy-Item -LiteralPath $exportConfig -Destination $configPath
            Copy-Item -LiteralPath $exportSettings -Destination $settingsPath
            $backup = [pscustomobject]@{
                UserSid = $userSid
                ComputerName = $env:COMPUTERNAME
                InstanceId = $enterprise.instanceId
                InstallationVersion = $enterprise.installationVersion
                CreatedUtc = [DateTime]::UtcNow.ToString('o')
                Archive = $archive
                ConfigHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
                SettingsHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
            }
            $backup | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $archive 'Backup.json')
            $null = Get-ValidatedBackup
            $changed = 1
        }
        Assert-MigrationContext
        # A new removal attempt must not reuse completion from an earlier migration.
        $completionPath = Join-Path $migrationRoot 'Complete.json'
        if (Test-Path -LiteralPath $completionPath) { Remove-Item -LiteralPath $completionPath -Force }
    } else {
        $backup = Get-ValidatedBackup
        if ($enterprise) { throw 'Enterprise is still registered. Complete its removal and any required reboot before continuing.' }
        Save-MicrosoftBootstrapper -Edition professional
        if ($Phase -eq 'Restore') {
            if (-not $professional -or -not $professional.isComplete -or -not $professional.isLaunchable) { throw 'Professional is not complete and launchable.' }
            # Save existing Professional preferences before replacing them, when available.
            $restoreArchive = Join-Path $migrationRoot ("Professional-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            New-Item -Path $restoreArchive -ItemType Directory | Out-Null
            $ide = Join-Path $professionalPath 'Common7\IDE\devenv.exe'
            Export-IdeSettings -IdePath $ide -Destination (Join-Path $restoreArchive 'Before.vssettings')
            Invoke-MigrationProcess -FilePath $ide -Arguments "/NoSplash /ResetSettings `"$settingsPath`" /Command `"File.Exit`""
            Export-IdeSettings -IdePath $ide -Destination (Join-Path $restoreArchive 'After.vssettings')
            Invoke-MigrationProcess -FilePath $setupPath -Arguments "export --installPath `"$professionalPath`" --config `"$restoreArchive\Professional.vsconfig`" --quiet"
            $source = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $target = Get-Content -LiteralPath (Join-Path $restoreArchive 'Professional.vsconfig') -Raw | ConvertFrom-Json
            $missing = @($source.components | Where-Object { $_ -notin $target.components })
            [pscustomobject]@{ MissingComponents = $missing } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $restoreArchive 'ComponentComparison.json') -Encoding UTF8
            if ($missing.Count -gt 0) { throw "Professional is missing $($missing.Count) exported components. Review $restoreArchive\ComponentComparison.json; Enterprise-only components may not be available. Completion has not been recorded." }
            [pscustomobject]@{
                UserSid = $userSid
                ComputerName = $env:COMPUTERNAME
                CompletedUtc = [DateTime]::UtcNow.ToString('o')
                VerificationDirectory = $restoreArchive
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $migrationRoot 'Complete.json') -Encoding UTF8
            $changed = 1
        } else { $unchanged = 1 }
    }
    $outcome = 'Succeeded'
} finally {
    $summary = [pscustomobject]@{
        Script = 'Invoke-VisualStudio2022Migration.ps1'
        Target = $env:COMPUTERNAME
        Phase = $Phase
        StartUtc = $started.ToString('o')
        EndUtc = [DateTime]::UtcNow.ToString('o')
        Outcome = $outcome
        Changed = $changed
        Unchanged = $unchanged
        Skipped = 0
        Failed = [int]($outcome -eq 'Failed')
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath $logPath -Encoding UTF8
    $summary
}
