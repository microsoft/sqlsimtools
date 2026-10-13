#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Publish sqlsim executable and documentation to release directory
.DESCRIPTION
    Builds sqlsim (unless -SkipBuild), then stages a project-root installation
    with the tool under sqlsim/ and its skill under .github/skills/sqlsim/.

    Publishing into an existing project never overwrites a file whose contents
    differ, and never deletes files the project added, unless -Force is given.
    The repository's own release\sqlsimtools staging directory is disposable
    and is always refreshed.
.PARAMETER ReleaseDir
    Project root to install into. Defaults to release\sqlsimtools\1.0.
.PARAMETER SkipBuild
    Skip building sqlsim (use existing executable)
.PARAMETER Architecture
    All (default) publishes x64 and, when built, ARM64. x64 or ARM64 publishes
    only that architecture.
.PARAMETER Force
    Replace existing files that differ from this release.
.PARAMETER Preview
    List the files that would be created, replaced, or kept, and write nothing.
    Implies -SkipBuild.
.PARAMETER ReportPath
    Write a JSON report of created, replaced, unchanged, and kept files.
.EXAMPLE
    .\publish.ps1 -ReleaseDir C:\myproject -SkipBuild -Architecture x64 -Preview
#>

param(
    [string]$ReleaseDir = (Join-Path $PSScriptRoot '..\release\sqlsimtools\1.0'),
    [switch]$SkipBuild,
    [ValidateSet('All', 'x64', 'ARM64')]
    [string]$Architecture = 'All',
    [switch]$Force,
    [switch]$Preview,
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot '..\release\OverlayInstall.psm1') -Force
if ($Preview) { $SkipBuild = $true }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SQLSIM PUBLISH SCRIPT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Build sqlsim unless -SkipBuild
if (-not $SkipBuild) {
    $buildLabel = if ($Architecture -eq 'All') { 'x64 and ARM64' } else { $Architecture }
    Write-Host "Building sqlsim ($buildLabel)..." -ForegroundColor Yellow
    $buildScript = Join-Path $scriptDir "build.ps1"
    if (Test-Path $buildScript) {
        Push-Location $scriptDir
        if ($Architecture -eq 'All') {
            & $buildScript  # Builds both architectures by default
        } else {
            & $buildScript -Architecture $Architecture
        }
        $buildExitCode = $LASTEXITCODE
        Pop-Location
        if ($buildExitCode -ne 0) {
            Write-Host "ERROR: Build failed" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "ERROR: build.ps1 not found at $buildScript" -ForegroundColor Red
        exit 1
    }
}

$exePathX64 = Join-Path $scriptDir "build\x64\Release\sqlsim.exe"
$exePathARM64 = Join-Path $scriptDir "build\ARM64\Release\sqlsim.exe"
$docPath = Join-Path $scriptDir "sqlsim.md"
$licensePath = Join-Path $scriptDir "LICENSE"
$noticesPath = Join-Path $scriptDir "..\THIRD-PARTY-NOTICES.md"
$agentsPath = Join-Path $scriptDir "AGENTS.md"
$skillPath = Join-Path $scriptDir "..\.github\skills\sqlsim\SKILL.md"
$workloadAgentPath = Join-Path $scriptDir "..\.github\agents\sqlsimtools-workload-builder.agent.md"
$examplesPath = Join-Path $scriptDir "examples"
$assetsPath = Join-Path $scriptDir "..\assets"

# Ensure pandoc is in PATH (it's installed but may not be in PATH)
$pandocPath = "C:\Users\$env:USERNAME\AppData\Local\Pandoc"
if (Test-Path $pandocPath) {
    $env:PATH += ";$pandocPath"
}

# Generate HTML documentation from markdown using pandoc
Write-Host "Generating HTML documentation..." -ForegroundColor Cyan
$htmlPath = Join-Path $scriptDir "sqlsim.html"

# Custom CSS for Microsoft-style documentation
$customCss = @"
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    line-height: 1.6;
    max-width: 980px;
    margin: 0 auto;
    padding: 40px 20px;
    color: #24292e;
}
header#title-block-header {
    display: none;
}
h1 { color: #0078d4; border-bottom: 3px solid #0078d4; padding-bottom: 10px; margin-top: 30px; }
h2 { color: #005a9e; border-bottom: 2px solid #e1e4e8; padding-bottom: 8px; margin-top: 28px; }
h3 { color: #106ebe; margin-top: 24px; }
h4 { color: #005a9e; margin-top: 20px; }
code {
    background-color: #f6f8fa;
    padding: 2px 6px;
    border-radius: 3px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.9em;
}
pre {
    background-color: #f6f8fa;
    border: 1px solid #e1e4e8;
    border-radius: 6px;
    padding: 16px;
    overflow-x: auto;
}
pre code {
    background-color: transparent;
    padding: 0;
}
a { color: #0078d4; text-decoration: none; }
a:hover { text-decoration: underline; }
ul, ol {
    margin: 10px 0;
    padding-left: 30px;
}
li {
    margin: 6px 0;
    line-height: 1.5;
}
ul li {
    list-style-type: disc;
}
ul ul li {
    list-style-type: circle;
}
ul ul ul li {
    list-style-type: square;
}
blockquote {
    border-left: 4px solid #0078d4;
    padding-left: 16px;
    margin-left: 0;
    color: #57606a;
    font-style: italic;
}
table {
    border-collapse: collapse;
    width: 100%;
    margin: 20px 0;
}
th, td {
    border: 1px solid #e1e4e8;
    padding: 8px 12px;
    text-align: left;
}
th {
    background-color: #f6f8fa;
    font-weight: 600;
}
nav#TOC {
    background-color: #f6f8fa;
    border: 1px solid #e1e4e8;
    border-radius: 6px;
    padding: 20px;
    margin-bottom: 30px;
}
nav#TOC::before {
    content: "Table of Contents";
    display: block;
    font-weight: 600;
    font-size: 1.2em;
    margin-bottom: 15px;
    color: #0078d4;
}
nav#TOC > ul {
    list-style-type: none;
    padding-left: 0;
    margin: 0;
}
nav#TOC > ul > li {
    margin: 8px 0;
}
nav#TOC > ul > li > a {
    font-weight: 600;
}
nav#TOC ul ul {
    padding-left: 20px;
    margin-top: 5px;
}
nav#TOC li {
    margin: 4px 0;
}
nav#TOC a {
    color: #0078d4;
}
"@

