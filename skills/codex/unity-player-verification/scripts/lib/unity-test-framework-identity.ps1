Set-StrictMode -Version Latest

$script:UpvTestFrameworkPackageName = 'com.unity.test-framework'
$script:UpvOfficialUnityRegistryOrigin = 'https://packages.unity.com'
$script:UpvPackageTreeCanonicalization = 'upv-package-tree-relative-path-length-sha256-lf-v1'
$script:UpvIdentityUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Adds the Windows extended-length prefix used only by direct .NET package file access.
function ConvertTo-UpvExtendedLengthPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        return $Path
    }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $Path.Substring(2)
    }
    return '\\?\' + $Path
}

# Removes a Windows extended-length prefix while preserving the absolute path text.
function ConvertFrom-UpvExtendedLengthPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::Ordinal)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        return $Path.Substring(4)
    }
    return $Path
}

# Hashes one package file through an extended-length path on Windows PowerShell 5.1.
function Get-UpvPackageFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead((ConvertTo-UpvExtendedLengthPath -Path $Path))
        $digest = $algorithm.ComputeHash($stream)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $algorithm.Dispose()
    }
}

# Normalizes one HTTPS registry origin without accepting credentials, queries, or fragments.
function ConvertTo-UpvCanonicalRegistryOrigin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Origin
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Origin, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "Registry origin is not an absolute URI: $Origin"
    }
    if ($uri.Scheme -cne 'https') {
        throw 'Registry origin must use HTTPS.'
    }
    if (
        -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($uri.Query) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment)
    ) {
        throw 'Registry origin must not contain credentials, a query, or a fragment.'
    }

    $builder = New-Object System.UriBuilder($uri)
    $builder.Host = $builder.Host.ToLowerInvariant()
    $builder.Path = $builder.Path.TrimEnd('/')
    if ($builder.Port -eq 443) {
        $builder.Port = -1
    }
    return $builder.Uri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
}

# Tests whether one Unity scoped-registry scope can claim the Test Framework package name.
function Test-UpvPackageScopeMatch {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $normalizedScope = $Scope.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        return $false
    }
    return (
        $PackageName.Equals($normalizedScope, [System.StringComparison]::Ordinal) -or
        $PackageName.StartsWith($normalizedScope + '.', [System.StringComparison]::Ordinal)
    )
}

