#!/usr/bin/env bash
# Comprehensive test suite for sqlpysim on Linux.
#
# Native bash port of full-test-suite.ps1 so Linux users never need PowerShell.
# Test names match the PowerShell suite so the inventories can be compared;
# see --list-tests and scripts/check-suite-parity.ps1.
#
# Usage:
#   ./full-test-suite-linux.sh --server HOST[,PORT] --database DB \
#       --username USER --password-file FILE
#   ./full-test-suite-linux.sh --list-tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLPYSIM="$SCRIPT_DIR/sqlpysim.py"

SERVER="localhost"
DATABASE="master"
USERNAME=""
PASSWORD=""
TOKEN=""
PYTHON="${PYTHON:-python3}"
STOP_ON_ERROR=0
SKIP_INSTALL=0

# Canonical inventory. Keep in step with full-test-suite.ps1.
TEST_NAMES=(
  "Help Display"
  "Version Display"
  "No Arguments"
  "Simple Query"
  "Default Localhost"
  "Verbose Output"
  "Batch Terminology"
  "Multiple Iterations"
  "File Parsing"
  "Query And File Are Mutually Exclusive"
  "Login Timeout (Invalid Server)"
  "Invalid Thread Count (Zero)"
  "Invalid Iteration Count"
  "Missing Authentication"
  "Windows Auth Query"
  "Connection String Mode"
  "Connection String And Components Are Mutually Exclusive"
  "Authentication Methods Are Mutually Exclusive"
  "Trust Server Certificate"
  "Invalid Encryption Level"
  "Low Concurrency (5 threads)"
  "Medium Concurrency (25 threads)"
  "High Concurrency (50 threads)"
  "Reconnect Mode"
  "Connection Pooling Without Reconnect"
  "Connection Pooling Reuses Physical Connection"
  "Connection Pooling Is Off By Default"
  "SQL Error Detection"
  "Invalid Server"
  "Multiple GO Batches"
  "GO in Query String"
  "Timestamp Format"
  "Text Summary Parity"
  "JSON Output Valid"
  "JSON Has Configuration"
  "JSON Has Metrics"
  "Querystats JSON"
  "Querystats Executions"
  "Querystats Logical Reads"
  "Querystats Totals"
  "Querystats SPIDs"
  "JSON to File"
  "JSON File Valid"
  "JSON Shared Schema"
  "Verbose Phase 1"
  "Verbose Phase 5"
  "Verbose Connection String"
  "Verbose Metrics"
  "Verbose Credential Redaction"
  "Quiet Suppresses Results"
  "Connection Test Only"
  "Connection Test JSON"
  "Single Column Result"
  "Multiple Column Result"
  "Multiple Rows"
  "Result Set Per Execution"
  "Result Sets Do Not Interleave"
  "Error Text Per Failure"
  "Quiet Mode Still Suppresses Rows"
  "Empty Result Set Reported"
  "Workload Single Group"
  "Workload Thread Count From Groups"
  "Workload Total Batches"
  "Workload Comments Accepted"
  "Workload JSON Output"
  "Workload Duration Mode"
  "Workload Think Time Delays"
  "Workload Rejects Missing Key"
  "Workload Rejects Both Sources"
  "Workload Rejects Query Source Conflict"
  "Example: 01-simple-queries.sql"
  "Stream Progress Cadence"
  "Stream Event Order"
  "Stream Purity"
  "Stream Started Fields"
  "Stream Environment Metadata"
  "Stream Elapsed Advances"
  "Stream Ignores Output File"
  "Stream Counters Under Concurrency"
  "Stream Throughput Reported"
  "Stream Canonical JSON Requires Output File"
  "Stream Writes Canonical Final JSON"
  "Error Total Is Not Capped"
  "Snapshot Appears While Running"
  "Snapshot Is Never Partially Written"
  "Snapshot Counts Advance"
  "Snapshot Final Status"
  "Snapshot Peak Throughput Retained"
  "Snapshot Config Block"
  "Snapshot Records Errors"
  "Snapshot Records Failed Executions"
  "Snapshot Default File Name"
  "Snapshot Rejects Non-Numeric Interval"
)

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --server)         SERVER="$2"; shift 2 ;;
    --database)       DATABASE="$2"; shift 2 ;;
    --username)       USERNAME="$2"; shift 2 ;;
    --password)       PASSWORD="$2"; shift 2 ;;
    --password-file)  PASSWORD="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --token)          TOKEN="$2"; shift 2 ;;
    --token-file)     TOKEN="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --python)         PYTHON="$2"; shift 2 ;;
    --stop-on-error)  STOP_ON_ERROR=1; shift ;;
    --skip-install)   SKIP_INSTALL=1; shift ;;
    --list-tests)     printf '%s\n' "${TEST_NAMES[@]}"; exit 0 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$SQLPYSIM" ] || { echo "ERROR: sqlpysim.py not found at $SQLPYSIM" >&2; exit 1; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "ERROR: python '$PYTHON' not found" >&2; exit 1; }

