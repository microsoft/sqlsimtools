---
name: sqlsimstudio-manual-test
description: 'Source-repository-only guided sqlsim Studio manual acceptance test. Use when a contributor asks to start or resume the repository MANUAL-TEST.md checklist, verify a release candidate built from this checkout, record GUI evidence, diagnose acceptance failures, or produce a session report. DO NOT USE FOR: ordinary use of an installed/released Studio package, Studio workload execution, tiered load tests (use sqlsimstudio-load-test), or general Studio configuration help (use sqlsimstudio).'
argument-hint: 'start | resume | status | section <number> | next'
user-invocable: true
disable-model-invocation: false
---

# Guided sqlsim Studio Manual Test

Guide the user through the repository's manual acceptance test in a series of
short chat turns. Give one exact test or tightly related action group at a time,
wait for the user's observation, record it, and then continue.

## Authoritative Sources

Read these before starting or resuming:

- [`sqlsimstudio/MANUAL-TEST.md`](../../../sqlsimstudio/MANUAL-TEST.md): test
  IDs, inputs, expected results, evidence requirements, and known gaps.
- [`sqlsimstudio/README.md`](../../../sqlsimstudio/README.md): current supported
  behavior and test commands.
- [`sqlsimstudio/gui-tests/studio.spec.cjs`](../../../sqlsimstudio/gui-tests/studio.spec.cjs):
  current automated browser coverage.

If implementation and the manual checklist disagree, stop and identify the
drift. Do not silently test obsolete behavior.

## Invocation Modes

- `start`: begin a new complete manual acceptance session.
- `resume`: continue the latest incomplete session report.
- `status`: report totals and the next pending test without advancing.
- `section <number>`: start or resume a specific checklist section.
- `next`: present the next pending test.

If no mode is supplied, infer `resume` when an incomplete report exists;
otherwise use `start`.

## Non-Negotiable Rules

1. Work from the `sqlsimstudio` folder in the repository root on Windows unless
   the user explicitly selects another supported platform.
2. Use repository wrappers: `build.ps1`, `smoke-test.ps1`, and
   `gui-smoke-test.ps1`. Do not invoke ad hoc build commands.
3. Before build, test, or executable commands, inspect the active terminal's
   last command and exit code. Do not rerun a successful current-artifact check.
4. Never print, store, request through chat, screenshot, or log passwords,
   tokens, or one-time bootstrap URLs. The user types secrets directly into the
   browser when a future credential test explicitly requires them.
5. Default to `AdventureWorksLT`, which the checklist uses for every SQL step so
   the same pass runs on SQL Server and Azure SQL Database. Preflight it on the
   current machine before the first test and never reuse a remembered server or
   database name without that check. For Azure targets, confirm the
   authentication mode with the user first and prefer a token obtained outside
   chat over interactive sign-in, which prompts on every run.
6. Query Store is optional. Run its preflight before presenting QS-01/QS-02. If
   no eligible database exists, record both as Skip with the reason.
7. Never mark a visual/manual check Pass for the user. Automated checks are
   recorded separately as `Automated pass`; the user decides manual outcomes.
8. Present one test ID at a time, except when adjacent IDs are one inseparable
   observation. Do not paste the whole checklist into chat.
9. On Fail, stop advancing. Record expected versus actual, gather non-secret
   evidence, diagnose the defect, and either fix/retest or record a defect link.
10. Visible but unwired controls listed in MANUAL-TEST.md section 15 are
    `Known gap reviewed`, never Pass.

## Session Report

Store each run under this ignored path:

```text
sqlsimstudio/build/manual-test-results/YYYYMMDD-HHmmss-<commit>.md
```

The report must contain:

- Date, tester, commit, branch, package path and SHA-256.
- Windows, browser, SQL target, ODBC, Python, and mssql-python versions.
- Automated preflight command outcomes.
- A row for every manual test ID with status, observation, and evidence path.
- Known gaps reviewed.
- Pass/Fail/Blocked/Skip totals and release recommendation.

