[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('TEST_PLAYER', 'SCENARIO_TEST_PLAYER', 'INSTRUMENTED_STANDALONE', 'PREBUILT_STANDALONE')]
    [string]$Mode = 'TEST_PLAYER',

    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [AllowNull()]
    [string]$UnityExecutable,

    [Parameter()]
    [AllowNull()]
    [string]$ArtifactsRoot,

    [Parameter()]
    [ValidateRange(1, 86400)]
    [int]$BuildTimeoutSeconds = 3600,

    [Parameter()]
    [ValidateRange(1, 86400)]
    [int]$RunTimeoutSeconds = 600,

    [Parameter()]
    [AllowNull()]
    [string]$TestFilter,

    [Parameter()]
    [AllowNull()]
    [string]$TestCategory,

    [Parameter()]
    [AllowNull()]
    [string]$AssemblyNames,

    [Parameter()]
    [AllowNull()]
    [string]$ScenarioBundlePath,

    [Parameter()]
    [AllowNull()]
    [string]$BuildRoot,

    [Parameter()]
    [AllowNull()]
    [string]$PlayerExecutable,

    [Parameter()]
    [AllowNull()]
    [string]$BuildReceiptPath,

    [Parameter()]
    [ValidateSet('Project', 'Mono', 'IL2CPP')]
    [string]$ScriptingBackend = 'Mono',

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:SchemaVersion = '1.0.0'
$script:ComponentVersion = '0.3.0-rc.1'
$script:VerifierVersion = '0.3.0-rc.1'
$script:ExpectedDoctorSchemaVersion = '1.1.0'
$script:ExpectedDoctorScannerVersion = '0.2.1'
$script:SkillRoot = Split-Path -Parent $PSScriptRoot
$script:VendorRoot = Join-Path $PSScriptRoot 'vendor'
$script:DoctorScannerPath = Join-Path $script:VendorRoot 'doctor\inspect-unity-project.ps1'
$script:FingerprintLibraryPath = Join-Path $script:VendorRoot 'doctor\lib\unity-project-fingerprint.ps1'
$script:SharedRoot = Join-Path $script:VendorRoot 'shared'
$script:OrchestrationLibraryPath = Join-Path $script:SharedRoot 'unity-baseline-orchestration.ps1'
$script:ProcessLibraryPath = Join-Path $script:SharedRoot 'unity-process-job.ps1'
$script:GitIntegrityLibraryPath = Join-Path $script:SharedRoot 'git-metadata-integrity.ps1'
$script:IsolationBudgetLibraryPath = Join-Path $script:SharedRoot 'unity-isolation-path-budget.ps1'
$script:JsonSchemaLibraryPath = Join-Path $script:SharedRoot 'json-schema-validator.ps1'
$script:PlayCoreLibraryPath = Join-Path $PSScriptRoot 'lib\unity-play-verification-core.ps1'
$script:IdentityLibraryPath = Join-Path $PSScriptRoot 'lib\unity-test-framework-identity.ps1'
$script:PlayerCoreLibraryPath = Join-Path $PSScriptRoot 'lib\unity-player-verification-core.ps1'
$script:CompatibilityRegistryPath = Join-Path $script:SkillRoot 'config\unity-player-compatibility.json'
$script:P1InfrastructureRoot = Join-Path $script:SkillRoot 'infrastructure\p1'
$script:P2InfrastructureRoot = Join-Path $script:SkillRoot 'infrastructure\p2'
$script:P3InfrastructureRoot = Join-Path $script:SkillRoot 'infrastructure\p3'
$script:Blockers = New-Object System.Collections.ArrayList
$script:Failures = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
$script:EvidenceSequence = 0
$script:NormalizedProjectRoot = $null
$script:SessionRoot = $null
$script:SessionToken = [guid]::NewGuid().ToString('N')
$script:OriginalFingerprintBefore = $null
$script:GitSnapshotBefore = $null
$script:TestFrameworkProvenance = $null
$script:CompatibilityAssessment = $null
$script:ScenarioAssessment = $null
$script:EffectiveScriptingBackend = $ScriptingBackend
$script:StandaloneBuildReceiptAssessment = $null
$script:PrebuiltIdentityAssessment = $null
$script:PrebuiltTreeBefore = $null

[Console]::OutputEncoding = $script:Utf8NoBom

foreach ($libraryPath in @(
    $script:FingerprintLibraryPath,
    $script:OrchestrationLibraryPath,
    $script:ProcessLibraryPath,
    $script:GitIntegrityLibraryPath,
    $script:IsolationBudgetLibraryPath,
    $script:JsonSchemaLibraryPath,
    $script:PlayCoreLibraryPath,
    $script:IdentityLibraryPath,
    $script:PlayerCoreLibraryPath
)) {
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required Unity Player Verification library was not found: $libraryPath"
    }
    . $libraryPath
}

# Creates one independent empty NUnit summary for the public result.
function New-UpvrEmptyNUnitSummary {
    return [ordered]@{
        exists = $false; byteLength = $null; sha256 = $null; format = $null; rootResult = $null
        total = 0; executed = 0; passed = 0; failed = 0; skipped = 0; inconclusive = 0
        assertions = 0; durationSeconds = $null; failureDetails = @(); classification = 'NOT_ANALYZED'; error = $null
    }
}

# Creates one empty process-control record used independently for Editor build and Player launch phases.
function New-UpvrEmptyProcessControlEvidence {
    return [ordered]@{
        rootProcessId=$null; jobObjectCreated=$false; killOnJobCloseConfigured=$false
        processAssignedToJob=$false; terminationRequested=$false; terminationReason=$null
        terminationApiSucceeded=$null; rootProcessExited=$false; processTreeExitVerified=$false
        activeProcessCountAfterWait=$null; treeExitWaitMilliseconds=0; timeoutPhase=$null
        buildPhaseCompleted=$false; buildElapsedMilliseconds=0; runElapsedMilliseconds=0
        observationCompleted=$false; responsiveObserved=$false; mainWindowHandle=0
        closeMainWindowRequested=$false; closeMainWindowSucceeded=$false
        failureSignalObserved=$false; exitCode=$null; processStarted=$false; controlError=$null
    }
}

# Creates the versioned result shape with all P1-P3 public areas reserved.
function New-UpvrResult {
    return [ordered]@{
        schemaVersion = $script:SchemaVersion
        componentVersion = $script:ComponentVersion
        verifierVersion = $script:VerifierVersion
        input = [ordered]@{
            kind = if ($Mode -eq 'PREBUILT_STANDALONE') { 'PREBUILT' } else { 'UNITY_PROJECT' }
            mode = $Mode
            projectRoot = $null
            buildRoot = $BuildRoot
            playerExecutable = $PlayerExecutable
            buildReceiptPath = $BuildReceiptPath
            scriptingBackend = if ($Mode -eq 'PREBUILT_STANDALONE') { $null } else { $ScriptingBackend }
        }
        doctor = [ordered]@{
            sourcePath = $null; sha256 = $null; schemaVersion = $null; scannerVersion = $null
            projectRoot = $null; finalStatus = $null; warningCount = 0; warnings = @()
            blockedCheckCount = 0; fingerprintMatched = $false; accepted = $false
        }
        compatibility = [ordered]@{
            registryPath = $script:CompatibilityRegistryPath; registrySchemaVersion = $null
            verificationStatus = 'NOT_VERIFIED'; reason = 'Compatibility has not been verified.'
            unityVersion = $null; testFrameworkVersion = $null; testFrameworkSource = $null
            target = 'StandaloneWindows64'; scriptingBackend = if ($Mode -eq 'PREBUILT_STANDALONE') { $null } else { $ScriptingBackend }
            entryFound = $false; entryStatus = $null; minimumPhase = $null; allowedSourceKind = $null
            registryOrigin = $null; unityExecutableSha256 = $null; packageTreeSha256 = $null
            packageHashCanonicalization = $null; windowsModuleTreeSha256 = $null
            moduleHashCanonicalization = $null; toolchainIdentitySha256 = $null
            visualStudioVersion = $null; msvcVersion = $null; windowsSdkVersion = $null
            evidencePath = $null; approved = $false
            provenance = [ordered]@{ accepted = $false; errors = @(); sourceEvidence = @() }
            postRunProvenance = [ordered]@{ accepted = $false; errors = @(); sourceEvidence = @() }
            packageIdentity = [ordered]@{ accepted = $false; errors = @(); treeSha256 = $null; expectedTreeSha256 = $null }
            windowsStandaloneModule = [ordered]@{
                root = $null; exists = $false; fileCount = 0; totalBytes = 0; treeSha256 = $null
                expectedTreeSha256 = $null; canonicalization = $null; monoAvailable = $false
                il2cppAvailable = $false; monoVariationPaths = @(); il2cppVariationPaths = @()
                identityMatched = $false; accepted = $false; error = $null
            }
            toolchain = [ordered]@{
                requested = $Mode -ne 'PREBUILT_STANDALONE' -and $ScriptingBackend -eq 'IL2CPP'; visualStudioVersion = $null; msvcVersion = $null
                windowsSdkVersion = $null; tools = @(); identitySha256 = $null
                expectedVisualStudioVersion = $null; expectedMsvcVersion = $null
                expectedWindowsSdkVersion = $null; expectedIdentitySha256 = $null
                identityMatched = $false; accepted = $false; errors = @()
            }
        }
        unity = [ordered]@{
            executablePath = $null; executableSha256 = $null; fileVersion = $null; productVersion = $null
            detectedExecutableVersion = $null; executableVersionMatched = $false
            signatureStatus = $null; signerSubject = $null; certificateThumbprint = $null; publisherMatched = $false
            resolutionStatus = $null; resolutionSource = $null; candidates = @(); arguments = @()
            commandLineContainsOriginalProject = $null; processStarted = $false; timedOut = $false
            exitCode = $null; elapsedMilliseconds = 0
        }
        selection = [ordered]@{
            testFilter = $TestFilter; testCategory = $TestCategory; assemblyNames = $AssemblyNames
            scenarioBundlePath = $ScenarioBundlePath; scenarioId = $null
        }
        timeouts = [ordered]@{
            buildSeconds = $BuildTimeoutSeconds; runSeconds = $RunTimeoutSeconds
            combinedProcessSeconds = $BuildTimeoutSeconds + $RunTimeoutSeconds
            buildWithinLimit = $null; runWithinLimit = $null; combinedWithinLimit = $null
        }
        preflight = [ordered]@{
            artifactRootOutsideProject = $false; trustedPathsWithoutReparse = $false
            noRunningUnityProcesses = $false; observedUnityProcessIds = @()
            sourceFingerprintStable = $false; localPackagesSafe = $false; isolatedLocalPackagesSafe = $false
        }
        processControl = [ordered]@{
            rootProcessId = $null; jobObjectCreated = $false; killOnJobCloseConfigured = $false
            processAssignedToJob = $false; terminationRequested = $false; terminationReason = $null
            terminationApiSucceeded = $null; rootProcessExited = $false; processTreeExitVerified = $false
            activeProcessCountAfterWait = $null; treeExitWaitMilliseconds = 0; timeoutPhase = $null
            buildPhaseCompleted = $false; buildElapsedMilliseconds = 0; runElapsedMilliseconds = 0
            failureSignalObserved = $false; controlError = $null
            editorBuild = New-UpvrEmptyProcessControlEvidence
            standaloneRun = New-UpvrEmptyProcessControlEvidence
        }
        isolation = [ordered]@{
            artifactsRoot = $null; sessionRoot = $null; projectCopyPath = $null; status = 'NOT_STARTED'
            copiedDirectoryCount = 0; copiedFileCount = 0; excludedTopLevelPaths = [string[]](Get-UnityCopyExcludedTopLevelNames)
            sourceFingerprint = $null; baseCopyFingerprint = $null; baseCopyMatched = $false
            infrastructureInjected = $false; infrastructurePath = $null; infrastructureTreeSha256 = $null
            scenarioOverlayPath = $null; scenarioOverlayTreeSha256 = $null
            postOverlayFingerprint = $null; localPackageReferences = @(); standaloneOverlayTreeSha256 = $null
        }
        build = [ordered]@{
            requested = $Mode -ne 'PREBUILT_STANDALONE'; kind = if ($Mode -match 'TEST_PLAYER$') { 'TEST_PLAYER' } else { 'STANDALONE' }
            target = 'StandaloneWindows64'; scriptingBackend = if ($Mode -eq 'PREBUILT_STANDALONE') { $null } else { $ScriptingBackend }; executablePath = $null
            executableExists = $false; executableSha256 = $null; dataDirectoryPath = $null; dataDirectoryExists = $false
            report = [ordered]@{ exists = $false; accepted = $false; errors = @() }
            tree = [ordered]@{ root = $null; canonicalization = $null; fileCount = 0; directoryCount = 0; totalBytes = 0; treeSha256 = $null; files = @() }
        }
        playerProcess = [ordered]@{
            observedProcessId = $null; runtimeReceiptCompleted = $false; crashObserved = $false
            responsiveObservationSeconds = 0; responsiveObserved = $false; observationCompleted = $false
            closeMainWindowRequested = $false; closeMainWindowSucceeded = $false; exited = $false
            exitCode = $null; timedOut = $false; elapsedMilliseconds = 0
        }
        nunit = [ordered]@{
            playerConnection = New-UpvrEmptyNUnitSummary
            runtime = New-UpvrEmptyNUnitSummary
            agreement = [ordered]@{ comparedProperties = @(); mismatches = @(); accepted = $false }
        }
        editorLog = [ordered]@{
            exists = $false; byteLength = $null; sha256 = $null; detectedUnityVersion = $null
            versionMatched = $false; batchModeObserved = $false; isolatedProjectPathObserved = $false
            testRunnerObserved = $false; compilerErrors = @(); compilerErrorCount = 0
            failureMarkers = @(); missingRequiredMarkers = @(); classification = 'NOT_ANALYZED'
        }
        playerLog = [ordered]@{ exists = $false; byteLength = $null; sha256 = $null; runStartedMarker = $false; runFinishedMarker = $false; standaloneStartedMarker = $false; standaloneFinishedMarker = $false; crashMarkers = @(); classification = 'NOT_ANALYZED' }
        scenario = [ordered]@{
            requested = $Mode -in @('SCENARIO_TEST_PLAYER', 'INSTRUMENTED_STANDALONE')
            schemaVersion = $null; scenarioId = $null; displayName = $null; bundlePath = $ScenarioBundlePath
            kind = $null; bundleTreeSha256 = $null; buildScenes = @(); expectedScenes = @(); expectedAssertionIds = @(); expectedCaptureIds = @()
            timeoutSeconds = $null; graphicsRequired = $null; testFilter = $null; files = @()
            activeScene = $null; assertions = @(); result = $null; receiptAccepted = $false; receiptErrors = @()
        }
        captures = [ordered]@{ requestedIds = @(); artifacts = @(); allPresent = $false; contentJudged = $false }
        buildReceipt = [ordered]@{ requestedPath = $BuildReceiptPath; resolvedPath = $null; exists = $false; sha256 = $null; accepted = $false; errors = @(); identity = $null }
        prebuiltIdentity = [ordered]@{ buildRoot = $BuildRoot; executablePath = $PlayerExecutable; executableSha256 = $null; peValidated = $false; machine = $null; dataDirectoryPath = $null; dataDirectoryExists = $false; signatureStatus = $null; signerSubject = $null; treeSha256 = $null; beforeTreeSha256 = $null; afterTreeSha256 = $null; treeUnchanged = $null; accepted = $false; errors = @() }
        originalProjectIntegrity = [ordered]@{
            scope = 'PLAYER_COPY_SET'; status = 'NOT_VERIFIED'; beforeDirectoryCount = $null; afterDirectoryCount = $null
            beforeFileCount = $null; afterFileCount = $null; beforeTreeSha256 = $null; afterTreeSha256 = $null; unchanged = $null
        }
        gitMetadataIntegrity = [ordered]@{
            scope = '.git'; status = 'NOT_VERIFIED'; presentBefore = $null; presentAfter = $null
            beforeTreeSha256 = $null; afterTreeSha256 = $null; unchanged = $null; ambientChangesAllowed = $false
            allowedAdditionPrefix = '.git/refs/codex/turn-diffs/checkpoints/'
            addedDirectories = @(); removedDirectories = @(); addedFiles = @(); removedFiles = @(); changedFiles = @()
        }
        verification = [ordered]@{
            scriptCompilation = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No compilation evidence.' }
            windowsPlayerBuild = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No Windows Player build evidence.' }
            testPlayerExecution = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No Test Player runtime receipt.' }
            playerConnection = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No PlayerConnection NUnit result.' }
            playerTests = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No Player test verdict.' }
            scenarioBehavior = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No Player scenario was requested.' }
            visualEvidence = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No capture evidence was requested.' }
            standaloneBuild = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No instrumented Standalone build was requested.' }
            standaloneLaunch = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No Standalone launch was requested.' }
            prebuiltIdentity = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'No prebuilt Player was requested.' }
        }
        artifacts = [ordered]@{
            doctorResultPath = $null; doctorStderrPath = $null; editorLogPath = $null; upmLogPath = $null
            unityStdoutPath = $null; unityStderrPath = $null; playerConnectionResultsPath = $null
            runtimeNUnitPath = $null; runtimeReceiptPath = $null; playerLogPath = $null
            buildReportPath = $null; buildTreePath = $null; scenarioReceiptPath = $null
            scenarioContractPath = $null; standaloneBuildContractPath = $null; buildReceiptPath = $null
            screenshotRoot = $null; playerStdoutPath = $null; playerStderrPath = $null
            resultPath = $null; resultWritten = $false
        }
        verificationScopes = @(
            'scriptCompilation', 'windowsPlayerBuild', 'testPlayerExecution', 'playerConnection', 'playerTests',
            'scenarioBehavior', 'visualEvidence', 'standaloneBuild', 'standaloneLaunch', 'prebuiltIdentity'
        )
        warnings = @(); failures = @(); blockers = @(); finalStatus = 'VERIFICATION_BLOCKED'; evidence = @()
    }
}

$script:Result = New-UpvrResult

# Adds one ordered evidence statement to the result.
function Add-UpvrEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter()][AllowNull()][string]$Source,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $script:EvidenceSequence++
    [void]$script:Evidence.Add([ordered]@{ sequence = $script:EvidenceSequence; check = $Check; status = $Status; source = $Source; detail = $Detail })
}

