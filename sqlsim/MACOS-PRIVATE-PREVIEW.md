# sqlsim macOS ARM64 Private Preview

This invitation-only package is for validating sqlsim on Apple Silicon. It is
not a supported public release. Use a dedicated test database, never a
production workload.

## Requirements

- Apple Silicon Mac running macOS 15 or later
- Homebrew
- Microsoft ODBC Driver 18 for SQL Server

Install the runtime dependencies:

```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew trust microsoft/mssql-release
HOMEBREW_ACCEPT_EULA=Y brew install unixodbc msodbcsql18
```

Verify the driver and package:

```bash
odbcinst -q -d
chmod +x ./sqlsim/arm64/sqlsim
./sqlsim/arm64/sqlsim --version
./sqlsim/arm64/sqlsim --help
```

## First live test

Prefer an access token for Azure SQL and pass it through standard input:

```bash
az account get-access-token \
  --resource https://database.windows.net \
  --query accessToken -o tsv |
  ./sqlsim/arm64/sqlsim -S <server>.database.windows.net -d <database> \
    -T - -N m -Q "SELECT @@VERSION"
```

For SQL authentication, pass the password through standard input:

```bash
printf '%s\n' "$SQLSIM_PASSWORD" |
  ./sqlsim/arm64/sqlsim -S <server> -d <database> -U <user> -P - \
    -N m -Q "SELECT @@VERSION"
```

Do not use Microsoft Entra interactive authentication on macOS. Use an access
token, managed identity, service principal, Kerberos integrated
authentication, or SQL authentication.

## What to validate

1. Record the macOS version and `uname -m` output.
2. Record the ODBC Driver 18 version from `brew list --versions msodbcsql18`.
3. Run `--version` and `--help`.
4. Run a single query against a non-production SQL Server or Azure SQL target.
5. Run a small workload before increasing concurrency.
6. Capture JSON with `-json -q -o result.json`.
7. Stop if authentication, TLS, stability, or data-integrity behavior is
   unexpected.

## Feedback

Report non-sensitive results through the sqlsimtools macOS ARM64 Private
Preview channel or the repository welcome discussion:
<https://github.com/microsoft/sqlsimtools/discussions/11>.

Include the tool version, macOS version, architecture, ODBC driver version,
target SQL product/version, authentication mode, sanitized command, and JSON
result. Never include passwords, access tokens, connection strings containing
credentials, customer data, or other secrets. Report security vulnerabilities
privately by following
<https://github.com/microsoft/sqlsimtools/security/policy>.
