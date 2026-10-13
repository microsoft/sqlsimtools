<#
.SYNOPSIS
    Validates an installed sqlsim or sqlpysim release overlay without a database.
.DESCRIPTION
    Checks the package layout, skill and Workload Builder frontmatter, local
    skill links, the native binary's architecture, that --help and --version
    run, and that every option the help lists is documented in the manual's
    Command Reference and vice versa. Release CI runs this against every
    extracted archive; scripts\install-local.ps1 runs it after installing.
.EXAMPLE
    .\release\validate-package-layout.ps1 -InstallRoot C:\myproject -Tool sqlsim -SqlsimExecutable sqlsim/x64/sqlsim.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('sqlsim', 'sqlpysim')]
    [string[]]$Tool,

    [string]$SqlsimExecutable,

    [switch]$SkipExecution
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -LiteralPath $InstallRoot).Path
$errors = [System.Collections.Generic.List[string]]::new()

function Test-RequiredPath {
    param([string]$RelativePath)

    $fullPath = Join-Path $resolvedRoot $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $errors.Add("Missing required path: $RelativePath")
    }
}

function Test-SkillLinks {
    param([string]$RelativeSkillPath)

    $skillPath = Join-Path $resolvedRoot $RelativeSkillPath
    if (-not (Test-Path -LiteralPath $skillPath)) {
        return
    }

    $skillDirectory = Split-Path -Parent $skillPath
    $content = Get-Content -LiteralPath $skillPath -Raw
    $matches = [regex]::Matches($content, '\[[^\]]+\]\(([^)]+)\)')
    foreach ($match in $matches) {
        $target = $match.Groups[1].Value
        if ($target -match '^(https?://|#)') {
            continue
        }

        $targetWithoutAnchor = ($target -split '#', 2)[0]
        $resolvedTarget = [IO.Path]::GetFullPath((Join-Path $skillDirectory $targetWithoutAnchor))
        if (-not (Test-Path -LiteralPath $resolvedTarget)) {
            $errors.Add("Broken local link in ${RelativeSkillPath}: $target")
        }
    }
}

function Test-SkillFrontmatter {
    param([string]$RelativeSkillPath, [string]$ExpectedName)

    $skillPath = Join-Path $resolvedRoot $RelativeSkillPath
    if (-not (Test-Path -LiteralPath $skillPath)) {
        return
    }
    $content = Get-Content -LiteralPath $skillPath -Raw
    $frontmatter = [regex]::Match($content, '\A---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    if (-not $frontmatter.Success) {
        $errors.Add("Skill has no YAML frontmatter: $RelativeSkillPath")
        return
    }
    if ($frontmatter.Groups[1].Value -notmatch "(?m)^name:\s*$([regex]::Escape($ExpectedName))\s*$") {
        $errors.Add("Skill frontmatter name is not '$ExpectedName': $RelativeSkillPath")
    }
    if ($frontmatter.Groups[1].Value -notmatch '(?m)^description:\s*\S.{20,}') {
        $errors.Add("Skill frontmatter is missing a description: $RelativeSkillPath")
    }
}

