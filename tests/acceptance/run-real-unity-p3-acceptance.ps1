[CmdletBinding()]
param(
    [Parameter()]
    [string]$ArtifactsRoot = 'E:\CodexValidation\unity-player-verification-p3-acceptance',

    [Parameter()]
    [ValidateRange(60, 86400)]
    [int]$BuildTimeoutSeconds = 3600,

    [Parameter()]
    [ValidateRange(15, 86400)]
    [int]$RunTimeoutSeconds = 60,

    [Parameter()]
    [AllowNull()]
    [string[]]$UnityVersions,

    [Parameter()]
    [AllowNull()]
    [ValidateSet('Mono','IL2CPP')]
    [string[]]$ScriptingBackends,

    [Parameter()]
    [AllowNull()]
    [string[]]$CaseNames,

    [Parameter()]
    [AllowNull()]
    [string]$CandidateProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:TEMP = 'E:\CodexTemp'
$env:TMP = 'E:\CodexTemp'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd('\', '/')
$script:SourceSkillRoot = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification'
$script:RunnerPath = Join-Path $script:SourceSkillRoot 'scripts\invoke-unity-player-verification.ps1'
$script:FingerprintPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\vendor\doctor\lib\unity-project-fingerprint.ps1'
$script:SchemaValidatorPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\vendor\shared\json-schema-validator.ps1'
$script:ResultSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-player-verification-result-1.1.0.schema.json'
$script:AcceptanceRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd('\', '/')
$script:AcceptanceToolchainProfileId = $null
$script:AcceptanceVisualStudioPath = $null
$script:CandidateEvidence = $null

. $script:FingerprintPath
. $script:SchemaValidatorPath

if ([string]::Equals([System.IO.Path]::GetPathRoot($script:AcceptanceRoot), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Real Unity P3 acceptance artifacts must not use the C drive.'
}
[void][System.IO.Directory]::CreateDirectory($script:AcceptanceRoot)
[void][System.IO.Directory]::CreateDirectory('E:\CodexTemp')

# Writes one generated P3 source, bundle, or summary as UTF-8 without a byte-order mark.
function Write-UpvrP3AcceptanceText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Creates an external Skill copy whose one reviewed candidate is temporarily eligible only for acceptance execution.
function Initialize-UpvrP3CandidateAcceptanceRunner {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidatePath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw 'CandidateProfilePath is missing.' }
    if ([string]::Equals([System.IO.Path]::GetPathRoot($candidatePath), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'CandidateProfilePath must not use the C drive.' }
    $candidateSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidatePath).Hash.ToLowerInvariant()
    $candidateDocument = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([string]$candidateDocument.schemaVersion -cne '1.0.0' -or [string]$candidateDocument.kind -cne 'UPVR_IL2CPP_TOOLCHAIN_CANDIDATE' -or [string]$candidateDocument.profile.status -cne 'CANDIDATE') {
        throw 'CandidateProfilePath is not an unapproved UPVR IL2CPP toolchain candidate.'
    }

    $stageParent = Join-Path $script:AcceptanceRoot ('staged-skill-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($stageParent)
    Copy-Item -LiteralPath $script:SourceSkillRoot -Destination $stageParent -Recurse -Force
    $stagedSkillRoot = Join-Path $stageParent 'unity-player-verification'
    $registryPath = Join-Path $stagedSkillRoot 'config\unity-player-compatibility.json'
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $profileId = [string]$candidateDocument.profile.profileId
    $profiles = @($registry.toolchainProfiles | Where-Object { [string]$_.profileId -ceq $profileId })
    if ($profiles.Count -ne 1) { throw "Staged registry does not contain candidate profile '$profileId' exactly once." }
    $profile = $profiles[0]
    if ([string]$profile.buildToolchainIdentity.identitySha256 -cne [string]$candidateDocument.profile.buildToolchainIdentity.identitySha256 -or
        [string]$profile.approvalHostEnvironmentIdentity.identitySha256 -cne [string]$candidateDocument.profile.approvalHostEnvironmentIdentity.identitySha256) {
        throw 'Candidate manifest does not exactly match the staged registry candidate.'
    }
    $profile.status = 'APPROVED'
    $profile.approval.evidencePath = $candidatePath
    $profile.approval.evidenceSha256 = $candidateSha256
    $profile.approval.approvedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-UpvrP3AcceptanceText -Path $registryPath -Content (ConvertTo-Json $registry -Depth 40)
    $script:RunnerPath = Join-Path $stagedSkillRoot 'scripts\invoke-unity-player-verification.ps1'
    $script:AcceptanceToolchainProfileId = $profileId
    $script:AcceptanceVisualStudioPath = [string]$candidateDocument.profile.approvalHostEnvironmentIdentity.visualStudioPath
    $script:CandidateEvidence = [pscustomobject][ordered]@{
        candidatePath=$candidatePath; candidateSha256=$candidateSha256; profileId=$profileId
        buildToolchainIdentitySha256=[string]$candidateDocument.profile.buildToolchainIdentity.identitySha256
        hostEnvironmentIdentitySha256=[string]$candidateDocument.profile.approvalHostEnvironmentIdentity.identitySha256
        stagedSkillRoot=$stagedSkillRoot; stagedRegistryPath=$registryPath
        stagedRegistrySha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $registryPath).Hash.ToLowerInvariant()
    }
}

# Creates one minimal immutable project with an enabled Standalone build Scene.
function New-UpvrP3AcceptanceProject {
    param([Parameter(Mandatory = $true)][object]$Configuration)

    $root = Join-Path $script:AcceptanceRoot ('sources\' + $Configuration.unityVersion)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Assets\Scenes'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Packages'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'ProjectSettings'))
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'ProjectSettings\ProjectVersion.txt') -Content ("m_EditorVersion: $($Configuration.unityVersion)`r`nm_EditorVersionWithRevision: $($Configuration.unityVersion) ($($Configuration.revision))`r`n")
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'ProjectSettings\EditorBuildSettings.asset') -Content "%YAML 1.1`r`n--- !u!1045 &1`r`nEditorBuildSettings:`r`n  m_ObjectHideFlags: 0`r`n  serializedVersion: 2`r`n  m_Scenes:`r`n  - enabled: 1`r`n    path: Assets/Scenes/Main.unity`r`n    guid: 11111111111111111111111111111111`r`n  m_configObjects: {}`r`n"
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'Assets\Scenes\Main.unity') -Content "%YAML 1.1`r`n--- !u!1 &1`r`nGameObject:`r`n  m_ObjectHideFlags: 0`r`n  m_CorrespondingSourceObject: {fileID: 0}`r`n  m_PrefabInstance: {fileID: 0}`r`n  m_PrefabAsset: {fileID: 0}`r`n  serializedVersion: 6`r`n  m_Component:`r`n  - component: {fileID: 4}`r`n  m_Layer: 0`r`n  m_Name: Main`r`n  m_TagString: Untagged`r`n  m_Icon: {fileID: 0}`r`n  m_NavMeshLayer: 0`r`n  m_StaticEditorFlags: 0`r`n  m_IsActive: 1`r`n--- !u!4 &4`r`nTransform:`r`n  m_ObjectHideFlags: 0`r`n  m_CorrespondingSourceObject: {fileID: 0}`r`n  m_PrefabInstance: {fileID: 0}`r`n  m_PrefabAsset: {fileID: 0}`r`n  m_GameObject: {fileID: 1}`r`n  serializedVersion: 2`r`n  m_LocalRotation: {x: 0, y: 0, z: 0, w: 1}`r`n  m_LocalPosition: {x: 0, y: 0, z: 0}`r`n  m_LocalScale: {x: 1, y: 1, z: 1}`r`n  m_ConstrainProportionsScale: 0`r`n  m_Children: []`r`n  m_Father: {fileID: 0}`r`n  m_LocalEulerAnglesHint: {x: 0, y: 0, z: 0}`r`n"

    $manifest = [ordered]@{ dependencies = [ordered]@{ 'com.unity.test-framework' = $Configuration.testFrameworkVersion } }
    $testEntry = [ordered]@{
        version=$Configuration.testFrameworkVersion; depth=0; source=$Configuration.testFrameworkSource
        dependencies=[ordered]@{ 'com.unity.ext.nunit'=$Configuration.nunitVersion; 'com.unity.modules.imgui'='1.0.0'; 'com.unity.modules.jsonserialize'='1.0.0' }
    }
    if ($Configuration.testFrameworkSource -eq 'registry') { $testEntry.url = 'https://packages.unity.com' }
    $nunitEntry = [ordered]@{ version=$Configuration.nunitVersion; depth=1; source=$Configuration.nunitSource; dependencies=[ordered]@{} }
    if ($Configuration.nunitSource -eq 'registry') { $nunitEntry.url = 'https://packages.unity.com' }
    $lock = [ordered]@{ dependencies = [ordered]@{
        'com.unity.ext.nunit'=$nunitEntry
        'com.unity.modules.imgui'=[ordered]@{ version='1.0.0'; depth=1; source='builtin'; dependencies=[ordered]@{} }
        'com.unity.modules.jsonserialize'=[ordered]@{ version='1.0.0'; depth=1; source='builtin'; dependencies=[ordered]@{} }
        'com.unity.test-framework'=$testEntry
    } }
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'Packages\manifest.json') -Content (ConvertTo-Json $manifest -Depth 10)
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'Packages\packages-lock.json') -Content (ConvertTo-Json $lock -Depth 10)
    return $root
}

