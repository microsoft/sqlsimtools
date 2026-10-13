# Developer Setup Guide

This guide helps new developers set up the complete development environment for sqlsim using VS Code.

**How This Tool Was Built:**
100% of the code, scripts, and documentation for sqlsim was developed with GitHub Copilot in Visual Studio Code using various AI models, but 100% orchestrated by Bob Ward.

## Prerequisites

### Ubuntu 24.04/26.04 LTS x64

Install the compiler and unixODBC headers:

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake unixodbc-dev
```

Install Microsoft ODBC Driver 18 using the official Linux instructions: <https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server>.

Then validate, build, and run the offline smoke suite:

```bash
bash ./check-prerequisites-linux.sh --require-driver
bash ./build-linux.sh --clean
bash ./smoke-test-linux.sh --skip-build
```

The supported Linux build output is `build/linux-x64/sqlsim`.

### macOS Apple Silicon ARM64 (Private Preview)

This invitation-only path is for customer and tester validation; macOS is not included in public releases. On an Apple Silicon Mac:

```bash
brew install cmake unixodbc
bash ./check-prerequisites-macos.sh
bash ./build-macos.sh --clean
bash ./smoke-test-macos.sh --skip-build
```

The Private Preview output is `build/macos-arm64/sqlsim`. Microsoft ODBC Driver 18 is additionally required for live database connections.

### Windows

### 1. Visual Studio Code
**Download:** https://code.visualstudio.com/
- Install with default settings
- Restart after installation

### 2. Visual Studio Build Tools 2026 or 2022 (Recommended) or Visual Studio Community

#### Option A: Visual Studio Build Tools (Lightweight, ~1GB)

`build.ps1` detects Build Tools 2026 first, then 2022. The link below installs
2022; Build Tools 2026 is available from
<https://visualstudio.microsoft.com/downloads/>.
**Recommended for VS Code developers**

**Manual Install (Recommended):**
1. Download: https://aka.ms/vs/17/release/vs_buildtools.exe
2. Run the installer as Administrator
3. In the installer, select **"C++ build tools"** workload
4. Ensure these components are selected:
   - MSVC v143 - VS 2022 C++ x64/x86 build tools (latest)
   - Windows 11 SDK (latest version)
   - CMake tools for Visual Studio
5. Click Install and wait for completion

**Alternative - Command Line Install:**
```powershell
# Download installer
Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile "vs_buildtools.exe"

# Run installer with C++ components (as Administrator)
.\vs_buildtools.exe --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --wait
```

**Note:** winget may show Build Tools as "installed" but without C++ components. Use the manual method above to ensure proper installation.

#### Option B: Visual Studio Community 2022 (Full IDE, ~3GB+)
**Download:** https://visualstudio.microsoft.com/downloads/
- During installation, select the **"Desktop development with C++"** workload
- Ensure CMake tools are included

### 3. ODBC Driver 18 for SQL Server
**Download:** https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server
- Download "Windows x64" version
- Run installer with default settings
- Required for connecting to SQL Server/Azure SQL

Current documented baseline is ODBC Driver 18.6.2.1. For ongoing policy and cadence, see [../DRIVER-COMPATIBILITY.md](../DRIVER-COMPATIBILITY.md).

### 4. CMake (if not included with Build Tools)
**Download:** https://cmake.org/download/
- Add to system PATH during installation
- Or install via winget: `winget install Kitware.CMake`

## VS Code Extensions

Install these essential extensions in VS Code:

### Required Extensions

1. **C/C++** by Microsoft (`ms-vscode.cpptools`)
   - Provides IntelliSense, debugging, and code browsing
   
2. **C/C++ Extension Pack** by Microsoft (`ms-vscode.cpptools-extension-pack`)
   - Includes C/C++, CMake Tools, and other helpful extensions
   
3. **CMake Tools** by Microsoft (`ms-vscode.cmake-tools`)
   - CMake integration, build configuration, and debugging

### Recommended Extensions

4. **PowerShell** by Microsoft (`ms-vscode.powershell`)
   - For editing build scripts and running PowerShell commands
   
5. **GitLens** by GitKraken (`eamodio.gitlens`)
   - Enhanced Git capabilities
   
6. **Error Lens** by Alexander (`usernamehw.errorlens`)
   - Highlights errors and warnings inline

### Install Extensions via Command Line
```powershell
# Install all recommended extensions at once
code --install-extension ms-vscode.cpptools-extension-pack
code --install-extension ms-vscode.powershell
code --install-extension eamodio.gitlens
code --install-extension usernamehw.errorlens
```

## Project Setup

### 1. Clone and Open Project
```powershell
# Clone the repository
git clone <your-repo-url>
cd sqlsim

