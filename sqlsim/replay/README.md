# Replay Mode

sqlsim can replay SQL Server Extended Events (XEvent) traces to simulate real-world workloads captured from production or test environments.

## Quick Start

```powershell
# 1. Capture a workload
sqlsim -S localhost -E -app sqlsim_admin -i replay\setup-test-capture.sql -q
sqlsim -S localhost -E -d master -Q "SELECT @@VERSION" -n 3 -q
sqlsim -S localhost -E -app sqlsim_admin -i replay\stop-test-capture.sql -q

# 2. Convert .xel to replay XML
.\replay\convert-xel.ps1 -XelFile "C:\temp\sqlsim_test_capture*.xel" -OutputFile trace.xml

# 3. Replay
sqlsim -S localhost -E -replay fast -replayfile trace.xml
```

## Workflow Overview

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐     ┌────────────┐
│ 1. Capture   │────▶│ 2. Convert   │────▶│ 3. Replay  │────▶│ 4. Analyze │
│ XEvent trace │     │ .xel → .xml  │     │ fast/stress │     │ metrics    │
└─────────────┘     └──────────────┘     └────────────┘     └────────────┘
```

## Step-by-Step Guide

### Step 1: Capture a Workload

Start an XEvent session that captures only sqlsim traffic:

```powershell
sqlsim -S localhost -E -app sqlsim_admin -i replay\setup-test-capture.sql -q
```

**Key detail:** The `-app sqlsim_admin` flag tags this connection so the XEvent session
filters it out. Only events from the default app name (`sqlsim`) are captured.

Run your workload (any combination of queries, threads, iterations):

```powershell
# Simple workload
sqlsim -S localhost -E -d master -Q "SELECT @@VERSION" -n 4 -r 10 -q

# From a SQL file
sqlsim -S localhost -E -i my-workload.sql -n 8 -q

# Mixed queries
sqlsim -S localhost -E -Q "SELECT 1`nGO`nSELECT name FROM sys.databases`nGO`nSELECT @@SERVERNAME" -n 3 -q
```

Stop the capture:

```powershell
sqlsim -S localhost -E -app sqlsim_admin -i replay\stop-test-capture.sql -q
```

### Step 2: Convert .xel to Replay XML

```powershell
.\replay\convert-xel.ps1 -XelFile "C:\temp\sqlsim_test_capture*.xel" -OutputFile trace.xml
```

The converter reads the .xel file via `sys.fn_xe_file_target_read_file()` on the target
SQL Server. The raw `event_data` XML is passed through directly — no parsing or
re-serialization.

Options:
- `-ServerName <server>` — SQL Server to read the .xel file (default: localhost)
- `-MaxEvents <n>` — Limit the number of events extracted

### Step 3: Replay the Trace

**Fast mode** — preserves captured session grouping. Each original session gets its own
connection. Supported events replay as fast as possible in their captured order within
each session; timestamp gaps are not reproduced:

```powershell
sqlsim -S localhost -E -replay fast -replayfile trace.xml
```

**Stress mode** — flattens all events into a single sequence and runs them across N
threads for M iterations. Good for stress testing:

```powershell
sqlsim -S localhost -E -replay stress -replayfile trace.xml -n 8 -r 100
```

Add `-v` for verbose per-event logging:

```powershell
sqlsim -S localhost -E -replay fast -replayfile trace.xml -v
```

Add `-json` for machine-readable metrics:

```powershell
sqlsim -S localhost -E -replay fast -replayfile trace.xml -json
```

### Step 4: Verify Replayed Statements (Optional)

To compare the captured and replayed query text and event counts:

```powershell
# Start a capture during replay
sqlsim -S localhost -E -app sqlsim_admin -i replay\capture-during-replay.sql -q

# Replay
sqlsim -S localhost -E -replay fast -replayfile trace.xml -q

# Stop capture
Start-Sleep 2
sqlsim -S localhost -E -app sqlsim_admin -i replay\stop-replay-capture.sql -q

# Compare
.\replay\compare-traces.ps1 `
    -OriginalXel "C:\temp\sqlsim_test_capture*.xel" `
    -ReplayXel "C:\temp\sqlsim_replay_capture*.xel"
