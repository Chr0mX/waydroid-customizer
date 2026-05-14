#!/system/bin/sh
# /system/bin/waydroid-spoof-loader
# Runs as a oneshot init service on boot.
# Reads /data/waydroid-spoof/active.prop and applies each property via setprop.

SPOOF_DIR=/data/waydroid-spoof
ACTIVE_PROP=${SPOOF_DIR}/active.prop

if [ ! -f "${ACTIVE_PROP}" ]; then
    log -t waydroid-spoof "No active.prop found – using build-time identity."
    exit 0
fi

log -t waydroid-spoof "Applying runtime spoof profile from ${ACTIVE_PROP}"

while IFS= read -r line; do
    # Skip blank lines and comments
    case "$line" in
        ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    setprop "$key" "$value" && \
        log -t waydroid-spoof "  set ${key}=${value}" || \
        log -t waydroid-spoof "  FAILED: ${key}"
done < "${ACTIVE_PROP}"

log -t waydroid-spoof "Runtime spoof complete."
