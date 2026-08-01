#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir="$project_dir/.native/vendor/whisper.cpp"
build_dir="$project_dir/.native/whisper-build"
output_dir="$project_dir/assets/bin"
model_dir="$project_dir/assets/models"
output="$output_dir/whisper-cli"
model="$model_dir/ggml-medium.bin"
whisper_version="v1.9.1"
whisper_commit="f049fff95a089aa9969deb009cdd4892b3e74916"
model_sha256="6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"

mkdir -p "$project_dir/.native/vendor" "$output_dir" "$model_dir"

if [ ! -f "$source_dir/CMakeLists.txt" ]; then
	git clone --depth 1 --branch "$whisper_version" https://github.com/ggml-org/whisper.cpp.git "$source_dir"
fi

actual_commit=$(git -C "$source_dir" rev-parse HEAD)
if [ "$actual_commit" != "$whisper_commit" ]; then
	echo "unexpected whisper.cpp commit: $actual_commit" >&2
	echo "expected $whisper_commit ($whisper_version)" >&2
	exit 1
fi

if [ ! -f "$model" ]; then
	sh "$source_dir/models/download-ggml-model.sh" medium "$model_dir"
fi

actual_model_sha256=$(shasum -a 256 "$model" | awk '{print $1}')
if [ "$actual_model_sha256" != "$model_sha256" ]; then
	echo "whisper medium model checksum mismatch" >&2
	echo "expected $model_sha256" >&2
	echo "received $actual_model_sha256" >&2
	exit 1
fi

cmake \
	-S "$source_dir" \
	-B "$build_dir" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DWHISPER_BUILD_TESTS=OFF \
	-DWHISPER_BUILD_SERVER=OFF \
	-DWHISPER_BUILD_EXAMPLES=ON \
	-DGGML_NATIVE=OFF \
	-DGGML_METAL=OFF

cmake --build "$build_dir" --target whisper-cli --config Release --parallel
cp "$build_dir/bin/whisper-cli" "$output"
chmod 755 "$output"
codesign --force --sign - "$output" >/dev/null

echo "bundled whisper.cpp $whisper_version and the medium model"
