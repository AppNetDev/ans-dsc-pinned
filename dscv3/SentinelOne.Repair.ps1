#Requires -Version 5.1
<#
.SYNOPSIS
    DSC v3 command resource for SentinelOne service recovery and explicit bind requests.
.NOTES
    Secrets are read from process environment only and are never returned as DSC state.
    Ready means local recovery and requested commands completed, not portal enrollment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('get', 'set')]
    [string] $Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-AgentFiles {
    [CmdletBinding()]
    param()
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='SentinelAgent'"
    if ($null -eq $service) { return $null }
    $path = [Environment]::ExpandEnvironmentVariables($service.PathName)
    if ($path -notmatch '^\s*(?:"(?<Executable>[^"]+\.exe)"|(?<Executable>.+?\.exe))(?:\s|$)') {
        throw 'Cannot resolve the registered SentinelAgent executable path.'
    }
    $executable = $Matches.Executable
    $ctl = Join-Path (Split-Path -Path $executable -Parent) 'SentinelCtl.exe'
    [pscustomobject]@{
        Service = $service
        ControlPath = $ctl
        FilesPresent = ((Test-Path -LiteralPath $executable -PathType Leaf) -and
            (Test-Path -LiteralPath $ctl -PathType Leaf))
    }
}

function Get-BindReceiptPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($RequestId))).Replace('-', '')
        Join-Path 'C:\ANS\SentinelOne\BindRequests' "$hash.json"
    } finally { $sha.Dispose() }
}

function Test-BindReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)
    $path = Get-BindReceiptPath -RequestId $RequestId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return ($receipt.RequestId -ceq $RequestId -and $receipt.ComputerName -eq $env:COMPUTERNAME -and
            $receipt.Outcome -eq 'BindCommandAccepted')
    } catch { return $false }
}

function Get-RepairState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Settings)
    $agent = Get-AgentFiles
    $healthy = $null -ne $agent -and $agent.FilesPresent -and
        $agent.Service.StartMode -eq 'Auto' -and $agent.Service.State -eq 'Running'
    $bindAccepted = $false
    if ($Settings.Reenroll) { $bindAccepted = Test-BindReceipt -RequestId $Settings.RequestId }
    $state = [ordered]@{}
    foreach ($key in $Settings.Keys) { $state[$key] = $Settings[$key] }
    $state.Ready = [bool] ($healthy -and (-not $Settings.Reenroll -or $bindAccepted))
    $state.Enrollment = 'NotVerified'
    $state.BindCommandAccepted = $bindAccepted
    [pscustomobject] $state
}

function Assert-NativeSecret {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Value)
    if ($Value -match '["\r\n\x00]' -or $Value -match '\\$') {
        throw 'A secret contains unsupported native argument characters.'
    }
}

function Invoke-RepairProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    # Do not include native output or arguments in exceptions, logs, or DSC state.
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # An MSI may still be running in the installer service. Do not kill it or retry automatically.
            throw 'Native operation timed out. Inspect agent and Windows Installer state before retrying.'
        }
        $null = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Write-RepairLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)
    Add-Content -LiteralPath $script:LogPath -Value ('{0:o} {1}' -f (Get-Date), $Message) -Encoding UTF8
}

