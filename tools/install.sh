#!/usr/bin/env bash
# install.sh — Waydroid installer
#
# Installs Waydroid, initialises the container with stock LineageOS images
# (downloaded by waydroid itself), then layers NDK translation, Widevine L3,
# and optionally Google Play (GApps) as overlay modules.
#
# Approach follows casualsnek/waydroid_script: base images stay unmodified;
# extras are applied via /var/lib/waydroid/overlay/ and activated with
# `waydroid upgrade --offline`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/install.sh \
#     | sudo bash -s -- [OPTIONS]
#
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --variant gapps|vanilla   Install with or without Google Play (default: vanilla)
#   --yes                     Non-interactive; accept all prompts
#   --help                    Show this help
#
# Supported distros: Ubuntu/Debian (apt), Fedora (dnf + Copr), Arch (AUR)
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────

# NDK translation — Android 11 x86_64 (supremegamers prebuilt, commit-pinned)
readonly NDK_URL="https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt/archive/9324a8914b649b885dad6f2bfd14a67e5d1520bf.zip"
readonly NDK_MD5="c9572672d1045594448068079b34c350"

# Widevine L3 — Android 11 x86_64 (supremegamers prebuilt, commit-pinned)
readonly WV_URL="https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/archive/48d1076a570837be6cdce8252d5d143363e37cc1.zip"
readonly WV_MD5="f587b8859f9071da4bca6cea1b9bed6a"

# OpenGApps pico — Android 11 x86_64
readonly GAPPS_URL="https://sourceforge.net/projects/opengapps/files/x86_64/20220503/open_gapps-x86_64-11.0-pico-20220503.zip/download"
readonly GAPPS_MD5="5a6d242be34ad1acf92899c7732afa1b"

readonly OVERLAY_SYS="/var/lib/waydroid/overlay/system"
readonly OVERLAY_VND="/var/lib/waydroid/overlay/vendor"
readonly WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"
readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/waydroid-customizer"
readonly TMP_DIR="/tmp/waydroid-install-$$"

# ── Globals ────────────────────────────────────────────────────────────────────
VARIANT="vanilla"
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

_md5() { md5sum "$1" | awk '{print $1}'; }

# Write a key=value into waydroid.cfg [properties] section.
_set_waydroid_prop() {
    local key="$1" val="$2"
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

# ── Download with retry + MD5 validation ──────────────────────────────────────
_download() {
    local url="$1" dest="$2" expected_md5="${3:-}"

    mkdir -p "$(dirname "$dest")"

    # Cache hit
    if [[ -f "$dest" && -n "$expected_md5" ]]; then
        if [[ "$(_md5 "$dest")" == "$expected_md5" ]]; then
            log_info "Cache hit: $(basename "$dest")"
            return 0
        fi
        log_warn "Cached file MD5 mismatch — redownloading."
        rm -f "$dest"
    fi

    local attempt=0 wait=5
    while (( attempt < 3 )); do
        (( attempt++ )) || true
        log_info "Downloading $(basename "$dest") (attempt $attempt/3)…"
        if curl -fL --http1.1 --progress-bar --connect-timeout 30 --max-time 900 \
                "$url" -o "$dest" 2>&1; then
            if [[ -n "$expected_md5" && "$(_md5 "$dest")" != "$expected_md5" ]]; then
                log_warn "MD5 mismatch — retrying."
                rm -f "$dest"
            else
                return 0
            fi
        fi
        log_warn "Download failed. Retrying in ${wait}s…"
        sleep "$wait"; (( wait *= 2 ))
    done
    die "Download failed after 3 attempts: $url"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

    # Non-interactive stdin (piped via curl) → auto-yes
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

# ── Dependency installation ────────────────────────────────────────────────────
install_deps() {
    local pkgs=()
    command -v curl  &>/dev/null || pkgs+=(curl)
    command -v unzip &>/dev/null || pkgs+=(unzip)
    command -v python3 &>/dev/null || pkgs+=(python3)
    [[ "$VARIANT" == "gapps" ]] && ! command -v lzip &>/dev/null && pkgs+=(lzip)

    [[ "${#pkgs[@]}" -eq 0 ]] && return 0
    log_info "Installing dependencies: ${pkgs[*]}"
    case "$DISTRO_FAMILY" in
        debian) apt-get install -y -qq "${pkgs[@]}" ;;
        fedora) dnf install -y -q "${pkgs[@]}" ;;
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

            # Add waydroid repo
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
            [[ -n "$aur_cmd" ]] || die "AUR helper (yay or paru) is required on Arch. Install one first."
            local real_user="${SUDO_USER:-${USER:-root}}"
            sudo -u "$real_user" "$aur_cmd" -S --noconfirm waydroid
            ;;
    esac

    log_ok "Waydroid installed."
}

