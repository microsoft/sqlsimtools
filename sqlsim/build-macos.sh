#!/usr/bin/env bash

set -euo pipefail

configuration="Release"
clean=false
verbose=false

usage() {
    cat <<'EOF'
Usage: bash build-macos.sh [options]

Options:
  --clean                  Remove the macOS build directory first
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
build_dir="$script_dir/build/macos-arm64"

bash "$script_dir/check-prerequisites-macos.sh"
odbc_prefix="$(brew --prefix unixodbc)"

if [[ "$clean" == true ]]; then
    rm -rf "$build_dir"
fi

cmake_args=(
    -S "$script_dir"
    -B "$build_dir"
    "-DCMAKE_BUILD_TYPE=$configuration"
    "-DCMAKE_OSX_ARCHITECTURES=arm64"
    "-DCMAKE_PREFIX_PATH=$odbc_prefix"
    "-DODBC_INCLUDE_DIR=$odbc_prefix/include"
    "-DODBC_LIBRARY=$odbc_prefix/lib/libodbc.dylib"
)

cpu_count="$(sysctl -n hw.logicalcpu)"
build_args=(--build "$build_dir" --parallel "$cpu_count")
if [[ "$verbose" == true ]]; then
    build_args+=(--verbose)
fi

echo "Configuring sqlsim for macOS ARM64 ($configuration)..."
cmake "${cmake_args[@]}"

echo "Building sqlsim..."
cmake "${build_args[@]}"

binary="$build_dir/sqlsim"
if [[ ! -x "$binary" ]]; then
    echo "ERROR: Build completed without producing $binary" >&2
    exit 1
fi

if ! file "$binary" | grep -q 'Mach-O 64-bit executable arm64'; then
    echo "ERROR: Build did not produce a native macOS ARM64 executable." >&2
    file "$binary" >&2
    exit 1
fi

echo "Build succeeded: $binary"
file "$binary"
otool -L "$binary"
