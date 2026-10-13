# Building sqlsim

**How This Tool Was Built:**
100% of the code, scripts, and documentation for sqlsim was developed with GitHub Copilot in Visual Studio Code using various AI models, but 100% orchestrated by Bob Ward.

## Prerequisites Check (Recommended First Step)

Before building, check if your system has everything needed:

```powershell
.\check-prerequisites.ps1
```

On Ubuntu 24.04 or 26.04 LTS x64:

```bash
bash ./check-prerequisites-linux.sh
```

This will verify Visual Studio Build Tools 2026 or 2022, PowerShell policy, and other requirements.

## Quick Build

### Ubuntu 24.04/26.04 LTS x64

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake unixodbc-dev
bash ./build-linux.sh --clean
```

The build output is `build/linux-x64/sqlsim`.

### macOS Apple Silicon ARM64 (Private Preview)

macOS is an invitation-only Private Preview platform. To test the native Apple Silicon build on a Mac or through the manual GitHub Actions workflow:

```bash
brew install cmake unixodbc
bash ./build-macos.sh --clean
bash ./smoke-test-macos.sh --skip-build
```

The Private Preview output is `build/macos-arm64/sqlsim`. `build-macos.sh` verifies that it is a Mach-O ARM64 executable and prints its dynamic-library dependencies. Run the `sqlsim macOS ARM64 Private Preview` workflow to produce a downloadable `sqlsim-macos-arm64-private-preview` artifact for invited customer and tester validation.

### Windows Option 1: PowerShell (Recommended)
```powershell
# Build both x64 and ARM64 (default)
.\build.ps1 -Clean

# Regular build (both architectures)
.\build.ps1

# Build only x64
.\build.ps1 -Architecture x64

# Build only ARM64 (for Windows on ARM devices)
.\build.ps1 -Architecture ARM64

# Debug build
.\build.ps1 -Configuration Debug

# Verbose build (see detailed compilation)
.\build.ps1 -Verbose

# Clean verbose build  
.\build.ps1 -Clean -Verbose

# ODBC debug build (logs all ODBC operations with thread IDs)
# WARNING: Only use for debugging - adds significant performance overhead
.\build.ps1 -DebugODBC

# Combine flags
.\build.ps1 -Clean -DebugODBC
```

### Windows Option 2: Batch File
```cmd
.\build.bat
```

### Windows Option 3: Direct cmake (if in PATH)
```powershell
cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

## Requirements

### Ubuntu x64

- Ubuntu 24.04 or 26.04 LTS
- GCC with C++17 support
- CMake 3.15 or later
- unixODBC development headers (`unixodbc-dev`)
- Microsoft ODBC Driver 18 for SQL Server for runtime connections

Install Driver 18 using Microsoft's current instructions: <https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server>.

Validate both build and runtime prerequisites with:

```bash
bash ./check-prerequisites-linux.sh --require-driver
```

### Option 1: Visual Studio Build Tools 2026/2022 (Recommended for VS Code users)
**Lightweight installation (~1GB) with just the compiler tools**

The build script automatically detects Visual Studio Build Tools 2026 or 2022:

```powershell
# Install latest Build Tools 2026 (if available)
# Or Build Tools 2022 via Windows Package Manager
winget install Microsoft.VisualStudio.2022.BuildTools

# Download Build Tools 2026: https://aka.ms/vs/18/stable/vs_buildtools.exe  
# Download Build Tools 2022: https://aka.ms/vs/17/release/vs_buildtools.exe
```

**During installation, select:**
- ✅ C++ build tools  
- ✅ CMake tools
- ✅ Windows 10/11 SDK
- ✅ MSVC build tools for ARM64/ARM64EC (only needed for ARM64 builds)

### Option 2: Full Visual Studio 2026/2022 (If you want the IDE)
**Complete development environment (~3GB+)**

```powershell
# Community edition (free) - 2022 version
winget install Microsoft.VisualStudio.2022.Community

# Download Visual Studio 2026: https://visualstudio.microsoft.com/downloads/
# Download Visual Studio 2022: https://visualstudio.microsoft.com/downloads/
```

**During installation, select:**
- ✅ "Desktop development with C++" workload

