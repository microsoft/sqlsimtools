# Install sqlsimtools

The recommended installation method is to download a versioned archive from
[GitHub Releases](https://github.com/microsoft/sqlsimtools/releases) and extract
it into the project where you want to use the tool.

Release archives are project overlays. They include the runtime, examples,
manuals, and workspace agent guidance in their expected relative paths.

## Choose a package

Replace `<version>` with the release version shown on GitHub.

| Tool | Supported public platform | Release asset |
| --- | --- | --- |
| sqlsim | Windows x64 | `sqlsim-<version>-win-x64.zip` |
| sqlsim | Windows ARM64 | `sqlsim-<version>-win-arm64.zip` |
| sqlsim | Ubuntu 24.04/26.04 LTS x64 | `sqlsim-<version>-linux-x64.tar.gz` |
| sqlpysim | Windows or Ubuntu with Python 3.10+ | `sqlpysim-<version>-src.zip` |
| sqlsimtools: sqlsim Studio with the complete sqlsim and sqlpysim packages | Windows x64 | `sqlsimtools-<version>-win-x64.zip` |

The newest release is always at
<https://github.com/microsoft/sqlsimtools/releases/latest>; older versions are on
the [Releases](https://github.com/microsoft/sqlsimtools/releases) page.

sqlsim Studio on Ubuntu x64, Windows ARM64, and macOS ARM64 is a controlled
Private Preview for invited testers. Those packages are not attached to the
public GitHub Release. Do not treat a preview artifact as a supported public
release unless its release notes say otherwise. To ask for access, open a
[Private Preview request](https://github.com/microsoft/sqlsimtools/issues/new?template=private-preview.yml).

Validated driver versions, and what to expect from newer driver releases, are
documented in [DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md).

## Install sqlsim on Windows

1. Install [Microsoft ODBC Driver 18 for SQL Server](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server).
2. Download `sqlsim-<version>-win-x64.zip` from the release.
3. If you trust the archive downloaded from the official release, remove
   Windows' Internet security mark before extracting it:

```powershell
Unblock-File .\sqlsim-<version>-win-x64.zip
Expand-Archive .\sqlsim-<version>-win-x64.zip -DestinationPath .
```

For Windows ARM64, substitute the `win-arm64` archive name. Unblocking before
extraction prevents PowerShell from rejecting the included unsigned example
scripts under the `RemoteSigned` execution policy.

If you already extracted the archive, unblock only its PowerShell scripts:

```powershell
Get-ChildItem .\sqlsim -Recurse -File -Filter *.ps1 | Unblock-File
```

4. Verify the executable:

```powershell
.\sqlsim\x64\sqlsim.exe --version
.\sqlsim\x64\sqlsim.exe -h
```

If a script still reports that it is not digitally signed, run
`Get-ExecutionPolicy -List`. A `MachinePolicy` or `UserPolicy` of `AllSigned`
is organization-managed and requires an approved signing or execution process
from your administrator. Do not weaken a managed execution policy.

The resulting project layout includes:

```text
your-project/
|-- .github/
|   |-- agents/sqlsimtools-workload-builder.agent.md
|   `-- skills/sqlsim/SKILL.md
`-- sqlsim/
    |-- AGENTS.md
    |-- examples/
    |-- replay/
    |-- sqlsim.md
    `-- x64/sqlsim.exe
```

## Install sqlsim on Ubuntu

1. Install unixODBC and Microsoft ODBC Driver 18 using Microsoft's
   [Linux installation instructions](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server).
2. Download `sqlsim-<version>-linux-x64.tar.gz` from the release.
3. Extract it at your project root:

```bash
tar -xzf sqlsim-<version>-linux-x64.tar.gz
./sqlsim/x64/sqlsim --version
./sqlsim/x64/sqlsim -h
```

The Linux executable has no `.exe` extension. If an archive tool did not retain
its executable bit, run `chmod +x ./sqlsim/x64/sqlsim`.

## Install sqlpysim

sqlpysim requires Python 3.10 or later.

1. Download `sqlpysim-<version>-src.zip` from the release.
2. On Windows, if you trust the download, unblock it so the included PowerShell
   examples run: `Unblock-File .\sqlpysim-<version>-src.zip`.
3. Extract it at your project root.
4. Create a virtual environment and install the pinned requirements:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r .\sqlpysim\requirements.txt
python .\sqlpysim\sqlpysim.py --version
```

On Linux:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r ./sqlpysim/requirements.txt
python ./sqlpysim/sqlpysim.py --version
```

See [sqlpysim/SETUP.md](sqlpysim/SETUP.md) for platform-specific Python driver
dependencies.

## Install sqlsim Studio

sqlsim Studio is a local browser app for building, running, monitoring, and
comparing workloads. It ships in the sqlsimtools Windows x64 package, which also
contains the complete sqlsim and sqlpysim packages that Studio uses as its
engines. Studio is self-contained; you do not need to install .NET.

### Prerequisites

- Microsoft ODBC Driver 18 for SQL Server, required by the bundled `sqlsim`
  engine. See [DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md).
- Current Microsoft Edge or Google Chrome.
- Optional: Python 3.10 or later, only if you want to use the `sqlpysim`
  engine.

### Install and start

1. Download `sqlsimtools-<version>-win-x64.zip` from
   [GitHub Releases](https://github.com/microsoft/sqlsimtools/releases).
2. If you trust the download, unblock it before extracting. Studio is not code
   signed, so a blocked download triggers a SmartScreen warning when Studio
   starts, and PowerShell rejects the included example scripts. Right-click the
   ZIP, choose **Properties**, select **Unblock**, and click **OK**, or run:

   ```powershell
   Unblock-File .\sqlsimtools-<version>-win-x64.zip
   ```

   If you already extracted it, run this from the extracted folder instead:

   ```powershell
   Get-ChildItem . -Recurse -File -Include *.exe, *.ps1 | Unblock-File
   ```

3. Extract it to a folder you control, such as `C:\Tools\sqlsimtools`.
4. Double-click `sqlsimstudio\sqlsimstudio.exe`.

Studio opens your default browser. The header shows the Studio version, and the
**Execution engine** list shows the engine versions.

The extracted folder contains:

```text
README.md
sqlsimstudio\        sqlsimstudio.exe, manual, CONFIGURATION.md, examples\
sqlsim\              the complete sqlsim x64 package (x64\sqlsim.exe, manual, examples, reports, replay)
sqlpysim\            the complete sqlpysim package (sqlpysim.py, requirements.txt, manual, examples)
.github\             agent skills for each tool and the Workload Builder agent
```

Studio runs `sqlsim\x64\sqlsim.exe` and `sqlpysim\sqlpysim.py` from the
sqlsimtools folder. Keep the folder structure intact. The `sqlsim` and
`sqlpysim` folders are the same as the separate downloads, so the command-line
tools are ready to use too.

### Enable the optional sqlpysim engine

Create a Python environment named `.venv` in the sqlsimtools folder and install
the sqlpysim dependencies. The same environment runs sqlpysim from the command
line:

```powershell
cd C:\Tools\sqlsimtools
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\sqlpysim\requirements.txt
```

Refresh Studio. The engine list should show `sqlpysim <version> ·
mssql-python` without a warning.

Studio chooses Python in this order:

1. The `SQLSIM_STUDIO_PYTHON_PATH` environment variable.
2. `.venv\Scripts\python.exe` beside `sqlsimstudio.exe`.
3. `.venv\Scripts\python.exe` in the sqlsimtools folder.
4. `python` on `PATH`.

If the engine list says **Python not found** or **mssql-python not
installed**, repeat the commands above or set `SQLSIM_STUDIO_PYTHON_PATH` to the
Python executable that has `mssql-python` installed.

Open `sqlsimstudio\sqlsimstudio.html` for the browser-friendly offline manual.
The Markdown source is `sqlsimstudio\sqlsimstudio.md` in the package and
[sqlsimstudio/sqlsimstudio.md](sqlsimstudio/sqlsimstudio.md) in this repository.
See [sqlsimstudio/README.md](sqlsimstudio/README.md) for browser support,
security behavior, and preview limitations.

## Install both command-line tools

The sqlsim and sqlpysim archives can be extracted into the same project. Their
tool and skill paths do not overwrite each other. Both contain the same shared
Workload Builder at:

```text
.github/agents/sqlsimtools-workload-builder.agent.md
```

VS Code usually discovers the new skills and custom agent automatically. If a
skill or the Workload Builder does not appear in chat, reload the window
(**Developer: Reload Window**) or restart your agent client. See
[Using sqlsimtools with agents](USING-WITH-AGENTS.md).

## Upgrade

1. Download the desired newer release asset.
2. Keep workload scripts and result files outside the installed `sqlsim/` or
   `sqlpysim/` directory.
3. Replace the old tool directory with the directory from the new archive.
4. Allow the new archive to update its matching `.github/skills/` entry and the
   shared Workload Builder.
5. Run `--version` and `-h` before connecting to a database.

GitHub retains older published releases, so you can reinstall or compare an
older version from the repository's
[Releases](https://github.com/microsoft/sqlsimtools/releases) page.

## Build instead

To compile from source or create local release-shaped output, continue to
[BUILDING.md](BUILDING.md). To build from a source checkout and install into a
project in one step, use `scripts\install-local.ps1`, described in
[Install a source build into a project](BUILDING.md#install-a-source-build-into-a-project).
