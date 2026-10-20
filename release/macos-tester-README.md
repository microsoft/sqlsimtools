# macOS ARM64 Private Preview tester kit

This is a self-contained test installation of sqlsim, sqlpysim, and sqlsim
Studio, plus their maintained test suites, examples, and fixtures. You do not
need a source checkout or to extract the three individual packages first.
Extract the kit into a new, writable folder; do not overlay an existing project.

The build commit and Actions run are in `BUILD-INFO.txt`. Use kits from one
successful run, not a mixture of different candidates.

## Requirements

- Apple Silicon, macOS 15 or later.
- Homebrew and PowerShell 7 (`pwsh`) for the test runner and Studio suites.
- Python 3.11 or later, OpenSSL, and the pinned Python driver for Python/Studio
  testing.
- Microsoft ODBC Driver 18 for live sqlsim/Studio tests.
- `coreutils` (provides `gtimeout`) for the native live smoke suite, and `jq`
  for the native full suite.

Install the test-runner dependencies:

```bash
brew install powershell python@3.11 openssl coreutils jq
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -r ./sqlpysim/requirements.txt
```

Install ODBC Driver 18 using the instructions in
`sqlsim/MACOS-PRIVATE-PREVIEW.md`. Studio's platform-specific launch and signing
limitations are in `sqlsimstudio/MACOS-PRIVATE-PREVIEW.md`. If macOS blocks an
executable, report the exact message; do not disable Gatekeeper or remove
quarantine recursively.

## 1. Offline checks first

From the extracted kit folder, with the Python environment activated:

```bash
pwsh -NoProfile -File ./run-tests.ps1 -Tier Offline -Python python
```

This runs the existing native macOS smoke checks, Python help/version and unit
tests, and Studio startup plus its full offline validation suite. No configured
database is contacted. Some native rejection tests probe a reserved,
unreachable address to validate error reporting.

Each offline check has a five-minute limit. A timeout stops that check's process
tree, fails the run, and records `timedOut: true` alongside its logs.

To test just one tool, add `-Tool sqlsim`, `-Tool sqlpysim`, or
`-Tool sqlsimstudio`. Python/Studio selections require the Python environment;
the native-only selection does not.

## 2. Live smoke tests

Only use a dedicated, non-production database you are authorized to test.
These are the repository's real suites, not a single-query demonstration:
even smoke tests can create test procedures/temporary objects, run dozens of
concurrent connections, and require catalog/statistics permissions. The native
smoke suite includes a 100-thread test. Non-Azure tests inherit the suites'
existing trust-server-certificate behavior. Review the suites before running
against your target.

Create a local credential file with only the password or access token on its
first line. Keep it outside the kit and its results folder, restrict access
(`chmod 600 /path/to/credential-file`), and never attach it to an issue. Do not
put the secret itself on the command line.

For SQL authentication:

```bash
pwsh -NoProfile -File ./run-tests.ps1 \
  -Tier Smoke -Tool sqlsim \
  -Server 'your-test-server,1433' -Database YourDedicatedTestDatabase \
  -Username YourTestUser -PasswordFile /path/to/password-file \
  -AllowLiveTests
```

For Azure SQL, use a fresh access token rather than Entra interactive sign-in:

```bash
pwsh -NoProfile -File ./run-tests.ps1 \
  -Tier Smoke -Tool sqlpysim -Python python \
  -Server your-test-server.database.windows.net -Database YourDedicatedTestDatabase \
  -TokenFile /path/to/access-token-file -AllowLiveTests
```

For Studio, substitute `-Tool sqlsimstudio -Python python`. Its smoke suite
tests both bundled engines, file and mixed workloads, results, and replay.
This does not replace manual Safari/Chrome/Edge/Firefox testing or Finder launch
validation. Follow the included example guides for interactive testing.

## 3. Optional full suites

Full suites are opt-in. They generate substantial load, exercise error paths,
and can create/drop named test objects. They must not be run against a database
containing valuable data. Feature/permission differences across SQL Server,
Azure SQL, and Fabric can produce failures or explicit skips; report these
instead of treating them as proof of a product bug.

Use the same target/authentication options as smoke, but select:

```text
-Tier Full -AllowLiveTests -AllowLoadTests
```

The sqlsim runner passes `--skip-scale` by default, excluding its 1024-thread
tests. To opt into those as well, add `-IncludeScale`; the rest of the full suite
still includes significant concurrency and performance checks without it.
The wrapper stops at the first failed suite, preserves its exit code in the
report, and exits nonzero. Individual suites retain their existing failure and
skip behavior; read their logs as well as the overall runner status.

The CLI Bash filenames retain `-linux.sh` because these are the same maintained
Unix suites, not divergent macOS copies. They run from the kit's installed
paths without compilation. Live execution on macOS remains unverified until
recorded against an actual SQL target.

## Reports and feedback

Each invocation creates a fresh `results/<timestamp>-<id>/` directory with
`results.json` plus separate stdout/stderr logs for each check. A failed run
still writes a JSON report. You can choose a new output directory with
`-ReportDirectory /path/to/new-results-directory`.

Reply in your existing Private Preview request issue with:

- Mac chip, macOS version, tool selection, and build commit.
- Tier and SQL target product/version (no private hostname needed).
- Authentication mode, not the credentials.
- What passed, failed, or was skipped.
- Sanitized report/log excerpts and reproduction steps.

The kit uploads nothing. Review all logs before attaching them: they can contain
server/database names, SQL text, result rows, and error details. Never share
passwords, tokens, credential files, credential-bearing connection strings, or
customer data. Report vulnerabilities privately under the repository's
[security policy](https://github.com/microsoft/sqlsimtools/security/policy).