# Verifies that manifest, lock, and scoped-registry evidence resolve Test Framework from an explicitly allowed Unity source.
function Get-UpvTestFrameworkProvenanceAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter()][string]$OfficialRegistryOrigin = $script:UpvOfficialUnityRegistryOrigin,
        [Parameter()][ValidateSet('registry', 'builtin')][string[]]$AllowedSourceKinds = @('registry', 'builtin')
    )

    $root = Get-UpvNormalizedPath -Path $ProjectRoot
    $manifestPath = Join-Path -Path $root -ChildPath 'Packages\manifest.json'
    $lockPath = Join-Path -Path $root -ChildPath 'Packages\packages-lock.json'
    $result = [ordered]@{
        packageName = $script:UpvTestFrameworkPackageName
        manifestPath = $manifestPath
        packagesLockPath = $lockPath
        manifestDependency = $null
        declaredVersion = $null
        resolvedVersion = $null
        packagesLockSource = $null
        packagesLockUrl = $null
        registryOrigin = $null
        expectedRegistryOrigin = $null
        registryOriginMatched = $false
        allowedSourceKinds = [string[]]@($AllowedSourceKinds)
        sourcePolicyMatched = $false
        scopedRegistryInterceptors = @()
        sourceEvidence = @()
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    $interceptors = New-Object System.Collections.ArrayList
    $evidence = New-Object System.Collections.ArrayList

    $officialOrigin = $null
    try {
        $officialOrigin = ConvertTo-UpvCanonicalRegistryOrigin -Origin $OfficialRegistryOrigin
    } catch {
        [void]$errors.Add("Approved registry origin is invalid: $($_.Exception.Message)")
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        [void]$errors.Add('Packages/manifest.json is required for Test Framework provenance.')
    } else {
        try {
            $manifest = Read-UpvJsonFile -Path $manifestPath
            $manifestDependencies = Get-UpvJsonProperty -InputObject $manifest -Name 'dependencies'
            $manifestDependencyValue = Get-UpvJsonProperty -InputObject $manifestDependencies -Name $script:UpvTestFrameworkPackageName
            if ($manifestDependencyValue -isnot [string]) {
                [void]$errors.Add('Manifest Test Framework dependency must be one exact package version string.')
            } else {
                $result.manifestDependency = [string]$manifestDependencyValue
                $result.declaredVersion = [string]$manifestDependencyValue
                [void]$evidence.Add("manifest:$($result.declaredVersion)")
                if ($result.declaredVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
                    [void]$errors.Add('Manifest Test Framework dependency is not an exact package version.')
                }
            }

            $scopedRegistriesProperty = $manifest.PSObject.Properties['scopedRegistries']
            if ($null -ne $scopedRegistriesProperty) {
                $scopedRegistries = $scopedRegistriesProperty.Value
                if ($scopedRegistries -isnot [System.Array]) {
                    [void]$errors.Add('Manifest scopedRegistries must be a JSON array when present.')
                }
                foreach ($registry in @($scopedRegistries)) {
                    $registryName = [string](Get-UpvJsonProperty -InputObject $registry -Name 'name')
                    $registryUrl = [string](Get-UpvJsonProperty -InputObject $registry -Name 'url')
                    $scopesProperty = $registry.PSObject.Properties['scopes']
                    $scopes = $null
                    if ($null -ne $scopesProperty) {
                        $scopes = $scopesProperty.Value
                    }
                    if ($scopes -isnot [System.Array]) {
                        [void]$errors.Add("Scoped registry '$registryName' must declare a JSON scopes array.")
                    }
                    foreach ($scopeValue in @($scopes)) {
                        if ($scopeValue -isnot [string]) {
                            [void]$errors.Add("Scoped registry '$registryName' contains a non-string scope.")
                            continue
                        }
                        if (Test-UpvPackageScopeMatch -PackageName $script:UpvTestFrameworkPackageName -Scope ([string]$scopeValue)) {
                            [void]$interceptors.Add([ordered]@{
                                name = $registryName
                                url = $registryUrl
                                scope = [string]$scopeValue
                            })
                        }
                    }
                }
            }
            if ($interceptors.Count -gt 0) {
                [void]$errors.Add('A custom scoped registry can intercept com.unity.test-framework.')
            }
        } catch {
            [void]$errors.Add("Packages/manifest.json provenance could not be parsed: $($_.Exception.Message)")
        }
    }

    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        [void]$errors.Add('Packages/packages-lock.json is required for Test Framework provenance.')
    } else {
        try {
            $lock = Read-UpvJsonFile -Path $lockPath
            $lockDependencies = Get-UpvJsonProperty -InputObject $lock -Name 'dependencies'
            $lockEntry = Get-UpvJsonProperty -InputObject $lockDependencies -Name $script:UpvTestFrameworkPackageName
            if ($null -eq $lockEntry) {
                [void]$errors.Add('packages-lock.json does not contain com.unity.test-framework.')
            } else {
                $lockVersionValue = Get-UpvJsonProperty -InputObject $lockEntry -Name 'version'
                $lockSourceValue = Get-UpvJsonProperty -InputObject $lockEntry -Name 'source'
                $lockUrlValue = Get-UpvJsonProperty -InputObject $lockEntry -Name 'url'
                $result.resolvedVersion = if ($null -eq $lockVersionValue) { $null } else { [string]$lockVersionValue }
                $result.packagesLockSource = if ($null -eq $lockSourceValue) { $null } else { [string]$lockSourceValue }
                $result.packagesLockUrl = if ($null -eq $lockUrlValue) { $null } else { [string]$lockUrlValue }
                if ($lockVersionValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$lockVersionValue)) {
                    [void]$errors.Add('Test Framework packages-lock version is missing or invalid.')
                }
                if ($lockSourceValue -isnot [string]) {
                    [void]$errors.Add('Test Framework packages-lock source is missing or invalid.')
                } elseif ([string]$lockSourceValue -cnotin [string[]]@($AllowedSourceKinds)) {
                    [void]$errors.Add("Test Framework packages-lock source '$lockSourceValue' is not allowed by the selected compatibility contract.")
                } elseif ([string]$lockSourceValue -ceq 'registry') {
                    $result.expectedRegistryOrigin = $officialOrigin
                    if ($lockUrlValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$lockUrlValue)) {
                        [void]$errors.Add('Registry Test Framework packages-lock entry must record its registry URL.')
                    } else {
                        try {
                            $result.registryOrigin = ConvertTo-UpvCanonicalRegistryOrigin -Origin $result.packagesLockUrl
                            $result.registryOriginMatched = $result.registryOrigin -ceq $officialOrigin
                            $result.sourcePolicyMatched = $result.registryOriginMatched
                            if (-not $result.registryOriginMatched) {
                                [void]$errors.Add("Test Framework registry origin '$($result.registryOrigin)' is not the approved Unity registry.")
                            }
                        } catch {
                            [void]$errors.Add("Test Framework registry URL is invalid: $($_.Exception.Message)")
                        }
                    }
                } elseif ([string]$lockSourceValue -ceq 'builtin') {
                    $result.expectedRegistryOrigin = $null
                    $result.registryOriginMatched = $null -eq $lockUrlValue -or [string]::IsNullOrWhiteSpace([string]$lockUrlValue)
                    $result.sourcePolicyMatched = $result.registryOriginMatched
                    if (-not $result.registryOriginMatched) {
                        [void]$errors.Add('Builtin Test Framework packages-lock evidence must not claim a registry URL.')
                    }
                }
                if (
                    -not [string]::IsNullOrWhiteSpace([string]$result.declaredVersion) -and
                    -not [string]::IsNullOrWhiteSpace([string]$result.resolvedVersion) -and
                    $result.declaredVersion -cne $result.resolvedVersion
                ) {
                    [void]$errors.Add('Manifest and packages-lock Test Framework versions do not match exactly.')
                }
                $originEvidence = if ([string]$result.packagesLockSource -ceq 'builtin') {
                    'unity-editor-builtin'
                } elseif ([string]::IsNullOrWhiteSpace([string]$result.registryOrigin)) {
                    [string]$result.packagesLockUrl
                } else {
                    [string]$result.registryOrigin
                }
                [void]$evidence.Add("packages-lock:$($result.packagesLockSource):$($originEvidence):$($result.resolvedVersion)")
            }
        } catch {
            [void]$errors.Add("Packages/packages-lock.json provenance could not be parsed: $($_.Exception.Message)")
        }
    }

    $result.scopedRegistryInterceptors = @($interceptors)
    $result.sourceEvidence = @($evidence)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Computes a deterministic non-reparse package tree over sorted relative paths, lengths, and raw file hashes.
