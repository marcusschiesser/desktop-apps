#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=$(uname -m)
output_dir="$project_dir/assets/bin"
output="$output_dir/meeting-notes-helper"
module_cache="$project_dir/.native/swift-module-cache"

mkdir -p "$output_dir" "$module_cache"

xcrun swiftc \
	-parse-as-library \
	-O \
	-module-cache-path "$module_cache" \
	-target "${arch}-apple-macos15.0" \
	-framework AppKit \
	-framework AVFoundation \
	-framework CoreMedia \
	-framework ScreenCaptureKit \
	-framework SoundAnalysis \
	"$project_dir/native/MeetingNotesHelper.swift" \
	-o "$output"

codesign \
	--force \
	--sign - \
	--identifier com.local.meetingnotes.helper \
	--requirements '=designated => identifier "com.local.meetingnotes.helper"' \
	"$output" >/dev/null
echo "built $output"
