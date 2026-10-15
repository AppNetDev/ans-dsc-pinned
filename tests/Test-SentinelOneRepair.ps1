#Requires -Version 5.1
<#
.SYNOPSIS
    Tests recovery detection and bind receipts without touching the installed agent.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot 'dscv3\SentinelOne.Repair.ps1'), [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$passed = 0
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}
# All service queries are simulated; the resource entry point is never executed.
function Get-CimInstance { param($ClassName, $Filter) return $script:RegisteredService }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneTest-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $exe = Join-Path $testRoot 'SentinelAgent.exe'
    $ctl = Join-Path $testRoot 'SentinelCtl.exe'
    Set-Content -LiteralPath $exe -Value 'test fixture; never executed'
    Set-Content -LiteralPath $ctl -Value 'test fixture; never executed'
    $script:RegisteredService = [pscustomobject]@{ PathName = '"' + $exe + '" --service'; StartMode = 'Auto'; State = 'Running' }
    $settings = [ordered]@{ Ready = $true; Reenroll = $false; RequestId = ''; InstallerUri = 'https://example.invalid/agent.msi' }
    Assert-Condition ((Get-AgentFiles).ControlPath -eq $ctl) 'Control utility must be located beside the registered executable.'
    Assert-Condition ((Get-RepairState -Settings $settings).Ready) 'Healthy service should converge in repair-only mode.'
    $script:RegisteredService.State = 'Stopped'
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'Stopped service must require recovery.'
    $script:RegisteredService.State = 'Running'
    $script:RegisteredService.StartMode = 'Disabled'
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'Disabled startup must require recovery.'
    $script:RegisteredService.StartMode = 'Auto'
    Remove-Item -LiteralPath $ctl
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'Missing control binary must require recovery.'
    Set-Content -LiteralPath $ctl -Value 'test fixture; never executed'
    $serviceCopy = $script:RegisteredService
    $script:RegisteredService = $null
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'Missing service must require installation.'
    $script:RegisteredService = $serviceCopy
    # Redirect receipts into the test root, never C:\ANS.
    function Get-BindReceiptPath { param([string] $RequestId) return (Join-Path $testRoot 'Receipt.json') }
    $settings.Reenroll = $true
    $settings.RequestId = 'CHG-TEST-1'
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'A healthy service alone must not satisfy a requested bind.'
    $receipt = @{ RequestId = 'CHG-TEST-1'; ComputerName = $env:COMPUTERNAME; Outcome = 'BindCommandAccepted' }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Get-BindReceiptPath '')
    $state = Get-RepairState -Settings $settings
    Assert-Condition ($state.Ready -and $state.BindCommandAccepted -and $state.Enrollment -eq 'NotVerified') 'Accepted request should converge without claiming enrollment.'
    $settings.RequestId = 'CHG-TEST-2'
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'A new request ID must require another bind.'
    $settings.RequestId = 'CHG-TEST-1'
    $receipt.ComputerName = 'OTHER-ENDPOINT'
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Get-BindReceiptPath '')
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'A receipt from another endpoint must be rejected.'
    Set-Content -LiteralPath (Get-BindReceiptPath '') -Value 'invalid json'
    Assert-Condition (-not (Get-RepairState -Settings $settings).Ready) 'Invalid receipts must not suppress a bind.'
    foreach ($value in @('quote"inside', "line`nbreak", 'trailing\')) {
        $rejected = $false
        try { Assert-NativeSecret -Value $value } catch { $rejected = $true }
        Assert-Condition $rejected 'Unsupported secret characters must be rejected before native invocation.'
    }
    $nativeExit = Invoke-RepairProcess -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 7') -TimeoutSeconds 10
    Assert-Condition ($nativeExit -eq 7) 'Native failures must preserve their exit code.'
    [pscustomobject]@{ Passed = $passed; Failed = 0; AgentModified = $false }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneTest-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
