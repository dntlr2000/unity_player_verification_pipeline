Set-StrictMode -Version Latest

$script:BaselineGitAllowedCheckpointPrefix = ".git/refs/codex/turn-diffs/checkpoints/"
$script:BaselineIntegrityUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:BaselineIntegrityPathComparer = if ($env:OS -eq "Windows_NT") {
    [System.StringComparer]::OrdinalIgnoreCase
} else {
    [System.StringComparer]::Ordinal
}
$script:BaselineIntegrityPathComparison = if ($env:OS -eq "Windows_NT") {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Returns the only Git metadata prefix whose newly added checkpoint entries are ambient and non-blocking.
function Get-BaselineGitAllowedCheckpointPrefix {
    return $script:BaselineGitAllowedCheckpointPrefix
}

# Normalizes an integrity path without resolving a link target.
function Get-BaselineIntegrityNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($script:BaselineIntegrityPathComparer.Equals($fullPath, $pathRoot)) {
        return $fullPath
    }
    return $fullPath.TrimEnd("\", "/")
}

# Converts one path below the project root to a forward-slash relative path.
function ConvertTo-BaselineIntegrityRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $normalizedPath = Get-BaselineIntegrityNormalizedPath -Path $Path
    $normalizedRoot = Get-BaselineIntegrityNormalizedPath -Path $ProjectRoot
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, $script:BaselineIntegrityPathComparison)) {
        throw "Git metadata path escapes the project root: $normalizedPath"
    }
    return $normalizedPath.Substring($normalizedRoot.Length + 1).Replace("\", "/")
}

# Calculates a lowercase SHA-256 digest without preventing another process from reading or updating the file.
function Get-BaselineIntegrityFileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $algorithm = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $share
        )
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $algorithm.ComputeHash($stream)
        return -join @($bytes | ForEach-Object { $_.ToString("x2") })
    } finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# Calculates a lowercase SHA-256 digest over canonical UTF-8 text.
function Get-BaselineIntegrityTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:BaselineIntegrityUtf8NoBom.GetBytes($Text)
        $digest = $algorithm.ComputeHash($bytes)
        return -join @($digest | ForEach-Object { $_.ToString("x2") })
    } finally {
        $algorithm.Dispose()
    }
}

# Captures only the in-project .git entry and its descendants without following reparse points or Git indirection.
function Get-BaselineGitMetadataSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $normalizedRoot = Get-BaselineIntegrityNormalizedPath -Path $ProjectRoot
    $rootEntry = Get-Item -LiteralPath $normalizedRoot -Force -ErrorAction Stop
    if (-not $rootEntry.PSIsContainer) {
        throw "Project root is not a directory: $normalizedRoot"
    }
    if (($rootEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Project root is a reparse point: $normalizedRoot"
    }

    $gitPath = Join-Path -Path $normalizedRoot -ChildPath ".git"
    $gitEntry = $null
    try {
        $gitEntry = Get-Item -LiteralPath $gitPath -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        $gitEntry = $null
    }
    if ($null -eq $gitEntry) {
        return [pscustomobject][ordered]@{
            present = $false
            entryType = "MISSING"
            directories = [string[]]@()
            files = [object[]]@()
            directoryCount = 0
            fileCount = 0
            treeSha256 = Get-BaselineIntegrityTextSha256 -Text "R|MISSING"
        }
    }

    if (($gitEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The in-project .git entry is a reparse point."
    }

    $directories = New-Object 'System.Collections.Generic.List[string]'
    $filesByPath = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ($script:BaselineIntegrityPathComparer)
    $entryType = if ($gitEntry.PSIsContainer) { "DIRECTORY" } else { "FILE" }

    if ($gitEntry.PSIsContainer) {
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($gitEntry.FullName)
        while ($queue.Count -gt 0) {
            $currentDirectory = $queue.Dequeue()
            foreach ($entry in @(Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop)) {
                $relativePath = ConvertTo-BaselineIntegrityRelativePath -Path $entry.FullName -ProjectRoot $normalizedRoot
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Git metadata contains a reparse point: $relativePath"
                }
                if ($entry.PSIsContainer) {
                    $directories.Add($relativePath)
                    $queue.Enqueue($entry.FullName)
                    continue
                }
                if (-not (Test-Path -LiteralPath $entry.FullName -PathType Leaf)) {
                    throw "Git metadata contains an unsupported filesystem entry: $relativePath"
                }
                $filesByPath.Add($relativePath, [pscustomobject][ordered]@{
                    path = $relativePath
                    length = [long]$entry.Length
                    sha256 = Get-BaselineIntegrityFileSha256 -Path $entry.FullName
                })
            }
        }
    } elseif (Test-Path -LiteralPath $gitEntry.FullName -PathType Leaf) {
        $filesByPath.Add(".git", [pscustomobject][ordered]@{
            path = ".git"
            length = [long]$gitEntry.Length
            sha256 = Get-BaselineIntegrityFileSha256 -Path $gitEntry.FullName
        })
    } else {
        throw "The in-project .git entry has an unsupported filesystem type."
    }

    $directoryArray = $directories.ToArray()
    [System.Array]::Sort($directoryArray, [System.StringComparer]::Ordinal)
    $fileArray = [object[]]@($filesByPath.Values)
    $canonicalLines = New-Object 'System.Collections.Generic.List[string]'
    $canonicalLines.Add("R|$entryType")
    foreach ($directoryPath in $directoryArray) {
        $canonicalLines.Add("D|$directoryPath")
    }
    foreach ($file in $fileArray) {
        $canonicalLines.Add("F|$($file.path)|$($file.length)|$($file.sha256)")
    }

    return [pscustomobject][ordered]@{
        present = $true
        entryType = $entryType
        directories = [string[]]$directoryArray
        files = $fileArray
        directoryCount = [int]$directoryArray.Count
        fileCount = [int]$fileArray.Count
        treeSha256 = Get-BaselineIntegrityTextSha256 -Text ([string]::Join([char]10, $canonicalLines.ToArray()))
    }
}