### Other Requirements
- Windows 10/11
- PowerShell 5.1 or later (included with Windows 10/11) - all scripts are compatible with Windows PowerShell 5.1
- ODBC Driver 18 for SQL Server (current documented baseline: 18.7.1.1)

For driver support policy and update cadence, see [../DRIVER-COMPATIBILITY.md](../DRIVER-COMPATIBILITY.md).

### Build Tools vs Full Visual Studio

| Feature | Build Tools | Visual Studio |
|---------|------------------|---------------------|
| **Size** | ~1GB | ~3GB+ |
| **Use Case** | Building/compiling only | Full IDE + building |
| **Good for** | VS Code users, CI/CD | Complete development |
| **Includes** | Compiler, CMake, SDK | Everything + IDE |
| **Install command (2022)** | `winget install Microsoft.VisualStudio.2022.BuildTools` | `winget install Microsoft.VisualStudio.2022.Community` |

**Recommendation:** Use Build Tools if you primarily work in VS Code or other editors.

> **Note**: `build.ps1` detects Visual Studio 2026 first, then 2022. The winget commands above install 2022; Visual Studio 2026 is available from <https://visualstudio.microsoft.com/downloads/>.

## Build Output

Builds are organized by architecture:

| Architecture | Release Build | Debug Build |
|--------------|---------------|-------------|
| x64 (default) | `build\x64\Release\sqlsim.exe` | `build\x64\Debug\sqlsim.exe` |
| ARM64 | `build\ARM64\Release\sqlsim.exe` | `build\ARM64\Debug\sqlsim.exe` |
| Ubuntu x64 | `build/linux-x64/sqlsim` | `build/linux-x64/sqlsim` (use `--configuration Debug`) |

**Note:** ARM64 builds require the MSVC ARM64 build tools component and can be cross-compiled from an x64 machine.

## Testing

After building, validate your build with the test suites:

### Ubuntu Offline and Live Tests

The Linux suites are native Bash counterparts of the PowerShell suites, so a
Linux VM, container, or WSL distribution needs no PowerShell. Point them at any
SQL Server, Azure SQL Database, or Azure SQL Managed Instance the machine can
reach over TCP:

```bash
# Offline CLI, authentication-matrix, secure-stdin, streaming-output, and signal checks
bash ./smoke-test-linux.sh --skip-build

# Live smoke and full suites with SQL authentication
bash ./smoke-test-linux.sh --skip-build --server HOST[,PORT] --database DB \
  --username USER --password-file FILE
bash ./full-test-suite-linux.sh --server HOST[,PORT] --database DB \
  --username USER --password-file FILE

# Or with a Microsoft Entra access token (Azure SQL)
az account get-access-token --resource https://database.windows.net \
  --query accessToken -o tsv > ~/.sqltoken && chmod 600 ~/.sqltoken
bash ./full-test-suite-linux.sh --server myserver.database.windows.net \
  --database mydb --token-file ~/.sqltoken --skip-scale
```

Notes:

- Secret files are read from their first line. A CRLF line ending from a file
  created on Windows is ignored. Keep the files owner-readable only. The suites
  hand the secret to sqlsim on stdin (`-T -`, `-P -`), so it never appears in a
  process list; `--token` and `--password` still put it on the suite's own
  command line, so prefer the file options.
- The full suite needs `jq` (`sudo apt-get install -y jq`).
- The target database needs no sample schema. The login must be able to create
  and drop `dbo.sqlsim_test_proc` in `tempdb` (SQL Server) or in the target
  database (Azure SQL Database), and to read its own session from the DMVs.
- Azure SQL Database targets are detected by name. Tests that cannot apply
  there are reported as skipped with a reason: certificate rejection, and
  throughput gates that would measure network latency.
- A WSL distribution in the default NAT networking mode cannot reach SQL Server
  on the Windows host through `localhost`. Target a server reachable by name or
  address, or enable WSL mirrored networking.
- The smoke suite also reads `SQLSIM_SERVER`, `SQLSIM_DATABASE`,
  `SQLSIM_ACCESS_TOKEN`, `SQLSIM_USERNAME`, and `SQLSIM_PASSWORD`.
