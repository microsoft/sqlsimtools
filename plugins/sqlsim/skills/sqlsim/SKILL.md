---
name: sqlsim
description: Run SQL queries, scripts, or multi-threaded workloads against SQL Server, Azure SQL Database, Azure SQL Managed Instance, or SQL database in Microsoft Fabric using the sqlsim CLI. USE FOR — executing T-SQL ad-hoc or from a `.sql` file; stress / load testing with N threads × R iterations; measuring connection / login / fetch timings; producing JSON metrics for automation; capturing per-query statistics (`-querystats`). DO NOT USE FOR — non-SQL Server engines (MySQL, Postgres, Oracle), or schema generation / data loading (sqlsim runs queries; it does not generate schemas).
---

# sqlsim — SQL workload simulator

## Authoritative references (read these before authoring commands)
Prefer the installed, version-matched copies in the workspace release overlay.
They match the executable you will run and work offline:
- Consumer-facing agent instructions: `sqlsim/AGENTS.md`
- User manual: `sqlsim/sqlsim.md`
- Examples: `sqlsim/examples/`

If the overlay is not installed, for example when this skill comes from an
Agent Plugin, use the public copies. They track the latest release, so confirm
an option exists in `sqlsim -h` before relying on it:
- <https://github.com/microsoft/sqlsimtools/blob/main/sqlsim/AGENTS.md>
- <https://github.com/microsoft/sqlsimtools/blob/main/sqlsim/sqlsim.md>
- <https://github.com/microsoft/sqlsimtools/tree/main/sqlsim/examples>

## Installation prerequisite and binary discovery
This plugin supplies agent guidance, not the sqlsim executable. Install a
[sqlsim release](https://github.com/microsoft/sqlsimtools/releases) in the
workspace or install `sqlsim` on `PATH` before running a workload.

Resolve the executable in this order:
1. Workspace release overlay: `.\sqlsim\x64\sqlsim.exe` or `.\sqlsim\ARM64\sqlsim.exe` on Windows; `./sqlsim/x64/sqlsim` on Ubuntu.
2. A `sqlsim` executable already available on `PATH`.

If neither exists, stop and report the missing prerequisite. Do not assume the
Agent Plugin installation directory contains the executable.

## Command shape
```powershell
sqlsim.exe -S <server> <auth> [-d <database>] [-Q <query> | -i <file>] [-n threads] [-r iters] [-q|-v] [-stream-json] [-json [-o file]]
```

Authentication (exactly one is required):

| Flag | Use case |
|------|----------|
| `-E` | Windows SSPI or Linux Kerberos integrated authentication |
| `-A` | Microsoft Entra interactive (Windows only) |
| `-A ActiveDirectoryIntegrated` | Entra integrated (Kerberos ticket required on Linux) |
| `-A ActiveDirectoryMsi` | Managed Identity |
| `-A ActiveDirectoryServicePrincipal -U <client_id> -P <secret>` | Service principal |
| `-T <token>` | Access token — preferred for repeated Azure runs |
| `-U <user> -P <pwd>` | SQL Authentication |

For local applications and automation, use `-T -` or `-P -` with redirected stdin to keep secrets out of process arguments.

## Canonical patterns
```powershell
# Smoke — local SQL Server
.\sqlsim\x64\sqlsim.exe -S localhost -E -Q "SELECT @@VERSION"

# Workload — 10 threads × 100 iterations, suppress result sets
.\sqlsim\x64\sqlsim.exe -S localhost -d AdventureWorks -E -i .\workload.sql -n 10 -r 100 -q

# Azure SQL with token (no interactive popup)
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | .\sqlsim\x64\sqlsim.exe -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"

# JSON for automation
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 -json -o results.json
$r = Get-Content results.json | ConvertFrom-Json

# NDJSON progress stream for live consumers
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 -stream-json

# NDJSON progress plus canonical final JSON
.\sqlsim\x64\sqlsim.exe -S localhost -E -i .\workload.sql -n 4 -r 50 `
  -stream-json -json -o final-results.json
```

## Workload pattern
Separate logic from execution: a `.ps1` invokes `sqlsim.exe -i workload.sql`. SQL batches are separated by `GO`. Use `-stoponerror` to halt all threads on the first failure (default: continue).

## Rules
1. Resolve the executable using the discovery order above. Do not search source build directories.
2. Never append `2>&1`, `>`, or `| Select-String` to a sqlsim invocation. Capture into a variable instead.
3. Parse JSON results with `ConvertFrom-Json`. Compute deltas between phases — never compare cumulative values.
4. For Azure SQL prefer `-T <token>` over `-A` for repeated runs.
5. On Linux, do not use bare `-A` or `ActiveDirectoryInteractive`; use `-T`, Kerberos integrated authentication, managed identity, service principal, or SQL authentication.
6. `-querystats-interval <seconds>` snapshots query statistics to a file while the run is in progress, implying `-querystats` and defaulting to `querystats-live.json`. The file is replaced atomically, so it is safe to poll. A write failure never fails the run and is reported once on stderr, but that message is suppressed in `-json` and `-stream-json` modes; verify the file exists rather than relying on a message or the exit code.
7. Combine `-stream-json` with `-json -o <file>` to keep live NDJSON on stdout and write the canonical final JSON to the file. The combined mode requires `-o`.
8. Certificate validation follows `sqlcmd` (Go): neither `-N` nor `-C` means the certificate is not validated, `-N` without `-C` requires validation, and `-C` bypasses it. This applies to every authentication mode including `-T`. For Azure SQL prefer `-N m`; use `-C` only for a self-signed server, or `-F <hostname>` when the connected name differs from the certificate name.
9. Start load tests with a small `-n` value and scale gradually while monitoring client and server CPU, memory, network, and connection usage. High thread counts can exhaust client resources and invalidate results; use a dedicated client for significant load tests.
