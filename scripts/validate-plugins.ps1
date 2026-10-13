[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()
$plugins = @('sqlsim', 'sqlpysim')
$versions = @{ sqlsim = '1.0.0'; sqlpysim = '1.0.0' }
$repository = 'https://github.com/microsoft/sqlsimtools'
$marketplaces = @(
    '.agents/plugins/marketplace.json',
    '.claude-plugin/marketplace.json',
    '.cursor-plugin/marketplace.json',
    '.github/plugin/marketplace.json'
)
$compatibilityManifests = @(
    '.claude-plugin/plugin.json',
    '.codex-plugin/plugin.json',
    '.cursor-plugin/plugin.json'
)

$canonicalSkillsRoot = Join-Path $repoRoot '.github\skills'
foreach ($skillDirectory in Get-ChildItem -LiteralPath $canonicalSkillsRoot -Directory) {
    $skillPath = Join-Path $skillDirectory.FullName 'SKILL.md'
    $relativeSkillPath = ".github/skills/$($skillDirectory.Name)/SKILL.md"
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        $errors.Add("Missing canonical skill: $relativeSkillPath")
        continue
    }

    $skill = Get-Content -LiteralPath $skillPath -Raw
    $frontmatter = [regex]::Match($skill, '(?s)\A---\s*\r?\n(?<body>.*?)\r?\n---\s*(?:\r?\n|$)')
    if (-not $frontmatter.Success) {
        $errors.Add("${relativeSkillPath}: invalid frontmatter")
        continue
    }

    $nameMatch = [regex]::Match($frontmatter.Groups['body'].Value, '(?m)^name:\s*[''"]?(?<value>[^''"\r\n]+)[''"]?\s*$')
    if (-not $nameMatch.Success -or $nameMatch.Groups['value'].Value -ne $skillDirectory.Name) {
        $errors.Add("${relativeSkillPath}: name must match folder '$($skillDirectory.Name)'")
    }

    $descriptionMatch = [regex]::Match($frontmatter.Groups['body'].Value, '(?m)^description:\s*(?:''(?<single>[^'']+)''|"(?<double>[^"]+)"|(?<plain>[^''"\r\n][^\r\n]*))\s*$')
    if (-not $descriptionMatch.Success) {
        $errors.Add("${relativeSkillPath}: missing or invalid one-line description")
    } else {
        $description = @(
            $descriptionMatch.Groups['single'].Value,
            $descriptionMatch.Groups['double'].Value,
            $descriptionMatch.Groups['plain'].Value
        ) | Where-Object { $_ } | Select-Object -First 1
        if ($description.Length -gt 1024) {
            $errors.Add("${relativeSkillPath}: description exceeds 1024 characters")
        }
    }
}

function Read-JsonFile {
    param([string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing file: $RelativePath")
        return $null
    }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        $errors.Add("Invalid JSON in ${RelativePath}: $($_.Exception.Message)")
        return $null
    }
}

foreach ($plugin in $plugins) {
    $manifestPath = "plugins/$plugin/plugin.json"
    $manifest = Read-JsonFile $manifestPath
    if ($null -ne $manifest) {
        $allowedFields = @('$schema', 'name', 'version', 'description', 'author', 'homepage', 'repository', 'license', 'keywords', 'extensions')
        foreach ($property in $manifest.PSObject.Properties.Name) {
            if ($property -notin $allowedFields) {
                $errors.Add("${manifestPath}: unknown Agent Plugins field '$property'")
            }
        }
        if ($manifest.'$schema' -ne 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json') {
            $errors.Add("${manifestPath}: invalid Agent Plugins schema")
        }
        if ($manifest.name -ne $plugin -or $manifest.version -ne $versions[$plugin]) {
            $errors.Add("${manifestPath}: name or version mismatch")
        }
        if ($manifest.repository -ne $repository -or $manifest.license -ne 'MIT') {
            $errors.Add("${manifestPath}: repository or license mismatch")
        }
        if ($manifest.name -notmatch '^[a-z0-9](?:[a-z0-9.-]{0,62}[a-z0-9])?$' -or $manifest.name -match '--|\.\.') {
            $errors.Add("${manifestPath}: invalid plugin name")
        }
    }

    foreach ($relativePath in $compatibilityManifests) {
        $path = "plugins/$plugin/$relativePath"
        $compatibilityManifest = Read-JsonFile $path
        if ($null -ne $compatibilityManifest) {
            if ($compatibilityManifest.name -ne $plugin -or $compatibilityManifest.version -ne $versions[$plugin]) {
                $errors.Add("${path}: name or version mismatch")
            }
            if ($compatibilityManifest.repository -ne $repository) {
                $errors.Add("${path}: repository mismatch")
            }
        }
    }

    $skillPath = Join-Path $repoRoot "plugins\$plugin\skills\$plugin\SKILL.md"
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        $errors.Add("Missing skill: plugins/$plugin/skills/$plugin/SKILL.md")
    } else {
        $skill = Get-Content -LiteralPath $skillPath -Raw
        if ($skill -notmatch "(?ms)^---\s+name:\s*$plugin\s+description:\s*.+?^---\s*$") {
            $errors.Add("plugins/$plugin/skills/$plugin/SKILL.md: invalid frontmatter")
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "plugins\$plugin\README.md") -PathType Leaf)) {
        $errors.Add("Missing plugin README: plugins/$plugin/README.md")
    }
}

foreach ($marketplacePath in $marketplaces) {
    $marketplace = Read-JsonFile $marketplacePath
    if ($null -eq $marketplace) {
        continue
    }
    if ($marketplace.name -ne 'sqlsimtools') {
        $errors.Add("${marketplacePath}: marketplace name mismatch")
    }
    $actualNames = @($marketplace.plugins | ForEach-Object { $_.name } | Sort-Object)
    if (Compare-Object -ReferenceObject $plugins -DifferenceObject $actualNames) {
        $errors.Add("${marketplacePath}: plugin list mismatch")
    }
    foreach ($entry in @($marketplace.plugins)) {
        $source = if ($entry.source -is [string]) { $entry.source } else { $entry.source.path }
        if ($source -ne "./plugins/$($entry.name)") {
            $errors.Add("${marketplacePath}: invalid source for $($entry.name)")
        }
    }
}

$readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
foreach ($plugin in $plugins) {
    if ($readme -notmatch [regex]::Escape("$plugin@sqlsimtools")) {
        $errors.Add("README.md: missing install coordinate $plugin@sqlsimtools")
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

$canonicalSkillCount = @(Get-ChildItem -LiteralPath $canonicalSkillsRoot -Directory).Count
Write-Host "Validated $canonicalSkillCount canonical skills, $($plugins.Count) plugins, and $($marketplaces.Count) marketplace descriptors."

# Callers read $LASTEXITCODE; without this it can still hold an earlier native tool's code.
exit 0
