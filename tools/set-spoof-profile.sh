#!/usr/bin/env bash
# tools/set-spoof-profile.sh
#
# Apply a Waydroid device spoof profile – works both locally (cloned repo)
# and online (piped from curl).
#
# Online usage (run as root):
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/set-spoof-profile.sh \
#     | sudo bash -s -- --list
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/set-spoof-profile.sh \
#     | sudo bash -s -- pixel-5
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/set-spoof-profile.sh \
#     | sudo bash -s -- --clear
#
# Local usage (from a cloned repo):
#   sudo bash tools/set-spoof-profile.sh <profile_name>
#   sudo bash tools/set-spoof-profile.sh --list
#   sudo bash tools/set-spoof-profile.sh --clear
#
# Props are patched into the overlay build.prop files so they load before
# the system image's build.prop (where ro.* locks happen). Also written to
# waydroid_base.prop as a belt-and-suspenders fallback.
#
set -euo pipefail

# ── Remote profile source ─────────────────────────────────────────────────────
readonly REPO_RAW="https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main"
readonly PROFILES_REMOTE="${REPO_RAW}/modules/spoof/profiles"
readonly PROFILES_API="https://api.github.com/repos/chr0mx/waydroid-customizer/contents/modules/spoof/profiles"

# ── Waydroid paths ────────────────────────────────────────────────────────────
readonly WAYDROID_DIR="/var/lib/waydroid"
WAYDROID_BASE_PROP="${WAYDROID_BASE_PROP:-${WAYDROID_DIR}/waydroid_base.prop}"
readonly OVERLAY_SYS="${WAYDROID_DIR}/overlay/system"
readonly OVERLAY_VND="${WAYDROID_DIR}/overlay/vendor"
readonly ACTIVE_KEYS_FILE="${WAYDROID_DIR}/waydroid-spoof-active-keys"

