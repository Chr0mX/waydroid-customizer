#!/usr/bin/env bash
# modules/widevine/install.sh
#
# Injects Widevine L3 DRM blobs into a mounted vendor image.
# Widevine L3 = software-only DRM; enables SD/HD playback on Netflix,
# Prime Video, Disney+, etc. L1 (hardware TEE) cannot be achieved in a
# container and is not attempted.
#
# If the blobs are not pre-staged in assets/ this script attempts to
# download them automatically (best-effort; non-fatal on failure).
#
# Usage: install.sh <vendor_image_root>
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/images.sh"

VENDOR_ROOT="${1:?Usage: install.sh <vendor_image_root>}"
WV_ASSET_DIR="${MODULE_DIR}/assets"

# ─── Asset availability ───────────────────────────────────────────────────────
_wv_available() {
    [[ -f "${WV_ASSET_DIR}/lib64/libwvhidl.so" ]] || \
    [[ -f "${WV_ASSET_DIR}/lib64/mediadrm/libwvdrmengine.so" ]]
}

_try_fetch_widevine() {
    local fetch_script="${MODULE_DIR}/fetch-widevine.sh"
    if [[ -x "$fetch_script" ]]; then
        log_info "Running Widevine fetch script…"
        bash "$fetch_script" "$WV_ASSET_DIR"
    else
        log_warn "fetch-widevine.sh not found or not executable."
        return 1
    fi
}

# ─── Injection ────────────────────────────────────────────────────────────────
_inject_widevine() {
    local root="$1"
    log_info "Injecting Widevine L3 blobs…"

    # Core DRM engine
    local wvhidl="${WV_ASSET_DIR}/lib64/libwvhidl.so"
    if [[ -f "$wvhidl" ]]; then
        inject_file "$wvhidl" "$root" "lib64/libwvhidl.so" 0755 root:root
    fi

    # MediaDRM plugin
    local wvdrm="${WV_ASSET_DIR}/lib64/mediadrm/libwvdrmengine.so"
    if [[ -f "$wvdrm" ]]; then
        inject_file "$wvdrm" "$root" "lib64/mediadrm/libwvdrmengine.so" 0755 root:root
    fi

    # VINTF HAL manifest — tells mediaserver the Widevine 1.3 HAL is present
    local manifest="${WV_ASSET_DIR}/etc/vintf/manifest/manifest_android.hardware.drm@1.3-service.widevine.xml"
    if [[ -f "$manifest" ]]; then
        inject_file "$manifest" "$root" \
            "etc/vintf/manifest/manifest_android.hardware.drm@1.3-service.widevine.xml" \
            0644 root:root
    fi

    log_ok "Widevine L3 injection complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    if ! _wv_available; then
        log_info "Widevine assets not pre-staged – attempting fetch…"
        _try_fetch_widevine || {
            log_warn "Widevine fetch failed. Skipping Widevine injection."
            return 0
        }
    fi

    if ! _wv_available; then
        log_warn "Widevine assets unavailable after fetch. Skipping injection."
        return 0
    fi

    _inject_widevine "$VENDOR_ROOT"
}

main
