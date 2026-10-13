# SQL Workload Simulator - Python Edition (sqlpysim) v1.0.0

User Manual for SQL Workload Simulator - Python Edition (sqlpysim).

> **Public Preview:** sqlpysim is under active compatibility development and
> is not yet a drop-in replacement for sqlsim.

## Table of Contents
- [Overview](#overview)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Command Reference](#command-reference)
- [Limits and Resource Considerations](#limits-and-resource-considerations)
- [Usage Examples](#usage-examples)
- [Understanding Output](#understanding-output)
- [Query Stats](#query-stats)
- [SQL Script Files](#sql-script-files)
- [Unicode Support](#unicode-support)
- [Error Handling](#error-handling)
- [Using Microsoft Entra Authentication](#using-microsoft-entra-authentication)
- [Python Integration](#python-integration)
- [Security and Best Practices](#security-and-best-practices)
- [sqlpysim vs sqlsim - What's Different?](#sqlpysim-vs-sqlsim---whats-different)
- [Troubleshooting](#troubleshooting)
- [Using sqlpysim with a Coding Agent](#using-sqlpysim-with-a-coding-agent)
- [Getting Help](#getting-help)

## Overview

SQL Workload Simulator - Python Edition (sqlpysim) is a cross-platform Python-based command-line tool for testing SQL Server, Azure SQL, and other TDS compatible servers. It shares sqlsim's core query, concurrency, authentication, and reporting workflow while leveraging Microsoft's native mssql-python driver. Advanced CLI modes and some output fields differ; see [sqlpysim vs sqlsim - What's Different?](#sqlpysim-vs-sqlsim---whats-different) and the repository [release limitations](https://github.com/microsoft/sqlsimtools/blob/main/RELEASE-NOTES.md#sqlpysim-does-not-yet-have-full-sqlsim-cli-or-output-compatibility).

**⚠️ Important:** sqlpysim is a **testing and workload simulation tool** designed for development, testing, and performance evaluation environments. It is **NOT intended for use against production systems**. Running sqlpysim with high thread counts (`-n`) can consume substantial CPU, memory, network bandwidth, and database connections on the client and server. Excessive concurrency can make the client unresponsive, exhaust resources, and distort benchmark results before the database reaches its limit. Start with a small thread count, increase it gradually, and monitor both client and server resources. Use dedicated test environments and, for significant load tests, a dedicated client machine.

**How This Tool Was Built:**
100% of the code, scripts, and documentation for sqlpysim was developed with GitHub Copilot in Visual Studio Code using various AI models, orchestrated by Bob Ward.

**Key Capabilities:**
- Cross-platform: Windows and Ubuntu Linux in Public Preview, with macOS ARM64 in Private Preview
- Single Python file (no installation required beyond Python and driver)
- Native builds leverage Microsoft's official mssql-python driver
- Familiar sqlsim-style CLI and output conventions for shared core workflows
- Execute single queries or SQL script files
- Multi-threaded workload simulation
- Multiple authentication methods (Windows, Entra, SQL Auth, Access Token, Managed Identity)
- Detailed performance metrics (connection time, query execution, percentiles)
- Per-query server statistics compatible with sqlsim (`-querystats`)
- Timeout controls for connections and queries
- TDS 8.0 encryption support
- Connection behavior controls (reconnect mode)
- Support for read replicas and Always On Availability Groups
- Full Unicode support (UTF-8 input and output)
- Support for local SQL Server, Azure SQL Database, Azure SQL Managed Instance, and SQL database in Fabric

**Top 10 Cool Things You Can Do with sqlpysim:**

| # | Cool Thing | Why It's Unique |
|---|------------|-----------------|
| **1** | **Cross-platform stress testing** | Run the same workload tests on Windows and Ubuntu Linux, or help validate macOS ARM64 through the Private Preview |
| **2** | **Zero compilation - just Python** | Single .py file, runs anywhere Python 3.10+ is installed |
| **3** | **Full Entra authentication support** | Interactive, Managed Identity, Service Principal, and more |
| **4** | **Familiar sqlsim-style output** | Use common metrics concepts across the C++ and Python tools while accounting for documented schema differences |
| **5** | **Test Azure SQL with modern auth** | Full Managed Identity support (ActiveDirectoryMsi) |
| **6** | **Separate connection time from query time** | Understand *where* time is spent - network, auth, or query |
| **7** | **Export results as JSON** | Machine-readable output for CI/CD pipelines |
| **8** | **Get detailed percentiles (P50, P95, P99)** | Know your real latency distribution, not just averages |
| **9** | **Native driver performance** | mssql-python is Microsoft's official native driver |
| **10** | **Per-query server statistics** | Compare server CPU, elapsed time, and reads per query using the same fields as sqlsim (`-querystats`) |

[↑ Back to Table of Contents](#table-of-contents)

## Installation

### Prerequisites

sqlpysim requires Python 3.10 or higher and the Microsoft mssql-python driver.

**Supported Platforms:**

sqlpysim targets the same platforms as sqlsim.

| Platform | Architectures | Requirements |
|----------|---------------|--------------|
| Windows | x64, ARM64 | ARM64 requires Python 3.11 or later |
| Ubuntu 24.04 / 26.04 LTS | x64 | Python 3.10 or later |

macOS ARM64 is available through the Private Preview; see `MACOS-PRIVATE-PREVIEW.md`
in the package. `mssql-python` also publishes wheels for Linux ARM64 and
musl-based distributions. Those combinations may work but are untested and
unsupported, which is the same stance sqlsim takes for platforms outside its
validated matrix.

**Included Files:**
- `sqlpysim.py` - Main script (single file, no installation required)
- `sqlpysim.md` - Full documentation (this file)
- `examples/` - Sample SQL scripts and PowerShell examples

### Step 1: Install Python

**Windows:**
```powershell
# Download from https://python.org or use winget
winget install Python.Python.3.12
```

**macOS:**
```bash
# Use Homebrew
brew install python@3.12
```

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install python3 python3-pip python3-venv

# RHEL/Fedora
sudo dnf install python3 python3-pip

# Arch Linux
sudo pacman -S python python-pip
```

**Verify Installation:**
```bash
# Linux/macOS
python3 --version  # Should show 3.10 or higher

# Windows
python --version
```

> **Note:** On Linux/macOS, use `python3` and `pip3` instead of `python` and `pip`.

### Step 2: Set Up Virtual Environment (Recommended)

Using a virtual environment keeps dependencies isolated and is a Python best practice.

**Create and activate virtual environment:**

```bash
# Linux/macOS
python3 -m venv .venv
source .venv/bin/activate

# Windows (PowerShell)
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Windows (Command Prompt)
python -m venv .venv
.\.venv\Scripts\activate.bat
```

**Using conda:**
```bash
conda create -n sqlpysim python=3.12
conda activate sqlpysim
```

### Step 3: Install mssql-python Driver

The mssql-python driver is Microsoft's official native Python driver for SQL Server.

**Install the tested version with pip:**

The package's `requirements.txt` pins the version sqlpysim is tested with
(`mssql-python==1.15.0`). Install from it in the `sqlpysim` folder:

```bash
# Linux/macOS
pip3 install -r requirements.txt

# Windows
pip install -r requirements.txt
```

**Verify Installation (Linux/macOS):**
```bash
python3 -c "import mssql_python; print('mssql-python installed successfully')"
```

**Verify Installation (Windows):**
```powershell
python -c "import mssql_python; print('mssql-python installed successfully')"
```

### Step 4: Install Azure CLI (Optional)

**Only required for:**
- Token authentication (`-T` option) with Azure SQL Database
- If you need to acquire access tokens manually

**Not needed for:**
- Windows Authentication (`-E`)
- SQL Authentication (`-U`/`-P`)
- Microsoft Entra interactive authentication (`-A`) - uses device code flow
- Managed Identity authentication (`-A ActiveDirectoryMsi`) - for Azure resources

**Download:** https://learn.microsoft.com/en-us/cli/azure/install-azure-cli

If using token authentication:

**Windows (PowerShell):**
```powershell
az login  # One-time setup
$token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT @@VERSION"
```

**Linux/macOS (Bash):**
```bash
az login  # One-time setup
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
printf '%s\n' "$TOKEN" | python3 sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT @@VERSION"
```

### SQL Server Access (Required)

You need access to a SQL Server instance. Choose the option that best fits your platform and testing needs:

**Option A: Local SQL Server (Windows)**

For Windows users, install SQL Server locally:
- **Developer Edition** (free, full-featured): https://www.microsoft.com/en-us/sql-server/sql-server-downloads
- **Express Edition** (free, limited): https://www.microsoft.com/en-us/sql-server/sql-server-downloads

**Option B: SQL Server in Docker (Linux/macOS/Windows)**

The easiest cross-platform option is SQL Server in Docker:

```bash
# Pull and run SQL Server 2022 container
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=YourStrong@Passw0rd" \
    -p 1433:1433 --name sqlserver \
    -d mcr.microsoft.com/mssql/server:2022-latest

# Wait for startup (~30 seconds), then test
printf '%s\n' 'YourStrong@Passw0rd' | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT @@VERSION"
```

> **Note:** SQL Server container requires Docker Desktop (macOS/Windows) or Docker Engine (Linux) and at least 2GB RAM.

**Option C: Azure SQL Database**

For cloud-based testing:
- Create: Azure Portal → SQL databases → Create SQL Database
- Guide: https://learn.microsoft.com/en-us/azure/azure-sql/database/single-database-create-quickstart
- Server format: `yourserver.database.windows.net`
- Authentication: Entra (`-A`), SQL Auth (`-U`/`-P`), Token (`-T`)

**Option D: Azure SQL Managed Instance**

For managed SQL Server instance:
- Create: Azure Portal → Azure SQL → Create SQL Managed Instance
- Authentication: Entra (`-A`), SQL Auth (`-U`/`-P`), Token (`-T`)

**Option E: Microsoft Fabric SQL Database**

For Fabric users:
- Create: Microsoft Fabric Portal → Create → SQL Database
- Authentication: Entra (`-A`), Token (`-T`)

**Required Permissions:**

Your account needs:
- **Connection permissions**: Ability to connect to the database
- **Query permissions**: At minimum `db_datareader` role or `SELECT` on tables
- **Firewall access** (Azure): Your client IP must be allowed in firewall rules

### Supported SQL Server Versions

sqlpysim supports all SQL Server platforms that the mssql-python driver supports:

- **SQL Server:** 2025, 2022, 2019, 2017, 2016, 2014, 2012 (and older with basic support)
- **Azure SQL Database:** All service tiers
- **Azure SQL Managed Instance**
- **Microsoft Fabric:** SQL Database in Fabric

> **Note:** sqlpysim can connect to any TDS-compatible SQL Server that mssql-python supports.

[↑ Back to Table of Contents](#table-of-contents)

## Getting Started

### Running sqlpysim

**Note:** The examples in this documentation use `python sqlpysim.py` assuming you're in the sqlpysim directory. You can also use the full path.

**Options for running sqlpysim:**
- **Run locally:** Navigate to the sqlpysim directory and run `python sqlpysim.py`
- **Full path:** Use `python C:\path\to\sqlpysim.py` or `python3 /path/to/sqlpysim.py`
- **Create alias:** Add an alias in your shell profile

### Minimum Required Parameters

**Note:** Parameters which support values can be specified with or without a space (e.g., `-n 10` or `-n10`).

To run sqlpysim, you need to specify:

**1. Connection:**
   - `-S <server>` (optional, defaults to localhost)
   - Authentication method: `-E`, `-A`, `-T`, or `-U/-P` (one required)

**2. Query Source (optional):**
   - `-Q <query>` for a single query, OR
   - `-i <file>` for a SQL script file
   - If omitted, performs connection test only

**3. Database (optional):**
   - `-d <database>` (optional for SQL Server, required for Azure SQL Database)

**4. Certificate Trust (often needed for localhost):**
   - `-C` to trust self-signed certificates

**Minimal Examples:**
```powershell
# Connection test only (minimal possible command)
python sqlpysim.py -S localhost -E -C
python sqlpysim.py -S myserver.database.windows.net -d mydb -A

# Basic query
python sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"

# Azure SQL Database (database required)
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1"
```

> **Why `-C`?** SQL Server connections use TLS encryption by default. Local SQL Server installations typically use self-signed certificates that aren't trusted by the operating system. The `-C` flag tells sqlpysim to trust the server's certificate without validation. **Use `-C` for:**
> - Local development (localhost)
> - SQL Server in Docker containers
> - Test environments with self-signed certificates
> 
> **`-C` is optional for:**
> - Azure SQL Database (has CA-signed certificates that are already trusted)
> - Microsoft Fabric SQL endpoint (has CA-signed certificates)
> - Production servers with CA-signed certificates
> 
> Using `-C` with Azure SQL won't cause errors—it's just unnecessary since the certificates are already valid.

### Quick Start Example

**Windows (PowerShell):**
```powershell
# 1. Navigate to sqlpysim directory
cd C:\path\to\sqlpysim

# 2. Run your first query (Windows Auth - local SQL Server)
python sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"

# 3. View help
python sqlpysim.py -h
```

**Linux/macOS (Bash):**
```bash
# 1. Navigate to sqlpysim directory
cd /path/to/sqlpysim

# 2. Run your first query (SQL Auth - SQL Server in container or remote)
read -rsp "SQL password: " SQL_PASSWORD; printf '\n'
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT @@VERSION"
unset SQL_PASSWORD

# 3. Azure SQL with Entra Interactive
python3 sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT @@VERSION"

# 4. View help
python3 sqlpysim.py --help
```

> **Linux Note:** Windows Authentication (`-E`) uses Kerberos on Linux and needs a
> domain-joined host with a valid credential cache (run `kinit` first). Without one the
> driver reports `No Kerberos credentials available`. This path is untested and
> unsupported; use SQL Authentication (`-U`/`-P`) or Token Authentication (`-T`) instead.

### Basic Workflow

Build your sqlpysim command step by step:

**1. Specify Server and Database:**
```powershell
# Start with server (database is optional for SQL Server)
python sqlpysim.py -S localhost
```

**2. Add Authentication Method:**
```powershell
# Add Windows Authentication
python sqlpysim.py -S localhost -E -C
```

**3. Add Query Source (optional):**
```powershell
# Add a query to execute
python sqlpysim.py -S localhost -E -C -Q "SELECT COUNT(*) FROM sys.databases"

# Or use a SQL script file
python sqlpysim.py -S localhost -E -C -i queries.sql
```

**4. Configure Workload (optional):**
```powershell
# Add concurrency: 10 threads, 50 iterations each
python sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 10 -r 50
```

**5. Add Output Control (optional):**
```powershell
# Add quiet mode to suppress query results
python sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 10 -r 50 -q
```

### Exit Codes

sqlpysim returns standard exit codes for scripting:

- **0**: Success - all queries completed successfully
- **1**: Error - connection failed, invalid parameters, or execution errors

**Windows (PowerShell):**
```powershell
python sqlpysim.py -S localhost -E -C -Q "SELECT 1"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Success!"
} else {
    Write-Host "Failed with exit code: $LASTEXITCODE"
}
```

**Linux/macOS (Bash):**
```bash
# Set once without echo: read -rs -p 'SQL password: ' SQL_PASSWORD; echo
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1"
rc=$?
if [ $rc -eq 0 ]; then
    echo "Success!"
else
    echo "Failed with exit code: $rc"
fi
```

[↑ Back to Table of Contents](#table-of-contents)

## Command Reference

### Connection Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-S <server>` | Server name or IP address | localhost |
| `-d <database>` | Database name | (server default) |
| `-c <connection_string>` | Full ODBC connection string; cannot be combined with `-S`, `-d`, or authentication flags | |

### Authentication Parameters

| Parameter | Description |
|-----------|-------------|
| `-E` | Windows Integrated Authentication |
| `-A [method]` | Microsoft Entra authentication (see below) |
| `-T <token>` | Access token for authentication |
| `-U <user>` | SQL Server username |
| `-P <password>` | SQL Server password |

**Microsoft Entra Methods (`-A`):**

| Method | Description |
|--------|-------------|
| `ActiveDirectoryInteractive` | Browser-based interactive on Windows (default) |
| `ActiveDirectoryIntegrated` | Integrated Microsoft Entra authentication |
| `ActiveDirectoryMsi` | Managed Identity (Azure VMs, containers) |
| `ActiveDirectoryServicePrincipal` | Client ID from `-U` and client secret from `-P` |

The method names are case-insensitive. Unknown names are rejected rather than
silently falling back to interactive authentication.

### Workload Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Q <query>` | Query string to execute | |
| `-i <file>` | Input file containing SQL batches | |
| `-workload <jsonfile>` | Run mixed workload groups from a sqlsim-format JSON definition file; cannot be combined with `-Q` or `-i` | |
| `-n <threads>` | Number of concurrent threads | 1 |
| `-r <iterations>` | Iterations per thread | 1 |

### Output Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-q` | Quiet mode - suppress query results | Off |
| `-v` | Verbose mode - detailed metrics and percentiles | Off |
| `-json` | Output results as JSON | Off |
| `-stream-json` | Stream live progress events as one JSON object per line | Off |
| `-o <file>` | Write output to file | (stdout) |
| `-querystats` | Show sqlsim-compatible per-query server statistics | Off |
| `-querystats-interval <n>` | Write a snapshot every n seconds (implies `-querystats`) | Off |
| `-querystats-file <file>` | Snapshot path | querystats-live.json |

`-querystats` aggregates the same fields as sqlsim across all threads and
iterations: client elapsed time, server elapsed and CPU time, compile time,
logical, physical, and read-ahead reads, row counts, executions, and failures.
sqlpysim obtains these counters from actual execution-plan result sets because
`mssql-python` does not preserve the final `SET STATISTICS TIME/IO` diagnostics
across `nextset()`. The plan result is consumed internally and is never included
in query rows or JSON. This mode does not query DMVs, require server-state
permissions, or emit query/plan hashes.

`-stream-json` replaces the single JSON document with a stream of events, one
compact JSON object per line on stdout, matching sqlsim's shape and cadence.
It turns on JSON mode. Events go to stdout even when `-o` is supplied, because
the stream is a channel for a supervising process rather than part of the run's
recorded output.

Combine `-stream-json` with `-json -o <file>` to retain the complete canonical
result while streaming. NDJSON remains on stdout and the final JSON document is
written to the file after completion. The combined mode requires `-o` so the
two JSON formats never share one channel.

| Event | When | Fields |
|-------|------|--------|
| `started` | Once, before the first connection | `type`, `timestamp`, `version`, `threads` |
| `progress` | Every second while running | `type`, `timestamp`, `elapsed_seconds`, connection and execution counters, `errors`, `throughput_per_second`, and, after the first successful connection, `odbc_driver_version`, `server_version`, and `server_edition` |
| `completed` | Once, after the last thread finishes | The `progress` fields plus `status`, either `success` or `error` |

Counters are cumulative, and `throughput_per_second` is the running average
since the run began rather than an instantaneous rate; a consumer wanting a
current rate computes the delta between two events. A run shorter than one
second emits only `started` and `completed`.

```bash
python sqlpysim.py -S localhost -d AdventureWorksLT -E -C \
    -Q "SELECT TOP 100 * FROM SalesLT.Product" -n 4 -r 500 -stream-json -q

python sqlpysim.py -S localhost -d AdventureWorksLT -E -C \
    -Q "SELECT TOP 100 * FROM SalesLT.Product" -n 4 -r 500 \
    -stream-json -json -o final-results.json -q
```

```json
{"type":"started","timestamp":"2026-09-30T14:43:35.359","version":"1.0.0","threads":4}
{"type":"progress","timestamp":"2026-09-30T14:43:36.371","elapsed_seconds":1.012,"successful_connections":4,"failed_connections":0,"successful_executions":812,"failed_executions":0,"errors":0,"throughput_per_second":802.372,"odbc_driver_version":"1.15.0","server_version":"16.0.4215.2","server_edition":"Developer Edition (64-bit)"}
{"type":"completed","timestamp":"2026-09-30T14:43:38.510","elapsed_seconds":3.150,"successful_connections":4,"failed_connections":0,"successful_executions":2000,"failed_executions":0,"errors":0,"throughput_per_second":634.920,"odbc_driver_version":"1.15.0","server_version":"16.0.4215.2","server_edition":"Developer Edition (64-bit)","status":"success"}
```

`-querystats-interval <seconds>` writes a query-statistics snapshot to a file
while the run is in progress, so a dashboard can read server-side counters
without waiting for the run to end. It implies `-querystats`.
`-querystats-file` sets the path, defaulting to `querystats-live.json` in the
working directory.

A first snapshot is written immediately, then one per interval, then a final
one after the last thread finishes. The file is written to a temporary name in
the same directory and renamed over the target, so a reader never sees a
partially written file.

A write failure never interrupts the workload: the run continues and the exit
code is unaffected. It is reported once on the normal error channel, so a
mistyped path does not look like a healthy run, and later failures stay quiet
so a per-interval timer cannot flood the output. That channel is silent in
`-json` and `-stream-json` modes, so machine-readable output is never
disturbed; in those modes check that the file exists rather than relying on a
message. `sqlsim` behaves the same way.

Each snapshot carries `timestamp`, `elapsed_seconds`,
`execution_elapsed_seconds`, `throughput`, `peak_throughput`, and `status`
(`running` until the final snapshot, then `complete`), followed by `config`,
`connection_stats`, `query_stats` with the same per-query aggregates and
totals `-querystats` prints, `total_errors`, `total_warnings`,
`recent_errors`, and `recent_warnings`.

`throughput` is measured over the execution window rather than the whole run,
so the connection phase does not depress it, and `peak_throughput` retains the
highest value seen across the run.

```bash
python sqlpysim.py -S localhost -d AdventureWorksLT -E -C \
    -Q "SELECT TOP 100 * FROM SalesLT.Product" -n 4 -r 500 \
    -querystats-interval 5 -querystats-file live.json -q
```

`recent_warnings` retains the ten most recent structured ODBC warning entries,
matching the final JSON `metrics.warnings.list` contract.

### Connection Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-C` | Trust server certificate explicitly | Without `-N`, certificates are trusted; with `-N`, certificates are validated |
| `-N [level]` | Encryption level (o=optional, m=mandatory, s=strict) | mandatory when `-N` is specified without a level |
| `-R <intent>` | Application intent (readonly/readwrite) | readwrite |
| `-M` | Enable MultiSubnetFailover | Off |
| `-l <seconds>` | Login timeout (0–86400) | 30 |
| `-t <seconds>` | Query timeout (0–86400) | 0 (no timeout) |
| `-app <name>` | Not supported: the driver reserves the application name | n/a |

### Control Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-p` | Prepared statements (accepted with warning, not functional) | Off |
| `-stoponerror` | Stop on first error | Off |
| `-reconnect` | Reconnect for each iteration | Off |
| `-usepool` | Enable connection pooling (requires `-reconnect`) | Off |
| `-retry <count>` | Connection retry attempts (0–255) | 0 |
| `-retrydelay <seconds>` | Seconds between retries (1–60) | 10 |
| `-h`, `-?`, `--help` | Show help message | |
| `--version` | Show version information | |

[↑ Back to Table of Contents](#table-of-contents)

## Limits and Resource Considerations

sqlpysim does not impose fixed size caps on SQL text, SQL script files, or
workload JSON files. Those inputs are memory-bound and remain subject to
operating-system, `mssql-python`, ODBC driver, and SQL Server limits. A missing
application cap does not mean an input or concurrency level is safe.

### Input and Output Limits

| Item | sqlpysim limit | Resource consideration |
|------|----------------|------------------------|
| Command-line query (`-Q`) | No explicit sqlpysim cap | The operating system's command-line length, available memory, driver behavior, and SQL Server batch limit still apply. Use `-i` for large scripts. |
| SQL script (`-i`) | No explicit file-size cap | The complete file is loaded into memory and split into batches before execution. |
| Workload JSON (`-workload`) | No explicit file-size cap | The complete JSON document is loaded into memory before parsing. |
| Script referenced by workload JSON | No explicit file-size cap | Each script is loaded into memory; workload expansion and high thread counts increase client memory use. |
| Inline query in workload JSON | No explicit per-query cap | Query text is held in memory and remains subject to SQL Server's batch limit. |
| Query result set when not using `-q` | No explicit row or byte cap | `mssql-python` fetches the result set into client memory before sqlpysim formats it. Use `-q` for load tests. |
| Text, JSON, and statistics output files | No explicit file-size cap | Available disk space is the effective limit. Verbose output and large error collections can grow quickly. |
| SQL batch sent to the server | SQL Server limit | SQL Server allows 65,536 times the negotiated network packet size per batch; the default 4 KB packet size is approximately 256 MiB. |
| Replay XML | Not supported | Use sqlsim for workload replay. |

Use `GO` separators to split large scripts into smaller batches. Keep individual
batches well below the server maximum; very large batches increase client
memory, network traffic, compilation cost, and server memory use.

### Numeric and Concurrency Limits

| Item | Accepted range | Resource consideration |
|------|----------------|------------------------|
| Threads (`-n`) | 1 or greater; no explicit maximum | Each worker consumes Python and driver memory, scheduling capacity, network resources, and a database connection. |
| Iterations (`-r`) | 1 or greater; no explicit maximum | Total executions multiply by threads and batches. |
| Login and query timeouts (`-l`, `-t`) | 0 to 86,400 seconds | Zero uses the documented driver behavior for that option. |
| Retry count (`-retry`) | 0 to 255 | Retries can extend total runtime. |
| Retry delay (`-retrydelay`) | 1 to 60 seconds | Applied between connection attempts. |

Workload-file groups add their thread counts together. Start with a small
thread count, scale gradually, and monitor CPU, memory, network, open
connections, and errors on both client and server. Stop scaling when the
client becomes saturated, because results beyond that point measure the load
generator rather than the database. Use a dedicated client machine for
significant load tests.

[↑ Back to Table of Contents](#table-of-contents)

## Usage Examples

The following examples demonstrate common sqlpysim scenarios. Examples are shown in both **PowerShell (Windows)** and **Bash (Linux/macOS)** formats where authentication differs.

> **Platform Note:** Windows Authentication (`-E`) uses SSPI on Windows and Kerberos on
> Linux. Linux requires a domain-joined host with an active credential cache and is
> untested. On Linux prefer SQL Auth (`-U`/`-P`) or Token Auth (`-T`).
>
> The Linux/macOS SQL Auth examples below pipe the password from `$SQL_PASSWORD` with
> `-P -`, so it never appears in the process list. Set it once without echo:
> `read -rs -p 'SQL password: ' SQL_PASSWORD; echo`

### Basic Query Execution

**Simple query test:**
```bash
# Linux/macOS (SQL Auth)
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT @@VERSION"

# Windows (Windows Auth)
python sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"
```

**Default to localhost (Linux/macOS):**
```bash
# -S defaults to localhost when authentication is provided
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -U sa -P - -C -Q "SELECT @@VERSION"
```

**Query from file (Linux/macOS):**
```bash
# Execute queries from a SQL script file
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -i workload.sql
```

**Verbose mode for debugging (Linux/macOS):**
```bash
# See detailed execution phases and metrics
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1" -v
```

**Quiet mode for load testing (Linux/macOS):**
```bash
# Suppress result output, show only metrics
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -i queries.sql -n 50 -r 100 -q
```

**Output file redirection (Linux/macOS):**
```bash
# Write all output to file
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT @@VERSION" -o output.txt
```

**JSON output for programmatic parsing:**

**Bash (Linux/macOS):**
```bash
# Output results in JSON format
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1" -n 10 -json

# Parse JSON with jq
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1" -n 10 -json | jq '.metrics.p99_ms'

# Parse JSON with Python
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1" -n 10 -json | \
    python3 -c "import sys, json; d=json.load(sys.stdin); print(f'P99: {d[\"metrics\"][\"p99_ms\"]}ms')"
```

**PowerShell (Windows):**
```powershell
# Parse JSON with PowerShell
$result = python sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 10 -json | ConvertFrom-Json
Write-Host "Success: $($result.success)"
Write-Host "P99 Latency: $($result.metrics.p99_ms) ms"
```

**Stop on first error (Linux/macOS):**
```bash
# Exit immediately on any SQL error
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -i script.sql -stoponerror
```

**Query and login timeouts (Linux/macOS):**
```bash
# Set 30-second connection timeout and 60-second query timeout
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S myserver -d mydb -U sa -P - -C -l 30 -t 60 -i workload.sql
```

### Running Multiple Concurrent Users

**Simulate concurrent users (Linux/macOS):**
```bash
# 50 concurrent threads, each running 100 iterations (5000 total queries)
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -i queries.sql -n 50 -r 100 -q
```

**High concurrency stress test (Linux/macOS):**
```bash
# Test with 100 concurrent connections
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1" -n 100 -r 10 -q
```

**Connection-only load test (Linux/macOS):**
```bash
# Test connection limits without queries (10 threads, 5 connect/disconnect cycles each)
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -n 10 -r 5
```

### Authentication Examples

**Windows Authentication (Windows only):**
```powershell
# Use Windows Authentication (Windows only)
python sqlpysim.py -S localhost -E -C -Q "SELECT SUSER_SNAME()"
```

**SQL Server Authentication (Linux/macOS):**
```bash
# Use SQL Server username and password
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S myserver -d mydb -U sqladmin -P - -Q "SELECT USER_NAME()"
```

**Microsoft Entra Interactive (Windows):**
```powershell
# Opens browser for Azure authentication
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT USER_NAME()"
```

**Microsoft Entra Managed Identity (Linux/macOS - Azure VMs, containers):**
```bash
# Use Azure VM or App Service managed identity
python3 sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -Q "SELECT SUSER_SNAME()"

# System-assigned managed identity (same as above)
python3 sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -Q "SELECT 1"

# User-assigned managed identity (specify client ID)
python3 sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -U <client_id> -Q "SELECT 1"
```

**Access Token authentication:**
```powershell
# First, sign in to Azure (one-time setup)
az login

# Acquire token and use it
$token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT @@VERSION"
```

### Using Azure SQL Database

**Basic Azure SQL Database connection:**
```powershell
# Connect to Azure SQL Database with Entra auth
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT @@VERSION"
```

**Azure SQL with read replica:**
```powershell
# Route to read replica (Business Critical/Premium tier)
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -R readonly -Q "SELECT @@SERVERNAME"
```

**Azure SQL performance testing:**
```powershell
# Test Azure SQL under concurrent load
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -i workload.sql -n 25 -r 100 -q
```

### Connection Behavior Examples

**Test connection establishment overhead:**
```powershell
# Reconnect after each iteration
python sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION" -r 10 -reconnect -v
```

**Connection-only testing (no queries):**
```powershell
# Test pure connection overhead with reconnects
python sqlpysim.py -S localhost -E -C -r 50 -reconnect -v
```

### Connection Encryption Examples

**Basic encryption (default):**
```powershell
# -N defaults to mandatory encryption
python sqlpysim.py -S localhost -E -C -N -Q "SELECT @@VERSION"
```

**Optional encryption:**
```powershell
# Optional encryption (allow unencrypted if server doesn't require)
python sqlpysim.py -S localhost -E -N o -Q "SELECT @@VERSION"
```

**Strict encryption (TDS 8.0):**
```powershell
# Requires valid CA-signed certificates
python sqlpysim.py -S sql.company.com -E -N s -Q "SELECT @@VERSION"
```

### Always On Availability Group Examples

**Connect to read replica:**
```powershell
# Route to secondary replica for read workloads
python sqlpysim.py -S ag-listener -d mydb -E -C -R readonly -Q "SELECT @@SERVERNAME"
```

**Multi-subnet failover:**
```powershell
# Enable for multi-subnet AGs
python sqlpysim.py -S ag-listener -d mydb -E -C -M -Q "SELECT @@VERSION"
```

**Combined AG settings:**
```powershell
# Read-only intent with multi-subnet failover
python sqlpysim.py -S ag-listener -d mydb -E -C -R readonly -M -Q "SELECT COUNT(*) FROM Sales"
```

### Example Files

The `examples/` directory mirrors sqlsim's layout. Each folder has its own README.

**SQL Files (`examples/sql/`):**

| File | Description |
|------|-------------|
| `01-simple-queries.sql` | Catalog view queries to verify connectivity; works on any database |
| `02-customer-queries-adventureworkslt.sql` | Customer table queries with filters; requires AdventureWorksLT |
| `03-product-queries-adventureworkslt.sql` | Product catalog queries; requires AdventureWorksLT |
| `04-sales-queries-adventureworkslt.sql` | Sales order queries with joins; requires AdventureWorksLT |
| `05-aggregation-queries-adventureworkslt.sql` | Aggregation and `GROUP BY` queries; requires AdventureWorksLT |
| `06-complex-joins-adventureworkslt.sql` | Multi-table joins; requires AdventureWorksLT |
| `07-insert-test-adventureworkslt.sql` | Temporary-data `INSERT` operations; requires AdventureWorksLT |
| `08-mixed-workload-adventureworkslt.sql` | Mixed OLTP-style reads; requires AdventureWorksLT |
| `09-reporting-queries-adventureworkslt.sql` | Analytical reporting queries; requires AdventureWorksLT |
| `setup-managed-identity-access.sql` | Grants a managed identity access to Azure SQL Database |

**PowerShell Scripts (`examples/powershell/`):**

| Script | Description |
|--------|-------------|
| `localhost-simple-test.ps1` | Localhost default-server example; works on any database |
| `sql-auth-simple.ps1` | SQL authentication example; works on any database |
| `run-basic-tests-adventureworkslt.ps1` | Runs examples 01-04 on localhost with Windows authentication |
| `run-basic-tests-verbose-adventureworkslt.ps1` | Runs examples 01-04 with verbose output |
| `run-all-tests-adventureworkslt.ps1` | Runs examples 01-09 on localhost |
| `run-load-test-adventureworkslt.ps1` | Runs `08-mixed-workload-adventureworkslt.sql` at 1, 5, 10, 25, and 50 threads |
| `azure-simple-interactive.ps1` | Azure SQL example with interactive Microsoft Entra authentication |
| `run-basic-tests-azure-adventureworkslt.ps1` | Runs examples 01-04 on Azure SQL with an access token |
| `run-all-tests-azure-adventureworkslt.ps1` | Runs examples 01-09 on Azure SQL with an access token |
| `run-load-test-azure-adventureworkslt.ps1` | Runs the load-test sequence on Azure SQL |
| `json-output-examples.ps1` | JSON parsing examples |
| `test-managed-identity.ps1` | Managed identity authentication test for an Azure host |
| `basic-perf-benchmark.ps1` | Performance benchmarking |

**Workload Files (`examples/workload/`):**

| File | Description |
|------|-------------|
| `workload-basic.json` | Two-group iteration workload with think time |
| `workload-duration.json` | Two-group duration-mode workload with think time |

The `examples/github-actions-ci/` guide shows how to use sqlpysim as a workload gate in GitHub Actions.

### Run Examples

```powershell
# Run a simple example
python sqlpysim.py -S localhost -E -C -i examples/sql/01-simple-queries.sql

# Run the PowerShell example scripts
.\examples\powershell\localhost-simple-test.ps1
.\examples\powershell\run-basic-tests-adventureworkslt.ps1
```

[↑ Back to Table of Contents](#table-of-contents)

## Understanding Output

sqlpysim provides multiple output modes: standard output with timestamps, quiet mode for performance testing, verbose mode for detailed metrics, and JSON mode for programmatic parsing.

### Timestamp Format

All output lines (except JSON mode) are prefixed with timestamps in the format `YYYY-MM-DD HH:MM:SS.mmm | `. This provides millisecond-precision timing for all operations.

**Example output (with various options):**
```
2026-01-30 10:15:23.456 | === SQL Python Workload Simulator v1.0.0 ===
2026-01-30 10:15:23.456 | Driver: mssql-python
2026-01-30 10:15:23.456 | Configuration:
2026-01-30 10:15:23.456 | Server: localhost
2026-01-30 10:15:23.456 | Database: testdb
2026-01-30 10:15:23.456 | Authentication: Windows
2026-01-30 10:15:23.456 | Threads: 2
2026-01-30 10:15:23.456 | Iterations per thread: 3
2026-01-30 10:15:23.456 | Total batches to execute: 42
2026-01-30 10:15:23.456 | Batches in workload: 7
2026-01-30 10:15:23.456 | Input file: queries.sql
2026-01-30 10:15:23.456 | Query timeout: 30 seconds
2026-01-30 10:15:23.456 | Reconnect per iteration: Yes
2026-01-30 10:15:23.456 | Stop on error: Yes
2026-01-30 10:15:23.456 | Application name: sqlpysim
2026-01-30 10:15:23.456 | Trust server certificate: Yes
2026-01-30 10:15:23.456 | Output file: results.txt
2026-01-30 10:15:23.456 | Quiet mode: Yes
2026-01-30 10:15:23.456 | Verbose mode: Yes
2026-01-30 10:15:23.456 |
2026-01-30 10:15:23.456 | Connecting...
2026-01-30 10:15:23.500 | Driver Version: 1.15.0
2026-01-30 10:15:23.500 | Starting execution (2 threads)
```

**Note:** Configuration lines are shown only when the corresponding option is set.

### Output File (`-o`)

Redirects all output to a specified file while showing progress on console:
- Console shows: "Output redirected to: <file>", "Connecting to...", "Execution complete"
- File captures: query results, metrics, errors, and all other output
- File is created/overwritten when sqlpysim starts
- Example: `python sqlpysim.py -E -C -Q "SELECT 1" -o results.txt`

**Console output when using -o:**
```
2026-01-30 10:15:23.456 | === SQL Python Workload Simulator v1.0.0 ===
2026-01-30 10:15:23.456 | Driver: mssql-python
2026-01-30 10:15:23.456 | Output redirected to: results.txt
2026-01-30 10:15:23.456 | Connecting to localhost...
```

### Quiet Mode (`-q`)

Suppresses console output of query results:
- No column headers or row data printed to console
- **Still fetches and processes all rows** from result sets
- Significantly improves performance by eliminating console I/O overhead
- Ideal for load testing and benchmarking
- All performance metrics remain accurate
- Example: `python sqlpysim.py -E -C -Q "SELECT * FROM LargeTable" -n 10 -r 100 -q`

### Verbose Mode (`-v`)

Shows detailed execution phases and metrics:
- Displays configuration summary before execution
- Shows per-thread connection status
- Prints detailed performance metrics with percentiles
- Shows server edition and version
- Useful for debugging and understanding execution flow
- Example: `python sqlpysim.py -E -C -Q "SELECT 1" -n 5 -v`

**Verbose Mode Phases:**
1. **PHASE 1: Configuration** - Shows threads, iterations, queries, connection settings
2. **PHASE 2: Connection** - Connection messages, Server Edition and Version
3. **PHASE 3: Executing workload** - Query execution begins
4. **PHASE 4: Workload completed** - Execution finished
5. **PHASE 5: Summary** - Detailed metrics with percentiles

### Understanding Percentile Metrics (P50, P95, P99)

sqlpysim reports latency percentiles to help you understand performance distribution:

| Metric | Meaning | Why It Matters |
|--------|---------|----------------|
| **Avg** | Average (mean) latency | General indicator, but can hide outliers |
| **Min** | Fastest operation | Best-case performance |
| **Max** | Slowest operation | Worst-case performance |
| **P50** | 50th percentile (median) | Half of operations completed faster |
| **P95** | 95th percentile | 95% of operations completed faster |
| **P99** | 99th percentile | Shows "long tail" latency |

**Why percentiles matter more than averages:**

- **Averages hide outliers**: A system with Avg=1ms but P99=100ms has serious tail latency
- **P95/P99 show real user experience**: If P99=500ms, 1 in 100 users experiences half-second delays
- **Identifies contention**: When P99 >> P50, it indicates resource contention under load

**Example interpretation:**
```
Execution Metrics:
Avg: 0.47 ms      ← Average looks great
Min: 0.14 ms      ← Best case
Max: 5.06 ms      ← One outlier hit 5ms
P50: 0.32 ms      ← Half completed in <0.32ms (better than avg!)
P95: 1.26 ms      ← 95% completed in <1.26ms
P99: 3.50 ms      ← 1% took >3.5ms (10x the median)
```

### JSON Output Mode (`-json`)

Outputs results in structured JSON format for programmatic parsing:
- Complete configuration and metrics in machine-readable format
- **Automatically suppresses query result output**
- Compatible with `-o` flag to write JSON to a file
- Designed for metrics collection, not query result retrieval
- Example: `python sqlpysim.py -E -C -Q "SELECT 1" -n 10 -json -o results.json`

### JSON Output Structure

**JSON Example:**
```json
{
  "version": "1.0.0",
  "start_time": "2026-02-14T10:15:23.456",
  "configuration": {
    "odbc_driver": "mssql-python",
    "server": "localhost",
    "database": "master",
    "authentication": "Windows",
    "threads": 1,
    "iterations_per_thread": 1,
    "total_batches": 1,
    "batch_count": 1,
    "batches": ["SELECT 1"],
    "application_name": "MSSQL-Python",
    "retry_count": 0
  },
  "metrics": {
    "odbc_driver_version": "1.15.0",
    "total_runtime_seconds": 0.044,
    "total_connection_time_seconds": 0.035,
    "total_query_execution_time_seconds": 0.002,
    "end_time": "2026-02-14T10:15:23.500",
    "errors": {
      "total": 0,
      "list": []
    },
    "warnings": {
      "total": 0,
      "list": []
    }
  },
  "server_edition": "Enterprise Developer Edition (64-bit)",
  "server_version": "17.0.4085.5",
  "success": true
}
```

**JSON with Errors:**

When errors occur, the `errors.list` array contains detailed error objects:

```json
{
  "errors": {
    "total": 1,
    "list": [
      {
        "type": "sql_error",
        "timestamp": "2026-02-14T10:15:23.456",
        "message": "Invalid object name 'nonexistent_table'"
      }
    ]
  },
  "warnings": {
    "total": 0,
    "list": []
  }
}
```

**Verbose JSON Example (`-json -v`):**

With the `-v` flag, thread-level connection and iteration details are included:

```json
{
  "version": "1.0.0",
  "start_time": "2026-02-14T10:15:23.456",
  "configuration": { "..." : "..." },
  "metrics": {
    "odbc_driver_version": "1.15.0",
    "total_runtime_seconds": 0.544,
    "total_connection_time_seconds": 0.125,
    "total_query_execution_time_seconds": 0.419,
    "end_time": "2026-02-14T10:15:24.000",
    "errors": { "total": 0, "list": [] },
    "warnings": { "total": 0, "list": [] }
  },
  "success": true,
  "thread_connections": [
    {"thread_id": 0, "connect_time_ms": 33.337, "status": "success"},
    {"thread_id": 1, "connect_time_ms": 0.510, "status": "success"}
  ],
  "thread_iterations": [
    {
      "thread_id": 0,
      "iterations": [
        {"iteration": 1, "total_query_ms": 0.654, "queries_executed": 1, "queries_failed": 0},
        {"iteration": 2, "total_query_ms": 0.336, "queries_executed": 1, "queries_failed": 0}
      ]
    },
    {
      "thread_id": 1,
      "iterations": [
        {"iteration": 1, "total_query_ms": 0.482, "queries_executed": 1, "queries_failed": 0},
        {"iteration": 2, "total_query_ms": 0.421, "queries_executed": 1, "queries_failed": 0}
      ]
    }
  ]
}
```

**JSON Field Descriptions:**

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | sqlpysim version |
| `start_time` | string | ISO 8601 timestamp when execution started |
| `configuration.server` | string | Server name |
| `configuration.database` | string | Database name or "(default)" |
| `configuration.authentication` | string | Authentication method used |
| `configuration.threads` | number | Number of concurrent threads |
| `configuration.iterations_per_thread` | number | Iterations per thread |
| `configuration.total_batches` | number | Total batch executions planned |
| `configuration.batch_count` | number | Number of distinct batches |
| `configuration.batches` | array | Array of batch query strings |
| `configuration.application_name` | string | Application name |
| `configuration.stream_json` | boolean | Set to true when `-stream-json` was used (shown only when enabled) |
| `metrics.total_runtime_seconds` | number | Total execution time |
| `metrics.total_connection_time_seconds` | number | Total time spent connecting |
| `metrics.total_query_execution_time_seconds` | number | Total time spent executing queries |
| `metrics.end_time` | string | ISO 8601 timestamp when execution ended |
| `metrics.errors.total` | number | Total error count |
| `metrics.errors.list` | array | Array of error objects (max 10) with `type`, `timestamp`, `message` |
| `metrics.warnings.total` | number | Total ODBC warning count |
| `metrics.warnings.list` | array | Up to ten recent structured ODBC warnings |
| `server_edition` | string | SQL Server edition from `SERVERPROPERTY('Edition')` (shown when the server returns it) |
| `server_version` | string | SQL Server product version from `SERVERPROPERTY('ProductVersion')` (shown when the server returns it) |
| `success` | boolean | Overall success status |
| `thread_connections` | array | *(verbose only)* Per-thread connection results with `thread_id`, `connect_time_ms`, `status` |
| `thread_iterations` | array | *(verbose only)* Per-thread iteration details with `thread_id`, `iterations[]` |

### JSON Use Cases

1. **CI/CD Integration:**
   ```powershell
   $result = python sqlpysim.py -E -C -Q "SELECT 1" -n 10 -r 100 -json | ConvertFrom-Json
   if ($result.metrics.p99_ms -gt 100) {
       Write-Host "WARN: P99 latency exceeds 100ms threshold"
       exit 1
   }
   ```

2. **Performance Monitoring:**
   ```powershell
   # Capture metrics over time
   python sqlpysim.py -E -C -i workload.sql -n 10 -r 100 -json -o "metrics_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
   ```

3. **Comparison Testing:**
   ```powershell
   # Before optimization
   python sqlpysim.py -E -C -i queries.sql -n 10 -r 50 -json -o before.json
   # After optimization
   python sqlpysim.py -E -C -i queries.sql -n 10 -r 50 -json -o after.json
   ```

[↑ Back to Table of Contents](#table-of-contents)

## Query Stats

`-querystats` collects per-query server statistics and aggregates them by unique
query text across every thread and iteration. The text summary and the
`query_stats` JSON object use the same field names as sqlsim, so reports and
pipelines can parse either tool.

```powershell
python sqlpysim.py -S localhost -E -C -i queries.sql -n 4 -r 50 -querystats -json -q -o results.json
```

| Field | Description |
|-------|-------------|
| `total_elapsed_ms` | Client wall-clock time per execution, including network round-trip |
| `server_elapsed_ms` / `server_cpu_ms` | Server-reported elapsed and CPU time for the statement |
| `server_elapsed_sum_ms` / `server_cpu_sum_ms` | Sum of server elapsed and CPU time across statements in the batch |
| `compile_elapsed_ms` | Plan compile time |
| `logical_reads`, `physical_reads`, `read_ahead_reads` | Buffer pool, disk, and read-ahead page reads |
| `row_count` | Rows returned per execution, when the query returns rows |
| `executions`, `failures` | Successful and failed execution counts |
| `spids` | Up to the first 10 distinct SQL Server session IDs (SPIDs) that executed the query, in ascending order |
| `spid_count` | Total distinct SPIDs that executed the query |

Each metric reports `avg`, `min`, and `max`, and the `totals` object sums the
same fields across all queries. sqlpysim reads each connection's SPID once,
when query statistics are enabled, and again after each reconnect; failed
executions keep their SPID. SQL Server can reuse a session ID after a
disconnect, so reconnect mode may report fewer SPIDs than connections.

sqlpysim collects these counters from actual execution-plan result sets because
`mssql-python` does not preserve the final `SET STATISTICS TIME/IO` diagnostics
across result sets. The plan result is consumed internally and never appears in
query output or JSON. This mode does not read DMVs, require server-state
permissions, or emit query or plan hashes.

Do not add `SET STATISTICS` statements to SQL run with `-querystats`; sqlpysim
manages the session setting.

[↑ Back to Table of Contents](#table-of-contents)

## SQL Script Files

### File Format

SQL script files use `GO` as batch separators (case-insensitive). Each batch is executed separately.

**Important:** `GO` must be on its own line to be recognized as a batch separator.

**Example: `queries.sql`**
```sql
-- Query 1: Get database info
SELECT DB_NAME() AS DatabaseName, @@VERSION AS Version
GO

-- Query 2: Get server name
SELECT @@SERVERNAME AS ServerName
GO

-- Query 3: Count databases
SELECT COUNT(*) AS DatabaseCount FROM sys.databases
GO
```

### File Format Rules

1. **Batch Separator:** Use `GO` on its own line to separate batches
   - **Case Insensitive:** `GO`, `go`, `Go`, `gO` all work
   - **Whitespace:** Leading/trailing spaces are trimmed
2. **Comments:** Lines with `--` comments are passed to SQL Server
3. **Empty Lines:** Preserved in the SQL batch
4. **Multiple Statements:** Multiple statements in one batch (before GO) are allowed

### Using GO with Command-Line Queries (-Q)

When using `-Q` with GO batch separators, GO must be on its own line. Use PowerShell's multi-line string syntax:

```powershell
# PowerShell: Use @" "@ here-string for multi-line queries with GO
python sqlpysim.py -E -C -Q @"
SELECT 1 AS FirstBatch
GO
SELECT 2 AS SecondBatch
GO
SELECT 3 AS ThirdBatch
"@

# Alternative: Use actual newlines
python sqlpysim.py -E -C -Q "SELECT 1
GO
SELECT 2"
```

**Common mistakes to avoid:**
```powershell
# WRONG: GO inline with SQL - causes syntax error
python sqlpysim.py -E -C -Q "SELECT 1;GO;SELECT 2"

# CORRECT: GO on its own line
python sqlpysim.py -E -C -Q "SELECT 1
GO
SELECT 2"
```

### Using Script Files

```powershell
# Execute all batches in the file once
python sqlpysim.py -S localhost -E -C -i queries.sql

# Execute all batches 100 times with 10 threads
python sqlpysim.py -S localhost -E -C -i queries.sql -n 10 -r 100 -q
```

### Multiple Result Sets

sqlpysim supports multiple result sets within a single batch. When a batch contains multiple SELECT statements separated by semicolons (not GO), all result sets are displayed:

```powershell
# Multiple SELECTs in one batch (semicolon separated)
python sqlpysim.py -E -C -Q "SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c"
```

**Output:**
```
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | a
2026-01-30 10:15:23.456 | --------------------------------------------------------------------------------
2026-01-30 10:15:23.456 | 1
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | (1 row(s) affected)
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | b
2026-01-30 10:15:23.456 | --------------------------------------------------------------------------------
2026-01-30 10:15:23.456 | 2
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | (1 row(s) affected)
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | c
2026-01-30 10:15:23.456 | --------------------------------------------------------------------------------
2026-01-30 10:15:23.456 | 3
2026-01-30 10:15:23.456 | 
2026-01-30 10:15:23.456 | (1 row(s) affected)
```

**Key distinction:**
- **Semicolon (`;`)**: Multiple statements in ONE batch - all result sets returned together
- **GO**: Separate batches - each batch executed independently

[↑ Back to Table of Contents](#table-of-contents)

## Unicode Support

sqlpysim provides full Unicode (UTF-8) support for both query execution and result retrieval.

### What's Supported

| Scenario | Supported | Example |
|----------|-----------|---------|
| **Retrieving Unicode data from tables** | ✅ Yes | `SELECT name FROM Products` where `name` contains 日本語 |
| **Unicode literals in queries** | ✅ Yes | `SELECT N'日本語'` (via file input) |
| **Unicode column names** | ✅ Yes | Column headers with international characters |
| **Unicode in error messages** | ✅ Yes | SQL Server error messages in any language |

### Using Unicode Queries

For Unicode literals in queries, use file input (`-i`) with UTF-8 encoded files:

```powershell
# Create a UTF-8 encoded SQL file
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText("query.sql", "SELECT N'日本語' AS test", $utf8NoBom)

# Execute the file
python sqlpysim.py -S localhost -E -C -i query.sql
```

### Console Display

Python handles Unicode output better than many native tools. However, the Windows console may not display all characters correctly. To verify:

```powershell
# Output to file, then read as UTF-8
python sqlpysim.py -S localhost -E -C -Q "SELECT NCHAR(26085) AS test" -o output.txt
Get-Content output.txt -Encoding UTF8
```

[↑ Back to Table of Contents](#table-of-contents)

## Error Handling

### Error Display Format

sqlpysim displays SQL Server errors with timestamps and clear formatting:

```
2026-01-30 10:15:23.456 | Error: [42S02] Invalid object name 'NonExistentTable'
```

### Common Error Types

| Error Code | Description | Common Cause |
|------------|-------------|--------------|
| `08001` | Connection failed | Server unreachable, wrong server name |
| `28000` | Login failed | Invalid credentials |
| `42S02` | Invalid object name | Table doesn't exist |
| `42000` | Syntax error | Invalid SQL syntax |
| `08S01` | Communication link failure | Network issues, server restart |

### Stop on Error (`-stoponerror`)

By default, sqlpysim continues execution after errors. Use `-stoponerror` to halt on first error:

```powershell
# Stop immediately on any error
python sqlpysim.py -S localhost -E -C -i script.sql -stoponerror
```

### Connection Errors

**Login timeout:**
```
Error: Login timeout expired
```
Indicates connection could not be established within timeout (`-l` parameter).

**Query timeout:**
```
Error: Query timeout expired
```
Indicates query execution was cancelled due to timeout (`-t` parameter).

### Retry Behavior

For transient failures, consider wrapping sqlpysim in a retry loop:

```powershell
$maxRetries = 3
$retryCount = 0
do {
    python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1"
    if ($LASTEXITCODE -eq 0) { break }
    $retryCount++
    Start-Sleep -Seconds 5
} while ($retryCount -lt $maxRetries)
```

[↑ Back to Table of Contents](#table-of-contents)

## Using Microsoft Entra Authentication

sqlpysim currently maps interactive authentication on Windows and managed
identity on supported Azure hosts. Use access-token authentication for other
non-interactive scenarios. Additional named Entra modes are tracked as a
compatibility gap in the repository release notes.

### Supported Authentication Methods

| Method | Flag | Use Case |
|--------|------|----------|
| **Interactive** | `-A` or `-A ActiveDirectoryInteractive` | Development, testing |
| **Managed Identity** | `-A ActiveDirectoryMsi` | Azure VMs, App Service, Containers |
| **Access Token** | `-T <token>` | Automation and custom token management |

### Interactive Authentication

Best for development and testing. Opens a browser for login:

```powershell
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT @@VERSION"
```

### Managed Identity Authentication

Best for production workloads running in Azure. No credentials needed.

**Supported Platforms:**
- Azure Virtual Machines
- Azure App Service
- Azure Container Instances
- Azure Kubernetes Service (AKS)
- Azure Functions
- Works on Windows and Linux

**System-assigned managed identity:**
```powershell
python sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -Q "SELECT SUSER_SNAME()"
```

**User-assigned managed identity:**
```powershell
python sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -U <client_id> -Q "SELECT SUSER_SNAME()"
```

**Setting up managed identity access:**
```sql
-- Run on Azure SQL Database as admin
CREATE USER [your-vm-name] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [your-vm-name];
ALTER ROLE db_datawriter ADD MEMBER [your-vm-name];
```

### Access Token Authentication

Best for custom token management scenarios:

```powershell
# Acquire token with Azure CLI
$token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)

# Use token with sqlpysim
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT @@VERSION"
```

**Token lifetime:**
- Access tokens are typically valid for 1 hour
- Acquire a fresh token before long-running tests

### Choosing the Right Method

| Method | Best For | Requires |
|--------|----------|----------|
| `-A` (Interactive) | Windows development and testing | User account, browser |
| `-A ActiveDirectoryMsi` | Production in Azure | Managed identity configured |
| `-T <token>` | Custom token management | Azure CLI or token provider |

[↑ Back to Table of Contents](#table-of-contents)

## Python Integration

sqlpysim is designed to integrate seamlessly with Python workflows, scripts, and automation pipelines.

### Calling from Python Scripts

Use `subprocess` to call sqlpysim from Python code:

```python
import subprocess
import json
import sys

def run_sqlpysim(server, database, query, threads=1, iterations=1):
    """Run sqlpysim and return parsed JSON results."""
    cmd = [
        sys.executable, "sqlpysim.py",
        "-S", server,
        "-d", database,
        "-A",  # Entra Interactive
        "-Q", query,
        "-n", str(threads),
        "-r", str(iterations),
        "-json"
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        raise RuntimeError(f"sqlpysim failed: {result.stderr}")
    
    return json.loads(result.stdout)

# Example usage
if __name__ == "__main__":
    results = run_sqlpysim(
        server="myserver.database.windows.net",
        database="mydb",
        query="SELECT COUNT(*) FROM Orders",
        threads=10,
        iterations=100
    )
    
    print(f"Success: {results['success']}")
    print(f"P99 Latency: {results['metrics']['p99_ms']} ms")
    print(f"Total Runtime: {results['metrics']['total_runtime_seconds']} s")
```

### Integration with pytest

Create performance regression tests with pytest:

```python
# test_performance.py
import subprocess
import json
import pytest

@pytest.fixture
def sqlpysim_runner():
    """Fixture to run sqlpysim commands."""
    def run(query, threads=1, iterations=1):
        result = subprocess.run([
            "python3", "sqlpysim.py",
            "-S", "localhost",
            "-U", "sa", "-P", "TestPassword123!",
            "-C",
            "-Q", query,
            "-n", str(threads),
            "-r", str(iterations),
            "-json"
        ], capture_output=True, text=True)
        return json.loads(result.stdout) if result.returncode == 0 else None
    return run

def test_simple_query_latency(sqlpysim_runner):
    """Test that simple queries complete in under 10ms average."""
    result = sqlpysim_runner("SELECT 1", threads=5, iterations=100)
    
    assert result is not None
    assert result["success"] is True
    assert result["metrics"]["avg_ms"] < 10, "Average latency exceeded 10ms"

def test_p99_latency_threshold(sqlpysim_runner):
    """Test that P99 latency stays under 100ms."""
    result = sqlpysim_runner("SELECT * FROM sys.databases", threads=10, iterations=50)
    
    assert result is not None
    assert result["success"] is True
    assert result["metrics"]["p99_ms"] < 100, f"P99 latency {result['metrics']['p99_ms']}ms exceeded 100ms"

def test_concurrent_connections(sqlpysim_runner):
    """Test that 50 concurrent connections succeed."""
    result = sqlpysim_runner("SELECT @@SPID", threads=50, iterations=10)
    
    assert result is not None
    assert result["success"] is True
    assert result["metrics"]["failed_batches"] == 0
```

Run tests:
```bash
pytest test_performance.py -v
```

### Environment Variables

sqlpysim respects standard environment variables for configuration:

```bash
# Set default server (Linux/macOS)
export SQLPYSIM_SERVER="myserver.database.windows.net"
export SQLPYSIM_DATABASE="mydb"

# Windows PowerShell
$env:SQLPYSIM_SERVER = "myserver.database.windows.net"
$env:SQLPYSIM_DATABASE = "mydb"
```

### CI/CD Integration

**GitHub Actions Example:**

```yaml
# .github/workflows/db-perf-test.yml
name: Database Performance Test

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM

jobs:
  perf-test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      
      - name: Install dependencies
        run: pip install mssql-python
      
      - name: Run performance tests
        env:
          SQL_ACCESS_TOKEN: ${{ secrets.SQL_ACCESS_TOKEN }}
        run: |
          printf '%s\n' "$SQL_ACCESS_TOKEN" | python3 sqlpysim.py \
            -S ${{ secrets.SQL_SERVER }} \
            -d ${{ secrets.SQL_DATABASE }} \
            -T - \
            -Q "SELECT COUNT(*) FROM Orders" \
            -n 10 -r 100 \
            -json -o results.json
      
      - name: Check latency threshold
        run: |
          P99=$(python3 -c "import json; print(json.load(open('results.json'))['metrics']['p99_ms'])")
          echo "P99 Latency: ${P99}ms"
          if (( $(echo "$P99 > 100" | bc -l) )); then
            echo "ERROR: P99 latency exceeded 100ms threshold"
            exit 1
          fi
      
      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: perf-results
          path: results.json
```

**Azure DevOps Pipeline:**

```yaml
# azure-pipelines.yml
trigger:
  - main

pool:
  vmImage: 'ubuntu-latest'

steps:
  - task: UsePythonVersion@0
    inputs:
      versionSpec: '3.12'
  
  - script: pip install mssql-python
    displayName: 'Install dependencies'
  
  - script: |
      python3 sqlpysim.py \
        -S $(SQL_SERVER) \
        -d $(SQL_DATABASE) \
        -A ActiveDirectoryMsi \
        -Q "SELECT 1" \
        -n 20 -r 50 \
        -json -o $(Build.ArtifactStagingDirectory)/results.json
    displayName: 'Run sqlpysim'
  
  - publish: $(Build.ArtifactStagingDirectory)/results.json
    artifact: perf-results
```

### Working with JSON Output in Python

```python
import json
import subprocess
from dataclasses import dataclass
from typing import Optional

@dataclass
class SqlpysimMetrics:
    """Parsed sqlpysim metrics."""
    total_runtime: float
    total_batches: int
    successful: int
    failed: int
    min_ms: float
    max_ms: float
    avg_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float

def parse_sqlpysim_output(json_str: str) -> Optional[SqlpysimMetrics]:
    """Parse sqlpysim JSON output into a dataclass."""
    data = json.loads(json_str)
    if not data.get("success"):
        return None
    
    m = data["metrics"]
    return SqlpysimMetrics(
        total_runtime=m["total_runtime_seconds"],
        total_batches=m["total_batches"],
        successful=m["successful_batches"],
        failed=m["failed_batches"],
        min_ms=m["min_ms"],
        max_ms=m["max_ms"],
        avg_ms=m["avg_ms"],
        p50_ms=m["p50_ms"],
        p95_ms=m["p95_ms"],
        p99_ms=m["p99_ms"]
    )

# Usage
result = subprocess.run([
    "python3", "sqlpysim.py", "-S", "localhost", "-U", "sa", "-P", "Pass123!",
    "-C", "-Q", "SELECT 1", "-n", "10", "-r", "100", "-json"
], capture_output=True, text=True)

metrics = parse_sqlpysim_output(result.stdout)
if metrics:
    print(f"Throughput: {metrics.total_batches / metrics.total_runtime:.1f} queries/sec")
    print(f"Latency Distribution: P50={metrics.p50_ms}ms, P95={metrics.p95_ms}ms, P99={metrics.p99_ms}ms")
```

### Docker Integration

**Dockerfile:**
```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install mssql-python driver
RUN pip install --no-cache-dir mssql-python

# Copy sqlpysim
COPY sqlpysim.py .
COPY examples/ ./examples/

ENTRYPOINT ["python", "sqlpysim.py"]
```

**Build and run:**
```bash
# Build the image
docker build -t sqlpysim .

# Run sqlpysim in container. -i forwards stdin, so -P - and -T - read the
# secret from the pipe and it never appears in `docker run` arguments.
printf '%s\n' "$SA_PASSWORD" | docker run --rm -i sqlpysim \
    -S host.docker.internal \
    -U sa -P - \
    -C \
    -Q "SELECT @@VERSION"

# Run against Azure SQL
printf '%s\n' "$SQL_ACCESS_TOKEN" | docker run --rm -i sqlpysim \
    -S myserver.database.windows.net \
    -d mydb \
    -T - \
    -Q "SELECT 1" \
    -n 10 -r 100 -json
```

### Makefile for Common Tasks

```makefile
# Makefile for sqlpysim workflows

PYTHON = python3
SQLPYSIM = $(PYTHON) sqlpysim.py
SERVER ?= localhost
DATABASE ?= master

.PHONY: test quick-test load-test azure-test clean

# Quick connectivity test
quick-test:
  printf '%s\n' "$$SQL_PASSWORD" | $(SQLPYSIM) -S $(SERVER) -U sa -P - -C -Q "SELECT 1"

# Run example files
test:
  printf '%s\n' "$$SQL_PASSWORD" | $(SQLPYSIM) -S $(SERVER) -U sa -P - -C -i examples/sql/01-simple-queries.sql

# Load test (100 users, 50 iterations)
load-test:
  printf '%s\n' "$$SQL_PASSWORD" | $(SQLPYSIM) -S $(SERVER) -U sa -P - -C \
		-Q "SELECT 1" -n 100 -r 50 -q -json -o load-results.json

# Azure SQL test with interactive auth
azure-test:
	$(SQLPYSIM) -S $(AZURE_SERVER) -d $(AZURE_DATABASE) -A \
		-Q "SELECT @@VERSION" -json

# Generate performance report
report: load-test
	@$(PYTHON) -c "import json; d=json.load(open('load-results.json')); \
		print(f'Queries: {d[\"metrics\"][\"total_batches\"]}'); \
		print(f'Success Rate: {d[\"metrics\"][\"successful_batches\"]/d[\"metrics\"][\"total_batches\"]*100:.1f}%'); \
		print(f'P99 Latency: {d[\"metrics\"][\"p99_ms\"]:.2f}ms')"

clean:
	rm -f *.json output.txt
```

**Usage:**
```bash
read -rsp "SQL password: " SQL_PASSWORD; printf '\n'
export SQL_PASSWORD
make quick-test
make load-test
make report
unset SQL_PASSWORD
```

[↑ Back to Table of Contents](#table-of-contents)

## Security and Best Practices

### Credential Security

**⚠️ Command-Line Credential Visibility**

When using SQL Authentication (`-P`) or Access Tokens (`-T`) with a literal value, credentials are visible in process lists.

For local applications and automation, pass the credential through redirected standard input so it never appears in the process command line:

```powershell
$password | python sqlpysim.py -S localhost -U testuser -P - -Q "SELECT 1"
$token | python sqlpysim.py -S server.database.windows.net -d mydb -T - -Q "SELECT 1"
```

`-P -` and `-T -` require redirected stdin and read exactly one UTF-8 line. They fail instead of prompting when stdin is an interactive terminal. Python retains immutable string values in process memory until reclaimed, but credentials are not included in command previews, results, or process arguments.

Verbose output and output files redact values supplied through `-P`, `-T`, and sensitive connection-string keywords. This does not prevent the operating system or shell from exposing command-line arguments while the process is running.

**Recommended Patterns:**
```powershell
# ✅ Preferred: Windows Authentication
python sqlpysim.py -S localhost -E -C -Q "SELECT 1"

# ✅ Preferred: Entra Interactive
python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1"

# ✅ Preferred: Managed Identity (no credentials)
python sqlpysim.py -S myserver.database.windows.net -d mydb -A ActiveDirectoryMsi -Q "SELECT 1"

# ✅ Access tokens via variable (not in shell history)
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"
```

### For Maximum Performance

1. **Run on a Separate Client:** Run sqlpysim on a dedicated client machine for accurate stress testing
2. **Ensure Low Network Latency:** Position client close to server
3. **Use Quiet Mode:** `-q` eliminates console I/O overhead
4. **Size Your Client:** High thread counts require sufficient client CPU and memory

### For Load Testing

1. **Start Small:** Begin with 1 thread, 1 iteration to verify queries work
2. **Scale Gradually:** Increase threads incrementally (10, 50, 100)
3. **Use Quiet Mode:** `-q` reduces output overhead
4. **Set Timeouts:** Use `-l` and `-t` to prevent hung connections/queries
5. **Monitor Client and Server:** Watch CPU, memory, network, and connection usage on the load generator as well as SQL Server. Stop increasing concurrency when the client becomes the bottleneck.

### For Development Testing

1. **Use Verbose Mode:** `-v` shows detailed execution flow
2. **Test Authentication:** Verify each auth method before load testing
3. **Validate Queries:** Run queries once before multi-threaded execution
4. **Use Scripts:** Create `.sql` files for repeatable tests

[↑ Back to Table of Contents](#table-of-contents)

## sqlpysim vs sqlsim - What's Different?

Both sqlpysim and sqlsim serve the same purpose: SQL workload simulation and
performance testing. They share a core command shape and common metrics
concepts, but they are not currently interchangeable for every option,
validation rule, or output consumer.

### Core Differences

| Aspect | sqlpysim | sqlsim |
|--------|----------|--------|
| **Language** | Python 3.10+ | C++ |
| **Driver** | ODBC Driver 18 (bundled by mssql-python) | ODBC Driver 18 (system-installed) |
| **Platform** | Windows, Ubuntu Linux | Windows, Ubuntu Linux |
| **Deployment** | Single .py file + pip install | Single .exe (xcopy deploy) |
| **Performance** | Very good | Excellent (native code) |

### Compatibility Summary

| Feature | sqlpysim | sqlsim |
|---------|----------|--------|
| CLI Parameters | Shared core subset | Full command set |
| Output Format | Similar conventions with documented differences | Reference format |
| JSON Output | Tool-specific schema with shared core concepts | Reference schema |
| Timestamp Format | Same display format | Same display format |
| Multi-threading | ✅ Yes | ✅ Yes |
| Multiple Result Sets | ✅ Yes | ✅ Yes |
| Windows Auth | ✅ Yes | ✅ Yes |
| Entra Auth | Interactive, Integrated, MSI, and Service Principal | Interactive, Integrated, MSI, and Service Principal |
| Token Auth | ✅ Yes | ✅ Yes |
| Managed Identity | ✅ Yes | ✅ Yes |
| Connection String | ✅ Yes (`-c`) | ✅ Yes (`-c`) |
| Multi-subnet Failover | ✅ Yes (`-M`) | ✅ Yes (`-M`) |
| Prepared Statements | ⚠️ Accepted with warning | ✅ Yes (`-p`) |
| Connection Retry | ✅ Yes (`-retry`, `-retrydelay`) | ✅ Yes (`-retry`, `-retrydelay`) |
| Connection Pooling | ✅ Yes (`-usepool` with `-reconnect`) | ✅ Yes (`-usepool` with `-reconnect`) |

### Features Not Available in sqlpysim

The following sqlsim features are **not available** or have limitations in sqlpysim:

| Feature | sqlsim | sqlpysim Status |
|---------|--------|---------------------|
| **Prepared Statements** (`-p`) | Uses ODBC `SQLPrepare()` + `SQLExecute()` for complete SQL text without bound parameters | Flag accepted but ignored with warning; mssql-python prepares only executions with bound parameters, while sqlpysim has no parameter-binding input |
| **Streaming JSON** (`-stream-json`) | Emits NDJSON progress events | Supported; same event types, fields, and one-second cadence |
| **XEvent replay** (`-replay`, `-replayfile`) | Fast and stress replay modes | Deliberately deferred from v1.0 Public Preview; future support may be considered. Use sqlsim for replay. |
| **Mixed workload files** (`-workload`) | Per-group concurrency, duration, think time, and ramp-up | Supported; same file format and validation |
| **Live query-stat snapshots** (`-querystats-interval`, `-querystats-file`) | Periodic JSON snapshots | Supported; same snapshot shape, cadence, and atomic replacement |
| **Pooling control** | Opt-in `-usepool` with reconnect mode | Supported with the same default and reconnect requirement |
| **Application name** (`-app`) | Applied to the ODBC connection | Rejected; the driver reserves the keyword and reports `MSSQL-Python` |
| **Certificate hostname** (`-F`) | Applied as `HostNameInCertificate` | Not supported in v1.0; future support will be investigated |

The complete current compatibility inventory is maintained in
[RELEASE-NOTES.md](https://github.com/microsoft/sqlsimtools/blob/main/RELEASE-NOTES.md#sqlpysim-does-not-yet-have-full-sqlsim-cli-or-output-compatibility).

### When to Use Each

**Use sqlpysim when:**
- You need cross-platform support (macOS, Linux)
- You prefer Python for scripting and automation
- You want to modify the source code easily
- You're in a Python-centric environment
- You want to compare `mssql-python` connection pooling with `-reconnect -usepool`

**Use sqlsim when:**
- You need maximum performance (native C++)
- You need prepared statement support (`-p`)
- You need XEvent replay (`-replay`, `-replayfile`)
- You need sqlsim's exact CLI and low-level client measurements

### Test Suite Comparison

sqlsim's suites are larger because they include native ODBC behavior, prepared statements, replay, and other sqlsim-only features. sqlpysim's suites cover its supported workflows, including CLI validation, authentication, concurrency, workload files, live progress, query statistics, shared JSON schema fields, and text-summary parity. For current inventories, run either tool's Bash suite with `--list-tests`.

[↑ Back to Table of Contents](#table-of-contents)

## Troubleshooting

### Connection Issues

**SSL Certificate Errors:**
```
Error: SSL certificate verify failed
```
**Solution:** Use `-C` to trust self-signed certificates (common for localhost):
```bash
# Set once without echo: read -rs -p 'SQL password: ' SQL_PASSWORD; echo
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1"
```

**Connection Refused:**
```
Error: Connection refused
```
**Solutions:**
1. Verify SQL Server is running
2. Check server name and port
3. Verify firewall allows connections

**Test connectivity:**
```bash
# Linux/macOS
nc -zv localhost 1433
# or
telnet localhost 1433

# Windows PowerShell
Test-NetConnection -ComputerName localhost -Port 1433
```

**Authentication Failed:**
```
Error: Login failed for user
```
**Solutions:**
1. Verify credentials are correct
2. For Windows Auth (Windows only), ensure you have permissions
3. For Azure, verify your Entra account has database access
4. For Managed Identity, ensure the identity is configured in the database

### Platform-Specific Issues

**Linux: Windows Authentication fails without Kerberos credentials:**
```
Thread 0: Connection failed - Driver Error: General error; DDBC Error: [Microsoft]SSPI
Provider: No credentials were supplied, or the credentials were unavailable or
inaccessible. No Kerberos credentials available (default cache: FILE:/tmp/krb5cc_1000)
```
**Solution:** On a domain-joined Linux host, obtain a ticket with `kinit` before running.
Otherwise use SQL Authentication or Token Authentication:
```bash
# SQL Authentication (password read from stdin)
read -rs -p "SQL password: " SQL_PASSWORD; echo
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT 1"

# Entra Interactive
python3 sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1"

# Token Authentication
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
printf '%s\n' "$TOKEN" | python3 sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"
```

**Linux: `python` command not found:**
```
bash: python: command not found
```
**Solution:** Use `python3` explicitly (standard on most Linux distributions):
```bash
python3 sqlpysim.py --help
```

Or create an alias:
```bash
# Add to ~/.bashrc or ~/.zshrc
alias python=python3
alias pip=pip3
```

**macOS: SSL/TLS errors with system Python:**
```
Error: SSL: CERTIFICATE_VERIFY_FAILED
```
**Solution:** Install certificates for Python:
```bash
# If using Homebrew Python
brew install python-tk@3.12

# Or run the certificate installer
/Applications/Python\ 3.12/Install\ Certificates.command
```

### Driver Issues

**Module Not Found:**
```
ModuleNotFoundError: No module named 'mssql_python'
```
**Solution:** Install the driver:
```bash
# Linux/macOS
pip3 install mssql-python

# Windows
pip install mssql-python

# If using virtual environment, ensure it's activated
source .venv/bin/activate  # Linux/macOS
.\.venv\Scripts\Activate.ps1  # Windows PowerShell
```

**Wrong Python Version:**
```
SyntaxError: invalid syntax
```
**Solution:** Verify Python 3.10+:
```bash
python3 --version
```

**Virtual Environment Not Activated:**
```
ModuleNotFoundError: No module named 'mssql_python'
```
**Solution:** Activate your virtual environment:
```bash
# Linux/macOS
source .venv/bin/activate

# Windows PowerShell
.\.venv\Scripts\Activate.ps1

# Windows Command Prompt
.\.venv\Scripts\activate.bat
```

### Performance Issues

**Slow Performance:**
1. Check network latency to the server
2. Ensure client has sufficient resources
3. Use `-q` to suppress output
4. Reduce thread count if client is bottleneck

**High Memory Usage:**
1. Reduce thread count (`-n`)
2. Reduce iterations (`-r`)
3. Use queries that return fewer rows

### Azure SQL Issues

**Firewall Blocked:**
```
Error: Cannot connect to server
```
**Solution:** Add your IP to Azure SQL firewall rules in Azure Portal

**Database Not Found:**
```
Error: Cannot open database
```
**Solution:** Always specify `-d <database>` for Azure SQL Database

**Token Expired:**
```
Error: Token has expired
```
**Solution:** Acquire a fresh token:

**Bash (Linux/macOS):**
```bash
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
```

**PowerShell (Windows):**
```powershell
$token = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
```

### SQL Server in Docker (Linux/macOS)

**Connect to SQL Server running in Docker:**
```bash
# Start SQL Server container
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=YourStrong@Passw0rd" \
    -p 1433:1433 --name sqlserver \
    -d mcr.microsoft.com/mssql/server:2022-latest

# Wait for SQL Server to start (about 30 seconds)
sleep 30

# Test connection with sqlpysim
printf '%s\n' 'YourStrong@Passw0rd' | python3 sqlpysim.py -S localhost -U sa -P - -C -Q "SELECT @@VERSION"
```

**Docker host.docker.internal (macOS/Windows Docker Desktop):**
```bash
# From inside another container, use host.docker.internal
# Set once without echo: read -rs -p 'SQL password: ' SQL_PASSWORD; echo
printf '%s\n' "$SQL_PASSWORD" | python3 sqlpysim.py -S host.docker.internal -U sa -P - -C -Q "SELECT 1"
```

[↑ Back to Table of Contents](#table-of-contents)

## Using sqlpysim with a Coding Agent

The sqlpysim release package ships with two files that let coding agents
(GitHub Copilot, Claude Code, Cursor, Aider, Codex CLI, etc.) automatically
discover and correctly invoke sqlpysim:

| File (in release ZIP) | Picked up by |
|-----------------------|--------------|
| `sqlpysim/AGENTS.md` | Most agent CLIs that read scoped `AGENTS.md` files |
| `.github/skills/sqlpysim/SKILL.md` | VS Code GitHub Copilot skill system |

The archive also includes `sqlpysim/LICENSE` with the MIT license.

Extract the ZIP at your project root. It creates `sqlpysim/` for the tool and
`.github/skills/sqlpysim/` for the skill. No copy step or manual reference is
required.

### Example agent prompts

- *"Run `SELECT @@VERSION` against my local SQL Server."*
  → `python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"`
- *"Stress test my Azure SQL database with 10 concurrent users."*
  → `python .\sqlpysim\sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1" -n 10 -r 100 -q`
- *"Generate JSON metrics for this workload."*
  → `python .\sqlpysim\sqlpysim.py -S localhost -E -C -i workload.sql -n 5 -r 50 -json -o results.json`

Core query commands follow the same shape as `sqlsim.exe`, but advanced flags,
validation rules, and JSON fields differ. Use the packaged sqlpysim skill and
this manual rather than translating every sqlsim command mechanically.

[↑ Back to Table of Contents](#table-of-contents)

## Getting Help

### View Help

```powershell
# Any of these show help:
python sqlpysim.py
python sqlpysim.py -h
python sqlpysim.py -?
python sqlpysim.py --help
```

### View Version

```powershell
python sqlpysim.py --version
```

[↑ Back to Table of Contents](#table-of-contents)

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

[↑ Back to Table of Contents](#table-of-contents)
