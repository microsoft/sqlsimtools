# Release Notes

Known issues and behavioral limitations that apply to released builds.

This is the canonical record for issues that affect released versions,
including issues under investigation for possible future releases. An issue
remains documented here until it no longer applies to a supported release.
Investigation does not commit the project to a fix or release date.

[BACKLOG.md](BACKLOG.md) tracks planned project work and points here for
release issues rather than duplicating their descriptions.

## Preview status and platform availability

Public Preview builds are published for general evaluation. Private Preview
builds are shared only with invited customers and testers helping validate
platform support; they are not supported public release assets. To ask for
access, open a [Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml). Access is granted to your
GitHub account.

| Tool | Platform | Status |
| --- | --- | --- |
| `sqlsim` | Windows x64 | Public Preview |
| `sqlsim` | Windows ARM64 | Public Preview |
| `sqlsim` | Ubuntu 24.04/26.04 LTS x64 | Public Preview |
| `sqlsim` | macOS ARM64 | Private Preview for invited customers and testers; live SQL validation and a signing/notarization decision remain |
| `sqlpysim` | Windows x64 and ARM64 | Public Preview; Windows ARM64 requires Python 3.11 or later |
| `sqlpysim` | Ubuntu 24.04/26.04 LTS x64 | Public Preview |
| `sqlpysim` | macOS ARM64 | Private Preview for invited customers and testers; native dependency and live SQL validation remain |
| `sqlsim Studio` | Windows x64 | Public Preview, shipped in `sqlsimtools-<version>-win-x64.zip` with the sqlsim x64 and sqlpysim packages |
| `sqlsim Studio` | Ubuntu 24.04/26.04 LTS x64 | Private Preview for invited testers; platform validation remains incomplete |
| `sqlsim Studio` | Windows ARM64 | Private Preview for invited testers; native validation and release packaging remain incomplete |
| `sqlsim Studio` | macOS ARM64 | Private Preview for invited testers; native validation, signing, notarization, and release packaging remain incomplete |

## Known issues and limitations

### sqlsim Studio Replay supports one target database

sqlsim Studio v1.0 accepts converted Replay files containing zero or one
distinct captured database. The destination is always the database selected in
Configure. If the trace contains one captured `database_name`, Studio redirects
that context to the selected destination when it stages the private Replay XML.
The converted file does not need a hand-authored target attribute.

Studio rejects captures containing multiple distinct databases during file
preflight. Source-to-target mapping for multi-database Replay is tracked in
[BACKLOG.md](BACKLOG.md) for a future release.

Studio validates target connectivity, not schema or data equivalence. Users are
responsible for synchronizing target schema and data before interpreting
performance comparisons. Server configuration, indexes, statistics, cache
state, concurrency, and Query Store activity can also affect results.

### sqlpysim does not yet have full sqlsim CLI or output compatibility

`sqlpysim` is in **Public Preview**. These compatibility gaps remain and are
tracked for future releases.

`sqlpysim` supports the shared core workflow: connection tests, `-Q` and `-i`
query execution, `-workload` mixed workload groups with per-group threads,
iterations, think time, duration mode and ramp-up, concurrent threads and
iterations, reconnect mode, text, JSON and `-stream-json` live event output,
and `-querystats` aggregates with optional `-querystats-interval` snapshots.
It does not yet implement the entire `sqlsim` command surface or every
low-level client measurement.

The following `sqlsim` options are unavailable in `sqlpysim`:

- `-replay` and `-replayfile` for fast or stress replay of converted XEvent
  traces. Replay is deliberately deferred from the sqlpysim v1.0 Public
  Preview because matching sqlsim requires a substantial session-aware
  scheduling, RPC fidelity, metrics, and testing subsystem. Future support may
  be considered; use `sqlsim` for replay.
- `-F` for overriding the hostname used during certificate validation

Some accepted options also differ in effect:

- `-p` prints a warning and runs unprepared. `mssql-python` prepares only
  executions with bound parameters, while sqlpysim workloads contain complete
  SQL text and expose no parameter-binding source. This cannot reproduce
  sqlsim's prepare/execute mode for raw SQL.
