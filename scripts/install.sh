#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-app.sh"
destination="/Applications/CapsTalk.app"
if pgrep -x CapsTalk >/dev/null; then
    printf 'Quit CapsTalk from its menu before replacing the installed app.\n' >&2
    exit 1
fi
ditto "$project_dir/dist/CapsTalk.app" "$destination"
printf 'Installed %s\n' "$destination"
open "$destination"
