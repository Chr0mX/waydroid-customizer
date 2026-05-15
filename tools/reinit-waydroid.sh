#!/usr/bin/env bash
# reinit-waydroid.sh – Reinitialize the Waydroid container using persisted OTA ZIPs.
#
# waydroid 1.4+ requires explicit -s (system OTA) and -v (vendor OTA) ZIP paths.
# Running bare `waydroid init` without these fails. This script provides them
# from the OTA ZIPs saved by install.sh, downloading them if not yet present.
#
# Usage:
#   sudo bash reinit-waydroid.sh [--release vDATE-custom]
#
# Options:
#   --release  vDATE-custom   Release tag to download ZIPs from (default: latest)
#   --variant  vanilla|gapps  Required only if OTA ZIPs are missing (default: gapps)
#   --help                    Show this help
set -euo pipefail

readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly OTA_DIR="/var/lib/waydroid/ota"
readonly TMP_DIR="/tmp/waydroid-reinit-$$"
readonly SYSTEM_ZIP_BYTES=$(( 450 * 1024 * 1024 ))
readonly VENDOR_ZIP_BYTES=$(( 200 * 1024 * 1024 ))

_ts()      { date '+%H:%M:%S'; }
log_info() { echo "[INFO]  $(_ts) $*" >&2; }
log_ok()   { echo "[OK]    $(_ts) $*" >&2; }
log_warn() { echo "[WARN]  $(_ts) $*" >&2; }
die()      { echo "[ERROR] $(_ts) $*" >&2; exit 1; }

RELEASE_TAG=""
VARIANT="gapps"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -18; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE_TAG="$2"; shift 2 ;;
        --variant) VARIANT="$2";     shift 2 ;;
        --help|-h) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"
command -v waydroid &>/dev/null || die "waydroid is not installed."

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

_download() {
    local url="$1" dest="$2"
    log_info "Downloading $(basename "$dest")…"
    curl -fL --progress-bar --connect-timeout 30 --max-time 600 "$url" -o "$dest" \
        || die "Download failed: $url"
    [[ -s "$dest" ]] || die "Downloaded file is empty: $dest"
}

_fetch_release_tag() {
    [[ -n "$RELEASE_TAG" ]] && return
    log_info "Fetching latest release…"
    local resp
    resp="$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" 2>/dev/null)" \
        || die "GitHub API request failed."
    RELEASE_TAG="$(printf '%s' "$resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)" \
        || die "Could not parse release tag — use --release vDATE-custom."
    log_ok "Latest release: $RELEASE_TAG"
}

_ensure_ota_zips() {
    if [[ -f "${OTA_DIR}/system.zip" && -f "${OTA_DIR}/vendor.zip" ]]; then
        log_info "Using persisted OTA ZIPs from ${OTA_DIR}."
        return 0
    fi

    log_warn "OTA ZIPs not found in ${OTA_DIR} — downloading from GitHub Releases."
    log_warn "(This happens once; ZIPs will be saved for future reinit.)"

    _fetch_release_tag

    local date_tag="${RELEASE_TAG#v}"
    date_tag="${date_tag%-custom}"
    local variant_upper="${VARIANT^^}"
    local base="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"
    local arch="waydroid_x86_64"

    mkdir -p "$TMP_DIR" "$OTA_DIR"

    local sys_zip="${TMP_DIR}/system.zip"
    local vnd_zip="${TMP_DIR}/vendor.zip"

    _download "${base}/waydroid-custom-${date_tag}-${variant_upper}-${arch}-system.zip" "$sys_zip"
    _download "${base}/waydroid-custom-${date_tag}-MAINLINE-${arch}-vendor.zip"         "$vnd_zip"

    cp -f "$sys_zip" "${OTA_DIR}/system.zip"
    cp -f "$vnd_zip"  "${OTA_DIR}/vendor.zip"
    log_ok "OTA ZIPs saved to ${OTA_DIR}."
}

main() {
    _ensure_ota_zips

    log_info "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 2

    rm -rf /var/lib/waydroid/lxc/waydroid
    log_info "Reinitializing Waydroid container…"
    waydroid init -f \
        -s "file://${OTA_DIR}/system.zip" \
        -v "file://${OTA_DIR}/vendor.zip" \
        || die "waydroid init failed."

    systemctl start waydroid-container 2>/dev/null || true
    log_ok "Done. Run: waydroid show-full-ui"
}

main "$@"