- No SQL Server to test against? A disposable SQL Server container works on any
  machine with Docker. Keep the password in owner-only files, not on a command
  line, and remove the container afterward:

  ```bash
  umask 077
  printf '%s\n' "$SA_PASSWORD" > ~/.sqlpw
  printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\n' "$SA_PASSWORD" > ~/.mssql.env
  docker run -d --name sqlsim-test -p 14333:1433 --env-file ~/.mssql.env \
    mcr.microsoft.com/mssql/server:2025-latest
  bash ./full-test-suite-linux.sh --server 127.0.0.1,14333 --database master \
    --username sa --password-file ~/.sqlpw
  docker rm -f sqlsim-test; rm -f ~/.sqlpw ~/.mssql.env
  ```

  Live XEvent capture is skipped there; it needs SQL Server on the Windows
  machine running the PowerShell suite.

Do not claim a Linux release is ready until at least one live test run has passed.

### Quick Smoke Test (Recommended First Step)

Run the smoke test for quick validation (typically under 30 seconds against a local server):

```powershell
# Quick validation with existing build
.\smoke-test.ps1

# Test against specific server
.\smoke-test.ps1 -Server "myserver" -Database "mydb"
```

The smoke test validates essential core functionality:
- Help text and basic parameters
- Connection and authentication (Windows, SQL, or Token)
- Query execution with and without output
- High repetition (100 iterations)
- Concurrency (25 threads x 10 iterations = 250 queries)
- Quiet and verbose modes
- **Output terminology validation** (verifies "batches" not "queries")
- File input with GO batch separators
- Output to file (-o flag)
- Error handling
- Application name and connection pooling
- JSON output format with validation (-json flag)
- Streaming NDJSON event validation (`-stream-json`)
- Timestamp format and output features
- **Performance regression checks** (`SELECT 1` ratios and per-iteration slopes; machine-independent, so no baseline file is used)

**JSON Output Validation**: All tests that use `-json` validate the output is proper JSON using PowerShell's `ConvertFrom-Json`.

### Comprehensive Testing

For complete validation, run the full test suite (typically a few minutes against a local server; much longer against Azure SQL, where every round trip crosses the network).
The full suite runs smoke-test.ps1 first, then executes extended tests:

```powershell
# Run full suite with existing build (fastest)
.\full-test-suite.ps1 -SkipBuild

# Build and test in one command  
.\full-test-suite.ps1

# Clean build and full test
.\build.ps1 -Clean
.\full-test-suite.ps1 -SkipBuild
```

### Advanced Test Options

```powershell
# Stop on first failure (useful for debugging)
.\full-test-suite.ps1 -SkipBuild -StopOnError

# Tag perf measurements (saved to measurements/ folder)
.\smoke-test.ps1 -SkipBuild -PerfTag "After refactoring X"
.\full-test-suite.ps1 -SkipBuild -PerfTag "After refactoring X"

# Log output to file with timestamps
.\full-test-suite.ps1 -SkipBuild -OutputFile "test-results.log"

# Show verbose command details
.\full-test-suite.ps1 -SkipBuild -Verbose

# Test against remote SQL Server
.\full-test-suite.ps1 -SkipBuild -Server "192.168.1.100" -Database "testdb"

# Test against Azure SQL Database with interactive auth
.\full-test-suite.ps1 -SkipBuild -Server "myserver.database.windows.net" -Database "mydb"

# Test against Azure SQL Database with access token (automated)
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
.\full-test-suite.ps1 -SkipBuild -Server "myserver.database.windows.net" -Database "mydb" -UseToken $token

# Combine options for Azure testing with logging
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
.\full-test-suite.ps1 -SkipBuild -Server "myserver.database.windows.net" -Database "mydb" -UseToken $token -StopOnError -OutputFile "azure-test.log"

# Test read-only routing (-R) and multi-subnet failover (-M) on servers with read replicas
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
.\full-test-suite.ps1 -SkipBuild -Server "myserver.database.windows.net" -Database "mydb" -UseToken $token -TestReadReplica

```

The suites pass `-UseToken` and `-Password` values to sqlsim through stdin
(`-T -` and `-P -`), so the secret never appears in a process list. Run them
from a PowerShell session as shown, not through `pwsh -File ... -UseToken`,
which would put the token on the PowerShell command line instead.

### Example Validation Tests

Validate that examples in help text, documentation, and example scripts work correctly:

