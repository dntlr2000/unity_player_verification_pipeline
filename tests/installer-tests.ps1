[CmdletBinding()]
param(
    [Parameter()]
    [string]$TestRoot = 'E:\CodexTemp\unity-player-verification-installer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repositoryRoot 'scripts\install-unity-player-verification-skill.ps1'
$sessionRoot = Join-Path $TestRoot ('run-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($sessionRoot)
$script:Assertions = 0

# Records one installer assertion and throws when it is false.
function Assert-UpvrInstallerTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Assertions++
}

# Executes the installer in an isolated child PowerShell process.
function Invoke-UpvrInstallerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter()][switch]$WhatIf
    )

    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installer,'-DestinationRoot',$DestinationRoot)
    if ($WhatIf) { $arguments += '-WhatIf' }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ exitCode = $exitCode; output = [string]::Join([Environment]::NewLine, [string[]]@($output)) }
}

$destination = Join-Path $sessionRoot 'skills'
$whatIf = Invoke-UpvrInstallerProcess -DestinationRoot $destination -WhatIf
Assert-UpvrInstallerTrue -Condition ($whatIf.exitCode -eq 0) -Message 'WhatIf must succeed.'
Assert-UpvrInstallerTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'unity-player-verification'))) -Message 'WhatIf must not create a Skill link.'

$first = Invoke-UpvrInstallerProcess -DestinationRoot $destination
Assert-UpvrInstallerTrue -Condition ($first.exitCode -eq 0) -Message "Initial install must succeed: $($first.output)"
$installed = Get-Item -LiteralPath (Join-Path $destination 'unity-player-verification') -Force
Assert-UpvrInstallerTrue -Condition ($installed.LinkType -in @('SymbolicLink','Junction')) -Message 'Install must create a link, not a copied directory.'

$second = Invoke-UpvrInstallerProcess -DestinationRoot $destination
Assert-UpvrInstallerTrue -Condition ($second.exitCode -eq 0 -and $second.output -match '\[unchanged\]') -Message 'Second install must be idempotent.'

$collisionRoot = Join-Path $sessionRoot 'collision'
[void][System.IO.Directory]::CreateDirectory($collisionRoot)
[void][System.IO.File]::WriteAllText((Join-Path $collisionRoot 'unity-player-verification'), 'collision')
$collision = Invoke-UpvrInstallerProcess -DestinationRoot $collisionRoot
Assert-UpvrInstallerTrue -Condition ($collision.exitCode -ne 0) -Message 'Installer must refuse an unrelated collision.'

Write-Host ("Unity Player Verification installer tests passed. Assertions: {0}; artifacts: {1}" -f $script:Assertions, $sessionRoot)
