Set-StrictMode -Version Latest

$script:UpvUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UpvPathComparison = if ($env:OS -eq "Windows_NT") {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Returns a normalized absolute path without resolving link targets.
function Get-UpvNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path must not be empty."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($root, $script:UpvPathComparison)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

# Tests whether one path is equal to or below a trusted root.
function Test-UpvPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-UpvNormalizedPath -Path $Path
    $normalizedRoot = Get-UpvNormalizedPath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, $script:UpvPathComparison)) {
        return $true
    }
    return $normalizedPath.StartsWith(
        $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
        $script:UpvPathComparison
    )
}

# Returns the first existing reparse point on a path or an existing ancestor.
function Get-UpvReparsePointOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = Get-UpvNormalizedPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $entry.FullName
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
        } catch [System.IO.FileNotFoundException] {
        } catch [System.IO.DirectoryNotFoundException] {
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName.Equals($current, $script:UpvPathComparison)) {
            break
        }
        $current = $parent.FullName
    }
    return $null
}

# Returns the reserved isolated scenario path and rejects a pre-existing collision.
function Get-UpvReservedScenarioOverlayAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectCopyPath
    )

    $root = Get-UpvNormalizedPath -Path $ProjectCopyPath
    $reservedPath = Join-Path -Path $root -ChildPath 'Assets\__UnityPlayVerification'
    $exists = Test-Path -LiteralPath $reservedPath
    return [pscustomobject][ordered]@{
        path = $reservedPath
        collision = [bool]$exists
        accepted = -not [bool]$exists
        error = if ($exists) { 'The isolated base project already contains the reserved Assets/__UnityPlayVerification path.' } else { $null }
    }
}

# Calculates a lowercase SHA-256 digest for one file.
function Get-UpvFileSha256 {
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

# Calculates a lowercase SHA-256 digest for UTF-8 text.
function Get-UpvTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:UpvUtf8NoBom.GetBytes($Text)
        $digest = $algorithm.ComputeHash($bytes)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
    }
}

# Reads a UTF-8 JSON document without permitting an empty file.
function Read-UpvJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "JSON file is empty: $Path"
    }
    return ConvertFrom-Json -InputObject $text -ErrorAction Stop
}

# Returns a named JSON property value or null when the property is absent.
function Get-UpvJsonProperty {
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

# Verifies that one parsed JSON object contains exactly the declared property names.
function Test-UpvExactJsonProperties {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredNames,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $errors = New-Object System.Collections.ArrayList
    if ($null -eq $InputObject -or $InputObject -isnot [System.Management.Automation.PSCustomObject]) {
        [void]$errors.Add("$Context must be a JSON object.")
        return [pscustomobject][ordered]@{ accepted = $false; errors = @($errors) }
    }

    $actualNames = @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($requiredName in $RequiredNames) {
        if ($actualNames -cnotcontains $requiredName) {
            [void]$errors.Add("$Context is missing required property '$requiredName'.")
        }
    }
    foreach ($actualName in $actualNames) {
        if ($RequiredNames -cnotcontains $actualName) {
            [void]$errors.Add("$Context contains unsupported property '$actualName'.")
        }
    }
    return [pscustomobject][ordered]@{
        accepted = $errors.Count -eq 0
        errors = @($errors)
    }
}

# Validates a user-provided Unity Test Framework selector as one opaque argument.
function Test-UpvSelectorValue {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject][ordered]@{ accepted = $true; error = $null }
    }
    if ($Value.IndexOf([char]0) -ge 0 -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        return [pscustomobject][ordered]@{
            accepted = $false
            error = "$Name must not contain null, carriage-return, or line-feed characters."
        }
    }
    if ($Value.Length -gt 4096) {
        return [pscustomobject][ordered]@{
            accepted = $false
            error = "$Name must not exceed 4096 characters."
        }
    }
    return [pscustomobject][ordered]@{ accepted = $true; error = $null }
}

# Parses one Windows process command line into tokens for exact project-path comparison.
function ConvertFrom-UpvWindowsCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $length = $CommandLine.Length
    $index = 0
    while ($index -lt $length) {
        while ($index -lt $length -and [char]::IsWhiteSpace($CommandLine[$index])) { $index++ }
        if ($index -ge $length) { break }

        $builder = New-Object System.Text.StringBuilder
        $insideQuotes = $false
        while ($index -lt $length) {
            $backslashCount = 0
            while ($index -lt $length -and $CommandLine[$index] -eq '\') {
                $backslashCount++
                $index++
            }
            if ($index -lt $length -and $CommandLine[$index] -eq '"') {
                [void]$builder.Append(('\' * [int]($backslashCount / 2)))
                if (($backslashCount % 2) -eq 0) {
                    $insideQuotes = -not $insideQuotes
                } else {
                    [void]$builder.Append('"')
                }
                $index++
                continue
            }
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * $backslashCount)) }
            if ($index -ge $length -or (-not $insideQuotes -and [char]::IsWhiteSpace($CommandLine[$index]))) { break }
            [void]$builder.Append($CommandLine[$index])
            $index++
        }
        $arguments.Add($builder.ToString())
    }
    return [string[]]$arguments.ToArray()
}

