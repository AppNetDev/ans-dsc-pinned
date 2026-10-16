#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot 'Uninstall-SentinelOneAgent.ps1'), [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load function definitions only: never execute the entry point against this endpoint.
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
$product = [pscustomobject]@{ ProductCode = '{12345678-1234-1234-1234-123456789ABC}'; WindowsInstaller = $true }
$state = [pscustomobject]@{ UninstallerPath = $null; Products = @($product) }
$command = Get-SentinelOneUninstallCommand -State $state
Assert-Condition ($command.ProductCode -eq $product.ProductCode -and $command.FilePath -like '*msiexec.exe') 'Registered MSI must use its validated product code.'
$state.Products = @($product, [pscustomobject]@{ ProductCode = '{AAAAAAAA-1234-1234-1234-123456789ABC}'; WindowsInstaller = $true })
Assert-Throws { Get-SentinelOneUninstallCommand -State $state } 'Ambiguous products must fail closed.'
$state.Products = @([pscustomobject]@{ ProductCode = 'injected arguments'; WindowsInstaller = $true })
Assert-Throws { Get-SentinelOneUninstallCommand -State $state } 'Non-GUID MSI targets must be rejected.'
function Get-AuthenticodeSignature { param($LiteralPath) return $script:Signature }
$state.UninstallerPath = 'C:\Fixture\uninstall.exe'
$script:Signature = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Sentinel Labs, Inc.' } }
Assert-Condition ((Get-SentinelOneUninstallCommand -State $state).FilePath -eq $state.UninstallerPath) 'Signed local uninstaller should be preferred.'
$script:Signature.Status = 'NotSigned'
Assert-Throws { Get-SentinelOneUninstallCommand -State $state } 'Unsigned uninstallers must be rejected.'
foreach ($password in @('quote"inside', "line`nbreak", 'trailing\', '   ')) {
    Assert-Throws { Invoke-SentinelOneUninstallProcess -Command $command -Password $password -TimeoutSeconds 30 } 'Unsafe secret must be rejected before process creation.'
}
# Mock process creation to verify quoting and failures without invoking any vendor binary.
function New-Object {
    param([string] $TypeName)
    if ($TypeName -ne 'System.Diagnostics.Process') { return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
    $process = [pscustomobject]@{
        StartInfo = $null; ExitCode = $script:NativeExitCode
        StandardOutput = [IO.StringReader]::new(''); StandardError = [IO.StringReader]::new('')
    }
    $process | Add-Member ScriptMethod Start { $script:NativeArguments = $this.StartInfo.Arguments; return $true }
    $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $script:NativeCompleted }
    $process | Add-Member ScriptMethod Dispose { }
    return $process
}
$script:NativeExitCode = 3010
$script:NativeCompleted = $true
$exitCode = Invoke-SentinelOneUninstallProcess -Command $command -Password 'test phrase & $ literal' -TimeoutSeconds 30
Assert-Condition ($exitCode -eq 3010) 'Native reboot code must be preserved.'
Assert-Condition ($script:NativeArguments -like '*UNINSTALL_KEY="test phrase & $ literal"*') 'MSI passphrase must remain one literal argument.'
$command.ProductCode = $null
$null = Invoke-SentinelOneUninstallProcess -Command $command -Password 'test phrase' -TimeoutSeconds 30
Assert-Condition ($script:NativeArguments -eq '/uninstall /norestart /q /k="test phrase"') 'Vendor EXE switches must suppress automatic restart.'
$script:NativeCompleted = $false
Assert-Throws { Invoke-SentinelOneUninstallProcess -Command $command -Password 'test phrase' -TimeoutSeconds 30 } 'Timeout must fail without retrying or terminating the installer.'
Remove-Item Function:\New-Object

function Test-SentinelOneUninstallAdministrator { return $true }
function Get-SentinelOneUninstallState { return $script:AgentState }
function Get-SentinelOneUninstallCommand { param($State) return [pscustomobject]@{ FilePath = 'fixture'; ProductCode = $null } }
function Invoke-SentinelOneUninstallProcess {
    param($Command, $Password, $TimeoutSeconds)
    $script:Invocations++
    if ($script:RemoveAgent) { $script:AgentState.Present = $false }
    return $script:NativeExitCode
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneUninstallTest-' + [guid]::NewGuid().ToString('N'))
$parameters = @{ Password = 'TEST-SECRET-NOT-LOGGED'; TimeoutSeconds = 30; VerificationTimeoutSeconds = 0; LogDirectory = $testRoot }
$script:AgentState = [pscustomobject]@{ Present = $false }
$script:Invocations = 0
$script:RemoveAgent = $false
try {
    $result = Invoke-SentinelOneUninstall @parameters
    Assert-Condition ($result.Outcome -eq 'AlreadyAbsent' -and $script:Invocations -eq 0) 'Absent agent must be an idempotent no-op.'
    $script:AgentState.Present = $true
    $result = Invoke-SentinelOneUninstall @parameters -WhatIf
    Assert-Condition ($result.Skipped -eq 1 -and $script:Invocations -eq 0 -and -not (Test-Path $testRoot)) 'WhatIf must not launch removal or write logs.'
    $script:NativeExitCode = 1603
    Assert-Throws { Invoke-SentinelOneUninstall @parameters } 'Vendor failures must terminate.'
    $script:NativeExitCode = 0
    Assert-Throws { Invoke-SentinelOneUninstall @parameters } 'Success with remaining registrations must not claim removal.'
    $script:NativeExitCode = 3010
    $result = Invoke-SentinelOneUninstall @parameters
    Assert-Condition ($result.RestartRequired -and -not $result.RemovalVerified) 'Pending reboot must remain distinct from verified removal.'
    $script:NativeExitCode = 0
    $script:RemoveAgent = $true
    $result = Invoke-SentinelOneUninstall @parameters
    Assert-Condition ($result.Outcome -eq 'Removed' -and $result.RemovalVerified) 'Removal must be verified locally.'
    $logs = (Get-ChildItem -LiteralPath $testRoot -File | Get-Content) -join "`n"
    Assert-Condition ($logs -notmatch 'TEST-SECRET-NOT-LOGGED') 'Logs must not contain the passphrase.'
    Assert-Condition ($logs -match 'outcome=Failed' -and $logs -match 'outcome=Removed') 'Logs must record failed and successful outcomes.'
    # Forced cleanup is gated on a supplied passkey and an accepted vendor exit.
    function Get-SentinelOneCleanupTargets { return @() }
    function Invoke-SentinelOneRemnantCleanup {
        param($LogPath)
        $script:CleanupInvocations++
        return [pscustomobject]@{ Changed = 3; Skipped = 4; BackupPath = 'fixture-backup' }
    }
    $script:CleanupInvocations = 0
    $beforeInvocations = $script:Invocations
    Assert-Throws { Invoke-SentinelOneUninstall -ForceCleanup -Password '' } 'Force mode must reject an omitted passkey before invoking the vendor.'
    Assert-Condition ($script:Invocations -eq $beforeInvocations) 'Missing passkey must cause no native invocation.'
    Assert-Throws { Invoke-SentinelOneUninstall @parameters -ForceCleanup } 'Orphaned remnants cannot bypass vendor passkey validation.'
    $script:AgentState.Present = $true
    $script:RemoveAgent = $false
    $result = Invoke-SentinelOneUninstall @parameters -ForceCleanup -WhatIf
    Assert-Condition ($script:CleanupInvocations -eq 0 -and $result.Skipped -eq 1) 'Force WhatIf must not clean remnants.'
    $script:NativeExitCode = 1603
    Assert-Throws { Invoke-SentinelOneUninstall @parameters -ForceCleanup } 'Vendor rejection must block force cleanup.'
    Assert-Condition ($script:CleanupInvocations -eq 0) 'Rejected passkey must never reach cleanup.'
    $script:NativeExitCode = 3010
    $result = Invoke-SentinelOneUninstall @parameters -ForceCleanup
    Assert-Condition ($result.RestartRequired -and $script:CleanupInvocations -eq 0) 'Vendor pending reboot must defer destructive cleanup.'
    $script:NativeExitCode = 0
    $result = Invoke-SentinelOneUninstall @parameters -ForceCleanup
    Assert-Condition ($script:CleanupInvocations -eq 1 -and $result.CleanupVerified -and $result.CleanupChanged -eq 3 -and
        $result.RestartRequired -and $result.BackupPath -eq 'fixture-backup') 'Accepted uninstall must back up and clean remnants, then require reboot.'
    [pscustomobject]@{ Passed = $passed; Failed = 0; AgentModified = $false }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneUninstallTest-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
