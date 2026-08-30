[CmdletBinding()]
param(
    [Parameter()]
    [string]$ArtifactsRoot = 'E:\CodexValidation\unity-player-verification-p1-acceptance',

    [Parameter()]
    [ValidateRange(60, 86400)]
    [int]$BuildTimeoutSeconds = 1800,

    [Parameter()]
    [ValidateRange(30, 86400)]
    [int]$RunTimeoutSeconds = 300,

    [Parameter()]
    [AllowNull()]
    [string[]]$UnityVersions,

    [Parameter()]
    [AllowNull()]
    [string[]]$CaseNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd('\', '/')
$script:RunnerPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\invoke-unity-player-verification.ps1'
$script:FingerprintPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\vendor\doctor\lib\unity-project-fingerprint.ps1'
$script:SchemaValidatorPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\vendor\shared\json-schema-validator.ps1'
$script:ResultSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-player-verification-result-1.1.0.schema.json'
$script:AcceptanceRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd('\', '/')

. $script:FingerprintPath
. $script:SchemaValidatorPath

if ([string]::Equals([System.IO.Path]::GetPathRoot($script:AcceptanceRoot), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Real Unity acceptance artifacts must not use the C drive.'
}
[void][System.IO.Directory]::CreateDirectory($script:AcceptanceRoot)

# Writes one generated acceptance source or summary as UTF-8 without a byte-order mark.
function Write-UpvrAcceptanceText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Creates one minimal source project for an exact approved Unity/Test Framework pair.
function New-UpvrAcceptanceProject {
    param([Parameter(Mandatory = $true)][object]$Configuration)

    $root = Join-Path $script:AcceptanceRoot ('sources\' + $Configuration.unityVersion)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Assets\Tests\PlayMode'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Packages'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'ProjectSettings'))
    Write-UpvrAcceptanceText -Path (Join-Path $root 'ProjectSettings\ProjectVersion.txt') -Content ("m_EditorVersion: $($Configuration.unityVersion)`r`nm_EditorVersionWithRevision: $($Configuration.unityVersion) ($($Configuration.revision))`r`n")
    Write-UpvrAcceptanceText -Path (Join-Path $root 'ProjectSettings\EditorBuildSettings.asset') -Content "%YAML 1.1`r`n--- !u!1045 &1`r`nEditorBuildSettings:`r`n  m_ObjectHideFlags: 0`r`n  serializedVersion: 2`r`n  m_Scenes: []`r`n"

    $manifest = [ordered]@{ dependencies = [ordered]@{ 'com.unity.test-framework' = $Configuration.testFrameworkVersion } }
    $testEntry = [ordered]@{
        version = $Configuration.testFrameworkVersion; depth = 0; source = $Configuration.testFrameworkSource
        dependencies = [ordered]@{ 'com.unity.ext.nunit' = $Configuration.nunitVersion; 'com.unity.modules.imgui' = '1.0.0'; 'com.unity.modules.jsonserialize' = '1.0.0' }
    }
    if ($Configuration.testFrameworkSource -eq 'registry') { $testEntry.url = 'https://packages.unity.com' }
    $nunitEntry = [ordered]@{ version = $Configuration.nunitVersion; depth = 1; source = $Configuration.nunitSource; dependencies = [ordered]@{} }
    if ($Configuration.nunitSource -eq 'registry') { $nunitEntry.url = 'https://packages.unity.com' }
    $lock = [ordered]@{ dependencies = [ordered]@{
        'com.unity.ext.nunit' = $nunitEntry
        'com.unity.modules.imgui' = [ordered]@{ version='1.0.0'; depth=1; source='builtin'; dependencies=[ordered]@{} }
        'com.unity.modules.jsonserialize' = [ordered]@{ version='1.0.0'; depth=1; source='builtin'; dependencies=[ordered]@{} }
        'com.unity.test-framework' = $testEntry
    } }
    Write-UpvrAcceptanceText -Path (Join-Path $root 'Packages\manifest.json') -Content (ConvertTo-Json $manifest -Depth 10)
    Write-UpvrAcceptanceText -Path (Join-Path $root 'Packages\packages-lock.json') -Content (ConvertTo-Json $lock -Depth 10)

    $asmdef = @'
{
  "name": "Upvr.Acceptance.Tests",
  "rootNamespace": "Upvr.Acceptance",
  "references": [],
  "includePlatforms": [],
  "excludePlatforms": [],
  "allowUnsafeCode": false,
  "overrideReferences": false,
  "precompiledReferences": [],
  "autoReferenced": true,
  "defineConstraints": [],
  "versionDefines": [],
  "noEngineReferences": false,
  "optionalUnityReferences": ["TestAssemblies"]
}
'@
    $tests = @'
using System;
using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Upvr.Acceptance
{
    /// <summary>Provides deterministic Windows Test Player acceptance cases.</summary>
    public sealed class AcceptanceTests
    {
        /// <summary>Proves a coroutine test executes across multiple Player frames.</summary>
        [UnityTest]
        public IEnumerator PassesAcrossFrames()
        {
            var startingFrame = Time.frameCount;
            yield return null;
            yield return null;
            Assert.Greater(Time.frameCount, startingFrame);
            Assert.IsTrue(Application.isPlaying);
        }

        /// <summary>Produces a deliberate complete Player-side NUnit failure.</summary>
        [UnityTest]
        public IEnumerator FailsDeliberately()
        {
            yield return null;
            Assert.Fail("Intentional Unity Player Verification acceptance failure.");
        }

        /// <summary>Produces a deliberate ignored Player test.</summary>
        [UnityTest, Ignore("Intentional Unity Player Verification acceptance skip.")]
        public IEnumerator SkipsDeliberately()
        {
            yield return null;
        }

        /// <summary>Produces a deliberate inconclusive Player test.</summary>
        [UnityTest]
        public IEnumerator IsInconclusiveDeliberately()
        {
            yield return null;
            Assert.Inconclusive("Intentional Unity Player Verification acceptance inconclusive result.");
        }

        /// <summary>Emits a retained crash marker and abruptly terminates the Test Player.</summary>
        [UnityTest]
        public IEnumerator CrashesPlayerDeliberately()
        {
            yield return null;
            Debug.LogError("UPVR_ACCEPTANCE_PLAYER_CRASH");
            Environment.FailFast("Intentional Unity Player Verification crash acceptance case.");
        }

        /// <summary>Exits before NUnit callbacks can return complete PlayerConnection evidence.</summary>
        [UnityTest]
        public IEnumerator ExitsBeforeResults()
        {
            yield return null;
            Debug.Log("UPVR_ACCEPTANCE_CONNECTION_MISSING");
            Application.Quit(0);
            while (true)
            {
                yield return null;
            }
        }
    }
}
'@
    Write-UpvrAcceptanceText -Path (Join-Path $root 'Assets\Tests\PlayMode\Upvr.Acceptance.Tests.asmdef') -Content $asmdef
    Write-UpvrAcceptanceText -Path (Join-Path $root 'Assets\Tests\PlayMode\AcceptanceTests.cs') -Content $tests
    return $root
}

# Creates a separate source project containing an intentional C# compiler error.
function New-UpvrCompileFailureProject {
    param(
        [Parameter(Mandatory = $true)][string]$BaseProject,
        [Parameter(Mandatory = $true)][string]$UnityVersion
    )

    $root = Join-Path $script:AcceptanceRoot ('sources\' + $UnityVersion + '-compile-failure')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Copy-Item -LiteralPath $BaseProject -Destination $root -Recurse }
    Write-UpvrAcceptanceText -Path (Join-Path $root 'Assets\Tests\PlayMode\IntentionalCompileFailure.cs') -Content 'this is intentionally invalid C#;'
    return $root
}

# Runs one production verifier case and enforces its expected status and integrity evidence.
function Invoke-UpvrAcceptanceCase {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][object]$CaseDefinition
    )

    $caseArtifactRoot = Join-Path $script:AcceptanceRoot ("runs\$($Configuration.unityVersion)\$($CaseDefinition.name)")
    $arguments = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,
        '-Mode','TEST_PLAYER','-ProjectRoot',$ProjectRoot,'-UnityExecutable',$Configuration.unityExecutable,
        '-ArtifactsRoot',$caseArtifactRoot,'-BuildTimeoutSeconds',$BuildTimeoutSeconds,
        '-RunTimeoutSeconds',$RunTimeoutSeconds,'-ScriptingBackend','Mono'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$CaseDefinition.testFilter)) { $arguments += @('-TestFilter', [string]$CaseDefinition.testFilter) }
    $stdout = & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "Verifier child process exited with code $LASTEXITCODE." }
    if (@($stdout).Count -ne 1) { throw "Verifier stdout contained $(@($stdout).Count) documents instead of one." }
    $result = ConvertFrom-Json -InputObject ([string]$stdout) -ErrorAction Stop
    if ([string]$result.finalStatus -cne [string]$CaseDefinition.expectedStatus) {
        throw "Acceptance $($Configuration.unityVersion)/$($CaseDefinition.name) expected $($CaseDefinition.expectedStatus), got $($result.finalStatus). Result: $($result.artifacts.resultPath)"
    }
    $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $result -SchemaPath $script:ResultSchemaPath)
    if ($schemaErrors.Count -ne 0) { throw "Result schema rejected $($Configuration.unityVersion)/$($CaseDefinition.name): $([string]::Join(' | ', [string[]]$schemaErrors))" }
    if ($result.originalProjectIntegrity.status -cne 'UNCHANGED' -or $result.gitMetadataIntegrity.status -notin @('UNCHANGED','NOT_PRESENT')) {
        throw "Source integrity failed for $($Configuration.unityVersion)/$($CaseDefinition.name)."
    }
    return [pscustomobject][ordered]@{
        unityVersion = $Configuration.unityVersion
        testFrameworkVersion = $Configuration.testFrameworkVersion
        caseName = $CaseDefinition.name
        expectedStatus = $CaseDefinition.expectedStatus
        finalStatus = $result.finalStatus
        resultPath = $result.artifacts.resultPath
        compatibilityStatus = $result.compatibility.verificationStatus
        moduleTreeSha256 = $result.compatibility.windowsStandaloneModule.treeSha256
        packageTreeSha256 = $result.compatibility.packageIdentity.treeSha256
        playerConnectionClassification = $result.nunit.playerConnection.classification
        runtimeClassification = $result.nunit.runtime.classification
        nunitAgreement = $result.nunit.agreement.accepted
        buildTreeSha256 = $result.build.tree.treeSha256
        originalIntegrity = $result.originalProjectIntegrity.status
        gitIntegrity = $result.gitMetadataIntegrity.status
        blockerCodes = @($result.blockers | ForEach-Object { $_.code })
        failureCodes = @($result.failures | ForEach-Object { $_.code })
    }
}

