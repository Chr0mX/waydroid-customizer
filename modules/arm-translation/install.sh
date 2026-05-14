#!/usr/bin/env bash
# modules/arm-translation/install.sh
#
# Injects ARM translation support into a mounted Android image.
# Supports two backends:
#   houdini  – Intel libhoudini (binary assets must be present in assets/houdini/)
#   ndk      – libndk_translation (extracted from ChromeOS or downloaded)
#   auto     – try houdini, fall back to ndk
#
# Usage:
#   install.sh <image_root> [system|vendor]
#     image_root – mounted image root path
#     mode       – "system" (default) or "vendor"
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/common.sh"
source "${REPO_ROOT}/scripts/lib/images.sh"

IMAGE_ROOT="${1:?Usage: install.sh <image_root> [system|vendor]}"
INSTALL_MODE="${2:-system}"

HOUDINI_ASSET_DIR="${MODULE_DIR}/assets/houdini"
NDK_ASSET_DIR="${MODULE_DIR}/assets/ndk_translation"

# ─── Backend selection ────────────────────────────────────────────────────────
_houdini_available() {
    [[ -f "${HOUDINI_ASSET_DIR}/lib64/libhoudini.so" ]] || \
    [[ -f "${HOUDINI_ASSET_DIR}/lib/libhoudini.so"   ]]
}

_ndk_available() {
    [[ -f "${NDK_ASSET_DIR}/lib64/libndk_translation.so" ]] || \
    [[ -f "${NDK_ASSET_DIR}/lib/libndk_translation.so"   ]]
}

_resolve_backend() {
    case "${ARM_TRANSLATION_BACKEND:-auto}" in
        houdini)
            _houdini_available || die "Houdini assets missing. See modules/arm-translation/assets/README.md"
            echo "houdini"
            ;;
        ndk)
            _ndk_available || { _try_fetch_ndk; echo "ndk"; }
            echo "ndk"
            ;;
        auto)
            if _houdini_available; then echo "houdini"
            elif _ndk_available;   then echo "ndk"
            else
                log_info "No ARM translation assets found – attempting NDK fetch…"
                _try_fetch_ndk && echo "ndk" || {
                    log_warn "ARM translation assets unavailable. Skipping injection."
                    echo "none"
                }
            fi
            ;;
        *) die "Unknown ARM_TRANSLATION_BACKEND: ${ARM_TRANSLATION_BACKEND}" ;;
    esac
}

# ─── NDK translation fetch ────────────────────────────────────────────────────
# Downloads libndk_translation from a known community package.
_try_fetch_ndk() {
    local fetch_script="${MODULE_DIR}/fetch-ndk.sh"
    if [[ -x "$fetch_script" ]]; then
        log_info "Running NDK fetch script…"
        bash "$fetch_script" "$NDK_ASSET_DIR"
    else
        log_warn "fetch-ndk.sh not found or not executable."
        return 1
    fi
}

# ─── System image injection ───────────────────────────────────────────────────
_inject_houdini_system() {
    local root="$1"
    log_info "Injecting Intel Houdini (system)…"

    # 32-bit translator
    if [[ -f "${HOUDINI_ASSET_DIR}/lib/libhoudini.so" ]]; then
        inject_file "${HOUDINI_ASSET_DIR}/lib/libhoudini.so" "$root" "lib/libhoudini.so" 0755 root:root
    fi

    # 64-bit translator
    if [[ -f "${HOUDINI_ASSET_DIR}/lib64/libhoudini.so" ]]; then
        inject_file "${HOUDINI_ASSET_DIR}/lib64/libhoudini.so" "$root" "lib64/libhoudini.so" 0755 root:root
    fi

    # houdini/houdini64 binfmt executors (ARM ELF launchers)
    if [[ -f "${HOUDINI_ASSET_DIR}/bin/houdini" ]]; then
        inject_file "${HOUDINI_ASSET_DIR}/bin/houdini"   "$root" "bin/houdini"   0755 root:shell
        inject_file "${HOUDINI_ASSET_DIR}/bin/houdini64" "$root" "bin/houdini64" 0755 root:shell 2>/dev/null || true
    fi

    # houdini arm native libraries (extracted from the asset package)
    for dir in "${HOUDINI_ASSET_DIR}/lib/arm" "${HOUDINI_ASSET_DIR}/lib64/arm64"; do
        [[ -d "$dir" ]] || continue
        local arch_rel
        arch_rel="${dir#${HOUDINI_ASSET_DIR}/}"
        inject_dir "$dir" "$root" "lib/${arch_rel##*/lib/}"
    done

    _inject_binfmt_system "$root" "houdini"
    _inject_arm_props     "$root" "houdini"
    _inject_arm_rc        "$root"
}

