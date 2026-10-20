# Build sqlsimtools from source

Each sqlsimtools component builds independently. Use the build and publish
scripts in the component directory; they encode the supported toolchain,
architecture, output layout, and validation steps.

## Clone the repository

```powershell
git clone https://github.com/microsoft/sqlsimtools.git
cd sqlsimtools
```

For runtime installation without a source checkout, use
[INSTALL.md](INSTALL.md) instead.

## Build sqlsim

### Windows

Prerequisites:

- Visual Studio 2022 or 2026 with C++ build tools
- CMake 3.15 or later
- Windows SDK
- Microsoft ODBC Driver 18 for SQL Server

```powershell
cd sqlsim
.\check-prerequisites.ps1
.\build.ps1 -Clean -Architecture x64
.\build\x64\Release\sqlsim.exe --version
```

Use `-Architecture ARM64` to build the Windows ARM64 Public Preview binary.
See [sqlsim/BUILD.md](sqlsim/BUILD.md) for debug builds and additional options.

### Ubuntu 24.04/26.04 LTS x64

```bash
cd sqlsim
bash ./check-prerequisites-linux.sh --require-driver
bash ./build-linux.sh --clean
./build/linux-x64/sqlsim --version
```

See [sqlsim/BUILD.md](sqlsim/BUILD.md) for required packages and experimental
macOS instructions.

## Prepare sqlpysim

sqlpysim is Python source and does not require compilation.

```powershell
cd sqlpysim
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python .\sqlpysim.py --version
```

On Linux, activate the environment with `. .venv/bin/activate`. See
[sqlpysim/BUILD.md](sqlpysim/BUILD.md) and
[sqlpysim/SETUP.md](sqlpysim/SETUP.md) for platform dependencies and tests.

## Build sqlsim Studio

### Windows x64

```powershell
cd sqlsimstudio
.\build.ps1
.\build\win-x64\sqlsimstudio.exe
```

### Ubuntu x64

```bash
cd sqlsimstudio
bash ./build-linux.sh
./build/linux-x64/sqlsimstudio
```

Studio builds are self-contained and include the matching native sqlsim binary.
See [sqlsimstudio/README.md](sqlsimstudio/README.md) for the supported platform
matrix and package contents.

### macOS ARM64 Private Preview candidates

The [macOS preview workflow](.github/workflows/sqlsim-macos-arm64-private-preview.yml)
builds all three tools on a macOS 15 Apple Silicon runner using their existing
build and publish scripts. To build an invited-tester candidate without
creating a tag or public release:

```powershell
gh workflow run sqlsim-macos-arm64-private-preview.yml --repo microsoft/sqlsimtools --ref main
```

The `sqlsimtools-macos-arm64-private-preview` Actions artifact contains:

| Archive | Intended use |
| --- | --- |
| `sqlsim-macos-arm64-private-preview.tar.gz` | Complete native CLI overlay, including its macOS preview guide |
| `sqlpysim-macos-arm64-private-preview.tar.gz` | Complete Python source overlay, including its macOS preview guide |
| `sqlsimstudio-macos-arm64-private-preview.tar.gz` | Self-contained Studio with both engines and its macOS preview guide |
| `sqlsimtools-macos-arm64-tester-kit.tar.gz` | Self-contained installation of all tools plus shared offline, smoke, and full suites, fixtures, and a JSON-reporting runner |

The artifact also contains `SHA256SUMS` and `BUILD-INFO.txt`; each archive
includes the same build receipt. Distribute packages from the same successful
run to the invited cohort. Downloading Actions artifacts requires signing in
to GitHub, and the artifacts expire according to repository retention settings.
Private Preview describes support status, not access control: artifacts in
this public repository are not confidential.

The workflow extracts each archive before validation, runs CLI help/version
and layout checks, verifies Studio and its native engine are ARM64, and runs
Studio's offline startup smoke test. This does not validate live SQL
connectivity, workload execution, Finder launch, signing, or notarization.
Testers should follow the packaged preview guides and report sanitized results
in their existing request issues. macOS candidates are not public release assets.

