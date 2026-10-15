#Requires -Version 5.1
<#
.SYNOPSIS
    Exercises the MSI wrapper/resource using real DSC with isolated agent/MSI fixtures.
.NOTES
    Never runs msiexec, SentinelCtl, real CIM service queries, or changes service ACLs.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$dscPath = (Get-Command -Name dsc.exe -CommandType Application -ErrorAction Stop).Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneMsiTest-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$global:SentinelOneMsiTestPassed = 0
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $global:SentinelOneMsiTestPassed++
}
function Assert-Rejected {
    param([scriptblock] $Action, [string] $Expected)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Condition ($message -like "*$Expected*") "Expected rejection containing '$Expected'; got '$message'."
}
# Do not modify filesystem ACLs during fixture tests. Check the supplied DACL instead.
function Set-Acl {
    param($LiteralPath, $AclObject)
    $rules = @($AclObject.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    Assert-Condition ($AclObject.AreAccessRulesProtected -and $rules.Count -eq 2) 'Staging must request a protected Admin/SYSTEM DACL.'
}
try {
    . (Join-Path $repositoryRoot 'dscv3\SentinelOne.Msi.Functions.ps1')
    $fakeMsi = Join-Path $testRoot 'Approved.msi'
    Set-Content -LiteralPath $fakeMsi -Value 'test fixture; never executed'
    $packageHash = (Get-FileHash -LiteralPath $fakeMsi -Algorithm SHA256).Hash
    Assert-Rejected { Get-SentinelOneMsiPackage -Path $fakeMsi -ExpectedSha256 ('0' * 64) } 'SHA256'
    Assert-Rejected { Get-SentinelOneMsiPackage -Path $fakeMsi -ExpectedSha256 $packageHash } 'valid SentinelOne'
    # Exercise the real timeout implementation while intercepting process creation.
    $script:FakeProcessDisposed = $false
    function Start-Process {
        param($FilePath, $ArgumentList, [switch] $PassThru, $WindowStyle)
        $process = [pscustomobject]@{ Id = 12345 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $false }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:FakeProcessDisposed = $true }
        return $process
    }
    Assert-Rejected { Invoke-SentinelOneMsiInstall -PackagePath $fakeMsi -TimeoutSeconds 30 } 'was not terminated'
    Assert-Condition $script:FakeProcessDisposed 'Timed-out process handle must be disposed.'
    Remove-Item -LiteralPath Function:\Start-Process

    $sourceRoot = Join-Path $testRoot 'Source'
    $resourceRoot = Join-Path $sourceRoot 'dscv3'
    $null = New-Item -ItemType Directory -Path $resourceRoot -Force
    $wrapper = Join-Path $sourceRoot 'Install-SentinelOneAgentDscV3.ps1'
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'Install-SentinelOneAgentDscV3.ps1') -Destination $wrapper
    foreach ($name in @('SentinelOne.Msi.ps1', 'SentinelOne.Msi.Functions.ps1', 'SentinelOne.Msi.dsc.resource.json')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "dscv3\$name") -Destination (Join-Path $resourceRoot $name)
    }
    $fixturePath = Join-Path $testRoot 'Fixture.json'
    $invocationsPath = Join-Path $testRoot 'MsiInvocations.log'
    $agentPath = Join-Path $testRoot 'SentinelAgent.exe'
    Set-Content -LiteralPath $agentPath -Value 'test fixture; never executed'
    Set-Content -LiteralPath (Join-Path $testRoot 'SentinelCtl.exe') -Value 'test fixture; never executed'
    $overrides = @'

