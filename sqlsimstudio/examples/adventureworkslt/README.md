# AdventureWorksLT tiered test assets

Light, medium, and heavy inputs for exercising sqlsim Studio against the
AdventureWorksLT sample database, on SQL Server or Azure SQL Database.

This README is the reference for running them by hand. In the source
repository, the `sqlsimstudio-load-test` agent skill also provides a guided
walkthrough: ask an agent to "run the light tier" or "start a Studio load test
pass" to be stepped through one run at a time.

## Why AdventureWorksLT

Studio's automated suites deliberately avoid a sample database: they target
`tempdb` with catalog queries so they run anywhere. These assets exist for the
opposite case, where the point is realistic schema and volume. AdventureWorksLT
is the sample Azure SQL Database offers at creation, so the same files work
on-premises and in Azure without a restore.

## Prerequisites

- AdventureWorksLT, reachable from the machine running Studio. Azure SQL
  Database offers it as a sample at creation; for SQL Server, install it from
  the Microsoft sample databases.
- SQL Server 2019 or later, Azure SQL Database, Azure SQL Managed Instance, or
  SQL database in Microsoft Fabric. Nothing here requires SQL Server 2022 or a
  compatibility level above 150.
- The extracted sqlsimtools package, or a source build from `sqlsimstudio` with
  `.\build.ps1 -Runtime win-x64`.

Confirm the target before opening Studio. From the extracted sqlsimtools
folder (in a source build, use `sqlsim\build\x64\Release\sqlsim.exe`):

```powershell
.\sqlsim\x64\sqlsim.exe `
  -S localhost -d AdventureWorksLT -E -C `
  -Q "SELECT COUNT(*) AS Customers FROM SalesLT.Customer"
```

847 customers means the database is present and fully populated. Do not add
`-q`: it suppresses result rows, which is the value this check reads.

## The tiers

| Tier | Purpose | Per-execution cost |
| --- | --- | --- |
| Light | Reachability, Results page, fast iteration | under 0.1 s |
| Medium | Live monitoring, progress ticks, query statistics | 1 s to 3.5 s |
| Heavy | Cancellation, timeouts, sustained load, connection pressure | 9 s to 25 s |

Light is deliberately too fast for live monitoring to show anything
interesting: sqlsim counts an execution only on completion, so a sub-second
query reports zero throughput for its entire duration. Medium is the tier to use
when validating the Monitor view.

## Query mode

Paste the file contents into the query box. Set **Connections (`-n`)** and
**Iterations per connection (`-r`)** as listed.

| Tier | File | `-n` | `-r` |
| --- | --- | --- | --- |
| Light | [`sql/light-query.sql`](sql/light-query.sql) | 4 | 50 |
| Medium | [`sql/medium-query.sql`](sql/medium-query.sql) | 4 | 3 |
| Heavy | [`sql/heavy-query.sql`](sql/heavy-query.sql) | 8 | 2 |

## SQL file mode

Select the file with **Choose file**. Studio reports the batch count before the
run; the expected value is in the table.

| Tier | File | `-n` | `-r` | Batches |
| --- | --- | --- | --- | --- |
| Light | [`sql/light-script.sql`](sql/light-script.sql) | 4 | 25 | 4 |
| Medium | [`sql/medium-script.sql`](sql/medium-script.sql) | 4 | 5 | 3 |
| Heavy | [`sql/heavy-script.sql`](sql/heavy-script.sql) | 8 | 2 | 3 |

## Workload mode

Use **Import JSON**. Connections and iterations come from the file, so the
`-n` and `-r` fields do not apply.

| Tier | File | Groups | Connections | Batches |
| --- | --- | --- | --- | --- |
| Light | [`workload/light-workload.json`](workload/light-workload.json) | 3 | 7 | 450 |
| Medium | [`workload/medium-workload.json`](workload/medium-workload.json) | 4 | 14 | 1,150 |
| Heavy | [`workload/heavy-workload.json`](workload/heavy-workload.json) | 6 | 46 | 16,650 |

Every group uses inline `queries`. Studio cannot read scripts referenced by a
`file` property and silently skips any group that has one, so a definition
written for the sqlsim CLI may import with fewer groups than it declares. None
of these files set `duration_seconds`, which sqlsim honors but Studio ignores.

## Replay mode

| Tier | File | Sessions | Events |
| --- | --- | --- | --- |
| Any | [`replay/portable-replay.xml`](replay/portable-replay.xml) | 3 | 9 |

Fast mode is faithful per session and replays all 9 events. Stress mode flattens
them into one pool, so N connections replay N x 9.

The fixture contains genuine `sql_batch_completed` events captured from three
concurrent sqlsim sessions against AdventureWorksLT. Each event includes its
original duration, CPU, logical and physical reads, writes, row count, outcome,
and session ID. Enable **Collect per-query performance** in Studio to populate
the full **Original capture vs Replay** comparison.

The capture intentionally records no database action, so replay issues no
`USE` and runs in the database the connection specifies. Its batches are
`SalesLT` qualified, so they only resolve if the connection context is correct.
Original timings describe one local capture only; use them to validate the
comparison workflow, not as a portable performance baseline.
Select AdventureWorksLT as the Studio target before running. Studio validates
that connection but cannot validate schema or data equivalence; the selected
database must contain the AdventureWorksLT schema and synchronized test data
for the comparison to be meaningful. For a Replay pass that needs no sample
database, use `../any-database/replay/catalog-replay.xml`.

The replay fixtures in the source repository's `sqlsim/testing` folder are
different on purpose.
`clean-replay.xml` alternates between `master` and `tempdb` because exercising
database switching is the point of it, and `replay-test-data.xml` records
`master` on every event. Both make sqlsim issue `USE`, which Azure SQL Database
does not support for switching databases. Use them for sqlsim's own replay
coverage, not for a portable Studio pass.

## Before running the heavy tier

1. **Raise the query timeout.** The default is 30 seconds and a heavy execution
   can exceed it under concurrency. A timeout is a valid test, but it is not
   this one.
2. **On Azure SQL Database, halve the connections.** On a small service tier the
   heavy tier measures throttling rather than client behavior.
3. **Expect a long run.** The heavy workload is 16,650 batches.

## Reading the measurements

Durations in these files were measured on an Intel i7-1370P against a warm
cache. Treat them as relative rather than absolute. That part is a hybrid
design, and identical runs land in two clusters more than 2x apart depending on
whether the worker is scheduled on a performance or an efficiency core. Take the
median of several runs before reading anything into a timing change, and
re-measure on each new host rather than carrying these numbers forward. A cold
cache roughly doubles the first execution.

## Adjusting cost

The medium and heavy SQL files carry a tally CTE whose `TOP` value is the cost
dial. Rows evaluated is that value multiplied by 295, the row count of
`SalesLT.Product`, and duration tracks it closely:

| `TOP` | Rows evaluated | Duration |
| --- | --- | --- |
| 3,000 | 885,000 | under 1 s |
| 10,000 | 2,950,000 | 1 s to 3.5 s |
| 80,000 | 23,600,000 | 9 s to 25 s |

Prefer this dial over cross-joining the sample tables against each other. The
sample is small, and growing a table cross join changes the plan rather than the
cost: tripling the row count that way was measured to raise the duration only 20
percent, which makes it useless as a dial.
