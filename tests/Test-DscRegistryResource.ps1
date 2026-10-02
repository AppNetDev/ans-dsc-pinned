#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies Registry resource bootstrap compatibility without installing DSC.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples\dscv3\Install-PinnedDscV3.ps1'
$tokens = $null
$parseErrors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

# Load only these functions; the bootstrap's installation entry point must not run.
foreach ($functionName in @('Get-DscRegistryManifestPath', 'Test-DscBundledResources', 'Install-DscRegistryResource')) {
    $functionAst = $installerAst.Find({
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $functionName
    }, $true)
    if (-not $functionAst) {
        throw "Missing installer function: $functionName"
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ans-registry-bootstrap-test-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -Path $testRoot -ItemType Directory | Out-Null
try {
    $sourceDirectory = Join-Path $testRoot 'DSC'
    New-Item -Path $sourceDirectory -ItemType Directory | Out-Null
    $dscPath = Join-Path $sourceDirectory 'dsc.exe'
    $registryExecutable = Join-Path $sourceDirectory 'registry.exe'
    $legacyManifest = Join-Path $sourceDirectory 'registry.dsc.resource.json'
    $collectionManifest = Join-Path $sourceDirectory 'registry.dsc.manifests.json'
    $pinnedDirectory = Join-Path $testRoot 'Resources\AppNetOnline.Pinned'

    Assert-Condition (-not (Test-DscBundledResources -Path $dscPath)) 'Empty install must fail the bundled-resource check.'
    Set-Content -LiteralPath $legacyManifest -Value '{"type":"Microsoft.Windows/Registry"}'
    Assert-Condition (-not (Test-DscBundledResources -Path $dscPath)) 'A manifest without registry.exe must fail.'
    Set-Content -LiteralPath $registryExecutable -Value 'test fixture; never executed'
    Assert-Condition (Test-DscBundledResources -Path $dscPath) 'Legacy layout must be accepted.'
    $destination = Install-DscRegistryResource -DscPath $dscPath -ResourceInstallDirectory $pinnedDirectory
    Assert-Condition (Test-Path -LiteralPath (Join-Path $destination 'registry.dsc.resource.json')) 'Legacy manifest must be copied.'

    Set-Content -LiteralPath $collectionManifest -Value '{"resources":[{"type":"Microsoft.Windows/Registry"}]}'
    Assert-Condition ((Get-DscRegistryManifestPath -DscPath $dscPath) -eq $collectionManifest) 'Collection must take precedence when both source manifests exist.'
    Assert-Condition (Test-DscBundledResources -Path $dscPath) 'DSC 3.3 layout must be accepted.'
    $destination = Install-DscRegistryResource -DscPath $dscPath -ResourceInstallDirectory $pinnedDirectory
    Assert-Condition (Test-Path -LiteralPath (Join-Path $destination 'registry.dsc.manifests.json')) 'Collection filename must be preserved.'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'registry.dsc.resource.json'))) 'Upgrade must remove the stale managed manifest.'
    Assert-Condition (Test-Path -LiteralPath $legacyManifest) 'Upgrade must preserve the source manifest.'
    $null = Install-DscRegistryResource -DscPath $dscPath -ResourceInstallDirectory $pinnedDirectory
    Assert-Condition (@(Get-ChildItem -LiteralPath $destination -Filter '*.json').Count -eq 1) 'Repeat installation must keep a single manifest.'

    Remove-Item -LiteralPath $collectionManifest
    $destination = Install-DscRegistryResource -DscPath $dscPath -ResourceInstallDirectory $pinnedDirectory
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'registry.dsc.manifests.json'))) 'Downgrade must remove the stale collection.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $destination 'registry.exe')) 'Registry executable must be copied.'

    Remove-Item -LiteralPath $legacyManifest
    $caughtMissingManifest = $false
    try {
        $null = Install-DscRegistryResource -DscPath $dscPath -ResourceInstallDirectory $pinnedDirectory
    }
    catch {
        $caughtMissingManifest = $_.Exception.Message -like '*Expected registry.dsc.manifests.json*'
    }
    Assert-Condition $caughtMissingManifest 'Missing manifest must report both supported filenames.'
    [pscustomobject] @{ Test = 'DSC Registry bootstrap compatibility'; Outcome = 'Passed' }
}
finally {
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    $expectedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot -ne $expectedTestRoot -or (Split-Path -Leaf $resolvedTestRoot) -notlike 'ans-registry-bootstrap-test-*') {
        throw "Refusing to remove unexpected test directory: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
