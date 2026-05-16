#!/usr/bin/env bash
# set-spoof-profile.sh – Apply a device spoof profile to Waydroid.
#
# Works both as a local script and piped via curl — profiles are fetched
# from GitHub when the local repo is not present.
#
# Usage:
#   sudo bash set-spoof-profile.sh <profile>
#   sudo bash set-spoof-profile.sh --list
#   sudo bash set-spoof-profile.sh --clear
#
#   # Via curl (no local clone needed):
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/set-spoof-profile.sh \
#     | sudo bash -s -- <profile>
#
# Profiles: pixel-5  pixel-4a  samsung-s21  generic-x86  none
set -euo pipefail

readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly PROFILES_RAW_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/modules/spoof/profiles"
readonly VALID_PROFILES=(pixel-5 pixel-4a samsung-s21 generic-x86)
readonly SPOOF_DIR="${WAYDROID_DATA_DIR:-/var/lib/waydroid/data}/waydroid-spoof"

_ts()  { date '+%H:%M:%S'; }
log()  { echo "[INFO]  $(_ts) $*" >&2; }
ok()   { echo "[OK]    $(_ts) $*" >&2; }
die()  { echo "[ERROR] $(_ts) $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

# ── Profile JSON source ───────────────────────────────────────────────────────
# Prefer local file (when running from a repo clone), fall back to GitHub.
_profile_json() {
    local profile="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    local local_file="${script_dir}/../modules/spoof/profiles/${profile}.json"

    if [[ -n "$script_dir" && -f "$local_file" ]]; then
        cat "$local_file"
    else
        curl -fsSL --connect-timeout 15 "${PROFILES_RAW_URL}/${profile}.json" 2>/dev/null \
            || die "Could not fetch profile '${profile}' from GitHub."
    fi
}

# ── Subcommands ───────────────────────────────────────────────────────────────
list_profiles() {
    echo "Available spoof profiles:"
    local p
    for p in "${VALID_PROFILES[@]}"; do
        local desc
        desc="$(_profile_json "$p" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null || echo "")"
        printf "  %-16s  %s\n" "$p" "$desc"
    done
    echo "  none              Remove active profile (use image defaults)"
}

apply_profile() {
    local profile="$1"
    local valid=0
    local p
    for p in "${VALID_PROFILES[@]}"; do [[ "$profile" == "$p" ]] && valid=1 && break; done
    [[ "$valid" -eq 1 ]] || die "Unknown profile '${profile}'. Run with --list to see options."

    log "Fetching profile: ${profile}…"
    local json
    json="$(_profile_json "$profile")"
    [[ -n "$json" ]] || die "Profile JSON is empty."

    mkdir -p "$SPOOF_DIR"
    printf '%s' "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
props = data.get('props', {})
if not props:
    raise ValueError('No props in profile')
for k, v in props.items():
    print(f'{k}={v}')
" > "${SPOOF_DIR}/active.prop" || die "Failed to parse profile JSON."

    ok "Profile '${profile}' applied → ${SPOOF_DIR}/active.prop"
    echo >&2
    echo "  Restart Waydroid to activate:" >&2
    echo "    waydroid session stop && waydroid show-full-ui" >&2
}

clear_profile() {
    if [[ -f "${SPOOF_DIR}/active.prop" ]]; then
        rm "${SPOOF_DIR}/active.prop"
        ok "Profile cleared — image defaults will be used on next boot."
    else
        echo "No active profile set." >&2
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    none)    clear_profile ;;
    *)       apply_profile "$1" ;;
esac
