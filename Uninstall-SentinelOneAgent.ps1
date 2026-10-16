#Requires -Version 5.1
<#
.SYNOPSIS
    Silently removes the local Windows SentinelOne agent using its uninstall passphrase.
.DESCRIPTION
    Run elevated or as SYSTEM. Uses the signed uninstaller beside the registered
    SentinelAgent executable, or a registered SentinelOne MSI product code.
    Does not stop services, disable protection, delete agent files, or reboot.
    Supports execution as a downloaded script block without companion files.
.PARAMETER UninstallPassword
    Agent uninstall passphrase. UninstallToken, AgentPassphrase and Passphrase are
    aliases. This is not a site registration token or a management API token.
.PARAMETER ForceCleanup
    After the vendor accepts the passphrase and completes removal, back up and
    delete the explicitly listed leftover registry entries and agent folders.
    Requires native 64-bit PowerShell on 64-bit Windows. Active components block
    cleanup. Registry ownership and protection are never bypassed.
.EXAMPLE
    & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri $Uri).Content)) -UninstallPassword $Passphrase -WhatIf
.NOTES
    Native command lines necessarily contain the passphrase. This script never
    records arguments or vendor output in its own logs or result objects.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Alias('UninstallToken', 'AgentPassphrase', 'Passphrase', 'Passkey')]
    [ValidateNotNullOrEmpty()]
    [string] $UninstallPassword,

    [Alias('Force')]
    [switch] $ForceCleanup,

    [ValidateRange(30, 7200)]
    [int] $TimeoutSeconds = 900,

    [ValidateRange(0, 600)]
    [int] $VerificationTimeoutSeconds = 60,

    [string] $LogDirectory = 'C:\ANS\SentinelOne\Logs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SentinelOneUninstallState {
    [CmdletBinding()]
    param()

    # Explicit registry views also work from a 32-bit RMM PowerShell process.
    $products = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $uninstallKey = $null
        try {
            $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $uninstallKey) { continue }
            foreach ($name in $uninstallKey.GetSubKeyNames()) {
                $key = $uninstallKey.OpenSubKey($name)
                try {
                    $displayName = [string] $key.GetValue('DisplayName')
                    $publisher = [string] $key.GetValue('Publisher')
                    if ($displayName -notmatch '^Sentinel(?:One| Agent)(?:\s|$)' -or
                        $publisher -notmatch '^Sentinel(?:One| Labs)(?:\b|$)') { continue }
                    $products += [pscustomobject]@{
                        ProductCode = $name
                        WindowsInstaller = ($key.GetValue('WindowsInstaller') -eq 1)
                    }
                } finally { if ($null -ne $key) { $key.Dispose() } }
            }
        } finally {
            if ($null -ne $uninstallKey) { $uninstallKey.Dispose() }
            $baseKey.Dispose()
        }
    }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='SentinelAgent'"
    $uninstaller = $null
    if ($null -ne $service) {
        $path = [Environment]::ExpandEnvironmentVariables($service.PathName)
        if ($path -notmatch '^\s*(?:"(?<Executable>[^"]+\.exe)"|(?<Executable>.+?\.exe))(?:\s|$)') {
            throw 'Cannot resolve the registered SentinelAgent executable path.'
        }
        $candidate = Join-Path (Split-Path -Parent $Matches.Executable) 'uninstall.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $uninstaller = $candidate }
    }
    [pscustomobject]@{
        Present = ($null -ne $service -or $products.Count -gt 0)
        ServicePresent = ($null -ne $service)
        Products = @($products)
        UninstallerPath = $uninstaller
    }
}