# Isolated test dependencies. No endpoint service or installer is ever invoked.
$script:FixturePath = '__FIXTURE_PATH__'
function Read-Fixture { Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json }
function Get-SentinelOneMsiPackage {
    param([string] $Path, [string] $ExpectedSha256)
    $fixture = Read-Fixture
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($ExpectedSha256 -and $ExpectedSha256 -ne $hash) { throw 'MSI SHA256 does not match the expected hash.' }
    [pscustomobject]@{ Path = $Path; Version = $fixture.PackageVersion; Sha256 = $hash; ProductName = 'Sentinel Agent fixture' }
}
function Test-SentinelOneAdministrator { return $true }
function Get-CimInstance {
    param($ClassName, $Filter)
    $fixture = Read-Fixture
    if ($ClassName -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{ LastBootUpTime = [datetime] $fixture.BootTime }
    }
    if ($ClassName -ne 'Win32_Service') { throw 'Unexpected fixture CIM query.' }
    if ($fixture.ServiceState -eq 'Missing') { return $null }
    [pscustomobject]@{ State = $fixture.ServiceState; StartMode = $fixture.StartMode; PathName = ('"{0}"' -f $fixture.AgentPath) }
}
function Get-Item {
    param([string] $LiteralPath)
    $fixture = Read-Fixture
    if ($LiteralPath -eq $fixture.AgentPath) {
        return [pscustomobject]@{ VersionInfo = [pscustomobject]@{ ProductVersion = $fixture.InstalledVersion } }
    }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
}
function Test-Path {
    param([string] $LiteralPath, $PathType)
    if ($LiteralPath -like 'HKLM:*') { return [bool] (Read-Fixture).PendingReboot }
    if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Invoke-SentinelOneStatus {
    param([string] $Path)
    $fixture = Read-Fixture
    $agent = if ($fixture.AgentLoaded) { 'loaded' } else { 'not loaded' }
    [pscustomobject]@{ ExitCode = $fixture.StatusExitCode; Output = "SentinelAgent is $agent`r`nSelf-Protection status: $($fixture.SelfProtection)`r`n" }
}
function Invoke-SentinelOneMsiInstall {
    param([string] $PackagePath, [int] $TimeoutSeconds)
    $fixture = Read-Fixture
    Add-Content -LiteralPath $fixture.InvocationsPath -Value 'Simulated MSI'
    if ($fixture.ExitCode -in @(0, 3010)) {
        $fixture.InstalledVersion = $fixture.PackageVersion
        $fixture.ServiceState = 'Running'
        $fixture.StartMode = 'Auto'
        $fixture.AgentLoaded = $fixture.PostUpgradeHealthy
        $fixture.SelfProtection = if ($fixture.PostUpgradeHealthy) { 'On' } else { 'Off' }
        $fixture | ConvertTo-Json | Set-Content -LiteralPath $script:FixturePath -Encoding UTF8
    }
    return $fixture.ExitCode
}
'@
    $overrides = $overrides.Replace('__FIXTURE_PATH__', $fixturePath.Replace("'", "''"))
    Add-Content -LiteralPath (Join-Path $resourceRoot 'SentinelOne.Msi.Functions.ps1') -Value $overrides
    $fixture = [ordered]@{
        PackageVersion = '25.3.1.100'; InstalledVersion = '25.2.6.442'
        ServiceState = 'Start Pending'; StartMode = 'Auto'; AgentLoaded = $false
        SelfProtection = 'Off'; StatusExitCode = 0; ExitCode = 0; PostUpgradeHealthy = $true
        PendingReboot = $false; BootTime = '2026-01-01T00:00:00Z'
        AgentPath = $agentPath; InvocationsPath = $invocationsPath
    }
    function Save-Fixture { $fixture | ConvertTo-Json | Set-Content -LiteralPath $fixturePath -Encoding UTF8 }
    function Get-InvocationCount {
        if (-not (Test-Path -LiteralPath $invocationsPath)) { return 0 }
        return @(Get-Content -LiteralPath $invocationsPath).Count
    }
    $parameters = @{
        InstallerPath = $fakeMsi; ExpectedSha256 = $packageHash; DscPath = $dscPath
        WorkingDirectory = (Join-Path $testRoot 'Runs'); HealthTimeoutSeconds = 5
    }
    Save-Fixture
    $beforeResourcePath = $env:DSC_RESOURCE_PATH
    foreach ($operation in @('Get', 'Test')) {
        $result = & $wrapper @parameters -Operation $operation
        Assert-Condition (-not $result.Healthy -and $result.AgentLoaded -eq $false -and $result.SelfProtection -eq 'Off') "$operation must detect the supplied broken-agent state despite status exit zero."
        Assert-Condition ((Get-InvocationCount) -eq 0) "$operation must never invoke MSI."
        Assert-Condition (Test-Path -LiteralPath $result.ResultPath) 'DSC result must be retained.'
        Assert-Condition $result.UpgradeAvailable 'Test output must identify an available newer target.'
    }
    $result = & $wrapper @parameters -WhatIf
    Assert-Condition ($result.Operation -eq 'test' -and (Get-InvocationCount) -eq 0) 'WhatIf must use real DSC Test without MSI.'
    Assert-Condition ($env:DSC_RESOURCE_PATH -eq $beforeResourcePath) 'Wrapper must restore resource discovery.'
    $configText = Get-Content -LiteralPath $result.ConfigurationPath -Raw
    Assert-Condition ($configText -notmatch 'SiteToken|Passphrase') 'Upgrade configuration must contain no enrollment credentials.'

    $result = & $wrapper @parameters
    Assert-Condition ($result.Healthy -and $result.AgentLoaded -and $result.SelfProtection -eq 'On') 'Successful upgrade must satisfy all health checks.'
    Assert-Condition ($result.InstalledVersion -eq $fixture.PackageVersion -and (Get-InvocationCount) -eq 1) 'Upgrade must run once and reach the target version.'
    $result = & $wrapper @parameters
    Assert-Condition ($result.Healthy -and (Get-InvocationCount) -eq 1) 'Healthy target must converge without a second MSI invocation.'

    $fixture.InstalledVersion = $fixture.PackageVersion
    $fixture.AgentLoaded = $false
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 1) 'Unhealthy same-version agent must not trigger a forced reinstall.'
    $fixture.InstalledVersion = '26.1.1.100'
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 1) 'Unhealthy newer agent must not be downgraded.'
    $fixture.InstalledVersion = '25.2.6.442'
    $fixture.ServiceState = 'Missing'
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 1) 'Missing agents must not be installed by the upgrade resource.'
    $fixture.ServiceState = 'Start Pending'
    $fixture.PendingReboot = $true
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 1) 'Pending Windows reboot must block installation.'
    $fixture.PendingReboot = $false
    $fixture.ExitCode = 1603
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 2) 'MSI failure must be surfaced.'
    $fixture.ExitCode = 0
    $fixture.PostUpgradeHealthy = $false
    Save-Fixture
    Assert-Rejected { & $wrapper @parameters } 'DSC set failed'
    Assert-Condition ((Get-InvocationCount) -eq 3) 'MSI exit zero without health must fail.'

    $fixture.InstalledVersion = '25.2.6.442'
    $fixture.ExitCode = 3010
    Save-Fixture
    $result = & $wrapper @parameters
    Assert-Condition ($result.RestartRequired -and -not $result.Healthy -and $result.Outcome -eq 'RebootRequired') '3010 must report reboot required without claiming health.'
    Assert-Condition ((Get-InvocationCount) -eq 4) 'Reboot-required upgrade must run exactly once.'
    $result = & $wrapper @parameters
    Assert-Condition ($result.RestartRequired -and (Get-InvocationCount) -eq 4) 'Boot-scoped receipt must block another MSI attempt before restart.'
    $fixture.BootTime = '2026-01-02T00:00:00Z'
    $fixture.InstalledVersion = $fixture.PackageVersion
    $fixture.ServiceState = 'Running'
    $fixture.AgentLoaded = $true
    $fixture.SelfProtection = 'On'
    Save-Fixture
    $result = & $wrapper @parameters -Operation Test
    Assert-Condition ($result.Healthy -and -not $result.RestartRequired) 'After simulated reboot, health must be evaluated without a stale reboot flag.'
    # Exercise the wrapper fetched as text, sourcing companion fixtures via mocked HTTPS.
    function Invoke-WebRequest {
        param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
        if ($Uri -like 'https://example.invalid/revision/dscv3/*') {
            Copy-Item -LiteralPath (Join-Path $resourceRoot ($Uri.Split('/')[-1])) -Destination $OutFile
        }
        elseif ($Uri -eq 'https://example.invalid/approved.msi') {
            Copy-Item -LiteralPath $fakeMsi -Destination $OutFile
        }
        else { throw 'Unexpected fixture download.' }
    }
    $remoteParameters = @{
        InstallerUri = 'https://example.invalid/approved.msi'
        SourceBaseUri = 'https://example.invalid/revision'
        WorkingDirectory = (Join-Path $testRoot 'RemoteRuns')
        DscPath = $dscPath
        Operation = 'Test'
        ExpectedSha256 = $packageHash
    }
    $result = & ([scriptblock]::Create((Get-Content -LiteralPath $wrapper -Raw))) @remoteParameters
    Assert-Condition ($result.Healthy -and (Get-InvocationCount) -eq 4) 'Downloaded wrapper must stage companions and evaluate health without MSI.'
    Assert-Condition ($result.ConfigurationPath.StartsWith($remoteParameters.WorkingDirectory)) 'Downloaded invocation must retain its own run artifacts.'
    $remoteParameters.ExpectedSha256 = '0' * 64
    Assert-Rejected { & ([scriptblock]::Create((Get-Content -LiteralPath $wrapper -Raw))) @remoteParameters } 'SHA256'
    [pscustomobject]@{ Passed = $global:SentinelOneMsiTestPassed; Failed = 0; RealDscEngine = $true; AgentModified = $false }
}
catch {
    Get-ChildItem -LiteralPath $testRoot -Filter DscDiagnostics.log -Recurse -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime |
        Select-Object -Last 1 |
        ForEach-Object { Write-Warning (Get-Content -LiteralPath $_.FullName -Raw) }
    throw
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneMsiTest-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    Remove-Variable -Name SentinelOneMsiTestPassed -Scope Global
}
