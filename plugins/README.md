# Agent Plugin packages

This directory contains portable Agent Plugin packages for sqlsim and
sqlpysim. The packages provide agent guidance only; they do not contain the
tools' binaries or Python runtime.

| Package | Guidance |
| --- | --- |
| [`sqlsim/`](sqlsim/) | Running native sqlsim workloads |
| [`sqlpysim/`](sqlpysim/) | Running mssql-python-based sqlpysim workloads |

Each package contains the Agent Plugins manifest, client compatibility
manifests, a package README, and a generated copy of its canonical skill.

## Source of truth

Canonical skills live under [`../.github/skills/`](../.github/skills/).
The files under `plugins/<tool>/skills/<tool>/` are generated and must not be
edited directly.

After changing a canonical sqlsim or sqlpysim skill, run:

```powershell
.\scripts\sync-plugins.ps1
.\scripts\validate-plugins.ps1
```

Repository marketplace descriptors live in:

- [`../.github/plugin/marketplace.json`](../.github/plugin/marketplace.json)
- [`../.agents/plugins/marketplace.json`](../.agents/plugins/marketplace.json)
- [`../.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json)
- [`../.cursor-plugin/marketplace.json`](../.cursor-plugin/marketplace.json)

Release ZIPs remain the tool distribution. Installing a plugin does not install
`sqlsim.exe`, sqlpysim, sqlsim Studio, ODBC drivers, or Python dependencies.
