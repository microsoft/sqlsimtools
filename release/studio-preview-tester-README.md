# sqlsim Studio Private Preview tester kit

**Private Preview - testing only.** Ubuntu 24.04/26.04 LTS x64 and Windows 11
ARM64 remain experimental, unsupported production platforms. Passing tests does
not promote either platform. To participate or request preview testing
assistance, open a [Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml).
Use your existing request issue if you already have one.

The kit contains self-contained Studio, matching native sqlsim, sqlpysim source,
examples, manuals, canonical Studio suites, and a reporting runner. No source
checkout, compiler, or .NET installation is needed. Extract into a new writable
folder, not over an existing project. `BUILD-INFO.json` records the runtime,
commit, and Actions build. Do not mix files from different candidates.

## Setup

Install PowerShell 7 and **native target-architecture Python 3.11 or later**.
Windows ARM64 needs ARM64 Python, not an emulated x64 installation. The pinned
driver has a native ARM64 wheel. Keep the virtual environment active for tests
and interactive Studio launch.

On Ubuntu, install PowerShell using
[Microsoft's Ubuntu instructions](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu),
and install Python/venv and runtime prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv unixodbc libltdl7 libkrb5-3 libgssapi-krb5-2
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ./sqlsimstudio/sqlpysim/requirements.txt
pwsh -NoProfile -File ./run-tests.ps1 -Tier Offline -Python python
```

On Windows ARM64, install PowerShell 7 and ARM64 Python, then from the extracted
kit root in PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\sqlsimstudio\sqlpysim\requirements.txt
pwsh -NoProfile -File .\run-tests.ps1 -Tier Offline -Python .\.venv\Scripts\python.exe
```

The offline tier checks native Python/driver imports, both engines' help/version,
Studio startup, and the full offline API/lifecycle suite. It does not use your
SQL target; rejection probes can use a reserved unreachable address. Each check
has a five-minute limit; timeout kills its process tree and fails the run.

For live native sqlsim/Studio use, install **ODBC Driver 18 matching your OS and
architecture** using Microsoft's [Linux](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server)
or [Windows](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server)
instructions. Windows ARM64 needs the ARM64 driver. Driver, TLS, authentication,
permissions, and SQL target differences remain part of preview testing.

If Windows blocks an unsigned executable, report the exact message and stop.
Do not disable SmartScreen, antivirus, or other security controls.

## Interactive first test

From the kit root, launch `./sqlsimstudio/sqlsimstudio` on Ubuntu, or
`.\sqlsimstudio\sqlsimstudio.exe` on Windows. Studio runs locally in your browser.
For Windows Python selection, set `$env:SQLSIM_STUDIO_PYTHON_PATH` to the absolute
path of `.venv\Scripts\python.exe` before launch. On Ubuntu, keep the venv active.
No .NET runtime installation is required.

Use a dedicated non-production database you are authorized to test. Try
connection, `SELECT 1` with one thread and one iteration, results, then a small
included example and cancellation. Repeat with both engines if convenient.
Examples and manuals are under `sqlsimstudio/`. Use Studio's Shut down control
when finished. Installation/browser/manual testing is not established by CI.

## Optional live suites

Smoke/full suites are optional, not required for initial feedback. They can
create test objects, generate concurrent connections, and require catalog or
statistics permissions. Full suites can create/drop named test objects and
exercise load/error paths. Never use a database containing valuable data.

Create a restricted local file containing only the password or access token on
the first line. Keep it outside the kit/results and never attach it to an issue.
On Unix restrict access with `chmod 600`; on Windows restrict its file ACL to
your account. Never put the secret itself in process arguments.

For SQL authentication, use the runner's `-Tier Smoke -Server HOST -Database DB
-Username USER -PasswordFile PATH -AllowLiveTests` options. For Azure SQL, use
`-TokenFile PATH` instead of username/password and obtain a fresh database access
token. Keep the same `-Python` selection used for offline checks. On Ubuntu,
start with access-token rather than interactive Entra authentication.

To opt into full suites, use `-Tier Full -AllowLiveTests -AllowLoadTests` with
the same explicit target/authentication. Full first runs smoke, then full.
Feature/permission skips and failures must be reported rather than hidden.
These canonical suites remain unverified against a live target on the preview
platforms until results are recorded. Integrated and other authentication modes
can be exercised manually in Studio; the runner accepts SQL auth or tokens.

## Results and feedback

Once argument/platform validation has passed, a run creates
`results/<timestamp>-<id>/results.json` plus separate stdout/stderr logs. Failed
prerequisites/suites still produce a failure report and a nonzero exit.
`-ReportDirectory PATH` selects a new report directory. The kit uploads nothing.

Reply in your existing request issue with chip, OS version, browser, build
commit, engine, tier, target product/version and authentication mode, plus what
passed/failed/skipped and sanitized reproduction steps. Remove credentials,
tokens, private hostnames, credential-bearing connection strings, SQL/customer
data, and result rows before sharing reports. Report vulnerabilities privately
under the [security policy](https://github.com/microsoft/sqlsimtools/security/policy).

Maintainers own the repeatable native build and extracted-kit offline gates.
Live SQL, clean-machine installation, actual browsers, authentication coverage,
signing/distribution decisions, and explicit promotion approval are still
required; volunteer feedback supplements rather than replaces those gates.