$cssPath = Join-Path $scriptDir "temp-style.css"
$customCss | Out-File -Encoding UTF8 $cssPath

try {
    # Use pandoc to convert markdown to HTML with proper rendering
    # Options explained:
    # --standalone: Generate complete HTML document with <html>, <head>, <body>
    # --from=gfm: Use GitHub Flavored Markdown (better list support)
    # --css=<path>: Use custom CSS styling (absolute path required for --embed-resources)
    # --resource-path=<path>: Resolve Markdown assets from the sqlsim source directory
    # --embed-resources: Embed CSS directly in HTML (standalone file)
    # --metadata pagetitle: Set browser tab title without creating header block
    # Note: No --toc flag because sqlsim.md already has a manual TOC
    & pandoc $docPath -o $htmlPath `
        --standalone `
        --from=gfm `
        --css="$cssPath" `
        --resource-path="$scriptDir" `
        --embed-resources `
        --metadata pagetitle="SQLSIM - SQL Server Workload Simulator v1.0.0"
    
    # Inject logo into HTML after the opening <body> tag
    $logoPath = Join-Path $assetsPath "sqlsim-logo.svg"
    if (Test-Path $logoPath) {
        $svgContent = Get-Content $logoPath -Raw
        # Create logo header div with the SVG embedded
        $logoHtml = @"
<div style="text-align: center; margin: 20px 0 30px 0; padding: 20px; background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%); border-radius: 8px;">
$svgContent
</div>
"@
        $htmlContent = Get-Content $htmlPath -Raw
        # Insert logo after <body> tag
        $htmlContent = $htmlContent -replace '(<body[^>]*>)', "`$1`n$logoHtml"
        $htmlContent | Out-File -Encoding UTF8 $htmlPath
        Write-Host "  Logo embedded in HTML" -ForegroundColor Green
    }

    # Embed asset images as base64 data URIs
    $htmlContent = Get-Content $htmlPath -Raw
    $imgPattern = '<img[^>]*src="\.\./assets/([^"]+)"[^>]*>'
    $matches2 = [regex]::Matches($htmlContent, $imgPattern)
    foreach ($match in $matches2) {
        $imgFile = $match.Groups[1].Value
        $imgPath = Join-Path $assetsPath $imgFile
        if (Test-Path $imgPath) {
            $ext = [System.IO.Path]::GetExtension($imgFile).TrimStart('.')
            $mime = switch ($ext) { 'png' { 'image/png' } 'jpg' { 'image/jpeg' } 'jpeg' { 'image/jpeg' } 'gif' { 'image/gif' } 'svg' { 'image/svg+xml' } default { "image/$ext" } }
            $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imgPath))
            $dataUri = "data:$mime;base64,$b64"
            $htmlContent = $htmlContent.Replace($match.Value, $match.Value.Replace("../assets/$imgFile", $dataUri))
            Write-Host "  Image embedded: $imgFile" -ForegroundColor Green
        }
    }
    if ($matches2.Count -gt 0) {
        $htmlContent | Out-File -Encoding UTF8 $htmlPath
    }
    
    # Clean up temp CSS file
    Remove-Item $cssPath -ErrorAction SilentlyContinue
}
catch {
    Write-Host "Warning: pandoc not found. HTML generation skipped." -ForegroundColor Yellow
    Write-Host "Install pandoc for HTML documentation: winget install --id JohnMacFarlane.Pandoc" -ForegroundColor Yellow
    $htmlPath = $null
}

