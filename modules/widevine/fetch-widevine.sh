#!/usr/bin/env bash
# modules/widevine/fetch-widevine.sh
#
# Downloads Widevine L3 DRM blobs for x86_64 / Android 11 (LineageOS 18.1).
# Widevine L3 is software-only DRM — L1 (hardware TEE) is impossible in a
# container and is NOT attempted here.
#
# Source: community ChromeOS-x86 vendor package (same origin as fetch-ndk.sh).
# Override WV_PKG_URL to pin a specific archive URL.
#
# Usage: fetch-widevine.sh <output_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"

OUT_DIR="${1:?Usage: fetch-widevine.sh <output_dir>}"
CACHE_DIR="${DOWNLOAD_DIR:-/tmp}/widevine-cache"

_WV_CANDIDATES=(
    "https://github.com/supremegamers/android_vendor_google_chromeos-x86/archive/refs/heads/main.tar.gz"
    "https://github.com/supremegamers/android_vendor_google_chromeos-x86/archive/refs/heads/lineage-18.1.tar.gz"
)
if [[ -n "${WV_PKG_URL:-}" ]]; then
    _WV_CANDIDATES=("$WV_PKG_URL" "${_WV_CANDIDATES[@]}")
fi

_fetch_archive() {
    local dest="$1"
    local candidate
    for candidate in "${_WV_CANDIDATES[@]}"; do
        log_info "Trying: $candidate"
        if curl -fsSL --max-time 120 --connect-timeout 20 \
                -o "$dest" "$candidate" 2>/dev/null; then
            log_ok "Downloaded from: $candidate"
            return 0
        fi
        log_warn "Failed (trying next): $candidate"
    done
    log_error "All Widevine download candidates failed."
    return 1
}

_extract_widevine() {
    local archive="$1"
    local extract_dir="$2"

    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir" --strip-components=1 2>/dev/null || {
        log_error "Failed to extract archive (may be corrupt)."
        return 1
    }

    local found=0

    # Widevine L3 shared libraries (x86_64)
    for so in \
        "vendor/lib64/libwvhidl.so" \
        "vendor/lib64/mediadrm/libwvdrmengine.so"; do
        local full_src="${extract_dir}/${so}"
        if [[ -f "$full_src" ]]; then
            local rel="${so#vendor/}"
            mkdir -p "${OUT_DIR}/$(dirname "$rel")"
            cp -af "$full_src" "${OUT_DIR}/${rel}"
            log_info "Extracted: $rel"
            (( found++ )) || true
        fi
    done

    # VINTF manifest for Widevine HAL (needed for mediaserver to load the plugin)
    local manifest_src="${extract_dir}/vendor/etc/vintf/manifest/manifest_android.hardware.drm@1.3-service.widevine.xml"
    if [[ -f "$manifest_src" ]]; then
        mkdir -p "${OUT_DIR}/etc/vintf/manifest"
        cp -af "$manifest_src" "${OUT_DIR}/etc/vintf/manifest/"
        log_info "Extracted: etc/vintf/manifest/manifest_android.hardware.drm@1.3-service.widevine.xml"
        (( found++ )) || true
    fi

    if (( found == 0 )); then
        log_error "No Widevine libraries found in archive."
        log_error "Archive layout may have changed – check the source repository."
        return 1
    fi
    return 0
}

main() {
    ensure_dir "$OUT_DIR" "$CACHE_DIR"

    local archive="${CACHE_DIR}/widevine-main.tar.gz"

    if [[ ! -f "$archive" ]]; then
        _fetch_archive "$archive" || return 1
    else
        log_info "Widevine archive already cached."
    fi

    local extract_dir="${CACHE_DIR}/widevine-main"
    _extract_widevine "$archive" "$extract_dir" || {
        rm -f "$archive"
        rm -rf "$extract_dir"
        log_info "Retrying download after cache invalidation…"
        _fetch_archive "$archive" || return 1
        _extract_widevine "$archive" "$extract_dir" || return 1
    }

    if [[ -f "${OUT_DIR}/lib64/libwvhidl.so" ]] || \
       [[ -f "${OUT_DIR}/lib64/mediadrm/libwvdrmengine.so" ]]; then
        log_ok "Widevine L3 blobs ready in $OUT_DIR"
        return 0
    fi

    log_error "Widevine blobs not found after extraction."
    return 1
}

main
