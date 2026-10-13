# AGENTS.md — sqlsim

This file tells coding agents (GitHub Copilot, Claude Code, Cursor, Aider,
Codex CLI, etc.) how to invoke **sqlsim** when a user asks them to run SQL
workloads. It is shipped at the root of the sqlsim release package so any
agent operating in the user's project picks it up automatically.

A companion VS Code skill descriptor lives at
[`../.github/skills/sqlsim/SKILL.md`](../.github/skills/sqlsim/SKILL.md) and is
discovered automatically by skill-aware agents.

## What sqlsim is

sqlsim is a single-binary SQL workload simulator for SQL Server, Azure SQL
Database, Azure SQL Managed Instance, and SQL database in Microsoft Fabric.
It supports Windows x64/ARM64 and Ubuntu x64, multi-threaded execution, and
JSON output for automation.

## When to invoke sqlsim

**USE** when the user wants to:
- Run T-SQL ad-hoc or from a `.sql` file against SQL Server / Azure SQL
- Stress / load test with N threads × R iterations
- Measure connection, login, query, and fetch timings
- Produce JSON metrics for an automation pipeline
- Capture per-query statistics (`-querystats`)

**DO NOT use** for:
- Non-SQL Server engines (MySQL, PostgreSQL, Oracle, etc.)
- Schema generation or data loading (sqlsim runs queries; it does not
  generate schemas)

## Binary location

After extracting the release archive into your project root:

```
your-project/
├── .github/skills/sqlsim/SKILL.md
└── sqlsim/
   ├── x64/sqlsim.exe   # Windows x64, or x64/sqlsim on Ubuntu
   ├── ARM64/sqlsim.exe # Windows ARM64
   ├── AGENTS.md        # this file
   ├── LICENSE          # MIT license
   ├── sqlsim.md        # full user manual
   └── examples/        # sample .sql, .ps1, workload JSON
```

From the project root, default to `.\sqlsim\x64\sqlsim.exe` on Windows unless
the user specifies ARM64. On Ubuntu, use `./sqlsim/x64/sqlsim`.

## Command shape

```powershell
sqlsim.exe -S <server> <auth> [-d <database>] [-Q <query> | -i <file>] `
           [-n <threads>] [-r <iterations>] [-q|-v] `
           [-stream-json] [-json [-o <file>]]
```

```bash
./sqlsim/x64/sqlsim -S <server> <auth> [-d <database>] [-Q <query> | -i <file>] \
             [-n <threads>] [-r <iterations>] [-q|-v] \
             [-stream-json] [-json [-o <file>]]
```

### Authentication — one is REQUIRED, every time

| Flag | Use case |
|------|----------|
| `-E` | Windows SSPI or Linux Kerberos integrated authentication |
| `-A` | Microsoft Entra interactive (Windows only) |
| `-A ActiveDirectoryIntegrated` | Entra integrated (Kerberos ticket required on Linux) |
| `-A ActiveDirectoryMsi` | Managed Identity (Azure VM / App Service) |
| `-A ActiveDirectoryServicePrincipal -U <client_id> -P <secret>` | Service principal |
| `-T <token>` | Access token — preferred for repeated Azure runs |
| `-U <user> -P <pwd>` | SQL Authentication |

For applications and automation, use `-T -` or `-P -` with redirected stdin so the secret does not appear in the process command line.

On Linux, never use bare `-A`: Driver 18 interactive authentication is
Windows-only. Prefer token auth (`-T`) for interactive Azure SQL work. `-E`
requires a valid Kerberos ticket on Linux and does not fall back to NTLM.

For Azure SQL, ask the user once whether to use token auth (`-T`) to avoid
interactive popups on repeated Windows runs and to support Linux. If yes:

```powershell
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | .\sqlsim\x64\sqlsim.exe -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"
```

### Certificate validation

sqlsim follows the `sqlcmd` (Go) rule: with neither `-N` nor `-C` the server
certificate is **not** validated, `-N` without `-C` requires validation, and
`-C` bypasses it. This applies to every authentication mode including `-T`.

For Azure SQL, prefer `-N m` (or `-N s` on SQL Server 2022 and later), since
Azure presents a certificate from a trusted authority and the connection
crosses the internet. Reach for `-C` only against a server with a self-signed
certificate, and prefer `-F <hostname>` when the name you connect to differs
from the name on the certificate.

### Common parameters

