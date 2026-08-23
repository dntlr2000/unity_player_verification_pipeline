[CmdletBinding()]
param(
    [Parameter()]
    [string]$ArtifactsRoot = 'E:\CodexValidation\unity-player-verification-p2-acceptance',

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
$script:ResultSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-player-verification-result-1.0.0.schema.json'
$script:AcceptanceRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd('\', '/')

. $script:FingerprintPath
. $script:SchemaValidatorPath

if ([string]::Equals([System.IO.Path]::GetPathRoot($script:AcceptanceRoot), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Real Unity P2 acceptance artifacts must not use the C drive.'
}
[void][System.IO.Directory]::CreateDirectory($script:AcceptanceRoot)

# Writes one generated P2 source, bundle, or summary as UTF-8 without a byte-order mark.
function Write-UpvrP2AcceptanceText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Creates one minimal immutable project for an approved Unity/Test Framework pair.
function New-UpvrP2AcceptanceProject {
    param([Parameter(Mandatory = $true)][object]$Configuration)

    $root = Join-Path $script:AcceptanceRoot ('sources\' + $Configuration.unityVersion)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Assets'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Packages'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'ProjectSettings'))
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'ProjectSettings\ProjectVersion.txt') -Content ("m_EditorVersion: $($Configuration.unityVersion)`r`nm_EditorVersionWithRevision: $($Configuration.unityVersion) ($($Configuration.revision))`r`n")
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'ProjectSettings\EditorBuildSettings.asset') -Content "%YAML 1.1`r`n--- !u!1045 &1`r`nEditorBuildSettings:`r`n  m_ObjectHideFlags: 0`r`n  serializedVersion: 2`r`n  m_Scenes: []`r`n"
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
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'Packages\manifest.json') -Content (ConvertTo-Json $manifest -Depth 10)
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'Packages\packages-lock.json') -Content (ConvertTo-Json $lock -Depth 10)
    return $root
}

