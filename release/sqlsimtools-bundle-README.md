# sqlsimtools {{VERSION}} for Windows x64

This package contains every sqlsimtools tool:

| Folder | Tool | Start here |
| --- | --- | --- |
| `sqlsimstudio/` | sqlsim Studio, a local browser app that configures, runs, monitors, replays, and compares workloads | `sqlsimstudio/sqlsimstudio.html` |
| `sqlsim/` | sqlsim, the native C++/ODBC workload engine and command-line tool | `sqlsim/sqlsim.html` |
| `sqlpysim/` | sqlpysim, the Python port on `mssql-python` (Public Preview) | `sqlpysim/sqlpysim.html` |
| `.github/` | Agent skills for each tool and the sqlsimtools Workload Builder agent | `sqlsim/AGENTS.md`, `sqlpysim/AGENTS.md` |

The `sqlsim/` and `sqlpysim/` folders are the same as the separate sqlsim and
sqlpysim downloads. Studio runs workloads with them, so there is one copy of
each engine.

## Prerequisites

- Microsoft ODBC Driver 18 for SQL Server, for sqlsim and Studio.
- Microsoft Edge or Google Chrome, for Studio.
- Python 3.10 or later, only for sqlpysim.

## Start sqlsim Studio

```powershell
.\sqlsimstudio\sqlsimstudio.exe
```

Studio opens in your browser. Its examples are in `sqlsimstudio/examples/`,
including any-database and AdventureWorksLT queries, workloads, and Replay
captures. To compare two runs without a database, import
`sqlsim/examples/results/index-baseline.json` and `index-candidate.json` on the
Compare page.

## Use sqlpysim from Studio or the command line

Create a Python environment named `.venv` in this folder; Studio finds it
automatically:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\sqlpysim\requirements.txt
```

## Run sqlsim from the command line

```powershell
.\sqlsim\x64\sqlsim.exe -S localhost -d master -E -C -Q "SELECT @@VERSION"
```

HTML report scripts are in `sqlsim/examples/reports/`, and the XEvent Replay
tools are in `sqlsim/replay/`.

## License

MIT. See `sqlsim/LICENSE`, `sqlpysim/LICENSE`, `sqlsimstudio/LICENSE`, and each
folder's `THIRD-PARTY-NOTICES.md`.
