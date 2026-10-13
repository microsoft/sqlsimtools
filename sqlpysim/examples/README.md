# sqlpysim Examples

Ready-to-run SQL files, workloads, and scripts for sqlpysim. The layout matches
sqlsim's examples, and each folder has its own README.

| Folder | Contents |
| --- | --- |
| [sql/](sql/README.md) | T-SQL files for `-i`: a catalog query that works anywhere, eight AdventureWorksLT workloads, and a managed identity setup script |
| [workload/](workload/README.md) | Workload JSON definitions for `-workload` |
| [powershell/](powershell/README.md) | Scripts that run the SQL files with common authentication and load patterns |
| [github-actions-ci/](github-actions-ci/README.md) | Community guide, contributed by Aaryabrat Chhatkuli: run sqlpysim as a workload gate in GitHub Actions. A written walkthrough with inline YAML and scripts, not runnable files |

**Naming:** any example that needs the AdventureWorksLT sample database ends in
`-adventureworkslt`, for example `sql/08-mixed-workload-adventureworkslt.sql`.
Everything else runs against any database.

For HTML reports, use the sqlsim report scripts in `sqlsim/examples/reports/`.
They read sqlsim JSON; sqlpysim JSON is not guaranteed to match field for field.

## Prerequisites

- Python 3.10 or later with the pinned requirements installed:
  `python -m pip install -r requirements.txt` in the `sqlpysim` folder.
- PowerShell 5.1 or later for the scripts. They call `python`, so activate the
  environment where you installed the requirements first.
- Azure CLI, only for the access-token (`-T`) examples against Azure SQL.
- The AdventureWorksLT sample database, only for the `-adventureworkslt`
  examples. See
  [AdventureWorks sample databases](https://learn.microsoft.com/sql/samples/adventureworks-install-configure).

The AdventureWorksLT queries compute `TotalDue` and `LineTotal` inline so they
also work in SQL database in Fabric, where those computed columns may be
missing.

## Quick Start

Run these from the `sqlpysim` folder. `-C` trusts the server certificate, which
a local SQL Server usually needs.

```powershell
# Connectivity check on localhost (no -S needed)
python sqlpysim.py -E -C -Q "SELECT @@VERSION"

# A SQL file that works on any database
python sqlpysim.py -S localhost -E -C -i examples\sql\01-simple-queries.sql

# AdventureWorksLT load test: 10 threads x 100 iterations, quiet
python sqlpysim.py -S localhost -d AdventureWorksLT -E -C -i examples\sql\08-mixed-workload-adventureworkslt.sql -n 10 -r 100 -q

# A workload that works on any database
python sqlpysim.py -S localhost -d tempdb -E -C -workload examples\workload\workload-basic.json -q

# Azure SQL with an access token read from stdin
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$token | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -i examples\sql\01-simple-queries.sql

# JSON output parsed in PowerShell
$result = python sqlpysim.py -E -C -Q "SELECT 1" -json | ConvertFrom-Json
$result.metrics.total_runtime_seconds

# Scripts
.\examples\powershell\localhost-simple-test.ps1
.\examples\powershell\run-basic-tests-adventureworkslt.ps1
```

On Linux, use `python3` and forward slashes.

## Notes

- All SQL files are read-only except `07-insert-test-adventureworkslt.sql`,
  which inserts into a temporary table and cleans up.
- Scale threads (`-n`) and iterations (`-r`) to your system, and do not load
  test a shared or production server.