# Creates one manifest-owned source-only bundle for the requested P2 verdict case.
function New-UpvrP2AcceptanceBundle {
    param([Parameter(Mandatory = $true)][object]$CaseDefinition)

    $root = Join-Path $script:AcceptanceRoot ('bundles\' + $CaseDefinition.name)
    [void][System.IO.Directory]::CreateDirectory($root)
    $manifest = [ordered]@{
        schemaVersion='1.0.0'; kind='PLAYER_SCENARIO_BUNDLE'; scenarioId=('p2-' + $CaseDefinition.name)
        displayName=('P2 acceptance ' + $CaseDefinition.name); timeoutSeconds=[int]$CaseDefinition.timeoutSeconds
        expectedScenes=@('P2AcceptanceScene'); expectedAssertionIds=@('state-ready'); expectedCaptureIds=@('frame')
        graphicsRequired=$true; testFilter='UnityPlayerVerification.PlayerScenarioTest.ExecuteScenario'
    }
    $asmdef = @'
{
  "name": "Upvr.P2.Acceptance.Scenario",
  "rootNamespace": "Upvr.P2.Acceptance",
  "references": ["UnityPlayerVerification.Harness"],
  "includePlatforms": [],
  "excludePlatforms": [],
  "allowUnsafeCode": false,
  "overrideReferences": false,
  "precompiledReferences": [],
  "autoReferenced": true,
  "defineConstraints": [],
  "versionDefines": [],
  "noEngineReferences": false
}
'@
    $body = switch ($CaseDefinition.name) {
        'success' { @'
            var scene = SceneManager.CreateScene("P2AcceptanceScene");
            SceneManager.SetActiveScene(scene);
            yield return context.WaitFrames(2);
            context.RecordAssertion("state-ready", Application.isPlaying, "Player is running.");
            yield return context.CapturePng("frame");
'@ }
        'assertion-failure' { @'
            var scene = SceneManager.CreateScene("P2AcceptanceScene");
            SceneManager.SetActiveScene(scene);
            yield return context.WaitFrames(1);
            context.RecordAssertion("state-ready", false, "Intentional assertion failure.");
            yield return context.CapturePng("frame");
'@ }
        'capture-missing' { @'
            var scene = SceneManager.CreateScene("P2AcceptanceScene");
            SceneManager.SetActiveScene(scene);
            yield return context.WaitFrames(1);
            context.RecordAssertion("state-ready", true, "Capture is intentionally omitted.");
'@ }
        'timeout' { @'
            var scene = SceneManager.CreateScene("P2AcceptanceScene");
            SceneManager.SetActiveScene(scene);
            context.RecordAssertion("state-ready", true, "Scenario entered its intentional loop.");
            while (true)
            {
                yield return null;
            }
'@ }
        'overlay-compile-failure' { '            this is intentionally invalid C#; // IPlayerVerificationScenario' }
        default { throw "Unknown P2 case $($CaseDefinition.name)." }
    }
    $source = @"
using System.Collections;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityPlayerVerification;

namespace Upvr.P2.Acceptance
{
    /// <summary>Runs one deterministic source-only Player acceptance scenario.</summary>
    public sealed class AcceptanceScenario : IPlayerVerificationScenario
    {
        /// <summary>Emits the manifest-owned evidence for the selected acceptance case.</summary>
        public IEnumerator Execute(PlayerVerificationContext context)
        {
$body
        }
    }
}
"@
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'manifest.json') -Content (ConvertTo-Json $manifest -Depth 10)
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'Upvr.P2.Acceptance.Scenario.asmdef') -Content $asmdef
    Write-UpvrP2AcceptanceText -Path (Join-Path $root 'AcceptanceScenario.cs') -Content $source
    return $root
}

# Runs one production P2 case and enforces its verdict, schema, receipt, and source integrity.
function Invoke-UpvrP2AcceptanceCase {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][object]$CaseDefinition
    )

    $caseArtifactRoot = Join-Path $script:AcceptanceRoot ("runs\$($Configuration.unityVersion)\$($CaseDefinition.name)")
    $arguments = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,
        '-Mode','SCENARIO_TEST_PLAYER','-ProjectRoot',$ProjectRoot,'-UnityExecutable',$Configuration.unityExecutable,
        '-ArtifactsRoot',$caseArtifactRoot,'-BuildTimeoutSeconds',$BuildTimeoutSeconds,
        '-RunTimeoutSeconds',$RunTimeoutSeconds,'-ScenarioBundlePath',$BundlePath,'-ScriptingBackend','Mono'
    )
    $stdout = & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "Verifier child process exited with code $LASTEXITCODE." }
    if (@($stdout).Count -ne 1) { throw "Verifier stdout contained $(@($stdout).Count) documents instead of one." }
    $result = ConvertFrom-Json -InputObject ([string]$stdout) -ErrorAction Stop
    if ([string]$result.finalStatus -cne [string]$CaseDefinition.expectedStatus) {
        throw "P2 acceptance $($Configuration.unityVersion)/$($CaseDefinition.name) expected $($CaseDefinition.expectedStatus), got $($result.finalStatus). Result: $($result.artifacts.resultPath)"
    }
    $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $result -SchemaPath $script:ResultSchemaPath)
    if ($schemaErrors.Count -ne 0) { throw "Result schema rejected $($Configuration.unityVersion)/$($CaseDefinition.name): $([string]::Join(' | ', [string[]]$schemaErrors))" }
    if ($result.originalProjectIntegrity.status -cne 'UNCHANGED' -or $result.gitMetadataIntegrity.status -notin @('UNCHANGED','NOT_PRESENT')) {
        throw "P2 acceptance source integrity failed for $($Configuration.unityVersion)/$($CaseDefinition.name)."
    }
    return [pscustomobject][ordered]@{
        unityVersion=$Configuration.unityVersion; testFrameworkVersion=$Configuration.testFrameworkVersion
        caseName=$CaseDefinition.name; expectedStatus=$CaseDefinition.expectedStatus; finalStatus=$result.finalStatus
        resultPath=$result.artifacts.resultPath; scenarioId=$result.scenario.scenarioId
        scenarioStatus=$result.verification.scenarioBehavior.status; visualStatus=$result.verification.visualEvidence.status
        receiptAccepted=$result.scenario.receiptAccepted; bundleTreeSha256=$result.scenario.bundleTreeSha256
        overlayTreeSha256=$result.isolation.scenarioOverlayTreeSha256; buildTreeSha256=$result.build.tree.treeSha256
        originalIntegrity=$result.originalProjectIntegrity.status; gitIntegrity=$result.gitMetadataIntegrity.status
        blockerCodes=@($result.blockers | ForEach-Object { $_.code }); failureCodes=@($result.failures | ForEach-Object { $_.code })
    }
}

