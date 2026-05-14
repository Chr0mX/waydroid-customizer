#!/usr/bin/env bash
# scripts/pipeline.sh – Full pipeline orchestrator
#
# Usage:
#   pipeline.sh [--variant vanilla|gapps|both] [--from-stage <stage>] [--dry-run]
#
# Stages (in order):
#   download → unpack → patch-vendor → patch-system → repack
#
# Each stage is idempotent. Use --from-stage to resume after a failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/versions.sh"

require_root
require_cmd mount umount losetup simg2img img2simg e2fsck unzip zip curl python3

# ─── Argument parsing ─────────────────────────────────────────────────────────
VARIANT="${BUILD_VARIANT:-both}"
FROM_STAGE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)    VARIANT="$2";     shift 2 ;;
        --from-stage) FROM_STAGE="$2";  shift 2 ;;
        --dry-run)    DRY_RUN=true;     shift   ;;
        --clean)
            log_info "Cleaning state and work directories…"
            rm -rf "${STATE_DIR}" "${UNPACK_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"
            log_ok "Clean complete."
            exit 0
            ;;
        -h|--help)
            echo "Usage: $0 [--variant vanilla|gapps|both] [--from-stage STAGE] [--dry-run] [--clean]"
            echo ""
            echo "Stages: download | unpack | patch-vendor | patch-system | repack"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

export BUILD_VARIANT="$VARIANT"

# ─── Stage definitions ────────────────────────────────────────────────────────
STAGES=(download unpack patch-vendor patch-system repack)

# Find start index when --from-stage is supplied
START_IDX=0
if [[ -n "$FROM_STAGE" ]]; then
    for i in "${!STAGES[@]}"; do
        if [[ "${STAGES[$i]}" == "$FROM_STAGE" ]]; then
            START_IDX=$i
            log_info "Resuming from stage: $FROM_STAGE"
            # Clear done markers from this stage onward
            for j in $(seq "$i" "$(( ${#STAGES[@]} - 1 ))"); do
                clear_stage "${STAGES[$j]}"
            done
            break
        fi
    done
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would run: $*"
        return 0
    fi
    "$@"
}

_patch_for_variant() {
    local v="$1"
    _run "${SCRIPT_DIR}/patch-system.sh" "$v"
}

# ─── Stage implementations ───────────────────────────────────────────────────
stage_download() {
    _run "${SCRIPT_DIR}/download.sh" "$VARIANT"
}

stage_unpack() {
    _run "${SCRIPT_DIR}/unpack.sh" "$VARIANT"
}

stage_patch_vendor() {
    _run "${SCRIPT_DIR}/patch-vendor.sh"
}

stage_patch_system() {
    case "$VARIANT" in
        vanilla) _patch_for_variant vanilla ;;
        gapps)   _patch_for_variant gapps   ;;
        both|all)
            _patch_for_variant vanilla
            _patch_for_variant gapps
            ;;
    esac
}

stage_repack() {
    _run "${SCRIPT_DIR}/repack.sh" "$VARIANT"
}

# ─── Main loop ────────────────────────────────────────────────────────────────
ensure_dir "$STATE_DIR" "$DOWNLOAD_DIR" "$UNPACK_DIR" "$MOUNT_DIR" "$OUTPUT_DIR"

log_step "Waydroid Image Pipeline"
log_info "Variant:   $VARIANT"
log_info "Work dir:  $WORK_DIR"
log_info "Spoof:     ${SPOOF_PROFILE}"
log_info "ARM trans: ${ARM_TRANSLATION_BACKEND}"

for i in $(seq "$START_IDX" "$(( ${#STAGES[@]} - 1 ))"); do
    stage="${STAGES[$i]}"
    fn="stage_${stage//-/_}"
    run_stage "$stage" "$fn"
done

# ─── Record build ─────────────────────────────────────────────────────────────
record_build "$VARIANT" "$UPSTREAM_DATE"

log_step "Pipeline Complete"
log_ok "Artifacts in: $OUTPUT_DIR"