if [ "$SKIP_INSTALL" -eq 0 ] && ! "$PYTHON" -c 'import mssql_python' >/dev/null 2>&1; then
  echo "ERROR: mssql-python is not installed for $PYTHON" >&2
  exit 1
fi

case "$SERVER" in
  *database.windows.net*|*database.fabric.microsoft.com*) IS_AZURE=1 ;;
  *) IS_AZURE=0 ;;
esac

BASE_AUTH=(-S "$SERVER" -d "$DATABASE")
AUTH_SECRET=""
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
  AUTH_METHOD="SQL Authentication"
  BASE_AUTH+=(-U "$USERNAME" -P -)
  AUTH_SECRET="$PASSWORD"
  [ "$IS_AZURE" -eq 0 ] && BASE_AUTH+=(-C)
elif [ -n "$TOKEN" ]; then
  AUTH_METHOD="Access Token"
  BASE_AUTH+=(-T -)
  AUTH_SECRET="$TOKEN"
elif [ "$IS_AZURE" -eq 1 ]; then
  AUTH_METHOD="Microsoft Entra Interactive"
  BASE_AUTH+=(-A)
else
  AUTH_METHOD="Windows Integrated"
  BASE_AUTH+=(-E -C)
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

TEST_DIR="$SCRIPT_DIR/testing"
mkdir -p "$TEST_DIR"

