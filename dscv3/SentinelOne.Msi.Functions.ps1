#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SentinelOneMsiPackage {
    <# .SYNOPSIS
        Validates an approved, signed local SentinelOne MSI and reads its metadata.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $Path,
        [string] $ExpectedSha256
    )

    $Package = Get-Item -LiteralPath $Path
    if ($Package.PSIsContainer -or $Package.Extension -ne '.msi') {
        throw 'InstallerPath must identify a local MSI file.'
    }
    $Hash = (Get-FileHash -LiteralPath $Package.FullName -Algorithm SHA256).Hash
    if ($ExpectedSha256 -and $Hash -ne $ExpectedSha256) {
        throw 'MSI SHA256 does not match the expected hash.'
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Package.FullName
    if ($Signature.Status -ne 'Valid' -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Subject -notmatch '(?i)\bSentinel(?:One| Labs)\b') {
        throw 'MSI must have a valid SentinelOne/Sentinel Labs Authenticode signature.'
    }

    $Installer = $null
    $Database = $null
    $Metadata = @{}
    try {
        $Installer = New-Object -ComObject WindowsInstaller.Installer
        $Database = $Installer.OpenDatabase($Package.FullName, 0)
        foreach ($PropertyName in @('ProductName', 'ProductVersion', 'Manufacturer')) {
            $View = $null
            $Record = $null
            try {
                $View = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$PropertyName'")
                # COM void methods emit explicit null values into PowerShell's
                # success stream unless captured. Return only the package object.
                $null = $View.Execute()
                $Record = $View.Fetch()
                if ($null -eq $Record) { throw "MSI property $PropertyName is missing." }
                $Metadata[$PropertyName] = $Record.StringData(1)
            }
            finally {
                if ($null -ne $Record) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Record) }
                if ($null -ne $View) {
                    $null = $View.Close()
                    $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($View)
                }
            }
        }
        # MSI ProductVersion and agent file versions use different layouts.
        # Read the actual target executable version instead of guessing a mapping.
        $View = $null
        $Record = $null
        $AgentVersions = @()
        try {
            $View = $Database.OpenView('SELECT `FileName`, `Version` FROM `File`')
            $null = $View.Execute()
            while ($null -ne ($Record = $View.Fetch())) {
                try {
                    if (($Record.StringData(1).Split('|')[-1]) -ieq 'SentinelAgent.exe') {
                        $AgentVersions += $Record.StringData(2)
                    }
                }
                finally {
                    $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Record)
                    $Record = $null
                }
            }
        }
        finally {
            if ($null -ne $View) {
                $null = $View.Close()
                $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($View)
            }
        }
        if ($AgentVersions.Count -ne 1 -or $AgentVersions[0] -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            throw 'MSI must identify exactly one SentinelAgent.exe with a numeric file version.'
        }
    }
    finally {
        if ($null -ne $Database) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Database) }
        if ($null -ne $Installer) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Installer) }
    }
    if ($Metadata.ProductName -notmatch '(?i)Sentinel(?:One| Agent)' -or
        $Metadata.Manufacturer -notmatch '(?i)Sentinel') {
        throw 'MSI metadata does not identify a SentinelOne agent package.'
    }
    [pscustomobject]@{
        Path = $Package.FullName
        Version = ([version] $Metadata.ProductVersion).ToString()
        AgentVersion = ([version] $AgentVersions[0]).ToString()
        Sha256 = $Hash
        ProductName = $Metadata.ProductName
    }
}

function Invoke-SentinelOneStatus {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string] $Path)

    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = $Path
    $ProcessInfo.Arguments = 'status'
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.CreateNoWindow = $true
    $ProcessInfo.RedirectStandardOutput = $true
    $ProcessInfo.RedirectStandardError = $true
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    try {
        $null = $Process.Start()
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(30000)) {
            $Process.Kill()
            throw 'SentinelCtl status timed out.'
        }
        $OutputText = $OutputTask.GetAwaiter().GetResult()
        $null = $ErrorTask.GetAwaiter().GetResult()
        [pscustomobject]@{ ExitCode = $Process.ExitCode; Output = $OutputText }
    }
    finally { $Process.Dispose() }
}

