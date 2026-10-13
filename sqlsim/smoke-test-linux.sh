#!/usr/bin/env bash
# Smoke test for sqlsim on Linux.
#
# Runs offline checks that need no server, then the live suite when a target is
# supplied. The live tests mirror smoke-test.ps1 so Linux users never need
# PowerShell; see --list-tests and scripts/check-suite-parity.ps1.
#
# Usage:
#   bash smoke-test-linux.sh [--skip-build]
#   bash smoke-test-linux.sh --skip-build --server HOST[,PORT] --database DB \
#        (--username USER --password-file FILE | --token-file FILE)
#   bash smoke-test-linux.sh --list-tests
#
# Live tests also accept the environment interface used by CI:
#   SQLSIM_SERVER, SQLSIM_DATABASE, SQLSIM_ACCESS_TOKEN,
#   SQLSIM_USERNAME, SQLSIM_PASSWORD

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$script_dir/build/linux-x64/sqlsim"
skip_build=false

# Live-test inventory. Keep in step with smoke-test.ps1.
TEST_NAMES=(
    "Verbose command redacts credentials"
    "Help text displays"
    "Basic connection to server"
    "Explicit -S localhost -d tempdb"
    "Simple SELECT query with output"
    "Multi-threaded query with output"
    "Authentication"
    "Query repetition (-n 100)"
    "Concurrency (25 threads x 10 iterations)"
    "Quiet mode suppresses query output"
    "Verbose mode shows details"
    "Non-verbose output uses batch terminology"
    "Invalid server error handling"
    "File input (-i flag)"
    "GO batch separators"
    "Output to file (-o flag)"
    "Application name (-app)"
    "Connection pooling (-usepool -reconnect)"
    "JSON output format (-json)"
    "Streaming JSON output format (-stream-json)"
    "Streaming JSON with canonical final result"
    "Credentials from redirected stdin (-P - and -T -)"
    "JSON output to file (-json -o)"
    "Timestamp format and output features"
    "SQL error returns exit code 1"
    "Error messages properly captured (not Unknown ODBC error)"
    "Chained error messages captured (multiple diagnostic records)"
    "RAISERROR sev 10 is info (exit code 0)"
    "PRINT + RAISERROR error combo (exit code 1)"
    "Multi-statement error in non-first statement (exit code 1)"
    "PRINT statements don't cause cursor errors"
    "PRINT statements are displayed in output"
    "PRINT control characters are sanitized"
    "PRINT statements suppressed with -q"
    "Stored proc OUTPUT param + second batch (cursor state)"
    "Multi-result proc + second batch (cursor state)"
    "Unicode data retrieval (NCHAR function)"
    "USE database message filtered (not displayed)"
    "PRINT suppressed in JSON mode (-json)"
    "Query timeout with -t (HYT00 error)"
    "-stoponerror stops execution on first error"
    "Live capture and replay (end-to-end)"
    "Basic workload file"
    "Workload with querystats"
    "sqlsim per-iteration overhead (P1)"
    "sqlsim thread scaling (P2)"
    "Duration mode workload (duration_seconds)"
)

cli_server=""
cli_database=""
cli_username=""
cli_password=""
cli_token=""

while (($# > 0)); do
    case "$1" in
        --skip-build)    skip_build=true; shift ;;
        --server)        cli_server="$2"; shift 2 ;;
        --database)      cli_database="$2"; shift 2 ;;
        --username)      cli_username="$2"; shift 2 ;;
        --password)      cli_password="$2"; shift 2 ;;
        --password-file) cli_password="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
        --token)         cli_token="$2"; shift 2 ;;
        --token-file)    cli_token="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
        --list-tests)    printf '%s\n' "${TEST_NAMES[@]}"; exit 0 ;;
        -h|--help)       sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            echo "Usage: bash smoke-test-linux.sh [--skip-build] [--server HOST] [--database DB] [--username USER --password-file FILE | --token-file FILE]" >&2
            echo "Optional live-test environment: SQLSIM_SERVER, SQLSIM_DATABASE, and either SQLSIM_ACCESS_TOKEN or SQLSIM_USERNAME plus SQLSIM_PASSWORD." >&2
            exit 2
            ;;
    esac
done

