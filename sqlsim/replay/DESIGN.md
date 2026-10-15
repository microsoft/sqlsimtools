# sqlsim Replay Mode — Design Document

**Created:** February 10, 2026

## Overview

Replay mode allows sqlsim to replay SQL workloads captured via SQL Server Extended Events. The user captures a workload into `.xel` files, converts them to XML using a provided script, and replays them against a target server using sqlsim's existing multi-threading and connection infrastructure.

## Parameters

```
-replay <mode>          Replay mode: "fast" or "stress"
-replayfile <xmlfile>   Path to the XML replay file (from convert-xel.ps1)
```

- `-replay` and `-replayfile` must both be specified together
- Mutually exclusive with `-Q` and `-i`
- `-p` is ignored (replay decides prepared vs. direct per event type)

### Parameter Support in Replay Mode

| Parameter | fast mode | stress mode | Notes |
|---|---|---|---|
| **Connection** | | | |
| `-S <server>` | ✅ | ✅ | Target server for replay |
| `-d <database>` | ✅ | ✅ | Default database (override per-event context) |
| `-c <connection_string>` | ✅ | ✅ | Full connection string for replay target |
| `-E` | ✅ | ✅ | Windows auth |
| `-A [mode]` | ✅ | ✅ | Entra auth |
| `-T <token>` | ✅ | ✅ | Access token |
| `-U` / `-P` | ✅ | ✅ | SQL auth |
| `-l <seconds>` | ✅ | ✅ | Login timeout |
| `-app <name>` | ✅ | ✅ | Application name |
| `-retry` / `-retrydelay` | ✅ | ✅ | Connection retry |
| **Security & Encryption** | | | |
| `-N [level]` | ✅ | ✅ | Encryption |
| `-C` | ✅ | ✅ | Trust server cert |
| `-F <hostname>` | ✅ | ✅ | Certificate hostname |
| `-R` | ❌ | ❌ | Not supported — replay may contain modifications |
| `-M` | ❌ | ❌ | Not supported in replay |
| **Output** | | | |
| `-o <file>` | ✅ | ✅ | Output to file |
| `-q` | ✅ | ✅ | Quiet mode |
| `-v` | ✅ | ✅ | Verbose mode |
| `-json` | ✅ | ✅ | JSON output |
| `-stoponerror` | ✅ | ✅ | Stop on first error |
| **Query** | | | |
| `-Q <query>` | ❌ Error | ❌ Error | Queries come from replay file |
| `-i <file>` | ❌ Error | ❌ Error | Queries come from replay file |
| `-t <seconds>` | ✅ | ✅ | Safety net query timeout |
| `-p` | ❌ Ignored | ❌ Ignored | Replay decides per event type |
| **Workload** | | | |
| `-n <threads>` | ❌ Ignored | ✅ | fast: thread count = session count from trace; stress: N concurrent copies |
| `-r <iterations>` | ✅ | ✅ | Replay entire trace R times |
| `-reconnect` | ❌ Ignored | ❌ Ignored | Replay manages connections |
| `-usepool` | ❌ Auto | ❌ Ignored | fast: auto-detected from trace; stress: ignored |

## Phase 1: Two Replay Modes

### Mode 1: Fast Replay (`-replay fast`)

Faithful session-based replay with full ODBC fidelity, as fast as possible (no timing).

- One thread per unique `session_id` in the trace
- Preserves session affinity, prepare/execute handle lifecycle, database context
- `-n` is ignored (thread count comes from the trace)
- `-r` replays the entire trace R times
- Purpose: **reproduce the original workload pattern** on a target server

### Mode 2: Stress Replay (`-replay stress`)

Flatten all events into one ordered sequence and run it like a SQL script.

- All events from the trace ordered by timestamp into a single sequence (stable sort, so events that share a timestamp keep their `event_sequence` order)
- `-n` concurrent threads each run the full sequence (like `-i` with a SQL file)
- `-r` iterations per thread
- `sp_prepare`/`sp_execute`/`sp_unprepare` lifecycle is collapsed — each event replayed as a one-shot
- Purpose: **stress test the server** with a realistic workload at scale

### Events to Replay

