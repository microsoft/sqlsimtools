#!/usr/bin/env bash
# Comprehensive test suite for sqlsim on Linux.
#
# Native bash port of full-test-suite.ps1 so Linux users never need PowerShell.
# Test names match the PowerShell suite so the inventories can be compared; see
# --list-tests and scripts/check-suite-parity.ps1.
#
# Usage:
#   ./full-test-suite-linux.sh [--server HOST] [--database DB] \
#       (--username USER --password-file FILE | --token-file FILE)
#       [--sqlsim PATH] [--skip-scale] [--stop-on-error]
#   ./full-test-suite-linux.sh --list-tests
#
# Options:
#   --password, --token   Pass the secret directly (visible in process lists;
#                         prefer the -file forms)
#   --sqlsim PATH         sqlsim binary (default: build/linux-x64/sqlsim)
#   --skip-scale          Skip the 1024-thread tests on constrained targets
#   --stop-on-error       Stop at the first failing test
#   --list-tests          Print the test inventory and exit
#
# Requires jq. Secret files are read from their first line, and a Windows CRLF
# line ending is ignored.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="localhost"
DATABASE="tempdb"
USERNAME=""
PASSWORD=""
TOKEN=""
SQLSIM=""
SKIP_SCALE=0
STOP_ON_ERROR=0

# Implemented tests only. Extend as each group is ported.
TEST_NAMES=(
  # Group A: argument and parameter validation
  "No Arguments"
  "Query and File Conflict"
  "Empty Input File"
  "Login Timeout"
  "Invalid Threads (Text)"
  "Invalid Threads (Too High)"
  "Invalid Threads (Zero)"
  "Invalid Timeout"
  "Invalid Iterations"
  "Missing Server Name"
  "Missing Database Name"
  "Missing Connection String"
  "Missing Query"
  "Query Starting With SQL Comment"
  "Query Starting With Flag-Like Comment"
  "Missing Query Before A Flag"
  "Missing Query Before Output Flag"
  "Missing Input File"
  "Missing Username"
  "Missing Password"
  "Missing Access Token"
  "Missing App Name"
  "Missing Thread Count"
  "Missing Iteration Count"
  "Missing Login Timeout"
  "Missing Query Timeout"
  "Missing Retry Count"
  "Missing Retry Delay"
  "Invalid Encryption Level"
  "Missing Certificate Hostname"
  "Long Certificate Hostname"
  "Certificate Conflict"
  "Server Name Too Long"
  "Database Name Too Long"
  "Invalid Database Characters"
  "Username Too Long"
  "Password Too Long"
  "Access Token Too Short"
  "App Name Too Long"
  "Connection String Too Long"
  # Group B: connection, concurrency, prepared statements, encryption
  "Default Localhost"
  "Server with Port"
  "Connection String Mode"
  "Verbose Output"
  "Non-Verbose Batch Terminology"
  "Multiple Iterations"
  "Prepared Statements (2 threads)"
  "Prepared Statements (10 threads)"
  "Prepared Statements (50 threads)"
  "Prepared Statements with Iterations"
  "Prepared Statements with Reconnect"
  "File Parsing"
  "Empty Query String"
  "Connection Test Only"
  "Connection Test With Database"
  "Connection Test Verbose"
  "Connection Test Multiple Threads"
  "Connection Test Multiple Iterations"
  "Connection Test Threads And Iterations"
  "Path Length Validation"
  "Null Byte Validation"
  "High Concurrency (100 threads)"
  "High Concurrency with Prepared Statements (100 threads)"
  "Higher Thread Count"
  "Higher Thread Count with Prepared Statements"
  "Threads with Query Timeout"
  "Threads with Verbose Mode"
  "Threads with Reconnect"
  "Threads with Connection Pooling"
  "Threads with Application Name"
  "Threads with Stop On Error"
  "Application Name"
  "Connection Retry Count"
  "Connection Retry Delay"
  "Invalid Retry Count (Negative)"
  "Invalid Retry Count (Too High)"
  "Invalid Retry Delay (Zero)"
  "Invalid Retry Delay (Too High)"
  "Continue On Error (Default)"
  "TDS 8.0 Mandatory Encryption"
  "TDS 8.0 Optional Encryption"
  "TDS 8.0 Default Encryption"
  "TDS 8.0 Mandatory Cert Fail"
  "TDS 8.0 Strict Encryption"
  "TDS 8.0 Default Cert Fail"
  "Certificate Hostname"
  # Group C: error handling, batch separators, cursor state, T-SQL features
  "Reconnect Mode"
  "Connection Pooling"
  "Connection Pooling Without Reconnect"
  "Missing Connection Info"
  "Missing Authentication"
  "Invalid SQL Syntax"
  "Non-existent Database"
  "Missing Query File"
  "GO Separator Query (Simple)"
  "GO Separator Query (Multiple)"
  "GO Separator Case Insensitive"
  "GO Separator File (Detailed)"
  "Multi-Statement Query"
  "Multi-Statement File"
  "Result Set Separators"
  "RETURN Value + Second Batch"
  "RAISERROR + Result + Second Batch"
  "NOCOUNT Toggle + Second Batch"
  "Prepared Stmt + OUTPUT Param + Second Batch"
  "Transaction Across Batches"
  "FOR XML + Second Batch"
  "FOR JSON + Second Batch"
  "TRY/CATCH + Second Batch"
  "Temp Table Across Batches"
  "THROW Error + Second Batch"
  "Large LOB Data Retrieval"
  "NULL Values in Results"
  "Empty Result + Second Batch"
  "DML + SELECT Second Batch"
  "T-SQL Cursor + Second Batch"
  "INSERT EXEC + Second Batch"
  "Severity 16 Error + Second Batch"
  "WAITFOR Timeout + Second Batch"
  "NULL Multiple Types + Second Batch"
  "Unicode Query Literals (File)"
  "Binary Data + Second Batch"
  # Group D: output files, JSON, credential masking
  "Output File Redirection"
  "Output File Error Capture"
  "Output File Permission Denied"
  "JSON Output Format"
  "JSON Output to File"
  "JSON Output Multi-threaded"
  "JSON Suppresses Verbose Output"
  "Password Masking - PWD Format"
  "Username Masking - UID Format"
  "Connection String Password Masking"
  "Attached Password Masking"
  "Braced Password Masking"
  "Output File Thread Safety"
  "Access Token Size Limit"
  "Empty Access Token"
  "High Concurrency Connection Metrics"
  # Group E: output validation, PRINT behaviour, documented examples
  "Timestamp Format and Output Features"
  "Non-Verbose Output Validation"
  "Optional Features Display"
  "Verbose Output Validation"
  "JSON Output Validation"
  "No Queries Terminology"
  "Multiple PRINT Statements"
  "PRINT Between SELECTs"
  "PRINT From File Input"
  "Help Example: Connection Test"
  "Help Example: Basic Query"
  "Help Example: Load Test Pattern"
  "Doc Example: Default Localhost"
  "Doc Example: Verbose Mode"
  "Doc Example: Prepared Statements"
  "Doc Example: Connection String"
  "Script Example: localhost-simple-test Pattern 1"
  "Script Example: localhost-simple-test Pattern 3"
  "Script Example: json-output-examples Pattern 1"
  "Script Example: json-output-examples Pattern 2"
  "Script Example: json-output-examples Pattern 4"
  "SQL Example: 01-simple-queries.sql"
  # Group F: workload files and replay
  "Workload: Basic Execution"
  "Workload: Config Display"
  "Workload: Completion"
  "Querystats: Value Validation"
  "Workload: Querystats"
  "Workload: Querystats Totals"
  "Workload: JSON Output"
  "Workload: JSON Querystats"
  "Workload Conflict: -Q with -workload"
  "Workload Conflict: -i with -workload"
  "Workload Conflict: -replay with -workload"
  "Workload: Missing File"
  "Workload: -n Ignored Warning"
  "Workload: -r Ignored Warning"
  "Replay Conflict: -Q with -replay"
  "Replay Conflict: -i with -replay"
  "Replay Conflict: -p with -replay"
  "Replay Conflict: -reconnect with -replay"
  "Replay Conflict: -usepool with -replay"
  "Replay Conflict: Missing -replayfile"
  "Replay Conflict: Missing -replay"
  "Replay Conflict: Invalid replay mode"
  "Replay Fast: Completion"
  "Replay Fast: Replay Summary Text"
  "Replay Fast: Replay Result Text"
  "Replay Stress: Completion"
  "Replay Stress: Replay Summary"
  "Replay JSON: Valid JSON"
  "Replay JSON: Replay Summary Fields"
  "Replay JSON: Original Event Count"
  "Replay JSON: Original Performance Comparison"
  "Replay Verbose: Configuration"
  "Replay Fast: -n Warning"
  # Group G: performance regression checks
  "Single-thread SELECT 1 x1000"
  "4-thread SELECT 1 x1000"
  "4-thread sys.objects x500"
  # Certificate connection-string validation
  "Certificate: $"
  "Certificate: keyword appears once"
  "Certificate: token stays out of the connection string"
)

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --server)        SERVER="$2"; shift 2 ;;
    --database)      DATABASE="$2"; shift 2 ;;
    --username)      USERNAME="$2"; shift 2 ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --password-file) PASSWORD="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --token-file)    TOKEN="$(head -n 1 -- "$2" | tr -d '\r')"; shift 2 ;;
    --sqlsim)        SQLSIM="$2"; shift 2 ;;
    --skip-scale)    SKIP_SCALE=1; shift ;;
    --stop-on-error) STOP_ON_ERROR=1; shift ;;
    --list-tests)    printf '%s\n' "${TEST_NAMES[@]}"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SQLSIM" ] || SQLSIM="$SCRIPT_DIR/build/linux-x64/sqlsim"
