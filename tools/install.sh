#!/usr/bin/env bash
# install.sh – Install Waydroid with custom images from chr0mx/waydroid-customizer
#
# Usage:
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --variant   vanilla|gapps        Image variant (default: prompt)
#   --profile   pixel-5|pixel-4a|samsung-s21|generic-x86|none
#                                    Device spoof profile (default: pixel-5)
#   --release   vDATE-custom         Specific release tag (default: latest)
#   --local-images <dir>             Use pre-built ZIPs from this directory instead of
#                                    downloading from GitHub Releases. The directory must
#                                    contain the output of scripts/repack.sh (*.zip files).
#   --images-only                    Skip Waydroid package install; replace images only
#   --overlay-modules <list>         Comma-separated runtime modules to install via
#                                    /var/lib/waydroid/overlay/ (e.g. widevine,arm-ndk)
#                                    Does NOT replace base images.
#   --yes                            Non-interactive; use defaults without prompting
#   --help                           Show this help
#
# Supported distributions: Ubuntu/Debian (apt), Fedora (dnf + Copr)
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly PROFILES_RAW_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/modules/spoof/profiles"
readonly NDK_PREBUILT_URL="https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt/archive/9324a8914b649b885dad6f2bfd14a67e5d1520bf.tar.gz"
readonly WV_PREBUILT_URL="https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/archive/48d1076a570837be6cdce8252d5d143363e37cc1.tar.gz"
readonly IMAGES_DIR="/var/lib/waydroid/images"
readonly SPOOF_DIR="/var/lib/waydroid/data/waydroid-spoof"
readonly OVERLAY_SYS="/var/lib/waydroid/overlay/system"
readonly OVERLAY_VND="/var/lib/waydroid/overlay/vendor"
readonly WAYDROID_APT_LIST="/etc/apt/sources.list.d/waydroid.list"
readonly WAYDROID_GPG="/usr/share/keyrings/waydroid.gpg"
readonly TMP_DIR="/tmp/waydroid-install-$$"
readonly VALID_PROFILES=(pixel-5 pixel-4a samsung-s21 generic-x86 none)
DISTRO_FAMILY=""   # set by preflight(): "debian" | "fedora"
# Approximate sizes for disk-space pre-check (bytes)
readonly SYSTEM_ZIP_BYTES=$(( 450 * 1024 * 1024 ))
readonly VENDOR_ZIP_BYTES=$(( 200 * 1024 * 1024 ))
readonly OVERLAY_ARCHIVE_BYTES=$(( 150 * 1024 * 1024 ))

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts() { date '+%H:%M:%S'; }
log_info()  { echo "[INFO]  $(_ts) $*" >&2; }
log_ok()    { echo "[OK]    $(_ts) $*" >&2; }
log_warn()  { echo "[WARN]  $(_ts) $*" >&2; }
log_error() { echo "[ERROR] $(_ts) $*" >&2; }
die()       { log_error "$*"; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
VARIANT=""
PROFILE="pixel-5"
RELEASE_TAG=""
LOCAL_IMAGES_DIR=""
IMAGES_ONLY=0
OVERLAY_MODULES=""
YES=0

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -26
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)         VARIANT="$2";          shift 2 ;;
        --profile)         PROFILE="$2";          shift 2 ;;
        --release)         RELEASE_TAG="$2";      shift 2 ;;
        --local-images)    LOCAL_IMAGES_DIR="$2"; shift 2 ;;
        --images-only)     IMAGES_ONLY=1;         shift ;;
        --overlay-modules) OVERLAY_MODULES="$2";  shift 2 ;;
        --yes|-y)          YES=1;                 shift ;;
        --help|-h)         usage ;;
        *) die "Unknown option: $1  (use --help for usage)" ;;
    esac
done

# When stdin is not a terminal (e.g. curl | sudo bash), interactive prompts
# hang forever. Auto-enable --yes so piped execution works out of the box.
if [[ ! -t 0 ]] && [[ "$YES" -eq 0 ]]; then
    log_info "Non-interactive stdin detected — enabling --yes mode."
    YES=1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

