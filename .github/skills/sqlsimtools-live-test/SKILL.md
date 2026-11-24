---
name: sqlsimtools-live-test
description: "Run the sqlsimtools on-demand live SQL validation workflow. USE WHEN: a maintainer asks to run live tests, run the entire test, run Ubuntu x64, or run sqlsim/sqlpysim against SQL Server 2025 in GitHub Actions. DO NOT USE FOR: local builds or tests (use sqlsimtools-build), released workload runs (use sqlsim or sqlpysim), or release publishing (use sqlsimtools-release)."
---

# Run sqlsimtools live validation

This maintainer skill starts the `live-validation.yml` GitHub Actions workflow,
waits for it, and reports the tested ref, commit, SQL Server version, suite
totals, and log artifact.

## Current coverage

Step 1 supports Ubuntu x64 against a fresh SQL Server 2025 Developer container.
It can run `sqlsim`, `sqlpysim`, or both. The full sqlsim suite includes both
1024-thread scale tests. The workflow currently has no Azure dependency or
repository secrets.

## Run a test

Check `gh auth status` first. Start the workflow from `main`, and specify the
source ref separately as an input:

```powershell
gh workflow run live-validation.yml --repo microsoft/sqlsimtools --ref main `
    -f platform=ubuntu-x64 -f tool=all -f suite=full -f ref=1.1.0
```

Defaults are `ubuntu-x64`, `all`, `full`, and `1.1.0`. For a smoke run, use
`-f suite=smoke`. To run one tool, use `-f tool=sqlsim` or
`-f tool=sqlpysim`.

Find the run just started and wait for its result:

```powershell
gh run list --repo microsoft/sqlsimtools --workflow live-validation.yml `
    --event workflow_dispatch --branch main --limit 5
gh run watch <run-id> --repo microsoft/sqlsimtools --exit-status
```

If the run fails, inspect the logs and download the retained artifacts:

```powershell
gh run view <run-id> --repo microsoft/sqlsimtools --log
gh run download <run-id> --repo microsoft/sqlsimtools `
    --name live-validation-logs --dir "$env:TEMP\sqlsim-live-validation"
```

Report the run URL, source ref and commit, SQL Server build, each suite's
passed/failed/skipped counts, and the relevant failure output. Do not report a
failed or cancelled suite as a successful validation.
