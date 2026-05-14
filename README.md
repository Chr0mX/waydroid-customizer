# waydroid-customizer

Production-grade pipeline for customizing prebuilt Waydroid x86_64 images —
ARM translation, runtime device spoofing, and automated CI/CD.

```
download → unpack → patch-vendor → patch-system → repack → publish
```

No AOSP source build required. The pipeline starts from official LineageOS 18.1
Waydroid images and injects modifications via overlay and property injection.

---

## Table of contents

1. [Quick start](#quick-start)
2. [Repository layout](#repository-layout)
3. [Architecture](#architecture)
   - [ARM translation](#arm-translation)
   - [Device spoofing](#device-spoofing)
   - [Image manipulation strategy](#image-manipulation-strategy)
4. [Configuration](#configuration)
5. [Running locally](#running-locally)
6. [CI/CD with GitHub Actions](#cicd-with-github-actions)
7. [Runtime profile switching (host)](#runtime-profile-switching-host)
8. [Upstream update workflow](#upstream-update-workflow)
9. [Adding a custom spoof profile](#adding-a-custom-spoof-profile)
10. [ARM translation assets](#arm-translation-assets)

---

## Quick start

```bash
# Clone
git clone https://github.com/chr0mx/waydroid-customizer
cd waydroid-customizer

# Build both vanilla and GAPPS variants with Pixel 6a identity
sudo BUILD_VARIANT=both SPOOF_PROFILE=pixel-6a bash scripts/pipeline.sh

# Output
ls work/output/*.zip
```

Requires root (loop mount), `simg2img/img2simg`, `e2fsprogs`, `unzip`, `zip`,
`curl`, `python3`, `bc`.

Install on Ubuntu/Debian:
```bash
sudo apt-get install android-sdk-libsparse-utils e2fsprogs unzip zip curl python3 bc
```

Or use Docker (no host deps other than Docker + `--privileged`):
```bash
bash tools/docker-run.sh --variant vanilla
```

---

## Repository layout

```
waydroid-customizer/
├── config/
│   ├── images.conf          # Upstream URLs and version pins
│   └── pipeline.conf        # Build flags, paths, feature toggles
│
├── scripts/
│   ├── pipeline.sh          # Orchestrator – runs all stages in order
│   ├── download.sh          # Stage 1: download upstream ZIPs
│   ├── unpack.sh            # Stage 2: unzip + simg2img + resize
│   ├── patch-system.sh      # Stage 3a: patch system image
│   ├── patch-vendor.sh      # Stage 3b: patch vendor image
│   ├── repack.sh            # Stage 4: img2simg + zip + sha256
│   └── lib/
│       ├── common.sh        # Logging, download, state machine
│       ├── images.sh        # Mount/unmount, prop editing, file injection
│       └── versions.sh      # Version tracking, upstream probe
│
├── modules/
│   ├── arm-translation/
│   │   ├── install.sh       # Injects ARM translation into a mounted image
│   │   ├── fetch-ndk.sh     # Downloads libndk_translation automatically
│   │   ├── binfmt/          # binfmt_misc rule files (arm_dyn, arm64_dyn, …)
│   │   ├── props/           # Backend-specific property additions
│   │   ├── rc/              # Init RC fragment for binfmt registration
│   │   └── assets/          # Binary assets dir (gitignored); see assets/README.md
│   │
│   └── spoof/
│       ├── install.sh       # Merges profile props + injects runtime loader
│       ├── profiles/        # JSON device identity profiles
│       │   ├── pixel-6a.json
│       │   ├── pixel-4a.json
│       │   ├── samsung-s21.json
│       │   └── generic-x86.json
│       ├── rc/              # Init RC fragment for runtime spoof loader
│       └── scripts/         # spoof-loader.sh (injected into /system/bin/)
│
├── overlays/
│   ├── system/              # Files copied verbatim into the system image root
│   └── vendor/              # Files copied verbatim into the vendor image root
│
├── tools/
│   ├── Dockerfile           # Self-contained build environment
│   ├── docker-run.sh        # Convenience wrapper for Docker builds
│   └── set-spoof-profile.sh # Host-side runtime profile switcher
│
├── .github/
│   └── workflows/
│       ├── build.yml        # Full build + release pipeline
│       └── update-check.yml # Daily upstream version poller
│
└── versions.json            # Tracks last-built upstream dates
```

---

## Architecture

### ARM translation

ARM translation is injected as a **module** (`modules/arm-translation/`).
Two backends are supported:

| Backend | Library | Source |
|---------|---------|--------|
| `houdini` | Intel `libhoudini.so` | Proprietary – see [ARM translation assets](#arm-translation-assets) |
| `ndk` | `libndk_translation.so` | ChromeOS community package – auto-fetched by `fetch-ndk.sh` |
| `auto` | tries houdini first | Graceful fallback to ndk, warns if neither available |

**What gets injected (system image):**

- `lib/libhoudini.so` / `lib64/libhoudini.so` (or ndk equivalent)
- `/system/bin/houdini` + `houdini64` — ELF launchers that the kernel calls
  via `binfmt_misc` for ARM binaries
- `/system/etc/binfmt_misc/arm_dyn`, `arm64_dyn`, `arm_exe`, `arm64_exe` —
  kernel registration rule files
- `/system/etc/init/waydroid-arm.rc` — init fragment that writes the `binfmt_misc`
  entries at `post-fs-data` time
- `build.prop` additions:
  ```
  ro.dalvik.vm.native.bridge=libhoudini.so
  ro.enable.native.bridge.exec=1
  ro.dalvik.vm.isa.arm=x86
  ro.dalvik.vm.isa.arm64=x86_64
  ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
  ```

**Design principle:** no binary patching of existing ELFs.  All ARM translation
plumbing goes through Android's official `NativeBridge` API (`ro.dalvik.vm.native.bridge`),
which survives upstream image updates as long as LineageOS 18.1 keeps shipping
standard AOSP init and ART.

---

### Device spoofing

Spoof profiles are JSON files in `modules/spoof/profiles/`.  A profile contains
the full set of `ro.product.*` and `ro.build.*` properties for a target device.

**Two injection layers:**

1. **Build-time** – profile properties are merged into `system/build.prop` and
   `vendor/build.prop` during image patching.  This ensures the identity is
   available from the very first boot, including during OTA checks.

2. **Runtime** – a small shell service (`waydroid-spoof-loader`) is injected
   into `/system/bin/`.  On each boot it reads
   `/data/waydroid-spoof/active.prop` (a host-writable path) and applies the
   properties via `setprop`.  This allows switching profiles without rebuilding
   images (see [Runtime profile switching](#runtime-profile-switching-host)).

**Profile format:**
```json
{
  "name": "Google Pixel 6a",
  "id": "pixel-6a",
  "description": "…",
  "props": {
    "ro.product.model": "Pixel 6a",
    "ro.build.fingerprint": "google/bluejay/…",
    "ro.build.version.sdk": "33"
  }
}
```

Add a new profile by dropping a `.json` file into `modules/spoof/profiles/`
and setting `SPOOF_PROFILE=<id>` in `config/pipeline.conf` or as an env var.

---

### Image manipulation strategy

1. **No binary patching.** File injection only – `cp` into a mounted EXT4.
2. **Overlay-first.** Generic overlay files in `overlays/system/` and
   `overlays/vendor/` are applied before module scripts.  Modules can then
   further modify the image.
3. **Property merging via upsert.** `set_prop()` in `images.sh` does a
   find-and-replace on existing keys; it appends new keys.  Idempotent.
4. **Sparse ↔ raw round-trip.** `simg2img` → patch → `img2simg`.  The pipeline
   resizes the raw EXT4 before patching to create headroom for injected files
   (`SYSTEM_EXTRA_BYTES`, default 128 MiB).
5. **e2fsck on every boundary.** Run before mount and after unmount to keep
   the filesystem clean.
6. **State machine.** Each pipeline stage writes a `.done` marker to
   `work/state/`.  Re-running `pipeline.sh` skips completed stages.
   Use `--from-stage <stage>` to resume from a failure point.

---

## Configuration

### `config/images.conf`

| Variable | Purpose |
|----------|---------|
| `UPSTREAM_DATE` | Date tag in upstream filenames (e.g. `20250628`) |
| `VENDOR_URL` / `SYSTEM_VANILLA_URL` / `SYSTEM_GAPPS_URL` | Direct download URLs |
| `*_SHA256` | Optional SHA-256 for integrity verification |

### `config/pipeline.conf`

| Variable | Default | Purpose |
|----------|---------|---------|
| `BUILD_VARIANT` | `both` | `vanilla` \| `gapps` \| `both` |
| `ENABLE_ARM_TRANSLATION` | `true` | Enable ARM translation module |
| `ENABLE_SPOOF` | `true` | Enable device spoof module |
| `ARM_TRANSLATION_BACKEND` | `auto` | `houdini` \| `ndk` \| `auto` |
| `SPOOF_PROFILE` | `pixel-6a` | Profile name from `modules/spoof/profiles/` |
| `SYSTEM_EXTRA_BYTES` | `128 MiB` | Extra headroom when resizing system image |
| `VENDOR_EXTRA_BYTES` | `32 MiB` | Extra headroom when resizing vendor image |

All variables can be overridden via environment:
```bash
sudo SPOOF_PROFILE=samsung-s21 BUILD_VARIANT=gapps bash scripts/pipeline.sh
```

---

## Running locally

```bash
# Full pipeline
sudo bash scripts/pipeline.sh

# Single variant
sudo BUILD_VARIANT=vanilla bash scripts/pipeline.sh

# Resume from patch stage after a failure
sudo bash scripts/pipeline.sh --from-stage patch-system

# Clean and restart
sudo bash scripts/pipeline.sh --clean

# Dry-run (shows what would execute)
sudo bash scripts/pipeline.sh --dry-run
```

### Via Docker (no host deps)

```bash
# Build image once
docker build -t waydroid-customizer-build tools/

# Run pipeline
docker run --rm --privileged \
  -v "$(pwd)":/workspace \
  -e BUILD_VARIANT=both \
  -e SPOOF_PROFILE=pixel-6a \
  waydroid-customizer-build

# Or use the wrapper
bash tools/docker-run.sh --variant vanilla
```

---

## CI/CD with GitHub Actions

### `build.yml` – Full build pipeline

Triggered by:
- **Manual** (`workflow_dispatch`) with inputs for variant, spoof profile, ARM backend
- **Push** to `main` when `config/images.conf`, `modules/`, `overlays/`, or
  `scripts/` change
- **Schedule** – weekly Monday rebuild

Flow:
```
download (cached) → build-vanilla ─┐
                 → build-gapps    ─┴─ release (GitHub Release + artifacts)
```

Artifacts are uploaded as GitHub Release assets with SHA-256 checksums and a
`manifest.json`.

### `update-check.yml` – Upstream version poller

Runs daily at 06:00 UTC.  Probes the SourceForge directory listing for new
image date tags.  When a newer date is found, it:
1. Bumps `UPSTREAM_DATE` in `config/images.conf`
2. Opens a pull request (`auto/upstream-<date>`)

Merging the PR triggers `build.yml` automatically.

---

## Runtime profile switching (host)

```bash
# List available profiles
bash tools/set-spoof-profile.sh --list

# Apply a profile (writes to /var/lib/waydroid/data/waydroid-spoof/active.prop)
sudo bash tools/set-spoof-profile.sh pixel-4a

# Restart Waydroid to activate
waydroid session stop && waydroid session start

# Revert to build-time identity
sudo bash tools/set-spoof-profile.sh --clear
```

The `active.prop` file is read by `waydroid-spoof-loader` (a oneshot init
service) on every boot.  The build-time identity from `build.prop` acts as the
fallback when no `active.prop` is present.

---

## Upstream update workflow

When a new Waydroid image set is released on SourceForge:

1. The `update-check.yml` workflow detects the new date tag.
2. A PR bumps `UPSTREAM_DATE` in `config/images.conf`.
3. Review the PR – check that the new URLs are valid.
4. Merge → `build.yml` triggers a full rebuild.

**Manual bump:**
```bash
source scripts/lib/versions.sh
bump_version 20251231
git add config/images.conf
git commit -m "chore: bump upstream to 20251231"
```

---

## Adding a custom spoof profile

1. Create `modules/spoof/profiles/<id>.json`:
   ```json
   {
     "name": "My Device",
     "id": "my-device",
     "description": "Custom identity",
     "props": {
       "ro.product.model": "My Device",
       "ro.build.fingerprint": "brand/device/…",
       "ro.build.version.sdk": "33"
     }
   }
   ```
2. Set `SPOOF_PROFILE=my-device` in `config/pipeline.conf` (or as env var).
3. Rebuild.  The profile is also automatically copied into the image so the
   runtime loader can reference it.

---

## ARM translation assets

The `modules/arm-translation/assets/` directory is **gitignored** (binaries
are not redistributed here).  See `modules/arm-translation/assets/README.md`
for sourcing instructions.

**Automated (libndk_translation):**
```bash
bash modules/arm-translation/fetch-ndk.sh modules/arm-translation/assets/ndk_translation
```

**Manual (Intel Houdini):**
See `modules/arm-translation/assets/README.md` for extraction methods from
ChromeOS images or the `waydroid_script` community tool.

If no ARM translation assets are available, the pipeline completes
successfully but the resulting images will not run ARM-only apps.

---

## License

Scripts and configuration in this repository are released under the MIT License.
Upstream Waydroid/LineageOS images retain their respective licenses.
ARM translation binaries (Houdini, libndk_translation) are governed by their
respective upstream licenses and are **not** included in this repository.
