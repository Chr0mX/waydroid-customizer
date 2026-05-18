#!/usr/bin/env bash
# tools/set-spoof-profile.sh
#
# Apply, verify and manage Waydroid device spoof profiles.
# Works both locally (cloned repo) and online (piped from curl).
#
# Usage:
#   sudo bash set-spoof-profile.sh --list
#   sudo bash set-spoof-profile.sh --clear
#   sudo bash set-spoof-profile.sh <profile>
#   sudo bash set-spoof-profile.sh <profile> --check
#   sudo bash set-spoof-profile.sh <profile> --restart
#   sudo bash set-spoof-profile.sh <profile> --apply-and-check
#
# Flags (can be combined):
#   --list              List available profiles and exit.
#   --clear             Remove all spoof patches and restore originals.
#   --check             After applying, compare live getprop values against
#                       the profile. Exits non-zero on any mismatch or leak.
#   --restart           After applying, stop + restart the container and poll
#                       until Android reports ready (implies --check waits for
#                       a live session).
#   --apply-and-check   Shorthand for <profile> --restart --check.
#
# Online usage (run as root):
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/set-spoof-profile.sh \
#     | sudo bash -s -- samsung-s21 --apply-and-check
#
# Patching order:
#   1. vendor.img      – loop-mount/fuse2fs/e2cp (primary, direct inode patch)
#   2. system overlay  – /var/lib/waydroid/overlay/system/build.prop
#   3. waydroid_base.prop – fallback / belt-and-suspenders
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
readonly ACTIVE_KEYS_FILE="${WAYDROID_DIR}/waydroid-spoof-active-keys"
readonly VENDOR_IMG_BACKUP_SUFFIX=".spoof.bak"

# ── Global flags (set by arg parse) ──────────────────────────────────────────
PROFILE=""
DO_RESTART=0
DO_CHECK=0

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
        echo "  samsung-s21   Samsung Galaxy S21 Snapdragon (SM-G991U) – Android 11 / SDK 30"
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
    local name="$1"
    local candidates=(
        "/usr/share/waydroid-extra/images/${name}"
        "${WAYDROID_DIR}/images/${name}"
    )
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && echo "$p" && return 0
    done
    return 1
}

# ── Extract build.prop from an EXT4 image (no loop-mount) ────────────────────
# Tries /build.prop first, then /system/build.prop (system-as-root layout).
_extract_build_prop() {
    local img="$1" out="$2"
    debugfs -R 'cat /build.prop' "$img" > "$out" 2>/dev/null || true
    if [[ ! -s "$out" ]]; then
        debugfs -R 'cat /system/build.prop' "$img" > "$out" 2>/dev/null || true
    fi
    [[ -s "$out" ]]
}

# ── Patch build.prop lines (Python helper) ────────────────────────────────────
# Args: <json_file> <src_prop> <dst_prop> <keys_filter>
# keys_filter: empty = all props; comma-separated prefixes to restrict subset
# Prints the number of patched props to stdout.
_apply_prop_patch() {
    python3 - "$@" <<'PYEOF'
import sys, json

json_file, src_path, dst_path, keys_filter = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

profile = json.load(open(json_file))
props   = profile.get("props", {})

if keys_filter:
    prefixes = tuple(p for p in keys_filter.split(',') if p)
    props = {k: v for k, v in props.items() if k.startswith(prefixes)}

with open(src_path, "r", errors="replace") as f:
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

with open(dst_path, "w") as f:
    f.writelines(lines)

print(patched)
PYEOF
}

# ── Patch system partition via Waydroid overlayfs ────────────────────────────
_patch_system_overlay() {
    local img="$1" json_file="$2"

    local orig_tmp
    orig_tmp="$(mktemp /tmp/waydroid-orig-build-XXXXXX.prop)"
    _extract_build_prop "$img" "$orig_tmp" || { rm -f "$orig_tmp"; return 1; }

    mkdir -p "$OVERLAY_SYS"
    local dest="${OVERLAY_SYS}/build.prop"
    local n
    n="$(_apply_prop_patch "$json_file" "$orig_tmp" "$dest" "")"
    rm -f "$orig_tmp"
    log "system overlay build.prop: patched ${n} props"
}

