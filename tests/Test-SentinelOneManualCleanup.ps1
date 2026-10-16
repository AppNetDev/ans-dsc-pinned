#Requires -Version 5.1
<# .SYNOPSIS
    Tests manual cleanup against temporary files, without touching agent remnants.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Clear-SentinelOneAgentRemnants.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$testMutex = 'Local\ANS.SentinelOneManualCleanupTest-' + [guid]::NewGuid().ToString('N')
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text.Replace('Global\ANS.SentinelOneRepair', $testMutex)))
}
$script:Passed = 0
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Throws {
    param([scriptblock] $Action, [string] $Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Condition $rejected $Message
}
Assert-Condition (-not (Get-Command Invoke-SentinelOneManualCleanup).Parameters.ContainsKey('Password')) 'Manual cleanup must require no vendor passphrase.'
Assert-Condition ($ast.Extent.Text -notmatch 'Invoke-SentinelOneUninstallProcess|msiexec|Stop-Service|unprotect_by_approved_process') 'Manual cleanup must not invoke vendor uninstall or unload protection.'
Assert-Condition ((ConvertTo-SentinelOneCleanupProviderPath -Target ([pscustomobject]@{ Kind = 'Value'; Path = 'HKCU\Software\Fixture' })) -eq 'Registry::HKEY_CURRENT_USER\Software\Fixture') 'HKCU must resolve to the user backing hive.'
$listedTargets = @(Get-SentinelOneCleanupTargets)
Assert-Condition (@($listedTargets | Where-Object Kind -eq 'Directory').Count -eq 3) 'Only the three supplied directory roots may be removed.'
Assert-Condition (@($listedTargets | Where-Object { $_.Kind -eq 'Key' -and $_.Path -match '\\(?:Run|ApplicationAssociationToasts)$' }).Count -eq 0) 'Shared startup/toast keys must never be deleted.'
Assert-Condition (@($listedTargets | Where-Object { $_.Kind -eq 'Value' -and $_.Name -notin @('Sentinel Agent', 'SentinelOneLog_.binlog') }).Count -eq 0) 'Only supplied named startup/toast values may be deleted.'
Assert-Throws { Assert-SentinelOneCleanupDirectory -Path 'C:\Windows' } 'Windows root must not be an eligible deletion target.'

# Parse an existing reboot queue without writing to the real Session Manager key.
$parsedQueue = & {
    function Get-Item {
        param($LiteralPath)
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValue { param($Name, $DefaultValue) return @('\??\C:\Fixture\Delete.log', '', '\??\C:\Fixture\Rename.log', '\??\C:\Fixture\NewName.log') }
        $key | Add-Member ScriptMethod Dispose {}
        return $key
    }
    Get-SentinelOneQueuedDeletionPaths
}
Assert-Condition ($parsedQueue.Contains('c:\fixture\delete.log') -and -not $parsedQueue.Contains('C:\Fixture\Rename.log')) 'Queue reader must normalize deletion paths case-insensitively and ignore rename requests.'
$discovered = @(& {
    function Get-CimInstance {
        param($ClassName)
        if ($ClassName -eq 'Win32_SystemDriver') {
            [pscustomobject]@{ Name = 'SentinelNetworkMonitor'; PathName = '\SystemRoot\system32\drivers\SentinelOne\Fixture\Driver.sys'; State = 'Running' }
            [pscustomobject]@{ Name = 'SentinelUnrelated'; PathName = 'C:\OtherProduct\Driver.sys'; State = 'Running' }
        }
    }
    function Test-Path { param($LiteralPath) return $true }
    Get-SentinelOneRegisteredComponents
})
Assert-Condition ($discovered.Count -eq 1 -and $discovered[0].Name -eq 'SentinelNetworkMonitor') 'Driver discovery must recognize native SystemRoot paths and exclude unrelated paths.'
# Compile the native declaration, but never call MoveFileEx in fixture tests.
$nativeCommand = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type' }, $true)
Add-Type -TypeDefinition $nativeCommand.CommandElements[2].Value
Assert-Condition ($null -ne ('ANS.SentinelOneCleanup.NativeMethods' -as [type])) 'Native MoveFileEx declaration must compile in Windows PowerShell.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneManualCleanupTest-' + [guid]::NewGuid().ToString('N'))
$script:FirstTarget = Join-Path $testRoot 'FirstRemnant'
$script:SecondTarget = Join-Path $testRoot 'SecondRemnant'
$logDirectory = Join-Path $testRoot 'Logs'
$script:QueuedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:QueueCalls = @()
$script:QueueFailurePath = ''
$script:RegisteredComponents = @()
function Get-SentinelOneRegisteredComponents { return $script:RegisteredComponents }
function Get-SentinelOneQueuedDeletionPaths { return ,$script:QueuedPaths }
function Add-SentinelOneRebootDeletion {
    param([string] $Path)
    if ($Path -eq $script:QueueFailurePath) { throw 'Simulated queue failure' }
    $script:QueueCalls += $Path
}
function Test-SentinelOneUninstallAdministrator { return $true }
function Get-SentinelOneCleanupTargets {
    foreach ($path in @($script:FirstTarget, $script:SecondTarget)) {
        [pscustomobject]@{ Kind = 'Directory'; Path = $path; Name = $null }
    }
}
function Initialize-SentinelOneCleanupBackup {
    $backupPath = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $backupPath -Force
    return $backupPath
}
function Initialize-Fixture {
    foreach ($path in @($script:FirstTarget, $script:SecondTarget)) {
        $null = New-Item -ItemType Directory -Path $path -Force
        Set-Content -LiteralPath (Join-Path $path 'Vendor.log') -Value 'preserve evidence'
    }
}
try {
    Initialize-Fixture
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -WhatIf
    Assert-Condition ($result.Outcome -eq 'Skipped' -and -not (Test-Path -LiteralPath $logDirectory)) 'WhatIf must not write logs/backups or delete targets.'
    Assert-Condition (Test-Path -LiteralPath $script:FirstTarget) 'Preview must leave remnants present.'
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.Changed -eq 2 -and $result.CleanupVerified -and $result.RestartRequired -and $result.Failed -eq 0) 'No-password cleanup must remove backed-up targets and require reboot.'
    Assert-Condition ((Get-Content -LiteralPath (Join-Path $result.BackupPath '001\Vendor.log') -Raw) -match 'preserve evidence') 'Vendor evidence must survive backup.'
    $manifest = Get-Content -LiteralPath (Join-Path $result.BackupPath 'Manifest.json') -Raw | ConvertFrom-Json
    Assert-Condition ($manifest.Count -eq 2 -and $manifest[0].Path -eq $script:FirstTarget) 'Backup manifest must map originals to their backups.'
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false
    Assert-Condition ($result.Outcome -eq 'AlreadyAbsent' -and $result.Changed -eq 0 -and -not $result.RestartRequired) 'Repeated cleanup must converge without reporting new changes.'

    Initialize-Fixture
    function Copy-Item {
        param($LiteralPath, $Destination, [switch] $Recurse, [switch] $Force)
        if ($LiteralPath -eq $script:FirstTarget) { throw 'Simulated unreadable backup source' }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force:$Force
    }
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ((Test-Path -LiteralPath $script:FirstTarget) -and -not (Test-Path -LiteralPath $script:SecondTarget)) 'Backup failure must retain its original target while other backed-up targets continue.'
    Assert-Condition ($result.Outcome -eq 'CleanupIncomplete' -and $result.Failed -eq 1 -and $result.RemainingTargets.Count -eq 1) 'Incomplete cleanup must report remaining targets without claiming success.'
    Assert-Condition ($script:QueueCalls.Count -eq 0) 'A target whose backup failed must never be queued for deletion.'
    Remove-Item -LiteralPath Function:\Copy-Item

    Initialize-Fixture
    function Remove-Item {
        param($LiteralPath, [switch] $Recurse, [switch] $Force)
        if ($LiteralPath -eq $script:FirstTarget) { throw 'Simulated locked file' }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force
    }
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ((Test-Path -LiteralPath $script:FirstTarget) -and -not (Test-Path -LiteralPath $script:SecondTarget)) 'A locked target must not prevent independent cleanup.'
    Assert-Condition ($result.RestartRequired -and $result.Outcome -eq 'RebootDeletionScheduled' -and -not $result.CleanupVerified -and $result.ScheduledForDeletion -eq 2 -and $result.Failed -eq 0) 'Backed-up locked remnants must be scheduled without being reported as removed.'
    Assert-Condition ($script:QueueCalls[0] -eq (Join-Path $script:FirstTarget 'Vendor.log') -and $script:QueueCalls[1] -eq $script:FirstTarget) 'Queue must contain each file before its parent directory.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $result.BackupPath 'RebootDeletions.json')) 'A reboot-deletion receipt must be retained with the backup.'
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.AlreadyScheduled -eq 2 -and $result.ScheduledForDeletion -eq 0 -and $script:QueueCalls.Count -eq 2) 'Retries before reboot must not duplicate existing deletion requests.'

    # A remaining driver/service registration must prevent queuing its files.
    $script:QueuedPaths.Clear()
    $script:QueueCalls = @()
    $script:RegisteredComponents = @([pscustomobject]@{ Name = ('SentinelFixture' + [guid]::NewGuid().ToString('N')); Root = $script:FirstTarget })
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.Outcome -eq 'CleanupIncomplete' -and $result.RemainingComponents.Count -eq 1 -and $script:QueueCalls.Count -eq 0) 'Still-registered components must block deletion scheduling for their directory.'
    $script:RegisteredComponents = @()

    # A failed native queue operation must remain incomplete even if other
    # requests were accepted. No real reboot requests are made by this suite.
    $script:QueueFailurePath = Join-Path $script:FirstTarget 'Vendor.log'
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.Outcome -eq 'CleanupIncomplete' -and $result.Failed -gt 0 -and $result.ScheduledForDeletion -eq 1) 'Partial queue failure must not report the directory as fully scheduled.'
    $script:QueueFailurePath = ''
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath Function:\Remove-Item
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition (-not $result.CleanupVerified -and $result.Changed -eq 1 -and $result.RestartRequired) 'An immediate deletion retry must still require reboot while earlier requests are pending.'
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.Changed -eq 0 -and $result.Outcome -eq 'RebootDeletionScheduled' -and -not $result.CleanupVerified) 'Absent files must not imply safe reinstall when their deletion requests are still pending.'
    $script:QueuedPaths.Clear()
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false
    Assert-Condition ($result.CleanupVerified -and $result.Outcome -eq 'AlreadyAbsent') 'Post-reboot verification must succeed after remnants and pending requests are both absent.'

    Initialize-Fixture
    $linkPath = Join-Path $script:FirstTarget 'UnsafeLink'
    $null = New-Item -ItemType Junction -Path $linkPath -Target $script:SecondTarget
    $result = Invoke-SentinelOneManualCleanup -LogDirectory $logDirectory -Confirm:$false -WarningAction SilentlyContinue
    Assert-Condition ($result.Outcome -eq 'CleanupIncomplete' -and (Test-Path -LiteralPath $script:FirstTarget)) 'Junction-containing targets must not be recursively copied or deleted.'
    [IO.Directory]::Delete($linkPath)

    # Exercise a nested plan and reject any file absent from the completed backup.
    $null = New-Item -ItemType Directory -Path (Join-Path $script:FirstTarget 'Child\Grandchild') -Force
    Set-Content -LiteralPath (Join-Path $script:FirstTarget 'Child\Grandchild\Nested.log') -Value 'evidence'
    $planBackup = Join-Path $testRoot 'PlanBackup'
    Copy-Item -LiteralPath $script:FirstTarget -Destination $planBackup -Recurse -Force
    $script:QueuedPaths.Clear()
    $script:QueueCalls = @()
    $queue = @(Register-SentinelOneDirectoryRebootDeletion -Path $script:FirstTarget -BackupPath $planBackup -LogPath (Join-Path $logDirectory 'Plan.log'))
    Assert-Condition ($script:QueueCalls[-1] -eq $script:FirstTarget -and $script:QueueCalls[-2] -eq (Join-Path $script:FirstTarget 'Child') -and $script:QueueCalls[-3] -eq (Join-Path $script:FirstTarget 'Child\Grandchild')) 'Directories must be queued deepest first, with the root last.'
    Set-Content -LiteralPath (Join-Path $script:FirstTarget 'Unbacked.log') -Value 'created after backup'
    $script:QueuedPaths.Clear()
    $script:QueueCalls = @()
    Assert-Throws { Register-SentinelOneDirectoryRebootDeletion -Path $script:FirstTarget -BackupPath $planBackup -LogPath (Join-Path $logDirectory 'Plan.log') } 'Unbacked files must block the entire directory plan before scheduling.'
    Assert-Condition ($script:QueueCalls.Count -eq 0) 'Validation failure must not create any persistent deletion requests.'
    [pscustomobject]@{ Passed = $script:Passed; Failed = 0; LiveAgentModified = $false }
}
finally {
    foreach ($name in @('Copy-Item', 'Remove-Item')) {
        if (Test-Path -LiteralPath "Function:\$name") { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "Function:\$name" }
    }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneManualCleanupTest-*') { throw 'Unsafe test cleanup path.' }
    $linkPath = Join-Path $script:FirstTarget 'UnsafeLink'
    if ([IO.Directory]::Exists($linkPath)) { [IO.Directory]::Delete($linkPath) }
    if (Test-Path -LiteralPath $resolvedRoot) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