| Parameter | Description |
|-----------|-------------|
| `-S <server>` | Server (localhost, FQDN, `server\instance`) |
| `-d <database>` | Database name (REQUIRED for Azure SQL) |
| `-Q <query>` | Inline query (supports `GO` batch separator) |
| `-i <file>` | Path to a `.sql` file |
| `-n <threads>` | Concurrent threads (default 1) |
| `-r <iterations>` | Iterations per thread (default 1) |
| `-q` | Quiet — suppress result sets (use for load tests) |
| `-v` | Verbose — detailed timing |
| `-json` | Final JSON document output |
| `-stream-json` | Live NDJSON started/progress/completed events |
| `-o <file>` | Write output to file |
| `-querystats` | Per-query stats (CPU, logical reads, etc.) |
| `-querystats-interval <sec>` | Snapshot query stats to a file while running (implies `-querystats`) |
| `-querystats-file <file>` | Snapshot path (default `querystats-live.json`) |
| `-workload <file>` | Mixed-workload JSON config |
| `-stoponerror` | Stop all threads on first error |
| `-reconnect` | New connection per iteration |
| `-t <sec>` | Query timeout (default 30) |
| `-l <sec>` | Login timeout (default 15) |

## Canonical patterns

```powershell
# 1. Smoke — local SQL Server, Windows Auth
.\sqlsim\x64\sqlsim.exe -S localhost -E -Q "SELECT @@VERSION"

# 2. Run a SQL file
.\sqlsim\x64\sqlsim.exe -S localhost -d AdventureWorks -E -i .\queries.sql

# 3. Load test — 10 threads × 100 iterations, suppress rows
.\sqlsim\x64\sqlsim.exe -S localhost -d testdb -E -i .\workload.sql -n 10 -r 100 -q

# 4. Azure SQL with token (no interactive popup)
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | .\sqlsim\x64\sqlsim.exe -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"

# 5. JSON output for automation
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 -json -o results.json
$r = Get-Content results.json | ConvertFrom-Json

# 6. Per-query statistics
.\sqlsim\x64\sqlsim.exe -S localhost -d testdb -E -i .\queries.sql -querystats -json -o stats.json

# 7. Live NDJSON progress
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 -stream-json

# 8. Live progress plus canonical final JSON
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 `
  -stream-json -json -o final-results.json
```

## Output contract

- Text output (default): per-batch timing + summary.
- `-json`: structured JSON — always parse with `ConvertFrom-Json` (PowerShell)
  or `json.loads()` (Python), never by hand. Top-level keys include `summary`,
  `batches`, and (when `-querystats`) `querystats`.
- `-stream-json`: one JSON object per line for live monitoring. Parse each line
  independently; it is not a single JSON document. Combine it with
  `-json -o <file>` to keep NDJSON on stdout and write the canonical final JSON
  document to the file. Combined mode requires `-o`.
- `-querystats-interval`: a snapshot file replaced atomically on each tick, so
   it is always safe to read while the run is in progress. A write failure never
   fails the run and is reported once on stderr, but that message is suppressed
   in `-json` and `-stream-json` modes; check that the file exists rather than
   relying on a message or the exit code.
- Exit code is non-zero on any failure; honor it in scripts.

## Authoring rules for agents

1. **Always include an auth flag.** sqlsim has no default auth mode.
2. **For Azure SQL, always include `-d <database>`.** Required by the service.
3. **Do not add `-v` unless the user asked for detail.** It generates a lot
   of output that's rarely needed.
4. **Use `-q` for load tests.** Result sets in stress tests just consume I/O.
5. **Scale concurrency safely.** Start with a small `-n` value, increase it
   gradually, and monitor client and server CPU, memory, network, and
   connection usage. High thread counts can exhaust client resources and
   invalidate results; use a dedicated client for significant load tests.
6. **Prefer `-i <file>` for anything multi-statement.** Inline `-Q` is fine
   for one-liners; use a file when there are multiple `GO` batches.
7. **Do not invent flags.** sqlsim uses short flags. There is no
   `--server` / `--query` / `--threads`. The only long flag is `--help`.
8. **Do not pipe through `2>&1` or `Select-String`.** Capture into a variable
   if you need to parse: `$out = & .\sqlsim\x64\sqlsim.exe ...`.

## Help

```powershell
.\sqlsim\x64\sqlsim.exe --help
```

Full manual: [`sqlsim.md`](sqlsim.md) (also rendered as `sqlsim.html`).
Examples: [`examples/`](examples/).
