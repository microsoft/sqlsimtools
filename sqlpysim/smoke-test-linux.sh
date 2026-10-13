#!/usr/bin/env bash
# Minimal smoke test for sqlpysim on Linux.
#
# Native bash port of smoke-test.ps1 so Linux users never need PowerShell.
# Test names are kept identical to the PowerShell suite so the two inventories
# can be compared; see --list-tests.
#
# Usage:
#   ./smoke-test-linux.sh --server HOST[,PORT] --database DB --username USER --password-file FILE
#   ./smoke-test-linux.sh --server HOST --token-file FILE
#   ./smoke-test-linux.sh --list-tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLPYSIM="$SCRIPT_DIR/sqlpysim.py"

SERVER="localhost"
DATABASE="tempdb"
USERNAME=""
PASSWORD=""
TOKEN=""
PYTHON="${PYTHON:-python3}"
SKIP_INSTALL=0

# Canonical inventory. Keep in step with smoke-test.ps1.
TEST_NAMES=(
  "Help text displays"
  "Basic connection to server"
  "Explicit -S localhost -d tempdb"
  "Simple SELECT query with output"
  "Multi-threaded query with output"
  "Authentication"
  "Query repetition (-r 100)"
  "Concurrency (25 threads x 10 iterations)"
  "Quiet mode suppresses query output"
  "Verbose mode shows details"
  "Non-verbose output uses batch terminology"
  "Prepared statements (-p) report their effective state"
  "Invalid server error handling"
  "File input (-i flag)"
  "Query and file input are mutually exclusive"
  "GO batch separators"
  "Output to file (-o flag)"
  "Application name (-app) is refused"
  "Reported application name matches APP_NAME()"
  "Reconnect mode (-reconnect)"
  "Connection pooling requires reconnect"
  "Connection pooling (-usepool)"
  "JSON output format (-json)"
  "Credentials from redirected stdin (-P - and -T -)"
  "JSON output to file (-json -o)"
  "Timestamp format and output features"
  "SQL error returns exit code 1"
  "Error messages properly captured"
  "Connection test only (no query)"
  "Version display (--version)"
  "Missing authentication fails"
  "Trust server certificate (-C)"
  "Connection string mode (-c)"
  "Multiple columns in result"
  "@@VERSION query"
  "Verbose shows connection info"
  "Verbose command redacts credentials"
  "Connection string rejects component options"
  "Mixed authentication methods fail"
  "Invalid encryption level is rejected"
  "Workload file with two groups"
  "Workload threads are the sum of its groups"
  "Duration mode workload (duration_seconds)"
  "Live telemetry emits started then completed"
  "Live telemetry counts every execution"
  "Live telemetry reports a failing run"
  "Live canonical JSON requires an output file"
  "Live telemetry writes canonical final JSON"
  "Snapshot interval implies -querystats"
  "Snapshot file contains the run's statistics"
  "Snapshot interval below one is rejected"
  "An unwritable snapshot path warns but does not fail the run"
  "An unwritable snapshot path does not corrupt the stream"
)

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server)        SERVER="$2"; shift 2 ;;
    --database)      DATABASE="$2"; shift 2 ;;
    --username)      USERNAME="$2"; shift 2 ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --password-file) PASSWORD="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --token-file)    TOKEN="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --python)        PYTHON="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=1; shift ;;
    --list-tests)    printf '%s\n' "${TEST_NAMES[@]}"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f "$SQLPYSIM" ]; then
  echo "ERROR: sqlpysim.py not found at $SQLPYSIM" >&2
  exit 1
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "ERROR: python interpreter '$PYTHON' not found" >&2
  exit 1
fi

if [ "$SKIP_INSTALL" -eq 0 ]; then
  if ! "$PYTHON" -c 'import mssql_python' >/dev/null 2>&1; then
    echo "ERROR: mssql-python is not installed for $PYTHON" >&2
    echo "       pip install -r requirements.txt" >&2
    exit 1
  fi