function Get-SentinelOneUninstallCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $State)

    if ($State.UninstallerPath) {
        $signature = Get-AuthenticodeSignature -LiteralPath $State.UninstallerPath
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -notmatch '(?i)\bSentinel(?:\s*One| Labs)\b') {
            throw 'The installed uninstaller must have a valid SentinelOne/Sentinel Labs signature.'
        }
        return [pscustomobject]@{ FilePath = $State.UninstallerPath; ProductCode = $null }
    }
    $products = @($State.Products | Where-Object {
        $_.WindowsInstaller -and $_.ProductCode -match '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$'
    } | Sort-Object -Property ProductCode -Unique)
    if ($products.Count -ne 1) {
        throw 'No unambiguous supported uninstall target. Repair the agent or obtain its approved installer from the console.'
    }
    $systemDirectory = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $systemDirectory = Join-Path $env:SystemRoot 'Sysnative'
    }
    [pscustomobject]@{ FilePath = (Join-Path $systemDirectory 'msiexec.exe'); ProductCode = $products[0].ProductCode }
}

function Invoke-SentinelOneUninstallProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Command,
        [Parameter(Mandatory)][string] $Password,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    # Restrict characters that would break Windows native argument quoting.
    if ([string]::IsNullOrWhiteSpace($Password) -or $Password -match '["\r\n\x00]' -or $Password.EndsWith('\')) {
        throw 'An uninstall passphrase is required and must not contain quotes, line breaks, NUL, or a trailing backslash.'
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Command.FilePath
    if ($Command.ProductCode) {
        $info.Arguments = '/x {0} /qn /norestart REBOOT=ReallySuppress UNINSTALL_KEY="{1}"' -f $Command.ProductCode, $Password
    } else {
        $info.Arguments = '/uninstall /norestart /q /k="{0}"' -f $Password
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        try { $null = $process.Start() } catch { throw 'Unable to start the vendor uninstaller.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'Uninstall timed out; it may still be running. Inspect vendor and Windows Installer state before retrying.'
        }
        $null = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {
        $info.Arguments = ''
        $process.Dispose()
    }
}

function Get-SentinelOneCleanupTargets {
    [CmdletBinding()]
    param()
    # Fixed allowlist derived from the supplied incomplete-uninstall procedure.
    # HKCR is represented by its machine Classes backing key, not the merged view.
    $keys = @()
    foreach ($classes in @('SOFTWARE\Classes', 'SOFTWARE\Classes\WOW6432Node')) {
        foreach ($suffix in @('AppID\SentinelAgent', 'AppID\SentinelHelperService',
            'SentinelAgent', 'SentinelHelper', 'SentinelOneLog')) {
            $keys += "HKLM\$classes\$suffix"
        }
    }
    foreach ($software in @('SOFTWARE', 'SOFTWARE\WOW6432Node')) {
        $keys += "HKLM\$software\Microsoft\Windows\CurrentVersion\Uninstall\Sentinel Agent"
        $keys += "HKLM\$software\SentinelOneLog"
        foreach ($exe in @('SentinelAgent.exe', 'SentinelCtl.exe', 'SentinelHelperService.exe',
            'SentinelRemediation.exe', 'SentinelServiceHost.exe', 'SentinelStaticEngine.exe', 'SentinelStaticEngineScanner.exe')) {
            $keys += "HKLM\$software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        }
    }
    foreach ($controlSet in @('CurrentControlSet', 'ControlSet001')) {
        foreach ($name in @('SentinelAgent', 'SentinelHelperService', 'SentinelMonitor', 'SentinelStaticEngine')) {
            $keys += "HKLM\SYSTEM\$controlSet\Services\$name"
        }
        foreach ($name in @('SentinelLogger', 'SentinelLogSession0', 'SentinelStatic')) {
            $keys += "HKLM\SYSTEM\$controlSet\Control\WMI\Autologger\$name"
        }
    }
    foreach ($name in @('SentinelAgent', 'SentinelHelperService', 'SentinelMonitor', 'SentinelStaticEngine')) {
        $keys += "HKLM\SYSTEM\Setup\FirstBoot\Services\$name"
    }
    # LogProcessorService is not a product-specific name; include only when its
    # registered executable establishes SentinelOne ownership.
    foreach ($prefix in @('SYSTEM\CurrentControlSet', 'SYSTEM\ControlSet001', 'SYSTEM\Setup\FirstBoot')) {
        $path = "HKLM\$prefix\Services\LogProcessorService"
        $providerPath = 'Registry::HKEY_LOCAL_MACHINE\' + $path.Substring(5)
        if (Test-Path -LiteralPath $providerPath) {
            $key = Get-Item -LiteralPath $providerPath
            try { $imagePath = [string] $key.GetValue('ImagePath') } finally { $key.Dispose() }
            if ($imagePath -match '(?i)\\SentinelOne\\') { $keys += $path }
        }
    }
    foreach ($key in $keys) {
        [pscustomobject]@{ Kind = 'Key'; Path = $key; Name = $null }
    }
    foreach ($path in @('HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')) {
        [pscustomobject]@{ Kind = 'Value'; Path = $path; Name = 'Sentinel Agent' }
    }
    # HKCU is intentionally excluded: under SYSTEM it is not the interactive user.
    foreach ($path in @((Join-Path $env:SystemRoot 'System32\drivers\SentinelOne'),
        (Join-Path $env:ProgramData 'Sentinel'),
        (Join-Path $env:ProgramW6432 'SentinelOne'))) {
        [pscustomobject]@{ Kind = 'Directory'; Path = [IO.Path]::GetFullPath($path); Name = $null }
    }
}

function Assert-SentinelOneComponentsStopped {
    [CmdletBinding()]
    param()
    foreach ($class in @('Win32_Service', 'Win32_SystemDriver')) {
        foreach ($component in @(Get-CimInstance -ClassName $class)) {
            if ($component.Name -match '^Sentinel' -or $component.PathName -match '(?i)\\(?:SentinelOne|Sentinel)\\') {
                if ($component.State -ne 'Stopped') {
                    throw 'SentinelOne components remain active or pending. Reboot and inspect vendor state before cleanup; nothing will be forcibly unloaded.'
                }
            }
        }
    }
}

function Assert-SentinelOneCleanupDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedPaths = @(Get-SentinelOneCleanupTargets | Where-Object Kind -eq 'Directory' | ForEach-Object { $_.Path.TrimEnd('\') })
    if ($fullPath -notin $allowedPaths) { throw 'Refusing directory cleanup outside the fixed SentinelOne allowlist.' }
    # Reject junctions/symlinks in ancestors and descendants before recursive copy/delete.
    $ancestor = $fullPath
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Reparse points are not supported in SentinelOne cleanup paths.'
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    if (Test-Path -LiteralPath $fullPath) {
        foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cleanup tree contains a reparse point.' }
            if ($item.PSIsContainer) {
                # Enumerate one level at a time, rejecting links before descending.
                Assert-SentinelOneCleanupTree -Path $item.FullName
            }
        }
    }
}

function Assert-SentinelOneCleanupTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cleanup tree contains a reparse point.' }
        if ($item.PSIsContainer) { Assert-SentinelOneCleanupTree -Path $item.FullName }
    }
}

function Test-SentinelOneCleanupTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Target)
    $providerPath = if ($Target.Kind -eq 'Directory') { $Target.Path } else {
        'Registry::HKEY_LOCAL_MACHINE\' + $Target.Path.Substring(5)
    }
    if (-not (Test-Path -LiteralPath $providerPath)) { return $false }
    if ($Target.Kind -eq 'Value') {
        $key = Get-Item -LiteralPath $providerPath
        try { return $Target.Name -in $key.GetValueNames() } finally { $key.Dispose() }
    }
    return $true
}

