#!/usr/bin/env bash
# tools/set-spoof-profile.sh
#
# Host-side helper: apply a device spoof profile to Waydroid.
#
# Properties are written directly into /var/lib/waydroid/waydroid.cfg
# [properties] section and activated with 'waydroid upgrade --offline'.
# This mirrors the approach used by lil-xhris/Waydroid-total-spoof and
# works without loop-mounting images or restarting LXC.
#
# Usage (run as root):
#   sudo bash set-spoof-profile.sh <profile_name>
#   sudo bash set-spoof-profile.sh --list
#   sudo bash set-spoof-profile.sh --clear
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${REPO_ROOT}/modules/spoof/profiles"

WAYDROID_CFG="${WAYDROID_CFG:-/var/lib/waydroid/waydroid.cfg}"
# Tracks the keys we injected so --clear can remove exactly those
ACTIVE_KEYS_FILE="/var/lib/waydroid/waydroid-spoof-active-keys"

log() { echo "[spoof] $*" >&2; }
ok()  { echo "[spoof] OK: $*" >&2; }
die() { echo "[spoof] ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"
command -v python3 &>/dev/null || die "python3 is required."
command -v waydroid &>/dev/null || die "waydroid is not in PATH."

list_profiles() {
    echo "Available spoof profiles:"
    for f in "${PROFILES_DIR}"/*.json; do
        local id desc
        id="$(basename "$f" .json)"
        desc="$(python3 -c "import json; p=json.load(open('$f')); print(p.get('description',''))")"
        printf "  %-22s  %s\n" "$id" "$desc"
    done
}

# Write every prop from a profile JSON into waydroid.cfg [properties],
# then save the list of injected keys for later --clear.
_write_props_to_cfg() {
    local json_file="$1"
    python3 - "$json_file" "$WAYDROID_CFG" "$ACTIVE_KEYS_FILE" <<'PYEOF'
import sys, json, configparser

json_file, cfg_path, keys_out = sys.argv[1], sys.argv[2], sys.argv[3]

profile = json.load(open(json_file))
props   = profile.get("props", {})

cfg = configparser.ConfigParser()
cfg.read(cfg_path)
if "properties" not in cfg:
    cfg["properties"] = {}

injected = []
for key, val in props.items():
    cfg["properties"][key] = str(val)
    injected.append(key)

with open(cfg_path, "w") as f:
    cfg.write(f)

with open(keys_out, "w") as f:
    f.write("\n".join(injected) + "\n")

print(f"[spoof] Wrote {len(injected)} properties to {cfg_path}", file=sys.stderr)
PYEOF
}

# Remove the previously injected keys from waydroid.cfg [properties].
_remove_props_from_cfg() {
    python3 - "$ACTIVE_KEYS_FILE" "$WAYDROID_CFG" <<'PYEOF'
import sys, configparser

keys_file, cfg_path = sys.argv[1], sys.argv[2]

with open(keys_file) as f:
    keys = [l.strip() for l in f if l.strip()]

cfg = configparser.ConfigParser()
cfg.read(cfg_path)

removed = 0
if "properties" in cfg:
    for key in keys:
        if cfg.remove_option("properties", key):
            removed += 1

with open(cfg_path, "w") as f:
    cfg.write(f)

print(f"[spoof] Removed {removed} properties from {cfg_path}", file=sys.stderr)
PYEOF
}

apply_profile() {
    local profile="$1"
    local json="${PROFILES_DIR}/${profile}.json"

    [[ -f "$json" ]] \
        || die "Profile not found: '${profile}' (looked in ${PROFILES_DIR})"
    [[ -f "$WAYDROID_CFG" ]] \
        || die "waydroid.cfg not found at ${WAYDROID_CFG}. Has waydroid been initialised? (sudo waydroid init)"

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    log "Applying profile '${profile}'…"
    _write_props_to_cfg "$json"

    log "Activating with waydroid upgrade --offline…"
    waydroid upgrade --offline 2>/dev/null \
        || log "waydroid upgrade returned non-zero (may be harmless)."

    log "Starting Waydroid container…"
    systemctl start waydroid-container 2>/dev/null || true

    ok "Profile '${profile}' applied."
    echo "  Start UI : waydroid show-full-ui" >&2
    echo "  Revert   : sudo bash $0 --clear" >&2
}

clear_profile() {
    [[ -f "$WAYDROID_CFG" ]] \
        || die "waydroid.cfg not found at ${WAYDROID_CFG}."

    if [[ ! -f "$ACTIVE_KEYS_FILE" ]]; then
        log "No active spoof profile (${ACTIVE_KEYS_FILE} missing). Nothing to do."
        return 0
    fi

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    log "Removing injected props from ${WAYDROID_CFG}…"
    _remove_props_from_cfg
    rm -f "$ACTIVE_KEYS_FILE"

    log "Activating with waydroid upgrade --offline…"
    waydroid upgrade --offline 2>/dev/null \
        || log "waydroid upgrade returned non-zero (may be harmless)."

    log "Starting Waydroid container…"
    systemctl start waydroid-container 2>/dev/null || true

    ok "Spoof cleared. Default identity will be used."
}

case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    *)       apply_profile "$1" ;;
esac
