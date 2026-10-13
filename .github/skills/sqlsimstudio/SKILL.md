---
name: sqlsimstudio
description: "Use when a user wants to install, launch, configure, authenticate, run, monitor, compare, or troubleshoot released sqlsim Studio, including the Windows package, browser bootstrap, sqlsim or sqlpysim workloads, JSON results, Query Store statistics, cancellation, saved configurations, themes, or A/B comparisons. DO NOT USE FOR: source builds, CI, repository manual acceptance testing, or repository load-test tier recording."
---

# Use sqlsim Studio

sqlsim Studio is a local browser application for configuring, running,
monitoring, and comparing SQL Server workloads. It starts a loopback-only web
server and opens the interface in the user's browser. It does not send workload
data to a hosted service.

## Choose the right workflow

- Use this skill for an installed or extracted Studio release.
- Use `sqlsimstudio-manual-test` for the source repository's manual acceptance
  checklist.
- Use `sqlsimstudio-load-test` for the source repository's light, medium, and
  heavy AdventureWorksLT test tiers.
- Use `sqlsimtools-build` to build or test Studio from source.
- Use `sqlsim` or `sqlpysim` for direct command-line execution.

## Platform status

| Platform | v1.0 status |
| --- | --- |
| Windows x64 | Public Preview release |
| Ubuntu x64 | Private Preview for invited testers |
| Windows ARM64 | Private Preview |
| macOS ARM64 | Private Preview |

Do not direct a general user to a Private Preview package unless they already
have access to it.

## Locate and launch the package

Studio's public Windows x64 release is `sqlsimtools-<version>-win-x64.zip`. It
contains Studio plus the complete sqlsim x64 and sqlpysim packages:

```text
README.md
sqlsimstudio/sqlsimstudio.exe
sqlsimstudio/sqlsimstudio.md
sqlsimstudio/sqlsimstudio.html
sqlsimstudio/CONFIGURATION.md
sqlsimstudio/sqlsimstudio-cleanup.ps1
sqlsimstudio/examples/README.md
sqlsimstudio/examples/any-database/
sqlsimstudio/examples/adventureworkslt/
sqlsimstudio/examples/sql/
sqlsimstudio/examples/convert-workload-for-studio.ps1
sqlsim/x64/sqlsim.exe
sqlsim/examples/results/index-baseline.json
sqlsim/examples/reports/
sqlsim/replay/
sqlpysim/sqlpysim.py
sqlpysim/requirements.txt
.github/skills/sqlsimstudio/SKILL.md
```

Studio runs `sqlsim/x64/sqlsim.exe` and `sqlpysim/sqlpysim.py` from the
sqlsimtools folder. `sqlsimstudio/examples/any-database/` holds query, workload,
and Replay samples that run against any database;
`sqlsimstudio/examples/adventureworkslt/` holds light, medium, and heavy tiers
and a Replay capture for AdventureWorksLT. For Compare without a database,
import `sqlsim/examples/results/index-baseline.json` and `index-candidate.json`.
Use `sqlsimstudio/examples/convert-workload-for-studio.ps1` before
**Import JSON** when a sqlsim workload references SQL files with `file`.

Launch from the extracted sqlsimtools folder:

```powershell
.\sqlsimstudio\sqlsimstudio.exe
```

