# Copilot Instructions — sqlsimtools (umbrella repo)

This is the **umbrella repository** for a family of independent SQL Server
testing / benchmarking tools. Each tool lives in its own top-level folder
and ships with its own build, test, publish, and Copilot guidance. The
root only owns cross-tool documentation, the release packager, and shared
agent customization.

> When the user is working inside a specific tool's subfolder, prefer
> that tool's `.github/copilot-instructions.md` over this file. This file
> is the contract for cross-cutting / multi-tool work.

## Repository layout

```
sqlsimtools/
├── README.md, PROJECT-GUIDE.md     # front page and project overview
├── INSTALL.md, BUILDING.md         # released-package install; build, test, and release from source
├── USING-WITH-AGENTS.md            # skills, Agent Plugins, and the Workload Builder
├── RELEASE-NOTES.md, BACKLOG.md    # known issues and preview status; working backlog
├── DRIVER-COMPATIBILITY.md         # validated driver versions
├── sqlsimtools.code-workspace      # VS Code workspace
├── assets/                         # shared logos, images, and demos
├── release/                        # bundle assembly, release staging, version check, package validation
├── scripts/                        # repository checks, plugin sync, local installs
├── .github/
│   ├── copilot-instructions.md     # this file (umbrella DEV contract)
│   ├── agents/sqlsimtools-workload-builder.agent.md # shared VS Code workload agent
│   ├── skills/<skill>/SKILL.md     # tool skills (USE) and repository build/release/test skills
│   ├── ISSUE_TEMPLATE/             # bug, feature, documentation, and Private Preview forms
│   ├── plugin/marketplace.json     # GitHub Copilot plugin marketplace
│   └── workflows/                  # CI and the Release workflow
├── .agents/plugins/marketplace.json # Codex marketplace
├── .claude-plugin/marketplace.json  # Claude Code and Grok marketplace
├── .cursor-plugin/marketplace.json  # Cursor marketplace
├── plugins/<tool>/                  # generated portable Agent Plugin packages
├── sqlsim/                          # C++ — SQL workload simulator
│   ├── .github/copilot-instructions.md # DEV: per-tool source-modification rules
│   └── AGENTS.md                       # USE: ships in release ZIP, agent contract
├── sqlpysim/                        # Python — sqlsim port on mssql-python
│   ├── .github/copilot-instructions.md # DEV
│   └── AGENTS.md                       # USE
└── sqlsimstudio/                    # .NET 10 — local browser studio
```

## The tools at a glance

| Tool | Language | Purpose | Folder |
|------|----------|---------|--------|
| `sqlsim` | C++ / ODBC | General SQL workload simulator & load tester | `sqlsim/` |
| `sqlpysim` | Python / mssql-python | Public Preview Python port sharing sqlsim's core workload interface | `sqlpysim/` |
| sqlsim Studio | .NET 10 / browser UI | Local app that configures, runs, monitors, replays, and compares sqlsim and sqlpysim workloads | `sqlsimstudio/` |

Agents are the fourth way to use the tools: the skills under
`.github/skills/` and the sqlsimtools Workload Builder agent ship in the
release packages. Future workload ideas (TPC-inspired transactional and
analytical workloads, vector search) are tracked in `BACKLOG.md`; none is in
active development.

All tools target SQL Server 2019/2022/2025, Azure SQL DB, Azure SQL MI,
and SQL database in Microsoft Fabric. All accept the same auth flags:
`-E` (Windows), `-A` (Entra), `-T <token>` (access token), `-U/-P` (SQL
auth).

## Working rules (apply to ALL tools in this repo)

### 1. Stay in the tool's folder
Each tool is independently buildable and publishable. When the user asks
to build, test, or run a tool, `cd` into that tool's folder first and use
**its own** `build.ps1`, `smoke-test.ps1`, `full-test-suite.ps1`, and
`publish.ps1`. Do not invoke `cmake`, `msbuild`, `python -m build`, or
ad-hoc compile commands directly.

### 2. Check the terminal context before running anything
Before running any build / test / `*.exe` command, inspect the current
terminal's `Last Command:` and `Exit Code:`. If the user already ran it
successfully, ask about the result instead of re-running.