function Get-UpvPackageTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $root = Get-UpvNormalizedPath -Path $PackageRoot
    $extendedRoot = ConvertTo-UpvExtendedLengthPath -Path $root
    if (-not [System.IO.Directory]::Exists($extendedRoot)) {
        throw 'Resolved package root is not a directory.'
    }
    $rootAttributes = [System.IO.File]::GetAttributes($extendedRoot)
    if (($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Resolved package root must not be a reparse point.'
    }

    $files = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([System.StringComparer]::Ordinal)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        $extendedDirectory = ConvertTo-UpvExtendedLengthPath -Path $directory
        foreach ($extendedEntry in [System.IO.Directory]::GetFileSystemEntries($extendedDirectory)) {
            $entryPath = ConvertFrom-UpvExtendedLengthPath -Path $extendedEntry
            $relative = $entryPath.Substring($root.Length + 1).Replace('\', '/')
            $attributes = [System.IO.File]::GetAttributes($extendedEntry)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Resolved package contains a reparse point: $relative"
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $queue.Enqueue($entryPath)
                continue
            }
            $fileInfo = New-Object System.IO.FileInfo($extendedEntry)
            $files.Add($relative, [pscustomobject][ordered]@{
                path = $relative
                length = [long]$fileInfo.Length
                sha256 = Get-UpvPackageFileSha256 -Path $entryPath
            })
        }
    }
    if ($files.Count -eq 0) {
        throw 'Resolved package tree contains no files.'
    }

    $canonicalLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @($files.Values)) {
        $pathLength = $script:UpvIdentityUtf8NoBom.GetByteCount([string]$file.path)
        $canonicalLines.Add("F|$pathLength|$($file.path)|$($file.length)|$($file.sha256)")
    }
    return [pscustomobject][ordered]@{
        root = $root
        fileCount = [int]$files.Count
        files = [object[]]@($files.Values)
        canonicalization = $script:UpvPackageTreeCanonicalization
        treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, $canonicalLines.ToArray()))
    }
}

