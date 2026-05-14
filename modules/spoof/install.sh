#!/usr/bin/env bash
# modules/spoof/install.sh
#
# Injects device identity spoofing into a mounted Android image.
#
# Architecture:
#   • At build time: selected profile's properties are merged into build.prop
#     so the identity is stable from first boot.
#   • At runtime: an init service reads /data/waydroid-spoof/active.prop on
#     each boot and applies overrides via setprop, enabling profile switching
#     without rebuilding images.
#
# Usage:
#   install.sh <image_root> <system|vendor> <profile_name>
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/images.sh"

IMAGE_ROOT="${1:?Usage: install.sh <image_root> <system|vendor> <profile>}"
INSTALL_MODE="${2:-system}"
PROFILE_NAME="${3:-${SPOOF_PROFILE:-pixel-6a}}"

PROFILES_DIR="${MODULE_DIR}/profiles"
PROFILE_JSON="${PROFILES_DIR}/${PROFILE_NAME}.json"

[[ -f "$PROFILE_JSON" ]] || die "Spoof profile not found: $PROFILE_JSON"

# ─── Parse profile ────────────────────────────────────────────────────────────
_parse_profile() {
    python3 - "$PROFILE_JSON" <<'EOF'
import json, sys

profile = json.load(open(sys.argv[1]))
props = profile.get("props", {})
for k, v in props.items():
    print(f"{k}={v}")
EOF
}

# ─── Locate build.prop in image ──────────────────────────────────────────────
_find_build_prop() {
    local root="$1" mode="$2"
    case "$mode" in
        system)
            if   [[ -f "${root}/system/build.prop" ]]; then echo "${root}/system/build.prop"
            elif [[ -f "${root}/build.prop"         ]]; then echo "${root}/build.prop"
            else echo ""; fi
            ;;
        vendor)
            if   [[ -f "${root}/vendor/build.prop" ]]; then echo "${root}/vendor/build.prop"
            elif [[ -f "${root}/build.prop"         ]]; then echo "${root}/build.prop"
            else echo ""; fi
            ;;
    esac
}

# ─── System-side injection ────────────────────────────────────────────────────
_inject_system() {
    local root="$1"
    local build_prop
    build_prop="$(_find_build_prop "$root" "system")"

    if [[ -z "$build_prop" ]]; then
        log_warn "build.prop not found in system image root – skipping build-time spoof."
    else
        log_info "Merging spoof profile '${PROFILE_NAME}' → $(basename "$build_prop")"
        # Write a temp prop file from the JSON profile
        local tmp_props
        tmp_props="$(mktemp /tmp/spoof-XXXXXX.prop)"
        _parse_profile > "$tmp_props"
        merge_prop_file "$tmp_props" "$build_prop"
        rm -f "$tmp_props"
    fi

    # Inject the runtime spoof init RC
    inject_rc "${MODULE_DIR}/rc/waydroid-spoof.rc" "$root"

    # Inject the runtime spoof loader script
    mkdir -p "${root}/system/bin" 2>/dev/null || mkdir -p "${root}/bin"
    local bin_root
    bin_root="$( [[ -d "${root}/system/bin" ]] && echo "${root}/system/bin" || echo "${root}/bin" )"
    install -m 0755 "${MODULE_DIR}/scripts/spoof-loader.sh" "${bin_root}/waydroid-spoof-loader"
    log_info "Injected spoof-loader → /system/bin/waydroid-spoof-loader"

    # Copy all profiles into the image so the runtime loader can reference them
    local profiles_dest
    profiles_dest="$( [[ -d "${root}/system" ]] && echo "${root}/system/etc/waydroid/spoof/profiles" || echo "${root}/etc/waydroid/spoof/profiles" )"
    mkdir -p "$profiles_dest"
    cp -af "${PROFILES_DIR}/"*.json "$profiles_dest/" 2>/dev/null || true
    log_info "Profiles copied to $(basename "$(dirname "$profiles_dest")")/spoof/profiles/"
}

# ─── Vendor-side injection ────────────────────────────────────────────────────
_inject_vendor() {
    local root="$1"
    local build_prop
    build_prop="$(_find_build_prop "$root" "vendor")"

    if [[ -n "$build_prop" ]]; then
        log_info "Merging vendor spoof props '${PROFILE_NAME}' → $(basename "$build_prop")"
        local tmp_props
        tmp_props="$(mktemp /tmp/spoof-vendor-XXXXXX.prop)"
        _parse_profile | grep '^ro\.product\.' > "$tmp_props" || true
        [[ -s "$tmp_props" ]] && merge_prop_file "$tmp_props" "$build_prop"
        rm -f "$tmp_props"
    fi
}

# ─── Entry point ─────────────────────────────────────────────────────────────
main() {
    log_info "Spoof profile: ${PROFILE_NAME}  mode: ${INSTALL_MODE}"

    case "$INSTALL_MODE" in
        system) _inject_system "$IMAGE_ROOT" ;;
        vendor) _inject_vendor "$IMAGE_ROOT" ;;
        *) die "Unknown install mode: $INSTALL_MODE" ;;
    esac

    log_ok "Spoof injection complete (${PROFILE_NAME}, ${INSTALL_MODE})."
}

main
