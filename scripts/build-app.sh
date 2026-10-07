#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/CapsTalk.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/CapsTalk" "$app_dir/Contents/MacOS/CapsTalk"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/CapsTalk.icns "$app_dir/Contents/Resources/CapsTalk.icns"
# Prefer a local developer certificate when supplied. Ad hoc signing works for local use.
codesign --force --sign "${CAPSTALK_SIGNING_IDENTITY:--}" --identifier app.capstalk.CapsTalk "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
