#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Check if system is ready to build sqlsim
.DESCRIPTION
    Verifies that all prerequisites are installed before attempting to build
#>

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SQLSIM BUILD PREREQUISITES CHECK" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$allGood = $true

# Check PowerShell execution policy
Write-Host "`n1. Checking PowerShell execution policy..." -ForegroundColor Yellow
$policy = Get-ExecutionPolicy
if ($policy -eq "Restricted") {
    Write-Host "❌ PowerShell execution policy is Restricted" -ForegroundColor Red
    Write-Host "   Run: Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor White
    $allGood = $false
} else {
    Write-Host "✓ PowerShell execution policy: $policy" -ForegroundColor Green
}

# Check for Visual Studio Build Tools 2026/2022 or Visual Studio
Write-Host "`n2. Checking for Visual Studio Build Tools 2026/2022 or Visual Studio..." -ForegroundColor Yellow
$vsFound = $false
$foundWhat = ""

# Check Build Tools 2026 first (latest preferred)
$buildToolsPaths2026 = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
)

foreach ($path in $buildToolsPaths2026) {
    if (Test-Path $path) {
        Write-Host "✓ Found Visual Studio Build Tools 2026 (latest)" -ForegroundColor Green
        $vsFound = $true
        $foundWhat = "Build Tools 2026"
        
        # Check for CMake with Build Tools 2026
        $cmakeSearchPaths = @(
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
            "${env:ProgramFiles}\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        )
        
        $cmakeFound = $false
        foreach ($cmakePath in $cmakeSearchPaths) {
            if (Test-Path $cmakePath) {
                Write-Host "✓ CMake found with Build Tools 2026" -ForegroundColor Green
                $cmakeFound = $true
                break
            }
        }
        if (-not $cmakeFound) {
            Write-Host "⚠ CMake not found with Build Tools 2026 (may still work)" -ForegroundColor Yellow
        }
        break
    }
}

# If no Build Tools 2026, check for Build Tools 2022
if (-not $vsFound) {
    $buildToolsPaths2022 = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    )

    foreach ($path in $buildToolsPaths2022) {
        if (Test-Path $path) {
            Write-Host "✓ Found Visual Studio Build Tools 2022 (preferred)" -ForegroundColor Green
            $vsFound = $true
            $foundWhat = "Build Tools 2022"
            
            # Check for CMake with Build Tools 2022
            $cmakeSearchPaths = @(
                "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
                "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
            )
            
            $cmakeFound = $false
            foreach ($cmakePath in $cmakeSearchPaths) {
                if (Test-Path $cmakePath) {
                    Write-Host "✓ CMake found with Build Tools 2022" -ForegroundColor Green
                    $cmakeFound = $true
                    break
                }
            }
            if (-not $cmakeFound) {
                Write-Host "⚠ CMake not found with Build Tools 2022 (may still work)" -ForegroundColor Yellow
            }
            break
        }
    }
}

# If Build Tools not found, check for full Visual Studio (2026 then 2022)
if (-not $vsFound) {
    $vsEditions = @("Community", "Professional", "Enterprise")
    $vsVersions = @(
        @{ Version = "18"; DisplayName = "2026" },
        @{ Version = "2022"; DisplayName = "2022" }
    )
    
    foreach ($vsVersion in $vsVersions) {
        $vsPaths = @(
            "${env:ProgramFiles}\Microsoft Visual Studio\$($vsVersion.Version)",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\$($vsVersion.Version)"
        )

        foreach ($basePath in $vsPaths) {
            foreach ($edition in $vsEditions) {
                $testPath = Join-Path $basePath $edition "VC\Auxiliary\Build\vcvars64.bat"
                if (Test-Path $testPath) {
                    Write-Host "✓ Found Visual Studio $($vsVersion.DisplayName) $edition (fallback)" -ForegroundColor Yellow
                    $vsFound = $true
                    $foundWhat = "Visual Studio $($vsVersion.DisplayName) $edition"
                    
                    # Check for CMake
                    $cmakePath = Join-Path $basePath $edition "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
                    if (Test-Path $cmakePath) {
                        Write-Host "✓ CMake found with Visual Studio $($vsVersion.DisplayName)" -ForegroundColor Green
                    } else {
                        Write-Host "⚠ CMake not found with Visual Studio $($vsVersion.DisplayName) (may still work)" -ForegroundColor Yellow
                    }
                    
                    Write-Host "💡 Consider installing Build Tools for lighter development: https://aka.ms/vs/18/stable/vs_buildtools.exe" -ForegroundColor Cyan
                    break
                }
            }
            if ($vsFound) { break }
        }
        if ($vsFound) { break }
    }
}

# If nothing found, provide guidance
if (-not $vsFound) {
    Write-Host "❌ No Visual Studio 2022 or Build Tools found" -ForegroundColor Red
    Write-Host "`n🚀 RECOMMENDED: Visual Studio Build Tools 2022 (~1GB)" -ForegroundColor Cyan
    Write-Host "   Download: https://aka.ms/vs/17/release/vs_buildtools.exe" -ForegroundColor White
    Write-Host "`n💡 Alternative: Full Visual Studio 2022 (~3GB+)" -ForegroundColor Yellow
    Write-Host "   Download: https://visualstudio.microsoft.com/downloads/" -ForegroundColor White
    Write-Host "`n📋 During installation, select 'C++ build tools' workload" -ForegroundColor White
    $allGood = $false
}