fi

# Azure presents a publicly trusted certificate; everything else usually does not.
case "$SERVER" in
  *database.windows.net*|*database.fabric.microsoft.com*) IS_AZURE=1 ;;
  *) IS_AZURE=0 ;;
esac

AUTH_ARGS=()
AUTH_SECRET=""
if [ -n "$TOKEN" ]; then
  AUTH_METHOD="Token"
  AUTH_ARGS=(-T -)
  AUTH_SECRET="$TOKEN"
elif [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
  AUTH_METHOD="SQL Authentication"
  AUTH_ARGS=(-U "$USERNAME" -P -)
  AUTH_SECRET="$PASSWORD"
  [ "$IS_AZURE" -eq 0 ] && AUTH_ARGS+=(-C)
else
  AUTH_METHOD="Windows"
  AUTH_ARGS=(-E -C)
fi

# Runs a command, writing the secret to stdin when its arguments include
# -T - or -P -, so the token or password never appears in a process list.
with_secret() {
  local prev="" arg
  if [ -n "$AUTH_SECRET" ]; then
    for arg in "$@"; do
      if [ "$arg" = "-" ] && { [ "$prev" = "-T" ] || [ "$prev" = "-P" ]; }; then
        "$@" <<<"$AUTH_SECRET"
        return
      fi
      prev="$arg"
    done
  fi
  "$@"
}

BASE=(-S "$SERVER" -d "$DATABASE")
TEST_DIR="$SCRIPT_DIR/testing"
mkdir -p "$TEST_DIR"

passed=0
failed=0
skipped=0

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
[ -t 1 ] || { GREEN=""; RED=""; YELLOW=""; CYAN=""; RESET=""; }

pass() { echo "  ${GREEN}PASSED${RESET}"; passed=$((passed+1)); echo; }
fail() { echo "  ${RED}FAILED${RESET}${1:+ - $1}"; failed=$((failed+1)); echo; }
skip() { echo "  ${YELLOW}SKIPPED${RESET}${1:+ - $1}"; skipped=$((skipped+1)); echo; }

# run_test <name> <should_fail:0|1> <expect_regex|""> -- <args...>
run_test() {
  local name="$1" should_fail="$2" expect="$3"
  shift 4  # drop name, should_fail, expect, and the literal --
  echo "Testing: $name"
  local out rc
  out="$(with_secret "$PYTHON" "$SQLPYSIM" "$@" 2>&1)"
  rc=$?
  if [ "$should_fail" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then fail "expected non-zero exit"; return; fi
  else
    if [ "$rc" -ne 0 ]; then fail "exit code $rc"; return; fi
  fi
  if [ -n "$expect" ] && ! grep -qiE -- "$expect" <<<"$out"; then
    fail "output did not match: $expect"; return
  fi
  pass
}

echo
echo "${CYAN}========================================${RESET}"
echo "${CYAN}SQLPYSIM SMOKE TEST - Quick Validation${RESET}"
echo "${CYAN}========================================${RESET}"
echo "Server  : $SERVER"
echo "Database: $DATABASE"
echo "Auth    : $AUTH_METHOD"
echo "Test Set: Essential core functionality (${#TEST_NAMES[@]} tests)"
echo "${CYAN}========================================${RESET}"
echo

run_test "Help text displays" 0 "usage:" -- -h

run_test "Basic connection to server" 0 "" -- "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q

# The PowerShell suite hardcodes localhost and -E here; on Linux that would force
# Kerberos, so exercise the same shape using the configured target.
run_test "Explicit -S localhost -d tempdb" 0 "" -- -S "$SERVER" -d "$DATABASE" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q

run_test "Simple SELECT query with output" 0 "" -- "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1 AS TestCol"

run_test "Multi-threaded query with output" 0 "" -- "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -n 3 -r 2 -q

run_test "Authentication ($AUTH_METHOD)" 0 "" -- "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q

run_test "Query repetition (-r 100)" 0 "Total batches to execute: 100" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -r 100 -q

run_test "Concurrency (25 threads x 10 iterations)" 0 "Threads: 25" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -n 25 -r 10 -q

run_test "Quiet mode suppresses query output" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1 AS TestColumn" -q

run_test "Verbose mode shows details" 0 "PHASE" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -v -q

run_test "Non-verbose output uses batch terminology" 0 "Batches in workload" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q

run_test "Prepared statements (-p) report their effective state" 0 \
  "Prepared statements.*not supported.*flag ignored" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -p -v -q

run_test "Invalid server error handling" 1 "" -- \
  -S "InvalidServer123.invalid" -d tempdb "${AUTH_ARGS[@]}" -l 2 -Q "SELECT 1"

printf 'SELECT 1 AS FileTest\n' > "$TEST_DIR/test-smoke.sql"
run_test "File input (-i flag)" 0 "" -- "${BASE[@]}" "${AUTH_ARGS[@]}" -i "$TEST_DIR/test-smoke.sql" -q
run_test "Query and file input are mutually exclusive" 1 "Cannot use -Q with -i" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -i "$TEST_DIR/test-smoke.sql" -q
rm -f "$TEST_DIR/test-smoke.sql"

printf 'SELECT 1 AS Batch1\nGO\nSELECT 2 AS Batch2\nGO\nSELECT 3 AS Batch3\n' > "$TEST_DIR/test-smoke-go.sql"
run_test "GO batch separators" 0 "Batches in workload: 3" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -i "$TEST_DIR/test-smoke-go.sql" -q
rm -f "$TEST_DIR/test-smoke-go.sql"

run_test "Output to file (-o flag)" 0 "" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 'OutputTest' AS Result" -o "$TEST_DIR/test-smoke-output.txt" -q
rm -f "$TEST_DIR/test-smoke-output.txt"

run_test "Application name (-app) is refused" 1 "mssql-python driver reserves this connection keyword" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -app SmokeTest -Q "SELECT 1" -q

run_test "Reported application name matches APP_NAME()" 0 "Application name: MSSQL-Python" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT APP_NAME() AS AppName"

run_test "Reconnect mode (-reconnect)" 0 "" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -reconnect -Q "SELECT 1" -n 2 -r 2 -q

run_test "Connection pooling requires reconnect" 1 "-usepool requires -reconnect" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -usepool -Q "SELECT 1" -q

run_test "Connection pooling (-usepool)" 0 "" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -reconnect -usepool -Q "SELECT 1" -r 2 -q

# JSON must be valid on stdout alone; stderr is deliberately not merged.
echo "Testing: JSON output format (-json)"
json_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -json 2>/dev/null)"
json_rc=$?
if [ "$json_rc" -ne 0 ]; then
  fail "exit code $json_rc"
elif ! grep -q '"version"' <<<"$json_out"; then
  fail "missing version field"
elif ! "$PYTHON" -c 'import json,sys; json.load(sys.stdin)' <<<"$json_out" >/dev/null 2>&1; then
  fail "invalid JSON"
else
  pass
fi

echo "Testing: Credentials from redirected stdin (-P - and -T -)"
stdin_secret="sqlpysim-stdin-password"
stdin_token="sqlpysim-stdin-token-value"
pw_out="$(printf '%s\n' "$stdin_secret" | "$PYTHON" "$SQLPYSIM" -S "$SERVER" -U stdin-user -P - -C -l 1 -Q "SELECT 1" -v -q 2>&1)"; pw_rc=$?
tk_out="$(printf '%s\n' "$stdin_token"  | "$PYTHON" "$SQLPYSIM" -S "$SERVER" -T - -C -l 1 -Q "SELECT 1" -v -q 2>&1)"; tk_rc=$?
empty_out="$(printf '\n' | "$PYTHON" "$SQLPYSIM" -S "$SERVER" -U stdin-user -P - 2>&1)"; empty_rc=$?
big_out="$(printf '%s\n' "$(head -c 129 < /dev/zero | tr '\0' 'x')" | "$PYTHON" "$SQLPYSIM" -S "$SERVER" -U stdin-user -P - 2>&1)"; big_rc=$?
if [ "$pw_rc" -ne 0 ] && [ "$tk_rc" -ne 0 ] &&
   ! grep -qF "$stdin_secret" <<<"$pw_out" &&
   ! grep -qF "$stdin_token" <<<"$tk_out" &&
   ! grep -q 'requires redirected stdin' <<<"$pw_out" &&
   ! grep -qE 'Invalid access token format|requires redirected stdin' <<<"$tk_out" &&
   [ "$empty_rc" -ne 0 ] && grep -q 'cannot be empty' <<<"$empty_out" &&
   [ "$big_rc" -ne 0 ] && grep -q 'exceeds maximum' <<<"$big_out"; then
  pass
else
  fail "stdin credential contract not met"
fi

run_test "JSON output to file (-json -o)" 0 "" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -json -o "$TEST_DIR/test-smoke-json.json"
rm -f "$TEST_DIR/test-smoke-json.json"

echo "Testing: Timestamp format and output features"
ts_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q 2>&1)"; ts_rc=$?
if [ "$ts_rc" -eq 0 ] &&
   grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}' <<<"$ts_out" &&
   grep -qE 'Starting execution|Connecting' <<<"$ts_out" &&
   grep -q 'Total Runtime' <<<"$ts_out"; then
  pass