# Requires two consecutive identical package-tree snapshots with bounded retries after Unity teardown.
function Get-UpvStablePackageTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter()][ValidateRange(2, 20)][int]$MaxAttempts = 6,
        [Parameter()][ValidateRange(0, 5000)][int]$RetryDelayMilliseconds = 250
    )

    $previous = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $current = Get-UpvPackageTreeSnapshot -PackageRoot $PackageRoot
            if (
                $null -ne $previous -and
                $previous.fileCount -eq $current.fileCount -and
                [string]$previous.treeSha256 -ceq [string]$current.treeSha256
            ) {
                $current | Add-Member -NotePropertyName snapshotAttempts -NotePropertyValue $attempt
                return $current
            }
            $previous = $current
            $lastError = $null
        } catch {
            $previous = $null
            $lastError = $_.Exception
        }
        if ($attempt -lt $MaxAttempts -and $RetryDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
    if ($null -ne $lastError) {
        throw "Resolved package tree did not stabilize: $($lastError.Message)"
    }
    throw "Resolved package tree did not produce two identical snapshots in $MaxAttempts attempts."
}

# Locates exactly one resolved Test Framework package and matches its metadata and tree hash to the approved identity.
function Get-UpvResolvedTestFrameworkIdentityAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceKind,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$ExpectedRegistryOrigin,
        [Parameter(Mandatory = $true)][string]$ExpectedTreeSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedCanonicalization
    )

    $root = Get-UpvNormalizedPath -Path $ProjectRoot
    $cacheRoot = Join-Path -Path $root -ChildPath 'Library\PackageCache'
    $result = [ordered]@{
        packageName = $script:UpvTestFrameworkPackageName
        declaredVersion = [string]$Provenance.declaredVersion
        resolvedVersion = $null
        packagesLockSource = [string]$Provenance.packagesLockSource
        registryOrigin = if ($null -eq $Provenance.registryOrigin) { $null } else { [string]$Provenance.registryOrigin }
        expectedSourceKind = $ExpectedSourceKind
        expectedRegistryOrigin = if ([string]::IsNullOrWhiteSpace($ExpectedRegistryOrigin)) { $null } else { $ExpectedRegistryOrigin }
        sourceEvidence = @($Provenance.sourceEvidence)
        packageCacheRoot = $cacheRoot
        resolvedPackagePath = $null
        candidateCount = 0
        fileCount = 0
        snapshotAttempts = 0
        hashCanonicalization = $ExpectedCanonicalization
        treeSha256 = $null
        expectedTreeSha256 = $ExpectedTreeSha256
        identityMatched = $false
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    $candidates = New-Object System.Collections.ArrayList

    try {
        if ($ExpectedSourceKind -notin @('registry', 'builtin')) {
            throw "Approved Test Framework source kind '$ExpectedSourceKind' is unsupported."
        }
        if ($ExpectedCanonicalization -cne $script:UpvPackageTreeCanonicalization) {
            throw "Unsupported package tree canonicalization '$ExpectedCanonicalization'."
        }
        if ($ExpectedTreeSha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Expected Test Framework package tree SHA-256 is invalid.'
        }
        if (-not [bool]$Provenance.accepted) {
            throw 'Test Framework preflight provenance was not accepted.'
        }
        if ([string]$Provenance.packagesLockSource -cne $ExpectedSourceKind) {
            throw 'Resolved Test Framework source kind differs from the approved source kind.'
        }
        if ($ExpectedSourceKind -ceq 'registry') {
            if ([string]::IsNullOrWhiteSpace($ExpectedRegistryOrigin)) {
                throw 'Approved registry Test Framework identity is missing its registry origin.'
            }
            $canonicalExpectedOrigin = ConvertTo-UpvCanonicalRegistryOrigin -Origin $ExpectedRegistryOrigin
            if ([string]$Provenance.registryOrigin -cne $canonicalExpectedOrigin) {
                throw 'Resolved Test Framework registry origin differs from the approved registry origin.'
            }
        } elseif (
            -not [string]::IsNullOrWhiteSpace($ExpectedRegistryOrigin) -or
            $null -ne $Provenance.registryOrigin -or
            -not [string]::IsNullOrWhiteSpace([string]$Provenance.packagesLockUrl)
        ) {
            throw 'Builtin Test Framework identity must not carry registry-origin evidence.'
        }
        if ([string]$Provenance.resolvedVersion -cne $ExpectedVersion) {
            throw 'Preflight Test Framework version differs from the approved version.'
        }
        if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
            throw 'The isolated project has no Library/PackageCache directory.'
        }
        $cacheReparse = Get-UpvReparsePointOnPath -Path $cacheRoot
        if ($null -ne $cacheReparse) {
            throw "Package cache traverses reparse point $cacheReparse."
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $cacheRoot -Directory -Force -ErrorAction Stop)) {
            $packageJsonPath = Join-Path -Path $directory.FullName -ChildPath 'package.json'
            if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
                continue
            }
            try {
                $packageJson = Read-UpvJsonFile -Path $packageJsonPath
                $packageName = Get-UpvJsonProperty -InputObject $packageJson -Name 'name'
                if ($packageName -is [string] -and [string]$packageName -ceq $script:UpvTestFrameworkPackageName) {
                    [void]$candidates.Add([pscustomobject][ordered]@{
                        path = $directory.FullName
                        packageJson = $packageJson
                    })
                }
            } catch {
                if ($directory.Name.StartsWith($script:UpvTestFrameworkPackageName + '@', [System.StringComparison]::Ordinal)) {
                    throw "Test Framework package.json is invalid at $($directory.FullName): $($_.Exception.Message)"
                }
            }
        }
        $result.candidateCount = $candidates.Count
        if ($candidates.Count -ne 1) {
            throw "Exactly one resolved com.unity.test-framework package is required; found $($candidates.Count)."
        }

        $candidate = $candidates[0]
        $candidatePath = Get-UpvNormalizedPath -Path $candidate.path
        if (-not (Test-UpvPathWithinRoot -Path $candidatePath -Root $cacheRoot)) {
            throw 'Resolved Test Framework package escapes Library/PackageCache.'
        }
        $candidateReparse = Get-UpvReparsePointOnPath -Path $candidatePath
        if ($null -ne $candidateReparse) {
            throw "Resolved Test Framework package traverses reparse point $candidateReparse."
        }
        $result.resolvedPackagePath = $candidatePath
        $packageNameValue = Get-UpvJsonProperty -InputObject $candidate.packageJson -Name 'name'
        $packageVersionValue = Get-UpvJsonProperty -InputObject $candidate.packageJson -Name 'version'
        if ($packageNameValue -isnot [string] -or [string]$packageNameValue -cne $script:UpvTestFrameworkPackageName) {
            throw 'Resolved package.json name does not match com.unity.test-framework.'
        }
        if ($packageVersionValue -isnot [string]) {
            throw 'Resolved Test Framework package.json version is missing.'
        }
        $result.resolvedVersion = [string]$packageVersionValue
        if ($result.resolvedVersion -cne $ExpectedVersion) {
            throw "Resolved Test Framework package version '$($result.resolvedVersion)' does not match '$ExpectedVersion'."
        }
        if ($result.declaredVersion -cne $ExpectedVersion) {
            throw 'Declared Test Framework version does not match the approved version.'
        }

        $snapshot = Get-UpvStablePackageTreeSnapshot -PackageRoot $candidatePath
        $result.fileCount = $snapshot.fileCount
        $result.snapshotAttempts = $snapshot.snapshotAttempts
        $result.hashCanonicalization = $snapshot.canonicalization
        $result.treeSha256 = $snapshot.treeSha256
        $result.identityMatched = (
            $snapshot.canonicalization -ceq $ExpectedCanonicalization -and
            $snapshot.treeSha256 -ceq $ExpectedTreeSha256
        )
        if (-not $result.identityMatched) {
            throw "Resolved Test Framework package tree SHA-256 '$($snapshot.treeSha256)' does not match the approved identity."
        }
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }

    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0 -and $result.identityMatched
    return [pscustomobject]$result
}