# Adds one fail-closed prerequisite or evidence blocker.
function Add-UpvrBlocker {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Blockers.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Adds one concrete compilation, build, test, scenario, or crash failure.
function Add-UpvrFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Failures.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Adds one non-blocking diagnostic without changing the verdict.
function Add-UpvrWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Warnings.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Copies the stable Job Object evidence fields into one public process-control record.
function Set-UpvrProcessControlRecord {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Destination,
        [Parameter(Mandatory = $true)][object]$Process
    )

    foreach ($property in @(
        'rootProcessId','jobObjectCreated','killOnJobCloseConfigured','processAssignedToJob',
        'terminationRequested','terminationReason','terminationApiSucceeded','rootProcessExited',
        'processTreeExitVerified','activeProcessCountAfterWait','treeExitWaitMilliseconds','timeoutPhase',
        'buildPhaseCompleted','buildElapsedMilliseconds','runElapsedMilliseconds','observationCompleted',
        'responsiveObserved','mainWindowHandle','closeMainWindowRequested','closeMainWindowSucceeded',
        'failureSignalObserved','exitCode','processStarted','controlError'
    )) {
        if ($Process.PSObject.Properties.Name -contains $property) { $Destination[$property] = $Process.$property }
    }
}

# Writes one UTF-8 artifact without a byte-order mark or reparse traversal.
function Write-UpvrText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $reparse = Get-UpvReparsePointOnPath -Path $Path
    if ($null -ne $reparse) { throw "Refusing to write through reparse point $reparse." }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Creates one external artifact session and fixes every mutable output path.
function Initialize-UpvrArtifactSession {
    param([Parameter(Mandatory = $true)][string]$RequestedRoot)

    $root = Get-UpvNormalizedPath -Path $RequestedRoot
    if ($null -ne $script:NormalizedProjectRoot -and (Test-UpvPathWithinRoot -Path $root -Root $script:NormalizedProjectRoot)) {
        throw 'ArtifactsRoot must be outside the source Unity project.'
    }
    if ($Mode -eq 'PREBUILT_STANDALONE' -and -not [string]::IsNullOrWhiteSpace($BuildRoot)) {
        $normalizedBuildRoot = Get-UpvNormalizedPath -Path $BuildRoot
        if ((Test-UpvPathWithinRoot -Path $root -Root $normalizedBuildRoot) -or $root.Equals($normalizedBuildRoot, $script:UpvPathComparison)) {
            throw 'ArtifactsRoot must be outside the prebuilt build tree.'
        }
    }
    $reparse = Get-UpvReparsePointOnPath -Path $root
    if ($null -ne $reparse) { throw "ArtifactsRoot traverses reparse point $reparse." }
    if (Test-Path -LiteralPath $root -PathType Leaf) { throw 'ArtifactsRoot is an existing file.' }
    [void][System.IO.Directory]::CreateDirectory($root)
    $script:SessionRoot = Get-UpvNormalizedPath -Path (Join-Path $root ('s-' + [guid]::NewGuid().ToString('N')))
    [void][System.IO.Directory]::CreateDirectory($script:SessionRoot)

    $script:Result.preflight.artifactRootOutsideProject = $true
    $script:Result.preflight.trustedPathsWithoutReparse = $true
    $script:Result.isolation.artifactsRoot = $root
    $script:Result.isolation.sessionRoot = $script:SessionRoot
    $script:Result.isolation.projectCopyPath = Join-Path $script:SessionRoot 'p'
    $buildExecutableName = if ($Mode -eq 'INSTRUMENTED_STANDALONE') { 'InstrumentedPlayer.exe' } elseif ($Mode -eq 'PREBUILT_STANDALONE') { [System.IO.Path]::GetFileName($PlayerExecutable) } else { 'TestPlayer.exe' }
    $script:Result.build.executablePath = if ($Mode -eq 'PREBUILT_STANDALONE') { $PlayerExecutable } else { Join-Path $script:SessionRoot (Join-Path 'build' $buildExecutableName) }
    $script:Result.build.dataDirectoryPath = if ($Mode -eq 'PREBUILT_STANDALONE') { Join-Path $BuildRoot (([System.IO.Path]::GetFileNameWithoutExtension($PlayerExecutable)) + '_Data') } else { Join-Path $script:SessionRoot (Join-Path 'build' (([System.IO.Path]::GetFileNameWithoutExtension($buildExecutableName)) + '_Data')) }
    $script:Result.artifacts.doctorResultPath = Join-Path $script:SessionRoot 'doctor.json'
    $script:Result.artifacts.doctorStderrPath = Join-Path $script:SessionRoot 'doctor-stderr.log'
    $script:Result.artifacts.editorLogPath = Join-Path $script:SessionRoot 'Editor.log'
    $script:Result.artifacts.upmLogPath = Join-Path $script:SessionRoot 'upm.log'
    $script:Result.artifacts.unityStdoutPath = Join-Path $script:SessionRoot 'unity-stdout.log'
    $script:Result.artifacts.unityStderrPath = Join-Path $script:SessionRoot 'unity-stderr.log'
    $script:Result.artifacts.playerConnectionResultsPath = Join-Path $script:SessionRoot 'playerconnection-results.xml'
    $script:Result.artifacts.runtimeNUnitPath = Join-Path $script:SessionRoot 'runtime-nunit.xml'
    $script:Result.artifacts.runtimeReceiptPath = Join-Path $script:SessionRoot 'runtime-test-receipt.json'
    $script:Result.artifacts.playerLogPath = Join-Path $script:SessionRoot 'player-runtime.log'
    $script:Result.artifacts.buildReportPath = Join-Path $script:SessionRoot 'build-report.json'
    $script:Result.artifacts.buildTreePath = Join-Path $script:SessionRoot 'build-tree.json'
    $script:Result.artifacts.scenarioReceiptPath = Join-Path $script:SessionRoot 'scenario-result.json'
    $script:Result.artifacts.scenarioContractPath = Join-Path $script:SessionRoot 'scenario-contract.json'
    $script:Result.artifacts.standaloneBuildContractPath = Join-Path $script:SessionRoot 'standalone-build-contract.json'
    $script:Result.artifacts.buildReceiptPath = Join-Path $script:SessionRoot 'build-receipt.json'
    $script:Result.artifacts.screenshotRoot = Join-Path $script:SessionRoot 'screenshots'
    $script:Result.artifacts.playerStdoutPath = Join-Path $script:SessionRoot 'player-stdout.log'
    $script:Result.artifacts.playerStderrPath = Join-Path $script:SessionRoot 'player-stderr.log'
    $script:Result.artifacts.resultPath = Join-Path $script:SessionRoot 'result.json'
    Add-UpvrEvidence -Check 'artifactBoundary' -Status 'PASSED' -Source $script:SessionRoot -Detail 'All mutable project copies, builds, logs, receipts, and results are under one external non-reparse session.'
}