# Builds the closed Unity Test Framework argument contract for project or scenario mode.
function New-UpvUnityTestArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$TestResultsPath,
        [Parameter(Mandatory = $true)][string]$EditorLogPath,
        [Parameter(Mandatory = $true)][string]$UpmLogPath,
        [Parameter(Mandatory = $true)][ValidateSet('PROJECT_PLAYMODE_TESTS', 'SCENARIO_OVERLAY')][string]$Mode,
        [Parameter()][AllowNull()][string]$TestFilter,
        [Parameter()][AllowNull()][string]$TestCategory,
        [Parameter()][AllowNull()][string]$AssemblyNames,
        [Parameter()][AllowNull()][string]$ScenarioId,
        [Parameter()][AllowNull()][string]$ScenarioResultPath,
        [Parameter()][AllowNull()][string]$ScreenshotRoot,
        [Parameter()][int]$ScenarioTimeoutSeconds = 0
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @(
        '-batchmode',
        '-forgetProjectPath',
        '-runTests',
        '-projectPath', $ProjectPath,
        '-testPlatform', 'PlayMode',
        '-testResults', $TestResultsPath,
        '-logFile', $EditorLogPath,
        '-upmLogFile', $UpmLogPath
    )) {
        $arguments.Add([string]$argument)
    }

    if ($Mode -eq 'SCENARIO_OVERLAY') {
        foreach ($required in @(
            [pscustomobject]@{ name = 'TestFilter'; value = $TestFilter },
            [pscustomobject]@{ name = 'ScenarioId'; value = $ScenarioId },
            [pscustomobject]@{ name = 'ScenarioResultPath'; value = $ScenarioResultPath },
            [pscustomobject]@{ name = 'ScreenshotRoot'; value = $ScreenshotRoot }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.value)) {
                throw "$($required.name) is required in scenario mode."
            }
        }
        if ($ScenarioTimeoutSeconds -le 0) {
            throw 'ScenarioTimeoutSeconds must be positive in scenario mode.'
        }
        foreach ($argument in @(
            '-testFilter', $TestFilter,
            '-upvScenarioId', $ScenarioId,
            '-upvScenarioResultPath', $ScenarioResultPath,
            '-upvScreenshotRoot', $ScreenshotRoot,
            '-upvScenarioTimeoutSeconds', $ScenarioTimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        )) {
            $arguments.Add([string]$argument)
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($TestFilter)) { $arguments.Add('-testFilter'); $arguments.Add($TestFilter) }
        if (-not [string]::IsNullOrWhiteSpace($TestCategory)) { $arguments.Add('-testCategory'); $arguments.Add($TestCategory) }
        if (-not [string]::IsNullOrWhiteSpace($AssemblyNames)) { $arguments.Add('-assemblyNames'); $arguments.Add($AssemblyNames) }
    }
    return [string[]]$arguments.ToArray()
}

