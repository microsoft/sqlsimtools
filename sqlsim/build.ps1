#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Build script for sqlsim using Visual Studio tools
.DESCRIPTION
    Robust build script that finds Visual Studio 2026/2022 installation automatically
    and builds sqlsim using cmake and MSBuild.
.PARAMETER Clean
    Clean the build directory before building
.PARAMETER Configuration  
    Build configuration (Debug or Release). Default: Release
.PARAMETER Architecture
    Target architecture (x64, ARM64, or All). Default: All (builds both)
.PARAMETER Verbose
    Show detailed build output in real-time
.PARAMETER DebugODBC
    Enable detailed debug logging for all ODBC operations
#>

param(
    [switch]$Clean,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("x64", "ARM64", "All")]
    [string]$Architecture = "All",
    [switch]$Verbose,
    [switch]$DebugODBC
)

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM BUILD SCRIPT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Determine which architectures to build
if ($Architecture -eq "All") {
    $architectures = @("x64", "ARM64")
    Write-Host "Target architectures: x64, ARM64" -ForegroundColor Cyan
} else {
    $architectures = @($Architecture)
    Write-Host "Target architecture: $Architecture" -ForegroundColor Cyan
}

# Function to build a single architecture
function Build-SingleArchitecture {
    param(
        [string]$Arch,
        [switch]$CleanBuild,
        [string]$Config,
        [switch]$VerboseOutput,
        [switch]$DebugODBCFlag
    )
    
    if ($architectures.Count -gt 1) {
        Write-Host "`n----------------------------------------" -ForegroundColor Cyan
        Write-Host "Building $Arch..." -ForegroundColor Cyan
        Write-Host "----------------------------------------" -ForegroundColor Cyan
    }

    # Determine vcvars batch file based on architecture
    # x64: vcvars64.bat (native x64)
    # ARM64: vcvarsamd64_arm64.bat (cross-compile from x64 to ARM64)
    $vcvarsSuffix = if ($Arch -eq "ARM64") { "vcvarsamd64_arm64.bat" } else { "vcvars64.bat" }

    # Find Visual Studio Build Tools or Visual Studio installation
    $vsPath = $null
    $foundInstallation = ""

    Write-Host "Searching for Visual Studio Build Tools (2026, then 2022)..." -ForegroundColor Cyan

    # Check for Build Tools 2026 first (latest - stored as version 18)
    $buildToolsPaths2026 = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\$vcvarsSuffix",
        "${env:ProgramFiles}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\$vcvarsSuffix"
    )

    foreach ($path in $buildToolsPaths2026) {
        if (Test-Path $path) {
            $vsPath = $path
            $foundInstallation = "Visual Studio Build Tools 2026"
            break
        }
    }

    # If no 2026 Build Tools, check for 2022 Build Tools
    if (-not $vsPath) {
        $buildToolsPaths2022 = @(
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\$vcvarsSuffix",
            "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\$vcvarsSuffix"
        )
        
        foreach ($path in $buildToolsPaths2022) {
            if (Test-Path $path) {
                $vsPath = $path
                $foundInstallation = "Visual Studio Build Tools 2022"
                break
            }
        }
    }

    # Determine CMake generator
    $cmakeGenerator = "Visual Studio 17 2022"  # Default

    # If no Build Tools found, fall back to full Visual Studio (2026 then 2022)
    if (-not $vsPath) {
        Write-Host "Build Tools not found, checking for Visual Studio installations..." -ForegroundColor Gray
        
        $vsEditions = @("Community", "Professional", "Enterprise")
        $vsVersions = @(
            @{ Version = "18"; Generator = "Visual Studio 18 2026"; DisplayName = "2026" },
            @{ Version = "2022"; Generator = "Visual Studio 17 2022"; DisplayName = "2022" }
        )
        
        foreach ($vsVersion in $vsVersions) {
            $vsPaths = @(
                "${env:ProgramFiles}\Microsoft Visual Studio\$($vsVersion.Version)",
                "${env:ProgramFiles(x86)}\Microsoft Visual Studio\$($vsVersion.Version)"
            )
            
            foreach ($basePath in $vsPaths) {
                foreach ($edition in $vsEditions) {
                    $testPath = Join-Path $basePath $edition "VC\Auxiliary\Build\$vcvarsSuffix"
                    if (Test-Path $testPath) {
                        $vsPath = $testPath
                        $foundInstallation = "Visual Studio $($vsVersion.DisplayName) $edition (fallback)"
                        $cmakeGenerator = $vsVersion.Generator
                        break
                    }
                }
                if ($vsPath) { break }
            }
            if ($vsPath) { break }
        }
    }

    if ($vsPath) {
        Write-Host "✓ Found: $foundInstallation" -ForegroundColor Green
        Write-Host "Using compiler environment from: $vsPath" -ForegroundColor Gray
        
        # Show recommendation if using Visual Studio instead of Build Tools
        if ($foundInstallation -like "*fallback*") {
            Write-Host "💡 For lighter development, consider installing Build Tools: https://aka.ms/vs/17/release/vs_buildtools.exe" -ForegroundColor Yellow
        }
    } else {
        Write-Host "`n❌ ERROR: No Visual Studio 2022 or Build Tools found" -ForegroundColor Red
        
        Write-Host "`n🚀 RECOMMENDED: Visual Studio Build Tools 2022 (lightweight, ~1GB)" -ForegroundColor Cyan
        Write-Host "   Download: https://aka.ms/vs/17/release/vs_buildtools.exe" -ForegroundColor White
        Write-Host "   Run as Administrator and select 'C++ build tools' workload" -ForegroundColor White
        
        Write-Host "`n💡 Alternative: Full Visual Studio 2022 (heavier, ~3GB+)" -ForegroundColor Yellow
        Write-Host "   Download: https://visualstudio.microsoft.com/downloads/" -ForegroundColor White
        
        Write-Host "`n📋 During installation, ensure you select:" -ForegroundColor Cyan
        Write-Host "   ✓ C++ build tools" -ForegroundColor White
        Write-Host "   ✓ CMake tools" -ForegroundColor White
        Write-Host "   ✓ Windows 10/11 SDK" -ForegroundColor White
        
        Write-Host "`n💻 For VS Code development: Build Tools is the optimal choice" -ForegroundColor Green
        return $false
    }

    # Update CMake generator based on found installation
    if ($foundInstallation -like "*2026*") {
        $cmakeGenerator = "Visual Studio 18 2026"
    } elseif ($foundInstallation -like "*2022*") {
        $cmakeGenerator = "Visual Studio 17 2022"
    }

    # Architecture-specific build directory. Anchored to this script, not the
    # current directory, so -Clean can only ever empty sqlsim's own build output.
    $buildDir = Join-Path $PSScriptRoot "build\$Arch"

    # Clean build directory if requested
    if ($CleanBuild) {
        Write-Host "Cleaning build directory..." -ForegroundColor Yellow
        if (Test-Path $buildDir) {
            Remove-Item -Recurse -Force "$buildDir\*"
        }
    }

    # Ensure build directory exists
    if (-not (Test-Path $buildDir)) {
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    }

    # Prepare compiler flags
    $compilerFlags = ""
    if ($DebugODBCFlag) {
        $compilerFlags = '/DDEBUG_ODBC'
        Write-Host "Debug mode enabled:" -ForegroundColor Yellow
        Write-Host "  - ODBC operations logging" -ForegroundColor Yellow
    }

    # Build using CMD with VS environment
    if ($VerboseOutput) {
        # Verbose mode: Add detailed output flags
        $buildScript = @"
call "$vsPath"
cd /d "$buildDir"
cmake ../.. -G "$cmakeGenerator" -A $Arch --log-level=VERBOSE -DCMAKE_CXX_FLAGS="$compilerFlags"
cmake --build . --config $Config --verbose
"@
    } else {
        # Normal mode: Standard output
        $buildScript = @"
call "$vsPath"
cd /d "$buildDir"
cmake ../.. -G "$cmakeGenerator" -A $Arch -DCMAKE_CXX_FLAGS="$compilerFlags"
cmake --build . --config $Config
"@
    }

    Write-Host "Configuring build environment and compiling..." -ForegroundColor Cyan
    if ($VerboseOutput) {
        Write-Host "Verbose mode: Showing detailed build output" -ForegroundColor Yellow
    }

    $tempScript = [System.IO.Path]::GetTempFileName() + ".bat"
    try {
        $buildScript | Out-File -FilePath $tempScript -Encoding ASCII
        
        if ($VerboseOutput) {
            # Verbose mode: Show output in real-time
            Write-Host "`nBuild command:" -ForegroundColor Gray
            Write-Host $buildScript -ForegroundColor DarkGray
            Write-Host "`n--- BUILD OUTPUT ---" -ForegroundColor Gray
            
            # Execute and show output in real-time
            & cmd.exe /c "`"$tempScript`""
            $exitCode = $LASTEXITCODE
            
            Write-Host "--- BUILD COMPLETE ---`n" -ForegroundColor Gray
        } else {
            # Default mode: Capture output, show only on error
            $result = & cmd.exe /c "`"$tempScript`"" 2>&1
            $exitCode = $LASTEXITCODE
        }
        
        if ($exitCode -ne 0) {
            if (-not $VerboseOutput) {
                Write-Host "Build output:" -ForegroundColor Yellow
                $result | ForEach-Object { Write-Host "  $_" }
            }
            Write-Host "ERROR: $Arch build failed with exit code $exitCode" -ForegroundColor Red
            return $false
        }
        
        # Verify executable was created
        $exePath = "$buildDir\$Config\sqlsim.exe"
        if (Test-Path $exePath) {
            Write-Host "`n========================================" -ForegroundColor Green  
            Write-Host "BUILD SUCCESSFUL! ($Arch)" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "Executable: $((Resolve-Path $exePath).Path)" -ForegroundColor White
            return $true
        } else {
            Write-Host "ERROR: Build completed but executable not found at: $exePath" -ForegroundColor Red
            return $false
        }
    }
    finally {
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force
        }
    }
}

# Build each architecture
$successCount = 0
$failCount = 0

foreach ($arch in $architectures) {
    $result = Build-SingleArchitecture -Arch $arch -CleanBuild:$Clean -Config $Configuration -VerboseOutput:$Verbose -DebugODBCFlag:$DebugODBC
    if ($result) {
        $successCount++
    } else {
        $failCount++
    }
}

# Final summary
if ($architectures.Count -gt 1) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BUILD SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Successful: $successCount" -ForegroundColor $(if ($successCount -gt 0) { "Green" } else { "Gray" })
    Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
}

if ($failCount -eq 0) {
    Write-Host "`nYou can now run tests:" -ForegroundColor Cyan
    Write-Host "  .\smoke-test.ps1          # Quick validation" -ForegroundColor White
    Write-Host "  .\full-test-suite.ps1     # Comprehensive validation" -ForegroundColor White
    exit 0
} else {
    exit 1
}
