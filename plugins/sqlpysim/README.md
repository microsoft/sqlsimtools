# sqlpysim Agent Plugin

Portable [Agent Plugins 1.0](https://agent-plugins.org/specification) package
that teaches compatible agents to run SQL Server workloads with `sqlpysim`.

The plugin supplies guidance only. Install a
[sqlpysim release](https://github.com/microsoft/sqlsimtools/releases) in the
workspace and install its Python requirements before running a workload.

## Install

- GitHub Copilot CLI: `copilot plugin install sqlpysim@sqlsimtools` after `copilot plugin marketplace add microsoft/sqlsimtools`.
- Claude Code: `/plugin install sqlpysim@sqlsimtools` after `/plugin marketplace add microsoft/sqlsimtools`.
- VS Code: add `microsoft/sqlsimtools` to `chat.plugins.marketplaces`, then search Extensions for `@agentPlugins sqlpysim`.
- Codex: `codex plugin add sqlpysim@sqlsimtools` after `codex plugin marketplace add microsoft/sqlsimtools --ref main`.
- Any Agent Skills client: copy `skills/sqlpysim/` into a supported skill directory.

The package contains one skill: `sqlpysim`.