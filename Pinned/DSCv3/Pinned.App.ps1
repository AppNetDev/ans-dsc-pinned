#Requires -Version 5.1

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $True)]
    [ValidateSet('get', 'set', 'test', 'schema')]
    [String] $Operation
);

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';
$ProgressPreference = 'SilentlyContinue';
$VerbosePreference = 'SilentlyContinue';
$WarningPreference = 'SilentlyContinue';
$InformationPreference = 'SilentlyContinue';

Function ConvertTo-Hashtable {
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline = $True)]
        [Object] $InputObject
    );

    Process {
        If ($Null -eq $InputObject) {
            Return $Null;
        };

        If ($InputObject -is [System.Collections.IDictionary]) {
            $Hash = @{};

            ForEach ($Key in $InputObject.Keys) {
                $Hash[$Key] = ConvertTo-Hashtable -InputObject $InputObject[$Key];
            };

            Return $Hash;
        };

        If (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [String])) {
            Return @(
                $InputObject | ForEach-Object {
                    ConvertTo-Hashtable -InputObject $_;
                }
            );
        };

        If ($InputObject -is [PSCustomObject]) {
            $Hash = @{};

            ForEach ($Property in $InputObject.PSObject.Properties) {
                $Hash[$Property.Name] = ConvertTo-Hashtable -InputObject $Property.Value;
            };

            Return $Hash;
        };

        Return $InputObject;
    };
};

Function Read-JsonInput {
    [CmdletBinding()]
    Param();

    $RawInput = [Console]::In.ReadToEnd();

    If ([String]::IsNullOrWhiteSpace($RawInput)) {
        Return @{};
    };

    Return ConvertTo-Hashtable -InputObject (ConvertFrom-Json -InputObject $RawInput);
};

Function Write-JsonOutput {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [Object] $InputObject
    );

    Process {
        $InputObject | ConvertTo-Json -Depth 20 -Compress;
    };
};

Function Get-AppSchema {
    [CmdletBinding()]
    Param();

    Return @{
        '$schema'            = 'https://json-schema.org/draft/2020-12/schema';
        '$id'                = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/Pinned/DSCv3/Pinned.App.schema.json';
        title                = 'Pinned.App';
        type                 = 'object';
        required             = @('Name');
        additionalProperties = $False;
        properties           = @{
            Ensure                 = @{
                type    = 'string';
                enum    = @('Present', 'Absent');
                default = 'Present';
            };
            Name                   = @{
                type      = 'string';
                minLength = 1;
            };
            InstallerPath          = @{
                type    = 'string';
                default = '';
            };
            ProductId              = @{ type = 'string'; };
            InstalledCheckFilePath = @{ type = 'string'; };
            InstalledCheckScript   = @{ type = 'string'; };
            NoRestart              = @{
                type    = 'boolean';
                default = $False;
            };
            Arguments              = @{ type = 'string'; };
            ArgumentsForUninstall  = @{ type = 'string'; };
            WorkingDirectory       = @{ type = 'string'; };
            UseUninstallString     = @{
                type    = 'boolean';
                default = $False;
            };
            ReturnCode             = @{
                type    = 'array';
                items   = @{
                    type    = 'integer';
                    minimum = 0;
                };
                default = @(0, 1641, 3010);
            };
            ProcessTimeout         = @{
                type    = 'integer';
                minimum = 0;
                maximum = 2147483;
                default = 2147483;
            };
            DownloadTimeout        = @{
                type    = 'integer';
                minimum = 0;
                maximum = 2147483647;
                default = 900;
            };
            Version                = @{ type = 'string'; };
            PatchOnly              = @{
                type    = 'boolean';
                default = $False;
            };
            ForceVersion           = @{
                type    = 'boolean';
                default = $False;
            };
            UseSemVer              = @{
                type    = 'boolean';
                default = $False;
            };
            FileHash               = @{ type = 'string'; };
            HashAlgorithm          = @{
                type    = 'string';
                enum    = @('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5', 'RIPEMD160');
                default = 'SHA256';
            };
            PreAction              = @{ type = 'string'; };
            PostAction             = @{ type = 'string'; };
            PreCopyFrom            = @{ type = 'string'; };
            PreCopyTo              = @{ type = 'string'; };
            LogLevel               = @{
                type    = 'string';
                enum    = @('None', 'Minimal', 'Moderate', 'All');
                default = 'All';
            };
            Publisher              = @{ type = 'string'; };
            UninstallString        = @{ type = 'string'; };
            Installed              = @{ type = 'boolean'; };
            _inDesiredState        = @{ type = 'boolean'; };
        };
    };
};

Function Get-AppModulePath {
    [CmdletBinding()]
    Param();

    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\DSCResources\App\App.psm1';

    Return (Resolve-Path -LiteralPath $ModulePath).Path;
};

Function Import-AppResource {
    [CmdletBinding()]
    Param();

    Import-Module -Name (Get-AppModulePath) -Force -ErrorAction Stop;
};

