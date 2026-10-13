# Copilot Instructions for sqlpysim

## Project Purpose

**sqlpysim** is a Public Preview Python implementation of sqlsim - a SQL workload simulator using Microsoft's native mssql-python driver. It shares the core query, concurrency, authentication, and reporting workflow with sqlsim, but does not yet implement every option or an identical output schema. See `../RELEASE-NOTES.md` for the current compatibility gaps.
## CRITICAL: mssql-python Driver Reference

**ALWAYS consult the official mssql-python documentation before making connection or driver changes:**
- GitHub: https://github.com/microsoft/mssql-python
- PyPI: https://pypi.org/project/mssql-python/

### Key Driver Constraints
- Import as: `from mssql_python import connect`
- **Reserved keywords** (driver-controlled, cannot be set by user):
  - `APP` / `Application Name` - driver sets this automatically
- **Supported connection string keywords**:
  - `Server`, `Database`, `Trusted_Connection`, `UID`, `PWD`
  - `Authentication` (ActiveDirectoryInteractive, ActiveDirectoryMsi, etc.)
  - `Encrypt`, `TrustServerCertificate`
  - `ApplicationIntent` (ReadOnly, ReadWrite)
  - `MultiSubnetFailover`
- **Token authentication**: Use `attrs_before` with `SQL_COPT_SS_ACCESS_TOKEN`:
  ```python
  SQL_COPT_SS_ACCESS_TOKEN = 1256
  token_bytes = token.encode("utf-16le")
  token_struct = struct.pack(f'<I{len(token_bytes)}s', len(token_bytes), token_bytes)
  conn = connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})
  ```
  **Do NOT** use `access_token=` parameter - it doesn't exist!

## Terminal Command Guidelines

Do not append diagnostic or output redirection to tool commands:

- Do not use `2>&1`, `> file`, or `| Select-String`.
- Capture output directly or with a PowerShell variable: `$result = command`.

The only approved exception is the documented secret-input pattern: use
`-P -` or `-T -` with standard input when supported. Never echo, log, display,
or persist the secret, and never place passwords or tokens in process
arguments.
## Running sqlpysim

```powershell
# SQL Server (Windows Auth)
python sqlpysim.py -S localhost -E -C -Q "SELECT 1"

# Azure SQL (Token Auth)
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
$token | python sqlpysim.py -S server.database.windows.net -d mydb -T - -Q "SELECT 1"

# Multi-threaded workload
python sqlpysim.py -S localhost -E -C -Q "SELECT 1" -n 10 -r 100 -q
```

## Key Parameters

| Parameter | Description |
|-----------|-------------|
| `-S <server>` | Server name (defaults to localhost) |
| `-d <database>` | Database name (optional) |
| `-E` | Windows Authentication |
| `-A` | Microsoft Entra (interactive) |
| `-T <token>` | Access token |
| `-U/-P` | SQL Authentication |
| `-Q <query>` | Query string |
| `-i <file>` | Input file with queries |
| `-n <threads>` | Concurrent threads (default: 1) |
| `-r <iterations>` | Iterations per thread (default: 1) |
| `-v` | Verbose mode |
| `-q` | Quiet mode (suppress results) |
| `-json` | JSON output |
| `-C` | Trust server certificate |
| `-R <intent>` | Application intent (readonly/readwrite) |

## Testing

```powershell
# Quick validation
.\smoke-test.ps1

# Comprehensive testing
.\full-test-suite.ps1

# Check prerequisites
python --version
python -c "import mssql_python"
```

When adding a live test, build its arguments from the suite's auth arguments and
launch sqlpysim through the suite's launcher (`& $runSqlPySim` or
`Invoke-SqlPySim` in PowerShell, `with_secret` in Bash). The launcher hands the
token or password over on stdin; calling `python sqlpysim.py` directly with the auth
arguments fails, because `-T -` expects the secret on stdin. Add the test to the
PowerShell and Bash suites together; `scripts/check-suite-parity.ps1` checks.

## Output Format

sqlpysim follows sqlsim's general output conventions, with documented schema
and metrics differences:
- Timestamps: `YYYY-MM-DD HH:MM:SS.mmm | message`
- Metrics: Total runtime, batches, min/max/avg times
- Verbose: 5 phases with P50/P95/P99 percentiles
- JSON: Structured with version, configuration, metrics, errors, success

## Dependencies

- Python 3.10+
- mssql-python driver (`pip install mssql-python`)

## File Structure

```
sqlpysim/
├── sqlpysim.py          # Main single-file implementation
├── README.md            # Quick start guide
├── BUILD.md             # Installation instructions
├── SETUP.md             # Developer setup
├── requirements.txt     # pip dependencies
├── setup.py             # pip install support
├── smoke-test.ps1       # Quick validation
├── full-test-suite.ps1  # Comprehensive tests
├── LICENSE
└── examples/            # powershell/, sql/, workload/, github-actions-ci/
```

## Common Mistakes

1. **Missing -C for localhost** - Use `-C` to trust self-signed certs
2. **Wrong module name** - It's `mssql-python` not `mssql`
3. **Missing authentication** - Always specify `-E`, `-A`, `-T`, or `-U/-P`

## Reference

For complete sqlsim documentation: `../sqlsim/sqlsim.md`
