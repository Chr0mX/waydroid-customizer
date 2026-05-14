#!/usr/bin/env bash
# modules/arm-translation/fetch-ndk.sh
#
# Downloads libndk_translation from the WayDroid community NDK package.
# This is a best-effort script; update NDK_PKG_URL if the upstream moves.
#
# Usage: fetch-ndk.sh <output_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"

OUT_DIR="${1:?Usage: fetch-ndk.sh <output_dir>}"

# NDK translation package – community-maintained build extracted from ChromeOS.
# Pin the version here for reproducibility; update via update-check workflow.
NDK_PKG_VERSION="${NDK_PKG_VERSION:-0.2.2}"
NDK_PKG_URL="${NDK_PKG_URL:-https://github.com/supremegamers/android_vendor_google_chromeos-x86/archive/refs/tags/v${NDK_PKG_VERSION}.tar.gz}"
NDK_PKG_SHA256="${NDK_PKG_SHA256:-}"   # Set to enforce integrity

CACHE_DIR="${DOWNLOAD_DIR:-/tmp}/ndk-translation-cache"

main() {
    ensure_dir "$OUT_DIR" "$CACHE_DIR"

    local archive="${CACHE_DIR}/ndk_translation-${NDK_PKG_VERSION}.tar.gz"

    if [[ ! -f "$archive" ]]; then
        log_info "Fetching libndk_translation v${NDK_PKG_VERSION}…"
        download_file "$NDK_PKG_URL" "$archive" "$NDK_PKG_SHA256"
    else
        log_info "NDK translation archive already cached."
    fi

    local extract_dir="${CACHE_DIR}/ndk-${NDK_PKG_VERSION}"
    if [[ ! -d "$extract_dir" ]]; then
        mkdir -p "$extract_dir"
        tar -xzf "$archive" -C "$extract_dir" --strip-components=1
    fi

    # Copy relevant files into OUT_DIR
    local src_lib="${extract_dir}/houdini"
    if [[ ! -d "$src_lib" ]]; then
        # Try alternate layout
        src_lib="${extract_dir}"
    fi

    for so in \
        "system/lib/libndk_translation.so" \
        "system/lib64/libndk_translation.so" \
        "system/etc/ndk_translation_config.xml"; do
        local full_src="${extract_dir}/${so}"
        if [[ -f "$full_src" ]]; then
            local rel="${so#system/}"
            mkdir -p "${OUT_DIR}/$(dirname "$rel")"
            cp -af "$full_src" "${OUT_DIR}/${rel}"
            log_info "Extracted: $rel"
        fi
    done

    if [[ -f "${OUT_DIR}/lib64/libndk_translation.so" ]] || \
       [[ -f "${OUT_DIR}/lib/libndk_translation.so"   ]]; then
        log_ok "libndk_translation ready in $OUT_DIR"
        return 0
    else
        log_error "NDK translation libraries not found in extracted archive."
        log_error "Check NDK_PKG_URL and update fetch-ndk.sh."
        return 1
    fi
}

main