# Creates one source-only scenario whose acceptance branch is selected only by the local test harness.
function New-UpvrP3AcceptanceBundle {
    $root = Join-Path $script:AcceptanceRoot 'bundle'
    [void][System.IO.Directory]::CreateDirectory($root)
    $manifest = [ordered]@{
        schemaVersion='1.0.0'; kind='STANDALONE_SCENARIO_BUNDLE'; scenarioId='p3-runtime-matrix'
        displayName='P3 runtime matrix'; timeoutSeconds=5; buildScenes=@('Assets/Scenes/Main.unity')
        expectedScenes=@('Assets/Scenes/Main.unity'); expectedAssertionIds=@('state-ready')
        expectedCaptureIds=@('frame'); graphicsRequired=$true
    }
    $asmdef = @'
{
  "name": "Upvr.P3.Acceptance.Scenario",
  "rootNamespace": "Upvr.P3.Acceptance",
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
    $source = @'
using System;
using System.Collections;
using UnityEngine;
using UnityEngine.Diagnostics;
using UnityPlayerVerification;

namespace Upvr.P3.Acceptance
{
    /// <summary>Runs deterministic P3 runtime branches from one approved binary.</summary>
    public sealed class AcceptanceScenario : IPlayerVerificationScenario
    {
        /// <summary>Emits success, assertion, exception, crash, or timeout evidence selected by the acceptance environment.</summary>
        public IEnumerator Execute(PlayerVerificationContext context)
        {
            var acceptanceCase = Environment.GetEnvironmentVariable("UPVR_P3_ACCEPTANCE_CASE") ?? "success";
            if (string.Equals(acceptanceCase, "top-level-exception", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Intentional top-level scenario exception.");
            }
            if (string.Equals(acceptanceCase, "crash", StringComparison.Ordinal))
            {
                Debug.LogError("UPVR_ACCEPTANCE_PLAYER_CRASH");
                Utils.ForceCrash(ForcedCrashCategory.FatalError);
                yield break;
            }
            if (string.Equals(acceptanceCase, "timeout", StringComparison.Ordinal))
            {
                while (true)
                {
                    yield return null;
                }
            }
            yield return context.WaitFrames(2);
            var passed = !string.Equals(acceptanceCase, "assertion-failure", StringComparison.Ordinal);
            context.RecordAssertion("state-ready", passed, passed ? "Standalone Player is running." : "Intentional assertion failure.");
            yield return context.CapturePng("frame");
            if (string.Equals(acceptanceCase, "nested-exception", StringComparison.Ordinal))
            {
                yield return ThrowNestedException();
            }
            if (string.Equals(acceptanceCase, "nested-wait-timeout", StringComparison.Ordinal))
            {
                yield return context.WaitUntil(() => false, 1f);
            }
        }

        /// <summary>Throws after one nested frame so the Standalone runner must retain the exception boundary.</summary>
        private static IEnumerator ThrowNestedException()
        {
            yield return null;
            throw new InvalidOperationException("Intentional nested scenario exception.");
        }
    }
}
'@
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'manifest.json') -Content (ConvertTo-Json $manifest -Depth 10)
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'Upvr.P3.Acceptance.Scenario.asmdef') -Content $asmdef
    Write-UpvrP3AcceptanceText -Path (Join-Path $root 'AcceptanceScenario.cs') -Content $source
    return $root
}

