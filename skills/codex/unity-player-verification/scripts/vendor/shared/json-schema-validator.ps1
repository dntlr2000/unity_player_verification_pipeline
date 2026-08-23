Set-StrictMode -Version Latest

# Returns a named JSON property without collection enumeration or PowerShell 7 PSCustomObject coercion.
function Get-JsonSchemaPropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $dictionaryValue = $Object[$Name]
            return ,$dictionaryValue
        }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    $propertyValue = $property.Value
    return ,$propertyValue
}

# Converts one scalar or JSON array property into a stable object array on Windows PowerShell and PowerShell 7.
function ConvertTo-JsonSchemaValueArray {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $values = New-Object System.Collections.ArrayList
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            [void]$values.Add($item)
        }
    } else {
        [void]$values.Add($Value)
    }
    return ,([object[]]$values.ToArray())
}

# Tests whether a JSON object exposes one named property, including null-valued properties.
function Test-JsonSchemaProperty {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

# Returns only the data-property names represented by one JSON object.
function Get-JsonSchemaPropertyNames {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

# Tests whether a PowerShell value represents a JSON object.
function Test-JsonSchemaObjectValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    return (
        $null -ne $Value -and
        ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary])
    )
}

# Tests whether a PowerShell value represents a JSON array.
function Test-JsonSchemaArrayValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    return $null -ne $Value -and $Value -is [System.Array]
}

# Tests one PowerShell value against a JSON Schema primitive type name.
function Test-JsonSchemaType {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$TypeName
    )

    switch ($TypeName) {
        "null" { return $null -eq $Value }
        "object" { return Test-JsonSchemaObjectValue -Value $Value }
        "array" { return Test-JsonSchemaArrayValue -Value $Value }
        "string" { return $null -ne $Value -and $Value -is [string] }
        "boolean" { return $null -ne $Value -and $Value -is [bool] }
        "integer" {
            if ($null -eq $Value) {
                return $false
            }
            return [Type]::GetTypeCode($Value.GetType()) -in @(
                [TypeCode]::Byte,
                [TypeCode]::SByte,
                [TypeCode]::Int16,
                [TypeCode]::UInt16,
                [TypeCode]::Int32,
                [TypeCode]::UInt32,
                [TypeCode]::Int64,
                [TypeCode]::UInt64
            )
        }
        "number" {
            if ($null -eq $Value) {
                return $false
            }
            return [Type]::GetTypeCode($Value.GetType()) -in @(
                [TypeCode]::Byte,
                [TypeCode]::SByte,
                [TypeCode]::Int16,
                [TypeCode]::UInt16,
                [TypeCode]::Int32,
                [TypeCode]::UInt32,
                [TypeCode]::Int64,
                [TypeCode]::UInt64,
                [TypeCode]::Single,
                [TypeCode]::Double,
                [TypeCode]::Decimal
            )
        }
        default { throw "Unsupported JSON Schema type: $TypeName" }
    }
}

# Compares two JSON scalar values without PowerShell string/number coercion.
function Test-JsonSchemaScalarEqual {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Left,

        [Parameter()]
        [AllowNull()]
        [object]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return (
            $Left -is [string] -and
            $Right -is [string] -and
            [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::Ordinal)
        )
    }
    if ($Left -is [bool] -or $Right -is [bool]) {
        return $Left -is [bool] -and $Right -is [bool] -and [bool]$Left -eq [bool]$Right
    }

    $leftIsNumber = Test-JsonSchemaType -Value $Left -TypeName "number"
    $rightIsNumber = Test-JsonSchemaType -Value $Right -TypeName "number"
    if ($leftIsNumber -or $rightIsNumber) {
        return $leftIsNumber -and $rightIsNumber -and [decimal]$Left -eq [decimal]$Right
    }
    return $Left.Equals($Right)
}

# Appends one property name to an exact, machine-readable JSON path.
function Join-JsonSchemaPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($PropertyName -match '^[A-Za-z_][A-Za-z0-9_]*$') {
        return "$Path.$PropertyName"
    }
    $escapedName = $PropertyName.Replace("'", "\'")
    return "$Path['$escapedName']"
}