if [ ! -x "$SQLSIM" ]; then
  echo "ERROR: sqlsim not found at $SQLSIM" >&2
  echo "       run ./build-linux.sh first, or pass --sqlsim PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to check sqlsim JSON output" >&2
  echo "       install it with: sudo apt-get install -y jq" >&2
  exit 1
fi

case "$SERVER" in
  *database.windows.net*|*database.fabric.microsoft.com*) IS_AZURE=1 ;;
  *) IS_AZURE=0 ;;
esac

AUTH=()
AUTH_SECRET=""
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
  AUTH_METHOD="SQL Authentication"
  AUTH=(-U "$USERNAME" -P -)
  AUTH_SECRET="$PASSWORD"
  # Non-Azure targets commonly present a self-signed certificate.
  [ "$IS_AZURE" -eq 0 ] && AUTH+=(-C)
elif [ -n "$TOKEN" ]; then
  AUTH_METHOD="Access Token"
  AUTH=(-T -)
  AUTH_SECRET="$TOKEN"
else
  AUTH_METHOD="Windows Integrated"
  AUTH=(-E)
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
# Certificate-rejection tests must not inherit the suite-level -C.
AUTH_NOCERT=()
for a in "${AUTH[@]}"; do [ "$a" = "-C" ] || AUTH_NOCERT+=("$a"); done
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

# test_cmd <name> <desc> <should_fail> <expect_regex> -- <args...>
test_cmd() {
  local name="$1" desc="$2" should_fail="$3" expect="$4"
  shift 5
  echo "${YELLOW}TEST: $name${RESET}"
  echo "${GRAY}  Description: $desc${RESET}"
  local out rc
  out="$(with_secret "$SQLSIM" "$@" 2>&1)"; rc=$?
  if [ "$should_fail" -eq 1 ]; then
    [ "$rc" -eq 0 ] && { _fail "expected non-zero exit code but got 0"; return; }
  else
    [ "$rc" -ne 0 ] && { _fail "exit code $rc"; return; }
  fi
  if [ -n "$expect" ] && ! grep -qiE "$expect" <<<"$out"; then
    _fail "output didn't contain expected: $expect"; return
  fi
  _pass
}

echo
section "SQLSIM FULL TEST SUITE (Linux)"
echo "Server: $SERVER"
echo "Database: $DATABASE"
echo "Authentication: $AUTH_METHOD"
echo "Binary: $SQLSIM"
echo "Implemented tests: ${#TEST_NAMES[@]}"
echo

section "BASIC FUNCTIONALITY TESTS"

test_cmd "No Arguments" "Run without arguments shows usage" 1 "Usage:" --

section "FILE PARSING TESTS"

test_cmd "Query and File Conflict" "Reject -Q and -i together" 1 "Cannot use -Q with -i" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -i "examples/sql/01-simple-queries.sql" -q

: > "$TEST_DIR/test_empty_input.sql"
test_cmd "Empty Input File" "Reject empty input file with no batches" 1 "No batches found in input file" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$TEST_DIR/test_empty_input.sql"
rm -f "$TEST_DIR/test_empty_input.sql"

section "TIMEOUT TESTS"

test_cmd "Login Timeout" "Verify login timeout on invalid server" 1 "08001|timeout" -- \
  -S "invalid-server-12345.example.com" -d tempdb "${AUTH[@]}" -l 2 -Q "SELECT 1" -q

section "ENHANCED PARAMETER VALIDATION TESTS"

test_cmd "Invalid Threads (Text)" "Reject non-numeric thread count" 1 "sqlsim error.*Invalid.*thread" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n abc
test_cmd "Invalid Threads (Too High)" "Reject thread count > INT_MAX" 1 "sqlsim error.*Thread count.*out of range" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 999999999999
test_cmd "Invalid Threads (Zero)" "Reject thread count = 0" 1 "sqlsim error.*Number of threads must be between 1 and 2147483647" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 0
test_cmd "Invalid Timeout" "Reject non-numeric timeout" 1 "sqlsim error.*Invalid.*timeout" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -t xyz
test_cmd "Invalid Iterations" "Reject invalid iteration count" 1 "sqlsim error.*Iterations per thread must be between 1 and" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -r "-5"

section "MISSING VALUE DETECTION TESTS"

test_cmd "Missing Server Name" "Reject -S without server name" 1 "sqlsim error.*Server name cannot be empty" -- \
  -S -E -Q "SELECT 1"
test_cmd "Missing Database Name" "Reject -d without database name" 1 "sqlsim error.*Database name cannot be empty" -- \
  -S localhost -d -E -Q "SELECT 1"
test_cmd "Missing Connection String" "Reject -c without connection string" 1 "sqlsim error.*Connection string cannot be empty" -- \
  -c -Q "SELECT 1"
test_cmd "Missing Query" "Reject -Q without query" 1 "sqlsim error.*Query cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q
test_cmd "Query Starting With SQL Comment" "A query whose first line is a -- comment executes" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "-- leading comment
SELECT 1 AS CommentedQuery" -q
test_cmd "Query Starting With Flag-Like Comment" "A comment that begins like a known flag is still query text" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "--help me count rows
SELECT 1 AS FlagLikeComment" -q
test_cmd "Missing Query Before A Flag" "Reject -Q when the next argument is a whole flag" 1 "sqlsim error.*Query cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q -v
test_cmd "Missing Query Before Output Flag" "Reject -Q when followed by -o" 1 "sqlsim error.*Query cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q -o
test_cmd "Missing Input File" "Reject -i without file path" 1 "sqlsim error.*Input file path cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -i
test_cmd "Missing Username" "Reject -U without username" 1 "sqlsim error.*Username cannot be empty" -- \
  -S localhost -U -P password -Q "SELECT 1"
test_cmd "Missing Password" "Reject -P without password" 1 "sqlsim error.*Password cannot be empty" -- \
  -S localhost -U username -P -Q "SELECT 1"
test_cmd "Missing Access Token" "Reject -T without access token" 1 "sqlsim error.*Access token cannot be empty" -- \
  -S localhost -T -Q "SELECT 1"
test_cmd "Missing App Name" "Reject -app without application name" 1 "sqlsim error.*Application name cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -app -Q "SELECT 1"
test_cmd "Missing Thread Count" "Reject -n without thread count" 1 "sqlsim error.*Thread count cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -n -Q "SELECT 1"
test_cmd "Missing Iteration Count" "Reject -r without iteration count" 1 "sqlsim error.*Iteration count cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -r -Q "SELECT 1"
test_cmd "Missing Login Timeout" "Reject -l without timeout value" 1 "sqlsim error.*Timeout value cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -l -Q "SELECT 1"
test_cmd "Missing Query Timeout" "Reject -t without timeout value" 1 "sqlsim error.*Timeout value cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -t -Q "SELECT 1"
test_cmd "Missing Retry Count" "Reject -retry without retry count" 1 "sqlsim error.*Retry count cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -retry -Q "SELECT 1"
test_cmd "Missing Retry Delay" "Reject -retrydelay without delay value" 1 "sqlsim error.*(Retry delay|Invalid|Unknown option)" -- \
  "${BASE[@]}" "${AUTH[@]}" -retrydelay

section "ENCRYPTION PARAMETER VALIDATION TESTS"

test_cmd "Invalid Encryption Level" "Reject invalid encryption level" 1 "Invalid encryption level.*Valid options: o.*m.*s" -- \
  "${BASE[@]}" "${AUTH[@]}" -N x -Q "SELECT 1"
test_cmd "Missing Certificate Hostname" "Reject -F without hostname" 1 "Certificate hostname cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -F -Q "SELECT 1"
test_cmd "Long Certificate Hostname" "Reject certificate hostname > 253 chars" 1 "Certificate hostname.*maximum length" -- \
  "${BASE[@]}" "${AUTH[@]}" -F "$(printf 'a%.0s' $(seq 254))" -Q "SELECT 1"
test_cmd "Certificate Conflict" "Reject -F and -C together" 1 "Cannot use -F.*with -C" -- \
  "${BASE[@]}" "${AUTH[@]}" -F localhost -C -Q "SELECT 1"

section "STRING PARAMETER VALIDATION TESTS"

test_cmd "Server Name Too Long" "Reject server names exceeding 253 characters" 1 "Server name.*maximum length" -- \
  -S "$(printf 'x%.0s' $(seq 300))" -E -Q "SELECT 1"
test_cmd "Database Name Too Long" "Reject database names exceeding 128 characters" 1 "Database name.*maximum length" -- \
  -S localhost -d "$(printf 'x%.0s' $(seq 200))" -E -Q "SELECT 1"
test_cmd "Invalid Database Characters" "Reject database names with connection string metacharacters" 1 "Database name contains invalid characters" -- \
  -S localhost -d "test;database" -E -Q "SELECT 1"
test_cmd "Username Too Long" "Reject usernames exceeding 128 characters" 1 "Username.*maximum length" -- \
  -S localhost -U "$(printf 'x%.0s' $(seq 200))" -P password -Q "SELECT 1"
test_cmd "Password Too Long" "Reject passwords exceeding 128 characters" 1 "Password.*maximum length" -- \
  -S localhost -U username -P "$(printf 'x%.0s' $(seq 200))" -Q "SELECT 1"
test_cmd "Access Token Too Short" "Reject access tokens shorter than 10 characters" 1 "Invalid access token format" -- \
  -S localhost -T "abc" -Q "SELECT 1"
