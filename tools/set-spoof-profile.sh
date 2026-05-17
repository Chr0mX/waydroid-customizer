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
# Properties are written directly to /var/lib/waydroid/waydroid_base.prop
# (replace-or-append per key). Waydroid is restarted to apply.
# Based on: https://github.com/Quackdoc/waydroid-scripts/blob/main/spoof-device.sh
#
set -euo pipefail

# ── Remote profile source ─────────────────────────────────────────────────────
readonly REPO_RAW="https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main"
readonly PROFILES_REMOTE="${REPO_RAW}/modules/spoof/profiles"
readonly PROFILES_API="https://api.github.com/repos/chr0mx/waydroid-customizer/contents/modules/spoof/profiles"

# ── Waydroid paths ────────────────────────────────────────────────────────────
WAYDROID_BASE_PROP="${WAYDROID_BASE_PROP:-/var/lib/waydroid/waydroid_base.prop}"
ACTIVE_KEYS_FILE="/var/lib/waydroid/waydroid-spoof-active-keys"

# ── Mode detection ────────────────────────────────────────────────────────────
# Determine if running from a local clone or piped from curl.
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
command -v python3 &>/dev/null || die "python3 is required."
command -v waydroid &>/dev/null || die "waydroid is not in PATH."

# ── Profile resolution ────────────────────────────────────────────────────────
# Returns the path to a profile JSON, fetching from GitHub if not local.
_resolve_profile_json() {
    local profile="$1"

    if [[ -n "$PROFILES_LOCAL" ]]; then
        local local_path="${PROFILES_LOCAL}/${profile}.json"
        [[ -f "$local_path" ]] || die "Profile not found: '${profile}' (looked in ${PROFILES_LOCAL})"
        echo "$local_path"
        return
    fi

    # Online: fetch to a temp file
    local tmp
    tmp="$(mktemp /tmp/waydroid-spoof-XXXXXX.json)"
    local url="${PROFILES_REMOTE}/${profile}.json"
    log "Fetching profile '${profile}' from GitHub…"
    curl -fsSL --http1.1 --connect-timeout 15 "$url" -o "$tmp" \
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

    # Online: fetch file listing from GitHub API, then each JSON for description
    local listing
    listing="$(curl -fsSL --http1.1 --connect-timeout 15 "$PROFILES_API" 2>/dev/null)" || {
        # API unreachable – show known profiles
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
        local tmp url desc
        tmp="$(mktemp /tmp/waydroid-spoof-XXXXXX.json)"
        url="${PROFILES_REMOTE}/${id}.json"
        curl -fsSL --http1.1 --connect-timeout 10 "$url" -o "$tmp" 2>/dev/null
        desc="$(python3 -c "import json; p=json.load(open('$tmp')); print(p.get('description',''))" 2>/dev/null || echo "")"
        rm -f "$tmp"
        printf "  %-22s  %s\n" "$id" "$desc"
    done <<< "$names"
}

# ── Write to waydroid_base.prop (replace-or-append) ──────────────────────────
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

index = {}
for i, line in enumerate(lines):
    stripped = line.rstrip("\n")
    if stripped and not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].strip()
        index[k] = i

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

# ── Remove props from waydroid_base.prop ─────────────────────────────────────
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

# ── Apply profile ─────────────────────────────────────────────────────────────
apply_profile() {
    local profile="$1"

    [[ -f "$WAYDROID_BASE_PROP" ]] \
        || die "waydroid_base.prop not found at ${WAYDROID_BASE_PROP}. Run: sudo waydroid init"

    local json
    json="$(_resolve_profile_json "$profile")"

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    log "Writing to waydroid_base.prop…"
    _write_to_base_prop "$json"

    # Clean up temp file if we fetched remotely
    [[ -z "$PROFILES_LOCAL" ]] && rm -f "$json" || true

    log "Starting Waydroid container…"
    systemctl start waydroid-container 2>/dev/null || true

    ok "Profile '${profile}' applied."
    echo "  Start UI : waydroid show-full-ui" >&2
    echo "  Revert   : $(basename "$0") --clear" >&2
}

# ── Clear profile ─────────────────────────────────────────────────────────────
clear_profile() {
    if [[ ! -f "$ACTIVE_KEYS_FILE" ]]; then
        log "No active spoof profile (${ACTIVE_KEYS_FILE} missing). Nothing to do."
        return 0
    fi

    log "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    log "Removing injected props from waydroid_base.prop…"
    _remove_from_base_prop

    rm -f "$ACTIVE_KEYS_FILE"

    log "Starting Waydroid container…"
    systemctl start waydroid-container 2>/dev/null || true

    ok "Spoof cleared. Default identity will be used."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:---list}" in
    --list)  list_profiles ;;
    --clear) clear_profile ;;
    *)       apply_profile "$1" ;;
esac
