# Maintained macOS ARM64 support plan

## Objective and current status

macOS must become a maintained build, packaging, and validation target, not a
platform supported only by a one-time volunteer campaign. The initial scope is
Apple Silicon with macOS 15 or later; Intel Macs are not in scope.

All three tools remain **Private Preview**. Building a candidate or collecting
positive feedback does not promote support status. The maintainers own the
gates below; volunteers provide additional real-machine, browser, installation,
and SQL-environment coverage.

The current implementation provides:

- A native Apple Silicon build of sqlsim and a source package of sqlpysim.
- A self-contained ARM64 Studio with both engines.
- Extracted-package layout/architecture/entry-point checks.
- A self-contained tester kit assembled from the same candidate packages and
  the canonical suites, with explicit live/load-test consent and JSON reports.
- A macOS workflow for relevant PRs, pushes to main, and manual dispatch.
- Automated offline execution of the extracted tester kit before upload.

These checks do not establish live database correctness, signing/notarization,
Finder launch, or browser-specific behavior.

## Stage 1: continuously maintain offline validation

The maintainer acceptance gate for changes affecting macOS is a successful
[macOS workflow](.github/workflows/sqlsim-macos-arm64-private-preview.yml).
Do not bypass it because another platform passes.

On every relevant PR and main update:

1. Build native ARM64 sqlsim and Studio with the existing per-tool scripts.
2. Publish the three packages and extract them into clean directories.
3. Validate architecture, manifests, licenses, agent guidance, help/version,
   and startup.
4. Assemble the tester kit from those exact extracted packages and canonical
   suites; archive it, extract it again, and run its offline tier.
5. Check suite syntax, CLI inventory parity, and the runner's refusal of
   incomplete credentials or unacknowledged live/load testing.
6. Preserve reports, build receipts, and checksums. Never upload credentials.

Use one maintained Unix CLI suite for Linux and macOS; fix portability in the
source suite rather than editing generated kits. Keep platform-specific
assertions explicit and preserve the existing Windows/Bash test inventories.
Keep Studio's PowerShell suites shared across platforms.

Repository branch-protection settings are not changed by this work. A
maintainer should decide whether to require the macOS check once its PR-triggered
workflow has a stable baseline and its check name is available.

## Stage 2: establish maintainer-owned live automation

**The live-testing backend has not been selected or provisioned.** Evaluate
these options before implementing live CI:

| Option | Advantages | Costs and constraints |
| --- | --- | --- |
| GitHub-hosted Apple Silicon + dedicated Azure SQL test database | No Mac hardware ownership; isolated disposable data; direct Azure SQL/authentication coverage | Cloud cost, network/firewall setup, least-privilege identity, token renewal; does not cover every SQL Server/MI/Fabric feature |
| GitHub-hosted Apple Silicon + existing reachable SQL Server test instance | Reuses SQL Server fixtures; covers engine-specific features | Secure network access from ephemeral runners, isolated database, identity and availability ownership |
| Maintainer-controlled/self-hosted Apple Silicon runner | Real local installation/browser testing; access to a private test network | Hardware/cloud-Mac cost, patching, runner isolation, credential protection; never execute untrusted fork PR code on a privileged runner |

Record the selected backend, owner, budget, network design, credential
mechanism, and data-reset policy before enabling it. Do not widen database
firewalls or expose a local SQL instance merely to make CI pass.

The eventual live workflow must:

- Be opt-in initially and run only trusted, reviewed commits.
- Use a protected GitHub environment and scoped credentials, preferably a
  short-lived identity where the selected backend supports it.
- Run the same packaged tester kit, never a separate CI-only test inventory.
- Run smoke first, then full suites against disposable test data with explicit
  concurrency limits and separate approval for scale tests.
- Fail on test failures and distinguish product defects, harness failures,
  permission/feature skips, and infrastructure failures.
- Produce sanitized, commit-linked reports without credential files or raw
  customer data; clean up test objects and credentials even on cancellation.

Required initial live coverage is SQL authentication and Azure SQL access-token
authentication for both engines and Studio, on the appropriate selected
targets. If the first backend cannot exercise both, leave the missing coverage
open and plan a second target. Kerberos, managed identity, service principal,
MI, and Fabric must be tracked individually rather than inferred from another
authentication mode or product.

Until this infrastructure exists, maintainers must explicitly record the live
validation gap. Volunteer results can inform fixes but are not a substitute
for repeatable release validation.

## Stage 3: installation, browser, and distribution readiness

Before broader availability:

- Decide and document Developer ID signing and notarization for native
  executables and Studio; arrange certificate ownership/renewal and protected
  signing credentials.
- Validate download/extraction/quarantine behavior on a clean Mac without
  disabling Gatekeeper.
- Exercise Studio launch, reconnect, shutdown, both engines, monitoring,
  cancellation, results, and A/B comparison in real macOS browsers. WebKit
  emulation on Windows is not Safari-on-macOS evidence.
- Decide whether to add a `.app` launcher or retain the documented terminal
  launch experience; package that choice consistently.
- Document ODBC, Python/OpenSSL, minimum macOS, and architecture requirements.
- Keep the system-ICU exception for macOS explicit and test culture-sensitive
  comparisons rather than promising identical collation across platforms.
- Define reproducible candidate labels, artifact retention, update/rollback,
  and the eventual versioned release-asset path.

## Promotion and ongoing maintenance

Promotion is an explicit maintainer decision, separately for each tool. Require:

1. Green native build, packaging, and extracted-kit offline gates.
2. Recorded maintainer-controlled smoke/full live results on the release
   candidate, with SQL/authentication coverage and skips listed.
3. Clean-machine installation and actual macOS browser evidence where relevant.
4. Signing/notarization and distribution decisions completed and documented.
5. No unresolved installation, credential-handling, data-integrity,
   cancellation, or stability blockers.
6. Updated platform matrices, manuals, release notes, skills, and release
   packaging/validation for the promoted tools.

After promotion, keep macOS on relevant PR/main validation and the release
pipeline, revalidate driver/.NET/Python changes, and run the selected live
gate before every release. Evaluate newer macOS/Python versions explicitly;
do not silently raise the current minimum or imply an untested version works.
Choose a periodic live/clean-install cadence when the backend and its budget
are approved. Volunteers remain valuable for diverse environments, but the
maintainer owns release confidence and the regression baseline.
