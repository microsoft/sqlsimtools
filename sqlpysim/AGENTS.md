# AGENTS.md — sqlpysim

This file tells coding agents (GitHub Copilot, Claude Code, Cursor, Aider,
Codex CLI, etc.) how to invoke **sqlpysim** when a user asks them to run SQL
workloads from Python. It is shipped at the root of the sqlpysim release
package so any agent operating in the user's project picks it up automatically.

A companion VS Code skill descriptor lives at
[`../.github/skills/sqlpysim/SKILL.md`](../.github/skills/sqlpysim/SKILL.md).

## What sqlpysim is

sqlpysim is a Public Preview Python implementation of `sqlsim` built on Microsoft's native
`mssql-python` driver. It shares sqlsim's core query, concurrency,
authentication, and reporting workflow, but some advanced flags and output
fields differ. See [`../RELEASE-NOTES.md`](https://github.com/microsoft/sqlsimtools/blob/main/RELEASE-NOTES.md) before treating
the tools as interchangeable.

Use it when:
- The user is in a Python environment and prefers not to ship a C++ binary.
- The user wants to compare native ODBC (`sqlsim`) vs. `mssql-python` behavior.
- The user needs the JSON contract for automation but on a non-Windows or
  non-x64 environment where `sqlpysim` is easier to deploy than `sqlsim.exe`.

**Do not use** for absolute-lowest-overhead performance comparisons —
`sqlsim` (the native binary) is the right tool there.

## Installed layout

```
your-project/
├── .github/skills/sqlpysim/SKILL.md
└── sqlpysim/
  ├── sqlpysim.py      # entry point
  ├── requirements.txt # mssql-python
  ├── AGENTS.md        # this file
  ├── LICENSE          # MIT license
  ├── sqlpysim.md      # full user manual
  └── examples/        # powershell/, sql/, workload/, github-actions-ci/
```

## Prerequisites

```powershell
python -m pip install -r .\sqlpysim\requirements.txt
```

Requires Python 3.10+ and the `mssql-python` driver.

## Entry point

```powershell
python .\sqlpysim\sqlpysim.py <args>
```

Core query invocations use the same command shape as `sqlsim.exe`. Do not assume
that advanced flags, validation behavior, or JSON fields are interchangeable;
use this file and the sqlpysim manual for supported syntax.

## Canonical patterns

```powershell
# Local SQL Server, Windows Auth
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT @@VERSION"

# Azure SQL with token
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | python .\sqlpysim\sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"

# Multi-threaded workload (quiet)
python .\sqlpysim\sqlpysim.py -S localhost -E -C -i .\workload.sql -n 10 -r 100 -q

# JSON output for automation
python .\sqlpysim\sqlpysim.py -S localhost -E -C -i .\workload.sql -n 4 -r 50 -json -o results.json

# sqlsim-compatible per-query statistics
python .\sqlpysim\sqlpysim.py -S localhost -E -C -i .\workload.sql -n 4 -r 50 -querystats -json -q -o results.json

# Mixed workload groups from a sqlsim-format workload file
python .\sqlpysim\sqlpysim.py -S localhost -E -C -workload .\workload.json -q

# Live progress: one JSON event per line on stdout for a supervising process
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 -stream-json -q

# Live progress plus canonical final JSON
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 `
  -stream-json -json -o final-results.json -q

# Periodic statistics snapshots written while the run is still going
python .\sqlpysim\sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 4 -r 500 -querystats-interval 5 -querystats-file live.json -q

# Secure password input for local applications and automation
$password | python .\sqlpysim\sqlpysim.py -S localhost -U testuser -P - -Q "SELECT 1"
```

Use `-T -` or `-P -` with redirected stdin for local applications and automation so the secret does not appear in process arguments.

`-querystats` reports the same aggregate fields as sqlsim. It does not query
DMVs or emit query/plan hashes.

`-stream-json` emits `started`, one `progress` per second, and `completed`,
matching sqlsim's event shape. Combine it with `-json -o <file>` to retain the
canonical final result while streaming. Counters are cumulative and
`throughput_per_second` is a running average, so a consumer wanting a current
rate computes deltas between events.
After the first successful connection, progress and completed events also
identify the driver version and SQL Server version and edition.

`-querystats-interval <seconds>` writes a statistics snapshot to a file while
the run is in progress, implying `-querystats` and defaulting the path to
`querystats-live.json`. The file is replaced atomically, so it is always safe
to read. A write failure never interrupts the run; it is reported once on the
normal error channel, which is silent in `-json` and `-stream-json` modes, so
in those modes check that the file exists rather than relying on a message.
`sqlsim` behaves identically.

`-app` is rejected rather than silently ignored, because `mssql-python`
reserves the application name and always reports `MSSQL-Python` to the server.
Use sqlsim when the application name matters.

## Driver constraints (do not violate)

These come from `mssql-python` and an agent generating Python code that
wraps sqlpysim must respect them:

- **Reserved keywords** — the driver controls these; do not pass in the
  connection string: `APP`, `Application Name`.
- **Token auth** uses `attrs_before[SQL_COPT_SS_ACCESS_TOKEN]` with a
  UTF-16LE / SQLLEN-prefixed buffer. There is NO `access_token=` parameter.

  ```python
  import struct
  SQL_COPT_SS_ACCESS_TOKEN = 1256
  token_bytes  = token.encode("utf-16le")
  token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)
  conn = connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})
  ```

- Import as: `from mssql_python import connect`.

Reference: <https://github.com/microsoft/mssql-python>.

## Authoring rules for agents

Same as sqlsim — see [`sqlsim/AGENTS.md`](https://github.com/microsoft/sqlsimtools/blob/main/sqlsim/AGENTS.md) (or the sqlsim
package's `AGENTS.md`) for the full list. The key ones:

1. Always include an auth flag (`-E`, `-A`, `-T`, or `-U`/`-P`).
2. For Azure SQL, always include `-d <database>`.
3. Use `-q` for stress tests.
4. Start with a small `-n` value, scale gradually, and monitor client and
   server CPU, memory, network, and connection usage. High thread counts can
   exhaust client resources and invalidate results; use a dedicated client
   for significant load tests.
5. Use `-C` to trust server cert when working against local SQL Server with
   a dev cert.
6. Do not invent long flags. `--help` is the only long flag.
7. Do not pipe through `2>&1` or `Select-String`. Capture into a variable
   if you need to parse output.

## Help

```powershell
python .\sqlpysim\sqlpysim.py --help
```

Full manual: [`sqlpysim.md`](sqlpysim.md) (also rendered as `sqlpysim.html`).
