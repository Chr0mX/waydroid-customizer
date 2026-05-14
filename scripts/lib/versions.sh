#!/usr/bin/env bash
# scripts/lib/versions.sh – version tracking and upstream update detection
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSIONS_JSON="${REPO_ROOT}/versions.json"

# ─── Read / write versions.json ──────────────────────────────────────────────
versions_get() {
    local key="$1"
    if [[ -f "$VERSIONS_JSON" ]]; then
        python3 -c "import json,sys; d=json.load(open('${VERSIONS_JSON}')); print(d.get('${key}',''))" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

versions_set() {
    local key="$1" value="$2"
    local tmp
    tmp="$(mktemp)"
    if [[ -f "$VERSIONS_JSON" ]]; then
        python3 - "$VERSIONS_JSON" "$key" "$value" "$tmp" <<'EOF'
import json, sys
path, k, v, out = sys.argv[1:]
with open(path) as f:
    d = json.load(f)
d[k] = v
with open(out, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
EOF
    else
        python3 - "$key" "$value" "$tmp" <<'EOF'
import json, sys
k, v, out = sys.argv[1:]
with open(out, 'w') as f:
    json.dump({k: v}, f, indent=2)
    f.write('\n')
EOF
    fi
    mv "$tmp" "$VERSIONS_JSON"
}

# ─── Record a completed build ────────────────────────────────────────────────
record_build() {
    local variant="$1"
    local upstream_date="$2"
    local build_ts
    build_ts="$(date -u +%Y%m%dT%H%M%SZ)"

    versions_set "last_build_${variant}"    "$build_ts"
    versions_set "upstream_date_${variant}" "$upstream_date"
    log_ok "Recorded build: variant=${variant} upstream=${upstream_date} built=${build_ts}"
}

# ─── Probe SourceForge for latest image date tag ─────────────────────────────
# Returns the most recent YYYYMMDD date found in the listing page.
probe_latest_date() {
    local index_url="$1"
    require_cmd curl python3

    local html
    html="$(curl -fsSL --connect-timeout 20 --retry 3 "$index_url" 2>/dev/null)" || {
        log_warn "Could not fetch index: $index_url"
        echo ""
        return
    }

    # Extract all 8-digit date tags embedded in filenames.
    python3 - "$html" <<'EOF'
import sys, re
html = sys.argv[1]
dates = re.findall(r'lineage-\d+\.\d+-(\d{8})-', html)
if dates:
    print(max(dates))
else:
    print('')
EOF
}

# ─── Compare pinned vs live version ──────────────────────────────────────────
check_upstream_update() {
    source "${REPO_ROOT}/config/images.conf"
    local pinned="${UPSTREAM_DATE}"

    log_info "Pinned upstream date: $pinned"

    local latest_vendor latest_system
    latest_vendor="$(probe_latest_date "$SF_VENDOR_INDEX")"
    latest_system="$(probe_latest_date "$SF_SYSTEM_INDEX")"

    log_info "Latest vendor date:   ${latest_vendor:-unknown}"
    log_info "Latest system date:   ${latest_system:-unknown}"

    local latest="${latest_system:-$latest_vendor}"
    if [[ -n "$latest" && "$latest" > "$pinned" ]]; then
        echo "UPDATE_AVAILABLE=true"
        echo "LATEST_DATE=$latest"
    else
        echo "UPDATE_AVAILABLE=false"
        echo "LATEST_DATE=${latest:-$pinned}"
    fi
}

# ─── Bump pinned version in images.conf ──────────────────────────────────────
bump_version() {
    local new_date="$1"
    local conf="${REPO_ROOT}/config/images.conf"
    sed -i "s/^UPSTREAM_DATE=.*/UPSTREAM_DATE=\"${new_date}\"/" "$conf"
    # Update all *_VERSION variables that mirror UPSTREAM_DATE
    sed -i "s/^VENDOR_VERSION=.*/VENDOR_VERSION=\"\${UPSTREAM_DATE}\"/" "$conf"
    sed -i "s/^SYSTEM_VANILLA_VERSION=.*/SYSTEM_VANILLA_VERSION=\"\${UPSTREAM_DATE}\"/" "$conf"
    sed -i "s/^SYSTEM_GAPPS_VERSION=.*/SYSTEM_GAPPS_VERSION=\"\${UPSTREAM_DATE}\"/" "$conf"
    log_ok "Bumped UPSTREAM_DATE to $new_date in images.conf"
}
