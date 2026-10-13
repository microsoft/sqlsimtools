# sqlsim Studio Manual Acceptance Test

Use this checklist to validate a packaged Studio build and retain human evidence.
It mirrors the automated GUI and API smoke suites without requiring every
possible Cartesian combination of settings.

Every SQL step targets **AdventureWorksLT**, so the same pass runs unchanged
against SQL Server and Azure SQL Database. Studio's automated suites
deliberately target `tempdb` with catalog queries so they run anywhere; this
checklist deliberately uses realistic schema and volume instead. The tiered
inputs it references live in
[`examples/adventureworkslt`](examples/adventureworkslt).

## Test Record

Record these values before testing. Do not record passwords, access tokens, or
bootstrap URLs.

| Field | Value |
| --- | --- |
| Date / tester | |
| Git commit | |
| Version / platform stage | `1.0.0` / Public Preview or Private Preview |
| Package path | `build/win-x64/SqlSimStudio.exe` |
| Package SHA-256 | |
| Windows version | |
| Browser and version | |
| SQL Server / database | |
| ODBC driver version | |
| Python / mssql-python version | |
| Query Store database, if used | |

Use **Pass**, **Fail**, **Blocked**, or **Skip** for each test. Attach a
screenshot for failures and for the final Results, console rows, live Monitor,
and Compare screens.

## 1. Preflight

1. Stop any running Studio instance so the package is not locked.
2. From `sqlsimstudio`, build and run both automated suites:

   ```powershell
   .\build.ps1 -Runtime win-x64
   .\smoke-test.ps1 -SkipBuild -StudioExecutable .\build\win-x64\SqlSimStudio.exe
   .\gui-smoke-test.ps1 -SkipBuild
   ```

3. Confirm both suites pass and `npm audit --audit-level=high` reports no high
   severity vulnerabilities.
4. Verify the target independently before opening Studio:

   ```powershell
   .\build\win-x64\sqlsim\sqlsim.exe `
     -S <server> -d AdventureWorksLT -E -C `
     -Q "SELECT COUNT(*) AS Customers FROM SalesLT.Customer"
   ```

   `847` is the expected count. Any other number means a partial or
   non-standard restore; resolve that before testing rather than recording
   confusing results later. Do not add `-q` here: it suppresses result rows,
   which is what this check needs to read. For Azure SQL Database, drop `-C`
   and replace `-E` with the authentication this pass will use.

5. If Query Store will be tested, confirm the database exists, is accessible,
   and reports `READ_WRITE`. Never reuse a database name from another machine
   without this preflight.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| PF-01 | Package build | Build succeeds | |
| PF-02 | API smoke suite | All checks pass | |
| PF-03 | GUI smoke suite | All checks pass | |
| PF-04 | Direct SQL preflight | `847` customers returned | |
| PF-05 | Query Store preflight | Pass or explicitly Skip | |

## 2. Secure Startup and Navigation

1. Launch `build/win-x64/SqlSimStudio.exe`.
2. Confirm one browser tab opens and lands on **Configure**.
3. Confirm the top-right runtime badge says **Studio ready**, not
   **Disconnected**.
4. Open **Monitor**, verify **Stop run** is disabled before any workload, then
   open **Results**, **Compare**, and return to **Configure**.
5. Refresh the authenticated page; it should remain usable in that browser
   session.
6. Copy only the base address, without any bootstrap path, into a private or
   different browser profile. It must return 404 rather than exposing Studio.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| NAV-01 | Automatic launch | One authenticated local tab | |
| NAV-02 | Runtime badge | Studio ready; tooltip distinguishes app and SQL status | |
| NAV-03 | Primary navigation | All four views open | |
| NAV-04 | Idle Monitor action | Stop run is disabled | |
| SEC-01 | Unauthenticated profile | 404 | |

## 3. Connection and Capability Controls

Use placeholder text only; do not execute credential-dependent modes during this
section.