# Open in VS Code
code .
```

### 2. Verify Your Environment
Run our prerequisite checker:
```powershell
.\check-prerequisites.ps1
```

This script will verify:
- Visual Studio Build Tools or VS Community
- CMake availability
- ODBC Driver 18 for SQL Server
- PowerShell version (5.1 or later required - all scripts are compatible with Windows PowerShell 5.1)

### 3. Build the Project
```powershell
# Clean build
.\build.ps1 -Clean

# Or just build
.\build.ps1
```

### 4. Run Smoke Tests
```powershell
# Quick functionality test
.\smoke-test.ps1 -SkipBuild
```

## VS Code Configuration

The project includes these VS Code configuration files:

### `.vscode/c_cpp_properties.json`
- Configures IntelliSense paths and compiler settings
- Automatically configured for Windows with MSVC

### `.vscode/launch.json`
- Debug configurations for the sqlsim executable
- Includes sample command line arguments

### `.vscode/tasks.json`
- Build tasks integrated with VS Code
- Allows building with Ctrl+Shift+P → "Tasks: Run Task"

### `.vscode/settings.json`
- Project-specific settings
- Configures CMake and C++ defaults

## Quick Verification

After setup, verify everything works:

1. **Open the project in VS Code**
2. **Check IntelliSense**: Open `src/main.cpp` - you should see syntax highlighting and error checking
3. **Build**: Press `Ctrl+Shift+P` → "CMake: Build" or use `.\build.ps1`
4. **Debug**: Press F5 to launch debugger (requires build first)

## Troubleshooting

### "CMake not found"
- Ensure CMake is installed and in PATH
- In VS Code: `Ctrl+Shift+P` → "CMake: Scan for Kits"

### "MSVC compiler not found"
- Verify Visual Studio Build Tools or VS Community is installed
- Check that C++ workload/tools were selected during installation
- Run: `.\check-prerequisites.ps1` to verify

### "ODBC Driver not found"
- Install ODBC Driver 18 for SQL Server
- Verify with: `Get-OdbcDriver | Where-Object {$_.Name -like "*SQL Server*"}`

### IntelliSense not working
- Open Command Palette (`Ctrl+Shift+P`)
- Run "C/C++: Reset IntelliSense Database"
- Ensure `.vscode/c_cpp_properties.json` exists

## Development Workflow

1. **Edit code** in VS Code with full IntelliSense support
2. **Build** using `.\build.ps1` or VS Code tasks
3. **Debug** using F5 or the Debug panel
4. **Test** using `.\smoke-test.ps1`
5. **Commit** changes using GitLens or terminal

## Optional: SQL Server for Testing

If you need a local SQL Server for testing:

### SQL Server Express (Free)
```powershell
# Install SQL Server Express
winget install Microsoft.SQLServer.2022.Express

# Or download from: https://www.microsoft.com/en-us/sql-server/sql-server-downloads
```

### SQL Server Management Studio (SSMS)
```powershell
# Install SSMS for database management
winget install Microsoft.SQLServerManagementStudio
```

## Optional: Pandoc for Documentation Publishing

If you plan to publish releases using `publish.ps1`, install **pandoc** to generate HTML documentation:

```powershell
# Install pandoc
winget install pandoc

# Or download from: https://pandoc.org/installing.html
```

**What it does:** The `publish.ps1` script uses pandoc to convert `sqlsim.md` to HTML format for distribution.

## Summary

**Minimum required:**
- VS Code + C++ extensions
- Visual Studio Build Tools 2026 or 2022 (with C++ tools)
- ODBC Driver 18 for SQL Server
- CMake (usually included with Build Tools)

**Time to set up:** ~15-30 minutes depending on download speeds

**Total disk space:** ~2-3 GB for Build Tools option, ~4-5 GB for full VS Community

Once set up, you'll have a complete C++ development environment optimized for VS Code with full IntelliSense, debugging, and integrated build tools.