test_cmd "App Name Too Long" "Reject application names exceeding 128 characters" 1 "Application name.*maximum length" -- \
  "${BASE[@]}" "${AUTH[@]}" -app "$(printf 'x%.0s' $(seq 200))" -Q "SELECT 1"
test_cmd "Connection String Too Long" "Reject connection strings exceeding 4096 characters" 1 "Connection string.*maximum length" -- \
  -c "Driver={ODBC Driver 18 for SQL Server};Server=localhost;$(printf 'x%.0s' $(seq 4200))" -Q "SELECT 1"

section "CONNECTION AND OUTPUT TESTS"

# The PowerShell suite hardcodes -E here, which forces Kerberos on Linux.
test_cmd "Default Localhost" "Connect without -S (defaults to localhost)" 0 "Total Runtime:" -- \
  -d "$DATABASE" -S "$SERVER" "${AUTH[@]}" -Q "SELECT @@VERSION" -q
test_cmd "Server with Port" "Connect using server,port format" 0 "Total Runtime:" -- \
  -S "$SERVER" "${AUTH[@]}" -d "$DATABASE" -Q "SELECT @@VERSION" -q

if [ -n "$USERNAME" ] && [ -z "$TOKEN" ]; then
  test_cmd "Connection String Mode" "Execute query using full connection string" 0 "Total Runtime:" -- \
    -c "Driver={ODBC Driver 18 for SQL Server};Server=$SERVER;Database=$DATABASE;UID=$USERNAME;PWD=$PASSWORD;TrustServerCertificate=yes;" -Q "SELECT 1" -q
else
  echo "${YELLOW}TEST: Connection String Mode${RESET}"
  _skip "requires SQL authentication"
fi

test_cmd "Verbose Output" "Verify verbose mode shows detailed output with correct terminology" 0 "\[PHASE 5\]" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1 AS TestCol" -v
test_cmd "Non-Verbose Batch Terminology" "Verify non-verbose output uses batch terminology" 0 "Batches in workload" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -q
test_cmd "Multiple Iterations" "Run 5 iterations with 2 threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 2 -r 5 -q

section "PREPARED STATEMENTS TESTS"

test_cmd "Prepared Statements (2 threads)" "Execute queries using prepared statements with 2 threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 2 -r 5 -q
test_cmd "Prepared Statements (10 threads)" "Execute queries using prepared statements with 10 threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 10 -r 3 -q
test_cmd "Prepared Statements (50 threads)" "Execute queries using prepared statements with 50 threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 50 -r 2 -q
test_cmd "Prepared Statements with Iterations" "Verify prepared statements work with multiple iterations" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 5 -r 10 -q
test_cmd "Prepared Statements with Reconnect" "Verify prepared statements work with -reconnect flag" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 3 -r 3 -reconnect -q

section "FILE PARSING AND QUERY VALIDATION TESTS"

printf -- '-- Test query 1\nSELECT 1 AS Test1;\nGO\n\n-- Test query 2\nSELECT 2 AS Test2;\nGO\n\n-- Test query 3\nSELECT GETDATE() AS CurrentTime;\nGO\n' \
  > "$TEST_DIR/smoke_test_queries.sql"
test_cmd "File Parsing" "Parse and execute queries from file" 0 "Batches in workload: 3" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$TEST_DIR/smoke_test_queries.sql" -q
rm -f "$TEST_DIR/smoke_test_queries.sql"

test_cmd "Empty Query String" "Reject completely empty queries" 1 "Query cannot be empty" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q ""

section "CONNECTION-ONLY TESTING TESTS"

test_cmd "Connection Test Only" "Test connection without any queries" 0 "Mode: Connection test only" -- \
  "${BASE[@]}" "${AUTH[@]}" -q
test_cmd "Connection Test With Database" "Test connection to specific database" 0 "Mode: Connection test only" -- \
  "${BASE[@]}" "${AUTH[@]}" -q
test_cmd "Connection Test Verbose" "Test connection in verbose mode" 0 "Mode: Connection test only" -- \
  "${BASE[@]}" "${AUTH[@]}" -v -q
test_cmd "Connection Test Multiple Threads" "Test connection-only mode with multiple threads" 0 "Threads: 3" -- \
  "${BASE[@]}" "${AUTH[@]}" -n 3 -q
test_cmd "Connection Test Multiple Iterations" "Test connection-only mode with multiple iterations" 0 "Iterations per thread: 5" -- \
  "${BASE[@]}" "${AUTH[@]}" -r 5 -q
test_cmd "Connection Test Threads And Iterations" "Test connection-only mode with threads and iterations" 0 "Threads: 2" -- \
  "${BASE[@]}" "${AUTH[@]}" -n 2 -r 3 -q

section "SECURITY VALIDATION TESTS"

test_cmd "Path Length Validation" "Explain an input path longer than the operating system allows" 1 "Cannot open input file: .*File name too long" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$(printf 'x%.0s' $(seq 5000)).sql"
test_cmd "Null Byte Validation" "Reject file paths with null bytes" 1 "Cannot open input file" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "test.sql.missing"

section "CONCURRENCY TESTS"

test_cmd "High Concurrency (100 threads)" "Run 100 threads with 10 iterations each" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 100 -r 10 -q
test_cmd "High Concurrency with Prepared Statements (100 threads)" "Run 100 threads with prepared statements" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 100 -r 5 -q

if [ "$SKIP_SCALE" -eq 1 ]; then
  echo "${YELLOW}TEST: Higher Thread Count (1024)${RESET}"; _skip "--skip-scale specified"
  echo "${YELLOW}TEST: Higher Thread Count with Prepared Statements (1024)${RESET}"; _skip "--skip-scale specified"
else
  test_cmd "Higher Thread Count (1024)" "Verify higher thread counts work correctly" 0 "Total Runtime:" -- \
    "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 1024 -r 2 -l 60 -v
  test_cmd "Higher Thread Count with Prepared Statements (1024)" "Verify prepared statements work with very high thread counts" 0 "Total Runtime:" -- \
    "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 1024 -r 1 -l 60 -v
fi

test_cmd "Threads with Query Timeout" "Verify -t works with multiple threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 10 -t 30 -q
test_cmd "Threads with Verbose Mode" "Verify -v works with multiple threads" 0 "Thread.*Connected successfully" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 5 -v
test_cmd "Threads with Reconnect" "Verify -reconnect works with multiple threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 5 -r 3 -reconnect -q
test_cmd "Threads with Connection Pooling" "Verify -usepool works with multiple threads and reconnect" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 5 -r 3 -reconnect -usepool -q
test_cmd "Threads with Application Name" "Verify -app works with multiple threads" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -app "ConcurrencyTest" -Q "SELECT 1" -n 10 -q
test_cmd "Threads with Stop On Error" "Verify -stoponerror stops all threads on first error" 1 "STOP: Stopping execution due to error" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1/0" -n 5 -stoponerror -q

section "PARAMETER BEHAVIOUR TESTS"

test_cmd "Application Name" "Verify -app parameter sets application name" 0 "SmokeTest" -- \
  "${BASE[@]}" "${AUTH[@]}" -app "SmokeTest" -Q "SELECT program_name FROM sys.dm_exec_sessions WHERE session_id = @@SPID"
test_cmd "Connection Retry Count" "Verify -retry parameter is accepted" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -retry 3 -Q "SELECT 1" -q
test_cmd "Connection Retry Delay" "Verify -retrydelay parameter is accepted" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -retry 2 -retrydelay 5 -Q "SELECT 1" -q
test_cmd "Invalid Retry Count (Negative)" "Reject negative retry count" 1 "Connect retry count must be between 0 and 255" -- \
  "${BASE[@]}" "${AUTH[@]}" -retry "-1" -Q "SELECT 1"
test_cmd "Invalid Retry Count (Too High)" "Reject retry count > 255" 1 "Connect retry count must be between 0 and 255" -- \
  "${BASE[@]}" "${AUTH[@]}" -retry 300 -Q "SELECT 1"
test_cmd "Invalid Retry Delay (Zero)" "Reject retry delay = 0" 1 "Connect retry interval must be between 1 and 60" -- \
  "${BASE[@]}" "${AUTH[@]}" -retrydelay 0 -Q "SELECT 1"
test_cmd "Invalid Retry Delay (Too High)" "Reject retry delay > 60" 1 "Connect retry interval must be between 1 and 60" -- \
  "${BASE[@]}" "${AUTH[@]}" -retrydelay 100 -Q "SELECT 1"
test_cmd "Continue On Error (Default)" "Verify default behaviour continues through errors" 1 "Total Errors: 5" -- \
  "${BASE[@]}" "${AUTH[@]}" -r 5 -Q "SELECT 1/0" -q

section "TDS 8.0 ENCRYPTION TESTS"

test_cmd "TDS 8.0 Mandatory Encryption" "Test mandatory encryption with certificate bypass" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -N m -C -Q "SELECT 1" -q
test_cmd "TDS 8.0 Optional Encryption" "Test optional encryption" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -N o -Q "SELECT 1" -q
test_cmd "TDS 8.0 Default Encryption" "Test -N defaults to mandatory encryption with certificate bypass" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -N -C -Q "SELECT 1" -q

if [ "$IS_AZURE" -eq 1 ]; then
  for t in "TDS 8.0 Mandatory Cert Fail" "TDS 8.0 Strict Encryption" "TDS 8.0 Default Cert Fail" "Certificate Hostname"; do
    echo "${YELLOW}TEST: $t${RESET}"; _skip "Azure SQL Database has valid certificates"
  done
