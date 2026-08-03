#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$project_dir/assets/bin"
output="$output_dir/flow-helper"
module_cache="$project_dir/.native/swift-module-cache"

mkdir -p "$output_dir" "$module_cache"

if [ "$(uname -s)" = "Darwin" ]; then
  arch=$(uname -m)
  xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -module-cache-path "$module_cache" \
    -target "${arch}-apple-macos15.0" \
    -framework AppKit \
    -framework AVFoundation \
    -framework ApplicationServices \
    "$project_dir/native/FlowHelper.swift" \
    -o "$output"
  codesign --force --sign - --identifier com.marcusschiesser.flowdictation.helper --requirements '=designated => identifier "com.marcusschiesser.flowdictation.helper"' "$output" >/dev/null
else
  swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$module_cache" "$project_dir/native/FlowHelper.swift" -o "$output"
fi

echo "built $output"
