#!/usr/bin/env bash
# install.sh — Waydroid installer
#
# Downloads custom LineageOS 18.1 images from GitHub Releases, places them in
# the waydroid preinstalled-images path, initialises the container, then layers
# NDK translation and Widevine L3 as overlay modules (casualsnek style).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/install.sh \
#     | sudo bash -s -- [OPTIONS]
#
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --variant gapps|vanilla   Image variant (default: gapps)
#   --release <tag>           Specific release tag (default: latest)
#   --yes                     Non-interactive; accept all prompts
#   --help                    Show this help
#
# Supported distros: Ubuntu/Debian (apt), Fedora (dnf + Copr), Arch (AUR)
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly RELEASE_API="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
readonly RELEASE_BASE="https://github.com/${RELEASE_REPO}/releases/download"

# NDK translation — Android 11 x86_64 (supremegamers prebuilt, commit-pinned)
readonly NDK_URL="https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt/archive/9324a8914b649b885dad6f2bfd14a67e5d1520bf.zip"
readonly NDK_MD5="c9572672d1045594448068079b34c350"

# Widevine L3 — Android 11 x86_64 (supremegamers prebuilt, commit-pinned)
readonly WV_URL="https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/archive/48d1076a570837be6cdce8252d5d143363e37cc1.zip"
readonly WV_MD5="f587b8859f9071da4bca6cea1b9bed6a"

readonly IMAGES_DIR="/usr/share/waydroid-extra/images"
readonly OVERLAY_SYS="/var/lib/waydroid/overlay/system"
readonly OVERLAY_VND="/var/lib/waydroid/overlay/vendor"
readonly WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"
readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/waydroid-customizer"
readonly TMP_DIR="/tmp/waydroid-install-$$"

# ── Globals ────────────────────────────────────────────────────────────────────
VARIANT="gapps"
RELEASE_TAG=""
YES=0
DISTRO_FAMILY=""  # set by preflight()

# ── Logging ────────────────────────────────────────────────────────────────────
_ts()     { date '+%H:%M:%S'; }
log_info(){ echo "[INFO]  $(_ts) $*" >&2; }
log_ok()  { echo "[OK]    $(_ts) $*" >&2; }
log_warn(){ echo "[WARN]  $(_ts) $*" >&2; }
die()     { echo "[ERROR] $(_ts) $*" >&2; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────────
require_cmd() {
    local cmd="$1" hint="${2:-}"
    command -v "$cmd" &>/dev/null || die "'$cmd' not found.${hint:+ Hint: $hint}"
}

_sha256() { sha256sum "$1" | awk '{print $1}'; }
_md5()    { md5sum    "$1" | awk '{print $1}'; }

_json_field() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print(${1})" 2>/dev/null
}

# Write a key=value into waydroid.cfg [properties] section.
_set_waydroid_prop() {
    local key="$1" val="$2"
    [[ -f "$WAYDROID_CFG" ]] || return 0
    python3 - "$key" "$val" "$WAYDROID_CFG" <<'PYEOF'
import sys, configparser
key, val, cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = configparser.ConfigParser()
cfg.read(cfg_path)
if "properties" not in cfg:
    cfg["properties"] = {}
cfg["properties"][key] = val
with open(cfg_path, "w") as f:
    cfg.write(f)
PYEOF
}

# ── Download with retry ────────────────────────────────────────────────────────
_download() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"

    local attempt=0 wait=5
    while (( attempt < 3 )); do
        (( attempt++ )) || true
        log_info "Downloading $(basename "$dest") (attempt $attempt/3)…"
        if curl -fL --http1.1 --progress-bar --connect-timeout 30 --max-time 900 \
                "$url" -o "$dest" 2>&1; then
            [[ -s "$dest" ]] && return 0
            log_warn "Downloaded file is empty."
            rm -f "$dest"
        fi
        log_warn "Download failed. Retrying in ${wait}s…"
        sleep "$wait"; (( wait *= 2 ))
    done
    die "Download failed after 3 attempts: $url"
}