# Reads the resolved Unity Test Framework package version from packages-lock.json.
function Get-UpvTestFrameworkVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $lockPath = Join-Path -Path $ProjectRoot -ChildPath 'Packages\packages-lock.json'
    $result = [ordered]@{
        status = 'NOT_FOUND'
        sourcePath = $lockPath
        version = $null
        packageSource = $null
        error = $null
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        $result.error = 'Packages/packages-lock.json is required for an approved Test Framework pairing.'
        return [pscustomobject]$result
    }

    try {
        $lock = Read-UpvJsonFile -Path $lockPath
        $dependencies = Get-UpvJsonProperty -InputObject $lock -Name 'dependencies'
        $package = Get-UpvJsonProperty -InputObject $dependencies -Name 'com.unity.test-framework'
        $version = [string](Get-UpvJsonProperty -InputObject $package -Name 'version')
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw 'The resolved com.unity.test-framework entry is missing its version.'
        }
        $result.status = 'RESOLVED'
        $result.version = $version
        $result.packageSource = [string](Get-UpvJsonProperty -InputObject $package -Name 'source')
    } catch {
        $result.status = 'INVALID'
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Matches one exact Unity and Test Framework pair against the release compatibility registry.
function Get-UpvCompatibilityAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,

        [Parameter(Mandatory = $true)]
        [string]$UnityVersion,

        [Parameter(Mandatory = $true)]
        [string]$TestFrameworkVersion
    )

    $result = [ordered]@{
        registryPath = Get-UpvNormalizedPath -Path $RegistryPath
        registrySchemaVersion = $null
        unityVersion = $UnityVersion
        testFrameworkVersion = $TestFrameworkVersion
        entryFound = $false
        entryStatus = $null
        allowedSourceKind = $null
        registryOrigin = $null
        unityExecutableSha256 = $null
        packageTreeSha256 = $null
        hashCanonicalization = $null
        evidencePath = $null
        approved = $false
        error = $null
    }
    try {
        $registry = Read-UpvJsonFile -Path $RegistryPath
        $rootContract = Test-UpvExactJsonProperties `
            -InputObject $registry `
            -RequiredNames @('schemaVersion', 'entries') `
            -Context 'Compatibility registry'
        if (-not $rootContract.accepted) {
            throw ([string]::Join(' ', [string[]]@($rootContract.errors)))
        }
        $result.registrySchemaVersion = [string](Get-UpvJsonProperty -InputObject $registry -Name 'schemaVersion')
        if ($result.registrySchemaVersion -ne '1.2.0') {
            throw "Compatibility registry schemaVersion must be 1.2.0."
        }
        $entries = $registry.PSObject.Properties['entries'].Value
        if ($entries -isnot [System.Array]) {
            throw 'Compatibility registry entries must be a JSON array.'
        }
        $seenPairs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($entry in @($entries)) {
            $entryContract = Test-UpvExactJsonProperties `
                -InputObject $entry `
                -RequiredNames @(
                    'unityVersion', 'testFrameworkVersion', 'allowedSourceKind', 'registryOrigin',
                    'unityExecutableSha256', 'packageTreeSha256', 'hashCanonicalization', 'status', 'evidencePath'
                ) `
                -Context 'Compatibility registry entry'
            if (-not $entryContract.accepted) {
                throw ([string]::Join(' ', [string[]]@($entryContract.errors)))
            }
            $entryUnityVersion = Get-UpvJsonProperty -InputObject $entry -Name 'unityVersion'
            $entryFrameworkVersion = Get-UpvJsonProperty -InputObject $entry -Name 'testFrameworkVersion'
            $entrySourceKind = Get-UpvJsonProperty -InputObject $entry -Name 'allowedSourceKind'
            $entryRegistryOrigin = Get-UpvJsonProperty -InputObject $entry -Name 'registryOrigin'
            $entryUnityExecutableSha256 = Get-UpvJsonProperty -InputObject $entry -Name 'unityExecutableSha256'
            $entryTreeSha256 = Get-UpvJsonProperty -InputObject $entry -Name 'packageTreeSha256'
            $entryCanonicalization = Get-UpvJsonProperty -InputObject $entry -Name 'hashCanonicalization'
            $entryStatus = Get-UpvJsonProperty -InputObject $entry -Name 'status'
            $entryEvidencePath = Get-UpvJsonProperty -InputObject $entry -Name 'evidencePath'
            if ($entryUnityVersion -isnot [string] -or [string]$entryUnityVersion -notmatch '^\d+\.\d+\.\d+[abfp]\d+$') {
                throw 'Compatibility registry entry has an invalid Unity version.'
            }
            if ($entryFrameworkVersion -isnot [string] -or [string]$entryFrameworkVersion -notmatch '^\d+\.\d+\.\d+(?:[-+].+)?$') {
                throw 'Compatibility registry entry has an invalid Test Framework version.'
            }
            if ($entrySourceKind -isnot [string] -or [string]$entrySourceKind -notin @('registry', 'builtin')) {
                throw 'Compatibility registry entry has an unsupported Test Framework source kind.'
            }
            if ([string]$entrySourceKind -ceq 'registry') {
                if ($entryRegistryOrigin -isnot [string] -or [string]$entryRegistryOrigin -cne 'https://packages.unity.com') {
                    throw 'Registry compatibility entries must use the approved Unity registry origin.'
                }
            } elseif ($null -ne $entryRegistryOrigin) {
                throw 'Builtin compatibility entries must record a null registry origin.'
            }
            if ($entryUnityExecutableSha256 -isnot [string] -or [string]$entryUnityExecutableSha256 -notmatch '^[0-9a-f]{64}$') {
                throw 'Compatibility registry entry has an invalid Unity executable SHA-256.'
            }
            if ($entryTreeSha256 -isnot [string] -or [string]$entryTreeSha256 -notmatch '^[0-9a-f]{64}$') {
                throw 'Compatibility registry entry has an invalid package tree SHA-256.'
            }
            if (
                $entryCanonicalization -isnot [string] -or
                [string]$entryCanonicalization -cne 'upv-package-tree-relative-path-length-sha256-lf-v1'
            ) {
                throw 'Compatibility registry entry has an unsupported package hash canonicalization.'
            }
            if ($entryStatus -isnot [string] -or [string]$entryStatus -notin @('CANDIDATE', 'APPROVED', 'RETIRED')) {
                throw 'Compatibility registry entry has an invalid status.'
            }
            if ($entryEvidencePath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entryEvidencePath)) {
                throw 'Compatibility registry entry has an invalid evidence path.'
            }
            $pairKey = [string]$entryUnityVersion + [char]0 + [string]$entryFrameworkVersion
            if (-not $seenPairs.Add($pairKey)) {
                throw 'Compatibility registry contains a duplicate exact version pair.'
            }
        }
        $matches = @(
            @($entries) |
                Where-Object {
                    [string](Get-UpvJsonProperty -InputObject $_ -Name 'unityVersion') -ceq $UnityVersion -and
                    [string](Get-UpvJsonProperty -InputObject $_ -Name 'testFrameworkVersion') -ceq $TestFrameworkVersion
                }
        )
        if ($matches.Count -eq 1) {
            $result.entryFound = $true
            $result.entryStatus = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'status')
            $result.allowedSourceKind = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'allowedSourceKind')
            $matchedRegistryOrigin = Get-UpvJsonProperty -InputObject $matches[0] -Name 'registryOrigin'
            $result.registryOrigin = if ($null -eq $matchedRegistryOrigin) { $null } else { [string]$matchedRegistryOrigin }
            $result.unityExecutableSha256 = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'unityExecutableSha256')
            $result.packageTreeSha256 = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'packageTreeSha256')
            $result.hashCanonicalization = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'hashCanonicalization')
            $result.evidencePath = [string](Get-UpvJsonProperty -InputObject $matches[0] -Name 'evidencePath')
            $result.approved = $result.entryStatus -ceq 'APPROVED'
        }
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Reads the first integer-valued XML attribute from a declared name list.
function Get-UpvXmlIntegerAttribute {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Element,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter()]
        [int]$DefaultValue = 0
    )

    foreach ($name in $Names) {
        if ($Element.HasAttribute($name)) {
            $parsed = 0
            if ([int]::TryParse($Element.GetAttribute($name), [ref]$parsed)) {
                return $parsed
            }
        }
    }
    return $DefaultValue
}

# Reads the first invariant floating-point XML attribute from a declared name list.
function Get-UpvXmlDoubleAttribute {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Element,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Element.HasAttribute($name)) {
            $parsed = 0.0
            if ([double]::TryParse(
                $Element.GetAttribute($name),
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )) {
                return $parsed
            }
        }
    }
    return $null
}