The tester kit extracts into a new folder and does not require a checkout.
Its [README](release/macos-tester-README.md) documents dependencies, offline
checks, explicit live/load-test consent, and reports. CI runs the offline tier
from the extracted kit, not from source-tree paths. Relevant pull requests also
run the macOS workflow. The long-term live-testing backend is deliberately
undecided; see [MACOS-SUPPORT-PLAN.md](MACOS-SUPPORT-PLAN.md) for the maintained
platform plan and promotion gates.

## Prepare for source testing

After building sqlsim and preparing sqlpysim, run the shared test preflight
from the repository root:

```powershell
.\scripts\check-test-prerequisites.ps1
```

The preflight verifies the native binary, Python 3.10 or later,
`mssql-python`, ODBC connectivity, and the AdventureWorksLT test fixture. When
AdventureWorksLT is missing from a local SQL Server, it downloads Microsoft's
SQL Server 2019-compatible sample backup and restores it into the instance's
default data and log directories. The operation is idempotent: an existing
database is validated rather than replaced.

Automatic `.bak` restore is deliberately limited to a local SQL Server. For a
remote server or Azure SQL target, create or import AdventureWorksLT first and
then validate it without allowing provisioning:

```powershell
.\scripts\check-test-prerequisites.ps1 `
    -Server myserver -SkipDatabaseProvisioning
```

The fixture must contain the standard 295 `SalesLT.Product` rows and 847
`SalesLT.Customer` rows. A database with the right name but different contents
fails validation rather than being overwritten.

To compare the native and Python engines after preflight:

```powershell
.\scripts\check-engine-parity.ps1
```

The parity script invokes the shared preflight itself, so missing prerequisites
or a bad fixture fail before any scenario can be counted as a match.

Before building sqlsim or running the Bash suites under WSL, include the Linux
toolchain and driver checks:

```powershell
.\scripts\check-test-prerequisites.ps1 -IncludeLinux
```

This invokes `sqlsim/check-prerequisites-linux.sh --require-driver` inside WSL.
It requires Ubuntu 24.04 or 26.04 x64, `build-essential`, CMake,
`unixodbc-dev`, and Microsoft ODBC Driver 18. The preflight reports the
repository-supported `apt-get` command when build packages are missing.

## Install a source build into a project

To build sqlsim from this checkout and install it, with its manual, examples,
workspace skill, and Workload Builder, into an existing project on Windows, run
one command from the repository root:

```powershell
.\scripts\install-local.ps1 -Workspace C:\myproject -Build
```

Add sqlpysim with `-Tool sqlsim, sqlpysim`, choose a build with
`-Architecture x64` or `-Architecture ARM64`, and add `-Clean` for a clean
build. The script checks prerequisites, builds, installs, validates the result
without a database, and prints a receipt with the installed version and paths.

Installing never deletes project files, and keeps any files you added under
`sqlsim/examples` or `sqlpysim/examples`. If a file the release installs
already exists with different contents, such as a skill you edited, the script
lists it and stops before writing anything. Preview first, then replace those
files deliberately:

```powershell
.\scripts\install-local.ps1 -Workspace C:\myproject -Preview
.\scripts\install-local.ps1 -Workspace C:\myproject -Force
```

VS Code usually discovers the installed skill and Workload Builder without a
reload. If either does not appear in chat, run **Developer: Reload Window**.

On Ubuntu, build with `bash sqlsim/build-linux.sh`, then install with
`bash sqlsim/publish-linux.sh --skip-build --release-dir <project>`. It follows
the same rules and accepts `--preview` and `--force`.

To re-check an installed project at any time, without a database:

```powershell
.\release\validate-package-layout.ps1 -InstallRoot C:\myproject `
    -Tool sqlsim -SqlsimExecutable sqlsim/x64/sqlsim.exe
```

It checks the package layout, skill and Workload Builder frontmatter, the
binary's architecture, `--help` and `--version`, and that every option the help
lists is documented in the manual.

## Create local release-shaped output

