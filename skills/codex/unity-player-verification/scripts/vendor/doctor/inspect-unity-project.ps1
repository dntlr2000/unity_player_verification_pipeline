[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$script:SchemaVersion = "1.1.0"
$script:ScannerVersion = "0.2.1"
$script:FingerprintHelperPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\unity-project-fingerprint.ps1"
$script:IsWindowsPlatform = $env:OS -eq "Windows_NT"
$script:PathComparison = if ($script:IsWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$script:PathComparer = if ($script:IsWindowsPlatform) {
    [System.StringComparer]::OrdinalIgnoreCase
} else {
    [System.StringComparer]::Ordinal
}
$script:CandidateRoot = $null
$script:Warnings = New-Object System.Collections.ArrayList
$script:BlockedChecks = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
$script:WarningKeys = @{}
$script:BlockedKeys = @{}
$script:EvidenceSequence = 0
$script:TrackedGitPaths = @()

# Normalizes a path to a stable absolute form without resolving a link target.
function ConvertTo-NormalizedAbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $pathRoot)) {
        return $fullPath
    }

    $trimCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return $fullPath.TrimEnd($trimCharacters)
}

# Tests whether a normalized path is the candidate root or one of its descendants.
function Test-PathInsideProjectRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = ConvertTo-NormalizedAbsolutePath -Path $Path
    if ($normalizedPath.Equals($script:CandidateRoot, $script:PathComparison)) {
        return $true
    }

    $rootPrefix = $script:CandidateRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootPrefix, $script:PathComparison)
}

# Converts an in-root absolute path to a forward-slash project-relative path.
function ConvertTo-ProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = ConvertTo-NormalizedAbsolutePath -Path $Path
    if (-not (Test-PathInsideProjectRoot -Path $normalizedPath)) {
        throw "Path is outside the candidate project root: $normalizedPath"
    }

    if ($normalizedPath.Equals($script:CandidateRoot, $script:PathComparison)) {
        return "."
    }

    return $normalizedPath.Substring($script:CandidateRoot.Length + 1).Replace("\", "/")
}

# Sorts strings with an ordinal comparer for deterministic output.
function Sort-StringsOrdinal {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Values = @()
    )

    $copy = [string[]]@($Values)
    [System.Array]::Sort($copy, $script:PathComparer)
    return $copy
}

# Adds one evidence record in deterministic discovery order.
function Add-Evidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet("OBSERVED", "WARNING", "NOT_AVAILABLE", "NOT_VERIFIED", "BLOCKED")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Detail
    )

    $script:EvidenceSequence++
    [void]$script:Evidence.Add([ordered]@{
        id = "E{0:D3}" -f $script:EvidenceSequence
        check = $Check
        status = $Status
        source = $Source
        detail = $Detail
    })
}

# Records a deduplicated static warning and matching evidence.
function Add-AuditWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $key = "$Code|$Path|$Message"
    if ($script:WarningKeys.ContainsKey($key)) {
        return
    }

    $script:WarningKeys[$key] = $true
    [void]$script:Warnings.Add([ordered]@{
        code = $Code
        check = $Check
        path = $Path
        message = $Message
    })
    $source = if ([string]::IsNullOrWhiteSpace($Path)) { $Check } else { $Path }
    Add-Evidence -Check $Check -Status "WARNING" -Source $source -Detail $Message
}

# Records a deduplicated blocked check and matching evidence.
function Add-BlockedCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $key = "$Code|$Path|$Message"
    if ($script:BlockedKeys.ContainsKey($key)) {
        return
    }

    $script:BlockedKeys[$key] = $true
    [void]$script:BlockedChecks.Add([ordered]@{
        code = $Code
        check = $Check
        path = $Path
        message = $Message
    })
    $source = if ([string]::IsNullOrWhiteSpace($Path)) { $Check } else { $Path }
    Add-Evidence -Check $Check -Status "BLOCKED" -Source $source -Detail $Message
}

# Finds the first reparse point on the absolute path from the candidate root to the volume root.
function Get-ReparsePointOnRootPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $currentPath = $RootPath
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        try {
            $entry = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $entry.FullName
            }
        } catch {
            if ($_.Exception -isnot [System.Management.Automation.ItemNotFoundException]) {
                throw
            }
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            break
        }

        $parentPath = $parent.FullName
        if ($parentPath.Equals($currentPath, $script:PathComparison)) {
            break
        }
        $currentPath = $parentPath
    }

    return $null
}

# Inspects an in-root path component by component and refuses all reparse points.
function Get-SafeEntryState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [ValidateSet("Any", "File", "Directory")]
        [string]$ExpectedType = "Any"
    )

    try {
        $normalizedPath = ConvertTo-NormalizedAbsolutePath -Path $Path
    } catch {
        return [pscustomobject][ordered]@{
            state = "BLOCKED"
            path = $Path
            entry = $null
            error = $_.Exception.Message
        }
    }

    if (-not (Test-PathInsideProjectRoot -Path $normalizedPath)) {
        return [pscustomobject][ordered]@{
            state = "OUTSIDE_ROOT"
            path = $normalizedPath
            entry = $null
            error = "The path resolves outside the candidate project root."
        }
    }

    $relativePath = if ($normalizedPath.Equals($script:CandidateRoot, $script:PathComparison)) {
        ""
    } else {
        $normalizedPath.Substring($script:CandidateRoot.Length + 1)
    }
    $components = if ([string]::IsNullOrWhiteSpace($relativePath)) {
        @()
    } else {
        @($relativePath -split "[\\/]" | Where-Object { $_.Length -gt 0 })
    }

    $currentPath = $script:CandidateRoot
    $pathsToInspect = New-Object System.Collections.ArrayList
    [void]$pathsToInspect.Add($currentPath)
    foreach ($component in $components) {
        $currentPath = Join-Path -Path $currentPath -ChildPath $component
        [void]$pathsToInspect.Add($currentPath)
    }

    $entry = $null
    foreach ($pathToInspect in $pathsToInspect) {
        if (-not (Test-Path -LiteralPath $pathToInspect)) {
            return [pscustomobject][ordered]@{
                state = "MISSING"
                path = $normalizedPath
                entry = $null
                error = $null
            }
        }

        try {
            $entry = Get-Item -LiteralPath $pathToInspect -Force -ErrorAction Stop
        } catch {
            return [pscustomobject][ordered]@{
                state = "BLOCKED"
                path = $normalizedPath
                entry = $null
                error = $_.Exception.Message
            }
        }

        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject][ordered]@{
                state = "REPARSE_POINT"
                path = $normalizedPath
                entry = $entry
                error = "A reparse point was encountered at $($entry.FullName)."
            }
        }
    }

    if ($ExpectedType -eq "File" -and $entry.PSIsContainer) {
        return [pscustomobject][ordered]@{
            state = "WRONG_TYPE"
            path = $normalizedPath
            entry = $entry
            error = "Expected a file but found a directory."
        }
    }
    if ($ExpectedType -eq "Directory" -and -not $entry.PSIsContainer) {
        return [pscustomobject][ordered]@{
            state = "WRONG_TYPE"
            path = $normalizedPath
            entry = $entry
            error = "Expected a directory but found a file."
        }
    }

    return [pscustomobject][ordered]@{
        state = "PRESENT"
        path = $normalizedPath
        entry = $entry
        error = $null
    }
}

# Reads a text file only after validating its root boundary and path components.
function Read-SafeTextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $state = Get-SafeEntryState -Path $Path -ExpectedType "File"
    if ($state.state -ne "PRESENT") {
        return [pscustomobject][ordered]@{
            state = $state.state
            path = $state.path
            content = $null
            error = $state.error
        }
    }

    try {
        $content = Get-Content -LiteralPath $state.path -Raw -ErrorAction Stop
        return [pscustomobject][ordered]@{
            state = "READ"
            path = $state.path
            content = $content
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            state = "BLOCKED"
            path = $state.path
            content = $null
            error = $_.Exception.Message
        }
    }
}

# Enumerates files without following reparse points or entering excluded directories.
function Get-SafeTreeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath,

        [Parameter()]
        [AllowNull()]
        [string]$FileName,

        [Parameter()]
        [AllowNull()]
        [string]$Extension,

        [Parameter()]
        [string[]]$ExcludedDirectoryNames = @(),

        [Parameter(Mandatory = $true)]
        [string]$Check
    )

    $startState = Get-SafeEntryState -Path $StartPath -ExpectedType "Directory"
    if ($startState.state -eq "MISSING" -or $startState.state -eq "WRONG_TYPE") {
        return
    }
    if ($startState.state -ne "PRESENT") {
        Add-BlockedCheck -Code "TREE_ENUMERATION_BLOCKED" -Check $Check -Path $StartPath -Message "The scan root could not be enumerated safely: $($startState.error)"
        return
    }

    $results = New-Object System.Collections.ArrayList
    $queue = New-Object "System.Collections.Generic.Queue[string]"
    $queue.Enqueue($startState.path)

    while ($queue.Count -gt 0) {
        $directoryPath = $queue.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)
        } catch {
            $relativeDirectory = ConvertTo-ProjectRelativePath -Path $directoryPath
            Add-BlockedCheck -Code "DIRECTORY_READ_BLOCKED" -Check $Check -Path $relativeDirectory -Message "Directory enumeration failed: $($_.Exception.Message)"
            continue
        }

        $childPaths = Sort-StringsOrdinal -Values @($children | ForEach-Object { $_.FullName })
        foreach ($childPath in $childPaths) {
            try {
                $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
            } catch {
                $relativeChild = ConvertTo-ProjectRelativePath -Path $childPath
                Add-BlockedCheck -Code "ENTRY_READ_BLOCKED" -Check $Check -Path $relativeChild -Message "Filesystem entry inspection failed: $($_.Exception.Message)"
                continue
            }

            $relativeChildPath = ConvertTo-ProjectRelativePath -Path $child.FullName
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-AuditWarning -Code "REPARSE_POINT_SKIPPED" -Check $Check -Path $relativeChildPath -Message "A reparse point was not followed."
                continue
            }

            if ($child.PSIsContainer) {
                if ($ExcludedDirectoryNames -icontains $child.Name) {
                    continue
                }
                $queue.Enqueue($child.FullName)
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($FileName) -and $child.Name -ine $FileName) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($Extension) -and $child.Extension -ine $Extension) {
                continue
            }
            [void]$results.Add($child.FullName)
        }
    }

    return Sort-StringsOrdinal -Values @($results)
}