# Records one deterministic schema-validation error.
function Add-JsonSchemaError {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Errors,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Keyword,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [void]$Errors.Add([pscustomobject][ordered]@{
        path = $Path
        keyword = $Keyword
        message = $Message
    })
}

# Reads and caches one local JSON Schema document without network resolution.
function Get-JsonSchemaDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$DocumentCache
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ($DocumentCache.Contains($normalizedPath)) {
        return $DocumentCache[$normalizedPath]
    }
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw "JSON Schema document was not found: $normalizedPath"
    }

    $text = [System.IO.File]::ReadAllText($normalizedPath)
    $schema = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    $document = [pscustomobject][ordered]@{
        path = $normalizedPath
        schema = $schema
    }
    $DocumentCache[$normalizedPath] = $document
    return $document
}

# Resolves a JSON Pointer fragment within one parsed schema document.
function Resolve-JsonSchemaPointer {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Document,

        [Parameter(Mandatory = $true)]
        [string]$Fragment
    )

    if ([string]::IsNullOrEmpty($Fragment) -or $Fragment -eq '#') {
        return $Document.schema
    }
    if (-not $Fragment.StartsWith('#/', [System.StringComparison]::Ordinal)) {
        throw "Unsupported JSON Schema fragment: $Fragment"
    }

    $current = $Document.schema
    $pointerText = [System.Uri]::UnescapeDataString($Fragment.Substring(2))
    foreach ($encodedSegment in $pointerText.Split('/')) {
        $segment = $encodedSegment.Replace('~1', '/').Replace('~0', '~')
        if (-not (Test-JsonSchemaProperty -Object $current -Name $segment)) {
            throw "JSON Schema pointer was not found: $Fragment"
        }
        $current = Get-JsonSchemaPropertyValue -Object $current -Name $segment
    }
    return $current
}

# Resolves local or same-directory relative-file references without network access.
function Resolve-JsonSchemaReference {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CurrentDocument,

        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [string]$SchemaRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$DocumentCache
    )

    $parts = $Reference.Split([char]'#', 2)
    $relativeDocumentPath = $parts[0]
    $fragment = if ($parts.Count -eq 2) { '#' + $parts[1] } else { '#' }
    $targetDocument = $CurrentDocument

    if (-not [string]::IsNullOrEmpty($relativeDocumentPath)) {
        if (
            [System.IO.Path]::IsPathRooted($relativeDocumentPath) -or
            $relativeDocumentPath -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or
            $relativeDocumentPath.StartsWith('//', [System.StringComparison]::Ordinal)
        ) {
            throw "Remote or absolute JSON Schema references are forbidden: $Reference"
        }

        $targetPath = [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Parent $CurrentDocument.path) -ChildPath $relativeDocumentPath))
        $normalizedSchemaRoot = [System.IO.Path]::GetFullPath($SchemaRoot).TrimEnd('\', '/')
        $rootPrefix = $normalizedSchemaRoot + [System.IO.Path]::DirectorySeparatorChar
        if (
            -not $targetPath.Equals($normalizedSchemaRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "JSON Schema reference escapes the schema root: $Reference"
        }
        $targetDocument = Get-JsonSchemaDocument -Path $targetPath -DocumentCache $DocumentCache
    }

    return [pscustomobject][ordered]@{
        document = $targetDocument
        schema = Resolve-JsonSchemaPointer -Document $targetDocument -Fragment $fragment
    }
}