# Captures stable source-content and Git metadata evidence before Unity starts.
function Initialize-UpvrOriginalIntegrity {
    try {
        $script:OriginalFingerprintBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.preflight.sourceFingerprintStable = $true
        $script:Result.isolation.sourceFingerprint = $script:OriginalFingerprintBefore.treeSha256
        $script:Result.originalProjectIntegrity.beforeDirectoryCount = $script:OriginalFingerprintBefore.directoryCount
        $script:Result.originalProjectIntegrity.beforeFileCount = $script:OriginalFingerprintBefore.fileCount
        $script:Result.originalProjectIntegrity.beforeTreeSha256 = $script:OriginalFingerprintBefore.treeSha256
        Add-UpvrEvidence -Check 'sourceFingerprint' -Status 'PASSED' -Source $script:NormalizedProjectRoot -Detail "Stable source copy-set fingerprint $($script:OriginalFingerprintBefore.treeSha256) was captured."
    } catch {
        Add-UpvrBlocker -Code 'SOURCE_FINGERPRINT_BLOCKED' -Check 'sourceFingerprint' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
    try {
        $script:GitSnapshotBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.gitMetadataIntegrity.presentBefore = [bool]$script:GitSnapshotBefore.present
        $script:Result.gitMetadataIntegrity.beforeTreeSha256 = [string]$script:GitSnapshotBefore.treeSha256
    } catch {
        Add-UpvrBlocker -Code 'GIT_METADATA_SNAPSHOT_BLOCKED' -Check 'gitMetadataIntegrity' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
}

# Runs the pinned Doctor and validates its exact schema, version, status, and fingerprint handoff.
function Invoke-UpvrDoctorPreflight {
    try {
        $process = Invoke-OrchestrationPowerShellScript -ScriptPath $script:DoctorScannerPath -Arguments @('-ProjectRoot', $script:NormalizedProjectRoot) -WorkingDirectory $script:SkillRoot
        Write-UpvrText -Path $script:Result.artifacts.doctorStderrPath -Content ([string]$process.stderr)
        if ([int]$process.exitCode -ne 0) { throw "Doctor scanner exited with code $($process.exitCode)." }
        $stdout = ([string]$process.stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw 'Doctor scanner produced empty stdout.' }
        $doctor = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop
        Write-UpvrText -Path $script:Result.artifacts.doctorResultPath -Content $stdout
        $script:Result.doctor.sourcePath = $script:Result.artifacts.doctorResultPath
        $script:Result.doctor.sha256 = Get-UpvFileSha256 -Path $script:Result.artifacts.doctorResultPath
        $script:Result.doctor.schemaVersion = [string](Get-UpvJsonProperty $doctor 'schemaVersion')
        $script:Result.doctor.scannerVersion = [string](Get-UpvJsonProperty $doctor 'scannerVersion')
        $script:Result.doctor.projectRoot = [string](Get-UpvJsonProperty $doctor 'projectRoot')
        $script:Result.doctor.finalStatus = [string](Get-UpvJsonProperty $doctor 'finalStatus')
        $script:Result.doctor.warnings = @((Get-UpvJsonProperty $doctor 'warnings'))
        $script:Result.doctor.warningCount = $script:Result.doctor.warnings.Count
        $blockedChecks = @((Get-UpvJsonProperty $doctor 'blockedChecks'))
        $script:Result.doctor.blockedCheckCount = $blockedChecks.Count
        if ($script:Result.doctor.schemaVersion -cne $script:ExpectedDoctorSchemaVersion) { throw "Doctor schemaVersion must be $($script:ExpectedDoctorSchemaVersion)." }
        if ($script:Result.doctor.scannerVersion -cne $script:ExpectedDoctorScannerVersion) { throw "Doctor scannerVersion must be $($script:ExpectedDoctorScannerVersion)." }
        if (-not (Get-UpvNormalizedPath $script:Result.doctor.projectRoot).Equals($script:NormalizedProjectRoot, $script:UpvPathComparison)) { throw 'Doctor projectRoot does not match.' }
        if ($script:Result.doctor.finalStatus -notin @('STATIC_AUDIT_COMPLETE', 'STATIC_AUDIT_COMPLETE_WITH_WARNINGS')) { throw "Doctor finalStatus is not accepted: $($script:Result.doctor.finalStatus)" }
        if ($blockedChecks.Count -ne 0) { throw 'Doctor reported one or more blocked checks.' }
        $fingerprint = Get-UpvJsonProperty $doctor 'projectFingerprint'
        $script:Result.doctor.fingerprintMatched = [string](Get-UpvJsonProperty $fingerprint 'treeSha256') -ceq [string]$script:OriginalFingerprintBefore.treeSha256
        if (-not $script:Result.doctor.fingerprintMatched) { throw 'Doctor fingerprint does not match the fresh verifier fingerprint.' }
        $versionContainer = Get-UpvJsonProperty $doctor 'unityEditorVersion'
        $script:Result.compatibility.unityVersion = [string](Get-UpvJsonProperty $versionContainer 'editorVersion')
        if ([string]::IsNullOrWhiteSpace($script:Result.compatibility.unityVersion)) { throw 'Doctor did not parse the project Unity version.' }
        $script:Result.doctor.accepted = $true
        Add-UpvrEvidence -Check 'doctor' -Status 'PASSED' -Source $script:Result.artifacts.doctorResultPath -Detail 'Pinned Doctor 0.2.1 evidence matches the fresh source fingerprint.'
    } catch {
        Add-UpvrBlocker -Code 'DOCTOR_PREFLIGHT_REJECTED' -Check 'doctor' -Path $script:Result.artifacts.doctorResultPath -Message $_.Exception.Message
    }
}

# Rejects dynamic execution while any Unity editor process is already running.
function Test-UpvrNoRunningUnityProcesses {
    try {
        $processes = @(Get-Process -Name Unity -ErrorAction SilentlyContinue | Sort-Object -Property Id)
        $script:Result.preflight.observedUnityProcessIds = [int[]]@($processes | ForEach-Object { $_.Id })
        $script:Result.preflight.noRunningUnityProcesses = $processes.Count -eq 0
        if ($processes.Count -ne 0) {
            throw "Running Unity process IDs were observed: $([string]::Join(', ', [string[]]$script:Result.preflight.observedUnityProcessIds))."
        }
        Add-UpvrEvidence -Check 'unityProcessPreflight' -Status 'PASSED' -Source $script:NormalizedProjectRoot -Detail 'No pre-existing Unity.exe process can conflict with the isolated build.'
    } catch {
        Add-UpvrBlocker -Code 'UNITY_PROCESS_PREFLIGHT_REJECTED' -Check 'unityProcessPreflight' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
}

# Validates project-relative local package references without following paths outside the copy-set.
function Get-UpvrLocalPackageAssessment {
    param([Parameter(Mandatory = $true)][string]$Root)

    $errors = New-Object System.Collections.ArrayList
    $references = New-Object System.Collections.ArrayList
    try {
        $manifestPath = Join-Path $Root 'Packages\manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Packages/manifest.json is missing.' }
        $manifest = Read-UpvJsonFile -Path $manifestPath
        $dependencies = Get-UpvJsonProperty $manifest 'dependencies'
        foreach ($property in @($dependencies.PSObject.Properties)) {
            $reference = [string]$property.Value
            if (-not $reference.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $raw = $reference.Substring(5)
            for ($pass = 0; $pass -lt 4; $pass++) {
                $decoded = [System.Uri]::UnescapeDataString($raw)
                if ($decoded -eq $raw) { break }
                $raw = $decoded
            }
            $windowsPath = $raw.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($windowsPath) -or [System.IO.Path]::IsPathRooted($windowsPath) -or $windowsPath -match '^[^\\]+:') {
                throw "Local package $($property.Name) uses an unsafe path: $reference"
            }
            $resolved = Get-UpvNormalizedPath -Path (Join-Path (Split-Path -Parent $manifestPath) $windowsPath)
            if (-not (Test-UpvPathWithinRoot -Path $resolved -Root $Root)) { throw "Local package $($property.Name) escapes the project." }
            $relative = $resolved.Substring((Get-UpvNormalizedPath $Root).Length + 1).Replace('\', '/')
            if (Test-UnityCopyExcludedRelativePath -RelativePath $relative) { throw "Local package $($property.Name) resolves into excluded path $relative." }
            if ($null -ne (Get-UpvReparsePointOnPath $resolved)) { throw "Local package $($property.Name) traverses a reparse point." }
            if (-not (Test-Path -LiteralPath $resolved)) { throw "Local package $($property.Name) does not exist at $relative." }
            [void]$references.Add([ordered]@{ packageName = [string]$property.Name; reference = $reference; relativePath = $relative })
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    return [pscustomobject][ordered]@{ accepted = $errors.Count -eq 0; references = @($references); errors = @($errors) }
}

# Marks the exact compatibility contract blocked with one stable reason.
function Set-UpvrCompatibilityBlocked {
    param([Parameter(Mandatory = $true)][string]$Reason)

    $script:Result.compatibility.verificationStatus = 'BLOCKED'
    $script:Result.compatibility.reason = $Reason
}

# Resolves the effective Standalone backend before compatibility approval is evaluated.
function Resolve-UpvrEffectiveScriptingBackend {
    try {
        $script:EffectiveScriptingBackend = if ($Mode -eq 'INSTRUMENTED_STANDALONE' -and $ScriptingBackend -ceq 'Project') {
            $assessment = Get-UpvrProjectScriptingBackendAssessment -ProjectRoot $script:NormalizedProjectRoot
            if (-not $assessment.accepted) { throw $assessment.error }
            Add-UpvrEvidence -Check 'projectScriptingBackend' -Status 'PASSED' -Source $assessment.path -Detail "Serialized Standalone backend resolves to $($assessment.backend)."
            [string]$assessment.backend
        } else {
            [string]$ScriptingBackend
        }
        $script:Result.compatibility.scriptingBackend = $script:EffectiveScriptingBackend
        $script:Result.compatibility.toolchain.requested = $script:EffectiveScriptingBackend -ceq 'IL2CPP'
    } catch {
        Set-UpvrCompatibilityBlocked -Reason $_.Exception.Message
        Add-UpvrBlocker -Code 'PROJECT_BACKEND_REJECTED' -Check 'scriptingBackend' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
}

# Verifies Test Framework provenance, exact signed Unity, and the Windows Support module.
function Test-UpvrCompatibilityAndEditor {
    try {
        $unityVersion = [string]$script:Result.compatibility.unityVersion
        if ([string]::IsNullOrWhiteSpace($unityVersion)) { throw 'The project Unity version is unavailable.' }

        $script:TestFrameworkProvenance = Get-UpvTestFrameworkProvenanceAssessment -ProjectRoot $script:NormalizedProjectRoot
        foreach ($property in $script:TestFrameworkProvenance.PSObject.Properties.Name) {
            $script:Result.compatibility.provenance[$property] = $script:TestFrameworkProvenance.$property
        }
        $script:Result.compatibility.testFrameworkVersion = [string]$script:TestFrameworkProvenance.resolvedVersion
        $script:Result.compatibility.testFrameworkSource = [string]$script:TestFrameworkProvenance.packagesLockSource
        if (-not $script:TestFrameworkProvenance.accepted) {
            throw ([string]::Join(' ', [string[]]@($script:TestFrameworkProvenance.errors)))
        }

        $script:CompatibilityAssessment = Get-UpvrCompatibilityAssessment `
            -RegistryPath $script:CompatibilityRegistryPath `
            -UnityVersion $unityVersion `
            -TestFrameworkVersion ([string]$script:TestFrameworkProvenance.resolvedVersion) `
            -ScriptingBackend $script:EffectiveScriptingBackend
        foreach ($property in @(
            'registrySchemaVersion', 'target', 'scriptingBackend', 'entryFound', 'entryStatus', 'minimumPhase',
            'allowedSourceKind', 'registryOrigin', 'unityExecutableSha256', 'packageTreeSha256',
            'packageHashCanonicalization', 'windowsModuleTreeSha256', 'moduleHashCanonicalization',
            'toolchainIdentitySha256', 'visualStudioVersion', 'msvcVersion', 'windowsSdkVersion',
            'evidencePath', 'approved'
        )) {
            $script:Result.compatibility[$property] = $script:CompatibilityAssessment.$property
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:CompatibilityAssessment.error)) { throw $script:CompatibilityAssessment.error }
        if (-not $script:CompatibilityAssessment.entryFound) { throw "Unity $unityVersion, Test Framework $($script:TestFrameworkProvenance.resolvedVersion), StandaloneWindows64, and $($script:EffectiveScriptingBackend) are not registered." }
        if (-not $script:CompatibilityAssessment.approved) { throw "The exact Player compatibility tuple is $($script:CompatibilityAssessment.entryStatus), not APPROVED." }

        $script:TestFrameworkProvenance = Get-UpvTestFrameworkProvenanceAssessment -ProjectRoot $script:NormalizedProjectRoot -AllowedSourceKinds ([string[]]@($script:CompatibilityAssessment.allowedSourceKind))
        foreach ($property in $script:TestFrameworkProvenance.PSObject.Properties.Name) {
            $script:Result.compatibility.provenance[$property] = $script:TestFrameworkProvenance.$property
        }
        $originMatched = if ($script:CompatibilityAssessment.allowedSourceKind -ceq 'registry') {
            [string]$script:CompatibilityAssessment.registryOrigin -ceq [string]$script:TestFrameworkProvenance.registryOrigin
        } else {
            $null -eq $script:CompatibilityAssessment.registryOrigin -and $null -eq $script:TestFrameworkProvenance.registryOrigin
        }
        if (-not $script:TestFrameworkProvenance.accepted -or -not $originMatched) { throw 'Test Framework provenance does not match the approved source-specific entry.' }

        $resolution = Resolve-OrchestrationUnityExecutable `
            -RequiredVersion $unityVersion `
            -UnityExecutableOverride $UnityExecutable `
            -UnityEditorPath ([Environment]::GetEnvironmentVariable('UNITY_EDITOR_PATH', 'Process')) `
            -UnityHubEditorRoot ([Environment]::GetEnvironmentVariable('UNITY_HUB_EDITOR_ROOT', 'Process')) `
            -ProgramFilesRoot ([Environment]::GetEnvironmentVariable('ProgramFiles', 'Process')) `
            -ProgramFilesX86Root ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)', 'Process'))
        $script:Result.unity.resolutionStatus = $resolution.status
        $script:Result.unity.resolutionSource = $resolution.selectedSource
        $script:Result.unity.candidates = @($resolution.candidates)
        if ([string]::IsNullOrWhiteSpace([string]$resolution.selectedPath)) { throw "Exact Unity $unityVersion was not found." }

        $path = Get-UpvNormalizedPath -Path $resolution.selectedPath
        $script:Result.unity.executablePath = $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [System.IO.Path]::GetFileName($path) -ine 'Unity.exe') { throw 'Selected Unity executable is invalid.' }
        if ($null -ne (Get-UpvReparsePointOnPath $path)) { throw 'Selected Unity path traverses a reparse point.' }
        $item = Get-Item -LiteralPath $path -Force
        $script:Result.unity.executableSha256 = Get-UpvFileSha256 -Path $path
        $script:Result.unity.fileVersion = [string]$item.VersionInfo.FileVersion
        $script:Result.unity.productVersion = [string]$item.VersionInfo.ProductVersion
        $versionMatch = [regex]::Match($script:Result.unity.productVersion, '^(?<version>\d+\.\d+\.\d+[abfp]\d+)(?:_|$|\s)')
        if ($versionMatch.Success) { $script:Result.unity.detectedExecutableVersion = $versionMatch.Groups['version'].Value }
        $script:Result.unity.executableVersionMatched = $versionMatch.Success -and $script:Result.unity.detectedExecutableVersion -ceq $unityVersion
        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        $script:Result.unity.signatureStatus = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) {
            $script:Result.unity.signerSubject = [string]$signature.SignerCertificate.Subject
            $script:Result.unity.certificateThumbprint = [string]$signature.SignerCertificate.Thumbprint
        }
        $script:Result.unity.publisherMatched = $script:Result.unity.signatureStatus -ceq 'Valid' -and [regex]::IsMatch([string]$script:Result.unity.signerSubject, '(?i)\bUnity Technologies\b')
        if (-not $script:Result.unity.executableVersionMatched) { throw 'Unity.exe ProductVersion does not match the project.' }
        if ($script:Result.unity.signatureStatus -cne 'Valid' -or -not $script:Result.unity.publisherMatched) { throw 'Unity.exe does not have a valid Unity Technologies Authenticode signature.' }
        if ($script:Result.unity.executableSha256 -cne $script:CompatibilityAssessment.unityExecutableSha256) { throw 'Unity.exe hash does not match the compatibility entry.' }

        $module = Get-UpvrWindowsStandaloneModuleIdentity -UnityExecutablePath $path
        foreach ($property in @('root', 'exists', 'fileCount', 'totalBytes', 'treeSha256', 'canonicalization', 'monoAvailable', 'il2cppAvailable', 'monoVariationPaths', 'il2cppVariationPaths', 'accepted', 'error')) {
            $script:Result.compatibility.windowsStandaloneModule[$property] = $module.$property
        }
        $script:Result.compatibility.windowsStandaloneModule.expectedTreeSha256 = $script:CompatibilityAssessment.windowsModuleTreeSha256
        $script:Result.compatibility.windowsStandaloneModule.identityMatched = $module.treeSha256 -ceq $script:CompatibilityAssessment.windowsModuleTreeSha256
        if (-not $module.accepted) { throw $module.error }
        if (-not $script:Result.compatibility.windowsStandaloneModule.identityMatched) { throw 'Windows Standalone Support module hash does not match the approved entry.' }
        if ($script:EffectiveScriptingBackend -ceq 'Mono' -and -not $module.monoAvailable) { throw 'The approved Windows Standalone module lacks its Mono variation.' }
        if ($script:EffectiveScriptingBackend -ceq 'IL2CPP' -and -not $module.il2cppAvailable) { throw 'The approved Unity installation lacks IL2CPP support.' }

        if ($script:EffectiveScriptingBackend -ceq 'IL2CPP') {
            $toolchain = Get-UpvrIl2CppToolchainIdentity
            foreach ($property in @('visualStudioVersion','msvcVersion','windowsSdkVersion','tools','identitySha256','accepted','errors')) {
                $script:Result.compatibility.toolchain[$property] = $toolchain.$property
            }
            if (-not $toolchain.accepted) { throw ([string]::Join(' ', [string[]]@($toolchain.errors))) }
            $script:Result.compatibility.toolchain.expectedIdentitySha256 = $script:CompatibilityAssessment.toolchainIdentitySha256
            $script:Result.compatibility.toolchain.expectedVisualStudioVersion = $script:CompatibilityAssessment.visualStudioVersion
            $script:Result.compatibility.toolchain.expectedMsvcVersion = $script:CompatibilityAssessment.msvcVersion
            $script:Result.compatibility.toolchain.expectedWindowsSdkVersion = $script:CompatibilityAssessment.windowsSdkVersion
            $script:Result.compatibility.toolchain.identityMatched = `
                [string]$toolchain.identitySha256 -ceq [string]$script:CompatibilityAssessment.toolchainIdentitySha256 -and `
                [string]$toolchain.visualStudioVersion -ceq [string]$script:CompatibilityAssessment.visualStudioVersion -and `
                [string]$toolchain.msvcVersion -ceq [string]$script:CompatibilityAssessment.msvcVersion -and `
                [string]$toolchain.windowsSdkVersion -ceq [string]$script:CompatibilityAssessment.windowsSdkVersion
            if (-not $script:Result.compatibility.toolchain.identityMatched) { throw 'IL2CPP toolchain identity does not match the approved compatibility entry.' }
            Add-UpvrEvidence -Check 'il2cppToolchain' -Status 'PASSED' -Source $toolchain.visualStudioPath -Detail "IL2CPP toolchain identity SHA-256 $($toolchain.identitySha256) was captured."
        } else {
            $script:Result.compatibility.toolchain.accepted = $true
            $script:Result.compatibility.toolchain.identityMatched = $true
            $script:Result.compatibility.toolchain.errors = @()
        }

        $script:Result.compatibility.reason = 'Signed Unity, Test Framework provenance, and Windows Standalone Support module are accepted; resolved package identity is pending.'
        Add-UpvrEvidence -Check 'compatibilityPreflight' -Status 'PASSED' -Source $script:CompatibilityRegistryPath -Detail "Approved $unityVersion + Test Framework $($script:TestFrameworkProvenance.resolvedVersion) + StandaloneWindows64/$($script:EffectiveScriptingBackend) tuple selected."
        Add-UpvrEvidence -Check 'windowsStandaloneModule' -Status 'PASSED' -Source $module.root -Detail "Module tree SHA-256 $($module.treeSha256) matches the registry."
    } catch {
        Set-UpvrCompatibilityBlocked -Reason $_.Exception.Message
        Add-UpvrBlocker -Code 'PLAYER_COMPATIBILITY_REJECTED' -Check 'compatibility' -Path $script:CompatibilityRegistryPath -Message $_.Exception.Message
    }
}

# Copies the immutable Doctor copy-set and verifies every copied file digest.
function Copy-UpvrProjectToIsolation {
    try {
        if ($null -eq $script:OriginalFingerprintBefore) { throw 'No stable source snapshot is available.' }
        $destination = $script:Result.isolation.projectCopyPath
        $budget = Get-UnityIsolationPathBudgetAssessment -Snapshot $script:OriginalFingerprintBefore.snapshot -Destination $destination
        if (-not $budget.accepted) {
            foreach ($violation in @($budget.violations)) { Add-UpvrBlocker -Code $violation.code -Check $violation.check -Path $violation.path -Message $violation.message }
            return
        }
        [void][System.IO.Directory]::CreateDirectory($destination)
        foreach ($relativeDirectory in @($script:OriginalFingerprintBefore.snapshot.directories)) {
            [void][System.IO.Directory]::CreateDirectory((Get-UnityIsolationDestinationPath -DestinationRoot $destination -RelativePath $relativeDirectory))
            $script:Result.isolation.copiedDirectoryCount++
        }
        foreach ($file in @($script:OriginalFingerprintBefore.snapshot.files)) {
            $sourcePath = Join-Path $script:NormalizedProjectRoot ([string]$file.path).Replace('/', '\')
            $destinationPath = Get-UnityIsolationDestinationPath -DestinationRoot $destination -RelativePath ([string]$file.path)
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath))
            [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
            if ((Get-UpvFileSha256 $destinationPath) -cne [string]$file.sha256) { throw "Copied file hash mismatch: $($file.path)" }
            $script:Result.isolation.copiedFileCount++
        }
        $copyFingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $destination
        $script:Result.isolation.baseCopyFingerprint = $copyFingerprint.treeSha256
        $script:Result.isolation.baseCopyMatched = $copyFingerprint.treeSha256 -ceq $script:OriginalFingerprintBefore.treeSha256
        if (-not $script:Result.isolation.baseCopyMatched) { throw 'Isolated base fingerprint does not match the source.' }
        $script:Result.isolation.status = 'COPIED'
        Add-UpvrEvidence -Check 'isolation' -Status 'PASSED' -Source $destination -Detail 'The external base copy matches the source copy-set byte-for-byte.'
    } catch {
        $script:Result.isolation.status = 'FAILED'
        Add-UpvrBlocker -Code 'ISOLATION_COPY_FAILED' -Check 'isolation' -Path $script:Result.isolation.projectCopyPath -Message $_.Exception.Message
    }
}

# Copies a previously hashed source inventory into one reserved isolated root.
function Copy-UpvrVerifiedInventory {
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    foreach ($file in $Files) {
        $destination = Get-UnityIsolationDestinationPath -DestinationRoot $DestinationRoot -RelativePath ([string]$file.path)
        if ($destination.Length -ge 260) { throw "Infrastructure path exceeds the conservative Windows boundary: $destination" }
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [System.IO.File]::Copy([string]$file.sourcePath, $destination, $false)
        if ((Get-UpvFileSha256 $destination) -cne [string]$file.sha256) { throw "Infrastructure copy hash mismatch: $($file.path)" }
    }
}

# Injects only the pinned P1 Test Player infrastructure into the isolated copy.
function Add-UpvrP1InfrastructureOverlay {
    try {
        $reserved = Get-UpvrReservedInfrastructureAssessment -ProjectCopyPath $script:Result.isolation.projectCopyPath
        if (-not $reserved.accepted) { throw $reserved.error }
        $infrastructure = Get-UpvrInfrastructureFingerprint -InfrastructureRoot $script:P1InfrastructureRoot
        Copy-UpvrVerifiedInventory -Files $infrastructure.files -DestinationRoot $reserved.path
        $script:Result.isolation.infrastructureInjected = $true
        $script:Result.isolation.infrastructurePath = $reserved.path
        $script:Result.isolation.infrastructureTreeSha256 = $infrastructure.treeSha256
        $postOverlay = Get-StableUnityCopySetFingerprint -ProjectRoot $script:Result.isolation.projectCopyPath
        $script:Result.isolation.postOverlayFingerprint = $postOverlay.treeSha256
        $script:Result.isolation.status = 'INFRASTRUCTURE_INJECTED'
        Add-UpvrEvidence -Check 'infrastructureOverlay' -Status 'PASSED' -Source $reserved.path -Detail "Pinned P1 source infrastructure hash $($infrastructure.treeSha256) was injected only into the isolated copy."
    } catch {
        Add-UpvrBlocker -Code 'INFRASTRUCTURE_OVERLAY_REJECTED' -Check 'isolation' -Path $script:P1InfrastructureRoot -Message $_.Exception.Message
    }
}

# Validates the external source-only scenario bundle before any file is copied.
function Initialize-UpvrPlayerScenarioBundle {
    try {
        $assessment = Get-UpvrPlayerScenarioBundleAssessment -BundlePath $ScenarioBundlePath
        if (-not $assessment.accepted) { throw ([string]::Join(' ', [string[]]@($assessment.errors))) }
        if (Test-UpvPathWithinRoot -Path $assessment.root -Root $script:NormalizedProjectRoot) { throw 'ScenarioBundlePath must be outside the original Unity project.' }
        if (Test-UpvPathWithinRoot -Path $assessment.root -Root $script:SessionRoot) { throw 'ScenarioBundlePath cannot be inside the mutable artifact session.' }
        $script:ScenarioAssessment = $assessment
        $script:Result.selection.scenarioId = $assessment.scenarioId
        foreach ($property in @('schemaVersion', 'scenarioId', 'displayName', 'timeoutSeconds', 'expectedScenes', 'expectedAssertionIds', 'expectedCaptureIds', 'graphicsRequired', 'testFilter')) {
            $script:Result.scenario[$property] = $assessment.$property
        }
        $script:Result.scenario.bundlePath = $assessment.root
        $script:Result.scenario.bundleTreeSha256 = $assessment.treeSha256
        $script:Result.scenario.files = @($assessment.files | ForEach-Object { [ordered]@{ path = $_.path; length = $_.length; sha256 = $_.sha256 } })
        $script:Result.captures.requestedIds = [string[]]@($assessment.expectedCaptureIds)
        Add-UpvrEvidence -Check 'scenarioBundle' -Status 'PASSED' -Source $assessment.root -Detail "Source-only Player scenario $($assessment.scenarioId) has immutable tree SHA-256 $($assessment.treeSha256)."
    } catch {
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_BUNDLE_REJECTED' -Check 'scenario' -Path $ScenarioBundlePath -Message $_.Exception.Message
    }
}

# Validates one external source-only Standalone scenario before it reaches an isolated project.
function Initialize-UpvrStandaloneScenarioBundle {
    try {
        $assessment = Get-UpvrStandaloneScenarioBundleAssessment -BundlePath $ScenarioBundlePath
        if (-not $assessment.accepted) { throw ([string]::Join(' ', [string[]]@($assessment.errors))) }
        if (Test-UpvPathWithinRoot -Path $assessment.root -Root $script:NormalizedProjectRoot) { throw 'ScenarioBundlePath must be outside the original Unity project.' }
        if (Test-UpvPathWithinRoot -Path $assessment.root -Root $script:SessionRoot) { throw 'ScenarioBundlePath cannot be inside the mutable artifact session.' }
        $script:ScenarioAssessment = $assessment
        $script:Result.selection.scenarioId = $assessment.scenarioId
        foreach ($property in @('schemaVersion','kind','scenarioId','displayName','timeoutSeconds','buildScenes','expectedScenes','expectedAssertionIds','expectedCaptureIds','graphicsRequired')) {
            $script:Result.scenario[$property] = $assessment.$property
        }
        $script:Result.scenario.bundlePath = $assessment.root
        $script:Result.scenario.bundleTreeSha256 = $assessment.treeSha256
        $script:Result.scenario.files = @($assessment.files | ForEach-Object { [ordered]@{ path=$_.path; length=$_.length; sha256=$_.sha256 } })
        $script:Result.captures.requestedIds = [string[]]@($assessment.expectedCaptureIds)
        Add-UpvrEvidence -Check 'standaloneScenarioBundle' -Status 'PASSED' -Source $assessment.root -Detail "Source-only Standalone scenario $($assessment.scenarioId) has immutable tree SHA-256 $($assessment.treeSha256)."
    } catch {
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_BUNDLE_REJECTED' -Check 'scenario' -Path $ScenarioBundlePath -Message $_.Exception.Message
    }
}

# Injects the pinned Player scenario harness and reviewed bundle only into the isolated reservation.
function Add-UpvrP2ScenarioOverlay {
    try {
        if ($null -eq $script:ScenarioAssessment) { throw 'No validated Player scenario bundle is available.' }
        $reservedPath = [string]$script:Result.isolation.infrastructurePath
        if ([string]::IsNullOrWhiteSpace($reservedPath) -or -not (Test-Path -LiteralPath $reservedPath -PathType Container)) { throw 'P1 infrastructure reservation is unavailable.' }
        $harness = Get-UpvrInfrastructureFingerprint -InfrastructureRoot $script:P2InfrastructureRoot
        Copy-UpvrVerifiedInventory -Files $harness.files -DestinationRoot $reservedPath
        $scenarioPath = Join-Path $reservedPath 'Scenario'
        if (Test-Path -LiteralPath $scenarioPath) { throw 'Reserved Player scenario overlay path already exists.' }
        [void][System.IO.Directory]::CreateDirectory($scenarioPath)
        Copy-UpvrVerifiedInventory -Files $script:ScenarioAssessment.files -DestinationRoot $scenarioPath
        $copiedScenario = Get-UpvrPlayerScenarioBundleAssessment -BundlePath $scenarioPath
        if (-not $copiedScenario.accepted -or $copiedScenario.treeSha256 -cne $script:ScenarioAssessment.treeSha256) { throw 'Copied Player scenario overlay hash does not match the reviewed bundle.' }

        $runtimeContract = [ordered]@{
            schemaVersion = '1.0.0'
            sessionToken = $script:SessionToken
            scenarioId = $script:ScenarioAssessment.scenarioId
            displayName = $script:ScenarioAssessment.displayName
            timeoutSeconds = [int]$script:ScenarioAssessment.timeoutSeconds
            expectedScenes = [string[]]@($script:ScenarioAssessment.expectedScenes)
            expectedAssertionIds = [string[]]@($script:ScenarioAssessment.expectedAssertionIds)
            expectedCaptureIds = [string[]]@($script:ScenarioAssessment.expectedCaptureIds)
            graphicsRequired = [bool]$script:ScenarioAssessment.graphicsRequired
        }
        Write-UpvrText -Path $script:Result.artifacts.scenarioContractPath -Content (ConvertTo-Json $runtimeContract -Depth 10 -Compress)
        $script:Result.isolation.scenarioOverlayPath = $scenarioPath
        $script:Result.isolation.scenarioOverlayTreeSha256 = $copiedScenario.treeSha256
        $script:Result.isolation.infrastructureTreeSha256 = (Get-UpvrTreeSnapshot -Root $reservedPath -ExcludedRelativePrefixes @('Scenario')).treeSha256
        $script:Result.isolation.postOverlayFingerprint = (Get-StableUnityCopySetFingerprint -ProjectRoot $script:Result.isolation.projectCopyPath).treeSha256
        $script:Result.isolation.status = 'SCENARIO_INJECTED'
        Add-UpvrEvidence -Check 'scenarioOverlay' -Status 'PASSED' -Source $scenarioPath -Detail 'The reviewed bundle and pinned P2 harness were injected only after the base-copy fingerprint matched.'
    } catch {
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_OVERLAY_REJECTED' -Check 'scenario' -Path $ScenarioBundlePath -Message $_.Exception.Message
    }
}

# Injects the pinned Standalone harness, builder, bootstrap, linker roots, and reviewed scenario into isolation.
function Add-UpvrP3ScenarioOverlay {
    try {
        if ($null -eq $script:ScenarioAssessment) { throw 'No validated Standalone scenario bundle is available.' }
        $reserved = Get-UpvrReservedInfrastructureAssessment -ProjectCopyPath $script:Result.isolation.projectCopyPath
        if (-not $reserved.accepted) { throw $reserved.error }
        $harness = Get-UpvrInfrastructureFingerprint -InfrastructureRoot (Join-Path $script:P2InfrastructureRoot 'Harness')
        $standalone = Get-UpvrInfrastructureFingerprint -InfrastructureRoot $script:P3InfrastructureRoot
        Copy-UpvrVerifiedInventory -Files $harness.files -DestinationRoot $reserved.path
        Copy-UpvrVerifiedInventory -Files $standalone.files -DestinationRoot $reserved.path

        $scenarioPath = Join-Path $reserved.path 'Scenario'
        [void][System.IO.Directory]::CreateDirectory($scenarioPath)
        Copy-UpvrVerifiedInventory -Files $script:ScenarioAssessment.files -DestinationRoot $scenarioPath
        $copiedScenario = Get-UpvrStandaloneScenarioBundleAssessment -BundlePath $scenarioPath
        if (-not $copiedScenario.accepted -or $copiedScenario.treeSha256 -cne $script:ScenarioAssessment.treeSha256) { throw 'Copied Standalone scenario overlay hash does not match the reviewed bundle.' }

        $linkLines = New-Object System.Collections.Generic.List[string]
        $linkLines.Add('<linker>')
        foreach ($assemblyName in @('UnityPlayerVerification.Harness','UnityPlayerVerification.Standalone') + [string[]]@($script:ScenarioAssessment.assemblyNames)) {
            $linkLines.Add(('  <assembly fullname="{0}" preserve="all" />' -f $assemblyName))
        }
        $linkLines.Add('</linker>')
        Write-UpvrText -Path (Join-Path $reserved.path 'link.xml') -Content ([string]::Join([Environment]::NewLine, $linkLines.ToArray()))

        $runtimeContract = [ordered]@{
            schemaVersion='1.0.0'; sessionToken=$script:SessionToken; scenarioId=$script:ScenarioAssessment.scenarioId
            displayName=$script:ScenarioAssessment.displayName; timeoutSeconds=[int]$script:ScenarioAssessment.timeoutSeconds
            expectedScenes=[string[]]@($script:ScenarioAssessment.expectedScenes)
            expectedAssertionIds=[string[]]@($script:ScenarioAssessment.expectedAssertionIds)
            expectedCaptureIds=[string[]]@($script:ScenarioAssessment.expectedCaptureIds)
            graphicsRequired=[bool]$script:ScenarioAssessment.graphicsRequired
        }
        Write-UpvrText -Path $script:Result.artifacts.scenarioContractPath -Content (ConvertTo-Json $runtimeContract -Depth 10 -Compress)

        $overlay = Get-UpvrStableTreeSnapshot -Root $reserved.path -ExcludedRelativePrefixes @('Scenario')
        $toolchainHash = if ($script:EffectiveScriptingBackend -ceq 'IL2CPP') { [string]$script:Result.compatibility.toolchain.identitySha256 } else { $null }
        $buildContract = [ordered]@{
            schemaVersion='1.0.0'; sessionToken=$script:SessionToken
            originalFingerprint=[string]$script:OriginalFingerprintBefore.treeSha256
            overlayTreeSha256=[string]$overlay.treeSha256
            scenarioBundleTreeSha256=[string]$copiedScenario.treeSha256
            windowsModuleTreeSha256=[string]$script:Result.compatibility.windowsStandaloneModule.treeSha256
            toolchainIdentitySha256=$toolchainHash; requestedBackend=$ScriptingBackend
            scenarioId=$script:ScenarioAssessment.scenarioId; displayName=$script:ScenarioAssessment.displayName
            timeoutSeconds=[int]$script:ScenarioAssessment.timeoutSeconds
            buildScenes=[string[]]@($script:ScenarioAssessment.buildScenes)
            expectedScenes=[string[]]@($script:ScenarioAssessment.expectedScenes)
            expectedAssertionIds=[string[]]@($script:ScenarioAssessment.expectedAssertionIds)
            expectedCaptureIds=[string[]]@($script:ScenarioAssessment.expectedCaptureIds)
            graphicsRequired=[bool]$script:ScenarioAssessment.graphicsRequired
        }
        Write-UpvrText -Path $script:Result.artifacts.standaloneBuildContractPath -Content (ConvertTo-Json $buildContract -Depth 10 -Compress)

        $script:Result.isolation.infrastructureInjected = $true
        $script:Result.isolation.infrastructurePath = $reserved.path
        $script:Result.isolation.infrastructureTreeSha256 = $overlay.treeSha256
        $script:Result.isolation.standaloneOverlayTreeSha256 = $overlay.treeSha256
        $script:Result.isolation.scenarioOverlayPath = $scenarioPath
        $script:Result.isolation.scenarioOverlayTreeSha256 = $copiedScenario.treeSha256
        $script:Result.isolation.postOverlayFingerprint = (Get-StableUnityCopySetFingerprint -ProjectRoot $script:Result.isolation.projectCopyPath).treeSha256
        $script:Result.isolation.status = 'STANDALONE_SCENARIO_INJECTED'
        Add-UpvrEvidence -Check 'standaloneOverlay' -Status 'PASSED' -Source $reserved.path -Detail "Pinned P3 overlay SHA-256 $($overlay.treeSha256) and reviewed scenario SHA-256 $($copiedScenario.treeSha256) were injected only into isolation."
    } catch {
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_OVERLAY_REJECTED' -Check 'scenario' -Path $ScenarioBundlePath -Message $_.Exception.Message
    }
}

# Builds one isolated non-development instrumented Standalone with signed Unity inside a bounded Job Object.
function Invoke-UpvrStandaloneEditorBuild {
    $arguments = New-UpvrStandaloneBuildArguments `
        -ProjectPath $script:Result.isolation.projectCopyPath `
        -EditorLogPath $script:Result.artifacts.editorLogPath `
        -UpmLogPath $script:Result.artifacts.upmLogPath
    $script:Result.unity.arguments = $arguments
    if ($arguments -contains $script:NormalizedProjectRoot) {
        $script:Result.unity.commandLineContainsOriginalProject = $true
        Add-UpvrBlocker -Code 'ORIGINAL_PROJECT_IN_UNITY_ARGUMENTS' -Check 'unityArguments' -Path $script:NormalizedProjectRoot -Message 'Unity build arguments contain the source project.'
        return
    }
    $script:Result.unity.commandLineContainsOriginalProject = $false
    foreach ($required in @('-batchmode','-forgetProjectPath','-executeMethod','-quit','-logFile','-upmLogFile')) {
        if ($arguments -notcontains $required) { Add-UpvrBlocker -Code 'STANDALONE_BUILD_ARGUMENT_MISSING' -Check 'unityArguments' -Path $null -Message "Required Standalone build argument is missing: $required"; return }
    }
    foreach ($forbidden in @('-runTests','-nographics','-accept-apiupdate','-ignorecompilererrors')) {
        if ($arguments -contains $forbidden) { Add-UpvrBlocker -Code 'FORBIDDEN_UNITY_ARGUMENT' -Check 'unityArguments' -Path $null -Message "Forbidden Standalone build argument is present: $forbidden"; return }
    }

    $environment = [ordered]@{
        UPVR_SESSION_ROOT=$script:SessionRoot; UPVR_SESSION_TOKEN=$script:SessionToken
        UPVR_BUILD_EXE_PATH=$script:Result.build.executablePath
        UPVR_BUILD_REPORT_PATH=$script:Result.artifacts.buildReportPath
        UPVR_BUILD_RECEIPT_PATH=$script:Result.artifacts.buildReceiptPath
        UPVR_STANDALONE_BUILD_CONTRACT_PATH=$script:Result.artifacts.standaloneBuildContractPath
    }
    $previous = [ordered]@{}
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], 'Process')
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Invoke-UnityProcessInJob `
            -ExecutablePath $script:Result.unity.executablePath `
            -Arguments $arguments `
            -WorkingDirectory $script:SessionRoot `
            -StandardOutputPath $script:Result.artifacts.unityStdoutPath `
            -StandardErrorPath $script:Result.artifacts.unityStderrPath `
            -TimeoutSeconds $BuildTimeoutSeconds `
            -TreeExitGraceMilliseconds 15000
    } finally {
        $stopwatch.Stop()
        foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    $script:Result.unity.elapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    $script:Result.unity.processStarted = [bool]$process.processStarted
    $script:Result.unity.timedOut = [bool]$process.timedOut
    $script:Result.unity.exitCode = $process.exitCode
    $script:Result.timeouts.buildWithinLimit = -not $process.timedOut -and $stopwatch.Elapsed.TotalSeconds -le $BuildTimeoutSeconds
    Set-UpvrProcessControlRecord -Destination $script:Result.processControl.editorBuild -Process $process
    if ($process.processStarted) { Add-UpvrEvidence -Check 'standaloneEditorBuildProcess' -Status 'OBSERVED' -Source $script:Result.unity.executablePath -Detail 'Signed Unity built only the isolated instrumented Standalone project.' }
    if (-not $process.jobObjectCreated -or -not $process.killOnJobCloseConfigured -or ($process.processStarted -and -not $process.processAssignedToJob)) {
        Add-UpvrBlocker -Code 'STANDALONE_BUILD_JOB_CONTROL_FAILED' -Check 'processControl' -Path $script:Result.unity.executablePath -Message "Editor build Job Object setup failed: $($process.controlError)"
    }
    if ($process.timedOut) { Add-UpvrBlocker -Code 'STANDALONE_BUILD_TIMEOUT' -Check 'timeouts' -Path $script:Result.unity.executablePath -Message 'Instrumented Standalone build exceeded BuildTimeoutSeconds.' }
    if ($process.processStarted -and -not $process.processTreeExitVerified) {
        Add-UpvrBlocker -Code 'STANDALONE_BUILD_TREE_EXIT_UNPROVEN' -Check 'processControl' -Path $script:Result.unity.executablePath -Message 'Editor build Job Object accounting did not reach zero processes.'
    } elseif ($process.processStarted) {
        Add-UpvrEvidence -Check 'standaloneBuildProcessTree' -Status 'PASSED' -Source $script:Result.unity.executablePath -Detail 'Unity Editor build process accounting reached zero active Job Object processes.'
    }
}

# Launches one exact Standalone executable under fixed arguments and bounded Job Object control.
function Invoke-UpvrStandalonePlayer {
    param([Parameter()][switch]$OpaqueObservation)

    $arguments = New-UpvrStandalonePlayerArguments -PlayerLogPath $script:Result.artifacts.playerLogPath
    $environment = [ordered]@{}
    if (-not $OpaqueObservation) {
        $environment = [ordered]@{
            UPVR_SESSION_ROOT=$script:SessionRoot; UPVR_SESSION_TOKEN=$script:SessionToken
            UPVR_SCENARIO_CONTRACT_PATH=$script:Result.artifacts.scenarioContractPath
            UPVR_SCENARIO_RECEIPT_PATH=$script:Result.artifacts.scenarioReceiptPath
            UPVR_SCREENSHOT_ROOT=$script:Result.artifacts.screenshotRoot
        }
    }
    $previous = [ordered]@{}
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], 'Process')
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $invokeArguments = [ordered]@{
            ExecutablePath=$script:Result.build.executablePath; Arguments=$arguments; WorkingDirectory=(Split-Path -Parent $script:Result.build.executablePath)
            StandardOutputPath=$script:Result.artifacts.playerStdoutPath; StandardErrorPath=$script:Result.artifacts.playerStderrPath
            TimeoutSeconds=$RunTimeoutSeconds; FailureSignalPath=$script:Result.artifacts.playerLogPath
            FailureSignalPattern='(?i)(UPVR_ACCEPTANCE_PLAYER_CRASH|Crash!!!|Fatal Error!|UPVR_STANDALONE_RECEIPT_ERROR)'
            TreeExitGraceMilliseconds=15000
        }
        if ($OpaqueObservation) {
            $invokeArguments.ObservationSeconds = 10
            $invokeArguments.CloseMainWindowAfterObservation = $true
        }
        $process = Invoke-UnityProcessInJob @invokeArguments
    } finally {
        $stopwatch.Stop()
        foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    Set-UpvrProcessControlRecord -Destination $script:Result.processControl.standaloneRun -Process $process
    $script:Result.playerProcess.observedProcessId = $process.rootProcessId
    $script:Result.playerProcess.responsiveObservationSeconds = if ($OpaqueObservation -and $process.observationCompleted) { 10 } else { 0 }
    $script:Result.playerProcess.responsiveObserved = [bool]$process.responsiveObserved
    $script:Result.playerProcess.observationCompleted = [bool]$process.observationCompleted
    $script:Result.playerProcess.closeMainWindowRequested = [bool]$process.closeMainWindowRequested
    $script:Result.playerProcess.closeMainWindowSucceeded = [bool]$process.closeMainWindowSucceeded
    $script:Result.playerProcess.exited = [bool]$process.rootProcessExited
    $script:Result.playerProcess.exitCode = $process.exitCode
    $script:Result.playerProcess.timedOut = [bool]$process.timedOut
    $script:Result.playerProcess.elapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    $script:Result.timeouts.runWithinLimit = -not $process.timedOut -and $stopwatch.Elapsed.TotalSeconds -le $RunTimeoutSeconds
    if ($Mode -eq 'INSTRUMENTED_STANDALONE') { $script:Result.timeouts.combinedWithinLimit = [bool]$script:Result.timeouts.buildWithinLimit -and [bool]$script:Result.timeouts.runWithinLimit }

    if ($process.processStarted) { Add-UpvrEvidence -Check 'standalonePlayerProcess' -Status 'OBSERVED' -Source $script:Result.build.executablePath -Detail 'The exact Standalone executable started with only fixed verifier arguments.' }
    if (-not $process.jobObjectCreated -or -not $process.killOnJobCloseConfigured -or ($process.processStarted -and -not $process.processAssignedToJob)) {
        Add-UpvrBlocker -Code 'STANDALONE_PLAYER_JOB_CONTROL_FAILED' -Check 'processControl' -Path $script:Result.build.executablePath -Message "Standalone Player Job Object setup failed: $($process.controlError)"
    }
    if ($process.timedOut) { Add-UpvrBlocker -Code 'STANDALONE_PLAYER_TIMEOUT' -Check 'timeouts' -Path $script:Result.build.executablePath -Message 'Standalone Player exceeded RunTimeoutSeconds.' }
    if ($process.processStarted -and -not $process.processTreeExitVerified) {
        Add-UpvrBlocker -Code 'STANDALONE_PLAYER_TREE_EXIT_UNPROVEN' -Check 'processControl' -Path $script:Result.build.executablePath -Message 'Standalone Player Job Object accounting did not reach zero processes.'
    } elseif ($process.processStarted) {
        Add-UpvrEvidence -Check 'standalonePlayerProcessTree' -Status 'PASSED' -Source $script:Result.build.executablePath -Detail 'Standalone Player process accounting reached zero active Job Object processes.'
    }
}