# ── Patch vendor partition directly in vendor.img ────────────────────────────
# Waydroid bind-mounts vendor.img separately; files there are NOT covered by
# the overlayfs, so we must patch the image itself.
#
# Strategy (tried in order):
#   1. losetup + mount -t ext4  (most reliable when loop devices are available)
#   2. fuse2fs                  (FUSE-based ext4 mount, no kernel loop needed)
#   3. e2cp from e2tools        (direct inode-level copy into the image)
#
# A backup is created on first run so --clear can restore the original.
_patch_vendor_img() {
    local img="$1" json_file="$2"
    local backup="${img}${VENDOR_IMG_BACKUP_SUFFIX}"
    local filter="ro.product.vendor.,ro.soc.,ro.hardware,ro.vendor.build.,ro.boot."

    if [[ ! -f "$backup" ]]; then
        log "Backing up vendor.img → $(basename "$backup")…"
        cp "$img" "$backup"
    fi

    # Work on a /tmp copy to sidestep nodev/nosuid restrictions on source fs.
    local work_img mnt
    work_img="$(mktemp /tmp/waydroid-vendor-work-XXXXXX.img)"
    mnt="$(mktemp -d /tmp/waydroid-vnd-mnt-XXXXXX)"
    cp "$img" "$work_img"

    local method="" lodev=""

    # Method 1: losetup + mount
    if lodev="$(losetup --find --show "$work_img" 2>/dev/null)"; then
        if mount -t ext4 -o rw "$lodev" "$mnt" 2>/dev/null; then
            method="loop"
        else
            losetup --detach "$lodev" 2>/dev/null || true
            lodev=""
        fi
    fi

    # Method 2: fuse2fs
    if [[ -z "$method" ]] && command -v fuse2fs &>/dev/null; then
        if fuse2fs -o fakeroot,rw "$work_img" "$mnt" 2>/dev/null; then
            method="fuse2fs"
        fi
    fi

    # Mount-based edit
    if [[ -n "$method" ]]; then
        local prop_path="${mnt}/build.prop"
        local ok=0 n=0
        if [[ -f "$prop_path" ]]; then
            n="$(_apply_prop_patch "$json_file" "$prop_path" "$prop_path" "$filter")"
            ok=1
        fi
        sync
        if [[ "$method" == "fuse2fs" ]]; then
            fusermount -u "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
        else
            umount "$mnt" 2>/dev/null || true
            losetup --detach "$lodev" 2>/dev/null || true
        fi
        rmdir "$mnt" 2>/dev/null || true
        if [[ "$ok" -eq 1 ]]; then
            cp "$work_img" "$img"
            rm -f "$work_img"
            log "vendor.img build.prop: patched ${n} props (${method})"
            return 0
        fi
    else
        rmdir "$mnt" 2>/dev/null || true
    fi

    # Method 3: e2cp
    if command -v e2cp &>/dev/null; then
        local orig_tmp patched_tmp
        orig_tmp="$(mktemp /tmp/waydroid-vnd-orig-XXXXXX.prop)"
        patched_tmp="$(mktemp /tmp/waydroid-vnd-patched-XXXXXX.prop)"
        if e2cp "${work_img}:/build.prop" "$orig_tmp" 2>/dev/null; then
            local n
            n="$(_apply_prop_patch "$json_file" "$orig_tmp" "$patched_tmp" "$filter")"
            if e2cp "$patched_tmp" "${work_img}:/build.prop" 2>/dev/null; then
                cp "$work_img" "$img"
                rm -f "$work_img" "$orig_tmp" "$patched_tmp"
                log "vendor.img build.prop: patched ${n} props (e2cp)"
                return 0
            fi
        fi
        rm -f "$orig_tmp" "$patched_tmp"
    fi

    rm -f "$work_img"
    log "vendor.img patch: all methods failed – identity covered by property_source_order override"
    return 1
}

