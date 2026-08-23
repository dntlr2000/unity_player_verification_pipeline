[CmdletBinding()]
param(
    [Parameter()]
    [string]$TestRoot = 'E:\CodexTemp\unity-player-verification-unit'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repositoryRoot 'skills\codex\unity-player-verification'
$scriptsRoot = Join-Path $skillRoot 'scripts'
$runner = Join-Path $scriptsRoot 'invoke-unity-player-verification.ps1'
$schema = Join-Path $repositoryRoot 'schemas\unity-player-verification-result-1.0.0.schema.json'
$compatibilitySchema = Join-Path $repositoryRoot 'schemas\unity-player-compatibility-1.1.0.schema.json'
$scenarioSchema = Join-Path $repositoryRoot 'schemas\player-scenario-bundle-1.0.0.schema.json'
$standaloneScenarioSchema = Join-Path $repositoryRoot 'schemas\standalone-player-scenario-bundle-1.0.0.schema.json'
$compatibilityRegistry = Join-Path $skillRoot 'config\unity-player-compatibility.json'
. (Join-Path $scriptsRoot 'lib\unity-play-verification-core.ps1')
. (Join-Path $scriptsRoot 'vendor\shared\unity-process-job.ps1')
. (Join-Path $scriptsRoot 'lib\unity-player-verification-core.ps1')
. (Join-Path $scriptsRoot 'vendor\shared\json-schema-validator.ps1')

$script:Passed = 0
$script:Failed = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sessionRoot = Join-Path $TestRoot ('run-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($sessionRoot)

# Records one boolean assertion and throws immediately on failure.
function Assert-UpvrTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        $script:Failed++
        throw "ASSERTION FAILED: $Message"
    }
    $script:Passed++
}

# Records one exact scalar equality assertion.
function Assert-UpvrEqual {
    param(
        [Parameter()][AllowNull()][object]$Actual,
        [Parameter()][AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-UpvrTrue -Condition ([string]$Actual -ceq [string]$Expected) -Message "$Message Expected '$Expected', got '$Actual'."
}

# Writes one fixture file as UTF-8 without a byte-order mark.
function Write-UpvrFixtureText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [void][System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# Produces one NUnit 3 result fixture with declared strict counts.
function New-UpvrNUnitFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][int]$Passed,
        [Parameter(Mandatory = $true)][int]$Failed,
        [Parameter(Mandatory = $true)][int]$Skipped,
        [Parameter(Mandatory = $true)][int]$Inconclusive,
        [Parameter(Mandatory = $true)][string]$Result
    )

    $xml = '<test-run result="{0}" total="{1}" passed="{2}" failed="{3}" skipped="{4}" inconclusive="{5}" asserts="0" duration="0.1"></test-run>' -f $Result, $Total, $Passed, $Failed, $Skipped, $Inconclusive
    Write-UpvrFixtureText -Path $Path -Text $xml
}

# Produces one Player callback NUnit result-subtree fixture.
function New-UpvrRuntimeNUnitFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Results,
        [Parameter(Mandatory = $true)][string]$RootResult
    )

    $cases = for ($index = 0; $index -lt $Results.Count; $index++) {
        '<test-case fullname="Fixture.Test{0}" result="{1}" />' -f $index, $Results[$index]
    }
    Write-UpvrFixtureText -Path $Path -Text (('<test-suite result="{0}"><results>' -f $RootResult) + [string]::Join('', $cases) + '</results></test-suite>')
}

# Invokes the production entrypoint in a child Windows PowerShell process.
function Invoke-UpvrRunnerFixture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Runner process exited with code $LASTEXITCODE." }
    Assert-UpvrEqual -Actual @($output).Count -Expected 1 -Message 'Runner stdout must contain exactly one JSON document.'
    return ConvertFrom-Json -InputObject ([string]$output) -ErrorAction Stop
}

