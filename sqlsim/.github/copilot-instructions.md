# Copilot Instructions for sqlsim

## Building the Code

On Ubuntu 24.04/26.04 LTS x64, use:

```bash
bash ./build-linux.sh
bash ./smoke-test-linux.sh --skip-build
```

The Ubuntu Release binary is `build/linux-x64/sqlsim`. Do not invoke CMake directly.

For the Private Preview macOS Apple Silicon path, use:

```bash
bash ./build-macos.sh
bash ./smoke-test-macos.sh --skip-build
```

The Private Preview macOS ARM64 binary is `build/macos-arm64/sqlsim`. Do not invoke CMake directly. Treat macOS as invitation-only while customer and tester validation, live SQL testing, signing, and notarization decisions remain incomplete.

On Windows, always use the build script to compile **both architectures**:

Always use the build script to compile **both architectures**:
```powershell
.\build.ps1
```
Do NOT use cmake, msbuild, or other build commands directly.

**CRITICAL**: Always build both architectures (x64 and ARM64) by running `.\build.ps1` without `-Architecture`. Do NOT use `-Architecture x64` to build only one platform, even during iterative development. Both architectures must compile cleanly before testing.

Use `-Architecture x64` or `-Architecture ARM64` to build only one architecture when the user explicitly requests it.
- **x64**: `build\x64\Release\sqlsim.exe`
- **ARM64**: `build\ARM64\Release\sqlsim.exe`

**Note:** There is NO `build\Release\` folder - always use the architecture-specific paths.

After a successful build, ask the user whether to run:
- `.\full-test-suite.ps1 -SkipBuild` (comprehensive validation, ~15 seconds)
- `.\publish.ps1` (create release package for distribution)

**Note:** Always use `-SkipBuild` when running tests immediately after `.\build.ps1` to avoid redundant rebuilds.

When adding a live test, build its arguments from the suite's auth arguments and
launch sqlsim through the suite's launcher (`& $runSqlsim` or `Invoke-Sqlsim` in
PowerShell, `with_secret` in Bash). The launcher hands the token or password over
on stdin; calling the executable directly with the auth arguments fails, because
`-T -` expects the secret on stdin. Add the test to the PowerShell and Bash suites
together; `scripts/check-suite-parity.ps1` checks.

## Checking Terminal Output Before Acting

**CRITICAL**: Before running any command (build, test, or sqlsim.exe), ALWAYS check the VS Code terminal context first:
- Look at `Last Command:` to see what the user already ran
- Look at `Exit Code:` to see if it succeeded (0) or failed (non-zero)
- Do NOT re-run commands the user has already executed successfully
- If the user just ran a command, ask about the results or wait for them to share output instead of running it again

## Running sqlsim for Testing/Debugging

**CRITICAL**: Always use valid syntax when running sqlsim. Authentication is REQUIRED.

### Valid Command Patterns

```powershell
# Minimal connection test (Windows Auth)
.\build\x64\Release\sqlsim.exe -S localhost -E

# Query with Windows Auth
.\build\x64\Release\sqlsim.exe -S localhost -E -Q "SELECT @@VERSION"

# Query with database specified
.\build\x64\Release\sqlsim.exe -S localhost -d testdb -E -Q "SELECT 1"

# Multiple threads/iterations
.\build\x64\Release\sqlsim.exe -S localhost -E -Q "SELECT 1" -n 4 -r 10

# Verbose mode
.\build\x64\Release\sqlsim.exe -S localhost -E -Q "SELECT 1" -v

# JSON output
.\build\x64\Release\sqlsim.exe -S localhost -E -Q "SELECT 1" -json

# Input file
.\build\x64\Release\sqlsim.exe -S localhost -E -i examples\sql\01-simple-queries.sql

