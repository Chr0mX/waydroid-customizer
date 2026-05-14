#!/usr/bin/env bash
# scripts/patch-vendor.sh – Patch the raw vendor image
#
# Applies:
#   1. ARM translation vendor-side files (libhoudini vendor path, fstab entries)
#   2. Device spoof vendor props
#   3. Generic vendor overlays from overlays/vendor/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/images.sh"

require_cmd mount umount e2fsck

main() {
    local raw_img="${UNPACK_DIR}/vendor/vendor.img.raw"
    [[ -f "$raw_img" ]] || die "Raw vendor image not found: $raw_img (run unpack.sh first)"

    local mnt="${MOUNT_DIR}/vendor"
    ensure_dir "$mnt"

    log_step "Patch vendor image"
    log_info "Image: $raw_img"

    e2fsck -fy "$raw_img" &>/dev/null || true

    mount_image "$raw_img" "$mnt"
    register_unmount "$mnt"

    # ── 1. Generic vendor overlays ──────────────────────────────────────────
    local overlay_dir="${REPO_ROOT}/overlays/vendor"
    if [[ -d "$overlay_dir" ]]; then
        log_info "Applying vendor overlays…"
        inject_dir "$overlay_dir" "$mnt" "/"
    fi

    # ── 2. ARM translation – vendor side ────────────────────────────────────
    if [[ "${ENABLE_ARM_TRANSLATION}" == "true" ]]; then
        "${REPO_ROOT}/modules/arm-translation/install.sh" "$mnt" "vendor"
    fi

    # ── 3. Widevine L3 DRM blobs ────────────────────────────────────────────
    if [[ "${ENABLE_WIDEVINE:-true}" == "true" ]]; then
        "${REPO_ROOT}/modules/widevine/install.sh" "$mnt"
    fi

    # ── 4. Device spoof – vendor props ──────────────────────────────────────
    if [[ "${ENABLE_SPOOF}" == "true" ]]; then
        "${REPO_ROOT}/modules/spoof/install.sh" "$mnt" "vendor" "${SPOOF_PROFILE}"
    fi

    unmount_image "$mnt"
    e2fsck -fy "$raw_img" &>/dev/null || true

    log_ok "Vendor patch complete."
}

main "$@"