# Invokes one production verifier process and enforces stdout, schema, verdict, and retained result evidence.
function Invoke-UpvrP3Runner {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][string]$CaseLabel
    )

    $stdout = & powershell.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Verifier child process exited with code $LASTEXITCODE for $CaseLabel." }
    if (@($stdout).Count -ne 1) { throw "Verifier stdout contained $(@($stdout).Count) documents instead of one for $CaseLabel." }
    $result = ConvertFrom-Json -InputObject ([string]$stdout) -ErrorAction Stop
    if ([string]$result.finalStatus -cne $ExpectedStatus) { throw "$CaseLabel expected $ExpectedStatus, got $($result.finalStatus). Result: $($result.artifacts.resultPath)" }
    $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $result -SchemaPath $script:ResultSchemaPath)
    if ($schemaErrors.Count -ne 0) { throw "Result schema rejected ${CaseLabel}: $([string]::Join(' | ', [string[]]$schemaErrors))" }
    return $result
}

# Requires exception cases to retain a FAILED receipt and exit before the external process timeout.
function Assert-UpvrP3CoroutineFailureEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][int]$ExternalTimeoutSeconds
    )

    if ($CaseName -notin @('top-level-exception','nested-exception','nested-wait-timeout')) { return }
    $receiptPath = [string]$Result.artifacts.scenarioReceiptPath
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "$CaseName did not emit a scenario failure receipt." }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$receipt.runFinished -or [string]$receipt.result -cne 'FAILED') { throw "$CaseName receipt is not a completed FAILED result." }
    if ([bool]$Result.playerProcess.timedOut) { throw "$CaseName reached the external Player timeout instead of exiting from the runtime receipt path." }
    if ([long]$Result.playerProcess.exitCode -ne 1) { throw "$CaseName Player exit code must be 1 after a retained failure receipt." }
    $promptExitLimitMilliseconds = [long]([Math]::Min([Math]::Max(2, $ExternalTimeoutSeconds - 1), 30) * 1000)
    if ([long]$Result.playerProcess.elapsedMilliseconds -ge $promptExitLimitMilliseconds) { throw "$CaseName Player did not exit promptly after writing its receipt." }

    if ($CaseName -eq 'top-level-exception') {
        if ([string]$receipt.exception -notmatch 'Intentional top-level scenario exception') { throw 'Top-level exception detail was not retained.' }
        return
    }

    if (@($receipt.assertions).Count -ne 1 -or [string]$receipt.assertions[0].id -cne 'state-ready') { throw "$CaseName did not retain its recorded assertion." }
    if (@($receipt.captures).Count -ne 1 -or [string]$receipt.captures[0].id -cne 'frame') { throw "$CaseName did not retain its recorded capture." }
    $expectedExceptionPattern = if ($CaseName -eq 'nested-exception') { 'Intentional nested scenario exception' } else { 'TimeoutException' }
    if ([string]$receipt.exception -notmatch $expectedExceptionPattern) { throw "$CaseName exception detail was not retained." }
}

