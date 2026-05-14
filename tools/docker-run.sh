#!/usr/bin/env bash
# tools/docker-run.sh – Convenience wrapper to run the pipeline in Docker.
#
# Usage: tools/docker-run.sh [pipeline.sh args…]
#   e.g: tools/docker-run.sh --variant vanilla --dry-run
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="waydroid-customizer-build"

# Build the image if it doesn't exist or Dockerfile changed
if ! docker image inspect "$IMAGE_NAME" &>/dev/null || \
   [[ "${REBUILD:-false}" == "true" ]]; then
    echo "Building Docker image: $IMAGE_NAME"
    docker build -t "$IMAGE_NAME" "${REPO_ROOT}/tools/"
fi

exec docker run --rm \
    --privileged \
    -v "${REPO_ROOT}:/workspace" \
    -e "BUILD_VARIANT=${BUILD_VARIANT:-both}" \
    -e "SPOOF_PROFILE=${SPOOF_PROFILE:-pixel-6a}" \
    -e "ARM_TRANSLATION_BACKEND=${ARM_TRANSLATION_BACKEND:-auto}" \
    "$IMAGE_NAME" "$@"
