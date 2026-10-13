# sqlsim Studio examples

These files exercise sqlsim Studio's query, SQL file, workload, Replay, live
monitoring, and Compare features. In the sqlsimtools package they are in
`sqlsimstudio/examples/`, beside the `sqlsim/` and `sqlpysim/` folders.

| Folder or file | Requires | Use it for |
| --- | --- | --- |
| [`any-database/`](any-database/) | Any SQL Server, Azure SQL, or Fabric SQL database | Connection checks, query mode, a demo workload, and a Replay capture, with no sample data |
| [`adventureworkslt/`](adventureworkslt/README.md) | AdventureWorksLT | Light, medium, and heavy query, SQL file, workload, and Replay tiers |
| [`sql/live-progress-monitor-lt.sql`](sql/live-progress-monitor-lt.sql) | AdventureWorksLT at compatibility level 160 or later | A slow query for live monitoring and per-query statistics |
| [`sql/live-progress-monitor.sql`](sql/live-progress-monitor.sql) | AdventureWorks | A slow query for live monitoring on the full sample database |
| [`convert-workload-for-studio.ps1`](convert-workload-for-studio.ps1) | PowerShell | Convert sqlsim workload groups that use `file` into inline `queries` that Studio can import |

## Any database

These create no objects and read only catalog views, so they run against any
database.

| File | Studio mode | Notes |
| --- | --- | --- |
| [`any-database/sql/light-query.sql`](any-database/sql/light-query.sql) | Query or SQL file | Reads `sys.objects`; fast connection and Results check |
| [`any-database/sql/medium-query.sql`](any-database/sql/medium-query.sql) | Query or SQL file | More work without user tables |
| [`any-database/sql/heavy-query.sql`](any-database/sql/heavy-query.sql) | Query or SQL file | Longer-running catalog work for cancellation and timeouts |
| [`any-database/workload/demo-workload.json`](any-database/workload/demo-workload.json) | Workload | Three inline groups with think time; load with **Import JSON** |
| [`any-database/replay/catalog-replay.xml`](any-database/replay/catalog-replay.xml) | Replay | Nine genuine `sql_batch_completed` events from three concurrent sessions |

`catalog-replay.xml` was captured with Extended Events and converted with
[`convert-xel.ps1`](../../sqlsim/replay/convert-xel.ps1). It records no database action, so
Replay runs in the database you select in Configure. Fast mode replays the nine
events per captured session; stress mode flattens them across the connections
you choose. Enable **Collect per-query performance** to compare each statement's
original capture metrics with the Replay results. The original timings describe
one local capture; use them to learn the workflow, not as a baseline.

## AdventureWorksLT

[`adventureworkslt/README.md`](adventureworkslt/README.md) describes the light,
medium, and heavy tiers for every Studio mode, the AdventureWorksLT Replay
capture `replay/portable-replay.xml`, and the settings to use for each.
AdventureWorksLT is the sample database Azure SQL Database offers at creation;
for SQL Server, install it from the Microsoft sample databases.

## Compare

The measured before-and-after pair for Compare ships with sqlsim in
[`../../sqlsim/examples/results/`](../../sqlsim/examples/results/README.md):
`index-baseline.json` and `index-candidate.json`. They are real `sqlsim -json`
results for one AdventureWorksLT customer lookup before and after adding a
covering index, and comparing them needs no database:

1. Open **Compare**.
2. Select **Import JSON** above **A · Baseline** and choose
   `index-baseline.json`.
3. Select **Import JSON** above **B · Candidate** and choose
   `index-candidate.json`.

Studio reports that the runs are comparable and that the candidate roughly
doubles throughput. See [Comparing Runs](../sqlsimstudio.md#comparing-runs) for
the full Compare workflow.
## Convert a sqlsim workload for Studio

Studio imports workload JSON in the browser and cannot read SQL files referenced
by a workload group's `file` property. Convert those groups before importing.
The converter resolves each `file` path relative to the workload JSON file and
writes `<name>-studio.json` beside it:

```powershell
.\convert-workload-for-studio.ps1 -Path C:\workloads\my-workload.json
```

For a duration-mode sqlsim workload, supply `-Iterations` because Studio runs a
fixed iteration count.
