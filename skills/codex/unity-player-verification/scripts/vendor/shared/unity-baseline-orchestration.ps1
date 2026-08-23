Set-StrictMode -Version Latest

$script:OrchestrationPathComparison = if ($env:OS -eq "Windows_NT") {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$script:OrchestrationUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Returns a stable absolute path without resolving a symbolic-link target.
function Get-OrchestrationNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path must not be empty."
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, $script:OrchestrationPathComparison)) {
        return $fullPath
    }

    return $fullPath.TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ))
}

# Tests whether one normalized path is equal to or below another normalized path.
function Test-OrchestrationPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-OrchestrationNormalizedPath -Path $Path
    $normalizedRoot = Get-OrchestrationNormalizedPath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, $script:OrchestrationPathComparison)) {
        return $true
    }

    $rootPrefix = if ($normalizedRoot.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot
    } else {
        $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    }
    return $normalizedPath.StartsWith($rootPrefix, $script:OrchestrationPathComparison)
}

# Returns the first existing reparse point on a path or one of its existing ancestors.
function Get-OrchestrationReparsePointOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $currentPath = Get-OrchestrationNormalizedPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        try {
            $entry = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $entry.FullName
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
        } catch [System.IO.FileNotFoundException] {
        } catch [System.IO.DirectoryNotFoundException] {
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent -or $parent.FullName.Equals($currentPath, $script:OrchestrationPathComparison)) {
            break
        }
        $currentPath = $parent.FullName
    }

    return $null
}

# Quotes one Windows child-process argument without invoking a command shell.
function ConvertTo-OrchestrationProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument.Contains('"')) {
        throw "Child-process arguments must not contain a double quote."
    }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '\s') {
        return $Argument
    }

    $escaped = [regex]::Replace($Argument, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Runs one trusted PowerShell script with redirected UTF-8 stdout and stderr.
function Invoke-OrchestrationPowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $normalizedScript = Get-OrchestrationNormalizedPath -Path $ScriptPath
    if (-not (Test-Path -LiteralPath $normalizedScript -PathType Leaf)) {
        throw "Trusted child PowerShell script was not found: $normalizedScript"
    }

    $powerShellExecutable = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
        throw "Windows PowerShell executable was not found under PSHOME: $powerShellExecutable"
    }

    $argumentValues = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $normalizedScript
    ) + @($Arguments)
    $quotedArguments = foreach ($argumentValue in $argumentValues) {
        ConvertTo-OrchestrationProcessArgument -Argument ([string]$argumentValue)
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExecutable
    $startInfo.Arguments = [string]::Join(" ", [string[]]@($quotedArguments))
    $startInfo.WorkingDirectory = Get-OrchestrationNormalizedPath -Path $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:OrchestrationUtf8NoBom
    $startInfo.StandardErrorEncoding = $script:OrchestrationUtf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject][ordered]@{
            exitCode = $process.ExitCode
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

# Creates one ordered Unity executable candidate without reading executable metadata.
function New-OrchestrationUnityCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Priority,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = $null
    $normalizationError = $null
    $exists = $false
    $reparsePoint = $null
    try {
        $normalizedPath = Get-OrchestrationNormalizedPath -Path $Path
        $exists = Test-Path -LiteralPath $normalizedPath -PathType Leaf
        if ($exists) {
            $reparsePoint = Get-OrchestrationReparsePointOnPath -Path $normalizedPath
        }
    } catch {
        $normalizationError = $_.Exception.Message
    }

    return [pscustomobject][ordered]@{
        priority = $Priority
        source = $Source
        path = if ($null -ne $normalizedPath) { $normalizedPath } else { $Path }
        exists = [bool]$exists
        reparsePoint = $reparsePoint
        normalizationError = $normalizationError
    }
}

# Resolves an exact-version Unity.exe candidate in a fixed precedence order.
function Resolve-OrchestrationUnityExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequiredVersion,

        [Parameter()]
        [AllowNull()]
        [string]$UnityExecutableOverride,

        [Parameter()]
        [AllowNull()]
        [string]$UnityEditorPath,

        [Parameter()]
        [AllowNull()]
        [string]$UnityHubEditorRoot,

        [Parameter()]
        [AllowNull()]
        [string]$ProgramFilesRoot,

        [Parameter()]
        [AllowNull()]
        [string]$ProgramFilesX86Root
    )

    $candidates = New-Object System.Collections.ArrayList
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Adds a non-empty, non-duplicate candidate while preserving declared precedence.
    function Add-UnityCandidate {
        param(
            [Parameter(Mandatory = $true)]
            [int]$Priority,

            [Parameter(Mandatory = $true)]
            [string]$Source,

            [Parameter()]
            [AllowNull()]
            [string]$Path
        )

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $null
        }
        $candidate = New-OrchestrationUnityCandidate -Priority $Priority -Source $Source -Path $Path
        $key = [string]$candidate.path
        if ($seenPaths.Add($key)) {
            [void]$candidates.Add($candidate)
            return $candidate
        }
        return $null
    }

    $explicitCandidate = Add-UnityCandidate -Priority 1 -Source "UnityExecutable" -Path $UnityExecutableOverride
    if ($null -ne $explicitCandidate) {
        return [pscustomobject][ordered]@{
            requiredVersion = $RequiredVersion
            status = "EXPLICIT_OVERRIDE"
            selectedSource = $explicitCandidate.source
            selectedPath = $explicitCandidate.path
            candidates = @($candidates)
        }
    }

    [void](Add-UnityCandidate -Priority 2 -Source "UNITY_EDITOR_PATH" -Path $UnityEditorPath)
    if (-not [string]::IsNullOrWhiteSpace($UnityHubEditorRoot)) {
        [void](Add-UnityCandidate -Priority 3 -Source "UNITY_HUB_EDITOR_ROOT" -Path (
            Join-Path -Path $UnityHubEditorRoot -ChildPath ("{0}\Editor\Unity.exe" -f $RequiredVersion)
        ))
    }
    if (-not [string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
        [void](Add-UnityCandidate -Priority 4 -Source "ProgramFiles" -Path (
            Join-Path -Path $ProgramFilesRoot -ChildPath ("Unity\Hub\Editor\{0}\Editor\Unity.exe" -f $RequiredVersion)
        ))
    }
    if (-not [string]::IsNullOrWhiteSpace($ProgramFilesX86Root)) {
        [void](Add-UnityCandidate -Priority 5 -Source "ProgramFiles(x86)" -Path (
            Join-Path -Path $ProgramFilesX86Root -ChildPath ("Unity\Hub\Editor\{0}\Editor\Unity.exe" -f $RequiredVersion)
        ))
    }

    foreach ($candidate in @($candidates | Sort-Object -Property priority)) {
        if ($candidate.exists -and $null -eq $candidate.reparsePoint -and $null -eq $candidate.normalizationError) {
            return [pscustomobject][ordered]@{
                requiredVersion = $RequiredVersion
                status = "RESOLVED"
                selectedSource = $candidate.source
                selectedPath = $candidate.path
                candidates = @($candidates)
            }
        }
    }

    return [pscustomobject][ordered]@{
        requiredVersion = $RequiredVersion
        status = "NOT_FOUND"
        selectedSource = $null
        selectedPath = $null
        candidates = @($candidates)
    }
}