# Returns a property value from a parsed JSON object without StrictMode failures.
function Get-JsonPropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

# Tests whether a parsed JSON object declares a named property.
function Test-JsonProperty {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]
}

# Runs one fixed read-only Git operation with optional locks and executable integrations disabled.
function Invoke-SafeGitOperation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("IsWorktree", "TopLevel", "Branch", "Head", "Status", "TrackedFiles")]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string]$GitExecutable
    )

    $operationArguments = switch ($Operation) {
        "IsWorktree" { @("rev-parse", "--is-inside-work-tree") }
        "TopLevel" { @("rev-parse", "--show-toplevel") }
        "Branch" { @("symbolic-ref", "--quiet", "--short", "HEAD") }
        "Head" { @("rev-parse", "--verify", "HEAD") }
        "Status" { @("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all") }
        "TrackedFiles" { @("ls-files", "-z") }
    }

    $nullDevice = if ($script:IsWindowsPlatform) { "NUL" } else { "/dev/null" }
    $arguments = @(
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.preloadindex=false",
        "-c", "core.hooksPath=$nullDevice",
        "-c", "core.excludesFile=$nullDevice",
        "-c", "core.attributesFile=$nullDevice",
        "-c", "maintenance.auto=false",
        "-c", "submodule.recurse=false",
        "-c", "status.submoduleSummary=false",
        "-c", "core.quotepath=false"
    ) + $operationArguments

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GitExecutable
    $startInfo.WorkingDirectory = $script:CandidateRoot
    $startInfo.Arguments = $arguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:Utf8NoBom
    $startInfo.StandardErrorEncoding = $script:Utf8NoBom
    $inheritedGitEnvironmentKeys = @(
        $startInfo.EnvironmentVariables.Keys |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -like "GIT_*" }
    )
    foreach ($environmentKey in $inheritedGitEnvironmentKeys) {
        $startInfo.EnvironmentVariables.Remove($environmentKey)
    }
    $startInfo.EnvironmentVariables["GIT_OPTIONAL_LOCKS"] = "0"
    $startInfo.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"
    $startInfo.EnvironmentVariables["GIT_CONFIG_NOSYSTEM"] = "1"
    $startInfo.EnvironmentVariables["GIT_ATTR_NOSYSTEM"] = "1"
    $startInfo.EnvironmentVariables["GIT_CONFIG_GLOBAL"] = if ($script:IsWindowsPlatform) { "NUL" } else { "/dev/null" }
    $startInfo.EnvironmentVariables["GIT_CONFIG_SYSTEM"] = if ($script:IsWindowsPlatform) { "NUL" } else { "/dev/null" }
    $startInfo.EnvironmentVariables["GIT_CEILING_DIRECTORIES"] = $script:CandidateRoot
    $startInfo.EnvironmentVariables["GIT_DISCOVERY_ACROSS_FILESYSTEM"] = "0"
    $startInfo.EnvironmentVariables["GIT_LFS_SKIP_SMUDGE"] = "1"
    $startInfo.EnvironmentVariables["GIT_PAGER"] = ""

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.Result
        $standardError = $standardErrorTask.Result

        return [pscustomobject][ordered]@{
            operation = $Operation
            exitCode = $process.ExitCode
            stdout = $standardOutput
            stderr = $standardError.Trim()
        }
    } catch {
        return [pscustomobject][ordered]@{
            operation = $Operation
            exitCode = -1
            stdout = ""
            stderr = $_.Exception.Message
        }
    } finally {
        $process.Dispose()
    }
}

# Rejects Git metadata layouts that could make a read-only Git query follow data outside the project.
function Test-GitMetadataSafety {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitDirectoryPath
    )

    $blockedChecksBefore = $script:BlockedChecks.Count
    $reparseWarningsBefore = @($script:Warnings | Where-Object { $_.code -eq "REPARSE_POINT_SKIPPED" -and $_.check -eq "git" }).Count
    Get-SafeTreeFiles -StartPath $GitDirectoryPath -ExcludedDirectoryNames @() -Check "git" | Out-Null
    if ($script:BlockedChecks.Count -gt $blockedChecksBefore) {
        return $false
    }
    $reparseWarningsAfter = @($script:Warnings | Where-Object { $_.code -eq "REPARSE_POINT_SKIPPED" -and $_.check -eq "git" }).Count
    if ($reparseWarningsAfter -gt $reparseWarningsBefore) {
        return $false
    }

    $alternatesPath = Join-Path $GitDirectoryPath "objects\info\alternates"
    $alternatesState = Get-SafeEntryState -Path $alternatesPath -ExpectedType "File"
    if ($alternatesState.state -eq "PRESENT") {
        Add-AuditWarning -Code "GIT_ALTERNATES_UNSUPPORTED" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $alternatesPath) -Message "Git object alternates are not followed because they may reference data outside the candidate root."
        return $false
    }
    if ($alternatesState.state -notin @("MISSING", "WRONG_TYPE")) {
        Add-AuditWarning -Code "GIT_ALTERNATES_UNSAFE" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $alternatesPath) -Message "Git object alternates could not be ruled out safely."
        return $false
    }

    $commonDirectoryPath = Join-Path $GitDirectoryPath "commondir"
    $commonDirectoryState = Get-SafeEntryState -Path $commonDirectoryPath -ExpectedType "File"
    if ($commonDirectoryState.state -eq "PRESENT") {
        Add-AuditWarning -Code "GIT_COMMONDIR_UNSUPPORTED" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $commonDirectoryPath) -Message "Git common-directory indirection is not followed by this scanner."
        return $false
    }
    if ($commonDirectoryState.state -notin @("MISSING", "WRONG_TYPE")) {
        Add-AuditWarning -Code "GIT_COMMONDIR_UNSAFE" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $commonDirectoryPath) -Message "Git common-directory indirection could not be ruled out safely."
        return $false
    }

    foreach ($configurationName in @("config", "config.worktree")) {
        $configurationPath = Join-Path $GitDirectoryPath $configurationName
        $configurationState = Get-SafeEntryState -Path $configurationPath -ExpectedType "File"
        if ($configurationState.state -eq "MISSING" -or $configurationState.state -eq "WRONG_TYPE") {
            continue
        }
        if ($configurationState.state -ne "PRESENT") {
            Add-AuditWarning -Code "GIT_CONFIG_UNSAFE" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $configurationPath) -Message "Git configuration could not be inspected safely."
            return $false
        }

        $configurationRead = Read-SafeTextFile -Path $configurationPath
        if ($configurationRead.state -ne "READ") {
            Add-AuditWarning -Code "GIT_CONFIG_UNREADABLE" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $configurationPath) -Message "Git configuration could not be read before safe Git invocation."
            return $false
        }
        if ($configurationRead.content -match "(?im)^\s*\[\s*include(?:If)?\b") {
            Add-AuditWarning -Code "GIT_CONFIG_INCLUDE_UNSUPPORTED" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $configurationPath) -Message "Git configuration includes are not followed because they may reference files outside the candidate root."
            return $false
        }
        if ($configurationRead.content -match "(?im)^\s*worktree\s*=") {
            Add-AuditWarning -Code "GIT_CONFIG_WORKTREE_UNSUPPORTED" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $configurationPath) -Message "A configured Git worktree path is not followed because it may reference files outside the candidate root."
            return $false
        }
        if ($configurationRead.content -match "(?im)^\s*\[\s*filter\b") {
            Add-AuditWarning -Code "GIT_CONFIG_FILTER_UNSUPPORTED" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $configurationPath) -Message "Git commands were not run because a repository filter could execute a project-configured process."
            return $false
        }
    }

    return $true
}