Function Get-ResourceParameters {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [Hashtable] $InputObject,

        [Switch] $ForGet
    );

    $ParameterNames = @(
        'Ensure',
        'Name',
        'InstallerPath',
        'ProductId',
        'InstalledCheckFilePath',
        'InstalledCheckScript',
        'NoRestart',
        'Arguments',
        'ArgumentsForUninstall',
        'WorkingDirectory',
        'UseUninstallString',
        'ReturnCode',
        'ProcessTimeout',
        'DownloadTimeout',
        'Version',
        'PatchOnly',
        'ForceVersion',
        'UseSemVer',
        'FileHash',
        'HashAlgorithm',
        'PreAction',
        'PostAction',
        'PreCopyFrom',
        'PreCopyTo',
        'LogLevel'
    );

    If ($ForGet) {
        $ParameterNames = @(
            'Ensure',
            'Name',
            'InstallerPath',
            'ProductId',
            'Version',
            'InstalledCheckFilePath',
            'LogLevel'
        );
    };

    $Parameters = @{};

    ForEach ($Name in $ParameterNames) {
        If (($InputObject.ContainsKey($Name)) -and ($Null -ne $InputObject[$Name])) {
            $Parameters[$Name] = $InputObject[$Name];
        };
    };

    If (-not $Parameters.ContainsKey('Ensure')) {
        $Parameters.Ensure = 'Present';
    };

    If (-not $Parameters.ContainsKey('InstallerPath')) {
        $Parameters.InstallerPath = '';
    };

    Return $Parameters;
};

Function Get-NormalizedState {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [Hashtable] $InputObject
    );

    Import-AppResource;

    $Parameters = Get-ResourceParameters -InputObject $InputObject -ForGet;
    $State = Get-TargetResource @Parameters;
    $State = ConvertTo-Hashtable -InputObject $State;

    If (($State.ContainsKey('Ensure')) -and ($Null -ne $State.Ensure)) {
        $State.Ensure = $State.Ensure.ToString();
    };

    ForEach ($PropertyName in @('Name', 'InstallerPath', 'ProductId', 'Version', 'Publisher', 'UninstallString')) {
        If (($State.ContainsKey($PropertyName)) -and ($Null -eq $State[$PropertyName])) {
            $State[$PropertyName] = '';
        };
    };

    If (($InputObject.ContainsKey('Name')) -and ([String]::IsNullOrWhiteSpace([String] $State.Name))) {
        $State.Name = $InputObject.Name;
    };

    ForEach ($PropertyName in @('InstallerPath', 'ProductId', 'Version')) {
        If (($InputObject.ContainsKey($PropertyName)) -and ((-not $State.ContainsKey($PropertyName)) -or ($Null -eq $State[$PropertyName]))) {
            $State[$PropertyName] = $InputObject[$PropertyName];
        };
    };

    Return $State;
};

Function Test-NormalizedState {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [Hashtable] $InputObject
    );

    Import-AppResource;

    $Parameters = Get-ResourceParameters -InputObject $InputObject;

    Return [Boolean] (Test-TargetResource @Parameters);
};

Function Set-NormalizedState {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [Hashtable] $InputObject
    );

    Import-AppResource;

    $Parameters = Get-ResourceParameters -InputObject $InputObject;

    If (-not (Test-TargetResource @Parameters)) {
        Set-TargetResource @Parameters;
    };

    $State = Get-NormalizedState -InputObject $InputObject;
    $State._inDesiredState = Test-NormalizedState -InputObject $InputObject;

    If (-not $State._inDesiredState) {
        $DesiredVersion = If ($InputObject.ContainsKey('Version')) { $InputObject['Version'] } Else { '' };
        Throw ('Resource [{0}] did not reach the desired state after set. Current Ensure=[{1}], Installed=[{2}], Version=[{3}], DesiredVersion=[{4}].' -f $InputObject.Name, $State.Ensure, $State.Installed, $State.Version, $DesiredVersion);
    };

    Return $State;
};

Function New-FallbackState {
    [CmdletBinding()]
    Param(
        [Hashtable] $InputObject = @{}
    );

    $State = @{
        Ensure          = 'Absent';
        Name            = '';
        InstallerPath   = '';
        Version         = '';
        Installed       = $False;
        _inDesiredState = $False;
    };

    ForEach ($PropertyName in @('Ensure', 'Name', 'InstallerPath', 'Version', 'ProductId')) {
        If (($InputObject.ContainsKey($PropertyName)) -and ($Null -ne $InputObject[$PropertyName])) {
            $State[$PropertyName] = $InputObject[$PropertyName];
        };
    };

    Return $State;
};

$InputObject = @{};

Try {
    Switch ($Operation) {
        'schema' {
            Get-AppSchema | Write-JsonOutput;
            Break;
        };

        'get' {
            $InputObject = Read-JsonInput;
            Get-NormalizedState -InputObject $InputObject | Write-JsonOutput;
            Break;
        };

        'test' {
            $InputObject = Read-JsonInput;
            $State = Get-NormalizedState -InputObject $InputObject;
            $State._inDesiredState = Test-NormalizedState -InputObject $InputObject;
            $State | Write-JsonOutput;
            Break;
        };

        'set' {
            $InputObject = Read-JsonInput;
            Set-NormalizedState -InputObject $InputObject | Write-JsonOutput;
            Break;
        };
    };
} Catch {
    [Console]::Error.WriteLine($_.Exception.Message);

    If ($Operation -ne 'schema') {
        Try {
            $State = Get-NormalizedState -InputObject $InputObject;
            $State._inDesiredState = $False;
        } Catch {
            $State = New-FallbackState -InputObject $InputObject;
        };

        $State | Write-JsonOutput;
    };

    [Environment]::Exit(1);
};
