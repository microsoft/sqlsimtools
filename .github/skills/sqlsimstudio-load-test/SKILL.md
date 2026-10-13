---
name: sqlsimstudio-load-test
description: 'Source-repository-only guided sqlsim Studio performance/load exercise. Use when a contributor asks to run the AdventureWorksLT light, medium, or heavy Studio test tiers, exercise live monitoring or cancellation, compare tiers, or validate the repository workload assets. DO NOT USE FOR: installing, launching, configuring, or using a released Studio package; released-tool workloads; source builds; CI acceptance; or manual acceptance-test recording (use sqlsimstudio-manual-test).'
argument-hint: 'light | medium | heavy | query <tier> | script <tier> | workload <tier> | all | status'
user-invocable: true
disable-model-invocation: false
---

# Guided sqlsim Studio Load Test

Walk the user through running tiered workloads in the sqlsim Studio GUI against
AdventureWorksLT. Give one run at a time with exact values to enter, wait for
the observation, record it, then continue.

This is a performance and behavior exercise, not the release acceptance
checklist. For the packaged-build sign-off in `sqlsimstudio/MANUAL-TEST.md`, use
the `sqlsimstudio-manual-test` skill instead.

## Authoritative Sources

Read before starting:

- [`sqlsimstudio/examples/adventureworkslt/README.md`](../../../sqlsimstudio/examples/adventureworkslt/README.md):
  tiers, files, load values, and measured durations.
- The asset files themselves under
  [`sqlsimstudio/examples/adventureworkslt/`](../../../sqlsimstudio/examples/adventureworkslt/).

The README tables are authoritative for `-n` and `-r`. If an asset file's header
disagrees with the README, stop and report the drift rather than guessing.

## Invocation Modes

- `light`, `medium`, `heavy`: run all three modes at that tier.
- `query <tier>`, `script <tier>`, `workload <tier>`: run one mode.
- `all`: light, then medium, then heavy, in that order.
- `status`: report what has been run and what is pending.

With no argument, ask which tier to start with and recommend `light`.

## The Matrix

Confirm these against the README each session rather than trusting this copy.

| Mode | Light | Medium | Heavy |
| --- | --- | --- | --- |
| Query | `sql/light-query.sql`, -n 4, -r 50 | `sql/medium-query.sql`, -n 4, -r 3 | `sql/heavy-query.sql`, -n 8, -r 2 |
| SQL file | `sql/light-script.sql`, -n 4, -r 25 | `sql/medium-script.sql`, -n 4, -r 5 | `sql/heavy-script.sql`, -n 8, -r 2 |
| Workload | `workload/light-workload.json` | `workload/medium-workload.json` | `workload/heavy-workload.json` |

Workload mode takes connections and iterations from the JSON. The `-n` and `-r`
fields do not apply; say so rather than leaving the user guessing.

Expected batch counts, useful for confirming a run did what was asked: SQL file
mode reports 4 batches for light and 3 for medium and heavy. The workload files
are 450, 1,150, and 16,650 batches across 7, 14, and 46 connections.

## Non-Negotiable Rules

1. Work from the `sqlsimstudio` folder. Use `build.ps1` to build. Never invoke
   `dotnet publish` or other ad hoc build commands.
2. Check the active terminal's last command and exit code before building,
   testing, or launching. Do not rerun a successful current-artifact step.
3. Never print, log, or screenshot bootstrap URLs, tokens, or passwords. Let
   Studio open the browser, or launch with `--no-open --bootstrap-file <path>`
   and tell the user to use the window that opens.
4. The bootstrap token is single-use and its file is deleted after the first
   visit. A second visit, a stale tab, or a tab on a different port returns 404
   with a blank page. That is the auth gate, not a broken build. Relaunch for a
   fresh URL rather than debugging the 404.
5. Studio's client assets are embedded resources. If `client/*` changed,
   `build.ps1` must run before the change is visible.
6. `smoke-test.ps1 -SkipBuild` runs a stale non-RID DLL from
   `server/bin/Release/net10.0/`. Always pass
   `-StudioExecutable .\build\win-x64\sqlsimstudio.exe` or omit `-SkipBuild`.
7. Present one run at a time. Do not paste the whole matrix into chat.
8. Never mark a run Pass for the user. Report what you observe from the API if
   asked, but the user decides the outcome.
9. Treat a cancelled run as `Stopped`, not a failure. Cancelling is supported
   and Studio reports it as such.
10. Do not quote absolute durations as pass criteria. See Measurement Honesty.

## Preflight

Run once per session, before the first test.

