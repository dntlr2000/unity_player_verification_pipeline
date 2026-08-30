Set-StrictMode -Version Latest

$script:UpvrUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UpvrTreeCanonicalization = 'upvr-tree-relative-path-length-sha256-lf-v1'
$script:UpvrBuildToolchainIdentityAlgorithm = 'upvr-il2cpp-build-toolchain-v2'
$script:UpvrHostEnvironmentIdentityAlgorithm = 'upvr-il2cpp-host-environment-v1'
$script:UpvrBeeObservationAlgorithm = 'upvr-bee-tool-path-observation-v1'
$script:UpvrRequiredVisualStudioComponentIds = [string[]]@('Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
$script:UpvrToolchainTreeCache = @{}

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
        beeBackendPath = $null
        beeBackendSha256 = $null
        il2cppExecutablePath = $null
        il2cppExecutableSha256 = $null
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
        $editorDataRoot = Join-Path -Path $editorRoot -ChildPath 'Data'
        foreach ($relativeBeePath in @(
            'Tools\BuildPipeline\bee_backend.exe',
            'bee_backend.exe',
            'il2cpp\build\deploy\bee_backend\win-x64\bee_backend.exe'
        )) {
            $candidateBeePath = Join-Path -Path $editorDataRoot -ChildPath $relativeBeePath
            if (Test-Path -LiteralPath $candidateBeePath -PathType Leaf) {
                $result.beeBackendPath = Get-UpvNormalizedPath -Path $candidateBeePath
                $result.beeBackendSha256 = Get-UpvrFileSha256 -Path $candidateBeePath
                break
            }
        }
        $il2cppExecutablePath = Join-Path -Path $editorDataRoot -ChildPath 'il2cpp\build\deploy\il2cpp.exe'
        if (Test-Path -LiteralPath $il2cppExecutablePath -PathType Leaf) {
            $result.il2cppExecutablePath = Get-UpvNormalizedPath -Path $il2cppExecutablePath
            $result.il2cppExecutableSha256 = Get-UpvrFileSha256 -Path $il2cppExecutablePath
        }
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

# Matches one versioned Editor, Test Framework, module, target, backend, and toolchain-profile contract.
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
        unityIl2CppExecutableSha256 = $null
        unityBeeBackendExecutableSha256 = $null
        approvedToolchainProfileIds = @()
        toolchainProfiles = @()
        toolchainIdentitySha256 = $null
        visualStudioVersion = $null
        msvcVersion = $null
        windowsSdkVersion = $null
        evidencePath = $null
        evidenceSha256 = $null
        legacyRegistry = $false
        approved = $false
        error = $null
    }
    try {
        $registry = Read-UpvJsonFile -Path $RegistryPath
        $result.registrySchemaVersion = [string](Get-UpvJsonProperty -InputObject $registry -Name 'schemaVersion')
        if ($result.registrySchemaVersion -ceq '1.1.0') {
            $result.legacyRegistry = $true
            $entries = @(Get-UpvJsonProperty -InputObject $registry -Name 'entries')
            $legacyMatches = @($entries | Where-Object {
                [string]$_.unityVersion -ceq $UnityVersion -and
                [string]$_.testFrameworkVersion -ceq $TestFrameworkVersion -and
                [string]$_.target -ceq 'StandaloneWindows64' -and
                [string]$_.scriptingBackend -ceq $ScriptingBackend
            })
            if ($legacyMatches.Count -gt 1) { throw 'Legacy Player compatibility registry contains a duplicate exact tuple.' }
            if ($legacyMatches.Count -eq 0) { return [pscustomobject]$result }
            $legacyEntry = $legacyMatches[0]
            $result.entryFound = $true
            $result.entryStatus = [string]$legacyEntry.status
            $result.minimumPhase = [string]$legacyEntry.minimumPhase
            $result.allowedSourceKind = [string]$legacyEntry.allowedSourceKind
            $result.registryOrigin = Get-UpvJsonProperty -InputObject $legacyEntry -Name 'registryOrigin'
            $result.unityExecutableSha256 = [string]$legacyEntry.unityExecutableSha256
            $result.packageTreeSha256 = [string]$legacyEntry.packageTreeSha256
            $result.packageHashCanonicalization = [string]$legacyEntry.packageHashCanonicalization
            $result.windowsModuleTreeSha256 = [string]$legacyEntry.windowsModuleTreeSha256
            $result.moduleHashCanonicalization = [string]$legacyEntry.moduleHashCanonicalization
            $result.toolchainIdentitySha256 = Get-UpvJsonProperty -InputObject $legacyEntry -Name 'toolchainIdentitySha256'
            $result.visualStudioVersion = Get-UpvJsonProperty -InputObject $legacyEntry -Name 'visualStudioVersion'
            $result.msvcVersion = Get-UpvJsonProperty -InputObject $legacyEntry -Name 'msvcVersion'
            $result.windowsSdkVersion = Get-UpvJsonProperty -InputObject $legacyEntry -Name 'windowsSdkVersion'
            $result.evidencePath = [string]$legacyEntry.evidencePath
            if ($ScriptingBackend -ceq 'IL2CPP') {
                throw 'Schema 1.1.0 IL2CPP entries contain only the retired aggregate identity and cannot authorize a v0.4 build; migrate to a schema 1.2.0 approved toolchain profile.'
            }
            $result.approved = [string]$legacyEntry.status -ceq 'APPROVED'
            return [pscustomobject]$result
        }
        if ($result.registrySchemaVersion -cne '1.2.0') {
            throw 'Player compatibility registry schemaVersion must be 1.2.0; schema 1.1.0 is accepted only for legacy Mono replay.'
        }
        $topContract = Test-UpvExactJsonProperties -InputObject $registry -RequiredNames @(
            'schemaVersion', 'identityAlgorithms', 'toolchainProfiles', 'compatibilityEntries'
        ) -Context 'Player compatibility registry'
        if (-not $topContract.accepted) { throw ([string]::Join(' ', [string[]]@($topContract.errors))) }
        $algorithms = Get-UpvJsonProperty -InputObject $registry -Name 'identityAlgorithms'
        $algorithmContract = Test-UpvExactJsonProperties -InputObject $algorithms -RequiredNames @(
            'buildToolchain', 'hostEnvironment', 'tree', 'packageTree'
        ) -Context 'Player compatibility identityAlgorithms'
        if (-not $algorithmContract.accepted) { throw ([string]::Join(' ', [string[]]@($algorithmContract.errors))) }
        if ([string]$algorithms.buildToolchain -cne $script:UpvrBuildToolchainIdentityAlgorithm -or
            [string]$algorithms.hostEnvironment -cne $script:UpvrHostEnvironmentIdentityAlgorithm -or
            [string]$algorithms.tree -cne $script:UpvrTreeCanonicalization -or
            [string]$algorithms.packageTree -cne 'upv-package-tree-relative-path-length-sha256-lf-v1') {
            throw 'Player compatibility registry declares an unsupported identity algorithm.'
        }

        $profiles = @(Get-UpvJsonProperty -InputObject $registry -Name 'toolchainProfiles')
        $profilesById = @{}
        foreach ($profile in $profiles) {
            $profileContract = Test-UpvExactJsonProperties -InputObject $profile -RequiredNames @(
                'profileId', 'status', 'buildToolchainIdentity', 'approvalHostEnvironmentIdentity', 'approval'
            ) -Context 'Player toolchain profile'
            if (-not $profileContract.accepted) { throw ([string]::Join(' ', [string[]]@($profileContract.errors))) }
            $profileId = [string]$profile.profileId
            if ($profileId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$') { throw "Player toolchain profile has invalid profileId '$profileId'." }
            if ($profilesById.ContainsKey($profileId)) { throw "Player compatibility registry contains duplicate toolchain profile '$profileId'." }
            if ([string]$profile.status -notin @('CANDIDATE', 'APPROVED', 'RETIRED')) { throw "Player toolchain profile '$profileId' has an invalid status." }
            $buildIdentity = $profile.buildToolchainIdentity
            if ([string]$buildIdentity.algorithm -cne $script:UpvrBuildToolchainIdentityAlgorithm -or [string]$buildIdentity.identitySha256 -notmatch '^[0-9a-f]{64}$') {
                throw "Player toolchain profile '$profileId' has an invalid build identity."
            }
            if ([string]$buildIdentity.identitySha256 -cne (Get-UpvrBuildToolchainManifestSha256 -Identity $buildIdentity)) {
                throw "Player toolchain profile '$profileId' build identity does not match its canonical manifest."
            }
            $hostIdentity = $profile.approvalHostEnvironmentIdentity
            if ([string]$hostIdentity.algorithm -cne $script:UpvrHostEnvironmentIdentityAlgorithm -or [string]$hostIdentity.identitySha256 -notmatch '^[0-9a-f]{64}$') {
                throw "Player toolchain profile '$profileId' has an invalid approval host identity."
            }
            if ([string]$hostIdentity.identitySha256 -cne (Get-UpvrHostEnvironmentManifestSha256 -Identity $hostIdentity)) {
                throw "Player toolchain profile '$profileId' approval host identity does not match its canonical manifest."
            }
            if ([string]$profile.status -ceq 'APPROVED') {
                if ([string]$profile.approval.evidenceSha256 -notmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace([string]$profile.approval.evidencePath) -or [string]::IsNullOrWhiteSpace([string]$profile.approval.approvedAtUtc)) {
                    throw "Approved Player toolchain profile '$profileId' lacks immutable approval evidence."
                }
            }
            $profilesById[$profileId] = $profile
        }

        $entries = @(Get-UpvJsonProperty -InputObject $registry -Name 'compatibilityEntries')
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
            'unityIl2CppExecutableSha256', 'unityBeeBackendExecutableSha256', 'approvedToolchainProfileIds',
            'minimumPhase', 'status', 'evidencePath', 'evidenceSha256'
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
            foreach ($hashName in @('unityIl2CppExecutableSha256', 'unityBeeBackendExecutableSha256')) {
                if ([string]$entry.$hashName -notmatch '^[0-9a-f]{64}$') { throw "IL2CPP compatibility entry has an invalid $hashName." }
            }
            $profileIds = [string[]]@($entry.approvedToolchainProfileIds)
            if ($profileIds.Count -eq 0) { throw 'IL2CPP compatibility entry has no toolchain profile references.' }
            if (@($profileIds | Sort-Object -Unique).Count -ne $profileIds.Count) { throw 'IL2CPP compatibility entry contains duplicate toolchain profile references.' }
            foreach ($profileId in $profileIds) {
                if (-not $profilesById.ContainsKey($profileId)) { throw "IL2CPP compatibility entry references missing toolchain profile '$profileId'." }
            }
        } else {
            if ($null -ne (Get-UpvJsonProperty -InputObject $entry -Name 'unityIl2CppExecutableSha256') -or
                $null -ne (Get-UpvJsonProperty -InputObject $entry -Name 'unityBeeBackendExecutableSha256') -or
                @($entry.approvedToolchainProfileIds).Count -ne 0) { throw 'Mono compatibility entries cannot reference IL2CPP components or toolchain profiles.' }
        }
        if ([string]$entry.evidenceSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Player compatibility entry has an invalid evidenceSha256.' }
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
        $result.unityIl2CppExecutableSha256 = Get-UpvJsonProperty -InputObject $entry -Name 'unityIl2CppExecutableSha256'
        $result.unityBeeBackendExecutableSha256 = Get-UpvJsonProperty -InputObject $entry -Name 'unityBeeBackendExecutableSha256'
        $result.approvedToolchainProfileIds = [string[]]@($entry.approvedToolchainProfileIds)
        $result.toolchainProfiles = @($result.approvedToolchainProfileIds | ForEach-Object { $profilesById[$_] })
        $result.evidencePath = [string]$entry.evidencePath
        $result.evidenceSha256 = [string]$entry.evidenceSha256
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
        $expectedReceiptResult = if (
            $result.assertionsPassed -and $result.captureIdsMatched -and $result.capturesPresent -and
            [string]::IsNullOrWhiteSpace([string]$result.exception)
        ) { 'PASSED' } else { 'FAILED' }
        if ([string]$result.result -cne $expectedReceiptResult) {
            [void]$errors.Add('Scenario receipt result does not agree with its execution, assertion, and capture evidence.')
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.missingCaptureIds = [string[]]@($missingCaptures | Sort-Object -Unique)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0 -and $result.assertionsPassed -and $result.capturesPresent -and
        [string]$result.result -ceq 'PASSED' -and [string]::IsNullOrWhiteSpace([string]$result.exception)
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

# Returns a cached deterministic tree identity while allowing drift checks to force fresh bytes.
function Get-UpvrToolchainTreeIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter()][switch]$BypassCache
    )

    $normalizedRoot = Get-UpvNormalizedPath -Path $Root
    $cacheKey = $normalizedRoot.ToUpperInvariant()
    if (-not $BypassCache -and $script:UpvrToolchainTreeCache.ContainsKey($cacheKey)) {
        $cached = $script:UpvrToolchainTreeCache[$cacheKey]
        return [pscustomobject][ordered]@{
            name=$Name; root=$normalizedRoot; canonicalization=$cached.canonicalization
            directoryCount=$cached.directoryCount; fileCount=$cached.fileCount; totalBytes=$cached.totalBytes
            treeSha256=$cached.treeSha256
        }
    }
    $snapshot = Get-UpvrStableTreeSnapshot -Root $normalizedRoot
    if (-not $BypassCache) { $script:UpvrToolchainTreeCache[$cacheKey] = $snapshot }
    return [pscustomobject][ordered]@{
        name=$Name; root=$normalizedRoot; canonicalization=$snapshot.canonicalization
        directoryCount=$snapshot.directoryCount; fileCount=$snapshot.fileCount; totalBytes=$snapshot.totalBytes
        treeSha256=$snapshot.treeSha256
    }
}

