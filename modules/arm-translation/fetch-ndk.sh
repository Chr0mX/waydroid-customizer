#!/usr/bin/env bash
# modules/arm-translation/fetch-ndk.sh
#
# Downloads libndk_translation from the community ChromeOS-x86 vendor package.
# This is best-effort; if all candidates fail the caller (install.sh) falls
# back to "no ARM translation" gracefully.
#
# Usage: fetch-ndk.sh <output_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"

OUT_DIR="${1:?Usage: fetch-ndk.sh <output_dir>}"
CACHE_DIR="${DOWNLOAD_DIR:-/tmp}/ndk-translation-cache"

# Candidate archive URLs – tried in order; first 200 wins.
# Prefer branch archives over release tags so the source doesn't 404 when tags
# are deleted.  Override NDK_PKG_URL to pin a specific URL if desired.
_NDK_CANDIDATES=(
    # Commit-pinned prebuilt repo (Android 11 / libndk_translation)
    "https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt/archive/9324a8914b649b885dad6f2bfd14a67e5d1520bf.tar.gz"
)
if [[ -n "${NDK_PKG_URL:-}" ]]; then
    _NDK_CANDIDATES=("$NDK_PKG_URL" "${_NDK_CANDIDATES[@]}")
fi

# ─── Try each candidate URL ───────────────────────────────────────────────────
_fetch_archive() {
    local dest="$1"
    local url candidate
    for candidate in "${_NDK_CANDIDATES[@]}"; do
        log_info "Trying: $candidate"
        if curl -fsSL --max-time 120 --connect-timeout 20 \
                -o "$dest" "$candidate" 2>/dev/null; then
            log_ok "Downloaded from: $candidate"
            return 0
        fi
        log_warn "Failed (trying next): $candidate"
    done
    log_error "All NDK translation download candidates failed."
    return 1
}

# ─── Extract libndk_translation from archive ────────────────────────────────
_extract_libs() {
    local archive="$1"
    local extract_dir="$2"

    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir" --strip-components=1 2>/dev/null || {
        log_error "Failed to extract archive (may be corrupt)."
        return 1
    }

    local found=0
    for so in \
        "prebuilts/lib/libndk_translation.so" \
        "prebuilts/lib64/libndk_translation.so" \
        "prebuilts/etc/ndk_translation_config.xml"; do
        local full_src="${extract_dir}/${so}"
        if [[ -f "$full_src" ]]; then
            local rel="${so#prebuilts/}"
            mkdir -p "${OUT_DIR}/$(dirname "$rel")"
            cp -af "$full_src" "${OUT_DIR}/${rel}"
            log_info "Extracted: $rel"
            (( found++ )) || true
        fi
    done

    if (( found == 0 )); then
        log_error "No libndk_translation libraries found in archive."
        log_error "Archive layout may have changed – check the source repository."
        return 1
    fi
    return 0
}

main() {
    ensure_dir "$OUT_DIR" "$CACHE_DIR"

    local archive="${CACHE_DIR}/ndk_translation-main.tar.gz"

    if [[ ! -f "$archive" ]]; then
        _fetch_archive "$archive" || return 1
    else
        log_info "NDK translation archive already cached."
    fi

    local extract_dir="${CACHE_DIR}/ndk-main"
    _extract_libs "$archive" "$extract_dir" || {
        # Cached archive might be stale/corrupt – remove and retry once
        rm -f "$archive"
        rm -rf "$extract_dir"
        log_info "Retrying download after cache invalidation…"
        _fetch_archive "$archive" || return 1
        _extract_libs "$archive" "$extract_dir" || return 1
    }

    if [[ -f "${OUT_DIR}/lib64/libndk_translation.so" ]] || \
       [[ -f "${OUT_DIR}/lib/libndk_translation.so"   ]]; then
        log_ok "libndk_translation ready in $OUT_DIR"
        return 0
    fi

    log_error "libndk_translation not found after extraction."
    return 1
}

main