```powershell
# Run example validation
.\test-examples.ps1

# Skip tests requiring AdventureWorksLT database
.\test-examples.ps1 -SkipAdventureWorks

# Test against specific server
.\test-examples.ps1 -Server "myserver" -Database "testdb"
```

The example validation tests cover:
- **Help text examples** (from `sqlsim -?`) - Connection tests, queries, load test patterns
- **Documentation examples** (from sqlsim.md) - All code examples in the user manual
- **Example scripts** (from examples/powershell/ folder) - localhost-simple-test.ps1, json-output-examples.ps1 patterns
- **SQL files** (from examples/sql/ folder) - 01-simple-queries.sql through 09-reporting-queries-adventureworkslt.sql

### Replay Tests

Run this after changing XEL replay parsing or execution:

```powershell
.\test-replay.ps1                 # offline checks plus live replay on localhost
.\test-replay.ps1 -SkipOnline     # offline checks only
.\test-replay.ps1 -Server "myserver" -Database "testdb"
```

The offline checks cover replay option validation, capture XML parsing, and
error messages. The online checks replay `testing\replay-test-data.xml` against
the target with Windows authentication unless `-UseToken` or
`-Username`/`-Password` is supplied.

### HTML Report Tests

The report generators in `examples/reports/` render JSON results that may come
from another person. Run this offline test after changing a report generator:

```powershell
.\test-reports.ps1
```

It renders hostile result files with the comparison, execution, and query
statistics reports, and checks that text stays encoded and non-numeric metrics
cannot reach generated JavaScript. It also checks that `comparison-report.ps1`
uses the same metrics and configuration guardrails as sqlsim Studio Compare.
CI runs it in the PowerShell analysis job.

### Full Test Suite Features

- **130+ comprehensive tests** covering all functionality (varies based on options and environment)
- **Output format validation**: Comprehensive validation of non-verbose, verbose, and JSON output formats
- **Terminology verification**: Ensures consistent use of "batches" terminology (not "queries")
- **Automatic Azure detection**: Adjusts thread limits (500 for Azure, 1024 for on-prem)
- **TestReadReplica flag**: Enable tests for `-R` (read-only intent) and `-M` (multi-subnet failover) on servers with read replicas (adds 3 tests)
- **Warning category**: Read replica tests show warnings (not failures) if server doesn't have replicas configured
- **StopOnError flag**: Exit immediately on first failure for faster debugging
- **Output logging**: Write test results to file with start/end timestamps and duration
- **Separate output files**: Tests that use sqlsim's `-o` parameter create their own output files, not captured in the test transcript
- **Flexible authentication**: Windows, Entra ID (interactive or token-based)
- **Adaptive tests**: Automatically skips tests not applicable to target environment (e.g., cert tests on Azure)

### Full Test Coverage

The full test suite validates:
- Basic functionality (help, queries, connection modes)
- Prepared statements
- File parsing and GO batch separators
- Timeout handling (query and login)
- Parameter validation (all command-line options)
- TDS 8.0 encryption modes
- Connection-only testing
- Security validation
- Concurrency (100 threads, plus 500/1024 max threads)
- Error handling and SQL syntax errors
- Multi-result sets
- JSON output structure and validity (validates `-json` produces valid JSON, and `-v -json` includes verbose fields)
- **Output format validation** (validates 18 elements in non-verbose, 26 in verbose, 20 in JSON)
- **Terminology consistency** (verifies "batches" terminology used consistently, not "queries")
- **Example validation** (validates help text, documentation, and example script patterns work correctly)
- **Replay testing** (parameter conflicts, fast/stress mode, replay summary validation, JSON replay fields, verbose event output)
- Always Encrypted support detection
- **Performance regression tests** (3 scenarios, compared ±20% against a baseline saved on the same machine and SQL Server when one exists, otherwise fixed thresholds)
- Read-only routing and multi-subnet failover (requires `-TestReadReplica` flag)

**Output Format Validation**: The test suite includes comprehensive validation of output formats:
- **Non-verbose output**: Validates 18 key elements including Server, Database, Authentication, batch counts, Performance Metric Summary, avg connect time, avg elapsed, time breakdown
- **Verbose output**: Validates 26 key elements including all 5 PHASE markers, connection metrics, avg elapsed time
- **JSON output**: Validates 33 key JSON fields including configuration (server, database, authentication, optional features), metrics, runtime breakdown
- **Terminology check**: Ensures "batches" is used consistently (not "queries") across all output modes