# Parses NUnit 3 or legacy NUnit 2 XML into one strict PlayMode result summary.
function Get-UpvNUnitAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $analysis = [ordered]@{
        exists = $false
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
        classification = 'NOT_ANALYZED'
        error = $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $analysis.error = 'NUnit result XML was not created.'
        return [pscustomobject]$analysis
    }

    try {
        $analysis.exists = $true
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $analysis.byteLength = [long]$item.Length
        $analysis.sha256 = Get-UpvFileSha256 -Path $Path
        [xml]$document = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $root = $document.DocumentElement
        if ($null -eq $root) {
            throw 'NUnit result XML has no document element.'
        }

        if ($root.LocalName -eq 'test-run') {
            $analysis.format = 'NUNIT3'
            $analysis.rootResult = $root.GetAttribute('result')
            $analysis.total = Get-UpvXmlIntegerAttribute -Element $root -Names @('total', 'testcasecount')
            $analysis.passed = Get-UpvXmlIntegerAttribute -Element $root -Names @('passed')
            $analysis.failed = Get-UpvXmlIntegerAttribute -Element $root -Names @('failed')
            $analysis.skipped = Get-UpvXmlIntegerAttribute -Element $root -Names @('skipped')
            $analysis.inconclusive = Get-UpvXmlIntegerAttribute -Element $root -Names @('inconclusive')
            $analysis.assertions = Get-UpvXmlIntegerAttribute -Element $root -Names @('asserts')
            $analysis.durationSeconds = Get-UpvXmlDoubleAttribute -Element $root -Names @('duration')
        } elseif ($root.LocalName -eq 'test-results') {
            $analysis.format = 'NUNIT2'
            $analysis.rootResult = if ((Get-UpvXmlIntegerAttribute -Element $root -Names @('failures')) -gt 0) { 'Failed' } else { 'Passed' }
            $analysis.total = Get-UpvXmlIntegerAttribute -Element $root -Names @('total')
            $analysis.failed = Get-UpvXmlIntegerAttribute -Element $root -Names @('failures', 'errors')
            $analysis.inconclusive = Get-UpvXmlIntegerAttribute -Element $root -Names @('inconclusive')
            $analysis.skipped = (
                (Get-UpvXmlIntegerAttribute -Element $root -Names @('not-run')) +
                (Get-UpvXmlIntegerAttribute -Element $root -Names @('ignored')) +
                (Get-UpvXmlIntegerAttribute -Element $root -Names @('skipped')) +
                (Get-UpvXmlIntegerAttribute -Element $root -Names @('invalid'))
            )
            $analysis.passed = [Math]::Max(0, $analysis.total - $analysis.failed - $analysis.skipped - $analysis.inconclusive)
            $analysis.durationSeconds = Get-UpvXmlDoubleAttribute -Element $root -Names @('time')
        } else {
            throw "Unsupported NUnit XML root element '$($root.LocalName)'."
        }

        $analysis.executed = $analysis.passed + $analysis.failed + $analysis.inconclusive
        $failureDetails = New-Object System.Collections.ArrayList
        $failedNodes = @($document.SelectNodes("//*[local-name()='test-case' and (@result='Failed' or @result='Error' or @success='False')]") )
        foreach ($node in $failedNodes | Select-Object -First 200) {
            $messageNode = $node.SelectSingleNode("./*[local-name()='failure']/*[local-name()='message']")
            $stackNode = $node.SelectSingleNode("./*[local-name()='failure']/*[local-name()='stack-trace']")
            [void]$failureDetails.Add([ordered]@{
                name = [string]$node.GetAttribute('fullname')
                result = [string]$node.GetAttribute('result')
                message = if ($null -ne $messageNode) { [string]$messageNode.InnerText } else { $null }
                stackTrace = if ($null -ne $stackNode) { [string]$stackNode.InnerText } else { $null }
            })
        }
        $analysis.failureDetails = @($failureDetails)

        if ($analysis.total -le 0) {
            $analysis.classification = 'ZERO_TESTS'
        } elseif ($analysis.failed -gt 0 -or $analysis.rootResult -match '^(Failed|Error)$') {
            $analysis.classification = 'FAILED'
        } elseif ($analysis.skipped -gt 0 -or $analysis.inconclusive -gt 0 -or $analysis.executed -lt $analysis.total) {
            $analysis.classification = 'INCOMPLETE'
        } elseif ($analysis.passed -eq $analysis.total -and $analysis.rootResult -match '^(Passed|Success)$') {
            $analysis.classification = 'PASSED'
        } else {
            $analysis.classification = 'INCONCLUSIVE'
        }
    } catch {
        $analysis.classification = 'INVALID'
        $analysis.error = $_.Exception.Message
    }
    return [pscustomobject]$analysis
}

