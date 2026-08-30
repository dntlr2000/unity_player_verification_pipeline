[CmdletBinding()]
param(
    [Parameter()]
    [string]$ArtifactsRoot = 'E:\CodexValidation\unity-player-verification-toolchain-candidate',

    [Parameter()]
    [AllowNull()]
    [string]$VisualStudioPath,

    [Parameter()]
    [AllowNull()]
    [string]$MsvcVersion,

    [Parameter()]
    [AllowNull()]
    [string]$WindowsSdkVersion,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:TEMP = 'E:\CodexTemp'
$env:TMP = 'E:\CodexTemp'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd('\', '/')
$script:PlayCorePath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\lib\unity-play-verification-core.ps1'
$script:PlayerCorePath = Join-Path $script:RepositoryRoot 'skills\codex\unity-player-verification\scripts\lib\unity-player-verification-core.ps1'

. $script:PlayCorePath
. $script:PlayerCorePath

# Writes the candidate artifact as UTF-8 without a byte-order mark.
function Write-UpvrToolchainCandidateText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Converts one candidate identity into a registry-ready profile that remains unapproved.
function New-UpvrCandidateProfile {
    param([Parameter(Mandatory = $true)][object]$Candidate)

    $safeMsvc = ([string]$Candidate.msvcVersion).ToLowerInvariant().Replace('.', '-')
    $safeSdk = ([string]$Candidate.windowsSdkVersion).ToLowerInvariant().Replace('.', '-')
    $profileId = "msvc-$safeMsvc-sdk-$safeSdk-$($Candidate.buildToolchainIdentity.identitySha256.Substring(0,12))"
    return [pscustomobject][ordered]@{
        profileId=$profileId
        status='CANDIDATE'
        buildToolchainIdentity=$Candidate.buildToolchainIdentity
        approvalHostEnvironmentIdentity=$Candidate.hostEnvironmentIdentity
        approval=[pscustomobject][ordered]@{ evidencePath=$null; evidenceSha256=$null; approvedAtUtc=$null }
    }
}

$root = Get-UpvNormalizedPath -Path $ArtifactsRoot
if ([string]::Equals([System.IO.Path]::GetPathRoot($root), 'C:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Toolchain candidate artifacts must not use the C drive.'
}
if ($null -ne (Get-UpvReparsePointOnPath -Path $root)) { throw 'Toolchain candidate artifact root traverses a reparse point.' }
[void][System.IO.Directory]::CreateDirectory($root)
[void][System.IO.Directory]::CreateDirectory('E:\CodexTemp')

$inventory = Get-UpvrIl2CppToolchainCandidates -VisualStudioPath $VisualStudioPath -MsvcVersion $MsvcVersion -WindowsSdkVersion $WindowsSdkVersion
if (-not $inventory.accepted) { throw ([string]::Join(' ', [string[]]@($inventory.errors))) }
if (@($inventory.candidates).Count -ne 1) { throw "Candidate constraints resolved to $(@($inventory.candidates).Count) identities; specify VisualStudioPath, MsvcVersion, and WindowsSdkVersion until exactly one remains." }
$candidate = $inventory.candidates[0]
$profile = New-UpvrCandidateProfile -Candidate $candidate
$document = [pscustomobject][ordered]@{
    schemaVersion='1.0.0'
    kind='UPVR_IL2CPP_TOOLCHAIN_CANDIDATE'
    generatedAtUtc=[DateTime]::UtcNow.ToString('o')
    candidateId=$candidate.candidateId
    profile=$profile
    observedPaths=[pscustomobject][ordered]@{
        visualStudioPath=$candidate.visualStudioPath
        msvcRoot=$candidate.msvcRoot
        windowsKitsRoot=$candidate.windowsKitsRoot
        tools=@($candidate.tools | ForEach-Object { [pscustomobject][ordered]@{ name=$_.name; path=$_.path } })
        trees=@($candidate.trees | ForEach-Object { [pscustomobject][ordered]@{ name=$_.name; root=$_.root } })
    }
}
$json = if ($Pretty) { ConvertTo-Json $document -Depth 30 } else { ConvertTo-Json $document -Depth 30 -Compress }
$resultPath = Join-Path $root 'toolchain-candidate.json'
Write-UpvrToolchainCandidateText -Path $resultPath -Content $json
[Console]::OutputEncoding = $script:Utf8NoBom
[Console]::Out.WriteLine($json)