else
  fail "timestamp/start/runtime markers missing"
fi

run_test "SQL error returns exit code 1" 1 "" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT * FROM nonexistent_table_xyz_12345" -q

echo "Testing: Error messages properly captured"
err_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT * FROM nonexistent_table_xyz_12345" 2>&1)"; err_rc=$?
if [ "$err_rc" -ne 0 ] || grep -qiE 'Invalid object|does not exist|error' <<<"$err_out"; then
  pass
else
  fail "no error surfaced"
fi

run_test "Connection test only (no query)" 0 "Connection test" -- "${BASE[@]}" "${AUTH_ARGS[@]}"

run_test "Version display (--version)" 0 "sqlpysim" -- --version

run_test "Missing authentication fails" 1 "" -- -S "$SERVER" -Q "SELECT 1"

run_test "Trust server certificate (-C)" 0 "Total Runtime" -- \
  -S "$SERVER" -d "$DATABASE" "${AUTH_ARGS[@]}" -Q "SELECT 1" -q

if [ -z "$TOKEN" ] && [ -n "$USERNAME" ]; then
  run_test "Connection string mode (-c)" 0 "Total Runtime" -- \
    -c "Server=$SERVER;Database=$DATABASE;UID=$USERNAME;PWD=$PASSWORD;TrustServerCertificate=yes" -Q "SELECT 1" -q