# Scans worktree entry attributes without following links before Git can enumerate untracked paths.
function Test-GitWorktreeSafety {
    $gitMetadataPath = ConvertTo-NormalizedAbsolutePath -Path (Join-Path $script:CandidateRoot ".git")
    $queue = New-Object "System.Collections.Generic.Queue[string]"
    $queue.Enqueue($script:CandidateRoot)

    while ($queue.Count -gt 0) {
        $directoryPath = $queue.Dequeue()
        try {
            $entryPaths = @([System.IO.Directory]::EnumerateFileSystemEntries($directoryPath))
        } catch {
            $relativeDirectory = ConvertTo-ProjectRelativePath -Path $directoryPath
            Add-AuditWarning -Code "GIT_WORKTREE_SAFETY_SCAN_BLOCKED" -Check "git" -Path $relativeDirectory -Message "Git commands were not run because a worktree directory could not be inspected for reparse points."
            return $false
        }

        $sortedEntryPaths = Sort-StringsOrdinal -Values $entryPaths
        foreach ($entryPath in $sortedEntryPaths) {
            $normalizedEntryPath = ConvertTo-NormalizedAbsolutePath -Path $entryPath
            if ($normalizedEntryPath.Equals($gitMetadataPath, $script:PathComparison)) {
                continue
            }

            try {
                $attributes = [System.IO.File]::GetAttributes($normalizedEntryPath)
            } catch {
                $relativeEntry = ConvertTo-ProjectRelativePath -Path $normalizedEntryPath
                Add-AuditWarning -Code "GIT_WORKTREE_ENTRY_BLOCKED" -Check "git" -Path $relativeEntry -Message "Git commands were not run because a worktree entry could not be inspected safely."
                return $false
            }

            $relativePath = ConvertTo-ProjectRelativePath -Path $normalizedEntryPath
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-AuditWarning -Code "GIT_WORKTREE_REPARSE_POINT" -Check "git" -Path $relativePath -Message "Git commands were not run because Git may follow this worktree reparse point outside the candidate root."
                return $false
            }

            if ([System.IO.Path]::GetFileName($normalizedEntryPath) -ieq ".git") {
                Add-AuditWarning -Code "NESTED_GIT_METADATA" -Check "git" -Path $relativePath -Message "Git commands were not run because nested Git metadata may cause additional repository traversal."
                return $false
            }

            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $queue.Enqueue($normalizedEntryPath)
            }
        }
    }

    return $true
}

# Creates the complete, stable JSON shape before any project data is inspected.
function New-AuditResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedProjectRoot
    )

    return [ordered]@{
        schemaVersion = $script:SchemaVersion
        scannerVersion = $script:ScannerVersion
        projectRoot = $NormalizedProjectRoot
        projectDetection = [ordered]@{
            isUnityProject = $false
            rootStatus = "UNKNOWN"
            markers = @()
        }
        unityEditorVersion = [ordered]@{
            source = "ProjectSettings/ProjectVersion.txt"
            parseStatus = "NOT_INSPECTED"
            editorVersion = $null
            editorVersionWithRevision = $null
        }
        git = [ordered]@{
            gitAvailable = $false
            metadataStatus = "NOT_INSPECTED"
            worktree = $false
            topLevel = $null
            branch = $null
            detachedHead = $null
            headCommit = $null
            dirtyState = "NOT_AVAILABLE"
            dirty = $null
            changedPaths = @()
        }
        packages = [ordered]@{
            manifest = [ordered]@{
                path = "Packages/manifest.json"
                exists = $false
                parseStatus = "NOT_INSPECTED"
                error = $null
            }
            packagesLock = [ordered]@{
                path = "Packages/packages-lock.json"
                exists = $false
                parseStatus = "NOT_INSPECTED"
                error = $null
            }
            directDependencies = @()
            resolvedDependencies = @()
            directDependenciesMissingFromLock = @()
        }
        assemblies = [ordered]@{
            asmdefs = @()
            confirmedTestAssemblies = @()
            candidateOnlyTestAssemblies = @()
        }
        buildSettings = [ordered]@{
            path = "ProjectSettings/EditorBuildSettings.asset"
            exists = $false
            parseStatus = "NOT_INSPECTED"
            enabledScenes = @()
            disabledScenes = @()
            missingScenes = @()
        }
        agentsFiles = @()
        projectSkills = @()
        trackedGeneratedFolderPaths = @()
        projectFingerprint = [ordered]@{
            contractVersion = "1.0.0"
            status = "NOT_APPLICABLE"
            algorithm = "SHA-256"
            canonicalization = "unity-copy-set-relative-path-length-sha256-lf-v1"
            excludedTopLevelPaths = @(
                ".agents", ".codex", ".git", ".hg", ".idea", ".svn", ".vs",
                "Build", "Builds", "Library", "Logs", "Obj", "Temp", "UserSettings"
            )
            directoryCount = $null
            fileCount = $null
            treeSha256 = $null
            stabilityPasses = 0
            error = $null
        }
        warnings = @()
        blockedChecks = @()
        dynamicVerification = [ordered]@{
            compilation = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "Unity Editor and a compiler were not run."
            }
            tests = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No test runner was run. Test assembly presence is not test execution."
            }
            build = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No player or content build was run. Existing build output is historical evidence only."
            }
            runtime = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No scene, player, or runtime process was launched."
            }
        }
        finalStatus = "AUDIT_BLOCKED"
        evidence = @()
    }
}

# Computes a stable SHA-256 fingerprint for exactly the file set copied by Baseline.
function Invoke-ProjectFingerprintInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    try {
        if (-not (Test-Path -LiteralPath $script:FingerprintHelperPath -PathType Leaf)) {
            throw "Fingerprint helper was not found: $($script:FingerprintHelperPath)"
        }
        . $script:FingerprintHelperPath
        $fingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $script:CandidateRoot
        $Result.projectFingerprint.contractVersion = $fingerprint.contractVersion
        $Result.projectFingerprint.status = $fingerprint.status
        $Result.projectFingerprint.algorithm = $fingerprint.algorithm
        $Result.projectFingerprint.canonicalization = $fingerprint.canonicalization
        $Result.projectFingerprint.excludedTopLevelPaths = @($fingerprint.excludedTopLevelPaths)
        $Result.projectFingerprint.directoryCount = $fingerprint.directoryCount
        $Result.projectFingerprint.fileCount = $fingerprint.fileCount
        $Result.projectFingerprint.treeSha256 = $fingerprint.treeSha256
        $Result.projectFingerprint.stabilityPasses = $fingerprint.stabilityPasses
        $Result.projectFingerprint.error = $null
        Add-Evidence -Check "projectFingerprint" -Status "OBSERVED" -Source $script:CandidateRoot -Detail "Computed two identical SHA-256 snapshots over the exact Baseline copy-included file set."
    } catch {
        $Result.projectFingerprint.status = "BLOCKED"
        $Result.projectFingerprint.directoryCount = $null
        $Result.projectFingerprint.fileCount = $null
        $Result.projectFingerprint.treeSha256 = $null
        $Result.projectFingerprint.stabilityPasses = 0
        $Result.projectFingerprint.error = $_.Exception.Message
        Add-BlockedCheck -Code "PROJECT_FINGERPRINT_BLOCKED" -Check "projectFingerprint" -Path $null -Message "The Baseline copy-set fingerprint could not be computed safely: $($_.Exception.Message)"
    }
}

# Adds the four intentionally unperformed dynamic checks to the evidence ledger.
function Add-DynamicVerificationEvidence {
    Add-Evidence -Check "compilation" -Status "NOT_VERIFIED" -Source "scanner safety policy" -Detail "Unity Editor and a compiler were not run."
    Add-Evidence -Check "tests" -Status "NOT_VERIFIED" -Source "scanner safety policy" -Detail "No test runner was run."
    Add-Evidence -Check "build" -Status "NOT_VERIFIED" -Source "scanner safety policy" -Detail "No player or content build was run."
    Add-Evidence -Check "runtime" -Status "NOT_VERIFIED" -Source "scanner safety policy" -Detail "No scene, player, or runtime process was launched."
}

# Finalizes arrays and derives one of the four v0.1-compatible termination states.
function Complete-AuditResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $Result.warnings = @($script:Warnings.ToArray())
    $Result.blockedChecks = @($script:BlockedChecks.ToArray())
    $Result.evidence = @($script:Evidence.ToArray())

    if ($Result.projectDetection.rootStatus -eq "NOT_A_UNITY_PROJECT") {
        $Result.finalStatus = "NOT_A_UNITY_PROJECT"
    } elseif ($Result.projectDetection.rootStatus -eq "BLOCKED" -or $script:BlockedChecks.Count -gt 0) {
        $Result.finalStatus = "AUDIT_BLOCKED"
    } elseif ($script:Warnings.Count -gt 0) {
        $Result.finalStatus = "STATIC_AUDIT_COMPLETE_WITH_WARNINGS"
    } else {
        $Result.finalStatus = "STATIC_AUDIT_COMPLETE"
    }
}

