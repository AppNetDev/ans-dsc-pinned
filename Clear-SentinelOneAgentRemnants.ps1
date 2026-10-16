#Requires -Version 5.1
<#
.SYNOPSIS
    Removes listed SentinelOne remnants after an incomplete uninstall.
.DESCRIPTION
    Implements the supplied manual registry/file cleanup procedure independently
    of the vendor uninstaller. No passphrase or successful uninstall is required.
    Backs up each target before deletion. Locked or inaccessible targets are
    retained and reported; other eligible targets continue. Reboot and rerun for
    remaining targets, then reinstall using an approved installer and site token.
.PARAMETER LogDirectory
    Operational log directory. Backups use C:\ANS\SentinelOne\CleanupBackups.
.EXAMPLE
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Clear-SentinelOneAgentRemnants.ps1' -UseBasicParsing | Invoke-Expression
.EXAMPLE
    .\Clear-SentinelOneAgentRemnants.ps1 -WhatIf -Verbose
.NOTES
    Run elevated in native 64-bit PowerShell. Deletes the allowlisted local agent
    service/class/IFEO/autologger keys, named startup values, verified SentinelOne
    MSI registrations, and the three SentinelOne directories. This removes local
    protection configuration. It does not unload drivers, restart Windows, take
    ownership, or reinstall the agent. Access-denied targets must have their
    permissions corrected as described in the supplied manual procedure.
    Backups preserve remnants and logs, not a functional agent rollback. Use the
    manifest for selective restoration; never overwrite whole shared startup keys.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $LogDirectory = 'C:\ANS\SentinelOne\Logs'
)

& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
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
        # MSI builds register under a GUID rather than the legacy named key.
        # Include only registrations positively identified as this product.
        $uninstallPath = "Registry::HKEY_LOCAL_MACHINE\$software\Microsoft\Windows\CurrentVersion\Uninstall"
        $registrations = if (Test-Path -LiteralPath $uninstallPath) { @(Get-ChildItem -LiteralPath $uninstallPath -ErrorAction Stop) } else { @() }
        foreach ($registration in $registrations) {
            if ($registration.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
            try {
                $displayName = [string] $registration.GetValue('DisplayName')
                $publisher = [string] $registration.GetValue('Publisher')
                if ($displayName -match '^Sentinel(?: Agent|One)(?:\s|$)' -and
                    $publisher -match '^Sentinel(?:One| Labs)(?:\b|$)') {
                    $keys += "HKLM\$software\Microsoft\Windows\CurrentVersion\Uninstall\$($registration.PSChildName)"
                }
            }
            finally { $registration.Dispose() }
        }
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
    # Apply the supplied HKCU value cleanup only to the actual caller's user hive.
    # SYSTEM/service hives are not the endpoint user's profile.
    $cleanupIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($cleanupIdentity.User.Value -notin @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')) {
            [pscustomobject]@{
                Kind = 'Value'
                Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
                Name = 'SentinelOneLog_.binlog'
            }
        }
        else { Write-Verbose 'HKCU toast value skipped under SYSTEM/service context; check the affected user profile separately.' }
    }
    finally { $cleanupIdentity.Dispose() }
    foreach ($path in @((Join-Path $env:SystemRoot 'System32\drivers\SentinelOne'),
        (Join-Path $env:ProgramData 'Sentinel'),
        (Join-Path $env:ProgramW6432 'SentinelOne'))) {
        [pscustomobject]@{ Kind = 'Directory'; Path = [IO.Path]::GetFullPath($path); Name = $null }
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
    $providerPath = ConvertTo-SentinelOneCleanupProviderPath -Target $Target
    if (-not (Test-Path -LiteralPath $providerPath)) { return $false }
    if ($Target.Kind -eq 'Value') {
        $key = Get-Item -LiteralPath $providerPath
        try { return $Target.Name -in $key.GetValueNames() } finally { $key.Dispose() }
    }
    return $true
}

function ConvertTo-SentinelOneCleanupProviderPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Target)
    if ($Target.Kind -eq 'Directory') { return $Target.Path }
    if ($Target.Path.StartsWith('HKLM\', [StringComparison]::OrdinalIgnoreCase)) {
        return 'Registry::HKEY_LOCAL_MACHINE\' + $Target.Path.Substring(5)
    }
    if ($Target.Path.StartsWith('HKCU\', [StringComparison]::OrdinalIgnoreCase)) {
        return 'Registry::HKEY_CURRENT_USER\' + $Target.Path.Substring(5)
    }
    throw 'Unsupported registry hive in cleanup target.'
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

function Test-SentinelOneUninstallAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Invoke-SentinelOneManualCleanup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string] $LogDirectory)

    if (-not (Test-SentinelOneUninstallAdministrator)) { throw 'Run elevated or as SYSTEM.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Run cleanup in native 64-bit PowerShell.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\ANS.SentinelOneRepair')
    $locked = $false
    $logPath = $null
    $result = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Outcome = 'Failed'
        Changed = 0
        Unchanged = 0
        Skipped = 0
        Failed = 0
        RestartRequired = $false
        CleanupVerified = $false
        BackupPath = $null
        LogPath = $null
        RemainingTargets = @()
        Message = ''
    }
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another SentinelOne recovery, installation, or removal operation is running.' }
        $targets = @(Get-SentinelOneCleanupTargets)
        foreach ($target in $targets) { Write-Verbose ("Cleanup target: {0}; value={1}" -f $target.Path, $target.Name) }
        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Back up and remove listed SentinelOne remnants without invoking the vendor uninstaller; reboot and reinstall required')) {
            $result.Outcome = 'Skipped'
            $result.Skipped = $targets.Count
            return $result
        }
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        $logPath = Join-Path $LogDirectory ('Clear-SentinelOneAgentRemnants_{0}_{1}_{2}.log' -f
            $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'), [guid]::NewGuid().ToString('N'))
        $result.LogPath = $logPath
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
            '{0:o} Start; script=Clear-SentinelOneAgentRemnants; target={1}' -f (Get-Date), $env:COMPUTERNAME)
        $result.BackupPath = Initialize-SentinelOneCleanupBackup
        $manifestPath = Join-Path $result.BackupPath 'Manifest.json'
        $manifest = @()
        $eligible = @()
        $index = 0
        # Finish all possible backups before deletion. A failed copy/export
        # preserves that entire target while allowing unrelated targets to proceed.
        foreach ($target in $targets) {
            try {
                if (-not (Test-SentinelOneCleanupTarget -Target $target)) { $result.Unchanged++; continue }
                $index++
                $backupPath = Join-Path $result.BackupPath ('{0:D3}' -f $index)
                if ($target.Kind -eq 'Directory') {
                    Assert-SentinelOneCleanupDirectory -Path $target.Path
                    Copy-Item -LiteralPath $target.Path -Destination $backupPath -Recurse -Force
                }
                else {
                    $backupPath += '.reg'
                    & "$env:SystemRoot\System32\reg.exe" export $target.Path $backupPath /y *> $null
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                        throw 'Registry export failed; this target was retained.'
                    }
                }
                $manifest += [pscustomobject]@{ Kind = $target.Kind; Path = $target.Path; Name = $target.Name; BackupPath = $backupPath }
                $eligible += $target
            }
            catch {
                $result.Skipped++
                Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("BackupBlocked=$($target.Path); error=$($_.Exception.Message)")
            }
        }
        ConvertTo-Json -InputObject @($manifest) -Depth 4 |
            Set-Content -LiteralPath $manifestPath -Encoding UTF8
        foreach ($target in $eligible) {
            try {
                if (-not (Test-SentinelOneCleanupTarget -Target $target)) { $result.Unchanged++; continue }
                $providerPath = ConvertTo-SentinelOneCleanupProviderPath -Target $target
                # A failed recursive operation can be partial, so a reboot is
                # required once deletion has been attempted, even on failure.
                $result.RestartRequired = $true
                if ($target.Kind -eq 'Directory') {
                    Assert-SentinelOneCleanupDirectory -Path $target.Path
                    Remove-Item -LiteralPath $target.Path -Recurse -Force
                }
                elseif ($target.Kind -eq 'Value') {
                    Remove-ItemProperty -LiteralPath $providerPath -Name $target.Name -Force
                }
                else { Remove-Item -LiteralPath $providerPath -Recurse -Force }
                $result.Changed++
                Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("Removed=$($target.Path); value=$($target.Name)")
            }
            catch {
                $result.Skipped++
                Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("RemovalBlocked=$($target.Path); error=$($_.Exception.Message)")
            }
        }
        $remaining = @()
        foreach ($target in $targets) {
            try {
                if (Test-SentinelOneCleanupTarget -Target $target) { $remaining += $target }
            }
            catch { $remaining += $target }
        }
        $result.RemainingTargets = @($remaining | Select-Object Kind, Path, Name)
        $result.CleanupVerified = $remaining.Count -eq 0
        if ($remaining.Count) {
            $result.Failed = $remaining.Count
            $result.Outcome = 'CleanupIncomplete'
            $result.RestartRequired = $true
            $result.Message = 'Some remnants remain. Review the log, reboot, and rerun. For access denied, apply the ownership/permissions steps to the listed keys. Reinstall only after cleanup completes.'
            Write-Warning $result.Message
        }
        elseif ($result.RestartRequired) {
            $result.Outcome = 'RestartRequired'
            $result.Message = 'Listed remnants removed. Reboot before reinstalling the approved agent with the destination site token; verify protection and console check-in.'
            Write-Warning $result.Message
        }
        else {
            $result.Outcome = 'AlreadyAbsent'
            $result.Message = 'No listed remnants were found. This does not verify that all agent components are absent.'
        }
        return $result
    }
    catch {
        $result.Failed++
        throw
    }
    finally {
        try {
            if ($logPath) {
                Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
                    '{0:o} End; outcome={1}; changed={2}; unchanged={3}; skipped={4}; failed={5}; restartRequired={6}' -f
                    (Get-Date), $result.Outcome, $result.Changed, $result.Unchanged, $result.Skipped, $result.Failed, $result.RestartRequired)
            }
        }
        finally {
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

Invoke-SentinelOneManualCleanup -LogDirectory $LogDirectory -WhatIf:$WhatIfPreference -Confirm:$false
}
