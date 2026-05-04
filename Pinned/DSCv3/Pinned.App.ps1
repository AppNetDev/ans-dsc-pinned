#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('get', 'set', 'test', 'schema')]
    [string] $Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

function Read-JsonInput {
    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        return @{}
    }

    return ConvertTo-Hashtable (ConvertFrom-Json -InputObject $rawInput)
}

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) {
                $hash[$key] = ConvertTo-Hashtable $InputObject[$key]
            }
            return $hash
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
        }

        if ($InputObject -is [pscustomobject]) {
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable $property.Value
            }
            return $hash
        }

        return $InputObject
    }
}

function Write-JsonOutput {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $InputObject
    )

    process {
        $InputObject | ConvertTo-Json -Depth 20 -Compress
    }
}

function Get-AppSchema {
    @{
        '$schema' = 'https://json-schema.org/draft/2020-12/schema'
        '$id' = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/master/Pinned/DSCv3/Pinned.App.schema.json'
        title = 'Pinned.App'
        type = 'object'
        required = @('Name')
        additionalProperties = $false
        properties = @{
            Ensure = @{
                type = 'string'
                enum = @('Present', 'Absent')
                default = 'Present'
            }
            Name = @{
                type = 'string'
                minLength = 1
            }
            InstallerPath = @{
                type = 'string'
                default = ''
            }
            ProductId = @{ type = 'string' }
            InstalledCheckFilePath = @{ type = 'string' }
            InstalledCheckScript = @{ type = 'string' }
            NoRestart = @{
                type = 'boolean'
                default = $false
            }
            Arguments = @{ type = 'string' }
            ArgumentsForUninstall = @{ type = 'string' }
            WorkingDirectory = @{ type = 'string' }
            UseUninstallString = @{
                type = 'boolean'
                default = $false
            }
            ReturnCode = @{
                type = 'array'
                items = @{
                    type = 'integer'
                    minimum = 0
                }
                default = @(0, 1641, 3010)
            }
            ProcessTimeout = @{
                type = 'integer'
                minimum = 0
                maximum = 2147483
                default = 2147483
            }
            DownloadTimeout = @{
                type = 'integer'
                minimum = 0
                maximum = 2147483647
                default = 900
            }
            Version = @{ type = 'string' }
            PatchOnly = @{
                type = 'boolean'
                default = $false
            }
            ForceVersion = @{
                type = 'boolean'
                default = $false
            }
            UseSemVer = @{
                type = 'boolean'
                default = $false
            }
            FileHash = @{ type = 'string' }
            HashAlgorithm = @{
                type = 'string'
                enum = @('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5', 'RIPEMD160')
                default = 'SHA256'
            }
            PreAction = @{ type = 'string' }
            PostAction = @{ type = 'string' }
            PreCopyFrom = @{ type = 'string' }
            PreCopyTo = @{ type = 'string' }
            LogLevel = @{
                type = 'string'
                enum = @('None', 'Minimal', 'Moderate', 'All')
                default = 'All'
            }
            Publisher = @{ type = 'string' }
            UninstallString = @{ type = 'string' }
            Installed = @{ type = 'boolean' }
            _inDesiredState = @{ type = 'boolean' }
        }
    }
}

function Get-AppModulePath {
    $modulePath = Join-Path $PSScriptRoot '..\DSCResources\App\App.psm1'
    return (Resolve-Path -LiteralPath $modulePath).Path
}

function Import-AppResource {
    Import-Module (Get-AppModulePath) -Force -ErrorAction Stop
}

function Get-ResourceParameters {
    param(
        [Parameter(Mandatory)]
        [hashtable] $InputObject,

        [switch] $ForGet
    )

    $parameterNames = @(
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
    )

    if ($ForGet) {
        $parameterNames = @(
            'Ensure',
            'Name',
            'InstallerPath',
            'ProductId',
            'Version',
            'InstalledCheckFilePath',
            'LogLevel'
        )
    }

    $parameters = @{}
    foreach ($name in $parameterNames) {
        if ($InputObject.ContainsKey($name) -and $null -ne $InputObject[$name]) {
            $parameters[$name] = $InputObject[$name]
        }
    }

    if (-not $parameters.ContainsKey('Ensure')) {
        $parameters.Ensure = 'Present'
    }

    if (-not $parameters.ContainsKey('InstallerPath')) {
        $parameters.InstallerPath = ''
    }

    return $parameters
}

function Get-NormalizedState {
    param(
        [Parameter(Mandatory)]
        [hashtable] $InputObject
    )

    Import-AppResource

    $parameters = Get-ResourceParameters -InputObject $InputObject -ForGet
    $state = Get-TargetResource @parameters
    $state = ConvertTo-Hashtable $state

    if ($state.ContainsKey('Ensure') -and $null -ne $state.Ensure) {
        $state.Ensure = $state.Ensure.ToString()
    }

    if ($InputObject.ContainsKey('Name') -and [string]::IsNullOrWhiteSpace([string]$state.Name)) {
        $state.Name = $InputObject.Name
    }

    foreach ($propertyName in @('InstallerPath', 'ProductId', 'Version')) {
        if ($InputObject.ContainsKey($propertyName) -and (-not $state.ContainsKey($propertyName) -or $null -eq $state[$propertyName])) {
            $state[$propertyName] = $InputObject[$propertyName]
        }
    }

    return $state
}

function Test-NormalizedState {
    param(
        [Parameter(Mandatory)]
        [hashtable] $InputObject
    )

    Import-AppResource
    $parameters = Get-ResourceParameters -InputObject $InputObject
    return [bool](Test-TargetResource @parameters)
}

function Set-NormalizedState {
    param(
        [Parameter(Mandatory)]
        [hashtable] $InputObject
    )

    Import-AppResource
    $parameters = Get-ResourceParameters -InputObject $InputObject

    if (-not (Test-TargetResource @parameters)) {
        Set-TargetResource @parameters
    }

    return Get-NormalizedState -InputObject $InputObject
}

switch ($Operation) {
    'schema' {
        Get-AppSchema | Write-JsonOutput
        break
    }
    'get' {
        Get-NormalizedState -InputObject (Read-JsonInput) | Write-JsonOutput
        break
    }
    'test' {
        $inputObject = Read-JsonInput
        $state = Get-NormalizedState -InputObject $inputObject
        $state._inDesiredState = Test-NormalizedState -InputObject $inputObject
        $state | Write-JsonOutput
        break
    }
    'set' {
        Set-NormalizedState -InputObject (Read-JsonInput) | Write-JsonOutput
        break
    }
}
