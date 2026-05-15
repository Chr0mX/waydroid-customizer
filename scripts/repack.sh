#!/usr/bin/env bash
# scripts/repack.sh – Zip patched raw images for distribution
#
# Usage: repack.sh [vanilla|gapps|both]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/images.sh"

require_cmd zip sha256sum

# ─── Helpers ─────────────────────────────────────────────────────────────────
_raw_zip() {
    local raw_img="$1"
    local out_img_name="$2"  # e.g. system.img
    local zip_name="$3"      # e.g. waydroid-custom-...-VANILLA-...-system.zip
    local out_dir="$4"

    local staging="${out_dir}/${out_img_name}"
    local zip_out="${out_dir}/${zip_name}"

    log_info "Staging raw image: $out_img_name"
    cp "$raw_img" "$staging"

    log_info "Zipping: $zip_name"
    (cd "$out_dir" && zip "$zip_name" "$out_img_name")
    rm -f "$staging"

    local cksum
    cksum="$(sha256sum "$zip_out" | awk '{print $1}')"
    echo "$cksum  $zip_name" > "${zip_out}.sha256"
    log_ok "Artifact: $zip_name  sha256=${cksum}"
}

_repack_vendor() {
    local raw_img="${UNPACK_DIR}/vendor/vendor.img.raw"
    [[ -f "$raw_img" ]] || die "Patched vendor raw not found: $raw_img"

    local tag="${ARTIFACT_PREFIX}-${UPSTREAM_DATE}"
    local zip_name="${tag}-MAINLINE-${ARCH}-vendor.zip"
    _raw_zip "$raw_img" "vendor.img" "$zip_name" "$OUTPUT_DIR"
}

_repack_system() {
    local variant="$1"
    local raw_img="${UNPACK_DIR}/system-${variant}/system.img.raw"
    [[ -f "$raw_img" ]] || die "Patched system (${variant}) raw not found: $raw_img"

    local tag="${ARTIFACT_PREFIX}-${UPSTREAM_DATE}"
    local flavor
    case "$variant" in
        vanilla) flavor="VANILLA" ;;
        gapps)   flavor="GAPPS"   ;;
        *)       flavor="${variant^^}" ;;
    esac
    local zip_name="${tag}-${flavor}-${ARCH}-system.zip"
    _raw_zip "$raw_img" "system.img" "$zip_name" "$OUTPUT_DIR"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    ensure_dir "$OUTPUT_DIR"
    local target="${1:-${BUILD_VARIANT}}"
    log_step "Repack: $target"

    if [[ "${SKIP_VENDOR_REPACK:-0}" != "1" ]]; then
        _repack_vendor
    else
        log_info "Skipping vendor repack (SKIP_VENDOR_REPACK=1)."
    fi

    case "$target" in
        vanilla) _repack_system vanilla ;;
        gapps)   _repack_system gapps   ;;
        both|all)
            _repack_system vanilla
            _repack_system gapps
            ;;
        *) die "Unknown target: $target" ;;
    esac

    # Write a build manifest named per-variant to avoid asset-name collisions when
    # both vanilla and gapps artifacts are uploaded to the same GitHub release.
    local manifest="${OUTPUT_DIR}/manifest-${target}.json"
    python3 - "$OUTPUT_DIR" "$UPSTREAM_DATE" "$target" > "$manifest" <<'EOF'
import sys, os, json, hashlib, glob

out_dir, upstream_date, variant = sys.argv[1:]
artifacts = []
for f in sorted(glob.glob(os.path.join(out_dir, "*.zip"))):
    sha_file = f + ".sha256"
    sha = open(sha_file).read().split()[0] if os.path.exists(sha_file) else ""
    artifacts.append({
        "name": os.path.basename(f),
        "size": os.path.getsize(f),
        "sha256": sha
    })

manifest = {
    "upstream_date": upstream_date,
    "variant": variant,
    "artifacts": artifacts
}
print(json.dumps(manifest, indent=2))
EOF
    log_ok "Manifest written: $manifest"
    log_ok "All artifacts in: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/*.zip
}

main "$@"