# ── Waydroid init ─────────────────────────────────────────────────────────────
init_waydroid() {
    # Enable overlayfs so NDK/Widevine/GApps don't modify the base images.
    # waydroid prop set may not be available in all versions; fall back to
    # direct cfg edit.
    if ! waydroid prop set mount_overlays 1 2>/dev/null; then
        if [[ -f "$WAYDROID_CFG" ]]; then
            _set_waydroid_prop "mount_overlays" "True"
        fi
    fi

    log_info "Initialising Waydroid container (this downloads base images)…"

    # waydroid init downloads LineageOS images from waydroid's OTA server.
    # -f forces re-init if already initialised.
    if ! waydroid init -f 2>&1 | tee /dev/stderr | grep -qi "error\|fail"; then
        log_ok "Waydroid initialised."
        return 0
    fi

    # Some waydroid versions require explicit OTA URLs when no preinstalled
    # images are found.  Use the official Android 11 vanilla OTAs.
    log_warn "Plain init failed — retrying with explicit OTA URLs."
    local sys_ota="https://ota.waydroid.org/android11/lineage-18.1/VANILLA/SYSTEM-LATEST.zip"
    local vnd_ota="https://ota.waydroid.org/android11/lineage-18.1/MAINLINE/VENDOR-LATEST.zip"
    waydroid init -f -s "$sys_ota" -v "$vnd_ota" \
        || die "waydroid init failed. Check network connectivity and waydroid logs."

    log_ok "Waydroid initialised."
}

# ── Overlay helpers ────────────────────────────────────────────────────────────

# Download a prebuilt zip, locate its prebuilts/ directory, and copy it into
# an overlay partition directory.
_install_prebuilt_overlay() {
    local url="$1" md5="$2" cache_name="$3" overlay_dir="$4"

    local cache_file="${CACHE_DIR}/${cache_name}"
    _download "$url" "$cache_file" "$md5"

    local extract_dir="${TMP_DIR}/${cache_name%.zip}"
    mkdir -p "$extract_dir" "$overlay_dir"

    log_info "Extracting ${cache_name}…"
    unzip -q "$cache_file" "*/prebuilts/*" -d "$extract_dir"

    local prebuilts
    prebuilts="$(find "$extract_dir" -maxdepth 2 -name "prebuilts" -type d | head -1)"
    [[ -d "$prebuilts" ]] \
        || die "prebuilts/ directory not found inside ${cache_name}."

    cp -af "${prebuilts}/." "$overlay_dir/"
    rm -rf "$extract_dir"
}

# ── NDK translation ────────────────────────────────────────────────────────────
install_ndk() {
    log_info "Installing libndk_translation (ARM → x86 bridge)…"

    _install_prebuilt_overlay \
        "$NDK_URL" "$NDK_MD5" "ndk-translation.zip" "$OVERLAY_SYS"

    # Register ABI list and native bridge in waydroid.cfg
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
    _install_prebuilt_overlay \
        "$WV_URL" "$WV_MD5" "widevine.zip" "$OVERLAY_VND"
    log_ok "Widevine L3 installed."
}

# ── Google Apps (OpenGApps pico, Android 11 x86_64) ──────────────────────────
install_gapps() {
    require_cmd lzip "sudo apt install lzip  /  sudo dnf install lzip"
    require_cmd tar

    log_info "Installing OpenGApps pico (Android 11 x86_64)…"

    local cache_file="${CACHE_DIR}/opengapps.zip"
    _download "$GAPPS_URL" "$cache_file" "$GAPPS_MD5"

    local extract_dir="${TMP_DIR}/gapps"
    mkdir -p "$extract_dir"

    # OpenGApps pico contains Core/*.tar.lz — one per GApps component.
    unzip -q "$cache_file" "Core/*.tar.lz" -d "$extract_dir"

    # GmsCore_stub is a placeholder; real GmsCore downloads from Play Store.
    # PartnerSetupGoogle is not needed for bare GApps.
    local -A skip=([GmsCore_stub]=1 [PartnerSetupGoogle]=1)

    for lz_file in "${extract_dir}/Core/"*.tar.lz; do
        local name
        name="$(basename "$lz_file" .tar.lz)"
        [[ "${skip[$name]+set}" ]] && continue

        log_info "  Extracting ${name}…"
        local tar_file="${lz_file%.lz}"
        lzip -d -k "$lz_file" -o "$tar_file"

        local comp_dir="${extract_dir}/${name}"
        mkdir -p "$comp_dir"
        tar -xf "$tar_file" -C "$comp_dir"
        rm -f "$tar_file"

        # Copy APKs into priv-app overlay (pico components are all privileged).
        find "$comp_dir" -name "*.apk" | while IFS= read -r apk; do
            local apk_name
            apk_name="$(basename "$apk" .apk)"
            local dest="${OVERLAY_SYS}/priv-app/${apk_name}"
            mkdir -p "$dest"
            cp "$apk" "$dest/"
        done
    done

    rm -rf "$extract_dir"
    log_ok "GApps overlay installed."
}

# ── Apply overlays ────────────────────────────────────────────────────────────
apply_overlays() {
    log_info "Applying overlays (waydroid upgrade --offline)…"
    waydroid upgrade --offline 2>/dev/null \
        || log_warn "waydroid upgrade --offline returned non-zero (may be harmless)."
}

# ── Start Waydroid ────────────────────────────────────────────────────────────
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

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: sudo bash install.sh [OPTIONS]

Options:
  --variant gapps|vanilla   Install with (gapps) or without Google Play
                            (default: vanilla)
                            GApps requires lzip: apt install lzip / dnf install lzip
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
    init_waydroid
    install_ndk
    install_widevine
    [[ "$VARIANT" == "gapps" ]] && install_gapps
    apply_overlays
    start_waydroid
}

main "$@"