else
  echo "Testing: Connection string mode (-c)"
  skip "requires SQL authentication"
fi

run_test "Multiple columns in result" 0 "row.*affected" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1 AS A, 2 AS B, 3 AS C"

run_test "@@VERSION query" 0 "SQL Server|Microsoft SQL" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT @@VERSION"

run_test "Verbose shows connection info" 0 "Connection String" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -v -q

echo "Testing: Verbose command redacts credentials"
if "$PYTHON" - "$SQLPYSIM" <<'PY' >/dev/null 2>&1
import importlib.util, pathlib, sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("sqlpysim_script", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cases = [
    (["sqlpysim.py", "-U", "user-secret", "-P", "password-secret", "-T", "token-secret", "-t", "30"],
     "sqlpysim.py -U ******** -P ******** -T ******** -t 30"),
    (["sqlpysim.py", "-c", "Server=x;UID=user-secret;PWD=password-secret;Encrypt=yes"],
     "sqlpysim.py -c Server=x;UID=********;PWD=********;Encrypt=yes"),
]
raise SystemExit(0 if all(module.mask_command_line(a) == e for a, e in cases) else 1)
PY
then
  pass
else
  fail "credential masking mismatch"
fi

run_test "Connection string rejects component options" 1 \
  "Cannot use both -c and -S/-d/-E/-A/-T/-U/-P options" -- \
  -c "Server=$SERVER;Database=$DATABASE;Trusted_Connection=yes;TrustServerCertificate=yes" \
  -S "$SERVER" -Q "SELECT 1" -q

run_test "Mixed authentication methods fail" 1 \
  "Cannot mix authentication methods" -- \
  -S "$SERVER" -E -T "0123456789" -Q "SELECT 1" -q

run_test "Invalid encryption level is rejected" 1 \
  "Invalid encryption level.*Valid options" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -N x -Q "SELECT 1" -q

cat > "$TEST_DIR/smoke-workload.json" <<'JSON'
{
  "workloads": [
    { "queries": ["SELECT 1 AS SmokeGroupOne"], "threads": 2, "iterations": 2 },
    { "queries": ["SELECT 2 AS SmokeGroupTwo"], "threads": 1, "iterations": 3 }
  ]
}
JSON
run_test "Workload file with two groups" 0 "Workload groups: 2" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -workload "$TEST_DIR/smoke-workload.json" -q
run_test "Workload threads are the sum of its groups" 0 "Threads: 3" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -workload "$TEST_DIR/smoke-workload.json" -q

cat > "$TEST_DIR/smoke-duration-workload.json" <<'JSON'
{
  "duration_seconds": 3,
  "workloads": [
    { "queries": ["SELECT 1 AS SmokeDuration"], "threads": 2 }
  ]
}
JSON
run_test "Duration mode workload (duration_seconds)" 0 "Duration: 3 seconds" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -workload "$TEST_DIR/smoke-duration-workload.json" -q
rm -f "$TEST_DIR/smoke-workload.json" "$TEST_DIR/smoke-duration-workload.json"

check_stream() {
  local name="$1" mode="$2"
  shift 2
  echo "Testing: $name"
  local out rc
  out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" "$@" -stream-json -q 2>&1)"
  rc=$?
  if STREAM_MODE="$mode" STREAM_RC="$rc" "$PYTHON" -c '
import json, os, sys
lines = [line for line in sys.stdin.read().splitlines() if line.strip()]
try:
    events = [json.loads(line) for line in lines]
except json.JSONDecodeError:
    raise SystemExit(1)
mode, rc = os.environ["STREAM_MODE"], int(os.environ["STREAM_RC"])
completed = [event for event in events if event.get("type") == "completed"]
ok = len(events) >= 2 and events[0].get("type") == "started" and len(completed) == 1
if mode == "success":
    ok = ok and rc == 0 and events[-1].get("type") == "completed" and completed[0].get("status") == "success"
elif mode == "count":
    ok = ok and rc == 0 and completed[0].get("successful_executions") == 20 and completed[0].get("successful_connections") == 4
elif mode == "failure":
    ok = ok and rc != 0 and completed[0].get("status") == "error" and completed[0].get("failed_executions") == 2
raise SystemExit(0 if ok else 1)
' <<<"$out"; then
    pass
  else
    fail "stream contract mismatch"
  fi
}

check_stream "Live telemetry emits started then completed" success \
  -Q "SELECT 1 AS StreamSmoke"
check_stream "Live telemetry counts every execution" count \
  -Q "SELECT 1 AS StreamCount" -n 4 -r 5
check_stream "Live telemetry reports a failing run" failure \
  -Q "SELECT * FROM dbo.NoSuchTable_StreamSmoke" -n 1 -r 2

run_test "Live canonical JSON requires an output file" 1 "requires -o" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -json -stream-json -q

STREAM_FINAL_FILE="$TEST_DIR/smoke-stream-final.json"
rm -f "$STREAM_FINAL_FILE"
echo "Testing: Live telemetry writes canonical final JSON"
stream_final_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" \
  -Q "SELECT 1 AS StreamFinalResult" -stream-json -json -o "$STREAM_FINAL_FILE" -q 2>&1)"
stream_final_rc=$?
if [ "$stream_final_rc" -eq 0 ] && [ -f "$STREAM_FINAL_FILE" ] \
  && STREAM_FINAL_FILE="$STREAM_FINAL_FILE" "$PYTHON" -c '
import json, os, sys
events = [json.loads(line) for line in sys.stdin.read().splitlines() if line.strip()]
with open(os.environ["STREAM_FINAL_FILE"], encoding="utf-8") as handle:
    result = json.load(handle)
valid = (
    events and events[0].get("type") == "started"
    and events[-1].get("type") == "completed"
    and result.get("success") is True
    and result.get("configuration", {}).get("total_batches") == 1
)
raise SystemExit(0 if valid else 1)
' <<<"$stream_final_out"; then
  pass
else
  fail "stream or canonical final JSON was invalid"
fi
rm -f "$STREAM_FINAL_FILE"

SNAPSHOT_FILE="$TEST_DIR/smoke-snapshot.json"
run_test "Snapshot interval implies -querystats" 0 "Query stats interval: 1s" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1 AS SnapshotSmoke" -n 2 -r 5 \
  -querystats-interval 1 -querystats-file "$SNAPSHOT_FILE" -v -q

echo "Testing: Snapshot file contains the run's statistics"
if [ -f "$SNAPSHOT_FILE" ] && "$PYTHON" -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if doc.get("status") == "complete" and doc["query_stats"]["totals"]["executions"] == 10 else 1)
' "$SNAPSHOT_FILE"; then
  pass
