# Driver Compatibility Policy

This document defines supported and tested client-driver versions for tools in this repository.

## Purpose

- Keep driver compatibility expectations explicit.
- Avoid silent drift between release validation and user environments.
- Provide a repeatable cadence for revalidation.

## Current Baseline

Last validated policy update: 2026-10-13. The machine-readable tracked versions
are in [`.github/driver-versions.json`](.github/driver-versions.json); the
release workflow writes them into every draft GitHub Release.

| Tool | Driver | Tracked version | Source |
| --- | --- | --- | --- |
| `sqlsim` Windows | Microsoft ODBC Driver 18 for SQL Server | 18.7.1.1 | Installed on the host |
| `sqlsim` Ubuntu | Microsoft ODBC Driver 18 for SQL Server, unixODBC 2.3.14 | 18.7.1.1 | Installed on the host |
| `sqlpysim` | `mssql-python` | 1.15.0 | `sqlpysim/requirements.txt`; bundles its own ODBC Driver 18 build |
| sqlsim Studio | `Microsoft.Data.SqlClient` | 7.1.0 | Compiled into Studio; used only for Query Store collection |

### sqlsim (C++ / ODBC)

- Preferred driver family: Microsoft ODBC Driver 18 for SQL Server (`msodbcsql18`).
- Windows tracked version: 18.7.1.1. The 1.0.0 live Windows integrated-auth validation on 2026-10-13 ran ODBC Driver 18.7.1.1 against SQL Server 17.0.4085.5: sqlsim smoke 48/48, full suite 255/255, replay 24/24, examples 39/39, and the sqlsim Studio smoke test. The earlier 2026-10-12 run on 18.6.1.1 also passed.
- Ubuntu validation version: 18.7.1.1 with unixODBC 2.3.14.
- Supported floor: ODBC Driver 18.0; sqlsim names `ODBC Driver 18 for SQL Server` explicitly.
- Recommended for release validation and customer guidance: latest available 18.x.
- Supported Linux platforms: Ubuntu 24.04 and 26.04 LTS x64 with ODBC Driver 18.
- Ubuntu 26.04 build and offline smoke validation passed on 2026-09-17.

### sqlpysim (Python / mssql-python)

- Driver package: `mssql-python`.
- Latest package observed at update time: 1.15.0 (PyPI, queried 2026-09-18).
- Tested dependency pin in `sqlpysim/requirements.txt`: `mssql-python==1.15.0`.
- Recommended for release validation: latest available 1.x at release time.
- Public Preview platforms match sqlsim: Windows x64 and ARM64, plus Ubuntu 24.04 and 26.04 LTS x64. Windows ARM64 requires Python 3.11 or later. macOS ARM64 is Private Preview for invited customers and testers helping validate the `mssql-python` wheel, native dependencies, authentication, and live SQL behavior. Linux ARM64 and musl wheels remain untested and unsupported.
- Windows integrated-auth validation on SQL Server 17.0.4085.5 passed on 2026-10-12: full suite 92/92 with `mssql-python` 1.15.0.
- `mssql-python` loads the ODBC Driver 18 build bundled in its wheel, not the driver installed on the host. Updating the host ODBC driver does not change `sqlpysim`; a newer `mssql-python` release does.
- Linux offline validation passed on 2026-09-23 on Ubuntu x86_64 with Python 3.12.3: `mssql-python` 1.15.0 and `defusedxml` 0.7.1 installed from PyPI wheels, offline unit tests 4/4, and CLI startup checks succeeded.
- Linux live validation passed on 2026-09-23 from an Ubuntu x86_64 client (Python 3.12.3) against SQL Server 2025 running in a container: SQL auth connect and query, `-querystats` across 3 iterations (35 logical reads, 3 executions, 0 failures), a 4-thread x 5-iteration workload, prepared statements, and `-N m -C` encryption.
- Linux `-E` uses Kerberos and requires a domain-joined host with a valid credential cache from `kinit`. It is untested and unsupported; use `-U/-P` or `-T` on Linux.

### sqlsim Studio

- Studio runs workloads through the `sqlsim` and `sqlpysim` engines above, so their driver policy applies to workload execution.
- Studio uses `Microsoft.Data.SqlClient` 7.1.0 only to collect Query Store statistics. It is compiled into the self-contained Studio executable; users do not install it.
- The Windows x64 Studio full GUI suite passed 91/91 on 2026-10-12 against SQL Server 17.0.4085.5.
- `Microsoft.Data.SqlClient` updates are taken by rebuilding Studio and rerunning its full suite; they ship only in a new Studio release.