1. Select each authentication mode and verify the credential fields:
   - Integrated: no username or secret.
   - Entra token: secret only, labelled **Access token**.
   - Entra interactive: no username or secret. On Linux or macOS, verify the
     option is disabled and labelled **Windows only**.
   - Managed identity: optional **User-assigned client ID**, no secret.
   - Service principal: **Application (client) ID** and **Client secret**, both
     required. Verify the option remains enabled for both engines.
   - SQL authentication: username and password.
   Switch from a mode with credentials to one without, and verify the previous
   values are cleared rather than retained.
2. In a secret field, verify **Show** changes it to readable text and **Hide**
   masks it again. Clear the field afterward.
3. Expand **Connection options**. Toggle **Trust server certificate** and verify
   `-C` appears and disappears in Command preview.
4. Toggle **Stop on first error** and verify `-stoponerror` appears and
   disappears.
5. Select telemetry modes and verify:
   - Live progress: preview contains
     `-stream-json -json -o studio-results.json`; `-q` is checked/disabled.
   - Final results only: preview contains `-json -o studio-results.json`; `-q`
     is checked/disabled.
   - Console output: neither JSON flag is present; `-q` is available and off.
6. Select statistics modes and verify:
   - Runtime messages adds `-querystats` for sqlsim.
   - Query Store shows its preflight panel.
   - None removes statistics flags.
7. Select sqlpysim and verify Replay is disabled, and that **Application
   name** becomes empty and greyed out with the tooltip *Application name is
   not supported with sqlpysim.* Mixed workload, Live progress, and Runtime
   messages statistics must stay available. Switch back to sqlsim and confirm
   any application name you had typed returns.
8. Verify required inputs have a red asterisk and the legend says **Required
   fields**. Switch authentication modes and confirm only visible credential
   fields become required.
9. Verify Test connection reports the live server version, edition, database,
   and driver on success, and a specific error on failure. Verify remaining
   unfinished controls are visibly disabled.
10. Enter a nonexistent database and select **Run workload**. Verify Studio
    stays on Configure, reports the connection error beside **Test connection**,
    and does not open Monitor or start a workload.
11. Verify workload estimates and connection summaries update in every mode:
    Query and SQL File track connections x iterations (x batches for a file
    with `GO` separators), Session order replay shows Replay passes and the
    captured session count, Load stress shows Replay passes and selected stress
    connections, and Mixed workload sums its groups.
11. Verify every displayed CLI option preserves its documented case: `-n`,
    `-r`, and `-q` must remain lowercase even though surrounding labels are
    uppercase.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| CAP-01 | Authentication field states | Match list above | |
| CAP-02 | Secret reveal / hide | Works; secret cleared | |
| CAP-03 | Trust certificate preview | `-C` tracks toggle | |
| CAP-04 | Stop-on-error preview | Flag tracks toggle | |
| CAP-05 | Telemetry flags and `-q` | Match list above | |
| CAP-06 | Statistics controls | Match engine capabilities | |
| CAP-07 | sqlpysim restrictions | Unsupported choices disabled | |
| CAP-08 | Required-field indicators | Red marker and conditional semantics | |
| CAP-09 | Unfinished controls | Disabled; no simulated success | |
| CAP-10 | CLI option casing | Literal flags remain lowercase | |
| CAP-11 | Pre-run connection validation | Invalid target stays on Configure; no workload starts | |

## 3A. App Settings and Themes

1. Hover **Studio ready** and verify the tooltip explains that the Studio app is
   healthy while SQL target status appears when a workload runs.
2. Open the gear. Verify the dialog is titled **App settings** and says these
   preferences do not change sqlsim workload settings.
3. Select Dark. Verify it previews immediately and that panels, inputs, monitor,
   Results, Compare, log drawer, and console output remain legible. Confirm the
   palette uses deep Cowboys navy, royal-blue actions, silver structure, and
   white text rather than bright periwinkle accents.
4. Click Cancel. Verify the prior theme returns and is not saved.
5. Select Dark again and click OK. Refresh and verify Dark persists.
6. Preview Light and close with X. Verify Dark returns.
7. Select System, click OK, and verify Studio follows the operating-system
   preference.
