# Developer Setup Guide

This guide helps new developers set up the complete development environment for sqlpysim using VS Code.

**How This Tool Was Built:**
100% of the code, scripts, and documentation for sqlpysim was developed with GitHub Copilot in Visual Studio Code using various AI models, but 100% orchestrated by Bob Ward.

## Prerequisites

### 1. Python 3.10 or Later
**Download:** https://www.python.org/downloads/

- Install with "Add Python to PATH" option
- Verify: `python --version`

### 2. Visual Studio Code
**Download:** https://code.visualstudio.com/

- Install with default settings
- Restart after installation

### 3. SQL Server Access (Required)

You need access to one of the following:

**Option A: Local SQL Server**
- SQL Server Developer Edition (free): https://www.microsoft.com/en-us/sql-server/sql-server-downloads
- SQL Server Express (free)
- Any SQL Server 2012 or later

**Option B: Azure SQL**
- Azure SQL Database
- Azure SQL Managed Instance
- SQL Database in Fabric

### 4. Dependency Baseline

Use `mssql-python==1.15.0` for development and validation.
For ongoing policy and cadence, see [../DRIVER-COMPATIBILITY.md](../DRIVER-COMPATIBILITY.md).

## VS Code Extensions

Install these essential extensions in VS Code:

### Required Extensions

1. **Python** by Microsoft (`ms-python.python`)
   - Provides IntelliSense, debugging, and linting

2. **Pylance** by Microsoft (`ms-python.vscode-pylance`)
   - Fast, feature-rich language support

### Recommended Extensions

3. **PowerShell** by Microsoft (`ms-vscode.powershell`)
   - For editing test scripts

4. **GitLens** by GitKraken (`eamodio.gitlens`)
   - Enhanced Git capabilities

### Install Extensions via Command Line
```powershell
code --install-extension ms-python.python
code --install-extension ms-python.vscode-pylance
code --install-extension ms-vscode.powershell
code --install-extension eamodio.gitlens
```

## Project Setup

### 1. Clone and Open Project
```powershell
# Clone the repository
git clone <your-repo-url>
cd sqlpysim

# Open in VS Code
code .
```

### 2. Create Virtual Environment (Recommended)
```powershell
# Create virtual environment
python -m venv .venv

# Activate (Windows)
.\.venv\Scripts\Activate.ps1

# Activate (Linux/macOS)
source .venv/bin/activate
```

### 3. Install Dependencies
```powershell
pip install -r requirements.txt
```

### 4. Verify Your Environment
```powershell
python --version
python -c "import mssql_python; print('mssql-python', mssql_python.__version__)"
```

### 5. Run Smoke Tests
```powershell
.\smoke-test.ps1
```

## VS Code Configuration

The project includes these VS Code configuration files:

### `.vscode/settings.json`
```json
{
    "python.defaultInterpreterPath": "${workspaceFolder}/.venv/Scripts/python.exe",
    "python.analysis.typeCheckingMode": "basic",
    "python.linting.enabled": true,
    "editor.formatOnSave": true
}
```

### `.vscode/launch.json`
```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "sqlpysim: Simple Query",
            "type": "debugpy",
            "request": "launch",
            "program": "${workspaceFolder}/sqlpysim.py",
            "args": ["-S", "localhost", "-E", "-C", "-Q", "SELECT @@VERSION"],
            "console": "integratedTerminal"
        },
        {
            "name": "sqlpysim: Load Test",
            "type": "debugpy",
            "request": "launch",
            "program": "${workspaceFolder}/sqlpysim.py",
            "args": ["-S", "localhost", "-E", "-C", "-Q", "SELECT 1", "-n", "5", "-r", "10", "-q"],
            "console": "integratedTerminal"
        }
    ]
}
```

## Development Workflow

### Running Tests
```powershell
# Quick validation
.\smoke-test.ps1

# Full test suite
.\full-test-suite.ps1
```

### Debugging
1. Set breakpoints in `sqlpysim.py`
2. Press F5 to start debugging
3. Use the Debug Console to inspect variables

### Code Style
- Use type hints for function parameters and returns
- Follow PEP 8 style guidelines
- Use docstrings for all public functions

## Project Architecture

sqlpysim is a single-file Python application for simplicity:

```
sqlpysim.py
├── Data Classes (ConnectionConfig, WorkloadConfig, etc.)
├── TimestampOutput (handles sqlsim-style output conventions)
├── ConnectionManager (database connections with mssql-python)
├── QueryExecutor (SQL execution with batch support)
├── MetricsCollector (performance statistics)
├── WorkloadSimulator (multi-threaded workload execution)
├── Output Formatters (text and JSON output)
├── Command Line Parser (argparse for the shared sqlsim-style core)
└── Main Entry Point
```

## Key Design Decisions

1. **Single File**: All code in one file for easy deployment and understanding
2. **Shared CLI Core**: Preserve common sqlsim parameters where implemented and document every difference
3. **Output Format**: Preserve familiar conventions without assuming identical JSON fields
4. **mssql-python**: Uses Microsoft's Python driver, which bundles its own copy of ODBC Driver 18 (no separate system ODBC install required)
5. **Threading**: Uses Python's ThreadPoolExecutor for multi-threaded execution

## Comparison with sqlsim

| Aspect | sqlsim (C++) | sqlpysim (Python) |
|--------|--------------|-------------------|
| **Driver** | ODBC Driver 18 (system-installed) | ODBC Driver 18 (bundled by mssql-python) |
| **Threading** | std::thread | ThreadPoolExecutor |
| **Metrics** | Atomic counters | Thread-safe with locks |
| **Output** | std::cout with timestamps | Custom TimestampOutput class |
| **JSON** | Manual string building | Manual (to match format exactly) |