# Starts signed Unity with a closed Test Player argument and environment contract inside one Job Object.
function Invoke-UpvrUnityTestPlayer {
    $effectiveTestFilter = if ($Mode -eq 'SCENARIO_TEST_PLAYER') { [string]$script:ScenarioAssessment.testFilter } else { $TestFilter }
    $arguments = New-UpvrTestPlayerArguments `
        -ProjectPath $script:Result.isolation.projectCopyPath `
        -TestResultsPath $script:Result.artifacts.playerConnectionResultsPath `
        -EditorLogPath $script:Result.artifacts.editorLogPath `
        -UpmLogPath $script:Result.artifacts.upmLogPath `
        -TestFilter $effectiveTestFilter `
        -TestCategory $TestCategory `
        -AssemblyNames $AssemblyNames
    $script:Result.unity.arguments = $arguments
    if ($arguments -contains $script:NormalizedProjectRoot) {
        $script:Result.unity.commandLineContainsOriginalProject = $true
        Add-UpvrBlocker -Code 'ORIGINAL_PROJECT_IN_UNITY_ARGUMENTS' -Check 'unityArguments' -Path $script:NormalizedProjectRoot -Message 'Unity arguments contain the source project.'
        return
    }
    $script:Result.unity.commandLineContainsOriginalProject = $false
    foreach ($forbidden in @('-quit', '-nographics', '-runSynchronously', '-executeMethod', '-accept-apiupdate', '-ignorecompilererrors')) {
        if ($arguments -contains $forbidden) {
            Add-UpvrBlocker -Code 'FORBIDDEN_UNITY_ARGUMENT' -Check 'unityArguments' -Path $null -Message "Forbidden Unity argument is present: $forbidden"
            return
        }
    }

    $environment = [ordered]@{
        UPVR_SESSION_ROOT = $script:SessionRoot
        UPVR_SESSION_TOKEN = $script:SessionToken
        UPVR_BUILD_EXE_PATH = $script:Result.build.executablePath
        UPVR_BUILD_REPORT_PATH = $script:Result.artifacts.buildReportPath
        UPVR_RUNTIME_NUNIT_PATH = $script:Result.artifacts.runtimeNUnitPath
        UPVR_RUNTIME_RECEIPT_PATH = $script:Result.artifacts.runtimeReceiptPath
        UPVR_RUNTIME_LOG_PATH = $script:Result.artifacts.playerLogPath
        UPVR_MODE = $Mode
    }
    if ($Mode -eq 'SCENARIO_TEST_PLAYER') {
        $environment.UPVR_SCENARIO_CONTRACT_PATH = $script:Result.artifacts.scenarioContractPath
        $environment.UPVR_SCENARIO_RECEIPT_PATH = $script:Result.artifacts.scenarioReceiptPath
        $environment.UPVR_SCREENSHOT_ROOT = $script:Result.artifacts.screenshotRoot
    }
    $previous = [ordered]@{}
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], 'Process')
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Invoke-UnityProcessInJob `
            -ExecutablePath $script:Result.unity.executablePath `
            -Arguments $arguments `
            -WorkingDirectory $script:SessionRoot `
            -StandardOutputPath $script:Result.artifacts.unityStdoutPath `
            -StandardErrorPath $script:Result.artifacts.unityStderrPath `
            -TimeoutSeconds ($BuildTimeoutSeconds + $RunTimeoutSeconds) `
            -BuildCompletionPath $script:Result.artifacts.buildReportPath `
            -BuildTimeoutSeconds $BuildTimeoutSeconds `
            -RunTimeoutSeconds $RunTimeoutSeconds `
            -FailureSignalPath $script:Result.artifacts.playerLogPath `
            -FailureSignalPattern '(?i)(UPVR_ACCEPTANCE_PLAYER_CRASH|Crash!!!|Fatal Error!|UPVR_RUNTIME_RECEIPT_ERROR)' `
            -TreeExitGraceMilliseconds 15000
    } finally {
        $stopwatch.Stop()
        foreach ($name in $environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
    $script:Result.unity.elapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
    $script:Result.timeouts.combinedWithinLimit = $stopwatch.Elapsed.TotalSeconds -le ($BuildTimeoutSeconds + $RunTimeoutSeconds)
    $script:Result.timeouts.buildWithinLimit = [bool]$process.buildPhaseCompleted -and [long]$process.buildElapsedMilliseconds -le ([long]$BuildTimeoutSeconds * 1000)
    $script:Result.timeouts.runWithinLimit = [bool]$process.buildPhaseCompleted -and -not ($process.timedOut -and $process.timeoutPhase -eq 'RUN')
    $script:Result.unity.processStarted = [bool]$process.processStarted
    $script:Result.unity.timedOut = [bool]$process.timedOut
    $script:Result.unity.exitCode = $process.exitCode
    foreach ($property in @(
        'rootProcessId', 'jobObjectCreated', 'killOnJobCloseConfigured', 'processAssignedToJob',
        'terminationRequested', 'terminationReason', 'terminationApiSucceeded', 'rootProcessExited',
        'processTreeExitVerified', 'activeProcessCountAfterWait', 'treeExitWaitMilliseconds', 'timeoutPhase',
        'buildPhaseCompleted', 'buildElapsedMilliseconds', 'runElapsedMilliseconds', 'failureSignalObserved', 'controlError'
    )) {
        $script:Result.processControl[$property] = $process.$property
    }
    if ($process.processStarted) {
        Add-UpvrEvidence -Check 'unityProcess' -Status 'OBSERVED' -Source $script:Result.unity.executablePath -Detail 'Signed Unity started against only the isolated project and inherited the fixed artifact contract.'
    }
    $jobSetupFailed = -not $process.jobObjectCreated -or -not $process.killOnJobCloseConfigured -or ($process.processStarted -and -not $process.processAssignedToJob)
    if ($jobSetupFailed) {
        Add-UpvrBlocker -Code 'UNITY_JOB_OBJECT_CONTROL_FAILED' -Check 'processControl' -Path $script:Result.unity.executablePath -Message "Job Object setup failed: $($process.controlError)"
    }
    if ($process.timedOut) {
        $timeoutCode = if ($process.timeoutPhase -eq 'BUILD') { 'UNITY_PLAYER_BUILD_TIMEOUT' } elseif ($process.timeoutPhase -eq 'RUN') { 'UNITY_PLAYER_RUN_TIMEOUT' } else { 'UNITY_PLAYER_TOTAL_TIMEOUT' }
        Add-UpvrBlocker -Code $timeoutCode -Check 'timeouts' -Path $script:Result.unity.executablePath -Message "Unity Player verification exceeded its $($process.timeoutPhase) phase boundary."
    }
    if ($process.processStarted -and -not $process.processTreeExitVerified) {
        Add-UpvrBlocker -Code 'PLAYER_PROCESS_TREE_EXIT_UNPROVEN' -Check 'processControl' -Path $script:Result.unity.executablePath -Message 'Job Object accounting did not reach zero processes.'
    } elseif ($process.processStarted) {
        Add-UpvrEvidence -Check 'processTree' -Status 'PASSED' -Source $script:Result.unity.executablePath -Detail 'Unity and every assigned Test Player descendant reached zero active Job Object processes.'
    }
}

# Verifies post-run Test Framework provenance and the exact resolved package tree.
function Set-UpvrResolvedTestFrameworkIdentity {
    try {
        $treeExitVerified = if ($Mode -eq 'INSTRUMENTED_STANDALONE') { [bool]$script:Result.processControl.editorBuild.processTreeExitVerified } else { [bool]$script:Result.processControl.processTreeExitVerified }
        if (-not $script:Result.unity.processStarted -or $script:Result.unity.timedOut -or -not $treeExitVerified) {
            throw 'A completed Unity process tree is required before resolved package identity can be trusted.'
        }
        $post = Get-UpvTestFrameworkProvenanceAssessment -ProjectRoot $script:Result.isolation.projectCopyPath -AllowedSourceKinds ([string[]]@($script:CompatibilityAssessment.allowedSourceKind))
        foreach ($property in $post.PSObject.Properties.Name) { $script:Result.compatibility.postRunProvenance[$property] = $post.$property }
        if (-not $post.accepted) { throw ([string]::Join(' ', [string[]]@($post.errors))) }
        foreach ($property in @('declaredVersion', 'resolvedVersion', 'packagesLockSource', 'registryOrigin')) {
            if ([string]$post.$property -cne [string]$script:TestFrameworkProvenance.$property) { throw "Post-run Test Framework provenance changed '$property'." }
        }
        $identity = Get-UpvResolvedTestFrameworkIdentityAssessment `
            -ProjectRoot $script:Result.isolation.projectCopyPath `
            -Provenance $post `
            -ExpectedVersion $script:CompatibilityAssessment.testFrameworkVersion `
            -ExpectedSourceKind $script:CompatibilityAssessment.allowedSourceKind `
            -ExpectedRegistryOrigin $script:CompatibilityAssessment.registryOrigin `
            -ExpectedTreeSha256 $script:CompatibilityAssessment.packageTreeSha256 `
            -ExpectedCanonicalization $script:CompatibilityAssessment.packageHashCanonicalization
        foreach ($property in $identity.PSObject.Properties.Name) { $script:Result.compatibility.packageIdentity[$property] = $identity.$property }
        if (-not $identity.accepted) { throw ([string]::Join(' ', [string[]]@($identity.errors))) }
        $script:Result.compatibility.verificationStatus = 'VERIFIED_SUCCESS'
        $script:Result.compatibility.reason = 'Pre/post provenance, signed Unity, Test Framework package tree, and Windows Standalone module all match the approved tuple.'
        Add-UpvrEvidence -Check 'testFrameworkPackageIdentity' -Status 'PASSED' -Source $identity.resolvedPackagePath -Detail "Resolved package tree SHA-256 $($identity.treeSha256) matches the registry."
    } catch {
        Set-UpvrCompatibilityBlocked -Reason $_.Exception.Message
        Add-UpvrBlocker -Code 'TEST_FRAMEWORK_IDENTITY_REJECTED' -Check 'compatibility' -Path $script:Result.isolation.projectCopyPath -Message $_.Exception.Message
    }
}