# Command-line values win; otherwise fall back to the CI environment interface.
SQLSIM_SERVER="${cli_server:-${SQLSIM_SERVER:-}}"
SQLSIM_DATABASE="${cli_database:-${SQLSIM_DATABASE:-}}"
SQLSIM_USERNAME="${cli_username:-${SQLSIM_USERNAME:-}}"
SQLSIM_PASSWORD="${cli_password:-${SQLSIM_PASSWORD:-}}"
SQLSIM_ACCESS_TOKEN="${cli_token:-${SQLSIM_ACCESS_TOKEN:-}}"

if [[ "$skip_build" == false ]]; then
    bash "$script_dir/build-linux.sh"
fi

if [[ ! -x "$binary" ]]; then
    echo "ERROR: Linux sqlsim binary not found at $binary" >&2
    exit 1
fi

passed=0
failed=0

run_test() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    local output
    local status
    set +e
    output="$($binary "$@" 2>&1)"
    status=$?
    set -e

    local ok=false
    if [[ "$expected_status" == "zero" && $status -eq 0 ]]; then
        ok=true
    elif [[ "$expected_status" == "nonzero" && $status -ne 0 ]]; then
        ok=true
    fi

    if [[ "$ok" == true && ( -z "$expected_text" || "$output" == *"$expected_text"* ) ]]; then
        echo "PASS: $name"
        ((passed += 1))
    else
        echo "FAIL: $name (exit $status)" >&2
        echo "$output" >&2
        ((failed += 1))
    fi
}

run_test "help" zero "Usage: sqlsim" -h
run_test "version" zero "sqlsim 1.0.0" --version
run_test "unknown option rejected" nonzero "Unknown option" --not-a-real-option
run_test "missing token rejected" nonzero "requires a value" -T
run_test "zero threads rejected" nonzero "Number of threads must be between 1 and 2147483647" -E -n 0
run_test "conflicting query sources rejected" nonzero "Cannot use -Q with -i" -E -Q "SELECT 1" -i query.sql
run_test "interactive Entra rejected" nonzero "ActiveDirectoryInteractive is not supported" -S localhost -A
run_test "interactive Entra rejected case-insensitively" nonzero "ActiveDirectoryInteractive is not supported" -S localhost -A activedirectoryinteractive
run_test "interactive Entra connection string rejected" nonzero "ActiveDirectoryInteractive is not supported" -c "Driver={ODBC Driver 18 for SQL Server};Server=localhost;Authentication=ActiveDirectoryInteractive;"
run_test "interactive Entra spaced connection string rejected" nonzero "ActiveDirectoryInteractive is not supported" -c "Driver={ODBC Driver 18 for SQL Server}; Server=localhost; Authentication = ActiveDirectoryInteractive;"
run_test "service principal credentials required" nonzero "ActiveDirectoryServicePrincipal requires" -S localhost -A ActiveDirectoryServicePrincipal
run_test "managed identity rejects password" nonzero "ActiveDirectoryMsi does not accept -P" -S localhost -A ActiveDirectoryMsi -P invalid
run_test "integrated Entra reaches ODBC" nonzero "ODBC" -S 192.0.2.1,1433 -A ActiveDirectoryIntegrated -l 1
run_test "managed identity reaches ODBC" nonzero "ODBC" -S 192.0.2.1,1433 -A ActiveDirectoryMsi -l 1
run_test "user-assigned identity reaches ODBC" nonzero "ODBC" -S 192.0.2.1,1433 -A ActiveDirectoryMsi -U 00000000-0000-0000-0000-000000000000 -l 1
run_test "service principal reaches ODBC" nonzero "ODBC" -S 192.0.2.1,1433 -A ActiveDirectoryServicePrincipal -U 00000000-0000-0000-0000-000000000000 -P invalid -l 1

stdin_secret="sqlsim-linux-stdin-password"
stdin_output=""
stdin_status=0
set +e
stdin_output="$(printf '%s\n' "$stdin_secret" | "$binary" -S 192.0.2.1,1433 -U stdin-user -P - -C -l 1 -Q "SELECT 1" -v -q 2>&1)"
stdin_status=$?
set -e
if [[ $stdin_status -ne 0 && "$stdin_output" != *"$stdin_secret"* && "$stdin_output" != *"requires redirected stdin"* ]]; then
    echo "PASS: password from redirected stdin"
    ((passed += 1))
else
    echo "FAIL: password from redirected stdin (exit $stdin_status)" >&2
    echo "$stdin_output" >&2
    ((failed += 1))
fi

stream_output=""
stream_status=0
set +e
stream_output="$($binary -S 192.0.2.1,1433 -E -l 1 -stream-json -q)"
stream_status=$?
set -e
if [[ $stream_status -ne 0 ]] && printf '%s\n' "$stream_output" | python3 -c '
import json
import sys

