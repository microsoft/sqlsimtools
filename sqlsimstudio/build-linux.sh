#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime="${1:-linux-x64}"

if [[ "$runtime" != "linux-x64" && "$runtime" != "linux-arm64" ]]; then
    echo "Usage: bash build-linux.sh [linux-x64|linux-arm64]" >&2
    exit 2
fi

output="$script_dir/build/$runtime"
rm -rf "$output"

dotnet publish "$script_dir/server/SqlsimStudio.csproj" \
    -c Release \
    -r "$runtime" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:DebugType=None \
    -o "$output"

sqlsim_source="$script_dir/../sqlsim/build/$runtime/sqlsim"
if [[ ! -x "$sqlsim_source" ]]; then
    echo "ERROR: Matching sqlsim binary not found at $sqlsim_source" >&2
    exit 1
fi
mkdir -p "$output/sqlsim" "$output/sqlpysim" "$output/.github/skills/sqlsimstudio"
cp "$sqlsim_source" "$output/sqlsim/sqlsim"
cp "$script_dir/../sqlpysim/sqlpysim.py" "$output/sqlpysim/sqlpysim.py"
cp "$script_dir/../sqlpysim/requirements.txt" "$output/sqlpysim/requirements.txt"
cp "$script_dir/THIRD-PARTY-NOTICES.md" "$output/THIRD-PARTY-NOTICES.md"
cp "$script_dir/sqlsimstudio.md" "$output/sqlsimstudio.md"
if command -v pandoc >/dev/null 2>&1; then
    pandoc "$script_dir/sqlsimstudio.md" \
        -o "$output/sqlsimstudio.html" \
        --standalone \
        --from=gfm \
        --css="$script_dir/manual.css" \
        --resource-path="$script_dir" \
        --embed-resources \
        --metadata "pagetitle=sqlsim Studio User Manual"
    echo "sqlsim Studio HTML manual generated: $output/sqlsimstudio.html"
else
    echo "WARNING: pandoc was not found; sqlsimstudio.html was not generated." >&2
fi
cp "$script_dir/CONFIGURATION.md" "$output/CONFIGURATION.md"
cp -R "$script_dir/examples" "$output/examples"
cp "$script_dir/../.github/skills/sqlsimstudio/SKILL.md" "$output/.github/skills/sqlsimstudio/SKILL.md"
cp "$script_dir/../LICENSE" "$output/LICENSE"

echo "sqlsim Studio published: $output"
