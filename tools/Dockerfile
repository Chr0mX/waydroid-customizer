# Waydroid Customizer – build environment
# Provides all tools needed to run the pipeline locally without installing
# system packages on the host.
#
# Build:  docker build -t waydroid-customizer tools/
# Run:    docker run --rm --privileged \
#           -v "$(pwd)":/workspace \
#           -e BUILD_VARIANT=both \
#           -e SPOOF_PROFILE=pixel-6a \
#           waydroid-customizer bash scripts/pipeline.sh
#
# NOTE: --privileged (or at minimum CAP_SYS_ADMIN + /dev/loop* access) is
#       required for loop mount operations.  In CI, use a VM runner instead of
#       a Docker container when possible.

FROM ubuntu:24.04

LABEL org.opencontainers.image.title="waydroid-customizer-build"
LABEL org.opencontainers.image.description="Build environment for Waydroid image customization pipeline"

ENV DEBIAN_FRONTEND=noninteractive \
    WORK_DIR=/workspace/work

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Sparse image tools
    android-sdk-libsparse-utils \
    # Filesystem tools
    e2fsprogs \
    util-linux \
    # Archive tools
    unzip \
    zip \
    # Download
    curl \
    ca-certificates \
    # Scripting
    bash \
    python3 \
    python3-pip \
    # Build math (for bc in scripts)
    bc \
    # Checksum
    coreutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Default entrypoint runs the full pipeline
ENTRYPOINT ["bash", "scripts/pipeline.sh"]
CMD ["--help"]
