#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'Uninstall-SentinelOneAgent.ps1'), [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) { . ([scriptblock]::Create($function.Extent.Text)) }
$passed = 0
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Assert-Throws {
    param([scriptblock] $Action, [string] $Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Condition $rejected $Message
}
$targets = @(Get-SentinelOneCleanupTargets)
Assert-Condition (@($targets | Where-Object Kind -eq 'Directory').Count -eq 3) 'Exactly three fixed directory roots must be eligible.'
Assert-Condition (@($targets | Where-Object { $_.Kind -eq 'Key' -and $_.Path -match '\\(?:Run|StartupApproved)$' }).Count -eq 0) 'Shared startup keys must never be deleted.'
Assert-Condition (@($targets | Where-Object Kind -eq 'Value').Count -eq 2) 'Startup cleanup must target only two named values.'
Assert-Condition (@($targets | Where-Object { $_.Path -match '^HKCU|^HKCR' }).Count -eq 0) 'Cleanup must not affect merged classes or the RMM account user hive.'
Assert-Throws { Assert-SentinelOneCleanupDirectory -Path 'C:\Windows' } 'Windows root must never be eligible for recursive deletion.'
function Get-CimInstance { param($ClassName) return $script:Components }
$script:Components = @([pscustomobject]@{ Name = 'SentinelMonitor'; PathName = 'fixture'; State = 'Running' })
Assert-Throws { Assert-SentinelOneComponentsStopped } 'Loaded SentinelOne driver must block cleanup.'
$script:Components = @([pscustomobject]@{ Name = 'LogProcessorService'; PathName = 'C:\Program Files\SentinelOne\fixture.exe'; State = 'Start Pending' })
Assert-Throws { Assert-SentinelOneComponentsStopped } 'Pending product components must block cleanup.'
$script:Components = @([pscustomobject]@{ Name = 'Unrelated'; PathName = 'C:\Windows\fixture.exe'; State = 'Running' })
Assert-SentinelOneComponentsStopped
Assert-Condition $true 'Unrelated active services must not block cleanup.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneCleanupTest-' + [guid]::NewGuid().ToString('N'))
$script:FixturePath = Join-Path $testRoot 'AgentRemnants'
$script:BackupPath = Join-Path $testRoot 'Backups'
$logPath = Join-Path $testRoot 'Cleanup.log'
function Get-SentinelOneCleanupTargets {
    [pscustomobject]@{ Kind = 'Directory'; Path = $script:FixturePath; Name = $null }
}
function Initialize-SentinelOneCleanupBackup {
    $null = New-Item -ItemType Directory -Path $script:BackupPath -Force
    return $script:BackupPath
}
try {
    $null = New-Item -ItemType Directory -Path $script:FixturePath -Force
    Set-Content -LiteralPath (Join-Path $script:FixturePath 'Vendor.log') -Value 'preserved vendor evidence'
    $result = Invoke-SentinelOneRemnantCleanup -LogPath $logPath
    Assert-Condition ($result.Changed -eq 1 -and -not (Test-Path -LiteralPath $script:FixturePath)) 'Allowlisted fixture must be removed after backup.'
    Assert-Condition ((Get-Content -LiteralPath (Join-Path $script:BackupPath '001\Vendor.log') -Raw) -match 'preserved vendor evidence') 'Vendor logs must survive in backup.'
    $manifest = Get-Content -LiteralPath (Join-Path $script:BackupPath 'Manifest.json') -Raw | ConvertFrom-Json
    Assert-Condition ($manifest.Path -eq $script:FixturePath) 'Manifest must preserve the original restoration target.'
    $result = Invoke-SentinelOneRemnantCleanup -LogPath $logPath
    Assert-Condition ($result.Changed -eq 0) 'Repeated cleanup must converge safely.'
    $null = New-Item -ItemType Directory -Path $script:FixturePath -Force
    Set-Content -LiteralPath (Join-Path $script:FixturePath 'Keep.txt') -Value 'must remain'
    function Copy-Item { param($LiteralPath, $Destination, [switch] $Recurse, [switch] $Force) throw 'Simulated backup failure' }
    Assert-Throws { Invoke-SentinelOneRemnantCleanup -LogPath $logPath } 'Failed backup must abort cleanup.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $script:FixturePath 'Keep.txt')) 'Backup failure must preserve originals.'
    Remove-Item Function:\Copy-Item
    $null = New-Item -ItemType Junction -Path (Join-Path $script:FixturePath 'UnsafeLink') -Target $script:BackupPath
    Assert-Throws { Assert-SentinelOneCleanupDirectory -Path $script:FixturePath } 'Junctions inside cleanup trees must be rejected.'
    # Remove the junction itself without traversing its target.
    [IO.Directory]::Delete((Join-Path $script:FixturePath 'UnsafeLink'))
    [pscustomobject]@{ Passed = $passed; Failed = 0; AgentModified = $false }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneCleanupTest-*') { throw 'Unsafe test cleanup path.' }
    # If an assertion failed before junction removal, still remove that link first.
    $linkPath = Join-Path $script:FixturePath 'UnsafeLink'
    if (Test-Path -LiteralPath $linkPath) { [IO.Directory]::Delete($linkPath) }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