# Captures one required native tool as both an absolute observation and a path-independent manifest entry.
function Get-UpvrToolchainFileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('MSVC','WINDOWS_SDK')][string]$RootKind,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $normalizedRoot = Get-UpvNormalizedPath -Path $Root
    $path = Join-Path -Path $normalizedRoot -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required IL2CPP tool is missing: $path" }
    if ($null -ne (Get-UpvReparsePointOnPath -Path $path)) { throw "Required IL2CPP tool traverses a reparse point: $path" }
    $item = Get-Item -LiteralPath $path -Force
    return [pscustomobject][ordered]@{
        name=$Name; rootKind=$RootKind; relativePath=$RelativePath.Replace('\','/')
        path=$item.FullName; fileVersion=[string]$item.VersionInfo.FileVersion
        sha256=Get-UpvrFileSha256 -Path $item.FullName
    }
}

# Recomputes the canonical build-toolchain hash from one stored profile manifest.
function Get-UpvrBuildToolchainManifestSha256 {
    param([Parameter(Mandatory = $true)][object]$Identity)

    $canonical = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "ALG|$([string]$Identity.algorithm)",
        "ARCH|$([string]$Identity.hostArchitecture)|$([string]$Identity.targetArchitecture)",
        "MSVC|$([string]$Identity.msvcVersion)",
        "SDK|$([string]$Identity.windowsSdkVersion)"
    )) { $canonical.Add($line) }
    foreach ($tool in @($Identity.tools)) {
        $canonical.Add("TOOL|$([string]$tool.name)|$([string]$tool.rootKind)|$([string]$tool.relativePath)|$([string]$tool.fileVersion)|$([string]$tool.sha256)")
    }
    foreach ($tree in @($Identity.trees)) {
        $canonical.Add("TREE|$([string]$tree.name)|$([string]$tree.canonicalization)|$([string]$tree.directoryCount)|$([string]$tree.fileCount)|$([string]$tree.totalBytes)|$([string]$tree.treeSha256)")
    }
    return Get-UpvTextSha256 -Text ([string]::Join([char]10, $canonical.ToArray()))
}

