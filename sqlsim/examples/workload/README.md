# Workload Definitions

JSON files for `sqlsim -workload`. A workload runs several query groups at
once, each with its own thread count, iteration count or duration, and think
time. See [Workload File Mode](../../sqlsim.md#workload-file-mode) for the
format.

| File | What it runs | Database |
| --- | --- | --- |
| `workload-test.json` | Two groups of catalog queries | Any |
| `workload-think-time-iterations.json` | Iteration-count workload with fixed think time | Any |
| `workload-think-time.json` | Duration-mode workload with think time | Any |
| `workload-with-errors.json` | Includes an intentional divide-by-zero to show error reporting | Any |
| `workload-example-adventureworkslt.json` | OLTP, reporting, and monitoring groups | AdventureWorksLT |
| `mixed-workload-adventureworkslt.json` | Ten AdventureWorksLT groups; used by the live query-statistics dashboard | AdventureWorksLT |

## Run a workload

Run from the `sqlsim` folder. File paths inside a workload, such as
`examples/sql/01-simple-queries.sql`, are resolved from the current directory.

```powershell
.\x64\sqlsim.exe -S localhost -d tempdb -E -workload examples\workload\workload-test.json -q
.\x64\sqlsim.exe -S localhost -d AdventureWorksLT -E -workload examples\workload\workload-example-adventureworkslt.json -json -o results.json
```

sqlsim Studio can run these files too. Its examples folder includes converted
copies; see the Studio manual for details.