| Event | fast mode | stress mode | ODBC Replay Method |
|---|---|---|---|
| `sql_batch_completed` | **Replay** | **Replay** | `SQLExecDirect(batch_text)` |
| `rpc_completed` — `sp_executesql` | **Replay** | **Replay** | `SQLPrepare(sql_with_?)` + `SQLBindParameter` + `SQLExecute` |
| `rpc_completed` — `sp_prepexec` | **Replay** | **Replay** | Same as `sp_executesql` |
| `rpc_completed` — `sp_prepare` | **Replay** | **Skip** | fast: `SQLPrepare` → store in handle map |
| `rpc_completed` — `sp_execute` | **Replay** | **Replay as one-shot** | fast: look up handle + bind + execute; stress: `SQLPrepare` + bind + `SQLExecute` (no handle reuse) |
| `rpc_completed` — `sp_unprepare` | **Replay** | **Skip** | fast: `SQLFreeHandle` + remove from map |
| `rpc_completed` — user stored proc | **Replay** | **Replay** | `SQLPrepare("{CALL dbo.MyProc(?,?)}")` + `SQLBindParameter` + `SQLExecute` |
| `rpc_completed` — `sp_cursor*` | **Skip** | **Skip** | Cursor plumbing — not supported |
| `rpc_completed` — `sp_reset_connection` | **Metadata** | **Skip** | fast: session boundary marker for pooling |

### Fast Mode: Session-to-Thread Mapping

- Each unique `session_id` in the trace becomes a replay thread
- `sp_reset_connection` events split a single `session_id` into multiple logical sessions
- Thread count is dictated by the trace (no cap)
- Events within each session keep the replay file order, which `convert-xel.ps1` sorts by `event_sequence`

### Fast Mode: Connection Pooling Detection

- `login` event with `is_cached` field detects pooling
- `sp_reset_connection` events mark boundaries between logical sessions within a pooled physical connection
- If pooling detected, replay auto-enables connection pooling behavior

### Stress Mode: Event Flattening

- All events from all sessions ordered by timestamp into a single sequence; ties keep `event_sequence` order
- `sp_prepare`/`sp_unprepare` events are dropped (no handle context across flattened events)
- `sp_execute` events must include the statement text so they can replay as one-shot `SQLPrepare` + bind + `SQLExecute`
- Each of `-n` threads runs the full sequence independently

### Parameter Binding

For `sp_executesql`, `sp_prepexec`, and user stored proc replay, sqlsim must bind parameters via ODBC:

**Type inference from value literals:**

| Value Format | ODBC Type |
|---|---|
| Integer literal (`42`) | `SQL_BIGINT` |
| Decimal literal (`3.14`) | `SQL_DOUBLE` |
| `N'...'` | `SQL_WVARCHAR` |
| `'...'` | `SQL_VARCHAR` |
| `NULL` | `SQL_WVARCHAR` with null indicator |
| `0x...` | `SQL_BINARY` |

**Handle map for prepare/execute lifecycle:**
- Per-thread `std::unordered_map<int, SQLHSTMT>` mapping original prepare handle → ODBC statement handle
- `sp_prepare` creates entry, `sp_execute` looks up and reuses, `sp_unprepare` frees and removes
- Cleanup on thread exit frees all remaining handles

### XML Input Format

The XML comes from SQL Server's `sys.fn_xe_file_target_read_file()`. The function returns a relational rowset with these columns:

| Column | Type | Description |
|---|---|---|
| `object_name` | nvarchar(256) | Event name (`sql_batch_completed`, `rpc_completed`) |
| `event_data` | nvarchar(max) | Event details as XML |
| `file_name` | nvarchar(260) | Source `.xel` file |
| `file_offset` | bigint | Offset in file |
| `timestamp_utc` | datetime2(7) | UTC timestamp (SQL 2017+) |

The `event_data` XML format (defined by SQL Server):

```xml
<event name="sql_statement_completed" package="sqlserver" timestamp="2026-02-10T14:30:00.123Z">
  <data name="duration">
    <value>111021</value>
  </data>
  <data name="statement">
    <value>SELECT * FROM Orders WHERE CustomerID = 42</value>
  </data>
  <data name="object_name">
    <value>sp_executesql</value>
  </data>
  <action name="session_id">
    <value>52</value>
  </action>
  <action name="database_name">
    <value>AdventureWorks</value>
  </action>
</event>
```

Key field names by event:
- `sql_batch_completed`: `<data name="batch_text">` for the SQL text
- `rpc_completed`: `<data name="statement">` for the SQL text, `<data name="object_name">` for the RPC procedure name
- Actions like `session_id` and `database_name` only appear if added to the XE session definition

### Conversion Script (`convert-xel.ps1`)

