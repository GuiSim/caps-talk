#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "" && "${1:-}" != "--universal" ]]; then
    printf 'Usage: %s [--universal]\n' "$0" >&2
    exit 1
fi
app_dir="$project_dir/dist/CapsTalk.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ "${1:-}" == "--universal" ]]; then
    binaries=()
    for architecture in arm64 x86_64; do
        build_options=(-c release --triple "$architecture-apple-macosx13.0" --scratch-path "$project_dir/.build/release-$architecture")
        swift build "${build_options[@]}"
        binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
        binaries+=("$binary_dir/CapsTalk")
    done
    lipo -create "${binaries[@]}" -output "$app_dir/Contents/MacOS/CapsTalk"
else
    swift build -c release
    binary_dir="$(swift build -c release --show-bin-path)"
    cp "$binary_dir/CapsTalk" "$app_dir/Contents/MacOS/CapsTalk"
fi
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/CapsTalk.icns "$app_dir/Contents/Resources/CapsTalk.icns"
# Prefer a local developer certificate when supplied. Ad hoc signing works for local use.
signing_options=(--force --options runtime --sign "${CAPSTALK_SIGNING_IDENTITY:--}" --identifier app.capstalk.CapsTalk)
if [[ "${CAPSTALK_SIGNING_IDENTITY:--}" != "-" ]]; then
    signing_options+=(--timestamp)
fi
codesign "${signing_options[@]}" "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