8. Select each color theme. Verify Blue, Red & Blue, Green & Black, and Green &
   Gold color the whole screen, and Royal Blue and Green keep white panels with
   a colored navigation rail. In every theme, verify text, inputs, buttons, and
   the chart stay legible. Click OK on one, refresh, and verify it persists.
   Shut Studio down with the power button, start it again, and verify the same
   theme applies even though Studio is on a new port.
9. At mobile width, verify the gear remains available in the header.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| APP-01 | Runtime badge meaning | App readiness meaning is explicit | |
| APP-02 | Settings dialog | Opens/closes and is app-scoped | |
| APP-03 | Theme preview / Cancel | Preview changes; Cancel and X restore | |
| APP-04 | Dark theme / OK | Cowboys palette persists after OK and refresh | |
| APP-05 | System theme | Follows OS preference | |
| APP-06 | Mobile settings | Gear remains accessible | |
| APP-07 | Color themes | Each color theme applies, stays legible, and persists across a Studio restart | |

## 4. Query: Final Results and History

Configure sqlsim, the authentication for this pass, your server,
`AdventureWorksLT`, one connection, one iteration, no statistics, and **Final
results only**. Run the contents of
[`examples/adventureworkslt/sql/medium-query.sql`](examples/adventureworkslt/sql/medium-query.sql)
twice without changing any setting.

That file does one to three seconds of real server work per execution, which is
long enough to observe the running state. A sub-second query completes before
the state is visible.

For each run verify:

1. Monitor opens automatically.
2. The active state shows **Running...**, an animated pulse, target, elapsed
   time, **View log**, and **Stop run**.
3. The waiting message says final structured results are pending.
4. Completion changes the action to **View results**.
5. Results shows success, nonzero runtime, one execution/connection, timing
   bars, Query workload, target, driver, and engine version.
6. Open the execution log and verify it contains real sanitized events and no
   credentials.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| QF-01 | First final run | Successful real Results | |
| QF-02 | Second identical run | Successful real Results | |
| QF-03 | Running state | Clear and continuously active | |
| QF-04 | Execution log | Real, sanitized entries | |

## 5. Query: Console Rows

This section tests that Studio displays result *rows*, so the queries return
several. A single-row query such as `SELECT COUNT(*)` cannot tell a complete
result from a truncated one: the first row is also the last.

Select **Console output**, leave `-q` off, one connection and one iteration,
and run:

```sql
SELECT TOP 10 CustomerID, FirstName, LastName
FROM SalesLT.Customer
ORDER BY CustomerID;
```

Verify **Capturing console output** while it runs, that Results opens
automatically, and that the console shows all ten rows: the column headers,
`1 | Orlando | Gee` first, `12 | Johnny | Caprio` last, and
`(10 row(s) affected)`. Fewer rows means output is being truncated. Different
names mean the sample database is not standard, rather than that console
capture failed. Structured metric panels should not claim JSON metrics that
this mode never produced.

Repeat with sqlpysim:

```sql
SELECT TOP 10 ProductID, Name
FROM SalesLT.Product
ORDER BY ProductID;
```

Expect ten rows, `680 | HL Road Frame - Black, 58` first and
`714 | Long-Sleeve Logo Jersey, M` last.

sqlpysim prints a shorter summary after the rows than sqlsim does: no
**Performance Metric Summary** heading, and no start, end, average connect or
average elapsed lines. That is a known output-compatibility gap recorded in
[RELEASE-NOTES.md](../RELEASE-NOTES.md), not a defect in this run. The rows
themselves must match.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| QC-01 | sqlsim console rows | Ten rows, first and last as listed | |
| QC-02 | Automatic navigation | Results opens on completion | |
| QC-03 | sqlpysim console rows | Ten rows, first and last as listed | |

## 6. Query: Live Progress and Cancellation