# Captures executable, Data directory, and full build-tree identity after every process exits.
function Set-UpvrBuildTreeEvidence {
    try {
        $executable = $script:Result.build.executablePath
        $dataDirectory = $script:Result.build.dataDirectoryPath
        $script:Result.build.executableExists = Test-Path -LiteralPath $executable -PathType Leaf
        $script:Result.build.dataDirectoryExists = Test-Path -LiteralPath $dataDirectory -PathType Container
        if (-not $script:Result.build.executableExists -or -not $script:Result.build.dataDirectoryExists) { throw 'The Test Player executable or matching Data directory is missing.' }
        $script:Result.build.executableSha256 = Get-UpvFileSha256 -Path $executable
        $tree = Get-UpvrStableTreeSnapshot -Root (Split-Path -Parent $executable)
        foreach ($property in @('root', 'canonicalization', 'fileCount', 'directoryCount', 'totalBytes', 'treeSha256', 'files')) {
            $script:Result.build.tree[$property] = $tree.$property
        }
        Write-UpvrText -Path $script:Result.artifacts.buildTreePath -Content (ConvertTo-Json -InputObject $tree -Depth 10)
        Add-UpvrEvidence -Check 'buildTree' -Status 'PASSED' -Source $script:Result.artifacts.buildTreePath -Detail "Test Player tree contains $($tree.fileCount) files with SHA-256 $($tree.treeSha256)."
    } catch {
        Add-UpvrBlocker -Code 'TEST_PLAYER_BUILD_TREE_REJECTED' -Check 'windowsPlayerBuild' -Path $script:Result.build.executablePath -Message $_.Exception.Message
    }
}