# Classifies the exact candidate directory from the four required Unity root markers.
function Invoke-ProjectDetection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    try {
        $reparsePoint = Get-ReparsePointOnRootPath -RootPath $script:CandidateRoot
    } catch {
        Add-BlockedCheck -Code "PROJECT_ROOT_INSPECTION_BLOCKED" -Check "projectDetection" -Path $script:CandidateRoot -Message "The project root path could not be inspected safely: $($_.Exception.Message)"
        $Result.projectDetection.rootStatus = "BLOCKED"
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($reparsePoint)) {
        Add-BlockedCheck -Code "PROJECT_ROOT_REPARSE_POINT" -Check "projectDetection" -Path $script:CandidateRoot -Message "The project root path traverses a reparse point at $reparsePoint."
        $Result.projectDetection.rootStatus = "BLOCKED"
        return $false
    }

    try {
        $rootIsContainer = Test-Path -LiteralPath $script:CandidateRoot -PathType Container -ErrorAction Stop
    } catch {
        $Result.projectDetection.rootStatus = "BLOCKED"
        Add-BlockedCheck -Code "PROJECT_ROOT_READ_BLOCKED" -Check "projectDetection" -Path $script:CandidateRoot -Message "The candidate root could not be inspected: $($_.Exception.Message)"
        return $false
    }

    if (-not $rootIsContainer) {
        $Result.projectDetection.rootStatus = "NOT_A_UNITY_PROJECT"
        $markerResults = New-Object System.Collections.ArrayList
        foreach ($marker in @(
            [ordered]@{ path = "Assets"; type = "Directory" },
            [ordered]@{ path = "Packages"; type = "Directory" },
            [ordered]@{ path = "ProjectSettings"; type = "Directory" },
            [ordered]@{ path = "ProjectSettings/ProjectVersion.txt"; type = "File" }
        )) {
            [void]$markerResults.Add([ordered]@{
                path = $marker.path
                expectedType = $marker.type
                status = "MISSING"
            })
            Add-Evidence -Check "projectDetection" -Status "OBSERVED" -Source $marker.path -Detail "Required Unity root marker is missing."
        }
        $Result.projectDetection.markers = @($markerResults.ToArray())
        return $false
    }

    $definitions = @(
        [ordered]@{ path = "Assets"; nativePath = "Assets"; type = "Directory" },
        [ordered]@{ path = "Packages"; nativePath = "Packages"; type = "Directory" },
        [ordered]@{ path = "ProjectSettings"; nativePath = "ProjectSettings"; type = "Directory" },
        [ordered]@{ path = "ProjectSettings/ProjectVersion.txt"; nativePath = "ProjectSettings\ProjectVersion.txt"; type = "File" }
    )
    $markerResults = New-Object System.Collections.ArrayList
    $allPresent = $true
    $hasBlockedMarker = $false

    foreach ($definition in $definitions) {
        $fullPath = Join-Path -Path $script:CandidateRoot -ChildPath $definition.nativePath
        $state = Get-SafeEntryState -Path $fullPath -ExpectedType $definition.type
        $markerStatus = switch ($state.state) {
            "PRESENT" { "PRESENT" }
            "MISSING" { "MISSING" }
            "WRONG_TYPE" { "WRONG_TYPE" }
            "REPARSE_POINT" { "BLOCKED_REPARSE_POINT" }
            default { "BLOCKED" }
        }
        [void]$markerResults.Add([ordered]@{
            path = $definition.path
            expectedType = $definition.type
            status = $markerStatus
        })

        if ($state.state -eq "PRESENT") {
            Add-Evidence -Check "projectDetection" -Status "OBSERVED" -Source $definition.path -Detail "Required Unity root marker is present."
            continue
        }

        $allPresent = $false
        if ($state.state -eq "REPARSE_POINT" -or $state.state -eq "BLOCKED" -or $state.state -eq "OUTSIDE_ROOT") {
            $hasBlockedMarker = $true
            Add-BlockedCheck -Code "UNITY_MARKER_BLOCKED" -Check "projectDetection" -Path $definition.path -Message "Required Unity root marker could not be inspected safely: $($state.error)"
        } else {
            Add-Evidence -Check "projectDetection" -Status "OBSERVED" -Source $definition.path -Detail "Required Unity root marker is absent or has the wrong type."
        }
    }

    $Result.projectDetection.markers = @($markerResults.ToArray())
    $Result.projectDetection.isUnityProject = $allPresent
    if ($allPresent) {
        $Result.projectDetection.rootStatus = "UNITY_PROJECT"
        return $true
    }

    $Result.projectDetection.rootStatus = if ($hasBlockedMarker) { "BLOCKED" } else { "NOT_A_UNITY_PROJECT" }
    return $false
}

# Reads the exact Unity editor version fields from ProjectVersion.txt.
function Invoke-UnityVersionInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $relativePath = "ProjectSettings/ProjectVersion.txt"
    $readResult = Read-SafeTextFile -Path (Join-Path $script:CandidateRoot "ProjectSettings\ProjectVersion.txt")
    if ($readResult.state -ne "READ") {
        $Result.unityEditorVersion.parseStatus = "BLOCKED"
        Add-BlockedCheck -Code "UNITY_VERSION_READ_BLOCKED" -Check "unityEditorVersion" -Path $relativePath -Message "ProjectVersion.txt could not be read: $($readResult.error)"
        return
    }

    $editorVersionMatch = [regex]::Match($readResult.content, "(?m)^\s*m_EditorVersion:\s*(?<value>.+?)\s*$")
    $revisionMatch = [regex]::Match($readResult.content, "(?m)^\s*m_EditorVersionWithRevision:\s*(?<value>.+?)\s*$")
    if ($editorVersionMatch.Success) {
        $Result.unityEditorVersion.editorVersion = $editorVersionMatch.Groups["value"].Value
    } else {
        Add-AuditWarning -Code "UNITY_EDITOR_VERSION_MISSING" -Check "unityEditorVersion" -Path $relativePath -Message "m_EditorVersion was not found."
    }
    if ($revisionMatch.Success) {
        $Result.unityEditorVersion.editorVersionWithRevision = $revisionMatch.Groups["value"].Value
    } else {
        Add-AuditWarning -Code "UNITY_EDITOR_REVISION_MISSING" -Check "unityEditorVersion" -Path $relativePath -Message "m_EditorVersionWithRevision was not found."
    }

    $Result.unityEditorVersion.parseStatus = if ($editorVersionMatch.Success) { "PARSED" } else { "MALFORMED" }
    Add-Evidence -Check "unityEditorVersion" -Status "OBSERVED" -Source $relativePath -Detail "Unity editor version fields were read without launching Unity."
}

