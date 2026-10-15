#Requires -Version 5.1
<#
.SYNOPSIS
    Tests or upgrades an existing SentinelOne agent using a signed, approved MSI.
.DESCRIPTION
    Supports a local MSI or HTTPS download, local checkout or GitHub script content.
    Stages a protected DSC configuration and returns state plus result/log paths.
    Get, Test, and WhatIf stage and validate files but never run MSI. Set requires
    a newer package when the existing agent is unhealthy. No service ACL changes,
    direct service configuration, binding, uninstall, or automatic reboot.
.PARAMETER InstallerPath
    Existing local MSI. If omitted, InstallerUri is downloaded.
.PARAMETER InstallerUri
    HTTPS MSI source. Its actual version, signature, and SHA256 are inspected.
.PARAMETER ExpectedSha256
    Optional trusted SHA256 to pin the package; signature validation is always required.
.PARAMETER Operation
    Get, Test, or Set (default). Test reports Healthy=False as drift, not engine failure.
.PARAMETER SourceBaseUri
    Raw GitHub repository root with the same revision as this wrapper.
.EXAMPLE
    .\Install-SentinelOneAgentDscV3.ps1 -InstallerPath $ApprovedMsiPath -Operation Test
.EXAMPLE
    .\Install-SentinelOneAgentDscV3.ps1 -InstallerPath $ApprovedMsiPath -ExpectedSha256 $ApprovedSha256
.NOTES
    Run elevated in 64-bit PowerShell with DSC 3.x installed. Artifacts default to
    C:\ANS\SentinelOneDsc. Preserve logs; confirm portal protection/check-in separately.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $InstallerPath,
    [uri] $InstallerUri = 'https://cwa.connectwise.com/tools/sentinelone/SentinelOneAgent-Windows_64bit.msi',
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string] $ExpectedSha256,
    [ValidateSet('Get', 'Test', 'Set')][string] $Operation = 'Set',
    [string] $DscPath,
    [ValidateRange(5, 300)][int] $HealthTimeoutSeconds = 60,
    [ValidateRange(30, 7200)][int] $MsiTimeoutSeconds = 900,
    [uri] $SourceBaseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master',
    [ValidateNotNullOrEmpty()][string] $WorkingDirectory = 'C:\ANS\SentinelOneDsc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not [Environment]::Is64BitProcess) { throw 'Run this wrapper in 64-bit PowerShell.' }
if ($InstallerUri.Scheme -ne 'https' -or $SourceBaseUri.Scheme -ne 'https') { throw 'Download sources must use HTTPS.' }
if ([string]::IsNullOrWhiteSpace($DscPath)) {
    $DscPath = (Get-Command -Name dsc.exe -CommandType Application -ErrorAction Stop).Source
}

function Set-SentinelOneWorkingDirectoryAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    $Acl = New-Object Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $Rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($Sid)), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Initialize-SentinelOneMsiRun {
    [CmdletBinding()]
    param([string] $LocalSourceDirectory)
    # File staging is needed even when the eventual agent operation is read-only.
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    $RunRoot = Join-Path $WorkingDirectory ([guid]::NewGuid().ToString('N'))
    Set-SentinelOneWorkingDirectoryAccess -Path $RunRoot
    $ResourceDirectory = Join-Path $RunRoot 'dscv3'
    $null = New-Item -ItemType Directory -Path $ResourceDirectory
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($FileName in @('SentinelOne.Msi.ps1', 'SentinelOne.Msi.Functions.ps1', 'SentinelOne.Msi.dsc.resource.json')) {
        $Destination = Join-Path $ResourceDirectory $FileName
        if ($LocalSourceDirectory) {
            Copy-Item -LiteralPath (Join-Path $LocalSourceDirectory $FileName) -Destination $Destination
        }
        else {
            Invoke-WebRequest -Uri ($SourceBaseUri.AbsoluteUri.TrimEnd('/') + '/dscv3/' + $FileName) -OutFile $Destination -UseBasicParsing -TimeoutSec 120
        }
    }
    # Absolute worker paths avoid dependence on DSC's current directory or PATH resolution.
    $ManifestPath = Join-Path $ResourceDirectory 'SentinelOne.Msi.dsc.resource.json'
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    foreach ($Method in @('get', 'test', 'set', 'whatIf')) {
        $Manifest.$Method.executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $Arguments = @($Manifest.$Method.args)
        $FileIndex = [Array]::IndexOf($Arguments, '-File')
        if ($FileIndex -lt 0) { throw 'Resource manifest is missing its worker path.' }
        $Arguments[$FileIndex + 1] = Join-Path $ResourceDirectory 'SentinelOne.Msi.ps1'
        $Manifest.$Method.args = $Arguments
    }
    # DSC manifest discovery requires UTF-8 without the BOM emitted by PS 5.1.
    $Utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($ManifestPath, ($Manifest | ConvertTo-Json -Depth 20), $Utf8)
    $PackagePath = Join-Path $RunRoot 'SentinelOne.msi'
    if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
        Copy-Item -LiteralPath $InstallerPath -Destination $PackagePath
    }
    else {
        Invoke-WebRequest -Uri $InstallerUri.AbsoluteUri -OutFile $PackagePath -UseBasicParsing -TimeoutSec 300
    }
    . (Join-Path $ResourceDirectory 'SentinelOne.Msi.Functions.ps1')
    $PackageParameters = @{ Path = $PackagePath }
    if ($ExpectedSha256) { $PackageParameters.ExpectedSha256 = $ExpectedSha256 }
    $Package = Get-SentinelOneMsiPackage @PackageParameters
    $StateDirectory = Join-Path $WorkingDirectory 'State'
    Set-SentinelOneWorkingDirectoryAccess -Path $StateDirectory
    $Properties = [ordered]@{
        PackagePath = $Package.Path
        PackageVersion = $Package.Version
        PackageSha256 = $Package.Sha256
        LogDirectory = Join-Path $RunRoot 'Logs'
        ReceiptPath = Join-Path $StateDirectory ('Reboot-{0}.json' -f $Package.Sha256)
        HealthTimeoutSeconds = $HealthTimeoutSeconds
        MsiTimeoutSeconds = $MsiTimeoutSeconds
        Healthy = $true
    }
    $ConfigurationPath = Join-Path $RunRoot 'SentinelOneMsi.dsc.json'
    $Configuration = [ordered]@{
        '$schema' = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
        resources = @(@{ name = 'UpgradeSentinelOneAgent'; type = 'AppNet.SentinelOne/MsiUpgrade'; properties = $Properties })
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($ConfigurationPath, $Configuration, $Utf8)
    [pscustomobject]@{
        ResourceDirectory = $ResourceDirectory
        ConfigurationPath = $ConfigurationPath
        ResultPath = Join-Path $RunRoot 'DscResult.json'
        DiagnosticPath = Join-Path $RunRoot 'DscDiagnostics.log'
        PackageVersion = $Package.Version
        PackageSha256 = $Package.Sha256
    }
}

