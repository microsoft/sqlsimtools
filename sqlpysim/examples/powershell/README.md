# PowerShell Example Scripts

Scripts that run the [SQL examples](../sql/README.md) with common
authentication and load patterns. They run `..\..\sqlpysim.py` with the
`python` on your `PATH`, so activate the environment where you installed the
requirements first. They locate the SQL files from their own folder, so you can
run them from any directory.

Most scripts have the server and database written in them. Edit those values
before running against anything other than `localhost`.

## Local SQL Server

| Script | What it does | Database |
| --- | --- | --- |
| `localhost-simple-test.ps1` | Connects without `-S` to show the localhost default | Any |
| `sql-auth-simple.ps1` | SQL authentication; prompts for the password and passes it on stdin | Any |
| `run-basic-tests-adventureworkslt.ps1` | Runs SQL examples 01-04 with Windows authentication | AdventureWorksLT |
| `run-basic-tests-verbose-adventureworkslt.ps1` | The same with `-v` output | AdventureWorksLT |
| `run-all-tests-adventureworkslt.ps1` | Runs SQL examples 01-09 | AdventureWorksLT |
| `run-load-test-adventureworkslt.ps1` | Runs `08-mixed-workload-adventureworkslt.sql` at 1, 5, 10, 25, and 50 threads | AdventureWorksLT |

## Azure SQL

These get an access token with `az account get-access-token` and pipe it to
sqlpysim on stdin (`-T -`). Run `az login` first and replace
`myserver.database.windows.net` in the script.

| Script | What it does | Database |
| --- | --- | --- |
| `azure-simple-interactive.ps1` | Interactive Microsoft Entra sign-in (`-A`) | Any |
| `run-basic-tests-azure-adventureworkslt.ps1` | Runs SQL examples 01-04 with a token | AdventureWorksLT |
| `run-all-tests-azure-adventureworkslt.ps1` | Runs SQL examples 01-09 with a token | AdventureWorksLT |
| `run-load-test-azure-adventureworkslt.ps1` | The load-test sequence with a token | AdventureWorksLT |
| `test-managed-identity.ps1` | Managed identity authentication; run on an Azure VM or App Service after `../sql/setup-managed-identity-access.sql` | Any |

## Results and benchmarks

| Script | What it does |
| --- | --- |
| `json-output-examples.ps1` | Shows `-json` output and how to parse it in PowerShell |
| `basic-perf-benchmark.ps1` | Runs `SELECT 1` across thread counts and reports throughput |

## Examples

```powershell
.\examples\powershell\run-basic-tests-adventureworkslt.ps1
.\examples\powershell\sql-auth-simple.ps1 -ServerName myserver -DatabaseName mydb -Username myuser
```

If PowerShell refuses to run a script because it is not digitally signed,
unblock the package; see [INSTALL.md](https://github.com/microsoft/sqlsimtools/blob/main/INSTALL.md).