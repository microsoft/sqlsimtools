<#
.SYNOPSIS
    Publishes sqlpysim to the release directory with HTML documentation.

.DESCRIPTION
    This script:
    1. Generates HTML documentation from sqlpysim.md using pandoc
    2. Stages a project-root installation with the tool under sqlpysim/ and
       its skill under .github/skills/sqlpysim/

.PARAMETER ReleaseDir
    Project root to install into. Defaults to release\sqlsimtools\1.0.

.PARAMETER SkipHtmlGeneration
    Skip HTML generation (use existing sqlpysim.html).

.PARAMETER Force
    Replace existing files that differ from this release. Without it,
    publishing into an existing project stops before writing anything if a
    file would be replaced. The repository's release\sqlsimtools staging
    directory is disposable and is always refreshed.

.PARAMETER Preview
    List the files that would be created, replaced, or kept, and write nothing.

.PARAMETER ReportPath
    Write a JSON report of created, replaced, unchanged, and kept files.

.EXAMPLE
    .\publish.ps1
    
.EXAMPLE
    .\publish.ps1 -ReleaseDir "C:\custom\project-root" -Preview
#>

param(
    [string]$ReleaseDir = "",
    [switch]$SkipHtmlGeneration,
    [switch]$Force,
    [switch]$Preview,
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot '..\release\OverlayInstall.psm1') -Force

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "sqlpysim Publish Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Determine script and project paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptDir

# Source paths
$pythonScript = Join-Path $projectRoot "sqlpysim.py"
$docPath = Join-Path $projectRoot "sqlpysim.md"
$htmlPath = Join-Path $projectRoot "sqlpysim.html"
$examplesPath = Join-Path $projectRoot "examples"
$requirementsPath = Join-Path $projectRoot "requirements.txt"
$macosPreviewPath = Join-Path $projectRoot "MACOS-PRIVATE-PREVIEW.md"
$setupPath = Join-Path $projectRoot "setup.py"
$licensePath = Join-Path $projectRoot "LICENSE"
$noticesPath = Join-Path $projectRoot "..\THIRD-PARTY-NOTICES.md"
$agentsPath = Join-Path $projectRoot "AGENTS.md"
$skillPath = Join-Path $projectRoot "..\.github\skills\sqlpysim\SKILL.md"
$workloadAgentPath = Join-Path $projectRoot "..\.github\agents\sqlsimtools-workload-builder.agent.md"

# Verify source files exist
Write-Host "Verifying source files..." -ForegroundColor Cyan
$requiredFiles = @($pythonScript, $docPath, $examplesPath, $requirementsPath, $macosPreviewPath, $licensePath, $noticesPath, $agentsPath, $skillPath, $workloadAgentPath)
$missingFiles = @()

foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        $missingFiles += $file
    }
}

if ($missingFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: Missing required files:" -ForegroundColor Red
    foreach ($f in $missingFiles) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}

Write-Host "✓ All required source files found" -ForegroundColor Green
Write-Host ""

# Set release directory
if ([string]::IsNullOrEmpty($ReleaseDir)) {
    $ReleaseDir = Join-Path (Split-Path -Parent $projectRoot) "release\sqlsimtools\1.0"
}