# Compares two Git metadata snapshots and reports every structural or byte-level difference.
function Compare-BaselineGitMetadataSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Before,

        [Parameter(Mandatory = $true)]
        [object]$After
    )

    $beforeDirectories = @{}
    $afterDirectories = @{}
    foreach ($path in @($Before.directories)) {
        $key = if ($env:OS -eq "Windows_NT") { ([string]$path).ToUpperInvariant() } else { [string]$path }
        $beforeDirectories[$key] = [string]$path
    }
    foreach ($path in @($After.directories)) {
        $key = if ($env:OS -eq "Windows_NT") { ([string]$path).ToUpperInvariant() } else { [string]$path }
        $afterDirectories[$key] = [string]$path
    }

    $addedDirectories = New-Object System.Collections.ArrayList
    $removedDirectories = New-Object System.Collections.ArrayList
    foreach ($key in $afterDirectories.Keys) {
        if (-not $beforeDirectories.ContainsKey($key)) {
            [void]$addedDirectories.Add($afterDirectories[$key])
        } elseif ([string]$beforeDirectories[$key] -cne [string]$afterDirectories[$key]) {
            [void]$removedDirectories.Add($beforeDirectories[$key])
            [void]$addedDirectories.Add($afterDirectories[$key])
        }
    }
    foreach ($key in $beforeDirectories.Keys) {
        if (-not $afterDirectories.ContainsKey($key)) {
            [void]$removedDirectories.Add($beforeDirectories[$key])
        }
    }

    $beforeFiles = @{}
    $afterFiles = @{}
    foreach ($file in @($Before.files)) {
        $key = if ($env:OS -eq "Windows_NT") { ([string]$file.path).ToUpperInvariant() } else { [string]$file.path }
        $beforeFiles[$key] = $file
    }
    foreach ($file in @($After.files)) {
        $key = if ($env:OS -eq "Windows_NT") { ([string]$file.path).ToUpperInvariant() } else { [string]$file.path }
        $afterFiles[$key] = $file
    }

    $addedFiles = New-Object System.Collections.ArrayList
    $removedFiles = New-Object System.Collections.ArrayList
    $changedFiles = New-Object System.Collections.ArrayList
    foreach ($key in $afterFiles.Keys) {
        $afterFile = $afterFiles[$key]
        if (-not $beforeFiles.ContainsKey($key)) {
            [void]$addedFiles.Add([string]$afterFile.path)
            continue
        }
        $beforeFile = $beforeFiles[$key]
        if (
            [string]$beforeFile.path -cne [string]$afterFile.path -or
            [long]$beforeFile.length -ne [long]$afterFile.length -or
            [string]$beforeFile.sha256 -ne [string]$afterFile.sha256
        ) {
            [void]$changedFiles.Add([ordered]@{
                pathBefore = [string]$beforeFile.path
                pathAfter = [string]$afterFile.path
                lengthBefore = [long]$beforeFile.length
                lengthAfter = [long]$afterFile.length
                sha256Before = [string]$beforeFile.sha256
                sha256After = [string]$afterFile.sha256
            })
        }
    }
    foreach ($key in $beforeFiles.Keys) {
        if (-not $afterFiles.ContainsKey($key)) {
            [void]$removedFiles.Add([string]$beforeFiles[$key].path)
        }
    }

    $rootStateChanged = (
        [bool]$Before.present -ne [bool]$After.present -or
        -not [string]::Equals([string]$Before.entryType, [string]$After.entryType, [System.StringComparison]::Ordinal)
    )
    $addedDirectoryArray = [string[]]@($addedDirectories | Sort-Object)
    $removedDirectoryArray = [string[]]@($removedDirectories | Sort-Object)
    $addedFileArray = [string[]]@($addedFiles | Sort-Object)
    $removedFileArray = [string[]]@($removedFiles | Sort-Object)
    $changedFileArray = [object[]]@($changedFiles | Sort-Object -Property pathBefore)
    $unchanged = (
        -not $rootStateChanged -and
        $addedDirectoryArray.Count -eq 0 -and
        $removedDirectoryArray.Count -eq 0 -and
        $addedFileArray.Count -eq 0 -and
        $removedFileArray.Count -eq 0 -and
        $changedFileArray.Count -eq 0 -and
        [string]$Before.treeSha256 -eq [string]$After.treeSha256
    )

    return [pscustomobject][ordered]@{
        unchanged = $unchanged
        rootStateChanged = $rootStateChanged
        addedDirectories = $addedDirectoryArray
        removedDirectories = $removedDirectoryArray
        addedFiles = $addedFileArray
        removedFiles = $removedFileArray
        changedFiles = $changedFileArray
    }
}

