# Workload Definitions

JSON files for `sqlpysim -workload`. A workload runs several query groups at
once, each with its own thread count, iteration count or duration, and think
time. See [Workload Parameters](../../sqlpysim.md#workload-parameters) for the
format.

| File | What it runs | Database |
| --- | --- | --- |
| `workload-basic.json` | Two groups in iteration mode with think time | Any |
| `workload-duration.json` | Two groups in duration mode with think time | Any |

## Run a workload

From the `sqlpysim` folder:

```powershell
python sqlpysim.py -S localhost -d tempdb -E -C -workload examples\workload\workload-basic.json -q
python sqlpysim.py -S localhost -d tempdb -E -C -workload examples\workload\workload-duration.json -json -o results.json
```

sqlpysim accepts the same workload format as sqlsim, so the workloads in
`sqlsim/examples/workload/` also run with sqlpysim. Run those from the `sqlsim`
folder, because file paths inside a workload resolve from the current
directory:

```powershell
cd ..\sqlsim
python ..\sqlpysim\sqlpysim.py -S localhost -d tempdb -E -C -workload examples\workload\workload-test.json -q
```