function Get-SentinelOneMsiState {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary] $Properties)

    $State = [ordered]@{}
    foreach ($Key in @('PackagePath', 'PackageVersion', 'PackageSha256', 'LogDirectory', 'ReceiptPath', 'HealthTimeoutSeconds', 'MsiTimeoutSeconds')) {
        if ($Key -eq 'MsiTimeoutSeconds' -and -not $Properties.Contains($Key)) { continue }
        $State[$Key] = $Properties[$Key]
    }
    # Older staged configurations lack the executable version. Recover it from
    # their signed, hash-checked package; never compare across version layouts.
    $State.PackageAgentVersion = if ($Properties.Contains('PackageAgentVersion')) {
        $Properties.PackageAgentVersion
    }
    else {
        (Get-SentinelOneMsiPackage -Path $Properties.PackagePath -ExpectedSha256 $Properties.PackageSha256).AgentVersion
    }
    $State.Healthy = $false
    $State.InstalledVersion = ''
    $State.ServiceState = 'Missing'
    $State.StartMode = 'Unknown'
    $State.AgentLoaded = $false
    $State.SelfProtection = 'Unknown'
    $State.RestartRequired = $false
    $State.InstallerExitCode = $null
    $State.Enrollment = 'NotVerified'
    $State.Outcome = 'NotCompliant'
    $State.LogPath = ''

    if (Test-Path -LiteralPath $Properties.ReceiptPath -PathType Leaf) {
        $Receipt = Get-Content -LiteralPath $Properties.ReceiptPath -Raw | ConvertFrom-Json
        $BootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if ($Receipt.PackageSha256 -eq $Properties.PackageSha256 -and
            $Receipt.BootTime -eq $BootTime -and $Receipt.InstallerExitCode -eq 3010) {
            $State.RestartRequired = $true
            $State.InstallerExitCode = 3010
        }
    }

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='SentinelAgent'"
    if ($null -eq $Service) { return $State }
    $State.ServiceState = $Service.State
    $State.StartMode = $Service.StartMode
    $ServicePath = [Environment]::ExpandEnvironmentVariables($Service.PathName)
    if ($ServicePath -notmatch '^\s*(?:"(?<Executable>[^"]+\.exe)"|(?<Executable>.+?\.exe))(?:\s|$)') {
        return $State
    }
    $AgentExecutable = $Matches.Executable
    if (-not (Test-Path -LiteralPath $AgentExecutable -PathType Leaf)) { return $State }
    # Compare file versions on both sides; MSI ProductVersion is display metadata.
    $VersionInfo = (Get-Item -LiteralPath $AgentExecutable).VersionInfo
    if ($VersionInfo.FileVersion -match '^\d+\.\d+\.\d+\.\d+') {
        $State.InstalledVersion = $Matches[0]
    }
    $CtlPath = Join-Path (Split-Path -Path $AgentExecutable -Parent) 'SentinelCtl.exe'
    if (Test-Path -LiteralPath $CtlPath -PathType Leaf) {
        try {
            $Status = Invoke-SentinelOneStatus -Path $CtlPath
            if ($Status.ExitCode -eq 0) {
                $State.AgentLoaded = $Status.Output -match '(?im)^\s*SentinelAgent is loaded\s*$'
                if ($Status.Output -match '(?im)^\s*Self-Protection status:\s*(On|Off)\s*$') {
                    $State.SelfProtection = $Matches[1]
                }
            }
        }
        catch { Write-Verbose 'SentinelCtl status unavailable; agent health is unverified.' }
    }
    if ($State.InstalledVersion) {
        $State.Healthy = $State.ServiceState -eq 'Running' -and
            $State.StartMode -eq 'Auto' -and $State.AgentLoaded -and
            $State.SelfProtection -eq 'On' -and
            ([version] $State.InstalledVersion -ge [version] $State.PackageAgentVersion)
    }
    if ($State.Healthy) { $State.Outcome = 'HealthyPortalVerificationRequired' }
    if ($State.RestartRequired) { $State.Outcome = 'RebootRequired' }
    return $State
}

function Test-SentinelOneAdministrator {
    [CmdletBinding()]
    param ()
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SentinelOneMsiInstall {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $PackagePath,
        [ValidateRange(30, 7200)][int] $TimeoutSeconds = 900
    )

    # Upgrade only: no SITE_TOKEN (ignored on upgrades), reinstall properties,
    # ACL changes, unprotect, automatic reboot, or secret-bearing verbose MSI log.
    $Process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @(
        '/i', ('"{0}"' -f $PackagePath), '/qn', '/norestart', 'REBOOT=ReallySuppress'
    ) -PassThru -WindowStyle Hidden
    try {
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "MSI timed out (PID $($Process.Id)). It was not terminated. Inspect Windows Installer before retrying."
        }
        return $Process.ExitCode
    }
    finally { $Process.Dispose() }
}

