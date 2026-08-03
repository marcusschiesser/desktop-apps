#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk_hash=$(awk -F'"' '/^[[:space:]]*\.hash = "native_sdk-/{print $2; exit}' "$project_dir/build.zig.zon")
if [ -z "$sdk_hash" ]; then
    echo "could not read the Native SDK package hash from build.zig.zon" >&2
    exit 1
fi
sdk_dir="$project_dir/zig-pkg/$sdk_hash"
cli_prefix="$project_dir/.native/native-pr-264/$sdk_hash"
cli="$cli_prefix/bin/native"
global_cache="$project_dir/.native/zig-global-cache"

if [ ! -f "$sdk_dir/build.zig" ]; then
    (
        cd "$project_dir"
        ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build --fetch
    )
fi

if [ ! -x "$cli" ]; then
    (
        cd "$sdk_dir"
        ZIG_GLOBAL_CACHE_DIR="$global_cache" zig build cli \
            -Doptimize=ReleaseFast \
            --prefix "$cli_prefix"
    )
fi

export NATIVE_SDK_PATH="$sdk_dir"
export ZIG_GLOBAL_CACHE_DIR="$global_cache"
exec "$cli" "$@"
