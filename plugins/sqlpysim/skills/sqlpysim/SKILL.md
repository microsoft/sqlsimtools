---
name: sqlpysim
description: Public Preview Python-based port of sqlsim built on Microsoft's native `mssql-python` driver. USE FOR — running SQL queries, scripts, and multi-threaded workloads from Python environments; mixed workload files (`-workload`); live progress streaming (`-stream-json`); periodic query-statistic snapshots (`-querystats-interval`); comparing driver behavior between native ODBC (sqlsim) and `mssql-python`; producing sqlpysim JSON for automation. DO NOT USE FOR — sqlsim-only replay modes; setting an application name (`-app`, which the driver reserves); exact cross-tool JSON compatibility; or performance comparisons that require the lowest possible client overhead (use sqlsim instead).
---

# sqlpysim — Python port of sqlsim

## Authoritative references
Prefer the installed, version-matched copies in the workspace release overlay.
They match the script you will run and work offline:
- Consumer-facing agent instructions: `sqlpysim/AGENTS.md`
- User manual: `sqlpysim/sqlpysim.md`
- Examples: `sqlpysim/examples/`

If the overlay is not installed, for example when this skill comes from an
Agent Plugin, use the public copies. They track the latest release, so confirm
an option exists in `sqlpysim.py -h` before relying on it:
- <https://github.com/microsoft/sqlsimtools/blob/main/sqlpysim/AGENTS.md>
- <https://github.com/microsoft/sqlsimtools/blob/main/sqlpysim/sqlpysim.md>

Driver reference: <https://github.com/microsoft/mssql-python>

## Installation prerequisite and entry-point discovery
This plugin supplies agent guidance, not the sqlpysim runtime. Install a
[sqlpysim release](https://github.com/microsoft/sqlsimtools/releases) in the
workspace and install its Python requirements before running a workload.

Resolve the entry point in this order:
1. Workspace release overlay: `python .\sqlpysim\sqlpysim.py`.
2. An installed `sqlpysim` command on `PATH`.

If neither exists, stop and report the missing prerequisite. Do not assume the
Agent Plugin installation directory contains `sqlpysim.py`.

Canonical workspace command:
```powershell
python .\sqlpysim\sqlpysim.py <args>
```
Core query invocations follow sqlsim's command shape. Advanced flags,
validation, and JSON fields differ; consult the release notes before translating
commands or parsers between tools.

## Driver constraints (do not violate)
- Import: `from mssql_python import connect`
- **Reserved keywords** — driver controls these; do not set them in the connection string: `APP`, `Application Name`
- **Token auth** must use `attrs_before[SQL_COPT_SS_ACCESS_TOKEN]` with a UTF-16LE / SQLLEN-prefixed buffer. There is NO `access_token=` parameter.
  ```python
  SQL_COPT_SS_ACCESS_TOKEN = 1256
  token_bytes  = token.encode("utf-16le")
  token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)
  conn = connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})
  ```

## Canonical patterns
```powershell
# Local SQL Server, Windows Auth
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1"

# Azure SQL with token
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | python .\sqlpysim\sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"

# Multi-threaded workload (quiet)
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 10 -r 100 -q

# JSON for automation
python .\sqlpysim\sqlpysim.py -S localhost -E -C -i .\workload.sql -n 4 -r 50 -json -o results.json

# Per-query server statistics using the sqlsim JSON contract
python .\sqlpysim\sqlpysim.py -S localhost -E -C -i .\workload.sql -n 4 -r 50 -querystats -json -q -o results.json

# Mixed workload groups from a sqlsim-format workload file
python .\sqlpysim\sqlpysim.py -S localhost -E -C -workload .\workload.json -q

# Live progress for a supervising process: one JSON event per line on stdout
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 -stream-json -q

# Live progress plus canonical final JSON
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 `
  -stream-json -json -o final-results.json -q

# Periodic server-statistic snapshots while the run is in flight
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 -querystats-interval 5 -querystats-file live.json -q

# Secure password input for local applications and automation
$password | python .\sqlpysim\sqlpysim.py -S localhost -U testuser -P - -Q "SELECT 1"
```

## Installation prerequisite
```powershell
python -m pip install -r .\sqlpysim\requirements.txt
```

## Rules
1. Verify any driver syntax against the official `mssql-python` docs before writing or modifying connection code. Do not invent parameters.
2. Never append `2>&1` or pipe through `Select-String`. Capture output into a PowerShell variable if needed.
3. Parse sqlpysim JSON with `ConvertFrom-Json`, but do not assume its schema is identical to sqlsim.
4. When comparing tools, limit assertions to documented shared behavior and account for driver-specific timing and metrics.
5. For applications and automation, use `-T -` or `-P -` with redirected stdin so secrets do not appear in process arguments.
6. `-querystats` reports sqlsim-compatible aggregates without querying DMVs or emitting query/plan hashes.
7. `-stream-json` turns on JSON mode. Combine it with `-json -o <file>` to keep NDJSON on stdout and write the canonical final result to the file; combined mode requires `-o`. Events are cumulative and `throughput_per_second` is a running average, so compute deltas between events for a current rate.
8. `-querystats-interval` implies `-querystats` and defaults its file to `querystats-live.json`. A write failure never fails the run and is reported once on the normal error channel, which is silent in `-json` and `-stream-json` modes; verify the file exists rather than relying on a message or the exit code.
9. `-app` is rejected: `mssql-python` reserves the application name and always reports `MSSQL-Python`. Use sqlsim when the application name matters.
10. Start load tests with a small `-n` value and scale gradually while monitoring client and server CPU, memory, network, and connection usage. High thread counts can exhaust client resources and invalidate results; use a dedicated client for significant load tests.