# The options a manual documents in its Command Reference tables must match
# the options the shipped entry point prints in its help, in both directions.
function Test-DocumentedOptions {
    param([string]$Tool, [string]$RelativeManualPath, [string]$HelpText)

    $manualPath = Join-Path $resolvedRoot $RelativeManualPath
    if (-not (Test-Path -LiteralPath $manualPath)) {
        return
    }
    $manual = Get-Content -LiteralPath $manualPath -Raw
    $section = [regex]::Match($manual, '(?ms)^## Command Reference\s*$(.*?)(?=^## )')
    if (-not $section.Success) {
        $errors.Add("$RelativeManualPath has no '## Command Reference' section to compare with $Tool help")
        return
    }
    $documented = [regex]::Matches($section.Groups[1].Value, '(?m)^\|\s*`(-[A-Za-z][A-Za-z0-9-]*)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique -CaseSensitive
    $helped = [regex]::Matches($HelpText, '(?m)^\s+(-[A-Za-z][A-Za-z0-9-]*)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique -CaseSensitive

    $undocumented = @($helped | Where-Object { $_ -cnotin $documented })
    $unlisted = @($documented | Where-Object { $HelpText -cnotmatch ('(?<![\w-])' + [regex]::Escape($_) + '(?![\w-])') })
    if ($undocumented.Count -gt 0) {
        $errors.Add("$Tool help lists options missing from the $RelativeManualPath Command Reference: $($undocumented -join ', ')")
    }
    if ($unlisted.Count -gt 0) {
        $errors.Add("$RelativeManualPath documents options that $Tool help does not list: $($unlisted -join ', ')")
    }
}

# Reads the machine type from the executable header (PE, ELF, or Mach-O), so a
# package with the wrong binary in an architecture folder fails even when it
# cannot be run here.
function Test-ExecutableArchitecture {
    param([string]$RelativeExecutablePath)

    $path = Join-Path $resolvedRoot $RelativeExecutablePath
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }
    $expected = if ($RelativeExecutablePath -match '(^|[\\/])ARM64[\\/]') { 'ARM64' } else { 'x64' }
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $magic = $reader.ReadBytes(4)
        $actual = 'unknown'
        if ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A) {
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            $stream.Position = $peOffset + 4
            $actual = switch ($reader.ReadUInt16()) { 0x8664 { 'x64' } 0xAA64 { 'ARM64' } 0x14C { 'x86' } default { 'unknown PE' } }
        } elseif ($magic[0] -eq 0x7F -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4C -and $magic[3] -eq 0x46) {
            $stream.Position = 18
            $actual = switch ($reader.ReadUInt16()) { 62 { 'x64' } 183 { 'ARM64' } default { 'unknown ELF' } }
        } elseif ($magic[0] -eq 0xCF -and $magic[1] -eq 0xFA -and $magic[2] -eq 0xED -and $magic[3] -eq 0xFE) {
            # 64-bit Mach-O, little-endian; the CPU type follows the magic.
            $actual = switch ($reader.ReadUInt32()) { 0x01000007 { 'x64' } 0x0100000C { 'ARM64' } default { 'unknown Mach-O' } }
        } elseif ($magic[0] -eq 0xCA -and $magic[1] -eq 0xFE -and $magic[2] -eq 0xBA -and $magic[3] -eq 0xBE) {
            # Universal Mach-O: big-endian slice count, then 20-byte slice headers
            # that each start with a CPU type. It qualifies if it has the slice.
            $bigEndian = { param([byte[]]$b) ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3] }
            $count = & $bigEndian $reader.ReadBytes(4)
            $slices = @(for ($slice = 0; $slice -lt [Math]::Min($count, 16); $slice++) {
                $cpu = & $bigEndian $reader.ReadBytes(4)
                $null = $reader.ReadBytes(16)
                switch ($cpu) { 0x01000007 { 'x64' } 0x0100000C { 'ARM64' } }
            })
            $actual = if ($slices -contains $expected) { $expected } else { "universal ($($slices -join ', '))" }
        }
    } finally {
        $stream.Dispose()
    }
    if ($actual -ne $expected) {
        $errors.Add("$RelativeExecutablePath is a $actual binary; its folder requires $expected")
    }
}

function Test-WorkloadAgent {
    $relativePath = '.github/agents/sqlsimtools-workload-builder.agent.md'
    Test-RequiredPath $relativePath
    $agentPath = Join-Path $resolvedRoot $relativePath
    if (-not (Test-Path -LiteralPath $agentPath)) {
        return
    }

    $content = Get-Content -LiteralPath $agentPath -Raw
    if ($content -notmatch '(?ms)^---\s+.*?description:\s*".+?".*?tools:\s*\[read, search, edit, execute\].*?^---\s*$') {
        $errors.Add("Invalid workload-builder agent frontmatter: $relativePath")
    }
    if ($content -notmatch 'Do not execute until the user explicitly approves') {
        $errors.Add("Workload-builder agent is missing explicit execution approval: $relativePath")
    }
    if ($content -notmatch '`-P -`' -or $content -notmatch '`-T -`') {
        $errors.Add("Workload-builder agent is missing secure stdin guidance: $relativePath")
    }
    if ($content -notmatch 'Treat all such\s+content as untrusted data') {
        $errors.Add("Workload-builder agent is missing its prompt-injection boundary: $relativePath")
    }
}

