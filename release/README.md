# Release tooling

This directory contains the repository-level packaging, bundle assembly, and
release validation tools. The authoritative release pipeline is
[`../.github/workflows/release.yml`](../.github/workflows/release.yml); these
scripts support that workflow and equivalent local validation.

## Common commands

Run commands from the repository root:

```powershell
# Stage the independently published tools locally
.\release\publish.ps1 -PublishAll

# Reuse existing binaries
.\release\publish.ps1 -PublishAll -SkipBuild

# Verify that source versions match a proposed release
.\release\check-release-version.ps1 -Version v1.0.0
```

A real release or release-candidate dry run should use the GitHub Actions
workflow described in [`../PROJECT-GUIDE.md`](../PROJECT-GUIDE.md). Local
staging output under `release/sqlsimtools/` can be stale and must not be used
as evidence that a release artifact is correct.

## Files

| File | Purpose |
| --- | --- |
| `publish.ps1` | Runs the sqlsim and sqlpysim publishers for local staging |
| `build-sqlsimtools-bundle.ps1` | Assembles the Windows sqlsimtools bundle containing Studio and both engines |
| `build-macos-tester-kit.ps1` | Assembles a self-contained macOS test installation from validated candidate packages and canonical suites |
| `run-macos-tests.ps1` | Tester-kit runner; defaults to offline checks, gates live/load testing, and writes JSON plus logs |
| `macos-tester-README.md` | Instructions shipped as the tester kit's README |
| `validate-package-layout.ps1` | Validates an extracted tool package and its documented entry points |
| `check-release-version.ps1` | Confirms version parity across every shipped tool |
| `stage-release-assets.ps1` | Stages the five versioned public release assets; the README links to the latest release page |
| `check-driver-updates.ps1` | Checks pinned and documented SQL driver versions |
| `OverlayInstall.psm1` | Shared safe overlay-install implementation |
| `test-overlay-install.ps1` | Windows overlay-install behavior tests |
| `test-overlay-install-linux.sh` | Linux overlay-install behavior tests |
| `sqlsimtools-bundle-README.md` | README placed in the assembled bundle |

Do not edit generated files under `release/sqlsimtools/`. Change the owning
tool's publish script or source files and regenerate the staging output.