prompt_choice() {
    local var_name="$1" prompt="$2"; shift 2
    local choices=("$@")
    if [[ "$YES" -eq 1 ]]; then return 0; fi
    echo >&2
    log_info "$prompt"
    local i=1
    for c in "${choices[@]}"; do echo "  $i) $c" >&2; (( i++ )); done
    read -rp "  Choice [1]: " idx
    idx="${idx:-1}"
    [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#choices[@]}" ]] || die "Invalid choice."
    printf -v "$var_name" '%s' "${choices[$(( idx - 1 ))]}"
}

_json_field() {
    python3 -c "
import sys, json
data = json.load(sys.stdin)
val = data$1
if val is None:
    raise ValueError('field is null')
print(val)
" 2>/dev/null || true
}

# ─── Download with retry ──────────────────────────────────────────────────────
_human_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif (( bytes >=    1048576 )); then printf "%.0f MB"  "$(echo "scale=0; $bytes/1048576"    | bc)"
    else printf "%d KB" "$(( bytes / 1024 ))"
    fi
}

_download_with_retry() {
    local url="$1" dest="$2"

    local content_length
    content_length="$(curl -fsI --connect-timeout 10 "$url" 2>/dev/null \
        | grep -i '^content-length:' | tail -1 | tr -d '[:space:]' | cut -d: -f2)"
    if [[ "$content_length" =~ ^[0-9]+$ && "$content_length" -gt 0 ]]; then
        log_info "File size: $(_human_size "$content_length") — this may take several minutes."
    fi

    local attempt=0 wait=5
    while (( attempt < 3 )); do
        (( attempt++ )) || true
        log_info "Downloading $(basename "$dest") (attempt $attempt/3)…"
        if curl -fL --progress-bar --connect-timeout 30 --max-time 600 \
                "$url" -o "$dest" 2>&1; then
            [[ -s "$dest" ]] || { log_warn "Downloaded file is empty."; rm -f "$dest"; false; } && return 0
        fi
        log_warn "Download failed. Retrying in ${wait}s…"
        rm -f "$dest"
        sleep "$wait"
        (( wait *= 2 ))
    done
    die "Download failed after 3 attempts: $url"
}

# ─── Disk space check ─────────────────────────────────────────────────────────
_check_disk_space() {
    local dir="$1" need_bytes="$2"
    mkdir -p "$dir"
    local free_bytes
    free_bytes=$(df --output=avail -B1 "$dir" 2>/dev/null | tail -1 | tr -d ' ')
    if ! [[ "$free_bytes" =~ ^[0-9]+$ ]]; then
        log_warn "Could not determine free space in $dir — proceeding anyway."
        return 0
    fi
    (( free_bytes > need_bytes )) || \
        die "Not enough disk space in $dir — need $(( need_bytes / 1048576 )) MiB, have $(( free_bytes / 1048576 )) MiB."
}

# ─── Preflight ────────────────────────────────────────────────────────────────
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

    require_cmd curl python3 unzip sha256sum

    if [[ -f /etc/os-release ]]; then
        # Source in a subshell to avoid clobbering script globals (e.g. VARIANT, ID).
        local os_id os_id_like os_pretty
        os_id="$(      . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}"          )"
        os_id_like="$( . /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}"     )"
        os_pretty="$(  . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}" )"
        local id_like="${os_id_like} ${os_id}"
        if [[ "$id_like" == *debian* || "$id_like" == *ubuntu* ]]; then
            DISTRO_FAMILY="debian"
        elif [[ "$id_like" == *fedora* || "$id_like" == *rhel* || "$id_like" == *centos* || "$os_id" == "fedora" ]]; then
            DISTRO_FAMILY="fedora"
        else
            die "Unsupported distro (detected: ${os_id:-unknown}). Supports Ubuntu/Debian and Fedora."
        fi
        log_info "Detected distro family: $DISTRO_FAMILY (${os_pretty:-${os_id:-unknown}})"
    else
        die "/etc/os-release not found. Cannot determine OS."
    fi

    local p valid=0
    for p in "${VALID_PROFILES[@]}"; do [[ "$PROFILE" == "$p" ]] && valid=1 && break; done
    [[ "$valid" -eq 1 ]] || die "Invalid --profile '$PROFILE'. Valid: ${VALID_PROFILES[*]}"

    if [[ -n "$VARIANT" ]]; then
        [[ "$VARIANT" == vanilla || "$VARIANT" == gapps ]] || \
            die "Invalid --variant '$VARIANT'. Use: vanilla or gapps"
    fi

    if [[ -n "$LOCAL_IMAGES_DIR" ]]; then
        [[ -d "$LOCAL_IMAGES_DIR" ]] || die "--local-images: directory not found: $LOCAL_IMAGES_DIR"
    fi

    if [[ -n "$OVERLAY_MODULES" ]]; then
        local mod
        for mod in ${OVERLAY_MODULES//,/ }; do
            [[ "$mod" == widevine || "$mod" == arm-ndk ]] || \
                die "Unknown overlay module: '$mod'. Valid: widevine, arm-ndk"
        done
    fi
}