# Download + verify SHA256 checksum file.
_download_verified() {
    local url="$1" dest="$2"
    _download "$url"          "$dest"
    _download "${url}.sha256" "${dest}.sha256"

    local expected actual
    expected="$(awk '{print $1}' "${dest}.sha256")"
    actual="$(_sha256 "$dest")"
    [[ "$expected" == "$actual" ]] \
        || die "SHA256 mismatch for $(basename "$dest"). Expected: $expected  Got: $actual"
    log_ok "Verified: $(basename "$dest")"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

    if [[ ! -t 0 ]]; then
        log_info "Non-interactive stdin detected — enabling --yes mode."
        YES=1
    fi

    local os_id os_id_like
    os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
    os_id_like="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"

    case " ${os_id} ${os_id_like} " in
        *" fedora "*|*" rhel "*|*" centos "*)  DISTRO_FAMILY="fedora" ;;
        *" debian "*|*" ubuntu "*)             DISTRO_FAMILY="debian" ;;
        *" arch "*)                            DISTRO_FAMILY="arch"   ;;
        *)
            log_warn "Unrecognised distro '${os_id}' — assuming Debian/Ubuntu."
            DISTRO_FAMILY="debian"
            ;;
    esac

    local pretty
    pretty="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-$os_id}")"
    log_info "Detected distro family: ${DISTRO_FAMILY} (${pretty})"
}

# ── Dependencies ──────────────────────────────────────────────────────────────
install_deps() {
    local pkgs=()
    command -v curl    &>/dev/null || pkgs+=(curl)
    command -v unzip   &>/dev/null || pkgs+=(unzip)
    command -v python3 &>/dev/null || pkgs+=(python3)

    # e2fsck/simg2img needed for sparse-image conversion
    command -v e2fsck  &>/dev/null || pkgs+=(e2fsprogs)
    case "$DISTRO_FAMILY" in
        debian) command -v simg2img &>/dev/null || pkgs+=(android-sdk-libsparse-utils) ;;
        fedora) command -v simg2img &>/dev/null || pkgs+=(android-tools) ;;
        arch)   command -v simg2img &>/dev/null || pkgs+=(android-tools) ;;
    esac

    [[ "${#pkgs[@]}" -eq 0 ]] && return 0
    log_info "Installing dependencies: ${pkgs[*]}"
    case "$DISTRO_FAMILY" in
        debian) apt-get install -y -qq "${pkgs[@]}" ;;
        fedora) dnf install -y -q  "${pkgs[@]}" ;;
        arch)   pacman -S --noconfirm --needed "${pkgs[@]}" ;;
    esac
}

# ── Waydroid package ──────────────────────────────────────────────────────────
install_waydroid() {
    if command -v waydroid &>/dev/null; then
        log_info "Waydroid already installed ($(waydroid --version 2>/dev/null || echo '?'))."
        return 0
    fi

    log_info "Installing Waydroid…"
    case "$DISTRO_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq curl ca-certificates gnupg
            curl -fsSL --http1.1 https://repo.waydro.id/waydroid.gpg \
                | gpg --dearmor -o /usr/share/keyrings/waydroid.gpg
            local codename
            codename="$(. /etc/os-release 2>/dev/null; \
                printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-focal}}")"
            echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ ${codename} main" \
                > /etc/apt/sources.list.d/waydroid.list
            apt-get update -qq
            apt-get install -y -qq waydroid
            ;;
        fedora)
            command -v dnf-plugins-core &>/dev/null \
                || dnf install -y -q dnf-plugins-core
            dnf copr enable -y aleasto/waydroid
            dnf install -y -q waydroid
            ;;
        arch)
            local aur_cmd
            aur_cmd="$(command -v yay 2>/dev/null || command -v paru 2>/dev/null || true)"
            [[ -n "$aur_cmd" ]] || die "AUR helper (yay or paru) is required on Arch."
            local real_user="${SUDO_USER:-${USER:-root}}"
            sudo -u "$real_user" "$aur_cmd" -S --noconfirm waydroid
            ;;
    esac
    log_ok "Waydroid installed."
}

# ── Resolve release tag ────────────────────────────────────────────────────────
resolve_release() {
    if [[ -n "$RELEASE_TAG" ]]; then
        log_info "Using release: ${RELEASE_TAG}"
        return 0
    fi
    log_info "Fetching latest release from ${RELEASE_REPO}…"
    local api_response
    api_response="$(curl -fsSL --http1.1 --connect-timeout 15 "$RELEASE_API" 2>/dev/null)" \
        || die "GitHub API request failed."
    RELEASE_TAG="$(printf '%s' "$api_response" | _json_field "d['tag_name']")"
    [[ -n "$RELEASE_TAG" ]] || die "Could not parse release tag from GitHub API."
    log_ok "Latest release: ${RELEASE_TAG}"
}