# Cross-checks Editor compilation, BuildReport, build receipt, PE layout, and full Standalone tree identity.
function Set-UpvrStandaloneBuildEvidence {
    $editorLog = Get-UpvEditorLogAnalysis -Path $script:Result.artifacts.editorLogPath -ExpectedUnityVersion $script:Result.compatibility.unityVersion -ExpectedProjectPath $script:Result.isolation.projectCopyPath
    foreach ($property in $editorLog.PSObject.Properties.Name) { if ($script:Result.editorLog.Contains($property)) { $script:Result.editorLog[$property] = $editorLog.$property } }

    if ($editorLog.compilerErrorCount -gt 0) {
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_FAILURE'
        $script:Result.verification.scriptCompilation.reason = "$($editorLog.compilerErrorCount) C# compiler error(s) were retained in Editor.log."
        Add-UpvrFailure -Code 'STANDALONE_SCRIPT_COMPILATION_FAILED' -Check 'scriptCompilation' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.scriptCompilation.reason
    } elseif ($editorLog.classification -eq 'SAFE') {
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.scriptCompilation.reason = 'Signed Unity compiled the isolated Standalone overlay without retained compiler errors.'
        Add-UpvrEvidence -Check 'standaloneScriptCompilation' -Status 'PASSED' -Source $script:Result.artifacts.editorLogPath -Detail $script:Result.verification.scriptCompilation.reason
    } elseif ($editorLog.classification -eq 'FAILURE') {
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_FAILURE'
        $script:Result.verification.scriptCompilation.reason = 'Editor.log contains a concrete compilation, package, crash, or batchmode failure marker.'
        Add-UpvrFailure -Code 'STANDALONE_EDITOR_FAILURE' -Check 'scriptCompilation' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.scriptCompilation.reason
    } else {
        $script:Result.verification.scriptCompilation.status = 'BLOCKED'
        $script:Result.verification.scriptCompilation.reason = 'Editor compilation evidence lacks required version, batchmode, or isolated-project markers.'
        Add-UpvrBlocker -Code 'STANDALONE_EDITOR_LOG_INCOMPLETE' -Check 'scriptCompilation' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.scriptCompilation.reason
    }

    $report = Get-UpvrStandaloneBuildReportAssessment `
        -Path $script:Result.artifacts.buildReportPath `
        -ExpectedSessionToken $script:SessionToken `
        -ExpectedExecutablePath $script:Result.build.executablePath `
        -ExpectedBackend $script:EffectiveScriptingBackend
    $script:Result.build.report = $report
    if ($report.exists -and [int]$report.totalErrors -gt $report.buildErrors.Count -and $report.buildErrors.Count -eq 0 -and [string]$report.result -ceq 'Succeeded') {
        Add-UpvrWarning -Code 'AMBIENT_EDITOR_ERRORS_OUTSIDE_BUILD_STEPS' -Check 'standaloneBuild' -Path $script:Result.artifacts.editorLogPath -Message "BuildSummary retained $($report.totalErrors) ambient Editor error count(s), while BuildReport steps contained no concrete errors and the build result succeeded."
    }

    try {
        $script:PrebuiltIdentityAssessment = Get-UpvrPrebuiltIdentityAssessment -BuildRoot (Split-Path -Parent $script:Result.build.executablePath) -PlayerExecutable $script:Result.build.executablePath
        $identity = $script:PrebuiltIdentityAssessment
        $script:Result.build.executableExists = Test-Path -LiteralPath $script:Result.build.executablePath -PathType Leaf
        $script:Result.build.dataDirectoryExists = Test-Path -LiteralPath $script:Result.build.dataDirectoryPath -PathType Container
        if ($identity.accepted) {
            $script:Result.build.executableSha256 = $identity.executableSha256
            foreach ($property in @('root','canonicalization','fileCount','directoryCount','totalBytes','treeSha256','files')) { $script:Result.build.tree[$property] = $identity.tree.$property }
            Write-UpvrText -Path $script:Result.artifacts.buildTreePath -Content (ConvertTo-Json $identity.tree -Depth 20)
        }
    } catch {
        $script:PrebuiltIdentityAssessment = [pscustomobject][ordered]@{ accepted=$false; errors=@($_.Exception.Message); tree=$null }
    }

    $currentTree = if ($null -ne $script:PrebuiltIdentityAssessment -and $script:PrebuiltIdentityAssessment.accepted) { $script:PrebuiltIdentityAssessment.tree } else { [pscustomobject][ordered]@{ treeSha256=$null; fileCount=0; directoryCount=0; totalBytes=0 } }
    $script:StandaloneBuildReceiptAssessment = Get-UpvrStandaloneBuildReceiptAssessment `
        -Path $script:Result.artifacts.buildReceiptPath `
        -ExpectedSessionToken $script:SessionToken `
        -ExpectedBuildRoot (Split-Path -Parent $script:Result.build.executablePath) `
        -ExpectedExecutablePath $script:Result.build.executablePath `
        -ExpectedOriginalFingerprint $script:OriginalFingerprintBefore.treeSha256 `
        -ExpectedOverlayTreeSha256 $script:Result.isolation.standaloneOverlayTreeSha256 `
        -ExpectedScenarioBundleTreeSha256 $script:Result.isolation.scenarioOverlayTreeSha256 `
        -ExpectedWindowsModuleTreeSha256 $script:Result.compatibility.windowsStandaloneModule.treeSha256 `
        -ExpectedToolchainIdentitySha256 $(if ($script:EffectiveScriptingBackend -ceq 'IL2CPP') { $script:Result.compatibility.toolchain.identitySha256 } else { $null }) `
        -ExpectedBackend $script:EffectiveScriptingBackend `
        -CurrentTree $currentTree
    $script:Result.buildReceipt.resolvedPath = $script:Result.artifacts.buildReceiptPath
    $script:Result.buildReceipt.exists = [bool]$script:StandaloneBuildReceiptAssessment.exists
    $script:Result.buildReceipt.sha256 = $script:StandaloneBuildReceiptAssessment.sha256
    $script:Result.buildReceipt.accepted = [bool]$script:StandaloneBuildReceiptAssessment.accepted
    $script:Result.buildReceipt.errors = @($script:StandaloneBuildReceiptAssessment.errors)
    $script:Result.buildReceipt.identity = $script:StandaloneBuildReceiptAssessment
    if ($script:StandaloneBuildReceiptAssessment.scriptingBackend -in @('Mono','IL2CPP')) {
        $script:Result.build.scriptingBackend = [string]$script:StandaloneBuildReceiptAssessment.scriptingBackend
    }

    $concreteBuildFailure = $editorLog.classification -eq 'FAILURE' -or ($report.exists -and [string]$report.result -ne 'Succeeded')
    if ($concreteBuildFailure) {
        $script:Result.verification.windowsPlayerBuild.status = 'VERIFIED_FAILURE'
        $script:Result.verification.windowsPlayerBuild.reason = 'Unity retained a concrete instrumented Standalone build failure.'
        $script:Result.verification.standaloneBuild.status = 'VERIFIED_FAILURE'
        $script:Result.verification.standaloneBuild.reason = $script:Result.verification.windowsPlayerBuild.reason
        Add-UpvrFailure -Code 'INSTRUMENTED_STANDALONE_BUILD_FAILED' -Check 'standaloneBuild' -Path $script:Result.artifacts.buildReportPath -Message $script:Result.verification.standaloneBuild.reason
    } elseif (
        $report.accepted -and $script:StandaloneBuildReceiptAssessment.accepted -and
        $script:PrebuiltIdentityAssessment.accepted -and $script:Result.unity.exitCode -eq 0 -and
        $script:Result.processControl.editorBuild.processTreeExitVerified
    ) {
        $script:Result.verification.windowsPlayerBuild.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.windowsPlayerBuild.reason = 'BuildReport, PE layout, build receipt, and current full-tree identity agree.'
        $script:Result.verification.standaloneBuild.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.standaloneBuild.reason = 'A non-development BuildOptions.None StandaloneWindows64 instrumented build was produced and identified.'
        Add-UpvrEvidence -Check 'standaloneBuild' -Status 'PASSED' -Source $script:Result.artifacts.buildReceiptPath -Detail $script:Result.verification.standaloneBuild.reason
    } else {
        $script:Result.verification.windowsPlayerBuild.status = 'BLOCKED'
        $script:Result.verification.windowsPlayerBuild.reason = 'Standalone build report, receipt, PE, tree, exit, or process evidence is incomplete or inconsistent.'
        $script:Result.verification.standaloneBuild.status = 'BLOCKED'
        $script:Result.verification.standaloneBuild.reason = $script:Result.verification.windowsPlayerBuild.reason
        $messages = @($report.errors) + @($script:StandaloneBuildReceiptAssessment.errors) + @($script:PrebuiltIdentityAssessment.errors)
        Add-UpvrBlocker -Code 'INSTRUMENTED_STANDALONE_BUILD_EVIDENCE_INCOMPLETE' -Check 'standaloneBuild' -Path $script:Result.artifacts.buildReceiptPath -Message ([string]::Join(' ', [string[]]$messages))
    }
}

# Maps Editor, build, PlayerConnection, runtime callback, log, and tree evidence to P1 scopes.
function Set-UpvrP1VerificationEvidence {
    $script:Result.editorLog = Get-UpvEditorLogAnalysis `
        -Path $script:Result.artifacts.editorLogPath `
        -ExpectedUnityVersion $script:Result.compatibility.unityVersion `
        -ExpectedProjectPath $script:Result.isolation.projectCopyPath
    $script:Result.playerLog = Get-UpvrPlayerLogAnalysis -Path $script:Result.artifacts.playerLogPath

    $buildReport = Get-UpvrBuildReportAssessment `
        -Path $script:Result.artifacts.buildReportPath `
        -ExpectedSessionToken $script:SessionToken `
        -ExpectedExecutablePath $script:Result.build.executablePath `
        -ExpectedBackend 'Mono'
    foreach ($property in $buildReport.PSObject.Properties.Name) { $script:Result.build.report[$property] = $buildReport.$property }
    $runtimeReceipt = Get-UpvrRuntimeTestReceiptAssessment `
        -Path $script:Result.artifacts.runtimeReceiptPath `
        -ExpectedSessionToken $script:SessionToken `
        -ExpectedNUnitPath $script:Result.artifacts.runtimeNUnitPath `
        -ExpectedUnityVersion $script:Result.compatibility.unityVersion
    $script:Result.playerProcess.runtimeReceiptCompleted = [bool]$runtimeReceipt.runFinished
    $script:Result.playerProcess.observedProcessId = $runtimeReceipt.processId
    $script:Result.playerProcess.exited = [bool]$script:Result.processControl.processTreeExitVerified
    $script:Result.playerProcess.crashObserved = $script:Result.playerLog.classification -eq 'FAILURE'

    $script:Result.nunit.playerConnection = Get-UpvNUnitAnalysis -Path $script:Result.artifacts.playerConnectionResultsPath
    $script:Result.nunit.runtime = Get-UpvrRuntimeNUnitAnalysis -Path $script:Result.artifacts.runtimeNUnitPath
    $script:Result.nunit.agreement = Get-UpvrNUnitAgreementAssessment -PlayerConnection $script:Result.nunit.playerConnection -Runtime $script:Result.nunit.runtime

    $concreteEditorFailure = $script:Result.editorLog.classification -eq 'FAILURE'
    $concretePlayerFailure = $script:Result.playerLog.classification -eq 'FAILURE'
    $concreteDynamicFailure = $concreteEditorFailure -or $concretePlayerFailure
    if ($script:Result.processControl.processTreeExitVerified -and (-not $concreteEditorFailure -or (Test-Path -LiteralPath $script:Result.build.executablePath -PathType Leaf))) {
        Set-UpvrBuildTreeEvidence
    }

    if ($concreteEditorFailure) {
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_FAILURE'
        $script:Result.verification.scriptCompilation.reason = 'Editor.log contains concrete compiler, package, fatal, crash, or nonzero-exit evidence.'
        Add-UpvrFailure -Code 'UNITY_EDITOR_LOG_FAILURE' -Check 'scriptCompilation' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.scriptCompilation.reason
    } elseif (
        $script:Result.editorLog.classification -eq 'SAFE' -and
        ($script:Result.nunit.playerConnection.classification -in @('PASSED', 'FAILED', 'ZERO_TESTS', 'INCOMPLETE') -or $buildReport.accepted)
    ) {
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.scriptCompilation.reason = 'Editor.log is safe and Unity emitted a well-formed PlayerConnection result or accepted Test Player BuildReport after compilation.'
    } else {
        $script:Result.verification.scriptCompilation.status = 'BLOCKED'
        $script:Result.verification.scriptCompilation.reason = 'Compilation evidence requires a safe Editor.log and a well-formed PlayerConnection result.'
        Add-UpvrBlocker -Code 'SCRIPT_COMPILATION_EVIDENCE_INCOMPLETE' -Check 'scriptCompilation' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.scriptCompilation.reason
    }

    if ($buildReport.accepted -and $script:Result.timeouts.buildWithinLimit -and $script:Result.build.executableExists -and $script:Result.build.dataDirectoryExists -and -not [string]::IsNullOrWhiteSpace([string]$script:Result.build.tree.treeSha256)) {
        $script:Result.verification.windowsPlayerBuild.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.windowsPlayerBuild.reason = 'Unity BuildReport, output identity, backend, executable, Data directory, build duration, and full tree hash agree.'
        Add-UpvrEvidence -Check 'windowsPlayerBuild' -Status 'PASSED' -Source $script:Result.artifacts.buildReportPath -Detail $script:Result.verification.windowsPlayerBuild.reason
    } elseif ($buildReport.exists -and $buildReport.result -and $buildReport.result -notin @('Succeeded', 'Unknown')) {
        $script:Result.verification.windowsPlayerBuild.status = 'VERIFIED_FAILURE'
        $script:Result.verification.windowsPlayerBuild.reason = "Unity BuildReport completed with result $($buildReport.result)."
        Add-UpvrFailure -Code 'TEST_PLAYER_BUILD_FAILED' -Check 'windowsPlayerBuild' -Path $script:Result.artifacts.buildReportPath -Message $script:Result.verification.windowsPlayerBuild.reason
    } elseif ($concreteEditorFailure) {
        $script:Result.verification.windowsPlayerBuild.status = 'VERIFIED_FAILURE'
        $script:Result.verification.windowsPlayerBuild.reason = 'Concrete Editor compilation or build failure prevented a Test Player output.'
    } else {
        $script:Result.verification.windowsPlayerBuild.status = 'BLOCKED'
        $script:Result.verification.windowsPlayerBuild.reason = 'The successful Test Player build report or output-tree evidence is incomplete.'
        Add-UpvrBlocker -Code 'TEST_PLAYER_BUILD_EVIDENCE_INCOMPLETE' -Check 'windowsPlayerBuild' -Path $script:Result.artifacts.buildReportPath -Message ([string]::Join(' ', [string[]]@($buildReport.errors)))
    }
    if ($script:Result.processControl.timeoutPhase -eq 'BUILD') {
        Add-UpvrBlocker -Code 'TEST_PLAYER_BUILD_TIMEOUT' -Check 'timeouts' -Path $script:Result.artifacts.buildReportPath -Message "BuildReport duration exceeded $BuildTimeoutSeconds seconds."
    }

    if ($runtimeReceipt.accepted -and $script:Result.playerLog.classification -eq 'SAFE') {
        $script:Result.verification.testPlayerExecution.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.testPlayerExecution.reason = 'The Player-side callback proves start, finish, Unity version, process identity, and runtime log markers.'
        Add-UpvrEvidence -Check 'testPlayerExecution' -Status 'PASSED' -Source $script:Result.artifacts.runtimeReceiptPath -Detail $script:Result.verification.testPlayerExecution.reason
    } elseif ($script:Result.playerLog.classification -eq 'FAILURE') {
        $script:Result.verification.testPlayerExecution.status = 'VERIFIED_FAILURE'
        $script:Result.verification.testPlayerExecution.reason = 'The Player runtime log contains a concrete crash or receipt failure marker.'
        Add-UpvrFailure -Code 'TEST_PLAYER_RUNTIME_FAILED' -Check 'testPlayerExecution' -Path $script:Result.artifacts.playerLogPath -Message $script:Result.verification.testPlayerExecution.reason
    } elseif ($concreteEditorFailure) {
        $script:Result.verification.testPlayerExecution.status = 'NOT_VERIFIED'
        $script:Result.verification.testPlayerExecution.reason = 'The concrete pre-Player Editor failure prevented runtime execution.'
    } else {
        $script:Result.verification.testPlayerExecution.status = 'BLOCKED'
        $script:Result.verification.testPlayerExecution.reason = 'The Player-side runtime receipt or required log markers are incomplete.'
        Add-UpvrBlocker -Code 'TEST_PLAYER_RUNTIME_EVIDENCE_INCOMPLETE' -Check 'testPlayerExecution' -Path $script:Result.artifacts.runtimeReceiptPath -Message ([string]::Join(' ', [string[]]@($runtimeReceipt.errors)))
    }

    if ($script:Result.nunit.playerConnection.classification -in @('PASSED', 'FAILED', 'ZERO_TESTS', 'INCOMPLETE')) {
        $script:Result.verification.playerConnection.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.playerConnection.reason = 'Unity received a well-formed NUnit document through the Test Player connection.'
    } elseif ($concreteDynamicFailure) {
        $script:Result.verification.playerConnection.status = 'NOT_VERIFIED'
        $script:Result.verification.playerConnection.reason = 'A concrete compilation, build, or Player crash failure prevented PlayerConnection completion.'
    } else {
        $script:Result.verification.playerConnection.status = 'BLOCKED'
        $script:Result.verification.playerConnection.reason = 'PlayerConnection NUnit evidence is missing or malformed.'
        Add-UpvrBlocker -Code 'PLAYER_CONNECTION_RESULT_MISSING' -Check 'playerConnection' -Path $script:Result.artifacts.playerConnectionResultsPath -Message ([string]$script:Result.nunit.playerConnection.error)
    }

    $classification = [string]$script:Result.nunit.playerConnection.classification
    if ($concreteDynamicFailure -and $classification -notin @('FAILED')) {
        $script:Result.verification.playerTests.status = 'VERIFIED_FAILURE'
        $script:Result.verification.playerTests.reason = 'A concrete compilation, build, or Player crash failure prevented a complete Player test result.'
    } elseif (-not $script:Result.nunit.agreement.accepted) {
        $script:Result.verification.playerTests.status = 'BLOCKED'
        $script:Result.verification.playerTests.reason = 'PlayerConnection and Player-side NUnit summaries disagree.'
        Add-UpvrBlocker -Code 'PLAYER_NUNIT_EVIDENCE_MISMATCH' -Check 'playerTests' -Path $script:Result.artifacts.runtimeNUnitPath -Message ([string]::Join(' ', [string[]]@($script:Result.nunit.agreement.mismatches)))
    } elseif ($classification -eq 'ZERO_TESTS') {
        $script:Result.verification.playerTests.status = 'BLOCKED'
        $script:Result.verification.playerTests.reason = 'The selected Test Player run contained zero tests.'
        Add-UpvrBlocker -Code 'NO_PLAYER_TESTS_EXECUTED' -Check 'playerTests' -Path $script:Result.artifacts.playerConnectionResultsPath -Message $script:Result.verification.playerTests.reason
    } elseif ($classification -in @('INCOMPLETE', 'INCONCLUSIVE')) {
        $script:Result.verification.playerTests.status = 'BLOCKED'
        $script:Result.verification.playerTests.reason = 'Skipped or inconclusive Player tests prevent complete evidence.'
        Add-UpvrBlocker -Code 'PLAYER_TEST_RUN_INCOMPLETE' -Check 'playerTests' -Path $script:Result.artifacts.playerConnectionResultsPath -Message $script:Result.verification.playerTests.reason
    } elseif ($classification -eq 'FAILED') {
        $script:Result.verification.playerTests.status = 'VERIFIED_FAILURE'
        $script:Result.verification.playerTests.reason = "$($script:Result.nunit.playerConnection.failed) selected Player test(s) failed."
        Add-UpvrFailure -Code 'PLAYER_TESTS_FAILED' -Check 'playerTests' -Path $script:Result.artifacts.playerConnectionResultsPath -Message $script:Result.verification.playerTests.reason
    } elseif (
        $classification -eq 'PASSED' -and $runtimeReceipt.accepted -and
        $script:Result.verification.windowsPlayerBuild.status -eq 'VERIFIED_SUCCESS' -and
        $script:Result.verification.testPlayerExecution.status -eq 'VERIFIED_SUCCESS' -and
        $script:Result.verification.playerConnection.status -eq 'VERIFIED_SUCCESS'
    ) {
        $script:Result.verification.playerTests.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.playerTests.reason = "All $($script:Result.nunit.playerConnection.total) selected tests passed in the approved Mono Windows Test Player."
        Add-UpvrEvidence -Check 'playerTests' -Status 'PASSED' -Source $script:Result.artifacts.playerConnectionResultsPath -Detail $script:Result.verification.playerTests.reason
    } else {
        $script:Result.verification.playerTests.status = 'BLOCKED'
        $script:Result.verification.playerTests.reason = 'Positive Player test evidence is incomplete.'
        Add-UpvrBlocker -Code 'PLAYER_TEST_EVIDENCE_INCOMPLETE' -Check 'playerTests' -Path $script:Result.artifacts.playerConnectionResultsPath -Message $script:Result.verification.playerTests.reason
    }

    if ($null -ne $script:Result.unity.exitCode -and [long]$script:Result.unity.exitCode -ne 0) {
        if ($classification -eq 'FAILED' -or $script:Result.editorLog.classification -eq 'FAILURE' -or $script:Result.playerLog.classification -eq 'FAILURE') {
            Add-UpvrFailure -Code 'UNITY_NONZERO_EXIT' -Check 'unityProcess' -Path $script:Result.unity.executablePath -Message "Unity exited with concrete nonzero code $($script:Result.unity.exitCode)."
        } else {
            Add-UpvrBlocker -Code 'UNITY_NONZERO_EXIT_INCONCLUSIVE' -Check 'unityProcess' -Path $script:Result.unity.executablePath -Message "Unity exited with code $($script:Result.unity.exitCode) without complete failure evidence."
        }
    }
}

# Validates the independent scenario receipt, exact IDs, and requested PNG identities.
function Set-UpvrP2ScenarioVerificationEvidence {
    if ($null -eq $script:ScenarioAssessment) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'The validated Player scenario manifest is unavailable.'
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_MANIFEST_UNAVAILABLE' -Check 'scenarioBehavior' -Path $ScenarioBundlePath -Message $script:Result.verification.scenarioBehavior.reason
        return
    }

    $receipt = Get-UpvrPlayerScenarioReceiptAssessment `
        -Path $script:Result.artifacts.scenarioReceiptPath `
        -Manifest $script:ScenarioAssessment `
        -ExpectedSessionToken $script:SessionToken `
        -ScreenshotRoot $script:Result.artifacts.screenshotRoot
    $script:Result.scenario.receiptAccepted = [bool]$receipt.accepted
    $script:Result.scenario.receiptErrors = @($receipt.errors)
    $script:Result.scenario.activeScene = $receipt.activeScene
    $script:Result.scenario.assertions = @($receipt.assertions)
    $script:Result.scenario.result = $receipt.result
    $script:Result.captures.artifacts = @($receipt.captures)
    $script:Result.captures.allPresent = [bool]$receipt.capturesPresent
    $script:Result.captures.contentJudged = $false

    $concreteEarlierFailure = @(
        $script:Result.verification.scriptCompilation.status,
        $script:Result.verification.windowsPlayerBuild.status,
        $script:Result.verification.testPlayerExecution.status
    ) -contains 'VERIFIED_FAILURE'
    $timeoutObserved = $script:Result.processControl.timeoutPhase -eq 'RUN' -or [string]$receipt.exception -match '(?i)TimeoutException|timed out|timeout'
    if (-not $receipt.exists) {
        if ($concreteEarlierFailure) {
            $script:Result.verification.scenarioBehavior.status = 'NOT_VERIFIED'
            $script:Result.verification.scenarioBehavior.reason = 'A concrete compilation, build, or Player crash failure prevented the scenario receipt.'
        } else {
            $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
            $script:Result.verification.scenarioBehavior.reason = 'The Player scenario receipt is missing.'
            Add-UpvrBlocker -Code 'PLAYER_SCENARIO_RECEIPT_MISSING' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
        }
    } elseif ($timeoutObserved) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'The Player scenario did not complete within its bounded timeout.'
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_TIMEOUT' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
    } elseif (-not $receipt.assertionIdsMatched -or -not $receipt.scenarioIdMatched -or -not $receipt.sceneMatched -or -not $receipt.runFinished) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'Scenario receipt identity, Scene, completion, or assertion IDs do not exactly match the manifest.'
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_RECEIPT_MISMATCH' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message ([string]::Join(' ', [string[]]@($receipt.errors)))
    } elseif (-not $receipt.assertionsPassed -or [string]$receipt.result -cne 'PASSED') {
        $script:Result.verification.scenarioBehavior.status = 'VERIFIED_FAILURE'
        $script:Result.verification.scenarioBehavior.reason = 'One or more manifest-owned Player scenario assertions failed.'
        Add-UpvrFailure -Code 'PLAYER_SCENARIO_ASSERTION_FAILED' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
    } elseif ($receipt.accepted) {
        $script:Result.verification.scenarioBehavior.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.scenarioBehavior.reason = 'Scenario ID, active Scene, assertions, and completion receipt exactly match the reviewed manifest.'
        Add-UpvrEvidence -Check 'scenarioBehavior' -Status 'PASSED' -Source $script:Result.artifacts.scenarioReceiptPath -Detail $script:Result.verification.scenarioBehavior.reason
    } else {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'Scenario receipt evidence is incomplete or internally inconsistent.'
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_EVIDENCE_INCOMPLETE' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message ([string]::Join(' ', [string[]]@($receipt.errors)))
    }

    if (-not $receipt.exists -and $concreteEarlierFailure) {
        $script:Result.verification.visualEvidence.status = 'NOT_VERIFIED'
        $script:Result.verification.visualEvidence.reason = 'A concrete compilation, build, or Player crash failure prevented capture evidence.'
    } elseif (-not $receipt.captureIdsMatched -or -not $receipt.capturesPresent) {
        $script:Result.verification.visualEvidence.status = 'BLOCKED'
        $script:Result.verification.visualEvidence.reason = 'Requested Player PNG IDs or file identities are missing or mismatched.'
        Add-UpvrBlocker -Code 'PLAYER_SCENARIO_CAPTURE_MISSING' -Check 'visualEvidence' -Path $script:Result.artifacts.screenshotRoot -Message $script:Result.verification.visualEvidence.reason
    } else {
        $script:Result.verification.visualEvidence.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.visualEvidence.reason = if ($script:ScenarioAssessment.expectedCaptureIds.Count -eq 0) {
            'The manifest requested no visual artifacts and the receipt emitted no unexpected capture IDs.'
        } else {
            'Every requested PNG exists with matching nonzero length and SHA-256; image content was not judged.'
        }
        Add-UpvrEvidence -Check 'visualEvidence' -Status 'PASSED' -Source $script:Result.artifacts.screenshotRoot -Detail $script:Result.verification.visualEvidence.reason
    }
}