events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["type"] == "started"
assert events[-1]["type"] == "completed"
assert events[-1]["status"] == "error"
assert events[-1]["failed_connections"] >= 1
assert events[-1]["errors"] >= 1
'; then
    echo "PASS: streaming JSON failure contract"
    ((passed += 1))
else
    echo "FAIL: streaming JSON failure contract (exit $stream_status)" >&2
    echo "$stream_output" >&2
    ((failed += 1))
fi

signal_output=""
signal_status=0
set +e
signal_output="$(timeout --preserve-status --signal=INT 1 "$binary" -S 192.0.2.1,1433 -E -l 30 2>&1)"
signal_status=$?
set -e
if [[ $signal_status -eq 130 && "$signal_output" == *"Received termination signal"* ]]; then
    echo "PASS: SIGINT exits with status 130"
    ((passed += 1))
else
    echo "FAIL: SIGINT exits with status 130 (exit $signal_status)" >&2
    echo "$signal_output" >&2
    ((failed += 1))
fi

live_tests=0
live_skipped=0
if [[ -n "${SQLSIM_SERVER:-}" ]]; then
    bash "$script_dir/check-prerequisites-linux.sh" --require-driver

    server="$SQLSIM_SERVER"
    database="${SQLSIM_DATABASE:-tempdb}"

    case "$server" in
        *database.windows.net*|*database.fabric.microsoft.com*) is_azure=true ;;
        *) is_azure=false ;;
    esac

    auth_args=()
    auth_secret=""
    if [[ -n "${SQLSIM_ACCESS_TOKEN:-}" ]]; then
        auth_method="Token"
        auth_args=(-T -)
        auth_secret="$SQLSIM_ACCESS_TOKEN"
    elif [[ -n "${SQLSIM_USERNAME:-}" && -n "${SQLSIM_PASSWORD:-}" ]]; then
        auth_method="SQL Authentication"
        auth_args=(-U "$SQLSIM_USERNAME" -P -)
        auth_secret="$SQLSIM_PASSWORD"
        # Non-Azure targets commonly present a self-signed certificate.
        [[ "$is_azure" == false ]] && auth_args+=(-C)
    else
        echo "ERROR: Live tests require SQLSIM_ACCESS_TOKEN or SQLSIM_USERNAME and SQLSIM_PASSWORD." >&2
        exit 1
    fi

    # Runs a command, writing the secret to stdin when its arguments include
    # -T - or -P -, so the token or password never appears in a process list.
    with_secret() {
        local prev="" arg
        if [[ -n "$auth_secret" ]]; then
            for arg in "$@"; do
                if [[ "$arg" == "-" && ( "$prev" == "-T" || "$prev" == "-P" ) ]]; then
                    "$@" <<<"$auth_secret"
                    return
                fi
                prev="$arg"
            done
        fi
        "$@"
    }

    base=(-S "$server" -d "$database")
    testing="$script_dir/testing"
    mkdir -p "$testing"

    live_pass() { echo "PASS: $1"; ((passed += 1)); ((live_tests += 1)); }
    live_fail() { echo "FAIL: $1${2:+ - $2}" >&2; ((failed += 1)); ((live_tests += 1)); }
    live_skip() { echo "SKIP: $1${2:+ - $2}"; ((live_skipped += 1)); ((live_tests += 1)); }

    json_valid() {
        if command -v jq >/dev/null 2>&1; then jq -e . >/dev/null 2>&1 <<<"$1"
        elif command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$1" >/dev/null 2>&1
        else return 1
        fi
    }

    # live_test <name> <zero|nonzero> <expect|""> <not_expect|""> -- <args...>
    live_test() {
        local name="$1" want="$2" expect="$3" notexpect="$4"
        shift 5
        local out status
        set +e
        out="$(with_secret "$binary" "$@" 2>&1)"
        status=$?
        set -e
        if [[ "$want" == "zero" && $status -ne 0 ]]; then live_fail "$name" "exit $status"; return; fi
        if [[ "$want" == "nonzero" && $status -eq 0 ]]; then live_fail "$name" "expected non-zero exit"; return; fi
        if [[ -n "$expect" && "$out" != *"$expect"* ]]; then live_fail "$name" "missing: $expect"; return; fi
        if [[ -n "$notexpect" && "$out" == *"$notexpect"* ]]; then live_fail "$name" "unexpected: $notexpect"; return; fi
        live_pass "$name"
    }

    print_fixture="$testing/test-print-statements.sql"
    [[ -f "$print_fixture" ]] || printf "PRINT 'Starting test script'\nPRINT 'Before SELECT'\nSELECT 'TestValue' AS TestColumn\nPRINT 'After SELECT'\n" > "$print_fixture"

    set +e
    sql_auth_cmd="$("$binary" -S 192.0.2.1,1433 -U user-secret -P password-secret -C -l 1 -Q "SELECT 1" -v 2>&1 | grep 'Command:')"
    token_cmd="$("$binary" -S 192.0.2.1,1433 -T token-secret -C -l 1 -Q "SELECT 1" -v 2>&1 | grep 'Command:')"
    cs_cmd="$("$binary" -c "Driver={ODBC Driver 18 for SQL Server};Server=192.0.2.1;UID=user-secret;PWD=password-secret;TrustServerCertificate=yes" -l 1 -Q "SELECT 1" -v 2>&1 | grep 'Command:')"
    set -e
    if ! grep -qE 'user-secret|password-secret|token-secret' <<<"$sql_auth_cmd$token_cmd$cs_cmd" \
        && grep -qE -- '-U \*{8}.*-P \*{8}' <<<"$sql_auth_cmd" \
        && grep -qE -- '-T \*{8}' <<<"$token_cmd" \
        && grep -qE 'UID=\*{8};PWD=\*{8}' <<<"$cs_cmd"; then
        live_pass "Verbose command redacts credentials"
    else
        live_fail "Verbose command redacts credentials" "credentials not masked"
    fi

    live_test "Help text displays" zero "Usage:" "" -- -h
    live_test "Basic connection to server" zero "" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -q
    # The PowerShell suite hardcodes localhost and -E here, which forces Kerberos on Linux.
    live_test "Explicit -S localhost -d tempdb" zero "" "" -- -S "$server" -d "$database" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -q
    live_test "Simple SELECT query with output" zero "" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -r 1
    live_test "Multi-threaded query with output" zero "" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -n 3 -r 2
    live_test "Authentication ($auth_method)" zero "" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -q
    live_test "Query repetition (-n 100)" zero "Total batches to execute: 100" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -n 100 -q
    live_test "Concurrency (25 threads x 10 iterations)" zero "Threads: 25" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM sys.objects" -n 25 -r 10 -q
    live_test "Quiet mode suppresses query output" zero "Total Runtime:" "row(s) affected" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT 1 AS TestColumn" -q
    live_test "Verbose mode shows details" zero "Total batches to execute" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" -v -q
    live_test "Non-verbose output uses batch terminology" zero "Batches in workload" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" -q
    live_test "Invalid server error handling" nonzero "" "" -- -S "InvalidServer123" -d tempdb "${auth_args[@]}" -Q "SELECT 1" -l 1 -q

    printf 'SELECT * FROM sys.objects\n' > "$testing/test-smoke.sql"
    live_test "File input (-i flag)" zero "" "" -- "${base[@]}" "${auth_args[@]}" -i "$testing/test-smoke.sql" -q
    rm -f "$testing/test-smoke.sql"

    printf 'SELECT * FROM sys.objects\nGO\nSELECT * FROM sys.databases\nGO\nSELECT * FROM sys.schemas\n' > "$testing/test-smoke-go.sql"
    live_test "GO batch separators" zero "" "" -- "${base[@]}" "${auth_args[@]}" -i "$testing/test-smoke-go.sql" -q
    rm -f "$testing/test-smoke-go.sql"

    live_test "Output to file (-o flag)" zero "" "" -- "${base[@]}" "${auth_args[@]}" -Q "SELECT 'OutputTest' AS Result" -o "$testing/test-smoke-output.txt" -q
    rm -f "$testing/test-smoke-output.txt"

    live_test "Application name (-app)" zero "" "" -- "${base[@]}" "${auth_args[@]}" -app SmokeTest -Q "SELECT * FROM sys.objects" -q
    live_test "Connection pooling (-usepool -reconnect)" zero "" "" -- "${base[@]}" "${auth_args[@]}" -reconnect -usepool -Q "SELECT * FROM sys.objects" -n 2 -q

    set +e
    json_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" -json -q 2>/dev/null)"
    json_rc=$?
    set -e
    if [[ $json_rc -eq 0 ]] && grep -q '"version"' <<<"$json_out" && json_valid "$json_out"; then
        live_pass "JSON output format (-json)"
    else
        live_fail "JSON output format (-json)" "missing version or invalid JSON"
    fi

    printf "SELECT 1;\nGO\nWAITFOR DELAY '00:00:02';\nGO\nSELECT 2;\n" > "$testing/test-stream-json.sql"
    set +e
    stream_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -i "$testing/test-stream-json.sql" -stream-json -q 2>/dev/null)"
    stream_rc=$?
    err_stream="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1; RAISERROR('stream error', 16, 1); SELECT 2" -stream-json -q 2>/dev/null)"
    err_stream_rc=$?
    set -e
    rm -f "$testing/test-stream-json.sql"
    n_started=$(grep -c '"type"[[:space:]]*:[[:space:]]*"started"' <<<"$stream_out" || true)
    n_progress=$(grep -c '"type"[[:space:]]*:[[:space:]]*"progress"' <<<"$stream_out" || true)
    n_completed=$(grep -c '"type"[[:space:]]*:[[:space:]]*"completed"' <<<"$stream_out" || true)
    last_err="$(grep '"type"' <<<"$err_stream" | tail -1)"
    if [[ $stream_rc -eq 0 && $n_started -eq 1 && $n_progress -ge 1 && $n_completed -eq 1 ]] \
        && grep -q '"status"[[:space:]]*:[[:space:]]*"success"' <<<"$stream_out" \
        && grep -qE '"type"[[:space:]]*:[[:space:]]*"progress".*"successful_executions"[[:space:]]*:[[:space:]]*[1-9]' <<<"$stream_out" \
        && grep -qE '"type"[[:space:]]*:[[:space:]]*"progress".*"odbc_driver_version"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$stream_out" \
        && grep -qE '"type"[[:space:]]*:[[:space:]]*"completed".*"server_version"[[:space:]]*:[[:space:]]*"[^"]+".*"server_edition"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$stream_out" \
        && [[ $err_stream_rc -eq 1 ]] \
        && grep -q '"status"[[:space:]]*:[[:space:]]*"error"' <<<"$last_err"; then
        live_pass "Streaming JSON output format (-stream-json)"
    else
        live_fail "Streaming JSON output format (-stream-json)" "incomplete NDJSON event stream"
    fi

    stream_final="$testing/test-stream-final.json"
    rm -f "$stream_final"
    set +e
    stream_final_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1 AS StreamFinalResult" \
        -stream-json -json -o "$stream_final" -q 2>/dev/null)"
    stream_final_rc=$?
    invalid_final_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" \
        -stream-json -json -q 2>&1)"
    invalid_final_rc=$?
    set -e
    if [[ $stream_final_rc -eq 0 && -f "$stream_final" && $invalid_final_rc -ne 0 ]] \
        && grep -q '"type"[[:space:]]*:[[:space:]]*"started"' <<<"$stream_final_out" \
        && grep -q '"type"[[:space:]]*:[[:space:]]*"completed"' <<<"$stream_final_out" \
        && grep -q 'requires -o' <<<"$invalid_final_out" \
        && python3 - "$stream_final" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