```

Expected output:

```
COMPARISON RESULTS
Original: 9 query events (3 distinct)
Replay:   9 query events (3 distinct)
Matched queries: 3 / 3
RESULT: PASS - Query text and event counts match
```

This comparison does not prove complete application fidelity. Replay does not
restore transaction boundaries, think time, connection state, or session-level
`SET` options. Review errors and workload semantics separately.

### Compare Original and Replay Performance

Converted XEvent XML retains the original completed-event fields, including
duration, CPU time, logical and physical reads, writes, row count, outcome,
session, database, timestamp, and SQL text. Run Replay with query statistics to
emit both the original aggregates and Replay measurements:

```powershell
sqlsim -S localhost -E -replay fast -replayfile trace.xml `
  -querystats -json -o replay-results.json -q
```

For live monitoring plus the same canonical comparison data:

```powershell
sqlsim -S localhost -E -replay fast -replayfile trace.xml `
  -querystats -querystats-interval 1 -stream-json `
  -json -o replay-results.json -q
```

The JSON contains:

- `replay_capture.queries`: original per-query XEvent averages and outcomes;
- `query_stats.queries`: per-query Replay elapsed time, CPU, reads, rows, and
  failures; and
- `replay_summary`: overall original and Replay outcomes.

`replay_capture.queries` aggregates the entire capture into one row per unique
exact SQL text. Repeated events contribute to execution and outcome counts and
to the original metric averages. `query_stats.queries` aggregates Replay
measurements by the same exact SQL text before comparison; text variants remain
separate rows. XEvent duration is converted from microseconds to milliseconds;
XEvent CPU time is milliseconds. Missing fields remain `null`. Treat
stress-mode deltas as a transformed-load comparison, not a like-for-like
reproduction.

## XEvent Session Design

The capture sessions use the `sqlsim` application name as a filter:

| Session | Captures | Filter | File Target |
|---------|----------|--------|-------------|
| `sqlsim_test_capture` | Original workload | `client_app_name = 'sqlsim'` | `C:\temp\sqlsim_test_capture.xel` |
| `sqlsim_replay_capture` | Replay workload | `client_app_name = 'sqlsim'` | `C:\temp\sqlsim_replay_capture.xel` |

**Events captured:**
- `sql_batch_completed` — T-SQL batches (SELECT, INSERT, DDL, etc.)
- `rpc_completed` — RPC calls (sp_executesql, stored procedures, etc.)
- `login` / `logout` — Session boundaries (used for fast mode session mapping)

**Actions captured:**
- `session_id` — Maps events to original sessions
- `database_name` — Database context for each event

**Admin commands** (setup/teardown) use `-app sqlsim_admin` which is excluded from capture.

## Replay Modes

### Fast Mode

- Creates one connection per original session (preserving session affinity)
- Replays supported events as fast as possible in their original order within each session
- Sessions run concurrently on separate threads
- Best for: Statement regression testing and session-ordered performance experiments

### Stress Mode

- Flattens all events into a single ordered sequence
- Each of `-n` threads runs the full sequence `-r` times
- Best for: Throughput testing, stress testing, scalability testing

## Comparing Two Replay Runs

Replay A/B comparison uses the shared comparison report in `examples/reports/`,
not a replay-specific script. Replay the same capture against each
configuration, then compare the two JSON files:

```powershell
sqlsim -S serverA -d mydb -E -replay fast -replayfile trace.xml -json -o replay-a.json -q
sqlsim -S serverB -d mydb -E -replay fast -replayfile trace.xml -json -o replay-b.json -q

.\examples\reports\comparison-report.ps1 `
    -BaselineFile replay-a.json -CandidateFile replay-b.json `
    -LabelA "Server A" -LabelB "Server B"
```

The report's configuration table includes the replay mode and replayable event
count, and reports **Not comparable** when they differ — so a `fast` replay is
never silently compared against a `stress` replay. Add `-Csv results.csv` for a
spreadsheet or CI-friendly copy.

This is the same report used for non-replay A/B testing. See the HTML Reports
section of [../sqlsim.md](../sqlsim.md) for the full set of options.

## Azure SQL Database

The replay workflow works with Azure SQL DB. The key differences:

- XEvent sessions use `ON DATABASE` (not `ON SERVER`)
- Event file target writes to Azure Blob Storage (not local disk)
- You download the `.xel` from blob storage, then convert locally
- The `.xel` format and event schema are identical — `convert-xel.ps1` works unchanged

### Prerequisites

1. **Azure Storage account** with a blob container (e.g., `xevents`)
2. **SQL Server managed identity** granted `Storage Blob Data Contributor` on the storage account
3. **Database scoped credential** using managed identity
4. **Azure CLI** (`az`) for access tokens and blob download

