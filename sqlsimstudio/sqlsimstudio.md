# sqlsim Studio v1.0.0

User Manual for sqlsim Studio.

## Table of Contents
- [Overview](#overview)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Command-Line Options](#command-line-options)
- [The Studio Interface](#the-studio-interface)
- [Step 1 - Connection](#step-1---connection)
- [Authentication](#authentication)
- [Testing a Connection](#testing-a-connection)
- [Step 2 - Workload](#step-2---workload)
- [Step 3 - Execution](#step-3---execution)
- [Command Preview](#command-preview)
- [Monitoring a Run](#monitoring-a-run)
- [Results](#results)
- [Comparing Runs](#comparing-runs)
- [Saving and Loading Configurations](#saving-and-loading-configurations)
- [Execution Log](#execution-log)
- [App Settings](#app-settings)
- [Choosing Between sqlsim and sqlpysim](#choosing-between-sqlsim-and-sqlpysim)
- [Security Model](#security-model)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Getting Help](#getting-help)

## Overview

sqlsim Studio is a local browser interface for configuring, running, monitoring,
and comparing sqlsimtools workloads. It is a self-contained desktop application,
not a remote service: the packaged executable starts a web server bound only to
loopback, opens your default browser, and runs workloads as child processes
using the packaged `sqlsim` binary or an optional `sqlpysim` Python install.

**Important:** sqlsim Studio drives the same workload engines as the `sqlsim`
command line and is subject to the same guidance. It is a **testing and
workload simulation tool** for development, test, and performance evaluation
environments. It is **not intended for use against production systems**. High
connection counts can generate significant load that affects availability and
reliability. Always target dedicated test environments.

**Preview status:** Windows x64 is Public Preview. Ubuntu x64, Windows ARM64,
and macOS ARM64 are Private Preview for invited testers while platform
validation and packaging are completed.

**Key capabilities:**

- Four workload modes: single query, SQL script file, mixed workload, and XEvent replay
- Two execution engines: native `sqlsim` (ODBC) and `sqlpysim` (`mssql-python`)
- Live throughput and per-query statistics, or maximum-performance runs with final results only
- Console mode for viewing actual result rows
- Bounded in-session run history with guarded A/B comparison of session runs and saved result files
- Optional per-query statistics from runtime messages or Query Store deltas
- Connection testing against the exact settings a run will use
- Versioned JSON configuration save and load, with secrets excluded
- Light, dark, system, and six color themes

**How this tool was built:**
100% of the code, scripts, and documentation for sqlsim Studio was developed with
GitHub Copilot in Visual Studio Code using various AI models, but 100% orchestrated by Bob
Ward.

## Installation

1. Download `sqlsimtools-<version>-win-x64.zip` from the GitHub Release. It
   contains sqlsim Studio together with the complete sqlsim and sqlpysim
   packages.
2. Extract it to a folder you control, for example `C:\Tools\sqlsimtools`.
3. Run `sqlsimstudio\sqlsimstudio.exe`.

There is no installer and no separate runtime to install. Studio is
self-contained.

**Package layout:**

| Path | Purpose |
| --- | --- |
| `README.md` | Where to start with each tool |
| `sqlsimstudio/sqlsimstudio.exe` | The Studio application |
| `sqlsimstudio/sqlsimstudio.md` | This manual |
| `sqlsimstudio/sqlsimstudio.html` | This manual as a self-contained HTML page |
| `sqlsimstudio/CONFIGURATION.md` | Saved-configuration JSON contract |
| `sqlsimstudio/examples/` | Any-database and AdventureWorksLT queries, scripts, workloads, and Replay captures; live-monitor SQL; and the workload converter. See `examples/README.md` |
| `sqlsimstudio/sqlsimstudio-cleanup.ps1` | Stops orphaned engine processes and removes stale run directories |
| `sqlsimstudio/LICENSE`, `sqlsimstudio/THIRD-PARTY-NOTICES.md` | License and third-party attributions |
| `sqlsim/` | The complete sqlsim Windows x64 package: `x64/sqlsim.exe`, which Studio runs, plus its manual, examples, HTML report scripts, Compare result examples, and Replay tools |
| `sqlpysim/` | The complete sqlpysim package: `sqlpysim.py`, which Studio runs with Python, plus `requirements.txt`, its manual, and examples |
| `.github/` | Agent skills for Studio, sqlsim, and sqlpysim, and the Workload Builder agent |

The `sqlsim/` and `sqlpysim/` folders are identical to the separate sqlsim and
sqlpysim downloads, so the command-line tools, HTML reports, and Replay
conversion scripts are all beside Studio. Studio runs the engines from those
folders rather than carrying its own copies.

**Prerequisites:**

- **ODBC Driver 18 for SQL Server.** Required by the `sqlsim` engine. Studio
  cannot run workloads without it.
- **A supported browser.** Current stable Microsoft Edge or Google Chrome on
  Windows; Edge, Chrome, or Firefox on Linux; Safari, Edge, Chrome, or Firefox
  on macOS. Internet Explorer and legacy embedded webviews are not supported.
  Only Edge and Chrome on Windows x64 are tested; Linux and macOS are Private
  Preview and their browsers are untested. See Tested browsers in README.md.
- **Python 3.10 or later** *(optional)*. Only required to use the `sqlpysim`
  engine. See [Enabling sqlpysim](#enabling-sqlpysim).

### Enabling sqlpysim

Create a Python environment named `.venv` in the sqlsimtools folder and install
the sqlpysim dependencies:

```powershell
cd C:\Tools\sqlsimtools
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\sqlpysim\requirements.txt
```

The same environment runs sqlpysim from the command line. Refresh Studio after
installing. Studio chooses Python from `SQLSIM_STUDIO_PYTHON_PATH`, then `.venv`
beside `sqlsimstudio.exe`, then `.venv` in the sqlsimtools folder, then `python`
on `PATH`. Double-clicking Studio does not activate a virtual environment you
created somewhere else; use one of those `.venv` locations or set
`SQLSIM_STUDIO_PYTHON_PATH`.

The **Execution engine** list reports **Python not found** or **mssql-python
not installed** when sqlpysim cannot run.

### Disk and memory use

The sqlsimtools Windows x64 package is about 61 MB to download and 142 MB
extracted. Nearly all of that is Studio: the bundled .NET runtime inside
`sqlsimstudio.exe` (about 104 MB) and the ICU globalization libraries (about
35 MB). If you only need the command-line tools, the `sqlsim` and `sqlpysim`
packages are each under 1 MB to download and do not include Studio.

Studio runs each workload in a separate engine process, so memory is split
between Studio and the engine. Measured peaks on Windows x64 against a local
SQL Server:

| Scenario | Studio | Engine process | Total |
| --- | --- | --- | --- |
| Idle, signed in | 58 MB | — | 58 MB |
| sqlsim, 8 connections, Live progress and runtime statistics | 74 MB | 19 MB | ~95 MB |
| sqlsim, 100 connections, Live progress and runtime statistics | 73 MB | 42 MB | ~115 MB |
| sqlsim, 100 connections, Final results | 72 MB | 42 MB | ~115 MB |
| sqlpysim, 8 connections, Live progress and runtime statistics | 72 MB | 51 MB (Python) | ~125 MB |

Values are working-set memory. Connection count mainly grows the engine
process, by roughly 0.25 MB per connection for sqlsim; Studio itself stays
nearly flat and returns to about 72 MB after runs finish. Studio keeps the
current session's runs for [Compare](#comparing-runs), up to 50 runs. The
browser tab that displays Studio uses additional memory that is not included
here. Results vary with the workload, result-set sizes, and query statistics
collected.

## Getting Started

Run `sqlsimstudio\sqlsimstudio.exe`. Studio starts on a random loopback port and opens your
default browser to a one-time bootstrap address. No console window appears:
Studio's interface is the browser. When it is launched from a terminal it still
reports its address there:

```text
SQLSIM_STUDIO_URL=http://127.0.0.1:62967
```

The bootstrap URL contains a single-use 256-bit token that establishes an
authenticated session cookie. Once consumed it cannot be reused, but Studio
immediately writes a replacement into the session file, so there is always
exactly one unused token available while it runs.

**To stop Studio, use the power button in the top right.** It confirms first,
warning you if a workload is still running, then stops the workload, deletes
the private run directory, and exits. This is the only deliberate exit: Studio
has no window of its own and no usable Ctrl+C, because the binary is a GUI
subsystem process. Launched by double click there is no console at all;
launched from a terminal the prompt returns immediately, so Studio never holds
the foreground.

**Closing the browser does not stop Studio.** A workload outlives the page that
started it, which is what you want from a load test: a mis-click on a tab
should not abandon a run halfway through. If a workload is running when you
close the tab, the browser asks you to confirm first — its wording is generic
and cannot be changed, so the Monitor also carries a note explaining what is
about to happen. To get the interface back, open the URL in the session file:

```text
%TEMP%\sqlsimstudio-session-<user>.url
```

On macOS the file is in your private temporary directory (`$TMPDIR`). On
Linux, where `/tmp` is shared with other users, it is
`~/.local/share/sqlsimstudio/session.url` in a directory only you can read,
and private run files are under `~/.local/share/sqlsimstudio/runs`.

Studio does not watch the browser at all. Earlier versions inferred a closed
browser from a page that had gone quiet, and every version of that guess was
wrong in the same way: a backgrounded tab, a tab frozen by the browser, and a
sleeping laptop all look identical to a closed one, so Studio would stop a
session that was still in use.

If Studio is killed rather than shut down, the engine process survives and
keeps running the workload against your database. Collect it from the
sqlsimtools folder with:

```powershell
.\sqlsimstudio\sqlsimstudio-cleanup.ps1 -WhatIf   # report only
.\sqlsimstudio\sqlsimstudio-cleanup.ps1           # stop orphans, remove stale run directories
```

**Your first run:**

1. Enter a **Database**. It is required; there is no default.
2. Leave **Server** as `localhost`, or enter your target.
3. Leave **Authentication** as Windows / Kerberos integrated for a local server.
4. Click **Test connection** and confirm the server details come back.
5. Select the **Query** workload mode.
6. Accept the default query and load shape, or edit them.
7. Click **Run workload**.

Studio switches to the Monitor view automatically, then to Results when the run
completes.

## Command-Line Options

```text
Usage: sqlsimstudio [--no-open --bootstrap-file <path>] [--port <port>]
```

| Option | Description |
| --- | --- |
| `--port <port>` | Bind to a specific loopback port instead of a random one. |
| `--no-open` | Do not launch a browser. Requires `--bootstrap-file`. |
| `--bootstrap-file <path>` | Write the one-time bootstrap URL to a file instead of a log. Studio deletes the file after successful bootstrap. |
| `-h`, `--help` | Show usage and exit. |

`--no-open` exists for automated testing. The bootstrap URL is written to a file
rather than standard output so the single-use token is not captured in logs or
terminal scrollback.

## The Studio Interface

Studio has four views, selected from the tabs in the title bar:

| View | Purpose |
| --- | --- |
| **Configure** | Build the run: connection, workload, and execution settings |
| **Monitor** | Watch an active run: throughput, progress, events, and log |
| **Results** | Inspect the completed run's metrics and configuration |
| **Compare** | A/B two completed runs from this session or saved JSON result files |

The Configure view is organized as three numbered panels — Connection, Workload,
and Execution — with a persistent command preview and **Run workload** button at
the bottom. Required fields are marked with a red asterisk.

The status badge in the header shows the running Studio version, for example
**Studio ready · v1.0.0**. The Execution engine list shows the version reported
by each packaged engine, such as **sqlsim 1.0.0 · Native ODBC**. If an engine is
missing, the list says **not found**.

## Step 1 - Connection

| Field | Default | Notes |
| --- | --- | --- |
| Execution engine | `sqlsim` | See [Choosing Between sqlsim and sqlpysim](#choosing-between-sqlsim-and-sqlpysim) |
| Server | `localhost` | Host, `host,port`, or `host\instance` |
| Database | *(empty, required)* | Studio always sends `-d` |
| Authentication | Windows / Kerberos integrated | See [Authentication](#authentication) |

### Connection options

Expand **Connection options** for settings that map directly to `sqlsim` flags:

| Control | Flag | Default | Notes |
| --- | --- | --- | --- |
| Login timeout | `-l` | 15 sec | 0 to 86,400. 0 waits indefinitely. |
| Application name | `-app` | `sqlsimstudio` | Appears as `program_name` in `sys.dm_exec_sessions` |
| Encryption | `-N` | Mandatory | Mandatory, Strict (TDS 8.0), Optional, or Driver default |
| Retry count | `-retry` | 0 | 0 to 255 connection retries |
| Trust server certificate | `-C` | Checked | Skips certificate validation |
| Read-only application intent | `-R` | Off | Routes to a readable secondary |

Advanced execution options add:

| Control | Flag | Notes |
| --- | --- | --- |
| Multi-subnet failover | `-M` | For Always On availability groups |
| Certificate hostname | `-F` | Expected name when it differs from the server name |

**About the encryption defaults.** Studio defaults to Mandatory encryption with
Trust server certificate checked, matching SQL Server Management Studio. This is
appropriate for test servers using self-signed certificates. For a server with a
certificate issued by a trusted authority, clear **Trust server certificate** so
the certificate is actually validated. Choose **Strict** for TDS 8.0.

Note that the `sqlsim` command line behaves differently when invoked directly:
if neither `-N` nor `-C` is supplied it silently uses
`TrustServerCertificate=Yes`. Studio always sends an explicit encryption choice,
so what you see in the command preview is what you get.

## Authentication

Six modes are available:

| Mode | Flags | Credentials |
| --- | --- | --- |
| Windows / Kerberos integrated | `-E` | None |
| Microsoft Entra token | `-T` | Access token |
| Microsoft Entra interactive | `-A ActiveDirectoryInteractive` | None. Windows only |
| Managed identity | `-A ActiveDirectoryMsi` | Optional user-assigned client ID |
| Service principal | `-A ActiveDirectoryServicePrincipal` | Client ID and secret |
| SQL authentication | `-U` / `-P` | Username and password |

Studio shows only the fields a mode actually uses, and clears them when you
switch to a mode that does not. It enforces the same credential rules the
engines do, so an unusable combination is refused before a process starts rather
than failing partway into a run.

### Windows / Kerberos integrated

Emits `-E`. No credential fields. The default for local SQL Server.

### Microsoft Entra token

Emits `-T` and passes the token to the engine over standard input. Requires an
access token for the SQL Server audience. Acquire one with the Azure CLI:

```powershell
az login
az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
```

Paste the value into **Password / token**. This is the supported path for Azure
SQL Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.
It is also the recommended path for repeated runs because it avoids an
interactive sign-in prompt each time.

Tokens are short-lived, typically about an hour. If a run that previously
worked starts failing authentication, acquire a new token.

### SQL authentication

Emits `-U` with the username and `-P` with the password over standard input.

### Microsoft Entra interactive

Emits `-A ActiveDirectoryInteractive` and opens a browser sign-in prompt. Takes
no credential fields.

**Windows only.** ODBC Driver 18 implements interactive sign-in on Windows and
nowhere else, so Studio disables this option when running on Linux or macOS and
labels it accordingly. Use an access token or a managed identity there.

> **Do not use interactive sign-in for a multi-connection workload.** Every
> connection performs its own sign-in round trip. Measured against Azure SQL, a
> single interactive connection took **about 12 seconds** to establish, against
> roughly 1 second for the same target using an access token. At `-n 100` that
> is 100 separate sign-in attempts, and the connection time dominates whatever
> you were trying to measure. Entra may also throttle or block the repeated
> requests, and you may be prompted more than once.
>
> Use interactive sign-in for **Test connection** or a single-connection check.
> For any real workload, use **Microsoft Entra token**: acquire it once, and
> every connection reuses it.

### Managed identity

Emits `-A ActiveDirectoryMsi`. No secret is ever accepted; Studio rejects the
request if one is present, matching the engine.

Leave **User-assigned client ID** empty to use the system-assigned identity, or
enter an identifier to select a user-assigned one. Azure VMs expect the
identity's **object ID**; App Service expects its **client ID**.

**Two requirements, and both are easy to miss.**

**1. Studio must be running on an Azure resource that has a managed identity.**
The driver retrieves the token from the Azure Instance Metadata Service at
`169.254.169.254`, a link-local address that only exists inside Azure compute.
A developer workstation has nothing listening there, so this mode cannot work
locally no matter what permissions you hold. Run Studio on an Azure VM, VM Scale
Set, App Service, Container App, Azure Functions host, or AKS node with an
identity assigned. On a workstation, use **Microsoft Entra token** instead.

**2. The identity must exist as a principal inside the target database.**
Microsoft Entra authentication for Azure SQL does not integrate with Azure RBAC.
Assigning the identity a role such as *SQL DB Contributor* grants management
permissions, not the ability to connect and query. Connect as a Microsoft Entra
admin and create the principal explicitly:

```sql
-- System-assigned identity: the name is the Azure resource name.
CREATE USER [my-vm-name] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [my-vm-name];

-- User-assigned identity: the name is the identity's name.
CREATE USER [my-managed-identity] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [my-managed-identity];
```

A new database user receives `CONNECT` by default. Grant anything beyond that
explicitly, and prefer adding the identity to a role over granting directly.

Azure SQL requires principal names to be unique, while Microsoft Entra allows
duplicate display names. If creation fails for that reason, disambiguate with
the object ID:

```sql
CREATE USER [my-identity] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = 'aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb';
```

Verify the principal exists before running a workload:

```sql
SELECT name, type_desc FROM sys.database_principals WHERE type_desc = 'EXTERNAL_USER';
```

See [Configure and manage Microsoft Entra authentication with Azure SQL](https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-configure)
for the full procedure.

### Service principal

Emits `-A ActiveDirectoryServicePrincipal` with `-U` for the application
(client) ID and `-P` for the client secret over standard input. Both are
required.

Not supported by `sqlpysim`, whose `-A` handles interactive and managed identity
only. Studio disables the option when the Python engine is selected.

### Credential handling

Secrets you type are held in server memory only for the duration of a run and
are passed to the child process through redirected standard input. They are
never placed on a command line, written to a log, stored in browser storage, or
included in a saved configuration. Loading a configuration clears the secret
field.

## Testing a Connection

**Test connection** runs a single bounded probe using the exact settings the
workload will use — same engine, encryption, trust, timeouts, application name,
and authentication. It does not create a history entry and does not affect a
completed run's results.

**Run workload** performs the same bounded probe before opening Monitor or
starting the workload. If the server, database, authentication, or connection
options are invalid, Studio remains on Configure and shows the specific
connection error. This prevents a misspelled database from creating a failed
run that is only diagnosed later in Results.

On success Studio reports the live server details:

```text
Connected in 71 ms - SQL Server 17.0.4085.5 · Enterprise Developer Edition (64-bit) · database tempdb · driver 18.06.0001
```

On failure it reports the driver's own error text, which is usually specific
enough to identify the cause — a bad password, an unreachable port, or a
certificate that failed validation.

The test is bounded by your login timeout plus 20 seconds, and cannot run while
a workload is running.

## Step 2 - Workload

Choose one of four modes. The default is **Workload**.

### Query

Runs a single ad-hoc statement or batch from the text area.

| Control | Flag | Default |
| --- | --- | --- |
| SQL query | `-Q` | `SELECT @@VERSION;` |
| Connections | `-n` | 10 |
| Iterations per connection | `-r` | 100 |

Total executions is connections times iterations, shown live as you type.

### SQL file

Runs a `.sql` script. Browse or drop a file; the maximum size is 1 MB.

Studio counts `GO`-separated batches in the file and multiplies them into the
total execution count. The file is staged into a private temporary directory for
the run and deleted afterward — the browser never sends a path, only content.

| Control | Flag | Default |
| --- | --- | --- |
| SQL script | `-i` | *(required)* |
| Connections | `-n` | 10 |
| Iterations per connection | `-r` | 100 |

### Workload

Runs a mixed workload built from multiple scripts, each with independent
settings. Studio generates the workload JSON on the server and passes it with
`-workload`.

| Per-group setting | Range |
| --- | --- |
| Connections | 1 to 10,000 |
| Iterations per connection | 1 or more |
| Think time | 0 to 86,400,000 ms |

Limits: 1 to 20 groups, each script 1 MB or smaller, 10 MB combined.

Mixed workload runs on either engine.

**Import JSON** loads an existing sqlsim workload definition — the same file
format `sqlsim -workload` accepts — and converts its groups into Studio rows.
Groups defining inline `queries` are imported with their SQL, connection count,
iteration count, and think time.

Two things to know about importing:

- **`//` and `/* */` comments are tolerated.** The sqlsim workload parser accepts
  them and the shipped examples use them, so Studio strips comments before
  parsing rather than rejecting the file.
- **Groups that reference an external `file` are skipped.** The browser cannot
  read a path from inside a JSON document. Studio reports how many groups were
  skipped; add those scripts with **Add SQL script**, or convert the workload
  first with `examples/convert-workload-for-studio.ps1`, which inlines each
  referenced file as `queries`.

### Replay

Replays a converted sqlsim XEvent capture. Studio does not accept raw `.xel`
files: convert the capture with sqlsim's `replay\convert-xel.ps1` first. The
resulting `.xml` file must be 100 MB or smaller.

To try Replay without capturing anything, load
`examples/any-database/replay/catalog-replay.xml`, which runs against any
database, or `examples/adventureworkslt/replay/portable-replay.xml` against
AdventureWorksLT. Both are genuine captures of three concurrent sessions.

| Mode | Behavior | Connections |
| --- | --- | --- |
| **Session order (fast)** | One worker per captured session; runs each session as fast as possible while preserving its event order | Determined by the capture |
| **Load stress** | Recognized events flattened and distributed for maximum load; session boundaries are not preserved | Set with `-n` |

**Replay passes** maps to `-r`. Stress connections is only enabled — and `-n`
only emitted — in stress mode. Selecting Replay defaults telemetry to **Final
results only** because the canonical final JSON contains the original capture
aggregates, Replay outcomes, and per-query comparison inputs. You can select
**Live progress** afterward when execution monitoring is more important than
the original-versus-Replay comparison.

When a file is selected, Studio verifies the XML shape and shows captured,
recognized, and skipped event counts plus the captured SPID and database
context. The bounded capture preview lists SQL text, event type, captured SPID,
database, mode-specific inclusion decision, and original duration when it was
captured. Studio parses the complete file and computes the summary from every
event, but renders at most the first 100 preview rows. When more events exist,
the preview reports how many additional events are not displayed.

This Studio release supports Replay files containing zero or one captured
database. Choose the destination server and database in Configure. When no
`database_name` action was captured, Replay runs in that selected database.
When one database was captured, Studio redirects that captured context to the
selected database before staging the private Replay XML. This allows a trace
captured from one database to run against a differently named test copy without
editing the converted file.

Studio rejects a Replay file containing more than one distinct captured
database during preflight. Source-to-target mapping for multi-database captures
is deferred to a future release.

Studio validates connectivity to the selected target, not schema or data
equivalence. The user must ensure the target has synchronized schema and data
before interpreting the performance comparison. Server resources,
configuration, statistics, indexes, cache state, concurrency, and Query Store
activity can still make results differ.

Replay requires the `sqlsim` engine. It reproduces supported statements and
their order within captured sessions, not the original application's complete
runtime behavior. Event timestamps determine ordering but do not reproduce
timing gaps. Transactions, think time, connection state, and session-level
`SET` options are not captured or restored.

Replay XML can contain SQL text, object names, parameter values, and literal
customer data. Review it before loading, saving in a Studio configuration, or
sharing it.

Enable **Collect per-query performance** to see the replayed SQL and compare it
with original XEvent metrics. Runtime query statistics show a bounded list of
SQL Server SPIDs for each query in Query, SQL file, Workload, and Replay runs.
Results also show:

- original and Replay outcome counts;
- original and Replay execution counts;
- original and Replay average elapsed time;
- elapsed-time and logical-read deltas;
- Replay failures; and
- the full Runtime query statistics table with SPIDs, CPU, and I/O details.

The comparison is not limited to the 100-row preview. It aggregates the entire
capture into one row per unique exact SQL text. Repeated events contribute to
that row's execution and outcome counts and to its original metric averages.
Replay query statistics are aggregated by the same exact SQL text before the
two sides are matched; text variants remain separate rows. Original duration is
converted from XEvent microseconds to milliseconds; XEvent CPU time is already
milliseconds. Missing capture fields are shown as unavailable rather than
treated as zero. Load stress is labelled as a transformed workload because it
flattens sessions and can multiply execution counts.

Diagnostics enable `SET STATISTICS TIME/IO` and add overhead. Disable them when
measuring maximum Replay throughput. Deltas are descriptive: environment,
cache state, concurrency, and collection overhead can all affect the result.

## Step 3 - Execution

### What to use when

Client telemetry controls what Studio receives and displays while the workload
runs. Server statistics control how much per-query diagnostic work is collected.
Choose them independently based on the goal:

| Goal | Client telemetry | Server statistics |
| --- | --- | --- |
| Watch throughput and execution progress | **Live progress** | **None** |
| Diagnose individual slow or expensive queries while the run is active | **Live progress** | **Runtime messages** |
| Measure maximum throughput with minimum collection overhead | **Final results only** | **None** |
| Compare two clean benchmark runs | **Final results only** | **None** |
| Analyze aggregate server-side query performance on a quiet test database | **Final results only** | **Query Store** |
| See returned rows or troubleshoot query output | **Console output** | **None** |

Simple rules:

- Start with **Live progress + None** while developing a workload.
- Add **Runtime messages** when you need per-query elapsed time, CPU, reads,
  execution counts, and failures.
- Switch to **Final results only + None** for serious throughput measurements.
- Use **Query Store** only on a quiet test database; its aggregate deltas can
  include matching work from other sessions.
- Use **Console output** for correctness and troubleshooting, not benchmarking.
- Keep telemetry and statistics settings identical when comparing runs.

### Client telemetry

This is the most consequential execution choice. It determines what Studio can
show you and what it costs to collect.

| Mode | Flags | Monitor view | Results |
| --- | --- | --- | --- |
| **Live progress** | `-stream-json -json -o -q` | Throughput chart, counters, event stream, and live per-query statistics when runtime statistics are enabled | Full canonical metrics after completion |
| **Final results only** | `-json -o -q` | Process state and elapsed time only | Full metrics |
| **Console output** | *(neither)* | Process state and elapsed time only | Result rows, no canonical metrics |

Choose **Live progress** to watch a run. Choose **Final results only** for
maximum throughput when client-side streaming overhead would distort the
measurement. Choose **Console output** when you want to see the rows a query
actually returned.

For both engines, Live progress keeps NDJSON events on stdout while `-json -o`
writes the canonical final result to Studio's private run directory. Exports,
run history, and supported comparisons therefore remain available after a live
run.

**Suppress result rows** (`-q`) is forced on and locked for Live progress and
Final results, because structured JSON telemetry requires it. In Console mode it
becomes editable; leave it off to display rows from the first execution.

Console output is displayed up to a 256 KiB limit, after which it is truncated
with a notice. Console runs do not produce the canonical metrics required for
A/B comparison.

### Execution toggles

| Toggle | Flag | Notes |
| --- | --- | --- |
| Prepared statements | `-p` | Prepare once per connection. Accepted but ignored by `sqlpysim`. |
| Reconnect each iteration | `-reconnect` | Open a new connection per cycle |
| Connection pooling | `-usepool` | Requires reconnect. Supported by both engines. |
| Stop on first error | `-stoponerror` | Cancels all active workers |

Connection pooling stays disabled until Reconnect each iteration is enabled,
because pooling only has meaning when connections are actually recycled.

### Query statistics

| Source | Flag | Notes |
| --- | --- | --- |
| **None** | *(none)* | Default. Live monitoring is still available. |
| **Runtime messages** | `-querystats` | Per-execution server CPU and I/O via `SET STATISTICS TIME/IO`. Requires `sqlsim`. |
| **Query Store** | *(collected by Studio)* | Before/after aggregate deltas |

Query Store collection is performed by Studio itself using two read-only
snapshots taken around the run. It requires Query Store to be in read-write
state and the performance-state permission on the target database. Because the
deltas are aggregates, they can include matching queries executed by other
sessions during the run — Studio warns about this in the log.
When Query Store is selected, the Run preflight verifies those requirements and
keeps the user on Configure with the database error if validation fails.

### Query timeout

Maps to `-t`. Default 30 seconds; 0 to 86,400. Zero waits indefinitely.

## Command Preview

The bar above **Run workload** shows the exact command Studio will execute,
updating as you change settings:

```text
sqlsim -S localhost -d tempdb -E -Q "SELECT @@VERSION;" -n 10 -r 100 -l 15 -app sqlsimstudio -N m -C -t 30 -stream-json -json -o studio-results.json -q
```

Private staging paths appear as `<private-temp>` and secrets never appear at
all. The preview is a reliable way to learn the command-line equivalent of a
Studio configuration, and to confirm a setting took effect before committing to
a long run.

## Monitoring a Run

When a run starts, Studio switches to the Monitor view.

With **Live progress** telemetry you get:

- **Live throughput** — executions per second over a rolling 20-second window
- **Executions**, **Connections**, **Errors**, and **Failed connections** counters
- **Workload progress** — aggregate percentage complete
- **Live query statistics** — shown when **Collect per-query performance** uses
  runtime messages. Studio reads the engine's once-per-second query-statistics
  snapshot and shows totals, average elapsed time split into server and client
  time, average server CPU, average logical reads, execution share, and the
  same per-query table used in Results. Charts show up to 10 queries with the
  most total elapsed time; the table lists every query.
- **Event stream** — structured events received from the engine

Query Store statistics are collected around the run, so they appear in Results
after completion rather than in the Monitor view.

With Final results or Console telemetry, Studio tracks process state and elapsed
time only, and explains that in place of the chart. This is not a failure; it is
the cost of not streaming.

**Stop run** cancels the workload and terminates the process tree. A stopped run
is recorded as stopped rather than completed.

## Results

The Results view summarizes the completed run:

- **Throughput**, **Total duration**, **Executions**, **Query time**,
  **Connections**, and **Errors**
- **Execution summary** — client-observed time split across query execution,
  connection, and other
- **Run configuration** — workload shape, connection count, statistics source,
  driver, SQL Server version and edition, and engine, for reproducibility.
  Live progress runs populate driver and server details after the first
  successful connection.
- **Console output** — shown for console-mode runs
- **Query statistics** — shown when runtime or Query Store statistics were
  collected. Runtime statistics include the same totals and charts as Monitor,
  followed by the full per-query table. If you stop a Live progress run, Results
  uses the last query-statistics snapshot and labels it as partial.

### Exporting results

**Export JSON** downloads the run's canonical results file — the same structure
`sqlsim -json` produces, and the artifact to keep for automation, archiving, or
regression tracking. Studio runs final-results workloads with `-json`, so the
exported file includes the server version and edition, ODBC driver version,
configuration, and timing totals. It omits the per-thread, per-iteration detail
that `-v` adds, which grows with run length.

Export requires a completed **Final results only** run. Console and live-progress
runs do not produce the canonical structure.

### Generating an HTML report

Studio does not render HTML reports itself. Export the results JSON, then run the
reporting script from the `sqlsim` folder of the sqlsimtools package:

```powershell
# from the sqlsimtools folder
.\sqlsim\examples\reports\execution-report.ps1 -JsonFile .\sqlsim-results-20260925-141530.json
```

The script writes `execution-report.html` and opens it in your browser.

The reporting scripts belong to sqlsim rather than Studio because they work on
any sqlsim results file, whether it came from Studio or the command line.
Keeping a single generator also means the CLI and Studio produce identical
reports rather than two implementations that drift apart.

## Comparing Runs

The Compare view checks whether a change improved or regressed performance. It
compares a baseline (A) with a candidate (B).

### Two ways to compare

| Source | Use it when | How long it is available |
| --- | --- | --- |
| **Runs from this Studio session** | You run a workload, make a change, and run it again | Until Studio exits; up to 50 completed runs |
| **Saved JSON results** | You want to keep results, compare across sessions, or compare command-line results | Import with **Import JSON** whenever needed |

You can compare two session runs, two saved results, or one of each.

### Compare runs from this session

1. In **Configure**, choose the workload and settings.
2. Click **Run workload**. When it completes, Studio adds it to Compare.
3. Make the change you want to test outside Studio, such as adding an index or
   changing a server setting.
4. Run the same Studio configuration again.
5. Open **Compare**, select the earlier run as **A · Baseline**, and select the
   later run as **B · Candidate**.

Studio keeps completed **Final results only** and **Live progress** runs.
Console output, stopped, failed, and connection-test runs are not available,
because they do not produce a complete final result.

Use the same telemetry setting for A and B. **Live progress** streams updates
while the workload runs, so it adds client-side work. Studio refuses to compare
a Live progress run with a Final results run. For the most accurate measurement,
use Final results only for both runs.

### Save and compare results later

Use **Export JSON** on Results to keep a run after Studio exits. Later, use
**Import JSON** in Compare to load it as Baseline or Candidate. You can also
import a final result written by `sqlsim` or `sqlpysim` with `-json -o <file>`.

### What can change between A and B

| Difference | Compare behavior |
| --- | --- |
| Index, server setting, statistics, hardware, or other change outside Studio | Allowed |
| SQL Server version or edition, ODBC driver, or engine version | Allowed and flagged as informational |
| Query or workload SQL | Refused |
| Server or database | Refused |
| Connections, iterations, or execution count | Refused |
| sqlsim or sqlpysim engine | Refused |
| Query statistics setting | Refused |
| Live progress or Final results telemetry | Refused |
| Connection options such as reconnect, pooling, encryption, or timeouts | Refused |

When Compare refuses a pair, it names the differing setting and does not show
performance deltas.

### Reading the comparison

Select a baseline (A) and candidate (B). Studio reports percentage deltas for
throughput, total duration, average execution time, average connection time, and
errors, with an explicit verdict of how many metrics improved, stayed the same,
or regressed. Changes within ±2% count as unchanged.

Studio and `comparison-report.ps1` use the same definitions:

- **Throughput** — executions divided by `execution_elapsed_seconds`, or total
  duration when the result does not record execution elapsed time
- **Total duration** — wall-clock time for the whole run, including connections
- **Executions** — total batches, or replayed events for Replay
- **Average execution** — total query execution time divided by executions
- **Average connection** — the engine's average connection time. It counts
  toward the verdict only when both runs use `-reconnect`; otherwise it is
  one-time setup cost and is shown as **not in verdict**.

**Per-query comparison** appears when both results include per-query statistics
from `-querystats`. Queries are matched by SQL text with whitespace normalized,
and each row shows executions, average elapsed time, average CPU, average
logical reads, and failures for A and B. Queries found in only one run are
labeled **Only in A** or **Only in B**.

**Configuration comparison** is the guardrail that matters. It lists the
target, workload checksum, load shape, statistics, telemetry, engine, driver,
and SQL Server details for A and B. A throughput difference between two runs
with different workloads or load shapes is not a result; this panel is what
stops you from reporting one. sqlsim and sqlpysim record SQL Server version and
edition in every JSON result.

### Importing saved results

Use **Import JSON** above Baseline or Candidate to load either:

- A final result written by `sqlsim` or `sqlpysim` with `-json -o <file>`, or by
  Studio's **Export JSON** button.
- A Studio **Export comparison** bundle. Studio loads its baseline and candidate
  together.

Imported files are parsed in the browser and are not uploaded to the Studio
server. They remain available until the page is reloaded or Studio exits; at
most 20 imported results are kept.

The sqlsimtools package includes a sample pair in `sqlsim/examples/results/`:
`index-baseline.json` and `index-candidate.json`. Import them as Baseline and
Candidate to see a comparable before-and-after index change.

When either side is imported, Studio compares the configuration recorded in the
result files: engine and mode, target, workload batches or Replay capture, load
shape, statistics setting, telemetry, and execution options such as
authentication, application name, encryption, timeouts, reconnect, pooling, and
prepared statements. File paths and verbose output are ignored. A plain result
file records runtime query statistics but not Studio Query Store collection, so
Studio treats Query Store as unavailable unless the file came from a Studio
comparison bundle.

Failed runs, connection tests, duration-mode results, live-progress streams, and
files that are not canonical final results are rejected.

Run history is bounded and held in memory for the current Studio session only.
It is discarded when Studio exits.

### Exporting a comparison

**Export comparison** downloads both runs and the computed analysis as a single
JSON file: each run's full canonical result, the percentage deltas, and the
configuration-match verdict.

Render it as an HTML report with the sqlsim comparison script:

```powershell
# from the sqlsimtools folder
.\sqlsim\examples\reports\comparison-report.ps1 -ComparisonFile .\sqlsim-comparison-20260925T141530.json
```

The same script also compares two ordinary result files directly, which does not
require Studio at all:

```powershell
.\sqlsim\examples\reports\comparison-report.ps1 -BaselineFile before.json -CandidateFile after.json
```

Use this script when you want an HTML report. To review saved results
interactively, import them into Compare instead.

The report repeats Studio's configuration guardrail and refuses to declare a
verdict when the two runs used different targets, engines, workloads, load
shapes, query-statistics settings, or execution options. Use
`-Threshold` to set the percentage treated as noise; it defaults to 2, which is
tight for short runs where normal variance is larger than the effect you are
measuring.

## Saving and Loading Configurations

**Save configuration** downloads the current mode and its settings as a
versioned JSON file. SQL script and replay content are embedded so the
configuration can be restored without reselecting files.

**Passwords and tokens are never included.** Loading any configuration clears
the current secret field, so you re-enter the credential deliberately.

Treat saved configurations as sensitive when their query or script text contains
environment-specific information.

See [CONFIGURATION.md](CONFIGURATION.md) for the version 1 JSON contract,
mode-specific source objects, validation limits, and examples.

## Execution Log

**View log** opens a drawer with sanitized, session-only log entries, filterable
by All, Errors, or Warnings. Credentials and tokens are never recorded.
Connection strings are sanitized before any entry is written.

Log entries are discarded when Studio closes.

## App Settings

The gear icon opens preferences. **Theme** offers Light, Dark, Use system
setting, and six color themes. Blue, Red & Blue, Green & Black, and Green & Gold
color the whole screen; Blue matches the Tomorrow Night Blue theme in VS Code.
Royal Blue and Green keep Light's white panels with a colored navigation rail
and accents; Green uses Microsoft Fabric's teal green. It does not change any
workload setting, and saved configuration files never include it.

Clicking OK saves the theme for your user account, so it applies every time
Studio starts, in any browser. Studio keeps it in `settings.json` under
`%LOCALAPPDATA%\sqlsimstudio` on Windows, `~/.local/share/sqlsimstudio` on
Linux, and `~/Library/Application Support/sqlsimstudio` on macOS. The file
holds only the theme name, never credentials. Delete it to return to Use system
setting. If the file is missing or unreadable, Studio starts normally with the
theme last used in that browser. Set `SQLSIMSTUDIO_SETTINGS_DIR` to keep the
file elsewhere; the test scripts do this so they never change your preference.

## Choosing Between sqlsim and sqlpysim

Studio can drive either engine. `sqlsim` is the default and the more capable.

| Capability | sqlsim | sqlpysim |
| --- | --- | --- |
| Query mode | Yes | Yes |
| SQL file mode | Yes | Yes |
| Mixed workload | Yes | Yes |
| Replay | Yes | No — deliberately deferred from sqlpysim v1.0 |
| Live progress telemetry | Yes | Yes |
| Final results / console | Yes | Yes |
| Runtime query statistics | Yes | Yes |
| Query Store statistics | Yes | Yes |
| Prepared statements | Yes | Accepted, ignored |
| Connection pooling | Yes | Yes, with reconnect mode |

Studio enforces these differences in the interface: selecting `sqlpysim`
disables the capabilities it does not support and switches away from an
incompatible mode rather than failing at run time.

Use `sqlpysim` when you want to measure `mssql-python` driver behavior or
compare it against native ODBC. Use `sqlsim` for everything else, particularly
for XEvent replay and maximum-throughput load testing where client overhead
matters.

`sqlpysim` requires Python and its dependencies to be installed; the package
ships the source, not a runtime.

## Security Model

Studio treats the local browser as untrusted. The protections are deliberate and
worth understanding:

- **Loopback only.** Kestrel binds to `127.0.0.1` on a random port. Studio is
  not reachable from the network.
- **One-time bootstrap.** A single-use 256-bit token establishes the session.
- **Session cookie.** `HttpOnly` and `SameSite=Strict`, so script cannot read it
  and cross-site requests cannot use it.
- **Host and Origin validation.** Unexpected `Host` headers are rejected, and
  unsafe methods require a matching `Origin`.
- **No CORS, no request logging.**
- **Unauthenticated requests receive 404,** including static assets, so the
  application's existence is not confirmed to an unauthenticated caller.
- **Secrets over standard input.** Never on a command line, in a URL, in browser
  storage, or in a saved configuration.
- **Private staging.** Script and replay content is written to a per-run private
  directory and deleted when the run completes.

The browser never connects to SQL Server directly. All database access happens
in the Studio process or its child workload processes.

## Known Limitations

Studio ships only controls that work. Unimplemented features are absent from the
interface rather than present and greyed out, so a visible button always does
something.

One option disables itself based on where Studio runs because the capability
genuinely is not available:

| Option | Unavailable when |
| --- | --- |
| Microsoft Entra interactive | Studio is running on Linux or macOS |

Planned for a future preview revision, currently absent from the interface:

| Area | Feature |
| --- | --- |
| Monitor | Copy events to the clipboard |
| Results | Run again, open a completed run's configuration |
| Execution log | Copy, export, and clear the log display |

The execution log itself works — severity filtering, entry counts, and entries
are all live. Only the clipboard, export, and clear actions are outstanding.

**Not limitations.** Several controls start disabled and enable themselves when
they become meaningful. These are working as intended:

| Control | Enables when |
| --- | --- |
| Stress connections | Replay mode is set to Stress |
| Connection pooling | Reconnect each iteration is enabled |
| Suppress result rows | Telemetry is set to Console output |
| Stop run | A workload is running |
| Baseline / Candidate | A final-result run exists in this session or a result file is imported |

**Run history is session-scoped.** It is held in memory, bounded, and discarded
when Studio exits. To compare runs across sessions, use **Export JSON** on each
run, then use **Import JSON** in Compare.

## Troubleshooting

**The browser did not open.**
Studio has no console window to read the address from, so restart it: the
bootstrap token is single-use and a fresh one is issued each time. To capture
the address instead, start Studio with
`--no-open --bootstrap-file <path>` and open the URL written to that file, or
launch it from a terminal, where it still prints `SQLSIM_STUDIO_URL`.

**Studio exited on its own.**
It should not. Studio runs until you shut it down from the interface or the
process is killed, and it does not watch the browser. If it exits while you
are still using it, that is a defect worth reporting: capture what you were
doing and whether a workload was running.

**A page says Studio is no longer running.**
That tab belongs to an instance that has exited. If Studio is still running,
reopen the interface from the URL in `%TEMP%\sqlsimstudio-session-<user>.url`,
which always holds an unused token. If it has gone, start Studio again and use
the tab it opens.

**"sqlsim is not installed where Studio can find it."**
The engine is missing from the extracted folder. Re-extract the full
sqlsimtools archive; Studio looks for `sqlsim\x64\sqlsim.exe` in the
sqlsimtools folder, one level above `sqlsimstudio.exe`.

**"sqlpysim is not installed where Studio can find it."**
`sqlpysim/sqlpysim.py` is missing from the extracted folder. Re-extract the full
archive.

**The engine list says Python not found or mssql-python not installed.**
Follow [Enabling sqlpysim](#enabling-sqlpysim), then refresh Studio. If Python
is installed elsewhere, set `SQLSIM_STUDIO_PYTHON_PATH` to that Python
executable before starting Studio.

**Connection fails with a certificate error.**
Either enable **Trust server certificate**, or set **Certificate hostname** to
the name on the certificate. Use Test connection to iterate quickly.

**Entra token authentication worked earlier and now fails.**
Access tokens expire in about an hour. Acquire a new one.

**Test connection reports success but a workload fails.**
The connection is fine; the problem is in the workload. Check the execution log,
and consider running once in Console output mode to see what the server actually
returned.

**The Monitor view shows no chart.**
Live progress telemetry is required for charting. Final results and Console
modes intentionally track only process state and elapsed time.

**Compare refuses two runs.**
Session runs must be completed Final results only or Live progress runs, and
both sides must use the same telemetry. Imported files must be canonical final
results with a fixed execution count. Check the configuration comparison panel
for an engine, workload, target, load-shape, statistics, telemetry, or
execution-option mismatch.

**A run is slower than the same command on the command line.**
Live progress telemetry adds client-side streaming work. Use Final results only
for measurement runs.

## Getting Help

- Configuration file contract: [CONFIGURATION.md](CONFIGURATION.md)
- `sqlsim` command-line manual: https://github.com/microsoft/sqlsimtools/blob/main/sqlsim/sqlsim.md
- Studio architecture and development notes: https://github.com/microsoft/sqlsimtools/blob/main/sqlsimstudio/README.md
- Issues and discussions: https://github.com/microsoft/sqlsimtools