The root local-publish orchestrator stages sqlsim and sqlpysim into one
project-overlay tree:

```powershell
cd release
.\publish.ps1 -PublishAll
```

To reuse existing native binaries:

```powershell
.\publish.ps1 -PublishAll -SkipBuild
```

Output is staged under `release/sqlsimtools/1.0/`. That directory is ignored by
Git and can be deleted after validation. The local orchestrator does not create
a GitHub Release and does not publish Studio.

Each tool can also be staged independently:

```powershell
cd sqlsim
.\publish.ps1
```

```powershell
cd sqlpysim
.\publish.ps1
```

The publish scripts include the runtime, manual, examples, `AGENTS.md`, the
workspace skill, and the shared Workload Builder in the release-shaped layout.
The `release/sqlsimtools/` staging tree is disposable and is refreshed on every
publish. Publishing anywhere else, with `-ReleaseDir`, follows the project
install rules above: nothing is deleted, files that differ require `-Force`,
and `-Preview` lists the changes without writing. Both publishers accept
`-ReportPath` to write a JSON record of created, replaced, unchanged, and kept
files.

To test those rules offline, run `.\release\test-overlay-install.ps1` after
building sqlsim, or `bash release/test-overlay-install-linux.sh` on Ubuntu.
sqlsim CI runs both.

## Validate a release candidate

The authoritative release process is
[`.github/workflows/release.yml`](.github/workflows/release.yml). Before a real
release, run it manually with an RC version:

```powershell
gh workflow run release.yml --repo microsoft/sqlsimtools --ref main `
    -f version=1.0.0-rc1
```

A manual run builds and validates downloadable GitHub Actions artifacts. It
does not create a tag or GitHub Release.

Validate at least:

- Every expected Windows and Linux asset exists, with and without the version in its name.
- Archives extract without an extra wrapper directory.
- The workflow's `validate-package-layout.ps1` step passed for every archive.
  It checks layout, frontmatter, binary architecture, `--version`, `-h`, and
  that the help and the manual list the same options.
- `.github/skills/<tool>/SKILL.md` is present.
- The sqlsimtools package contains `sqlsimstudio/sqlsimstudio.exe`, the
  complete sqlsim x64 and sqlpysim packages, and
  `.github/skills/sqlsimstudio/SKILL.md`.
- `.github/agents/sqlsimtools-workload-builder.agent.md` is present.
- `<tool>/AGENTS.md`, manuals, examples, licenses, and notices are present.
- A smoke workload succeeds against a dedicated test database.

## Publish a version

Make each change on a branch from `main` (`fix/`, `feat/`, `chore/`, or
`docs/`) and merge it through a pull request once CI passes. Routine commits and
merges never create a release.

sqlsimtools uses semantic version tags:

- Patch: compatible bug fix, such as `v1.0.1`
- Minor: compatible feature, such as `v1.1.0`
- Major: breaking CLI or output change, such as `v2.0.0`

Bump the version in the pull request that prepares the release. It lives in
`sqlsim/include/version.h`, `sqlsim/CMakeLists.txt`, `sqlpysim/sqlpysim.py`,
`sqlpysim/setup.py`, and `sqlsimstudio/server/SqlsimStudio.csproj`. Confirm all
five match the tag you plan to push; the Release workflow refuses to build when
they differ:

```powershell
.\release\check-release-version.ps1 -Version v1.0.1
```

After the RC artifacts pass validation, tag the exact tested commit:

```powershell
git checkout main
git pull
git tag v1.0.0
git push origin v1.0.0
```

The tag starts the Release workflow. It rebuilds every public asset and creates
a draft GitHub Release with generated notes. Review the draft and its assets,
then publish it in the GitHub Releases UI.

Do not move a published tag, replace assets for an existing version, or delete
older releases. Publish a new patch version instead. GitHub Releases remains
the download and version-history page, and `main` represents the latest
released source.

See [Using sqlsimtools with agents](USING-WITH-AGENTS.md) for plugin, skill,
and Workload Builder packaging behavior.