# Extracts version, project, batch mode, compiler, package, crash, and test-run evidence from Editor.log.
function Get-UpvEditorLogAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedUnityVersion,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedProjectPath
    )

    $analysis = [ordered]@{
        exists = $false
        byteLength = $null
        sha256 = $null
        detectedUnityVersion = $null
        versionMatched = $false
        batchModeObserved = $false
        isolatedProjectPathObserved = $false
        testRunnerObserved = $false
        compilerErrors = @()
        compilerErrorCount = 0
        failureMarkers = @()
        missingRequiredMarkers = @()
        classification = 'NOT_ANALYZED'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$analysis
    }

    $analysis.exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $analysis.byteLength = [long]$item.Length
    $analysis.sha256 = Get-UpvFileSha256 -Path $Path
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $lines = @([regex]::Split($text, "\r?\n"))

    $versionMatch = [regex]::Match($text, "(?m)^Built from .+? Version is '(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    if (-not $versionMatch.Success) {
        $versionMatch = [regex]::Match($text, "(?m)^Initialize engine version:\s*(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    }
    if ($versionMatch.Success) {
        $analysis.detectedUnityVersion = $versionMatch.Groups['version'].Value
        $analysis.versionMatched = $analysis.detectedUnityVersion -ceq $ExpectedUnityVersion
    }
    $analysis.batchModeObserved = [regex]::IsMatch($text, "(?m)^BatchMode:\s*1\b")
    $analysis.testRunnerObserved = [regex]::IsMatch($text, "(?im)(runTests|test run|TestRunner|Test Framework)")

    foreach ($projectPathMatch in [regex]::Matches($text, "(?m)^Successfully changed project path to:\s*(?<path>.+?)\s*$")) {
        try {
            $observed = Get-UpvNormalizedPath -Path $projectPathMatch.Groups['path'].Value
            $expected = Get-UpvNormalizedPath -Path $ExpectedProjectPath
            if ($observed.Equals($expected, $script:UpvPathComparison)) {
                $analysis.isolatedProjectPathObserved = $true
                break
            }
        } catch {
        }
    }

    $compilerErrors = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([regex]::IsMatch($line, "\berror\s+CS\d{4}\s*:", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $analysis.compilerErrorCount++
            if ($compilerErrors.Count -lt 200) {
                [void]$compilerErrors.Add($line.Trim())
            }
        }
    }
    $analysis.compilerErrors = @($compilerErrors)

    $definitions = @(
        [pscustomobject]@{ code = 'COMPILER_ERROR'; pattern = '\berror\s+CS\d{4}\s*:' },
        [pscustomobject]@{ code = 'SCRIPTS_HAVE_COMPILER_ERRORS'; pattern = 'Scripts have compiler errors' },
        [pscustomobject]@{ code = 'COMPILATION_FAILED'; pattern = '(?:Compilation failed|Failed to compile)' },
        [pscustomobject]@{ code = 'BATCHMODE_ABORTED'; pattern = 'Aborting batchmode due to failure' },
        [pscustomobject]@{ code = 'FATAL_ERROR'; pattern = 'Fatal Error!' },
        [pscustomobject]@{ code = 'CRASH'; pattern = '^Crash!!!\s*$' },
        [pscustomobject]@{ code = 'NONZERO_RETURN_CODE'; pattern = 'Application will terminate with return code [1-9]\d*' },
        [pscustomobject]@{ code = 'PACKAGE_RESOLUTION_FAILED'; pattern = '(?:An error occurred while resolving packages|Package resolution failed)' }
    )
    $failures = New-Object System.Collections.ArrayList
    foreach ($definition in $definitions) {
        foreach ($line in $lines) {
            if ([regex]::IsMatch($line, $definition.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                [void]$failures.Add([ordered]@{ code = $definition.code; line = $line.Trim() })
                break
            }
        }
    }
    if ($null -ne $analysis.detectedUnityVersion -and -not $analysis.versionMatched) {
        [void]$failures.Add([ordered]@{
            code = 'UNITY_LOG_VERSION_MISMATCH'
            line = "Editor.log identifies Unity $($analysis.detectedUnityVersion)."
        })
    }
    $analysis.failureMarkers = @($failures)

    $missing = New-Object System.Collections.ArrayList
    if (-not $analysis.versionMatched) { [void]$missing.Add('unityVersion') }
    if (-not $analysis.batchModeObserved) { [void]$missing.Add('batchMode') }
    if (-not $analysis.isolatedProjectPathObserved) { [void]$missing.Add('isolatedProjectPath') }
    $analysis.missingRequiredMarkers = @($missing)
    if ($analysis.failureMarkers.Count -gt 0) {
        $analysis.classification = 'FAILURE'
    } elseif ($analysis.missingRequiredMarkers.Count -gt 0) {
        $analysis.classification = 'INCONCLUSIVE'
    } else {
        $analysis.classification = 'SAFE'
    }
    return [pscustomobject]$analysis
}

# Maps Editor.log, NUnit, and exit evidence to the three base verification scopes without final-status promotion.
function Get-UpvBaseVerificationScopeAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$EditorLog,
        [Parameter(Mandatory = $true)][object]$NUnit,
        [Parameter()][AllowNull()][object]$ExitCode
    )

    $result = [ordered]@{
        scriptCompilation = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'Compilation evidence is incomplete.' }
        editorPlayMode = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'Editor PlayMode execution is incomplete.' }
        playModeTests = [ordered]@{ status = 'NOT_VERIFIED'; reason = 'PlayMode test evidence is incomplete.' }
        nunitWellFormed = $false
        evidenceConflict = $false
    }
    $wellFormedClassifications = @('PASSED', 'FAILED', 'ZERO_TESTS', 'INCOMPLETE')
    $result.nunitWellFormed = [string]$NUnit.classification -in $wellFormedClassifications

    if ([string]$EditorLog.classification -eq 'FAILURE') {
        $result.scriptCompilation.status = 'VERIFIED_FAILURE'
        $result.scriptCompilation.reason = 'Editor.log contains concrete compilation, package, fatal, crash, or nonzero-exit evidence.'
    } elseif ([string]$EditorLog.classification -eq 'SAFE' -and $result.nunitWellFormed) {
        $result.scriptCompilation.status = 'VERIFIED_SUCCESS'
        $result.scriptCompilation.reason = 'Editor.log is safe and Unity emitted a well-formed test result after project compilation.'
    } elseif ([string]$EditorLog.classification -in @('SAFE', 'INCONCLUSIVE', 'NOT_ANALYZED')) {
        $result.scriptCompilation.status = 'BLOCKED'
        $result.scriptCompilation.reason = 'Compilation evidence requires both a safe Editor.log and a well-formed NUnit result.'
    }

    if ([long]$NUnit.total -gt 0 -and [string]$NUnit.classification -in @('PASSED', 'FAILED')) {
        $result.editorPlayMode.status = 'VERIFIED_SUCCESS'
        $result.editorPlayMode.reason = 'Unity Test Framework produced an executed Editor PlayMode result.'
    } elseif ([string]$NUnit.classification -in @('ZERO_TESTS', 'INCOMPLETE', 'INVALID', 'NOT_ANALYZED')) {
        $result.editorPlayMode.status = 'BLOCKED'
        $result.editorPlayMode.reason = 'Editor PlayMode execution is missing, empty, skipped, inconclusive, or malformed.'
    }

    if ([string]$NUnit.classification -eq 'FAILED') {
        $result.playModeTests.status = 'VERIFIED_FAILURE'
        $result.playModeTests.reason = "$($NUnit.failed) selected PlayMode test(s) failed."
    } elseif (
        [string]$NUnit.classification -eq 'PASSED' -and
        [string]$EditorLog.classification -eq 'SAFE' -and
        $null -ne $ExitCode -and [long]$ExitCode -eq 0
    ) {
        $result.playModeTests.status = 'VERIFIED_SUCCESS'
        $result.playModeTests.reason = "All $($NUnit.total) selected Editor PlayMode tests passed with complete log and exit evidence."
    } elseif ([string]$NUnit.classification -in @('ZERO_TESTS', 'INCOMPLETE', 'INVALID', 'NOT_ANALYZED')) {
        $result.playModeTests.status = 'BLOCKED'
        $result.playModeTests.reason = 'PlayMode test evidence is missing, empty, skipped, inconclusive, or malformed.'
    } elseif ([string]$NUnit.classification -eq 'PASSED') {
        $result.playModeTests.status = 'BLOCKED'
        $result.playModeTests.reason = 'A passed NUnit result conflicts with Editor.log or process-exit evidence.'
    }
    $result.evidenceConflict = (
        [string]$NUnit.classification -eq 'PASSED' -and
        ([string]$EditorLog.classification -ne 'SAFE' -or $null -eq $ExitCode -or [long]$ExitCode -ne 0)
    )
    return [pscustomobject]$result
}

