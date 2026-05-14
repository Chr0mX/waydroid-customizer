#!/usr/bin/env bash
# install.sh – Install Waydroid with custom images from chr0mx/waydroid-customizer
#
# Usage:
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --variant   vanilla|gapps        Image variant (default: prompt)
#   --profile   pixel-6a|pixel-4a|samsung-s21|generic-x86|none
#                                    Device spoof profile (default: pixel-6a)
#   --release   vDATE-custom         Specific release tag (default: latest)
#   --images-only                    Skip Waydroid installation; replace images only
#   --yes                            Non-interactive; use defaults without prompting
#   --help                           Show this help
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly RELEASE_REPO="chr0mx/waydroid-customizer"
readonly PROFILES_RAW_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/modules/spoof/profiles"
readonly IMAGES_DIR="/var/lib/waydroid/images"
readonly SPOOF_DIR="/var/lib/waydroid/data/waydroid-spoof"
readonly WAYDROID_APT_LIST="/etc/apt/sources.list.d/waydroid.list"
readonly WAYDROID_GPG="/usr/share/keyrings/waydroid.gpg"
readonly TMP_DIR="/tmp/waydroid-install-$$"
readonly VALID_PROFILES=(pixel-6a pixel-4a samsung-s21 generic-x86 none)

# ─── Logging ──────────────────────────────────────────────────────────────────
_ts() { date '+%H:%M:%S'; }
log_info()  { echo "[INFO]  $(_ts) $*" >&2; }
log_ok()    { echo "[OK]    $(_ts) $*" >&2; }
log_warn()  { echo "[WARN]  $(_ts) $*" >&2; }
log_error() { echo "[ERROR] $(_ts) $*" >&2; }
die()       { log_error "$*"; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
VARIANT=""
PROFILE="pixel-6a"
RELEASE_TAG=""
IMAGES_ONLY=0
YES=0

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)    VARIANT="$2";     shift 2 ;;
        --profile)    PROFILE="$2";     shift 2 ;;
        --release)    RELEASE_TAG="$2"; shift 2 ;;
        --images-only) IMAGES_ONLY=1;   shift ;;
        --yes|-y)     YES=1;            shift ;;
        --help|-h)    usage ;;
        *) die "Unknown option: $1  (use --help for usage)" ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

confirm() {
    local prompt="$1"
    [[ "$YES" -eq 1 ]] && return 0
    read -rp "$prompt [y/N] " ans
    [[ "${ans,,}" == y* ]]
}

prompt_choice() {
    local var_name="$1" prompt="$2"; shift 2
    local choices=("$@")
    [[ "$YES" -eq 1 ]] && return 0   # caller must have set a default already
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
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
preflight() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0 $*"

    require_cmd curl python3 unzip sha256sum

    # Debian/Ubuntu detection
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        local id_like="${ID_LIKE:-} ${ID:-}"
        if [[ "$id_like" != *debian* && "$id_like" != *ubuntu* ]]; then
            die "Unsupported distro (detected: ${ID:-unknown}). This installer supports Ubuntu/Debian only."
        fi
    else
        die "/etc/os-release not found. Cannot determine OS."
    fi

    # Validate --profile
    local p valid=0
    for p in "${VALID_PROFILES[@]}"; do [[ "$PROFILE" == "$p" ]] && valid=1 && break; done
    [[ "$valid" -eq 1 ]] || die "Invalid --profile '$PROFILE'. Valid: ${VALID_PROFILES[*]}"

    # Validate --variant if provided
    if [[ -n "$VARIANT" ]]; then
        [[ "$VARIANT" == vanilla || "$VARIANT" == gapps ]] || \
            die "Invalid --variant '$VARIANT'. Use: vanilla or gapps"
    fi
}

# ─── Variant selection ────────────────────────────────────────────────────────
resolve_variant() {
    if [[ -n "$VARIANT" ]]; then return; fi
    prompt_choice VARIANT "Which image variant?" vanilla gapps
    VARIANT="${VARIANT:-vanilla}"
}

