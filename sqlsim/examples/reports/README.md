# HTML Reports

PowerShell scripts that turn sqlsim JSON results into self-contained HTML
reports. Chart.js (`chart.umd.min.js`) is embedded in each report, so reports
open offline. See [HTML Reports](../../sqlsim.md#html-reports) in the manual.

| Script | Input | Output |
| --- | --- | --- |
| `execution-report.ps1` | A `-json` result file, or a SQL file, workload, or query it runs for you | Execution summary: runtime, throughput, connection and query timing |
| `querystats-chart.ps1` | A `-querystats -json` result file, or a SQL file, workload, or query it runs for you | Per-query CPU, reads, and elapsed time charts |
| `comparison-report.ps1` | Two result files, or a sqlsim Studio comparison export | A/B comparison with deltas and a configuration check |
| `live-querystats-dashboard.ps1` | A SQL file, workload, or query it runs for you | Browser dashboard that refreshes while the workload runs |

## Examples

Run from the `sqlsim` folder:

```powershell
# Report from a saved result file
.\examples\reports\execution-report.ps1 -JsonFile results.json

# Compare two runs
.\examples\reports\comparison-report.ps1 -BaselineFile before.json -CandidateFile after.json -LabelA "Before" -LabelB "After"

# Try the comparison report with the saved index example
.\examples\reports\comparison-report.ps1 -BaselineFile examples\results\index-baseline.json -CandidateFile examples\results\index-candidate.json

# Run a workload and chart its query statistics
.\examples\reports\querystats-chart.ps1 -SqlFile examples\sql\01-simple-queries.sql -Threads 2 -Iterations 3

# Live dashboard while a workload runs
.\examples\reports\live-querystats-dashboard.ps1 -SqlFile examples\sql\08-mixed-workload-adventureworkslt.sql -DatabaseName AdventureWorksLT -Threads 8 -Iterations 200
```

When a script runs sqlsim for you, it connects with Windows authentication to
`-ServerName` (default `localhost`). For other authentication, run sqlsim
yourself with `-json -o <file>` and pass the file with `-JsonFile`. Add
`-NoOpen` to skip opening the browser, and `-OutputFile` to choose where the
report is written.

The scripts find sqlsim in the package (`x64` or `ARM64`), then a source build,
then `PATH`.