# Parses NUL-delimited porcelain status records into deterministic changed-path objects.
function ConvertFrom-GitStatusOutput {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Output
    )

    $records = New-Object System.Collections.ArrayList
    $tokens = @($Output.Split([char]0))
    $index = 0
    while ($index -lt $tokens.Count) {
        $token = $tokens[$index]
        $index++
        if ([string]::IsNullOrEmpty($token) -or $token.Length -lt 3) {
            continue
        }

        $status = $token.Substring(0, 2)
        $path = if ($token.Length -gt 3) { $token.Substring(3).Replace("\", "/") } else { "" }
        $originalPath = $null
        if ($status.IndexOf("R") -ge 0 -or $status.IndexOf("C") -ge 0) {
            if ($index -lt $tokens.Count) {
                $originalPath = $tokens[$index].Replace("\", "/")
                $index++
            }
        }

        [void]$records.Add([ordered]@{
            status = $status
            indexStatus = [string]$status[0]
            workTreeStatus = [string]$status[1]
            path = $path
            originalPath = $originalPath
        })
    }
    return @($records.ToArray())
}

# Audits Git only when repository metadata is safely contained by the candidate root.
function Invoke-GitInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $gitMetadataPath = Join-Path $script:CandidateRoot ".git"
    $metadataState = Get-SafeEntryState -Path $gitMetadataPath -ExpectedType "Any"
    if ($metadataState.state -eq "MISSING") {
        $Result.git.metadataStatus = "NOT_FOUND"
        Add-AuditWarning -Code "GIT_NOT_WORKTREE" -Check "git" -Path ".git" -Message "No project-root Git metadata was found. Parent repositories are intentionally not searched."
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source ".git" -Detail "Git inspection is unavailable for this candidate root."
        return
    }
    if ($metadataState.state -ne "PRESENT") {
        $Result.git.metadataStatus = "UNSAFE"
        Add-AuditWarning -Code "GIT_METADATA_UNSAFE" -Check "git" -Path ".git" -Message "Git metadata was not followed because it is blocked or is a reparse point."
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source ".git" -Detail "Safe Git inspection was not available."
        return
    }

    $gitDirectoryPath = $metadataState.path
    if (-not $metadataState.entry.PSIsContainer) {
        $gitFile = Read-SafeTextFile -Path $gitMetadataPath
        if ($gitFile.state -ne "READ" -or $gitFile.content -notmatch "(?m)^\s*gitdir:\s*(?<path>.+?)\s*$") {
            $Result.git.metadataStatus = "INVALID_GIT_FILE"
            Add-AuditWarning -Code "GIT_FILE_INVALID" -Check "git" -Path ".git" -Message "The .git file could not be parsed as an in-root gitdir reference."
            return
        }

        $rawGitDirectory = $Matches["path"]
        $gitDirectoryPath = if ([System.IO.Path]::IsPathRooted($rawGitDirectory)) {
            ConvertTo-NormalizedAbsolutePath -Path $rawGitDirectory
        } else {
            ConvertTo-NormalizedAbsolutePath -Path (Join-Path $script:CandidateRoot $rawGitDirectory)
        }
        if (-not (Test-PathInsideProjectRoot -Path $gitDirectoryPath)) {
            $Result.git.metadataStatus = "OUTSIDE_PROJECT_ROOT"
            Add-AuditWarning -Code "GIT_METADATA_OUTSIDE_PROJECT" -Check "git" -Path ".git" -Message "The gitdir target is outside the candidate root and was not read."
            Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source ".git" -Detail "External Git metadata was deliberately not followed."
            return
        }

        $gitDirectoryState = Get-SafeEntryState -Path $gitDirectoryPath -ExpectedType "Directory"
        if ($gitDirectoryState.state -ne "PRESENT") {
            $Result.git.metadataStatus = "UNSAFE_GITDIR"
            Add-AuditWarning -Code "GITDIR_UNSAFE" -Check "git" -Path ".git" -Message "The in-root gitdir target could not be inspected safely."
            return
        }
    }

    if (-not (Test-GitMetadataSafety -GitDirectoryPath $gitDirectoryPath)) {
        $Result.git.metadataStatus = "UNSAFE_LAYOUT"
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source ".git" -Detail "Git commands were not run because metadata safety checks found an unsupported indirection or reparse point."
        return
    }

    $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCommand) {
        $Result.git.metadataStatus = "GIT_EXECUTABLE_NOT_FOUND"
        Add-AuditWarning -Code "GIT_EXECUTABLE_NOT_FOUND" -Check "git" -Path $null -Message "Git metadata exists, but the Git executable is unavailable."
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source "git executable lookup" -Detail "Git commands were not run."
        return
    }

    $Result.git.gitAvailable = $true
    $gitExecutablePath = if (-not [string]::IsNullOrWhiteSpace($gitCommand.Path)) { $gitCommand.Path } else { $gitCommand.Source }
    $normalizedGitExecutablePath = ConvertTo-NormalizedAbsolutePath -Path $gitExecutablePath
    if (Test-PathInsideProjectRoot -Path $normalizedGitExecutablePath) {
        $Result.git.metadataStatus = "PROJECT_LOCAL_EXECUTABLE_REFUSED"
        Add-AuditWarning -Code "GIT_EXECUTABLE_INSIDE_PROJECT" -Check "git" -Path (ConvertTo-ProjectRelativePath -Path $normalizedGitExecutablePath) -Message "A project-local Git executable was not run."
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source "git executable lookup" -Detail "Git inspection was skipped rather than execute a program inside the audited project."
        return
    }

    if (-not (Test-GitWorktreeSafety)) {
        $Result.git.metadataStatus = "UNSAFE_WORKTREE_LAYOUT"
        Add-Evidence -Check "git" -Status "NOT_AVAILABLE" -Source "worktree reparse-point preflight" -Detail "Git commands were deliberately skipped so they could not traverse outside the candidate root."
        return
    }

    $worktreeResult = Invoke-SafeGitOperation -Operation "IsWorktree" -GitExecutable $gitExecutablePath
    if ($worktreeResult.exitCode -ne 0 -or $worktreeResult.stdout.Trim() -ne "true") {
        $Result.git.metadataStatus = "QUERY_FAILED"
        Add-BlockedCheck -Code "GIT_WORKTREE_QUERY_FAILED" -Check "git" -Path ".git" -Message "Read-only Git worktree detection failed: $($worktreeResult.stderr)"
        $Result.git.dirtyState = "BLOCKED"
        return
    }

    $topLevelResult = Invoke-SafeGitOperation -Operation "TopLevel" -GitExecutable $gitExecutablePath
    if ($topLevelResult.exitCode -ne 0) {
        $Result.git.metadataStatus = "QUERY_FAILED"
        Add-BlockedCheck -Code "GIT_TOPLEVEL_QUERY_FAILED" -Check "git" -Path ".git" -Message "Git top-level detection failed: $($topLevelResult.stderr)"
        $Result.git.dirtyState = "BLOCKED"
        return
    }

    try {
        $topLevelPath = ConvertTo-NormalizedAbsolutePath -Path $topLevelResult.stdout.Trim()
    } catch {
        Add-BlockedCheck -Code "GIT_TOPLEVEL_INVALID" -Check "git" -Path ".git" -Message "Git returned an invalid top-level path."
        $Result.git.dirtyState = "BLOCKED"
        return
    }
    if (-not $topLevelPath.Equals($script:CandidateRoot, $script:PathComparison)) {
        $Result.git.metadataStatus = "TOPLEVEL_MISMATCH"
        Add-BlockedCheck -Code "GIT_TOPLEVEL_OUTSIDE_PROJECT" -Check "git" -Path ".git" -Message "Git reported a top-level directory different from the candidate root; no further Git commands were run."
        $Result.git.dirtyState = "BLOCKED"
        return
    }

    $Result.git.metadataStatus = "SAFE"
    $Result.git.worktree = $true
    $Result.git.topLevel = $script:CandidateRoot
    Add-Evidence -Check "git" -Status "OBSERVED" -Source "git --no-optional-locks rev-parse" -Detail "The candidate root is a safely contained Git worktree."

    $branchResult = Invoke-SafeGitOperation -Operation "Branch" -GitExecutable $gitExecutablePath
    if ($branchResult.exitCode -eq 0) {
        $Result.git.branch = $branchResult.stdout.Trim()
        $Result.git.detachedHead = $false
    } elseif ($branchResult.exitCode -eq 1) {
        $Result.git.detachedHead = $true
    } else {
        Add-BlockedCheck -Code "GIT_BRANCH_QUERY_FAILED" -Check "git" -Path ".git" -Message "Git branch detection failed: $($branchResult.stderr)"
        $Result.git.dirtyState = "BLOCKED"
        return
    }

    $headResult = Invoke-SafeGitOperation -Operation "Head" -GitExecutable $gitExecutablePath
    if ($headResult.exitCode -eq 0) {
        $Result.git.headCommit = $headResult.stdout.Trim()
    } else {
        Add-AuditWarning -Code "GIT_HEAD_UNBORN" -Check "git" -Path ".git" -Message "The Git worktree has no readable HEAD commit."
    }

    $statusResult = Invoke-SafeGitOperation -Operation "Status" -GitExecutable $gitExecutablePath
    if ($statusResult.exitCode -ne 0) {
        Add-BlockedCheck -Code "GIT_STATUS_QUERY_FAILED" -Check "git" -Path ".git" -Message "Read-only Git status failed: $($statusResult.stderr)"
        $Result.git.dirtyState = "BLOCKED"
        return
    }
    $changedPaths = @(ConvertFrom-GitStatusOutput -Output $statusResult.stdout)
    $Result.git.changedPaths = $changedPaths
    $Result.git.dirty = $changedPaths.Count -gt 0
    $Result.git.dirtyState = if ($Result.git.dirty) { "DIRTY" } else { "CLEAN" }
    Add-Evidence -Check "git" -Status "OBSERVED" -Source "git --no-optional-locks status --porcelain=v1" -Detail "Git dirty state and changed paths were read without refreshing the index."

    $trackedResult = Invoke-SafeGitOperation -Operation "TrackedFiles" -GitExecutable $gitExecutablePath
    if ($trackedResult.exitCode -ne 0) {
        Add-BlockedCheck -Code "GIT_TRACKED_FILES_QUERY_FAILED" -Check "trackedGeneratedFolderPaths" -Path ".git" -Message "Read-only tracked-file enumeration failed: $($trackedResult.stderr)"
        return
    }
    $trackedPaths = @($trackedResult.stdout.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.Replace("\", "/") })
    $script:TrackedGitPaths = @(Sort-StringsOrdinal -Values $trackedPaths)
}

# Parses one safe JSON file while keeping malformed JSON as structured audit data.
function Read-SafeJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $readResult = Read-SafeTextFile -Path $FullPath
    if ($readResult.state -ne "READ") {
        return [pscustomobject][ordered]@{
            state = $readResult.state
            data = $null
            error = $readResult.error
        }
    }

    try {
        $data = ConvertFrom-Json -InputObject $readResult.content -ErrorAction Stop
        return [pscustomobject][ordered]@{
            state = "PARSED"
            data = $data
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            state = "INVALID_JSON"
            data = $null
            error = $_.Exception.Message
        }
    }
}

# Classifies a Unity manifest dependency reference without resolving it.
function Get-DependencyReferenceType {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "unknown"
    }

    $text = [string]$Value
    if ($text -match "^(?i)file:") {
        return "file"
    }
    if ($text -match "^(?i)(git\+|git:|https?://).*(\.git|#)") {
        return "git"
    }
    if ($text -match "^(?i)(\.{1,2}[\\/]|[A-Za-z]:[\\/]|/)") {
        return "local"
    }
    if ($text -match "^\d+(\.\d+){1,3}([\-+].*)?$") {
        return "registry"
    }
    return "other"
}