# Requires the Editor build and Player Job Objects to prove that their complete process trees exited.
function Assert-UpvrP3ProcessCleanupEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$CaseLabel
    )

    $playerProcess = $Result.processControl.standaloneRun
    if (
        -not [bool]$playerProcess.jobObjectCreated -or
        -not [bool]$playerProcess.killOnJobCloseConfigured -or
        -not [bool]$playerProcess.processAssignedToJob -or
        -not [bool]$playerProcess.rootProcessExited -or
        -not [bool]$playerProcess.processTreeExitVerified -or
        [long]$playerProcess.activeProcessCountAfterWait -ne 0
    ) {
        throw "$CaseLabel did not prove complete Player process-tree cleanup."
    }

    if ([string]$Result.input.mode -ceq 'INSTRUMENTED_STANDALONE') {
        $editorProcess = $Result.processControl.editorBuild
        if (
            -not [bool]$editorProcess.jobObjectCreated -or
            -not [bool]$editorProcess.killOnJobCloseConfigured -or
            -not [bool]$editorProcess.processAssignedToJob -or
            -not [bool]$editorProcess.rootProcessExited -or
            -not [bool]$editorProcess.processTreeExitVerified -or
            [long]$editorProcess.activeProcessCountAfterWait -ne 0
        ) {
            throw "$CaseLabel did not prove complete Unity Editor build process-tree cleanup."
        }
    }
}