# Check for ARM64 cross-compilation tools (required for build.ps1 ARM64 target)
Write-Host "`n2b. Checking for ARM64 cross-compilation tools..." -ForegroundColor Yellow
if ($vsFound) {
    $arm64Found = $false

    # Derive the base VS installation path from the x64 vcvars path we already found
    # Check Build Tools 2026
    $arm64SearchPaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvarsamd64_arm64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvarsamd64_arm64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsamd64_arm64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsamd64_arm64.bat"
    )

    # Also check full VS editions
    $vsEditionsArm = @("Community", "Professional", "Enterprise")
    $vsVersionsArm = @(
        @{ Version = "18"; DisplayName = "2026" },
        @{ Version = "2022"; DisplayName = "2022" }
    )
    foreach ($vsVer in $vsVersionsArm) {
        foreach ($basePath in @("${env:ProgramFiles}\Microsoft Visual Studio\$($vsVer.Version)", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\$($vsVer.Version)")) {
            foreach ($ed in $vsEditionsArm) {
                $arm64SearchPaths += Join-Path $basePath $ed "VC\Auxiliary\Build\vcvarsamd64_arm64.bat"
            }
        }
    }

    foreach ($arm64Path in $arm64SearchPaths) {
        if (Test-Path $arm64Path) {
            Write-Host "✓ ARM64 cross-compilation tools found (vcvarsamd64_arm64.bat)" -ForegroundColor Green
            $arm64Found = $true
            break
        }
    }

    if (-not $arm64Found) {
        Write-Host "⚠ ARM64 cross-compilation tools NOT found" -ForegroundColor Yellow
        Write-Host "   build.ps1 will fail for the ARM64 target without these tools" -ForegroundColor White
        Write-Host "   Use -Architecture x64 to build x64 only, or install the ARM64 tools:" -ForegroundColor White
        Write-Host "" -ForegroundColor White
        Write-Host "   Option 1: Visual Studio Installer UI" -ForegroundColor Cyan
        Write-Host "     -> Individual components -> search ARM64" -ForegroundColor White
        Write-Host "     -> Check: MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools (Latest)" -ForegroundColor White
        Write-Host "" -ForegroundColor White
        Write-Host "   Option 2: Command line (Build Tools)" -ForegroundColor Cyan
        Write-Host "     vs_buildtools.exe --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --passive" -ForegroundColor White
        Write-Host "" -ForegroundColor White
        Write-Host "   Option 3: Command line (Visual Studio)" -ForegroundColor Cyan
        Write-Host "     vs_installer.exe modify --installPath `"C:\...\2022\Enterprise`" --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --passive" -ForegroundColor White
    }
} else {
    Write-Host "⚠ Skipped (no Visual Studio found)" -ForegroundColor Yellow
}

# Check Windows version
Write-Host "`n3. Checking Windows version..." -ForegroundColor Yellow
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -ge 10) {
    Write-Host "✓ Windows version: $($osVersion)" -ForegroundColor Green
} else {
    Write-Host "⚠ Windows version: $($osVersion) (may have compatibility issues)" -ForegroundColor Yellow
}

# Check for ODBC Driver 18 for SQL Server (runtime requirement)
Write-Host "`n4. Checking for ODBC Driver 18 for SQL Server..." -ForegroundColor Yellow
try {
    $odbcDrivers = Get-OdbcDriver -Name "ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue
    if ($odbcDrivers) {
        Write-Host "✓ ODBC Driver 18 for SQL Server is installed" -ForegroundColor Green
    } else {
        Write-Host "⚠ ODBC Driver 18 for SQL Server not found" -ForegroundColor Yellow
        Write-Host "   This is required to run sqlsim (not needed for build)" -ForegroundColor White
        Write-Host "   Download: https://aka.ms/downloadmsodbcsql" -ForegroundColor White
    }
} catch {
    Write-Host "⚠ Could not check ODBC driver (non-critical for build)" -ForegroundColor Yellow
}

# Check available disk space
Write-Host "`n5. Checking disk space..." -ForegroundColor Yellow
try {
    $drive = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DeviceID -eq "C:" }
    $freeSpaceGB = [math]::Round($drive.FreeSpace / 1GB, 2)
    if ($freeSpaceGB -gt 5) {
        Write-Host "✓ Available disk space: $freeSpaceGB GB" -ForegroundColor Green
    } else {
        Write-Host "⚠ Low disk space: $freeSpaceGB GB (may cause build issues)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠ Could not check disk space" -ForegroundColor Yellow
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
if ($allGood) {
    Write-Host "✅ SYSTEM READY FOR BUILD" -ForegroundColor Green
    Write-Host "`nYou can now run: .\build.ps1" -ForegroundColor White
} else {
    Write-Host "❌ PREREQUISITES MISSING" -ForegroundColor Red
    Write-Host "`nPlease address the issues above before building" -ForegroundColor White
}
Write-Host "========================================" -ForegroundColor Cyan

# Scripts such as scripts\install-local.ps1 rely on a failing exit code.
exit $(if ($allGood) { 0 } else { 1 })