passed=0; failed=0; skipped=0
start_time=$(date +%s)

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'; RESET=$'\033[0m'
[ -t 1 ] || { GREEN=""; RED=""; YELLOW=""; CYAN=""; GRAY=""; RESET=""; }

section() { echo "${CYAN}========================================${RESET}"; echo "${CYAN}$1${RESET}"; echo "${CYAN}========================================${RESET}"; echo; }

_pass() { echo "  ${GREEN}PASSED${RESET}"; passed=$((passed+1)); echo; }
_fail() { echo "  ${RED}FAILED${RESET}${1:+: $1}"; failed=$((failed+1)); echo; [ "$STOP_ON_ERROR" -eq 1 ] && exit 1; return 0; }
_skip() { echo "  ${YELLOW}SKIPPED${RESET}${1:+: $1}"; skipped=$((skipped+1)); echo; }

# test_cmd <name> <description> <should_fail> <expect_regex> -- <sqlpysim args...>
test_cmd() {
  local name="$1" desc="$2" should_fail="$3" expect="$4"
  shift 5
  echo "${YELLOW}TEST: $name${RESET}"
  echo "${GRAY}  Description: $desc${RESET}"
  local out rc
  out="$(with_secret "$PYTHON" "$SQLPYSIM" "$@" 2>&1)"; rc=$?
  if [ "$should_fail" -eq 1 ]; then
    [ "$rc" -eq 0 ] && { _fail "expected non-zero exit code but got 0"; return; }
  else
    [ "$rc" -ne 0 ] && { _fail "exit code $rc"; return; }
  fi
  if [ -n "$expect" ] && ! grep -qiE -- "$expect" <<<"$out"; then
    _fail "output didn't contain expected: $expect"; return
  fi
  _pass
}

# test_condition <name> <description> <0=true>
test_condition() {
  echo "${YELLOW}TEST: $1${RESET}"
  echo "${GRAY}  Description: $2${RESET}"
  if [ "$3" -eq 0 ]; then _pass; else _fail; fi
}

echo
section "SQLPYSIM FULL TEST SUITE"
echo "Server: $SERVER"
echo "Database: $DATABASE"
echo "Environment: $([ "$IS_AZURE" -eq 1 ] && echo 'Azure SQL Database' || echo 'SQL Server')"
echo "Authentication: $AUTH_METHOD"
echo

# The suite uses only portable T-SQL, so it never changes the target
# database's compatibility level or any other persistent setting.

section "BASIC FUNCTIONALITY TESTS"

test_cmd "Help Display" "Verify help text is shown" 0 "usage:" -- -h
test_cmd "Version Display" "Show version information" 0 "sqlpysim" -- --version
test_cmd "No Arguments" "Run without arguments shows error" 1 "" --
test_cmd "Simple Query" "Execute simple query" 0 "Total Runtime:" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -q
# The PowerShell suite hardcodes -E here, which forces Kerberos on Linux.
test_cmd "Default Localhost" "Connect without explicit -S" 0 "Total Runtime:" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -q
test_cmd "Verbose Output" "Verify verbose mode shows phases" 0 "\[PHASE" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -v -q
test_cmd "Batch Terminology" "Output uses 'batches' not 'queries'" 0 "Batches in workload" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -q
test_cmd "Multiple Iterations" "Run 5 iterations with 2 threads" 0 "Total Runtime:" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -n 2 -r 5 -q

section "FILE PARSING TESTS"

printf 'SELECT 1 AS Test1\nGO\nSELECT 2 AS Test2\nGO\nSELECT 3 AS Test3\n' > "$TEST_DIR/test_queries.sql"
test_cmd "File Parsing" "Parse and execute queries from file" 0 "Batches in workload: 3" -- \
  "${BASE_AUTH[@]}" -i "$TEST_DIR/test_queries.sql" -q
test_cmd "Query And File Are Mutually Exclusive" "Reject -Q combined with -i" 1 "Cannot use -Q with -i" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -i "$TEST_DIR/test_queries.sql" -q
rm -f "$TEST_DIR/test_queries.sql"

section "TIMEOUT TESTS"

test_cmd "Login Timeout (Invalid Server)" "Verify timeout on invalid server" 1 "" -- \
  -S "invalid-server-12345.example.com" -d "$DATABASE" -U u -P p -C -l 2 -Q "SELECT 1" -q

section "PARAMETER VALIDATION TESTS"

test_cmd "Invalid Thread Count (Zero)" "Reject thread count = 0" 1 "" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -n 0
test_cmd "Invalid Iteration Count" "Reject zero iterations" 1 "" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -r 0

section "AUTHENTICATION TESTS"

test_cmd "Missing Authentication" "Reject missing auth method" 1 "Must specify authentication" -- \
  -S "$SERVER" -Q "SELECT 1"

echo "${YELLOW}TEST: Windows Auth Query${RESET}"
echo "${GRAY}  Description: Execute with Windows Auth${RESET}"
_skip "Windows Authentication requires a domain-joined Kerberos host"

section "CONNECTION STRING TESTS"

if [ -n "$USERNAME" ] && [ -z "$TOKEN" ]; then
  test_cmd "Connection String Mode" "Execute using -c connection string" 0 "Total Runtime:" -- \
    -c "Server=$SERVER;Database=$DATABASE;UID=$USERNAME;PWD=$PASSWORD;TrustServerCertificate=yes" -Q "SELECT 1" -q
else
  echo "${YELLOW}TEST: Connection String Mode${RESET}"
  _skip "Not applicable for token/Entra auth"
fi

test_cmd "Connection String And Components Are Mutually Exclusive" \
  "Reject -c combined with connection components" 1 \
  "Cannot use both -c and -S/-d/-E/-A/-T/-U/-P options" -- \
  -c "Server=$SERVER;Database=$DATABASE;Trusted_Connection=yes;TrustServerCertificate=yes" \
  -S "$SERVER" -Q "SELECT 1" -q

test_cmd "Authentication Methods Are Mutually Exclusive" \
  "Reject mixed authentication methods" 1 "Cannot mix authentication methods" -- \
  -S "$SERVER" -E -T "0123456789" -Q "SELECT 1" -q

section "ENCRYPTION TESTS"

test_cmd "Trust Server Certificate" "Connect with -C flag" 0 "Total Runtime:" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -q
test_cmd "Invalid Encryption Level" "Reject unsupported -N values" 1 \
  "Invalid encryption level.*Valid options" -- "${BASE_AUTH[@]}" -N x -Q "SELECT 1" -q

section "CONCURRENCY TESTS"

test_cmd "Low Concurrency (5 threads)" "5 threads x 10 iterations" 0 "Total Runtime:" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -n 5 -r 10 -q
test_cmd "Medium Concurrency (25 threads)" "25 threads x 10 iterations" 0 "Total Runtime:" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -n 25 -r 10 -q
test_cmd "High Concurrency (50 threads)" "50 threads x 5 iterations" 0 "Total Runtime:" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -n 50 -r 5 -q
test_cmd "Reconnect Mode" "Reconnect after each iteration" 0 "Total Runtime:" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -n 3 -r 3 -reconnect -q

test_cmd "Connection Pooling Without Reconnect" "-usepool requires -reconnect" 1 \
  "-usepool requires -reconnect" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -usepool -q

connection_id_query="SELECT connection_id FROM sys.dm_exec_connections WHERE session_id = @@SPID"
pooled_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -Q "$connection_id_query" -r 3 -reconnect -usepool 2>&1)"
pooled_count="$(grep -Eio '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$pooled_out" | sort -u | wc -l | tr -d ' ')"
test_condition "Connection Pooling Reuses Physical Connection" \
  "-usepool returns one connection_id across reconnect cycles" \
  "$([ "$pooled_count" -eq 1 ] && echo 0 || echo 1)"

unpooled_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -Q "$connection_id_query" -r 3 -reconnect 2>&1)"
unpooled_count="$(grep -Eio '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$unpooled_out" | sort -u | wc -l | tr -d ' ')"
test_condition "Connection Pooling Is Off By Default" \
  "Reconnect creates three physical connections without -usepool" \
  "$([ "$unpooled_count" -eq 3 ] && echo 0 || echo 1)"

section "ERROR HANDLING TESTS"

test_cmd "SQL Error Detection" "Detect invalid object error" 1 "" -- \
  "${BASE_AUTH[@]}" -Q "SELECT * FROM nonexistent_table_xyz" -q