### One-Time Setup

```powershell
# Grant the SQL Server managed identity access to the storage account
az role assignment create `
    --assignee <sql-server-managed-identity-principal-id> `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/<sub>/resourcegroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>"

# Create the database scoped credential
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$token | sqlsim -S myserver.database.windows.net -d mydb -T - -app sqlsim_admin -Q "
    CREATE DATABASE SCOPED CREDENTIAL [https://<storage>.blob.core.windows.net/<container>]
    WITH IDENTITY = 'Managed Identity'" -q
```

### Azure Capture → Convert → Replay

```powershell
# Get access token
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

# 1. Start capture (writes to blob storage)
$token | sqlsim -S myserver.database.windows.net -d mydb -T - -app sqlsim_admin `
    -i replay\azure-setup-capture.sql

# 2. Run workload
$token | sqlsim -S myserver.database.windows.net -d mydb -T - `
    -i replay\azure-workload-batches.sql -q
$token | sqlsim -S myserver.database.windows.net -d mydb -T - `
    -i replay\azure-workload-rpc.sql -q
$token | sqlsim -S myserver.database.windows.net -d mydb -T - `
    -i replay\azure-workload-sp-executesql.sql -q

# 3. Stop capture
$token | sqlsim -S myserver.database.windows.net -d mydb -T - -app sqlsim_admin `
    -i replay\azure-stop-capture.sql -q

# 4. Download .xel from blob storage
az storage blob list --container-name xevents --account-name <storage> --auth-mode key `
    --query "[].name" -o tsv
az storage blob download --container-name xevents --account-name <storage> `
    --name "sqlsim_capture_0_<timestamp>.xel" --file capture.xel --auth-mode key

# 5. Convert .xel to replay XML (uses any SQL Server to read the .xel file)
.\replay\convert-xel.ps1 -XelFile capture.xel -OutputFile trace.xml -ServerName localhost

# 6. Replay against Azure SQL DB
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$token | sqlsim -S myserver.database.windows.net -d mydb -T - -replay fast -replayfile trace.xml
```

> **Note:** The `convert-xel.ps1` script reads `.xel` files via `sys.fn_xe_file_target_read_file()`
> on a SQL Server instance. The file doesn't need to come from that instance — any SQL Server
> can read any `.xel` file. Use a local SQL Server for convenience.

> **Note:** Update the blob storage URL in `azure-setup-capture.sql` to match your storage
> account and container before first use.

## Files in This Directory

| File | Purpose |
|------|---------|
| `README.md` | This guide |
| `DESIGN.md` | Detailed technical design document |
| `setup-test-capture.sql` | Start XEvent capture for original workload |
| `stop-test-capture.sql` | Stop original capture |
| `capture-during-replay.sql` | Start XEvent capture during replay (for comparison) |
| `stop-replay-capture.sql` | Stop replay capture |
| `convert-xel.ps1` | Convert .xel files to replay XML |
| `compare-traces.ps1` | Compare original vs replay traces for fidelity |
| `generate-rpc-workload.ps1` | Generate RPC events for testing (uses SqlClient) |
| `run-replay-test.ps1` | End-to-end automated test of the full workflow |
| `azure-setup-capture.sql` | Start XEvent capture on Azure SQL DB (blob storage target) |
| `azure-stop-capture.sql` | Stop capture on Azure SQL DB |
| `azure-create-test-proc.sql` | Create test stored proc on Azure SQL DB |
| `azure-workload-batches.sql` | SQL batch workload for Azure capture testing |
| `azure-workload-rpc.sql` | RPC workload (user stored proc) for Azure capture testing |
| `azure-workload-sp-executesql.sql` | RPC workload (sp_executesql) for Azure capture testing |

## Troubleshooting

**"The log file name is invalid"** — The .xel path contains a wildcard that expanded to
multiple space-separated files. The `convert-xel.ps1` script handles this by resolving
the directory and keeping the wildcard pattern for `sys.fn_xe_file_target_read_file()`.

**Too many events captured** — Make sure the XEvent session filters on
`client_app_name = 'sqlsim'`. Other applications on the server will generate events too.

**"Bulk load data was expected but not sent"** — The trace contains `INSERT BULK`
statements that can't be replayed without the actual data. These are expected errors
during replay of traces that included bulk operations.

**login/logout events show as "skipped"** — This is correct. Login/logout events are used
for session mapping in fast mode but are not replayed as queries.
