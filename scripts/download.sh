#!/usr/bin/env bash
# scripts/download.sh – Download upstream Waydroid images
#
# Usage: download.sh [vanilla|gapps|vendor|all]
#   Defaults to BUILD_VARIANT from pipeline.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

_download_vendor() {
    local dest="${DOWNLOAD_DIR}/${VENDOR_FILENAME}"
    if [[ -f "$dest" ]]; then
        log_info "Vendor image already downloaded: $dest"
    else
        download_file "$VENDOR_URL" "$dest" "$VENDOR_SHA256"
    fi
    log_ok "Vendor image ready: $(human_bytes "$(stat -c%s "$dest")")"
}

_download_system() {
    local variant="$1"
    local url filename sha
    case "$variant" in
        vanilla)
            url="$SYSTEM_VANILLA_URL"
            filename="$SYSTEM_VANILLA_FILENAME"
            sha="$SYSTEM_VANILLA_SHA256"
            ;;
        gapps)
            url="$SYSTEM_GAPPS_URL"
            filename="$SYSTEM_GAPPS_FILENAME"
            sha="$SYSTEM_GAPPS_SHA256"
            ;;
        *) die "Unknown system variant: $variant" ;;
    esac

    local dest="${DOWNLOAD_DIR}/${filename}"
    if [[ -f "$dest" ]]; then
        log_info "${variant} system image already downloaded: $dest"
    else
        download_file "$url" "$dest" "$sha"
    fi
    log_ok "${variant} system image ready: $(human_bytes "$(stat -c%s "$dest")")"
}

main() {
    ensure_dir "$DOWNLOAD_DIR"
    local target="${1:-${BUILD_VARIANT}}"

    log_step "Download: $target"
    _download_vendor

    case "$target" in
        vanilla) _download_system vanilla ;;
        gapps)   _download_system gapps   ;;
        both|all)
            _download_system vanilla
            _download_system gapps
            ;;
        *) die "Unknown target: $target (expected: vanilla | gapps | both)" ;;
    esac

    log_ok "All downloads complete."
}

main "$@"