The conversion script reads `.xel` files and produces the XML file for replay:
- **Primary path**: Query via `sys.fn_xe_file_target_read_file()` on a SQL Server
- **Alternate path**: Use `Microsoft.SqlServer.XEvent.Linq` .NET assembly (offline, no server needed)
- Filters out `sp_cursor*` and `sp_reset_connection` (or marks `sp_reset_connection` as metadata)
- Uses XQuery to extract fields from `event_data` XML
- Orders events by the `package0.event_sequence` action, not file position: Extended Events writes memory buffers to the file in no guaranteed order. `event_sequence` restarts at 1 when the session starts, so a file whose lowest sequence is not above the previous file's lowest starts a new run, and runs stay in file name order. Without the action, events stay in file order with a warning
- Wraps all events into a single XML file

### XEvent Capture Script

Standard XEvent session definition to capture the required events:

```sql
CREATE EVENT SESSION [sqlsim_capture] ON SERVER
ADD EVENT sqlserver.sql_batch_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
),
ADD EVENT sqlserver.rpc_completed(
    ACTION(package0.event_sequence, sqlserver.session_id, sqlserver.database_name)
),
ADD EVENT sqlserver.login(
    ACTION(package0.event_sequence, sqlserver.session_id)
),
ADD EVENT sqlserver.logout(
    ACTION(package0.event_sequence, sqlserver.session_id)
)
ADD TARGET package0.event_file(
    SET filename = N'sqlsim_capture.xel',
        max_file_size = 100  -- MB
)
WITH (
    MAX_MEMORY = 8192 KB,
    MAX_DISPATCH_LATENCY = 5 SECONDS
);
```

### A/B Testing (PowerShell Scripts)

Replay A/B comparison uses the shared comparison report in `examples/reports/`,
not a replay-specific script. The report is general purpose; replay is one of
its inputs.

**Workflow:**
```powershell
# Capture workload and convert
.\convert-xel.ps1 -XelFile capture.xel -OutputFile trace.xml

# Replay against server A
.\sqlsim -replay fast -replayfile trace.xml -S serverA -E -json -v -o resultA.json

# Replay against server B
.\sqlsim -replay fast -replayfile trace.xml -S serverB -E -json -v -o resultB.json

# Compare results
.\..\examples\reports\comparison-report.ps1 -BaselineFile resultA.json -CandidateFile resultB.json `
    -LabelA "Server A" -LabelB "Server B"
```

**Scripts:**

| Script | Purpose |
|---|---|
| `examples/reports/comparison-report.ps1` | Compare two sqlsim JSON outputs; produce an HTML report and optional CSV |

**Report includes:**
- Delta cards per metric, coloured by improvement or regression
- Side-by-side metric table with percentage change and verdict
- Tally of improved, unchanged, and regressed metrics
- Configuration comparison covering target, replay mode, replayable event count,
  load shape, batch count, driver, and server version

**Configuration guardrail:** when the two runs used different targets, replay
modes, or load shapes, the report reports **Not comparable** and names the
differing settings rather than presenting a misleading verdict. A `fast` replay
is never silently compared against a `stress` replay.

**Use cases:** version upgrades, config changes, hardware comparison, index tuning validation, migration testing

### New Source Files

| File | Purpose |
|---|---|
| `include/xel_replay.h` | `ReplayEvent`, `ReplaySession` structs, XML parser class, parameter binding helpers |
| `src/xel_replay.cpp` | XML parsing, session grouping, event ordering, parameter type inference |

### Changes to Existing Files

| File | Changes |
|---|---|
| `include/workload_simulator.h` | Add replay fields to `WorkloadConfig`, handle map support |
| `src/workload_simulator.cpp` | Replay branch in `workerThread()` — fast mode: per-session dispatch; stress mode: shared sequence |
| `include/command_line_parser.h` | Add `-replay` and `-replayfile` parameter validation |
| `src/command_line_parser.cpp` | Parse `-replay <mode>` and `-replayfile <file>`, mutual exclusion with `-Q`/`-i`, validate mode |
| `src/main.cpp` | Replay-specific configuration output, help text |
| `include/odbc_connection.h` | Add `executeWithParameters()` and handle map methods |
| `src/odbc_connection.cpp` | `SQLBindParameter` implementation |
| `CMakeLists.txt` | Add `src/xel_replay.cpp` to sources |

### Fast Mode: Worker Thread Logic

```
for each event in session (in event_sequence order):
    if event is sql_batch_completed:
        SQLExecDirect(batch_text)

    else if event is rpc_completed:
        if object_name is sp_executesql or sp_prepexec:
            extract inner SQL, replace @P1/@P2 with ? markers
            parse param types and values
            SQLPrepare(sql_with_?) + SQLBindParameter(each) + SQLExecute()

        else if object_name is sp_prepare:
            SQLAllocHandle + SQLPrepare(sql_with_?)
            store in handleMap[prepare_handle]

        else if object_name is sp_execute:
            hStmt = handleMap[prepare_handle]
            SQLBindParameter(each) + SQLExecute(hStmt)

        else if object_name is sp_unprepare:
            SQLFreeHandle(handleMap[prepare_handle])
            handleMap.erase(prepare_handle)

        else if object_name starts with sp_cursor:
            skip

        else:
            // user stored proc
            parse proc name and parameters
            SQLPrepare("{CALL proc(?,?)}") + SQLBindParameter(each) + SQLExecute()