if (result.get("success") is not True
        or result.get("configuration", {}).get("total_batches") != 1
        or result.get("configuration", {}).get("stream_json") is not True):
    raise SystemExit(1)
PY
    then
        live_pass "Streaming JSON with canonical final result"
    else
        live_fail "Streaming JSON with canonical final result" "stream or final JSON was invalid"
    fi
    rm -f "$stream_final"

    sp="sqlsim-stdin-password"; st="sqlsim-stdin-token-value"
    set +e
    pw_out="$(printf '%s\n' "$sp" | "$binary" -S 192.0.2.1,1433 -U stdin-user -P - -C -l 1 -Q "SELECT 1" -v -q 2>&1)"; pw_rc=$?
    tk_out="$(printf '%s\n' "$st" | "$binary" -S 192.0.2.1,1433 -T - -C -l 1 -Q "SELECT 1" -v -q 2>&1)"; tk_rc=$?
    em_out="$(printf '\n' | "$binary" -S "$server" -U stdin-user -P - 2>&1)"; em_rc=$?
    ov_out="$(printf '%s\n' "$(head -c 129 /dev/zero | tr '\0' 'x')" | "$binary" -S "$server" -U stdin-user -P - 2>&1)"; ov_rc=$?
    set -e
    if [[ $pw_rc -ne 0 && $tk_rc -ne 0 && $em_rc -ne 0 && $ov_rc -ne 0 ]] \
        && [[ "$pw_out" != *"$sp"* && "$tk_out" != *"$st"* ]] \
        && [[ "$pw_out" != *"requires redirected stdin"* ]] \
        && [[ "$em_out" == *"cannot be empty"* && "$ov_out" == *"exceeds maximum"* ]]; then
        live_pass "Credentials from redirected stdin (-P - and -T -)"
    else
        live_fail "Credentials from redirected stdin (-P - and -T -)" "stdin credential contract not met"
    fi

    set +e
    with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" -json -o "$testing/test-smoke-json.json" -q >/dev/null 2>&1
    jf_rc=$?
    set -e
    if [[ $jf_rc -eq 0 && -f "$testing/test-smoke-json.json" ]] && json_valid "$(cat "$testing/test-smoke-json.json")"; then
        live_pass "JSON output to file (-json -o)"
    else
        live_fail "JSON output to file (-json -o)" "file missing or invalid JSON"
    fi
    rm -f "$testing/test-smoke-json.json"

    set +e
    ts_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1" -q 2>&1)"; ts_rc=$?
    set -e
    if [[ $ts_rc -eq 0 ]] \
        && grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} \|' <<<"$ts_out" \
        && grep -q 'Starting execution' <<<"$ts_out" \
        && grep -q 'Total Connection Time:' <<<"$ts_out" \
        && grep -q '% of work)' <<<"$ts_out" \
        && grep -qE 'Start Time: [0-9]{4}-[0-9]{2}-[0-9]{2}T' <<<"$ts_out" \
        && grep -qE 'End Time:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T' <<<"$ts_out"; then
        live_pass "Timestamp format and output features"
    else
        live_fail "Timestamp format and output features" "summary markers missing"
    fi

    live_test "SQL error returns exit code 1" nonzero "Invalid object name" "" -- \
        "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM nonexistent_table_xyz_12345" -q

    set +e
    e_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM nonexistent_table_xyz_12345" 2>&1)"; e_rc=$?
    set -e
    if [[ $e_rc -eq 1 ]] && grep -q 'Invalid object name' <<<"$e_out" && ! grep -q 'Unknown ODBC error' <<<"$e_out"; then
        live_pass "Error messages properly captured (not Unknown ODBC error)"
    else
        live_fail "Error messages properly captured (not Unknown ODBC error)" "expected real SQL error text"
    fi

    set +e
    c_out="$(with_secret "$binary" -S "InvalidServerXYZ123" -d tempdb "${auth_args[@]}" -Q "SELECT 1" -l 1 2>&1)"; c_rc=$?
    set -e
    n_states=$(grep -oE '[0-9]{5}:' <<<"$c_out" | wc -l)
    if [[ $c_rc -eq 1 && $n_states -ge 2 ]]; then
        live_pass "Chained error messages captured (multiple diagnostic records)"
    else
        live_fail "Chained error messages captured (multiple diagnostic records)" "found $n_states SQLSTATE records"
    fi

    live_test "RAISERROR sev 10 is info (exit code 0)" zero "" "" -- \
        "${base[@]}" "${auth_args[@]}" -Q "RAISERROR('info message', 10, 1)" -q

    set +e
    pr_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "PRINT 'info before error'; RAISERROR('sev16 error', 16, 1)" 2>&1)"; pr_rc=$?
    set -e
    if [[ $pr_rc -eq 1 ]] && grep -q 'info before error' <<<"$pr_out" && grep -q 'sev16 error' <<<"$pr_out" && grep -q 'Total Errors: 1' <<<"$pr_out"; then
        live_pass "PRINT + RAISERROR error combo (exit code 1)"
    else
        live_fail "PRINT + RAISERROR error combo (exit code 1)"
    fi

    set +e
    ms_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT 1 AS val; RAISERROR('mid-batch error', 16, 1); SELECT 2 AS val2" 2>&1)"; ms_rc=$?
    set -e
    if [[ $ms_rc -eq 1 ]] && grep -q 'mid-batch error' <<<"$ms_out" && grep -q 'Total Errors: 1' <<<"$ms_out"; then
        live_pass "Multi-statement error in non-first statement (exit code 1)"
    else
        live_fail "Multi-statement error in non-first statement (exit code 1)"
    fi

    live_test "PRINT statements don't cause cursor errors" zero "TestValue" "" -- \
        "${base[@]}" "${auth_args[@]}" -i "$print_fixture"
    live_test "PRINT statements are displayed in output" zero "Hello from PRINT" "" -- \
        "${base[@]}" "${auth_args[@]}" -Q "PRINT 'Hello from PRINT'; SELECT 1 AS Result"

    set +e
    esc_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "PRINT CHAR(27) + '[31mSECURITY_MARKER'; SELECT 1" 2>&1)"; esc_rc=$?
    set -e
    esc_stripped="$(tr -d '\033' <<<"$esc_out")"
    if [[ $esc_rc -eq 0 && "$esc_out" == *"[31mSECURITY_MARKER"* && "$esc_out" == "$esc_stripped" ]]; then
        live_pass "PRINT control characters are sanitized"
    else
        live_fail "PRINT control characters are sanitized" "escape sequence not stripped"
    fi

    set +e
    q_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "PRINT 'QuietModePrintTest'; SELECT 1" -q 2>&1)"; q_rc=$?
    set -e
    exec_section="$(sed -n '/Starting execution/,/Total Runtime/p' <<<"$q_out")"
    if [[ $q_rc -eq 0 && -n "$exec_section" ]] && ! grep -q 'QuietModePrintTest' <<<"$exec_section"; then
        live_pass "PRINT statements suppressed with -q"
    else
        live_fail "PRINT statements suppressed with -q"
    fi

    live_test "Stored proc OUTPUT param + second batch (cursor state)" zero "SecondBatchOK" "" -- \
        "${base[@]}" "${auth_args[@]}" -Q "$(printf "DECLARE @result INT; EXEC sp_executesql N'SELECT @out = 1', N'@out INT OUTPUT', @out = @result OUTPUT; SELECT @result AS Result\nGO\nSELECT 'SecondBatchOK' AS Status")"
    live_test "Multi-result proc + second batch (cursor state)" zero "AfterMultiResult" "" -- \
        "${base[@]}" "${auth_args[@]}" -Q "$(printf "EXEC sp_executesql N'SELECT 1; SELECT 2; SELECT 3'\nGO\nSELECT 'AfterMultiResult' AS Status")"

    uni_file="$testing/unicode_smoke_test.txt"
    set +e
    with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT NCHAR(26085) + NCHAR(26412) + NCHAR(35486) AS japanese" -o "$uni_file" >/dev/null 2>&1
    set -e
    if [[ -f "$uni_file" ]] && grep -q '日本語' "$uni_file"; then
        live_pass "Unicode data retrieval (NCHAR function)"
    else
        live_fail "Unicode data retrieval (NCHAR function)" "expected 日本語"
    fi
    rm -f "$uni_file"

    # USE the current database: Azure SQL Database rejects switching to another
    # database, but every target still sends the "Changed database context" message.
    set +e
    use_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "USE [${database//]/]]}]; SELECT 'AfterUse' AS Result" 2>&1)"; use_rc=$?
    set -e
    if [[ $use_rc -eq 0 ]] && grep -q 'AfterUse' <<<"$use_out" && ! grep -q 'Changed database context' <<<"$use_out"; then
        live_pass "USE database message filtered (not displayed)"
    else
        live_fail "USE database message filtered (not displayed)"
    fi

    set +e
    jp_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "PRINT 'JsonPrintSmokeTest'; SELECT 1" -json 2>&1)"; jp_rc=$?
    set -e
    jp_nobatches="$(tr '\n' ' ' <<<"$jp_out" | sed 's/"batches":[[:space:]]*\[[^]]*\]/"batches": []/')"
    if [[ $jp_rc -eq 0 ]] && ! grep -q 'JsonPrintSmokeTest' <<<"$jp_nobatches"; then
        live_pass "PRINT suppressed in JSON mode (-json)"
    else
        live_fail "PRINT suppressed in JSON mode (-json)" "PRINT text leaked into JSON"
    fi

    set +e
    to_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "WAITFOR DELAY '00:00:05'" -t 1 -q 2>&1)"; to_rc=$?
    set -e
    if [[ $to_rc -eq 1 ]] && grep -qiE 'HYT00|timeout' <<<"$to_out"; then
        live_pass "Query timeout with -t (HYT00 error)"
    else
        live_fail "Query timeout with -t (HYT00 error)"
    fi

    set +e
    so_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -Q "SELECT * FROM nonexistent_table_xyz_stop" -r 5 -stoponerror -q 2>&1)"; so_rc=$?
    set -e
    if [[ $so_rc -eq 1 ]] && grep -qE 'STOP.*stoponerror' <<<"$so_out" && grep -q 'Total Errors: 1' <<<"$so_out"; then
        live_pass "-stoponerror stops execution on first error"
    else
        live_fail "-stoponerror stops execution on first error"
    fi

    live_skip "Live capture and replay (end-to-end)" "requires replay/convert-xel.ps1, which is PowerShell-only"

    workload="$script_dir/examples/workload/workload-test.json"
    live_test "Basic workload file" zero "Workload groups: 2" "" -- \
        "${base[@]}" "${auth_args[@]}" -workload "$workload" -q
    live_test "Workload with querystats" zero "Query Stats" "" -- \
        "${base[@]}" "${auth_args[@]}" -workload "$workload" -q -querystats

    perf_run() {
        local out
        set +e
        out="$(with_secret "$binary" -S "$server" "${auth_args[@]}" -q -Q "SELECT 1" -json "$@" 2>/dev/null)"
        set -e
        grep -oE '"total_runtime_seconds"[[:space:]]*:[[:space:]]*[0-9.]+' <<<"$out" | grep -oE '[0-9.]+$' | head -1
    }

    t_r2k=""; t_r10k=""
    if [[ "$is_azure" == false ]]; then
        t_r2k="$(perf_run -n 1 -r 2000)"
        t_r10k="$(perf_run -n 1 -r 10000)"
    fi
    if [[ "$is_azure" == true ]]; then
        # The 2000 us ceiling measures client overhead; Azure network latency dominates it.
        live_skip "sqlsim per-iteration overhead (P1)" "client-overhead gate needs a low-latency target, not Azure"
    elif [[ -n "$t_r2k" && -n "$t_r10k" ]]; then
        per_iter="$(awk -v a="$t_r2k" -v b="$t_r10k" 'BEGIN{printf "%.1f", ((b-a)/8000.0)*1e6}')"
        if awk -v p="$per_iter" 'BEGIN{exit !(p > 0 && p < 2000)}'; then
            live_pass "sqlsim per-iteration overhead (P1) [${per_iter} us]"
        else
            live_fail "sqlsim per-iteration overhead (P1)" "per-iter ${per_iter} us outside (0, 2000)"
        fi
    else
        live_fail "sqlsim per-iteration overhead (P1)" "sqlsim invocation failed"
    fi

    t_n1="$(perf_run -n 1 -r 5000)"
    t_n4="$(perf_run -n 4 -r 5000)"
    cpu_count="$(nproc 2>/dev/null || echo 1)"
    if [[ "$cpu_count" -lt 4 ]]; then
        # The 2.0x floor assumes at least 4 logical CPUs; fewer cores cap scaling.
        live_skip "sqlsim thread scaling (P2)" "needs >= 4 logical CPUs, host has $cpu_count"
    elif [[ -n "$t_n1" && -n "$t_n4" ]]; then
        scale="$(awk -v a="$t_n1" -v b="$t_n4" 'BEGIN{printf "%.2f", (4.0*a)/b}')"
        if awk -v s="$scale" 'BEGIN{exit !(s >= 2.0)}'; then
            live_pass "sqlsim thread scaling (P2) [${scale}x]"
        else
            live_fail "sqlsim thread scaling (P2)" "throughput scaling ${scale}x below 2.0x floor"
        fi
    else
        live_fail "sqlsim thread scaling (P2)" "sqlsim invocation failed"
    fi

    dur_file="$testing/test-duration-workload.json"
    cat > "$dur_file" <<'JSON'
{
    "duration_seconds": 3,
    "workloads": [
        {
            "queries": ["SELECT 1"],
            "threads": 2
        }
    ]
}
JSON
    set +e
    dur_out="$(with_secret "$binary" "${base[@]}" "${auth_args[@]}" -workload "$dur_file" -q 2>&1)"; dur_rc=$?
    set -e
    rm -f "$dur_file"
    if [[ $dur_rc -eq 0 ]] && grep -q 'Duration: 3 seconds' <<<"$dur_out" && grep -q 'Total Runtime:' <<<"$dur_out"; then
        live_pass "Duration mode workload (duration_seconds)"
    else
        live_fail "Duration mode workload (duration_seconds)"
    fi

    rmdir "$testing" 2>/dev/null || true
fi

echo "Linux smoke test: $passed passed, $failed failed, $live_skipped skipped, $live_tests live tests run."
if [[ $failed -ne 0 ]]; then
    exit 1
fi