# ─── Variant selection ────────────────────────────────────────────────────────
resolve_variant() {
    if [[ -n "$VARIANT" ]]; then return; fi
    prompt_choice VARIANT "Which image variant?" vanilla gapps
    VARIANT="${VARIANT:-vanilla}"
}

# ─── Waydroid installation ────────────────────────────────────────────────────
_install_waydroid_apt() {
    require_cmd gpg lsb_release apt-get

    local codename
    codename="$(lsb_release -sc)"

    # Download GPG key to temp file first — avoids empty stdin reaching gpg on curl failure
    local gpg_tmp="${TMP_DIR}/waydroid.gpg.tmp"
    mkdir -p "$TMP_DIR"
    _download_with_retry "https://repo.waydro.id/waydroid.gpg" "$gpg_tmp"
    gpg --dearmor < "$gpg_tmp" > "$WAYDROID_GPG"
    rm -f "$gpg_tmp"

    echo "deb [signed-by=${WAYDROID_GPG}] https://repo.waydro.id/ ${codename} main" \
        > "$WAYDROID_APT_LIST"

    apt-get update -q || die "apt-get update failed. Check network and apt sources."
    DEBIAN_FRONTEND=noninteractive apt-get install -y waydroid \
        || die "apt-get install waydroid failed."
}

_install_waydroid_dnf() {
    require_cmd dnf

    # dnf copr requires the copr plugin (dnf-plugins-core)
    if ! dnf copr --help &>/dev/null 2>&1; then
        log_info "Installing dnf-plugins-core for Copr support…"
        dnf install -y dnf-plugins-core || die "Failed to install dnf-plugins-core."
    fi

    log_info "Enabling aleasto/waydroid Copr repository…"
    dnf copr enable -y aleasto/waydroid || die "dnf copr enable aleasto/waydroid failed."
    dnf install -y waydroid || die "dnf install waydroid failed."
}

install_waydroid() {
    if [[ "$IMAGES_ONLY" -eq 1 ]]; then
        log_info "Skipping Waydroid package installation (--images-only)."
        return
    fi

    if command -v waydroid &>/dev/null; then
        log_info "Waydroid already installed ($(waydroid --version 2>/dev/null || echo 'version unknown'))."
        return
    fi

    log_info "Installing Waydroid from official repo…"
    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        _install_waydroid_dnf
    else
        _install_waydroid_apt
    fi
    log_ok "Waydroid installed."
}

# ─── Release resolution ───────────────────────────────────────────────────────
resolve_release() {
    if [[ -n "$RELEASE_TAG" ]]; then
        log_info "Using specified release: $RELEASE_TAG"
        return
    fi

    log_info "Fetching latest release from ${RELEASE_REPO}…"
    local api_url="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
    local api_response
    api_response="$(curl -fsSL --connect-timeout 15 "$api_url" 2>/dev/null)" \
        || die "GitHub API request failed. Check network connectivity."
    [[ -n "$api_response" ]] || die "GitHub API returned empty response."

    RELEASE_TAG="$(echo "$api_response" | _json_field "['tag_name']")"
    [[ -n "$RELEASE_TAG" ]] || \
        die "Could not parse release tag from GitHub API — may be rate-limited. Use --release vDATE-custom."
    log_ok "Latest release: $RELEASE_TAG"
}

