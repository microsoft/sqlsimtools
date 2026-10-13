#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_release_dir="$script_dir/release/linux-x64"
release_dir="$default_release_dir"
skip_build=false
force=false
preview=false

usage() {
    cat <<'EOF'
Usage: bash publish-linux.sh [options]

Stages the Linux release overlay: sqlsim/ plus .github/skills/sqlsim and the
shared Workload Builder. Publishing into an existing project never deletes
files and never replaces a file whose contents differ unless --force is given.
The default staging directory is disposable and is always refreshed.

Options:
  --release-dir <path>  Project root or staging directory (default: release/linux-x64)
  --skip-build          Use the existing Release binary
  --force               Replace existing files that differ from this release
  --preview             List files that would be created or replaced; write nothing
  -h, --help            Show this help
EOF
}

while (($# > 0)); do
    case "$1" in
        --release-dir)
            if (($# < 2)); then
                echo "ERROR: --release-dir requires a path." >&2
                exit 2
            fi
            release_dir="$2"
            shift 2
            ;;
        --skip-build)
            skip_build=true
            shift
            ;;
        --force)
            force=true
            shift
            ;;
        --preview)
            preview=true
            skip_build=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$skip_build" == false ]]; then
    bash "$script_dir/build-linux.sh"
fi

binary="$script_dir/build/linux-x64/sqlsim"
if [[ ! -x "$binary" ]]; then
    echo "ERROR: Linux sqlsim binary not found at $binary" >&2
    exit 1
fi

release_dir="$(realpath -m "$release_dir")"
disposable=false
if [[ "$release_dir" == "$(realpath -m "$default_release_dir")" ]]; then
    disposable=true
fi

# Every file the overlay installs, as "source|relative destination".
plan=()
add_file() { plan+=("$1|$2"); }
add_file "$binary" "sqlsim/x64/sqlsim"
for name in AGENTS.md LICENSE sqlsim.md; do
    add_file "$script_dir/$name" "sqlsim/$name"
done
add_file "$script_dir/../THIRD-PARTY-NOTICES.md" "sqlsim/THIRD-PARTY-NOTICES.md"
if [[ -f "$script_dir/sqlsim.html" ]]; then
    add_file "$script_dir/sqlsim.html" "sqlsim/sqlsim.html"
fi
while IFS= read -r -d '' example; do
    add_file "$example" "sqlsim/examples/${example#"$script_dir/examples/"}"
done < <(find "$script_dir/examples" -type f -print0 | sort -z)
while IFS= read -r -d '' replay_file; do
    add_file "$replay_file" "sqlsim/replay/${replay_file#"$script_dir/replay/"}"
done < <(find "$script_dir/replay" -type f -print0 | sort -z)
add_file "$script_dir/../.github/skills/sqlsim/SKILL.md" ".github/skills/sqlsim/SKILL.md"
add_file "$script_dir/../.github/agents/sqlsimtools-workload-builder.agent.md" ".github/agents/sqlsimtools-workload-builder.agent.md"

if [[ "$disposable" == true && "$preview" == false ]]; then
    rm -rf "$release_dir"
fi

created=()
replaced=()
unchanged=()
for entry in "${plan[@]}"; do
    source_file="${entry%%|*}"
    relative="${entry#*|}"
    destination="$release_dir/$relative"
    if [[ ! -e "$destination" ]]; then
        created+=("$relative")
    elif cmp -s "$source_file" "$destination"; then
        unchanged+=("$relative")
    else
        replaced+=("$relative")
    fi
done

echo "Overlay target: $release_dir"
echo "  ${#created[@]} to create, ${#replaced[@]} to replace, ${#unchanged[@]} unchanged"
for relative in "${replaced[@]}"; do
    echo "  replace: $relative"
done

if [[ "$preview" == true ]]; then
    if ((${#replaced[@]} > 0)) && [[ "$force" == false ]]; then
        echo "Installing would require --force to replace the files above."
    fi
    echo "Preview complete: no files were written."
    exit 0
fi

if ((${#replaced[@]} > 0)) && [[ "$force" == false ]]; then
    echo "ERROR: ${#replaced[@]} existing file(s) in $release_dir differ from this release and were not changed." >&2
    echo "Review the list above, then re-run with --force to replace them, or with --preview to list changes." >&2
    exit 1
fi

for entry in "${plan[@]}"; do
    source_file="${entry%%|*}"
    destination="$release_dir/${entry#*|}"
    mkdir -p "$(dirname "$destination")"
    cp "$source_file" "$destination"
done
chmod +x "$release_dir/sqlsim/x64/sqlsim"

echo "Linux release staged at: $release_dir"
echo "  Created ${#created[@]}, replaced ${#replaced[@]}, unchanged ${#unchanged[@]}."
