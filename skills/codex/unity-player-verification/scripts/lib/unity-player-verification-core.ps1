Set-StrictMode -Version Latest

$script:UpvrUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UpvrTreeCanonicalization = 'upvr-tree-relative-path-length-sha256-lf-v1'

# Returns true when an absolute Windows path is located on the C drive.
function Test-UpvrCDrivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-UpvNormalizedPath -Path $Path
    return [string]::Equals([System.IO.Path]::GetPathRoot($normalized), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Creates a deterministic, reparse-safe inventory and tree digest for one directory.
function Get-UpvrTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter()][string[]]$ExcludedRelativePrefixes = @()
    )

    $normalizedRoot = Get-UpvNormalizedPath -Path $Root
    if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
        throw "Tree root is not an existing directory: $normalizedRoot"
    }
    if ($null -ne (Get-UpvReparsePointOnPath -Path $normalizedRoot)) {
        throw "Tree root traverses a reparse point: $normalizedRoot"
    }

    $files = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([System.StringComparer]::Ordinal)
    $directories = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    $pending = New-Object System.Collections.Stack
    $pending.Push($normalizedRoot)
    while ($pending.Count -gt 0) {
        $current = [string]$pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop | Sort-Object -Property Name)) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Tree contains a forbidden reparse point: $($entry.FullName)"
            }
            $relative = $entry.FullName.Substring($normalizedRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $excluded = $false
            foreach ($prefix in $ExcludedRelativePrefixes) {
                $cleanPrefix = ([string]$prefix).Trim('/').Replace('\', '/')
                if ($relative -ceq $cleanPrefix -or $relative.StartsWith($cleanPrefix + '/', [System.StringComparison]::Ordinal)) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) {
                continue
            }
            if ($entry.PSIsContainer) {
                [void]$directories.Add($relative)
                $pending.Push($entry.FullName)
            } else {
                $files.Add($relative, [pscustomobject][ordered]@{
                    path = $relative
                    length = [long]$entry.Length
                    sha256 = Get-UpvFileSha256 -Path $entry.FullName
                })
            }
        }
    }

    $sortedDirectories = [string[]]@($directories)
    $sortedFiles = [object[]]@($files.Values)
    $canonical = New-Object System.Collections.ArrayList
    foreach ($directory in $sortedDirectories) {
        [void]$canonical.Add("D|$($script:UpvrUtf8NoBom.GetByteCount($directory))|$directory")
    }
    foreach ($file in $sortedFiles) {
        [void]$canonical.Add("F|$($script:UpvrUtf8NoBom.GetByteCount([string]$file.path))|$($file.path)|$($file.length)|$($file.sha256)")
    }
    return [pscustomobject][ordered]@{
        root = $normalizedRoot
        canonicalization = $script:UpvrTreeCanonicalization
        directoryCount = $sortedDirectories.Count
        fileCount = $sortedFiles.Count
        totalBytes = [long](($sortedFiles | Measure-Object -Property length -Sum).Sum)
        directories = $sortedDirectories
        files = $sortedFiles
        treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]@($canonical)))
    }
}

# Repeats a directory snapshot until two consecutive tree digests match.
function Get-UpvrStableTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter()][string[]]$ExcludedRelativePrefixes = @(),
        [Parameter()][ValidateRange(2, 5)][int]$MaximumAttempts = 3
    )

    $previous = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $current = Get-UpvrTreeSnapshot -Root $Root -ExcludedRelativePrefixes $ExcludedRelativePrefixes
        if ($null -ne $previous -and $previous.treeSha256 -ceq $current.treeSha256) {
            $current | Add-Member -NotePropertyName snapshotAttempts -NotePropertyValue $attempt
            return $current
        }
        $previous = $current
    }
    throw "Tree changed during $MaximumAttempts consecutive snapshot attempts: $Root"
}

