# sqlpysim macOS ARM64 Private Preview

This invitation-only package is for validating sqlpysim on Apple Silicon. It
is not a supported public release. Use a dedicated test database, never a
production workload.

## Requirements

- Apple Silicon Mac running macOS 15 or later
- Python 3.11 or later
- Homebrew OpenSSL

From the extracted package:

```bash
brew install openssl
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r ./sqlpysim/requirements.txt
python3 ./sqlpysim/sqlpysim.py --version
python3 ./sqlpysim/sqlpysim.py --help
```

## First live test

Prefer an access token for Azure SQL and pass it through standard input:

```bash
az account get-access-token \
  --resource https://database.windows.net \
  --query accessToken -o tsv |
  python3 ./sqlpysim/sqlpysim.py \
    -S <server>.database.windows.net -d <database> \
    -T - -N m -Q "SELECT @@VERSION"
```

For SQL authentication, pass the password through standard input:

```bash
printf '%s\n' "$SQLPYSIM_PASSWORD" |
  python3 ./sqlpysim/sqlpysim.py \
    -S <server> -d <database> -U <user> -P - \
    -N m -Q "SELECT @@VERSION"
```

Do not use Microsoft Entra interactive authentication on macOS. Use an access
token, managed identity, service principal, Kerberos integrated
authentication, or SQL authentication.

## What to validate

1. Record the macOS version, `uname -m`, and `python3 --version`.
2. Record the installed driver with
   `python3 -m pip show mssql-python`.
3. Run `--version` and `--help`.
4. Run a single query against a non-production SQL Server or Azure SQL target.
5. Run a small workload before increasing concurrency.
6. Capture JSON with `-json -q -o result.json`.
7. Stop if authentication, TLS, stability, or data-integrity behavior is
   unexpected.

## Feedback

Report non-sensitive results through the sqlsimtools macOS ARM64 Private
Preview channel or the repository welcome discussion:
<https://github.com/microsoft/sqlsimtools/discussions/13>.

Include the tool version, macOS version, architecture, Python version,
`mssql-python` version, target SQL product/version, authentication mode,
sanitized command, and JSON result. Never include passwords, access tokens,
connection strings containing credentials, customer data, or other secrets.
Report security vulnerabilities privately by following
<https://github.com/microsoft/sqlsimtools/security/policy>.
