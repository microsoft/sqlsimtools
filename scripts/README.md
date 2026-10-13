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