# ── Mode detection ────────────────────────────────────────────────────────────
_detect_local_profiles_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && "$src" != "/dev/stdin" && "$src" != "bash" ]]; then
        local candidate
        candidate="$(cd "$(dirname "$src")/../modules/spoof/profiles" 2>/dev/null && pwd || true)"
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    fi
    echo ""
}
PROFILES_LOCAL="$(_detect_local_profiles_dir)"

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[spoof] $*" >&2; }
ok()  { echo "[spoof] OK: $*" >&2; }
die() { echo "[spoof] ERROR: $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"
command -v python3  &>/dev/null || die "python3 is required."
command -v waydroid &>/dev/null || die "waydroid is not in PATH."
command -v debugfs  &>/dev/null || die "debugfs not found (install e2fsprogs)."

# ── Profile resolution ────────────────────────────────────────────────────────
_resolve_profile_json() {
    local profile="$1"
    if [[ -n "$PROFILES_LOCAL" ]]; then
        local local_path="${PROFILES_LOCAL}/${profile}.json"
        [[ -f "$local_path" ]] || die "Profile not found: '${profile}' (looked in ${PROFILES_LOCAL})"
        echo "$local_path"
        return
    fi
    local tmp
    tmp="$(mktemp /tmp/waydroid-spoof-XXXXXX.json)"
    log "Fetching profile '${profile}' from GitHub…"
    curl -fsSL --http1.1 --connect-timeout 15 \
        "${PROFILES_REMOTE}/${profile}.json" -o "$tmp" \
        || die "Profile '${profile}' not found. Check --list for valid names."
    echo "$tmp"
}

# ── List profiles ─────────────────────────────────────────────────────────────
list_profiles() {
    echo "Available spoof profiles:"
    if [[ -n "$PROFILES_LOCAL" ]]; then
        for f in "${PROFILES_LOCAL}"/*.json; do
            local id desc
            id="$(basename "$f" .json)"
            desc="$(python3 -c "import json; p=json.load(open('$f')); print(p.get('description',''))")"
            printf "  %-22s  %s\n" "$id" "$desc"
        done
        return
    fi
    local listing
    listing="$(curl -fsSL --http1.1 --connect-timeout 15 "$PROFILES_API" 2>/dev/null)" || {
        echo "  pixel-5       Google Pixel 5 (redfin) – Android 11 / SDK 30"
        echo "  pixel-4a      Google Pixel 4a (sunfish) – Android 11 / SDK 30"
        echo "  samsung-s21   Samsung Galaxy S21 (SM-G991B) – Android 11 / SDK 30"
        echo "  generic-x86   Minimal identity – hides LineageOS/emulator markers"
        return 0
    }
    local names
    names="$(python3 -c "
import json, sys
files = json.loads(sys.stdin.read())
for f in files:
    if f['name'].endswith('.json'):
        print(f['name'][:-5])
" <<< "$listing")"
    while IFS= read -r id; do
        local tmp desc
        tmp="$(mktemp /tmp/waydroid-spoof-XXXXXX.json)"
        curl -fsSL --http1.1 --connect-timeout 10 \
            "${PROFILES_REMOTE}/${id}.json" -o "$tmp" 2>/dev/null
        desc="$(python3 -c "import json; p=json.load(open('$tmp')); print(p.get('description',''))" 2>/dev/null || echo "")"
        rm -f "$tmp"
        printf "  %-22s  %s\n" "$id" "$desc"
    done <<< "$names"
}

# ── Find system/vendor images ─────────────────────────────────────────────────
_find_img() {
    local name="$1"   # system.img or vendor.img
    local candidates=(
        "/usr/share/waydroid-extra/images/${name}"
        "${WAYDROID_DIR}/images/${name}"
    )
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && echo "$p" && return 0
    done
    return 1
}

# ── Patch a build.prop via overlayfs ─────────────────────────────────────────
# Reads the original build.prop out of the EXT4 image using debugfs (no
# loop-mount needed), patches in the profile props, and writes the result
# to the Waydroid overlay directory so Android reads it before the image copy.
_patch_overlay_build_prop() {
    local img="$1"          # path to system.img or vendor.img
    local overlay_dir="$2"  # /var/lib/waydroid/overlay/system or .../vendor
    local json_file="$3"    # profile JSON
    local keys_filter="${4:-}"  # optional: only patch keys matching this prefix

    # Extract build.prop from image without mounting.
    # Try /build.prop first (vendor/traditional layout), then /system/build.prop
    # (system-as-root layout used by LineageOS 18.1).
    local orig_tmp
    orig_tmp="$(mktemp /tmp/waydroid-orig-build-XXXXXX.prop)"
    debugfs -R 'cat /build.prop' "$img" > "$orig_tmp" 2>/dev/null || true
    if [[ ! -s "$orig_tmp" ]]; then
        debugfs -R 'cat /system/build.prop' "$img" > "$orig_tmp" 2>/dev/null || true
    fi
    if [[ ! -s "$orig_tmp" ]]; then
        rm -f "$orig_tmp"; return 1
    fi

    mkdir -p "$overlay_dir"
    local dest="${overlay_dir}/build.prop"

    python3 - "$json_file" "$orig_tmp" "$dest" "$keys_filter" <<'PYEOF'
import sys, json

json_file, orig_path, dest_path, keys_filter = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

profile = json.load(open(json_file))
props   = profile.get("props", {})

# Optionally filter to a subset of keys (e.g. only "ro.product.vendor.")
if keys_filter:
    props = {k: v for k, v in props.items() if k.startswith(keys_filter)}

with open(orig_path, "r", errors="replace") as f:
    lines = f.readlines()

index = {}
for i, line in enumerate(lines):
    s = line.rstrip("\n")
    if s and not s.startswith("#") and "=" in s:
        index[s.split("=", 1)[0]] = i

patched = 0
for key, val in props.items():
    entry = f"{key}={val}\n"
    if key in index:
        lines[index[key]] = entry
    else:
        lines.append(entry)
        index[key] = len(lines) - 1
    patched += 1

with open(dest_path, "w") as f:
    f.writelines(lines)

print(f"[spoof] overlay {dest_path}: patched {patched} props", file=sys.stderr)
PYEOF
    rm -f "$orig_tmp"
}

# ── Patch waydroid_base.prop (replace-or-append, fallback) ───────────────────
_patch_base_prop() {
    local json_file="$1"
    [[ -f "$WAYDROID_BASE_PROP" ]] || touch "$WAYDROID_BASE_PROP"
    python3 - "$json_file" "$WAYDROID_BASE_PROP" "$ACTIVE_KEYS_FILE" <<'PYEOF'
import sys, json

json_file, prop_path, keys_out = sys.argv[1], sys.argv[2], sys.argv[3]

profile = json.load(open(json_file))
props   = profile.get("props", {})

with open(prop_path, "r") as f:
    lines = f.readlines()

index = {}
for i, line in enumerate(lines):
    s = line.rstrip("\n")
    if s and not s.startswith("#") and "=" in s:
        index[s.split("=", 1)[0]] = i

for key, val in props.items():
    entry = f"{key}={val}\n"
    if key in index:
        lines[index[key]] = entry
    else:
        lines.append(entry)
        index[key] = len(lines) - 1

with open(prop_path, "w") as f:
    f.writelines(lines)

with open(keys_out, "w") as f:
    f.write("\n".join(props.keys()) + "\n")

print(f"[spoof] base.prop: patched {len(props)} props", file=sys.stderr)
PYEOF
}

# ── Remove from waydroid_base.prop ────────────────────────────────────────────
_remove_from_base_prop() {
    [[ -f "$WAYDROID_BASE_PROP" ]] || return 0
    python3 - "$ACTIVE_KEYS_FILE" "$WAYDROID_BASE_PROP" <<'PYEOF'
import sys

keys_file, prop_path = sys.argv[1], sys.argv[2]

with open(keys_file) as f:
    keys = set(l.strip() for l in f if l.strip())

with open(prop_path, "r") as f:
    lines = f.readlines()

kept, removed = [], 0
for line in lines:
    s = line.rstrip("\n")
    if s and not s.startswith("#") and "=" in s and s.split("=", 1)[0] in keys:
        removed += 1
        continue
    kept.append(line)

with open(prop_path, "w") as f:
    f.writelines(kept)

print(f"[spoof] base.prop: removed {removed} props", file=sys.stderr)
PYEOF
}

# ── Apply profile ─────────────────────────────────────────────────────────────
apply_profile() {
    local profile="$1"

    [[ -d "$WAYDROID_DIR" ]] \
        || die "${WAYDROID_DIR} not found. Run: sudo waydroid init"

    local json
    json="$(_resolve_profile_json "$profile")"

    log "Stopping Waydroid…"
    ( cd / && waydroid session stop 2>/dev/null ) || true
    ( cd / && systemctl stop waydroid-container 2>/dev/null ) || true
    sleep 1

    # ── Primary: patch overlay build.prop files (loads before image build.prop)
    local sys_img vnd_img
    if sys_img="$(_find_img system.img 2>/dev/null)"; then
        log "Patching system overlay build.prop from ${sys_img}…"
        _patch_overlay_build_prop "$sys_img" "$OVERLAY_SYS" "$json" "" \
            || log "system overlay patch failed – falling back to base.prop only"
    else
        log "system.img not found – skipping overlay patch"
    fi

    if vnd_img="$(_find_img vendor.img 2>/dev/null)"; then
        log "Patching vendor overlay build.prop from ${vnd_img}…"
        _patch_overlay_build_prop "$vnd_img" "$OVERLAY_VND" "$json" "ro.product.vendor." \
            || log "vendor overlay patch failed (non-fatal)"
    fi

    # ── Fallback: waydroid_base.prop (works if image has no baked identity)
    log "Patching waydroid_base.prop…"
    _patch_base_prop "$json"

    # Clean up temp file if fetched remotely
    [[ -z "$PROFILES_LOCAL" ]] && rm -f "$json" || true

    log "Starting Waydroid container…"
    ( cd / && systemctl start waydroid-container 2>/dev/null ) || true

    ok "Profile '${profile}' applied."
    echo "  Start UI : waydroid show-full-ui" >&2
    echo "  Revert   : curl -fsSL ${REPO_RAW}/tools/set-spoof-profile.sh | sudo bash -s -- --clear" >&2
}

# ── Clear profile ─────────────────────────────────────────────────────────────
clear_profile() {
    if [[ ! -f "$ACTIVE_KEYS_FILE" ]]; then
        log "No active spoof profile (${ACTIVE_KEYS_FILE} missing). Nothing to do."
        return 0
    fi

    log "Stopping Waydroid…"
    ( cd / && waydroid session stop 2>/dev/null ) || true
    ( cd / && systemctl stop waydroid-container 2>/dev/null ) || true
    sleep 1

    log "Removing overlay build.prop patches…"
    rm -f "${OVERLAY_SYS}/build.prop" "${OVERLAY_VND}/build.prop"

    log "Removing patches from waydroid_base.prop…"
    _remove_from_base_prop
    rm -f "$ACTIVE_KEYS_FILE"

    log "Starting Waydroid container…"
    ( cd / && systemctl start waydroid-container 2>/dev/null ) || true

    ok "Spoof cleared. Default identity will be used."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    *)       apply_profile "$1" ;;
esac
