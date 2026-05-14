#!/usr/bin/env bash
# scripts/lib/images.sh – EXT4 image mount/unmount and file-injection helpers
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ─── Sparse ↔ raw conversion ─────────────────────────────────────────────────
sparse_to_raw() {
    local sparse="$1" raw="$2"
    require_cmd simg2img
    log_info "Converting sparse → raw: $(basename "$sparse")"
    simg2img "$sparse" "$raw"
    log_ok "Raw image: $raw ($(human_bytes "$(stat -c%s "$raw")"))"
}

raw_to_sparse() {
    local raw="$1" sparse="$2"
    require_cmd img2simg
    log_info "Converting raw → sparse: $(basename "$raw")"
    img2simg "$raw" "$sparse"
    log_ok "Sparse image: $sparse ($(human_bytes "$(stat -c%s "$sparse")"))"
}

# ─── Resize a raw EXT4 image to accommodate extra bytes ──────────────────────
resize_raw_image() {
    local img="$1"
    local extra_bytes="${2:-$((128 * 1024 * 1024))}"
    require_cmd e2fsck resize2fs

    local current_size
    current_size="$(stat -c%s "$img")"
    local new_size=$(( current_size + extra_bytes ))
    # Round up to nearest 4096-byte block
    new_size=$(( (new_size + 4095) / 4096 * 4096 ))

    log_info "Resizing image: $(human_bytes "$current_size") → $(human_bytes "$new_size")"
    truncate -s "$new_size" "$img"
    e2fsck -fy "$img" &>/dev/null || true
    resize2fs "$img" &>/dev/null
    log_ok "Image resized."
}

# ─── Mount / unmount loop ────────────────────────────────────────────────────
mount_image() {
    local img="$1" mnt="$2"
    require_cmd mount
    mkdir -p "$mnt"
    log_info "Mounting $(basename "$img") → $mnt"
    mount -o loop,rw "$img" "$mnt"
}

unmount_image() {
    local mnt="$1"
    if mountpoint -q "$mnt" 2>/dev/null; then
        log_info "Unmounting $mnt"
        sync
        umount "$mnt"
    fi
}

# ─── Safe unmount on exit ────────────────────────────────────────────────────
# Usage: register_unmount /mnt/point
#   Call once per mount. The trap fires at script exit.
_REGISTERED_MOUNTS=()
register_unmount() {
    _REGISTERED_MOUNTS+=("$1")
    trap '_unmount_all_registered' EXIT INT TERM
}

_unmount_all_registered() {
    local mnt
    for mnt in "${_REGISTERED_MOUNTS[@]:-}"; do
        unmount_image "$mnt" || true
    done
}

# ─── File injection into a mounted image ─────────────────────────────────────
# inject_file <src> <image_root> <dest_path_inside_image> [mode] [owner:group]
inject_file() {
    local src="$1"
    local image_root="$2"
    local dest_rel="$3"
    local mode="${4:-0644}"
    local owner="${5:-root:root}"

    local dest="${image_root}/${dest_rel#/}"
    mkdir -p "$(dirname "$dest")"
    cp -af "$src" "$dest"
    chmod "$mode" "$dest"
    chown "$owner" "$dest" 2>/dev/null || true
    log_info "Injected: $dest_rel"
}

# inject_dir <src_dir> <image_root> <dest_dir_inside_image>
inject_dir() {
    local src_dir="$1"
    local image_root="$2"
    local dest_dir_rel="$3"

    local dest="${image_root}/${dest_dir_rel#/}"
    mkdir -p "$dest"
    cp -af "$src_dir/." "$dest/"
    log_info "Injected directory: $dest_dir_rel"
}

# ─── Property file manipulation ──────────────────────────────────────────────
# set_prop <prop_file> <key> <value>
# Upserts a key=value in an Android property file.
set_prop() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# append_prop_block <prop_file> <marker> <block>
# Append a multi-line block once, guarded by a marker comment.
append_prop_block() {
    local file="$1" marker="$2"
    shift 2
    if grep -qF "$marker" "$file" 2>/dev/null; then
        log_info "Property block '$marker' already present – skipping."
        return 0
    fi
    {
        echo ""
        echo "# $marker"
        printf '%s\n' "$@"
    } >> "$file"
    log_info "Appended property block: $marker"
}

# merge_prop_file <additions_file> <target_prop_file>
# Each line that isn't a comment/blank either upserts or appends.
merge_prop_file() {
    local additions="$1" target="$2"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local k="${line%%=*}" v="${line#*=}"
        set_prop "$target" "$k" "$v"
    done < "$additions"
    log_ok "Properties merged from $(basename "$additions") → $(basename "$target")"
}

# ─── ABI list patching ───────────────────────────────────────────────────────
# expand_abilist <prop_file> – adds ARM ABI entries alongside x86/x86_64
expand_abilist() {
    local prop_file="$1"

    local list64 list32
    list64="$(grep '^ro.product.cpu.abilist64=' "$prop_file" | head -1 | cut -d= -f2)"
    list32="$(grep '^ro.product.cpu.abilist32=' "$prop_file" | head -1 | cut -d= -f2)"

    # Add arm64-v8a to 64-bit list if not already present
    if [[ "$list64" != *"arm64-v8a"* ]]; then
        set_prop "$prop_file" "ro.product.cpu.abilist64" "${list64},arm64-v8a"
    fi

    # Add armeabi-v7a,armeabi to 32-bit list
    if [[ "$list32" != *"armeabi"* ]]; then
        set_prop "$prop_file" "ro.product.cpu.abilist32" "${list32},armeabi-v7a,armeabi"
    fi

    # Full combined list
    local full="x86_64,x86,arm64-v8a,armeabi-v7a,armeabi"
    set_prop "$prop_file" "ro.product.cpu.abilist" "$full"

    log_ok "ABI lists expanded: $full"
}

# ─── RC script injection ─────────────────────────────────────────────────────
# inject_rc <src_rc> <image_root>
# Places an init.rc fragment in /system/etc/init/ where Android's init picks it up.
inject_rc() {
    local src_rc="$1"
    local image_root="$2"
    inject_file "$src_rc" "$image_root" "etc/init/$(basename "$src_rc")" 0644 root:root
}