# ── Download & install custom images ─────────────────────────────────────────
install_images() {
    local date_tag="${RELEASE_TAG#v}"   # v20250628-custom → 20250628-custom
    date_tag="${date_tag%%-*}"          # 20250628-custom  → 20250628

    local variant_upper="${VARIANT^^}"  # gapps → GAPPS
    local arch="waydroid_x86_64"

    local sys_name="waydroid-custom-${date_tag}-${variant_upper}-${arch}-system.zip"
    local vnd_name="waydroid-custom-${date_tag}-MAINLINE-${arch}-vendor.zip"
    local base_url="${RELEASE_BASE}/${RELEASE_TAG}"

    local sys_zip="${CACHE_DIR}/${sys_name}"
    local vnd_zip="${CACHE_DIR}/${vnd_name}"

    _download_verified "${base_url}/${sys_name}" "$sys_zip"
    _download_verified "${base_url}/${vnd_name}" "$vnd_zip"

    log_info "Extracting images to ${IMAGES_DIR}…"
    mkdir -p "$IMAGES_DIR"

    # Extract and convert sparse → raw ext4 if needed
    _extract_image "$sys_zip" "${IMAGES_DIR}/system.img"
    _extract_image "$vnd_zip" "${IMAGES_DIR}/vendor.img"

    log_ok "Images installed to ${IMAGES_DIR}."
}

# Extract the .img from a release zip, converting from sparse ext4 if needed.
_extract_image() {
    local zip_file="$1" dest_img="$2"
    local img_name
    img_name="$(basename "$dest_img")"

    local extract_dir="${TMP_DIR}/img-extract"
    mkdir -p "$extract_dir"

    log_info "Extracting ${img_name}…"
    unzip -q "$zip_file" "*.img" -d "$extract_dir"

    local raw_img
    raw_img="$(find "$extract_dir" -name "*.img" | head -1)"
    [[ -f "$raw_img" ]] || die "No .img found inside $(basename "$zip_file")."

    # Detect Android sparse image (magic: 3aff26ed)
    local magic
    magic="$(od -A n -t x1 -N 4 "$raw_img" | tr -d ' \n')"
    if [[ "$magic" == "3aff26ed" ]]; then
        log_info "Converting sparse → raw ext4…"
        simg2img "$raw_img" "$dest_img"
    else
        mv "$raw_img" "$dest_img"
    fi

    rm -rf "$extract_dir"
}

# ── Init waydroid container ───────────────────────────────────────────────────
init_waydroid() {
    # Enable overlayfs so NDK/Widevine stay separate from base images.
    waydroid prop set mount_overlays 1 2>/dev/null \
        || _set_waydroid_prop "mount_overlays" "True"

    log_info "Initialising Waydroid container…"
    # Images are in IMAGES_DIR (a preinstalled_images_path waydroid checks),
    # so waydroid init needs no -s/-v OTA flags.
    waydroid init -f \
        || die "waydroid init failed. Check logs: sudo journalctl -u waydroid-container"
    log_ok "Waydroid initialised."
}

# ── Fix binder protocol for Android 11 ────────────────────────────────────────
# Android 11 (LineageOS 18.1) only supports up to aidl2; waydroid init writes
# aidl3 on recent waydroid versions, causing servicemanager to never appear.
fix_binder_protocol() {
    [[ -f "$WAYDROID_CFG" ]] || return 0
    log_info "Setting binder protocol to aidl2 (required for Android 11)…"
    python3 - "$WAYDROID_CFG" <<'PYEOF'
import sys, configparser
cfg_path = sys.argv[1]
cfg = configparser.ConfigParser()
cfg.read(cfg_path)
section = "waydroid"
if section not in cfg:
    cfg[section] = {}
cfg[section]["binder_protocol"] = "aidl2"
cfg[section]["service_manager_protocol"] = "aidl2"
with open(cfg_path, "w") as f:
    cfg.write(f)
PYEOF
    log_ok "binder_protocol = aidl2, service_manager_protocol = aidl2"
}