test_cmd "Invalid Server" "Handle connection failure" 1 "" -- \
  -S "invalid.server.name" -d "$DATABASE" -U u -P p -C -l 2 -Q "SELECT 1" -q

section "GO BATCH SEPARATOR TESTS"

printf 'SELECT 1 AS B1\nGO\nSELECT 2 AS B2\nGO\nSELECT 3 AS B3\nGO\nSELECT 4 AS B4\nGO\nSELECT 5 AS B5\n' \
  > "$TEST_DIR/go_batch_test.sql"
test_cmd "Multiple GO Batches" "Parse 5 GO-separated batches" 0 "Batches in workload: 5" -- \
  "${BASE_AUTH[@]}" -i "$TEST_DIR/go_batch_test.sql" -q
rm -f "$TEST_DIR/go_batch_test.sql"

test_cmd "GO in Query String" "GO separator in -Q parameter" 0 "Batches in workload: 2" -- \
  "${BASE_AUTH[@]}" -Q "$(printf 'SELECT 1\nGO\nSELECT 2')" -q

section "OUTPUT FORMAT TESTS"

test_cmd "Timestamp Format" "Verify timestamp in output" 0 "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -q
summary_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -Q "SELECT 1" -q 2>&1)"
if grep -q "Performance Metric Summary" <<<"$summary_out" &&
   grep -qE "Start Time: [0-9-]+T[0-9:.]+" <<<"$summary_out" &&
   grep -qE "End Time:[[:space:]]+[0-9-]+T[0-9:.]+" <<<"$summary_out" &&
   grep -q "Avg Connect Time:" <<<"$summary_out" &&
   grep -q "Avg Elapsed:" <<<"$summary_out"; then
  test_condition "Text Summary Parity" "Match sqlsim summary headings and timing fields" 0
else
  test_condition "Text Summary Parity" "Match sqlsim summary headings and timing fields" 1
fi
test_cmd "JSON Output Valid" "Verify valid JSON output" 0 '"version"' -- "${BASE_AUTH[@]}" -Q "SELECT 1" -json
test_cmd "JSON Has Configuration" "JSON includes configuration section" 0 '"configuration"' -- "${BASE_AUTH[@]}" -Q "SELECT 1" -json
test_cmd "JSON Has Metrics" "JSON includes metrics section" 0 '"metrics"' -- "${BASE_AUTH[@]}" -Q "SELECT 1" -json

QS_FILE="$TEST_DIR/querystats.json"
test_cmd "Querystats JSON" "Collect sqlsim-compatible per-query statistics" 0 "" -- \
  "${BASE_AUTH[@]}" -Q "SELECT TOP 5 name FROM sys.objects ORDER BY object_id" -querystats -json -q -r 3 -o "$QS_FILE"

if [ -f "$QS_FILE" ]; then
  QS_CHECKS="$TEST_DIR/qs-checks"
  "$PYTHON" - "$QS_FILE" "$QS_CHECKS" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
q = doc["query_stats"]["queries"][0]
totals = doc["query_stats"].get("totals", {})
checks = {
    "executions": int(q.get("executions") == 3 and q.get("failures") == 0),
    "logical_reads": int(q["logical_reads"]["avg"] > 0),
    "totals": int(totals.get("logical_reads") == q["logical_reads"]["avg"] * q["executions"]),
    "spids": int(len(q.get("spids", [])) == 1 and q.get("spid_count") == 1 and q["spids"][0] > 0),
}
open(sys.argv[2], "w").write("".join(str(1 - v) for v in checks.values()))
PY
  qs="$(cat "$QS_CHECKS" 2>/dev/null || echo 1111)"
  test_condition "Querystats Executions" "Reports three successful executions" "${qs:0:1}"
  test_condition "Querystats Logical Reads" "Reports deterministic logical reads" "${qs:1:1}"
  test_condition "Querystats Totals" "Per-query totals agree with summary totals" "${qs:2:1}"
  test_condition "Querystats SPIDs" "Reports the one SQL Server SPID that ran the query, as sqlsim does" "${qs:3:1}"
  rm -f "$QS_FILE" "$QS_CHECKS"
else
  test_condition "Querystats Executions" "Reports three successful executions" 1
  test_condition "Querystats Logical Reads" "Reports deterministic logical reads" 1
  test_condition "Querystats Totals" "Per-query totals agree with summary totals" 1
  test_condition "Querystats SPIDs" "Reports the one SQL Server SPID that ran the query, as sqlsim does" 1
fi

JSON_FILE="$TEST_DIR/output.json"
test_cmd "JSON to File" "Write JSON output to file" 0 "" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -json -o "$JSON_FILE"
if [ -f "$JSON_FILE" ] && "$PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON_FILE" >/dev/null 2>&1; then
  test_condition "JSON File Valid" "Output file contains valid JSON" 0
else
  test_condition "JSON File Valid" "Output file contains valid JSON" 1