# ── Patch waydroid_base.prop (fallback) ───────────────────────────────────────
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
# $1 = profile name
# $2 = 1 (default) start container at end; 0 = skip (caller handles restart)
apply_profile() {
    local profile="$1"
    local start_after="${2:-1}"

    [[ -d "$WAYDROID_DIR" ]] \
        || die "${WAYDROID_DIR} not found. Run: sudo waydroid init"

    local json
    json="$(_resolve_profile_json "$profile")"

    log "Stopping Waydroid…"
    ( cd / && waydroid session stop 2>/dev/null ) || true
    ( cd / && systemctl stop waydroid-container 2>/dev/null ) || true
    sleep 1

    # Vendor first (primary – direct image patch)
    local vnd_img
    if vnd_img="$(_find_img vendor.img 2>/dev/null)"; then
        log "Patching vendor.img…"
        _patch_vendor_img "$vnd_img" "$json" \
            || log "vendor.img patch skipped – identity covered by source_order override"
    else
        log "vendor.img not found – skipping vendor patch"
    fi

    # System overlay
    local sys_img
    if sys_img="$(_find_img system.img 2>/dev/null)"; then
        log "Patching system overlay from ${sys_img}…"
        _patch_system_overlay "$sys_img" "$json" \
            || log "system overlay patch failed"
    else
        log "system.img not found – skipping system overlay patch"
    fi

    # Fallback: waydroid_base.prop
    log "Patching waydroid_base.prop…"
    _patch_base_prop "$json"

    # Clear Android's persistent property cache
    local prop_cache="${WAYDROID_DIR}/data/property/persistent_properties"
    if [[ -f "$prop_cache" ]]; then
        log "Clearing Android property cache…"
        rm -f "$prop_cache"
    fi

    # Clean up remote temp JSON
    [[ -z "$PROFILES_LOCAL" ]] && rm -f "$json" || true

    if [[ "$start_after" -eq 1 ]]; then
        log "Starting Waydroid container…"
        ( cd / && systemctl start waydroid-container 2>/dev/null ) || true
        ok "Profile '${profile}' applied."
        echo "  Start UI : waydroid show-full-ui" >&2
        echo "  Revert   : curl -fsSL ${REPO_RAW}/tools/set-spoof-profile.sh | sudo bash -s -- --clear" >&2
    fi
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

    log "Removing system overlay build.prop…"
    rm -f "${OVERLAY_SYS}/build.prop"

    local vnd_img vnd_bak
    if vnd_img="$(_find_img vendor.img 2>/dev/null)"; then
        vnd_bak="${vnd_img}${VENDOR_IMG_BACKUP_SUFFIX}"
        if [[ -f "$vnd_bak" ]]; then
            log "Restoring vendor.img from backup…"
            cp "$vnd_bak" "$vnd_img"
            rm -f "$vnd_bak"
        else
            log "No vendor.img backup found – vendor props may still be spoofed"
        fi
    fi

    log "Removing patches from waydroid_base.prop…"
    _remove_from_base_prop
    rm -f "$ACTIVE_KEYS_FILE"

    log "Starting Waydroid container…"
    ( cd / && systemctl start waydroid-container 2>/dev/null ) || true

    ok "Spoof cleared. Default identity will be used."
}

