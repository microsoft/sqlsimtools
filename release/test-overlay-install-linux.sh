#!/usr/bin/env bash
# Exercises publish-linux.sh against a temporary project: fresh install,
# repeat, refusal without --force, --preview, --force, and that a project's
# own files are never deleted. Uses a placeholder binary when none is built.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sqlsim_dir="$(cd "$script_dir/../sqlsim" && pwd)"
binary="$sqlsim_dir/build/linux-x64/sqlsim"
placeholder=false
if [[ ! -x "$binary" ]]; then
    mkdir -p "$(dirname "$binary")"
    printf '#!/bin/sh\necho placeholder\n' > "$binary"
    chmod +x "$binary"
    placeholder=true
fi

project="$(mktemp -d)"
cleanup() {
    rm -rf "$project"
    if [[ "$placeholder" == true ]]; then
        rm -f "$binary"
    fi
}
trap cleanup EXIT

passed=0
failed=0
check() {
    local name="$1"; shift
    if "$@"; then
        echo "  ok      $name"; passed=$((passed + 1))
    else
        echo "  FAILED  $name"; failed=$((failed + 1))
    fi
}
publish() { bash "$sqlsim_dir/publish-linux.sh" --skip-build --release-dir "$project" "$@"; }

echo "Linux overlay install tests in $project"
echo 'SELECT 1;' > "$project/keep-me.sql"

fresh_install() { publish >/dev/null && [[ -x "$project/sqlsim/x64/sqlsim" && -f "$project/keep-me.sql" ]]; }
check 'a fresh install into an existing project keeps its files' fresh_install

repeat_install() { local output; output="$(publish)"; grep -q '0 to create, 0 to replace' <<<"$output"; }
check 'republishing the same release changes nothing' repeat_install

skill="$project/.github/skills/sqlsim/SKILL.md"
mkdir -p "$project/sqlsim/examples"
echo 'SELECT 2;' > "$project/sqlsim/examples/my-team-workload.sql"
echo '# my locally edited skill' > "$skill"

refuse() {
    local before after output
    before="$(sha256sum "$skill")"
    if output="$(publish 2>&1)"; then return 1; fi
    after="$(sha256sum "$skill")"
    [[ "$before" == "$after" ]] && grep -q 'replace: .github/skills/sqlsim/SKILL.md' <<<"$output" && grep -q -- '--force' <<<"$output"
}
check 'a changed file is not replaced without --force and nothing is written' refuse

preview() {
    local before after output
    before="$(sha256sum "$skill")"
    output="$(publish --preview)"
    after="$(sha256sum "$skill")"
    [[ "$before" == "$after" ]] && grep -q 'Preview complete' <<<"$output"
}
check '--preview lists the change and writes nothing' preview

force() {
    publish --force >/dev/null &&
        grep -q '^name: sqlsim' "$skill" &&
        [[ -f "$project/sqlsim/examples/my-team-workload.sql" && -f "$project/keep-me.sql" ]]
}
check '--force replaces the file and keeps the project'"'"'s own files' force

echo
echo "Passed: $passed  Failed: $failed"
((failed == 0))
