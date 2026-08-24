Set-StrictMode -Version Latest

$script:UpvrUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UpvrTreeCanonicalization = 'upvr-tree-relative-path-length-sha256-lf-v1'

# Returns true when an absolute Windows path is located on the C drive.
function Test-UpvrCDrivePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-UpvNormalizedPath -Path $Path
    return [string]::Equals([System.IO.Path]::GetPathRoot($normalized), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Converts one absolute Windows path to the extended-length form used by System.IO.
function Get-UpvrExtendedIoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-UpvNormalizedPath -Path $Path
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $normalized }
    if ($normalized.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $normalized.Substring(2)
    }
    return '\\?\' + $normalized
}

# Computes a lowercase SHA-256 digest without the legacy Windows MAX_PATH limit.
function Get-UpvrFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $algorithm = $null
    try {
        $stream = [System.IO.File]::OpenRead((Get-UpvrExtendedIoPath -Path $Path))
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
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
                    sha256 = Get-UpvrFileSha256 -Path $entry.FullName
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
    $totalBytes = [long]0
    foreach ($file in $sortedFiles) {
        $totalBytes += [long]$file.length
    }
    return [pscustomobject][ordered]@{
        root = $normalizedRoot
        canonicalization = $script:UpvrTreeCanonicalization
        directoryCount = $sortedDirectories.Count
        fileCount = $sortedFiles.Count
        totalBytes = $totalBytes
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
        monoVariationPaths = @()
        il2cppVariationPaths = @()
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
        $result.monoVariationPaths = @($snapshot.directories | Where-Object {
            $_ -match '(?i)^Variations[\\/]win64(?:_player)?_nondevelopment_mono$'
        })
        $result.il2cppVariationPaths = @($snapshot.directories | Where-Object {
            $_ -match '(?i)^Variations[\\/]win64(?:_player)?_nondevelopment_il2cpp$'
        })
        $result.monoAvailable = $result.monoVariationPaths.Count -gt 0
        $result.il2cppAvailable = $result.il2cppVariationPaths.Count -gt 0
        if (-not $result.monoAvailable -and -not $result.il2cppAvailable) {
            throw 'The Windows Standalone module contains neither a Windows x64 non-development Mono variation nor a Windows x64 non-development IL2CPP variation.'
        }
        $result.accepted = $true
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Resolves the serialized Standalone scripting backend without opening or changing the Unity project.
function Get-UpvrProjectScriptingBackendAssessment {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $result = [ordered]@{ path=$null; backend=$null; serializedValue=$null; accepted=$false; error=$null }
    try {
        $path = Join-Path (Get-UpvNormalizedPath -Path $ProjectRoot) 'ProjectSettings\ProjectSettings.asset'
        $result.path = $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'ProjectSettings/ProjectSettings.asset is missing.' }
        $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
        $sectionIndex = -1
        for ($index = 0; $index -lt $lines.Length; $index++) {
            if ($lines[$index] -cmatch '^  scriptingBackend:\s*(?<inline>\{\})?\s*$') { $sectionIndex = $index; break }
        }
        if ($sectionIndex -lt 0) { throw 'Unity ProjectSettings does not contain a scriptingBackend section.' }
        $value = 0
        for ($index = $sectionIndex + 1; $index -lt $lines.Length; $index++) {
            if ($lines[$index] -cmatch '^  \S') { break }
            if ($lines[$index] -cmatch '^    Standalone:\s*(?<value>\d+)\s*$') {
                $value = [int]$Matches.value
                break
            }
        }
        if ($value -notin @(0, 1)) { throw "Unsupported serialized Standalone scripting backend value $value." }
        $result.serializedValue = $value
        $result.backend = if ($value -eq 1) { 'IL2CPP' } else { 'Mono' }
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
        toolchainIdentitySha256 = $null
        visualStudioVersion = $null
        msvcVersion = $null
        windowsSdkVersion = $null
        evidencePath = $null
        approved = $false
        error = $null
    }
    try {
        $registry = Read-UpvJsonFile -Path $RegistryPath
        $result.registrySchemaVersion = [string](Get-UpvJsonProperty -InputObject $registry -Name 'schemaVersion')
        if ($result.registrySchemaVersion -cne '1.1.0') {
            throw 'Player compatibility registry schemaVersion must be 1.1.0.'
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
            'toolchainIdentitySha256', 'visualStudioVersion', 'msvcVersion', 'windowsSdkVersion',
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
        if ($ScriptingBackend -ceq 'IL2CPP') {
            if ([string]$entry.toolchainIdentitySha256 -notmatch '^[0-9a-f]{64}$') {
                throw 'IL2CPP compatibility entry has an invalid toolchain identity hash.'
            }
            foreach ($versionName in @('visualStudioVersion', 'msvcVersion', 'windowsSdkVersion')) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.$versionName)) {
                    throw "IL2CPP compatibility entry lacks $versionName."
                }
            }
        } else {
            foreach ($toolchainName in @('toolchainIdentitySha256', 'visualStudioVersion', 'msvcVersion', 'windowsSdkVersion')) {
                if ($null -ne (Get-UpvJsonProperty -InputObject $entry -Name $toolchainName)) {
                    throw "Mono compatibility entry must keep $toolchainName null."
                }
            }
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
        $result.toolchainIdentitySha256 = Get-UpvJsonProperty -InputObject $entry -Name 'toolchainIdentitySha256'
        $result.visualStudioVersion = Get-UpvJsonProperty -InputObject $entry -Name 'visualStudioVersion'
        $result.msvcVersion = Get-UpvJsonProperty -InputObject $entry -Name 'msvcVersion'
        $result.windowsSdkVersion = Get-UpvJsonProperty -InputObject $entry -Name 'windowsSdkVersion'
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
        [Parameter()][switch]$LaunchOnly,
        [Parameter()][switch]$CompatibilityNotRequired
    )

    if ($OriginalIntegrityStatus -ceq 'CHANGED' -or $GitIntegrityStatus -ceq 'CHANGED') {
        return 'ORIGINAL_PROJECT_CHANGED'
    }
    if ($BlockerCount -gt 0 -or (-not $CompatibilityNotRequired -and $CompatibilityStatus -cne 'VERIFIED_SUCCESS')) {
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

# Parses retained Test Player or Standalone runtime markers and concrete crash signatures.
function Get-UpvrPlayerLogAnalysis {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [ordered]@{
        exists=$false; byteLength=$null; sha256=$null; runStartedMarker=$false; runFinishedMarker=$false
        standaloneStartedMarker=$false; standaloneFinishedMarker=$false; crashMarkers=@(); classification='NOT_ANALYZED'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }
    $item = Get-Item -LiteralPath $Path -Force
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $result.exists = $true
    $result.byteLength = [long]$item.Length
    $result.sha256 = Get-UpvFileSha256 -Path $Path
    $result.runStartedMarker = $text.Contains('UPVR_RUNTIME_RUN_STARTED')
    $result.runFinishedMarker = $text.Contains('UPVR_RUNTIME_RUN_FINISHED')
    $result.standaloneStartedMarker = $text.Contains('UPVR_STANDALONE_SCENARIO_STARTED')
    $result.standaloneFinishedMarker = $text.Contains('UPVR_STANDALONE_SCENARIO_FINISHED')
    $markers = New-Object System.Collections.ArrayList
    foreach ($definition in @(
        [pscustomobject]@{ code='PLAYER_CRASH'; pattern='(?im)^Crash!!!\s*$' },
        [pscustomobject]@{ code='PLAYER_FATAL_ERROR'; pattern='(?i)Fatal Error!' },
        [pscustomobject]@{ code='PLAYER_RECEIPT_ERROR'; pattern='UPVR_RUNTIME_RECEIPT_ERROR' },
        [pscustomobject]@{ code='STANDALONE_RECEIPT_ERROR'; pattern='UPVR_STANDALONE_RECEIPT_ERROR' },
        [pscustomobject]@{ code='PLAYER_ACCEPTANCE_CRASH'; pattern='UPVR_ACCEPTANCE_PLAYER_CRASH' }
    )) {
        if ([regex]::IsMatch($text, $definition.pattern)) { [void]$markers.Add($definition.code) }
    }
    $result.crashMarkers = @($markers)
    $result.classification = if ($markers.Count -gt 0) { 'FAILURE' } elseif (($result.runStartedMarker -and $result.runFinishedMarker) -or ($result.standaloneStartedMarker -and $result.standaloneFinishedMarker)) { 'SAFE' } else { 'INCONCLUSIVE' }
    return [pscustomobject]$result
}

# Validates one source-only Player scenario bundle and returns its immutable inventory.
function Get-UpvrPlayerScenarioBundleAssessment {
    param([Parameter(Mandatory = $true)][string]$BundlePath)

    $result = [ordered]@{
        accepted = $false
        root = $null
        schemaVersion = $null
        kind = $null
        scenarioId = $null
        displayName = $null
        timeoutSeconds = $null
        expectedScenes = @()
        expectedAssertionIds = @()
        expectedCaptureIds = @()
        graphicsRequired = $null
        testFilter = $null
        fileCount = 0
        treeSha256 = $null
        files = @()
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        $root = Get-UpvNormalizedPath -Path $BundlePath
        $result.root = $root
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'ScenarioBundlePath is not an existing directory.' }
        $reparse = Get-UpvReparsePointOnPath -Path $root
        if ($null -ne $reparse) { throw "Scenario bundle traverses a reparse point: $reparse" }
        $files = @(Get-UpvBundleFileInventory -BundleRoot $root)
        if ($files.Count -eq 0) { throw 'Scenario bundle is empty.' }
        $manifestFiles = @($files | Where-Object { [string]$_.path -ceq 'manifest.json' })
        if ($manifestFiles.Count -ne 1) { throw 'Scenario bundle must contain exactly one root manifest.json.' }
        $sourceFiles = @($files | Where-Object { [System.IO.Path]::GetExtension([string]$_.path) -ceq '.cs' })
        $assemblyFiles = @($files | Where-Object { [System.IO.Path]::GetExtension([string]$_.path) -ceq '.asmdef' })
        if ($sourceFiles.Count -eq 0 -or $assemblyFiles.Count -eq 0) { throw 'Scenario bundle requires at least one .cs source and one .asmdef.' }
        foreach ($file in $files) {
            $extension = [System.IO.Path]::GetExtension([string]$file.path)
            if ([string]$file.path -cne 'manifest.json' -and $extension -notin @('.cs', '.asmdef')) {
                [void]$errors.Add("Scenario bundle contains forbidden file type: $($file.path)")
            }
        }

        $manifest = Read-UpvJsonFile -Path $manifestFiles[0].sourcePath
        $contract = Test-UpvExactJsonProperties -InputObject $manifest -RequiredNames @(
            'schemaVersion', 'kind', 'scenarioId', 'displayName', 'timeoutSeconds', 'expectedScenes',
            'expectedAssertionIds', 'expectedCaptureIds', 'graphicsRequired', 'testFilter'
        ) -Context 'Player scenario manifest'
        foreach ($contractError in @($contract.errors)) { [void]$errors.Add($contractError) }
        $result.schemaVersion = [string](Get-UpvJsonProperty $manifest 'schemaVersion')
        $result.kind = [string](Get-UpvJsonProperty $manifest 'kind')
        $result.scenarioId = [string](Get-UpvJsonProperty $manifest 'scenarioId')
        $result.displayName = [string](Get-UpvJsonProperty $manifest 'displayName')
        $result.timeoutSeconds = Get-UpvJsonProperty $manifest 'timeoutSeconds'
        $result.expectedScenes = [string[]]@((Get-UpvJsonProperty $manifest 'expectedScenes'))
        $result.expectedAssertionIds = [string[]]@((Get-UpvJsonProperty $manifest 'expectedAssertionIds'))
        $result.expectedCaptureIds = [string[]]@((Get-UpvJsonProperty $manifest 'expectedCaptureIds'))
        $result.graphicsRequired = Get-UpvJsonProperty $manifest 'graphicsRequired'
        $result.testFilter = [string](Get-UpvJsonProperty $manifest 'testFilter')
        if ($result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Scenario manifest schemaVersion must be 1.0.0.') }
        if ($result.kind -cne 'PLAYER_SCENARIO_BUNDLE') { [void]$errors.Add('Scenario manifest kind must be PLAYER_SCENARIO_BUNDLE.') }
        if ($result.scenarioId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { [void]$errors.Add('Scenario manifest scenarioId is invalid.') }
        if ([string]::IsNullOrWhiteSpace($result.displayName) -or $result.displayName.Length -gt 256) { [void]$errors.Add('Scenario manifest displayName is invalid.') }
        if ($result.timeoutSeconds -isnot [int] -and $result.timeoutSeconds -isnot [long]) { [void]$errors.Add('Scenario manifest timeoutSeconds must be an integer.') }
        elseif ([long]$result.timeoutSeconds -lt 1 -or [long]$result.timeoutSeconds -gt 600) { [void]$errors.Add('Scenario manifest timeoutSeconds must be between 1 and 600.') }
        if ($result.expectedScenes.Count -eq 0 -or @($result.expectedScenes | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_.Length -gt 512 -or $_ -match '[\x00-\x1f]' }).Count -gt 0) {
            [void]$errors.Add('Scenario manifest expectedScenes must contain safe non-empty values.')
        }
        if (@($result.expectedScenes | Sort-Object -Unique).Count -ne $result.expectedScenes.Count) { [void]$errors.Add('Scenario manifest expectedScenes contains duplicates.') }
        $assertionIds = Test-UpvIdentifierArray -Value (,$result.expectedAssertionIds) -Name 'expectedAssertionIds'
        $captureIds = Test-UpvIdentifierArray -Value (,$result.expectedCaptureIds) -Name 'expectedCaptureIds'
        foreach ($identifierError in @($assertionIds.errors) + @($captureIds.errors)) { [void]$errors.Add($identifierError) }
        if ($result.expectedAssertionIds.Count -eq 0) { [void]$errors.Add('Scenario manifest expectedAssertionIds must contain at least one ID.') }
        if ($result.graphicsRequired -isnot [bool]) { [void]$errors.Add('Scenario manifest graphicsRequired must be boolean.') }
        if ($result.testFilter -cne 'UnityPlayerVerification.PlayerScenarioTest.ExecuteScenario') { [void]$errors.Add('Scenario manifest testFilter is not the fixed Player harness test.') }

        $interfaceObserved = $false
        foreach ($source in $sourceFiles) {
            $text = [System.IO.File]::ReadAllText([string]$source.sourcePath, [System.Text.Encoding]::UTF8)
            if ($text -match '\bIPlayerVerificationScenario\b') { $interfaceObserved = $true }
            if ($text -match '(?i)\b(SendInput|SetCursorPos|mouse_event|keybd_event|InputSimulator)\b|user32\.dll|System\.Windows\.Forms') {
                [void]$errors.Add("Scenario source contains forbidden OS input automation: $($source.path)")
            }
        }
        if (-not $interfaceObserved) { [void]$errors.Add('Scenario source does not reference IPlayerVerificationScenario.') }

        foreach ($assembly in $assemblyFiles) {
            $asmdef = Read-UpvJsonFile -Path $assembly.sourcePath
            $name = [string](Get-UpvJsonProperty $asmdef 'name')
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^UnityPlayerVerification\.') { [void]$errors.Add("Scenario asmdef has a missing or reserved assembly name: $($assembly.path)") }
            $references = [string[]]@((Get-UpvJsonProperty $asmdef 'references'))
            if ($references -notcontains 'UnityPlayerVerification.Harness') { [void]$errors.Add("Scenario asmdef must reference UnityPlayerVerification.Harness: $($assembly.path)") }
            $unsafe = Get-UpvJsonProperty $asmdef 'allowUnsafeCode'
            if ($null -ne $unsafe -and [bool]$unsafe) { [void]$errors.Add("Scenario asmdef cannot enable unsafe code: $($assembly.path)") }
            $precompiled = @((Get-UpvJsonProperty $asmdef 'precompiledReferences'))
            if ($precompiled.Count -gt 0) { [void]$errors.Add("Scenario asmdef cannot reference precompiled assemblies: $($assembly.path)") }
            $override = Get-UpvJsonProperty $asmdef 'overrideReferences'
            if ($null -ne $override -and [bool]$override) { [void]$errors.Add("Scenario asmdef cannot override references: $($assembly.path)") }
            $includePlatforms = [string[]]@((Get-UpvJsonProperty $asmdef 'includePlatforms'))
            if ($includePlatforms -contains 'Editor') { [void]$errors.Add("Scenario asmdef cannot be Editor-only: $($assembly.path)") }
        }

        $canonical = foreach ($file in @($files | Sort-Object -Property path)) {
            "F|$($script:UpvrUtf8NoBom.GetByteCount([string]$file.path))|$($file.path)|$($file.length)|$($file.sha256)"
        }
        $result.files = $files
        $result.fileCount = $files.Count
        $result.treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]@($canonical)))
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Parses a Player scenario receipt and verifies its manifest-owned evidence files.
function Get-UpvrPlayerScenarioReceiptAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionToken,
        [Parameter(Mandatory = $true)][string]$ScreenshotRoot
    )

    $result = [ordered]@{
        exists = $false
        sha256 = $null
        schemaVersion = $null
        sessionTokenMatched = $false
        scenarioId = $null
        scenarioIdMatched = $false
        runStarted = $false
        runFinished = $false
        result = $null
        activeScene = $null
        sceneMatched = $false
        elapsedSeconds = $null
        exception = $null
        assertions = @()
        captures = @()
        assertionIdsMatched = $false
        captureIdsMatched = $false
        assertionsPassed = $false
        capturesPresent = $false
        missingCaptureIds = @()
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    $missingCaptures = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Player scenario receipt is missing.' }
        $result.exists = $true
        $result.sha256 = Get-UpvFileSha256 -Path $Path
        $document = Read-UpvJsonFile -Path $Path
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames @(
            'schemaVersion', 'sessionToken', 'scenarioId', 'runStarted', 'runFinished', 'result',
            'activeScene', 'elapsedSeconds', 'exception', 'assertions', 'captures'
        ) -Context 'Player scenario receipt'
        foreach ($contractError in @($contract.errors)) { [void]$errors.Add($contractError) }
        foreach ($property in @('schemaVersion', 'scenarioId', 'result', 'activeScene', 'elapsedSeconds', 'exception')) { $result[$property] = $document.$property }
        $result.runStarted = [bool]$document.runStarted
        $result.runFinished = [bool]$document.runFinished
        $result.sessionTokenMatched = [string]$document.sessionToken -ceq $ExpectedSessionToken
        $result.scenarioIdMatched = [string]$result.scenarioId -ceq [string]$Manifest.scenarioId
        $expectedScenes = [string[]]@($Manifest.expectedScenes)
        $normalizedActive = ([string]$result.activeScene).Replace('\', '/')
        $result.sceneMatched = @($expectedScenes | Where-Object {
            $normalizedExpected = ([string]$_).Replace('\', '/')
            $normalizedExpected -ceq $normalizedActive -or [System.IO.Path]::GetFileNameWithoutExtension($normalizedExpected) -ceq [System.IO.Path]::GetFileNameWithoutExtension($normalizedActive)
        }).Count -gt 0
        if ($result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Scenario receipt schemaVersion must be 1.0.0.') }
        if (-not $result.sessionTokenMatched) { [void]$errors.Add('Scenario receipt session token does not match.') }
        if (-not $result.scenarioIdMatched) { [void]$errors.Add('Scenario receipt scenarioId does not match the manifest.') }
        if (-not $result.runStarted -or -not $result.runFinished) { [void]$errors.Add('Scenario receipt does not prove a complete run.') }
        if (-not $result.sceneMatched) { [void]$errors.Add('Scenario receipt active scene does not match the manifest.') }
        if ([double]$result.elapsedSeconds -lt 0 -or [double]$result.elapsedSeconds -gt ([double]$Manifest.timeoutSeconds + 5.0)) { [void]$errors.Add('Scenario receipt elapsed time is invalid or exceeds the manifest limit.') }

        $assertions = @($document.assertions)
        $assertionIds = New-Object System.Collections.ArrayList
        $assertionObjects = New-Object System.Collections.ArrayList
        foreach ($assertion in $assertions) {
            $itemContract = Test-UpvExactJsonProperties -InputObject $assertion -RequiredNames @('id', 'passed', 'detail') -Context 'Scenario assertion'
            foreach ($itemError in @($itemContract.errors)) { [void]$errors.Add($itemError) }
            [void]$assertionIds.Add([string]$assertion.id)
            [void]$assertionObjects.Add([ordered]@{ id = [string]$assertion.id; passed = [bool]$assertion.passed; detail = [string]$assertion.detail })
        }
        $result.assertionIdsMatched = Test-UpvExactStringSet -Expected ([string[]]@($Manifest.expectedAssertionIds)) -Actual ([string[]]@($assertionIds))
        if (-not $result.assertionIdsMatched) { [void]$errors.Add('Scenario assertion IDs do not exactly match the manifest.') }
        $result.assertions = @($assertionObjects)
        $result.assertionsPassed = $assertions.Count -gt 0 -and @($assertionObjects | Where-Object { -not [bool]$_.passed }).Count -eq 0

        $normalizedScreenshotRoot = Get-UpvNormalizedPath -Path $ScreenshotRoot
        if ($null -ne (Get-UpvReparsePointOnPath -Path $normalizedScreenshotRoot)) { throw 'Scenario screenshot root traverses a reparse point.' }
        $captureIds = New-Object System.Collections.ArrayList
        $captureObjects = New-Object System.Collections.ArrayList
        foreach ($capture in @($document.captures)) {
            $itemContract = Test-UpvExactJsonProperties -InputObject $capture -RequiredNames @('id', 'path', 'byteLength', 'sha256') -Context 'Scenario capture'
            foreach ($itemError in @($itemContract.errors)) { [void]$errors.Add($itemError) }
            $id = [string]$capture.id
            [void]$captureIds.Add($id)
            $capturePath = Get-UpvNormalizedPath -Path ([string]$capture.path)
            $expectedCapturePath = Get-UpvNormalizedPath -Path (Join-Path $normalizedScreenshotRoot ($id + '.png'))
            $pathAccepted = (Test-UpvPathWithinRoot -Path $capturePath -Root $normalizedScreenshotRoot) -and $capturePath.Equals($expectedCapturePath, $script:UpvPathComparison) -and $null -eq (Get-UpvReparsePointOnPath -Path $capturePath)
            $exists = $pathAccepted -and (Test-Path -LiteralPath $capturePath -PathType Leaf)
            $actualLength = if ($exists) { [long](Get-Item -LiteralPath $capturePath -Force).Length } else { 0L }
            $actualHash = if ($exists -and $actualLength -gt 0) { Get-UpvFileSha256 -Path $capturePath } else { $null }
            $identityMatched = $exists -and $actualLength -gt 0 -and [string]$capture.sha256 -match '^[0-9a-f]{64}$' -and $actualLength -eq [long]$capture.byteLength -and $actualHash -ceq [string]$capture.sha256
            if (-not $identityMatched) { [void]$missingCaptures.Add($id); [void]$errors.Add("Capture file evidence is missing or mismatched: $id") }
            [void]$captureObjects.Add([ordered]@{
                id = $id; path = $capturePath; exists = $exists; byteLength = $actualLength
                sha256 = $actualHash; identityMatched = $identityMatched
            })
        }
        $result.captureIdsMatched = Test-UpvExactStringSet -Expected ([string[]]@($Manifest.expectedCaptureIds)) -Actual ([string[]]@($captureIds))
        if (-not $result.captureIdsMatched) { [void]$errors.Add('Scenario capture IDs do not exactly match the manifest.') }
        foreach ($expectedId in [string[]]@($Manifest.expectedCaptureIds)) {
            if ([string[]]@($captureIds) -cnotcontains $expectedId) { [void]$missingCaptures.Add($expectedId) }
        }
        $result.captures = @($captureObjects)
        $result.capturesPresent = $missingCaptures.Count -eq 0
        if ([string]$result.result -cne $(if ($result.assertionsPassed -and $result.captureIdsMatched -and $result.capturesPresent) { 'PASSED' } else { 'FAILED' })) {
            [void]$errors.Add('Scenario receipt result does not agree with its assertion and capture evidence.')
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.missingCaptureIds = [string[]]@($missingCaptures | Sort-Object -Unique)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0 -and $result.assertionsPassed -and $result.capturesPresent
    return [pscustomobject]$result
}

# Validates one source-only instrumented Standalone scenario bundle and its build Scene contract.
function Get-UpvrStandaloneScenarioBundleAssessment {
    param([Parameter(Mandatory = $true)][string]$BundlePath)

    $result = [ordered]@{
        accepted = $false; root = $null; schemaVersion = $null; kind = $null; scenarioId = $null
        displayName = $null; timeoutSeconds = $null; buildScenes = @(); expectedScenes = @()
        expectedAssertionIds = @(); expectedCaptureIds = @(); graphicsRequired = $null
        assemblyNames = @(); fileCount = 0; treeSha256 = $null; files = @(); errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    $assemblyNames = New-Object System.Collections.ArrayList
    try {
        $root = Get-UpvNormalizedPath -Path $BundlePath
        $result.root = $root
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'ScenarioBundlePath is not an existing directory.' }
        $reparse = Get-UpvReparsePointOnPath -Path $root
        if ($null -ne $reparse) { throw "Standalone scenario bundle traverses a reparse point: $reparse" }
        $files = @(Get-UpvBundleFileInventory -BundleRoot $root)
        $manifestFiles = @($files | Where-Object { [string]$_.path -ceq 'manifest.json' })
        $sourceFiles = @($files | Where-Object { [System.IO.Path]::GetExtension([string]$_.path) -ceq '.cs' })
        $assemblyFiles = @($files | Where-Object { [System.IO.Path]::GetExtension([string]$_.path) -ceq '.asmdef' })
        if ($manifestFiles.Count -ne 1 -or $sourceFiles.Count -eq 0 -or $assemblyFiles.Count -eq 0) { throw 'Standalone scenario requires one root manifest.json, at least one .cs, and at least one .asmdef.' }
        foreach ($file in $files) {
            $extension = [System.IO.Path]::GetExtension([string]$file.path)
            if ([string]$file.path -cne 'manifest.json' -and $extension -notin @('.cs', '.asmdef')) { [void]$errors.Add("Standalone scenario contains forbidden file type: $($file.path)") }
        }

        $manifest = Read-UpvJsonFile -Path $manifestFiles[0].sourcePath
        $contract = Test-UpvExactJsonProperties -InputObject $manifest -RequiredNames @(
            'schemaVersion', 'kind', 'scenarioId', 'displayName', 'timeoutSeconds', 'buildScenes',
            'expectedScenes', 'expectedAssertionIds', 'expectedCaptureIds', 'graphicsRequired'
        ) -Context 'Standalone scenario manifest'
        foreach ($contractError in @($contract.errors)) { [void]$errors.Add($contractError) }
        foreach ($property in @('schemaVersion', 'kind', 'scenarioId', 'displayName', 'timeoutSeconds', 'graphicsRequired')) { $result[$property] = Get-UpvJsonProperty $manifest $property }
        $result.schemaVersion = [string]$result.schemaVersion
        $result.kind = [string]$result.kind
        $result.scenarioId = [string]$result.scenarioId
        $result.displayName = [string]$result.displayName
        $result.buildScenes = [string[]]@((Get-UpvJsonProperty $manifest 'buildScenes'))
        $result.expectedScenes = [string[]]@((Get-UpvJsonProperty $manifest 'expectedScenes'))
        $result.expectedAssertionIds = [string[]]@((Get-UpvJsonProperty $manifest 'expectedAssertionIds'))
        $result.expectedCaptureIds = [string[]]@((Get-UpvJsonProperty $manifest 'expectedCaptureIds'))
        if ($result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Standalone scenario schemaVersion must be 1.0.0.') }
        if ($result.kind -cne 'STANDALONE_SCENARIO_BUNDLE') { [void]$errors.Add('Standalone scenario kind must be STANDALONE_SCENARIO_BUNDLE.') }
        if ($result.scenarioId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { [void]$errors.Add('Standalone scenarioId is invalid.') }
        if ([string]::IsNullOrWhiteSpace($result.displayName) -or $result.displayName.Length -gt 256) { [void]$errors.Add('Standalone displayName is invalid.') }
        if (($result.timeoutSeconds -isnot [int] -and $result.timeoutSeconds -isnot [long]) -or [long]$result.timeoutSeconds -lt 1 -or [long]$result.timeoutSeconds -gt 600) { [void]$errors.Add('Standalone timeoutSeconds must be an integer from 1 through 600.') }
        if ($result.graphicsRequired -isnot [bool]) { [void]$errors.Add('Standalone graphicsRequired must be boolean.') }
        $sceneSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($scene in $result.buildScenes) {
            if ($scene -notmatch '^Assets/.+\.unity$' -or $scene -match '(^|/)\.\.(/|$)' -or -not $sceneSet.Add($scene)) { [void]$errors.Add("Standalone build Scene is invalid or duplicated: $scene") }
        }
        if ($result.expectedScenes.Count -eq 0 -or @($result.expectedScenes | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_.Length -gt 512 }).Count -gt 0) { [void]$errors.Add('Standalone expectedScenes must contain safe non-empty values.') }
        if (@($result.expectedScenes | Sort-Object -Unique).Count -ne $result.expectedScenes.Count) { [void]$errors.Add('Standalone expectedScenes contains duplicates.') }
        $assertionIds = Test-UpvIdentifierArray -Value (,$result.expectedAssertionIds) -Name 'expectedAssertionIds'
        $captureIds = Test-UpvIdentifierArray -Value (,$result.expectedCaptureIds) -Name 'expectedCaptureIds'
        foreach ($identifierError in @($assertionIds.errors) + @($captureIds.errors)) { [void]$errors.Add($identifierError) }
        if ($result.expectedAssertionIds.Count -eq 0) { [void]$errors.Add('Standalone expectedAssertionIds must contain at least one ID.') }

        $interfaceObserved = $false
        foreach ($source in $sourceFiles) {
            $text = [System.IO.File]::ReadAllText([string]$source.sourcePath, [System.Text.Encoding]::UTF8)
            if ($text -match '\bIPlayerVerificationScenario\b') { $interfaceObserved = $true }
            if ($text -match '(?i)\b(SendInput|SetCursorPos|mouse_event|keybd_event|InputSimulator)\b|user32\.dll|System\.Windows\.Forms') { [void]$errors.Add("Standalone scenario source contains forbidden OS input automation: $($source.path)") }
        }
        if (-not $interfaceObserved) { [void]$errors.Add('Standalone scenario source does not reference IPlayerVerificationScenario.') }
        foreach ($assembly in $assemblyFiles) {
            $asmdef = Read-UpvJsonFile -Path $assembly.sourcePath
            $name = [string](Get-UpvJsonProperty $asmdef 'name')
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $name -match '^UnityPlayerVerification\.') { [void]$errors.Add("Standalone scenario asmdef has an invalid or reserved name: $($assembly.path)") } else { [void]$assemblyNames.Add($name) }
            $references = [string[]]@((Get-UpvJsonProperty $asmdef 'references'))
            if ($references -notcontains 'UnityPlayerVerification.Harness') { [void]$errors.Add("Standalone scenario asmdef must reference UnityPlayerVerification.Harness: $($assembly.path)") }
            if ([bool](Get-UpvJsonProperty $asmdef 'allowUnsafeCode')) { [void]$errors.Add("Standalone scenario cannot enable unsafe code: $($assembly.path)") }
            if (@((Get-UpvJsonProperty $asmdef 'precompiledReferences')).Count -gt 0) { [void]$errors.Add("Standalone scenario cannot reference precompiled assemblies: $($assembly.path)") }
            if ([bool](Get-UpvJsonProperty $asmdef 'overrideReferences')) { [void]$errors.Add("Standalone scenario cannot override references: $($assembly.path)") }
            if ([string[]]@((Get-UpvJsonProperty $asmdef 'includePlatforms')) -contains 'Editor') { [void]$errors.Add("Standalone scenario cannot be Editor-only: $($assembly.path)") }
            if ([string[]]@((Get-UpvJsonProperty $asmdef 'optionalUnityReferences')) -contains 'TestAssemblies') { [void]$errors.Add("Standalone scenario cannot depend on TestAssemblies: $($assembly.path)") }
        }
        if (@($assemblyNames | Sort-Object -Unique).Count -ne $assemblyNames.Count) { [void]$errors.Add('Standalone scenario asmdef names must be unique.') }
        $canonical = foreach ($file in @($files | Sort-Object -Property path)) { "F|$($script:UpvrUtf8NoBom.GetByteCount([string]$file.path))|$($file.path)|$($file.length)|$($file.sha256)" }
        $result.files = $files
        $result.fileCount = $files.Count
        $result.treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]@($canonical)))
        $result.assemblyNames = [string[]]@($assemblyNames)
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Builds the fixed Unity Editor command line for an instrumented Standalone build.
function New-UpvrStandaloneBuildArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$EditorLogPath,
        [Parameter(Mandatory = $true)][string]$UpmLogPath
    )

    return [string[]]@(
        '-batchmode', '-forgetProjectPath', '-projectPath', $ProjectPath,
        '-executeMethod', 'UnityPlayerVerification.StandaloneBuildEntry.Build',
        '-quit', '-logFile', $EditorLogPath, '-upmLogFile', $UpmLogPath
    )
}

# Builds the only Player arguments allowed for instrumented and opaque Standalone execution.
function New-UpvrStandalonePlayerArguments {
    param([Parameter(Mandatory = $true)][string]$PlayerLogPath)

    return [string[]]@('-logFile', $PlayerLogPath, '-screen-fullscreen', '0', '-screen-width', '1280', '-screen-height', '720')
}

# Captures the exact Visual Studio, MSVC, and Windows SDK tools used to approve IL2CPP.
function Get-UpvrIl2CppToolchainIdentity {
    $result = [ordered]@{
        requested = $true; visualStudioVersion = $null; visualStudioPath = $null; msvcVersion = $null
        windowsSdkVersion = $null; tools = @(); identitySha256 = $null; accepted = $false; errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    $tools = New-Object System.Collections.ArrayList
    try {
        $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere.exe is missing.' }
        $raw = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "vswhere.exe exited with code $LASTEXITCODE." }
        $instances = @((ConvertFrom-Json -InputObject ([string]::Join([Environment]::NewLine, [string[]]$raw))) )
        if ($instances.Count -ne 1) { throw 'Exactly one latest Visual Studio C++ toolchain instance is required.' }
        $instance = $instances[0]
        $vsRoot = Get-UpvNormalizedPath -Path ([string]$instance.installationPath)
        $result.visualStudioPath = $vsRoot
        $result.visualStudioVersion = [string]$instance.installationVersion
        $msvcRoots = @(Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory -ErrorAction Stop | Sort-Object { [version]$_.Name } -Descending)
        if ($msvcRoots.Count -eq 0) { throw 'No MSVC toolset directory was found.' }
        $msvcRoot = $msvcRoots[0].FullName
        $result.msvcVersion = $msvcRoots[0].Name
        $sdkRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
        $sdkRoots = @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
        if ($sdkRoots.Count -eq 0) { throw 'No versioned Windows 10 SDK tools directory was found.' }
        $sdk = $sdkRoots[0]
        $result.windowsSdkVersion = $sdk.Name
        foreach ($definition in @(
            [pscustomobject]@{ name='cl.exe'; path=(Join-Path $msvcRoot 'bin\Hostx64\x64\cl.exe') },
            [pscustomobject]@{ name='link.exe'; path=(Join-Path $msvcRoot 'bin\Hostx64\x64\link.exe') },
            [pscustomobject]@{ name='rc.exe'; path=(Join-Path $sdk.FullName 'x64\rc.exe') }
        )) {
            if (-not (Test-Path -LiteralPath $definition.path -PathType Leaf)) { throw "Required IL2CPP tool is missing: $($definition.path)" }
            $item = Get-Item -LiteralPath $definition.path -Force
            [void]$tools.Add([ordered]@{ name=$definition.name; path=$item.FullName; fileVersion=[string]$item.VersionInfo.FileVersion; sha256=Get-UpvFileSha256 -Path $item.FullName })
        }
        $canonical = @(
            "VS|$($result.visualStudioVersion)|$($result.visualStudioPath)",
            "MSVC|$($result.msvcVersion)",
            "SDK|$($result.windowsSdkVersion)"
        ) + @($tools | ForEach-Object { "TOOL|$($_.name)|$($_.fileVersion)|$($_.sha256)" })
        $result.identitySha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]$canonical))
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.tools = @($tools)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Validates one explicit Windows x64 Unity Player executable and its current build layout.
function Get-UpvrPrebuiltIdentityAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [Parameter(Mandatory = $true)][string]$PlayerExecutable
    )

    $result = [ordered]@{
        buildRoot=$null; executablePath=$null; executableSha256=$null; peValidated=$false; machine=$null
        dataDirectoryPath=$null; dataDirectoryExists=$false; signatureStatus=$null; signerSubject=$null
        tree=$null; accepted=$false; errors=@()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        $root = Get-UpvNormalizedPath -Path $BuildRoot
        $exe = Get-UpvNormalizedPath -Path $PlayerExecutable
        $result.buildRoot = $root
        $result.executablePath = $exe
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'BuildRoot is not an existing directory.' }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'PlayerExecutable is not an existing file.' }
        if (-not (Test-UpvPathWithinRoot -Path $exe -Root $root)) { throw 'PlayerExecutable must be strictly below BuildRoot.' }
        if ([System.IO.Path]::GetExtension($exe) -ine '.exe') { throw 'PlayerExecutable must have an .exe extension.' }
        if ($null -ne (Get-UpvReparsePointOnPath -Path $root) -or $null -ne (Get-UpvReparsePointOnPath -Path $exe)) { throw 'Prebuilt input traverses a reparse point.' }
        $bytes = [System.IO.File]::ReadAllBytes($exe)
        if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw 'PlayerExecutable is not an MZ executable.' }
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
        if ($peOffset -lt 0 -or $peOffset + 26 -ge $bytes.Length -or $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) { throw 'PlayerExecutable has an invalid PE header.' }
        $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        $magic = [BitConverter]::ToUInt16($bytes, $peOffset + 24)
        $result.machine = ('0x{0:x4}' -f $machine)
        if ($machine -ne 0x8664 -or $magic -ne 0x20b) { throw 'PlayerExecutable is not a PE32+ AMD64 executable.' }
        $data = Join-Path $root (([System.IO.Path]::GetFileNameWithoutExtension($exe)) + '_Data')
        $result.dataDirectoryPath = $data
        $result.dataDirectoryExists = Test-Path -LiteralPath $data -PathType Container
        if (-not $result.dataDirectoryExists) { throw 'Matching Unity Player Data directory is missing.' }
        $result.executableSha256 = Get-UpvFileSha256 -Path $exe
        $signature = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
        $result.signatureStatus = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) { $result.signerSubject = [string]$signature.SignerCertificate.Subject }
        $result.tree = Get-UpvrStableTreeSnapshot -Root $root
        $result.peValidated = $true
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Parses the fixed BuildPipeline summary emitted by the instrumented Standalone builder.
function Get-UpvrStandaloneBuildReportAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionToken,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory = $true)][string]$ExpectedBackend
    )

    $result = [ordered]@{
        exists=$false; sha256=$null; schemaVersion=$null; sessionTokenMatched=$false; result=$null
        outputPath=$null; outputPathMatched=$false; platform=$null; scriptingBackend=$null; backendMatched=$false
        buildGuid=$null; totalSize=$null; totalErrors=$null; totalWarnings=$null; startedAtUtc=$null
        durationSeconds=$null; buildErrors=@(); buildWarnings=@(); accepted=$false; errors=@()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Standalone build-report receipt is missing.' }
        $result.exists = $true
        $result.sha256 = Get-UpvFileSha256 -Path $Path
        $document = Read-UpvJsonFile -Path $Path
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames @(
            'schemaVersion','sessionToken','result','outputPath','platform','scriptingBackend','buildGuid',
            'totalSize','totalErrors','totalWarnings','errors','warnings','startedAtUtc','durationSeconds'
        ) -Context 'Standalone build report'
        foreach ($error in @($contract.errors)) { [void]$errors.Add($error) }
        foreach ($property in @('schemaVersion','result','outputPath','platform','scriptingBackend','buildGuid','totalSize','totalErrors','totalWarnings','startedAtUtc','durationSeconds')) { $result[$property] = $document.$property }
        $result.buildErrors = [string[]]@($document.errors)
        $result.buildWarnings = [string[]]@($document.warnings)
        $result.sessionTokenMatched = [string]$document.sessionToken -ceq $ExpectedSessionToken
        if (-not [string]::IsNullOrWhiteSpace([string]$result.outputPath)) { $result.outputPathMatched = (Get-UpvNormalizedPath $result.outputPath).Equals((Get-UpvNormalizedPath $ExpectedExecutablePath), $script:UpvPathComparison) }
        $result.backendMatched = $ExpectedBackend -ceq 'Project' -and [string]$result.scriptingBackend -in @('Mono','IL2CPP') -or [string]$result.scriptingBackend -ceq $ExpectedBackend
        if ([string]$result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Standalone build report schemaVersion must be 1.0.0.') }
        if (-not $result.sessionTokenMatched) { [void]$errors.Add('Standalone build report session token does not match.') }
        if ([string]$result.result -cne 'Succeeded') { [void]$errors.Add("Standalone BuildReport result is $($result.result), not Succeeded.") }
        if (-not $result.outputPathMatched) { [void]$errors.Add('Standalone BuildReport output path does not match.') }
        if ([string]$result.platform -cne 'StandaloneWindows64') { [void]$errors.Add('Standalone BuildReport platform is not StandaloneWindows64.') }
        if (-not $result.backendMatched) { [void]$errors.Add('Standalone BuildReport backend does not match the request.') }
        if ($result.buildErrors.Count -ne 0) { [void]$errors.Add('Standalone BuildReport step messages contain one or more concrete errors.') }
        if ([string]::IsNullOrWhiteSpace([string]$result.buildGuid)) { [void]$errors.Add('Standalone BuildReport GUID is missing.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Validates a receipt-backed Standalone build against current EXE and full-tree identities.
function Get-UpvrStandaloneBuildReceiptAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][AllowNull()][string]$ExpectedSessionToken,
        [Parameter(Mandatory = $true)][string]$ExpectedBuildRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath,
        [Parameter()][AllowNull()][string]$ExpectedOriginalFingerprint,
        [Parameter()][AllowNull()][string]$ExpectedOverlayTreeSha256,
        [Parameter()][AllowNull()][string]$ExpectedScenarioBundleTreeSha256,
        [Parameter()][AllowNull()][string]$ExpectedWindowsModuleTreeSha256,
        [Parameter()][AllowNull()][string]$ExpectedToolchainIdentitySha256,
        [Parameter()][ValidateSet('Project','Mono','IL2CPP')][string]$ExpectedBackend = 'Project',
        [Parameter(Mandatory = $true)][object]$CurrentTree
    )

    $result = [ordered]@{
        exists=$false; sha256=$null; schemaVersion=$null; sessionToken=$null; sessionTokenMatched=$null
        originalFingerprint=$null; overlayTreeSha256=$null; scenarioBundleTreeSha256=$null; unityVersion=$null
        windowsModuleTreeSha256=$null; toolchainIdentitySha256=$null; scriptingBackend=$null; backendMatched=$false
        scenes=@(); buildOptions=$null; developmentBuild=$null; buildGuid=$null; executablePath=$null
        executableSha256=$null; buildRoot=$null; treeCanonicalization=$null; buildTreeSha256=$null
        fileCount=$null; directoryCount=$null; totalBytes=$null; scenario=$null; accepted=$false; errors=@()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Standalone build receipt is missing.' }
        if ($null -ne (Get-UpvReparsePointOnPath -Path $Path)) { throw 'Standalone build receipt traverses a reparse point.' }
        $result.exists = $true
        $result.sha256 = Get-UpvFileSha256 -Path $Path
        $document = Read-UpvJsonFile -Path $Path
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames @(
            'schemaVersion','sessionToken','originalFingerprint','overlayTreeSha256','scenarioBundleTreeSha256',
            'unityVersion','windowsModuleTreeSha256','toolchainIdentitySha256','scriptingBackend','scenes',
            'buildOptions','developmentBuild','buildGuid','executablePath','executableSha256','buildRoot',
            'treeCanonicalization','buildTreeSha256','fileCount','directoryCount','totalBytes','scenario'
        ) -Context 'Standalone build receipt'
        foreach ($error in @($contract.errors)) { [void]$errors.Add($error) }
        foreach ($property in @(
            'schemaVersion','sessionToken','originalFingerprint','overlayTreeSha256','scenarioBundleTreeSha256','unityVersion',
            'windowsModuleTreeSha256','toolchainIdentitySha256','scriptingBackend','buildOptions','developmentBuild',
            'buildGuid','executablePath','executableSha256','buildRoot','treeCanonicalization','buildTreeSha256',
            'fileCount','directoryCount','totalBytes'
        )) { $result[$property] = $document.$property }
        $result.scenes = [string[]]@($document.scenes)
        $result.scenario = $document.scenario
        $scenarioContract = Test-UpvExactJsonProperties -InputObject $document.scenario -RequiredNames @(
            'scenarioId','displayName','timeoutSeconds','buildScenes','expectedScenes','expectedAssertionIds','expectedCaptureIds','graphicsRequired'
        ) -Context 'Standalone build receipt scenario'
        foreach ($error in @($scenarioContract.errors)) { [void]$errors.Add($error) }
        if ([string]$result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Standalone build receipt schemaVersion must be 1.0.0.') }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionToken)) {
            $result.sessionTokenMatched = [string]$result.sessionToken -ceq $ExpectedSessionToken
            if (-not $result.sessionTokenMatched) { [void]$errors.Add('Standalone build receipt session token does not match.') }
        }
        foreach ($identity in @(
            [pscustomobject]@{ name='originalFingerprint'; expected=$ExpectedOriginalFingerprint; actual=$result.originalFingerprint },
            [pscustomobject]@{ name='overlayTreeSha256'; expected=$ExpectedOverlayTreeSha256; actual=$result.overlayTreeSha256 },
            [pscustomobject]@{ name='scenarioBundleTreeSha256'; expected=$ExpectedScenarioBundleTreeSha256; actual=$result.scenarioBundleTreeSha256 },
            [pscustomobject]@{ name='windowsModuleTreeSha256'; expected=$ExpectedWindowsModuleTreeSha256; actual=$result.windowsModuleTreeSha256 },
            [pscustomobject]@{ name='toolchainIdentitySha256'; expected=$ExpectedToolchainIdentitySha256; actual=$result.toolchainIdentitySha256 }
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$identity.expected) -and [string]$identity.actual -cne [string]$identity.expected) { [void]$errors.Add("Standalone build receipt $($identity.name) does not match.") }
        }
        $result.backendMatched = $ExpectedBackend -ceq 'Project' -and [string]$result.scriptingBackend -in @('Mono','IL2CPP') -or [string]$result.scriptingBackend -ceq $ExpectedBackend
        if (-not $result.backendMatched) { [void]$errors.Add('Standalone build receipt backend does not match.') }
        if ($result.scenes.Count -eq 0 -or -not (Test-UpvExactStringSet -Expected $result.scenes -Actual ([string[]]@($document.scenario.buildScenes)))) { [void]$errors.Add('Standalone build receipt Scene lists are empty or inconsistent.') }
        if ([string]$result.buildOptions -cne 'None' -or [bool]$result.developmentBuild) { [void]$errors.Add('Standalone build receipt is not a non-development BuildOptions.None build.') }
        $normalizedRoot = Get-UpvNormalizedPath -Path $ExpectedBuildRoot
        $normalizedExe = Get-UpvNormalizedPath -Path $ExpectedExecutablePath
        if (-not (Get-UpvNormalizedPath $result.buildRoot).Equals($normalizedRoot, $script:UpvPathComparison)) { [void]$errors.Add('Standalone build receipt root does not match.') }
        if (-not (Get-UpvNormalizedPath $result.executablePath).Equals($normalizedExe, $script:UpvPathComparison)) { [void]$errors.Add('Standalone build receipt executable path does not match.') }
        if (-not (Test-Path -LiteralPath $normalizedExe -PathType Leaf) -or (Get-UpvFileSha256 $normalizedExe) -cne [string]$result.executableSha256) { [void]$errors.Add('Standalone build receipt executable hash does not match current bytes.') }
        if ([string]$result.treeCanonicalization -cne $script:UpvrTreeCanonicalization) { [void]$errors.Add('Standalone build receipt tree canonicalization is unsupported.') }
        if ([string]$result.buildTreeSha256 -cne [string]$CurrentTree.treeSha256 -or [int]$result.fileCount -ne [int]$CurrentTree.fileCount -or [int]$result.directoryCount -ne [int]$CurrentTree.directoryCount -or [long]$result.totalBytes -ne [long]$CurrentTree.totalBytes) { [void]$errors.Add('Standalone build receipt tree identity does not match current build bytes.') }
        foreach ($hash in @($result.originalFingerprint,$result.overlayTreeSha256,$result.scenarioBundleTreeSha256,$result.windowsModuleTreeSha256,$result.executableSha256,$result.buildTreeSha256)) { if ([string]$hash -notmatch '^[0-9a-f]{64}$') { [void]$errors.Add('Standalone build receipt contains an invalid SHA-256 value.'); break } }
        if ([string]$result.scriptingBackend -ceq 'IL2CPP' -and [string]$result.toolchainIdentitySha256 -notmatch '^[0-9a-f]{64}$') { [void]$errors.Add('IL2CPP build receipt lacks a valid toolchain identity.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}
