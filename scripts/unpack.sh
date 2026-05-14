#!/usr/bin/env bash
# scripts/unpack.sh – Unzip upstream images and convert to raw EXT4
#
# Usage: unpack.sh [vanilla|gapps|vendor|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/images.sh"

require_cmd unzip simg2img file

# ─── Helpers ─────────────────────────────────────────────────────────────────
_unpack_zip() {
    local zip="$1"
    local dest_dir="$2"
    local label="$3"

    ensure_dir "$dest_dir"
    log_info "Unpacking ${label}: $(basename "$zip")"

    # Only extract *.img files to avoid polluting the workspace
    unzip -o "$zip" "*.img" -d "$dest_dir" | grep -E 'inflating|extracting' || true
    log_ok "Unpacked ${label} → $dest_dir"
}

_prepare_raw() {
    local src_img="$1"
    local raw_img="$2"
    local extra_bytes="${3:-0}"

    if [[ ! -f "$src_img" ]]; then
        die "Image not found after unpack: $src_img"
    fi

    log_info "Image type: $(file -b "$src_img" | head -c80)"

    if is_sparse_image "$src_img"; then
        sparse_to_raw "$src_img" "$raw_img"
    else
        log_info "Image is already raw EXT4 – copying."
        cp "$src_img" "$raw_img"
    fi

    if (( extra_bytes > 0 )); then
        resize_raw_image "$raw_img" "$extra_bytes"
    fi
}

# ─── Per-component unpack ─────────────────────────────────────────────────────
_unpack_vendor() {
    local zip="${DOWNLOAD_DIR}/${VENDOR_FILENAME}"
    local unpack_dir="${UNPACK_DIR}/vendor"
    local raw="${unpack_dir}/vendor.img.raw"

    [[ -f "$zip" ]] || die "Vendor zip not found. Run download.sh first."

    _unpack_zip "$zip" "$unpack_dir" "vendor"
    _prepare_raw "${unpack_dir}/vendor.img" "$raw" "$VENDOR_EXTRA_BYTES"
    log_ok "Vendor raw image: $raw"
}

_unpack_system() {
    local variant="$1"
    local filename
    case "$variant" in
        vanilla) filename="$SYSTEM_VANILLA_FILENAME" ;;
        gapps)   filename="$SYSTEM_GAPPS_FILENAME"   ;;
        *) die "Unknown variant: $variant" ;;
    esac

    local zip="${DOWNLOAD_DIR}/${filename}"
    local unpack_dir="${UNPACK_DIR}/system-${variant}"
    local raw="${unpack_dir}/system.img.raw"

    [[ -f "$zip" ]] || die "System zip (${variant}) not found. Run download.sh first."

    _unpack_zip "$zip" "$unpack_dir" "system-${variant}"
    _prepare_raw "${unpack_dir}/system.img" "$raw" "$SYSTEM_EXTRA_BYTES"
    log_ok "System (${variant}) raw image: $raw"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    ensure_dir "$UNPACK_DIR"
    local target="${1:-${BUILD_VARIANT}}"
    log_step "Unpack: $target"

    _unpack_vendor

    case "$target" in
        vanilla) _unpack_system vanilla ;;
        gapps)   _unpack_system gapps   ;;
        both|all)
            _unpack_system vanilla
            _unpack_system gapps
            ;;
        *) die "Unknown target: $target" ;;
    esac

    log_ok "Unpack complete."
}

main "$@"
