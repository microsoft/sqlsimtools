---
name: sqlsimtools-build
description: "Build and test sqlsimtools from source. USE WHEN: cloning the repository, setting up a development environment, compiling sqlsim, preparing sqlpysim, building sqlsim Studio, running smoke tests or the full test suite, checking prerequisites, or diagnosing a build or test failure on Windows or Linux. DO NOT USE FOR: running SQL workloads with the released tools (use the sqlsim or sqlpysim skills), or cutting a release (use the sqlsimtools-release skill)."
---

# Build and test sqlsimtools

Developer skill for working with this repository's source. Each tool builds and
tests independently and owns its own scripts. Always run a tool's scripts from
that tool's directory.

## Order of operations

1. Check prerequisites.
2. Build the tool.
3. Run its smoke test.
4. Run its full test suite if behavior changed.

Studio depends on step 2 for sqlsim: its build copies the compiled binary out
of `sqlsim/build/<arch>/Release/`. Build sqlsim before building Studio.

## Prerequisites

| Tool | Windows | Linux |
|------|---------|-------|
| sqlsim | `.\check-prerequisites.ps1` | `bash ./check-prerequisites-linux.sh --require-driver` |
| sqlpysim | `python --version` (3.10+), then `python -c "import mssql_python"` after installing requirements | Verify Python 3.10+, install `mssql-python`, then use the native Bash suites below |
| Studio | .NET 10 SDK | .NET 10 SDK |

All tools need Microsoft ODBC Driver 18 to reach a live SQL target. sqlsim also
needs CMake 3.15+ and a C++17 toolchain: Visual Studio 2022 or 2026 Build Tools
on Windows, `build-essential` and `unixodbc-dev` on Ubuntu.

## Build

```powershell
# sqlsim, Windows. Default builds x64 and ARM64.
cd sqlsim
.\build.ps1 -Clean -Architecture x64

# sqlsim Studio, Windows. Requires sqlsim built first.
cd sqlsimstudio
.\build.ps1 -Runtime win-x64
```

```bash
# sqlsim, Ubuntu 24.04 or 26.04 LTS x64
cd sqlsim
bash ./build-linux.sh --clean

# sqlsim Studio, Linux
cd sqlsimstudio
bash ./build-linux.sh linux-x64
```

sqlpysim has no build step:

```powershell
cd sqlpysim
python -m pip install -r requirements.txt
```

Build outputs:

| Tool | Windows | Linux |
|------|---------|-------|
| sqlsim | `build/x64/Release/sqlsim.exe`, `build/ARM64/Release/sqlsim.exe` | `build/linux-x64/sqlsim` |
| Studio | `build/win-x64/sqlsimstudio.exe` | `build/linux-x64/sqlsimstudio` |

## Install a source build into a project

To install sqlsim (and optionally sqlpysim) with its manual, examples, skill,
and Workload Builder into another project, use the wrapper from the repository
root rather than copying files:

```powershell
.\scripts\install-local.ps1 -Workspace C:\myproject -Build
.\scripts\install-local.ps1 -Workspace C:\myproject -Tool sqlsim, sqlpysim -Preview
```

It checks prerequisites, builds, installs, validates offline, and prints a
receipt. It never deletes project files and stops before writing if a file it
installs already differs; re-run with `-Force` only after the user agrees to
replace those files. On Ubuntu use
`bash sqlsim/publish-linux.sh --skip-build --release-dir <project>`, which
accepts `--preview` and `--force`. Re-check an installed project with
`release\validate-package-layout.ps1`.

## Test

Smoke tests are fast and validate core behavior. The full suites are the gate
for any behavior or CLI change.

```powershell
cd sqlsim
.\smoke-test.ps1 -SkipBuild
.\full-test-suite.ps1 -SkipBuild
```

```bash
cd sqlsim
bash ./smoke-test-linux.sh
bash ./full-test-suite-linux.sh
```

Shared parameters for sqlsim `smoke-test.ps1` and `full-test-suite.ps1`:
`-Server`, `-Database`, `-UseToken`, `-Username`, `-Password`, `-SkipBuild`,
`-Verbose`, `-OutputFile`. `full-test-suite.ps1` also accepts `-SkipScale` to
skip the 1024-thread test on constrained targets.

sqlpysim Windows tests use `smoke-test.ps1` and `full-test-suite.ps1`.
Native Linux/WSL Bash suites are supported for both tools, so PowerShell is not
required. They take the target as options and work from any Linux VM,
container, or WSL distribution that can reach the server over TCP:

```bash
cd sqlpysim   # or sqlsim
bash ./smoke-test-linux.sh --server HOST --database DB \
  --username USER --password-file FILE
bash ./full-test-suite-linux.sh --server HOST --database DB \
  --username USER --password-file FILE
```

For token authentication, use `--token-file FILE` instead of the username and
password options. Secret files are read from their first line, and a Windows
CRLF ending is ignored. Every suite, PowerShell and Bash, hands the token or
password to the engine on stdin (`-T -`, `-P -`), so it never appears in a
process list. When adding a test, build its arguments from the suite's auth
array and launch the engine through the suite's launcher (`$runSqlsim`,
`$runSqlPySim`, or `with_secret`) so this stays true. All four suites support `--list-tests` and `--help`.
The sqlpysim suites also take `--python` and `--skip-install`. The sqlsim full
suite takes `--sqlsim`, `--skip-scale`, and `--stop-on-error`, and needs `jq`.
A WSL distribution in NAT mode cannot reach SQL Server on the Windows host via
`localhost`; target a reachable server name or address instead.

Studio `smoke-test.ps1` takes `-SkipBuild`, `-StartupOnly`, `-StudioExecutable`,
and `-QueryStoreDatabase`. `-StartupOnly` is what CI uses to verify a packaged
build starts without touching SQL Server. Interactive GUI coverage is manual and
tracked in `sqlsimstudio/MANUAL-TEST.md`.

Azure SQL targets are auto-detected by server name. Prefer `-UseToken` over
interactive authentication so runs stay non-interactive:

```powershell
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
.\full-test-suite.ps1 -SkipBuild -Server myserver.database.windows.net -Database mydb -UseToken $token
```

## Suite parity

The PowerShell and native Bash suites are deliberate parity counterparts for
sqlsim and sqlpysim, so Linux and WSL users do not need PowerShell for the
supported test suites. Adding or changing a test in only one counterpart is a
defect. Check with:

```powershell
./scripts/check-suite-parity.ps1
```

## Plugin packages

Canonical skills live under `.github/skills/`. Plugin copies are generated.

```powershell
./scripts/sync-plugins.ps1      # after editing a canonical skill
./scripts/validate-plugins.ps1  # gate; also runs in CI
```

Never edit `plugins/<tool>/skills/` directly.

## Rules

1. Use each tool's own scripts. Do not call `cmake`, `msbuild`, or
   `dotnet publish` directly.
2. Never append `2>&1`, `> file`, or `| Select-String` to a tool invocation.
   Capture into a variable instead, or use the script's `-OutputFile`.
3. Supply exactly one authentication mode. Nothing defaults.
4. Keep credentials out of process arguments. Use `-P -` or `-T -` with
   redirected stdin where a script supports it.
5. Do not scale thread counts against a shared or production SQL instance.
6. Treat a failing test as a real defect until proven otherwise. Do not skip or
   disable tests to get a green run.
