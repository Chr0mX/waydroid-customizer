#!/usr/bin/env bash
# tools/set-spoof-profile.sh
#
# Host-side helper: push a spoof profile into the running Waydroid container.
# The profile is written to /data/waydroid-spoof/active.prop inside the
# Waydroid data directory.  On next boot (or waydroid restart), the loader
# will apply it.
#
# Usage:
#   set-spoof-profile.sh <profile_name>
#   set-spoof-profile.sh --list
#   set-spoof-profile.sh --clear
#
# Requires: waydroid session to be running (waydroid status = RUNNING)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${REPO_ROOT}/modules/spoof/profiles"

# Waydroid data dir (adjust if non-standard)
WAYDROID_DATA_DIR="${WAYDROID_DATA_DIR:-/var/lib/waydroid/data}"
SPOOF_DIR="${WAYDROID_DATA_DIR}/waydroid-spoof"

require_waydroid() {
    command -v waydroid &>/dev/null || { echo "waydroid not found in PATH" >&2; exit 1; }
}

list_profiles() {
    echo "Available spoof profiles:"
    for f in "${PROFILES_DIR}"/*.json; do
        local id name desc
        id="$(basename "$f" .json)"
        name="$(python3 -c "import json; p=json.load(open('$f')); print(p.get('name','?'))")"
        desc="$(python3 -c "import json; p=json.load(open('$f')); print(p.get('description',''))")"
        printf "  %-20s  %s\n" "$id" "$desc"
    done
}

apply_profile() {
    local profile="$1"
    local json="${PROFILES_DIR}/${profile}.json"
    [[ -f "$json" ]] || { echo "Profile not found: $profile" >&2; exit 1; }

    mkdir -p "$SPOOF_DIR"

    python3 - "$json" > "${SPOOF_DIR}/active.prop" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
for k, v in p.get("props", {}).items():
    print(f"{k}={v}")
EOF

    echo "Profile '${profile}' written to ${SPOOF_DIR}/active.prop"
    echo "Restart Waydroid to apply: waydroid session stop && waydroid session start"
}

clear_profile() {
    if [[ -f "${SPOOF_DIR}/active.prop" ]]; then
        rm "${SPOOF_DIR}/active.prop"
        echo "active.prop removed – build-time identity will be used on next boot."
    else
        echo "No active profile set."
    fi
}

case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    *)       apply_profile "$1" ;;
esac