# Audits manifest and lockfile parsing plus their direct/resolved dependency relationship.
function Invoke-PackageInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $manifestRelativePath = "Packages/manifest.json"
    $lockRelativePath = "Packages/packages-lock.json"
    $manifestResult = Read-SafeJsonFile -FullPath (Join-Path $script:CandidateRoot "Packages\manifest.json")
    $lockResult = Read-SafeJsonFile -FullPath (Join-Path $script:CandidateRoot "Packages\packages-lock.json")

    $manifestData = $null
    if ($manifestResult.state -eq "PARSED") {
        $Result.packages.manifest.exists = $true
        $Result.packages.manifest.parseStatus = "PARSED"
        $manifestData = $manifestResult.data
        Add-Evidence -Check "packages" -Status "OBSERVED" -Source $manifestRelativePath -Detail "manifest.json exists and parsed as JSON."
    } elseif ($manifestResult.state -eq "MISSING" -or $manifestResult.state -eq "WRONG_TYPE") {
        $Result.packages.manifest.parseStatus = "NOT_FOUND"
        Add-AuditWarning -Code "MANIFEST_MISSING" -Check "packages" -Path $manifestRelativePath -Message "manifest.json is missing."
    } elseif ($manifestResult.state -eq "INVALID_JSON") {
        $Result.packages.manifest.exists = $true
        $Result.packages.manifest.parseStatus = "INVALID_JSON"
        $Result.packages.manifest.error = $manifestResult.error
        Add-AuditWarning -Code "MANIFEST_JSON_INVALID" -Check "packages" -Path $manifestRelativePath -Message "manifest.json could not be parsed as JSON."
    } else {
        $Result.packages.manifest.parseStatus = "BLOCKED"
        $Result.packages.manifest.error = $manifestResult.error
        Add-BlockedCheck -Code "MANIFEST_READ_BLOCKED" -Check "packages" -Path $manifestRelativePath -Message "manifest.json could not be read safely: $($manifestResult.error)"
    }

    $lockData = $null
    if ($lockResult.state -eq "PARSED") {
        $Result.packages.packagesLock.exists = $true
        $Result.packages.packagesLock.parseStatus = "PARSED"
        $lockData = $lockResult.data
        Add-Evidence -Check "packages" -Status "OBSERVED" -Source $lockRelativePath -Detail "packages-lock.json exists and parsed as JSON."
    } elseif ($lockResult.state -eq "MISSING" -or $lockResult.state -eq "WRONG_TYPE") {
        $Result.packages.packagesLock.parseStatus = "NOT_FOUND"
        Add-AuditWarning -Code "PACKAGES_LOCK_MISSING" -Check "packages" -Path $lockRelativePath -Message "packages-lock.json is missing."
    } elseif ($lockResult.state -eq "INVALID_JSON") {
        $Result.packages.packagesLock.exists = $true
        $Result.packages.packagesLock.parseStatus = "INVALID_JSON"
        $Result.packages.packagesLock.error = $lockResult.error
        Add-AuditWarning -Code "PACKAGES_LOCK_JSON_INVALID" -Check "packages" -Path $lockRelativePath -Message "packages-lock.json could not be parsed as JSON."
    } else {
        $Result.packages.packagesLock.parseStatus = "BLOCKED"
        $Result.packages.packagesLock.error = $lockResult.error
        Add-BlockedCheck -Code "PACKAGES_LOCK_READ_BLOCKED" -Check "packages" -Path $lockRelativePath -Message "packages-lock.json could not be read safely: $($lockResult.error)"
    }

    $directDependencies = New-Object System.Collections.ArrayList
    if ($null -ne $manifestData) {
        $dependencies = Get-JsonPropertyValue -InputObject $manifestData -Name "dependencies"
        if ($null -eq $dependencies -or $dependencies -is [string] -or $dependencies -is [System.Array]) {
            Add-AuditWarning -Code "MANIFEST_DEPENDENCIES_INVALID" -Check "packages" -Path $manifestRelativePath -Message "The manifest dependencies property is missing or is not an object."
        } else {
            $dependencyNames = Sort-StringsOrdinal -Values @($dependencies.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($dependencyName in $dependencyNames) {
                $dependencyValue = Get-JsonPropertyValue -InputObject $dependencies -Name $dependencyName
                $referenceType = Get-DependencyReferenceType -Value $dependencyValue
                [void]$directDependencies.Add([ordered]@{
                    name = $dependencyName
                    value = if ($null -eq $dependencyValue) { $null } else { [string]$dependencyValue }
                    referenceType = $referenceType
                })
                if ($referenceType -ne "registry") {
                    Add-AuditWarning -Code "NON_REGISTRY_DEPENDENCY_REFERENCE" -Check "packages" -Path $manifestRelativePath -Message "Dependency $dependencyName uses a $referenceType reference and was not resolved by the scanner."
                }
            }
        }
    }
    $Result.packages.directDependencies = @($directDependencies.ToArray())

    $resolvedDependencies = New-Object System.Collections.ArrayList
    $resolvedNames = @()
    if ($null -ne $lockData) {
        $lockDependencies = Get-JsonPropertyValue -InputObject $lockData -Name "dependencies"
        if ($null -eq $lockDependencies -or $lockDependencies -is [string] -or $lockDependencies -is [System.Array]) {
            Add-AuditWarning -Code "PACKAGES_LOCK_DEPENDENCIES_INVALID" -Check "packages" -Path $lockRelativePath -Message "The lockfile dependencies property is missing or is not an object."
        } else {
            $resolvedNames = Sort-StringsOrdinal -Values @($lockDependencies.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($resolvedName in $resolvedNames) {
                $resolvedEntry = Get-JsonPropertyValue -InputObject $lockDependencies -Name $resolvedName
                [void]$resolvedDependencies.Add([ordered]@{
                    name = $resolvedName
                    version = if ($null -eq (Get-JsonPropertyValue -InputObject $resolvedEntry -Name "version")) { $null } else { [string](Get-JsonPropertyValue -InputObject $resolvedEntry -Name "version") }
                    depth = Get-JsonPropertyValue -InputObject $resolvedEntry -Name "depth"
                    source = if ($null -eq (Get-JsonPropertyValue -InputObject $resolvedEntry -Name "source")) { $null } else { [string](Get-JsonPropertyValue -InputObject $resolvedEntry -Name "source") }
                })
            }
        }
    }
    $Result.packages.resolvedDependencies = @($resolvedDependencies.ToArray())

    $missingFromLock = New-Object System.Collections.ArrayList
    foreach ($directDependency in $Result.packages.directDependencies) {
        if ($resolvedNames -notcontains $directDependency.name) {
            [void]$missingFromLock.Add($directDependency.name)
        }
    }
    $Result.packages.directDependenciesMissingFromLock = @(Sort-StringsOrdinal -Values @($missingFromLock))
    if ($Result.packages.directDependenciesMissingFromLock.Count -gt 0) {
        $missingNames = $Result.packages.directDependenciesMissingFromLock -join ", "
        Add-AuditWarning -Code "DIRECT_DEPENDENCIES_MISSING_FROM_LOCK" -Check "packages" -Path $lockRelativePath -Message "Direct dependencies are absent from the lockfile: $missingNames."
    }
}

# Audits all safe asmdef files and separates confirmed evidence from name-only candidates.
function Invoke-AssemblyInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $excludedDirectories = @(
        ".git", "Library", "Temp", "Obj", "obj", "Logs", "Build", "Builds",
        "UserSettings", "MemoryCaptures", "Recordings", "PackageCache"
    )
    $asmdefPaths = New-Object System.Collections.ArrayList
    foreach ($relativeRoot in @("Assets", "Packages")) {
        $scanRoot = Join-Path $script:CandidateRoot $relativeRoot
        $files = @(Get-SafeTreeFiles -StartPath $scanRoot -Extension ".asmdef" -ExcludedDirectoryNames $excludedDirectories -Check "assemblies")
        foreach ($file in $files) {
            [void]$asmdefPaths.Add($file)
        }
    }

    $sortedAsmdefPaths = Sort-StringsOrdinal -Values @($asmdefPaths)
    $asmdefs = New-Object System.Collections.ArrayList
    $confirmedAssemblies = New-Object System.Collections.ArrayList
    $candidateAssemblies = New-Object System.Collections.ArrayList

    foreach ($asmdefPath in $sortedAsmdefPaths) {
        $relativePath = ConvertTo-ProjectRelativePath -Path $asmdefPath
        $jsonResult = Read-SafeJsonFile -FullPath $asmdefPath
        $name = $null
        $confirmedReasons = New-Object System.Collections.ArrayList
        $candidateReasons = New-Object System.Collections.ArrayList
        $parseStatus = $jsonResult.state
        $parseError = $null

        if ($jsonResult.state -eq "PARSED") {
            $nameValue = Get-JsonPropertyValue -InputObject $jsonResult.data -Name "name"
            if ($null -ne $nameValue) {
                $name = [string]$nameValue
            }

            $optionalReferences = Get-JsonPropertyValue -InputObject $jsonResult.data -Name "optionalUnityReferences"
            foreach ($optionalReference in @($optionalReferences)) {
                if ($null -ne $optionalReference -and [string]$optionalReference -eq "TestAssemblies") {
                    [void]$confirmedReasons.Add("optionalUnityReferences:TestAssemblies")
                }
            }

            $references = Get-JsonPropertyValue -InputObject $jsonResult.data -Name "references"
            foreach ($reference in @($references)) {
                if ($null -eq $reference) {
                    continue
                }
                $referenceText = [string]$reference
                if ($referenceText -in @("UnityEngine.TestRunner", "UnityEditor.TestRunner")) {
                    [void]$confirmedReasons.Add("reference:$referenceText")
                }
            }
            Add-Evidence -Check "assemblies" -Status "OBSERVED" -Source $relativePath -Detail "Assembly definition parsed as JSON."
        } elseif ($jsonResult.state -eq "INVALID_JSON") {
            $parseError = $jsonResult.error
            Add-AuditWarning -Code "ASMDEF_JSON_INVALID" -Check "assemblies" -Path $relativePath -Message "Assembly definition could not be parsed as JSON."
        } else {
            $parseError = $jsonResult.error
            Add-BlockedCheck -Code "ASMDEF_READ_BLOCKED" -Check "assemblies" -Path $relativePath -Message "Assembly definition could not be read safely: $($jsonResult.error)"
        }

        if ($relativePath -match "(?i)(^|[\/._-])tests?([\/._-]|$)") {
            [void]$candidateReasons.Add("path contains a test-like token")
        }
        if (-not [string]::IsNullOrWhiteSpace($name) -and $name -match "(?i)(^|[._-])tests?([._-]|$)") {
            [void]$candidateReasons.Add("assembly name contains a test-like token")
        }

        $confirmedReasonValues = @(Sort-StringsOrdinal -Values @($confirmedReasons))
        $candidateReasonValues = @(Sort-StringsOrdinal -Values @($candidateReasons))
        $isConfirmed = $confirmedReasonValues.Count -gt 0
        $isCandidateOnly = -not $isConfirmed -and $candidateReasonValues.Count -gt 0
        $asmdefRecord = [ordered]@{
            path = $relativePath
            name = $name
            parseStatus = $parseStatus
            error = $parseError
            confirmedTestAssembly = $isConfirmed
            confirmedEvidence = $confirmedReasonValues
            candidateOnlyTestAssembly = $isCandidateOnly
            candidateEvidence = $candidateReasonValues
        }
        [void]$asmdefs.Add($asmdefRecord)

        if ($isConfirmed) {
            [void]$confirmedAssemblies.Add([ordered]@{
                path = $relativePath
                name = $name
                evidence = $confirmedReasonValues
            })
        } elseif ($isCandidateOnly) {
            [void]$candidateAssemblies.Add([ordered]@{
                path = $relativePath
                name = $name
                evidence = $candidateReasonValues
            })
        }
    }

    $Result.assemblies.asmdefs = @($asmdefs.ToArray())
    $Result.assemblies.confirmedTestAssemblies = @($confirmedAssemblies.ToArray())
    $Result.assemblies.candidateOnlyTestAssemblies = @($candidateAssemblies.ToArray())
    if ($Result.assemblies.confirmedTestAssemblies.Count -eq 0) {
        Add-AuditWarning -Code "NO_DECLARED_TEST_ASSEMBLY_DETECTED" -Check "assemblies" -Path $null -Message "No asmdef contains direct Unity test assembly evidence; this does not prove that the project has no tests."
    }
}