# Recomputes the canonical host-environment hash from one stored profile manifest.
function Get-UpvrHostEnvironmentManifestSha256 {
    param([Parameter(Mandatory = $true)][object]$Identity)

    $canonical = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "ALG|$([string]$Identity.algorithm)",
        "INSTANCE|$([string]$Identity.visualStudioInstanceId)",
        "VERSION|$([string]$Identity.visualStudioVersion)",
        "PRODUCT|$([string]$Identity.visualStudioProductId)",
        "CHANNEL|$([string]$Identity.visualStudioChannelId)",
        "PATH|$([string]$Identity.visualStudioPath)",
        "STATE|$([uint64]$Identity.installationState)",
        "COMPLETE|$([bool]$Identity.isComplete)",
        "LAUNCHABLE|$([bool]$Identity.isLaunchable)",
        "PRERELEASE|$([bool]$Identity.isPrerelease)",
        "REBOOT|$([bool]$Identity.isRebootRequired)"
    )) { $canonical.Add($line) }
    foreach ($component in @($Identity.requiredComponentIds)) { $canonical.Add("COMPONENT|$([string]$component)") }
    $canonical.Add("DISCOVERY|$([string]$Identity.discoveryTool.path)|$([string]$Identity.discoveryTool.fileVersion)|$([string]$Identity.discoveryTool.sha256)")
    return Get-UpvTextSha256 -Text ([string]::Join([char]10, $canonical.ToArray()))
}

# Builds a host-only Visual Studio identity that can drift without changing approved build bytes between runs.
function Get-UpvrHostEnvironmentIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$VisualStudioInstance,
        [Parameter(Mandatory = $true)][string]$VsWherePath
    )

    $vswhere = Get-Item -LiteralPath $VsWherePath -Force
    $visualStudioPath = Get-UpvNormalizedPath -Path ([string]$VisualStudioInstance.installationPath)
    $requiredComponents = [string[]]@($script:UpvrRequiredVisualStudioComponentIds | Sort-Object)
    $discoveryTool = [pscustomobject][ordered]@{
        path=$vswhere.FullName; fileVersion=[string]$vswhere.VersionInfo.FileVersion
        sha256=Get-UpvrFileSha256 -Path $vswhere.FullName
    }
    $identity = [pscustomobject][ordered]@{
        algorithm=$script:UpvrHostEnvironmentIdentityAlgorithm
        identitySha256=$null
        visualStudioInstanceId=[string]$VisualStudioInstance.instanceId
        visualStudioVersion=[string]$VisualStudioInstance.installationVersion
        visualStudioProductId=[string]$VisualStudioInstance.productId
        visualStudioChannelId=[string]$VisualStudioInstance.channelId
        visualStudioPath=$visualStudioPath
        installationState=[uint64]$VisualStudioInstance.state
        isComplete=[bool]$VisualStudioInstance.isComplete
        isLaunchable=[bool]$VisualStudioInstance.isLaunchable
        isPrerelease=[bool]$VisualStudioInstance.isPrerelease
        isRebootRequired=[bool]$VisualStudioInstance.isRebootRequired
        requiredComponentIds=$requiredComponents
        discoveryTool=$discoveryTool
    }
    $identity.identitySha256 = Get-UpvrHostEnvironmentManifestSha256 -Identity $identity
    return $identity
}