# ── Restart Waydroid session and wait for readiness ───────────────────────────
restart_waydroid_session() {
    local timeout=60

    log "Restarting Waydroid session…"
    ( cd / && waydroid session stop 2>/dev/null ) || true
    ( cd / && systemctl stop waydroid-container 2>/dev/null ) || true
    sleep 2
    ( cd / && systemctl start waydroid-container 2>/dev/null ) || true

    log "Polling for Android readiness (timeout ${timeout}s)…"
    local elapsed=0
    while (( elapsed < timeout )); do
        local ver
        ver="$( ( cd / && waydroid shell getprop ro.build.version.release 2>/dev/null ) \
                | tr -d '\r\n' )" || true
        if [[ -n "$ver" ]]; then
            ok "Android ready (version ${ver})."
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    die "Android did not become ready within ${timeout}s. Try: waydroid show-full-ui"
}

# ── Live getprop from running container ───────────────────────────────────────
_live_prop() {
    ( cd / && waydroid shell getprop "$1" 2>/dev/null ) | tr -d '\r' | head -1
}

# ── Spoof verification ────────────────────────────────────────────────────────
check_spoof_profile() {
    local json_file="$1"
    local profile_name="$2"

    local critical_keys=(
        ro.product.brand
        ro.product.manufacturer
        ro.product.device
        ro.product.model
        ro.product.name
        ro.product.system.brand
        ro.product.system.device
        ro.product.system.model
        ro.product.system.name
        ro.product.vendor.brand
        ro.product.vendor.device
        ro.product.vendor.model
        ro.product.vendor.name
        ro.build.fingerprint
        ro.system.build.fingerprint
        ro.vendor.build.fingerprint
        ro.build.tags
    )
    local optional_keys=(
        ro.product.board
        ro.hardware
        ro.bootloader
        gsm.version.baseband
        ro.boot.selinux
    )
    # Identity-related props scanned for emulator/stock leaks
    local leak_props=(
        ro.product.brand ro.product.manufacturer ro.product.device
        ro.product.model ro.product.name
        ro.product.system.brand ro.product.system.model ro.product.system.device
        ro.product.vendor.brand ro.product.vendor.model ro.product.vendor.device
        ro.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint
        ro.build.description ro.build.display.id ro.build.tags ro.build.type
    )
    local leak_pattern="pixel|lineage|waydroid|sdk_gphone|generic_x86|emulator|test-keys"

    # Load all expected values from JSON into a flat key=value map via Python
    local expected_flat
    expected_flat="$(python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
for k, v in p.get('props', {}).items():
    print(f'{k}\x1f{v}')
" "$json_file")"

    _expected_val() {
        # Print expected value for a key (empty string if not in profile)
        local key="$1"
        while IFS=$'\x1f' read -r k v; do
            [[ "$k" == "$key" ]] && { echo "$v"; return; }
        done <<< "$expected_flat"
        echo ""
    }

    # Print header
    printf '\n[check] ── Spoof verification: %s ──\n\n' "$profile_name" >&2
    printf '[check]  %-44s %-22s %-22s %s\n' \
        "Key" "Expected" "Actual" "Status" >&2
    printf '[check]  %s\n' "────────────────────────────────────────────────────────────────────────────────────────────────" >&2

    local critical_fails=0 critical_pass=0 opt_fails=0

    _check_one() {
        local key="$1" tier="$2"
        local expected actual status
        expected="$(_expected_val "$key")"
        actual="$(_live_prop "$key")"

        if [[ -z "$expected" ]]; then
            printf '[check]  %-44s %-22s %-22s %s\n' \
                "$key" "(not in profile)" "${actual:-(empty)}" "INFO" >&2
            return
        fi

        if [[ "$actual" == "$expected" ]]; then
            status="PASS"
            [[ "$tier" == "critical" ]] && critical_pass=$(( critical_pass + 1 ))
        else
            status="FAIL ✗"
            [[ "$tier" == "critical" ]] && critical_fails=$(( critical_fails + 1 ))
            [[ "$tier" == "optional" ]] && opt_fails=$(( opt_fails + 1 ))
        fi

        # Truncate long values for display
        local exp_disp act_disp
        exp_disp="${expected:0:21}"
        act_disp="${actual:0:21}"
        printf '[check]  %-44s %-22s %-22s %s\n' \
            "$key" "$exp_disp" "$act_disp" "$status" >&2
    }

    printf '[check]\n[check]  Critical keys:\n' >&2
    for k in "${critical_keys[@]}"; do _check_one "$k" "critical"; done

    printf '[check]\n[check]  Optional keys:\n' >&2
    for k in "${optional_keys[@]}"; do _check_one "$k" "optional"; done

    # Leak scan
    printf '\n[check]  Leak scan  (pattern: %s)\n' "$leak_pattern" >&2
    local leaks=0
    for k in "${leak_props[@]}"; do
        local v
        v="$(_live_prop "$k")"
        if [[ -n "$v" ]] && echo "$v" | grep -qiE "$leak_pattern" 2>/dev/null; then
            printf '[check]    LEAK  %-42s = %s\n' "$k" "$v" >&2
            leaks=$(( leaks + 1 ))
        fi
    done
    if (( leaks == 0 )); then
        printf '[check]    clean – no identity leaks detected\n' >&2
    fi

    # Summary
    printf '\n' >&2
    if (( critical_fails > 0 || leaks > 0 )); then
        printf '[check]  RESULT: FAILED  (%d critical mismatch(es), %d leak(s))\n' \
            "$critical_fails" "$leaks" >&2
        return 1
    else
        printf '[check]  RESULT: PASSED  (%d/%d critical keys matched, %d optional mismatch(es), 0 leaks)\n' \
            "$critical_pass" "${#critical_keys[@]}" "$opt_fails" >&2
        return 0
    fi
}

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    cat >&2 <<'EOF'
Usage: sudo bash set-spoof-profile.sh [--list | --clear | <profile> [flags]]