# Compiles an unsigned phase-aware executable for internal Job Object tests only.
function New-UpvrPhaseProcessFixture {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    $source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

internal static class Program
{
    // Writes a delayed sentinel only if a descendant survives Job Object termination.
    private static void WriteDelayedSentinel()
    {
        Thread.Sleep(2500);
        var path = Environment.GetEnvironmentVariable("UPVR_FAKE_DELAYED_SENTINEL");
        if (!String.IsNullOrWhiteSpace(path))
        {
            File.WriteAllText(path, "survived");
        }
    }

    // Writes the verifier-observed build phase transition marker.
    private static void WriteBuildSignal()
    {
        var path = Environment.GetEnvironmentVariable("UPVR_FAKE_BUILD_SIGNAL");
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllText(path, "built");
    }

    // Runs deterministic pass, timeout, failure-signal, and child-lifetime cases.
    private static int Main(string[] args)
    {
        var mode = args.Length == 0 ? String.Empty : args[0];
        if (String.Equals(mode, "--child", StringComparison.Ordinal))
        {
            WriteDelayedSentinel();
            return 0;
        }
        if (String.Equals(mode, "--pass", StringComparison.Ordinal))
        {
            Thread.Sleep(100);
            WriteBuildSignal();
            Thread.Sleep(100);
            return 0;
        }
        if (String.Equals(mode, "--run-timeout", StringComparison.Ordinal))
        {
            WriteBuildSignal();
            Process.Start(new ProcessStartInfo { FileName = Assembly.GetExecutingAssembly().Location, Arguments = "--child", UseShellExecute = false });
            Thread.Sleep(Timeout.Infinite);
        }
        if (String.Equals(mode, "--failure-signal", StringComparison.Ordinal))
        {
            WriteBuildSignal();
            Thread.Sleep(100);
            File.WriteAllText(Environment.GetEnvironmentVariable("UPVR_FAKE_FAILURE_SIGNAL"), "UPVR_FAKE_CRASH");
            Thread.Sleep(Timeout.Infinite);
        }
        Thread.Sleep(Timeout.Infinite);
        return 0;
    }
}
'@
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
    $sourcePath = [System.IO.Path]::ChangeExtension($OutputPath, '.cs')
    Write-UpvrFixtureText -Path $sourcePath -Text $source
    $windowsRoot = [Environment]::GetEnvironmentVariable('WINDIR', 'Process')
    $compiler = @(
        (Join-Path $windowsRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $windowsRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$compiler)) { throw 'A .NET Framework C# compiler is required.' }
    $output = @(& $compiler /nologo /target:exe /platform:x64 "/out:$OutputPath" $sourcePath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Phase process compilation failed: ' + [string]::Join([Environment]::NewLine, [string[]]$output) }
    return $OutputPath
}

$arguments = New-UpvrTestPlayerArguments `
    -ProjectPath 'E:\CodexValidation\p' `
    -TestResultsPath 'E:\CodexValidation\results.xml' `
    -EditorLogPath 'E:\CodexValidation\Editor.log' `
    -UpmLogPath 'E:\CodexValidation\upm.log' `
    -TestFilter 'A;B with spaces' `
    -TestCategory 'Smoke;Player' `
    -AssemblyNames 'One.Tests;Two.Tests'
Assert-UpvrTrue -Condition ($arguments -contains 'StandaloneWindows64') -Message 'Test Player argument contract must target StandaloneWindows64.'
Assert-UpvrTrue -Condition ($arguments -notcontains '-quit' -and $arguments -notcontains '-runSynchronously' -and $arguments -notcontains '-nographics') -Message 'Forbidden Unity arguments must be absent.'
$filterIndex = [array]::IndexOf($arguments, '-testFilter')
Assert-UpvrEqual -Actual $arguments[$filterIndex + 1] -Expected 'A;B with spaces' -Message 'Filter must remain one opaque argument.'

$treeRoot = Join-Path $sessionRoot 'tree'
Write-UpvrFixtureText -Path (Join-Path $treeRoot 'a.txt') -Text 'alpha'
Write-UpvrFixtureText -Path (Join-Path $treeRoot 'nested\b.txt') -Text 'beta'
$treeOne = Get-UpvrStableTreeSnapshot -Root $treeRoot
$treeTwo = Get-UpvrStableTreeSnapshot -Root $treeRoot
Assert-UpvrEqual -Actual $treeOne.treeSha256 -Expected $treeTwo.treeSha256 -Message 'Tree hashing must be deterministic.'
Assert-UpvrEqual -Actual $treeOne.fileCount -Expected 2 -Message 'Tree inventory must retain every file.'

$scenarioBundle = Join-Path $sessionRoot 'scenario-bundle'
$scenarioManifest = @'
{
  "schemaVersion": "1.0.0",
  "kind": "PLAYER_SCENARIO_BUNDLE",
  "scenarioId": "fixture-scenario",
  "displayName": "Fixture scenario",
  "timeoutSeconds": 30,
  "expectedScenes": ["P2Scene"],
  "expectedAssertionIds": ["state-ready"],
  "expectedCaptureIds": ["frame"],
  "graphicsRequired": true,
  "testFilter": "UnityPlayerVerification.PlayerScenarioTest.ExecuteScenario"
}
'@
$scenarioAsmdef = @'
{
  "name": "Upvr.Fixture.Scenario",
  "references": ["UnityPlayerVerification.Harness"],
  "includePlatforms": [],
  "allowUnsafeCode": false,
  "overrideReferences": false,
  "precompiledReferences": [],
  "autoReferenced": true
}
'@
Write-UpvrFixtureText -Path (Join-Path $scenarioBundle 'manifest.json') -Text $scenarioManifest
Write-UpvrFixtureText -Path (Join-Path $scenarioBundle 'Fixture.asmdef') -Text $scenarioAsmdef
Write-UpvrFixtureText -Path (Join-Path $scenarioBundle 'Fixture.cs') -Text 'public sealed class FixtureScenario : UnityPlayerVerification.IPlayerVerificationScenario { public System.Collections.IEnumerator Execute(UnityPlayerVerification.PlayerVerificationContext context) { yield break; } }'
$scenarioAssessment = Get-UpvrPlayerScenarioBundleAssessment -BundlePath $scenarioBundle
Assert-UpvrTrue -Condition $scenarioAssessment.accepted -Message ('A valid source-only Player scenario bundle must pass: ' + [string]::Join(' ', [string[]]@($scenarioAssessment.errors)))
Assert-UpvrEqual -Actual $scenarioAssessment.scenarioId -Expected 'fixture-scenario' -Message 'Scenario manifest identity'
Assert-UpvrEqual -Actual $scenarioAssessment.fileCount -Expected 3 -Message 'Scenario inventory count'

$scenarioDocument = Read-UpvJsonFile -Path (Join-Path $scenarioBundle 'manifest.json')
$scenarioSchemaErrors = @(Invoke-JsonSchemaValidation -Instance $scenarioDocument -SchemaPath $scenarioSchema)
Assert-UpvrEqual -Actual $scenarioSchemaErrors.Count -Expected 0 -Message 'Player scenario manifest schema validation'

$forbiddenBundle = Join-Path $sessionRoot 'forbidden-bundle'
Copy-Item -LiteralPath $scenarioBundle -Destination $forbiddenBundle -Recurse
Write-UpvrFixtureText -Path (Join-Path $forbiddenBundle 'plugin.dll') -Text 'binary fixture'
Assert-UpvrTrue -Condition (-not (Get-UpvrPlayerScenarioBundleAssessment -BundlePath $forbiddenBundle).accepted) -Message 'Scenario DLL files must be rejected.'

$osInputBundle = Join-Path $sessionRoot 'os-input-bundle'
Copy-Item -LiteralPath $scenarioBundle -Destination $osInputBundle -Recurse
Write-UpvrFixtureText -Path (Join-Path $osInputBundle 'Fixture.cs') -Text 'public sealed class FixtureScenario : UnityPlayerVerification.IPlayerVerificationScenario { public System.Collections.IEnumerator Execute(UnityPlayerVerification.PlayerVerificationContext context) { SendInput(); yield break; } private void SendInput() {} }'
Assert-UpvrTrue -Condition (-not (Get-UpvrPlayerScenarioBundleAssessment -BundlePath $osInputBundle).accepted) -Message 'OS input automation tokens must be rejected.'

$screenshotRoot = Join-Path $sessionRoot 'scenario-screenshots'
$capturePath = Join-Path $screenshotRoot 'frame.png'
Write-UpvrFixtureText -Path $capturePath -Text 'PNG fixture bytes'
$captureItem = Get-Item -LiteralPath $capturePath
$scenarioReceiptPath = Join-Path $sessionRoot 'scenario-result.json'
$scenarioReceipt = [ordered]@{
    schemaVersion='1.0.0'; sessionToken='scenario-token'; scenarioId='fixture-scenario'
    runStarted=$true; runFinished=$true; result='PASSED'; activeScene='P2Scene'; elapsedSeconds=1.0; exception=$null
    assertions=@([ordered]@{ id='state-ready'; passed=$true; detail='ready' })
    captures=@([ordered]@{ id='frame'; path=$capturePath; byteLength=[long]$captureItem.Length; sha256=(Get-UpvFileSha256 -Path $capturePath) })
}
Write-UpvrFixtureText -Path $scenarioReceiptPath -Text (ConvertTo-Json $scenarioReceipt -Depth 10 -Compress)
$scenarioReceiptAssessment = Get-UpvrPlayerScenarioReceiptAssessment -Path $scenarioReceiptPath -Manifest $scenarioAssessment -ExpectedSessionToken 'scenario-token' -ScreenshotRoot $screenshotRoot
Assert-UpvrTrue -Condition $scenarioReceiptAssessment.accepted -Message ('Matching scenario receipt and PNG must pass: ' + [string]::Join(' ', [string[]]@($scenarioReceiptAssessment.errors)))
[System.IO.File]::Delete($capturePath)
$missingCaptureAssessment = Get-UpvrPlayerScenarioReceiptAssessment -Path $scenarioReceiptPath -Manifest $scenarioAssessment -ExpectedSessionToken 'scenario-token' -ScreenshotRoot $screenshotRoot
Assert-UpvrTrue -Condition (-not $missingCaptureAssessment.accepted -and $missingCaptureAssessment.missingCaptureIds -contains 'frame') -Message 'A requested missing PNG must block scenario evidence.'

$standaloneBundle = Join-Path $sessionRoot 'standalone-bundle'
$standaloneManifest = [ordered]@{
    schemaVersion='1.0.0'; kind='STANDALONE_SCENARIO_BUNDLE'; scenarioId='fixture-standalone'
    displayName='Fixture Standalone'; timeoutSeconds=30; buildScenes=@('Assets/Scenes/Main.unity')
    expectedScenes=@('Assets/Scenes/Main.unity'); expectedAssertionIds=@('state-ready')
    expectedCaptureIds=@('frame'); graphicsRequired=$true
}
$standaloneAsmdef = @'
{
  "name": "Upvr.Fixture.StandaloneScenario",
  "references": ["UnityPlayerVerification.Harness"],
  "includePlatforms": [],
  "allowUnsafeCode": false,
  "overrideReferences": false,
  "precompiledReferences": [],
  "autoReferenced": true
}
'@
Write-UpvrFixtureText -Path (Join-Path $standaloneBundle 'manifest.json') -Text (ConvertTo-Json $standaloneManifest -Depth 10)
Write-UpvrFixtureText -Path (Join-Path $standaloneBundle 'Fixture.asmdef') -Text $standaloneAsmdef
Write-UpvrFixtureText -Path (Join-Path $standaloneBundle 'Fixture.cs') -Text 'public sealed class FixtureStandaloneScenario : UnityPlayerVerification.IPlayerVerificationScenario { public System.Collections.IEnumerator Execute(UnityPlayerVerification.PlayerVerificationContext context) { yield break; } }'
$standaloneAssessment = Get-UpvrStandaloneScenarioBundleAssessment -BundlePath $standaloneBundle
Assert-UpvrTrue -Condition $standaloneAssessment.accepted -Message ('A valid source-only Standalone scenario bundle must pass: ' + [string]::Join(' ', [string[]]@($standaloneAssessment.errors)))
Assert-UpvrEqual -Actual $standaloneAssessment.scenarioId -Expected 'fixture-standalone' -Message 'Standalone scenario manifest identity'
Assert-UpvrEqual -Actual $standaloneAssessment.buildScenes[0] -Expected 'Assets/Scenes/Main.unity' -Message 'Standalone scenario build Scene'
$standaloneSchemaErrors = @(Invoke-JsonSchemaValidation -Instance (Read-UpvJsonFile (Join-Path $standaloneBundle 'manifest.json')) -SchemaPath $standaloneScenarioSchema)
Assert-UpvrEqual -Actual $standaloneSchemaErrors.Count -Expected 0 -Message 'Standalone scenario manifest schema validation'

$standaloneForbidden = Join-Path $sessionRoot 'standalone-forbidden'
Copy-Item -LiteralPath $standaloneBundle -Destination $standaloneForbidden -Recurse
Write-UpvrFixtureText -Path (Join-Path $standaloneForbidden 'native.dll') -Text 'forbidden binary'
Assert-UpvrTrue -Condition (-not (Get-UpvrStandaloneScenarioBundleAssessment -BundlePath $standaloneForbidden).accepted) -Message 'Standalone scenario DLL files must be rejected.'

$standaloneCollision = Join-Path $sessionRoot 'standalone-reserved-asmdef'
Copy-Item -LiteralPath $standaloneBundle -Destination $standaloneCollision -Recurse
Write-UpvrFixtureText -Path (Join-Path $standaloneCollision 'Fixture.asmdef') -Text ($standaloneAsmdef.Replace('Upvr.Fixture.StandaloneScenario','UnityPlayerVerification.Attack'))
Assert-UpvrTrue -Condition (-not (Get-UpvrStandaloneScenarioBundleAssessment -BundlePath $standaloneCollision).accepted) -Message 'Standalone scenario reserved assembly names must be rejected.'

$standaloneArguments = New-UpvrStandaloneBuildArguments -ProjectPath 'E:\CodexValidation\isolated' -EditorLogPath 'E:\CodexValidation\Editor.log' -UpmLogPath 'E:\CodexValidation\upm.log'
Assert-UpvrTrue -Condition ($standaloneArguments -contains '-executeMethod' -and $standaloneArguments -contains '-quit') -Message 'Standalone build arguments must call only the fixed builder and quit.'
Assert-UpvrTrue -Condition ($standaloneArguments -notcontains '-runTests' -and $standaloneArguments -notcontains '-nographics') -Message 'Standalone build arguments must not use Test Runner or nographics.'
$standalonePlayerArguments = New-UpvrStandalonePlayerArguments -PlayerLogPath 'E:\CodexValidation\player.log'
Assert-UpvrEqual -Actual ([string]::Join('|', $standalonePlayerArguments)) -Expected '-logFile|E:\CodexValidation\player.log|-screen-fullscreen|0|-screen-width|1280|-screen-height|720' -Message 'Standalone Player fixed argument contract'

$projectBackendRoot = Join-Path $sessionRoot 'backend-project'
Write-UpvrFixtureText -Path (Join-Path $projectBackendRoot 'ProjectSettings\ProjectSettings.asset') -Text "PlayerSettings:`n  scriptingBackend:`n    Standalone: 1`n  il2cppCompilerConfiguration: {}`n"
$projectBackend = Get-UpvrProjectScriptingBackendAssessment -ProjectRoot $projectBackendRoot
Assert-UpvrTrue -Condition ($projectBackend.accepted -and $projectBackend.backend -eq 'IL2CPP') -Message 'Serialized Project backend must resolve IL2CPP without opening Unity.'

$moduleFixtureEditor = Join-Path $sessionRoot 'module-fixture\Editor'
$moduleFixtureUnity = Join-Path $moduleFixtureEditor 'Unity.exe'
$moduleFixtureRoot = Join-Path $moduleFixtureEditor 'Data\PlaybackEngines\windowsstandalonesupport'
Write-UpvrFixtureText -Path $moduleFixtureUnity -Text 'module identity fixture'
[void][System.IO.Directory]::CreateDirectory((Join-Path $moduleFixtureEditor 'Data\il2cpp'))
Write-UpvrFixtureText -Path (Join-Path $moduleFixtureRoot 'Variations\win64_player_nondevelopment_mono\player.marker') -Text 'mono variation'
$monoOnlyModule = Get-UpvrWindowsStandaloneModuleIdentity -UnityExecutablePath $moduleFixtureUnity
Assert-UpvrTrue -Condition ($monoOnlyModule.accepted -and $monoOnlyModule.monoAvailable) -Message 'The exact Windows x64 non-development Mono variation must be detected.'
Assert-UpvrTrue -Condition (-not $monoOnlyModule.il2cppAvailable) -Message 'Editor/Data/il2cpp alone must not be mistaken for Windows x64 IL2CPP Build Support.'
Write-UpvrFixtureText -Path (Join-Path $moduleFixtureRoot 'Variations\win64_player_nondevelopment_il2cpp\player.marker') -Text 'il2cpp variation'
$dualBackendModule = Get-UpvrWindowsStandaloneModuleIdentity -UnityExecutablePath $moduleFixtureUnity
Assert-UpvrTrue -Condition ($dualBackendModule.il2cppAvailable -and @($dualBackendModule.il2cppVariationPaths).Count -eq 1) -Message 'The exact Windows x64 non-development IL2CPP variation must be detected.'

$nunitCases = @(
    [pscustomobject]@{ Name='pass'; Total=1; Passed=1; Failed=0; Skipped=0; Inconclusive=0; Result='Passed'; Class='PASSED' },
    [pscustomobject]@{ Name='fail'; Total=1; Passed=0; Failed=1; Skipped=0; Inconclusive=0; Result='Failed'; Class='FAILED' },
    [pscustomobject]@{ Name='skip'; Total=1; Passed=0; Failed=0; Skipped=1; Inconclusive=0; Result='Passed'; Class='INCOMPLETE' },
    [pscustomobject]@{ Name='inconclusive'; Total=1; Passed=0; Failed=0; Skipped=0; Inconclusive=1; Result='Inconclusive'; Class='INCOMPLETE' },
    [pscustomobject]@{ Name='zero'; Total=0; Passed=0; Failed=0; Skipped=0; Inconclusive=0; Result='Passed'; Class='ZERO_TESTS' }
)
foreach ($case in $nunitCases) {
    $path = Join-Path $sessionRoot ("$($case.Name).xml")
    New-UpvrNUnitFixture -Path $path -Total $case.Total -Passed $case.Passed -Failed $case.Failed -Skipped $case.Skipped -Inconclusive $case.Inconclusive -Result $case.Result
    Assert-UpvrEqual -Actual (Get-UpvNUnitAnalysis $path).classification -Expected $case.Class -Message "NUnit $($case.Name) classification"
}
$invalidXml = Join-Path $sessionRoot 'invalid.xml'
Write-UpvrFixtureText -Path $invalidXml -Text '<broken'
Assert-UpvrEqual -Actual (Get-UpvNUnitAnalysis $invalidXml).classification -Expected 'INVALID' -Message 'Malformed NUnit must be invalid.'
Assert-UpvrEqual -Actual (Get-UpvNUnitAnalysis (Join-Path $sessionRoot 'missing.xml')).classification -Expected 'NOT_ANALYZED' -Message 'Missing NUnit must not be analyzed.'

$runtimePass = Join-Path $sessionRoot 'runtime-pass.xml'
New-UpvrRuntimeNUnitFixture -Path $runtimePass -Results @('Passed') -RootResult 'Passed'
$runtimeAnalysis = Get-UpvrRuntimeNUnitAnalysis $runtimePass
Assert-UpvrEqual -Actual $runtimeAnalysis.classification -Expected 'PASSED' -Message 'Runtime NUnit subtree pass classification'
$connectionPass = Get-UpvNUnitAnalysis (Join-Path $sessionRoot 'pass.xml')
Assert-UpvrTrue -Condition (Get-UpvrNUnitAgreementAssessment $connectionPass $runtimeAnalysis).accepted -Message 'Equivalent independent NUnit summaries must agree.'
$runtimeFail = Join-Path $sessionRoot 'runtime-fail.xml'
New-UpvrRuntimeNUnitFixture -Path $runtimeFail -Results @('Failed') -RootResult 'Failed'
Assert-UpvrTrue -Condition (-not (Get-UpvrNUnitAgreementAssessment $connectionPass (Get-UpvrRuntimeNUnitAnalysis $runtimeFail)).accepted) -Message 'Conflicting independent NUnit summaries must block.'

$buildExe = Join-Path $sessionRoot 'build\TestPlayer.exe'
Write-UpvrFixtureText -Path $buildExe -Text 'MZ fixture'
$buildReportPath = Join-Path $sessionRoot 'build-report.json'
$buildReport = [ordered]@{
    schemaVersion='1.0.0'; sessionToken='token'; result='Succeeded'; outputPath=$buildExe
    platform='StandaloneWindows64'; scriptingBackend='Mono2x'; buildGuid='guid'; totalSize=10
    totalErrors=0; totalWarnings=0; startedAtUtc='2026-08-23T00:00:00.0000000Z'; durationSeconds=1.0
}
Write-UpvrFixtureText -Path $buildReportPath -Text (ConvertTo-Json $buildReport -Compress)
Assert-UpvrTrue -Condition (Get-UpvrBuildReportAssessment $buildReportPath 'token' $buildExe 'Mono').accepted -Message 'Matching successful build report must pass.'
Assert-UpvrTrue -Condition (-not (Get-UpvrBuildReportAssessment $buildReportPath 'wrong' $buildExe 'Mono').accepted) -Message 'Build report session mismatch must block.'

$runtimeReceiptPath = Join-Path $sessionRoot 'runtime-receipt.json'
$runtimeReceipt = [ordered]@{
    schemaVersion='1.0.0'; sessionToken='token'; runStarted=$true; runFinished=$true; resultState='Passed'
    nunitPath=$runtimePass; unityVersion='6000.0.69f1'; productName='Fixture'; processId=123; error=$null
}
Write-UpvrFixtureText -Path $runtimeReceiptPath -Text (ConvertTo-Json $runtimeReceipt -Compress)
Assert-UpvrTrue -Condition (Get-UpvrRuntimeTestReceiptAssessment $runtimeReceiptPath 'token' $runtimePass '6000.0.69f1').accepted -Message 'Matching runtime receipt must pass.'
Assert-UpvrTrue -Condition (-not (Get-UpvrRuntimeTestReceiptAssessment $runtimeReceiptPath 'wrong' $runtimePass '6000.0.69f1').accepted) -Message 'Runtime receipt session mismatch must block.'

Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'CHANGED' 'UNCHANGED' 1 1 'BLOCKED' @()) -Expected 'ORIGINAL_PROJECT_CHANGED' -Message 'Original change must have first precedence.'
Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'UNCHANGED' 'UNCHANGED' 1 1 'VERIFIED_SUCCESS' @('VERIFIED_FAILURE')) -Expected 'VERIFICATION_BLOCKED' -Message 'Blockers must precede failures.'
Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'UNCHANGED' 'UNCHANGED' 0 1 'VERIFIED_SUCCESS' @('VERIFIED_FAILURE')) -Expected 'PLAYER_FAILED' -Message 'Concrete failure must produce PLAYER_FAILED.'
Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'UNCHANGED' 'UNCHANGED' 0 0 'VERIFIED_SUCCESS' @('VERIFIED_SUCCESS')) -Expected 'PLAYER_VERIFIED' -Message 'Complete evidence must verify Player.'
Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'UNCHANGED' 'UNCHANGED' 0 0 'VERIFIED_SUCCESS' @('VERIFIED_SUCCESS') -LaunchOnly) -Expected 'PLAYER_LAUNCH_VERIFIED' -Message 'Opaque launch success must remain launch-only.'
Assert-UpvrEqual -Actual (Get-UpvrFinalStatusAssessment 'NOT_VERIFIED' 'NOT_VERIFIED' 0 0 'NOT_VERIFIED' @('VERIFIED_SUCCESS') -LaunchOnly -CompatibilityNotRequired) -Expected 'PLAYER_LAUNCH_VERIFIED' -Message 'Explicit prebuilt launch must not require project compatibility evidence.'

$phaseFixture = New-UpvrPhaseProcessFixture -OutputPath (Join-Path $sessionRoot 'phase-process\PhaseProcess.exe')
$buildSignal = Join-Path $sessionRoot 'phase-process\build.signal'
$failureSignal = Join-Path $sessionRoot 'phase-process\failure.log'
$delayedSentinel = Join-Path $sessionRoot 'phase-process\child-survived.txt'
$previousBuildSignal = [Environment]::GetEnvironmentVariable('UPVR_FAKE_BUILD_SIGNAL', 'Process')
$previousFailureSignal = [Environment]::GetEnvironmentVariable('UPVR_FAKE_FAILURE_SIGNAL', 'Process')
$previousDelayedSentinel = [Environment]::GetEnvironmentVariable('UPVR_FAKE_DELAYED_SENTINEL', 'Process')
try {
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_BUILD_SIGNAL', $buildSignal, 'Process')
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_FAILURE_SIGNAL', $failureSignal, 'Process')
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_DELAYED_SENTINEL', $delayedSentinel, 'Process')

    $phasePass = Invoke-UnityProcessInJob -ExecutablePath $phaseFixture -Arguments @('--pass') -WorkingDirectory $sessionRoot -StandardOutputPath (Join-Path $sessionRoot 'phase-pass.out') -StandardErrorPath (Join-Path $sessionRoot 'phase-pass.err') -TimeoutSeconds 10 -BuildCompletionPath $buildSignal -BuildTimeoutSeconds 3 -RunTimeoutSeconds 3
    Assert-UpvrTrue -Condition ($phasePass.buildPhaseCompleted -and -not $phasePass.timedOut -and $phasePass.processTreeExitVerified) -Message 'Phase-aware Job Object success must observe build transition and zero remaining processes.'

    $buildTimeoutSignal = Join-Path $sessionRoot 'phase-process\never-built.signal'
    $phaseBuildTimeout = Invoke-UnityProcessInJob -ExecutablePath $phaseFixture -Arguments @('--build-timeout') -WorkingDirectory $sessionRoot -StandardOutputPath (Join-Path $sessionRoot 'phase-build-timeout.out') -StandardErrorPath (Join-Path $sessionRoot 'phase-build-timeout.err') -TimeoutSeconds 10 -BuildCompletionPath $buildTimeoutSignal -BuildTimeoutSeconds 1 -RunTimeoutSeconds 3
    Assert-UpvrTrue -Condition ($phaseBuildTimeout.timedOut -and $phaseBuildTimeout.timeoutPhase -eq 'BUILD' -and $phaseBuildTimeout.processTreeExitVerified) -Message 'Build deadline must terminate the Job Object and identify BUILD phase.'

    if (Test-Path -LiteralPath $buildSignal) { [System.IO.File]::Delete($buildSignal) }
    $phaseRunTimeout = Invoke-UnityProcessInJob -ExecutablePath $phaseFixture -Arguments @('--run-timeout') -WorkingDirectory $sessionRoot -StandardOutputPath (Join-Path $sessionRoot 'phase-run-timeout.out') -StandardErrorPath (Join-Path $sessionRoot 'phase-run-timeout.err') -TimeoutSeconds 10 -BuildCompletionPath $buildSignal -BuildTimeoutSeconds 3 -RunTimeoutSeconds 1
    Start-Sleep -Milliseconds 3000
    Assert-UpvrTrue -Condition ($phaseRunTimeout.timedOut -and $phaseRunTimeout.timeoutPhase -eq 'RUN' -and $phaseRunTimeout.processTreeExitVerified) -Message 'Run deadline must terminate the parent and descendant process tree.'
    Assert-UpvrTrue -Condition (-not (Test-Path -LiteralPath $delayedSentinel)) -Message 'A terminated child process must not write its delayed sentinel.'

    if (Test-Path -LiteralPath $buildSignal) { [System.IO.File]::Delete($buildSignal) }
    $phaseFailure = Invoke-UnityProcessInJob -ExecutablePath $phaseFixture -Arguments @('--failure-signal') -WorkingDirectory $sessionRoot -StandardOutputPath (Join-Path $sessionRoot 'phase-failure.out') -StandardErrorPath (Join-Path $sessionRoot 'phase-failure.err') -TimeoutSeconds 10 -BuildCompletionPath $buildSignal -BuildTimeoutSeconds 3 -RunTimeoutSeconds 3 -FailureSignalPath $failureSignal -FailureSignalPattern 'UPVR_FAKE_CRASH'
    Assert-UpvrTrue -Condition ($phaseFailure.failureSignalObserved -and -not $phaseFailure.timedOut -and $phaseFailure.processTreeExitVerified) -Message 'Concrete failure signal must stop the tree without being mislabeled a timeout.'
} finally {
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_BUILD_SIGNAL', $previousBuildSignal, 'Process')
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_FAILURE_SIGNAL', $previousFailureSignal, 'Process')
    [Environment]::SetEnvironmentVariable('UPVR_FAKE_DELAYED_SENTINEL', $previousDelayedSentinel, 'Process')
}

$prebuiltRoot = Join-Path $sessionRoot 'prebuilt'
$prebuiltExe = Join-Path $prebuiltRoot 'FixtureGame.exe'
[void][System.IO.Directory]::CreateDirectory((Join-Path $prebuiltRoot 'FixtureGame_Data'))
[System.IO.File]::Copy($phaseFixture, $prebuiltExe, $false)
Write-UpvrFixtureText -Path (Join-Path $prebuiltRoot 'FixtureGame_Data\globalgamemanagers') -Text 'fixture data'
$prebuiltIdentity = Get-UpvrPrebuiltIdentityAssessment -BuildRoot $prebuiltRoot -PlayerExecutable $prebuiltExe
Assert-UpvrTrue -Condition $prebuiltIdentity.accepted -Message ('A valid explicit x64 PE and matching Data directory must pass: ' + [string]::Join(' ', [string[]]@($prebuiltIdentity.errors)))
Assert-UpvrEqual -Actual $prebuiltIdentity.machine -Expected '0x8664' -Message 'Prebuilt PE machine identity'
$prebuiltJunction = Join-Path $sessionRoot 'prebuilt-junction'
[void](New-Item -ItemType Junction -Path $prebuiltJunction -Target $prebuiltRoot -ErrorAction Stop)
$junctionExecutable = Join-Path $prebuiltJunction 'FixtureGame.exe'
Assert-UpvrTrue -Condition (-not (Get-UpvrPrebuiltIdentityAssessment -BuildRoot $prebuiltJunction -PlayerExecutable $junctionExecutable).accepted) -Message 'Prebuilt inputs that traverse a reparse point must be rejected.'

$standaloneReportPath = Join-Path $sessionRoot 'standalone-build-report.json'
$standaloneReport = [ordered]@{
    schemaVersion='1.0.0'; sessionToken='standalone-token'; result='Succeeded'; outputPath=$prebuiltExe
    platform='StandaloneWindows64'; scriptingBackend='Mono'; buildGuid='fixture-guid'; totalSize=10
    totalErrors=0; totalWarnings=1; errors=@(); warnings=@('fixture warning')
    startedAtUtc='2026-08-23T00:00:00.0000000Z'; durationSeconds=2.0
}
Write-UpvrFixtureText -Path $standaloneReportPath -Text (ConvertTo-Json $standaloneReport -Compress)
Assert-UpvrTrue -Condition (Get-UpvrStandaloneBuildReportAssessment -Path $standaloneReportPath -ExpectedSessionToken 'standalone-token' -ExpectedExecutablePath $prebuiltExe -ExpectedBackend Mono).accepted -Message 'Matching Standalone BuildReport receipt must pass.'

$standaloneReceiptPath = Join-Path $sessionRoot 'standalone-build-receipt.json'
$standaloneReceipt = [ordered]@{
    schemaVersion='1.0.0'; sessionToken='standalone-token'; originalFingerprint=('a' * 64)
    overlayTreeSha256=('b' * 64); scenarioBundleTreeSha256=('c' * 64); unityVersion='6000.0.69f1'
    windowsModuleTreeSha256=('d' * 64); toolchainIdentitySha256=$null; scriptingBackend='Mono'
    scenes=@('Assets/Scenes/Main.unity'); buildOptions='None'; developmentBuild=$false; buildGuid='fixture-guid'
    executablePath=$prebuiltExe; executableSha256=(Get-UpvFileSha256 $prebuiltExe); buildRoot=$prebuiltRoot
    treeCanonicalization='upvr-tree-relative-path-length-sha256-lf-v1'
    buildTreeSha256=$prebuiltIdentity.tree.treeSha256; fileCount=$prebuiltIdentity.tree.fileCount
    directoryCount=$prebuiltIdentity.tree.directoryCount; totalBytes=$prebuiltIdentity.tree.totalBytes
    scenario=[ordered]@{
        scenarioId='fixture-standalone'; displayName='Fixture Standalone'; timeoutSeconds=30
        buildScenes=@('Assets/Scenes/Main.unity'); expectedScenes=@('Assets/Scenes/Main.unity')
        expectedAssertionIds=@('state-ready'); expectedCaptureIds=@('frame'); graphicsRequired=$true
    }
}
Write-UpvrFixtureText -Path $standaloneReceiptPath -Text (ConvertTo-Json $standaloneReceipt -Depth 10)
$standaloneReceiptAssessment = Get-UpvrStandaloneBuildReceiptAssessment -Path $standaloneReceiptPath -ExpectedSessionToken 'standalone-token' -ExpectedBuildRoot $prebuiltRoot -ExpectedExecutablePath $prebuiltExe -ExpectedOriginalFingerprint ('a' * 64) -ExpectedOverlayTreeSha256 ('b' * 64) -ExpectedScenarioBundleTreeSha256 ('c' * 64) -ExpectedWindowsModuleTreeSha256 ('d' * 64) -ExpectedBackend Mono -CurrentTree $prebuiltIdentity.tree
Assert-UpvrTrue -Condition $standaloneReceiptAssessment.accepted -Message ('Matching Standalone build receipt must pass: ' + [string]::Join(' ', [string[]]@($standaloneReceiptAssessment.errors)))
Write-UpvrFixtureText -Path (Join-Path $prebuiltRoot 'tampered.txt') -Text 'post-build mutation'
$tamperedTree = Get-UpvrStableTreeSnapshot -Root $prebuiltRoot
Assert-UpvrTrue -Condition (-not (Get-UpvrStandaloneBuildReceiptAssessment -Path $standaloneReceiptPath -ExpectedBuildRoot $prebuiltRoot -ExpectedExecutablePath $prebuiltExe -ExpectedBackend Project -CurrentTree $tamperedTree).accepted) -Message 'Post-build full-tree mutation must invalidate a retained build receipt.'

$standaloneLogPath = Join-Path $sessionRoot 'standalone-player.log'
Write-UpvrFixtureText -Path $standaloneLogPath -Text "UPVR_STANDALONE_SCENARIO_STARTED fixture`nUPVR_STANDALONE_SCENARIO_FINISHED PASSED`n"
$standaloneLog = Get-UpvrPlayerLogAnalysis -Path $standaloneLogPath
Assert-UpvrTrue -Condition ($standaloneLog.classification -eq 'SAFE' -and $standaloneLog.standaloneStartedMarker -and $standaloneLog.standaloneFinishedMarker) -Message 'Standalone runtime marker pair must classify the Player log as safe.'

$compatibilityDocument = Read-UpvJsonFile $compatibilityRegistry
$compatibilityErrors = @(Invoke-JsonSchemaValidation -Instance $compatibilityDocument -SchemaPath $compatibilitySchema)
Assert-UpvrEqual -Actual $compatibilityErrors.Count -Expected 0 -Message 'Compatibility registry schema validation'
$monoCompatibility = Get-UpvrCompatibilityAssessment -RegistryPath $compatibilityRegistry -UnityVersion '6000.0.69f1' -TestFrameworkVersion '1.6.0' -ScriptingBackend Mono
Assert-UpvrTrue -Condition ($monoCompatibility.approved -and $null -eq $monoCompatibility.toolchainIdentitySha256) -Message 'Mono compatibility must be approved without an external native toolchain identity.'
$il2cppCompatibility = Get-UpvrCompatibilityAssessment -RegistryPath $compatibilityRegistry -UnityVersion '6000.0.69f1' -TestFrameworkVersion '1.6.0' -ScriptingBackend IL2CPP
Assert-UpvrTrue -Condition (-not $il2cppCompatibility.entryFound -and -not $il2cppCompatibility.approved) -Message 'An IL2CPP tuple without completed real-Unity approval must remain absent and fail closed.'
$il2cppRegistryFixture = Join-Path $sessionRoot 'il2cpp-compatibility-fixture.json'
$il2cppRegistryDocument = [ordered]@{
    schemaVersion = '1.1.0'
    entries = @([ordered]@{
        unityVersion='6000.0.69f1'; testFrameworkVersion='1.6.0'; allowedSourceKind='builtin'; registryOrigin=$null
        unityExecutableSha256=('a' * 64); packageTreeSha256=('b' * 64)
        packageHashCanonicalization='upv-package-tree-relative-path-length-sha256-lf-v1'
        target='StandaloneWindows64'; scriptingBackend='IL2CPP'; windowsModuleTreeSha256=('c' * 64)
        moduleHashCanonicalization='upvr-tree-relative-path-length-sha256-lf-v1'; toolchainIdentitySha256=('d' * 64)
        visualStudioVersion='17.14.36915.13'; msvcVersion='14.44.35207'; windowsSdkVersion='10.0.26100.0'
        minimumPhase='P3'; status='APPROVED'; evidencePath='fixture-evidence.md'
    })
}
Write-UpvrFixtureText -Path $il2cppRegistryFixture -Text (ConvertTo-Json $il2cppRegistryDocument -Depth 8)
$approvedIl2cppFixture = Get-UpvrCompatibilityAssessment -RegistryPath $il2cppRegistryFixture -UnityVersion '6000.0.69f1' -TestFrameworkVersion '1.6.0' -ScriptingBackend IL2CPP
Assert-UpvrTrue -Condition ($approvedIl2cppFixture.approved -and [string]$approvedIl2cppFixture.toolchainIdentitySha256 -match '^[0-9a-f]{64}$') -Message 'An approved IL2CPP compatibility entry must pin one exact external native toolchain identity.'

$blockedResult = Invoke-UpvrRunnerFixture -Arguments @('-Mode','SCENARIO_TEST_PLAYER','-ProjectRoot','E:\does-not-exist','-ArtifactsRoot',(Join-Path $sessionRoot 'blocked-artifacts'))
Assert-UpvrEqual -Actual $blockedResult.finalStatus -Expected 'VERIFICATION_BLOCKED' -Message 'A missing scenario bundle and project must fail closed.'
$resultSchemaErrors = @(Invoke-JsonSchemaValidation -Instance $blockedResult -SchemaPath $schema)
Assert-UpvrEqual -Actual $resultSchemaErrors.Count -Expected 0 -Message 'Blocked production result schema validation'

$scenarioSelectorConflict = Invoke-UpvrRunnerFixture -Arguments @('-Mode','INSTRUMENTED_STANDALONE','-ProjectRoot','E:\does-not-exist','-ScenarioBundlePath',$standaloneBundle,'-TestFilter','Fixture','-ArtifactsRoot',(Join-Path $sessionRoot 'scenario-selector-conflict'))
Assert-UpvrTrue -Condition (@($scenarioSelectorConflict.blockers | Where-Object { $_.code -eq 'SCENARIO_SELECTOR_CONFLICT' }).Count -eq 1) -Message 'Scenario modes must reject all test selector combinations.'
$projectPrebuiltConflict = Invoke-UpvrRunnerFixture -Arguments @('-Mode','TEST_PLAYER','-ProjectRoot','E:\does-not-exist','-BuildRoot','E:\prebuilt','-PlayerExecutable','E:\prebuilt\Game.exe','-ArtifactsRoot',(Join-Path $sessionRoot 'project-prebuilt-conflict'))
Assert-UpvrTrue -Condition (@($projectPrebuiltConflict.blockers | Where-Object { $_.code -eq 'PROJECT_PREBUILT_INPUT_CONFLICT' }).Count -eq 1) -Message 'Project modes must reject prebuilt input parameters.'
$missingPrebuiltInput = Invoke-UpvrRunnerFixture -Arguments @('-Mode','PREBUILT_STANDALONE','-ArtifactsRoot',(Join-Path $sessionRoot 'missing-prebuilt-input'))
Assert-UpvrTrue -Condition (@($missingPrebuiltInput.blockers | Where-Object { $_.code -eq 'PREBUILT_INPUT_REQUIRED' }).Count -eq 1) -Message 'Prebuilt mode must require an explicit build root and executable.'
Assert-UpvrTrue -Condition ($null -eq $missingPrebuiltInput.input.scriptingBackend -and $null -eq $missingPrebuiltInput.build.scriptingBackend) -Message 'Opaque prebuilt input must not inherit an unverified default backend identity.'
$prebuiltScenarioConflict = Invoke-UpvrRunnerFixture -Arguments @('-Mode','PREBUILT_STANDALONE','-BuildRoot',$prebuiltRoot,'-PlayerExecutable',$prebuiltExe,'-ScenarioBundlePath',$standaloneBundle,'-ArtifactsRoot',(Join-Path $sessionRoot 'prebuilt-scenario-conflict'))
Assert-UpvrTrue -Condition (@($prebuiltScenarioConflict.blockers | Where-Object { $_.code -eq 'PREBUILT_SELECTION_CONFLICT' }).Count -eq 1) -Message 'Prebuilt mode must reject source scenario and test-selection inputs.'
$prebuiltProjectConflict = Invoke-UpvrRunnerFixture -Arguments @('-Mode','PREBUILT_STANDALONE','-ProjectRoot','E:\does-not-exist','-BuildRoot',$prebuiltRoot,'-PlayerExecutable',$prebuiltExe,'-ArtifactsRoot',(Join-Path $sessionRoot 'prebuilt-project-conflict'))
Assert-UpvrTrue -Condition (@($prebuiltProjectConflict.blockers | Where-Object { $_.code -eq 'PREBUILT_PROJECT_INPUT_CONFLICT' }).Count -eq 1) -Message 'Prebuilt mode must reject an explicitly supplied project root.'
$prebuiltBackendConflict = Invoke-UpvrRunnerFixture -Arguments @('-Mode','PREBUILT_STANDALONE','-BuildRoot',$prebuiltRoot,'-PlayerExecutable',$prebuiltExe,'-ScriptingBackend','IL2CPP','-ArtifactsRoot',(Join-Path $sessionRoot 'prebuilt-backend-conflict'))
Assert-UpvrTrue -Condition (@($prebuiltBackendConflict.blockers | Where-Object { $_.code -eq 'PREBUILT_BACKEND_INPUT_CONFLICT' }).Count -eq 1) -Message 'Prebuilt mode must derive backend identity from a retained receipt instead of a caller assertion.'

$fixtureSource = Join-Path $PSScriptRoot 'fixtures\unity-minimal-clean'
$unsignedProject = Join-Path $sessionRoot 'unsigned-project'
Copy-Item -LiteralPath $fixtureSource -Destination $unsignedProject -Recurse
Write-UpvrFixtureText -Path (Join-Path $unsignedProject 'ProjectSettings\ProjectVersion.txt') -Text "m_EditorVersion: 2022.3.62f3`nm_EditorVersionWithRevision: 2022.3.62f3 (fixture)"
$fakeUnity = Join-Path $sessionRoot 'fake\Unity.exe'
Write-UpvrFixtureText -Path $fakeUnity -Text 'unsigned fake Unity'
if (@(Get-Process -Name Unity -ErrorAction SilentlyContinue).Count -eq 0) {
    $unsignedResult = Invoke-UpvrRunnerFixture -Arguments @('-Mode','TEST_PLAYER','-ProjectRoot',$unsignedProject,'-UnityExecutable',$fakeUnity,'-ArtifactsRoot',(Join-Path $sessionRoot 'unsigned-artifacts'))
    Assert-UpvrEqual -Actual $unsignedResult.finalStatus -Expected 'VERIFICATION_BLOCKED' -Message 'Unsigned fake Unity must be blocked.'
    Assert-UpvrTrue -Condition (-not [bool]$unsignedResult.unity.processStarted) -Message 'Unsigned fake Unity must never start.'
} else {
    Write-Warning 'Unsigned fake production test skipped because a pre-existing Unity process would trigger the earlier process-safety blocker.'
}

Write-Host ("Unity Player Verification unit tests passed. Assertions: {0}; failures: {1}; artifacts: {2}" -f $script:Passed, $script:Failed, $sessionRoot)
