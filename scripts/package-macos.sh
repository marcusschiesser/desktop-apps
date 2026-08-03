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
cp "$project_dir/assets/bin/whisper-cli" "$package_assets/bin/"
cp "$project_dir/assets/icon.png" "$package_assets/"

sh "$project_dir/scripts/native-pr.sh" package \
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

plist="$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$plist"

chmod 755 "$app_path/Contents/Resources/bin/whisper-cli"

if [ "$signing_identity" = "-" ]; then
	codesign --force --sign - "$app_path/Contents/Resources/bin/whisper-cli"
	codesign \
		--force \
		--sign - \
		--identifier com.local.meetingnotes \
		--requirements '=designated => identifier "com.local.meetingnotes"' \
		--entitlements "$project_dir/assets/meeting-notes.entitlements" \
		"$app_path"
else
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