# Records the stable acceptance fields for one P3 execution.
function New-UpvrP3AcceptanceRecord {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$SourceResult
    )

    return [pscustomobject][ordered]@{
        unityVersion=$Configuration.unityVersion; testFrameworkVersion=$Configuration.testFrameworkVersion
        scriptingBackend=$Backend; caseName=$CaseName; expectedStatus=$ExpectedStatus; finalStatus=$Result.finalStatus
        resultPath=$Result.artifacts.resultPath; buildReceiptPath=$Result.artifacts.buildReceiptPath
        scenarioReceiptPath=$Result.artifacts.scenarioReceiptPath; playerExitCode=$Result.playerProcess.exitCode
        playerTimedOut=$Result.playerProcess.timedOut; playerElapsedMilliseconds=$Result.playerProcess.elapsedMilliseconds
        playerJobObjectCreated=$Result.processControl.standaloneRun.jobObjectCreated
        playerAssignedToJob=$Result.processControl.standaloneRun.processAssignedToJob
        playerRootProcessExited=$Result.processControl.standaloneRun.rootProcessExited
        playerProcessTreeExitVerified=$Result.processControl.standaloneRun.processTreeExitVerified
        playerActiveProcessCountAfterWait=$Result.processControl.standaloneRun.activeProcessCountAfterWait
        buildTreeSha256=$SourceResult.build.tree.treeSha256; executableSha256=$SourceResult.build.executableSha256
        unityExecutableSha256=$SourceResult.unity.executableSha256
        windowsModuleTreeSha256=$SourceResult.compatibility.windowsStandaloneModule.treeSha256
        toolchainIdentitySha256=$SourceResult.compatibility.toolchain.identitySha256
        toolchainProfileId=$SourceResult.compatibility.toolchain.selectedProfileId
        buildToolchainIdentityAlgorithm=$(if ($Backend -eq 'IL2CPP') { $SourceResult.compatibility.toolchain.buildToolchainIdentity.algorithm } else { $null })
        buildToolchainIdentitySha256=$(if ($Backend -eq 'IL2CPP') { $SourceResult.compatibility.toolchain.buildToolchainIdentity.identitySha256 } else { $null })
        hostEnvironmentIdentityAlgorithm=$(if ($Backend -eq 'IL2CPP') { $SourceResult.compatibility.toolchain.hostEnvironmentIdentity.algorithm } else { $null })
        hostEnvironmentIdentitySha256=$(if ($Backend -eq 'IL2CPP') { $SourceResult.compatibility.toolchain.hostEnvironmentIdentity.identitySha256 } else { $null })
        buildIdentityUnchanged=$SourceResult.compatibility.toolchain.buildIdentityUnchanged
        hostIdentityUnchanged=$SourceResult.compatibility.toolchain.hostIdentityUnchanged
        beeObservationAccepted=$SourceResult.compatibility.toolchain.beeObservation.accepted
        beeEvidencePath=$SourceResult.artifacts.beeToolchainEvidencePath
        visualStudioVersion=$SourceResult.compatibility.toolchain.visualStudioVersion
        msvcVersion=$SourceResult.compatibility.toolchain.msvcVersion
        windowsSdkVersion=$SourceResult.compatibility.toolchain.windowsSdkVersion
        toolchainTools=@($SourceResult.compatibility.toolchain.tools)
        scenarioStatus=$Result.verification.scenarioBehavior.status; launchStatus=$Result.verification.standaloneLaunch.status
        prebuiltStatus=$Result.verification.prebuiltIdentity.status; originalIntegrity=$Result.originalProjectIntegrity.status
        gitIntegrity=$Result.gitMetadataIntegrity.status; blockerCodes=@($Result.blockers | ForEach-Object { $_.code })
        failureCodes=@($Result.failures | ForEach-Object { $_.code })
        sourceOriginalIntegrity=$SourceResult.originalProjectIntegrity.status
        sourceGitIntegrity=$SourceResult.gitMetadataIntegrity.status
        sourceBeforeTreeSha256=$SourceResult.originalProjectIntegrity.beforeTreeSha256
        sourceAfterTreeSha256=$SourceResult.originalProjectIntegrity.afterTreeSha256
    }
}

