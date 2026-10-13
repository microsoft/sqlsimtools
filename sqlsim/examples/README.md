# sqlsim Examples

Ready-to-run SQL files, workloads, scripts, reports, and saved results for
sqlsim. Each folder has its own README.

| Folder | Contents |
| --- | --- |
| [sql/](sql/README.md) | T-SQL files for `-i`: a catalog query that works anywhere, eight AdventureWorksLT workloads, and a managed identity setup script |
| [workload/](workload/README.md) | Workload JSON definitions for `-workload` |
| [powershell/](powershell/README.md) | Scripts that run the SQL files with common authentication and load patterns |
| [reports/](reports/README.md) | HTML report generators for execution summaries, query statistics, A/B comparisons, and a live dashboard |
| [results/](results/README.md) | Saved before-and-after results from an index experiment, ready to compare |

**Naming:** any example that needs the AdventureWorksLT sample database ends in
`-adventureworkslt`, for example `sql/08-mixed-workload-adventureworkslt.sql`.
Everything else runs against any database.

## Prerequisites

- The sqlsim package for your platform, or a source build.
- Microsoft ODBC Driver 18 for SQL Server.
- PowerShell 5.1 or later for the scripts. All scripts run in Windows
  PowerShell 5.1 and PowerShell 7.
- Azure CLI, only for the access-token (`-T`) examples against Azure SQL.
- The AdventureWorksLT sample database, only for the `-adventureworkslt`
  examples. See
  [AdventureWorks sample databases](https://learn.microsoft.com/sql/samples/adventureworks-install-configure).

## Database Compatibility

The AdventureWorksLT examples work with:

- **SQL Server** - full AdventureWorksLT schema with computed columns
- **Azure SQL Database** - full AdventureWorksLT schema with computed columns
- **SQL database in Fabric** - AdventureWorksLT schema that may lack the
  computed columns `TotalDue` and `LineTotal`

### Computed Column Handling

Several queries (04, 05, 06, 08, 09) need `TotalDue` and `LineTotal`, which are
computed columns in the standard AdventureWorksLT schema:

- `TotalDue = SubTotal + TaxAmt + Freight` (in `SalesLT.SalesOrderHeader`)
- `LineTotal = OrderQty * UnitPrice * (1 - UnitPriceDiscount)` (in `SalesLT.SalesOrderDetail`)

So that the same files work in SQL database in Fabric, the queries calculate
these values inline:

```sql
-- Instead of:
SELECT TotalDue FROM SalesLT.SalesOrderHeader

-- We use:
SELECT (SubTotal + TaxAmt + Freight) AS TotalDue FROM SalesLT.SalesOrderHeader

-- Instead of:
SELECT LineTotal FROM SalesLT.SalesOrderDetail

-- We use:
SELECT (OrderQty * UnitPrice * (1 - UnitPriceDiscount)) AS LineTotal FROM SalesLT.SalesOrderDetail
```

## Quick Start

Run these from the `sqlsim` folder of an installed package. On Windows ARM64
use `.\ARM64\sqlsim.exe`; on Ubuntu use `./x64/sqlsim`; in a source checkout use
`.\build\x64\Release\sqlsim.exe`.

```powershell
# Connectivity check on localhost (no -S needed)
.\x64\sqlsim.exe -E -Q "SELECT @@VERSION"

# A SQL file that works on any database
.\x64\sqlsim.exe -S localhost -E -i examples\sql\01-simple-queries.sql

# AdventureWorksLT load test: 10 threads x 100 iterations, quiet
.\x64\sqlsim.exe -S localhost -d AdventureWorksLT -E -i examples\sql\08-mixed-workload-adventureworkslt.sql -n 10 -r 100 -q

# A workload that works on any database
.\x64\sqlsim.exe -S localhost -d tempdb -E -workload examples\workload\workload-test.json -q

# SQL authentication, password read from stdin
$password | .\x64\sqlsim.exe -S localhost -U myuser -P - -i examples\sql\01-simple-queries.sql

# Azure SQL with an access token read from stdin
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$token | .\x64\sqlsim.exe -S myserver.database.windows.net -d mydb -T - -i examples\sql\01-simple-queries.sql

# Scripts
.\examples\powershell\localhost-simple-test.ps1
.\examples\powershell\run-basic-tests-adventureworkslt.ps1
```

## Notes

- All SQL files are read-only except `07-insert-test-adventureworkslt.sql`,
  which inserts into a temporary table and cleans up.
- Scale threads (`-n`) and iterations (`-r`) to your system, and do not load
  test a shared or production server.
- Use `-q` during load tests to reduce output overhead, and `-v` to see detailed
  execution information.