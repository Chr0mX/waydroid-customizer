#!/usr/bin/env bash
# tools/set-spoof-profile.sh
#
# Host-side helper: apply a device spoof profile to Waydroid (LineageOS 18.1).
#
# Properties are written to two places:
#   1. /var/lib/waydroid/waydroid.cfg [properties]  – survives waydroid init/upgrade
#   2. /var/lib/waydroid/waydroid_base.prop          – immediate effect on next boot
#
# Then 'waydroid upgrade --offline' syncs both and regenerates waydroid_base.prop.
# Based on: https://github.com/lil-xhris/Waydroid-total-spoof
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
WAYDROID_BASE_PROP="${WAYDROID_BASE_PROP:-/var/lib/waydroid/waydroid_base.prop}"
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

# Write every prop from a profile JSON into waydroid.cfg [properties].
# Saves the list of injected keys to ACTIVE_KEYS_FILE for --clear.
_write_to_cfg() {
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

print(f"[spoof] cfg: wrote {len(injected)} props", file=sys.stderr)
PYEOF
}

# Upsert every prop from a profile JSON directly into waydroid_base.prop.
# Replace the line if key already exists, append if new.
# This mirrors how lil-xhris/Waydroid-total-spoof (waydroid.sh) works.
_write_to_base_prop() {
    local json_file="$1"
    [[ -f "$WAYDROID_BASE_PROP" ]] || touch "$WAYDROID_BASE_PROP"
    python3 - "$json_file" "$WAYDROID_BASE_PROP" <<'PYEOF'
import sys, json

json_file, prop_path = sys.argv[1], sys.argv[2]

profile = json.load(open(json_file))
props   = profile.get("props", {})

with open(prop_path, "r") as f:
    lines = f.readlines()

# Index existing keys
index = {}
for i, line in enumerate(lines):
    stripped = line.rstrip("\n")
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        index[k] = i

# Upsert
for key, val in props.items():
    entry = f"{key}={val}\n"
    if key in index:
        lines[index[key]] = entry
    else:
        lines.append(entry)
        index[key] = len(lines) - 1

with open(prop_path, "w") as f:
    f.writelines(lines)

print(f"[spoof] base.prop: upserted {len(props)} props", file=sys.stderr)
PYEOF
}

# Remove the previously injected keys from waydroid.cfg [properties].
_remove_from_cfg() {
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

print(f"[spoof] cfg: removed {removed} props", file=sys.stderr)
PYEOF
}

# Remove the previously injected keys from waydroid_base.prop.
_remove_from_base_prop() {
    [[ -f "$WAYDROID_BASE_PROP" ]] || return 0
    python3 - "$ACTIVE_KEYS_FILE" "$WAYDROID_BASE_PROP" <<'PYEOF'
import sys

keys_file, prop_path = sys.argv[1], sys.argv[2]

with open(keys_file) as f:
    keys = set(l.strip() for l in f if l.strip())

with open(prop_path, "r") as f:
    lines = f.readlines()

kept = []
removed = 0
for line in lines:
    stripped = line.rstrip("\n")
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        if k in keys:
            removed += 1
            continue
    kept.append(line)

with open(prop_path, "w") as f:
    f.writelines(kept)

print(f"[spoof] base.prop: removed {removed} props", file=sys.stderr)
PYEOF
}

apply_profile() {
    local profile="$1"
    local json="${PROFILES_DIR}/${profile}.json"

    [[ -f "$json" ]] \
        || die "Profile not found: '${profile}' (looked in ${PROFILES_DIR})"
    [[ -f "$WAYDROID_CFG" ]] \
        || die "waydroid.cfg not found at ${WAYDROID_CFG}. Run: sudo waydroid init"

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    log "Writing to waydroid.cfg [properties]…"
    _write_to_cfg "$json"

    log "Writing to waydroid_base.prop…"
    _write_to_base_prop "$json"

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

    log "Removing injected props from waydroid.cfg…"
    _remove_from_cfg

    log "Removing injected props from waydroid_base.prop…"
    _remove_from_base_prop

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