# ─── Download & verify ────────────────────────────────────────────────────────
_download_and_verify() {
    local url="$1" dest="$2"
    _download_with_retry "$url" "$dest"

    local sha_url="${url}.sha256" sha_file="${dest}.sha256"
    _download_with_retry "$sha_url" "$sha_file"

    local expected actual
    expected="$(awk '{print $1}' "$sha_file")"
    actual="$(sha256sum "$dest" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "SHA256 mismatch for $(basename "$dest").
  Expected: $expected
  Got:      $actual"
    log_ok "Verified: $(basename "$dest")"
}

download_images() {
    mkdir -p "$TMP_DIR"
    _check_disk_space "$TMP_DIR" $(( SYSTEM_ZIP_BYTES + VENDOR_ZIP_BYTES + 100 * 1024 * 1024 ))

    local date_tag="${RELEASE_TAG#v}"
    date_tag="${date_tag%-custom}"
    local variant_upper="${VARIANT^^}"
    local base_url="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"
    local arch="waydroid_x86_64"

    SYSTEM_ZIP="${TMP_DIR}/waydroid-custom-${date_tag}-${variant_upper}-${arch}-system.zip"
    VENDOR_ZIP="${TMP_DIR}/waydroid-custom-${date_tag}-MAINLINE-${arch}-vendor.zip"

    _download_and_verify \
        "${base_url}/waydroid-custom-${date_tag}-${variant_upper}-${arch}-system.zip" \
        "$SYSTEM_ZIP"

    _download_and_verify \
        "${base_url}/waydroid-custom-${date_tag}-MAINLINE-${arch}-vendor.zip" \
        "$VENDOR_ZIP"
}

# ─── Local image location ────────────────────────────────────────────────────
_locate_local_images() {
    local dir="$1"
    local variant_upper="${VARIANT^^}"

    SYSTEM_ZIP="$(find "$dir" -maxdepth 1 -name "*-${variant_upper}-*-system.zip" | sort | tail -1)"
    VENDOR_ZIP="$(find "$dir" -maxdepth 1 -name "*-MAINLINE-*-vendor.zip"         | sort | tail -1)"

    [[ -f "$SYSTEM_ZIP" ]] || die "No ${variant_upper} system ZIP found in $LOCAL_IMAGES_DIR"
    [[ -f "$VENDOR_ZIP" ]] || die "No MAINLINE vendor ZIP found in $LOCAL_IMAGES_DIR"

    log_ok "Local system: $(basename "$SYSTEM_ZIP")"
    log_ok "Local vendor: $(basename "$VENDOR_ZIP")"
}

# ─── Sparse image detection and conversion ───────────────────────────────────
_is_sparse_image() {
    local magic
    magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "ed26ff3a" ]]
}

_ensure_raw_ext4() {
    local img="$1"
    _is_sparse_image "$img" || return 0
    log_info "Detected Android sparse format in $(basename "$img") — converting to raw ext4…"
    if ! command -v simg2img &>/dev/null; then
        log_info "Installing simg2img…"
        if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
            dnf install -y android-tools 2>/dev/null \
                || die "simg2img not found. Install it: dnf install android-tools"
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y android-tools-fsutils 2>/dev/null \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y simg2img 2>/dev/null \
                || die "simg2img not found. Install it: apt-get install android-tools-fsutils"
        fi
    fi
    local tmp="${img}.raw"
    simg2img "$img" "$tmp" || die "simg2img conversion failed for $(basename "$img")"
    mv "$tmp" "$img"
    log_ok "Converted to raw ext4: $(basename "$img")"
}

# ─── Image replacement ────────────────────────────────────────────────────────
_wait_for_stopped() {
    local deadline=$(( $(date +%s) + 15 ))
    while (( $(date +%s) < deadline )); do
        local status
        status="$(waydroid status 2>/dev/null | awk '/Session:/{print $2}' || true)"
        [[ "$status" == "STOPPED" || -z "$status" ]] && return 0
        sleep 1
    done
    log_warn "Waydroid did not stop within 15s — proceeding anyway."
}

