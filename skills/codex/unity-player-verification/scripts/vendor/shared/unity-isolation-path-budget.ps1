Set-StrictMode -Version Latest

$script:UnityIsolationDirectoryPathBoundary = 248
$script:UnityIsolationFilePathBoundary = 260
$script:UnityIsolationPathComparison = if ($env:OS -eq "Windows_NT") {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Returns one normalized destination path for a project-relative copy-set entry.
function Get-UnityIsolationDestinationPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RelativePath
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $pathRoot = [System.IO.Path]::GetPathRoot($normalizedRoot)
    if (-not $normalizedRoot.Equals($pathRoot, $script:UnityIsolationPathComparison)) {
        $normalizedRoot = $normalizedRoot.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq ".") {
        return $normalizedRoot
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Copy-set path must be project-relative: $RelativePath"
    }

    $nativeRelativePath = $RelativePath.Replace(
        "/",
        [string][System.IO.Path]::DirectorySeparatorChar
    ).Replace(
        "\",
        [string][System.IO.Path]::DirectorySeparatorChar
    )
    $destinationPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($normalizedRoot, $nativeRelativePath)
    )
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destinationPath.StartsWith($rootPrefix, $script:UnityIsolationPathComparison)) {
        throw "Copy-set path escapes the isolated project destination: $RelativePath"
    }
    return $destinationPath
}

# Creates one structured path-budget violation for later blocker reporting.
function New-UnityIsolationPathBudgetViolation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("DIRECTORY", "FILE")]
        [string]$PathType,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [int]$Boundary
    )

    $code = if ($PathType -eq "DIRECTORY") {
        "ISOLATION_DIRECTORY_PATH_BUDGET_EXCEEDED"
    } else {
        "ISOLATION_FILE_PATH_BUDGET_EXCEEDED"
    }
    $kind = $PathType.ToLowerInvariant()
    return [pscustomobject][ordered]@{
        code = $code
        check = "isolationPathBudget"
        path = $DestinationPath
        pathType = $PathType
        relativePath = $RelativePath
        destinationPath = $DestinationPath
        characterCount = $DestinationPath.Length
        boundary = $Boundary
        message = "The isolated $kind destination for relative path '$RelativePath' is $($DestinationPath.Length) characters; Baseline requires fewer than $Boundary characters: $DestinationPath"
    }
}

# Calculates copy destination lengths without creating a directory or file.
function Get-UnityIsolationPathBudgetAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $normalizedDestination = Get-UnityIsolationDestinationPath -DestinationRoot $Destination -RelativePath "."
    $violations = New-Object System.Collections.ArrayList
    $maximumDirectoryPathLength = $normalizedDestination.Length
    $maximumFilePathLength = 0

    if ($normalizedDestination.Length -ge $script:UnityIsolationDirectoryPathBoundary) {
        [void]$violations.Add((
            New-UnityIsolationPathBudgetViolation `
                -PathType "DIRECTORY" `
                -RelativePath "." `
                -DestinationPath $normalizedDestination `
                -Boundary $script:UnityIsolationDirectoryPathBoundary
        ))
    }

    [string[]]$relativeDirectories = @($Snapshot.directories | ForEach-Object { [string]$_ })
    [System.Array]::Sort($relativeDirectories, [System.StringComparer]::Ordinal)
    foreach ($relativePath in $relativeDirectories) {
        $destinationPath = Get-UnityIsolationDestinationPath -DestinationRoot $normalizedDestination -RelativePath $relativePath
        $maximumDirectoryPathLength = [Math]::Max($maximumDirectoryPathLength, $destinationPath.Length)
        if ($destinationPath.Length -ge $script:UnityIsolationDirectoryPathBoundary) {
            [void]$violations.Add((
                New-UnityIsolationPathBudgetViolation `
                    -PathType "DIRECTORY" `
                    -RelativePath $relativePath.Replace("\", "/") `
                    -DestinationPath $destinationPath `
                    -Boundary $script:UnityIsolationDirectoryPathBoundary
            ))
        }
    }

    [string[]]$relativeFiles = @($Snapshot.files | ForEach-Object { [string]$_.path })
    [System.Array]::Sort($relativeFiles, [System.StringComparer]::Ordinal)
    foreach ($relativePath in $relativeFiles) {
        $destinationPath = Get-UnityIsolationDestinationPath -DestinationRoot $normalizedDestination -RelativePath $relativePath
        $maximumFilePathLength = [Math]::Max($maximumFilePathLength, $destinationPath.Length)
        if ($destinationPath.Length -ge $script:UnityIsolationFilePathBoundary) {
            [void]$violations.Add((
                New-UnityIsolationPathBudgetViolation `
                    -PathType "FILE" `
                    -RelativePath $relativePath.Replace("\", "/") `
                    -DestinationPath $destinationPath `
                    -Boundary $script:UnityIsolationFilePathBoundary
            ))
        }
    }

    return [pscustomobject][ordered]@{
        accepted = $violations.Count -eq 0
        destinationRoot = $normalizedDestination
        directoryPathBoundary = $script:UnityIsolationDirectoryPathBoundary
        filePathBoundary = $script:UnityIsolationFilePathBoundary
        maximumDirectoryPathLength = $maximumDirectoryPathLength
        maximumFilePathLength = $maximumFilePathLength
        violations = @($violations)
    }
}
