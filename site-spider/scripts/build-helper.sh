#!/bin/sh
set -eu

mkdir -p assets/bin
output="assets/bin/seo-spider-helper"
case "$(go env GOOS)" in
  windows) output="${output}.exe" ;;
esac

go build -trimpath -ldflags="-s -w" -o "$output" ./helper
printf 'Built %s\n' "$output"