# Resolves the Windows Standalone Support module bound to one Unity executable.
function Get-UpvrWindowsStandaloneModuleIdentity {
    param([Parameter(Mandatory = $true)][string]$UnityExecutablePath)

    $unityPath = Get-UpvNormalizedPath -Path $UnityExecutablePath
    $editorRoot = Split-Path -Parent $unityPath
    $moduleRoot = Join-Path -Path $editorRoot -ChildPath 'Data\PlaybackEngines\windowsstandalonesupport'
    $result = [ordered]@{
        root = $moduleRoot
        target = 'StandaloneWindows64'
        exists = $false
        fileCount = 0
        totalBytes = 0
        canonicalization = $script:UpvrTreeCanonicalization
        treeSha256 = $null
        monoAvailable = $false
        il2cppAvailable = $false
        accepted = $false
        error = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
            throw 'Windows Standalone Support module is not installed for the selected Unity editor.'
        }
        $snapshot = Get-UpvrStableTreeSnapshot -Root $moduleRoot
        $result.exists = $true
        $result.fileCount = $snapshot.fileCount
        $result.totalBytes = $snapshot.totalBytes
        $result.treeSha256 = $snapshot.treeSha256
        $result.monoAvailable = Test-Path -LiteralPath (Join-Path $moduleRoot 'Variations\win64_player_nondevelopment_mono') -PathType Container
        if (-not $result.monoAvailable) {
            $result.monoAvailable = @($snapshot.directories | Where-Object { $_ -match '(?i)win64.*mono' }).Count -gt 0
        }
        $result.il2cppAvailable = Test-Path -LiteralPath (Join-Path $editorRoot 'Data\il2cpp') -PathType Container
        if (-not $result.monoAvailable) {
            throw 'The Windows Standalone module does not contain a Windows x64 Mono variation.'
        }
        $result.accepted = $true
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Matches one exact Editor, Test Framework, module, target, and backend tuple.
function Get-UpvrCompatibilityAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$UnityVersion,
        [Parameter(Mandatory = $true)][string]$TestFrameworkVersion,
        [Parameter(Mandatory = $true)][ValidateSet('Mono', 'IL2CPP')][string]$ScriptingBackend
    )

    $result = [ordered]@{
        registryPath = Get-UpvNormalizedPath -Path $RegistryPath
        registrySchemaVersion = $null
        unityVersion = $UnityVersion
        testFrameworkVersion = $TestFrameworkVersion
        target = 'StandaloneWindows64'
        scriptingBackend = $ScriptingBackend
        entryFound = $false
        entryStatus = $null
        minimumPhase = $null
        allowedSourceKind = $null
        registryOrigin = $null
        unityExecutableSha256 = $null
        packageTreeSha256 = $null
        packageHashCanonicalization = $null
        windowsModuleTreeSha256 = $null
        moduleHashCanonicalization = $null
        evidencePath = $null
        approved = $false
        error = $null
    }
    try {
        $registry = Read-UpvJsonFile -Path $RegistryPath
        $result.registrySchemaVersion = [string](Get-UpvJsonProperty -InputObject $registry -Name 'schemaVersion')
        if ($result.registrySchemaVersion -cne '1.0.0') {
            throw 'Player compatibility registry schemaVersion must be 1.0.0.'
        }
        $entries = @(Get-UpvJsonProperty -InputObject $registry -Name 'entries')
        $matches = @($entries | Where-Object {
            [string]$_.unityVersion -ceq $UnityVersion -and
            [string]$_.testFrameworkVersion -ceq $TestFrameworkVersion -and
            [string]$_.target -ceq 'StandaloneWindows64' -and
            [string]$_.scriptingBackend -ceq $ScriptingBackend
        })
        if ($matches.Count -gt 1) {
            throw 'Player compatibility registry contains a duplicate exact tuple.'
        }
        if ($matches.Count -eq 0) {
            return [pscustomobject]$result
        }
        $entry = $matches[0]
        $required = @(
            'unityVersion', 'testFrameworkVersion', 'allowedSourceKind', 'registryOrigin',
            'unityExecutableSha256', 'packageTreeSha256', 'packageHashCanonicalization',
            'target', 'scriptingBackend', 'windowsModuleTreeSha256', 'moduleHashCanonicalization',
            'minimumPhase', 'status', 'evidencePath'
        )
        $contract = Test-UpvExactJsonProperties -InputObject $entry -RequiredNames $required -Context 'Player compatibility entry'
        if (-not $contract.accepted) {
            throw ([string]::Join(' ', [string[]]@($contract.errors)))
        }
        foreach ($hashName in @('unityExecutableSha256', 'packageTreeSha256', 'windowsModuleTreeSha256')) {
            if ([string]$entry.$hashName -notmatch '^[0-9a-f]{64}$') {
                throw "Player compatibility entry has an invalid $hashName."
            }
        }
        if ([string]$entry.packageHashCanonicalization -cne 'upv-package-tree-relative-path-length-sha256-lf-v1') {
            throw 'Player compatibility entry has an unsupported package hash canonicalization.'
        }
        if ([string]$entry.moduleHashCanonicalization -cne $script:UpvrTreeCanonicalization) {
            throw 'Player compatibility entry has an unsupported module hash canonicalization.'
        }
        if ([string]$entry.status -notin @('CANDIDATE', 'APPROVED', 'RETIRED')) {
            throw 'Player compatibility entry has an invalid status.'
        }
        if ([string]$entry.minimumPhase -notin @('P1', 'P2', 'P3')) {
            throw 'Player compatibility entry has an invalid minimum phase.'
        }
        $result.entryFound = $true
        $result.entryStatus = [string]$entry.status
        $result.minimumPhase = [string]$entry.minimumPhase
        $result.allowedSourceKind = [string]$entry.allowedSourceKind
        $result.registryOrigin = Get-UpvJsonProperty -InputObject $entry -Name 'registryOrigin'
        $result.unityExecutableSha256 = [string]$entry.unityExecutableSha256
        $result.packageTreeSha256 = [string]$entry.packageTreeSha256
        $result.packageHashCanonicalization = [string]$entry.packageHashCanonicalization
        $result.windowsModuleTreeSha256 = [string]$entry.windowsModuleTreeSha256
        $result.moduleHashCanonicalization = [string]$entry.moduleHashCanonicalization
        $result.evidencePath = [string]$entry.evidencePath
        $result.approved = [string]$entry.status -ceq 'APPROVED'
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Builds the closed Unity command line for a Windows Test Player run.
function New-UpvrTestPlayerArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$TestResultsPath,
        [Parameter(Mandatory = $true)][string]$EditorLogPath,
        [Parameter(Mandatory = $true)][string]$UpmLogPath,
        [Parameter()][AllowNull()][string]$TestFilter,
        [Parameter()][AllowNull()][string]$TestCategory,
        [Parameter()][AllowNull()][string]$AssemblyNames
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @(
        '-batchmode', '-forgetProjectPath', '-runTests',
        '-projectPath', $ProjectPath,
        '-testPlatform', 'StandaloneWindows64',
        '-testResults', $TestResultsPath,
        '-logFile', $EditorLogPath,
        '-upmLogFile', $UpmLogPath
    )) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($TestFilter)) { $arguments.Add('-testFilter'); $arguments.Add($TestFilter) }
    if (-not [string]::IsNullOrWhiteSpace($TestCategory)) { $arguments.Add('-testCategory'); $arguments.Add($TestCategory) }
    if (-not [string]::IsNullOrWhiteSpace($AssemblyNames)) { $arguments.Add('-assemblyNames'); $arguments.Add($AssemblyNames) }
    return [string[]]$arguments.ToArray()
}