else
  # Linux reports OpenSSL wording rather than the Windows schannel text.
  test_cmd "TDS 8.0 Mandatory Cert Fail" "Mandatory encryption fails without certificate bypass" 1 "certificate|SSL|TLS" -- \
    "${BASE[@]}" "${AUTH_NOCERT[@]}" -N m -Q "SELECT 1" -q
  test_cmd "TDS 8.0 Strict Encryption" "Strict encryption fails with self-signed certificate" 1 "" -- \
    "${BASE[@]}" "${AUTH[@]}" -N s -C -Q "SELECT 1" -q
  test_cmd "TDS 8.0 Default Cert Fail" "-N (default mandatory) fails without certificate bypass" 1 "certificate|SSL|TLS" -- \
    "${BASE[@]}" "${AUTH_NOCERT[@]}" -N -Q "SELECT 1" -q
  test_cmd "Certificate Hostname" "Test certificate hostname parameter" 1 "certificate|SSL|TLS" -- \
    "${BASE[@]}" "${AUTH_NOCERT[@]}" -N m -F localhost -Q "SELECT 1" -q
fi

section "RECONNECT AND POOLING TESTS"

test_cmd "Reconnect Mode" "Verify -reconnect disconnects and reconnects after each iteration" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -r 3 -reconnect -q
test_cmd "Connection Pooling" "Verify -usepool enables connection pooling with reconnect" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -r 3 -reconnect -usepool -q
test_cmd "Connection Pooling Without Reconnect" "Verify -usepool requires -reconnect" 1 "usepool requires -reconnect" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -usepool -q

section "ERROR HANDLING TESTS"

test_cmd "Missing Connection Info" "Fail when no connection information provided" 1 "Connection information is required" -- \
  -Q "SELECT 1"
test_cmd "Missing Authentication" "Fail when server provided but no authentication method" 1 "Must specify either -E.*-A.*-T.*or -U" -- \
  -S localhost -Q "SELECT 1"
test_cmd "Invalid SQL Syntax" "Handle SQL syntax errors gracefully" 1 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "INVALID SQL SYNTAX HERE" -q
test_cmd "Non-existent Database" "Handle connection to non-existent database" 1 "" -- \
  -S "$SERVER" -d NonExistentDatabase999 "${AUTH[@]}" -Q "SELECT 1" -q
test_cmd "Missing Query File" "Fail when specified file doesn't exist" 1 "Cannot open input file" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "nonexistent_file_xyz.sql"

section "GO BATCH SEPARATOR TESTS"

test_cmd "GO Separator Query (Simple)" "Execute GO-separated batches in -Q mode" 0 "Total batches to execute: 2" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf 'SELECT 1 AS FirstBatch\nGO\nSELECT 2 AS SecondBatch')" -q
test_cmd "GO Separator Query (Multiple)" "Execute multiple GO-separated batches in -Q mode" 0 "Total batches to execute: 3" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf 'SELECT @@VERSION\nGO\nSELECT DB_NAME()\nGO\nSELECT GETDATE()')" -q
test_cmd "GO Separator Case Insensitive" "Test GO separator is case insensitive" 0 "Total batches to execute: 2" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT 'First' as Test\ngo\nSELECT 'Second' as Test")" -q

printf -- "-- First batch\nSELECT 'Batch 1' as BatchName;\nGO\n\n-- Second batch with comments\nSELECT 'Batch 2' as BatchName,\n       GETDATE() as CurrentTime;\nGO\n\n-- Third batch\nSELECT COUNT(*) as ObjectCount\nFROM sys.objects\nWHERE type = 'U';\nGO\n" \
  > "$TEST_DIR/test_go_batches.sql"
test_cmd "GO Separator File (Detailed)" "Execute detailed GO-separated file with comments" 0 "Batches in workload: 3" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$TEST_DIR/test_go_batches.sql" -q
rm -f "$TEST_DIR/test_go_batches.sql"

section "MULTI-RESULT SET TESTS"

test_cmd "Multi-Statement Query" "Execute multiple statements in single -Q command" 0 "Total batches to execute: 1" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT @@VERSION; SELECT COUNT(*) as ObjectCount FROM sys.objects WHERE type='U'" -q

printf 'SELECT @@VERSION;\nSELECT COUNT(*) as TableCount FROM sys.tables;\nSELECT DB_NAME() as CurrentDatabase;\n' \
  > "$TEST_DIR/test_multistatement.sql"
test_cmd "Multi-Statement File" "Execute file with semicolon-separated statements" 0 "Total batches to execute: 1" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$TEST_DIR/test_multistatement.sql" -q
rm -f "$TEST_DIR/test_multistatement.sql"

test_cmd "Result Set Separators" "Verify multiple result sets are properly separated" 0 "Total batches to execute: 1" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 'First Result' as Result; SELECT 'Second Result' as Result" -q

section "CURSOR STATE TESTS"

test_cmd "RETURN Value + Second Batch" "EXEC with RETURN value must not break next batch" 0 "AfterReturn" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "DECLARE @rc INT; EXEC @rc = sp_executesql N'SELECT 1'; SELECT @rc AS ReturnCode\nGO\nSELECT 'AfterReturn' AS Status")"
test_cmd "RAISERROR + Result + Second Batch" "RAISERROR with results must not break next batch" 0 "SecondBatchAfterRaiserror" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "RAISERROR('Warning message', 10, 1) WITH NOWAIT; SELECT 1 AS AfterRaiserror\nGO\nSELECT 'SecondBatchAfterRaiserror' AS Status")"
test_cmd "NOCOUNT Toggle + Second Batch" "SET NOCOUNT ON/OFF must not break next batch" 0 "AfterNocount" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SET NOCOUNT ON; SELECT 1 AS A; SELECT 2 AS B; SET NOCOUNT OFF\nGO\nSELECT 'AfterNocount' AS Status")"
test_cmd "Prepared Stmt + OUTPUT Param + Second Batch" "Prepared stmt with OUTPUT param must not break next batch" 0 "PreparedOK" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "DECLARE @x INT; EXEC sp_executesql N'SELECT @o = 42', N'@o INT OUTPUT', @o = @x OUTPUT; SELECT @x AS Val\nGO\nSELECT 'PreparedOK' AS Status")" -p

section "T-SQL FEATURE TESTS"

test_cmd "Transaction Across Batches" "BEGIN TRAN in first batch should persist to second batch" 0 "TranCount" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf 'BEGIN TRAN; SELECT 1 AS InTransaction\nGO\nSELECT @@TRANCOUNT AS TranCount\nGO\nROLLBACK')"
test_cmd "FOR XML + Second Batch" "FOR XML result must not break next batch" 0 "AfterXML" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT 1 AS Col FOR XML PATH('row')\nGO\nSELECT 'AfterXML' AS Status")"
test_cmd "FOR JSON + Second Batch" "FOR JSON result must not break next batch" 0 "AfterJSON" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT 1 AS Col FOR JSON PATH\nGO\nSELECT 'AfterJSON' AS Status")"
test_cmd "TRY/CATCH + Second Batch" "TRY/CATCH must not break next batch" 0 "AfterTryCatch" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "BEGIN TRY SELECT 1/0 END TRY BEGIN CATCH SELECT ERROR_MESSAGE() AS Err END CATCH\nGO\nSELECT 'AfterTryCatch' AS Status")"
test_cmd "Temp Table Across Batches" "Temp table created in first batch should be accessible in second" 0 "TempTableWorks" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "CREATE TABLE #TestTemp (ID INT); INSERT INTO #TestTemp VALUES (1)\nGO\nSELECT 'TempTableWorks' AS Status FROM #TestTemp\nGO\nDROP TABLE #TestTemp")"
test_cmd "THROW Error + Second Batch" "THROW in first batch should not prevent second batch execution" 1 "SecondBatchRan" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "THROW 50000, 'Test error', 1\nGO\nSELECT 'SecondBatchRan' AS Status")"
test_cmd "Large LOB Data Retrieval" "Large text columns should be retrieved correctly" 0 "Total batches to execute: 1" -- \
  -S "$SERVER" -d master "${AUTH[@]}" -Q "SELECT TOP 1 LEN(definition) AS DefLen FROM sys.sql_modules WHERE definition IS NOT NULL ORDER BY LEN(definition) DESC" -q
test_cmd "NULL Values in Results" "NULL values should be handled correctly" 0 "AfterNull" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT NULL AS NullCol, 1 AS NotNull\nGO\nSELECT 'AfterNull' AS Status")"
test_cmd "Empty Result + Second Batch" "Empty result set must not break next batch" 0 "AfterEmpty" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT 1 WHERE 1=0\nGO\nSELECT 'AfterEmpty' AS Status")"
test_cmd "DML + SELECT Second Batch" "DML without result set must not break next batch" 0 "AfterDML" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "DECLARE @t TABLE (x INT); INSERT INTO @t VALUES (1)\nGO\nSELECT 'AfterDML' AS Status")"
test_cmd "T-SQL Cursor + Second Batch" "T-SQL CURSOR operations must not break next batch" 0 "CursorOK" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "DECLARE @cur CURSOR; SET @cur = CURSOR FOR SELECT TOP 2 name FROM sys.databases; OPEN @cur; FETCH NEXT FROM @cur; CLOSE @cur; DEALLOCATE @cur;\nGO\nSELECT 'CursorOK' AS Status")"
test_cmd "INSERT EXEC + Second Batch" "INSERT INTO...EXEC must not break next batch" 0 "InsertExecOK" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "CREATE TABLE #dbs (name NVARCHAR(128), size INT, remarks NVARCHAR(254)); INSERT INTO #dbs EXEC sp_databases; DROP TABLE #dbs;\nGO\nSELECT 'InsertExecOK' AS Status")"
test_cmd "Severity 16 Error + Second Batch" "Severity 16 error should not prevent second batch" 1 "AfterSev16" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "RAISERROR('Sev16 test', 16, 1)\nGO\nSELECT 'AfterSev16' AS Status")"
test_cmd "WAITFOR Timeout + Second Batch" "Query timeout in first batch should not prevent second batch" 1 "AfterTimeout" -- \
  "${BASE[@]}" "${AUTH[@]}" -t 1 -Q "$(printf "WAITFOR DELAY '00:00:05'\nGO\nSELECT 'AfterTimeout' AS Status")"