# Applies the public final-status precedence to integrity, blockers, failures, compatibility, and required scopes.
function Get-UpvFinalStatusAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalIntegrityStatus,
        [Parameter(Mandatory = $true)][string]$GitIntegrityStatus,
        [Parameter(Mandatory = $true)][int]$BlockerCount,
        [Parameter(Mandatory = $true)][int]$FailureCount,
        [Parameter(Mandatory = $true)][string]$CompatibilityStatus,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RequiredScopeStatuses
    )

    if ($OriginalIntegrityStatus -ceq 'CHANGED' -or $GitIntegrityStatus -ceq 'CHANGED') {
        return 'ORIGINAL_PROJECT_CHANGED'
    }
    if ($BlockerCount -gt 0 -or $CompatibilityStatus -cne 'VERIFIED_SUCCESS') {
        return 'VERIFICATION_BLOCKED'
    }
    if ($FailureCount -gt 0) {
        return 'PLAY_FAILED'
    }
    foreach ($scopeStatus in @($RequiredScopeStatuses)) {
        if ($scopeStatus -cne 'VERIFIED_SUCCESS') {
            return 'VERIFICATION_BLOCKED'
        }
    }
    return 'PLAY_VERIFIED'
}

# Validates one array of unique non-empty manifest identifiers.
function Test-UpvIdentifierArray {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $errors = New-Object System.Collections.ArrayList
    $values = if ($null -eq $Value) { [object[]]@() } else { [object[]]@($Value) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($item in $values) {
        $text = [string]$item
        if ($item -isnot [string] -or $text -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            [void]$errors.Add("$Name entries must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$.")
            continue
        }
        if (-not $seen.Add($text)) {
            [void]$errors.Add("$Name contains duplicate identifier '$text'.")
        }
    }
    return [pscustomobject][ordered]@{
        accepted = $errors.Count -eq 0
        values = [string[]]$values
        errors = @($errors)
    }
}

# Builds a deterministic file inventory without following reparse points.
function Get-UpvBundleFileInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundleRoot
    )

    $root = Get-UpvNormalizedPath -Path $BundleRoot
    $rootEntry = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootEntry.PSIsContainer) {
        throw 'ScenarioBundlePath must be a directory.'
    }
    if (($rootEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Scenario bundle root must not be a reparse point.'
    }

    $files = New-Object System.Collections.ArrayList
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Sort-Object Name)) {
            $relative = $entry.FullName.Substring($root.Length + 1).Replace('\', '/')
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Scenario bundle contains a reparse point: $relative"
            }
            if ($entry.PSIsContainer) {
                $queue.Enqueue($entry.FullName)
                continue
            }
            if (-not (Test-Path -LiteralPath $entry.FullName -PathType Leaf)) {
                throw "Scenario bundle contains an unsupported filesystem entry: $relative"
            }
            $extension = [System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
            if ($extension -notin @('.cs', '.asmdef', '.json')) {
                throw "Scenario bundle file type is not allowed: $relative"
            }
            if ($extension -eq '.json' -and $relative -cne 'manifest.json') {
                throw "Only the root manifest.json may use the .json extension: $relative"
            }
            [void]$files.Add([ordered]@{
                path = $relative
                sourcePath = $entry.FullName
                length = [long]$entry.Length
                sha256 = Get-UpvFileSha256 -Path $entry.FullName
            })
        }
    }
    return @($files | Sort-Object -Property path)
}

