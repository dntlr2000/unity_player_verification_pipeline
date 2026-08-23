[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.agents\skills')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Returns a stable absolute installer path without resolving a link target.
function Get-UpvrInstallerNormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root)) { return $fullPath }
    return $fullPath.TrimEnd('\', '/')
}

# Finds an existing entry, including a dangling link, at one exact installer path.
function Get-UpvrInstallerPathEntry {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $parent = Split-Path -Parent $LiteralPath
    $leaf = Split-Path -Leaf $LiteralPath
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -ieq $leaf } | Select-Object -First 1
}

# Confirms an existing link targets the exact repository Skill source.
function Test-UpvrInstallerLinkTarget {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Link,
        [Parameter(Mandatory = $true)][string]$ExpectedSource
    )

    if ($Link.LinkType -notin @('SymbolicLink', 'Junction')) { return $false }
    $targets = @($Link.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) { return $false }
    $target = [string]$targets[0]
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $Link.Parent.FullName $target }
    return [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-UpvrInstallerNormalizedPath $target), (Get-UpvrInstallerNormalizedPath $ExpectedSource))
}

# Creates a symbolic link and falls back to a junction only for missing link privilege.
function New-UpvrInstallerSkillLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    try {
        return New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop
    } catch {
        $privilegeDenied = $_.FullyQualifiedErrorId -like 'NewItemSymbolicLinkElevationRequired*' -or $_.Exception -is [System.UnauthorizedAccessException]
        if (-not $privilegeDenied) { throw }
        return New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop
    }
}

$skillName = 'unity-player-verification'
$repositoryRoot = Get-UpvrInstallerNormalizedPath -Path (Split-Path -Parent $PSScriptRoot)
$sourcePath = Get-UpvrInstallerNormalizedPath -Path (Join-Path $repositoryRoot 'skills\codex\unity-player-verification')
$destinationRootPath = Get-UpvrInstallerNormalizedPath -Path $DestinationRoot
$targetPath = Join-Path $destinationRootPath $skillName

foreach ($required in @($sourcePath, (Join-Path $sourcePath 'SKILL.md'), (Join-Path $sourcePath 'VERSION'), (Join-Path $sourcePath 'scripts\invoke-unity-player-verification.ps1'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Standalone Unity Player Verification source is incomplete: $required" }
}
$sourceEntry = Get-Item -LiteralPath $sourcePath -Force
if (-not $sourceEntry.PSIsContainer -or $sourceEntry.LinkType) { throw 'Skill source must be a physical repository directory.' }
$destinationEntry = Get-UpvrInstallerPathEntry -LiteralPath $destinationRootPath
if ($null -ne $destinationEntry -and (-not $destinationEntry.PSIsContainer -or $destinationEntry.LinkType)) { throw 'Installation root must be a physical directory.' }
$existing = Get-UpvrInstallerPathEntry -LiteralPath $targetPath
if ($null -ne $existing) {
    if (Test-UpvrInstallerLinkTarget -Link $existing -ExpectedSource $sourcePath) {
        Write-Host "[unchanged] $skillName -> $sourcePath"
        Write-Host 'Install plan processed. Created: 0; unchanged: 1.'
        return
    }
    throw "Refusing to replace an unrelated existing entry at $targetPath."
}
if ($null -eq $destinationEntry -and $PSCmdlet.ShouldProcess($destinationRootPath, 'Create Skill installation root')) {
    New-Item -ItemType Directory -Path $destinationRootPath -Force | Out-Null
}
$created = $false
if ($PSCmdlet.ShouldProcess($targetPath, "Create filesystem link to $sourcePath")) {
    $createdEntry = New-UpvrInstallerSkillLink -Path $targetPath -Target $sourcePath
    $created = $true
}
if ($created) {
    $installed = Get-UpvrInstallerPathEntry -LiteralPath $targetPath
    if ($null -eq $installed -or -not (Test-UpvrInstallerLinkTarget -Link $installed -ExpectedSource $sourcePath)) { throw 'Installed Skill link verification failed.' }
    Write-Host "[linked:$($createdEntry.LinkType)] $skillName -> $sourcePath"
}
Write-Host ("Install plan processed. Created: {0}; unchanged: 0." -f $(if ($created) { 1 } else { 0 }))
