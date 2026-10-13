#!/usr/bin/env bash

set -euo pipefail

binary="${1:?Usage: verify-macos-arm64.sh <binary>}"
file "$binary"
file "$binary" | grep -q 'Mach-O 64-bit executable arm64'