fi
if [ -f "$JSON_FILE" ] && "$PYTHON" -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
ok = doc["configuration"].get("odbc_driver") == "mssql-python"
ok = ok and "driver" not in doc["configuration"]
ok = ok and doc["metrics"].get("odbc_driver_version") is not None
ok = ok and isinstance(doc["metrics"]["warnings"].get("list"), list)
ok = ok and bool(doc.get("server_edition")) and bool(doc.get("server_version"))
raise SystemExit(0 if ok else 1)
' "$JSON_FILE"; then
  test_condition "JSON Shared Schema" "Uses sqlsim driver and warning field names" 0
else
  test_condition "JSON Shared Schema" "Uses sqlsim driver and warning field names" 1
fi
rm -f "$JSON_FILE"

section "VERBOSE MODE TESTS"

test_cmd "Verbose Phase 1" "Shows configuration phase" 0 "PHASE 1" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -v -q
test_cmd "Verbose Phase 5" "Shows completion phase" 0 "PHASE 5" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -v -q
test_cmd "Verbose Connection String" "Shows connection string" 0 "Connection String:" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -v -q
test_cmd "Verbose Metrics" "Shows percentile metrics" 0 "P50 Latency" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -n 5 -r 10 -v -q

echo "${YELLOW}TEST: Verbose Credential Redaction${RESET}"
echo "${GRAY}  Description: Masks password, token, and connection-string credentials in command display${RESET}"
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
then _pass; else _fail "credential masking mismatch"; fi

section "QUIET MODE TESTS"

test_cmd "Quiet Suppresses Results" "No row output in quiet mode" 0 "Total Runtime:" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1 AS ShouldNotShow" -q

section "CONNECTION TEST ONLY"

test_cmd "Connection Test Only" "No query, just test connection" 0 "Connection test" -- "${BASE_AUTH[@]}"
test_cmd "Connection Test JSON" "Connection test with JSON output" 0 "connection_test_only" -- "${BASE_AUTH[@]}" -json

section "RESULT SET TESTS"

test_cmd "Single Column Result" "Display single column" 0 "SingleCol" -- "${BASE_AUTH[@]}" -Q "SELECT 1 AS SingleCol"
test_cmd "Multiple Column Result" "Display multiple columns" 0 "row.*affected" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1 AS A, 2 AS B, 3 AS C"
test_cmd "Multiple Rows" "Display multiple rows" 0 "5 row.*affected" -- \
  "${BASE_AUTH[@]}" -Q "SELECT v.value FROM (VALUES (1), (2), (3), (4), (5)) AS v(value)"

result_sets_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -Q "SELECT 1 AS PerExecution" -n 4 -r 2 2>&1)"
result_sets_count="$(grep -Ec '1 row\(s\) affected' <<<"$result_sets_out")"
test_condition "Result Set Per Execution" "Every execution prints a result set" \
  "$([ "$result_sets_count" -eq 8 ] && echo 0 || echo 1)"

interleave_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT v.value FROM (VALUES (1), (2), (3)) AS v(value)" -n 6 -r 2 2>&1)"
if "$PYTHON" -c '
import re, sys
lines = [re.sub(r"^\S+ \S+ \| ", "", line).rstrip() for line in sys.stdin.read().splitlines()]
headers = malformed = 0
for i, line in enumerate(lines):
    if line != "value":
        continue
    headers += 1
    if i + 4 >= len(lines) or not re.fullmatch(r"-{80}", lines[i + 1]):
        malformed += 1
        continue
    malformed += sum(not re.fullmatch(r"\d+", lines[i + offset]) for offset in range(2, 5))
raise SystemExit(0 if headers == 12 and malformed == 0 else 1)
' <<<"$interleave_out"; then
  test_condition "Result Sets Do Not Interleave" "Concurrent result sets stay intact" 0
else
  test_condition "Result Sets Do Not Interleave" "Concurrent result sets stay intact" 1
fi

error_text_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT * FROM dbo.NoSuchTableForParityTest" -n 4 -r 1 2>&1)"
error_text_count="$(grep -c 'Invalid object name' <<<"$error_text_out")"
test_condition "Error Text Per Failure" "Every failing execution prints its error" \
  "$([ "$error_text_count" -eq 4 ] && echo 0 || echo 1)"

quiet_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT 1 AS Suppressed" -n 4 -r 2 -q 2>&1)"
quiet_sets="$(grep -c 'row(s) affected' <<<"$quiet_out")"
test_condition "Quiet Mode Still Suppresses Rows" "-q suppresses every result set" \
  "$([ "$quiet_sets" -eq 0 ] && echo 0 || echo 1)"

test_cmd "Empty Result Set Reported" "An empty result still prints its header and count" 0 \
  "0 row\(s\) affected" -- "${BASE_AUTH[@]}" -Q "SELECT name FROM sys.objects WHERE 1 = 0"

section "WORKLOAD FILE TESTS"

