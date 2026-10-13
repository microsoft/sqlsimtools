# sqlsim Agent Plugin

Portable [Agent Plugins 1.0](https://agent-plugins.org/specification) package
that teaches compatible agents to run SQL Server workloads with `sqlsim`.

The plugin supplies guidance only. Install a
[sqlsim release](https://github.com/microsoft/sqlsimtools/releases) in the
workspace or make `sqlsim` available on `PATH` before running a workload.

## Install

- GitHub Copilot CLI: `copilot plugin install sqlsim@sqlsimtools` after `copilot plugin marketplace add microsoft/sqlsimtools`.
- Claude Code: `/plugin install sqlsim@sqlsimtools` after `/plugin marketplace add microsoft/sqlsimtools`.
- VS Code: add `microsoft/sqlsimtools` to `chat.plugins.marketplaces`, then search Extensions for `@agentPlugins sqlsim`.
- Codex: `codex plugin add sqlsim@sqlsimtools` after `codex plugin marketplace add microsoft/sqlsimtools --ref main`.
- Any Agent Skills client: copy `skills/sqlsim/` into a supported skill directory.

The package contains one skill: `sqlsim`.