To enable sqlpysim, create `.venv` in the sqlsimtools folder and install the
sqlpysim requirements. Studio uses `SQLSIM_STUDIO_PYTHON_PATH`, then `.venv`
beside `sqlsimstudio.exe`, then `.venv` in the sqlsimtools folder, then
`python` on `PATH`:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\sqlpysim\requirements.txt
```

Studio binds to a random loopback port and opens a one-time bootstrap URL in
the default browser. Treat that URL as a temporary local credential:

- Do not paste or publish it.
- Do not replace its host with a remote name.
- If the browser did not open, stop Studio and launch it again rather than
  sharing or repeatedly reusing an old bootstrap URL.
- Shut Studio down with the power button so an active child workload is also
  stopped.

## Configure a connection

1. Choose `sqlsim` for the lowest client overhead, replay, and the full native
   feature set.
2. Choose `sqlpysim` to exercise Microsoft's native `mssql-python` driver.
3. Enter the SQL Server or Azure SQL target and database.
4. Select exactly one authentication mode.
5. Review encryption and certificate settings.
6. Use **Test connection** before starting a load.

Supported authentication modes are Windows/Kerberos integrated, Microsoft
Entra token, Microsoft Entra interactive, managed identity, service principal,
and SQL authentication. Availability depends on the platform, engine, and
target.

Never put passwords, access tokens, or client secrets in chat, saved
configuration files, SQL text, screenshots, or command arguments. Studio keeps
the current secret in server memory and passes it to the child engine through
standard input. Saved configurations always clear and omit the secret.

For Azure SQL token authentication, acquire a token for the database audience
outside Studio, then paste it into the credential field:

```powershell
az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
```

## Choose a workload mode

| Mode | Use it for |
| --- | --- |
| Query | One SQL batch with a connection and iteration count |
| SQL File | A `.sql` script, including `GO`-separated batches |
| Workload | Multiple scripts with independent connections, iterations, and think time |
| Replay | Native sqlsim session-ordered or load-stress replay from converted XML |

Replay requires the `sqlsim` engine. When switching engines, follow the
capability messages in the interface instead of forcing an unsupported
combination.

Select the converted replay XML and review the preflight event/session summary
before running. Studio summarizes the entire capture but displays at most 100
capture-preview rows. Original-versus-Replay results aggregate the entire
capture by exact SQL text; they are not limited to the preview. Replay defaults
to Final results to minimize streaming overhead, but Live progress also writes
canonical final JSON so the same comparison is available after completion.
Replay preserves supported
statement order within captured sessions but does not reproduce timestamp
pacing, transactions, think time, connection state, or session `SET` options.
Treat the XML as sensitive because it can contain SQL text and literal values.
This Studio release accepts Replay files with zero or one captured database.
It runs captures without database context in the selected Studio target and
redirects one captured database to that target. It rejects multi-database
captures during preflight; source-to-target mapping is deferred. Studio
validates connectivity, not schema or data equivalence, so confirm the target
contains synchronized schema and data before comparing performance.

Enable **Collect per-query performance** to compare original XEvent duration,
CPU, reads, rows, execution counts, and outcomes with Replay measurements.
Runtime query statistics show a bounded SPID list for each query in Query, SQL
file, Workload, and Replay runs. Studio matches exact captured SQL text in the
original-versus-Replay comparison and labels stress-mode results as a
transformed workload. Diagnostics add `SET STATISTICS TIME/IO` overhead, so
disable them for maximum-throughput measurements.

Start conservatively when the user has not supplied a load level: one
connection and one iteration. Before running, confirm the exact target,
database, SQL write behavior, connection count, iteration count, and estimated
executions. Studio validates the configured connection before it starts every
workload and remains on Configure when that validation fails. Use only a
dedicated test system for stress or load testing.

## Select telemetry and statistics

- **Live progress** streams aggregate progress and supports the Monitor view.
- **Final results** minimizes monitoring overhead and maps canonical JSON when
  the run finishes.
- **Console output** displays bounded result rows and raw engine output.
- **Runtime query statistics** uses engine-reported query statistics where
  supported.
- **Query Store** takes read-only before/after snapshots and can include work
  from other sessions; use a quiet test database for meaningful deltas.

Use the interface's capability notes as authoritative for the selected engine.

## Run, monitor, and stop

1. Review the command preview. Private staged paths are expected.
2. Select **Run** only after confirming the target and load.
3. Use Monitor for progress, throughput, connection state, sanitized logs, and
   live per-query statistics when Live progress uses runtime statistics.
4. Use **Stop run** to cancel. Closing the browser tab does not stop the child
   workload.
5. Use **View results** after completion.

Studio logs are session-only and sanitized, but SQL errors can still reveal
object names or query text. Review them before sharing.

## Results and comparisons

Results include canonical engine metrics when structured telemetry is used.
Export JSON when the result needs to be retained outside the current session.

Compare session runs or imported result files only when they are successful,
compatible final results. Keep the target, database, engine, workload, authentication mode,
connection count, iterations, telemetry, and statistics settings equivalent.
Use **Export JSON** and Compare's **Import JSON** buttons to compare results
across Studio sessions.
Treat differences in driver and client overhead as part of an intentional
sqlsim-versus-sqlpysim experiment, not as interchangeable measurements.

## Save and load configurations

Studio configuration files may include server names, database names, query
text, SQL scripts, workload scripts, and replay XML in plain text. They never
include passwords, tokens, or client secrets.

Review a configuration from another person before loading or running it. See
`../../../sqlsimstudio/CONFIGURATION.md`, in both a source checkout and the
extracted sqlsimtools package, for the versioned format and limits.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Browser does not open | Confirm Studio is still running; relaunch from the package directory |
| Bootstrap link fails | It is single-use; stop and relaunch Studio |
| Engine missing | Keep the sqlsimtools layout intact and verify `sqlsim/x64/sqlsim.exe` or `sqlpysim/sqlpysim.py` |
| sqlpysim unavailable | Create `.venv` in the sqlsimtools folder, install `sqlpysim/requirements.txt`, then refresh Studio |
| ODBC or TLS failure | Verify the packaged engine prerequisites, ODBC Driver 18, encryption, and certificate settings |
| Authentication failure | Reacquire an expired token and verify the selected mode is supported on this platform |
| Query Store unavailable | Verify it is read-write and the identity has the required performance-state permission |
| Run continues after tab closes | Reopen Studio through a fresh launch or use the packaged cleanup guidance |
| Comparison is disabled | Complete or import two successful, compatible final results |

The packaged `sqlsimstudio/sqlsimstudio.md` is the authoritative user manual. Do not work
around an explicit validation or capability error by changing hidden files or
calling the local API directly.