### 3. No shell redirects in tool invocations
Do not append `2>&1`, `> file`, or `| Select-String` to tool commands. The
terminal already captures both streams, and filtering hides diagnostic
output. If you need to inspect output, capture it into a PowerShell
variable: `$out = .\build\Release\sqlsim.exe ...`.

### 4. JSON output is canonical
Each tool supports `-json` (or `--json`). Results files are JSON — parse
with `ConvertFrom-Json`, never by hand. When comparing runs, compute
deltas between phases, never cumulative values.

### 5. Authentication is required, every time
No tool defaults to an auth mode. Every command must include one of:
`-E`, `-A`, `-T <token>`, `-U <user> -P <password>`, or
`-c "<connstr>"` (where supported). For Azure SQL, prefer `-T` with a
token obtained via `az account get-access-token` to avoid interactive
popups on repeated runs.

### 6. Don't "improve" working code from memory
If a `SKILL.md`, a tool's `AGENTS.md` or `.github/copilot-instructions.md`,
or an existing working `.sql` / `.ps1` demonstrates a syntax, mirror it
exactly. Verify unfamiliar T-SQL / driver syntax against Microsoft Learn
before writing.

## Release / publish workflow

The authoritative release pipeline is `.github/workflows/release.yml` —
triggered by pushing a `v*.*.*` tag or manually via `workflow_dispatch` for RC
validation. Both paths build and validate every public asset. Manual dispatches
retain GitHub Actions artifacts only and cannot create a tag or release. Tag
pushes additionally attach the assets to a draft GitHub Release. sqlsim and
sqlpysim each ship as their own asset. sqlsim Studio ships only in
`sqlsimtools-<version>-win-x64.zip`, which `release/build-sqlsimtools-bundle.ps1`
assembles from the unchanged sqlsim x64 and sqlpysim archives plus Studio in
`sqlsimstudio/`.

**Nothing else triggers a release.** Routine commits, PR merges, and the
passage of time do not produce ZIPs. Publish cadence is fully manual.

```powershell
# Real release: tag and push. Workflow fires automatically.
git checkout main; git pull
git tag v1.0.1
git push origin v1.0.1
# Then click "Publish" in the GitHub Releases UI.

# RC validation: build Actions artifacts without creating a tag or release.
gh workflow run release.yml --repo microsoft/sqlsimtools --ref main `
    -f version=1.0.1-rc1
# Download and inspect the artifacts from the completed workflow run.
```

For ad-hoc local builds, `release/publish.ps1 -PublishAll` calls each
tool's own `publish.ps1` in sequence. Each tool stages its output under
its own folder; nothing is assembled at the root.

```powershell
# Local build of every tool (optional)
cd release; .\publish.ps1 -PublishAll

