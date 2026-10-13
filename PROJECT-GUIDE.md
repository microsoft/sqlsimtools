# SQL Simulation Tools (sqlsimtools)

> [!TIP]
> Looking for the visual overview? Return to the [sqlsimtools front page](README.md).

SQL workload engineering tools for SQL Server, Azure SQL, and SQL database in Microsoft Fabric: native and Python workload engines, a local browser studio, and agent guidance. This guide is the project overview; it links to [INSTALL.md](INSTALL.md), [BUILDING.md](BUILDING.md), and [USING-WITH-AGENTS.md](USING-WITH-AGENTS.md) for the detailed steps.

**How these tools were built:** 100% of the code, scripts, and documentation was developed with GitHub Copilot in Visual Studio Code using various AI models, orchestrated by Bob Ward.

[Join the sqlsimtools Discussions](https://github.com/microsoft/sqlsimtools/discussions) for usage questions, design feedback, and new workload ideas. To test a Private Preview platform, open a [Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml). Start with the [welcome discussion](https://github.com/microsoft/sqlsimtools/discussions/13) for guidance on where to post.

## Tools overview

| Tool | Language | Description | Location |
| --- | --- | --- | --- |
| **sqlsim** | C++ / ODBC | General-purpose SQL query / workload simulator and load tester | [`sqlsim/`](sqlsim/) |
| **sqlpysim** | Python / mssql-python | Public Preview Python port sharing sqlsim's core query and workload interface; see [release limitations](RELEASE-NOTES.md) | [`sqlpysim/`](sqlpysim/) |
| **sqlsim Studio** | .NET 10 / browser UI | Local browser companion for configuring, running, monitoring, replaying, and comparing workloads | [`sqlsimstudio/`](sqlsimstudio/) — _v1.0 Public Preview: Windows x64; Private Preview: Ubuntu x64 / Windows ARM64 / macOS ARM64_ |

## Futures

Possible future workload simulators include:

| Idea | What it could measure |
| --- | --- |
| TPC-like transactional workloads | Independent commerce and order-processing patterns for concurrency, throughput, and transaction-latency experiments. These would not be TPC-compliant implementations or produce official benchmark results. |
| TPC-like analytical workloads | Independent decision-support query mixes for scan, join, aggregation, power, and throughput experiments. |
| Vector search simulator | Concurrent vector ingestion, index construction, filtered approximate search, exact-search baselines, recall, and latency. |

These are exploratory ideas, not committed roadmap items. Any benchmark-inspired
workload would use original schemas and scenarios and would report only its own
measured results.

Is there something you think should be part of sqlsimtools?
[File an issue](https://github.com/microsoft/sqlsimtools/issues/new/choose) and
tell us what you would want to measure with it.

## Backlog

**[Check out our current backlog](BACKLOG.md)** to see what is finished, what is
open, and what is under consideration — release-readiness gates, platform preview
decisions, and longer-term cross-tool ideas.

The backlog is a working document rather than a commitment. Entries are
reordered, rewritten, and dropped as priorities change, and an item appearing
there does not mean it is scheduled. To propose or follow specific work, open a
[GitHub issue](https://github.com/microsoft/sqlsimtools/issues) or start a
[discussion](https://github.com/microsoft/sqlsimtools/discussions).

## Platform support

All tools support:

- SQL Server 2019, 2022, 2025
- Azure SQL Database
- Azure SQL Managed Instance
- SQL database in Microsoft Fabric

## Prerequisites

- **Windows x64/ARM64** or **Ubuntu 24.04/26.04 LTS x64** for `sqlsim`
- **ODBC Driver 18 for SQL Server** — [Download](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server)
- **Python 3.10+** (for `sqlpysim` only)

The Linux release contains one native application binary, `x64/sqlsim` (Linux executables do not use the `.exe` extension). It does not require the source tree or a language runtime, but it is not a fully static binary: unixODBC and Microsoft ODBC Driver 18 must be installed on the target system. The Windows `sqlsim.exe` likewise requires Microsoft ODBC Driver 18.

Official Linux support is limited to **Ubuntu 24.04 LTS x64** and **Ubuntu 26.04 LTS x64**. Other Linux distributions may work when they provide compatible system libraries, unixODBC, and Microsoft ODBC Driver 18 packages, but they are currently untested and unsupported. Linux ARM64 is not currently supported.

Driver baseline and update cadence are tracked in [DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md).

## Quick start

The [front page](README.md#get-started) walks through the prerequisite, which
download to choose, and a first run with sqlsim Studio, sqlsim, sqlpysim, or an
agent. [INSTALL.md](INSTALL.md) covers every platform, verification, and
upgrades.

All tools share the same authentication flags: `-E` (Windows or Kerberos
integrated), `-A` (Microsoft Entra), `-T <token>` (access token), and `-U`/`-P`
(SQL authentication).

sqlsim Studio is a self-contained loopback application. It opens the user's
installed browser and serves embedded local assets. Its public Windows x64
release is the sqlsimtools package, which places Studio in `sqlsimstudio/`
beside the complete sqlsim x64 and sqlpysim packages that it runs as engines.
Ubuntu x64, Windows ARM64, and macOS ARM64 are controlled Private Preview
platforms for invited testers and are not included in public release assets.
The saved configuration file contract is documented in
[sqlsimstudio/CONFIGURATION.md](sqlsimstudio/CONFIGURATION.md).

## HTML reports

The sqlsim package ships four PowerShell report generators in
[`sqlsim/examples/reports/`](sqlsim/examples/reports/). They are self-contained
and need no internet access.

| Report | Purpose |
| --- | --- |
| `execution-report.ps1` | Overall execution summary from `-json` output |
| `comparison-report.ps1` | A/B comparison of two runs, with a configuration guardrail |
| `querystats-chart.ps1` | Per-query server CPU and I/O charts from `-querystats -json` |
| `live-querystats-dashboard.ps1` | Live auto-refreshing dashboard |

`comparison-report.ps1` takes two sqlsim JSON files, or a comparison exported
from the sqlsim Studio Compare view. It is the same report used for replay A/B
testing. Because it compares target, workload mode, load shape, and batch count,
it reports **Not comparable** rather than presenting a misleading verdict when
the two runs were not equivalent.

The reporting scripts ship with the sqlsim package, which is also included in
the sqlsimtools package, so they remain usable without Studio.

## Azure SQL — token authentication (recommended)

For repeated runs against Azure SQL, prefer access-token auth (`-T`) over interactive Entra (`-A`) to avoid login popups:

```powershell
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | .\sqlsim\x64\sqlsim.exe -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"
```

## Documentation

Start with the task-oriented guides:

- [Install a release package](INSTALL.md)
- [Build from source and publish versions](BUILDING.md)
- [Use sqlsimtools with plugins and agents](USING-WITH-AGENTS.md)

Each tool has comprehensive documentation:

| Tool | User manual | Build guide |
| --- | --- | --- |
| sqlsim | [sqlsim.md](sqlsim/sqlsim.md) | [BUILD.md](sqlsim/BUILD.md) |
| sqlpysim | [sqlpysim.md](sqlpysim/sqlpysim.md) | [BUILD.md](sqlpysim/BUILD.md) |
| sqlsim Studio | [sqlsimstudio.md](sqlsimstudio/sqlsimstudio.md) | [README.md](sqlsimstudio/README.md) |

Third-party software included in release packages is documented in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Agent Plugin marketplace

This repository is the installable `sqlsimtools` marketplace. It contains two
portable [Agent Plugins 1.0](https://agent-plugins.org/specification) packages
with compatibility descriptors for GitHub Copilot, Claude Code, Codex, Cursor,
and Grok Build.

| Plugin | Install coordinate | Version | Use it for |
| --- | --- | ---: | --- |
| [`sqlsim`](plugins/sqlsim/) | `sqlsim@sqlsimtools` | 1.0.0 | Native ODBC query, script, load-test, and workload guidance |
| [`sqlpysim`](plugins/sqlpysim/) | `sqlpysim@sqlsimtools` | 1.0.0 | Python and `mssql-python` workload guidance |

The plugins install agent guidance only. Install the matching tool from
[Releases](https://github.com/microsoft/sqlsimtools/releases), or make its
command available on `PATH`, before asking an agent to run a workload.
[Using sqlsimtools with agents](USING-WITH-AGENTS.md) has the install commands
for each client and explains release-embedded skills versus plugins.

## Building from source

[BUILDING.md](BUILDING.md) is the build guide. It covers cloning the
repository, building sqlsim on Windows and Ubuntu, preparing sqlpysim, building
sqlsim Studio, running the smoke and full test suites, installing a source
build into a project, and validating, versioning, and publishing releases.
Each tool builds independently with its own scripts.

## Releases

Releases are produced by the [Release workflow](.github/workflows/release.yml)
and published on [GitHub Releases](https://github.com/microsoft/sqlsimtools/releases).
Each release contains:

| Package | Contents |
| --- | --- |
| `sqlsimtools-<version>-win-x64.zip` | sqlsim Studio with the complete sqlsim x64 and sqlpysim packages |
| `sqlsim-<version>-win-x64.zip`, `-win-arm64.zip`, `-linux-x64.tar.gz` | sqlsim |
| `sqlpysim-<version>-src.zip` | sqlpysim |

Every package is also attached without the version in its name, so the
[front page](README.md#get-started) can link to the newest download. Users
should start with [INSTALL.md](INSTALL.md). Maintainers should follow
[BUILDING.md](BUILDING.md) for release-candidate dry runs, version bumps,
tagging, and publishing. Routine commits and merges never create a release;
only pushing a version tag does.

## Directory structure

```text
sqlsimtools/
├── README.md                        # visual repository front page
├── PROJECT-GUIDE.md                 # this project overview
├── INSTALL.md                       # install released packages
├── BUILDING.md                      # build, test, and release from source
├── USING-WITH-AGENTS.md             # skills, Agent Plugins, and the Workload Builder
├── RELEASE-NOTES.md                 # known issues and preview status
├── DRIVER-COMPATIBILITY.md          # validated driver versions
├── BACKLOG.md                       # working backlog
├── LICENSE, SECURITY.md, SUPPORT.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md
├── sqlsimtools.code-workspace       # multi-root VS Code workspace
├── assets/                          # logos, images, and the Studio demo GIF
├── .github/
│   ├── copilot-instructions.md      # repo-wide Copilot guidance for contributors
│   ├── agents/                      # sqlsimtools Workload Builder agent
│   ├── skills/<tool>/SKILL.md       # canonical per-tool agent skills
│   ├── ISSUE_TEMPLATE/              # bug, feature, documentation, and Private Preview forms
│   ├── plugin/marketplace.json      # GitHub Copilot marketplace index
│   └── workflows/                   # CI and the Release workflow
├── .agents/plugins/marketplace.json # Codex marketplace index
├── .claude-plugin/marketplace.json  # Claude Code and Grok marketplace index
├── .cursor-plugin/marketplace.json  # Cursor marketplace index
├── plugins/                         # portable Agent Plugins packages (generated skills)
├── scripts/                         # repository checks, plugin sync, and local installs
├── release/                         # bundle assembly, release staging, and package validation
├── sqlsim/                          # C++ — SQL workload simulator
├── sqlpysim/                        # Python — sqlsim port on mssql-python
└── sqlsimstudio/                    # .NET — local browser studio
```

Each tool folder has its own `README.md`, user manual, examples, and build and
test scripts; `sqlsim/` and `sqlpysim/` also have the `AGENTS.md` that ships in
their release packages.

## Contributing

During Public Preview, report reproducible bugs and scoped feature requests as
[GitHub issues](https://github.com/microsoft/sqlsimtools/issues). Use
[GitHub Discussions](https://github.com/microsoft/sqlsimtools/discussions) for
usage questions, early design feedback, and new workload ideas. To test a
Private Preview platform, open a
[Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml).

External pull requests are not currently accepted while the interfaces, tests,
and release process are stabilizing. The policy will be reconsidered after
Public Preview. GitHub does not provide a permanent setting to disable pull
request creation while keeping issues enabled, so external pull requests may
still be opened but will be closed with a reference to this policy.

Please read [SECURITY.md](SECURITY.md) before reporting security-sensitive
issues. Report those to the Microsoft Security Response Center, not through a
public GitHub issue.

This project welcomes contributions and suggestions. Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>.

If external pull requests are accepted in the future, a CLA bot will
automatically determine whether you need to provide a CLA and provide the
required instructions. You will only need to complete this once across all
repositories using the CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

See [CONTRIBUTING.md](CONTRIBUTING.md) for additional contribution guidance specific to this repository.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those third-party policies.

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

```text
Copyright (c) Microsoft Corporation.

Licensed under the MIT License. See the LICENSE file in this project for full terms.
```
