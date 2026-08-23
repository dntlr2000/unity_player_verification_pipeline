Set-StrictMode -Version Latest

$script:UnityFingerprintUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UnityCopyExcludedTopLevelNames = [string[]]@(
    ".agents",
    ".codex",
    ".git",
    ".hg",
    ".idea",
    ".svn",
    ".vs",
    "Build",
    "Builds",
    "Library",
    "Logs",
    "Obj",
    "Temp",
    "UserSettings"
)
$script:UnityCopyExcludedTopLevelLookup = @{}
foreach ($excludedTopLevelName in $script:UnityCopyExcludedTopLevelNames) {
    $script:UnityCopyExcludedTopLevelLookup[$excludedTopLevelName.ToUpperInvariant()] = $true
}

# Returns the frozen top-level exclusions shared by Doctor fingerprinting and Baseline copying.
function Get-UnityCopyExcludedTopLevelNames {
    return [string[]]@($script:UnityCopyExcludedTopLevelNames)
}

# Normalizes one root or entry path without resolving link targets.
function Get-UnityFingerprintNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

# Converts one in-root absolute path to a canonical forward-slash relative path.
function ConvertTo-UnityFingerprintRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-UnityFingerprintNormalizedPath -Path $Path
    $normalizedRoot = Get-UnityFingerprintNormalizedPath -Path $Root
    $comparison = if ($env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if ($normalizedPath.Equals($normalizedRoot, $comparison)) {
        return '.'
    }
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($rootPrefix, $comparison)) {
        throw "Fingerprint path escapes the project root: $normalizedPath"
    }
    return $normalizedPath.Substring($normalizedRoot.Length + 1).Replace('\', '/')
}

# Tests whether a relative path belongs to a generated or tooling tree excluded from copying.
function Test-UnityCopyExcludedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $firstSegment = @($RelativePath.Replace('\', '/').Split('/'))[0]
    return $script:UnityCopyExcludedTopLevelLookup.ContainsKey($firstSegment.ToUpperInvariant())
}

# Calculates one lowercase SHA-256 file digest using read-only sharing.
function Get-UnityFingerprintFileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $algorithm = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $algorithm.ComputeHash($stream)
        return -join @($bytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# Calculates one lowercase SHA-256 digest over UTF-8 text.
function Get-UnityFingerprintTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:UnityFingerprintUtf8NoBom.GetBytes($Text)
        $digest = $algorithm.ComputeHash($bytes)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
    }
}

# Builds the exact non-reparse file set copied into an isolated Unity project.
function Get-UnityCopySetSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $normalizedRoot = Get-UnityFingerprintNormalizedPath -Path $ProjectRoot
    $rootEntry = Get-Item -LiteralPath $normalizedRoot -Force -ErrorAction Stop
    if (-not $rootEntry.PSIsContainer) {
        throw "Fingerprint root is not a directory: $normalizedRoot"
    }
    if (($rootEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Fingerprint root is a reparse point: $normalizedRoot"
    }

    $directories = New-Object 'System.Collections.Generic.List[string]'
    $filesByPath = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([System.StringComparer]::Ordinal)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($normalizedRoot)

    while ($queue.Count -gt 0) {
        $currentDirectory = $queue.Dequeue()
        foreach ($entry in @(Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop)) {
            $relativePath = ConvertTo-UnityFingerprintRelativePath -Path $entry.FullName -Root $normalizedRoot
            if (Test-UnityCopyExcludedRelativePath -RelativePath $relativePath) {
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Copy-included path is a reparse point: $relativePath"
            }

            if ($entry.PSIsContainer) {
                $directories.Add($relativePath)
                $queue.Enqueue($entry.FullName)
                continue
            }
            if (-not (Test-Path -LiteralPath $entry.FullName -PathType Leaf)) {
                throw "Copy-included path has an unsupported filesystem type: $relativePath"
            }

            $filesByPath.Add($relativePath, [pscustomobject][ordered]@{
                path = $relativePath
                length = [long]$entry.Length
                sha256 = Get-UnityFingerprintFileSha256 -Path $entry.FullName
            })
        }
    }

    $directoryArray = $directories.ToArray()
    [System.Array]::Sort($directoryArray, [System.StringComparer]::Ordinal)
    $fileArray = @($filesByPath.Values)
    $canonicalLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directoryPath in $directoryArray) {
        $pathByteLength = $script:UnityFingerprintUtf8NoBom.GetByteCount($directoryPath)
        $canonicalLines.Add("D|$pathByteLength|$directoryPath")
    }
    foreach ($file in $fileArray) {
        $pathByteLength = $script:UnityFingerprintUtf8NoBom.GetByteCount([string]$file.path)
        $canonicalLines.Add("F|$pathByteLength|$($file.path)|$($file.length)|$($file.sha256)")
    }
    $canonicalText = [string]::Join([char]10, $canonicalLines.ToArray())

    return [pscustomobject][ordered]@{
        root = $normalizedRoot
        directories = [string[]]$directoryArray
        files = [object[]]$fileArray
        directoryCount = [int]$directoryArray.Count
        fileCount = [int]$fileArray.Count
        treeSha256 = Get-UnityFingerprintTextSha256 -Text $canonicalText
    }
}

# Requires two consecutive copy-set snapshots to match before returning fingerprint evidence.
function Get-StableUnityCopySetFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $first = Get-UnityCopySetSnapshot -ProjectRoot $ProjectRoot
    $second = Get-UnityCopySetSnapshot -ProjectRoot $ProjectRoot
    if (
        $first.directoryCount -ne $second.directoryCount -or
        $first.fileCount -ne $second.fileCount -or
        -not [string]::Equals($first.treeSha256, $second.treeSha256, [System.StringComparison]::Ordinal)
    ) {
        throw 'The project copy set changed while its fingerprint was being computed.'
    }

    return [pscustomobject][ordered]@{
        contractVersion = '1.0.0'
        status = 'COMPUTED'
        algorithm = 'SHA-256'
        canonicalization = 'unity-copy-set-relative-path-length-sha256-lf-v1'
        excludedTopLevelPaths = [string[]](Get-UnityCopyExcludedTopLevelNames)
        directoryCount = $second.directoryCount
        fileCount = $second.fileCount
        treeSha256 = $second.treeSha256
        stabilityPasses = 2
        error = $null
        snapshot = $second
    }
}
