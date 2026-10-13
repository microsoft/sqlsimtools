[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$plugins = @('sqlsim', 'sqlpysim')

foreach ($plugin in $plugins) {
    $source = Join-Path $repoRoot ".github\skills\$plugin\SKILL.md"
    $destinationDirectory = Join-Path $repoRoot "plugins\$plugin\skills\$plugin"
    $destination = Join-Path $destinationDirectory 'SKILL.md'

    if ($Check) {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Generated plugin skill is missing: $destination"
        }
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
            throw "Generated plugin skill has drifted: $destination"
        }
        continue
    }

    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Host "Synchronized plugins/$plugin/skills/$plugin/SKILL.md"
}

if ($Check) {
    Write-Host 'Plugin skill copies match their canonical sources.'
}

# Callers read $LASTEXITCODE; without this it can still hold an earlier native tool's code.
exit 0