**JSON Output Validation**: All tests that use `-json` validate the output is proper JSON using PowerShell's `ConvertFrom-Json`. The verbose JSON test (Test 35) additionally verifies that when `-v -json` are used together, the output includes the three verbose fields at top level: `connection_string`, `thread_connections`, and `thread_iterations`.

**Performance Baselines**: The smoke test's performance checks use ratios and per-iteration slopes of `SELECT 1` runs, so process start, driver load, and login cost cancel out and no baseline is needed. The full suite compares its three scenarios against a baseline saved with `baseline/save-full-perf-baseline.ps1` (5 runs, median), but only when that baseline was recorded on the same machine, CPU, server, and SQL Server version; otherwise it uses fixed thresholds (5s, 10s, 30s). Baselines are machine-specific, so `baseline/*.json` is ignored by Git. Each test run saves a measurement to `measurements/` with machine config, SQL Server version, and optional `-PerfTag` annotation.

## ODBC Debug Mode

**⚠️ Performance Warning**: ODBC debug logging adds significant overhead and should **only be used for debugging**. Do not use this flag for performance testing or production workloads.

For troubleshooting ODBC connection and query execution issues, build with the `-DebugODBC` flag:

```powershell
# Build with ODBC debug logging
.\build.ps1 -Clean -DebugODBC

# Test with debug output
.\build\x64\Release\sqlsim.exe -S localhost -d master -E -Q "SELECT @@VERSION" -n 5 -r 2 -q
```

**Debug output includes:**
- Thread ID for each operation (useful for multi-threaded troubleshooting)
- SQLAllocHandle operations (environment, connection, statement handles)
- SQLDriverConnect (connection establishment)
- SQLSetConnectAttr (access token authentication)
- SQLExecDirect (query execution)
- SQLFetch (result retrieval)
- SQLDisconnect and SQLFreeHandle (cleanup)

**Example output:**
```
[DEBUG ODBC Thread 69788] Connect: Starting connection
[DEBUG ODBC Thread 69788] SQLAllocHandle(ENV) result=0
[DEBUG ODBC Thread 69788] SQLDriverConnect: Connecting to database
[DEBUG ODBC Thread 69788] SQLDriverConnect result=1
[DEBUG ODBC Thread 69788] SQLExecDirect: SELECT @@VERSION
[DEBUG ODBC Thread 69788] SQLExecDirect result=0
[DEBUG ODBC Thread 69788] SQLFetch: Fetching row
[DEBUG ODBC Thread 69788] SQLFetch result=0
```

This is particularly helpful for:
- Diagnosing connection failures
- Understanding multi-threaded behavior
- Tracing ODBC errors
- Performance analysis of ODBC operations

## Publishing

To publish the release build and generate HTML documentation:

```powershell
# Build both architectures and publish
.\\publish.ps1

# Publish only (skip build, use existing executables)
.\\publish.ps1 -SkipBuild
```

This script:
- Builds sqlsim for x64 and ARM64 (unless `-SkipBuild` is specified)
- Copies `build\\x64\\Release\\sqlsim.exe` to `release/x64/`
- Copies `build\\ARM64\\Release\\sqlsim.exe` to `release/ARM64/`
- Copies `sqlsim.md` (user manual) to the release folder
- Converts `sqlsim.md` to HTML using pandoc
- Copies the `examples\\` folder (sample scripts, SQL files, workloads, and reports in subfolders)

**Release folder structure:**
```
release/sqlsimtools/1.0/
├── .github/skills/sqlsim/SKILL.md
└── sqlsim/
  ├── x64/sqlsim.exe      # Windows x64 executable
  ├── ARM64/sqlsim.exe    # Windows ARM64 executable
  ├── AGENTS.md           # Scoped agent contract
  ├── LICENSE             # MIT license
  ├── sqlsim.md           # User manual
  ├── sqlsim.html         # HTML documentation
  └── examples/           # Example scripts
```

