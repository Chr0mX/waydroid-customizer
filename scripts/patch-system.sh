#!/usr/bin/env bash
# scripts/patch-system.sh – Patch a raw system image
#
# Usage: patch-system.sh <variant>   (vanilla | gapps)
#
# Applies:
#   1. ARM translation module
#   2. Device spoof module
#   3. Generic system overlays from overlays/system/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/images.sh"

require_cmd mount umount losetup e2fsck

main() {
    local variant="${1:-}"
    [[ -n "$variant" ]] || die "Usage: patch-system.sh <vanilla|gapps>"

    local raw_img="${UNPACK_DIR}/system-${variant}/system.img.raw"
    [[ -f "$raw_img" ]] || die "Raw system image not found: $raw_img (run unpack.sh first)"

    local mnt="${MOUNT_DIR}/system-${variant}"
    ensure_dir "$mnt"

    log_step "Patch system image: ${variant}"
    log_info "Image: $raw_img"

    # Integrity check before mounting
    e2fsck -fy "$raw_img" &>/dev/null || true

    mount_image "$raw_img" "$mnt"
    register_unmount "$mnt"

    # ── 1. Apply generic overlays ────────────────────────────────────────────
    local overlay_dir="${REPO_ROOT}/overlays/system"
    if [[ -d "$overlay_dir" ]]; then
        log_info "Applying system overlays…"
        inject_dir "$overlay_dir" "$mnt" "/"
    fi

    # ── 2. ARM translation ───────────────────────────────────────────────────
    if [[ "${ENABLE_ARM_TRANSLATION}" == "true" ]]; then
        log_info "Injecting ARM translation…"
        "${REPO_ROOT}/modules/arm-translation/install.sh" "$mnt"
    fi

    # ── 3. Device spoof ──────────────────────────────────────────────────────
    if [[ "${ENABLE_SPOOF}" == "true" ]]; then
        log_info "Applying device spoof profile: ${SPOOF_PROFILE}"
        "${REPO_ROOT}/modules/spoof/install.sh" "$mnt" "system" "${SPOOF_PROFILE}"
    fi

    # ── 4. SELinux context refresh ───────────────────────────────────────────
    # If a file_contexts exists, restore contexts so SELinux doesn't reject injected files.
    local fc
    for fc in \
        "${mnt}/system/etc/selinux/plat_file_contexts" \
        "${mnt}/etc/selinux/plat_file_contexts"; do
        if [[ -f "$fc" ]]; then
            log_info "Skipping restorecon (no host selinux tools expected in CI)"
            break
        fi
    done

    unmount_image "$mnt"
    # Repair filesystem after modifications
    e2fsck -fy "$raw_img" &>/dev/null || true

    log_ok "System patch complete: ${variant}"
}

main "$@"