# Tests whether an added directory is the checkpoint namespace, one of its parents, or one of its descendants.
function Test-BaselineGitAllowedCheckpointDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$AllowedPrefix
    )

    $path = $RelativePath.Replace("\", "/").TrimEnd("/")
    $prefix = $AllowedPrefix.Replace("\", "/").TrimEnd("/")
    if ($path.Equals($prefix, $script:BaselineIntegrityPathComparison) -or $path.StartsWith($prefix + "/", $script:BaselineIntegrityPathComparison)) {
        return $true
    }
    $parent = $prefix
    while ($parent.LastIndexOf("/", [System.StringComparison]::Ordinal) -gt 0) {
        $parent = $parent.Substring(0, $parent.LastIndexOf("/", [System.StringComparison]::Ordinal))
        if ($parent.Equals(".git", $script:BaselineIntegrityPathComparison)) {
            break
        }
        if ($path.Equals($parent, $script:BaselineIntegrityPathComparison)) {
            return $true
        }
    }
    return $false
}

# Tests whether an added file is strictly below the allowed checkpoint namespace.
function Test-BaselineGitAllowedCheckpointFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$AllowedPrefix
    )

    $path = $RelativePath.Replace("\", "/")
    $prefix = $AllowedPrefix.Replace("\", "/").TrimEnd("/") + "/"
    return $path.StartsWith($prefix, $script:BaselineIntegrityPathComparison)
}

# Classifies unchanged metadata, ambient checkpoint-only additions, and every unsafe Git metadata delta.
function Get-BaselineGitMetadataAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Before,

        [Parameter(Mandatory = $true)]
        [object]$After,

        [Parameter()]
        [string]$AllowedAdditionPrefix = $script:BaselineGitAllowedCheckpointPrefix
    )

    $comparison = Compare-BaselineGitMetadataSnapshots -Before $Before -After $After
    $disallowedAddedDirectories = [string[]]@(
        $comparison.addedDirectories |
            Where-Object { -not (Test-BaselineGitAllowedCheckpointDirectory -RelativePath $_ -AllowedPrefix $AllowedAdditionPrefix) }
    )
    $disallowedAddedFiles = [string[]]@(
        $comparison.addedFiles |
            Where-Object { -not (Test-BaselineGitAllowedCheckpointFile -RelativePath $_ -AllowedPrefix $AllowedAdditionPrefix) }
    )
    $hasAnyAddition = $comparison.addedDirectories.Count -gt 0 -or $comparison.addedFiles.Count -gt 0
    $checkpointOnly = (
        -not $comparison.rootStateChanged -and
        $hasAnyAddition -and
        $comparison.removedDirectories.Count -eq 0 -and
        $comparison.removedFiles.Count -eq 0 -and
        $comparison.changedFiles.Count -eq 0 -and
        $disallowedAddedDirectories.Count -eq 0 -and
        $disallowedAddedFiles.Count -eq 0
    )

    $status = if (-not [bool]$Before.present -and -not [bool]$After.present -and $comparison.unchanged) {
        "NOT_PRESENT"
    } elseif ($comparison.unchanged) {
        "UNCHANGED"
    } elseif ($checkpointOnly) {
        "AMBIENT_CODEX_CHECKPOINTS_ONLY"
    } else {
        "CHANGED"
    }

    return [pscustomobject][ordered]@{
        status = $status
        unchanged = $comparison.unchanged
        ambientChangesAllowed = $checkpointOnly
        allowedAdditionPrefix = $AllowedAdditionPrefix
        rootStateChanged = $comparison.rootStateChanged
        addedDirectories = [string[]]@($comparison.addedDirectories)
        removedDirectories = [string[]]@($comparison.removedDirectories)
        addedFiles = [string[]]@($comparison.addedFiles)
        removedFiles = [string[]]@($comparison.removedFiles)
        changedFiles = [object[]]@($comparison.changedFiles)
        disallowedAddedDirectories = $disallowedAddedDirectories
        disallowedAddedFiles = $disallowedAddedFiles
    }
}
