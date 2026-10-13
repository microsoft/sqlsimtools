# sqlsim example results

These files are real `sqlsim -json` final results from a local SQL Server 2025
instance. Use them to try Studio Compare or the HTML comparison report without
first running a workload.

| File | Description |
| --- | --- |
| `index-baseline.json` | Customer lookup before adding a covering index |
| `index-candidate.json` | The same lookup after adding the covering index |

Both runs used the AdventureWorksLT database, Windows authentication, 8
connections, 1,000 iterations per connection, quiet mode, and runtime query
statistics. Each recorded run followed one warm-up run with the same settings.

| Metric | Baseline | Candidate |
| --- | ---: | ---: |
| Throughput | 9,412 exec/sec | 19,048 exec/sec |
| Total duration | 0.907 sec | 0.478 sec |
| Average logical reads | 36 | 2 |

Throughput uses execution elapsed time, as both sqlsim Studio Compare and
`comparison-report.ps1` do. Average connection time is shown, but it counts
toward the verdict only when both runs use `-reconnect`.

The difference shows what an index can do for this query on that machine. It is
not a benchmark result for SQL Server or for another system.

## Compare in Studio

1. Open **Compare**.
2. Select **Import JSON** above **A · Baseline**, then choose
   `index-baseline.json`.
3. Select **Import JSON** above **B · Candidate**, then choose
   `index-candidate.json`.

Studio should report that the runs are comparable and show the candidate's
throughput and runtime improvement.

## Create an HTML report

From the extracted sqlsim package:

```powershell
.\sqlsim\examples\reports\comparison-report.ps1 `
    -BaselineFile .\sqlsim\examples\results\index-baseline.json `
    -CandidateFile .\sqlsim\examples\results\index-candidate.json `
    -LabelA 'Without index' -LabelB 'With covering index'
```

## Reproduce

Use a disposable or non-production AdventureWorksLT database. The candidate step
creates an index, and the cleanup step removes it.

```powershell
$query = "SELECT CustomerID, FirstName, LastName FROM SalesLT.Customer WHERE CompanyName = N'Friendly Bike Shop';"
$arguments = @(
    '-S', 'localhost', '-d', 'AdventureWorksLT', '-E', '-C',
    '-Q', $query, '-n', '8', '-r', '1000', '-q', '-querystats', '-json'
)

$null = & sqlsim @arguments
& sqlsim @arguments -o index-baseline.json

& sqlsim -S localhost -d AdventureWorksLT -E -C -Q @"
CREATE NONCLUSTERED INDEX IX_Customer_CompanyName_Example
ON SalesLT.Customer (CompanyName)
INCLUDE (FirstName, LastName);
"@

try {
    $null = & sqlsim @arguments
    & sqlsim @arguments -o index-candidate.json
}
finally {
    & sqlsim -S localhost -d AdventureWorksLT -E -C -Q "DROP INDEX IF EXISTS IX_Customer_CompanyName_Example ON SalesLT.Customer;"
}
```

Results vary with hardware, SQL Server configuration, cache state, and
concurrent activity. The checked-in files omit `output_file` because they were
captured from standard output; files written with `-o` record that path.
