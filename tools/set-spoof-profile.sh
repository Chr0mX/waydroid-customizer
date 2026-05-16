#!/usr/bin/env bash
# set-spoof-profile.sh – Apply a device spoof profile to Waydroid.
#
# Patches build.prop directly inside system.img and vendor.img so that
# ro.* properties take effect on next boot.  Works both as a local script
# and piped via curl — profiles are fetched from GitHub when the local
# repo is not present.
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
readonly SPOOF_DIR="${WAYDROID_DATA_DIR:-/var/lib/waydroid/data}/waydroid-spoof"
readonly WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"
readonly DEFAULT_IMAGES_DIR="/usr/share/waydroid-extra/images"

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

# ── Image path from waydroid.cfg ─────────────────────────────────────────────
_get_images_path() {
    python3 -c "
import configparser
cfg = configparser.ConfigParser()
cfg.read('${WAYDROID_CFG}')
print(cfg.get('waydroid', 'images_path', fallback='${DEFAULT_IMAGES_DIR}'))
" 2>/dev/null || echo "$DEFAULT_IMAGES_DIR"
}

# ── Loop-mount helpers ────────────────────────────────────────────────────────
_mount_image() {
    local img="$1" mnt="$2"
    [[ -f "$img" ]] || die "Image not found: $img"
    mkdir -p "$mnt"
    e2fsck -fy "$img" &>/dev/null || true
    mount -o loop,rw "$img" "$mnt" || die "Failed to mount $img"
}

_umount_image() {
    local mnt="$1"
    sync 2>/dev/null || true
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    rmdir  "$mnt" 2>/dev/null || true
}

_find_build_prop() {
    local root="$1" mode="$2"
    case "$mode" in
        system)
            if   [[ -f "${root}/system/build.prop" ]]; then echo "${root}/system/build.prop"
            elif [[ -f "${root}/build.prop"         ]]; then echo "${root}/build.prop"
            fi ;;
        vendor)
            if   [[ -f "${root}/vendor/build.prop" ]]; then echo "${root}/vendor/build.prop"
            elif [[ -f "${root}/build.prop"         ]]; then echo "${root}/build.prop"
            fi ;;
    esac
}

# ── Patch build.prop with profile props ──────────────────────────────────────
# Replaces matching keys in-place; appends any keys that are missing.
# JSON is piped via stdin; writes to a temp file then renames atomically
# so a failure mid-write never leaves build.prop in a corrupt state.
_patch_build_prop() {
    local prop_file="$1" json="$2"
    [[ -f "$prop_file" ]] || { warn "build.prop not found at $prop_file — skipping."; return 0; }
    local tmp="${prop_file}.spoof-tmp"
    printf '%s' "$json" | python3 - "$prop_file" "$tmp" <<'PYEOF'
import sys, json, os

prop_file = sys.argv[1]
tmp_file  = sys.argv[2]
props = json.load(sys.stdin).get("props", {})

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
    [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Patching produced empty build.prop — aborting to avoid corruption."; }
    mv "$tmp" "$prop_file"
    log "Patched: $(basename "$prop_file")"
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
    echo "  none              Remove active profile (revert to installed image default)"
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

    local images_path
    images_path="$(_get_images_path)"
    log "Images path: ${images_path}"

    local mnt_sys="/tmp/waydroid-spoof-sys-$$"
    local mnt_vnd="/tmp/waydroid-spoof-vnd-$$"
    # Ensure mounts are cleaned up on exit
    trap "_umount_image '${mnt_sys}'; _umount_image '${mnt_vnd}'" EXIT

    [[ -f "${images_path}/system.img" ]] || die "system.img not found in ${images_path}. Run the installer first."
    [[ -f "${images_path}/vendor.img" ]] || die "vendor.img not found in ${images_path}. Run the installer first."

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 5

    # ── Patch system.img ──────────────────────────────────────────────────────
    log "Mounting system.img…"
    _mount_image "${images_path}/system.img" "$mnt_sys"
    local bp_sys
    bp_sys="$(_find_build_prop "$mnt_sys" system)"
    _patch_build_prop "$bp_sys" "$json"
    _umount_image "$mnt_sys"

    # ── Patch vendor.img (ro.product.* only) ─────────────────────────────────
    local vendor_json
    vendor_json="$(printf '%s' "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['props'] = {k: v for k, v in d['props'].items() if k.startswith('ro.product.')}
print(json.dumps(d))
")"
    log "Mounting vendor.img…"
    _mount_image "${images_path}/vendor.img" "$mnt_vnd"
    local bp_vnd
    bp_vnd="$(_find_build_prop "$mnt_vnd" vendor)"
    _patch_build_prop "$bp_vnd" "$vendor_json"
    _umount_image "$mnt_vnd"

    trap - EXIT

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
    ok "Profile '${profile}' applied — build.prop patched in both images."
    echo "  Run: waydroid show-full-ui" >&2
}

clear_profile() {
    warn "--clear cannot undo build.prop patches already written to the images."
    warn "To restore the original profile, reinstall or re-run set-spoof-profile.sh <profile>."
    if [[ -f "${SPOOF_DIR}/active.prop" ]]; then
        rm "${SPOOF_DIR}/active.prop"
        ok "active.prop removed."
    else
        echo "No active.prop found." >&2
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    none)    clear_profile ;;
    *)       apply_profile "$1" ;;
esac
