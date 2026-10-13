# Contributing

Thanks for your interest in contributing to **sqlsimtools**! This repository is an umbrella for independent SQL Server testing and benchmarking tools. The shipping command-line tools are `sqlsim` and `sqlpysim`, with sqlsim Studio as their local browser companion. Each tool lives in its own top-level folder with its own build, tests, and documentation.

During Public Preview, the project accepts GitHub issues but does not accept
external pull requests. Open an issue for reproducible bugs and scoped feature
requests. Use [GitHub Discussions](https://github.com/microsoft/sqlsimtools/discussions)
for questions, early proposals, platform testing interest, and new workload
ideas. Start with the [welcome discussion](https://github.com/microsoft/sqlsimtools/discussions/11).
This policy will be reconsidered after Public Preview.

## Contributor License Agreement

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>.

If external pull requests are accepted in the future, a CLA bot will automatically determine whether
you need to provide a CLA and provide the required instructions. You will only need to do this once
across all repositories using the CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Before you start

1. **Pick the right tool.** Each tool has its own `README.md`, deep user manual (`<tool>.md`), and `.github/copilot-instructions.md`. Read the tool-specific docs before opening an issue about that folder.
2. **Check existing issues and discussions.** Trackable work is on [Issues](https://github.com/microsoft/sqlsimtools/issues); questions and early ideas are in [Discussions](https://github.com/microsoft/sqlsimtools/discussions).
3. **Build and run the tool's smoke tests locally** before submitting. Every tool ships a `build.ps1`, `smoke-test.ps1`, and `full-test-suite.ps1`.

## Reporting issues

- **Security vulnerabilities** — do **not** open a public issue. Follow [SECURITY.md](SECURITY.md) to report to the Microsoft Security Response Center.
- **Bugs and feature requests** — open a [GitHub issue](https://github.com/microsoft/sqlsimtools/issues). Include the tool name, version (or commit), SQL Server flavor / version, repro steps, and full JSON output from the failing run when available.
- **Questions** — start a [Q&A discussion](https://github.com/microsoft/sqlsimtools/discussions/categories/q-a), or see [SUPPORT.md](SUPPORT.md).
- **New workload and design ideas** — start an [Ideas discussion](https://github.com/microsoft/sqlsimtools/discussions/categories/ideas) with the scenario, target SQL products, workload shape, success metrics, and expected output.
- **Private Preview access** — open a [Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml). Access is granted to your GitHub account; do not include contact or confidential details.

## Pull requests

External pull requests are not accepted during Public Preview. Please open an
Ideas discussion first so maintainers and users can refine a proposal. Use an
issue for an agreed, trackable defect or feature request. Maintainer pull
requests must target `main`, remain focused on one change, pass required CI,
include tests and documentation for behavior changes, and record the test
environment and results.

### Required testing for a PR

The bar scales with what the contributor can reach. Free-tier SQL Server Developer Edition or a container is enough for everything except the Azure-specific paths.

| Test | Who | Required? |
|---|---|---|
| `build.ps1` clean | Everyone | **Yes** |
| `smoke-test.ps1` against any SQL target you have (local, container, or Azure) | Everyone touching tool code | **Yes** |
| `full-test-suite.ps1` against that same local/container target | Anyone changing tool behavior or CLI surface | **Strongly recommended**; tests that target Azure-only behavior will SKIP automatically |
| `full-test-suite.ps1` against Azure SQL Database, Azure SQL Managed Instance, or SQL database in Microsoft Fabric | Maintainers | Not required of external contributors — a maintainer will re-run on Azure before merge or release |

Call out in the PR description which tier you ran and what (if anything) was skipped or failed. If a pull request changes behavior and reports no smoke run, reviewers will request one before review.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those
third-party's policies.