# Constructs one path-independent IL2CPP build identity from an explicit VS, MSVC, and SDK tuple.
function New-UpvrIl2CppToolchainCandidateIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$VisualStudioInstance,
        [Parameter(Mandatory = $true)][string]$MsvcRoot,
        [Parameter(Mandatory = $true)][string]$WindowsKitsRoot,
        [Parameter(Mandatory = $true)][string]$WindowsSdkVersion,
        [Parameter(Mandatory = $true)][string]$VsWherePath,
        [Parameter()][switch]$BypassTreeCache
    )

    $errors = New-Object System.Collections.ArrayList
    $result = [ordered]@{
        candidateId=$null; visualStudioPath=$null; visualStudioInstanceId=$null; visualStudioVersion=$null
        msvcRoot=$null; msvcVersion=$null; windowsKitsRoot=$null; windowsSdkVersion=$WindowsSdkVersion
        buildToolchainIdentity=$null; hostEnvironmentIdentity=$null; tools=@(); trees=@(); accepted=$false; errors=@()
    }
    try {
        $vsRoot = Get-UpvNormalizedPath -Path ([string]$VisualStudioInstance.installationPath)
        $normalizedMsvcRoot = Get-UpvNormalizedPath -Path $MsvcRoot
        $normalizedKitsRoot = Get-UpvNormalizedPath -Path $WindowsKitsRoot
        if (-not (Test-UpvPathWithinRoot -Path $normalizedMsvcRoot -Root $vsRoot)) { throw 'MSVC root must be strictly below the selected Visual Studio instance.' }
        foreach ($path in @($vsRoot, $normalizedMsvcRoot, $normalizedKitsRoot)) {
            if ($null -ne (Get-UpvReparsePointOnPath -Path $path)) { throw "IL2CPP toolchain root traverses a reparse point: $path" }
        }
        $msvcVersion = Split-Path -Leaf $normalizedMsvcRoot
        $msvcBinRelative = 'bin\Hostx64\x64'
        $toolDefinitions = @(
            [pscustomobject]@{ name='cl.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'cl.exe') },
            [pscustomobject]@{ name='c1.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'c1.dll') },
            [pscustomobject]@{ name='c1xx.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'c1xx.dll') },
            [pscustomobject]@{ name='c2.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'c2.dll') },
            [pscustomobject]@{ name='link.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'link.exe') },
            [pscustomobject]@{ name='lib.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'lib.exe') },
            [pscustomobject]@{ name='cvtres.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'cvtres.exe') },
            [pscustomobject]@{ name='msobj140.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'msobj140.dll') },
            [pscustomobject]@{ name='mspdb140.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'mspdb140.dll') },
            [pscustomobject]@{ name='mspdbcore.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'mspdbcore.dll') },
            [pscustomobject]@{ name='mspdbsrv.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'mspdbsrv.exe') },
            [pscustomobject]@{ name='mspdbst.dll'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'mspdbst.dll') },
            [pscustomobject]@{ name='mspdbcmf.exe'; rootKind='MSVC'; root=$normalizedMsvcRoot; relative=(Join-Path $msvcBinRelative 'mspdbcmf.exe') },
            [pscustomobject]@{ name='rc.exe'; rootKind='WINDOWS_SDK'; root=$normalizedKitsRoot; relative=("bin\$WindowsSdkVersion\x64\rc.exe") },
            [pscustomobject]@{ name='mt.exe'; rootKind='WINDOWS_SDK'; root=$normalizedKitsRoot; relative=("bin\$WindowsSdkVersion\x64\mt.exe") }
        )
        $observedTools = New-Object System.Collections.ArrayList
        foreach ($definition in $toolDefinitions) {
            [void]$observedTools.Add((Get-UpvrToolchainFileIdentity -Name $definition.name -RootKind $definition.rootKind -Root $definition.root -RelativePath $definition.relative))
        }
        $observedTrees = [object[]]@(
            Get-UpvrToolchainTreeIdentity -Name 'msvcInclude' -Root (Join-Path $normalizedMsvcRoot 'include') -BypassCache:$BypassTreeCache
            Get-UpvrToolchainTreeIdentity -Name 'msvcLibX64' -Root (Join-Path $normalizedMsvcRoot 'lib\x64') -BypassCache:$BypassTreeCache
            Get-UpvrToolchainTreeIdentity -Name 'windowsSdkInclude' -Root (Join-Path $normalizedKitsRoot "Include\$WindowsSdkVersion") -BypassCache:$BypassTreeCache
            Get-UpvrToolchainTreeIdentity -Name 'windowsSdkUcrtLibX64' -Root (Join-Path $normalizedKitsRoot "Lib\$WindowsSdkVersion\ucrt\x64") -BypassCache:$BypassTreeCache
            Get-UpvrToolchainTreeIdentity -Name 'windowsSdkUmLibX64' -Root (Join-Path $normalizedKitsRoot "Lib\$WindowsSdkVersion\um\x64") -BypassCache:$BypassTreeCache
        )
        $manifestTools = [object[]]@($observedTools | ForEach-Object {
            [pscustomobject][ordered]@{ name=$_.name; rootKind=$_.rootKind; relativePath=$_.relativePath; fileVersion=$_.fileVersion; sha256=$_.sha256 }
        })
        $manifestTrees = [object[]]@($observedTrees | ForEach-Object {
            [pscustomobject][ordered]@{ name=$_.name; canonicalization=$_.canonicalization; directoryCount=$_.directoryCount; fileCount=$_.fileCount; totalBytes=$_.totalBytes; treeSha256=$_.treeSha256 }
        })
        $buildIdentity = [pscustomobject][ordered]@{
            algorithm=$script:UpvrBuildToolchainIdentityAlgorithm
            identitySha256=$null
            hostArchitecture='x64'; targetArchitecture='x64'; msvcVersion=$msvcVersion
            windowsSdkVersion=$WindowsSdkVersion; tools=$manifestTools; trees=$manifestTrees
        }
        $buildIdentity.identitySha256 = Get-UpvrBuildToolchainManifestSha256 -Identity $buildIdentity
        $hostIdentity = Get-UpvrHostEnvironmentIdentity -VisualStudioInstance $VisualStudioInstance -VsWherePath $VsWherePath
        $result.visualStudioPath = $vsRoot
        $result.visualStudioInstanceId = [string]$VisualStudioInstance.instanceId
        $result.visualStudioVersion = [string]$VisualStudioInstance.installationVersion
        $result.msvcRoot = $normalizedMsvcRoot
        $result.msvcVersion = $msvcVersion
        $result.windowsKitsRoot = $normalizedKitsRoot
        $result.buildToolchainIdentity = $buildIdentity
        $result.hostEnvironmentIdentity = $hostIdentity
        $result.tools = @($observedTools)
        $result.trees = @($observedTrees)
        $result.candidateId = "candidate-$($buildIdentity.identitySha256.Substring(0,12))-$($hostIdentity.identitySha256.Substring(0,8))"
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Enumerates every complete Visual Studio C++ instance instead of relying on vswhere -latest.
function Get-UpvrVisualStudioInstanceInventory {
    param(
        [Parameter()][string]$VsWherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
        [Parameter()][AllowNull()][string]$VisualStudioPath
    )

    $result = [ordered]@{ vsWherePath=$null; instances=@(); accepted=$false; errors=@() }
    $errors = New-Object System.Collections.ArrayList
    try {
        $vswhere = Get-UpvNormalizedPath -Path $VsWherePath
        $result.vsWherePath = $vswhere
        if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere.exe is missing.' }
        $arguments = @('-all', '-prerelease', '-products', '*', '-requires') + $script:UpvrRequiredVisualStudioComponentIds + @('-format', 'json', '-utf8')
        $raw = @(& $vswhere @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "vswhere.exe exited with code $LASTEXITCODE." }
        $instances = @((ConvertFrom-Json -InputObject ([string]::Join([Environment]::NewLine, [string[]]$raw))))
        $eligible = @($instances | Where-Object { [bool]$_.isComplete -and [bool]$_.isLaunchable -and -not [bool]$_.isRebootRequired })
        if (-not [string]::IsNullOrWhiteSpace($VisualStudioPath)) {
            $requiredPath = Get-UpvNormalizedPath -Path $VisualStudioPath
            $eligible = @($eligible | Where-Object { (Get-UpvNormalizedPath -Path ([string]$_.installationPath)).Equals($requiredPath, $script:UpvPathComparison) })
        }
        $result.instances = @($eligible | Sort-Object -Property @{Expression={ [string]$_.installationPath }}, @{Expression={ [string]$_.instanceId }})
        if ($result.instances.Count -eq 0) { throw 'No complete and launchable Visual Studio C++ instance matched the requested constraint.' }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Enumerates every valid VS/MSVC/Windows SDK candidate so profile selection is explicit and deterministic.
function Get-UpvrIl2CppToolchainCandidates {
    param(
        [Parameter()][AllowNull()][string]$VisualStudioPath,
        [Parameter()][AllowNull()][string]$MsvcVersion,
        [Parameter()][AllowNull()][string]$WindowsSdkVersion,
        [Parameter()][string]$VsWherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
        [Parameter()][string]$WindowsKitsRoot = 'C:\Program Files (x86)\Windows Kits\10',
        [Parameter()][switch]$BypassTreeCache
    )

    $result = [ordered]@{ requested=$true; candidates=@(); rejectedCandidates=@(); accepted=$false; errors=@() }
    $errors = New-Object System.Collections.ArrayList
    $candidates = New-Object System.Collections.ArrayList
    $rejected = New-Object System.Collections.ArrayList
    try {
        $inventory = Get-UpvrVisualStudioInstanceInventory -VsWherePath $VsWherePath -VisualStudioPath $VisualStudioPath
        if (-not $inventory.accepted) { throw ([string]::Join(' ', [string[]]@($inventory.errors))) }
        $kitsRoot = Get-UpvNormalizedPath -Path $WindowsKitsRoot
        $sdkDirectories = @(Get-ChildItem -LiteralPath (Join-Path $kitsRoot 'bin') -Directory -ErrorAction Stop | Where-Object {
            $_.Name -match '^10\.0\.\d+\.\d+$' -and ([string]::IsNullOrWhiteSpace($WindowsSdkVersion) -or $_.Name -ceq $WindowsSdkVersion)
        } | Sort-Object { [version]$_.Name } -Descending)
        if ($sdkDirectories.Count -eq 0) { throw 'No versioned Windows SDK candidate matched the requested constraint.' }
        foreach ($instance in @($inventory.instances)) {
            $vsRoot = Get-UpvNormalizedPath -Path ([string]$instance.installationPath)
            $msvcDirectories = @(Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory -ErrorAction Stop | Where-Object {
                [string]::IsNullOrWhiteSpace($MsvcVersion) -or $_.Name -ceq $MsvcVersion
            } | Sort-Object { [version]$_.Name } -Descending)
            foreach ($msvcDirectory in $msvcDirectories) {
                foreach ($sdkDirectory in $sdkDirectories) {
                    $candidate = New-UpvrIl2CppToolchainCandidateIdentity -VisualStudioInstance $instance -MsvcRoot $msvcDirectory.FullName -WindowsKitsRoot $kitsRoot -WindowsSdkVersion $sdkDirectory.Name -VsWherePath $inventory.vsWherePath -BypassTreeCache:$BypassTreeCache
                    if ($candidate.accepted) { [void]$candidates.Add($candidate) } else { [void]$rejected.Add($candidate) }
                }
            }
        }
        if ($candidates.Count -eq 0) { throw 'No complete IL2CPP toolchain candidate could be identified.' }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.candidates = @($candidates | Sort-Object -Property visualStudioPath, msvcVersion, windowsSdkVersion)
    $result.rejectedCandidates = @($rejected)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Selects one and only one approved profile/candidate pair, honoring explicit path and profile constraints.
function Select-UpvrApprovedToolchainCandidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter()][AllowNull()][string]$ToolchainProfileId,
        [Parameter()][AllowNull()][string]$VisualStudioPath
    )

    $result = [ordered]@{ selectedCandidate=$null; selectedProfile=$null; matches=@(); warnings=@(); accepted=$false; errors=@() }
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    try {
        $eligibleProfiles = @($Profiles)
        if (-not [string]::IsNullOrWhiteSpace($ToolchainProfileId)) {
            $eligibleProfiles = @($eligibleProfiles | Where-Object { [string]$_.profileId -ceq $ToolchainProfileId })
            if ($eligibleProfiles.Count -ne 1) { throw "ToolchainProfileId '$ToolchainProfileId' is not referenced exactly once by the selected compatibility entry." }
        }
        $eligibleCandidates = @($Candidates)
        if (-not [string]::IsNullOrWhiteSpace($VisualStudioPath)) {
            $requiredPath = Get-UpvNormalizedPath -Path $VisualStudioPath
            $eligibleCandidates = @($eligibleCandidates | Where-Object { ([string]$_.visualStudioPath).Equals($requiredPath, $script:UpvPathComparison) })
        }
        $identityMatches = New-Object System.Collections.ArrayList
        foreach ($profile in $eligibleProfiles) {
            foreach ($candidate in $eligibleCandidates) {
                if ([string]$profile.buildToolchainIdentity.algorithm -ceq [string]$candidate.buildToolchainIdentity.algorithm -and
                    [string]$profile.buildToolchainIdentity.identitySha256 -ceq [string]$candidate.buildToolchainIdentity.identitySha256) {
                    [void]$identityMatches.Add([pscustomobject][ordered]@{ profile=$profile; candidate=$candidate })
                }
            }
        }
        $approvedMatches = @($identityMatches | Where-Object { [string]$_.profile.status -ceq 'APPROVED' })
        if ($approvedMatches.Count -eq 0) {
            $candidateMatches = @($identityMatches | Where-Object { [string]$_.profile.status -ceq 'CANDIDATE' })
            $retiredMatches = @($identityMatches | Where-Object { [string]$_.profile.status -ceq 'RETIRED' })
            if ($candidateMatches.Count -gt 0) { throw 'Only a CANDIDATE IL2CPP toolchain profile matches; signed-Unity approval is required before production use.' }
            if ($retiredMatches.Count -gt 0) { throw 'Only a RETIRED IL2CPP toolchain profile matches; retired profiles cannot authorize a build.' }
            throw 'No installed IL2CPP toolchain candidate matches an approved profile for this compatibility entry.'
        }
        if ($approvedMatches.Count -gt 1) {
            throw 'Multiple approved IL2CPP profile/candidate pairs match; provide ToolchainProfileId and/or VisualStudioPath until exactly one pair remains.'
        }
        $selected = $approvedMatches[0]
        if ([string]$selected.profile.approvalHostEnvironmentIdentity.identitySha256 -cne [string]$selected.candidate.hostEnvironmentIdentity.identitySha256) {
            [void]$warnings.Add('Visual Studio host metadata differs from the approval host while the approved build-toolchain identity remains exact.')
        }
        $result.selectedCandidate = $selected.candidate
        $result.selectedProfile = $selected.profile
        $result.matches = @($identityMatches | ForEach-Object { [pscustomobject][ordered]@{ profileId=$_.profile.profileId; profileStatus=$_.profile.status; candidateId=$_.candidate.candidateId; visualStudioPath=$_.candidate.visualStudioPath } })
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.warnings = @($warnings)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Compares two fully observed candidates and fails closed on either build-byte or within-run host drift.
function Compare-UpvrIl2CppToolchainIdentities {
    param(
        [Parameter(Mandatory = $true)][object]$PreBuild,
        [Parameter(Mandatory = $true)][object]$PostBuild
    )

    $errors = New-Object System.Collections.ArrayList
    $buildIdentityUnchanged = [string]$PreBuild.buildToolchainIdentity.identitySha256 -ceq [string]$PostBuild.buildToolchainIdentity.identitySha256
    $hostIdentityUnchanged = [string]$PreBuild.hostEnvironmentIdentity.identitySha256 -ceq [string]$PostBuild.hostEnvironmentIdentity.identitySha256
    if (-not $buildIdentityUnchanged) { [void]$errors.Add('IL2CPP build-toolchain identity changed while Unity was running.') }
    if (-not $hostIdentityUnchanged) { [void]$errors.Add('Visual Studio host-environment identity changed while Unity was running.') }
    return [pscustomobject][ordered]@{
        preBuild=$PreBuild; postBuild=$PostBuild; buildIdentityUnchanged=$buildIdentityUnchanged
        hostIdentityUnchanged=$hostIdentityUnchanged; accepted=$errors.Count -eq 0; errors=@($errors)
    }
}

# Recomputes the selected tuple after the Editor exits to detect build-byte or host drift during execution.
function Test-UpvrIl2CppToolchainDrift {
    param(
        [Parameter(Mandatory = $true)][object]$SelectedCandidate,
        [Parameter()][string]$VsWherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    )

    $result = [ordered]@{ preBuild=$SelectedCandidate; postBuild=$null; buildIdentityUnchanged=$false; hostIdentityUnchanged=$false; accepted=$false; errors=@() }
    $errors = New-Object System.Collections.ArrayList
    try {
        $inventory = Get-UpvrVisualStudioInstanceInventory -VsWherePath $VsWherePath -VisualStudioPath ([string]$SelectedCandidate.visualStudioPath)
        if (-not $inventory.accepted -or @($inventory.instances).Count -ne 1) { throw 'The selected Visual Studio instance is missing or ambiguous after the build.' }
        $post = New-UpvrIl2CppToolchainCandidateIdentity -VisualStudioInstance $inventory.instances[0] -MsvcRoot ([string]$SelectedCandidate.msvcRoot) -WindowsKitsRoot ([string]$SelectedCandidate.windowsKitsRoot) -WindowsSdkVersion ([string]$SelectedCandidate.windowsSdkVersion) -VsWherePath $inventory.vsWherePath -BypassTreeCache
        if (-not $post.accepted) { throw ([string]::Join(' ', [string[]]@($post.errors))) }
        $comparison = Compare-UpvrIl2CppToolchainIdentities -PreBuild $SelectedCandidate -PostBuild $post
        $result.postBuild = $post
        $result.buildIdentityUnchanged = $comparison.buildIdentityUnchanged
        $result.hostIdentityUnchanged = $comparison.hostIdentityUnchanged
        foreach ($error in @($comparison.errors)) { [void]$errors.Add($error) }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Parses isolated Bee DAG JSON, normalizes Unity path separators, and proves that the selected native tools were observed.
function Get-UpvrBeeToolchainObservation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectCopyPath,
        [Parameter(Mandatory = $true)][object]$SelectedCandidate
    )

    $result = [ordered]@{
        algorithm=$script:UpvrBeeObservationAlgorithm; beeRoot=$null; sourceFiles=@(); observedTools=@()
        requiredToolNames=@('cl.exe','link.exe','lib.exe'); missingToolNames=@(); mismatchedTools=@(); accepted=$false; errors=@()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        $projectRoot = Get-UpvNormalizedPath -Path $ProjectCopyPath
        $beeRoot = Join-Path $projectRoot 'Library\Bee'
        $result.beeRoot = $beeRoot
        if (-not (Test-Path -LiteralPath $beeRoot -PathType Container)) { throw 'Isolated Unity build did not produce Library/Bee evidence.' }
        if ($null -ne (Get-UpvReparsePointOnPath -Path $beeRoot)) { throw 'Isolated Bee evidence traverses a reparse point.' }
        $knownByName = @{}
        foreach ($tool in @($SelectedCandidate.tools)) { $knownByName[[string]$tool.name] = Get-UpvNormalizedPath -Path ([string]$tool.path) }
        $observed = New-Object System.Collections.ArrayList
        $sources = New-Object System.Collections.ArrayList
        $dagFiles = @(Get-ChildItem -LiteralPath $beeRoot -Recurse -File -Force -ErrorAction Stop | Where-Object { $_.Name -match '(?i)dag.*\.json$|\.dag\.json$' } | Sort-Object -Property FullName)
        foreach ($dagFile in $dagFiles) {
            $text = [System.IO.File]::ReadAllText($dagFile.FullName, [System.Text.Encoding]::UTF8)
            $normalizedText = $text.Replace('\\', '\').Replace('\/', '/').Replace('/', '\')
            $matches = [regex]::Matches($normalizedText, '(?i)(?<path>[A-Z]:\\[^"\r\n]*?\\(?<name>cl|link|lib|cvtres|rc|mt)\.exe)')
            if ($matches.Count -eq 0) { continue }
            [void]$sources.Add([pscustomobject][ordered]@{ path=$dagFile.FullName; length=[long]$dagFile.Length; sha256=Get-UpvrFileSha256 -Path $dagFile.FullName })
            foreach ($match in $matches) {
                $path = [string]$match.Groups['path'].Value
                $name = ([string]$match.Groups['name'].Value + '.exe').ToLowerInvariant()
                try { $path = Get-UpvNormalizedPath -Path $path } catch { continue }
                [void]$observed.Add([pscustomobject][ordered]@{ name=$name; path=$path; sourcePath=$dagFile.FullName })
            }
        }
        $distinctObserved = @($observed | Sort-Object -Property name, path, sourcePath -Unique)
        $mismatches = New-Object System.Collections.ArrayList
        foreach ($tool in $distinctObserved) {
            if ($knownByName.ContainsKey([string]$tool.name) -and -not ([string]$tool.path).Equals([string]$knownByName[[string]$tool.name], $script:UpvPathComparison)) {
                [void]$mismatches.Add($tool)
            }
        }
        $missing = @($result.requiredToolNames | Where-Object {
            $requiredName = $_
            -not @($distinctObserved | Where-Object { [string]$_.name -ceq $requiredName -and ([string]$_.path).Equals([string]$knownByName[$requiredName], $script:UpvPathComparison) }).Count
        })
        $result.sourceFiles = @($sources | Sort-Object -Property path -Unique)
        $result.observedTools = $distinctObserved
        $result.missingToolNames = [string[]]$missing
        $result.mismatchedTools = @($mismatches)
        if ($result.sourceFiles.Count -eq 0) { [void]$errors.Add('No parseable isolated Bee DAG JSON contained native tool paths.') }
        if ($missing.Count -gt 0) { [void]$errors.Add("Bee evidence did not observe selected tools: $([string]::Join(', ', [string[]]$missing)).") }
        if ($mismatches.Count -gt 0) { [void]$errors.Add('Bee evidence contains native tool paths outside the selected toolchain candidate.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Retains a fail-closed compatibility wrapper for callers that have not adopted explicit profile selection.
function Get-UpvrIl2CppToolchainIdentity {
    $inventory = Get-UpvrIl2CppToolchainCandidates
    if (-not $inventory.accepted -or @($inventory.candidates).Count -ne 1) {
        return [pscustomobject][ordered]@{
            requested=$true; visualStudioVersion=$null; visualStudioPath=$null; msvcVersion=$null
            windowsSdkVersion=$null; tools=@(); identitySha256=$null; accepted=$false
            errors=@($inventory.errors) + @('Explicit profile selection is required unless exactly one complete toolchain candidate exists.')
        }
    }
    $candidate = $inventory.candidates[0]
    return [pscustomobject][ordered]@{
        requested=$true; visualStudioVersion=$candidate.visualStudioVersion; visualStudioPath=$candidate.visualStudioPath
        msvcVersion=$candidate.msvcVersion; windowsSdkVersion=$candidate.windowsSdkVersion; tools=@($candidate.tools)
        identitySha256=$candidate.buildToolchainIdentity.identitySha256; accepted=$true; errors=@()
    }
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
        [Parameter()][AllowNull()][string]$ExpectedToolchainProfileId,
        [Parameter()][AllowNull()][string]$ExpectedBuildToolchainIdentityAlgorithm,
        [Parameter()][AllowNull()][string]$ExpectedBuildToolchainIdentitySha256,
        [Parameter()][AllowNull()][string]$ExpectedHostEnvironmentIdentityAlgorithm,
        [Parameter()][AllowNull()][string]$ExpectedHostEnvironmentIdentitySha256,
        [Parameter()][ValidateSet('Project','Mono','IL2CPP')][string]$ExpectedBackend = 'Project',
        [Parameter(Mandatory = $true)][object]$CurrentTree,
        [Parameter()][switch]$FreshBuild
    )

    $result = [ordered]@{
        exists=$false; sha256=$null; schemaVersion=$null; sessionToken=$null; sessionTokenMatched=$null
        originalFingerprint=$null; overlayTreeSha256=$null; scenarioBundleTreeSha256=$null; unityVersion=$null
        windowsModuleTreeSha256=$null; toolchainIdentitySha256=$null; scriptingBackend=$null; backendMatched=$false
        toolchainProfileId=$null; buildToolchainIdentityAlgorithm=$null; buildToolchainIdentitySha256=$null
        hostEnvironmentIdentityAlgorithm=$null; hostEnvironmentIdentitySha256=$null; legacy=$false; warning=$null
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
        $schemaVersion = [string](Get-UpvJsonProperty -InputObject $document -Name 'schemaVersion')
        $commonNames = @(
            'schemaVersion','sessionToken','originalFingerprint','overlayTreeSha256','scenarioBundleTreeSha256',
            'unityVersion','windowsModuleTreeSha256','scriptingBackend','scenes','buildOptions','developmentBuild',
            'buildGuid','executablePath','executableSha256','buildRoot','treeCanonicalization','buildTreeSha256',
            'fileCount','directoryCount','totalBytes','scenario'
        )
        $identityNames = if ($schemaVersion -ceq '1.0.0') {
            @('toolchainIdentitySha256')
        } elseif ($schemaVersion -ceq '1.1.0') {
            @('toolchainProfileId','buildToolchainIdentityAlgorithm','buildToolchainIdentitySha256','hostEnvironmentIdentityAlgorithm','hostEnvironmentIdentitySha256')
        } else {
            throw 'Standalone build receipt schemaVersion must be 1.0.0 or 1.1.0.'
        }
        $contract = Test-UpvExactJsonProperties -InputObject $document -RequiredNames ($commonNames + $identityNames) -Context 'Standalone build receipt'
        foreach ($error in @($contract.errors)) { [void]$errors.Add($error) }
        foreach ($property in @(
            'schemaVersion','sessionToken','originalFingerprint','overlayTreeSha256','scenarioBundleTreeSha256','unityVersion',
            'windowsModuleTreeSha256','toolchainIdentitySha256','toolchainProfileId','buildToolchainIdentityAlgorithm',
            'buildToolchainIdentitySha256','hostEnvironmentIdentityAlgorithm','hostEnvironmentIdentitySha256',
            'scriptingBackend','buildOptions','developmentBuild',
            'buildGuid','executablePath','executableSha256','buildRoot','treeCanonicalization','buildTreeSha256',
            'fileCount','directoryCount','totalBytes'
        )) { if ($document.PSObject.Properties.Name -ccontains $property) { $result[$property] = $document.$property } }
        $result.scenes = [string[]]@($document.scenes)
        $result.scenario = $document.scenario
        $scenarioContract = Test-UpvExactJsonProperties -InputObject $document.scenario -RequiredNames @(
            'scenarioId','displayName','timeoutSeconds','buildScenes','expectedScenes','expectedAssertionIds','expectedCaptureIds','graphicsRequired'
        ) -Context 'Standalone build receipt scenario'
        foreach ($error in @($scenarioContract.errors)) { [void]$errors.Add($error) }
        $result.legacy = [string]$result.schemaVersion -ceq '1.0.0'
        if ($FreshBuild -and $result.legacy) { [void]$errors.Add('Fresh instrumented builds require Standalone build receipt schemaVersion 1.1.0.') }
        if ($result.legacy) { $result.warning = 'Legacy schema 1.0.0 receipt accepted only for exact prebuilt replay; it lacks split toolchain identity fields.' }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionToken)) {
            $result.sessionTokenMatched = [string]$result.sessionToken -ceq $ExpectedSessionToken
            if (-not $result.sessionTokenMatched) { [void]$errors.Add('Standalone build receipt session token does not match.') }
        }
        foreach ($identity in @(
            [pscustomobject]@{ name='originalFingerprint'; expected=$ExpectedOriginalFingerprint; actual=$result.originalFingerprint },
            [pscustomobject]@{ name='overlayTreeSha256'; expected=$ExpectedOverlayTreeSha256; actual=$result.overlayTreeSha256 },
            [pscustomobject]@{ name='scenarioBundleTreeSha256'; expected=$ExpectedScenarioBundleTreeSha256; actual=$result.scenarioBundleTreeSha256 },
            [pscustomobject]@{ name='windowsModuleTreeSha256'; expected=$ExpectedWindowsModuleTreeSha256; actual=$result.windowsModuleTreeSha256 }
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$identity.expected) -and [string]$identity.actual -cne [string]$identity.expected) { [void]$errors.Add("Standalone build receipt $($identity.name) does not match.") }
        }
        if ($result.legacy) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedToolchainIdentitySha256) -and [string]$result.toolchainIdentitySha256 -cne $ExpectedToolchainIdentitySha256) { [void]$errors.Add('Standalone build receipt legacy toolchainIdentitySha256 does not match.') }
        } else {
            foreach ($identity in @(
                [pscustomobject]@{ name='toolchainProfileId'; expected=$ExpectedToolchainProfileId; actual=$result.toolchainProfileId },
                [pscustomobject]@{ name='buildToolchainIdentityAlgorithm'; expected=$ExpectedBuildToolchainIdentityAlgorithm; actual=$result.buildToolchainIdentityAlgorithm },
                [pscustomobject]@{ name='buildToolchainIdentitySha256'; expected=$ExpectedBuildToolchainIdentitySha256; actual=$result.buildToolchainIdentitySha256 },
                [pscustomobject]@{ name='hostEnvironmentIdentityAlgorithm'; expected=$ExpectedHostEnvironmentIdentityAlgorithm; actual=$result.hostEnvironmentIdentityAlgorithm },
                [pscustomobject]@{ name='hostEnvironmentIdentitySha256'; expected=$ExpectedHostEnvironmentIdentitySha256; actual=$result.hostEnvironmentIdentitySha256 }
            )) {
                if (-not [string]::IsNullOrWhiteSpace([string]$identity.expected) -and [string]$identity.actual -cne [string]$identity.expected) { [void]$errors.Add("Standalone build receipt $($identity.name) does not match.") }
            }
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
        if ([string]$result.scriptingBackend -ceq 'IL2CPP') {
            if ($result.legacy -and [string]$result.toolchainIdentitySha256 -notmatch '^[0-9a-f]{64}$') { [void]$errors.Add('Legacy IL2CPP build receipt lacks a valid aggregate toolchain identity.') }
            if (-not $result.legacy -and (
                [string]::IsNullOrWhiteSpace([string]$result.toolchainProfileId) -or
                [string]$result.buildToolchainIdentityAlgorithm -cne $script:UpvrBuildToolchainIdentityAlgorithm -or
                [string]$result.buildToolchainIdentitySha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$result.hostEnvironmentIdentityAlgorithm -cne $script:UpvrHostEnvironmentIdentityAlgorithm -or
                [string]$result.hostEnvironmentIdentitySha256 -notmatch '^[0-9a-f]{64}$'
            )) { [void]$errors.Add('IL2CPP build receipt lacks valid split toolchain identities.') }
        } elseif (-not $result.legacy -and (
            -not [string]::IsNullOrWhiteSpace([string]$result.toolchainProfileId) -or
            -not [string]::IsNullOrWhiteSpace([string]$result.buildToolchainIdentityAlgorithm) -or
            -not [string]::IsNullOrWhiteSpace([string]$result.buildToolchainIdentitySha256) -or
            -not [string]::IsNullOrWhiteSpace([string]$result.hostEnvironmentIdentityAlgorithm) -or
            -not [string]::IsNullOrWhiteSpace([string]$result.hostEnvironmentIdentitySha256)
        )) { [void]$errors.Add('Mono build receipt must keep split toolchain identity fields null.') }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}
