#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: This experimental build requires macOS on Apple Silicon (arm64)." >&2
    exit 1
fi

missing=()
for command_name in brew cmake c++ sysctl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing+=("$command_name")
    fi
done

if ((${#missing[@]} > 0)); then
    echo "ERROR: macOS build prerequisites are missing: ${missing[*]}" >&2
    echo "Install Homebrew, then run: brew install cmake unixodbc" >&2
    exit 1
fi

odbc_prefix="$(brew --prefix unixodbc 2>/dev/null || true)"
if [[ -z "$odbc_prefix" || ! -f "$odbc_prefix/include/sql.h" || ! -f "$odbc_prefix/lib/libodbc.dylib" ]]; then
    echo "ERROR: Homebrew unixODBC development files are missing." >&2
    echo "Install them with: brew install unixodbc" >&2
    exit 1
fi

echo "macOS prerequisites passed: $(sw_vers -productVersion), $(uname -m), $(c++ --version | head -n 1), $(cmake --version | head -n 1)"