# Verify source files exist
$publishX64 = $Architecture -in @('All', 'x64')
$publishARM64 = $Architecture -in @('All', 'ARM64')

if ($publishX64 -and -not (Test-Path $exePathX64)) {
    Write-Host "ERROR: x64 sqlsim.exe not found at $exePathX64" -ForegroundColor Red
    Write-Host "Run .\build.ps1 first to build the executable" -ForegroundColor Yellow
    exit 1
}

$skipARM64 = -not $publishARM64
if ($publishARM64 -and -not (Test-Path $exePathARM64)) {
    if ($Architecture -eq 'ARM64') {
        Write-Host "ERROR: ARM64 sqlsim.exe not found at $exePathARM64" -ForegroundColor Red
        Write-Host "Run .\build.ps1 -Architecture ARM64 first." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "WARNING: ARM64 sqlsim.exe not found at $exePathARM64" -ForegroundColor Yellow
    Write-Host "ARM64 build will be skipped. Run .\build.ps1 -Architecture ARM64 to build it." -ForegroundColor Yellow
    $skipARM64 = $true
}

if (-not (Test-Path $docPath)) {
    Write-Host "ERROR: sqlsim.md not found at $docPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $licensePath)) {
    Write-Host "ERROR: LICENSE not found at $licensePath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $noticesPath)) {
    Write-Host "ERROR: THIRD-PARTY-NOTICES.md not found at $noticesPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $agentsPath)) {
    Write-Host "ERROR: AGENTS.md not found at $agentsPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $skillPath)) {
    Write-Host "ERROR: SKILL.md not found at $skillPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $workloadAgentPath)) {
    Write-Host "ERROR: Workload Builder agent not found at $workloadAgentPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $examplesPath)) {
    Write-Host "ERROR: examples folder not found at $examplesPath" -ForegroundColor Red
    exit 1
}

# Plan every file, then install without overwriting differing project files
# unless -Force is given.
$repositoryRoot = Split-Path -Parent $scriptDir
$disposable = Test-OverlayStagingDirectory -Target $ReleaseDir -RepositoryRoot $repositoryRoot

try {
    $plan = New-OverlayPlan -Root $ReleaseDir
    if ($publishX64) {
        Add-OverlayFile -Plan $plan -Source $exePathX64 -RelativePath 'sqlsim/x64/sqlsim.exe'
    }
    if (-not $skipARM64) {
        Add-OverlayFile -Plan $plan -Source $exePathARM64 -RelativePath 'sqlsim/ARM64/sqlsim.exe'
    }
    Add-OverlayFile -Plan $plan -Source $docPath -RelativePath 'sqlsim/sqlsim.md'
    Add-OverlayFile -Plan $plan -Source $licensePath -RelativePath 'sqlsim/LICENSE'
    Add-OverlayFile -Plan $plan -Source $noticesPath -RelativePath 'sqlsim/THIRD-PARTY-NOTICES.md'
    # AGENTS.md scopes agent guidance to the installed tool directory.
    Add-OverlayFile -Plan $plan -Source $agentsPath -RelativePath 'sqlsim/AGENTS.md'
    # Picked up by the VS Code Copilot skill system.
    Add-OverlayFile -Plan $plan -Source $skillPath -RelativePath '.github/skills/sqlsim/SKILL.md'
    # Shared VS Code custom agent for guided workload authoring and analysis.
    Add-OverlayFile -Plan $plan -Source $workloadAgentPath -RelativePath '.github/agents/sqlsimtools-workload-builder.agent.md'
    if ($htmlPath -and (Test-Path $htmlPath)) {
        Add-OverlayFile -Plan $plan -Source $htmlPath -RelativePath 'sqlsim/sqlsim.html'
    }
    Add-OverlayDirectory -Plan $plan -Source $examplesPath -RelativePath 'sqlsim/examples'
    # Replay XML must be created from XEvent files with these documented tools.
    Add-OverlayDirectory -Plan $plan -Source (Join-Path $scriptDir 'replay') -RelativePath 'sqlsim/replay'

    $null = Invoke-OverlayInstall -Plan $plan -Force:$Force -Preview:$Preview -Disposable:$disposable -ReportPath $ReportPath
    if ($Preview) {
        Write-Host ""
        Write-Host "PREVIEW COMPLETE: no files were written." -ForegroundColor Cyan
        exit 0
    }

    Write-Host ""
    
    # Validate HTML if it was generated
    if ($htmlPath -and (Test-Path $htmlPath)) {
        Write-Host "Validating HTML..." -ForegroundColor Cyan
        $htmlContent = Get-Content $htmlPath -Raw
        $validationErrors = @()
        
        # Check 1: DOCTYPE declaration
        if (-not ($htmlContent -match '<!DOCTYPE html>')) {
            $validationErrors += "Missing <!DOCTYPE html> declaration"
        }
        
        # Check 2: Basic structure tags
        if (-not ($htmlContent -match '<html[^>]*>')) {
            $validationErrors += "Missing <html> tag"
        }
        if (-not ($htmlContent -match '</html>')) {
            $validationErrors += "Missing </html> closing tag"
        }
        if (-not ($htmlContent -match '<head[^>]*>')) {
            $validationErrors += "Missing <head> tag"
        }
        if (-not ($htmlContent -match '</head>')) {
            $validationErrors += "Missing </head> closing tag"
        }
        if (-not ($htmlContent -match '<body[^>]*>')) {
            $validationErrors += "Missing <body> tag"
        }
        if (-not ($htmlContent -match '</body>')) {
            $validationErrors += "Missing </body> closing tag"
        }
        if (-not ($htmlContent -match '<title[^>]*>')) {
            $validationErrors += "Missing <title> tag"
        }
        
        # Check 3: Character encoding
        if (-not ($htmlContent -match 'charset=.*utf-8')) {
            $validationErrors += "Missing UTF-8 charset declaration"
        }
        
        # Check 4: Unclosed common tags (basic check)
        # Use word boundary to avoid matching thead when looking for th, etc.
        $tagPairs = @(
            @{ open = '<table\b'; close = '</table>' },
            @{ open = '<tr\b'; close = '</tr>' },
            @{ open = '<td\b'; close = '</td>' },
            @{ open = '<th\b'; close = '</th>' },
            @{ open = '<ul\b'; close = '</ul>' },
            @{ open = '<ol\b'; close = '</ol>' },
            @{ open = '<li\b'; close = '</li>' },
            @{ open = '<div\b'; close = '</div>' },
            @{ open = '<pre\b'; close = '</pre>' },
            @{ open = '<code\b'; close = '</code>' }
        )
        
        foreach ($tagPair in $tagPairs) {
            $openPattern = $tagPair.open + '[^>]*>'
            $closePattern = [regex]::Escape($tagPair.close)
            $openCount = ([regex]::Matches($htmlContent, $openPattern)).Count
            $closeCount = ([regex]::Matches($htmlContent, $closePattern)).Count
            if ($openCount -ne $closeCount) {
                $tagName = $tagPair.open -replace '\\b', '' -replace '<', ''
                $validationErrors += "Tag mismatch: $openCount opening '<$tagName>' vs $closeCount closing '</$tagName>'"
            }
        }
        
        # Check 5: Empty href or src attributes
        if ($htmlContent -match 'href\s*=\s*["''][""'']') {
            $validationErrors += "Found empty href attribute(s)"
        }
        if ($htmlContent -match 'src\s*=\s*["''][""'']') {
            $validationErrors += "Found empty src attribute(s)"
        }
        
        # Check 6: Broken internal links (anchors)
        $anchorLinks = [regex]::Matches($htmlContent, 'href="#([^"]+)"')
        $anchorIds = [regex]::Matches($htmlContent, 'id="([^"]+)"')
        $definedIds = $anchorIds | ForEach-Object { $_.Groups[1].Value }
        
        foreach ($link in $anchorLinks) {
            $targetId = $link.Groups[1].Value
            if ($targetId -notin $definedIds) {
                $validationErrors += "Broken internal link: #$targetId (no matching id found)"
            }
        }
        
        # Check 7: File size sanity check
        $fileSize = (Get-Item $htmlPath).Length
        if ($fileSize -lt 1000) {
            $validationErrors += "HTML file suspiciously small ($fileSize bytes)"
        }
        
        # Check 8: Verify HTML matches sqlsim.md content
        Write-Host "  Comparing HTML to sqlsim.md..." -ForegroundColor Gray
        $mdContent = Get-Content $docPath -Raw
        
        # Extract all markdown headers (## and ### level) and verify core text appears in HTML
        # Note: Pandoc may wrap long headers with newlines, so we extract key words
        $mdHeaders = [regex]::Matches($mdContent, '^#{2,3}\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $missingHeaders = @()
        
        foreach ($header in $mdHeaders) {
            $headerText = $header.Groups[1].Value.Trim()
            # Skip TOC entries (they have links)
            if ($headerText -match '^\[') { continue }
            # Extract key words from header (alphanumeric sequences of 4+ chars)
            $keyWords = [regex]::Matches($headerText, '[A-Za-z]{4,}') | ForEach-Object { $_.Value }
            # Check if at least 2 key words appear in HTML (handles line-wrapped headers)
            $foundCount = 0
            foreach ($word in $keyWords) {
                if ($htmlContent -match "\b$word\b") {
                    $foundCount++
                }
            }
            # If header has key words but less than half are found, flag it
            if ($keyWords.Count -ge 2 -and $foundCount -lt [Math]::Ceiling($keyWords.Count / 2)) {
                $missingHeaders += $headerText
            }
            elseif ($keyWords.Count -eq 1 -and $foundCount -eq 0) {
                $missingHeaders += $headerText
            }
        }
        
        if ($missingHeaders.Count -gt 0) {
            $validationErrors += "Missing headers from sqlsim.md in HTML:"
            foreach ($h in $missingHeaders) {
                $validationErrors += "  - $h"
            }
        }
        
        # Extract key parameter names from markdown tables and verify in HTML
        $paramMatches = [regex]::Matches($mdContent, '\|\s*`(-[A-Za-z]+)`')
        $missingParams = @()
        foreach ($param in $paramMatches) {
            $paramName = $param.Groups[1].Value
            if (-not ($htmlContent -match [regex]::Escape($paramName))) {
                $missingParams += $paramName
            }
        }
        
        if ($missingParams.Count -gt 0) {
            $validationErrors += "Missing parameters from sqlsim.md in HTML: $($missingParams -join ', ')"
        }
        
        # Verify key content phrases exist in both (spot check)
        $keyPhrases = @(
            'SQL Server Workload Simulator',
            'Command-Line Parameters',
            'total_batches',
            'batch_count',
            'stoponerror',
            'Entra',
            'JSON Output',
            'GO batch separator'
        )
        $missingPhrases = @()
        foreach ($phrase in $keyPhrases) {
            $inMd = $mdContent -match [regex]::Escape($phrase)
            $inHtml = $htmlContent -match [regex]::Escape($phrase)
            if ($inMd -and -not $inHtml) {
                $missingPhrases += $phrase
            }
        }
        
        if ($missingPhrases.Count -gt 0) {
            $validationErrors += "Key phrases in sqlsim.md missing from HTML: $($missingPhrases -join ', ')"
        }
        
        # Check HTML was generated from current markdown (timestamp comparison)
        $mdTimestamp = (Get-Item $docPath).LastWriteTime
        $htmlTimestamp = (Get-Item $htmlPath).LastWriteTime
        if ($htmlTimestamp -lt $mdTimestamp) {
            $validationErrors += "HTML is older than sqlsim.md (HTML: $htmlTimestamp, MD: $mdTimestamp) - regenerate HTML"
        }
        
        # Report validation results
        if ($validationErrors.Count -eq 0) {
            Write-Host "✓ HTML validation passed" -ForegroundColor Green
            Write-Host "✓ HTML content matches sqlsim.md" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "HTML VALIDATION WARNINGS:" -ForegroundColor Yellow
            foreach ($err in $validationErrors) {
                Write-Host "  ! $err" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Consider reviewing sqlsim.html manually" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "PUBLISH SUCCESSFUL!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Files published to: $ReleaseDir" -ForegroundColor Cyan
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "ERROR: Failed to publish files" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Callers read $LASTEXITCODE; without this it can still hold a native tool's code.
exit 0