function Set-RepairState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Settings)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run elevated or as SYSTEM.'
    }
    $mutex = New-Object Threading.Mutex($false, 'Global\ANS.SentinelOneRepair')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another SentinelOne recovery operation is running.' }
        if ((Get-RepairState -Settings $Settings).Ready) { return }
        $agent = Get-AgentFiles
        $installNeeded = $null -eq $agent -or -not $agent.FilesPresent
        $bindNeeded = $Settings.Reenroll -and -not (Test-BindReceipt -RequestId $Settings.RequestId)
        $siteToken = $env:SENTINELONE_SITE_TOKEN
        $passphrase = $env:SENTINELONE_AGENT_PASSPHRASE
        if (($installNeeded -or $bindNeeded) -and [string]::IsNullOrWhiteSpace($siteToken)) {
            throw 'Installation or re-enrollment requires SiteToken / SENTINELONE_SITE_TOKEN.'
        }
        Assert-NativeSecret -Value $siteToken
        Assert-NativeSecret -Value $passphrase
        if ($installNeeded -and -not [Environment]::Is64BitOperatingSystem) {
            throw 'The configured MSI requires 64-bit Windows.'
        }
        $root = 'C:\ANS\SentinelOne'
        $null = New-Item -ItemType Directory -Path $root -Force
        # Protect the downloaded executable and bind receipts from ordinary users.
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $root -AclObject $acl
        $logDirectory = Join-Path $root 'Logs'
        $null = New-Item -ItemType Directory -Path $logDirectory -Force
        $script:LogPath = Join-Path $logDirectory ('SentinelOneRepair_{0}_{1}.log' -f
            $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmmss_fff'))
        $changed = @()
        $unchanged = @()
        $outcome = 'Failed'
        Write-RepairLog "Start; script=SentinelOneRepair; target=$env:COMPUTERNAME"
        try {
            if ($installNeeded) {
                $msiPath = Join-Path $root ('Agent_{0}.msi' -f [guid]::NewGuid().ToString('N'))
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $Settings.InstallerUri -OutFile $msiPath -UseBasicParsing -TimeoutSec 300
                    $signature = Get-AuthenticodeSignature -LiteralPath $msiPath
                    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)\bSentinel(?:\s*One| Labs)\b') {
                        throw 'MSI must have a valid SentinelOne Authenticode signature.'
                    }
                    $exitCode = Invoke-RepairProcess -FilePath "$env:SystemRoot\System32\msiexec.exe" -Arguments @(
                        '/i', $msiPath, '/qn', '/norestart', 'REBOOT=ReallySuppress', "SITE_TOKEN=$siteToken"
                    ) -TimeoutSeconds 900
                    Write-RepairLog "MSI exit=$exitCode"
                    if ($exitCode -eq 3010) { throw 'MSI requires a reboot (3010). Reboot during an approved window, then rerun this configuration.' }
                    if ($exitCode -ne 0) { throw "MSI failed (exit $exitCode). Inspect vendor logs; no uninstall or forced reinstall was attempted." }
                    $changed += 'MsiInstall'
                } finally {
                    if (Test-Path -LiteralPath $msiPath) { Remove-Item -LiteralPath $msiPath -Force }
                }
                $agent = Get-AgentFiles
                if ($null -eq $agent -or -not $agent.FilesPresent) { throw 'Agent service or binaries are still missing after MSI installation.' }
            } else { $unchanged += 'AgentFiles' }
            if ($agent.Service.StartMode -ne 'Auto') {
                Set-Service -Name SentinelAgent -StartupType Automatic
                $changed += 'StartupType'
            } else { $unchanged += 'StartupType' }
            $service = Get-Service -Name SentinelAgent
            if ($service.Status -ne 'Running') {
                Start-Service -Name SentinelAgent
                $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                $changed += 'ServiceStart'
            } else { $unchanged += 'ServiceStart' }
            if ($bindNeeded) {
                $arguments = @('bind', $siteToken)
                if (-not [string]::IsNullOrWhiteSpace($passphrase)) { $arguments += @('-k', $passphrase) }
                $exitCode = Invoke-RepairProcess -FilePath $agent.ControlPath -Arguments $arguments -TimeoutSeconds 30
                if ($exitCode -ne 0) { throw "SentinelCtl bind failed (exit $exitCode). Check installed-version syntax, passphrase, and console association." }
                $receiptPath = Get-BindReceiptPath -RequestId $Settings.RequestId
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $receiptPath) -Force
                [ordered]@{
                    RequestId = $Settings.RequestId
                    ComputerName = $env:COMPUTERNAME
                    Outcome = 'BindCommandAccepted'
                    Timestamp = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
                $changed += 'BindCommandAccepted'
                Write-Warning 'Bind accepted; verify a fresh destination-site check-in. Follow installed-version restart guidance. Same-console binds may fail silently.'
            }
            $statusCode = Invoke-RepairProcess -FilePath $agent.ControlPath -Arguments @('status') -TimeoutSeconds 30
            Write-RepairLog "Status exit=$statusCode; enrollment=NotVerified"
            if ($statusCode -ne 0) { Write-Warning 'SentinelCtl status failed; service state does not prove protection or enrollment.' }
            if (-not (Get-RepairState -Settings $Settings).Ready) { throw 'Local recovery did not converge.' }
            $outcome = 'CompletedPortalVerificationRequired'
        } finally {
            Write-RepairLog ('End; outcome={0}; changed={1}; unchanged={2}; skipped={3}; failed={4}' -f
                $outcome, ($changed -join ','), ($unchanged -join ','),
                $(if ($bindNeeded) { 'None' } else { 'BindNotRequestedOrAlreadyAccepted' }),
                $(if ($outcome -eq 'Failed') { 1 } else { 0 }))
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try {
    $inputObject = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $settings = [ordered]@{
        Ready = $true
        Reenroll = $false
        RequestId = ''
        InstallerUri = 'https://cwa.connectwise.com/tools/sentinelone/SentinelOneAgent-Windows_64bit.msi'
    }
    foreach ($property in $inputObject.PSObject.Properties) {
        if ($settings.Contains($property.Name)) { $settings[$property.Name] = $property.Value }
        else { throw 'Unknown resource property.' }
    }
    if ($settings.Reenroll -and [string]::IsNullOrWhiteSpace($settings.RequestId)) { throw 'Reenroll requires a stable, non-secret RequestId.' }
    if (([uri] $settings.InstallerUri).Scheme -ne 'https') { throw 'InstallerUri must use HTTPS.' }
    if ($Operation -eq 'set') { Set-RepairState -Settings $settings }
    Get-RepairState -Settings $settings | ConvertTo-Json -Depth 5 -Compress
} catch {
    # Error messages above contain operation summaries only. Never dump input/native output.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
