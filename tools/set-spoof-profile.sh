#!/usr/bin/env bash
# set-spoof-profile.sh – Apply a device spoof profile to Waydroid.
#
# Writes profile properties into /var/lib/waydroid/waydroid_base.prop, which
# Waydroid injects into the LXC container at startup (before Android's early
# init), so ro.* properties are respected without loop-mounting images.
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
# Profiles: pixel-5  pixel-4a  samsung-s21  generic-x86
set -euo pipefail

readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly PROFILES_RAW_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/modules/spoof/profiles"
readonly VALID_PROFILES=(pixel-5 pixel-4a samsung-s21 generic-x86)
readonly SPOOF_DIR="/var/lib/waydroid/waydroid-spoof"
readonly BASE_PROP="/var/lib/waydroid/waydroid_base.prop"

_ts()  { date '+%H:%M:%S'; }
log()  { echo "[INFO]  $(_ts) $*" >&2; }
ok()   { echo "[OK]    $(_ts) $*" >&2; }
warn() { echo "[WARN]  $(_ts) $*" >&2; }
die()  { echo "[ERROR] $(_ts) $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

# ── Profile JSON source ───────────────────────────────────────────────────────
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

# ── Patch a prop file with profile props ──────────────────────────────────────
# Replaces matching keys in-place; appends any keys that are missing.
# JSON is written to a temp file to avoid stdin conflict with the heredoc.
# Output is written atomically via a temp file + rename.
_patch_prop_file() {
    local prop_file="$1" json="$2"
    [[ -f "$prop_file" ]] || touch "$prop_file"
    local json_tmp out_tmp
    json_tmp="$(mktemp /tmp/spoof-json-XXXXXX.json)"
    out_tmp="${prop_file}.spoof-tmp"
    printf '%s' "$json" > "$json_tmp"

    python3 - "$prop_file" "$json_tmp" "$out_tmp" <<'PYEOF'
import sys, json, os

prop_file = sys.argv[1]
json_file = sys.argv[2]
tmp_file  = sys.argv[3]

with open(json_file) as f:
    props = json.load(f).get("props", {})

with open(prop_file) as f:
    lines = f.read().splitlines()

applied = set()
result = []
for line in lines:
    if "=" in line and not line.startswith("#"):
        key = line.split("=", 1)[0]
        if key in props:
            result.append(f"{key}={props[key]}")
            applied.add(key)
            continue
    result.append(line)

for k, v in props.items():
    if k not in applied:
        result.append(f"{k}={v}")

content = "\n".join(result) + "\n"
with open(tmp_file, "w") as f:
    f.write(content)
    f.flush()
    os.fsync(f.fileno())
PYEOF

    rm -f "$json_tmp"
    [[ -s "$out_tmp" ]] || { rm -f "$out_tmp"; die "Patching produced empty file — aborting."; }
    mv "$out_tmp" "$prop_file"
    log "Patched: $(basename "$prop_file")"
}

# ── Remove profile keys from a prop file ──────────────────────────────────────
_remove_props_from_file() {
    local prop_file="$1" json="$2"
    [[ -f "$prop_file" ]] || return 0
    local json_tmp out_tmp
    json_tmp="$(mktemp /tmp/spoof-json-XXXXXX.json)"
    out_tmp="${prop_file}.spoof-tmp"
    printf '%s' "$json" > "$json_tmp"

    python3 - "$prop_file" "$json_tmp" "$out_tmp" <<'PYEOF'
import sys, json, os

prop_file = sys.argv[1]
json_file = sys.argv[2]
tmp_file  = sys.argv[3]

with open(json_file) as f:
    keys = set(json.load(f).get("props", {}).keys())

with open(prop_file) as f:
    lines = f.read().splitlines()

result = []
for line in lines:
    if "=" in line and not line.startswith("#"):
        key = line.split("=", 1)[0]
        if key in keys:
            continue
    result.append(line)

content = "\n".join(result) + "\n"
with open(tmp_file, "w") as f:
    f.write(content)
    f.flush()
    os.fsync(f.fileno())
PYEOF

    rm -f "$json_tmp"
    mv "$out_tmp" "$prop_file"
    log "Cleared profile keys from $(basename "$prop_file")"
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
    echo "  none              Remove active profile (clear waydroid_base.prop entries)"
}

apply_profile() {
    local profile="$1"

    local valid=0 p
    for p in "${VALID_PROFILES[@]}"; do [[ "$profile" == "$p" ]] && valid=1 && break; done
    [[ "$valid" -eq 1 ]] || die "Unknown profile '${profile}'. Run with --list to see options."

    log "Fetching profile: ${profile}…"
    local json
    json="$(_profile_json "$profile")"
    [[ -n "$json" ]] || die "Profile JSON is empty."

    [[ -d /var/lib/waydroid ]] || die "/var/lib/waydroid not found. Run the installer first."

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 2

    log "Writing properties to waydroid_base.prop…"
    _patch_prop_file "$BASE_PROP" "$json"

    # ── Record active profile on host ─────────────────────────────────────────
    mkdir -p "$SPOOF_DIR"
    printf '%s' "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k, v in d.get('props', {}).items():
    print(f'{k}={v}')
" > "${SPOOF_DIR}/active.prop"

    log "Restarting Waydroid…"
    systemctl start waydroid-container 2>/dev/null || true

    echo >&2
    ok "Profile '${profile}' applied — properties written to waydroid_base.prop."
    echo "  Run: waydroid show-full-ui" >&2
}

clear_profile() {
    local cleared=0

    if [[ -f "${SPOOF_DIR}/active.prop" ]]; then
        # Build a minimal JSON from active.prop so _remove_props_from_file can strip the keys
        local active_json
        active_json="$(python3 -c "
import sys, json
props = {}
with open('${SPOOF_DIR}/active.prop') as f:
    for line in f:
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            props[k] = v
print(json.dumps({'props': props}))
")"
        _remove_props_from_file "$BASE_PROP" "$active_json"
        rm "${SPOOF_DIR}/active.prop"
        ok "Profile cleared from waydroid_base.prop."
        cleared=1
    fi

    [[ "$cleared" -eq 1 ]] || echo "No active profile found." >&2

    log "Restarting Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 2
    systemctl start waydroid-container 2>/dev/null || true
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    none)    clear_profile ;;
    *)       apply_profile "$1" ;;
esac