```

### Stress Mode: Worker Thread Logic

```
// All events flattened into one sequence, ordered by timestamp (ties in event_sequence order)
// sp_prepare/sp_unprepare removed; sp_execute promoted to one-shot

for each event in sequence:
    if event is sql_batch_completed:
        SQLExecDirect(batch_text)

    else if event is rpc_completed:
        if object_name is sp_executesql, sp_prepexec, or sp_execute:
            extract SQL, replace @P1/@P2 with ? markers
            parse param types and values
            SQLPrepare(sql_with_?) + SQLBindParameter(each) + SQLExecute()

        else if object_name starts with sp_cursor:
            skip

        else:
            // user stored proc
            parse proc name and parameters
            SQLPrepare("{CALL proc(?,?)}") + SQLBindParameter(each) + SQLExecute()
```

---

## Phase 2: Timing and Polish

### Timed Replay Mode (`-replay timed`)
- Third replay mode: like fast but with original timing between events
- Insert `sleep()` between events matching the original inter-event gaps within each session
- Handle edge cases: very long gaps (cap at configurable max, e.g., 30 seconds)
- Optionally synchronize sessions to the original timeline so cross-session ordering is reproduced; tracked in GitHub issue #39

### Per-Session Metrics
- Report metrics grouped by session ID in addition to aggregate
- In JSON output, include session-level breakdown

### Database Context Switching
- Issue `USE <database_name>` when the database changes within a session
- Based on `database_name` field in each event

### Thread Pool Model
- For traces with many sessions (hundreds+), use a thread pool with work queues
- Sessions assigned to threads; each thread runs assigned sessions sequentially

### Filtered Replay
- `-replayfilter session:52,53` — replay only specific sessions
- `-replayfilter db:AdventureWorks` — replay only events for a specific database
- `-replayfilter proc:dbo.MyProc` — replay only specific stored procedures

### Session SET Options Replay
- Capture `login` and/or `existing_connection` XEvent events to extract session-level SET options
- SET options include: `ANSI_NULLS`, `QUOTED_IDENTIFIER`, `ARITHABORT`, `CONCAT_NULL_YIELDS_NULL`, `ANSI_PADDING`, `ANSI_WARNINGS`, `NUMERIC_ROUNDABORT`, etc.
- These are encoded as a bitmap in the `options` or `options2` fields of the login/existing_connection events
- At replay time, issue matching `SET` statements at the start of each session before replaying events
- **Current state**: ODBC Driver 18 sets standard defaults that match most applications (especially those using ODBC, ADO.NET, or similar modern drivers). The risk is limited to cases where the original application used a non-standard driver with different SET defaults.
- **Implementation approach**: Extend `convert-xel.ps1` to capture login/existing_connection events and emit per-session SET options in the replay XML; extend `xel_replay.cpp` to parse and apply them

> **Note:** Database Context Switching was listed in Phase 2 but was implemented during Phase 1.

---

## Phase 3: Advanced Features

### Direct `.xel` Binary Parsing
- Parse `.xel` files directly in C++ without conversion step
- Requires reverse-engineering or using the binary format
- Eliminates dependency on SQL Server or .NET for conversion

### Cursor Replay
- Replay `sp_cursoropen` with the original query
- Implement `sp_cursorfetch` / `sp_cursorclose` lifecycle
- Would require ODBC server-side cursor APIs

### RPC Parameter Type Enhancement
- Query `sys.parameters` on the target server to get exact parameter types for user stored procs
- Replace type inference with precise type binding

### Scaled Replay (`-replayscale <factor>`)
- Modifier for timed mode: run at N× original speed (e.g., `-replayscale 2.0` = twice as fast)
- `-replayscale 0.5` = half speed (stretch delays)
- Applied to inter-event delays in timed mode only