For Live progress, set four connections, three iterations, and Studio server
statistics **Runtime messages**, then run the contents of
[`examples/adventureworkslt/sql/medium-query.sql`](examples/adventureworkslt/sql/medium-query.sql).

That file does real server work for one to three seconds per execution, so a
single execution spans several one-second progress ticks. A sleeping query such
as `WAITFOR DELAY` holds the connection open without producing CPU, reads, or
query statistics, so it cannot show that live monitoring is measuring anything.

Verify the Monitor shows structured start/progress/completed events, elapsed
time, throughput, executions, connections, errors, and progress, and that a
measured average duration appears beside the execution rate. Throughput stays
at zero until the first execution completes: the engine counts an execution
only on completion, so that is expected rather than a stall. After the first
query-statistics snapshot, verify **Live query statistics** shows totals,
average elapsed, server CPU, logical reads, execution share, and a per-query
row whose values update during the run.

Then configure Final results only, raise the **Query timeout** above its 30
second default, set eight connections and two iterations, and start the
contents of
[`examples/adventureworkslt/sql/heavy-query.sql`](examples/adventureworkslt/sql/heavy-query.sql).

Click **Stop run** while active. The terminal state must be **Run stopped**, not
**Run failed**.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| QL-01 | Live telemetry | Events and metrics update | |
| QL-02 | Progress visualization | Bars visibly update | |
| QL-03 | Cancellation | Run stopped | |
| QL-04 | Measured duration | Real average shown, not zero | |
| QL-05 | Live query statistics | Totals, charts, and query table update | |

## 7. Runtime Query Statistics

Use sqlsim, Final results only, and **Runtime messages**. Run:

```sql
SELECT 252 AS ManualRuntimeStatisticsResult;
```

Verify Results displays **Runtime query statistics** with real execution,
elapsed, CPU, and logical-read values.

Then repeat the same run with sqlpysim selected. It gathers the same counters
from the execution plan rather than from `SET STATISTICS` output, so the panel
must appear with real values there too.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| STAT-01 | Runtime statistics | Real statistics panel shown | |
| STAT-02 | Runtime statistics on sqlpysim | Same panel, real values | |

## 8. SQL File Mode

Uses the tiered scripts in
[`examples/adventureworkslt/sql`](examples/adventureworkslt/sql). They run real
work against the sample schema, so this section proves Studio executes a
script rather than only that it can count `GO` separators.

1. Select **SQL file** mode and choose
   [`light-script.sql`](examples/adventureworkslt/sql/light-script.sql).
2. Before running, confirm Studio reports **4 batches** and that Total
   executions tracks connections x iterations x batches.
3. Set one connection, one iteration, **Final results only**, and run. Verify
   Results reports 4 batches with no errors.
4. Now choose
   [`medium-script.sql`](examples/adventureworkslt/sql/medium-script.sql),
   confirm Studio reports **3 batches**, set **4 connections** and **5
   iterations**, and run. Verify 60 batches complete with no errors.

The medium script includes one deliberately expensive batch, so the run takes
a few seconds under concurrency rather than finishing instantly. That is what
makes the batch and execution counts worth checking.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| FILE-01 | Upload and batch count | 4 batches detected | |
| FILE-02 | Execution | 4 batches succeed | |
| FILE-03 | Concurrent script run | 3 batches x 4 x 5 = 60, no errors | |

## 9. Mixed Workload Mode

Covers both ways of building a workload: adding scripts by hand, and importing
a definition. They are different code paths, so both are tested.

### Built by hand

1. Add [`light-script.sql`](examples/adventureworkslt/sql/light-script.sql) and
   [`medium-script.sql`](examples/adventureworkslt/sql/medium-script.sql) as two
   groups.
2. Set the first to two connections / one iteration.
3. Set the second to one connection / two iterations / 1 ms think time.
4. Verify estimated executions and total connections update as you type.
5. Run with **Final results only** and verify two groups complete successfully.
6. Remove one group and verify the row disappears and totals recalculate.

### Imported