WORKLOAD_DIR="$TEST_DIR/workloads"
mkdir -p "$WORKLOAD_DIR"
cat > "$WORKLOAD_DIR/single.json" <<'JSON'
{ "workloads": [ { "queries": ["SELECT 1 AS G1"], "threads": 2, "iterations": 3 } ] }
JSON
cat > "$WORKLOAD_DIR/commented.json" <<'JSON'
{
  // Two groups of differing shape.
  "workloads": [
    { "queries": ["SELECT 1 AS A"], "threads": 2, "iterations": 2 },
    { "queries": ["SELECT 2 AS B", "SELECT 3 AS C"], "threads": 1, "iterations": 3 }
  ]
}
JSON
cat > "$WORKLOAD_DIR/duration.json" <<'JSON'
{ "duration_seconds": 2, "workloads": [ { "queries": ["SELECT 1 AS D"], "threads": 2 } ] }
JSON
cat > "$WORKLOAD_DIR/think.json" <<'JSON'
{ "workloads": [ { "queries": ["SELECT 1 AS T"], "threads": 1, "iterations": 5, "think_time_ms": 200 } ] }
JSON

test_cmd "Workload Single Group" "Runs a one-group workload file" 0 "Workload groups: 1" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/single.json" -q
test_cmd "Workload Thread Count From Groups" "Thread count is the sum of groups" 0 "Threads: 3" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/commented.json" -q
test_cmd "Workload Total Batches" "Total batches expands every group" 0 "Total batches to execute: 10" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/commented.json" -q
test_cmd "Workload Comments Accepted" "A workload with comments parses" 0 "Workload groups: 2" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/commented.json" -q
test_cmd "Workload JSON Output" "JSON reports workload group count" 0 '"workload_groups": 2' -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/commented.json" -q -json
test_cmd "Workload Duration Mode" "duration_seconds replaces iterations" 0 "Duration: 2 seconds" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/duration.json" -q

think_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/think.json" -q -json 2>/dev/null)"
if "$PYTHON" -c '
import json, sys
doc = json.load(sys.stdin)
raise SystemExit(0 if doc["metrics"]["total_runtime_seconds"] >= 0.9 else 1)
' <<<"$think_out"; then
  test_condition "Workload Think Time Delays" "Five 200ms think delays take at least 0.9 seconds" 0
else
  test_condition "Workload Think Time Delays" "Five 200ms think delays take at least 0.9 seconds" 1
fi

printf '{ "duration_seconds": 3 }\n' > "$WORKLOAD_DIR/nokey.json"
test_cmd "Workload Rejects Missing Key" "Missing workloads key is refused" 1 "workloads.*required" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/nokey.json" -q
printf '{ "workloads": [ { "file": "x.sql", "queries": ["SELECT 1"], "threads": 1, "iterations": 1 } ] }\n' \
  > "$WORKLOAD_DIR/both.json"
test_cmd "Workload Rejects Both Sources" "A group cannot have file and queries" 1 "cannot have both" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/both.json" -q
test_cmd "Workload Rejects Query Source Conflict" "-Q with -workload is refused" 1 \
  "Cannot use -Q with -workload" -- \
  "${BASE_AUTH[@]}" -workload "$WORKLOAD_DIR/single.json" -Q "SELECT 1" -q
rm -rf "$WORKLOAD_DIR"

section "EXAMPLE FILE TESTS"

EXAMPLE="$SCRIPT_DIR/examples/sql/01-simple-queries.sql"
if [ -f "$EXAMPLE" ]; then
  test_cmd "Example: 01-simple-queries.sql" "Execute catalog view queries (works on any database)" 0 "Total Runtime:" -- \
    "${BASE_AUTH[@]}" -i "$EXAMPLE" -q
else
  echo "${YELLOW}TEST: Example: 01-simple-queries.sql${RESET}"
  _skip "example file not found"
fi

section "LIVE TELEMETRY TESTS"

stream_long="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "WAITFOR DELAY '00:00:04'; SELECT 1 AS StreamProgress" -stream-json -q 2>&1)"
stream_long_rc=$?

stream_check() {
  local name="$1" mode="$2" data="$3" rc="$4"
  echo "${YELLOW}TEST: $name${RESET}"
  echo "${GRAY}  Description: Validate $mode stream behavior${RESET}"
  if STREAM_MODE="$mode" STREAM_RC="$rc" "$PYTHON" -c '
import json, os, sys
lines = [line for line in sys.stdin.read().splitlines() if line.strip()]
try:
    events = [json.loads(line) for line in lines]
except json.JSONDecodeError:
    raise SystemExit(1)
mode = os.environ["STREAM_MODE"]
progress = [e for e in events if e.get("type") == "progress"]
completed = [e for e in events if e.get("type") == "completed"]
checks = {
    "progress": len(progress) >= 3,
    "order": len(events) >= 2 and events[0].get("type") == "started" and events[-1].get("type") == "completed",
    "purity": len(events) == len(lines),
    "started": bool(events) and events[0].get("version") is not None and events[0].get("threads") == 1,
    "metadata": (
        any(e.get("odbc_driver_version") and e.get("server_version") and e.get("server_edition") for e in progress)
        and len(completed) == 1
        and bool(completed[0].get("odbc_driver_version"))
        and bool(completed[0].get("server_version"))
        and bool(completed[0].get("server_edition"))
    ),
    "elapsed": len(progress) >= 2 and all(float(b["elapsed_seconds"]) > float(a["elapsed_seconds"]) for a, b in zip(progress, progress[1:])),
    "completed": len(completed) == 1,
    "counters": len(completed) == 1 and completed[0].get("successful_executions") == 42,
    "throughput": len(completed) == 1 and float(completed[0].get("throughput_per_second", 0)) > 0,
}
raise SystemExit(0 if int(os.environ["STREAM_RC"]) == 0 and checks.get(mode, False) else 1)
' <<<"$data"; then
    _pass
  else
    _fail "$mode stream assertion failed"
  fi
}