# Removes simple YAML quote delimiters without interpreting or executing content.
function Remove-SimpleYamlQuotes {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $null
    }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2) {
        if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }
    return $trimmed
}

# Counts leading whitespace so the Unity YAML scene section can be bounded safely.
function Get-LeadingWhitespaceCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $match = [regex]::Match($Line, "^\s*")
    return $match.Length
}

# Converts one Build Settings scene record and checks its path without following links.
function ConvertTo-BuildSceneRecord {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$EnabledRaw,

        [Parameter()]
        [AllowNull()]
        [string]$ScenePath,

        [Parameter()]
        [AllowNull()]
        [string]$Guid
    )

    $enabled = $null
    if ($EnabledRaw -eq "1") {
        $enabled = $true
    } elseif ($EnabledRaw -eq "0") {
        $enabled = $false
    } else {
        Add-AuditWarning -Code "BUILD_SCENE_ENABLED_INVALID" -Check "buildSettings" -Path "ProjectSettings/EditorBuildSettings.asset" -Message "A Build Settings scene has an unrecognized enabled value."
    }

    $normalizedScenePath = Remove-SimpleYamlQuotes -Value $ScenePath
    $normalizedGuid = Remove-SimpleYamlQuotes -Value $Guid
    $exists = $false
    $pathStatus = "EMPTY"

    if ([string]::IsNullOrWhiteSpace($normalizedScenePath)) {
        Add-AuditWarning -Code "BUILD_SCENE_PATH_EMPTY" -Check "buildSettings" -Path "ProjectSettings/EditorBuildSettings.asset" -Message "A Build Settings scene entry has an empty path."
    } elseif ([System.IO.Path]::IsPathRooted($normalizedScenePath)) {
        $pathStatus = "OUTSIDE_ROOT"
        Add-AuditWarning -Code "BUILD_SCENE_OUTSIDE_PROJECT" -Check "buildSettings" -Path $normalizedScenePath -Message "An absolute Build Settings scene path was not read."
    } else {
        try {
            $fullScenePath = ConvertTo-NormalizedAbsolutePath -Path (Join-Path $script:CandidateRoot $normalizedScenePath)
            if (-not (Test-PathInsideProjectRoot -Path $fullScenePath)) {
                $pathStatus = "OUTSIDE_ROOT"
                Add-AuditWarning -Code "BUILD_SCENE_OUTSIDE_PROJECT" -Check "buildSettings" -Path $normalizedScenePath -Message "A Build Settings scene path resolves outside the candidate root and was not read."
            } else {
                $sceneState = Get-SafeEntryState -Path $fullScenePath -ExpectedType "File"
                $pathStatus = $sceneState.state
                if ($sceneState.state -eq "PRESENT") {
                    $exists = $true
                } elseif ($sceneState.state -eq "MISSING" -or $sceneState.state -eq "WRONG_TYPE") {
                    Add-AuditWarning -Code "BUILD_SCENE_MISSING" -Check "buildSettings" -Path $normalizedScenePath -Message "A Build Settings scene path does not resolve to an existing project file."
                } elseif ($sceneState.state -eq "REPARSE_POINT") {
                    Add-AuditWarning -Code "BUILD_SCENE_REPARSE_POINT" -Check "buildSettings" -Path $normalizedScenePath -Message "A Build Settings scene path crosses a reparse point and was not followed."
                } else {
                    Add-BlockedCheck -Code "BUILD_SCENE_CHECK_BLOCKED" -Check "buildSettings" -Path $normalizedScenePath -Message "A Build Settings scene path could not be inspected safely: $($sceneState.error)"
                }
            }
        } catch {
            $pathStatus = "INVALID_PATH"
            Add-AuditWarning -Code "BUILD_SCENE_PATH_INVALID" -Check "buildSettings" -Path $normalizedScenePath -Message "A Build Settings scene path is invalid and was not read."
        }
    }

    return [ordered]@{
        enabled = $enabled
        path = $normalizedScenePath
        guid = $normalizedGuid
        exists = $exists
        pathStatus = $pathStatus
    }
}

# Parses EditorBuildSettings.asset as bounded text and inventories enabled, disabled, and missing scenes.
function Invoke-BuildSettingsInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $relativePath = "ProjectSettings/EditorBuildSettings.asset"
    $readResult = Read-SafeTextFile -Path (Join-Path $script:CandidateRoot "ProjectSettings\EditorBuildSettings.asset")
    if ($readResult.state -eq "MISSING" -or $readResult.state -eq "WRONG_TYPE") {
        $Result.buildSettings.parseStatus = "NOT_FOUND"
        Add-AuditWarning -Code "BUILD_SETTINGS_MISSING" -Check "buildSettings" -Path $relativePath -Message "EditorBuildSettings.asset is missing."
        return
    }
    if ($readResult.state -ne "READ") {
        $Result.buildSettings.parseStatus = "BLOCKED"
        Add-BlockedCheck -Code "BUILD_SETTINGS_READ_BLOCKED" -Check "buildSettings" -Path $relativePath -Message "EditorBuildSettings.asset could not be read safely: $($readResult.error)"
        return
    }

    $Result.buildSettings.exists = $true
    $lines = @($readResult.content -split "\r?\n")
    $sectionIndex = -1
    $sectionIndent = -1
    $inlineEmpty = $false
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $sectionMatch = [regex]::Match($lines[$lineIndex], "^\s*m_Scenes:\s*(?<tail>.*?)\s*$")
        if ($sectionMatch.Success) {
            $sectionIndex = $lineIndex
            $sectionIndent = Get-LeadingWhitespaceCount -Line $lines[$lineIndex]
            $inlineEmpty = $sectionMatch.Groups["tail"].Value -eq "[]"
            break
        }
    }

    if ($sectionIndex -lt 0) {
        $Result.buildSettings.parseStatus = "MALFORMED"
        Add-AuditWarning -Code "BUILD_SCENE_SECTION_MISSING" -Check "buildSettings" -Path $relativePath -Message "The m_Scenes section was not found."
        return
    }

    $rawScenes = New-Object System.Collections.ArrayList
    if (-not $inlineEmpty) {
        $currentScene = $null
        for ($lineIndex = $sectionIndex + 1; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lineIndent = Get-LeadingWhitespaceCount -Line $line
                $isSceneListItem = $line -match "^\s*-\s*enabled:"
                if ($lineIndent -lt $sectionIndent -or ($lineIndent -eq $sectionIndent -and -not $isSceneListItem)) {
                    break
                }
            }

            $enabledMatch = [regex]::Match($line, "^\s*-\s*enabled:\s*(?<value>\S+)\s*$")
            if ($enabledMatch.Success) {
                if ($null -ne $currentScene) {
                    [void]$rawScenes.Add($currentScene)
                }
                $currentScene = [ordered]@{
                    enabled = $enabledMatch.Groups["value"].Value
                    path = $null
                    guid = $null
                }
                continue
            }
            if ($null -eq $currentScene) {
                continue
            }

            $pathMatch = [regex]::Match($line, "^\s*path:\s*(?<value>.*?)\s*$")
            if ($pathMatch.Success) {
                $currentScene.path = $pathMatch.Groups["value"].Value
                continue
            }
            $guidMatch = [regex]::Match($line, "^\s*guid:\s*(?<value>.*?)\s*$")
            if ($guidMatch.Success) {
                $currentScene.guid = $guidMatch.Groups["value"].Value
            }
        }
        if ($null -ne $currentScene) {
            [void]$rawScenes.Add($currentScene)
        }
    }

    $enabledScenes = New-Object System.Collections.ArrayList
    $disabledScenes = New-Object System.Collections.ArrayList
    $missingScenes = New-Object System.Collections.ArrayList
    foreach ($rawScene in $rawScenes) {
        $scene = ConvertTo-BuildSceneRecord -EnabledRaw $rawScene.enabled -ScenePath $rawScene.path -Guid $rawScene.guid
        if ($scene.enabled -eq $true) {
            [void]$enabledScenes.Add($scene)
        } else {
            [void]$disabledScenes.Add($scene)
        }
        if (-not $scene.exists -and -not [string]::IsNullOrWhiteSpace($scene.path)) {
            [void]$missingScenes.Add([ordered]@{
                enabled = $scene.enabled
                path = $scene.path
                guid = $scene.guid
                reason = $scene.pathStatus
            })
        }
    }

    $Result.buildSettings.parseStatus = "PARSED"
    $Result.buildSettings.enabledScenes = @($enabledScenes.ToArray())
    $Result.buildSettings.disabledScenes = @($disabledScenes.ToArray())
    $Result.buildSettings.missingScenes = @($missingScenes.ToArray())
    Add-Evidence -Check "buildSettings" -Status "OBSERVED" -Source $relativePath -Detail "Build Settings scene entries were parsed as text without opening Unity scenes."
}