$configurations = @(
    [pscustomobject][ordered]@{ unityVersion='2022.3.62f3'; revision='96770f904ca7'; testFrameworkVersion='1.1.33'; testFrameworkSource='registry'; nunitVersion='1.0.6'; nunitSource='registry'; unityExecutable='C:\Program Files\Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.0.69f1'; revision='5f8607f5118b'; testFrameworkVersion='1.6.0'; testFrameworkSource='builtin'; nunitVersion='2.0.3'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.5.3f1'; revision='c2eb47b3a2a9'; testFrameworkVersion='1.7.0'; testFrameworkSource='builtin'; nunitVersion='2.1.0'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.5.3f1\Editor\Unity.exe' }
)
$caseDefinitions = @(
    [pscustomobject][ordered]@{ name='success'; expectedStatus='PLAYER_VERIFIED'; timeoutSeconds=30 },
    [pscustomobject][ordered]@{ name='assertion-failure'; expectedStatus='PLAYER_FAILED'; timeoutSeconds=30 },
    [pscustomobject][ordered]@{ name='capture-missing'; expectedStatus='VERIFICATION_BLOCKED'; timeoutSeconds=30 },
    [pscustomobject][ordered]@{ name='timeout'; expectedStatus='VERIFICATION_BLOCKED'; timeoutSeconds=3 },
    [pscustomobject][ordered]@{ name='overlay-compile-failure'; expectedStatus='PLAYER_FAILED'; timeoutSeconds=30 }
)

$results = New-Object System.Collections.ArrayList
foreach ($configuration in $configurations) {
    if ($null -ne $UnityVersions -and $UnityVersions.Count -gt 0 -and $configuration.unityVersion -notin $UnityVersions) { continue }
    if (-not (Test-Path -LiteralPath $configuration.unityExecutable -PathType Leaf)) { throw "Required Unity editor is missing: $($configuration.unityExecutable)" }
    $projectRoot = New-UpvrP2AcceptanceProject -Configuration $configuration
    $projectBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $projectRoot
    foreach ($caseDefinition in $caseDefinitions) {
        if ($null -ne $CaseNames -and $CaseNames.Count -gt 0 -and $caseDefinition.name -notin $CaseNames) { continue }
        $bundlePath = New-UpvrP2AcceptanceBundle -CaseDefinition $caseDefinition
        $bundleBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $bundlePath
        Write-Host "Starting real Unity P2 acceptance: $($configuration.unityVersion)/$($caseDefinition.name)"
        [void]$results.Add((Invoke-UpvrP2AcceptanceCase -Configuration $configuration -ProjectRoot $projectRoot -BundlePath $bundlePath -CaseDefinition $caseDefinition))
        $bundleAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $bundlePath
        if ($bundleBefore.treeSha256 -cne $bundleAfter.treeSha256) { throw "P2 acceptance bundle changed: $($configuration.unityVersion)/$($caseDefinition.name)" }
        Write-Host "Passed real Unity P2 acceptance: $($configuration.unityVersion)/$($caseDefinition.name)"
    }
    $projectAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $projectRoot
    if ($projectBefore.treeSha256 -cne $projectAfter.treeSha256) { throw "P2 acceptance project changed for $($configuration.unityVersion)." }
}
if ($results.Count -eq 0) { throw 'P2 acceptance filters selected zero cases.' }

$expectedCount = (@($configurations | Where-Object { $null -eq $UnityVersions -or $UnityVersions.Count -eq 0 -or $_.unityVersion -in $UnityVersions }).Count) * (@($caseDefinitions | Where-Object { $null -eq $CaseNames -or $CaseNames.Count -eq 0 -or $_.name -in $CaseNames }).Count)
$summary = [ordered]@{
    schemaVersion='1.0.0'; phase='P2'; acceptanceStatus=$(if ($results.Count -eq $expectedCount) { 'APPROVED' } else { 'INCOMPLETE' })
    generatedAtUtc=[DateTime]::UtcNow.ToString('o'); artifactRoot=$script:AcceptanceRoot
    expectedCaseCount=$expectedCount; caseCount=$results.Count; results=@($results)
}
$summaryPath = Join-Path $script:AcceptanceRoot 'acceptance-summary.json'
Write-UpvrP2AcceptanceText -Path $summaryPath -Content (ConvertTo-Json $summary -Depth 20)
Write-Host "Unity Player Verification P2 acceptance completed. Status: $($summary.acceptanceStatus); cases: $($summary.caseCount); summary: $summaryPath"
