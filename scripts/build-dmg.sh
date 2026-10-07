#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "--skip-build" ]]; then
    if [[ "${1:-}" != "" ]]; then
        printf 'Usage: %s [--skip-build]\n' "$0" >&2
        exit 1
    fi
    ./scripts/build-app.sh --universal
fi
app_dir="$project_dir/dist/CapsTalk.app"
codesign --verify --deep --strict "$app_dir"
for architecture in arm64 x86_64; do
    lipo "$app_dir/Contents/MacOS/CapsTalk" -verify_arch "$architecture"
done
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
disk_image="$project_dir/dist/CapsTalk-$version-universal.dmg"
approval="local"
if codesign -dv "$app_dir" 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application:'; then
    # Supply a keychain profile created with `xcrun notarytool store-credentials`.
    if [[ -z "${CAPSTALK_NOTARY_PROFILE:-}" ]]; then
        printf 'Developer ID releases require CAPSTALK_NOTARY_PROFILE for notarization.\n' >&2
        exit 1
    fi
    archive="$project_dir/dist/CapsTalk-notarization.zip"
    ditto -c -k --keepParent "$app_dir" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$CAPSTALK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    approval="signed"
fi
swift scripts/generate-installer-art.swift "$project_dir" "$approval"
packaging_env="$project_dir/.build/packaging-venv"
if [[ ! -x "$packaging_env/bin/python" ]]; then
    python3 -m venv "$packaging_env"
fi
"$packaging_env/bin/python" -m pip install --quiet -r scripts/packaging-requirements.txt
"$packaging_env/bin/dmgbuild" -s scripts/dmg-settings.py -D "project_dir=$project_dir" \
    'CapsTalk Installer' "$disk_image"
if [[ "$approval" == "signed" ]]; then
    codesign --sign "$CAPSTALK_SIGNING_IDENTITY" --timestamp "$disk_image"
    xcrun notarytool submit "$disk_image" --keychain-profile "$CAPSTALK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$disk_image"
    xcrun stapler validate "$disk_image"
fi
hdiutil verify "$disk_image"
(cd "$project_dir/dist" && shasum -a 256 "$(basename "$disk_image")" > SHA256SUMS.txt)
printf 'Built %s\n' "$disk_image"