# Same, reusing existing binaries
cd release; .\publish.ps1 -PublishAll -SkipBuild
```

Individual tools also have their own `publish.ps1` for tool-only
releases.

## Branching & versioning (post-v1.0.0)

Default branch is `main` — it always reflects the latest released code.
Don't commit directly to it.

**Per-change flow:**

1. Branch off `main`: `git checkout main; git pull; git checkout -b <prefix>/<short-desc>`
   - Prefixes: `fix/` (bug), `feat/` (feature), `chore/` (deps/build/cleanup), `docs/`
   - One PR = one change. Don't bundle unrelated work.
2. Open PR `<branch> → main`. `sqlsim CI` runs automatically; PR cannot merge until green.
3. Merge to `main`. Squash-merge for small fixes; merge-commit when multiple commits are worth preserving.
4. Tag using **semver** (no `v` in the param, but the tag itself has `v`):

   | Change type | Bump | Example |
   |---|---|---|
   | Bug fix, no behavior change | **patch** | `v1.0.0` → `v1.0.1` |
   | New flag, backward-compatible | **minor** | `v1.0.1` → `v1.1.0` |
   | Breaking CLI / output change | **major** | `v1.1.0` → `v2.0.0` |

   Bump the version in the same PR before tagging: `sqlsim/include/version.h`,
   `sqlsim/CMakeLists.txt`, `sqlpysim/sqlpysim.py`, `sqlpysim/setup.py`, and
   `sqlsimstudio/server/SqlsimStudio.csproj`. The Release workflow's
   `verify-version` job fails when any of them differs from the tag; check with
   `./release/check-release-version.ps1 -Version v<X.Y.Z>`.

5. `git push origin v<X.Y.Z>` → Release workflow fires → click **Publish** in the UI.

**Before tagging real:** always do a `workflow_dispatch` dry run with
`-f version=<X.Y.Z>-rc1`, download and inspect the Actions artifacts, then tag
for real. The dispatch does not create a tag or GitHub Release. Verify archive
contents (`<tool>/AGENTS.md`, `.github/skills/<tool>/SKILL.md` present,
expected sizes).

**Hotfix flow:** identical — `git checkout -b fix/...` off `main`, PR,
merge, tag a patch.

**Don't backport** unless explicitly required. Single supported version
(latest tag) is the policy; maintaining parallel `v1.x` / `v2.x` lines
is out of scope.

## Continuous integration (non-release)

| Workflow | File | Fires on |
|----------|------|----------|
| `sqlsim CI` | `.github/workflows/sqlsim-ci.yml` | PR and push to `main` touching `sqlsim/**`, `release/**`, and related paths; also `workflow_dispatch` |
| `sqlpysim CI` | `.github/workflows/sqlpysim-ci.yml` | PR and push to `main` touching `sqlpysim/**`; also `workflow_dispatch` |
| `sqlsim Studio CI` | `.github/workflows/sqlsimstudio-ci.yml` | PR and push to `main` touching `sqlsimstudio/**` or the Studio skill; also `workflow_dispatch` |
| `Agent Plugins CI` | `.github/workflows/plugin-ci.yml` | PR and push to `main` touching skills, plugins, or marketplace files; also `workflow_dispatch` |
| `sqlsim macOS ARM64 Private Preview` | `.github/workflows/sqlsim-macos-arm64-private-preview.yml` | Push to `main` touching `sqlsim/**` or `release/**`; also `workflow_dispatch` |
| `Driver update monitor` | `.github/workflows/driver-update-monitor.yml` | Weekly on Monday (`cron`); also `workflow_dispatch` |
| `External PR policy` | `.github/workflows/external-pr-policy.yml` | `pull_request_target`; redirects external PRs to issues |
| `Release` | `.github/workflows/release.yml` | Tag push `v*.*.*`; also `workflow_dispatch` |

CodeQL runs through GitHub's default code-scanning setup rather than a
workflow file.

None of these workflows touches SQL Server: hosted runners have no live
target, so CI builds the tools and runs offline checks (help and version
output, unit tests, PSScriptAnalyzer, report tests, overlay-install tests,
Studio startup and browser layout tests). Live testing remains manual via each
tool's `smoke-test.ps1` / `full-test-suite.ps1`. The driver update monitor
checks for new ODBC Driver 18 and `mssql-python` releases, runs offline smoke
tests against them, and files an issue; the live validation it calls for is
manual.

## Reviewing incoming PRs (maintainer workflow)

When the user (maintainer) asks you to help review or merge a PR, walk
them through these gates in order — do not skip ahead.

**1. Triage checks (read-only, in browser or via `gh`):**

```powershell
gh pr view <N> --repo microsoft/sqlsimtools
gh pr checks <N> --repo microsoft/sqlsimtools
```

Verify:
- **CLA bot** check is green. Merge is blocked until signed.
- **`sqlsim CI`** is green (only runs on PRs touching `sqlsim/**`).
- PR description states which testing tier was run (per
  [`CONTRIBUTING.md`](../CONTRIBUTING.md): build + smoke required, full
  recommended, Azure left to maintainer).
- Scope is one tool / one change. If not, advise the user to ask the
  contributor to split.

**2. Diff review.** Read changed files. Flag in PR comments:
- Disabled tests, `--no-verify`, or CI workarounds → block.
- New dependencies without justification → ask.
- Whitespace-only sprawl outside touched lines → ask to scope.
- Behavior changes without doc updates (`<tool>.md`, `AGENTS.md`,
  `SKILL.md` as applicable) → ask.

**3. Local validation** for anything non-trivial:

```powershell
cd <repo-root>
gh pr checkout <N>          # works for fork PRs too
cd <tool>
.\build.ps1
.\smoke-test.ps1 -Server <yours> -Database <yours> -T <token>
# Maintainer runs the Azure tier the contributor couldn't:
.\full-test-suite.ps1 -Server <azure-sql> -Database <db> -T <token>
git checkout main           # or your working branch
```

Use `az account get-access-token --resource https://database.windows.net --query accessToken -o tsv`
for `-T` against Azure SQL.

**4. Verdict** via `gh`:

```powershell
gh pr review <N> --approve -b "LGTM, tested against <env>"
gh pr review <N> --request-changes -b "<reason>"
gh pr review <N> --comment -b "<question>"
```

**5. Merge** only when CLA + CI + review are all green:

- **Squash** for small / single-purpose PRs (default).
- **Merge commit** when multi-step history is worth preserving.
- **Never rebase-merge** — rewrites authorship, complicates `git log`.

```powershell
gh pr merge <N> --squash --delete-branch
```

Edit the squash commit message before confirming. Drop noise like
`Co-authored-by:` lines unless real co-authorship.

**6. Cut a release only if explicitly asked.** Routine PR merges do
NOT release. Follow the "Branching & versioning (post-v1.0.0)" section
above when the user says "ship this".

**Anti-patterns to refuse:**
- Approving without local validation when the change is non-trivial.
- Merging with red CI "because it's flaky" — fix or document the
  flake first.
- Bypassing branch protection via admin override.
- Closing/reopening a PR to re-run checks instead of investigating
  the failure.

## Copilot / agent customization files in this repo

The repo serves source developers, release-overlay users, and plugin users:

| File | Audience | Where it lives | Shipped in release ZIP? |
|------|----------|----------------|-------------------------|
| `.github/copilot-instructions.md` (root + per-tool) | Developer modifying this repo's source | Source tree only | No |
| `.github/skills/<tool>/SKILL.md` | Agent (VS Code Copilot skill system) deciding when/how to invoke a released tool | Source tree at root; copied to ZIP `.github/skills/<tool>/SKILL.md` by `publish.ps1` | Yes |
| `plugins/<tool>/` | Agent Plugin clients installing guidance from the `sqlsimtools` marketplace | Generated from the canonical `.github/skills/<tool>/SKILL.md` plus portable and client compatibility manifests | No; installed from the repository marketplace |
| `.github/plugin/`, `.agents/plugins/`, `.claude-plugin/`, `.cursor-plugin/` | GitHub Copilot, Codex, Claude/Grok, and Cursor marketplace clients | Source tree only | No |
| `.github/agents/sqlsimtools-workload-builder.agent.md` | VS Code users designing, validating, running, and comparing sqlsimtools workloads | Source tree at root; copied to both release ZIPs by `publish.ps1` | Yes |
| `<tool>/AGENTS.md` | Any agent (Claude Code, Cursor, Aider, Codex CLI, Copilot) operating in a user's project that uses the released tool | Source tree at `<tool>/AGENTS.md`; copied to ZIP `<tool>/AGENTS.md` by `publish.ps1` | Yes |

**Rule of thumb:** if it's about building / testing / not breaking the
source, it goes in `copilot-instructions.md`. If it's about invoking the
released binary, it goes in `AGENTS.md` (and the matching `SKILL.md`).
These must not overlap.

## Skills

Per-tool skill descriptors live at `.github/skills/<tool>/SKILL.md`. When
a user asks "how do I use <tool>?" or asks to perform a task that maps to
a specific tool, load that tool's `SKILL.md` first. The skill is the
entry point; the tool's `AGENTS.md` and `<tool>.md` user manual are the
authoritative deep references for *using* the tool, and the tool's
`.github/copilot-instructions.md` and `<tool>.md` are the authoritative
references for *modifying* the tool.

The copies under `plugins/<tool>/skills/<tool>/SKILL.md` are generated. After
editing a canonical skill, run `scripts/sync-plugins.ps1`, then run
`scripts/validate-plugins.ps1`. Do not edit generated plugin skill copies
directly. Agent Plugin packages contain guidance only; release ZIPs remain the
tool distribution and marketplace skills must not assume the plugin directory
contains a binary or Python runtime.

## What this repo is NOT

- Not a monorepo with shared build infrastructure — each tool builds
  independently.
- Not a place for new tools to land directly — new tools start in their
  own folder following the existing layout (`build.ps1`,
  `smoke-test.ps1`, `full-test-suite.ps1`, `publish.ps1`, `README.md`,
  `<tool>.md`, `examples/`, `.github/copilot-instructions.md`).
- Not licensed for third-party code without compatible licensing —
  everything ships under MIT.
