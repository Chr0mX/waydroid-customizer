#!/usr/bin/env bash
# scripts/lib/common.sh – shared utilities for all pipeline scripts
set -euo pipefail

# ─── Resolve REPO_ROOT once ──────────────────────────────────────────────────
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT

# Source configs if not already loaded
_load_config() {
    local conf="$1"
    if [[ -f "${REPO_ROOT}/config/${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/config/${conf}"
    fi
}

if [[ -z "${_PIPELINE_CONF_LOADED:-}" ]]; then
    _load_config pipeline.conf
    _load_config images.conf
    export _PIPELINE_CONF_LOADED=1
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
_log_ts() { date '+%H:%M:%S'; }

log_info()  { echo "[INFO]  $(_log_ts) $*"; }
log_ok()    { echo "[OK]    $(_log_ts) $*"; }
log_warn()  { echo "[WARN]  $(_log_ts) $*" >&2; }
log_error() { echo "[ERROR] $(_log_ts) $*" >&2; }
log_step()  { echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }

die() { log_error "$*"; exit 1; }

# ─── Prerequisite checks ─────────────────────────────────────────────────────
require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This script must run as root (needed for loop mount operations)."
}

# ─── State machine helpers ───────────────────────────────────────────────────
state_file() { echo "${STATE_DIR}/$1.done"; }

stage_done() {
    local stage="$1"
    [[ -f "$(state_file "$stage")" ]]
}

mark_done() {
    local stage="$1"
    mkdir -p "${STATE_DIR}"
    touch "$(state_file "$stage")"
    log_ok "Stage '${stage}' marked complete."
}

clear_stage() {
    local stage="$1"
    rm -f "$(state_file "$stage")"
}

# Run a stage only if not already complete (idempotent pipeline).
# Usage: run_stage <name> <function_or_script>
run_stage() {
    local name="$1"; shift
    if stage_done "$name"; then
        log_info "Stage '${name}' already complete – skipping."
        return 0
    fi
    log_step "Stage: ${name}"
    "$@"
    mark_done "$name"
}

# ─── Download with retry ─────────────────────────────────────────────────────
# download_file <url> <dest> [sha256]
download_file() {
    local url="$1"
    local dest="$2"
    local expected_sha="${3:-}"
    local max_retries=5
    local attempt=0
    local wait=4

    mkdir -p "$(dirname "$dest")"

    while (( attempt < max_retries )); do
        (( attempt++ )) || true
        log_info "Downloading (attempt ${attempt}/${max_retries}): $(basename "$dest")"
        if curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
                -o "$dest" "$url"; then
            if [[ -n "$expected_sha" ]]; then
                local actual_sha
                actual_sha="$(sha256sum "$dest" | awk '{print $1}')"
                if [[ "$actual_sha" != "$expected_sha" ]]; then
                    log_warn "SHA256 mismatch for $dest. Expected: $expected_sha  Got: $actual_sha"
                    rm -f "$dest"
                    (( attempt < max_retries )) && { sleep "$wait"; (( wait *= 2 )); continue; }
                    die "SHA256 verification failed after $max_retries attempts."
                fi
                log_ok "SHA256 verified: $dest"
            fi
            return 0
        fi
        log_warn "Download failed. Retrying in ${wait}s…"
        sleep "$wait"
        (( wait *= 2 ))
    done
    die "Failed to download: $url"
}

# ─── Sparse image helpers ────────────────────────────────────────────────────
is_sparse_image() {
    local f="$1"
    # Sparse Android image magic: 0xed26ff3a
    local magic
    magic="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
    [[ "$magic" == "ed26ff3a" ]]
}

# ─── Filesystem size helpers ─────────────────────────────────────────────────
# Return used bytes in an ext4 image (raw/sparse both accepted)
image_used_bytes() {
    local img="$1"
    local raw_img="$img"
    local tmp_img=""
    if is_sparse_image "$img"; then
        tmp_img="$(mktemp /tmp/waydroid-sizecheck-XXXXXX.img)"
        simg2img "$img" "$tmp_img"
        raw_img="$tmp_img"
    fi
    local used
    used="$(dumpe2fs -h "$raw_img" 2>/dev/null \
            | awk -F': *' '/Block count/{bc=$2} /Block size/{bs=$2} END{print bc*bs}')"
    [[ -n "$tmp_img" ]] && rm -f "$tmp_img"
    echo "${used:-0}"
}

# ─── Misc helpers ────────────────────────────────────────────────────────────
ensure_dir() { mkdir -p "$@"; }

pushd_q() { pushd "$1" > /dev/null; }
popd_q()  { popd > /dev/null; }

# Human-readable bytes
human_bytes() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf "%.1f GiB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >=    1048576 )); then printf "%.1f MiB" "$(echo "scale=1; $b/1048576" | bc)"
    elif (( b >=       1024 )); then printf "%.1f KiB" "$(echo "scale=1; $b/1024" | bc)"
    else printf "%d B" "$b"
    fi
}