# ─── Waydroid installation ────────────────────────────────────────────────────
install_waydroid() {
    if [[ "$IMAGES_ONLY" -eq 1 ]]; then
        log_info "Skipping Waydroid installation (--images-only)."
        return
    fi

    if command -v waydroid &>/dev/null; then
        log_info "Waydroid already installed ($(waydroid --version 2>/dev/null || echo 'version unknown'))."
        return
    fi

    log_info "Installing Waydroid from official repo…"
    require_cmd gpg lsb_release apt-get

    local codename
    codename="$(lsb_release -sc)"

    curl -fsSL "https://repo.waydro.id/waydroid.gpg" \
        | gpg --dearmor -o "$WAYDROID_GPG"
    echo "deb [signed-by=${WAYDROID_GPG}] https://repo.waydro.id/ ${codename} main" \
        > "$WAYDROID_APT_LIST"

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y waydroid
    log_ok "Waydroid installed."

    log_info "Running waydroid init…"
    waydroid init || log_warn "waydroid init failed — will proceed; images will be replaced."
}

# ─── Release resolution ───────────────────────────────────────────────────────
resolve_release() {
    if [[ -n "$RELEASE_TAG" ]]; then
        log_info "Using specified release: $RELEASE_TAG"
        return
    fi

    log_info "Fetching latest release from ${RELEASE_REPO}…"
    local api_url="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
    RELEASE_TAG="$(curl -fsSL "$api_url" | _json_field "['tag_name']")"
    [[ -n "$RELEASE_TAG" ]] || die "Could not determine latest release tag."
    log_ok "Latest release: $RELEASE_TAG"
}

# ─── Download & verify ────────────────────────────────────────────────────────
_download_and_verify() {
    local url="$1" dest="$2"
    log_info "Downloading $(basename "$dest")…"
    curl -fsSL --progress-bar "$url" -o "$dest" || die "Download failed: $url"

    local sha_url="${url}.sha256" sha_file="${dest}.sha256"
    curl -fsSL "$sha_url" -o "$sha_file" || die "Checksum download failed: ${sha_url}"

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

# ─── Image replacement ────────────────────────────────────────────────────────
replace_images() {
    log_info "Stopping Waydroid…"
    waydroid session stop 2>/dev/null || true
    systemctl stop waydroid-container 2>/dev/null || true
    sleep 1

    mkdir -p "$IMAGES_DIR"

    log_info "Extracting system.img…"
    unzip -o "$SYSTEM_ZIP" "system.img" -d "$IMAGES_DIR" >/dev/null
    log_ok "system.img installed."

    log_info "Extracting vendor.img…"
    unzip -o "$VENDOR_ZIP" "vendor.img" -d "$IMAGES_DIR" >/dev/null
    log_ok "vendor.img installed."
}

# ─── Spoof profile ────────────────────────────────────────────────────────────
apply_spoof_profile() {
    if [[ "$PROFILE" == "none" ]]; then
        log_info "Skipping spoof profile (--profile none)."
        return
    fi

    log_info "Applying spoof profile: $PROFILE"
    mkdir -p "$SPOOF_DIR"

    curl -fsSL "${PROFILES_RAW_URL}/${PROFILE}.json" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
props = data.get('props', {})
for k, v in props.items():
    print(f'{k}={v}')
" > "${SPOOF_DIR}/active.prop"

    log_ok "Profile written: ${SPOOF_DIR}/active.prop"
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
    resolve_variant
    install_waydroid
    resolve_release
    download_images
    replace_images
    apply_spoof_profile
    start_waydroid

    echo >&2
    log_ok "════════════════════════════════════════════"
    log_ok "  Waydroid custom images installed!"
    log_ok "  Variant:  $VARIANT"
    log_ok "  Release:  $RELEASE_TAG"
    log_ok "  Profile:  $PROFILE"
    log_ok "════════════════════════════════════════════"
    echo >&2
    echo "  Next steps:" >&2
    echo "    waydroid show-full-ui       # launch the UI" >&2
    echo "    waydroid session stop       # stop the session" >&2
    if [[ "$PROFILE" != "none" ]]; then
        echo "" >&2
        echo "  Switch device profile at any time:" >&2
        echo "    sudo bash <(curl -fsSL https://raw.githubusercontent.com/${RELEASE_REPO}/main/tools/set-spoof-profile.sh) pixel-4a" >&2
    fi
    echo >&2
}

main "$@"