# Recursively validates primitive, object, array, reference, and oneOf keywords at one schema node.
function Invoke-JsonSchemaNodeValidation {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [object]$Schema,

        [Parameter(Mandatory = $true)]
        [object]$CurrentDocument,

        [Parameter(Mandatory = $true)]
        [string]$SchemaRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$DocumentCache,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Errors,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Depth
    )

    if ($Depth -gt 256) {
        throw "JSON Schema reference depth exceeded the safety limit."
    }

    if (Test-JsonSchemaProperty -Object $Schema -Name '$ref') {
        $resolved = Resolve-JsonSchemaReference -CurrentDocument $CurrentDocument -Reference ([string](Get-JsonSchemaPropertyValue -Object $Schema -Name '$ref')) -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache
        Invoke-JsonSchemaNodeValidation -Value $Value -Schema $resolved.schema -CurrentDocument $resolved.document -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache -Errors $Errors -Path $Path -Depth ($Depth + 1)
    }

    if (Test-JsonSchemaProperty -Object $Schema -Name 'oneOf') {
        $alternatives = ConvertTo-JsonSchemaValueArray -Value (Get-JsonSchemaPropertyValue -Object $Schema -Name 'oneOf')
        $matchedAlternatives = 0
        foreach ($alternative in $alternatives) {
            $alternativeErrors = New-Object System.Collections.ArrayList
            Invoke-JsonSchemaNodeValidation -Value $Value -Schema $alternative -CurrentDocument $CurrentDocument -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache -Errors $alternativeErrors -Path $Path -Depth ($Depth + 1)
            if ($alternativeErrors.Count -eq 0) {
                $matchedAlternatives++
            }
        }
        if ($matchedAlternatives -ne 1) {
            Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'oneOf' -Message "Expected exactly one matching schema alternative; matched $matchedAlternatives."
        }
    }

    if (Test-JsonSchemaProperty -Object $Schema -Name 'type') {
        $typeNames = ConvertTo-JsonSchemaValueArray -Value (Get-JsonSchemaPropertyValue -Object $Schema -Name 'type')
        $matchesType = $false
        foreach ($typeName in $typeNames) {
            if (Test-JsonSchemaType -Value $Value -TypeName ([string]$typeName)) {
                $matchesType = $true
                break
            }
        }
        if (-not $matchesType) {
            Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'type' -Message "Expected JSON type $([string]::Join('|', [string[]]$typeNames))."
            return
        }
    }

    if (Test-JsonSchemaProperty -Object $Schema -Name 'const') {
        $constant = Get-JsonSchemaPropertyValue -Object $Schema -Name 'const'
        if (-not (Test-JsonSchemaScalarEqual -Left $constant -Right $Value)) {
            Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'const' -Message 'Value does not match the required constant.'
        }
    }

    if (Test-JsonSchemaProperty -Object $Schema -Name 'enum') {
        $matchedEnum = $false
        $enumValues = ConvertTo-JsonSchemaValueArray -Value (Get-JsonSchemaPropertyValue -Object $Schema -Name 'enum')
        foreach ($candidate in $enumValues) {
            if (Test-JsonSchemaScalarEqual -Left $candidate -Right $Value) {
                $matchedEnum = $true
                break
            }
        }
        if (-not $matchedEnum) {
            Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'enum' -Message 'Value is not one of the allowed enum values.'
        }
    }

    if ($Value -is [string]) {
        if (Test-JsonSchemaProperty -Object $Schema -Name 'minLength') {
            $minimumLength = [int](Get-JsonSchemaPropertyValue -Object $Schema -Name 'minLength')
            if ($Value.Length -lt $minimumLength) {
                Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'minLength' -Message "String length must be at least $minimumLength."
            }
        }
        if (Test-JsonSchemaProperty -Object $Schema -Name 'maxLength') {
            $maximumLength = [int](Get-JsonSchemaPropertyValue -Object $Schema -Name 'maxLength')
            if ($Value.Length -gt $maximumLength) {
                Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'maxLength' -Message "String length must be at most $maximumLength."
            }
        }
        if (Test-JsonSchemaProperty -Object $Schema -Name 'pattern') {
            $pattern = [string](Get-JsonSchemaPropertyValue -Object $Schema -Name 'pattern')
            if (-not [regex]::IsMatch($Value, $pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'pattern' -Message 'String does not match the required pattern.'
            }
        }
    }

    if (Test-JsonSchemaArrayValue -Value $Value) {
        if (Test-JsonSchemaProperty -Object $Schema -Name 'minItems') {
            $minimumItems = [int](Get-JsonSchemaPropertyValue -Object $Schema -Name 'minItems')
            if ($Value.Count -lt $minimumItems) {
                Add-JsonSchemaError -Errors $Errors -Path $Path -Keyword 'minItems' -Message "Array must contain at least $minimumItems item(s)."
            }
        }
        if (Test-JsonSchemaProperty -Object $Schema -Name 'items') {
            $itemSchema = Get-JsonSchemaPropertyValue -Object $Schema -Name 'items'
            for ($index = 0; $index -lt $Value.Count; $index++) {
                Invoke-JsonSchemaNodeValidation -Value $Value[$index] -Schema $itemSchema -CurrentDocument $CurrentDocument -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache -Errors $Errors -Path "$Path[$index]" -Depth ($Depth + 1)
            }
        }
    }

    if (Test-JsonSchemaObjectValue -Value $Value) {
        if (Test-JsonSchemaProperty -Object $Schema -Name 'required') {
            $requiredNames = ConvertTo-JsonSchemaValueArray -Value (Get-JsonSchemaPropertyValue -Object $Schema -Name 'required')
            foreach ($requiredName in $requiredNames) {
                $requiredPath = Join-JsonSchemaPath -Path $Path -PropertyName ([string]$requiredName)
                if (-not (Test-JsonSchemaProperty -Object $Value -Name ([string]$requiredName))) {
                    Add-JsonSchemaError -Errors $Errors -Path $requiredPath -Keyword 'required' -Message "Required property '$requiredName' is missing."
                }
            }
        }

        $propertySchemas = Get-JsonSchemaPropertyValue -Object $Schema -Name 'properties'
        if ($null -ne $propertySchemas) {
            foreach ($propertyName in @(Get-JsonSchemaPropertyNames -Object $propertySchemas)) {
                if (Test-JsonSchemaProperty -Object $Value -Name $propertyName) {
                    $childPath = Join-JsonSchemaPath -Path $Path -PropertyName $propertyName
                    $childValue = Get-JsonSchemaPropertyValue -Object $Value -Name $propertyName
                    $childSchema = Get-JsonSchemaPropertyValue -Object $propertySchemas -Name $propertyName
                    Invoke-JsonSchemaNodeValidation -Value $childValue -Schema $childSchema -CurrentDocument $CurrentDocument -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache -Errors $Errors -Path $childPath -Depth ($Depth + 1)
                }
            }
        }

        if (Test-JsonSchemaProperty -Object $Schema -Name 'additionalProperties') {
            $additionalSchema = Get-JsonSchemaPropertyValue -Object $Schema -Name 'additionalProperties'
            $allowedNames = if ($null -eq $propertySchemas) { @() } else { @(Get-JsonSchemaPropertyNames -Object $propertySchemas) }
            foreach ($instanceName in @(Get-JsonSchemaPropertyNames -Object $Value)) {
                if ($allowedNames -ccontains $instanceName) {
                    continue
                }
                $additionalPath = Join-JsonSchemaPath -Path $Path -PropertyName $instanceName
                if ($additionalSchema -is [bool] -and -not [bool]$additionalSchema) {
                    Add-JsonSchemaError -Errors $Errors -Path $additionalPath -Keyword 'additionalProperties' -Message "Additional property '$instanceName' is not allowed."
                } elseif (-not ($additionalSchema -is [bool])) {
                    $additionalValue = Get-JsonSchemaPropertyValue -Object $Value -Name $instanceName
                    Invoke-JsonSchemaNodeValidation -Value $additionalValue -Schema $additionalSchema -CurrentDocument $CurrentDocument -SchemaRoot $SchemaRoot -DocumentCache $DocumentCache -Errors $Errors -Path $additionalPath -Depth ($Depth + 1)
                }
            }
        }
    }
}

# Validates one parsed JSON instance and returns every exact-path schema error.
function Invoke-JsonSchemaValidation {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Instance,

        [Parameter(Mandatory = $true)]
        [string]$SchemaPath
    )

    $normalizedSchemaPath = [System.IO.Path]::GetFullPath($SchemaPath)
    $schemaRoot = Split-Path -Parent $normalizedSchemaPath
    $documentCache = @{}
    $document = Get-JsonSchemaDocument -Path $normalizedSchemaPath -DocumentCache $documentCache
    $errors = New-Object System.Collections.ArrayList
    Invoke-JsonSchemaNodeValidation -Value $Instance -Schema $document.schema -CurrentDocument $document -SchemaRoot $schemaRoot -DocumentCache $documentCache -Errors $errors -Path '$' -Depth 0
    return @($errors.ToArray())
}