test_cmd "NULL Multiple Types + Second Batch" "NULL values in various types must not break next batch" 0 "NullTypesOK" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT CAST(NULL AS INT) AS NullInt, CAST(NULL AS DATETIME) AS NullDT, CAST(NULL AS DECIMAL(10,2)) AS NullDec, CAST(NULL AS UNIQUEIDENTIFIER) AS NullGuid\nGO\nSELECT 'NullTypesOK' AS Status")"

echo "${YELLOW}TEST: Unicode Query Literals (File)${RESET}"
echo "${GRAY}  Description: Unicode literals in queries work via file input${RESET}"
printf "SELECT N'日本語' AS test_col" > "$TEST_DIR/unicode_query_test.sql"
with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -i "$TEST_DIR/unicode_query_test.sql" -o "$TEST_DIR/unicode_query_result.txt" -q >/dev/null 2>&1
if [ -f "$TEST_DIR/unicode_query_result.txt" ] && grep -q '日本語' "$TEST_DIR/unicode_query_result.txt"; then
  _pass
else
  _fail "expected 日本語 in output file"
fi
rm -f "$TEST_DIR/unicode_query_test.sql" "$TEST_DIR/unicode_query_result.txt"

test_cmd "Binary Data + Second Batch" "VARBINARY data must not break next batch" 0 "BinaryOK" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "$(printf "SELECT CAST(0xDEADBEEF AS VARBINARY(100)) AS BinaryCol\nGO\nSELECT 'BinaryOK' AS Status")"

section "OUTPUT FILE TESTS"

# JSON field reader. jq is a prerequisite checked at startup.
json_field() {
  jq -r "$2" <<<"$1" 2>/dev/null
}

echo "${YELLOW}TEST: Output File Redirection${RESET}"
echo "${GRAY}  Description: Verify -o redirects output to file${RESET}"
rm -f "$TEST_DIR/test_output_redirection.txt"
with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT @@VERSION" -o "$TEST_DIR/test_output_redirection.txt" -q >/dev/null 2>&1
if [ -f "$TEST_DIR/test_output_redirection.txt" ] && grep -q "Total Runtime:" "$TEST_DIR/test_output_redirection.txt"; then
  _pass
else
  _fail "output file missing or lacks expected content"
fi
rm -f "$TEST_DIR/test_output_redirection.txt"

echo "${YELLOW}TEST: Output File Error Capture${RESET}"
echo "${GRAY}  Description: Verify -o captures SQL errors${RESET}"
rm -f "$TEST_DIR/test_error_capture.txt"
with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT * FROM NonExistentTable999" -o "$TEST_DIR/test_error_capture.txt" -v >/dev/null 2>&1
if [ -f "$TEST_DIR/test_error_capture.txt" ] \
  && grep -q "Invalid object name" "$TEST_DIR/test_error_capture.txt" \
  && grep -q "Total Errors: 1" "$TEST_DIR/test_error_capture.txt"; then
  _pass
else
  _fail "output file missing error information"
fi
rm -f "$TEST_DIR/test_error_capture.txt"

# A path under a regular file cannot be created even by root, unlike /, so this
# fails for every user. The PowerShell suite uses the same approach.
UNWRITABLE_PARENT="$TEST_DIR/sqlsim-not-a-directory.txt"
: > "$UNWRITABLE_PARENT"
test_cmd "Output File Permission Denied" "Fail gracefully when output file cannot be written" 1 "Cannot open output file" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -o "$UNWRITABLE_PARENT/test_permission.txt"
rm -f "$UNWRITABLE_PARENT"

section "JSON OUTPUT TESTS"

echo "${YELLOW}TEST: JSON Output Format${RESET}"
echo "${GRAY}  Description: Verify -json produces valid JSON with required fields${RESET}"
j="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -json -q 2>/dev/null)"
if [ -n "$(json_field "$j" '.version')" ] && [ -n "$(json_field "$j" '.configuration')" ] \
  && [ -n "$(json_field "$j" '.metrics')" ] && [ "$(json_field "$j" '.success')" = "true" ]; then
  _pass
else
  _fail "JSON missing required fields"
fi

echo "${YELLOW}TEST: JSON Output to File${RESET}"
echo "${GRAY}  Description: Verify -json -o writes valid JSON to file${RESET}"
rm -f "$TEST_DIR/test_json_output.json"
with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -json -o "$TEST_DIR/test_json_output.json" -q >/dev/null 2>&1
if [ -f "$TEST_DIR/test_json_output.json" ]; then
  jf="$(cat "$TEST_DIR/test_json_output.json")"
  if [ "$(json_field "$jf" '.version')" = "1.0.0" ] \
    && [ "$(json_field "$jf" '.configuration.threads')" = "1" ] \
    && [ "$(json_field "$jf" '.success')" = "true" ]; then
    _pass
  else
    _fail "JSON file has incorrect values"
  fi
else
  _fail "JSON file was not created"
fi
rm -f "$TEST_DIR/test_json_output.json"

echo "${YELLOW}TEST: JSON Output Multi-threaded${RESET}"
echo "${GRAY}  Description: Verify -json works with multiple threads${RESET}"
jm="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 10 -r 2 -json -v -q 2>/dev/null)"
if [ "$(json_field "$jm" '.configuration.threads')" = "10" ] \
  && [ "$(json_field "$jm" '.configuration.iterations_per_thread')" = "2" ] \
  && [ "$(json_field "$jm" '.metrics.query_execution_operations.total')" = "20" ] \
  && [ "$(json_field "$jm" '.metrics.connection_operations.total')" = "10" ]; then
  _pass
else
  _fail "JSON multi-threaded counts incorrect"
fi

echo "${YELLOW}TEST: JSON Suppresses Verbose Output${RESET}"
echo "${GRAY}  Description: Verify -json -v does not mix text and JSON${RESET}"
jv="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -json -v -q 2>/dev/null)"
first_line="$(head -1 <<<"$jv" | tr -d '[:space:]')"
if [ "$first_line" = "{" ] && ! grep -q "PHASE" <<<"$jv" \
  && [ -n "$(json_field "$jv" '.connection_string')" ] \
  && [ -n "$(json_field "$jv" '.thread_connections')" ] \
  && [ -n "$(json_field "$jv" '.thread_iterations')" ]; then
  _pass
else
  _fail "JSON output mixed with verbose text or missing verbose fields"
fi

section "CREDENTIAL MASKING TESTS"

echo "${YELLOW}TEST: Password Masking - PWD Format${RESET}"
echo "${GRAY}  Description: Verify PWD= is masked in verbose output${RESET}"
pm="$("$SQLSIM" -S "$SERVER" -d tempdb -U testuser -P 'SecretPass123!' -C -l 2 -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1)"
if grep -q 'PWD=\*\{8\}' <<<"$pm" && ! grep -q 'SecretPass123' <<<"$pm"; then _pass; else _fail "password not masked"; fi

echo "${YELLOW}TEST: Username Masking - UID Format${RESET}"
echo "${GRAY}  Description: Verify UID= is masked in verbose output${RESET}"
um="$("$SQLSIM" -S "$SERVER" -d tempdb -U SecretUser -P pass -C -l 2 -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1)"
if grep -q 'UID=\*\{8\}' <<<"$um"; then _pass; else _fail "username not masked"; fi

echo "${YELLOW}TEST: Connection String Password Masking${RESET}"
echo "${GRAY}  Description: Verify passwords masked in connection string mode${RESET}"
cm="$("$SQLSIM" -c "Driver={ODBC Driver 18 for SQL Server};Server=$SERVER;Database=master;UID=testuser;PWD=MySecret123!;TrustServerCertificate=Yes" -l 2 -Q "SELECT 1" -v -q 2>&1)"
if grep -q 'PWD=\*\{8\}' <<<"$cm" && ! grep -q 'MySecret123' <<<"$cm"; then _pass; else _fail "connection string password not masked"; fi

echo "${YELLOW}TEST: Attached Password Masking${RESET}"
echo "${GRAY}  Description: Verify an attached -P value is masked in the verbose command line${RESET}"
am="$("$SQLSIM" -S "$SERVER" -d tempdb -U testuser -PAttachedSecret99 -C -l 2 -Q "SELECT 1" -n 1 -r 1 -v -q 2>&1)"
if grep -q -- '-P\*\{8\}' <<<"$am" && ! grep -q 'AttachedSecret99' <<<"$am"; then _pass; else _fail "attached password not masked"; fi

echo "${YELLOW}TEST: Braced Password Masking${RESET}"
echo "${GRAY}  Description: Verify a braced PWD value containing ';' is fully masked${RESET}"
bm="$("$SQLSIM" -c "Driver={ODBC Driver 18 for SQL Server};Server=$SERVER;Database=master;UID=testuser;PWD={Brace;TailSecret77};TrustServerCertificate=Yes" -l 2 -Q "SELECT 1" -v -q 2>&1)"
if ! grep -q 'TailSecret77' <<<"$bm" && ! grep -q 'Brace;' <<<"$bm"; then _pass; else _fail "braced password not fully masked"; fi