# Quiet mode (suppress results)
.\build\x64\Release\sqlsim.exe -S localhost -E -Q "SELECT 1" -q
```

### Authentication Options (one REQUIRED)

| Option | Description |
|--------|-------------|
| `-E` | Windows Authentication |
| `-A` | Microsoft Entra (interactive) |
| `-A ActiveDirectoryMsi` | Managed Identity |
| `-T <token>` | Access token |
| `-U <user> -P <pass>` | SQL Authentication |

### Common Invalid Patterns (DO NOT USE)

```powershell
# WRONG: Missing authentication
.\build\x64\Release\sqlsim.exe -S localhost -Q "SELECT 1"

# WRONG: Long option names not supported (except --help)
.\build\x64\Release\sqlsim.exe --server localhost

# WRONG: Unix-style double-dash options
.\build\x64\Release\sqlsim.exe --verbose
```

### Getting Help

```powershell
# Any of these show help:
.\build\x64\Release\sqlsim.exe
.\build\x64\Release\sqlsim.exe -h
.\build\x64\Release\sqlsim.exe -?
.\build\x64\Release\sqlsim.exe --help
```

### Key Parameters

| Parameter | Description |
|-----------|-------------|
| `-S <server>` | Server name (defaults to localhost if omitted) |
| `-d <database>` | Database name (optional) |
| `-Q <query>` | Query string (use GO on own line for multiple batches) |
| `-i <file>` | Input file with queries |
| `-n <threads>` | Number of concurrent threads (default: 1) |
| `-r <iterations>` | Iterations per thread (default: 1) |
| `-v` | Verbose mode |
| `-q` | Quiet mode |
| `-json` | JSON output |
| `-o <file>` | Output to file |
| `-stoponerror` | Stop on first error |

## CRITICAL: Code Change Workflow (Follow This Order!)

**⚠️ MANDATORY: Before ANY code change, say aloud:**

> "This change affects **[type]**. Per the dependency table, I must also update **[list of files]**."

If Copilot skips this step, stop it immediately and ask: "What does your copilot-instructions say about this type of change?"

---

### BEFORE Editing Any Code:

1. **STOP: Search for ALL related occurrences FIRST** - Use grep/search to find everywhere the string or pattern appears:
   - Source files (src/*.cpp, include/*.h)
   - Tests (smoke-test.ps1, full-test-suite.ps1)
   - Documentation (sqlsim.md, BUILD.md, README.md, SETUP.md)
   - Examples (examples/sql/*.sql, examples/powershell/*.ps1)
   
   **List all files that will need changes BEFORE proceeding.**

2. **STOP: Read documentation FIRST** - Check sqlsim.md BEFORE making changes to understand:
   - Current sample outputs that may need updating
   - Feature descriptions that may need updating
   - Parameter tables that may need changes
   - Behavioral descriptions that may conflict with your changes

### DURING Code Changes:

3. **Update ALL affected files in a SINGLE response** (not separately):
   - Source code (src/*.cpp, include/*.h)
   - Tests (smoke-test.ps1, full-test-suite.ps1)
   - Documentation (sqlsim.md, BUILD.md, README.md, SETUP.md)
   - Examples (examples/sql/*.sql, examples/powershell/*.ps1)
   
   **Do NOT wait for user to ask "what about docs?" - include them proactively.**

### AFTER Editing Code:

4. **Build and evaluate sqlsim.md**:
   ```powershell
   .\build.ps1
   ```
   After ANY code change, you MUST:
   - Build with `.\build.ps1`
   - Evaluate whether sqlsim.md needs updates (sample outputs, parameter docs, behavior descriptions)
   - Ask the user: "Should I run full-test-suite.ps1 -SkipBuild?"

5. **Run the chosen test suite** - Do NOT consider a change complete until all tests pass.

6. **Verify test counts** - If you add or remove tests, update the test counts in:
   - smoke-test.ps1 (header comment and output message)
   - BUILD.md (smoke test and full test suite counts)
   - README.md (test counts)

### BEFORE Saying "Done":

7. **Review the dependency table below** - For each type of change made, verify all dependent files were updated.

8. **Ask about publishing** - If you changed sqlsim.exe behavior OR sqlsim.md, ask the user:
   "Would you like to publish? Run `.\publish.ps1` to create a release package."

9. **Validate release package** - After publishing, if example scripts were changed, remind user:
   "Run `.\test-nonazure-release-examples.ps1` to validate the release package works correctly."
   For Azure testing: `.\test-azure-release-examples.ps1 -ServerName <server>`

10. **Evaluate README.md and BUILD.md** - If you changed smoke-test.ps1 or full-test-suite.ps1, check whether:
   - Test counts in README.md need updating
   - Test counts in BUILD.md need updating
   - Test descriptions need updating

## Key Dependencies (If X changes, update Y)

| If you change... | You MUST also update... |
|------------------|------------------------|
| Output format/text | Tests that validate output, sqlsim.md sample outputs |
| Command-line parameters | Help text in main.cpp, sqlsim.md parameter tables, tests |
| JSON output fields | JSON schema docs in sqlsim.md, JSON validation tests, examples/powershell/json-output-examples.ps1 |
| Error messages | Tests that expect specific error text |
| Terminology (e.g., "batches" vs "queries") | ALL files - grep to find every occurrence |
| Examples in -? help text | test-examples.ps1, sqlsim.md, full-test-suite.ps1 example validation tests |
| Examples in sqlsim.md | test-examples.ps1, full-test-suite.ps1 example validation tests |
| Examples folder (add/remove/rename) | test-examples.ps1, sqlsim.md "Example Files" section, examples/README.md, release validation scripts |
| Example scripts in examples/powershell/*.ps1 | test-nonazure-release-examples.ps1, test-azure-release-examples.ps1 |
| Report generators in examples/reports/*.ps1 | Encode JSON-derived HTML values and coerce JavaScript numbers; run test-reports.ps1 |
| Test count (add/remove tests) | smoke-test.ps1 header, BUILD.md test counts, README.md |
| Version number | src/main.cpp, sqlsim.md, README.md |
| Verbose vs non-verbose behavior | Both text and JSON output paths, related tests |

## Security and Performance Review Threshold

**After significant code changes, ask the user whether to run a security and performance review.**

### What triggers this prompt:
- **3+ source files modified** in a single session (src/*.cpp, include/*.h)
- **New feature added** that involves user input, network, or file I/O
- **Authentication or connection handling** changes
- **Memory management** changes (allocations, buffers, string handling)
- **Concurrency/threading** changes
- **Any change to ODBC calls** or SQL execution paths

### When threshold is met, ask:
> "This session involved significant code changes ([list types: e.g., 'memory handling, threading, user input']). Would you like me to perform a security and performance review before we finalize?"

### Security review checks:
- Buffer overflow risks
- SQL injection vectors
- Input validation
- Memory leaks
- Credential handling
- Error message information disclosure

### Performance review checks:
- Unnecessary allocations in hot paths
- String copying vs. references
- Connection pooling efficiency
- Lock contention in multi-threaded code
- I/O batching opportunities

## Do NOT

- Use cmake/msbuild directly (always use build.ps1)
- Skip running full-test-suite.ps1 after code changes
- Say "done" or "ready to publish" without verifying the dependency table above
- Write to `std::cout` or `std::cerr` directly, or change their formatting state. Use `TS_OUT` / `TS_ERR` for timestamped lines, `ConsoleMessage(std::cout)` for untimestamped messages, or build multi-line output in a local `std::ostringstream` and pass it to `ConsoleOutput::write` (`include/console_output.h`). Put `std::fixed` / `std::setprecision` in the same statement as the value they format.

## Useful Grep Patterns

```powershell
# Find all occurrences of a string across source, tests, and docs
Get-ChildItem -Recurse -Include *.cpp,*.h,*.ps1,*.md | Select-String "pattern"

# Find output format strings
Get-ChildItem -Recurse -Include *.cpp | Select-String "TS_OUT|ConsoleMessage|ConsoleOutput::write"

# Find test expectations
Get-ChildItem -Include *.ps1 | Select-String "ExpectedOutput"
```