# Returns the reserved isolated infrastructure path and rejects project collisions.
function Get-UpvrReservedInfrastructureAssessment {
    param([Parameter(Mandatory = $true)][string]$ProjectCopyPath)

    $path = Join-Path -Path (Get-UpvNormalizedPath -Path $ProjectCopyPath) -ChildPath 'Assets\__UnityPlayerVerification'
    $collision = Test-Path -LiteralPath $path
    return [pscustomobject][ordered]@{
        path = $path
        collision = [bool]$collision
        accepted = -not [bool]$collision
        error = if ($collision) { 'The isolated base project already contains reserved Assets/__UnityPlayerVerification.' } else { $null }
    }
}

# Calculates the deterministic digest of pipeline-owned source infrastructure.
function Get-UpvrInfrastructureFingerprint {
    param([Parameter(Mandatory = $true)][string]$InfrastructureRoot)

    $inventory = @(Get-UpvBundleFileInventory -BundleRoot $InfrastructureRoot)
    if ($inventory.Count -eq 0) {
        throw 'Pipeline infrastructure inventory is empty.'
    }
    foreach ($file in $inventory) {
        $extension = [System.IO.Path]::GetExtension([string]$file.path)
        if ($extension -notin @('.cs', '.asmdef')) {
            throw "Pipeline infrastructure contains unsupported file: $($file.path)"
        }
    }
    $canonical = foreach ($file in @($inventory | Sort-Object -Property path)) {
        "F|$($script:UpvrUtf8NoBom.GetByteCount([string]$file.path))|$($file.path)|$($file.length)|$($file.sha256)"
    }
    return [pscustomobject][ordered]@{
        files = $inventory
        fileCount = $inventory.Count
        treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]@($canonical)))
    }
}

