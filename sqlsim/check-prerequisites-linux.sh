#!/usr/bin/env bash

set -euo pipefail

require_driver=false
if [[ "${1:-}" == "--require-driver" ]]; then
    require_driver=true
elif (($# > 0)); then
    echo "Usage: bash check-prerequisites-linux.sh [--require-driver]" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    echo "ERROR: sqlsim currently supports Linux x64 only." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: Cannot identify the Linux distribution." >&2
    exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || ("${VERSION_ID:-}" != "24.04" && "${VERSION_ID:-}" != "26.04") ]]; then
    echo "ERROR: sqlsim currently supports Ubuntu 24.04 and 26.04 LTS only." >&2
    echo "Detected: ${PRETTY_NAME:-unknown distribution}" >&2
    exit 1
fi

missing=()
for command_name in cmake c++ nproc; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing+=("$command_name")
    fi
done

if ((${#missing[@]} > 0)) || [[ ! -f /usr/include/sql.h ]]; then
    echo "ERROR: Ubuntu build prerequisites are missing." >&2
    if ((${#missing[@]} > 0)); then
        echo "Missing commands: ${missing[*]}" >&2
    fi
    if [[ ! -f /usr/include/sql.h ]]; then
        echo "Missing header: /usr/include/sql.h" >&2
    fi
    echo "Install them with: apt-get update && apt-get install -y build-essential cmake unixodbc-dev" >&2
    exit 1
fi

if [[ "$require_driver" == true ]]; then
    if ! command -v odbcinst >/dev/null 2>&1 || ! odbcinst -q -d -n "ODBC Driver 18 for SQL Server" >/dev/null 2>&1; then
        echo "ERROR: Microsoft ODBC Driver 18 for SQL Server is not registered with unixODBC." >&2
        exit 1
    fi
fi

echo "Ubuntu prerequisites passed: $PRETTY_NAME, $(uname -m), $(c++ --version | head -n 1), $(cmake --version | head -n 1)"
if [[ "$require_driver" == true ]]; then
    echo "ODBC Driver 18 for SQL Server is registered."
fi