# Enumerates immediate safe child directories without traversing their contents.
function Get-SafeImmediateDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$Check
    )

    $parentState = Get-SafeEntryState -Path $ParentPath -ExpectedType "Directory"
    if ($parentState.state -eq "MISSING" -or $parentState.state -eq "WRONG_TYPE") {
        return
    }
    if ($parentState.state -ne "PRESENT") {
        Add-AuditWarning -Code "PROJECT_SKILL_ROOT_UNSAFE" -Check $Check -Path (ConvertTo-ProjectRelativePath -Path $ParentPath) -Message "A project-local Skill root was not traversed because it is blocked or a reparse point."
        return
    }

    try {
        $children = @(Get-ChildItem -LiteralPath $parentState.path -Directory -Force -ErrorAction Stop)
    } catch {
        Add-BlockedCheck -Code "PROJECT_SKILL_ROOT_READ_BLOCKED" -Check $Check -Path (ConvertTo-ProjectRelativePath -Path $ParentPath) -Message "A project-local Skill root could not be enumerated: $($_.Exception.Message)"
        return
    }

    $childPaths = Sort-StringsOrdinal -Values @($children | ForEach-Object { $_.FullName })
    foreach ($childPath in $childPaths) {
        $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
        $relativeChild = ConvertTo-ProjectRelativePath -Path $childPath
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-AuditWarning -Code "PROJECT_SKILL_REPARSE_POINT" -Check $Check -Path $relativeChild -Message "A linked project-local Skill directory was not followed."
            continue
        }
        $child.FullName
    }
}

# Inventories AGENTS.md scopes and project-local Skill manifests without invoking their content.
function Invoke-ProjectGuidanceInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $excludedDirectories = @(
        ".git", "Library", "Temp", "Obj", "obj", "Logs", "Build", "Builds",
        "UserSettings", "MemoryCaptures", "Recordings", "PackageCache"
    )
    $agentsFiles = New-Object System.Collections.ArrayList
    $agentsPaths = @(Get-SafeTreeFiles -StartPath $script:CandidateRoot -FileName "AGENTS.md" -ExcludedDirectoryNames $excludedDirectories -Check "agentsFiles")
    foreach ($agentsPath in $agentsPaths) {
        $relativePath = ConvertTo-ProjectRelativePath -Path $agentsPath
        $lastSeparator = $relativePath.LastIndexOf("/")
        $scope = if ($lastSeparator -lt 0) { "." } else { $relativePath.Substring(0, $lastSeparator) }
        [void]$agentsFiles.Add([ordered]@{
            path = $relativePath
            scope = $scope
        })
    }
    $Result.agentsFiles = @($agentsFiles.ToArray())
    Add-Evidence -Check "agentsFiles" -Status "OBSERVED" -Source "safe filesystem enumeration" -Detail "AGENTS.md files and their directory scopes were inventoried without executing instructions."

    $projectSkills = New-Object System.Collections.ArrayList
    foreach ($skillRootRelative in @(".agents/skills", ".codex/skills")) {
        $skillRootNative = $skillRootRelative.Replace("/", "\")
        $skillRootPath = Join-Path $script:CandidateRoot $skillRootNative
        $skillDirectories = @(Get-SafeImmediateDirectories -ParentPath $skillRootPath -Check "projectSkills")
        foreach ($skillDirectory in $skillDirectories) {
            $skillManifestPath = Join-Path $skillDirectory "SKILL.md"
            $relativeManifestPath = ConvertTo-ProjectRelativePath -Path $skillManifestPath
            $readResult = Read-SafeTextFile -Path $skillManifestPath
            $name = $null
            $parseStatus = "NOT_FOUND"
            if ($readResult.state -eq "READ") {
                $frontmatterMatch = [regex]::Match($readResult.content, "^---\r?\n(?<body>.*?)\r?\n---", [System.Text.RegularExpressions.RegexOptions]::Singleline)
                if ($frontmatterMatch.Success) {
                    $nameMatch = [regex]::Match($frontmatterMatch.Groups["body"].Value, "(?m)^\s*name:\s*(?<name>.+?)\s*$")
                    if ($nameMatch.Success) {
                        $candidateName = $nameMatch.Groups["name"].Value.Trim().Trim([char]34).Trim([char]39)
                        if ($candidateName -match "^[a-z0-9-]+$") {
                            $name = $candidateName
                            $parseStatus = "PARSED"
                        } else {
                            $parseStatus = "NAME_INVALID"
                            Add-AuditWarning -Code "PROJECT_SKILL_NAME_INVALID" -Check "projectSkills" -Path $relativeManifestPath -Message "A project-local SKILL.md frontmatter name is not valid hyphen-case."
                        }
                    } else {
                        $parseStatus = "NAME_NOT_FOUND"
                        Add-AuditWarning -Code "PROJECT_SKILL_NAME_MISSING" -Check "projectSkills" -Path $relativeManifestPath -Message "A project-local SKILL.md has no readable frontmatter name."
                    }
                } else {
                    $parseStatus = "FRONTMATTER_INVALID"
                    Add-AuditWarning -Code "PROJECT_SKILL_FRONTMATTER_INVALID" -Check "projectSkills" -Path $relativeManifestPath -Message "A project-local SKILL.md has invalid frontmatter delimiters."
                }
            } elseif ($readResult.state -eq "MISSING" -or $readResult.state -eq "WRONG_TYPE") {
                Add-AuditWarning -Code "PROJECT_SKILL_MANIFEST_MISSING" -Check "projectSkills" -Path $relativeManifestPath -Message "A project-local Skill directory has no SKILL.md."
            } else {
                $parseStatus = "BLOCKED"
                Add-BlockedCheck -Code "PROJECT_SKILL_READ_BLOCKED" -Check "projectSkills" -Path $relativeManifestPath -Message "A project-local SKILL.md could not be read safely: $($readResult.error)"
            }

            $lastSeparator = $relativeManifestPath.LastIndexOf("/")
            $scope = if ($lastSeparator -lt 0) { "." } else { $relativeManifestPath.Substring(0, $lastSeparator) }
            [void]$projectSkills.Add([ordered]@{
                path = $relativeManifestPath
                scope = $scope
                name = $name
                parseStatus = $parseStatus
            })
        }
    }
    $Result.projectSkills = @($projectSkills.ToArray())
    Add-Evidence -Check "projectSkills" -Status "OBSERVED" -Source ".agents/skills and .codex/skills" -Detail "Project-local Skill manifests were inventoried but not invoked."
}

# Finds tracked paths containing known generated-directory segments.
function Invoke-TrackedGeneratedFolderInspection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Result
    )

    $generatedDirectoryNames = @(
        "Library", "Temp", "Obj", "Logs", "UserSettings", "Build", "Builds",
        "MemoryCaptures", "Recordings"
    )
    $trackedGeneratedPaths = New-Object System.Collections.ArrayList
    foreach ($trackedPath in $script:TrackedGitPaths) {
        $segments = @($trackedPath -split "[\\/]")
        $matchedFolder = $null
        foreach ($segment in $segments) {
            if ($generatedDirectoryNames -icontains $segment) {
                $matchedFolder = $segment
                break
            }
        }
        if ($null -eq $matchedFolder) {
            continue
        }

        [void]$trackedGeneratedPaths.Add([ordered]@{
            generatedFolder = $matchedFolder
            path = $trackedPath
        })
        Add-AuditWarning -Code "TRACKED_GENERATED_FOLDER" -Check "trackedGeneratedFolderPaths" -Path $trackedPath -Message "Git tracks a path under the generated or policy-sensitive folder $matchedFolder."
    }
    $Result.trackedGeneratedFolderPaths = @($trackedGeneratedPaths.ToArray())

    if ($Result.git.worktree) {
        Add-Evidence -Check "trackedGeneratedFolderPaths" -Status "OBSERVED" -Source "git --no-optional-locks ls-files" -Detail "Tracked paths were checked for generated-directory segments."
    }
}

$auditResult = $null
$dynamicEvidenceAdded = $false
try {
    $script:CandidateRoot = ConvertTo-NormalizedAbsolutePath -Path $ProjectRoot
    $auditResult = New-AuditResult -NormalizedProjectRoot $script:CandidateRoot
    $isUnityProject = Invoke-ProjectDetection -Result $auditResult
    if ($isUnityProject) {
        Invoke-ProjectFingerprintInspection -Result $auditResult
        Invoke-UnityVersionInspection -Result $auditResult
        Invoke-GitInspection -Result $auditResult
        Invoke-PackageInspection -Result $auditResult
        Invoke-AssemblyInspection -Result $auditResult
        Invoke-BuildSettingsInspection -Result $auditResult
        Invoke-ProjectGuidanceInspection -Result $auditResult
        Invoke-TrackedGeneratedFolderInspection -Result $auditResult
    }

    Add-DynamicVerificationEvidence
    $dynamicEvidenceAdded = $true
    Complete-AuditResult -Result $auditResult
} catch {
    [Console]::Error.WriteLine("Unity Project Doctor scanner error: $($_.Exception.Message)")
    if ($null -eq $script:CandidateRoot) {
        $script:CandidateRoot = [string]$ProjectRoot
    }
    if ($null -eq $auditResult) {
        $auditResult = New-AuditResult -NormalizedProjectRoot ([string]$script:CandidateRoot)
    }
    Add-BlockedCheck -Code "SCANNER_UNEXPECTED_ERROR" -Check "scanner" -Path $null -Message "The scanner encountered an unexpected internal error. See stderr for diagnostics."
    if (-not $dynamicEvidenceAdded) {
        Add-DynamicVerificationEvidence
    }
    Complete-AuditResult -Result $auditResult
}

$json = if ($Pretty) {
    ConvertTo-Json -InputObject $auditResult -Depth 30
} else {
    ConvertTo-Json -InputObject $auditResult -Depth 30 -Compress
}
[Console]::Out.WriteLine([string]$json)