$SourceDirectory = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $CandidateDirectory = Join-Path $PSScriptRoot 'dscv3'
    $Missing = @('SentinelOne.Msi.ps1', 'SentinelOne.Msi.Functions.ps1', 'SentinelOne.Msi.dsc.resource.json') |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $CandidateDirectory $_) -PathType Leaf) }
    if (@($Missing).Count -eq 0) { $SourceDirectory = $CandidateDirectory }
}
$Run = Initialize-SentinelOneMsiRun -LocalSourceDirectory $SourceDirectory
$DscOperation = $Operation.ToLowerInvariant()
if ($Operation -eq 'Set' -and -not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Apply SentinelOne MSI upgrade targeting $($Run.PackageVersion)")) {
    $DscOperation = 'test'
}
$OldResourcePath = $env:DSC_RESOURCE_PATH
try {
    $env:DSC_RESOURCE_PATH = $Run.ResourceDirectory
    # Capture stderr separately; Windows PowerShell can otherwise treat native
    # stderr as terminating PowerShell errors before we retain DSC's JSON result.
    $ProcessInfo = New-Object Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = $DscPath
    $ProcessInfo.Arguments = (@('config', $DscOperation, '--file', $Run.ConfigurationPath, '--output-format', 'json') |
        ForEach-Object { '"' + $_ + '"' }) -join ' '
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.CreateNoWindow = $true
    $ProcessInfo.RedirectStandardOutput = $true
    $ProcessInfo.RedirectStandardError = $true
    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    try {
        $null = $Process.Start()
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        $Output = $OutputTask.GetAwaiter().GetResult()
        $Diagnostics = $ErrorTask.GetAwaiter().GetResult()
        $ExitCode = $Process.ExitCode
    }
    finally { $Process.Dispose() }
    # Keep diagnostic results for failed DSC runs as well as successful ones.
    $Output | Set-Content -LiteralPath $Run.ResultPath -Encoding UTF8 -WhatIf:$false -Confirm:$false
    $Diagnostics | Set-Content -LiteralPath $Run.DiagnosticPath -Encoding UTF8 -WhatIf:$false -Confirm:$false
    if ($ExitCode -ne 0) { throw "DSC $DscOperation failed (exit $ExitCode). Results: $($Run.ResultPath); diagnostics: $($Run.DiagnosticPath)" }
    $Result = ($Output -join [Environment]::NewLine) | ConvertFrom-Json
    if ($Result.hadErrors) { throw "DSC reported errors. Results: $($Run.ResultPath)" }
    $ResourceResult = $Result.results[0].result
    $State = if ($DscOperation -eq 'set') { $ResourceResult.afterState } else { $ResourceResult.actualState }
    [pscustomobject]@{
        Operation = $DscOperation
        Outcome = $State.Outcome
        Healthy = [bool] $State.Healthy
        RestartRequired = [bool] $State.RestartRequired
        InstallerExitCode = $State.InstallerExitCode
        InstalledVersion = $State.InstalledVersion
        PackageVersion = $Run.PackageVersion
        PackageSha256 = $Run.PackageSha256
        UpgradeAvailable = [bool] ($State.InstalledVersion -and ([version] $State.InstalledVersion -lt [version] $Run.PackageVersion))
        ServiceState = $State.ServiceState
        StartMode = $State.StartMode
        AgentLoaded = [bool] $State.AgentLoaded
        SelfProtection = $State.SelfProtection
        Enrollment = $State.Enrollment
        ConfigurationPath = $Run.ConfigurationPath
        ResultPath = $Run.ResultPath
        DiagnosticPath = $Run.DiagnosticPath
        LogPath = $State.LogPath
    }
}
finally { $env:DSC_RESOURCE_PATH = $OldResourcePath }