1. Confirm AdventureWorksLT is reachable and populated:

   ```powershell
   .\build\win-x64\sqlsim\sqlsim.exe `
     -S <server> -d AdventureWorksLT -E -C `
     -Q "SELECT COUNT(*) AS Customers FROM SalesLT.Customer"
   ```

   847 is the expected count. A different number means a partial or non-standard
   restore; report it rather than proceeding silently. Do not add `-q`: it
   suppresses result rows, which is the value this check reads.

2. Confirm a Studio package exists at `build\win-x64\sqlsimstudio.exe`. If not,
   run `.\build.ps1 -Runtime win-x64`. That build requires a matching sqlsim
   binary at `..\sqlsim\build\x64\Release\sqlsim.exe` and fails without it, so
   build sqlsim first with `..\sqlsim\build.ps1 -Architecture x64`.

3. Launch Studio and confirm the listener before handing over to the user.

4. For Azure targets, confirm the auth mode with the user before the first run.
   Prefer a token obtained outside chat over interactive sign-in, which prompts
   on every run.

## Per-Run Chat Protocol

Use this exact compact shape:

```markdown
**MEDIUM - Query mode**

Configure tab:

1. Server `localhost`, Database `AdventureWorksLT`, Windows integrated.
2. Workload type **Query**. Paste the contents of
   `sqlsimstudio/examples/adventureworkslt/sql/medium-query.sql`.
3. Connections (-n) **4**, Iterations per connection (-r) **3**.
4. Client telemetry **Live progress**.
5. Studio server statistics **Runtime messages**.
6. Run workload, then switch to the Monitor tab.

Watch for: several progress ticks per execution, a non-zero execution rate once
the first execution completes, and a measured average duration.
```

Then ask one outcome question with the questions tool offering Pass, Fail,
Stopped, and Skip, allowing a free-form observation. After the answer, record it
and present the next run.

## What Each Tier Is For

State the purpose when presenting a tier, so the user knows what to watch.

- **Light**: reachability, the Results page, and fast iteration. Deliberately
  too fast for live monitoring to show anything, because sqlsim counts an
  execution only on completion, so a sub-second query reports zero throughput
  for its whole duration. If the user wants to watch the Monitor work, move to
  medium.
- **Medium**: live monitoring. Executions span several one-second progress
  ticks, so the rate, the progress bars, and the measured average duration all
  have something to show.
- **Heavy**: cancellation, query timeout, sustained load, and connection
  pressure.

## Before Any Heavy Run

Raise the **Query timeout** above its 30 second default first. A heavy execution
can exceed 30 seconds under concurrency and the run will fail with a timeout,
which is a valid test but not this one.

On Azure SQL Database, halve every connection count. On a small service tier the
heavy tier measures throttling rather than client behavior. Say this before the
run, not after it fails.

## Measurement Honesty

1. Durations in the assets were measured on one hybrid-core laptop against a
   warm cache. They are relative, not thresholds. Never fail a run for missing a
   quoted number.
2. On hybrid-core hosts, identical runs land in two clusters more than 2x apart
   depending on core scheduling. Take a median of several runs before treating a
   timing change as real.
3. A cold cache roughly doubles the first execution. Discard the first run of a
   tier when comparing.
4. Studio's Results page reports query time as the sum across connections, so a
   ten-connection run shows roughly ten times the wall clock. Use the measured
   average duration instead.
5. Before trusting any timing, confirm the server is healthy. Buffer pool
   pressure or error 802 in the SQL error log invalidates every measurement, and
   the symptom is slow runs rather than an obvious failure.

## Known Behavior, Not Defects

Do not let the user record these as failures.

- A live-telemetry run has no final results JSON. Studio sources the Results
  page from periodic query-statistics snapshots instead, and shows `--` where a
  value genuinely was not measured.
- Stopping a run reports `Stopped`, not `Failed`.
- With Studio server statistics set to **None**, a failed live run has no SQL
  error text available anywhere, only an exit code. Re-run with **Runtime
  messages** to get the message.
- Workload groups that reference a script by file path are skipped on import
  with a toast, because Studio cannot read a path from the browser. All three
  bundled workload files use inline queries and are unaffected.
- `duration_seconds` in a workload file is ignored by Studio and reported as
  ignored. sqlsim honors it; Studio does not.

## Reporting

Keep a running table in chat: tier, mode, outcome, and observation. On request,
write it to `sqlsimstudio/build/load-test-results/YYYYMMDD-HHmmss.md`, which is
an ignored build path. Do not edit the asset files or the README to record a
run.