7. Choose **Import JSON** and select
   [`light-workload.json`](examples/adventureworkslt/workload/light-workload.json).
   Verify Studio reports **3 groups imported**, shows **7 total connections**,
   and runs successfully.
8. Import `..\sqlsim\examples\workload\workload-test.json`, which is written
   for the sqlsim command line rather than Studio. Verify Studio says it
   **skipped 1 file-based group** and imports only the group with inline
   queries.

Step 8 matters because Studio cannot read a script that a definition refers to
by path: the browser has no access to it. A definition that imports with fewer
groups than it declares must say so rather than silently running a smaller
workload than the file describes.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| WORK-01 | Multiple groups | Two groups rendered | |
| WORK-02 | Per-group controls | Totals recalculate | |
| WORK-03 | Workload execution | Successful; two groups | |
| WORK-04 | Remove group | Row and totals update | |
| WORK-05 | Import JSON | 3 groups, 7 connections, runs clean | |
| WORK-06 | Skipped group reported | Says 1 file-based group was skipped | |

## 10. Replay Modes

Use the current test database. Confirm Replay initially selects Final results
only, then switch to Live progress for the Session order test.

1. Select Replay and browse to
   [`gui-tests/fixtures/replay-comparison.xml`](gui-tests/fixtures/replay-comparison.xml).
   Verify preflight reports four captured and recognized events, zero skipped
   events, two captured SPIDs, and no captured database context. Verify the
   capture table lists SQL, event type, captured SPID, mode decision, and original
   duration.
2. Confirm the privacy and behavior warning is visible. Select **Session order
   (fast)**, verify Stress connections is disabled, enable **Collect per-query
   performance**, select **Live progress**, set Replay passes to one, and run.
   Confirm four events complete successfully and Monitor reaches 100%.
3. In Results, verify **Original capture vs Replay** shows original and Replay
   outcomes, three exact SQL-text matches, original and Replay average elapsed
   time, elapsed and read deltas, and zero failures. Verify Runtime query
   statistics shows the same three queries with SPIDs, CPU, and I/O details.
   Verify the SPIDs column shows which new SQL Server connection executed each query
   and contains more than one distinct SPID across the Session order results.
4. Return to Configure, choose **Load stress**, verify Stress connections is
   enabled, set it to two, and run one pass. Confirm eight events complete
   successfully and Results labels the mode as transformed.
5. Select a malformed XML file and verify Studio rejects it before a run starts.

The source-only comparison fixture contains read-only catalog queries and
records no database name, so it runs in the database selected in Studio and
does not issue `USE`. It is test data and is not embedded in the packaged
application. For an AdventureWorksLT-specific pass, use
[`examples/adventureworkslt/replay/portable-replay.xml`](examples/adventureworkslt/replay/portable-replay.xml);
preflight should report nine events across three captured SPIDs. That file contains
genuine captured duration, CPU, read, write, row-count, and outcome fields, so
its comparison must show original values and deltas rather than **Not
captured** or **Unavailable**. Select AdventureWorksLT as the target and verify
the preflight warning explains that Studio validates connectivity rather than
schema or data equivalence.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| REPLAY-01 | Replay fixture preflight | 4 recognized, 0 skipped, 2 captured SPIDs | |
| REPLAY-02 | Live Session order replay | Connections disabled; Monitor and 4 events complete | |
| REPLAY-03 | Live original vs Replay | 3 SQL matches; Runtime SPIDs; metrics; zero failures | |
| REPLAY-04 | Load stress replay | Connections enabled; 8 events ok; transformed label | |
| REPLAY-05 | Malformed XML | Rejected before execution | |
| REPLAY-06 | Single captured database | Captured context is redirected to the selected target | |
| REPLAY-07 | Multiple captured databases | Rejected during file preflight as unsupported in this release | |

## 11. A/B Compare

Runs last, once every workload type has been exercised. Compare reads the run
history, so it can only be judged against a history that has something in it.
AB-04 in particular asks you to confirm that console and live runs are absent,
which means nothing until those runs have actually been performed.