- `-app` is rejected. The driver reserves the application name and always
  reports `MSSQL-Python` to the server, so a requested name can never take
  effect. This is documented driver behavior rather than a `sqlpysim`
  limitation: see
  [Connection strings for mssql-python](https://learn.microsoft.com/sql/connect/python/mssql-python/connection-strings),
  which lists `APP` as reserved and `Application Name` as unrecognized.
  `sqlpysim` refuses the option and reports `MSSQL-Python` as the application
  name, which is what `APP_NAME()` returns, so a session can be found by the
  name shown. Earlier versions accepted `-app` and echoed the requested name
  back in text and JSON while the server saw something else. Use `sqlsim` when
  the application name matters. `sqlsim Studio` disables its Application name
  field for the Python engine for the same reason.
JSON output remains suitable for tool-specific automation but is not an
identical metrics contract. The document uses the same driver, configuration,
warning, and verbose-operation field names as `sqlsim`, while retaining
engine-specific values such as `odbc_driver: "mssql-python"`. Both tools report
query execution time through result consumption and report zero fetch
operations in JSON mode. `sqlpysim` now derives `-querystats` aggregates from
the same `SET STATISTICS TIME/IO` diagnostic path as `sqlsim`.

Use `sqlsim` when any unavailable option, exact validation behavior, prepared
execution, or an identical metrics contract is required. Compatibility work is
tracked in [BACKLOG.md](BACKLOG.md).

`sqlpysim` also spends more client CPU per query than `sqlsim`. In pre-release
measurements against a local server, a trivial `SELECT 1` used about 15 times
the client CPU per execution, and at 50 threads `sqlpysim` reached roughly a
tenth of `sqlsim`'s throughput because Python threads share one interpreter
lock. For light queries the client, not SQL Server, becomes the limit. Use
`sqlpysim` to measure `mssql-python` driver behavior, and `sqlsim` when you
need maximum load or are comparing server-side performance.

### sqlsim Studio ships only controls that work

sqlsim Studio v1.0 omits unimplemented features from the interface rather than
showing them greyed out. A visible button always does something.

All six authentication modes are wired: Windows integrated, Microsoft Entra
token, Microsoft Entra interactive, managed identity, service principal, and SQL
authentication. Studio shows only the credential fields a mode uses and enforces
the same rules the engines do, so an unusable combination is refused before a
process starts.

One option disables itself where the capability genuinely does not exist:

| Option | Unavailable when | Reason |
| --- | --- | --- |
| Microsoft Entra interactive | Studio runs on Linux or macOS | ODBC Driver 18 implements interactive sign-in on Windows only |

For repeated runs against Azure SQL, prefer **Microsoft Entra token**. Each
connection under interactive sign-in can prompt, which does not suit a
high-connection workload:

```powershell
az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
```

Planned for a future preview revision, currently absent from the interface:
copying the Monitor event stream, Run again, opening a completed run's
configuration, and copying, exporting, or clearing the execution log display.
The log itself works; only those actions are missing.

Some controls start disabled and enable themselves when they become meaningful —
Stress connections in stress replay, Connection pooling once Reconnect each
iteration is on, Suppress result rows in console telemetry, Stop run during a
run, and the comparison selectors once a final result exists. Those are
working as intended, not gaps.

**HTML reporting is a two-step flow, not a Studio button.** Studio exports the
canonical results JSON with the verbose fields included, and
`sqlsim/examples/reports/execution-report.ps1` turns that file into an HTML
report. The Compare view likewise exports a comparison bundle that
`sqlsim/examples/reports/comparison-report.ps1` renders as an A/B report. A
single generator serves both the command line and Studio rather than two
implementations that drift apart.

**Studio run history is session-scoped.** It is held in memory and discarded
when Studio exits. To compare across sessions, export each run's JSON and use
**Import JSON** in the Compare view, or pass the two files to
`comparison-report.ps1 -BaselineFile <a> -CandidateFile <b>` for an HTML report.

The three authentication modes are the most consequential. `sqlsim` and
`sqlpysim` support all of them through `-A`; only the Studio wiring is
outstanding. **Use Microsoft Entra token instead**, which is fully implemented
and is the recommended path for Azure SQL Database, Azure SQL Managed Instance,
and SQL database in Microsoft Fabric:

```powershell
az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
```

Some controls start disabled and enable themselves when they become meaningful —
Stress connections in stress replay, Connection pooling once Reconnect each
iteration is on, Suppress result rows in console telemetry, Stop run during a
run, and the comparison selectors once a final result exists. Those are
working as intended, not gaps.

Studio run history is held in memory for the current session only. It is
discarded when Studio exits; use **Export JSON** and **Import JSON** to compare
results across sessions.

### Microsoft Entra interactive authentication is Windows-only

`-A` (and `-A ActiveDirectoryInteractive`) works on Windows only. Both `sqlsim`
and `sqlpysim` reject it on Linux and macOS during argument validation:

```text
ActiveDirectoryInteractive is not supported by ODBC Driver 18 on Linux.
```

The cause is Microsoft ODBC Driver 18, which implements interactive Entra sign-in
only on Windows. Rejecting early is deliberate and avoids a hang on headless
hosts.

**Use instead on Linux and macOS:**

- `-T <token>` — an access token, for example from
  `az account get-access-token --resource https://database.windows.net --query accessToken -o tsv`
- `-A ActiveDirectoryMsi` — a managed identity

### Certificate validation is off unless you ask for it

`sqlsim` follows the same negotiation rule as `sqlcmd` (Go): with neither `-N`
nor `-C` the server certificate is **not validated**, `-N` without `-C`
requires validation, and `-C` bypasses it. A bare
`sqlsim -S localhost -E` therefore connects to a server with a self-signed
certificate, where `sqlcmd` (ODBC) 18 and later would refuse.

This is deliberate, matching the documented `sqlcmd` (Go) behavior, but it is
easy to carry into production unnoticed. **For Azure SQL and any connection
that leaves the host, pass `-N m` or `-N s`.** Azure presents a certificate
from a trusted authority, so validation costs nothing and the connection
crosses the internet.

The rule applies to every authentication mode, including access token
authentication (`-T`). `-T` on its own connects without validating; add `-N m`
to opt in.

`sqlpysim` follows the same default. sqlsim Studio starts with **Trust server
certificate** checked, matching SQL Server Management Studio, and uses the same
setting for Query Store collection. Clear it for Azure SQL or any server with a
certificate from a trusted authority.

`-F <hostname>` sets the name the certificate is checked against, for a server
reached by an IP address, a DNS alias, or an availability-group listener. It
cannot be combined with `-C`. sqlsim supports `-F`; sqlpysim does not expose
the option in v1.0. Support will be investigated for a future release.

### `-p` (prepared statements) is ignored by sqlpysim

`sqlsim` executes complete SQL text through `SQLPrepare` / `SQLExecute` without
requiring bound parameters. `mssql-python` takes its prepare path only for
executions with bound parameters, while sqlpysim workloads expose no
parameter-binding source. `sqlpysim` therefore prints a warning and runs the
workload unprepared:

```text
Warning: Prepared statements (-p) are not supported for raw SQL workloads by mssql-python; flag ignored
```

Timings taken with `-p` are therefore comparable between `sqlpysim` runs, but not
between `sqlpysim` and `sqlsim`.

Parameterized sqlpysim workloads, including a format for supplying bound values,
may be considered for a future release. They are not part of the v1.0 Public
Preview contract.

### sqlpysim's ODBC driver version is pinned by its wheel, not the operating system

Both tools connect through Microsoft ODBC Driver 18, but they get it from
different places. `sqlsim` loads the driver installed on the host. `sqlpysim`
loads the copy vendored inside `mssql-python`, which hard-pins
`mssql-python-odbc`.

The two can differ — a host with `msodbcsql18` 18.7.1.1 installed still runs
`sqlpysim` on the bundled 18.6.2.1. Updating the system package does not move
`sqlpysim`; that requires a newer `mssql-python` release.

### sqlpysim stays on `mssql-python` 1.15.0 for now

`sqlpysim` 1.0.0 is validated with, and `requirements.txt` pins,
`mssql-python==1.15.0`. `mssql-python` 1.16.0 is available and passed the
Windows x64 test suites, but it adds a new Rust-based connection runtime
(`mssql-python-rs`), so it will be adopted only after Ubuntu, Windows ARM64,
and Azure SQL authentication testing. Until then, install from
`requirements.txt`. Running sqlpysim on a newer `mssql-python` is supported on a
best-effort basis; see [DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md).

### Very long, high-rate runs keep growing in memory

`sqlsim` and `sqlpysim` keep one latency sample per query execution until the
run ends. `sqlsim` stores 8 bytes per execution, so a run executing about 70,000
queries per second grows by roughly 2 GB per hour; at a few thousand executions
per second the growth is about 100 MB per hour. `sqlpysim` grows about
0.3 MB per second at its typical rates. Memory is released when the run ends.

For multi-hour runs of very fast queries, watch client memory, or split the
test into shorter runs. Query statistics (`-querystats`) no longer add
per-execution memory. Replacing the samples with running statistics is tracked
for a future release.

### sqlpysim threads start as they connect

`sqlsim` opens every connection first and then releases all threads together,
so its measurement window starts with full concurrency. `sqlpysim` starts each
thread as soon as its own connection opens, so the first moments of a run have
fewer active threads. On long runs the difference is negligible; on runs of a
few seconds it can lower `sqlpysim` throughput compared with `sqlsim`. Run
cross-tool comparisons long enough that connection time is a small fraction of
the run. A start barrier is tracked for a future release.