# Generate HTML from markdown using pandoc
if (-not $SkipHtmlGeneration) {
    Write-Host "Generating HTML documentation..." -ForegroundColor Cyan
    
    # Check if pandoc is available
    $pandocPath = Get-Command pandoc -ErrorAction SilentlyContinue
    if (-not $pandocPath) {
        Write-Host "WARNING: pandoc not found. Skipping HTML generation." -ForegroundColor Yellow
        Write-Host "         Install pandoc from https://pandoc.org/installing.html" -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        # Custom CSS - GitHub-inspired style matching sqlsim
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
        
        # Create temp CSS file
        $tempCssPath = Join-Path ([IO.Path]::GetTempPath()) ("sqlpysim-style-{0}.css" -f [guid]::NewGuid().ToString('N'))
        $customCss | Out-File -FilePath $tempCssPath -Encoding utf8
        
        # Python/SQL themed logo SVG (embedded for standalone HTML)
        $logoSvg = @"
<div style="text-align: center; margin: 20px 0 30px 0; padding: 20px; background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%); border-radius: 8px;">
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 120" width="400" height="120">
  <defs>
    <linearGradient id="pyBlue" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#5A9FD4;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#306998;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="pyYellow" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#FFE873;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#FFD43B;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="dbGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#3498db;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#2980b9;stop-opacity:1" />
    </linearGradient>
    <linearGradient id="speedGrad" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#e74c3c;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#f39c12;stop-opacity:1" />
    </linearGradient>
  </defs>
  
  <!-- Icon portion (left side) - matching sqlsim structure -->
  <g transform="translate(10, 10) scale(0.78)">
    <!-- Database cylinder body -->
    <ellipse cx="64" cy="28" rx="44" ry="14" fill="url(#dbGrad)" opacity="0.7"/>
    <rect x="20" y="28" width="88" height="64" fill="url(#dbGrad)" opacity="0.7"/>
    <ellipse cx="64" cy="92" rx="44" ry="14" fill="#2471a3" opacity="0.7"/>
    
    <!-- Highlight on top ellipse -->
    <ellipse cx="64" cy="28" rx="38" ry="9" fill="white" opacity="0.15"/>
    
    <!-- Python logo (small, centered in cylinder) -->
    <g transform="translate(50, 38) scale(0.55)">
      <!-- Blue half -->
      <path d="M25,2c-6,0-11,3.5-11,9v6h11v2H8c-3.5,0-8,3-8,11s3.5,11,8,11h6v-6c0-3.5,3-7,7-7h11c3.5,0,6-2.5,6-6v-10c0-5.5-5-10-12-10z" fill="url(#pyBlue)"/>
      <circle cx="17" cy="11" r="3" fill="#FFD43B"/>
      <!-- Yellow half -->
      <path d="M17,58c6,0,11-3.5,11-9v-6H17v-2h17c3.5,0,8-3,8-11s-3.5-11-8-11h-6v6c0,3.5-3,7-7,7H10c-3.5,0-6,2.5-6,6v10c0,5.5,5,10,12,10z" fill="url(#pyYellow)"/>
      <circle cx="25" cy="49" r="3" fill="#306998"/>
    </g>
    
    <!-- Speed arrows (inside cylinder, below Python logo) -->
    <g transform="translate(30, 74)">
      <path d="M0,4 L18,4 L18,0 L28,8 L18,16 L18,12 L0,12 Z" fill="url(#speedGrad)" opacity="0.95"/>
      <path d="M22,4 L40,4 L40,0 L50,8 L40,16 L40,12 L22,12 Z" fill="url(#speedGrad)" opacity="0.75"/>
      <path d="M44,4 L62,4 L62,0 L72,8 L62,16 L62,12 L44,12 Z" fill="url(#speedGrad)" opacity="0.55"/>
    </g>
  </g>
  
  <!-- Text: sqlpysim (matching sqlsim font size 52, blue for sql, yellow for pysim) -->
  <text x="135" y="78" font-family="Segoe UI, Arial, sans-serif" font-size="52" font-weight="bold">
    <tspan fill="#3498db">sql</tspan><tspan fill="#FFD43B">pysim</tspan>
  </text>
  
  <!-- Tagline -->
  <text x="137" y="100" font-family="Segoe UI, Arial, sans-serif" font-size="14" fill="#7f8c8d">SQL Python Workload Simulator</text>
</svg>
</div>
"@
        
        try {
            # Run pandoc to generate HTML
            $pandocArgs = @(
                $docPath,
                "-o", $htmlPath,
                "--standalone",
                "--from=gfm",
                "--metadata", "title=sqlpysim - SQL Python Workload Simulator",
                "--css", $tempCssPath,
                "--embed-resources"
            )
            
            & pandoc @pandocArgs 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                throw "pandoc failed with exit code $LASTEXITCODE"
            }
            
            # Read generated HTML and inject logo after <body>
            $htmlContent = Get-Content $htmlPath -Raw
            $htmlContent = $htmlContent -replace '(<body[^>]*>)', "`$1`n$logoSvg"
            $htmlContent | Out-File -FilePath $htmlPath -Encoding utf8
            
            Write-Host "✓ Generated: sqlpysim.html" -ForegroundColor Green
            
            # Cleanup temp CSS
            Remove-Item $tempCssPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "WARNING: HTML generation failed: $_" -ForegroundColor Yellow
            Write-Host "         Continuing without HTML..." -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "Skipping HTML generation (using existing file if present)" -ForegroundColor Yellow
}

Write-Host ""

# Plan every file, then install without overwriting differing project files
# unless -Force is given.
$disposable = Test-OverlayStagingDirectory -Target $ReleaseDir -RepositoryRoot (Split-Path -Parent $projectRoot)

try {
    $plan = New-OverlayPlan -Root $ReleaseDir
    Add-OverlayFile -Plan $plan -Source $pythonScript -RelativePath 'sqlpysim/sqlpysim.py'
    Add-OverlayFile -Plan $plan -Source $docPath -RelativePath 'sqlpysim/sqlpysim.md'
    if (Test-Path $htmlPath) {
        Add-OverlayFile -Plan $plan -Source $htmlPath -RelativePath 'sqlpysim/sqlpysim.html'
    }
    Add-OverlayFile -Plan $plan -Source $requirementsPath -RelativePath 'sqlpysim/requirements.txt'
    Add-OverlayFile -Plan $plan -Source $macosPreviewPath -RelativePath 'sqlpysim/MACOS-PRIVATE-PREVIEW.md'
    Add-OverlayFile -Plan $plan -Source $licensePath -RelativePath 'sqlpysim/LICENSE'
    Add-OverlayFile -Plan $plan -Source $noticesPath -RelativePath 'sqlpysim/THIRD-PARTY-NOTICES.md'
    if (Test-Path $setupPath) {
        Add-OverlayFile -Plan $plan -Source $setupPath -RelativePath 'sqlpysim/setup.py'
    }
    Add-OverlayDirectory -Plan $plan -Source $examplesPath -RelativePath 'sqlpysim/examples'
    # AGENTS.md scopes agent guidance to the installed tool directory.
    Add-OverlayFile -Plan $plan -Source $agentsPath -RelativePath 'sqlpysim/AGENTS.md'
    # Picked up by the VS Code Copilot skill system.
    Add-OverlayFile -Plan $plan -Source $skillPath -RelativePath '.github/skills/sqlpysim/SKILL.md'
    # Shared VS Code custom agent for guided workload authoring and analysis.
    Add-OverlayFile -Plan $plan -Source $workloadAgentPath -RelativePath '.github/agents/sqlsimtools-workload-builder.agent.md'

    $null = Invoke-OverlayInstall -Plan $plan -Force:$Force -Preview:$Preview -Disposable:$disposable -ReportPath $ReportPath
    if ($Preview) {
        Write-Host ""
        Write-Host "PREVIEW COMPLETE: no files were written." -ForegroundColor Cyan
        exit 0
    }

    Write-Host ""
    
    # Validate HTML if it exists
    if (Test-Path $htmlPath) {
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
        
        # Check 4: File size sanity check
        $fileSize = (Get-Item $htmlPath).Length
        if ($fileSize -lt 1000) {
            $validationErrors += "HTML file suspiciously small ($fileSize bytes)"
        }
        
        # Check 5: Verify HTML matches sqlpysim.md content
        Write-Host "  Comparing HTML to sqlpysim.md..." -ForegroundColor Gray
        $mdContent = Get-Content $docPath -Raw
        
        # Verify key content phrases exist in both
        $keyPhrases = @(
            'SQL Python Workload Simulator',
            'Command-Line Parameters',
            'mssql-python',
            'JSON Output',
            'Entra'
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
            $validationErrors += "Key phrases in sqlpysim.md missing from HTML: $($missingPhrases -join ', ')"
        }
        
        # Check HTML was generated from current markdown (timestamp comparison)
        $mdTimestamp = (Get-Item $docPath).LastWriteTime
        $htmlTimestamp = (Get-Item $htmlPath).LastWriteTime
        if ($htmlTimestamp -lt $mdTimestamp) {
            $validationErrors += "HTML is older than sqlpysim.md (HTML: $htmlTimestamp, MD: $mdTimestamp) - regenerate HTML"
        }
        
        # Report validation results
        if ($validationErrors.Count -eq 0) {
            Write-Host "✓ HTML validation passed" -ForegroundColor Green
            Write-Host "✓ HTML content matches sqlpysim.md" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "HTML VALIDATION WARNINGS:" -ForegroundColor Yellow
            foreach ($err in $validationErrors) {
                Write-Host "  ! $err" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Consider reviewing sqlpysim.html manually" -ForegroundColor Yellow
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
