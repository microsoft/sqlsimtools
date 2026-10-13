#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$script_dir/build/macos-arm64/sqlsim"
skip_build=false

if [[ "${1:-}" == "--skip-build" ]]; then
    skip_build=true
    shift
fi

if (($# > 0)); then
    echo "Usage: bash smoke-test-macos.sh [--skip-build]" >&2
    exit 2
fi

if [[ "$skip_build" == false ]]; then
    bash "$script_dir/build-macos.sh"
fi

if [[ ! -x "$binary" ]]; then
    echo "ERROR: macOS sqlsim binary not found at $binary" >&2
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

architecture_output="$(bash "$script_dir/testing/macOS/verify-macos-arm64.sh" "$binary")"
if [[ "$architecture_output" == *"Mach-O 64-bit executable arm64"* ]]; then
    echo "PASS: native ARM64 binary"
    ((passed += 1))
else
    echo "FAIL: native ARM64 binary" >&2
    echo "$architecture_output" >&2
    ((failed += 1))
fi

run_test "help" zero "Usage: sqlsim" -h
run_test "version" zero "sqlsim 1.0.0" --version
run_test "unknown option rejected" nonzero "Unknown option" --not-a-real-option
run_test "missing token rejected" nonzero "requires a value" -T
run_test "zero threads rejected" nonzero "Number of threads must be between 1 and 2147483647" -E -n 0
run_test "conflicting query sources rejected" nonzero "Cannot use -Q with -i" -E -Q "SELECT 1" -i query.sql
run_test "interactive Entra rejected" nonzero "ActiveDirectoryInteractive is not supported" -S localhost -A
run_test "interactive Entra connection string rejected" nonzero "ActiveDirectoryInteractive is not supported" -c "Driver={ODBC Driver 18 for SQL Server};Server=localhost;Authentication=ActiveDirectoryInteractive;"
run_test "service principal credentials required" nonzero "ActiveDirectoryServicePrincipal requires" -S localhost -A ActiveDirectoryServicePrincipal
run_test "managed identity rejects password" nonzero "ActiveDirectoryMsi does not accept -P" -S localhost -A ActiveDirectoryMsi -P invalid

stdin_secret="sqlsim-macos-stdin-password"
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

echo "macOS ARM64 smoke test: $passed passed, $failed failed."
if [[ $failed -ne 0 ]]; then
    exit 1
fi