else
  fail "snapshot did not contain the completed run"
fi
rm -f "$SNAPSHOT_FILE"

run_test "Snapshot interval below one is rejected" 1 "must be >= 1" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1" -querystats-interval 0 -q

UNWRITABLE_SNAPSHOT="/proc/sqlpysim-nope/bad.json"
run_test "An unwritable snapshot path warns but does not fail the run" 0 \
  "could not write the query statistics snapshot" -- \
  "${BASE[@]}" "${AUTH_ARGS[@]}" -Q "SELECT 1 AS SnapshotUnwritable" -n 1 -r 2 \
  -querystats-interval 1 -querystats-file "$UNWRITABLE_SNAPSHOT" -q

echo "Testing: An unwritable snapshot path does not corrupt the stream"
unwritable_stream="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE[@]}" "${AUTH_ARGS[@]}" \
  -Q "SELECT 1 AS SnapshotUnwritableStream" -n 1 -r 2 -querystats-interval 1 \
  -querystats-file "$UNWRITABLE_SNAPSHOT" -stream-json -q 2>&1)"
unwritable_rc=$?
if [ "$unwritable_rc" -eq 0 ] && "$PYTHON" -c '
import json, sys
events = [json.loads(line) for line in sys.stdin.read().splitlines() if line.strip()]
raise SystemExit(0 if events and events[-1].get("type") == "completed" else 1)
' <<<"$unwritable_stream"; then
  pass
else
  fail "stream was not valid JSON through snapshot write failure"
fi

rm -rf "$TEST_DIR"

echo "${CYAN}========================================${RESET}"
echo "${CYAN}SMOKE TEST RESULTS${RESET}"
echo "${CYAN}========================================${RESET}"
echo "Passed : $passed"
echo "Failed : $failed"
echo "Skipped: $skipped"
echo "Total  : $((passed + failed + skipped))"
echo "${CYAN}========================================${RESET}"
echo

if [ "$failed" -eq 0 ]; then
  echo "${GREEN}All smoke tests passed. Core functionality verified.${RESET}"
  exit 0
fi
echo "${RED}Some smoke tests failed.${RESET}"
exit 1
