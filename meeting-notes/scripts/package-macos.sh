#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

npm run setup:whisper
npm run build
rm -rf "$project_dir/release"
app_path="$project_dir/release/Local Meeting Notes.app"
package_assets="$project_dir/.native/package-assets"
signing_identity=${MEETING_NOTES_CODESIGN_IDENTITY:--}

rm -rf "$package_assets"
mkdir -p "$package_assets/bin"
cp "$project_dir/assets/bin/meeting-notes-helper" "$package_assets/bin/"
cp "$project_dir/assets/bin/whisper-cli" "$package_assets/bin/"
cp "$project_dir/assets/icon.png" "$package_assets/"

native package \
	--target macos \
	--output "$app_path" \
	--binary "$project_dir/zig-out/bin/meeting-notes" \
	--assets "$package_assets" \
	--web-layer exclude \
	--signing none

if [ ! -d "$app_path" ]; then
	echo "native package did not create an app bundle" >&2
	exit 1
fi

mkdir -p "$app_path/Contents/Resources/models"
cp "$project_dir/assets/models/ggml-medium.bin" "$app_path/Contents/Resources/models/"
mkdir -p "$app_path/Contents/Helpers"
mv \
	"$app_path/Contents/Resources/bin/meeting-notes-helper" \
	"$app_path/Contents/Helpers/meeting-notes-helper"

plist="$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Local Meeting Notes records your microphone during meetings." "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription Local Meeting Notes records your microphone during meetings." "$plist"
/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string Local Meeting Notes captures system audio during meetings." "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription Local Meeting Notes captures system audio during meetings." "$plist"
/usr/libexec/PlistBuddy -c "Add :NSAudioCaptureUsageDescription string Local Meeting Notes captures system audio during meetings." "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Set :NSAudioCaptureUsageDescription Local Meeting Notes captures system audio during meetings." "$plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$plist"

chmod 755 "$app_path/Contents/Helpers/meeting-notes-helper"
chmod 755 "$app_path/Contents/Resources/bin/whisper-cli"

if [ "$signing_identity" = "-" ]; then
	codesign \
		--force \
		--sign - \
		--identifier com.local.meetingnotes.helper \
		--requirements '=designated => identifier "com.local.meetingnotes.helper"' \
		"$app_path/Contents/Helpers/meeting-notes-helper"
	codesign --force --sign - "$app_path/Contents/Resources/bin/whisper-cli"
	codesign \
		--force \
		--sign - \
		--identifier com.local.meetingnotes \
		--requirements '=designated => identifier "com.local.meetingnotes"' \
		--entitlements "$project_dir/assets/meeting-notes.entitlements" \
		"$app_path"
else
	codesign \
		--force \
		--sign "$signing_identity" \
		--identifier com.local.meetingnotes.helper \
		"$app_path/Contents/Helpers/meeting-notes-helper"
	codesign --force --sign "$signing_identity" "$app_path/Contents/Resources/bin/whisper-cli"
	codesign \
		--force \
		--sign "$signing_identity" \
		--identifier com.local.meetingnotes \
		--entitlements "$project_dir/assets/meeting-notes.entitlements" \
		"$app_path"
fi
codesign --verify --deep --strict "$app_path"

echo "packaged $app_path"
