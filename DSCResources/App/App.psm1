#Requires -Version 5.1

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';
$ConfirmPreference = 'None';
$ProgressPreference = 'SilentlyContinue';

Enum Ensure {
    Absent
    Present
};

Enum LogLevel {
    None     = 0
    Minimal  = 8
    Moderate = 64
    All      = 256
};

Function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    Param(
        [Parameter(Mandatory = $False)]
        [ValidateSet('Present', 'Absent')]
        [String] $Ensure = 'Present',

        [Parameter(Mandatory = $True)]
        [String] $Name,

        [Parameter(Mandatory = $True)]
        [AllowEmptyString()]
        [String] $InstallerPath,

        [Parameter(Mandatory = $False)]
        [String] $ProductId,

        [Parameter(Mandatory = $False)]
        [String] $Version,

        [Parameter(Mandatory = $False)]
        [String] $InstalledCheckFilePath,

        [Parameter(Mandatory = $False)]
        [LogLevel] $LogLevel = [LogLevel]::All
    );

    $global:GlobalLogLevel = $LogLevel;

    $InstalledVersion  = $Null
    $UninstallString   = $Null
    $Publisher         = $Null
    $DetectedProductId = $Null
    $DisplayName       = $Name;

    If ($InstalledCheckFilePath) {
        Write-MyVerbose -Message ('Checking install via file: [{0}]' -f $InstalledCheckFilePath) -LogLevel Minimal
        $FileInfo = Get-ExecutableInfo -Path $InstalledCheckFilePath
        If ($FileInfo -and $FileInfo.ProductVersion) {
            $InstalledVersion = $FileInfo.ProductVersion
            Write-MyVerbose -Message ('File present, version: [{0}]' -f $InstalledVersion) -LogLevel Moderate
            $RegistryEntry = If ($ProductId) {
                Get-InstalledProgram -ProductId $ProductId
            } Else {
                Get-InstalledProgram -Name $Name
            }
            If ($RegistryEntry) {
                $UninstallString   = $RegistryEntry.UninstallString
                $Publisher         = $RegistryEntry.Publisher
                $DetectedProductId = $RegistryEntry.PSChildName
                $DisplayName       = $RegistryEntry.DisplayName
            }
        } Else {
            Write-MyVerbose -Message ('[{0}] not found - [{1}] is not installed' -f (Split-Path $InstalledCheckFilePath -Leaf), $Name) -LogLevel Moderate
        }
    } ElseIf ($ProductId) {
        $Program = Get-InstalledProgram -ProductId $ProductId
        If ($Program) {
            $InstalledVersion  = $Program.DisplayVersion
            $DisplayName       = $Program.DisplayName
            $UninstallString   = $Program.UninstallString
            $Publisher         = $Program.Publisher
            $DetectedProductId = $Program.PSChildName
        }
    } Else {
        $Program = Get-InstalledProgram -Name $Name
        If ($Program) {
            $InstalledVersion  = $Program.DisplayVersion
            $DisplayName       = $Program.DisplayName
            $UninstallString   = $Program.UninstallString
            $Publisher         = $Program.Publisher
            $DetectedProductId = $Program.PSChildName
        };
    };

    If (-not $InstalledVersion) {
        Write-MyVerbose -Message ('[{0}] is not installed' -f $Name) -LogLevel Minimal
        Return @{
            Ensure        = [Ensure]::Absent
            Name          = ''
            InstallerPath = $InstallerPath
            Installed     = $False
        }
    }

    Write-MyVerbose -Message ('[{0}] is installed | Version: [{1}]' -f $DisplayName, $InstalledVersion) -LogLevel Minimal

    If (-not $UninstallString -and $DetectedProductId) {
        $UninstallString = 'MsiExec.exe /X{0}' -f $DetectedProductId
        $KeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}' -f $DetectedProductId
        If (Test-Path $KeyPath) {
            Set-ItemProperty -Path $KeyPath -Name UninstallString -Value $UninstallString -Force -ErrorAction SilentlyContinue
            Write-MyVerbose -Message ('Wrote missing UninstallString to registry') -LogLevel Minimal
        }
    }

    Return @{
        Ensure          = 'Present'
        Name            = $DisplayName
        ProductId       = $DetectedProductId
        Version         = $InstalledVersion
        Publisher       = $Publisher
        InstallerPath   = $InstallerPath
        UninstallString = If ($UninstallString) { $UninstallString.Replace('"', '') } Else { '' }
        Installed       = $True
    }
};


