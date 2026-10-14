# Frequently asked questions

- [General](#general)
- [Privacy and security](#privacy-and-security)
- [Using the tools](#using-the-tools)
- [How sqlsimtools compares](#how-sqlsimtools-compares)
- [Contributing and preview access](#contributing-and-preview-access)

## General

### What is sqlsimtools?

A family of tools for SQL workload engineering: building a repeatable workload,
running it under controlled concurrency, measuring it, and comparing runs. It
targets SQL Server 2019, 2022, and 2025, Azure SQL Database, Azure SQL Managed
Instance, and SQL database in Microsoft Fabric. There are four ways to work:

- **sqlsim Studio**: a local browser app to configure, run, monitor, replay,
  and compare workloads.
- **sqlsim**: a native C++ command-line tool built on Microsoft ODBC Driver 18.
- **sqlpysim**: a Python command-line tool built on Microsoft's `mssql-python`
  driver, in Public Preview.
- **AI agents**: skills, Agent Plugins, and the Workload Builder agent let
  GitHub Copilot and other agents design, run, and compare workloads for you.

### Is it a Microsoft product? Is it supported?

No. sqlsimtools is an open-source project, not an official Microsoft product.
It is provided as-is under the MIT license and is not covered by Microsoft
commercial support. Help is available through the documentation,
[GitHub Issues](https://github.com/microsoft/sqlsimtools/issues), and
[Discussions](https://github.com/microsoft/sqlsimtools/discussions). See
[SUPPORT.md](SUPPORT.md).

### What does it cost?

Nothing. All tools are free under the [MIT license](LICENSE).

### Which platforms are supported?

| Tool | Public Preview | Private Preview (invitation only) |
| --- | --- | --- |
| sqlsim | Windows x64 and ARM64, Ubuntu 24.04/26.04 x64 | macOS ARM64 |
| sqlpysim | Windows x64 and ARM64, Ubuntu 24.04/26.04 x64 | macOS ARM64 |
| sqlsim Studio | Windows x64 | Ubuntu x64, Windows ARM64, macOS ARM64 |

To test a Private Preview platform, open a
[Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml).

### Which tool should I start with?

- Start with **sqlsim Studio** if you want a visual workflow, live monitoring,
  and side-by-side comparison of runs.
- Use **sqlsim** for scripts, automation, CI pipelines, the lowest client
  overhead, and replay of Extended Events captures.
- Use **sqlpysim** when you work in Python or want to exercise the
  `mssql-python` driver.
- Ask **an agent** to design and run a workload in plain language.

The [README](README.md#get-started) has a download table and a first run for
each.

## Privacy and security

### Does sqlsimtools collect any data about me or my databases?

No. sqlsim, sqlpysim, and sqlsim Studio do not collect telemetry or usage data
and do not send anything to Microsoft or any other service. The only network
connections they make are to the SQL target you specify, plus the Microsoft
Entra sign-in that the Microsoft drivers perform when you choose Entra
authentication. sqlsim Studio runs only on your computer, on a loopback
address that other machines cannot reach.

Anything you choose to post in an issue or discussion is public, and GitHub's
own privacy terms apply to it. Never post credentials, server names, customer
data, or other sensitive information.

### Where are my passwords and access tokens stored?

Nowhere. The command-line tools accept secrets on standard input (`-P -` and
`-T -`) so they do not appear in the process list, and verbose output masks
them. sqlsim Studio holds a secret in memory only for the duration of a run and
passes it to the engine on standard input. It is never placed on a command
line, written to a log, kept in browser storage, or included in a saved
configuration.

### What does sqlsim Studio save on my computer?

- `settings.json`, holding only your theme choice, under
  `%LOCALAPPDATA%\sqlsimstudio` on Windows.
- Files you choose to save, such as configurations, results, and comparison
  exports, in the location you pick. Configurations never contain secrets, but
  they do contain query text and server and database names as plain text, so
  protect them accordingly.

### Is it safe to run against production?

It runs the SQL you give it, at the concurrency you ask for. Start against a
test or development server and scale threads and iterations gradually. Do not
load test a shared or production server without the owner's agreement. All
included examples are read-only except `07-insert-test-adventureworkslt.sql`,
which inserts into a temporary table and cleans up after itself.

### Does sqlsim validate the server certificate?

Not by default, matching `sqlcmd` (Go): with neither `-N` nor `-C`, the server
certificate is not validated. For Azure SQL and any connection that leaves your
computer, pass `-N m` or `-N s`. See
[RELEASE-NOTES.md](RELEASE-NOTES.md#certificate-validation-is-off-unless-you-ask-for-it).

### How do I report a security vulnerability?

Report it privately to the Microsoft Security Response Center as described in
[SECURITY.md](SECURITY.md), not in a public issue. Every repository in the
Microsoft GitHub organization follows this process, and a public report could
expose people running the tools before a fix is available. Ordinary bugs,
including credential-handling mistakes that are not exploitable, can be filed
as regular issues.

### Why does Windows warn me when I run the tools?

The release files are not code signed, so Windows marks the download as coming
from the internet. If you trust the download, unblock the ZIP before you
extract it: right-click it, choose **Properties**, select **Unblock**, and click
**OK**, or run `Unblock-File` in PowerShell. See [INSTALL.md](INSTALL.md).

## Using the tools

### Do I need the AdventureWorksLT sample database?

Only for some examples. Any example that needs it ends in `-adventureworkslt`,
for example `08-mixed-workload-adventureworkslt.sql`. Everything else works
against any database. See the
[AdventureWorks installation guide](https://learn.microsoft.com/sql/samples/adventureworks-install-configure).

### Which drivers do I need?

sqlsim and sqlsim Studio need Microsoft ODBC Driver 18 for SQL Server on the
computer. sqlpysim installs `mssql-python` from its `requirements.txt`, which
brings its own copy of the ODBC driver. The validated versions are listed in
[DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md).

### Do sqlsim and sqlpysim behave the same?

They share the core command-line interface and workload format, but sqlpysim is
in Public Preview and does not yet have full sqlsim CLI or output
compatibility. See
[RELEASE-NOTES.md](RELEASE-NOTES.md#sqlpysim-does-not-yet-have-full-sqlsim-cli-or-output-compatibility).

### Can I use it in a CI pipeline?

Yes. sqlsim and sqlpysim write canonical JSON results with `-json`, return a
non-zero exit code on failure, and read secrets from standard input. The
[GitHub Actions guide](sqlpysim/examples/github-actions-ci/README.md) shows a
complete workload gate.

### How do I use it with GitHub Copilot or another agent?

See [USING-WITH-AGENTS.md](USING-WITH-AGENTS.md). Release packages include the
skills and the Workload Builder agent, and Agent Plugins are available from
this repository's marketplace.

## How sqlsimtools compares

### How is this different from ostress, SqlQueryStress, HammerDB, or WorkloadTools?

They are all good tools, and the right choice depends on the job.

| Tool | Best known for |
| --- | --- |
| **ostress** (RML Utilities) | Mature, long-standing command-line stress and replay tool from Microsoft |
| **SqlQueryStress** | Quick, simple multi-user stress of a single query from a Windows GUI |
| **HammerDB** | Standard TPC-C and TPC-H style benchmarks across many database platforms |
| **WorkloadTools** | Capturing, analyzing, and replaying real SQL Server workloads |

sqlsimtools focuses on your own workload, run the same way four ways: one
workload format and one JSON result format shared by a GUI, a native CLI, a
Python CLI, and AI agents. It is built for Azure SQL and SQL database in Fabric,
with Microsoft Entra and access-token authentication, runs on Windows and Linux,
and includes live query statistics, side-by-side comparison of runs, and
Extended Events replay with outcome comparison.

For a detailed comparison with ostress, see
[sqlsim vs ostress](sqlsim/sqlsim.md#sqlsim-vs-ostress---whats-different).

### Does it replace SQL Server Distributed Replay?

Partly. Distributed Replay is deprecated and is not available for SQL Server
2022 and later. sqlsim replays Extended Events captures in `fast` or `stress`
mode and compares the outcome with the original; sqlsim Studio can do the same.
It does not reproduce Distributed Replay's multi-machine controller model.

## Contributing and preview access

### Can I contribute code?

Not yet. During Public Preview the project accepts issues but not external pull
requests, while interfaces, packaging, and tests stabilize. Pull requests from
outside the maintainer team are closed automatically with a pointer to Issues.
Bugs, feature requests, and documentation problems are welcome as
[issues](https://github.com/microsoft/sqlsimtools/issues/new/choose), and
questions and ideas in
[Discussions](https://github.com/microsoft/sqlsimtools/discussions). See
[CONTRIBUTING.md](CONTRIBUTING.md).

### How do I get Private Preview access?

Open a
[Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml).
Access is granted to your GitHub account. A request records interest; it does
not guarantee access or a release date.

### How was sqlsimtools built?

The code, scripts, tests, documentation, workload agent, and Studio experience
were developed with GitHub Copilot in Visual Studio Code and reviewed through
repeatable builds, security analysis, and live SQL validation. The test suites
run against live SQL targets, and every release is built and checked by the
release workflow in this repository.