# Maps Standalone runtime receipt, log, exit, assertion, and PNG evidence to P3 verification scopes.
function Set-UpvrStandaloneScenarioVerificationEvidence {
    if ($null -eq $script:ScenarioAssessment) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'The receipt-bound Standalone scenario contract is unavailable.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_CONTRACT_UNAVAILABLE' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioContractPath -Message $script:Result.verification.scenarioBehavior.reason
        return
    }

    $script:Result.playerLog = Get-UpvrPlayerLogAnalysis -Path $script:Result.artifacts.playerLogPath
    $receipt = Get-UpvrPlayerScenarioReceiptAssessment `
        -Path $script:Result.artifacts.scenarioReceiptPath `
        -Manifest $script:ScenarioAssessment `
        -ExpectedSessionToken $script:SessionToken `
        -ScreenshotRoot $script:Result.artifacts.screenshotRoot
    $script:Result.playerProcess.runtimeReceiptCompleted = [bool]$receipt.runFinished
    $script:Result.playerProcess.crashObserved = $script:Result.playerLog.classification -eq 'FAILURE'
    $script:Result.scenario.receiptAccepted = [bool]$receipt.accepted
    $script:Result.scenario.receiptErrors = @($receipt.errors)
    $script:Result.scenario.activeScene = $receipt.activeScene
    $script:Result.scenario.assertions = @($receipt.assertions)
    $script:Result.scenario.result = $receipt.result
    $script:Result.captures.artifacts = @($receipt.captures)
    $script:Result.captures.allPresent = [bool]$receipt.capturesPresent
    $script:Result.captures.contentJudged = $false

    $crash = $script:Result.playerLog.classification -eq 'FAILURE' -or $script:Result.processControl.standaloneRun.failureSignalObserved
    $timeout = $script:Result.playerProcess.timedOut -or [string]$receipt.exception -match '(?i)TimeoutException|timed out|timeout'
    $expectedExit = if ([string]$receipt.result -ceq 'PASSED') { 0 } elseif ([string]$receipt.result -ceq 'FAILED') { 1 } else { $null }
    $exitMatched = $null -ne $expectedExit -and $null -ne $script:Result.playerProcess.exitCode -and [long]$script:Result.playerProcess.exitCode -eq [long]$expectedExit

    if ($crash) {
        $script:Result.verification.standaloneLaunch.status = 'VERIFIED_FAILURE'
        $script:Result.verification.standaloneLaunch.reason = 'Standalone Player log or Job Object monitoring retained a concrete crash/fatal marker.'
        Add-UpvrFailure -Code 'STANDALONE_PLAYER_CRASHED' -Check 'standaloneLaunch' -Path $script:Result.artifacts.playerLogPath -Message $script:Result.verification.standaloneLaunch.reason
    } elseif ($timeout) {
        $script:Result.verification.standaloneLaunch.status = 'BLOCKED'
        $script:Result.verification.standaloneLaunch.reason = 'Standalone Player or scenario exceeded its bounded timeout.'
    } elseif ($receipt.exists -and $script:Result.playerLog.classification -eq 'SAFE' -and $exitMatched -and $script:Result.processControl.standaloneRun.processTreeExitVerified) {
        $script:Result.verification.standaloneLaunch.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.standaloneLaunch.reason = 'Standalone runtime start/finish markers, receipt result, exit code, and process-tree completion agree.'
        Add-UpvrEvidence -Check 'standaloneLaunch' -Status 'PASSED' -Source $script:Result.artifacts.playerLogPath -Detail $script:Result.verification.standaloneLaunch.reason
    } else {
        $script:Result.verification.standaloneLaunch.status = 'BLOCKED'
        $script:Result.verification.standaloneLaunch.reason = 'Standalone launch receipt, runtime markers, exit code, or process-tree evidence is incomplete or inconsistent.'
        Add-UpvrBlocker -Code 'STANDALONE_LAUNCH_EVIDENCE_INCOMPLETE' -Check 'standaloneLaunch' -Path $script:Result.artifacts.playerLogPath -Message $script:Result.verification.standaloneLaunch.reason
    }

    if ($crash) {
        $script:Result.verification.scenarioBehavior.status = 'NOT_VERIFIED'
        $script:Result.verification.scenarioBehavior.reason = 'The concrete Player crash prevented a complete scenario receipt.'
    } elseif ($timeout) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'The Standalone scenario did not complete within its bounded timeout.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_TIMEOUT' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
    } elseif (-not $receipt.exists) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'The Standalone scenario receipt is missing.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_RECEIPT_MISSING' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
    } elseif (-not $receipt.captureIdsMatched -or -not $receipt.capturesPresent) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'Requested Standalone capture IDs or files are missing or mismatched.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_CAPTURE_MISSING' -Check 'scenarioBehavior' -Path $script:Result.artifacts.screenshotRoot -Message $script:Result.verification.scenarioBehavior.reason
    } elseif (-not $receipt.assertionIdsMatched -or -not $receipt.scenarioIdMatched -or -not $receipt.sceneMatched -or -not $receipt.runFinished) {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'Standalone receipt identity, Scene, completion, or assertion IDs do not exactly match the manifest.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_RECEIPT_MISMATCH' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message ([string]::Join(' ', [string[]]@($receipt.errors)))
    } elseif (-not $receipt.assertionsPassed -or [string]$receipt.result -cne 'PASSED') {
        $script:Result.verification.scenarioBehavior.status = 'VERIFIED_FAILURE'
        $script:Result.verification.scenarioBehavior.reason = 'One or more manifest-owned Standalone scenario assertions failed.'
        Add-UpvrFailure -Code 'STANDALONE_SCENARIO_ASSERTION_FAILED' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message $script:Result.verification.scenarioBehavior.reason
    } elseif ($receipt.accepted) {
        $script:Result.verification.scenarioBehavior.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.scenarioBehavior.reason = 'Scenario ID, active Scene, assertions, captures, and completion receipt exactly match the reviewed Standalone manifest.'
        Add-UpvrEvidence -Check 'standaloneScenarioBehavior' -Status 'PASSED' -Source $script:Result.artifacts.scenarioReceiptPath -Detail $script:Result.verification.scenarioBehavior.reason
    } else {
        $script:Result.verification.scenarioBehavior.status = 'BLOCKED'
        $script:Result.verification.scenarioBehavior.reason = 'Standalone scenario evidence is incomplete or internally inconsistent.'
        Add-UpvrBlocker -Code 'STANDALONE_SCENARIO_EVIDENCE_INCOMPLETE' -Check 'scenarioBehavior' -Path $script:Result.artifacts.scenarioReceiptPath -Message ([string]::Join(' ', [string[]]@($receipt.errors)))
    }

    if ($crash) {
        $script:Result.verification.visualEvidence.status = 'NOT_VERIFIED'
        $script:Result.verification.visualEvidence.reason = 'The Player crash prevented complete capture evidence.'
    } elseif ($timeout) {
        $script:Result.verification.visualEvidence.status = 'BLOCKED'
        $script:Result.verification.visualEvidence.reason = 'The scenario timeout prevents complete capture evidence.'
    } elseif (-not $receipt.captureIdsMatched -or -not $receipt.capturesPresent) {
        $script:Result.verification.visualEvidence.status = 'BLOCKED'
        $script:Result.verification.visualEvidence.reason = 'Requested Standalone PNG IDs or file identities are missing or mismatched.'
    } else {
        $script:Result.verification.visualEvidence.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.visualEvidence.reason = if ($script:ScenarioAssessment.expectedCaptureIds.Count -eq 0) { 'The manifest requested no captures and no unexpected capture IDs were emitted.' } else { 'Every requested PNG exists with matching nonzero length and SHA-256; image content was not judged.' }
        Add-UpvrEvidence -Check 'standaloneVisualEvidence' -Status 'PASSED' -Source $script:Result.artifacts.screenshotRoot -Detail $script:Result.verification.visualEvidence.reason
    }
}

# Validates one explicit prebuilt Player and optionally binds its retained build receipt to a fresh runtime contract.
function Initialize-UpvrPrebuiltStandalone {
    try {
        $script:PrebuiltIdentityAssessment = Get-UpvrPrebuiltIdentityAssessment -BuildRoot $BuildRoot -PlayerExecutable $PlayerExecutable
        $identity = $script:PrebuiltIdentityAssessment
        foreach ($property in @('buildRoot','executablePath','executableSha256','peValidated','machine','dataDirectoryPath','dataDirectoryExists','signatureStatus','signerSubject','accepted','errors')) {
            $script:Result.prebuiltIdentity[$property] = $identity.$property
        }
        if (-not $identity.accepted) { throw ([string]::Join(' ', [string[]]@($identity.errors))) }
        $script:PrebuiltTreeBefore = $identity.tree
        $script:Result.prebuiltIdentity.treeSha256 = $identity.tree.treeSha256
        $script:Result.prebuiltIdentity.beforeTreeSha256 = $identity.tree.treeSha256
        $script:Result.build.executablePath = $identity.executablePath
        $script:Result.build.executableExists = $true
        $script:Result.build.executableSha256 = $identity.executableSha256
        $script:Result.build.dataDirectoryPath = $identity.dataDirectoryPath
        $script:Result.build.dataDirectoryExists = $identity.dataDirectoryExists
        foreach ($property in @('root','canonicalization','fileCount','directoryCount','totalBytes','treeSha256','files')) { $script:Result.build.tree[$property] = $identity.tree.$property }
        Write-UpvrText -Path $script:Result.artifacts.buildTreePath -Content (ConvertTo-Json $identity.tree -Depth 20)
        $script:Result.verification.prebuiltIdentity.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.prebuiltIdentity.reason = 'The explicit prebuilt EXE is PE32+ AMD64, has its matching Data directory, and has a deterministic full-tree identity.'
        Add-UpvrEvidence -Check 'prebuiltIdentity' -Status 'PASSED' -Source $identity.executablePath -Detail $script:Result.verification.prebuiltIdentity.reason

        if ([string]::IsNullOrWhiteSpace($BuildReceiptPath)) { return }
        $receiptPath = Get-UpvNormalizedPath -Path $BuildReceiptPath
        $script:Result.buildReceipt.resolvedPath = $receiptPath
        $script:StandaloneBuildReceiptAssessment = Get-UpvrStandaloneBuildReceiptAssessment `
            -Path $receiptPath -ExpectedBuildRoot $identity.buildRoot -ExpectedExecutablePath $identity.executablePath `
            -ExpectedBackend 'Project' -CurrentTree $identity.tree
        $script:Result.buildReceipt.exists = [bool]$script:StandaloneBuildReceiptAssessment.exists
        $script:Result.buildReceipt.sha256 = $script:StandaloneBuildReceiptAssessment.sha256
        $script:Result.buildReceipt.accepted = [bool]$script:StandaloneBuildReceiptAssessment.accepted
        $script:Result.buildReceipt.errors = @($script:StandaloneBuildReceiptAssessment.errors)
        $script:Result.buildReceipt.identity = $script:StandaloneBuildReceiptAssessment
        if (-not $script:StandaloneBuildReceiptAssessment.accepted) { throw ([string]::Join(' ', [string[]]@($script:StandaloneBuildReceiptAssessment.errors))) }

        $scenario = $script:StandaloneBuildReceiptAssessment.scenario
        $script:ScenarioAssessment = [pscustomobject][ordered]@{
            accepted=$true; schemaVersion='1.0.0'; kind='STANDALONE_SCENARIO_BUNDLE'
            scenarioId=[string]$scenario.scenarioId; displayName=[string]$scenario.displayName
            timeoutSeconds=[int]$scenario.timeoutSeconds; buildScenes=[string[]]@($scenario.buildScenes)
            expectedScenes=[string[]]@($scenario.expectedScenes)
            expectedAssertionIds=[string[]]@($scenario.expectedAssertionIds)
            expectedCaptureIds=[string[]]@($scenario.expectedCaptureIds)
            graphicsRequired=[bool]$scenario.graphicsRequired
            treeSha256=[string]$script:StandaloneBuildReceiptAssessment.scenarioBundleTreeSha256
        }
        $script:Result.scenario.requested = $true
        foreach ($property in @('schemaVersion','kind','scenarioId','displayName','timeoutSeconds','buildScenes','expectedScenes','expectedAssertionIds','expectedCaptureIds','graphicsRequired')) { $script:Result.scenario[$property] = $script:ScenarioAssessment.$property }
        $script:Result.scenario.bundleTreeSha256 = $script:ScenarioAssessment.treeSha256
        $script:Result.selection.scenarioId = $script:ScenarioAssessment.scenarioId
        $script:Result.captures.requestedIds = [string[]]@($script:ScenarioAssessment.expectedCaptureIds)
        $script:Result.build.scriptingBackend = [string]$script:StandaloneBuildReceiptAssessment.scriptingBackend
        $script:Result.input.scriptingBackend = [string]$script:StandaloneBuildReceiptAssessment.scriptingBackend

        $runtimeContract = [ordered]@{
            schemaVersion='1.0.0'; sessionToken=$script:SessionToken; scenarioId=$script:ScenarioAssessment.scenarioId
            displayName=$script:ScenarioAssessment.displayName; timeoutSeconds=$script:ScenarioAssessment.timeoutSeconds
            expectedScenes=[string[]]@($script:ScenarioAssessment.expectedScenes)
            expectedAssertionIds=[string[]]@($script:ScenarioAssessment.expectedAssertionIds)
            expectedCaptureIds=[string[]]@($script:ScenarioAssessment.expectedCaptureIds)
            graphicsRequired=[bool]$script:ScenarioAssessment.graphicsRequired
        }
        Write-UpvrText -Path $script:Result.artifacts.scenarioContractPath -Content (ConvertTo-Json $runtimeContract -Depth 10 -Compress)
        Add-UpvrEvidence -Check 'prebuiltBuildReceipt' -Status 'PASSED' -Source $receiptPath -Detail 'The retained build receipt exactly matches the explicit EXE and current full build tree.'
    } catch {
        if ($script:Result.verification.prebuiltIdentity.status -ne 'VERIFIED_SUCCESS') {
            $script:Result.verification.prebuiltIdentity.status = 'BLOCKED'
            $script:Result.verification.prebuiltIdentity.reason = 'The explicit prebuilt Player identity is invalid or incomplete.'
        }
        Add-UpvrBlocker -Code 'PREBUILT_STANDALONE_REJECTED' -Check 'prebuiltIdentity' -Path $PlayerExecutable -Message $_.Exception.Message
    }
}

# Recomputes the prebuilt full-tree identity after execution and blocks any runtime mutation.
function Complete-UpvrPrebuiltTreeIntegrity {
    if ($null -eq $script:PrebuiltTreeBefore -or [string]::IsNullOrWhiteSpace([string]$script:Result.prebuiltIdentity.buildRoot)) { return }
    try {
        $after = Get-UpvrStableTreeSnapshot -Root $script:Result.prebuiltIdentity.buildRoot
        $unchanged = [string]$after.treeSha256 -ceq [string]$script:PrebuiltTreeBefore.treeSha256
        $script:Result.prebuiltIdentity.afterTreeSha256 = $after.treeSha256
        $script:Result.prebuiltIdentity.treeUnchanged = $unchanged
        if (-not $unchanged) { Add-UpvrBlocker -Code 'PREBUILT_BUILD_TREE_CHANGED' -Check 'prebuiltIdentity' -Path $script:Result.prebuiltIdentity.buildRoot -Message 'The prebuilt build tree changed while the Player was executed.' }
        else { Add-UpvrEvidence -Check 'prebuiltTreeIntegrity' -Status 'UNCHANGED' -Source $script:Result.prebuiltIdentity.buildRoot -Detail 'The prebuilt full-tree hash is unchanged after execution.' }
    } catch {
        Add-UpvrBlocker -Code 'PREBUILT_TREE_INTEGRITY_UNPROVEN' -Check 'prebuiltIdentity' -Path $script:Result.prebuiltIdentity.buildRoot -Message $_.Exception.Message
    }
}

# Classifies opaque prebuilt launch-only evidence without promoting it to behavioral verification.
function Set-UpvrOpaqueLaunchEvidence {
    $script:Result.playerLog = Get-UpvrPlayerLogAnalysis -Path $script:Result.artifacts.playerLogPath
    $crash = $script:Result.playerLog.classification -eq 'FAILURE' -or $script:Result.processControl.standaloneRun.failureSignalObserved
    if ($crash) {
        $script:Result.playerProcess.crashObserved = $true
        $script:Result.verification.standaloneLaunch.status = 'VERIFIED_FAILURE'
        $script:Result.verification.standaloneLaunch.reason = 'The opaque prebuilt Player retained a concrete crash or fatal marker.'
        Add-UpvrFailure -Code 'OPAQUE_PREBUILT_CRASHED' -Check 'standaloneLaunch' -Path $script:Result.artifacts.playerLogPath -Message $script:Result.verification.standaloneLaunch.reason
    } elseif ($script:Result.playerProcess.timedOut) {
        $script:Result.verification.standaloneLaunch.status = 'BLOCKED'
        $script:Result.verification.standaloneLaunch.reason = 'The opaque prebuilt Player exceeded RunTimeoutSeconds before completing the observation.'
    } elseif (
        $script:Result.playerProcess.observationCompleted -and $script:Result.playerProcess.responsiveObserved -and
        $script:Result.playerProcess.closeMainWindowRequested -and $script:Result.processControl.standaloneRun.processTreeExitVerified
    ) {
        $script:Result.verification.standaloneLaunch.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.standaloneLaunch.reason = 'The exact opaque EXE exposed a responsive window continuously for at least 10 seconds and its Job Object reached zero processes after CloseMainWindow was requested.'
        Add-UpvrEvidence -Check 'opaqueStandaloneLaunch' -Status 'PASSED' -Source $script:Result.build.executablePath -Detail $script:Result.verification.standaloneLaunch.reason
    } else {
        $script:Result.verification.standaloneLaunch.status = 'BLOCKED'
        $script:Result.verification.standaloneLaunch.reason = 'The opaque EXE exited early or lacked a responsive 10-second window/process-tree observation.'
        Add-UpvrBlocker -Code 'OPAQUE_LAUNCH_EVIDENCE_INCOMPLETE' -Check 'standaloneLaunch' -Path $script:Result.build.executablePath -Message $script:Result.verification.standaloneLaunch.reason
    }
}