1. Open **Compare**.
2. Select the two identical Final-results runs from section 4. Confirm both
   appear and **Runs are comparable** is shown.
3. Verify throughput, total duration, average execution, average connection,
   errors, normalized bars, verdict counts, target, workload hash, load shape,
   and statistics source are populated from the selected runs.
4. Click **Swap** and verify baseline and candidate values, and their deltas,
   reverse.
5. Select one of those runs against the SQL file or workload run from sections
   8 and 9. Studio must say the runs are not comparable and must hide the
   deltas: a different workload shape is not a like-for-like comparison.
6. Review the history list. The console run from section 5 must **not**
   appear, because it does not produce final JSON. Completed Final-results and
   Live-progress runs should appear. Select one Live-progress run against a
   Final-results run with the same workload and confirm Studio refuses the pair
   because telemetry differs.
7. On Results, use **Export JSON** for the two identical Final-results runs.
   In Compare, use **Import JSON** above Baseline and Candidate to load those
   files. Confirm the imported labels appear and **Runs are comparable** is
   shown. Import the SQL file or workload result as Candidate and confirm the
   comparison is rejected.
8. Import `sqlsim/examples/results/index-baseline.json` as Baseline and
   `index-candidate.json` as Candidate. Confirm **Per-query comparison** shows
   the customer lookup with logical reads changing from 36.0 to 2.0.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| AB-01 | Compatible pair | Real metrics and verdict | |
| AB-02 | Swap | A/B values reverse | |
| AB-03 | Incompatible pair | Rejected; no deltas | |
| AB-04 | History eligibility | Completed Final and Live runs appear; console runs absent | |
| AB-05 | Imported results | Compatible files compare; incompatible import rejected | |
| AB-06 | Per-query comparison | Matched query shows A/B values and changes | |

## 12. Optional Query Store

Only run after Query Store preflight passes. Use Final results only and Query
Store statistics:

```sql
SELECT TOP (10) name
FROM sys.objects
ORDER BY object_id;
```

Verify Results displays **Query Store statistics**, exact submitted SQL text,
and aggregate deltas. Record the warning that other sessions can affect totals.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| QS-01 | Query Store preflight | Database is accessible/read-write | |
| QS-02 | Aggregate capture | Real Query Store rows shown | |

## 13. Responsive and Browser Pass

Repeat the navigation and one Final-results query in each required browser for
the current platform. On Windows, test current Edge and Chrome.

Before this pass, run the automated responsive sweep
(`gui-tests/responsive.config.cjs`, described in README.md). It covers desktop
widths from 761 to 2560 pixels in Edge, Chrome, Firefox, WebKit, and a wide-font
pass; this manual pass confirms real-browser behavior it cannot observe.

At approximately 390 x 844 and 1440 x 1000 verify:

- No horizontal page overflow.
- Text and controls do not overlap or clip.
- Tabs, Configure panels, Monitor, Results, Compare, log drawer, and console
  output remain usable.
- Browser developer console contains no errors or CSP violations.
- Required asterisks are clearly visible in red.
- Field labels and supporting text remain readable at projection distance.
- The darker silver canvas distinguishes white panels without reducing text
   contrast.

| ID | Browser / viewport | Expected | Result / evidence |
| --- | --- | --- | --- |
| UI-01 | Edge desktop | No layout/console errors | |
| UI-02 | Edge mobile viewport | No overflow/overlap | |
| UI-03 | Chrome desktop | No layout/console errors | |
| UI-04 | Chrome mobile viewport | No overflow/overlap | |

## 14. Saved Configurations

Configure each workload mode, save it, change the visible fields, and load the
saved `.json` file. Inspect at least one saved file as text.

| ID | Scenario | Expected | Result / evidence |
| --- | --- | --- | --- |
| CFG-01 | Query round trip | Connection metadata, query, load shape, and execution options are restored | |
| CFG-02 | SQL file round trip | File name, SQL content, batch count, and load shape are restored | |
| CFG-03 | Mixed workload round trip | Every group, SQL body, connection count, iteration count, and think time is restored | |
| CFG-04 | Replay round trip | XML content, replay mode, passes, and stress connections are restored | |
| CFG-05 | SQL/token authentication | Username may be present; password/token is absent from JSON and cleared on load | |
| CFG-06 | Malformed or unsupported JSON | A bounded error toast appears and current configuration remains unchanged | |

