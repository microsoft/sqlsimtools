#!/usr/bin/env bash

set -euo pipefail

configuration="Release"
clean=false
verbose=false

usage() {
    cat <<'EOF'
Usage: bash build-linux.sh [options]

Options:
  --clean                  Remove the Linux build directory first
  --configuration <value>  Release or Debug (default: Release)
  --verbose                Show verbose compiler output
  -h, --help               Show this help
EOF
}

while (($# > 0)); do
    case "$1" in
        --clean)
            clean=true
            shift
            ;;
        --configuration)
            if (($# < 2)); then
                echo "ERROR: --configuration requires Release or Debug." >&2
                exit 2
            fi
            configuration="$2"
            shift 2
            ;;
        --verbose)
            verbose=true
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

if [[ "$configuration" != "Release" && "$configuration" != "Debug" ]]; then
    echo "ERROR: --configuration must be Release or Debug." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$script_dir/build/linux-x64"

bash "$script_dir/check-prerequisites-linux.sh"

if [[ "$clean" == true ]]; then
    rm -rf "$build_dir"
fi

cmake_args=(
    -S "$script_dir"
    -B "$build_dir"
    "-DCMAKE_BUILD_TYPE=$configuration"
)

build_args=(--build "$build_dir" --parallel "$(nproc)")
if [[ "$verbose" == true ]]; then
    build_args+=(--verbose)
fi

echo "Configuring sqlsim for Ubuntu x64 ($configuration)..."
cmake "${cmake_args[@]}"

echo "Building sqlsim..."
cmake "${build_args[@]}"

binary="$build_dir/sqlsim"
if [[ ! -x "$binary" ]]; then
    echo "ERROR: Build completed without producing $binary" >&2
    exit 1
fi

echo "Build succeeded: $binary"