replace_images() {
    log_info "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    _wait_for_stopped

    _check_disk_space "$IMAGES_DIR" $(( SYSTEM_ZIP_BYTES + VENDOR_ZIP_BYTES ))
    mkdir -p "$IMAGES_DIR"

    log_info "Extracting system.img…"
    unzip -o "$SYSTEM_ZIP" "system.img" -d "$IMAGES_DIR" >/dev/null
    [[ -s "${IMAGES_DIR}/system.img" ]] || die "system.img not found or empty after extraction."
    _ensure_raw_ext4 "${IMAGES_DIR}/system.img"
    log_ok "system.img installed ($(du -h "${IMAGES_DIR}/system.img" | awk '{print $1}'))."

    log_info "Extracting vendor.img…"
    unzip -o "$VENDOR_ZIP" "vendor.img" -d "$IMAGES_DIR" >/dev/null
    [[ -s "${IMAGES_DIR}/vendor.img" ]] || die "vendor.img not found or empty after extraction."
    _ensure_raw_ext4 "${IMAGES_DIR}/vendor.img"
    log_ok "vendor.img installed ($(du -h "${IMAGES_DIR}/vendor.img" | awk '{print $1}'))."
}

# ─── Waydroid container init ──────────────────────────────────────────────────
_init_waydroid_container() {
    # Delete any stale LXC config so waydroid creates a fresh one.
    # We pass -i "$IMAGES_DIR" (our images are already placed there by replace_images).
    # Without -f, waydroid sees existing images → skips CDN download → just creates LXC config.
    rm -rf /var/lib/waydroid/lxc/waydroid
    log_info "Creating Waydroid container config…"
    # waydroid 1.4+ requires -s/-v OTA URLs; -i alone no longer suffices.
    # Use file:// so waydroid handles extraction without hitting the network.
    waydroid init -f \
        -s "file://${SYSTEM_ZIP}" \
        -v "file://${VENDOR_ZIP}" \
        || log_warn "waydroid init reported an error — container may still start."
}

# ─── Spoof profile ────────────────────────────────────────────────────────────
apply_spoof_profile() {
    if [[ "$PROFILE" == "none" ]]; then
        log_info "Skipping spoof profile (--profile none)."
        return
    fi

    log_info "Applying spoof profile: $PROFILE"
    mkdir -p "$SPOOF_DIR"

    local json
    json="$(curl -fsSL --connect-timeout 15 "${PROFILES_RAW_URL}/${PROFILE}.json" 2>/dev/null)" \
        || die "Failed to download spoof profile: $PROFILE"
    [[ -n "$json" ]] || die "Spoof profile download returned empty response."

    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
props = data.get('props', {})
if not props:
    raise ValueError('No props found in profile')
for k, v in props.items():
    print(f'{k}={v}')
" > "${SPOOF_DIR}/active.prop" || die "Failed to parse spoof profile JSON."

    log_ok "Profile written: ${SPOOF_DIR}/active.prop"
}

# ─── Overlay module installation ──────────────────────────────────────────────
_overlay_extract_archive() {
    local url="$1" cache_file="$2" extract_dir="$3"
    if [[ ! -f "$cache_file" ]]; then
        _download_with_retry "$url" "$cache_file"
    else
        log_info "Using cached archive: $(basename "$cache_file")"
    fi
    mkdir -p "$extract_dir"
    tar -xzf "$cache_file" -C "$extract_dir" --strip-components=1 2>/dev/null || {
        rm -f "$cache_file"
        die "Failed to extract overlay archive (may be corrupt). Cache removed — retry."
    }
}

_overlay_widevine() {
    local overlay_vnd="$1"
    log_info "Installing Widevine L3 via overlay…"

    local cache_file="${TMP_DIR}/widevine-prebuilt.tar.gz"
    local extract_dir="${TMP_DIR}/widevine-prebuilt"

    _check_disk_space "$TMP_DIR" "$OVERLAY_ARCHIVE_BYTES"
    _overlay_extract_archive "$WV_PREBUILT_URL" "$cache_file" "$extract_dir"

    local prebuilts="${extract_dir}/prebuilts"
    if [[ ! -d "$prebuilts" ]]; then
        log_warn "prebuilts dir not found in Widevine archive."
        return 1
    fi
    mkdir -p "$overlay_vnd"
    cp -af "${prebuilts}/." "$overlay_vnd/"
    log_ok "Widevine L3 overlay installed."
}