# ── Overlay helpers ────────────────────────────────────────────────────────────
_install_prebuilt_overlay() {
    local url="$1" md5="$2" cache_name="$3" overlay_dir="$4"

    local cache_file="${CACHE_DIR}/${cache_name}"

    # Cache hit check
    if [[ -f "$cache_file" && "$(_md5 "$cache_file")" == "$md5" ]]; then
        log_info "Cache hit: ${cache_name}"
    else
        _download "$url" "$cache_file"
        [[ "$(_md5 "$cache_file")" == "$md5" ]] \
            || die "MD5 mismatch for ${cache_name}."
    fi

    local extract_dir="${TMP_DIR}/${cache_name%.zip}"
    mkdir -p "$extract_dir" "$overlay_dir"

    log_info "Extracting ${cache_name}…"
    unzip -q "$cache_file" "*/prebuilts/*" -d "$extract_dir"

    local prebuilts
    prebuilts="$(find "$extract_dir" -maxdepth 2 -name "prebuilts" -type d | head -1)"
    [[ -d "$prebuilts" ]] || die "prebuilts/ not found inside ${cache_name}."

    cp -af "${prebuilts}/." "$overlay_dir/"
    rm -rf "$extract_dir"
}

# ── NDK translation ────────────────────────────────────────────────────────────
install_ndk() {
    log_info "Installing libndk_translation (ARM → x86 bridge)…"
    _install_prebuilt_overlay "$NDK_URL" "$NDK_MD5" "ndk-translation.zip" "$OVERLAY_SYS"

    local -A ndk_props=(
        [ro.product.cpu.abilist]="x86_64,x86,arm64-v8a,armeabi-v7a,armeabi"
        [ro.product.cpu.abilist32]="x86,armeabi-v7a,armeabi"
        [ro.product.cpu.abilist64]="x86_64,arm64-v8a"
        [ro.dalvik.vm.native.bridge]="libndk_translation.so"
        [ro.enable.native.bridge.exec]="1"
        [ro.vendor.enable.native.bridge.exec]="1"
        [ro.vendor.enable.native.bridge.exec64]="1"
        [ro.ndk_translation.version]="0.2.3"
        [ro.dalvik.vm.isa.arm]="x86"
        [ro.dalvik.vm.isa.arm64]="x86_64"
    )
    for key in "${!ndk_props[@]}"; do
        _set_waydroid_prop "$key" "${ndk_props[$key]}"
    done

    log_ok "NDK translation installed."
}

# ── Widevine L3 ───────────────────────────────────────────────────────────────
install_widevine() {
    log_info "Installing Widevine L3…"
    _install_prebuilt_overlay "$WV_URL" "$WV_MD5" "widevine.zip" "$OVERLAY_VND"
    log_ok "Widevine L3 installed."
}

# ── Apply overlays ────────────────────────────────────────────────────────────
apply_overlays() {
    log_info "Applying overlays (waydroid upgrade --offline)…"
    waydroid upgrade --offline 2>/dev/null \
        || log_warn "waydroid upgrade --offline returned non-zero (may be harmless)."
}

# ── Start ─────────────────────────────────────────────────────────────────────
start_waydroid() {
    log_info "Enabling and starting waydroid-container service…"
    systemctl enable --now waydroid-container 2>/dev/null || true
    echo >&2
    log_ok "Installation complete."
    echo "  Run: waydroid show-full-ui" >&2
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: sudo bash install.sh [OPTIONS]

Options:
  --variant gapps|vanilla   Image variant: gapps (with Google Play, default)
                            or vanilla (no Google Play)
  --release <tag>           Use a specific release tag (default: latest)
  --yes                     Non-interactive; accept all prompts
  --help                    Show this help

EOF
    exit 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant) VARIANT="${2:-}"; shift 2 ;;
            --release) RELEASE_TAG="${2:-}"; shift 2 ;;
            --yes|-y)  YES=1; shift ;;
            --help|-h) usage ;;
            *) die "Unknown option: '$1'. Use --help for usage." ;;
        esac
    done

    [[ "$VARIANT" == "gapps" || "$VARIANT" == "vanilla" ]] \
        || die "Invalid --variant '${VARIANT}'. Must be 'gapps' or 'vanilla'."

    preflight
    install_deps
    install_waydroid
    resolve_release
    install_images
    init_waydroid
    fix_binder_protocol
    install_ndk
    install_widevine
    apply_overlays
    start_waydroid
}

main "$@"