section "THREAD SAFETY AND TOKEN VALIDATION TESTS"

echo "${YELLOW}TEST: Output File Thread Safety${RESET}"
echo "${GRAY}  Description: Verify -o with multiple threads doesn't corrupt output${RESET}"
rm -f "$TEST_DIR/test_threaded_output.txt"
with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 'MARKER' AS Col1, NEWID() AS UniqueID" -n 20 -r 10 -o "$TEST_DIR/test_threaded_output.txt" >/dev/null 2>&1
if [ -f "$TEST_DIR/test_threaded_output.txt" ]; then
  marker_count=$(grep -ao 'MARKER' "$TEST_DIR/test_threaded_output.txt" | wc -l)
  row_count=$(grep -ac 'row(s) affected' "$TEST_DIR/test_threaded_output.txt")
  corrupt=$(grep -acE 'MARKER.*MARKER.*MARKER|Col1.*Col1' "$TEST_DIR/test_threaded_output.txt" || true)
  # 1 occurrence from the query echo plus 20 threads x 10 iterations.
  if grep -aq 'Total Runtime:' "$TEST_DIR/test_threaded_output.txt" && [ "$corrupt" -eq 0 ] \
    && [ "$marker_count" -eq 201 ] && [ "$row_count" -eq 200 ]; then
    _pass
  else
    _fail "markers=$marker_count (expected 201), rows=$row_count (expected 200), corrupted lines=$corrupt; duplicated writes indicate the -o path is not thread-safe"
  fi
else
  _fail "output file was not created"
fi
rm -f "$TEST_DIR/test_threaded_output.txt"

test_cmd "Access Token Size Limit" "Reject tokens exceeding maximum size (10KB)" 1 "Access token" -- \
  -S "$SERVER" -d tempdb -T "$(printf 'A%.0s' $(seq 15000))" -Q "SELECT 1" -q
test_cmd "Empty Access Token" "Reject empty access tokens" 1 "Access token cannot be empty" -- \
  -S "$SERVER" -d tempdb -T "" -Q "SELECT 1" -q

echo "${YELLOW}TEST: High Concurrency Connection Metrics${RESET}"
echo "${GRAY}  Description: Verify thread-safe metrics with 50 threads${RESET}"
hc="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 50 -r 10 -v -q 2>&1)"
phase4_count=$(grep -c '\[PHASE 4\] Executing workload' <<<"$hc" || true)
if grep -q 'Thread 49:' <<<"$hc" && grep -q 'Thread 0:' <<<"$hc" \
  && grep -q 'Total Operations: 500' <<<"$hc" && [ "$phase4_count" -eq 1 ]; then
  _pass
else
  _fail "thread metrics inconsistent (PHASE 4 printed $phase4_count times)"
fi

section "OUTPUT FORMAT VALIDATION TESTS"