## Newer Driver Versions

sqlsimtools targets driver families, not specific builds. `sqlsim` requests
`ODBC Driver 18 for SQL Server` by name and supports any 18.x release at or
above the 18.0 floor. `sqlpysim` supports `mssql-python` 1.x.

Newer releases within those families are expected to work and are generally safe
to use, but only the versions listed under Current Baseline have been validated
by this project. Until a newer version appears in that list, treat it as
supported on a best-effort basis: it is not blocked, and it has not been tested
here. Report a regression as a GitHub issue and include the exact driver version.

A new major driver version, such as a future ODBC Driver 19 or `mssql-python`
2.x, is unsupported until it is validated and recorded here.

Because these tools measure performance, the client driver is part of the
measurement environment. `sqlsim` records `odbc_driver_version` in its JSON
output and `sqlpysim` reports the `mssql-python` version it loaded. Pin your
driver version for any comparison you intend to keep. sqlsim Studio Compare and
`comparison-report.ps1` show a driver difference as an informational
difference: they still compare the runs, but a driver change can explain part
of any performance change and should be held constant when it is not what you
are testing.

## Validation Matrix for Releases

Before tagging a release:

1. Validate `sqlsim` with ODBC Driver 18 latest GA against:
   - SQL Server 2022
   - Azure SQL Database
   - Windows x64 and Ubuntu x64
   - Windows auth modes: `-E`, interactive `-A`, `-T`, `-U/-P`
   - Ubuntu auth modes: Kerberos `-E`, `ActiveDirectoryIntegrated`, `ActiveDirectoryMsi` where available, `ActiveDirectoryServicePrincipal`, `-T`, and `-U/-P`
   - Confirm bare `-A` / `ActiveDirectoryInteractive` is rejected on Ubuntu because the ODBC driver supports it only on Windows
2. Validate `sqlpysim` with latest `mssql-python` 1.x against:
   - SQL Server 2022
   - Azure SQL Database
   - Windows x64 and Ubuntu x64
   - Windows auth modes: `-E`, `-A`, `-T`, `-U/-P`
   - Ubuntu auth modes: `-T` and `-U/-P`. Linux `-E` requires a domain-joined Kerberos host and is outside the supported matrix.
   - Confirm `-querystats` reports non-zero logical reads and consistent totals on each platform

## Automated Update Monitoring

The `Driver update monitor` workflow runs every Monday and can also be dispatched manually.

1. `release/check-driver-updates.ps1` compares `.github/driver-versions.json` with:
   - Windows ODBC Driver 18 from winget.
   - Ubuntu ODBC Driver 18 from `packages.microsoft.com`.
   - macOS ODBC Driver 18 from Microsoft's Homebrew formula.
   - `mssql-python` from PyPI JSON metadata.
2. Only drivers with changed versions run their platform-specific offline smoke job.
3. The workflow opens or updates one issue with detected versions and smoke results, assigned to a maintainer for notification.
4. A human reviews release notes and runs the live authentication/performance matrix before updating tracked versions.
5. Record any failures or regressions on that issue until they are resolved.

Manual validation of the workflow can set `force_smoke: true` to run every smoke job without filing an issue when upstream versions still match the tracked versions.

## Update Cadence

- Revalidate when a new Microsoft ODBC Driver GA is published.
- Revalidate when `mssql-python` publishes a new minor release.
- At minimum, run a monthly review of available driver updates.

## CI Scope

Current CI workflows perform offline sanity checks only because hosted runners do not provide live SQL targets.

- `sqlsim CI`: Windows and Ubuntu x64 builds + offline smoke + PowerShell linting.
- `sqlpysim CI`: dependency install, dependency and source security audit, offline unit tests, and offline smoke (`-h` / `--version`) on Windows and Ubuntu x64.

Live connection/authentication regression tests remain a manual pre-release gate.

## Release Notes Requirement

Every release calls out the validated driver versions. The release workflow
generates a **Validated client drivers** section in the draft GitHub Release
from `.github/driver-versions.json` and the Studio project file:

- `sqlsim`: ODBC Driver 18 version for Windows and Ubuntu.
- `sqlpysim`: `mssql-python` version.
- sqlsim Studio: `Microsoft.Data.SqlClient` version.

Update `.github/driver-versions.json` only after the live validation above
passes, so the release body never claims an untested version.