function Initialize-SentinelOneCleanupBackup {
    [CmdletBinding()]
    param()
    $backupRoot = Join-Path 'C:\ANS\SentinelOne\CleanupBackups' ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $backupRoot -AclObject $acl
    return $backupRoot
}

function Invoke-SentinelOneRemnantCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $LogPath)
    Assert-SentinelOneComponentsStopped
    $targets = @(Get-SentinelOneCleanupTargets)
    $existing = @()
    foreach ($target in $targets) {
        $providerPath = if ($target.Kind -eq 'Directory') { $target.Path } else {
            'Registry::HKEY_LOCAL_MACHINE\' + $target.Path.Substring(5)
        }
        if (-not (Test-SentinelOneCleanupTarget -Target $target)) { continue }
        if ($target.Kind -eq 'Directory') { Assert-SentinelOneCleanupDirectory -Path $target.Path }
        $existing += [pscustomobject]@{ Target = $target; ProviderPath = $providerPath }
    }
    $backupRoot = Initialize-SentinelOneCleanupBackup
    Add-Content -LiteralPath $LogPath -Value ("CleanupBackup=$backupRoot") -Encoding UTF8
    $manifest = @()
    $index = 0
    # Complete all backups before any remnant deletion. Vendor logs in ProgramData
    # are included in the folder copy and remain available to Support.
    foreach ($entry in $existing) {
        $index++
        $target = $entry.Target
        $backupPath = Join-Path $backupRoot ("{0:D3}" -f $index)
        if ($target.Kind -eq 'Directory') {
            Copy-Item -LiteralPath $target.Path -Destination $backupPath -Recurse -Force
        } else {
            $backupPath += '.reg'
            & "$env:SystemRoot\System32\reg.exe" export $target.Path $backupPath /y *> $null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backupPath)) {
                throw 'Registry export failed. No remnants were deleted.'
            }
        }
        $manifest += [pscustomobject]@{ Kind = $target.Kind; Path = $target.Path; Name = $target.Name; BackupPath = $backupPath }
    }
    ConvertTo-Json -InputObject @($manifest) -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'Manifest.json') -Encoding UTF8
    Assert-SentinelOneComponentsStopped
    $changed = 0
    foreach ($entry in $existing) {
        $target = $entry.Target
        # CurrentControlSet and ControlSet001 can refer to the same underlying key.
        if (-not (Test-SentinelOneCleanupTarget -Target $target)) { continue }
        if ($target.Kind -eq 'Directory') {
            Assert-SentinelOneCleanupDirectory -Path $target.Path
            Remove-Item -LiteralPath $target.Path -Recurse -Force
        } elseif ($target.Kind -eq 'Value') {
            Remove-ItemProperty -LiteralPath $entry.ProviderPath -Name $target.Name -Force
        } else {
            Remove-Item -LiteralPath $entry.ProviderPath -Recurse -Force
        }
        $changed++
        Add-Content -LiteralPath $LogPath -Value ("CleanupRemoved=$($target.Path); value=$($target.Name)") -Encoding UTF8
    }
    foreach ($target in $targets) {
        if (Test-SentinelOneCleanupTarget -Target $target) { throw 'A cleanup target remains or was recreated. Inspect the cleanup log before retrying.' }
    }
    [pscustomobject]@{ Changed = $changed; Skipped = ($targets.Count - $existing.Count); BackupPath = $backupRoot }
}

