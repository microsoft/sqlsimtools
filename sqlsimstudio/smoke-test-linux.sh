#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="${1:-$script_dir/build/linux-x64/sqlsimstudio}"
log_file="$(mktemp)"
cookie_file="$(mktemp)"
bootstrap_file="$(mktemp)"
# Keep the smoke test away from the user's saved Studio preferences.
settings_dir="$(mktemp -d)"
export SQLSIMSTUDIO_SETTINGS_DIR="$settings_dir"

cleanup() {
    if [[ -n "${studio_pid:-}" ]] && kill -0 "$studio_pid" 2>/dev/null; then
        kill "$studio_pid" 2>/dev/null || true
        wait "$studio_pid" 2>/dev/null || true
    fi
    rm -f "$log_file" "$cookie_file" "$bootstrap_file"
    rm -rf "$settings_dir"
}
trap cleanup EXIT

if [[ ! -f "$binary" ]]; then
    echo "ERROR: Linux Studio binary not found at $binary" >&2
    echo "Run .\\build.ps1 -Runtime linux-x64 from Windows first." >&2
    exit 1
fi

chmod +x "$binary"
"$binary" --no-open --bootstrap-file "$bootstrap_file" >"$log_file" 2>&1 &
studio_pid=$!

base_url=""
bootstrap_ready=""
for _ in {1..300}; do
    if ! kill -0 "$studio_pid" 2>/dev/null; then
        cat "$log_file" >&2
        exit 1
    fi
    base_url="$(sed -n 's/^SQLSIM_STUDIO_URL=//p' "$log_file" | tail -n 1)"
    bootstrap_ready="$(sed -n 's/^SQLSIM_STUDIO_BOOTSTRAP_READY=//p' "$log_file" | tail -n 1)"
    if [[ -n "$base_url" && "$bootstrap_ready" == "1" && -s "$bootstrap_file" ]]; then
        break
    fi
    sleep 0.1
 done

if [[ -z "$base_url" || "$bootstrap_ready" != "1" || ! -s "$bootstrap_file" ]]; then
    echo "ERROR: Studio did not publish startup URLs." >&2
    cat "$log_file" >&2
    exit 1
fi
bootstrap_url="$(cat "$bootstrap_file")"

unauthenticated_status="$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/api/health")"
[[ "$unauthenticated_status" == "404" ]]

bootstrap_headers="$(curl -sS -D - -o /dev/null -c "$cookie_file" "$bootstrap_url")"
grep -qi '^location: /#configure' <<<"$bootstrap_headers"
grep -qi 'httponly' <<<"$bootstrap_headers"
grep -qi 'samesite=strict' <<<"$bootstrap_headers"
[[ -s "$bootstrap_file" ]]
rotated_bootstrap_url="$(cat "$bootstrap_file")"
rotated_bootstrap_prefix="${base_url}/bootstrap/"
[[ "$rotated_bootstrap_url" != "$bootstrap_url" ]]
[[ "$rotated_bootstrap_url" == "$rotated_bootstrap_prefix"* ]]
rotated_bootstrap_token="${rotated_bootstrap_url#"$rotated_bootstrap_prefix"}"
[[ ${#rotated_bootstrap_token} -eq 64 ]]
[[ "$rotated_bootstrap_token" =~ ^[A-F0-9]+$ ]]

health_json="$(curl -sS -b "$cookie_file" "$base_url/api/health")"
python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["status"] == "ok"; assert data["application"] == "sqlsim Studio"; assert data["version"] == "1.0.0"; assert data["releaseStage"] == "Private Preview"' <<<"$health_json"

page="$(curl -sS -b "$cookie_file" "$base_url/")"
grep -q 'vendor/lucide.min.js' <<<"$page"
if grep -q 'unpkg.com' <<<"$page"; then
    echo "ERROR: Studio page references a remote script." >&2
    exit 1
fi

replay_status="$(curl -sS -o /dev/null -w '%{http_code}' "$bootstrap_url")"
[[ "$replay_status" == "404" ]]

echo "Linux Studio smoke test passed."