$configurations = @(
    [pscustomobject][ordered]@{ unityVersion='2022.3.62f3'; revision='96770f904ca7'; testFrameworkVersion='1.1.33'; testFrameworkSource='registry'; nunitVersion='1.0.6'; nunitSource='registry'; unityExecutable='C:\Program Files\Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.0.69f1'; revision='5f8607f5118b'; testFrameworkVersion='1.6.0'; testFrameworkSource='builtin'; nunitVersion='2.0.3'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe' },
    [pscustomobject][ordered]@{ unityVersion='6000.5.3f1'; revision='c2eb47b3a2a9'; testFrameworkVersion='1.7.0'; testFrameworkSource='builtin'; nunitVersion='2.1.0'; nunitSource='builtin'; unityExecutable='C:\Program Files\Unity\Hub\Editor\6000.5.3f1\Editor\Unity.exe' }
)
$backends = @('Mono','IL2CPP')
$runtimeCases = @(
    [pscustomobject]@{ name='success'; expectedStatus='PLAYER_VERIFIED'; acceptanceValue=$null },
    [pscustomobject]@{ name='assertion-failure'; expectedStatus='PLAYER_FAILED'; acceptanceValue='assertion-failure' },
    [pscustomobject]@{ name='top-level-exception'; expectedStatus='VERIFICATION_BLOCKED'; acceptanceValue='top-level-exception' },
    [pscustomobject]@{ name='nested-exception'; expectedStatus='PLAYER_FAILED'; acceptanceValue='nested-exception' },
    [pscustomobject]@{ name='nested-wait-timeout'; expectedStatus='VERIFICATION_BLOCKED'; acceptanceValue='nested-wait-timeout' },
    [pscustomobject]@{ name='crash'; expectedStatus='PLAYER_FAILED'; acceptanceValue='crash' },
    [pscustomobject]@{ name='timeout'; expectedStatus='VERIFICATION_BLOCKED'; acceptanceValue='timeout' },
    [pscustomobject]@{ name='opaque-launch'; expectedStatus='PLAYER_LAUNCH_VERIFIED'; acceptanceValue=$null },
    [pscustomobject]@{ name='receipt-mismatch'; expectedStatus='VERIFICATION_BLOCKED'; acceptanceValue=$null }
)
$il2cppSelected = $null -eq $ScriptingBackends -or $ScriptingBackends.Count -eq 0 -or 'IL2CPP' -in $ScriptingBackends
if ($il2cppSelected -and -not [string]::IsNullOrWhiteSpace($CandidateProfilePath)) {
    Initialize-UpvrP3CandidateAcceptanceRunner -Path $CandidateProfilePath
}
$bundlePath = New-UpvrP3AcceptanceBundle
$bundleBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $bundlePath
$results = New-Object System.Collections.ArrayList
$previousAcceptanceCase = [Environment]::GetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', 'Process')
try {
    foreach ($configuration in $configurations) {
        if ($null -ne $UnityVersions -and $UnityVersions.Count -gt 0 -and $configuration.unityVersion -notin $UnityVersions) { continue }
        if (-not (Test-Path -LiteralPath $configuration.unityExecutable -PathType Leaf)) { throw "Required Unity editor is missing: $($configuration.unityExecutable)" }
        $projectRoot = New-UpvrP3AcceptanceProject -Configuration $configuration
        $projectBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $projectRoot
        foreach ($backend in $backends) {
            if ($null -ne $ScriptingBackends -and $ScriptingBackends.Count -gt 0 -and $backend -notin $ScriptingBackends) { continue }
            [Environment]::SetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', $null, 'Process')
            $buildArtifactRoot = Join-Path $script:AcceptanceRoot ("runs\$($configuration.unityVersion)\$backend\success")
            $buildArguments = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,
                '-Mode','INSTRUMENTED_STANDALONE','-ProjectRoot',$projectRoot,'-UnityExecutable',$configuration.unityExecutable,
                '-ArtifactsRoot',$buildArtifactRoot,'-BuildTimeoutSeconds',$BuildTimeoutSeconds,'-RunTimeoutSeconds',$RunTimeoutSeconds,
                '-ScenarioBundlePath',$bundlePath,'-ScriptingBackend',$backend
            )
            if ($backend -eq 'IL2CPP' -and -not [string]::IsNullOrWhiteSpace($script:AcceptanceToolchainProfileId)) {
                $buildArguments += @('-ToolchainProfileId',$script:AcceptanceToolchainProfileId,'-VisualStudioPath',$script:AcceptanceVisualStudioPath)
            }
            Write-Host "Starting real Unity P3 build and success run: $($configuration.unityVersion)/$backend"
            $buildResult = Invoke-UpvrP3Runner -Arguments $buildArguments -ExpectedStatus 'PLAYER_VERIFIED' -CaseLabel "$($configuration.unityVersion)/$backend/success"
            if ($buildResult.originalProjectIntegrity.status -cne 'UNCHANGED' -or $buildResult.gitMetadataIntegrity.status -notin @('UNCHANGED','NOT_PRESENT')) { throw "P3 source integrity failed for $($configuration.unityVersion)/$backend." }
            Assert-UpvrP3ProcessCleanupEvidence -Result $buildResult -CaseLabel "$($configuration.unityVersion)/$backend/success"
            if ($null -eq $CaseNames -or $CaseNames.Count -eq 0 -or 'success' -in $CaseNames) { [void]$results.Add((New-UpvrP3AcceptanceRecord $configuration $backend 'success' 'PLAYER_VERIFIED' $buildResult $buildResult)) }

            $buildRoot = Split-Path -Parent ([string]$buildResult.build.executablePath)
            $playerExecutable = [string]$buildResult.build.executablePath
            $buildReceipt = [string]$buildResult.artifacts.buildReceiptPath
            foreach ($case in @($runtimeCases | Where-Object { $_.name -ne 'success' })) {
                if ($null -ne $CaseNames -and $CaseNames.Count -gt 0 -and $case.name -notin $CaseNames) { continue }
                $caseArtifactRoot = Join-Path $script:AcceptanceRoot ("runs\$($configuration.unityVersion)\$backend\$($case.name)")
                if ($case.name -eq 'opaque-launch') {
                    [Environment]::SetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', $null, 'Process')
                    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,'-Mode','PREBUILT_STANDALONE','-BuildRoot',$buildRoot,'-PlayerExecutable',$playerExecutable,'-ArtifactsRoot',$caseArtifactRoot,'-RunTimeoutSeconds',$RunTimeoutSeconds)
                } elseif ($case.name -eq 'receipt-mismatch') {
                    [Environment]::SetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', $null, 'Process')
                    $tamperPath = Join-Path $buildRoot '__upvr_acceptance_tamper.txt'
                    Write-UpvrP3AcceptanceText -Path $tamperPath -Content 'intentional post-build mutation'
                    try {
                        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,'-Mode','PREBUILT_STANDALONE','-BuildRoot',$buildRoot,'-PlayerExecutable',$playerExecutable,'-BuildReceiptPath',$buildReceipt,'-ArtifactsRoot',$caseArtifactRoot,'-RunTimeoutSeconds',$RunTimeoutSeconds)
                        $caseResult = Invoke-UpvrP3Runner -Arguments $arguments -ExpectedStatus $case.expectedStatus -CaseLabel "$($configuration.unityVersion)/$backend/$($case.name)"
                    } finally {
                        if (Test-Path -LiteralPath $tamperPath -PathType Leaf) { [System.IO.File]::Delete($tamperPath) }
                    }
                    if ([bool]$caseResult.processControl.standaloneRun.processStarted) { throw 'Receipt mismatch must be rejected before the Player starts.' }
                    [void]$results.Add((New-UpvrP3AcceptanceRecord $configuration $backend $case.name $case.expectedStatus $caseResult $buildResult))
                    continue
                } else {
                    [Environment]::SetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', [string]$case.acceptanceValue, 'Process')
                    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:RunnerPath,'-Mode','PREBUILT_STANDALONE','-BuildRoot',$buildRoot,'-PlayerExecutable',$playerExecutable,'-BuildReceiptPath',$buildReceipt,'-ArtifactsRoot',$caseArtifactRoot,'-RunTimeoutSeconds',$RunTimeoutSeconds)
                }
                Write-Host "Starting real Unity P3 prebuilt run: $($configuration.unityVersion)/$backend/$($case.name)"
                $caseResult = Invoke-UpvrP3Runner -Arguments $arguments -ExpectedStatus $case.expectedStatus -CaseLabel "$($configuration.unityVersion)/$backend/$($case.name)"
                Assert-UpvrP3CoroutineFailureEvidence -Result $caseResult -CaseName $case.name -ExternalTimeoutSeconds $RunTimeoutSeconds
                Assert-UpvrP3ProcessCleanupEvidence -Result $caseResult -CaseLabel "$($configuration.unityVersion)/$backend/$($case.name)"
                [void]$results.Add((New-UpvrP3AcceptanceRecord $configuration $backend $case.name $case.expectedStatus $caseResult $buildResult))
            }
        }
        $projectAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $projectRoot
        if ($projectBefore.treeSha256 -cne $projectAfter.treeSha256) { throw "P3 acceptance source project changed for $($configuration.unityVersion)." }
    }
} finally {
    [Environment]::SetEnvironmentVariable('UPVR_P3_ACCEPTANCE_CASE', $previousAcceptanceCase, 'Process')
}

$bundleAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $bundlePath
if ($bundleBefore.treeSha256 -cne $bundleAfter.treeSha256) { throw 'P3 acceptance scenario bundle changed.' }
if ($results.Count -eq 0) { throw 'P3 acceptance filters selected zero recorded cases.' }
$selectedConfigurationCount = @($configurations | Where-Object { $null -eq $UnityVersions -or $UnityVersions.Count -eq 0 -or $_.unityVersion -in $UnityVersions }).Count
$selectedBackendCount = @($backends | Where-Object { $null -eq $ScriptingBackends -or $ScriptingBackends.Count -eq 0 -or $_ -in $ScriptingBackends }).Count
$selectedCaseCount = @($runtimeCases | Where-Object { $null -eq $CaseNames -or $CaseNames.Count -eq 0 -or $_.name -in $CaseNames }).Count
$expectedCount = $selectedConfigurationCount * $selectedBackendCount * $selectedCaseCount
$summary = [ordered]@{
    schemaVersion='1.1.0'; phase='P3'; acceptanceStatus=$(if ($results.Count -eq $expectedCount) { 'APPROVAL_ELIGIBLE' } else { 'INCOMPLETE' })
    generatedAtUtc=[DateTime]::UtcNow.ToString('o'); artifactRoot=$script:AcceptanceRoot
    buildCombinationCount=$selectedConfigurationCount * $selectedBackendCount
    expectedCaseCount=$expectedCount; caseCount=$results.Count; candidateEvidence=$script:CandidateEvidence; results=@($results)
}
$summaryPath = Join-Path $script:AcceptanceRoot 'acceptance-summary.json'
Write-UpvrP3AcceptanceText -Path $summaryPath -Content (ConvertTo-Json $summary -Depth 30)
Write-Host "Unity Player Verification P3 acceptance completed. Status: $($summary.acceptanceStatus); cases: $($summary.caseCount); summary: $summaryPath"