# Validates the scenario manifest, source-only bundle, test asmdef, and canonical bundle hash.
function Get-UpvScenarioBundleAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [int]$ProcessTimeoutSeconds
    )

    $result = [ordered]@{
        requested = $true
        bundlePath = $null
        manifestPath = $null
        schemaVersion = $null
        scenarioId = $null
        displayName = $null
        testFilter = $null
        timeoutSeconds = $null
        requiresGraphics = $null
        expectedScenes = @()
        expectedAssertionIds = @()
        screenshotIds = @()
        files = @()
        fileCount = 0
        treeSha256 = $null
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    try {
        $root = Get-UpvNormalizedPath -Path $BundlePath
        $result.bundlePath = $root
        if (Test-UpvPathWithinRoot -Path $root -Root $ProjectRoot) {
            throw 'ScenarioBundlePath must be outside the original Unity project.'
        }
        $reparsePoint = Get-UpvReparsePointOnPath -Path $root
        if ($null -ne $reparsePoint) {
            throw "ScenarioBundlePath traverses reparse point $reparsePoint."
        }
        $manifestPath = Join-Path -Path $root -ChildPath 'manifest.json'
        $result.manifestPath = $manifestPath
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw 'Scenario bundle is missing root manifest.json.'
        }
        $manifest = Read-UpvJsonFile -Path $manifestPath
        $manifestContract = Test-UpvExactJsonProperties `
            -InputObject $manifest `
            -RequiredNames @(
                'schemaVersion', 'scenarioId', 'displayName', 'testFilter', 'timeoutSeconds',
                'requiresGraphics', 'expectedScenes', 'expectedAssertionIds', 'screenshotIds'
            ) `
            -Context 'Scenario manifest'
        foreach ($contractError in @($manifestContract.errors)) {
            [void]$errors.Add($contractError)
        }

        $schemaVersionValue = Get-UpvJsonProperty -InputObject $manifest -Name 'schemaVersion'
        $scenarioIdValue = Get-UpvJsonProperty -InputObject $manifest -Name 'scenarioId'
        $displayNameValue = Get-UpvJsonProperty -InputObject $manifest -Name 'displayName'
        $testFilterValue = Get-UpvJsonProperty -InputObject $manifest -Name 'testFilter'
        $result.schemaVersion = [string]$schemaVersionValue
        $result.scenarioId = [string]$scenarioIdValue
        $result.displayName = [string]$displayNameValue
        $result.testFilter = [string]$testFilterValue
        $result.timeoutSeconds = Get-UpvJsonProperty -InputObject $manifest -Name 'timeoutSeconds'
        $result.requiresGraphics = Get-UpvJsonProperty -InputObject $manifest -Name 'requiresGraphics'
        $expectedScenesValue = $manifest.PSObject.Properties['expectedScenes'].Value
        $expectedAssertionIdsValue = $manifest.PSObject.Properties['expectedAssertionIds'].Value
        $screenshotIdsValue = $manifest.PSObject.Properties['screenshotIds'].Value
        $result.expectedScenes = [object[]]@($expectedScenesValue)

        if ($schemaVersionValue -isnot [string] -or $result.schemaVersion -cne '1.0.0') {
            [void]$errors.Add('Scenario manifest schemaVersion must be 1.0.0.')
        }
        if ($scenarioIdValue -isnot [string] -or $result.scenarioId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            [void]$errors.Add('scenarioId has an invalid identifier format.')
        }
        if ($displayNameValue -isnot [string] -or [string]::IsNullOrWhiteSpace($result.displayName) -or $result.displayName.Length -gt 256) {
            [void]$errors.Add('displayName must contain 1-256 characters.')
        }
        $selector = Test-UpvSelectorValue -Value $result.testFilter -Name 'testFilter'
        if ($testFilterValue -isnot [string] -or -not $selector.accepted -or [string]::IsNullOrWhiteSpace($result.testFilter)) {
            [void]$errors.Add('testFilter must be one non-empty safe selector.')
        }
        if ($result.timeoutSeconds -isnot [int] -and $result.timeoutSeconds -isnot [long]) {
            [void]$errors.Add('timeoutSeconds must be an integer.')
        } elseif ([int]$result.timeoutSeconds -lt 1 -or [int]$result.timeoutSeconds -gt $ProcessTimeoutSeconds) {
            [void]$errors.Add("timeoutSeconds must be between 1 and $ProcessTimeoutSeconds.")
        }
        if ($result.requiresGraphics -isnot [bool]) {
            [void]$errors.Add('requiresGraphics must be a boolean.')
        }

        if ($expectedScenesValue -isnot [System.Array]) {
            [void]$errors.Add('expectedScenes must be a JSON array.')
        }
        $seenScenes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($scene in [object[]]@($expectedScenesValue)) {
            if ($scene -isnot [string] -or $scene -notmatch '^Assets/.+\.unity$' -or $scene -match '(^|/)\.\.(/|$)') {
                [void]$errors.Add("Invalid expected Scene path '$scene'.")
            } elseif (-not $seenScenes.Add([string]$scene)) {
                [void]$errors.Add("expectedScenes contains duplicate path '$scene'.")
            }
        }
        if ($expectedAssertionIdsValue -isnot [System.Array]) {
            [void]$errors.Add('expectedAssertionIds must be a JSON array.')
        }
        if ($screenshotIdsValue -isnot [System.Array]) {
            [void]$errors.Add('screenshotIds must be a JSON array.')
        }
        $assertionAssessment = Test-UpvIdentifierArray `
            -Value (,$expectedAssertionIdsValue) `
            -Name 'expectedAssertionIds'
        $screenshotAssessment = Test-UpvIdentifierArray `
            -Value (,$screenshotIdsValue) `
            -Name 'screenshotIds'
        $result.expectedAssertionIds = $assertionAssessment.values
        $result.screenshotIds = $screenshotAssessment.values
        foreach ($errorMessage in @($assertionAssessment.errors) + @($screenshotAssessment.errors)) {
            [void]$errors.Add($errorMessage)
        }
        if ($result.expectedAssertionIds.Count -eq 0) {
            [void]$errors.Add('expectedAssertionIds must contain at least one assertion.')
        }

        $files = @(Get-UpvBundleFileInventory -BundleRoot $root)
        $result.files = @($files | ForEach-Object {
            [ordered]@{ path = $_.path; length = $_.length; sha256 = $_.sha256 }
        })
        $result.fileCount = $files.Count
        if (@($files | Where-Object { [System.IO.Path]::GetExtension($_.path) -ieq '.cs' }).Count -eq 0) {
            [void]$errors.Add('Scenario bundle must contain at least one C# source file.')
        }
        $testAssemblyFound = $false
        foreach ($asmdefFile in @($files | Where-Object { [System.IO.Path]::GetExtension($_.path) -ieq '.asmdef' })) {
            try {
                $asmdef = Read-UpvJsonFile -Path $asmdefFile.sourcePath
                $optionalReferences = @((Get-UpvJsonProperty -InputObject $asmdef -Name 'optionalUnityReferences'))
                $references = @((Get-UpvJsonProperty -InputObject $asmdef -Name 'references'))
                if (
                    @($optionalReferences | Where-Object { [string]$_ -ceq 'TestAssemblies' }).Count -gt 0 -and
                    @($references | Where-Object { [string]$_ -ceq 'UnityPlayVerification.Harness' }).Count -gt 0
                ) {
                    $testAssemblyFound = $true
                }
            } catch {
                [void]$errors.Add("Invalid asmdef '$($asmdefFile.path)': $($_.Exception.Message)")
            }
        }
        if (-not $testAssemblyFound) {
            [void]$errors.Add('One asmdef must reference UnityPlayVerification.Harness and declare TestAssemblies.')
        }

        $canonical = foreach ($file in @($result.files | Sort-Object -Property path)) {
            "F|$($script:UpvUtf8NoBom.GetByteCount([string]$file.path))|$($file.path)|$($file.length)|$($file.sha256)"
        }
        $result.treeSha256 = Get-UpvTextSha256 -Text ([string]::Join([char]10, [string[]]@($canonical)))
    } catch {
        [void]$errors.Add($_.Exception.Message)
    }
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}

# Compares two ordinal string collections for exact set equality.
function Test-UpvExactStringSet {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Actual
    )

    $expectedValues = [string[]]@($Expected)
    $actualValues = [string[]]@($Actual)
    $expectedSorted = [string[]]@($expectedValues | Sort-Object -Unique)
    $actualSorted = [string[]]@($actualValues | Sort-Object -Unique)
    if ($expectedValues.Count -ne $expectedSorted.Count -or $actualValues.Count -ne $actualSorted.Count) {
        return $false
    }
    if ($expectedSorted.Count -ne $actualSorted.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedSorted.Count; $index++) {
        if ($expectedSorted[$index] -cne $actualSorted[$index]) {
            return $false
        }
    }
    return $true
}

# Validates a scenario receipt and hashes every requested screenshot without judging image content.
function Get-UpvScenarioReceiptAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReceiptPath,

        [Parameter(Mandatory = $true)]
        [string]$ScreenshotRoot,

        [Parameter(Mandatory = $true)]
        [object]$Bundle
    )

    $result = [ordered]@{
        exists = $false
        sha256 = $null
        schemaVersion = $null
        scenarioId = $null
        completed = $false
        error = $null
        scenes = @()
        assertions = @()
        captureReceipts = @()
        screenshots = @()
        accepted = $false
        errors = @()
    }
    $errors = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        [void]$errors.Add('Scenario receipt was not created.')
    } else {
        try {
            $result.exists = $true
            $result.sha256 = Get-UpvFileSha256 -Path $ReceiptPath
            $receipt = Read-UpvJsonFile -Path $ReceiptPath
            $result.schemaVersion = [string](Get-UpvJsonProperty -InputObject $receipt -Name 'schemaVersion')
            $result.scenarioId = [string](Get-UpvJsonProperty -InputObject $receipt -Name 'scenarioId')
            $result.completed = [bool](Get-UpvJsonProperty -InputObject $receipt -Name 'completed')
            $result.error = [string](Get-UpvJsonProperty -InputObject $receipt -Name 'error')
            $result.scenes = @((Get-UpvJsonProperty -InputObject $receipt -Name 'scenes'))
            $result.assertions = @((Get-UpvJsonProperty -InputObject $receipt -Name 'assertions'))
            $result.captureReceipts = @((Get-UpvJsonProperty -InputObject $receipt -Name 'captures'))
            if ($result.schemaVersion -cne '1.0.0') { [void]$errors.Add('Scenario receipt schemaVersion must be 1.0.0.') }
            if ($result.scenarioId -cne [string]$Bundle.scenarioId) { [void]$errors.Add('Scenario receipt ID does not match the manifest.') }
            if (-not $result.completed) { [void]$errors.Add('Scenario receipt is not marked completed.') }
            if (-not [string]::IsNullOrWhiteSpace($result.error)) { [void]$errors.Add("Scenario reported an error: $($result.error)") }

            if (-not (Test-UpvExactStringSet -Expected ([string[]]$Bundle.expectedScenes) -Actual ([string[]]@($result.scenes)))) {
                [void]$errors.Add('Scenario Scene paths do not exactly match the manifest.')
            }

            $actualAssertionIds = New-Object System.Collections.ArrayList
            foreach ($assertion in @($result.assertions)) {
                $identifier = [string](Get-UpvJsonProperty -InputObject $assertion -Name 'id')
                [void]$actualAssertionIds.Add($identifier)
                if (-not [bool](Get-UpvJsonProperty -InputObject $assertion -Name 'passed')) {
                    [void]$errors.Add("Scenario assertion failed: $identifier")
                }
            }
            if (-not (Test-UpvExactStringSet -Expected ([string[]]$Bundle.expectedAssertionIds) -Actual ([string[]]@($actualAssertionIds)))) {
                [void]$errors.Add('Scenario assertion IDs do not exactly match the manifest.')
            }

            $actualCaptureIds = New-Object System.Collections.ArrayList
            foreach ($capture in @($result.captureReceipts)) {
                $identifier = [string](Get-UpvJsonProperty -InputObject $capture -Name 'id')
                $reportedPath = [string](Get-UpvJsonProperty -InputObject $capture -Name 'path')
                [void]$actualCaptureIds.Add($identifier)
                if ($identifier -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
                    [void]$errors.Add('Scenario receipt contains an invalid capture ID.')
                    continue
                }
                $expectedCapturePath = Get-UpvNormalizedPath -Path (Join-Path -Path $ScreenshotRoot -ChildPath ($identifier + '.png'))
                try {
                    if ((Get-UpvNormalizedPath -Path $reportedPath) -cne $expectedCapturePath) {
                        [void]$errors.Add("Scenario capture path does not match the verifier-owned artifact path: $identifier")
                    }
                } catch {
                    [void]$errors.Add("Scenario capture path is invalid: $identifier")
                }
            }
            if (-not (Test-UpvExactStringSet -Expected ([string[]]$Bundle.screenshotIds) -Actual ([string[]]@($actualCaptureIds)))) {
                [void]$errors.Add('Scenario capture IDs do not exactly match the manifest.')
            }
        } catch {
            [void]$errors.Add("Scenario receipt is invalid: $($_.Exception.Message)")
        }
    }

    $screenshots = New-Object System.Collections.ArrayList
    foreach ($identifier in @($Bundle.screenshotIds)) {
        $path = Join-Path -Path $ScreenshotRoot -ChildPath ($identifier + '.png')
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $length = $null
        $sha256 = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $length = [long]$item.Length
            if ($length -gt 0) {
                $sha256 = Get-UpvFileSha256 -Path $path
            } else {
                [void]$errors.Add("Requested screenshot is empty: $identifier")
            }
        } else {
            [void]$errors.Add("Requested screenshot is missing: $identifier")
        }
        [void]$screenshots.Add([ordered]@{
            id = $identifier
            path = $path
            exists = $exists
            byteLength = $length
            sha256 = $sha256
        })
    }
    $result.screenshots = @($screenshots)
    $result.errors = @($errors)
    $result.accepted = $errors.Count -eq 0
    return [pscustomobject]$result
}