Function Test-TargetResource {
    [CmdletBinding()]
    [OutputType([Bool])]
    Param(
        [Parameter(Mandatory = $False)]
        [ValidateSet('Present', 'Absent')]
        [String] $Ensure = 'Present',

        [Parameter(Mandatory = $True)]
        [String] $Name,

        [Parameter(Mandatory = $True)]
        [AllowEmptyString()]
        [String] $InstallerPath,

        [String] $ProductId,
        [String] $InstalledCheckFilePath,
        [String] $InstalledCheckScript,
        [Bool]   $NoRestart = $False,
        [String] $Version,
        [Bool]   $ForceVersion = $False,
        [Bool]   $PatchOnly = $False,
        [Bool]   $UseSemVer = $False,
        [String] $Arguments,
        [String] $ArgumentsForUninstall,
        [String] $WorkingDirectory,
        [Bool]   $UseUninstallString = $False,

        [PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [ValidateNotNullOrEmpty()]
        [UInt32[]] $ReturnCode = @(0, 1641, 3010),

        [UInt32]
        [ValidateRange(0, 2147483)]
        $ProcessTimeout = 2147483,

        [UInt32]
        [ValidateRange(0, 2147483647)]
        $DownloadTimeout = 900,

        [String] $FileHash,

        [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5', 'RIPEMD160')]
        [String] $HashAlgorithm = 'SHA256',

        [String] $PreAction,
        [String] $PostAction,
        [String] $PreCopyFrom,
        [String] $PreCopyTo,

        [LogLevel] $LogLevel = [LogLevel]::All
    )

    $global:GlobalLogLevel = $LogLevel;

    If ($InstalledCheckScript) {
        Write-MyVerbose -Message ('Evaluating state via InstalledCheckScript') -LogLevel Minimal
        $ScriptBlock  = [ScriptBlock]::Create($InstalledCheckScript)
        $ScriptResult = [Bool]($ScriptBlock.Invoke())
        Write-MyVerbose -Message ('Script result: [{0}]' -f $ScriptResult) -LogLevel Minimal
        Return $ScriptResult
    }

    $GetParam = @{
        Ensure                 = $Ensure
        Name                   = $Name
        InstallerPath          = $InstallerPath
        ProductId              = $ProductId
        InstalledCheckFilePath = $InstalledCheckFilePath
        LogLevel               = $LogLevel
        Version                = $Version
    }

    $ProgramInfo = Get-TargetResource @GetParam -ErrorAction Stop

    If ($Ensure -eq 'Absent') {
        $IsAbsent = $ProgramInfo.Ensure -eq 'Absent'
        Write-MyVerbose -Message ('Desired: Absent | Current: [{0}] | Compliant: [{1}]' -f $ProgramInfo.Ensure, $IsAbsent) -LogLevel Minimal
        Return $IsAbsent
    }

    If ($ProgramInfo.Ensure -eq 'Absent') {
        If ($PatchOnly) {
            Write-Warning -Message '[PatchOnly] Application not present on this machine - skipping.'
            Return $True
        }
        Write-MyVerbose -Message ('[{0}] is not installed - desired state: Present' -f $Name) -LogLevel Minimal
        Return $False
    }

    If ($Version) {
        If ($UseSemVer) {
            $SemVer = $Null
            If (-not [pspm.SemVer]::TryParse($ProgramInfo.Version, [ref]$SemVer)) {
                Write-Error -Message 'The installed version does not follow Semantic Versioning.'
                Return $False
            }
            Try {
                $Range = [pspm.SemVerRange]::new($Version)
                If (-not $Range.IsSatisfied($SemVer)) {
                    Write-MyVerbose -Message ('[{0}] version [{1}] does not satisfy range [{2}]' -f $Name, $ProgramInfo.Version, $Version) -LogLevel Moderate
                    Write-MyVerbose -Message ('Current state does not match the desired state') -LogLevel Minimal
                    Return $False
                }
            } Catch {
                Write-Error -Exception $_.Exception
                Return $False
            }
        } Else {
            If (-not (Test-VersionsEqual -Version1 $ProgramInfo.Version -Version2 $Version)) {
                Write-MyVerbose -Message ('[{0}] installed: [{1}] | desired: [{2}] - mismatch' -f $Name, $ProgramInfo.Version, $Version) -LogLevel Moderate
                Write-MyVerbose -Message ('[{0}] is not in the desired state' -f $Name) -LogLevel Minimal
                Return $False
            }
        }
    }

    Write-MyVerbose -Message ('[{0}] is in the desired state' -f $Name) -LogLevel Minimal
    Return $True
};


Function Set-TargetResource {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $False)]
        [ValidateSet('Present', 'Absent')]
        [String] $Ensure = 'Present',

        [Parameter(Mandatory = $True)]
        [String] $Name,

        [Parameter(Mandatory = $True)]
        [AllowEmptyString()]
        [String] $InstallerPath,

        [String] $ProductId,
        [String] $InstalledCheckFilePath,
        [String] $InstalledCheckScript,
        [Bool]   $NoRestart = $False,
        [Bool]   $PatchOnly = $False,
        [Bool]   $ForceVersion = $False,
        [String] $Version,
        [Bool]   $UseSemVer = $False,
        [String] $Arguments,
        [String] $ArgumentsForUninstall,
        [String] $WorkingDirectory,
        [Bool]   $UseUninstallString = $False,

        [PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [ValidateNotNullOrEmpty()]
        [UInt32[]] $ReturnCode = @(0, 1641, 3010),

        [UInt32]
        [ValidateRange(0, 2147483)]
        $ProcessTimeout = 2147483,

        [UInt32]
        [ValidateRange(0, 2147483647)]
        $DownloadTimeout = 900,

        [String] $FileHash,

        [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5', 'RIPEMD160')]
        [String] $HashAlgorithm = 'SHA256',

        [String] $PreAction,
        [String] $PostAction,
        [String] $PreCopyFrom,
        [String] $PreCopyTo,

        [LogLevel] $LogLevel = [LogLevel]::All
    )

    $global:GlobalLogLevel = $LogLevel;

    If (($Ensure -eq 'Absent') -and (-not $UseUninstallString) -and (-not $InstallerPath)) {
        Write-Error -Message 'InstallerPath is required when Ensure=Absent and UseUninstallString=False.'
        Return
    }
    If (($Ensure -eq 'Present') -and (-not $InstallerPath)) {
        Write-Error -Message 'InstallerPath is required when Ensure=Present.'
        Return
    }

    If ($PreCopyFrom -and [String]::IsNullOrWhiteSpace($PreCopyTo)) {
        Write-Warning -Message 'PreCopyFrom specified but PreCopyTo is empty.'
    } ElseIf ([String]::IsNullOrWhiteSpace($PreCopyFrom) -and $PreCopyTo) {
        Write-Warning -Message 'PreCopyTo specified but PreCopyFrom is empty.'
    } ElseIf ($PreCopyFrom -and $PreCopyTo) {
        Write-MyVerbose -Message ('PreCopy: [{0}] -> [{1}]' -f $PreCopyFrom, $PreCopyTo) -LogLevel All
        Get-RemoteFile -Path $PreCopyFrom -DestinationFolder $PreCopyTo -Credential $Credential -TimeoutSec $DownloadTimeout -Force -ErrorAction Stop > $Null
    }

    Try {
        Invoke-ScriptBlock -ScriptBlockString $PreAction;
    }
    Catch {
        Write-Error -Exception $_.Exception;
    };

    $TempFolder        = $env:TEMP;
    $Installer         = '';
    $Action            = '';
    $MsiOption         = '';
    $Arg               = New-Object 'System.Collections.Generic.List[System.String]';
    $TempDriveName     = [Guid]::NewGuid();
    $TempInstallerFile = $Null;

    Try {
        If ($Ensure -eq 'Absent') {
            Write-MyVerbose -Message ('Ensure=Absent: uninstalling [{0}]' -f $Name) -LogLevel Minimal
            $Action = 'Uninstall';
            $MsiOption = 'x';
            $Arguments = $ArgumentsForUninstall;

            If ($UseUninstallString) {
                $GetParam = @{
                    Ensure        = $Ensure
                    Name          = $Name
                    InstallerPath = $InstallerPath
                    ProductId     = $ProductId
                }
                $ProgramInfo = Get-TargetResource @GetParam -ErrorAction Stop
                If (-not $ProgramInfo.UninstallString) {
                    Throw 'Could not retrieve UninstallString from the installed application.'
                }
                Write-MyVerbose -Message ('Using UninstallString: [{0}]' -f $ProgramInfo.UninstallString) -LogLevel Moderate
                If ($ProgramInfo.UninstallString -match '^(?<path>.+\.[a-z]{3})(?<args>.*)') {
                    $Installer = $Matches.path
                    $Arg.Add($Matches.args)
                } Else {
                    Throw 'Could not parse UninstallString.'
                }
            }
        } Else {
            Write-MyVerbose -Message ('Ensure=Present: installing [{0}]' -f $Name) -LogLevel Minimal
            $Action = 'Install';
            $MsiOption = 'i';
        }

        If (-not (($Ensure -eq 'Absent') -and $UseUninstallString)) {
            Write-MyVerbose -Message ('Installer path: [{0}]' -f $InstallerPath) -LogLevel All

            If ($InstallerPath -match '^msiexec[.exe]?') {
                $InstallerPath = Join-Path $env:windir 'system32\msiexec.exe';
            }

            $TempUri = [System.Uri]$InstallerPath

            If ($TempUri.IsLoopback -and (-not $TempUri.IsUnc)) {
                If ([String]::IsNullOrWhiteSpace($WorkingDirectory)) {
                    $Installer = $TempUri.LocalPath
                } Else {
                    If ($PSBoundParameters.ContainsKey('Credential')) {
                        New-PSDrive -Name $TempDriveName -PSProvider FileSystem -Root (Split-Path $TempUri.LocalPath) -Credential $Credential -ErrorAction Stop > $Null
                    }
                    $Installer = (Get-RemoteFile -Path $InstallerPath -DestinationFolder $WorkingDirectory -Force -PassThru -ErrorAction Stop).FullName
                }
            } ElseIf ($TempUri.IsUnc) {
                $CopyDest = If ([String]::IsNullOrWhiteSpace($WorkingDirectory)) { $TempFolder } Else { $WorkingDirectory }
                If ($PSBoundParameters.ContainsKey('Credential')) {
                    New-PSDrive -Name $TempDriveName -PSProvider FileSystem -Root (Split-Path $TempUri.LocalPath) -Credential $Credential -ErrorAction Stop > $Null
                }
                $Installer = (Get-RemoteFile -Path $InstallerPath -DestinationFolder $CopyDest -Force -PassThru -ErrorAction Stop).FullName
                If ($CopyDest -eq $TempFolder) { $TempInstallerFile = $Installer }
            } ElseIf ($TempUri.Scheme -eq 'http' -or $TempUri.Scheme -eq 'https') {
                $DownloadDest = If ([String]::IsNullOrWhiteSpace($WorkingDirectory)) { $TempFolder } Else { $WorkingDirectory }
                $Installer = (Get-RemoteFile -Path $InstallerPath -DestinationFolder $DownloadDest -Credential $Credential -TimeoutSec $DownloadTimeout -Force -PassThru -ErrorAction Stop).FullName
                $TempInstallerFile = $Installer
            } Else {
                Throw ('Unsupported installer path scheme: [{0}]. Use a local path, UNC path, or HTTP/HTTPS URL.' -f $InstallerPath)
            }

            If ($FileHash) {
                If (-not (Assert-FileHash -Path $Installer -FileHash $FileHash -Algorithm $HashAlgorithm)) {
                    Throw ('Hash mismatch for [{0}] - aborting installation.' -f $Installer)
                }
                Write-MyVerbose -Message ('Hash verified successfully') -LogLevel Moderate
            }
        }

        $Arg.Add($Arguments)

        If (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
            Throw ('Installer not found: [{0}]' -f $Installer)
        }

        $Extension = [System.IO.Path]::GetExtension($Installer).ToLower()
        If ($Extension -eq '.msi') {
            $Arg.Insert(0, ('/{0} "{1}"' -f $MsiOption, $Installer))
            $Installer = 'msiexec.exe'
        } ElseIf ($Extension -eq '.msp') {
            $Arg.Insert(0, ('/p "{0}"' -f $Installer))
            $Installer = 'msiexec.exe'
        }

        $CommandParam = @{
            FilePath     = $Installer
            ArgumentList = $Arg
            Timeout      = $ProcessTimeout * 1000
        }
        If ($WorkingDirectory) {
            $CommandParam.WorkingDirectory = $WorkingDirectory
            Write-MyVerbose -Message ('{0}: [{1}] args=[{2}] workdir=[{3}]' -f $Action, $Installer, ($Arg -join ' '), $WorkingDirectory) -LogLevel All
        } Else {
            Write-MyVerbose -Message ('{0}: [{1}] args=[{2}]' -f $Action, $Installer, ($Arg -join ' ')) -LogLevel All
        }

        $ExitCode = Start-Command @CommandParam -ErrorAction Stop
        Write-MyVerbose -Message ('{0} finished. ExitCode: [{1}]' -f $Action, $ExitCode) -LogLevel Moderate

        If ($ExitCode -eq 1603) {
            Write-Warning -Message 'Exit code 1603 - cleaning installer artifacts and retrying...'
            Remove-Artifacts -AppName $Name
            $ExitCode = Start-Command @CommandParam -ErrorAction Stop
            Write-MyVerbose -Message ('Retry ExitCode: [{0}]' -f $ExitCode) -LogLevel Moderate
        }

        If (-not ($ReturnCode -contains $ExitCode)) {
            Throw ('Unexpected exit code [{0}] - installation may have failed.' -f $ExitCode)
        }

        Write-MyVerbose -Message ('{0} completed successfully.' -f $Action) -LogLevel Minimal

        If ($ForceVersion -and $Version) {
            $InstalledProgram = If ($ProductId) {
                Get-InstalledProgram -ProductId $ProductId
            } Else {
                Get-InstalledProgram -Name $Name
            }
            If ($InstalledProgram -and $InstalledProgram.PSPath) {
                Write-MyVerbose -Message ('ForceVersion: writing DisplayVersion [{0}] to registry.' -f $Version) -LogLevel Minimal
                Set-ItemProperty -Path $InstalledProgram.PSPath -Name DisplayVersion -Value $Version -Force
            } Else {
                Write-Warning -Message ('ForceVersion: could not locate registry entry for [{0}] - version not forced.' -f $Name)
            }
        }

        If (-not $NoRestart) {
            $ServerFeatureData = Invoke-CimMethod -Name 'GetServerFeature' -Namespace 'root\microsoft\windows\servermanager' -Class 'MSFT_ServerManagerTasks' -Arguments @{ BatchSize = 256 } -ErrorAction Ignore -Verbose:$False
            $RegistryData      = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Ignore
            If (($ServerFeatureData -and $ServerFeatureData.RequiresReboot) -or $RegistryData -or ($ExitCode -eq 3010) -or ($ExitCode -eq 1641)) {
                Write-MyVerbose -Message 'Reboot required.' -LogLevel Minimal
                $global:DSCMachineStatus = 1;
            }
        }
    }
    Catch {
        Write-Error -Exception $_.Exception
    }
    Finally {
        If ($PreCopyTo -and (Test-Path $PreCopyTo -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $PreCopyTo -Force -Recurse > $Null
        }
        If ($TempInstallerFile -and (Test-Path $TempInstallerFile -PathType Leaf -ErrorAction SilentlyContinue)) {
            Write-MyVerbose -Message ('Removing temp installer: [{0}]' -f $TempInstallerFile) -LogLevel Moderate
            Remove-Item -LiteralPath $TempInstallerFile -Force > $Null
        }
        If (Get-PSDrive | Where-Object { $_.Name -eq $TempDriveName }) {
            Remove-PSDrive -Name $TempDriveName -Force -ErrorAction SilentlyContinue
        }
    }

    Try {
        Invoke-ScriptBlock -ScriptBlockString $PostAction;
    }
    Catch {
        Write-Error -Exception $_.Exception;
    };
};


Function Test-VersionsEqual {
    [CmdletBinding()]
    [OutputType([Bool])]
    Param(
        [Parameter(Mandatory = $True)]
        [String] $Version1,
        [Parameter(Mandatory = $True)]
        [String] $Version2
    )
    Try {
        $SemanticVersion1 = Get-SemanticVersion -Version $Version1
        $SemanticVersion2 = Get-SemanticVersion -Version $Version2
        Return ($SemanticVersion1.Major -eq $SemanticVersion2.Major -and
                $SemanticVersion1.Minor -eq $SemanticVersion2.Minor -and
                $SemanticVersion1.Patch -eq $SemanticVersion2.Patch -and
                $SemanticVersion1.Build -eq $SemanticVersion2.Build)
    } Catch {
        Return $Version1 -eq $Version2
    }
};


Function Get-SemanticVersion {
    [CmdletBinding()]
    Param(
        [String] $Version,
        [UInt64] $Major = [UInt64]::MinValue,
        [UInt64] $Minor = [UInt64]::MinValue,
        [UInt64] $Patch = [UInt64]::MinValue,
        [UInt64] $Build = [UInt64]::MinValue
    )

    If (-Not ([System.Management.Automation.PSTypeName]'SemanticVersion.Version').Type) {
        Add-Type -TypeDefinition @'
using System;
namespace SemanticVersion {
    public class Version {
        public UInt64 Major { get; set; }
        public UInt64 Minor { get; set; }
        public UInt64 Patch { get; set; }
        public UInt64 Build { get; set; }
        public String DisplayVersion { get; set; }
        public Version(UInt64 major, UInt64 minor, UInt64 patch, UInt64 build, string displayversion) {
            this.Major = major;
            this.Minor = minor;
            this.Patch = patch;
            this.Build = build;
            this.DisplayVersion = displayversion;
        }
    }
}
'@
    }

    If ($Null -ne $Version) {
        $Split  = $Version.Split('.')
        [UInt64]$Major = If ($Split.Count -gt 0 -and $Split[0]) { [UInt64]$Split[0] } Else { 0 }
        [UInt64]$Minor = If ($Split.Count -gt 1 -and $Split[1]) { [UInt64]$Split[1] } Else { 0 }
        [UInt64]$Patch = If ($Split.Count -gt 2 -and $Split[2]) { [UInt64]$Split[2] } Else { 0 }
        [UInt64]$Build = If ($Split.Count -gt 3 -and $Split[3]) { [UInt64]$Split[3] } Else { 0 }
    }

    $Obj = [SemanticVersion.Version]::New($Major, $Minor, $Patch, $Build, $Version)

    $Obj | Add-Member -MemberType ScriptMethod -Name ToString -Value {
        $Sb = '{0}.{1}.{2}' -f $This.Major, $This.Minor, $This.Patch
        If ($This.Build -gt 0) { $Sb = '{0}+{1}' -f $Sb, $This.Build }
        Return $Sb
    } -Force

    $Obj | Add-Member -MemberType ScriptMethod -Name Parse -Value {
        Param([String]$SemVer)
        Try {
            $ErrorActionPreference = 'Stop'
            $Null = $SemVer -match '^(?<major>\d+)(\.(?<minor>\d+))?(\.(?<patch>\d+))?(\-(?<pre>[0-9A-Za-z\-\.]+))?(\+(?<build>\d+))?$'
            $This.Build = [UInt64]$Matches['build']
            $This.Patch = [UInt64]$Matches['patch']
            $This.Minor = [UInt64]$Matches['minor']
            $This.Major = [UInt64]$Matches['major']
            Return $True
        } Catch {
            Return $False
        }
    } -Force

    $Obj | Add-Member -MemberType ScriptMethod -Name FromSystemVersion -Value {
        Param([Version]$SystemVersion)
        $This.Major = $SystemVersion.Major
        $This.Minor = $SystemVersion.Minor
        $This.Patch = $SystemVersion.Build
        $This.Build = $SystemVersion.Revision
        Return $This
    } -Force

    $Obj | Add-Member -MemberType ScriptMethod -Name ToSystemVersion -Value {
        $SemVer = $This
        Return [Version]::New($This.Major, $This.Minor, $This.Patch, $This.Build) |
            Add-Member -MemberType NoteProperty -Name 'SemVer' -Value $SemVer -Force -PassThru
    } -Force -PassThru
};


Function Get-RemoteFile {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [Alias('Uri', 'SourcePath')]
        [System.Uri[]] $Path,

        [Parameter(Mandatory = $True, Position = 1)]
        [String] $DestinationFolder,

        [Parameter()]
        [AllowNull()]
        [PSCredential] $Credential,

        [Parameter()]
        [Int] $TimeoutSec = 0,

        [Parameter()]
        [Switch] $Force,

        [Parameter()]
        [Switch] $PassThru
    )

    Begin {
        If (-not (Test-Path $DestinationFolder -PathType Container)) {
            Write-MyVerbose -Message ('Creating destination folder: [{0}]' -f $DestinationFolder) -LogLevel All
            New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop > $Null
        }
    }

    Process {
        ForEach ($TempPath in $Path) {
            Try {
                $OutFile      = ''
                $Valid        = $True
                $TempDriveName = [Guid]::NewGuid()

                If ($Null -eq $TempPath.IsLoopback) {
                    $Valid = $False
                    Throw ('{0} is not a valid URI.' -f $TempPath)
                }

                If ($TempPath.IsLoopback -and (-not $TempPath.IsUnc)) {
                    Write-MyVerbose -Message ('Local file: [{0}]' -f $TempPath.LocalPath) -LogLevel All
                    $Valid   = $True
                    $OutFile = Join-Path $DestinationFolder ([System.IO.Path]::GetFileName($TempPath.LocalPath))
                    If ($TempPath.LocalPath -ne $OutFile) {
                        Copy-Item -Path $TempPath.LocalPath -Destination $DestinationFolder -ErrorAction Stop -Force:$Force -Recurse > $Null
                    }
                } ElseIf ($TempPath.IsUnc) {
                    If ($PSBoundParameters.ContainsKey('Credential')) {
                        New-PSDrive -Name $TempDriveName -PSProvider FileSystem -Root (Split-Path $TempPath.LocalPath) -Credential $Credential -ErrorAction Stop > $Null
                    }
                    $OutFile = Join-Path $DestinationFolder ([System.IO.Path]::GetFileName($TempPath.LocalPath))
                    If ((Test-Path -LiteralPath $OutFile -PathType Leaf) -and ($TempPath.LocalPath -eq $OutFile)) {
                        If ($PassThru -and (Test-Path -LiteralPath $OutFile)) { Get-Item -LiteralPath $OutFile }
                        continue
                    }
                    If ((Test-Path -LiteralPath $OutFile -PathType Leaf) -and (-not $Force)) {
                        $Valid = $False
                        Throw ("'{0}' already exists. Use -Force to overwrite." -f $OutFile)
                    }
                    Write-MyVerbose -Message ('UNC copy: [{0}] -> [{1}]' -f $TempPath.LocalPath, $DestinationFolder) -LogLevel All
                    Copy-Item -Path $TempPath.LocalPath -Destination $DestinationFolder -ErrorAction Stop -Force:$Force -Recurse > $Null
                } ElseIf ($TempPath.Scheme -eq 'http' -or $TempPath.Scheme -eq 'https') {
                    $Valid    = $True
                    $FileName = [System.IO.Path]::GetFileName($TempPath.LocalPath)
                    If ([String]::IsNullOrWhiteSpace($FileName)) {
                        $FileName = $TempPath.Segments[-1].TrimEnd('/')
                    }
                    $OutFile = Join-Path $DestinationFolder $FileName

                    If ((Test-Path -LiteralPath $OutFile -PathType Leaf) -and (-not $Force)) {
                        $Valid = $False
                        Throw ("'{0}' already exists. Use -Force to overwrite." -f $OutFile)
                    }

                    Write-MyVerbose -Message ('Downloading [{0}] to [{1}]' -f $TempPath.AbsoluteUri, $OutFile) -LogLevel Moderate

                    $BitsAvailable = $Null -ne (Get-Command -Name 'Start-BitsTransfer' -CommandType Cmdlet -ErrorAction SilentlyContinue)

                    If ($BitsAvailable) {
                        $BitsTransferParams = @{
                            Source      = $TempPath.AbsoluteUri
                            Destination = $OutFile
                            ErrorAction = 'Stop'
                        }
                        If ($PSBoundParameters.ContainsKey('Credential') -and $Credential) {
                            $BitsTransferParams.Credential = $Credential
                        }
                        Start-BitsTransfer @BitsTransferParams
                    } Else {
                        $InvokeWebRequestParams = @{
                            Uri             = $TempPath.AbsoluteUri
                            OutFile         = $OutFile
                            UseBasicParsing = $True
                            ErrorAction     = 'Stop'
                        }
                        If ($PSBoundParameters.ContainsKey('Credential') -and $Credential) {
                            $InvokeWebRequestParams.Credential = $Credential
                        }
                        If ($TimeoutSec -gt 0) {
                            $InvokeWebRequestParams.TimeoutSec = $TimeoutSec;
                        };
                        Invoke-WebRequest @InvokeWebRequestParams;
                    }
                } Else {
                    $Valid = $False
                    Throw ('[{0}] uses an unsupported scheme. Provide a local path, UNC path, or HTTP/HTTPS URL.' -f $TempPath)
                }

                If ($Valid -and $OutFile -and $PassThru) {
                    If (Test-Path -LiteralPath $OutFile) {
                        Get-Item -LiteralPath $OutFile;
                    };
                }
            }
            Catch {
                Write-Error -Exception $_.Exception;
            }
            Finally {
                If (Get-PSDrive | Where-Object { $_.Name -eq $TempDriveName }) {
                    Remove-PSDrive -Name $TempDriveName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
};


Function Assert-FileHash {
    [CmdletBinding()]
    [OutputType([Bool])]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [String] $Path,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String] $FileHash,

        [Parameter()]
        [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5', 'RIPEMD160')]
        [String] $Algorithm = 'SHA256'
    )

    Process {
        $Hash = Get-FileHash -Path $Path -Algorithm $Algorithm | Select-Object -ExpandProperty Hash
        If ($FileHash -eq $Hash) {
            Write-MyVerbose -Message ('Hash match for [{0}]: {1}' -f $Path, $Hash) -LogLevel All
            Return $True
        } Else {
            Write-MyVerbose -Message ('Hash mismatch for [{0}]: expected [{1}], got [{2}]' -f $Path, $FileHash, $Hash) -LogLevel All
            Return $False
        }
    }
};


Function Get-InstalledProgram {
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    Param(
        [Parameter(Mandatory = $True, ParameterSetName = 'Name')]
        [String] $Name,

        [Parameter(Mandatory = $True, ParameterSetName = 'Id')]
        [String] $ProductId,

        [Switch] $Wow64,
        [Bool] $FallbackToWow64 = $True
    )

    Switch ($Wow64) {
        $True {
            $UninstallRegMachine = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            $UninstallRegUser    = 'HKCU:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        }
        $False {
            $UninstallRegMachine = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $UninstallRegUser    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        }
    }

    $InstalledPrograms = @()
    $InstalledPrograms += Get-ChildItem -LiteralPath $UninstallRegMachine |
        ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName }
    If (Test-Path $UninstallRegUser) {
        $InstalledPrograms += Get-ChildItem -LiteralPath $UninstallRegUser |
            ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName }
    }

    $Program = $Null
    Switch ($PsCmdlet.ParameterSetName) {
        'Name' {
            $Program = $InstalledPrograms | Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
        }
        'Id' {
            $ProductId = Format-ProductId -ProductId $ProductId
            $Program   = $InstalledPrograms | Where-Object { $_.PSChildName -eq $ProductId } | Select-Object -First 1
        }
    }

    If ($Program) {
        $Program
    } ElseIf ((-not $Wow64) -and $FallbackToWow64 -and (Test-Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-InstalledProgram @PSBoundParameters -Wow64
    }
};


Function Format-ProductId {
    [CmdletBinding()]
    [OutputType([String])]
    Param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [String] $ProductId
    )
    Try {
        Return '{{{0}}}' -f [Guid]::Parse($ProductId).ToString().ToUpper()
    } Catch {
        Write-Error -Message ('The specified ProductId [{0}] is not a valid GUID.' -f $ProductId)
    }
};


Function Get-ExecutableInfo {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [String] $Path
    )
    If (Test-Path -Path $Path) {
        Return (Get-Item -Path $Path).VersionInfo
    }
    Return $Null
};


Function Remove-Artifacts {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [String] $AppName
    )
    Try {
        $Keys = Get-ChildItem HKCR:Installer -Recurse -ErrorAction Stop |
            Get-ItemProperty -Name ProductName -ErrorAction SilentlyContinue
    } Catch {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
        $Keys = Get-ChildItem HKCR:Installer -Recurse |
            Get-ItemProperty -Name ProductName -ErrorAction SilentlyContinue
    } Finally {
        Write-MyVerbose -Message ('Removing installer artifacts for [{0}]' -f $AppName) -LogLevel Moderate
        ForEach ($Key in $Keys) {
            If ($Key.ProductName -like "*$AppName*") {
                Remove-Item $Key.PSPath -Force -Recurse
            }
        }
        Write-MyVerbose -Message ('Artifact removal complete for [{0}]' -f $AppName) -LogLevel Moderate
    }
};


Function Invoke-ScriptBlock {
    [CmdletBinding()]
    Param(
        [Parameter()] [AllowEmptyString()] [String]   $ScriptBlockString,
        [Parameter()] [AllowEmptyCollection()] [String[]] $Arguments
    )
    If (-not $ScriptBlockString) { Return }
    Try {
        $ScriptBlock = [ScriptBlock]::Create($ScriptBlockString).GetNewClosure()
        Write-MyVerbose -Message ('Executing ScriptBlock') -LogLevel Moderate
        If (@($Arguments).Count -ge 1) {
            $ScriptBlock.Invoke($Arguments) | Out-String -Stream | Write-MyVerbose -LogLevel All
        } Else {
            $ScriptBlock.Invoke() | Out-String -Stream | Write-MyVerbose -LogLevel All
        }
    } Catch {
        Throw $_
    }
};


Function Start-Command {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)] [String]   $FilePath,
        [Parameter(Position = 1)] [String[]] $ArgumentList,
        [Parameter()]             [String]   $WorkingDirectory,
        [Parameter()]             [Int]      $Timeout = [Int]::MaxValue
    )
    $ProcessInfo              = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName     = $FilePath
    $ProcessInfo.UseShellExecute = $False
    $ProcessInfo.Arguments    = [String]$ArgumentList
    If ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        If (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            Write-Warning -Message ('Working directory does not exist: [{0}]' -f $WorkingDirectory)
        } Else {
            $ProcessInfo.WorkingDirectory = $WorkingDirectory
        }
    }
    $Process           = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    $Process.Start()   > $Null
    If (-not $Process.WaitForExit($Timeout)) {
        $Process.Kill()
        Write-Warning -Message ('Process timed out after [{0}s] and was terminated: [{1}]' -f ($Timeout * 0.001), $FilePath)
        Return 1460
    }
    Return $Process.ExitCode
};