# Parses and validates the pipeline-owned Test Player build-report receipt.
function Get-UpvrBuildReportAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionToken,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)][string]$ExpectedBackend
    )

    $result = [ordered]@{
        exists = $false
        sha256 = $null
        schemaVersion = $null
        sessionTokenMatched = $false
        result = $null
        resultFinalized = $false
        outputPath = $null
        outputPathMatched = $false
        platform = $null
        scriptingBackend = $null
        backendMatched = $false
        buildGuid = $null
        totalSize = $null
        totalErrors = $null
        totalWarnings = $null
        startedAtUtc = $null
        durationSeconds = $null
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw 'Test Player build-report receipt is missing.'
        }
        $result.exists = $true
        $result.sha256 = Get-UpvFileSha256 -Path $Path
        $document = Read-UpvJsonFile -Path $Path
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames @(
            'schemaVersion', 'sessionToken', 'result', 'outputPath', 'platform', 'scriptingBackend',
            'buildGuid', 'totalSize', 'totalErrors', 'totalWarnings', 'startedAtUtc', 'durationSeconds'
        ) -Context 'Test Player build-report receipt'
        foreach ($error in @($contract.errors)) { [void]$errors.Add($error) }
        $result.schemaVersion = [string]$document.schemaVersion
        $result.sessionTokenMatched = [string]$document.sessionToken -ceq $ExpectedSessionToken
        $result.result = [string]$document.result
        $result.resultFinalized = $result.result -ceq 'Succeeded'
        $result.outputPath = [string]$document.outputPath
        if (-not [string]::IsNullOrWhiteSpace($result.outputPath)) {
            $result.outputPathMatched = (Get-UpvNormalizedPath -Path $result.outputPath).Equals((Get-UpvNormalizedPath -Path $ExpectedExecutablePath), $script:UpvPathComparison)
        }
        $result.platform = [string]$document.platform
        $result.scriptingBackend = [string]$document.scriptingBackend
        $expectedRuntimeBackend = if ($ExpectedBackend -ceq 'Mono') { 'Mono2x' } else { 'IL2CPP' }
        $result.backendMatched = $result.scriptingBackend -ceq $expectedRuntimeBackend
        $result.buildGuid = [string]$document.buildGuid
        $result.totalSize = $document.totalSize
        $result.totalErrors = $document.totalErrors
        $result.totalWarnings = $document.totalWarnings
        $result.startedAtUtc = [string]$document.startedAtUtc
        $result.durationSeconds = $document.durationSeconds
        if ($result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Build-report schemaVersion must be 1.0.0.') }
        if (-not $result.sessionTokenMatched) { [void]$errors.Add('Build-report session token does not match.') }
        if ($result.result -notin @('Succeeded', 'Unknown')) { [void]$errors.Add("BuildReport result is $($result.result), not Succeeded or the documented postprocess-callback value Unknown.") }
        if (-not $result.outputPathMatched) { [void]$errors.Add('BuildReport output path does not match the verifier-owned executable.') }
        if ($result.platform -cne 'StandaloneWindows64') { [void]$errors.Add('BuildReport platform is not StandaloneWindows64.') }
        if (-not $result.backendMatched) { [void]$errors.Add('BuildReport scripting backend does not match the requested backend.') }
        if ([int]$result.totalErrors -ne 0) { [void]$errors.Add('BuildReport contains one or more build errors.') }
        if ([string]::IsNullOrWhiteSpace($result.buildGuid)) { [void]$errors.Add('BuildReport GUID is missing.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Parses and validates the Player-side test-run receipt.
function Get-UpvrRuntimeTestReceiptAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionToken,
        [Parameter(Mandatory = $true)][string]$ExpectedNUnitPath,
        [Parameter(Mandatory = $true)][string]$ExpectedUnityVersion
    )

    $result = [ordered]@{
        exists = $false
        sha256 = $null
        schemaVersion = $null
        sessionTokenMatched = $false
        runStarted = $false
        runFinished = $false
        resultState = $null
        nunitPath = $null
        nunitPathMatched = $false
        unityVersion = $null
        unityVersionMatched = $false
        productName = $null
        processId = $null
        error = $null
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw 'Player-side test-run receipt is missing.'
        }
        $result.exists = $true
        $result.sha256 = Get-UpvFileSha256 -Path $Path
        $document = Read-UpvJsonFile -Path $Path
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames @(
            'schemaVersion', 'sessionToken', 'runStarted', 'runFinished', 'resultState',
            'nunitPath', 'unityVersion', 'productName', 'processId', 'error'
        ) -Context 'Player-side test-run receipt'
        foreach ($contractError in @($contract.errors)) { [void]$errors.Add($contractError) }
        foreach ($property in @('schemaVersion', 'resultState', 'nunitPath', 'unityVersion', 'productName', 'processId', 'error')) {
            $result[$property] = $document.$property
        }
        $result.sessionTokenMatched = [string]$document.sessionToken -ceq $ExpectedSessionToken
        $result.runStarted = [bool]$document.runStarted
        $result.runFinished = [bool]$document.runFinished
        if (-not [string]::IsNullOrWhiteSpace([string]$result.nunitPath)) {
            $result.nunitPathMatched = (Get-UpvNormalizedPath -Path $result.nunitPath).Equals((Get-UpvNormalizedPath -Path $ExpectedNUnitPath), $script:UpvPathComparison)
        }
        $result.unityVersionMatched = [string]$result.unityVersion -ceq $ExpectedUnityVersion
        if ([string]$result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Runtime receipt schemaVersion must be 1.0.0.') }
        if (-not $result.sessionTokenMatched) { [void]$errors.Add('Runtime receipt session token does not match.') }
        if (-not $result.runStarted -or -not $result.runFinished) { [void]$errors.Add('Runtime receipt does not prove a complete Player-side run.') }
        if (-not $result.nunitPathMatched) { [void]$errors.Add('Runtime receipt NUnit path does not match the verifier-owned path.') }
        if (-not $result.unityVersionMatched) { [void]$errors.Add('Runtime receipt Unity version does not match the selected editor.') }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) { [void]$errors.Add('Runtime receipt contains an error.') }
        if ([int]$result.processId -le 0) { [void]$errors.Add('Runtime receipt processId is invalid.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Parses the Player callback NUnit subtree while retaining the shared strict summary shape.
function Get-UpvrRuntimeNUnitAnalysis {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return Get-UpvNUnitAnalysis -Path $Path
    }
    try {
        [xml]$document = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($null -eq $document.DocumentElement -or $document.DocumentElement.LocalName -ne 'test-suite') {
            return Get-UpvNUnitAnalysis -Path $Path
        }
        $root = $document.DocumentElement
        $cases = @($document.SelectNodes("//*[local-name()='test-case']"))
        $passed = @($cases | Where-Object { [string]$_.GetAttribute('result') -match '^(Passed|Success)$' }).Count
        $failedCases = @($cases | Where-Object { [string]$_.GetAttribute('result') -match '^(Failed|Error)$' })
        $skipped = @($cases | Where-Object { [string]$_.GetAttribute('result') -match '^(Skipped|Ignored|NotRunnable)$' }).Count
        $inconclusive = @($cases | Where-Object { [string]$_.GetAttribute('result') -eq 'Inconclusive' }).Count
        $failureDetails = New-Object System.Collections.ArrayList
        foreach ($node in $failedCases | Select-Object -First 200) {
            $messageNode = $node.SelectSingleNode("./*[local-name()='failure']/*[local-name()='message']")
            $stackNode = $node.SelectSingleNode("./*[local-name()='failure']/*[local-name()='stack-trace']")
            [void]$failureDetails.Add([ordered]@{
                name = [string]$node.GetAttribute('fullname')
                result = [string]$node.GetAttribute('result')
                message = if ($null -ne $messageNode) { [string]$messageNode.InnerText } else { $null }
                stackTrace = if ($null -ne $stackNode) { [string]$stackNode.InnerText } else { $null }
            })
        }
        $total = $cases.Count
        $executed = $passed + $failedCases.Count + $inconclusive
        $rootResult = [string]$root.GetAttribute('result')
        $classification = if ($total -le 0) {
            'ZERO_TESTS'
        } elseif ($failedCases.Count -gt 0 -or $rootResult -match '^(Failed|Error)$') {
            'FAILED'
        } elseif ($skipped -gt 0 -or $inconclusive -gt 0 -or $executed -lt $total) {
            'INCOMPLETE'
        } elseif ($passed -eq $total -and $rootResult -match '^(Passed|Success)$') {
            'PASSED'
        } else {
            'INCONCLUSIVE'
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [pscustomobject][ordered]@{
            exists = $true
            byteLength = [long]$item.Length
            sha256 = Get-UpvFileSha256 -Path $Path
            format = 'NUNIT3_RESULT_SUBTREE'
            rootResult = $rootResult
            total = $total
            executed = $executed
            passed = $passed
            failed = $failedCases.Count
            skipped = $skipped
            inconclusive = $inconclusive
            assertions = Get-UpvXmlIntegerAttribute -Element $root -Names @('asserts')
            durationSeconds = Get-UpvXmlDoubleAttribute -Element $root -Names @('duration')
            failureDetails = @($failureDetails)
            classification = $classification
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            exists = $true
            byteLength = $null
            sha256 = $null
            format = $null
            rootResult = $null
            total = 0
            executed = 0
            passed = 0
            failed = 0
            skipped = 0
            inconclusive = 0
            assertions = 0
            durationSeconds = $null
            failureDetails = @()
            classification = 'INVALID'
            error = $_.Exception.Message
        }
    }
}

# Compares independent PlayerConnection and Player-side NUnit summaries.
function Get-UpvrNUnitAgreementAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$PlayerConnection,
        [Parameter(Mandatory = $true)][object]$Runtime
    )

    $properties = @('classification', 'total', 'executed', 'passed', 'failed', 'skipped', 'inconclusive')
    $mismatches = New-Object System.Collections.ArrayList
    foreach ($property in $properties) {
        if ([string]$PlayerConnection.$property -cne [string]$Runtime.$property) {
            [void]$mismatches.Add("$property differs: PlayerConnection=$($PlayerConnection.$property), runtime=$($Runtime.$property).")
        }
    }
    return [pscustomobject][ordered]@{
        comparedProperties = $properties
        mismatches = @($mismatches)
        accepted = $mismatches.Count -eq 0
    }
}

# Applies Player-specific final-status precedence to complete evidence.
function Get-UpvrFinalStatusAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalIntegrityStatus,
        [Parameter(Mandatory = $true)][string]$GitIntegrityStatus,
        [Parameter(Mandatory = $true)][int]$BlockerCount,
        [Parameter(Mandatory = $true)][int]$FailureCount,
        [Parameter(Mandatory = $true)][string]$CompatibilityStatus,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RequiredScopeStatuses,
        [Parameter()][switch]$LaunchOnly
    )

    if ($OriginalIntegrityStatus -ceq 'CHANGED' -or $GitIntegrityStatus -ceq 'CHANGED') {
        return 'ORIGINAL_PROJECT_CHANGED'
    }
    if ($BlockerCount -gt 0 -or $CompatibilityStatus -cne 'VERIFIED_SUCCESS') {
        return 'VERIFICATION_BLOCKED'
    }
    if ($FailureCount -gt 0) {
        return 'PLAYER_FAILED'
    }
    foreach ($scopeStatus in $RequiredScopeStatuses) {
        if ($scopeStatus -cne 'VERIFIED_SUCCESS') {
            return 'VERIFICATION_BLOCKED'
        }
    }
    if ($LaunchOnly) {
        return 'PLAYER_LAUNCH_VERIFIED'
    }
    return 'PLAYER_VERIFIED'
}