## 15. Known Nonfunctional Controls

Record these as **Known gap**, not Pass. They are visible but are not complete
production workflows yet:

- Copying the Monitor event stream, Run again, opening a completed run's
  configuration, and copying, exporting, or clearing the execution log are
  absent from the interface.
- Entra interactive, managed identity, and service principal are wired, but
  executing them needs targets this checklist does not provide: managed identity
  requires an Azure host, interactive requires a human at a sign-in prompt, and
  service principal requires an app registration. Verify their field behaviour
  and command preview here; record execution separately when a target exists.
- Imported results and persistent history are not implemented; history is
  session-only.

Any control removed from this list must gain a positive manual test and an
automated Playwright assertion in the same change.

## 16. Lifecycle and Shutdown

Studio has no window and no usable Ctrl+C, so the power button in the top right
is the only deliberate exit. Closing the browser deliberately does **not** stop
it: a workload must outlive the page that started it.

1. Start a workload long enough to still be running a minute from now, for
   example the heavy query at eight connections.
2. Confirm the Monitor shows the note saying that closing the tab will not stop
   the run.
3. While it runs, **close the browser tab**. Confirm the browser asks you to
   confirm before closing. Its wording is generic and browser-controlled; the
   point is that it asks at all. Cancel, and confirm the run is unaffected.
4. Close the tab again, this time confirming. Wait thirty seconds.
5. Confirm `sqlsimstudio.exe` and `sqlsim.exe` are both still running, in Task
   Manager or with `Get-Process`.
6. Reopen the interface from the URL in
   `%TEMP%\sqlsimstudio-session-<user>.url`. Confirm the run is still shown and
   the Monitor is still updating.
7. Let the run finish, then close and reopen a tab. Confirm the browser does
   **not** challenge the close when nothing is running.
8. Click the **power button**. Confirm the dialog says any running workload
   will be terminated, then cancel it and confirm nothing changed.
9. Start another workload, click the power button again, and confirm the dialog
   adds that a workload is running right now. Confirm it.
10. Confirm the page reports Studio has shut down, and that both
    `sqlsimstudio.exe` and `sqlsim.exe` have gone.
11. Start Studio again, start another workload, and this time **kill
    `sqlsimstudio.exe` from Task Manager**. Confirm `sqlsim.exe` survives: this
    is the case the cleanup script exists for.
12. Run `.\sqlsimstudio-cleanup.ps1 -WhatIf`, confirm it reports the orphan and
    the target it is running against, then run it without `-WhatIf` and confirm
    the orphan is gone.

| ID | Check | Expected | Result / evidence |
| --- | --- | --- | --- |
| LIFE-01 | Monitor note during a run | Says closing the tab will not stop it | |
| LIFE-02 | Closing the tab mid-run | Browser asks for confirmation; cancel is safe | |
| LIFE-03 | Closing the tab when idle | No challenge | |
| LIFE-04 | After closing mid-run | Studio and the workload keep running | |
| LIFE-05 | Reopening from the session file | Interface returns, run still live | |
| LIFE-06 | Shutdown dialog wording | States the workload will be terminated | |
| LIFE-07 | Shutdown dialog during a run | Adds that one is running now; cancel is safe | |
| LIFE-08 | Shutdown | Studio and engine both stop; page says so | |
| LIFE-09 | Orphan after a hard kill | `sqlsim.exe` survives the kill | |
| LIFE-10 | Cleanup script | Reports then removes the orphan | |

## Sign-off

| Summary | Count |
| --- | ---: |
| Passed | |
| Failed | |
| Blocked | |
| Skipped | |
| Known gaps reviewed | |

**Release recommendation:** Pass / Fail

**Notes and defect links:**