# Recomputes source content and Git metadata after all dynamic work completes.
function Complete-UpvrOriginalIntegrity {
    if ($null -ne $script:OriginalFingerprintBefore) {
        try {
            $after = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
            $script:Result.originalProjectIntegrity.afterDirectoryCount = $after.directoryCount
            $script:Result.originalProjectIntegrity.afterFileCount = $after.fileCount
            $script:Result.originalProjectIntegrity.afterTreeSha256 = $after.treeSha256
            $unchanged = $after.directoryCount -eq $script:OriginalFingerprintBefore.directoryCount -and $after.fileCount -eq $script:OriginalFingerprintBefore.fileCount -and $after.treeSha256 -ceq $script:OriginalFingerprintBefore.treeSha256
            $script:Result.originalProjectIntegrity.unchanged = $unchanged
            $script:Result.originalProjectIntegrity.status = if ($unchanged) { 'UNCHANGED' } else { 'CHANGED' }
            Add-UpvrEvidence -Check 'originalProjectIntegrity' -Status $script:Result.originalProjectIntegrity.status -Source $script:NormalizedProjectRoot -Detail 'Source copy-set fingerprints were compared before and after Player verification.'
        } catch {
            Add-UpvrBlocker -Code 'ORIGINAL_INTEGRITY_UNPROVEN' -Check 'originalProjectIntegrity' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
        }
    }
    if ($null -ne $script:GitSnapshotBefore) {
        try {
            $after = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
            $assessment = Get-BaselineGitMetadataAssessment -Before $script:GitSnapshotBefore -After $after
            $script:Result.gitMetadataIntegrity.presentAfter = [bool]$after.present
            $script:Result.gitMetadataIntegrity.afterTreeSha256 = [string]$after.treeSha256
            foreach ($property in @('status', 'unchanged', 'ambientChangesAllowed', 'addedDirectories', 'removedDirectories', 'addedFiles', 'removedFiles', 'changedFiles')) {
                $script:Result.gitMetadataIntegrity[$property] = $assessment.$property
            }
            Add-UpvrEvidence -Check 'gitMetadataIntegrity' -Status $assessment.status -Source $script:NormalizedProjectRoot -Detail 'Git metadata was compared independently with only Codex checkpoint additions allowed.'
        } catch {
            Add-UpvrBlocker -Code 'GIT_METADATA_INTEGRITY_UNPROVEN' -Check 'gitMetadataIntegrity' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
        }
    }
}

# Applies final precedence and freezes diagnostic collections into the public result.
function Complete-UpvrResult {
    $requiredScopes = if ($Mode -eq 'TEST_PLAYER') {
        @('scriptCompilation', 'windowsPlayerBuild', 'testPlayerExecution', 'playerConnection', 'playerTests')
    } elseif ($Mode -eq 'SCENARIO_TEST_PLAYER') {
        @('scriptCompilation', 'windowsPlayerBuild', 'testPlayerExecution', 'playerConnection', 'playerTests', 'scenarioBehavior', 'visualEvidence')
    } elseif ($Mode -eq 'INSTRUMENTED_STANDALONE') {
        @('scriptCompilation', 'standaloneBuild', 'standaloneLaunch', 'scenarioBehavior', 'visualEvidence')
    } elseif ($Mode -eq 'PREBUILT_STANDALONE' -and -not [string]::IsNullOrWhiteSpace($BuildReceiptPath)) {
        @('prebuiltIdentity', 'standaloneLaunch', 'scenarioBehavior', 'visualEvidence')
    } elseif ($Mode -eq 'PREBUILT_STANDALONE') {
        @('prebuiltIdentity', 'standaloneLaunch')
    } else {
        @()
    }
    $scopeStatuses = [string[]]@($requiredScopes | ForEach-Object { [string]$script:Result.verification[$_].status })
    $finalArguments = [ordered]@{
        OriginalIntegrityStatus=[string]$script:Result.originalProjectIntegrity.status
        GitIntegrityStatus=[string]$script:Result.gitMetadataIntegrity.status
        BlockerCount=$script:Blockers.Count; FailureCount=$script:Failures.Count
        CompatibilityStatus=[string]$script:Result.compatibility.verificationStatus
        RequiredScopeStatuses=$scopeStatuses
    }
    if ($Mode -eq 'PREBUILT_STANDALONE') { $finalArguments.CompatibilityNotRequired = $true }
    if ($Mode -eq 'PREBUILT_STANDALONE' -and [string]::IsNullOrWhiteSpace($BuildReceiptPath)) { $finalArguments.LaunchOnly = $true }
    $script:Result.finalStatus = Get-UpvrFinalStatusAssessment @finalArguments
    if ($script:Result.finalStatus -eq 'VERIFICATION_BLOCKED' -and $script:Blockers.Count -eq 0) {
        Add-UpvrBlocker -Code 'REQUIRED_SCOPE_NOT_VERIFIED' -Check 'finalStatus' -Path $null -Message 'One or more required Player verification scopes lack positive evidence.'
    }
    $script:Result.warnings = @($script:Warnings)
    $script:Result.failures = @($script:Failures)
    $script:Result.blockers = @($script:Blockers)
    $script:Result.evidence = @($script:Evidence)
}

# Serializes exactly one stdout JSON document and writes the identical external result.
function Write-UpvrResult {
    Complete-UpvrResult
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Result.artifacts.resultPath)) { $script:Result.artifacts.resultWritten = $true }
    $json = if ($Pretty) { ConvertTo-Json $script:Result -Depth 60 } else { ConvertTo-Json $script:Result -Depth 60 -Compress }
    if ($script:Result.artifacts.resultWritten) {
        try {
            Write-UpvrText -Path $script:Result.artifacts.resultPath -Content $json
        } catch {
            $script:Result.artifacts.resultWritten = $false
            Add-UpvrBlocker -Code 'RESULT_ARTIFACT_WRITE_FAILED' -Check 'artifacts' -Path $script:Result.artifacts.resultPath -Message $_.Exception.Message
            Complete-UpvrResult
            $json = if ($Pretty) { ConvertTo-Json $script:Result -Depth 60 } else { ConvertTo-Json $script:Result -Depth 60 -Compress }
        }
    }
    [Console]::Out.WriteLine($json)
}

try {
    if ($Mode -in @('TEST_PLAYER', 'SCENARIO_TEST_PLAYER') -and $ScriptingBackend -cne 'Mono') {
        Add-UpvrBlocker -Code 'P1_P2_BACKEND_REJECTED' -Check 'scriptingBackend' -Path $null -Message 'Test Player modes are sealed to Mono through P2.'
    }
    foreach ($selectorName in @('TestFilter', 'TestCategory', 'AssemblyNames')) {
        $assessment = Test-UpvSelectorValue -Value (Get-Variable -Name $selectorName -ValueOnly) -Name $selectorName
        if (-not $assessment.accepted) { Add-UpvrBlocker -Code 'TEST_SELECTOR_REJECTED' -Check 'selection' -Path $null -Message $assessment.error }
    }
    $selectorSupplied = -not [string]::IsNullOrWhiteSpace($TestFilter) -or -not [string]::IsNullOrWhiteSpace($TestCategory) -or -not [string]::IsNullOrWhiteSpace($AssemblyNames)
    if ($Mode -in @('SCENARIO_TEST_PLAYER','INSTRUMENTED_STANDALONE') -and $selectorSupplied) { Add-UpvrBlocker -Code 'SCENARIO_SELECTOR_CONFLICT' -Check 'selection' -Path $null -Message 'Scenario modes cannot be combined with test selection parameters; the manifest owns its execution contract.' }
    if ($Mode -in @('SCENARIO_TEST_PLAYER','INSTRUMENTED_STANDALONE') -and [string]::IsNullOrWhiteSpace($ScenarioBundlePath)) { Add-UpvrBlocker -Code 'SCENARIO_BUNDLE_REQUIRED' -Check 'selection' -Path $null -Message "$Mode requires ScenarioBundlePath." }
    if ($Mode -eq 'TEST_PLAYER' -and -not [string]::IsNullOrWhiteSpace($ScenarioBundlePath)) { Add-UpvrBlocker -Code 'TEST_PLAYER_SCENARIO_CONFLICT' -Check 'selection' -Path $ScenarioBundlePath -Message 'TEST_PLAYER cannot be combined with ScenarioBundlePath.' }
    if ($Mode -ne 'PREBUILT_STANDALONE' -and (-not [string]::IsNullOrWhiteSpace($BuildRoot) -or -not [string]::IsNullOrWhiteSpace($PlayerExecutable) -or -not [string]::IsNullOrWhiteSpace($BuildReceiptPath))) {
        Add-UpvrBlocker -Code 'PROJECT_PREBUILT_INPUT_CONFLICT' -Check 'input' -Path $null -Message 'Project modes cannot be combined with prebuilt inputs.'
    }
    if ($Mode -eq 'PREBUILT_STANDALONE') {
        if ($selectorSupplied -or -not [string]::IsNullOrWhiteSpace($ScenarioBundlePath)) { Add-UpvrBlocker -Code 'PREBUILT_SELECTION_CONFLICT' -Check 'selection' -Path $null -Message 'PREBUILT_STANDALONE cannot receive source scenario or test selection parameters.' }
        if ([string]::IsNullOrWhiteSpace($BuildRoot) -or [string]::IsNullOrWhiteSpace($PlayerExecutable)) { Add-UpvrBlocker -Code 'PREBUILT_INPUT_REQUIRED' -Check 'input' -Path $null -Message 'PREBUILT_STANDALONE requires explicit BuildRoot and PlayerExecutable.' }
        if ($PSBoundParameters.ContainsKey('ProjectRoot')) { Add-UpvrBlocker -Code 'PREBUILT_PROJECT_INPUT_CONFLICT' -Check 'input' -Path $ProjectRoot -Message 'PREBUILT_STANDALONE cannot receive ProjectRoot.' }
        if ($PSBoundParameters.ContainsKey('ScriptingBackend')) { Add-UpvrBlocker -Code 'PREBUILT_BACKEND_INPUT_CONFLICT' -Check 'input' -Path $null -Message 'PREBUILT_STANDALONE derives backend identity only from a matching build receipt.' }
        if (-not [string]::IsNullOrWhiteSpace($UnityExecutable)) { Add-UpvrBlocker -Code 'PREBUILT_UNITY_INPUT_CONFLICT' -Check 'input' -Path $UnityExecutable -Message 'PREBUILT_STANDALONE does not accept or start UnityExecutable.' }
        if ([string]::IsNullOrWhiteSpace($BuildReceiptPath) -and $RunTimeoutSeconds -lt 10) { Add-UpvrBlocker -Code 'OPAQUE_OBSERVATION_TIMEOUT_TOO_SHORT' -Check 'timeouts' -Path $null -Message 'Opaque prebuilt observation requires RunTimeoutSeconds of at least 10.' }
    }

    if ($Mode -eq 'PREBUILT_STANDALONE') {
        try {
            $BuildRoot = Get-UpvNormalizedPath -Path $BuildRoot
            $PlayerExecutable = Get-UpvNormalizedPath -Path $PlayerExecutable
            if (-not [string]::IsNullOrWhiteSpace($BuildReceiptPath)) { $BuildReceiptPath = Get-UpvNormalizedPath -Path $BuildReceiptPath }
            $script:Result.input.projectRoot = $null
            $script:Result.input.buildRoot = $BuildRoot
            $script:Result.input.playerExecutable = $PlayerExecutable
            $script:Result.input.buildReceiptPath = $BuildReceiptPath
            $script:Result.prebuiltIdentity.buildRoot = $BuildRoot
            $script:Result.prebuiltIdentity.executablePath = $PlayerExecutable
            $script:Result.buildReceipt.requestedPath = $BuildReceiptPath
        } catch {
            Add-UpvrBlocker -Code 'PREBUILT_PATH_REJECTED' -Check 'input' -Path $PlayerExecutable -Message $_.Exception.Message
        }
    } else {
        try {
            $script:NormalizedProjectRoot = Get-UpvNormalizedPath -Path $ProjectRoot
            $script:Result.input.projectRoot = $script:NormalizedProjectRoot
            if (-not (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) { throw 'ProjectRoot is not an existing directory.' }
            if ($null -ne (Get-UpvReparsePointOnPath $script:NormalizedProjectRoot)) { throw 'ProjectRoot traverses a reparse point.' }
            foreach ($marker in @('Assets', 'Packages', 'ProjectSettings', 'ProjectSettings\ProjectVersion.txt')) {
                if (-not (Test-Path -LiteralPath (Join-Path $script:NormalizedProjectRoot $marker))) { throw "ProjectRoot is missing Unity marker $marker." }
            }
        } catch {
            Add-UpvrBlocker -Code 'PROJECT_ROOT_REJECTED' -Check 'projectRoot' -Path $ProjectRoot -Message $_.Exception.Message
        }
    }

    if ($script:Blockers.Count -eq 0) {
        $requestedArtifactsRoot = if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) { Join-Path ([System.IO.Path]::GetTempPath()) 'upvr' } else { $ArtifactsRoot }
        try { Initialize-UpvrArtifactSession -RequestedRoot $requestedArtifactsRoot } catch { Add-UpvrBlocker -Code 'ARTIFACT_ROOT_REJECTED' -Check 'artifactBoundary' -Path $requestedArtifactsRoot -Message $_.Exception.Message }
    }
    if ($Mode -eq 'PREBUILT_STANDALONE') {
        if ($script:Blockers.Count -eq 0) { Initialize-UpvrPrebuiltStandalone }
        if ($script:Blockers.Count -eq 0) { Invoke-UpvrStandalonePlayer -OpaqueObservation:([string]::IsNullOrWhiteSpace($BuildReceiptPath)) }
        if ($script:Result.processControl.standaloneRun.processStarted) {
            if ([string]::IsNullOrWhiteSpace($BuildReceiptPath)) { Set-UpvrOpaqueLaunchEvidence } else { Set-UpvrStandaloneScenarioVerificationEvidence }
        }
    } else {
        if ($script:Blockers.Count -eq 0 -and $Mode -eq 'SCENARIO_TEST_PLAYER') { Initialize-UpvrPlayerScenarioBundle }
        if ($script:Blockers.Count -eq 0 -and $Mode -eq 'INSTRUMENTED_STANDALONE') { Initialize-UpvrStandaloneScenarioBundle }
        if ($script:Blockers.Count -eq 0) { Initialize-UpvrOriginalIntegrity }
        if ($script:Blockers.Count -eq 0) { Invoke-UpvrDoctorPreflight }
        if ($script:Blockers.Count -eq 0) { Test-UpvrNoRunningUnityProcesses }
        if ($script:Blockers.Count -eq 0) {
            $localPackages = Get-UpvrLocalPackageAssessment -Root $script:NormalizedProjectRoot
            $script:Result.preflight.localPackagesSafe = $localPackages.accepted
            $script:Result.isolation.localPackageReferences = @($localPackages.references)
            if (-not $localPackages.accepted) { Add-UpvrBlocker -Code 'LOCAL_PACKAGE_SAFETY_REJECTED' -Check 'localPackages' -Path (Join-Path $script:NormalizedProjectRoot 'Packages\manifest.json') -Message ([string]::Join(' ', [string[]]@($localPackages.errors))) }
        }
        if ($script:Blockers.Count -eq 0) { Resolve-UpvrEffectiveScriptingBackend }
        if ($script:Blockers.Count -eq 0) { Test-UpvrCompatibilityAndEditor }
        if ($script:Blockers.Count -eq 0) { Copy-UpvrProjectToIsolation }
        if ($script:Blockers.Count -eq 0) {
            $isolatedPackages = Get-UpvrLocalPackageAssessment -Root $script:Result.isolation.projectCopyPath
            $script:Result.preflight.isolatedLocalPackagesSafe = $isolatedPackages.accepted
            if (-not $isolatedPackages.accepted) { Add-UpvrBlocker -Code 'ISOLATED_LOCAL_PACKAGE_SAFETY_REJECTED' -Check 'localPackages' -Path (Join-Path $script:Result.isolation.projectCopyPath 'Packages\manifest.json') -Message ([string]::Join(' ', [string[]]@($isolatedPackages.errors))) }
        }

        if ($Mode -in @('TEST_PLAYER','SCENARIO_TEST_PLAYER')) {
            if ($script:Blockers.Count -eq 0) { Add-UpvrP1InfrastructureOverlay }
            if ($script:Blockers.Count -eq 0 -and $Mode -eq 'SCENARIO_TEST_PLAYER') { Add-UpvrP2ScenarioOverlay }
            if ($script:Blockers.Count -eq 0) { Invoke-UpvrUnityTestPlayer }
            if ($script:Result.unity.processStarted) { Set-UpvrResolvedTestFrameworkIdentity }
            if ($script:Result.unity.processStarted) { Set-UpvrP1VerificationEvidence }
            if ($script:Result.unity.processStarted -and $Mode -eq 'SCENARIO_TEST_PLAYER') { Set-UpvrP2ScenarioVerificationEvidence }
        } else {
            if ($script:Blockers.Count -eq 0) { Add-UpvrP3ScenarioOverlay }
            if ($script:Blockers.Count -eq 0) { Invoke-UpvrStandaloneEditorBuild }
            if ($script:Result.unity.processStarted) { Set-UpvrResolvedTestFrameworkIdentity }
            if ($script:Result.unity.processStarted) { Set-UpvrStandaloneBuildEvidence }
            if ($script:Blockers.Count -eq 0 -and $script:Result.verification.standaloneBuild.status -eq 'VERIFIED_SUCCESS') { Invoke-UpvrStandalonePlayer }
            if ($script:Result.processControl.standaloneRun.processStarted) { Set-UpvrStandaloneScenarioVerificationEvidence }
        }
    }
} catch {
    Add-UpvrBlocker -Code 'UNEXPECTED_VERIFIER_ERROR' -Check 'verifier' -Path $script:Result.input.projectRoot -Message $_.Exception.Message
} finally {
    if ($null -ne $script:NormalizedProjectRoot -and (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) { Complete-UpvrOriginalIntegrity }
    if ($Mode -eq 'PREBUILT_STANDALONE') { Complete-UpvrPrebuiltTreeIntegrity }
    Write-UpvrResult
}
