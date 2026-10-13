# Using sqlsimtools with agents

sqlsimtools separates the program that runs a workload from the guidance that
helps an AI agent use it correctly.

| Component | What it provides | Does it include the runtime? |
| --- | --- | --- |
| `sqlsim`, `sqlpysim`, or Studio release | Runtime, manuals, and matching workspace guidance | Yes |
| Agent Plugin | Reusable sqlsim or sqlpysim guidance installed in an agent client | No |
| Workspace skill | Automatic tool-specific guidance under `.github/skills/` | No |
| Workload Builder | A VS Code custom agent for designing, validating, running, and comparing experiments | No |
| `<tool>/AGENTS.md` | Portable instructions for agents working inside the installed tool directory | No |

The plugin and agent files never replace the executable or Python runtime.
Install the tool first, or extract a release package that contains it.

## Choose an installation path

### Release package in one project

This is the easiest path for a project that needs sqlsimtools.

1. Download the matching archive from
   [GitHub Releases](https://github.com/microsoft/sqlsimtools/releases).
2. Extract it at the root of your project.
3. Open the project in your agent client. VS Code usually discovers the skill
   and Workload Builder automatically; if either does not appear in chat, run
   **Developer: Reload Window**.

A sqlsim archive produces a layout similar to:

```text
your-project/
|-- .github/
|   |-- agents/sqlsimtools-workload-builder.agent.md
|   `-- skills/sqlsim/SKILL.md
`-- sqlsim/
    |-- AGENTS.md
    |-- examples/
    `-- x64/sqlsim.exe
```

The Linux archive uses `sqlsim/x64/sqlsim` without the `.exe` extension. The
sqlpysim archive uses `.github/skills/sqlpysim/SKILL.md` and
`sqlpysim/sqlpysim.py`. You can extract both archives into the same project.

The sqlsimtools package includes `.github/skills/sqlsimstudio/SKILL.md` for
general released-product guidance, beside the sqlsim and sqlpysim skills and
the Workload Builder. Studio's manual-test and load-test skills remain
source-repository workflows and are not substitutes for the released-product
skill.

No separate plugin installation is required for VS Code to discover the
workspace skill and Workload Builder included in the archive.

### Tool on PATH plus an Agent Plugin

Use this path when the runtime is already available on `PATH` and you want the
guidance available across many projects.

The sqlsimtools marketplace contains two plugins:

| Plugin | Install coordinate | Use it for |
| --- | --- | --- |
| sqlsim | `sqlsim@sqlsimtools` | Native ODBC workloads and lowest client overhead |
| sqlpysim | `sqlpysim@sqlsimtools` | Python workloads and driver behavior comparisons |

Installing a plugin does not download sqlsim or sqlpysim.

## GitHub Copilot in VS Code

### Use the release-embedded Workload Builder

After extracting a release archive at the workspace root:

1. Open Chat in Agent mode.
2. Select **sqlsimtools Workload Builder** from the agent picker.
3. Describe the target, workload, authentication mode, and measurement goal.
4. Review the generated files and masked command preview.
5. Approve the exact command, target, and load level before execution.

Example requests:

```text
Create a four-thread read-only workload that runs queries.sql 50 times against
my local test database and saves JSON results.
```

```text
Compare sqlsim and sqlpysim with equivalent commands, then summarize latency
and throughput deltas from their saved JSON files.
```

The Workload Builder starts at one thread and one iteration when a load level is
not supplied. It does not run a workload until you explicitly approve the
command, target, and load level.

### Install the marketplace plugins

Enable Agent Plugins and register this repository in VS Code user settings:

```json
{
    "chat.plugins.enabled": true,
    "chat.plugins.marketplaces": [
        "microsoft/sqlsimtools"
    ]
}
```

In the Extensions view, search for `@agentPlugins sqlsim` or
`@agentPlugins sqlpysim`, then install the desired plugin.

## Command-line agent clients

### GitHub Copilot CLI

```powershell
copilot plugin marketplace add microsoft/sqlsimtools
copilot plugin marketplace browse sqlsimtools
copilot plugin install sqlsim@sqlsimtools
```

Use `copilot plugin install sqlpysim@sqlsimtools` for the Python tool. In an
interactive session, use `/plugin` to manage plugins and `/skills` to inspect
installed skills.

### Claude Code

```powershell
claude plugin marketplace add microsoft/sqlsimtools
claude plugin install sqlsim@sqlsimtools
```

### OpenAI Codex CLI

```powershell
codex plugin marketplace add microsoft/sqlsimtools --ref main
codex plugin list --marketplace sqlsimtools --available --json
codex plugin add sqlsim@sqlsimtools
```

## Other Agent Skills clients

The generated plugin packages are under `plugins/sqlsim/` and
`plugins/sqlpysim/`. Clients that support Agent Skills can copy the selected
`skills/<tool>/` directory into their documented skill root.

For clients that discover `AGENTS.md`, keep the release archive layout intact.
The file inside `sqlsim/` or `sqlpysim/` scopes guidance to that tool directory.

- Cursor: copy one `plugins/<plugin>/` directory to
  `~/.cursor/plugins/local/<plugin>/`, then reload Cursor.
- Grok Build: use `grok --plugin-dir <checkout>/plugins/sqlsim` for one session,
  or copy it to `~/.grok/plugins/sqlsim`.

## Authentication and execution safety

- Select exactly one authentication mode for every run.
- Never paste passwords, access tokens, or credential-bearing connection
  strings into chat.
- Prefer `-T -` or `-P -` with redirected standard input when credentials are
  required by automation.
- Use a dedicated test system for load tests.
- Review thread count, iterations, duration, SQL writes, and target database
  before approving execution.
- Compare equivalent completed runs and calculate phase deltas rather than
  comparing cumulative counters.

## Studio and agents

sqlsim Studio is a deterministic local browser application and does not embed
an AI assistant. The `sqlsimstudio` skill guides installation, launch,
configuration, authentication, workload execution, monitoring, results,
comparisons, and troubleshooting for a released package. Use the Workload
Builder in VS Code to author or review SQL and workload files, then run them
through Studio or the command line.

## Troubleshooting discovery

If an agent cannot find the tool:

1. Confirm the release was extracted at the workspace root rather than inside
   another wrapper directory.
2. Confirm `.github/skills/<tool>/SKILL.md` exists.
3. Confirm `.github/agents/sqlsimtools-workload-builder.agent.md` exists when
   using VS Code.
4. Confirm `sqlsim` or `sqlpysim` exists in the release overlay or on `PATH`.
5. Reload the workspace or restart the agent client after installing a plugin.

See [INSTALL.md](INSTALL.md) for runtime installation and
[BUILDING.md](BUILDING.md) for source builds.