Flags:
  --list               List available profiles
  --clear              Remove all spoof patches and restore originals
  --check              Verify live getprop values match the profile after apply
  --restart            Restart Waydroid and poll until Android is ready
  --apply-and-check    Shorthand for <profile> --restart --check

Examples:
  sudo bash set-spoof-profile.sh samsung-s21
  sudo bash set-spoof-profile.sh samsung-s21 --check
  sudo bash set-spoof-profile.sh samsung-s21 --apply-and-check
  sudo bash set-spoof-profile.sh samsung-s21 --restart --check
  sudo bash set-spoof-profile.sh --clear
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    list_profiles
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)            list_profiles; exit 0 ;;
        --clear)           clear_profile; exit 0 ;;
        --help|-h)         show_help; exit 0 ;;
        --check)           DO_CHECK=1 ;;
        --restart)         DO_RESTART=1 ;;
        --apply-and-check) DO_CHECK=1; DO_RESTART=1 ;;
        --*)               die "Unknown flag: '$1'. Run with --help for usage." ;;
        *)
            [[ -z "$PROFILE" ]] \
                || die "Unexpected argument '$1' (profile already set to '${PROFILE}')."
            PROFILE="$1"
            ;;
    esac
    shift
done

[[ -n "$PROFILE" ]] || die "No profile specified. Run with --list to see available profiles."

# ── Main flow ─────────────────────────────────────────────────────────────────
# Resolve profile JSON once – reused by apply and check.
PROFILE_JSON="$(_resolve_profile_json "$PROFILE")"

# Apply (skip container start if we're about to restart with readiness poll)
apply_profile "$PROFILE" "$(( DO_RESTART == 0 ? 1 : 0 ))"

# Restart with readiness poll (handles container start when DO_RESTART=1)
if (( DO_RESTART )); then
    restart_waydroid_session
fi

# Verify live props
if (( DO_CHECK )); then
    check_spoof_profile "$PROFILE_JSON" "$PROFILE"
fi

# Clean up remote temp JSON (local profiles are not tmp files)
[[ -z "$PROFILES_LOCAL" ]] && rm -f "$PROFILE_JSON" || true

exit 0