Function Write-MyVerbose {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0, Mandatory = $True, ValueFromPipeline = $True)]
        [Alias('Msg')]
        [AllowEmptyString()]
        [String] $Message,

        [Parameter()]
        [LogLevel] $LogLevel = [LogLevel]::All
    )

    Begin {
        $ShouldInvoke = ($Null -eq $global:GlobalLogLevel) -or ($LogLevel -le $global:GlobalLogLevel);
        If ($ShouldInvoke) {
            $WriteVerboseParams = [System.Collections.Generic.Dictionary[[String],[Object]]]::new($PSBoundParameters)
            $Null = $WriteVerboseParams.Remove('LogLevel')
            $WrappedCommand       = $ExecutionContext.InvokeCommand.GetCommand('Write-Verbose', [System.Management.Automation.CommandTypes]::Cmdlet)
            $ScriptCommand        = { & $WrappedCommand @WriteVerboseParams }
            $SteppablePipeline = $ScriptCommand.GetSteppablePipeline($MyInvocation.CommandOrigin)
            $SteppablePipeline.Begin($PSCmdlet)
        }
    }
    Process {
        If ($ShouldInvoke) { $SteppablePipeline.Process($_) }
    }
    End {
        If ($ShouldInvoke) { $SteppablePipeline.End() }
    }
};

Export-ModuleMember -Function *-TargetResource



