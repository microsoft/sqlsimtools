# Repository maintenance scripts

These scripts perform cross-tool repository checks and maintenance. They are
not shipped as part of sqlsim, sqlpysim, or sqlsim Studio.

Run them from the repository root:

| Script | Purpose |
| --- | --- |
| `check-engine-parity.ps1` | Checks shared sqlsim and sqlpysim command behavior |
| `check-suite-parity.ps1` | Confirms Windows and Linux test suites cover the same tests |
| `check-test-prerequisites.ps1` | Checks prerequisites used by repository test workflows |
| `ensure-adventureworkslt.ps1` | Verifies or prepares the AdventureWorksLT test database |
| `get-project-stats.ps1` | Reports release downloads, website click-throughs, 14-day repository traffic, and stars (`-Json` for automation) |
| `install-local.ps1` | Builds and safely installs selected tools into another workspace |
| `set-welcome-discussion.ps1` | Configures the repository welcome discussion |
| `sync-plugins.ps1` | Copies canonical public skills into generated plugin packages |
| `validate-plugins.ps1` | Validates skills, plugin manifests, generated copies, and marketplaces |

## Plugin maintenance

Canonical public skills live under [`../.github/skills/`](../.github/skills/).
After changing the `sqlsim` or `sqlpysim` skill, run:

```powershell
.\scripts\sync-plugins.ps1
.\scripts\validate-plugins.ps1
```

Do not edit generated skill copies under [`../plugins/`](../plugins/) directly.

## Project stats

`get-project-stats.ps1` needs the GitHub CLI signed in (`gh auth login`).
Repository traffic, including click-throughs from the GitHub Pages site, is
available only to accounts with push access and covers the last 14 days.
Release download counts are running totals for uploaded release files; GitHub
does not count the automatic source-code archives.

```powershell
.\scripts\get-project-stats.ps1
.\scripts\get-project-stats.ps1 -Json | ConvertFrom-Json
```

In VS Code chat, ask for project stats or type `/sqlsimtools-project-stats`.
The [`sqlsimtools-project-stats`](../.github/skills/sqlsimtools-project-stats/SKILL.md)
skill runs this script and summarizes the results, including changes since
numbers you provide.