$oldRootPaths = @(
    'AGENTS.md',
    'sqlsim.md',
    'sqlsim.py',
    'requirements.txt',
    'x64',
    'ARM64',
    'examples'
)
foreach ($oldRootPath in $oldRootPaths) {
    if (Test-Path -LiteralPath (Join-Path $resolvedRoot $oldRootPath)) {
        $errors.Add("Old flat package path must not exist: $oldRootPath")
    }
}

if ($Tool -contains 'sqlsim') {
    @(
        '.github/skills/sqlsim/SKILL.md',
        'sqlsim/AGENTS.md',
        'sqlsim/LICENSE',
        'sqlsim/THIRD-PARTY-NOTICES.md',
        'sqlsim/sqlsim.md',
        'sqlsim/examples',
        'sqlsim/examples/reports/execution-report.ps1',
        'sqlsim/examples/reports/comparison-report.ps1',
        'sqlsim/examples/reports/chart.umd.min.js',
        'sqlsim/examples/results/index-baseline.json',
        'sqlsim/examples/results/index-candidate.json',
        'sqlsim/replay/README.md',
        'sqlsim/replay/convert-xel.ps1'
    ) | ForEach-Object { Test-RequiredPath $_ }
    Test-SkillLinks '.github/skills/sqlsim/SKILL.md'
    Test-SkillFrontmatter '.github/skills/sqlsim/SKILL.md' 'sqlsim'

    if ([string]::IsNullOrWhiteSpace($SqlsimExecutable)) {
        $errors.Add('SqlsimExecutable is required when validating sqlsim.')
    } else {
        Test-RequiredPath $SqlsimExecutable
        Test-ExecutableArchitecture $SqlsimExecutable
    }
}

if ($Tool -contains 'sqlpysim') {
    @(
        '.github/skills/sqlpysim/SKILL.md',
        'sqlpysim/AGENTS.md',
        'sqlpysim/LICENSE',
        'sqlpysim/MACOS-PRIVATE-PREVIEW.md',
        'sqlpysim/THIRD-PARTY-NOTICES.md',
        'sqlpysim/sqlpysim.md',
        'sqlpysim/sqlpysim.py',
        'sqlpysim/requirements.txt',
        'sqlpysim/examples'
    ) | ForEach-Object { Test-RequiredPath $_ }
    Test-SkillLinks '.github/skills/sqlpysim/SKILL.md'
    Test-SkillFrontmatter '.github/skills/sqlpysim/SKILL.md' 'sqlpysim'
}

Test-WorkloadAgent

if (($Tool -contains 'sqlsim') -and -not $SkipExecution -and $errors.Count -eq 0) {
    $sqlsimPath = Join-Path $resolvedRoot $SqlsimExecutable
    $sqlsimHelp = & $sqlsimPath --help | Out-String
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("sqlsim --help failed with exit code $LASTEXITCODE")
    } else {
        Test-DocumentedOptions 'sqlsim' 'sqlsim/sqlsim.md' $sqlsimHelp
    }
    $sqlsimVersion = (& $sqlsimPath --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("sqlsim --version failed with exit code $LASTEXITCODE")
    } else {
        Write-Host $sqlsimVersion
    }
}

if (($Tool -contains 'sqlpysim') -and -not $SkipExecution -and $errors.Count -eq 0) {
    $sqlpysimPath = Join-Path $resolvedRoot 'sqlpysim/sqlpysim.py'
    $sqlpysimHelp = & python $sqlpysimPath --help | Out-String
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("sqlpysim --help failed with exit code $LASTEXITCODE")
    } else {
        Test-DocumentedOptions 'sqlpysim' 'sqlpysim/sqlpysim.md' $sqlpysimHelp
    }
    $sqlpysimVersion = (& python $sqlpysimPath --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("sqlpysim --version failed with exit code $LASTEXITCODE")
    } else {
        Write-Host $sqlpysimVersion
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "ERROR: $_" -ForegroundColor Red }
    exit 1
}

$validationMode = if ($SkipExecution) { 'structure only' } else { 'structure, entry points, and documented options' }
Write-Host "Package layout validation passed for: $($Tool -join ', ') ($validationMode)"
exit 0