function Invoke-SentinelOneUninstall {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string] $Password,
        [switch] $ForceCleanup,
        [int] $TimeoutSeconds,
        [int] $VerificationTimeoutSeconds,
        [string] $LogDirectory
    )

    if (-not (Test-SentinelOneUninstallAdministrator)) { throw 'Run elevated or as SYSTEM.' }
    if ($ForceCleanup) {
        if ([string]::IsNullOrWhiteSpace($Password)) { throw 'Force cleanup requires -UninstallPassword / -UninstallToken; a passkey cannot be omitted.' }
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            throw 'Force cleanup requires native 64-bit PowerShell to avoid registry and filesystem redirection.'
        }
    }
    # Share the recovery lock so installation and removal cannot run together.
    $mutex = New-Object Threading.Mutex($false, 'Global\ANS.SentinelOneRepair')
    $locked = $false
    $logPath = $null
    $result = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME; Outcome = 'Failed'; Changed = 0
        Unchanged = 0; Skipped = 0; Failed = 1; ExitCode = $null
        RestartRequired = $false; RemovalVerified = $false; LogPath = $null
        CleanupChanged = 0; CleanupSkipped = 0; BackupPath = $null
        CleanupVerified = $false
    }
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another SentinelOne installation, recovery, or removal operation is running.' }
        $state = Get-SentinelOneUninstallState
        if (-not $state.Present) {
            if ($ForceCleanup) { throw 'Cannot authenticate the passkey: no registered vendor uninstall target remains. Use vendor Support for orphaned-agent cleanup.' }
            $result.Outcome = 'AlreadyAbsent'; $result.Unchanged = 1
            $result.Failed = 0; $result.RemovalVerified = $true
            return $result
        }
        $command = Get-SentinelOneUninstallCommand -State $state
        $action = 'Uninstall the local SentinelOne agent without automatic restart'
        if ($ForceCleanup) {
            $action += '; then back up and delete allowlisted registry entries and SentinelOne agent folders'
            # Display the exact deletion scope for a reviewable dry run.
            Get-SentinelOneCleanupTargets | ForEach-Object { Write-Verbose ("Cleanup target: {0}; value={1}" -f $_.Path, $_.Name) }
        }
        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
            $result.Outcome = 'Skipped'; $result.Skipped = 1; $result.Failed = 0
            return $result
        }
        if ([string]::IsNullOrWhiteSpace($Password)) { throw 'Supply -UninstallPassword (or -UninstallToken) with the agent uninstall passphrase.' }
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        $logPath = Join-Path $LogDirectory ('SentinelOneUninstall_{0}_{1}_{2}.log' -f
            $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N'))
        $result.LogPath = $logPath
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
            '{0:o} Start; script=Uninstall-SentinelOneAgent; target={1}' -f (Get-Date), $env:COMPUTERNAME)
        $result.ExitCode = Invoke-SentinelOneUninstallProcess -Command $command -Password $Password -TimeoutSeconds $TimeoutSeconds
        if ($result.ExitCode -notin @(0, 3010, 1641)) {
            throw "Vendor uninstall failed (exit $($result.ExitCode)). Inspect vendor logs; verify the passphrase and policy before retrying."
        }
        $result.RestartRequired = $result.ExitCode -in @(3010, 1641)
        if ($ForceCleanup -and -not $result.RestartRequired) {
            $cleanup = Invoke-SentinelOneRemnantCleanup -LogPath $logPath
            $result.CleanupChanged = $cleanup.Changed
            $result.CleanupSkipped = $cleanup.Skipped
            $result.BackupPath = $cleanup.BackupPath
            $result.CleanupVerified = $true
            # Manual registry/driver-file cleanup requires a controlled reboot.
            $result.RestartRequired = $cleanup.Changed -gt 0
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
        do {
            $state = Get-SentinelOneUninstallState
            if (-not $state.Present -or $result.RestartRequired -or [DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Seconds 2
        } while ($true)
        $result.RemovalVerified = -not $state.Present
        if (-not $result.RemovalVerified -and -not $result.RestartRequired) {
            throw 'The uninstaller returned success but the service or product registration remains. Removal is unverified; inspect vendor logs before retrying.'
        }
        $result.Outcome = if ($result.RestartRequired) { 'RestartRequired' } else { 'Removed' }
        $result.Changed = 1; $result.Failed = 0
        return $result
    } finally {
        try { if ($logPath) {
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
                '{0:o} End; outcome={1}; exit={2}; changed={3}; unchanged={4}; skipped={5}; failed={6}; removalVerified={7}; restartRequired={8}' -f
                (Get-Date), $result.Outcome, $result.ExitCode, $result.Changed, $result.Unchanged,
                $result.Skipped, $result.Failed, $result.RemovalVerified, $result.RestartRequired)
        } } finally {
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Test-SentinelOneUninstallAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

$invokeParameters = @{
    Password = $UninstallPassword
    ForceCleanup = [bool] $ForceCleanup
    TimeoutSeconds = $TimeoutSeconds
    VerificationTimeoutSeconds = $VerificationTimeoutSeconds
    LogDirectory = $LogDirectory
    WhatIf = [bool] $WhatIfPreference
}
if ($PSBoundParameters.ContainsKey('Confirm')) { $invokeParameters.Confirm = [bool] $PSBoundParameters['Confirm'] }
Invoke-SentinelOneUninstall @invokeParameters