_inject_ndk_system() {
    local root="$1"
    log_info "Injecting libndk_translation (system)…"

    for so in lib/libndk_translation.so lib64/libndk_translation.so; do
        local src="${NDK_ASSET_DIR}/${so}"
        [[ -f "$src" ]] && inject_file "$src" "$root" "$so" 0755 root:root
    done

    # NDK config XML
    local cfg_src="${NDK_ASSET_DIR}/etc/ndk_translation_config.xml"
    if [[ -f "$cfg_src" ]]; then
        inject_file "$cfg_src" "$root" "etc/ndk_translation_config.xml" 0644 root:root
    fi

    _inject_binfmt_system "$root" "ndk"
    _inject_arm_props     "$root" "ndk"
    _inject_arm_rc        "$root"
}

_inject_binfmt_system() {
    local root="$1" backend="$2"
    log_info "Installing binfmt_misc rules…"
    mkdir -p "$(_image_realpath "$root" "etc/binfmt_misc")"
    inject_file "${MODULE_DIR}/binfmt/arm_dyn"   "$root" "etc/binfmt_misc/arm_dyn"   0644 root:root
    inject_file "${MODULE_DIR}/binfmt/arm64_dyn" "$root" "etc/binfmt_misc/arm64_dyn" 0644 root:root
    inject_file "${MODULE_DIR}/binfmt/arm_exe"   "$root" "etc/binfmt_misc/arm_exe"   0644 root:root
    inject_file "${MODULE_DIR}/binfmt/arm64_exe" "$root" "etc/binfmt_misc/arm64_exe" 0644 root:root
}

_inject_arm_props() {
    local root="$1" backend="$2"
    # build.prop is at /system/build.prop when root is the system partition
    local build_prop
    if   [[ -f "${root}/system/build.prop" ]]; then build_prop="${root}/system/build.prop"
    elif [[ -f "${root}/build.prop"         ]]; then build_prop="${root}/build.prop"
    else
        log_warn "build.prop not found under $root – skipping ARM props."
        return
    fi

    log_info "Patching build.prop for ARM translation…"
    local bridge_lib
    case "$backend" in
        houdini) bridge_lib="libhoudini.so" ;;
        ndk)     bridge_lib="libndk_translation.so" ;;
    esac

    # NativeBridge registration
    set_prop "$build_prop" "ro.dalvik.vm.native.bridge"    "$bridge_lib"
    set_prop "$build_prop" "ro.enable.native.bridge.exec"  "1"
    set_prop "$build_prop" "ro.dalvik.vm.isa.arm"          "x86"
    set_prop "$build_prop" "ro.dalvik.vm.isa.arm64"        "x86_64"

    # Expand ABI lists to advertise ARM support
    expand_abilist "$build_prop"

    # Also merge backend-specific prop file if present
    local extra_props="${MODULE_DIR}/props/${backend}.prop"
    [[ -f "$extra_props" ]] && merge_prop_file "$extra_props" "$build_prop"
}

_inject_arm_rc() {
    local root="$1"
    inject_rc "${MODULE_DIR}/rc/waydroid-arm.rc" "$root"
}

# ─── Vendor image injection ───────────────────────────────────────────────────
_inject_houdini_vendor() {
    local root="$1"
    log_info "Injecting Houdini vendor-side files…"

    for so in lib/libhoudini.so lib64/libhoudini.so; do
        local src="${HOUDINI_ASSET_DIR}/${so}"
        [[ -f "$src" ]] && inject_file "$src" "$root" "$so" 0755 root:root
    done
}

_inject_ndk_vendor() {
    local root="$1"
    log_info "Injecting NDK translation vendor-side files…"

    for so in lib/libndk_translation.so lib64/libndk_translation.so; do
        local src="${NDK_ASSET_DIR}/${so}"
        [[ -f "$src" ]] && inject_file "$src" "$root" "$so" 0755 root:root
    done
}

# ─── Entry point ─────────────────────────────────────────────────────────────
main() {
    local backend
    backend="$(_resolve_backend)"

    if [[ "$backend" == "none" ]]; then
        log_warn "ARM translation skipped (no assets available)."
        return 0
    fi

    log_info "ARM translation backend: $backend  mode: $INSTALL_MODE"

    case "$INSTALL_MODE" in
        system)
            case "$backend" in
                houdini) _inject_houdini_system "$IMAGE_ROOT" ;;
                ndk)     _inject_ndk_system     "$IMAGE_ROOT" ;;
            esac
            ;;
        vendor)
            case "$backend" in
                houdini) _inject_houdini_vendor "$IMAGE_ROOT" ;;
                ndk)     _inject_ndk_vendor     "$IMAGE_ROOT" ;;
            esac
            ;;
        *) die "Unknown install mode: $INSTALL_MODE" ;;
    esac

    log_ok "ARM translation injection complete (${backend}, ${INSTALL_MODE})."
}

main