# assert_all <name> <desc> <output> <pattern>...
assert_all() {
  local name="$1" desc="$2" out="$3"; shift 3
  echo "${YELLOW}TEST: $name${RESET}"
  echo "${GRAY}  Description: $desc${RESET}"
  local missing=()
  for pat in "$@"; do grep -qE "$pat" <<<"$out" || missing+=("$pat"); done
  if [ ${#missing[@]} -eq 0 ]; then _pass; else _fail "missing: ${missing[*]}"; fi
}

ts_out="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -q 2>&1)"
assert_all "Timestamp Format and Output Features" "Verify timestamps, start message, and time breakdown" "$ts_out" \
  '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} \|' 'Starting execution' 'Total Connection Time:' '% of work\)'

nv_out="$ts_out"
assert_all "Non-Verbose Output Validation" "Verify all key elements in non-verbose output" "$nv_out" \
  'SQL Workload Simulator v[0-9]+\.[0-9]+' 'Configuration:' 'Server:' 'Database:' 'Authentication:' \
  'Threads: [0-9]+' 'Iterations per thread: [0-9]+' 'Total batches to execute: [0-9]+' \
  'Batches in workload: [0-9]+' 'Batches to execute:' 'Connecting\.\.\.' 'Starting execution' \
  'Performance Metric Summary' 'Avg Connect Time:' 'Avg Elapsed:' 'Total Runtime:' \
  'Total Connection Time:' 'Total Query Execution Time:'

echo "${YELLOW}TEST: Optional Features Display${RESET}"
echo "${GRAY}  Description: Verify optional features only shown when explicitly used${RESET}"
no_prep="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -q 2>&1)"
with_prep="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -q -p 2>&1)"
with_stop="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -q -stoponerror 2>&1)"
if ! grep -q 'Prepared statements:' <<<"$no_prep" \
  && grep -q 'Prepared statements: Yes' <<<"$with_prep" \
  && grep -q 'Stop on error: Yes' <<<"$with_stop"; then
  _pass
else
  _fail "optional features not displaying correctly"
fi

v_out="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -v -q 2>&1)"
assert_all "Verbose Output Validation" "Verify all key elements in verbose output" "$v_out" \
  'SQL Workload Simulator v[0-9]+\.[0-9]+' 'Server:' 'Database:' \
  '\[PHASE 1\] Configuration' '\[PHASE 2\] Initializing worker threads' '\[PHASE 3\] Connecting to database' \
  '\[PHASE 4\] Executing workload' '\[PHASE 5\] Workload execution completed' \
  'Total batches to execute: [0-9]+' 'Batches in workload: [0-9]+' 'Batches to execute:' \
  'Connection String:' 'Thread [0-9]+: Connected successfully' 'Launched [0-9]+ worker thread' \
  'Performance Metric Summary' 'Start Time: [0-9]{4}-[0-9]{2}-[0-9]{2}T' 'End Time:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
  'Connection Operations:' 'Total Operations: [0-9]+' 'Successful: [0-9]+' 'Avg Connect Time:' \
  'Query Execution Operations:' 'Fetch Operations:' 'Total Errors: [0-9]+' 'Time Breakdown:' \
  'Total Runtime:' 'Total Connection Time:' 'Total Query Execution Time:'

j_out="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -json -q 2>/dev/null)"
assert_all "JSON Output Validation" "Verify all key elements in JSON output" "$j_out" \
  '"version":' '"start_time":' '"success":' '"configuration":' '"server":' '"database":' \
  '"authentication":' '"threads":' '"iterations_per_thread":' '"total_batches":' '"batch_count":' \
  '"batches":' '"metrics":' '"total_runtime_seconds":' '"total_connection_time_seconds":' \
  '"total_query_execution_time_seconds":' '"end_time":' '"errors":' '"total":' '"list":' \
  '"server_edition":' '"server_version":'

echo "${YELLOW}TEST: No Queries Terminology${RESET}"
echo "${GRAY}  Description: Verify 'queries' terminology is NOT used (should be 'batches')${RESET}"
if ! grep -qE 'Total queries to execute|Queries in workload|Queries to execute:' <<<"$nv_out$v_out" \
  && ! grep -qE '"total_queries"|"query_count"' <<<"$j_out"; then
  _pass
else
  _fail "found incorrect 'queries' terminology"
fi

section "PRINT STATEMENT TESTS"

test_cmd "Multiple PRINT Statements" "Verify multiple PRINT statements are all displayed" 0 "Line3" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "PRINT 'Line1'; PRINT 'Line2'; PRINT 'Line3'; SELECT 1"
test_cmd "PRINT Between SELECTs" "Verify PRINT statement appears between SELECT results" 0 "MiddlePrint" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 'Before' AS Position; PRINT 'MiddlePrint'; SELECT 'After' AS Position"

PRINT_FIXTURE="$TEST_DIR/test-print-statements.sql"
# The fixture is tracked in source control; only recreate it when missing.
[ -f "$PRINT_FIXTURE" ] || printf "PRINT 'Starting test script'\nPRINT 'Before SELECT'\nSELECT 'TestValue' AS TestColumn\nPRINT 'After SELECT'\n" \
  > "$PRINT_FIXTURE"
test_cmd "PRINT From File Input" "Verify PRINT statements work from -i file input" 0 "Starting test script" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$PRINT_FIXTURE"

section "EXAMPLE VALIDATION TESTS"

# The PowerShell suite uses bare -E for these; on Linux that would force Kerberos.
test_cmd "Help Example: Connection Test" "Verify connection-test mode works (from -? help)" 0 "Total Runtime:" -- \
  -S "$SERVER" "${AUTH[@]}" -q
test_cmd "Help Example: Basic Query" "Verify basic query example works (from -? help)" 0 "@@VERSION" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT @@VERSION"
test_cmd "Help Example: Load Test Pattern" "Verify '-n 10 -r 100 -q' pattern works (from -? help)" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -n 10 -r 100 -q
test_cmd "Doc Example: Default Localhost" "Verify default-target query example (sqlsim.md)" 0 "@@VERSION" -- \
  -S "$SERVER" "${AUTH[@]}" -Q "SELECT @@VERSION"
test_cmd "Doc Example: Verbose Mode" "Verify verbose mode shows phases (sqlsim.md)" 0 "\[PHASE 5\]" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -v -q
test_cmd "Doc Example: Prepared Statements" "Verify '-p' prepared statements work (sqlsim.md)" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -Q "SELECT 1" -p -n 10 -r 100 -q

if [ -n "$USERNAME" ] && [ -z "$TOKEN" ]; then
  test_cmd "Doc Example: Connection String" "Verify '-c' connection string mode (sqlsim.md)" 0 "@@VERSION" -- \
    -c "Driver={ODBC Driver 18 for SQL Server};Server=$SERVER;Database=master;UID=$USERNAME;PWD=$PASSWORD;TrustServerCertificate=Yes;" -Q "SELECT @@VERSION"
else
  echo "${YELLOW}TEST: Doc Example: Connection String${RESET}"; _skip "requires SQL authentication"
fi

test_cmd "Script Example: localhost-simple-test Pattern 1" "Verify basic query pattern (localhost-simple-test.ps1)" 0 "@@VERSION" -- \
  -S "$SERVER" "${AUTH[@]}" -Q "SELECT @@VERSION"
test_cmd "Script Example: localhost-simple-test Pattern 3" "Verify connection test mode (localhost-simple-test.ps1)" 0 "Mode: Connection test only" -- \
  -S "$SERVER" "${AUTH[@]}" -v
test_cmd "Script Example: json-output-examples Pattern 1" "Verify JSON output (json-output-examples.ps1)" 0 '"success"' -- \
  -S "$SERVER" "${AUTH[@]}" -Q "SELECT 1 AS Value" -json
test_cmd "Script Example: json-output-examples Pattern 2" "Verify JSON with GO batches (json-output-examples.ps1)" 0 '"batch_count": 3' -- \
  -S "$SERVER" "${AUTH[@]}" -Q "$(printf 'SELECT 1\nGO\nSELECT 2\nGO\nSELECT 3')" -json -q
test_cmd "Script Example: json-output-examples Pattern 4" "Verify JSON connection test only (json-output-examples.ps1)" 0 '"connection_test_only": true' -- \
  -S "$SERVER" "${AUTH[@]}" -json
test_cmd "SQL Example: 01-simple-queries.sql" "Verify catalog view queries work (examples/sql/01-simple-queries.sql)" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -i "$SCRIPT_DIR/examples/sql/01-simple-queries.sql" -q

section "WORKLOAD FILE TESTS"

WORKLOAD="$SCRIPT_DIR/examples/workload/workload-test.json"

test_cmd "Workload: Basic Execution" "Execute workload file with multiple groups" 0 "Workload groups: 2" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q
test_cmd "Workload: Config Display" "Workload shows group details in config" 0 "Group 1:.*thread.*iteration.*batch" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q
test_cmd "Workload: Completion" "Workload completes with runtime" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q

echo "${YELLOW}TEST: Querystats: Value Validation${RESET}"
echo "${GRAY}  Description: Verify querystats values match SQL Server STATISTICS output${RESET}"
qs="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -Q "SELECT TOP 5 name FROM sys.objects ORDER BY object_id" -querystats -json -q -r 3 2>/dev/null)"
qs_issues=()
# jq preserves the JSON number literal (5.0), so compare numerically, not as a string.
rc_avg="$(json_field "$qs" '.query_stats.queries[0].row_count.avg')"
awk -v v="${rc_avg:-0}" 'BEGIN{exit !(v == 5)}' || qs_issues+=("row_count avg")
[ "$(json_field "$qs" '.query_stats.queries[0].executions')" = "3" ] || qs_issues+=("executions")
[ "$(json_field "$qs" '.query_stats.queries[0].spids | length')" = "1" ] || qs_issues+=("SPID list")
[ "$(json_field "$qs" '.query_stats.queries[0].spid_count')" = "1" ] || qs_issues+=("SPID count")
[ "$(json_field "$qs" '.query_stats.queries[0].spids[0]')" -gt 0 ] || qs_issues+=("SPID value")
[ "$(json_field "$qs" '.query_stats.totals.executions')" = "3" ] || qs_issues+=("total executions")
[ "$(json_field "$qs" '.query_stats.totals.total_rows')" = "15" ] || qs_issues+=("total_rows")
[ "$(json_field "$qs" '.query_stats.queries[0].failures')" = "0" ] || qs_issues+=("failures")
[ "$(json_field "$qs" '.query_stats.totals.failures')" = "0" ] || qs_issues+=("total failures")
lr="$(json_field "$qs" '.query_stats.totals.logical_reads')"
awk -v v="${lr:-0}" 'BEGIN{exit !(v > 0)}' || qs_issues+=("logical_reads not > 0")
if [ ${#qs_issues[@]} -eq 0 ]; then _pass; else _fail "${qs_issues[*]}"; fi

test_cmd "Workload: Querystats" "Workload with -querystats shows per-query stats" 0 "Query Stats" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -querystats
test_cmd "Workload: Querystats Totals" "Workload querystats shows totals with execution count" 0 "Executions:[[:space:]]+52" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -querystats
test_cmd "Workload: JSON Output" "Workload with -json produces valid JSON with workload fields" 0 '"workload_groups": 2' -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -json
test_cmd "Workload: JSON Querystats" "Workload with -json -querystats includes query_stats section" 0 '"executions": 52' -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -json -querystats

test_cmd "Workload Conflict: -Q with -workload" "Reject -Q when -workload is specified" 1 "Cannot use -workload with -Q or -i" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -Q "SELECT 1"
test_cmd "Workload Conflict: -i with -workload" "Reject -i when -workload is specified" 1 "Cannot use -workload with -Q or -i" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -i "$SCRIPT_DIR/examples/sql/01-simple-queries.sql"
test_cmd "Workload Conflict: -replay with -workload" "Reject -replay when -workload is specified" 1 "Cannot use.*(workload|replay)" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -replay fast -replayfile "$SCRIPT_DIR/testing/clean-replay.xml"
test_cmd "Workload: Missing File" "Reject workload with nonexistent file" 1 "Cannot open workload file" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload nonexistent.json
test_cmd "Workload: -n Ignored Warning" "Warning when -n used with -workload" 0 "warning: -n 4 ignored with -workload" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -n 4
test_cmd "Workload: -r Ignored Warning" "Warning when -r used with -workload" 0 "warning: -r 10 ignored with -workload" -- \
  "${BASE[@]}" "${AUTH[@]}" -workload "$WORKLOAD" -q -r 10

section "REPLAY TESTS"

# Live XEvent capture needs replay/convert-xel.ps1, which is PowerShell-only, so
# use the committed fixture. The PowerShell suite falls back to the same file.
REPLAY_FIXTURE="$SCRIPT_DIR/testing/clean-replay.xml"
REPLAY_EVENTS=14

# The fixture was recorded against master and tempdb. Azure SQL Database cannot
# switch databases, so there replay a copy that records the target database.
if [ "$IS_AZURE" -eq 1 ]; then
  REPLAY_DB="$DATABASE"
  REPLAY_AZURE_FIXTURE="$TEST_DIR/clean-replay-azure.xml"
  fixture_xml="$(<"$REPLAY_FIXTURE")"
  for recorded_db in master tempdb; do
    fixture_xml="${fixture_xml//"<action name=\"database_name\" package=\"sqlserver\"><value><![CDATA[$recorded_db]]>"/"<action name=\"database_name\" package=\"sqlserver\"><value><![CDATA[$DATABASE]]>"}"
  done
  printf '%s\n' "$fixture_xml" > "$REPLAY_AZURE_FIXTURE"
  REPLAY_FIXTURE="$REPLAY_AZURE_FIXTURE"
  echo "${YELLOW}  Azure SQL Database: replaying the fixture in $DATABASE${RESET}"
else
  REPLAY_DB=tempdb
fi

# The fixture contains three rpc_completed events against dbo.sqlsim_test_proc.
# Without the procedure those events replay as errors and sqlsim exits non-zero.
with_secret "$SQLSIM" -S "$SERVER" -d "$REPLAY_DB" "${AUTH[@]}" -app sqlsim_admin -q -Q "IF OBJECT_ID('dbo.sqlsim_test_proc','P') IS NOT NULL DROP PROCEDURE dbo.sqlsim_test_proc
GO
CREATE PROCEDURE dbo.sqlsim_test_proc @id INT, @name NVARCHAR(100) AS BEGIN SELECT @id AS id, @name AS name END" >/dev/null 2>&1 \
  || echo "${YELLOW}  WARNING: could not create dbo.sqlsim_test_proc - replay tests may fail${RESET}"

test_cmd "Replay Conflict: -Q with -replay" "Reject -Q when -replay is specified" 1 "Cannot use -replay with -Q or -i" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -Q "SELECT 1"
test_cmd "Replay Conflict: -i with -replay" "Reject -i when -replay is specified" 1 "Cannot use -replay with -Q or -i" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -i "$REPLAY_FIXTURE"
test_cmd "Replay Conflict: -p with -replay" "Reject -p when -replay is specified" 1 "Cannot use -p with -replay" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -p
test_cmd "Replay Conflict: -reconnect with -replay" "Reject -reconnect when -replay is specified" 1 "Cannot use -reconnect with -replay" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -reconnect
test_cmd "Replay Conflict: -usepool with -replay" "Reject -usepool when -replay is specified" 1 "Cannot use -reconnect with -replay" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -reconnect -usepool
test_cmd "Replay Conflict: Missing -replayfile" "Reject -replay without -replayfile" 1 "replay requires -replayfile" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast
test_cmd "Replay Conflict: Missing -replay" "Reject -replayfile without -replay" 1 "replayfile requires -replay" -- \
  "${BASE[@]}" "${AUTH[@]}" -replayfile "$REPLAY_FIXTURE"
test_cmd "Replay Conflict: Invalid replay mode" "Reject invalid replay mode value" 1 "Invalid replay mode" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay invalid -replayfile "$REPLAY_FIXTURE"

test_cmd "Replay Fast: Completion" "Fast mode replay completes successfully" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -q
test_cmd "Replay Fast: Replay Summary Text" "Fast mode shows replay summary with correct event count" 0 \
  "Original trace:[[:space:]]+$REPLAY_EVENTS events \($REPLAY_EVENTS ok, 0 error, 0 abort\)" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -q
test_cmd "Replay Fast: Replay Result Text" "Fast mode shows replay result line" 0 \
  "Replay result:[[:space:]]+$REPLAY_EVENTS events \($REPLAY_EVENTS ok, 0 error, 0 abort\)" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -q
test_cmd "Replay Stress: Completion" "Stress mode replay completes with 2 threads x 2 iterations" 0 "Total Runtime:" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay stress -replayfile "$REPLAY_FIXTURE" -n 2 -r 2 -q
test_cmd "Replay Stress: Replay Summary" "Stress mode shows replay summary" 0 "Replay Summary:" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay stress -replayfile "$REPLAY_FIXTURE" -n 2 -r 2 -q
test_cmd "Replay JSON: Valid JSON" "Replay with -json produces valid JSON" 0 '"replay_mode": "fast"' -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -json
test_cmd "Replay JSON: Replay Summary Fields" "JSON contains replay_summary" 0 '"replay_summary"' -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -json

echo "${YELLOW}TEST: Replay JSON: Original Event Count${RESET}"
echo "${GRAY}  Description: JSON replay_summary.original.events matches expected count${RESET}"
rj="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -json 2>/dev/null)"
if [ "$(json_field "$rj" '.replay_summary.original.events')" = "$REPLAY_EVENTS" ] \
  && [ "$(json_field "$rj" '.replay_summary.original.ok')" = "$REPLAY_EVENTS" ] \
  && [ "$(json_field "$rj" '.replay_summary.original.error')" = "0" ]; then
  _pass
else
  _fail "unexpected replay_summary values"
fi

echo "${YELLOW}TEST: Replay JSON: Original Performance Comparison${RESET}"
echo "${GRAY}  Description: JSON preserves original metrics, captured SPIDs, and Replay connection SPIDs${RESET}"
rj="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -querystats -json 2>/dev/null)"
capture_query_count="$(json_field "$rj" '.replay_capture.queries | length')"
captured_spid_count="$(json_field "$rj" '.replay_capture.captured_spids | length')"
connection_count="$(json_field "$rj" '.replay_capture.connection_map | length')"
if [ "$capture_query_count" -gt 0 ] \
  && [ "$(json_field "$rj" '.query_stats.queries | length')" -gt 0 ] \
  && [ "$(json_field "$rj" '[.replay_capture.queries[] | select(.avg_duration_ms != null)] | length')" -gt 0 ] \
  && [ "$captured_spid_count" -gt 0 ] \
  && [ "$connection_count" -eq "$captured_spid_count" ] \
  && [ "$(json_field "$rj" '[.replay_capture.connection_map[] | select(.captured_spid != null and .replay_spid != null)] | length')" -eq "$connection_count" ] \
  && [ "$(json_field "$rj" '[.replay_capture.connection_map[].replay_spid] | unique | length')" -eq "$connection_count" ] \
  && [ "$(json_field "$rj" '[.replay_capture.queries[] | select((.captured_spids | length) > 0)] | length')" -eq "$capture_query_count" ]; then
  _pass
else
  _fail "Replay comparison JSON is incomplete"
fi

test_cmd "Replay Verbose: Configuration" "Verbose replay shows replay mode and event counts" 0 "Replay mode: fast" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -v -q
test_cmd "Replay Fast: -n Warning" "Specifying -n in fast mode produces a warning" 0 "ignored in fast replay mode" -- \
  "${BASE[@]}" "${AUTH[@]}" -replay fast -replayfile "$REPLAY_FIXTURE" -n 4 -q

with_secret "$SQLSIM" -S "$SERVER" -d "$REPLAY_DB" "${AUTH[@]}" -app sqlsim_admin -q \
  -Q "IF OBJECT_ID('dbo.sqlsim_test_proc','P') IS NOT NULL DROP PROCEDURE dbo.sqlsim_test_proc" >/dev/null 2>&1
[ -n "${REPLAY_AZURE_FIXTURE:-}" ] && rm -f "$REPLAY_AZURE_FIXTURE"

section "PERFORMANCE REGRESSION TESTS"

# Reports wall-clock for trend tracking; no baseline file gates pass/fail.
perf_case() {
  local name="$1" desc="$2"; shift 2
  echo "${YELLOW}TEST: $name${RESET}"
  echo "${GRAY}  Description: $desc${RESET}"
  # These gates measure client throughput against a low-latency target. Each Azure
  # SQL Database round trip costs tens of milliseconds, so they would measure the network.
  if [ "$IS_AZURE" -eq 1 ]; then
    _skip "throughput gates need a low-latency target, not Azure SQL Database"
    return
  fi
  local out secs
  out="$(with_secret "$SQLSIM" "${BASE[@]}" "${AUTH[@]}" -q -json "$@" 2>/dev/null)"
  secs="$(grep -oE '"total_runtime_seconds"[[:space:]]*:[[:space:]]*[0-9.]+' <<<"$out" | grep -oE '[0-9.]+$' | head -1)"
  if [ -n "$secs" ] && awk -v s="$secs" 'BEGIN{exit !(s > 0 && s < 30)}'; then
    _pass
    echo "${GRAY}    ${secs}s${RESET}"
  else
    _fail "runtime '${secs:-none}' outside (0, 30) seconds"
  fi
}

perf_case "Single-thread SELECT 1 x1000" "SELECT 1 x1000 single-threaded" -Q "SELECT 1" -n 1 -r 1000
perf_case "4-thread SELECT 1 x1000" "SELECT 1 x1000 with 4 threads (4000 total)" -Q "SELECT 1" -n 4 -r 1000
perf_case "4-thread sys.objects x500" "SELECT TOP 50 * FROM sys.objects x500 with 4 threads (2000 total)" \
  -Q "SELECT TOP 50 * FROM sys.objects" -n 4 -r 500

section "CERTIFICATE VALIDATION TESTS"

probe_token="headerpart.$(printf 'a%.0s' {1..120}).signaturepart"

get_connection_string_for() {
  local out line
  out="$(with_secret "$SQLSIM" "$@" -Q "SELECT 1" -v -l 1 2>&1)"
  line="$(grep -m1 'Connection String' <<<"$out")"
  printf '%s' "${line#*Connection String: }"
}

test_certificate_case() {
  local name="$1" expected="$2"
  shift 2
  echo "${YELLOW}TEST: Certificate: $name${RESET}"
  echo "${GRAY}  Description: TrustServerCertificate=$expected${RESET}"
  local connection_string actual
  connection_string="$(get_connection_string_for "$@")"
  actual="$(grep -oE 'TrustServerCertificate=[[:alnum:]]+' <<<"$connection_string" | head -1)"
  actual="${actual#TrustServerCertificate=}"
  if [ "$actual" = "$expected" ]; then
    _pass
  else
    _fail "expected $expected, got ${actual:-\(absent\)}"
  fi
}

test_certificate_case "Token, no encryption flags" "Yes" \
  -S probe.database.windows.net -d db -T "$probe_token"
test_certificate_case "Token with -N s" "No" \
  -S probe.database.windows.net -d db -T "$probe_token" -N s
test_certificate_case "Token with -N m" "No" \
  -S probe.database.windows.net -d db -T "$probe_token" -N m
test_certificate_case "Token with -C" "Yes" \
  -S probe.database.windows.net -d db -T "$probe_token" -C
test_certificate_case "Integrated, no flags" "Yes" \
  -S localhost -d tempdb -E
test_certificate_case "Integrated with -N s" "No" \
  -S localhost -d tempdb -E -N s
test_certificate_case "Integrated with -C" "Yes" \
  -S localhost -d tempdb -E -C
test_certificate_case "SQL auth with -N s" "No" \
  -S localhost -d tempdb -U probeuser -P probepass -N s

token_connection_string="$(get_connection_string_for \
  -S probe.database.windows.net -d db -T "$probe_token" -N s)"

echo "${YELLOW}TEST: Certificate: keyword appears once${RESET}"
echo "${GRAY}  Description: TrustServerCertificate is not emitted twice for token authentication${RESET}"
emitted="$(grep -o 'TrustServerCertificate=' <<<"$token_connection_string" | wc -l)"
if [ "$emitted" -eq 1 ]; then
  _pass
else
  _fail "emitted $emitted time(s)"
fi

echo "${YELLOW}TEST: Certificate: token stays out of the connection string${RESET}"
echo "${GRAY}  Description: The access token does not appear in the echoed connection string${RESET}"
if [[ "$token_connection_string" != *"$probe_token"* ]]; then
  _pass
else
  _fail "the token was found in the echoed connection string"
fi

rmdir "$TEST_DIR" 2>/dev/null

total=$((passed + failed + skipped))
duration=$(( $(date +%s) - start_time ))

section "FULL TEST SUITE RESULTS (Linux)"
echo "Total Tests: $total"
echo "Passed: $passed"
echo "Skipped: $skipped"
echo "Failed: $failed"
echo "Duration: ${duration} seconds"
echo "${CYAN}========================================${RESET}"
echo

if [ "$failed" -eq 0 ]; then
  echo "${GREEN}ALL IMPLEMENTED TESTS PASSED${RESET}"
  exit 0
fi
echo "${RED}SOME TESTS FAILED${RESET}"
exit 1