Use only these manual statuses: `Pending`, `Pass`, `Fail`, `Blocked`, `Skip`.
Keep `Known gap reviewed` in its own section/count.

Update the report immediately after every answer so `resume` is reliable. Do
not edit the canonical MANUAL-TEST.md when recording a run.

## Start Procedure

1. Read the authoritative sources.
2. Confirm repository root, branch, commit, worktree state, and package path.
   Existing source changes are allowed; record that the worktree was dirty.
3. Check the active terminal context.
4. Collect only missing non-secret metadata. Prefer detected values. Ask for the
   tester name and alternate SQL target only if not available or not default.
5. Create the session report with all test IDs initially `Pending`.
6. Stop any running Studio instance before rebuilding.
7. Run automated preflight in this order:

   ```powershell
   .\build.ps1 -Runtime win-x64
   .\smoke-test.ps1 -SkipBuild -StudioExecutable .\build\win-x64\SqlSimStudio.exe
   .\gui-smoke-test.ps1 -SkipBuild
   npm audit --audit-level=high
   ```

8. Record exact exit outcomes and the GUI report path. A failed preflight blocks
   manual testing until diagnosed or explicitly recorded as Blocked.
9. Launch the packaged Studio executable normally. Confirm the process and
   loopback listener, but do not expose its bootstrap URL.
10. Begin with PF-01 or the requested section.

## Per-Test Chat Protocol

Use this exact compact shape:

```markdown
**TEST CAP-03 — Trust certificate preview**

Setup: Configure > Connection options.

1. Check **Trust server certificate**.
2. Read Command preview.
3. Uncheck it and read the preview again.

Expected: `-C` appears when checked and disappears when unchecked.
Evidence: Screenshot only if it fails.
```

Then use the questions tool with one outcome question:

- Pass
- Fail
- Blocked
- Skip

Allow a free-form observation. Do not ask the user to answer several tests at
once. After the answer:

1. Write the status and observation to the report.
2. If Pass, present the next test.
3. If Fail, ask only for the missing non-secret observation/evidence needed to
   diagnose, then fix or record the defect before proceeding.
4. If Blocked, record the blocker and offer the exact unblock action.
5. If Skip, record a concrete reason.

At the end of each section, report only the delta:

```text
Section 3 complete: 7 passed, 0 failed. Overall: 16/<total> complete. Next: QF-01.
```

## Resume Procedure

1. Find the newest report under `build/manual-test-results/` containing Pending
   rows.
2. Read its metadata, outcomes, last observation, and next pending ID.
3. Verify the commit and package hash still match. If either changed, do not mix
   evidence: offer to start a new report or rerun preflight for a clearly marked
   amended session.
4. Confirm Studio is running and authenticated. Relaunch securely if needed.
5. Summarize only completed totals, blockers, and the next test.
6. Continue with the per-test chat protocol.

## Failure Evidence

For a failure, record:

- Test ID and exact expected behavior.
- Exact observed behavior and timestamp.
- Browser/version and package hash.
- Screenshot path when visual.
- Sanitized execution log excerpt when behavioral.
- Automated artifact paths when relevant:
  - `build/gui-test-report/`
  - `build/gui-test-results/`

Never collect a screenshot while a password or token is visible.

## Completion

When no tests remain Pending:

1. Reconcile every test ID against the current MANUAL-TEST.md; never hardcode
   the expected count.
2. Confirm every non-Pass has a reason and every Fail has evidence or a defect
   link.
3. List known gaps separately from regressions.
4. Calculate totals and write `Pass` only when there are no Fail or Blocked
   outcomes; Skips must be justified.
5. Present a concise chat summary with the report path, totals, defects, skipped
   optional coverage, and release recommendation.

## Coverage Maintenance

When Studio gains or removes a GUI control, update all three together:

1. `sqlsimstudio/MANUAL-TEST.md`
2. `sqlsimstudio/gui-tests/studio.spec.cjs`
3. This skill only when the workflow or safety rules change

Do not allow a formerly known-gap control to become implemented without a
positive manual test and Playwright assertion.