$configurations = @(
    [pscustomobject][ordered]@{ unityVersion='2022.3.62f3'; revision='96770f904ca7'; testFrameworkVersion='1.1.33'; testFrameworkSource='registry'; nunitVersion='1.0.6'; nunitSource='registry'; unityExecutable='C:\Program Files\Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.0.69f1'; revision='5f8607f5118b'; testFrameworkVersion='1.6.0'; testFrameworkSource='builtin'; nunitVersion='2.0.3'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.5.3f1'; revision='c2eb47b3a2a9'; testFrameworkVersion='1.7.0'; testFrameworkSource='builtin'; nunitVersion='2.1.0'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.5.3f1\Editor\Unity.exe' }
)
$caseDefinitions = @(
    [pscustomobject][ordered]@{ name='pass'; expectedStatus='PLAYER_VERIFIED'; testFilter='Upvr.Acceptance.AcceptanceTests.PassesAcrossFrames'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='fail'; expectedStatus='PLAYER_FAILED'; testFilter='Upvr.Acceptance.AcceptanceTests.FailsDeliberately'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='skip'; expectedStatus='VERIFICATION_BLOCKED'; testFilter='Upvr.Acceptance.AcceptanceTests.SkipsDeliberately'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='inconclusive'; expectedStatus='VERIFICATION_BLOCKED'; testFilter='Upvr.Acceptance.AcceptanceTests.IsInconclusiveDeliberately'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='zero'; expectedStatus='VERIFICATION_BLOCKED'; testFilter='Upvr.Acceptance.NoSuchTest'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='compile-failure'; expectedStatus='PLAYER_FAILED'; testFilter='Upvr.Acceptance.AcceptanceTests.PassesAcrossFrames'; compileFailure=$true },
    [pscustomobject][ordered]@{ name='player-crash'; expectedStatus='PLAYER_FAILED'; testFilter='Upvr.Acceptance.AcceptanceTests.CrashesPlayerDeliberately'; compileFailure=$false },
    [pscustomobject][ordered]@{ name='connection-missing'; expectedStatus='VERIFICATION_BLOCKED'; testFilter='Upvr.Acceptance.AcceptanceTests.ExitsBeforeResults'; compileFailure=$false }
)

