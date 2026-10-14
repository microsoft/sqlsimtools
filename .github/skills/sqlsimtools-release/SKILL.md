---
name: sqlsimtools-release
description: "Build, package, validate, and publish sqlsimtools release assets. USE WHEN: running a release candidate dry run, cutting a version, tagging a release, publishing a draft GitHub Release, verifying archive contents, diagnosing a failed release workflow, or changing any publish script. DO NOT USE FOR: running sqlsim or sqlpysim workloads (use the sqlsim or sqlpysim skills), or day-to-day source edits."
---

# sqlsimtools release

Developer skill for producing and publishing release assets. This is not
product documentation and does not ship in release archives.

Publishing requires write access to the repository. Contributors without it can
still use this skill to understand what an archive must contain and to verify a
downloaded release, but the tagging and publishing steps are maintainer-only.
To build and test from source instead, use the `sqlsimtools-build` skill.

## Release assets

Five public assets. The sqlsim and sqlpysim archives are independent; the
sqlsimtools archive bundles sqlsim Studio with the Windows x64 sqlsim archive
and the sqlpysim archive, unchanged.

| Asset | Produced by | Runner |
|-------|-------------|--------|
| `sqlsim-<ver>-win-x64.zip` | `sqlsim/publish.ps1` | windows-latest |
| `sqlsim-<ver>-win-arm64.zip` | same run, split per architecture | windows-latest |
| `sqlsim-<ver>-linux-x64.tar.gz` | `sqlsim/publish-linux.sh` | ubuntu-24.04 |
| `sqlpysim-<ver>-src.zip` | `sqlpysim/publish.ps1` | windows-latest |
| `sqlsimtools-<ver>-win-x64.zip` | `release/build-sqlsimtools-bundle.ps1` from the sqlsim x64 and sqlpysim archives plus `sqlsimstudio/build.ps1` output | windows-latest |

`release/stage-release-assets.ps1` attaches these five versioned packages and
nothing else. The README links to `releases/latest`, the newest published
release page, so it never needs a version edit. The script fails if any package
is missing.

The workflow also builds and validates
`sqlsimstudio-<ver>-linux-x64.tar.gz` as an Actions artifact for invited
Private Preview testing. It is not attached to the public GitHub Release.

`<ver>` has no `v` prefix. A tag `v1.0.0` produces `1.0.0`.

## Required archive contents

The sqlsim and sqlpysim archives are project overlays. They extract at a
consumer project root and must not nest their payload any deeper.

```text
.github/agents/sqlsimtools-workload-builder.agent.md
.github/skills/<tool>/SKILL.md
<tool>/AGENTS.md
<tool>/LICENSE
<tool>/THIRD-PARTY-NOTICES.md
<tool>/<tool>.md
<tool>/examples/
```

Plus the payload: `sqlsim/x64/sqlsim.exe` and `sqlsim/ARM64/sqlsim.exe` on
Windows, `sqlsim/x64/sqlsim` on Linux, or `sqlpysim/sqlpysim.py` with
`requirements.txt` and `setup.py`.

The sqlsimtools archive is both overlays plus Studio in its own folder. Studio
runs the bundled engines from `../sqlsim/x64` and `../sqlpysim`, so the bundle
carries no second copy of either:

```text
README.md
.github/skills/{sqlsim,sqlpysim,sqlsimstudio}/SKILL.md
.github/agents/sqlsimtools-workload-builder.agent.md
sqlsim/...              the complete sqlsim win-x64 archive
sqlpysim/...            the complete sqlpysim archive
sqlsimstudio/sqlsimstudio.exe
sqlsimstudio/sqlsimstudio.md
sqlsimstudio/sqlsimstudio.html
sqlsimstudio/CONFIGURATION.md
sqlsimstudio/sqlsimstudio-cleanup.ps1
sqlsimstudio/examples/
sqlsimstudio/LICENSE
sqlsimstudio/THIRD-PARTY-NOTICES.md
```

The bundle script refuses differing overlapping files, an ARM64 sqlsim payload,
and missing entry points. The `build-sqlsimtools` job then validates the bundle
with `validate-package-layout.ps1` for both tools, the Studio startup smoke
test, and the Studio offline suite, which proves Studio finds the bundled
sqlsim. The Private Preview Linux Studio artifact remains a standalone Studio
build with its own engine copies:

```text
sqlsimstudio
sqlsim/sqlsim
sqlpysim/sqlpysim.py
sqlpysim/requirements.txt
.github/skills/sqlsimstudio/SKILL.md
sqlsimstudio.md
CONFIGURATION.md
examples/
LICENSE
THIRD-PARTY-NOTICES.md
```