function Set-SentinelOneMsiState {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][System.Collections.IDictionary] $Properties)

    # Share the recovery lock with the existing service/bind resource.
    $Mutex = New-Object Threading.Mutex($false, 'Global\ANS.SentinelOneRepair')
    $Locked = $false
    try {
        try { $Locked = $Mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $Locked = $true }
        if (-not $Locked) { throw 'Another SentinelOne recovery operation is running.' }
        Invoke-SentinelOneMsiUpgrade -Properties $Properties -WhatIf:$WhatIfPreference -Confirm:$false
    }
    finally {
        if ($Locked) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Invoke-SentinelOneMsiUpgrade {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][System.Collections.IDictionary] $Properties)

    if (-not (Test-SentinelOneAdministrator)) {
        throw 'Set requires an elevated administrator or SYSTEM session.'
    }
    $State = Get-SentinelOneMsiState -Properties $Properties
    if ($State.RestartRequired) { return $State }
    if ($State.Healthy) { return $State }
    if ($State.ServiceState -eq 'Missing' -or -not $State.InstalledVersion) {
        throw 'Existing agent/version could not be identified. This resource upgrades existing agents only.'
    }
    if ([version] $State.InstalledVersion -ge [version] $State.PackageAgentVersion) {
        throw 'Agent is unhealthy at the same or a newer version. Supply an approved newer MSI; this resource does not force reinstall or downgrade.'
    }
    if ((Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        throw 'Windows reports a pending restart. Complete the restart before attempting the upgrade.'
    }
    $Package = Get-SentinelOneMsiPackage -Path $Properties.PackagePath -ExpectedSha256 $Properties.PackageSha256
    if ([version] $Package.Version -ne [version] $Properties.PackageVersion) {
        throw 'MSI version differs from the DSC configuration.'
    }
    if ([version] $Package.AgentVersion -ne [version] $State.PackageAgentVersion) {
        throw 'MSI agent file version differs from the DSC configuration.'
    }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Upgrade SentinelOne to $($Package.Version) using the approved MSI")) {
        return $State
    }
    $null = New-Item -Path $Properties.LogDirectory -ItemType Directory -Force
    $StartTime = Get-Date
    $LogPath = Join-Path $Properties.LogDirectory ('SentinelOneMsi_{0}_{1}.log' -f
        $env:COMPUTERNAME, $StartTime.ToString('yyyyMMdd_HHmmss_fff'))
    $Outcome = 'Failed'
    try {
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
            '{0:o} Start; script=SentinelOne.Msi; target={1}; installed={2}; package={3}; sha256={4}' -f
            $StartTime, $env:COMPUTERNAME, $State.InstalledVersion, $Package.Version, $Package.Sha256)
        $TimeoutSeconds = 900
        if ($Properties.Contains('MsiTimeoutSeconds')) { $TimeoutSeconds = $Properties.MsiTimeoutSeconds }
        $InstallerExitCode = Invoke-SentinelOneMsiInstall -PackagePath $Package.Path -TimeoutSeconds $TimeoutSeconds
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value "$(Get-Date -Format o) MSI exit code=$InstallerExitCode"
        if ($InstallerExitCode -notin @(0, 3010)) {
            throw "MSI upgrade failed (exit $InstallerExitCode). Review native vendor logs; no service ACLs were changed."
        }
        $Deadline = (Get-Date).AddSeconds($Properties.HealthTimeoutSeconds)
        do {
            $State = Get-SentinelOneMsiState -Properties $Properties
            if ($State.Healthy -or $InstallerExitCode -eq 3010 -or (Get-Date) -ge $Deadline) { break }
            Start-Sleep -Seconds 2
        } while ($true)
        $State.InstallerExitCode = $InstallerExitCode
        $State.LogPath = $LogPath
        if ($InstallerExitCode -eq 3010) {
            $State.RestartRequired = $true
            $BootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            $null = New-Item -Path (Split-Path -Path $Properties.ReceiptPath -Parent) -ItemType Directory -Force
            @{PackageSha256 = $Package.Sha256; BootTime = $BootTime; InstallerExitCode = 3010} |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $Properties.ReceiptPath -Encoding UTF8
            $Outcome = 'RebootRequired'
        }
        elseif (-not $State.Healthy) {
            throw 'MSI returned success but the target version, Automatic/Running service, loaded agent, and self-protection On were not all confirmed. Provider-assisted recovery is required.'
        }
        else { $Outcome = 'HealthyPortalVerificationRequired' }
        $State.Outcome = $Outcome
        return $State
    }
    finally {
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
            '{0:o} End; outcome={1}; changed=MSIUpgradeAttempted; unchanged=ServiceACL; skipped=Reenrollment,AutomaticReboot; failed={2}' -f
            (Get-Date), $Outcome, ($Outcome -eq 'Failed'))
    }
}