$results = New-Object System.Collections.ArrayList
foreach ($configuration in $configurations) {
    if ($null -ne $UnityVersions -and $UnityVersions.Count -gt 0 -and $configuration.unityVersion -notin $UnityVersions) { continue }
    if (-not (Test-Path -LiteralPath $configuration.unityExecutable -PathType Leaf)) { throw "Required Unity editor is missing: $($configuration.unityExecutable)" }
    $baseProject = New-UpvrAcceptanceProject -Configuration $configuration
    $baseBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $baseProject
    foreach ($caseDefinition in $caseDefinitions) {
        if ($null -ne $CaseNames -and $CaseNames.Count -gt 0 -and $caseDefinition.name -notin $CaseNames) { continue }
        $caseProject = if ($caseDefinition.compileFailure) { New-UpvrCompileFailureProject -BaseProject $baseProject -UnityVersion $configuration.unityVersion } else { $baseProject }
        $caseBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $caseProject
        Write-Host "Starting real Unity P1 acceptance: $($configuration.unityVersion)/$($caseDefinition.name)"
        [void]$results.Add((Invoke-UpvrAcceptanceCase -Configuration $configuration -ProjectRoot $caseProject -CaseDefinition $caseDefinition))
        $caseAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $caseProject
        if ($caseBefore.treeSha256 -cne $caseAfter.treeSha256) { throw "Acceptance source changed: $($configuration.unityVersion)/$($caseDefinition.name)" }
        Write-Host "Passed real Unity P1 acceptance: $($configuration.unityVersion)/$($caseDefinition.name)"
    }
    $baseAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $baseProject
    if ($baseBefore.treeSha256 -cne $baseAfter.treeSha256) { throw "Base acceptance source changed for $($configuration.unityVersion)." }
}
if ($results.Count -eq 0) { throw 'Acceptance filters selected zero cases.' }

$expectedCount = (@($configurations | Where-Object { $null -eq $UnityVersions -or $UnityVersions.Count -eq 0 -or $_.unityVersion -in $UnityVersions }).Count) * (@($caseDefinitions | Where-Object { $null -eq $CaseNames -or $CaseNames.Count -eq 0 -or $_.name -in $CaseNames }).Count)
$summary = [ordered]@{
    schemaVersion = '1.0.0'
    phase = 'P1'
    acceptanceStatus = if ($results.Count -eq $expectedCount) { 'APPROVED' } else { 'INCOMPLETE' }
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    artifactRoot = $script:AcceptanceRoot
    expectedCaseCount = $expectedCount
    caseCount = $results.Count
    results = @($results)
}
$summaryPath = Join-Path $script:AcceptanceRoot 'acceptance-summary.json'
Write-UpvrAcceptanceText -Path $summaryPath -Content (ConvertTo-Json $summary -Depth 20)
Write-Host "Unity Player Verification P1 acceptance completed. Status: $($summary.acceptanceStatus); cases: $($summary.caseCount); summary: $summaryPath"