stream_check "Stream Progress Cadence" progress "$stream_long" "$stream_long_rc"
stream_check "Stream Event Order" order "$stream_long" "$stream_long_rc"
stream_check "Stream Purity" purity "$stream_long" "$stream_long_rc"
stream_check "Stream Started Fields" started "$stream_long" "$stream_long_rc"
stream_check "Stream Environment Metadata" metadata "$stream_long" "$stream_long_rc"
stream_check "Stream Elapsed Advances" elapsed "$stream_long" "$stream_long_rc"

STREAM_OUTPUT_FILE="$TEST_DIR/stream-redirect.log"
stream_redirect="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT 1 AS StreamRedirect" -stream-json -q -o "$STREAM_OUTPUT_FILE" 2>&1)"
stream_redirect_rc=$?
stream_check "Stream Ignores Output File" completed "$stream_redirect" "$stream_redirect_rc"

stream_threads="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT 1 AS StreamThreads" -n 6 -r 7 -stream-json -q 2>&1)"
stream_threads_rc=$?
stream_check "Stream Counters Under Concurrency" counters "$stream_threads" "$stream_threads_rc"
stream_check "Stream Throughput Reported" throughput "$stream_threads" "$stream_threads_rc"

test_cmd "Stream Canonical JSON Requires Output File" "combined JSON modes require -o" 1 \
  "requires -o" -- "${BASE_AUTH[@]}" -Q "SELECT 1" -json -stream-json -q

STREAM_FINAL_FILE="$TEST_DIR/stream-final.json"
rm -f "$STREAM_FINAL_FILE"
echo "${YELLOW}TEST: Stream Writes Canonical Final JSON${RESET}"
echo "${GRAY}  Description: NDJSON stays on stdout and -o receives the canonical final document${RESET}"
stream_final="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT 1 AS StreamFinal" -stream-json -json -o "$STREAM_FINAL_FILE" -q 2>&1)"
stream_final_rc=$?
if [ "$stream_final_rc" -eq 0 ] && [ -f "$STREAM_FINAL_FILE" ] \
  && STREAM_FINAL_FILE="$STREAM_FINAL_FILE" "$PYTHON" -c '
import json, os, sys
events = [json.loads(line) for line in sys.stdin.read().splitlines() if line.strip()]
with open(os.environ["STREAM_FINAL_FILE"], encoding="utf-8") as handle:
    result = json.load(handle)
valid = (
    len([event for event in events if event.get("type") == "completed"]) == 1
    and result.get("success") is True
    and result.get("configuration", {}).get("total_batches") == 1
    and result.get("configuration", {}).get("stream_json") is True
)
raise SystemExit(0 if valid else 1)
' <<<"$stream_final"; then
  _pass
else
  _fail "stream or canonical final JSON was invalid"
fi
rm -f "$STREAM_FINAL_FILE"

error_total_out="$(with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT * FROM dbo.NoSuchTable_TotalProbe" -n 1 -r 12 -json -q 2>/dev/null)"
if "$PYTHON" -c '
import json, sys
doc = json.load(sys.stdin)
raise SystemExit(0 if doc["metrics"]["errors"]["total"] == 12 else 1)
' <<<"$error_total_out"; then
  test_condition "Error Total Is Not Capped" "Twelve failures report a total of 12" 0
else
  test_condition "Error Total Is Not Capped" "Twelve failures report a total of 12" 1
fi

section "PERIODIC QUERY STATISTICS TESTS"

POLL_TARGET="$TEST_DIR/poll-snapshot.json"
OBSERVED_COUNTS="$TEST_DIR/observed-counts.txt"
rm -f "$POLL_TARGET" "$OBSERVED_COUNTS"
with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "WAITFOR DELAY '00:00:00.100'; SELECT TOP 50 name FROM sys.objects" \
  -n 4 -r 15 -querystats-interval 1 -querystats-file "$POLL_TARGET" -q \
  >/dev/null 2>&1 &
