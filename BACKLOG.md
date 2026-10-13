# sqlsimtools backlog

_Last reviewed: 2026-10-12._

This is a working document, not a committed roadmap. Items may be reordered,
rewritten, or dropped as priorities change. To propose work or follow a
specific item, open a
[GitHub issue](https://github.com/microsoft/sqlsimtools/issues) or start a
[discussion](https://github.com/microsoft/sqlsimtools/discussions).

## Release status

| Component | Public availability | Preview status |
| --- | --- | --- |
| `sqlsim` | Windows x64, Windows ARM64, and Ubuntu x64 | Public Preview. |
| `sqlpysim` | Source distribution validated on Windows x64 and Ubuntu 24.04 and 26.04 LTS x64 | Public Preview; compatibility work continues. |
| `sqlsim Studio` | v1.0 Public Preview on Windows x64 | Ubuntu x64, Windows ARM64, and macOS ARM64 are in invitation-only Private Preview pending platform validation; macOS also requires signing and notarization decisions. |

Platform support targets SQL Server 2019, 2022, and 2025, Azure SQL Database,
Azure SQL Managed Instance, and SQL database in Microsoft Fabric.

## Open

### Testing and validation

- **Close the sqlpysim workload and live-telemetry gaps.** Agreed as the next
  piece of work, in this order, because the three share plumbing and together
  restore what Studio currently disables for the Python engine:
  1. ~~`-workload` for mixed workload groups, per-group threads, think time and
     duration mode.~~ Implemented, and enabled in Studio. sqlpysim parses the
     same file format with the same validation and wording, expands groups
     into per-thread assignments, and reports the same text header and JSON
     `workloads` array. Studio now accepts `mode=workload` for the Python
     engine and leaves the Workload tab selectable. Covered by ten tests in
     sqlpysim's suite, eight scenarios in
     [scripts/check-engine-parity.ps1](scripts/check-engine-parity.ps1), and
     Studio's own suites.
  2. ~~`-stream-json` for the `started`, `progress` and `completed` events.~~
     Implemented, and enabled in Studio. sqlpysim emits the same three event
     types with the same field names and ordering, on the same one-second
     tick, with cumulative counters and a running-average throughput. It
     implies JSON mode. Both engines accept
     `-stream-json -json -o <file>` to preserve canonical final results while
     streaming. Studio accepts live telemetry for the Python engine and
     leaves the option selectable. Covered by four tests in sqlpysim's smoke
     suite, ten in its full suite, five scenarios in
     [scripts/check-engine-parity.ps1](scripts/check-engine-parity.ps1), and
     Studio's API and GUI suites.
  3. ~~`-querystats-interval` and `-querystats-file` for periodic query-stat
     snapshots.~~ Implemented, and enabled in Studio. sqlpysim writes the same
     snapshot shape with the same nested blocks and field names, on the same
     cadence, replacing the file atomically so a reader never sees a partial
     write. The interval implies `-querystats`, defaults its file to
     `querystats-live.json`, and swallows write failures, all matching sqlsim.
     Studio now accepts runtime statistics for the Python engine. Covered by
     four tests in sqlpysim's smoke suite, ten in its full suite, five
     scenarios in
     [scripts/check-engine-parity.ps1](scripts/check-engine-parity.ps1), and
     Studio's API and GUI suites.
- **Investigate the remaining sqlpysim differences before deciding on them.**
  Deliberately pending. The list below separates what has been measured from
  what is only claimed in [RELEASE-NOTES.md](RELEASE-NOTES.md), because the two
  have not been distinguished before and reasoning about this surface has
  proved unreliable: of two hypotheses formed and then tested in September
  2026, one was confirmed and one refuted.
  - *Verified.* `-p` warns and runs unprepared. `-app` is rejected because
    `mssql-python` reserves the application name and always reports
    `MSSQL-Python`; Studio disables the field for sqlpysim. `-F` is not exposed
    in v1.0; support will be investigated for a future release. `-replay` and
    `-replayfile` are deliberately deferred from the v1.0 Public Preview;
    future support may be considered, while `sqlsim` remains the supported
    replay engine. Documented in
    [sqlpysim/sqlpysim.md](sqlpysim/sqlpysim.md).
  - *Claimed, unverified.* Nothing outstanding: JSON field names and supported
    configuration/operation shapes now match, both tools time execution through
    result consumption, both report zero fetch operations in JSON mode, and
    both use `SET STATISTICS TIME/IO` for `-querystats`.
  - *Needs measurement rather than engineering.* Nothing outstanding: Studio's
    block on `statisticsSource=runtime` for sqlpysim was the last item here,
    and it has been lifted now that `-querystats-interval` and
    `-querystats-file` are implemented and compared against sqlsim.
  - *Likely permanent rather than pending.* `-p` cannot reproduce sqlsim's
    prepare/execute mode for complete SQL text because `mssql-python` prepares
    only executions with bound parameters, and sqlpysim has no
    parameter-binding input. `-app` is reserved by `mssql-python`. Listing
    these beside fixable gaps makes the surface look larger and vaguer than it
    is.
- **Make sqlpysim as compatible with sqlsim as the driver permits.** Close the
  CLI, behavior, and output gaps cataloged in
  [RELEASE-NOTES.md](RELEASE-NOTES.md).
  [scripts/check-engine-parity.ps1](scripts/check-engine-parity.ps1) runs the
  same arguments through both engines and compares structure rather than text,
  so a difference has to be either fixed or declared. Extend its scenarios as
  coverage grows: it currently exercises single and concurrent execution, GO
  batches, failures, and output modes, and does not yet cover `-i` file input,
  reconnect, retry, encryption levels, authentication modes, or the JSON
  schema. Any difference imposed by `mssql-python` should remain explicit and
  tested rather than hidden behind a general compatibility claim.
- **Extend live driver validation across platforms and authentication modes.**
  [DRIVER-COMPATIBILITY.md](DRIVER-COMPATIBILITY.md) records only combinations
  that have been proven. Remaining gaps include access-token and SQL
  authentication for `sqlpysim` on Windows; Azure SQL access-token
  authentication for `sqlsim` on Linux; managed-identity and service-principal
  authentication on Linux for both tools; and Kerberos (`-E`) on Linux, which
  requires a domain-joined host. Unvalidated combinations remain documented as
  unverified rather than supported.
- **Close the remaining Linux test-harness portability gaps.** The first full
  Linux run of both suites showed that the remaining failures are harness
  defects rather than product defects. Outstanding items: test cases that
  hard-code `-E` instead of the suite's configured authentication, fixtures
  that use Windows path separators, a harness that merges standard error into
  standard output before parsing JSON, assertions that match Windows-specific
  TLS error wording, and output-file permission tests written against Windows
  ACL semantics.
- **Guard PowerShell and bash test-suite parity.** The project deliberately
  maintains separate PowerShell and bash suites so Linux users never need
  PowerShell, which makes drift the primary risk. Each suite should declare its
  test inventory as data so a check can fail when the two diverge.
  [scripts/check-suite-parity.ps1](scripts/check-suite-parity.ps1) is the
  starting point.
- **Automate the smoke and full test suites on hosted runners.** Ubuntu runners
  can start SQL Server in a container as a live target. Windows runners include
  no SQL Server engine, so a live Windows job requires installing Developer
  Edition during the run. Azure-specific authentication coverage would stay on
  manual dispatch because it needs federated credentials and a firewall
  allowance.
- **Extend the tiered AdventureWorksLT load tests to sqlpysim.**
  [sqlsimstudio/examples/adventureworkslt](sqlsimstudio/examples/adventureworkslt)
  and the `sqlsimstudio-load-test` skill cover light, medium, and heavy runs in
  Query, SQL file, and Workload modes, but only against the sqlsim engine. Add
  the equivalent coverage for sqlpysim, limited to what that engine actually
  supports: Studio disables Replay mode and the runtime-statistics option when
  the Python engine is selected, so the matrix reduces to Query, SQL file and
  Workload modes with live progress or final results. The SQL assets themselves are engine-neutral and should be reused rather
  than duplicated. Expect different tier boundaries: the Python client's
  per-iteration overhead is higher, so the light tier's connection and iteration
  counts may need lowering to keep the run dominated by server work. Revisit the
  excluded modes as the parity work above lands.

- **Fix the race in the Studio GUI cancellation step.**
  `gui-tests/studio.spec.cjs` fails intermittently on a loaded machine. The
  trace shows a single `DELETE /api/runs/current` returning 404 at the step
  that starts a ten second `WAITFOR` and clicks Stop run. A `DELETE` with
  nothing running correctly returns 404, and Studio's own suite asserts that,
  so the 404 is the server behaving properly. The test then fails because it
  asserts the browser console is entirely clean, and a 404 is logged there
  even though `fetch` resolves normally and the client catch never fires.
  Under load the click can land after the run has already ended, so the stop
  finds nothing to stop. The fix is for the cancellation step to tolerate a
  run that finished before the click, rather than requiring a console with no
  entries at all. Not caused by the sqlpysim workload work: the failing step
  never selects sqlpysim and never touches workload mode. Whether it predates
  the shutdown changes in `daa4704` is still unestablished; an earlier attempt
  to reproduce it on a clean checkout stashed only the Studio files, so those
  changes were still present in the build under test.

### Tooling and platform coverage

- **Provide a bash equivalent of `replay/convert-xel.ps1`.** Linux users cannot
  currently capture a trace for replay without PowerShell.
- **Complete macOS ARM64 validation and decide its release path.** The native
  Apple Silicon build, offline smoke tests, and packaging already succeed in
  CI. Promotion to Public Preview depends on live validation against a real SQL
  target on Apple Silicon and a decision on signing and notarization.
- **Publish release asset checksums.** Generating a `SHA256SUMS` file as part of
  the release workflow would let users verify downloads.
- **Offer HTML reporting from sqlsim Studio.** Studio exports the canonical
  `-json` results file and a comparison bundle, which are exactly the inputs
  [`execution-report.ps1`](sqlsim/examples/reports/execution-report.ps1) and
  [`comparison-report.ps1`](sqlsim/examples/reports/comparison-report.ps1)
  consume, and the sqlsimtools package ships those scripts in `sqlsim/` beside
  Studio. Reports are still a two-step flow: export, then run the script. A
  future revision should generate both reports directly from the Results and
  Compare views, reusing the shipped generators rather than reimplementing
  them in the browser.
- **Seed the replay database context from the connection.** `currentDatabase_`
  in [odbc_connection.cpp](sqlsim/src/odbc_connection.cpp) starts empty and is
  only assigned after a successful `USE`, so replay issues `USE [database]` on
  the first event that names one even when the connection is already in that
  database. Initializing it from the connect-time database would make that
  redundant statement disappear, which matters for Azure SQL Database and SQL
  database in Microsoft Fabric: neither supports `USE` for switching databases,
  so today a single-database capture replayed into its own database still runs
  a statement that fails and is silently tolerated. Faithful switching for
  genuinely multi-database captures must keep working;
  `sqlsim/testing/clean-replay.xml` alternates between `master` and `tempdb` and
  is the fixture that covers it.

### Remaining sqlsim Studio control gaps

- **Add source-to-target database mapping for multi-database Replay.** Studio
  v1.0 accepts captures with zero or one database. A single captured database
  is redirected automatically to the database selected in Configure, while a
  capture containing multiple distinct databases is rejected during preflight.
  A future mapping UI should list every captured source database, prefill each
  destination with the same name, allow overrides, validate every destination,
  and stage private Replay XML with those mappings. Studio must continue to
  state that connectivity validation does not prove schema or data equivalence.

- **Make Studio able to run a real sqlsim workload file.** Found while
  preparing an Azure SQL Hyperscale demo from
  `azuresqlfoundations/scale/scale-workload-baseline.json`, a 250-connection,
  six-group, 120-second workload that Studio refused outright. Three separate
  gaps, in the order a user meets them:
  1. **Groups that reference SQL by path cannot be imported.** sqlsim's own
     format is `{ "file": "queries/loan-eligibility.sql", ... }`, but Import
     JSON runs in the browser, which can read only the file chosen in the
     picker. Every file-backed group is skipped, and a file where all groups
     are file-backed fails with "No groups contained inline queries". This is
     the shape real workloads are written in, so Studio currently cannot open
     most of them. A server-side import endpoint could resolve paths relative
     to the uploaded file; a file-picker for the referenced scripts is a weaker
     alternative.
  2. **`duration_seconds` is ignored and silently becomes one iteration.**
     Studio notes that it ignored the key, but a duration-mode file has no
     `iterations`, and Studio defaults a missing count to 1 — so a workload
     meant to run for two minutes runs each thread once and ends in seconds.
     Either implement duration mode or refuse the file rather than running
     something unrecognisably smaller.
  3. **`ramp_batch_size` and `ramp_delay_ms` are dropped without comment.**
     Every connection opens at once instead of in staged batches. For 250
     connections against Azure SQL that is a login storm and a materially
     different test. At minimum say so on import, as is done for
     `duration_seconds`.

  [sqlsimstudio/examples/convert-workload-for-studio.ps1](sqlsimstudio/examples/convert-workload-for-studio.ps1)
  works around the first gap by inlining the referenced scripts, and reports
  the other two. It is a stopgap: the conversion is lossy, because duration and
  ramp-up cannot be expressed in what Studio accepts.

- **Add a Get token button beside the Entra token field.** Today the user
  leaves Studio, runs
  `az account get-access-token --resource https://database.windows.net --query accessToken -o tsv`
  in a terminal, and pastes a 2,600-character string back into the browser.
  Measured during an Azure SQL Hyperscale demo, that round trip went wrong
  twice in one session: the clipboard was overwritten by an unrelated copy
  before it reached the field, and an earlier attempt returned a cached token
  with eleven minutes left, because `az` only refreshes within five minutes of
  expiry. A button that shells out to `az account get-access-token` and fills
  the field removes both failure modes.

  Requirements, mostly security:
  - The token must never reach a log, the execution log display, the command
    preview, or an exported result. It is a bearer credential with the same
    weight as a password, and the existing field is already masked.
  - Fail clearly when `az` is absent or signed out, naming the command to run,
    rather than surfacing a raw CLI error.
  - Offer a tenant override. `az` defaults to the signed-in tenant, which is
    not necessarily the one hosting the target server.
  - Show the expiry time once filled, and warn below roughly ten minutes. An
    access token is presented per connection at connect time, so a run that
    starts before expiry completes normally; the trap is a second run started
    afterwards.
  - Keep manual paste working. A user with a token from elsewhere, or on a
    host without `az`, must not be forced through the button.

- **Validate Entra interactive, managed identity, and service principal against
  live targets.** All three are wired and their credential rules are enforced,
  but automated coverage stops at request validation. Managed identity needs an
  Azure host to exercise, and interactive needs a human at a sign-in prompt.
- **Restore the convenience actions removed for v1.0.** These were taken out of
  the interface rather than shipped disabled, and should return once
  implemented:
  - Copy the Monitor event stream to the clipboard
  - Run again, from the Results view
  - Open a completed run's configuration back in the Configure view
  - Copy, export, and clear the execution log display
- **Expose `-c` (raw connection string) and `-v` (verbose) as user-facing
  options.** Studio passes `-v` for final-results runs so exported JSON matches
  the reporting script's input, but neither flag is selectable in the interface.
- **Carry error text on the `-stream-json` progress event.** The stream reports
  an error *count* and a terminal `"status":"error"`, but never the message, and
  a failing run writes nothing to stderr. Verified with a syntax error: stderr
  empty, the completed event carried `failed_executions:1, errors:1`, and the
  only copy of `Incorrect syntax near '*'` was in the querystats snapshot.
  Studio now promotes that snapshot's `recent_errors`, so live runs with
  Runtime messages show the failing query and message, but a live run with
  statistics set to None still has no channel carrying a reason. Adding an
  `errors` array to the progress or completed event would close this for every
  live run without forcing `SET STATISTICS` overhead.
- **Design a proper results view for live-telemetry runs.** `-stream-json`
  never emits the final aggregate metrics block: a run with `-o` writes only
  the progress events to that file, so `metrics`, `avg_elapsed_ms`,
  `connection_stats`, and `odbc_driver_version` do not exist for a live run at
  any point. The Results page was built around the final JSON and currently
  fills the gaps from the terminal progress event plus, when Runtime messages
  is selected, the querystats snapshot. That leaves a live run without server
  statistics showing fewer panels than a final-results run of the same
  workload. Options worth weighing: have the engine emit a terminal summary
  event on the stream, allow a results file alongside `-stream-json`, or give
  the Results view an explicit live-run layout instead of hiding panels.
- **Revisit a derived average duration for runs without server statistics.**
  The live monitor shows measured duration only when Runtime messages is
  selected, because that is the only mode where the engine writes per-execution
  timings. A derived figure (concurrency divided by completion rate) was built
  and then removed: it matched the measured value to 1.3% while every connection
  stayed busy, but overstated by 346% once threads began finishing at staggered
  times, since it keeps dividing by connections that are no longer working. It
  is also wrong whenever workload think time is set. Worth revisiting only with
  a reliable in-flight count to divide by.

### Microsoft Entra authentication coverage

- ~~**Fix sqlpysim silently falling back to interactive sign-in.**~~ Implemented.
  sqlpysim now accepts the same four case-insensitive `-A` values as sqlsim:
  `ActiveDirectoryInteractive`, `ActiveDirectoryIntegrated`,
  `ActiveDirectoryMsi`, and `ActiveDirectoryServicePrincipal`. Unknown values
  fail instead of becoming interactive, and MSI and service-principal
  credential rules match sqlsim.
- **Investigate matching go-sqlcmd's Entra method coverage.** go-sqlcmd v1.10
  accepts fifteen `--authentication-method` values; sqlsim accepts four. The gap
  exists because go-sqlcmd uses the Go driver plus `azidentity`, while sqlsim
  goes through ODBC Driver 18, so parity may not be achievable. Confirm which
  are reachable through the driver before promising any of them.

  | Method | go-sqlcmd | sqlsim |
  | --- | --- | --- |
  | `ActiveDirectoryInteractive` | Yes | Yes |
  | `ActiveDirectoryIntegrated` | Yes | Yes |
  | `ActiveDirectoryServicePrincipal` | Yes | Yes |
  | Managed identity | `ActiveDirectoryManagedIdentity` | `ActiveDirectoryMsi` |
  | `ActiveDirectoryDefault` | Yes | No |
  | `ActiveDirectoryAzCli` | Yes | No |
  | `ActiveDirectoryDeviceCode` | Yes | No |
  | `ActiveDirectoryPassword` | Yes | No |
  | `ActiveDirectoryWorkloadIdentity` | Yes | No |
  | `ActiveDirectoryClientAssertion` | Yes | No |
  | `ActiveDirectoryAzurePipelines` | Yes | No |
  | `ActiveDirectoryEnvironment` | Yes | No |
  | `ActiveDirectoryAzureDeveloperCli` | Yes | No |
  | `ActiveDirectoryServicePrincipalAccessToken` | Yes | Partly, via `-T` |

  Highest value first if the driver allows it:
  - `ActiveDirectoryAzCli` reuses an existing `az login`, removing the
    acquire-and-paste token step the documentation currently recommends.
  - `ActiveDirectoryDefault` tries the whole credential chain, so one mode works
    on a workstation, in CI, and on an Azure host.
  - `ActiveDirectoryDeviceCode` gives headless Linux and macOS an interactive
    path, which `ActiveDirectoryInteractive` cannot provide off Windows.
- **Consider accepting go-sqlcmd's method spellings as aliases.** Translating a
  working `sqlcmd` command to sqlsim fails on managed identity because the
  spelling differs. Accepting `ActiveDirectoryManagedIdentity` as an alias for
  `ActiveDirectoryMsi` would remove a predictable papercut.
- **Persist run history across sessions.** History is in-memory and bounded, so
  Compare lists only the current session's runs. Exporting each run's JSON and
  using Compare's **Import JSON** or `comparison-report.ps1` is the current
  workaround.
- **Run the live Studio browser tests in CI.** `sqlsim Studio CI` runs on pull
  requests and pushes to `main` and covers the offline checks, including the
  interface, configuration, and responsive Playwright suites. The live suites
  (`studio.spec.cjs`, `packaged-replay.spec.cjs`, and `full-test-suite.ps1`
  without `-OfflineOnly`) need a SQL Server and still run only on demand.
- **Cover Studio's error interface in the browser tests.** `full-test-suite.ps1`
  covers the API rejection paths, but no test yet asserts that an error toast
  appears and persists, that a failed run turns the result banner red, or that
  the failure reason is shown without opening the log drawer.

### Performance follow-ups

Found in the pre-launch performance review. User-visible effects are documented
in [RELEASE-NOTES.md](RELEASE-NOTES.md); the rest are internal improvements.

- **Keep latency as running statistics.** Fixes "Very long, high-rate runs
  keep growing in memory" in [RELEASE-NOTES.md](RELEASE-NOTES.md). Replace the
  per-execution samples in both engines with running totals or a fixed-size
  histogram, which would also allow publishing p50/p95/p99.
- **Start sqlpysim workers together.** Fixes "sqlpysim threads start as they
  connect" in [RELEASE-NOTES.md](RELEASE-NOTES.md). Add a start barrier like
  sqlsim's.
- **Send Studio poll deltas.** Each 350 ms poll returns and re-renders up to 500
  log rows and the full live query table, and the server re-reads the query
  statistics snapshot for every stream event. Send only new entries and skip
  unchanged snapshots.
- **Cap remaining unbounded lists.** sqlsim keeps every failure message for the
  end-of-run console summary outside JSON mode; Studio's connection test reads
  engine output whole; and the Query Store snapshot query has no row limit.
- **Linear report generation.** `execution-report.ps1` and
  `querystats-chart.ps1` build HTML and arrays with `+=` in loops, which is
  quadratic on large result files. Use `StringBuilder` and lists, and cap the
  chart to the top queries.

## Under consideration

- **Validate server certificates by default.** sqlsim, sqlpysim, and Studio
  currently skip certificate validation unless the user opts in; see
  "Certificate validation is off unless you ask for it" in
  [RELEASE-NOTES.md](RELEASE-NOTES.md). Changing the default would protect
  credentials and tokens from interception but breaks connections to servers
  with self-signed certificates, so it needs a major-version decision, a
  migration note, and a Studio warning when trust is enabled for a remote
  server.
- **Reassess release signing and provenance if distribution expands.** The
  current sample/Public Preview tools can remain unsigned while their limited
  distribution does not justify certificate, identity-validation, and signing
  infrastructure. Revisit this if SmartScreen warnings become a support
  burden, enterprise customers require a verified publisher or application
  allow-listing, or the tools move beyond sample/preview use. Windows would use
  Authenticode through Azure Artifact Signing for executables produced by this
  repository. Linux would use authenticated checksums and build provenance for
  release archives rather than per-ELF signing. Public macOS distribution
  remains separately gated on Developer ID signing and notarization.
- **Additional workload simulators.** TPC-inspired transactional and analytical
  workloads, and a vector search simulator. See the Futures section of
  [PROJECT-GUIDE.md](PROJECT-GUIDE.md) for what each would measure. Any
  benchmark-inspired workload would use original schemas and scenarios and
  report only its own measured results.
- **Optional color themes for sqlsim Studio.** The default theme would remain.
  Any additional theme must meet WCAG AA contrast, preserve semantic success,
  warning, and error colors, and render consistently across current browsers.

## Release-note issues under investigation

Issues affecting released versions are documented in
[RELEASE-NOTES.md](RELEASE-NOTES.md), including issues under investigation for
possible future releases. Release Notes remains the source of truth for those
issues; they are not duplicated here.