_overlay_arm_ndk() {
    local overlay_sys="$1"
    log_info "Installing libndk_translation via overlay…"

    local cache_file="${TMP_DIR}/ndk-prebuilt.tar.gz"
    local extract_dir="${TMP_DIR}/ndk-prebuilt"

    _check_disk_space "$TMP_DIR" "$OVERLAY_ARCHIVE_BYTES"
    _overlay_extract_archive "$NDK_PREBUILT_URL" "$cache_file" "$extract_dir"

    local prebuilts="${extract_dir}/prebuilts"
    if [[ ! -d "$prebuilts" ]]; then
        log_warn "prebuilts dir not found in NDK archive."
        return 1
    fi
    mkdir -p "$overlay_sys"
    cp -af "${prebuilts}/." "$overlay_sys/"
    log_ok "libndk_translation overlay installed."
}

install_overlay_modules() {
    [[ -n "$OVERLAY_MODULES" ]] || return 0

    if [[ ! -d "/var/lib/waydroid" ]]; then
        die "/var/lib/waydroid not found. Run the full installer first (without --overlay-modules)."
    fi

    mkdir -p "$OVERLAY_SYS" "$OVERLAY_VND"

    local mod
    for mod in ${OVERLAY_MODULES//,/ }; do
        case "$mod" in
            widevine) _overlay_widevine "$OVERLAY_VND" || log_warn "Widevine overlay failed — skipping." ;;
            arm-ndk)  _overlay_arm_ndk  "$OVERLAY_SYS" || log_warn "arm-ndk overlay failed — skipping." ;;
        esac
    done
}

# ─── Start Waydroid ───────────────────────────────────────────────────────────
start_waydroid() {
    log_info "Starting Waydroid…"
    systemctl start waydroid-container 2>/dev/null || true
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    rm -rf "$TMP_DIR"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    trap cleanup EXIT

    preflight "$@"

    # Overlay-only mode: install runtime modules without touching base images
    if [[ -n "$OVERLAY_MODULES" && "$IMAGES_ONLY" -eq 0 && -z "$VARIANT" ]]; then
        install_overlay_modules
        systemctl restart waydroid-container 2>/dev/null || true
        echo >&2
        log_ok "Overlay modules installed: $OVERLAY_MODULES"
        return 0
    fi

    resolve_variant
    install_waydroid

    if [[ -n "$LOCAL_IMAGES_DIR" ]]; then
        _locate_local_images "$LOCAL_IMAGES_DIR"
    else
        resolve_release
        download_images
    fi
    replace_images
    _init_waydroid_container
    apply_spoof_profile
    install_overlay_modules
    start_waydroid

    echo >&2
    log_ok "════════════════════════════════════════════"
    log_ok "  Waydroid custom images installed!"
    log_ok "  Variant:  $VARIANT"
    if [[ -n "$LOCAL_IMAGES_DIR" ]]; then
        log_ok "  Source:   local ($LOCAL_IMAGES_DIR)"
    else
        log_ok "  Release:  $RELEASE_TAG"
    fi
    log_ok "  Profile:  $PROFILE"
    [[ -n "$OVERLAY_MODULES" ]] && log_ok "  Overlays: $OVERLAY_MODULES"
    log_ok "════════════════════════════════════════════"
    echo >&2
    echo "  Next steps:" >&2
    echo "    waydroid show-full-ui       # launch the UI" >&2
    echo "    waydroid session stop       # stop the session" >&2
    if [[ "$PROFILE" != "none" ]]; then
        echo "" >&2
        echo "  Switch device profile at any time:" >&2
        echo "    curl -fsSL https://raw.githubusercontent.com/${RELEASE_REPO}/main/tools/set-spoof-profile.sh | sudo bash -s -- pixel-4a" >&2
    fi
    echo >&2
}

main "$@"