Studio also ships native libraries beside the executable. `PublishSingleFile`
bundles managed assemblies only; the operating system loader requires native
libraries on disk. Do not treat `icudt72.dll`, `icuin72.dll`, `icuuc72.dll`, or
`Microsoft.Data.SqlClient.SNI.dll` as packaging defects. App-local ICU is
pinned deliberately so string comparison and sorting stay identical across
machines.

## Parity rule

Four publish paths stage the same logical layout and drift independently:

- `sqlsim/publish.ps1`
- `sqlsim/publish-linux.sh`
- `sqlpysim/publish.ps1`
- `sqlsimstudio/build.ps1` and `sqlsimstudio/build-linux.sh`
- `release/build-sqlsimtools-bundle.ps1`

When adding or renaming any staged file, update every affected script in the
same change, then add the path to `release/validate-package-layout.ps1` or to
the sqlsimtools and Linux Studio checks in `.github/workflows/release.yml`. A file that only one
platform stages is a defect that reaches users as a missing license, a missing
agent file, or a failed release job.

The sqlsim and sqlpysim publishers also install into existing projects, so
they must never delete project files or silently replace one that differs.
`sqlsim/publish.ps1` and `sqlpysim/publish.ps1` share
`release/OverlayInstall.psm1` for this; `sqlsim/publish-linux.sh` implements
the same rules. Keep `release/test-overlay-install.ps1` and
`release/test-overlay-install-linux.sh` passing; sqlsim CI runs both.

## Workflow triggers

`.github/workflows/release.yml` runs two ways.

| Trigger | Result |
|---------|--------|
| `workflow_dispatch` with a version input | Builds and validates every asset, uploads GitHub Actions artifacts only. No tag, no Release. |
| Push a tag matching `v*.*.*` | Builds everything and creates a draft GitHub Release for review. |

Only the tag path has `contents: write`. Manual runs cannot publish.

The workflow does not modify in-tree version constants. Its first job,
`verify-version`, runs `release/check-release-version.ps1` and fails the run
unless the tag or RC label (ignoring a `v` prefix and any `-rc` suffix) matches
the version in every one of these files:

- `sqlsim/include/version.h` (`SQLSIM_VERSION`)
- `sqlsim/CMakeLists.txt` (`project(sqlsim VERSION ...)`)
- `sqlpysim/sqlpysim.py` (`__version__`)
- `sqlpysim/setup.py` (`version=`)
- `sqlsimstudio/server/SqlsimStudio.csproj` (`<Version>`)

Bump all five in the release PR, then confirm locally before tagging:

```powershell
./release/check-release-version.ps1 -Version v1.0.1
```

## Release candidate dry run

Always dry run before tagging.

```powershell
gh workflow run release.yml --ref main -f version=1.0.0-rc1
gh run list --workflow=release.yml --limit 1
gh run watch <run-id>
```

Download and inspect the artifacts:

```powershell
gh run download <run-id> --dir ./rc-artifacts
```

For each archive, extract to an empty directory and confirm:

- The overlay paths above exist, with no extra wrapper directory.
- `sqlsim --version` and `sqlsim -h` run from the extracted copy.
- `LICENSE` and `THIRD-PARTY-NOTICES.md` are present in every archive.
- The workload-builder agent is present in both sqlsim and sqlpysim archives.

The workflow already extracts each archive and runs
`release/validate-package-layout.ps1` against it, runs the Studio smoke test
and offline suite against the sqlsimtools bundle, and smoke tests the Private
Preview Linux Studio build. A green run means layout and startup
passed; it does not mean the tools were exercised against a live SQL target.

## Publish a version

Use semantic versioning: patch for a fix, minor for a compatible feature,
major for a breaking CLI or output change.

```powershell
git checkout main
git pull
git tag v1.0.0
git push origin v1.0.0
```

The tag starts the workflow and creates a draft Release with generated notes.
Review the draft and its assets, then publish it in the Releases UI.

Do not move a published tag, replace assets on an existing release, or delete
older releases. Ship a new patch version instead.

## Local builds

`release/publish.ps1 -PublishAll` runs each tool's publish script in sequence
and stages output under `release/sqlsimtools/1.0/`. That directory is ignored
by Git, is not the release pipeline, and can be stale. Never use it to judge
what an archive contains. Use artifacts from a dry run instead.

## Rules

1. Never tag without a passing dry run on the same commit.
2. Never edit one publish script without checking the other three.
3. Every archive ships `LICENSE` and `THIRD-PARTY-NOTICES.md`.
4. Parse JSON with a structured parser. Do not append `2>&1` or pipe tool
   output through text filters when capturing results.
5. Treat a validation failure as a packaging defect, not a flaky run.
