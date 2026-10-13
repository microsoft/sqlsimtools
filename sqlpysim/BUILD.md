# Installing sqlpysim

**How This Tool Was Built:**
100% of the code, scripts, and documentation for sqlpysim was developed with GitHub Copilot in Visual Studio Code using various AI models, but 100% orchestrated by Bob Ward.

## Prerequisites Check (Recommended First Step)

Before installing, check that Python 3.10 or later is available, then after
installing the requirements below, check that the `mssql-python` driver imports:

```powershell
python --version
python -c "import mssql_python; print('mssql-python', mssql_python.__version__)"
```

To check everything the source test suites need, including ODBC connectivity
and the AdventureWorksLT fixture, run `..\scripts\check-test-prerequisites.ps1`
from this directory.

## Quick Install

### Option 1: pip install (Recommended)

```powershell
# Install runtime dependencies
pip install mssql-python

# Verify installation
python sqlpysim.py -h
```

### Option 2: Install from requirements.txt

```powershell
pip install -r requirements.txt
```

### Option 3: Install as package

```powershell
pip install -e .
```

## Requirements

### Python 3.10 or Later (Required)

**Download:** https://www.python.org/downloads/

sqlpysim requires Python 3.10 or later. The mssql-python driver requires Python 3.10+.

```powershell
# Check Python version
python --version
```

### mssql-python Driver (Required)

The mssql-python driver is Microsoft's native Python driver for SQL Server. Its wheels include the native connectivity layer, so no separately installed ODBC driver is required.

The current tested pin is `mssql-python==1.15.0`.
For ongoing policy and cadence, see [../DRIVER-COMPATIBILITY.md](../DRIVER-COMPATIBILITY.md).

**Install:**
```powershell
pip install mssql-python
```

**Platform-specific requirements:**

| Platform | Additional Requirements |
|----------|------------------------|
| **Windows** | None (batteries included) |
| **Linux (Debian/Ubuntu)** | `apt-get install -y libltdl7 libkrb5-3 libgssapi-krb5-2` |
| **Linux (RHEL)** | `dnf install -y libtool-ltdl krb5-libs` |
| **macOS** | `brew install openssl` |

### Azure CLI (Optional - for Token Authentication)

**Download:** https://learn.microsoft.com/en-us/cli/azure/install-azure-cli

Only required if you plan to use token authentication (`-T` option):

```powershell
az login
$token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT @@VERSION"
```

## Verification

After installation, verify everything works:

```powershell
# Show help
python sqlpysim.py -h

# Quick connection test (requires local SQL Server)
python sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"

# Run smoke tests
.\smoke-test.ps1
```

## Testing

### Quick Smoke Test (Recommended First Step)

Run the minimal smoke test for quick validation (~2-3 seconds):

```powershell
.\smoke-test.ps1

# Skip pip install check
.\smoke-test.ps1 -SkipInstall
```

### Comprehensive Testing

For complete validation:

```powershell
.\full-test-suite.ps1

# With Azure SQL
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
.\full-test-suite.ps1 -ServerName "myserver.database.windows.net" -DatabaseName "mydb" -UseToken $token
```

The suites pass `-UseToken` and `-Password` values to sqlpysim through stdin
(`-T -` and `-P -`), so the secret never appears in a process list. On Linux,
use `--token-file` or `--password-file` with the Bash suites for the same
reason.

## Troubleshooting

### "mssql-python driver not installed"

```powershell
pip install mssql-python
```

### "SSL certificate error" on localhost

Use `-C` flag to trust server certificate:
```powershell
python sqlpysim.py -S localhost -E -C -Q "SELECT 1"
```

### Python version error

Upgrade to Python 3.10 or later:
```powershell
python --version  # Must be 3.10+
```

### Permission denied on Linux

Install system dependencies:
```bash
# Debian/Ubuntu
sudo apt-get install -y libltdl7 libkrb5-3 libgssapi-krb5-2

# RHEL/CentOS
sudo dnf install -y libtool-ltdl krb5-libs
```
