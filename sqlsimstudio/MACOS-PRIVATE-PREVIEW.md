# sqlsim Studio macOS ARM64 Private Preview

This candidate is for invited Apple Silicon testers, not a supported public
release. Automated checks cover packaging, engine startup, and Studio's local
HTTP startup. Live database connections, browser integration, and workload
execution on testers' Macs still need validation.

## Requirements and launch

- Apple Silicon Mac running macOS 15 or later.
- Microsoft ODBC Driver 18 for the bundled sqlsim engine. Follow the dependency
  instructions in the separate sqlsim package's `sqlsim/MACOS-PRIVATE-PREVIEW.md`.
- A current Safari, Microsoft Edge, Google Chrome, or Firefox browser.
- Optional: Python 3.11 or later and Homebrew OpenSSL for sqlpysim.

Extract this archive into its own folder. Keep the bundled `sqlsim` and
`sqlpysim` subfolders next to the Studio executable:

```bash
chmod +x ./sqlsimstudio ./sqlsim/sqlsim
./sqlsimstudio
```

Studio is self-contained; no .NET installation is required. The candidate is
not Developer ID signed or notarized. If macOS blocks it, report the exact
message and stop; do not disable Gatekeeper or remove quarantine recursively.

To enable the optional Python engine, create its environment in the extracted
Studio folder before launching:

```bash
brew install openssl
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r ./sqlpysim/requirements.txt
./sqlsimstudio
```

## First test

Use a non-production database you have permission to load test.

1. Record `sw_vers`, `uname -m`, the Studio version, and `BUILD-INFO.txt`.
2. Confirm that Studio opens in your browser and detects the sqlsim engine.
3. Choose a server, database, and authentication mode. For Azure SQL, start
   with an access token; Entra interactive authentication on macOS is not
   validated. Never post a token or other credential in an issue.
4. Test the connection and run `SELECT 1` with one thread and one iteration.
5. Confirm results and console output appear. Then try a small repeated
   workload and cancellation before increasing concurrency.
6. If requested, repeat with sqlpysim and compare the experience, not just
   raw timing numbers.
7. Shut down through Studio's shutdown control.

Report feedback in your existing Private Preview request issue. Include the
build commit, chip, macOS version, browser, engine, target SQL product,
authentication mode, and sanitized reproduction steps. Include no passwords,
tokens, customer data, or credential-bearing connection strings.