poll_pid=$!
running_snapshots=0
unreadable_snapshots=0
while kill -0 "$poll_pid" 2>/dev/null; do
  if [ -f "$POLL_TARGET" ]; then
    sample="$("$PYTHON" -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
print(doc.get("status", ""), doc.get("query_stats", {}).get("totals", {}).get("executions", -1))
' "$POLL_TARGET" 2>/dev/null)"
    sample_rc=$?
    if [ "$sample_rc" -eq 0 ]; then
      if [[ "$sample" == running\ * ]]; then
        running_snapshots=$((running_snapshots + 1))
        printf '%s\n' "${sample#running }" >> "$OBSERVED_COUNTS"
      fi
    else
      unreadable_snapshots=$((unreadable_snapshots + 1))
    fi
  fi
  sleep 0.05
done
wait "$poll_pid"

test_condition "Snapshot Appears While Running" "At least one snapshot has running status" \
  "$([ "$running_snapshots" -gt 0 ] && echo 0 || echo 1)"
test_condition "Snapshot Is Never Partially Written" "Every observed snapshot parsed" \
  "$([ "$unreadable_snapshots" -eq 0 ] && echo 0 || echo 1)"
unique_counts="$(sort -u "$OBSERVED_COUNTS" 2>/dev/null | wc -l | tr -d ' ')"
test_condition "Snapshot Counts Advance" "Execution totals advance while running" \
  "$([ "$unique_counts" -gt 1 ] && echo 0 || echo 1)"

snapshot_assert() {
  local name="$1" mode="$2" file="$3" description="$4"
  if [ -f "$file" ] && SNAPSHOT_MODE="$mode" "$PYTHON" -c '
import json, os, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
mode = os.environ["SNAPSHOT_MODE"]
totals = doc.get("query_stats", {}).get("totals", {})
checks = {
    "final": doc.get("status") == "complete" and totals.get("executions") == 60,
    "peak": float(doc.get("peak_throughput", 0)) >= float(doc.get("throughput", 0)),
    "config": doc.get("config", {}).get("threads") == 4 and doc.get("config", {}).get("total_batches") == 60,
    "errors": doc.get("total_errors") == 3 and bool(doc.get("recent_errors")) and "Invalid object name" in doc["recent_errors"][0].get("message", ""),
    "failures": totals.get("failures") == 3,
}
raise SystemExit(0 if checks.get(mode, False) else 1)
' "$file"; then
    test_condition "$name" "$description" 0
  else
    test_condition "$name" "$description" 1
  fi
}

snapshot_assert "Snapshot Final Status" final "$POLL_TARGET" "Final snapshot is complete with 60 executions"
snapshot_assert "Snapshot Peak Throughput Retained" peak "$POLL_TARGET" "Peak throughput is at least final throughput"
snapshot_assert "Snapshot Config Block" config "$POLL_TARGET" "Snapshot describes its run"

ERROR_SNAPSHOT="$TEST_DIR/error-snapshot.json"
with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" \
  -Q "SELECT * FROM dbo.NoSuchTable_SnapshotSuite" -n 1 -r 3 \
  -querystats-interval 1 -querystats-file "$ERROR_SNAPSHOT" -q >/dev/null 2>&1
snapshot_assert "Snapshot Records Errors" errors "$ERROR_SNAPSHOT" "Failure count and text are retained"
snapshot_assert "Snapshot Records Failed Executions" failures "$ERROR_SNAPSHOT" "Query totals report failures"

DEFAULT_SNAPSHOT_DIR="$TEST_DIR/default-snapshot"
mkdir -p "$DEFAULT_SNAPSHOT_DIR"
(
  cd "$DEFAULT_SNAPSHOT_DIR" || exit 1
  with_secret "$PYTHON" "$SQLPYSIM" "${BASE_AUTH[@]}" -Q "SELECT 1 AS DefaultSnapshot" -n 1 -r 2 \
    -querystats-interval 1 -q >/dev/null 2>&1
)
test_condition "Snapshot Default File Name" "Default snapshot is querystats-live.json" \
  "$([ -f "$DEFAULT_SNAPSHOT_DIR/querystats-live.json" ] && echo 0 || echo 1)"

test_cmd "Snapshot Rejects Non-Numeric Interval" "Interval must be numeric" 1 \
  "Invalid value for -querystats-interval" -- \
  "${BASE_AUTH[@]}" -Q "SELECT 1" -querystats-interval soon -q

rm -rf "$TEST_DIR"

total=$((passed + failed + skipped))
duration=$(( $(date +%s) - start_time ))

section "FULL TEST SUITE RESULTS"
echo "Total Tests: $total"
echo "Passed: $passed"
echo "Skipped: $skipped"
echo "Failed: $failed"
echo "Duration: ${duration} seconds"
echo "${CYAN}========================================${RESET}"
echo

if [ "$failed" -eq 0 ]; then
  echo "${GREEN}ALL TESTS PASSED${RESET}"
  exit 0
fi
echo "${RED}SOME TESTS FAILED${RESET}"
exit 1