Default installation root: `<repo-root>\release\sqlsimtools\1.0` (resolved relative to this script via `$PSScriptRoot`). That staging tree is disposable and is refreshed on every publish. Override with `-ReleaseDir <path>` to install into a project: publishing there never deletes files and keeps files you added under `sqlsim\examples`, and if a file it installs already exists with different contents it lists the file and stops before writing anything. Add `-Preview` to list changes without writing, `-Force` to replace differing files, `-Architecture x64` or `-Architecture ARM64` to publish one architecture, and `-ReportPath <file>` for a JSON record of what changed. To build, install, validate, and get a receipt in one step, use `..\scripts\install-local.ps1` from the repository root.

### Release Validation

After publishing, validate the release package works correctly:

```powershell
# Test against localhost/on-premises SQL Server
.\test-nonazure-release-examples.ps1

# Test with SQL Authentication (optional)
.\test-nonazure-release-examples.ps1 -SqlUser "myuser"   # prompts for the password

# Test against Azure SQL Database (requires Azure CLI)
.\test-azure-release-examples.ps1 -ServerName "myserver.database.windows.net"

# Skip interactive auth prompt for automated testing
.\test-azure-release-examples.ps1 -ServerName "myserver.database.windows.net" -SkipInteractive
```

These scripts test the example scripts in the staged release (default `release/sqlsimtools/1.0/sqlsim/examples/`, or `-ReleaseDir`) to ensure they work correctly in the distributed package.

### Pandoc Requirement

The `publish.ps1` script requires **pandoc** to generate HTML documentation from `sqlsim.md`:

**Install pandoc:**
```powershell
winget install pandoc
```

**Or download:** https://pandoc.org/installing.html

After installation, pandoc will be available at:
- `C:\Users\<username>\AppData\Local\Pandoc\pandoc.exe`
- Or in PATH if installed system-wide

**Note:** The publish script automatically detects pandoc in common locations.

## Continuous Integration

The repository runs a GitHub Actions workflow on every pull request that
touches `sqlsim/` (and on pushes to `main`). It lives at
`.github/workflows/sqlsim-ci.yml` and has two jobs:

1. **Build (`windows-latest`, x64)**
   - Runs `sqlsim/build.ps1 -Architecture x64 -Configuration Release` on a
     clean Windows runner (same toolchain as a local build: cmake + MSBuild +
     Visual Studio 2022 from the runner image).
   - Verifies `sqlsim/build/x64/Release/sqlsim.exe` was produced.
   - Runs offline sanity checks: `sqlsim.exe -h` and `sqlsim.exe -version`
     must exit 0.
   - Uploads the built `sqlsim.exe` as a workflow artifact (`sqlsim-x64-release`,
     14-day retention) so reviewers can grab the exact binary the PR produced.

2. **PSScriptAnalyzer**
   - Installs `PSScriptAnalyzer` and scans all PowerShell scripts in `sqlsim/`
     (`build.ps1`, `smoke-test.ps1`, `publish.ps1`, examples, etc.).
   - Fails the job on any **Error**-severity finding. Warnings are tolerated.

**What is NOT run in CI:** `smoke-test.ps1` and `full-test-suite.ps1` require
a live SQL Server / Azure SQL endpoint, which is not available on hosted
runners. These remain manual gates before publishing a release — run them
locally with `-PerfTag pre-release` and review the results under
`measurements/`.

**Triggering manually:** the workflow also supports `workflow_dispatch`, so
you can re-run it from the **Actions** tab without opening a PR.

**Other tools' CI:** sqlpysim, sqlsim Studio, plugin validation, and the macOS
Private Preview each have their own workflow under `.github/workflows/`. A new
tool should follow the same pattern: copy this file to
`.github/workflows/<tool>-ci.yml` and adjust the `paths:` filter and
build/test commands.

## Troubleshooting

1. **"cmake not found"**: Use `.\build.ps1` which automatically sets up the VS environment
2. **"Visual Studio not found"**: Install Visual Studio Build Tools 2026 or 2022 with the C++ tools
3. **Build fails**: Try clean build with `.\build.ps1 -Clean`
4. **"pandoc not found" during publish**: Install pandoc using `winget install pandoc`

The build scripts automatically detect a Visual Studio 2026 or 2022 installation and configure the environment properly.