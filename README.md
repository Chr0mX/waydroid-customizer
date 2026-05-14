# waydroid-customizer

Production-grade pipeline for customizing prebuilt Waydroid x86_64 images —
ARM translation, Widevine L3 DRM, runtime device spoofing, Play Integrity
compatibility, and automated CI/CD.

```
download → unpack → patch-vendor → patch-system → repack → publish
```

No AOSP source build required. The pipeline starts from official LineageOS 18.1
Waydroid images and injects modifications via overlay and property injection.

---

## Table of contents

1. [Quick install (end users)](#quick-install-end-users)
2. [Quick start (build from source)](#quick-start-build-from-source)
3. [Repository layout](#repository-layout)
4. [Architecture](#architecture)
   - [ARM translation](#arm-translation)
   - [Widevine L3 DRM](#widevine-l3-drm)
   - [Device spoofing & Play Integrity](#device-spoofing--play-integrity)
   - [Image manipulation strategy](#image-manipulation-strategy)
5. [Configuration](#configuration)
6. [Running locally](#running-locally)
7. [CI/CD with GitHub Actions](#cicd-with-github-actions)
8. [Runtime profile switching (host)](#runtime-profile-switching-host)
9. [Overlay module installation](#overlay-module-installation)
10. [Upstream update workflow](#upstream-update-workflow)
11. [Adding a custom spoof profile](#adding-a-custom-spoof-profile)
12. [ARM translation assets](#arm-translation-assets)

---

## Quick install (end users)

Install Waydroid and apply the latest custom images in one command
(Ubuntu/Debian only):

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/install.sh)
```

With options:

```bash
# GAPPS variant, Samsung S21 identity, no prompts
sudo bash <(curl -fsSL .../tools/install.sh) --variant gapps --profile samsung-s21 --yes

# Already have Waydroid — just swap images
sudo bash <(curl -fsSL .../tools/install.sh) --images-only --variant vanilla

# Add Widevine L3 to an already-installed system (no image rebuild)
sudo bash <(curl -fsSL .../tools/install.sh) --overlay-modules widevine

# Full install + Widevine overlay in one command
sudo bash <(curl -fsSL .../tools/install.sh) --variant vanilla --overlay-modules widevine --yes
```

### Installer options

| Flag | Default | Description |
|------|---------|-------------|
| `--variant vanilla\|gapps` | prompt | Image variant |
| `--profile <name>` | `pixel-6a` | Device spoof profile baked in at first boot |
| `--release vDATE-custom` | latest | Pin a specific release tag |
| `--images-only` | — | Skip Waydroid apt install; replace images only |
| `--overlay-modules <list>` | — | Runtime modules via overlay (see [below](#overlay-module-installation)) |
| `--yes` | — | Non-interactive; accept all defaults |

### Available spoof profiles

| Profile | Device | Android |
|---------|--------|---------|
| `pixel-6a` | Google Pixel 6a | 13 |
| `pixel-4a` | Google Pixel 4a | 12 |
| `samsung-s21` | Samsung Galaxy S21 | 12 |
| `generic-x86` | Minimal / passthrough | — |
| `none` | Skip profile injection | — |

---

## Quick start (build from source)

```bash
git clone https://github.com/chr0mx/waydroid-customizer
cd waydroid-customizer

# Build both vanilla and GAPPS variants with Pixel 6a identity
sudo BUILD_VARIANT=both SPOOF_PROFILE=pixel-6a bash scripts/pipeline.sh

ls work/output/*.zip
```

Requires root (loop mount), `simg2img/img2simg`, `e2fsprogs`, `unzip`, `zip`,
`curl`, `python3`, `bc`.

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
│   ├── widevine/
│   │   ├── install.sh       # Injects Widevine L3 blobs into vendor image
│   │   ├── fetch-widevine.sh# Downloads libwvhidl.so + libwvdrmengine.so
│   │   └── assets/          # Cached blobs dir (gitignored)
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
│   ├── install.sh           # End-user one-command installer (curl-installable)
│   ├── set-spoof-profile.sh # Host-side runtime profile switcher
│   ├── Dockerfile           # Self-contained build environment
│   └── docker-run.sh        # Convenience wrapper for Docker builds
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
- `/system/bin/houdini` + `houdini64` — ELF launchers called by the kernel via `binfmt_misc`
- `/system/etc/binfmt_misc/arm_dyn`, `arm64_dyn`, `arm_exe`, `arm64_exe` — kernel registration rules
- `/system/etc/init/waydroid-arm.rc` — init fragment that writes `binfmt_misc` entries at `post-fs-data`
- `build.prop` additions:
  ```
  ro.dalvik.vm.native.bridge=libhoudini.so
  ro.enable.native.bridge.exec=1
  ro.dalvik.vm.isa.arm=x86
  ro.dalvik.vm.isa.arm64=x86_64
  ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
  ```

**Design principle:** no binary patching of existing ELFs. All plumbing goes
through Android's official `NativeBridge` API (`ro.dalvik.vm.native.bridge`),
which survives upstream image updates.

---

### Widevine L3 DRM

Widevine L3 is **software-only DRM** that enables SD and HD playback on
streaming services (Netflix, Prime Video, Disney+, etc.).
**L1 (hardware TEE) is impossible in a container** and is not attempted.

Injected into the **vendor image** by `modules/widevine/install.sh`:

| File | Destination |
|------|-------------|
| `libwvhidl.so` | `/vendor/lib64/` |
| `libwvdrmengine.so` | `/vendor/lib64/mediadrm/` |
| Widevine HAL manifest | `/vendor/etc/vintf/manifest/` |

Blobs are sourced from the community ChromeOS-x86 vendor package and
downloaded automatically by `fetch-widevine.sh` if not pre-staged.

Controlled by `ENABLE_WIDEVINE=true` (default on). Disable in CI with
`ENABLE_WIDEVINE=false` or in the `workflow_dispatch` input.

---

### Device spoofing & Play Integrity

Spoof profiles are JSON files in `modules/spoof/profiles/`. Each profile
contains `ro.product.*`, `ro.build.*`, and **Play Integrity attestation props**.

**Two injection layers:**

1. **Build-time** — profile properties are merged into `system/build.prop` and
   `vendor/build.prop` during image patching.

2. **Runtime** — `waydroid-spoof-loader` (a oneshot init service injected into
   `/system/bin/`) reads `/data/waydroid-spoof/active.prop` on each boot and
   applies properties via `setprop`. Allows switching profiles without rebuilding
   (see [Runtime profile switching](#runtime-profile-switching-host)).

**Play Integrity props** (included in all profiles):

```
ro.secure=1
ro.debuggable=0
ro.boot.verifiedbootstate=green
ro.boot.flash.locked=1
ro.boot.veritymode=enforcing
ro.boot.warranty_bit=0
ro.warranty_bit=0
```

These props enable **BASIC** and **DEVICE** Play Integrity attestation levels,
required by banking apps, Google Pay, and apps using SafetyNet.
`STRONG` attestation (hardware-backed TEE) is impossible in a container.

**Profile format:**
```json
{
  "name": "Google Pixel 6a",
  "id": "pixel-6a",
  "description": "…",
  "props": {
    "ro.product.model": "Pixel 6a",
    "ro.build.fingerprint": "google/bluejay/bluejay:13/…",
    "ro.build.version.sdk": "33",
    "ro.boot.verifiedbootstate": "green"
  }
}
```

---

### Image manipulation strategy

1. **No binary patching.** File injection only — `cp` into a mounted EXT4.
2. **Overlay-first.** Generic overlay files in `overlays/system/` and
   `overlays/vendor/` are applied before module scripts.
3. **Property merging via upsert.** `set_prop()` in `images.sh` does a
   find-and-replace on existing keys; appends new ones. Idempotent.
4. **Sparse ↔ raw round-trip.** `simg2img` → patch → `img2simg`. The pipeline
   resizes the raw EXT4 before patching (`SYSTEM_EXTRA_BYTES`, default 128 MiB).
5. **Symlink-aware injection.** `_image_realpath()` resolves absolute symlinks
   (e.g. `/etc → /system/etc` in system-as-root images) to host paths before
   `mkdir -p`, preventing "File exists" failures under `set -e`.
6. **e2fsck on every boundary.** Run before mount and after unmount.
7. **State machine.** Each stage writes a `.done` marker to `work/state/`.
   Re-running `pipeline.sh` skips completed stages. Use `--from-stage <stage>`
   to resume from a failure point.

---

## Configuration

### `config/images.conf`

| Variable | Purpose |
|----------|---------|
| `UPSTREAM_DATE` | Date tag in upstream filenames (e.g. `20250628`) |
| `VENDOR_URL` / `SYSTEM_VANILLA_URL` / `SYSTEM_GAPPS_URL` | Download URLs |
| `*_SHA256` | Optional SHA-256 for integrity verification |

### `config/pipeline.conf`

| Variable | Default | Purpose |
|----------|---------|---------|
| `BUILD_VARIANT` | `both` | `vanilla` \| `gapps` \| `both` |
| `ENABLE_ARM_TRANSLATION` | `true` | Enable ARM translation module |
| `ENABLE_WIDEVINE` | `true` | Enable Widevine L3 DRM injection |
| `ENABLE_SPOOF` | `true` | Enable device spoof module |
| `ARM_TRANSLATION_BACKEND` | `auto` | `houdini` \| `ndk` \| `auto` |
| `SPOOF_PROFILE` | `pixel-6a` | Profile name from `modules/spoof/profiles/` |
| `SYSTEM_EXTRA_BYTES` | `128 MiB` | Extra headroom when resizing system image |
| `VENDOR_EXTRA_BYTES` | `32 MiB` | Extra headroom when resizing vendor image |

All variables can be overridden via environment:
```bash
sudo SPOOF_PROFILE=samsung-s21 BUILD_VARIANT=gapps ENABLE_WIDEVINE=false bash scripts/pipeline.sh
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
docker build -t waydroid-customizer-build tools/
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

### `build.yml` — Full build pipeline

Triggered by:
- **Manual** (`workflow_dispatch`) with inputs for variant, spoof profile, ARM backend, Widevine toggle
- **Push** to `main` when `config/images.conf`, `modules/`, `overlays/`, or `scripts/` change
- **Schedule** — weekly Monday rebuild

Flow:
```
download (cached) → build-vanilla ─┐
                 → build-gapps    ─┴─ release (GitHub Release + artifacts)
```

Artifacts are uploaded as GitHub Release assets with SHA-256 checksums and
per-variant `manifest-<variant>.json` files.

**`workflow_dispatch` inputs:**

| Input | Default | Options |
|-------|---------|---------|
| `variant` | `both` | `vanilla`, `gapps`, `both` |
| `spoof_profile` | `pixel-6a` | any profile id |
| `arm_backend` | `auto` | `auto`, `houdini`, `ndk` |
| `enable_widevine` | `true` | `true`, `false` |
| `upstream_date` | *(from images.conf)* | date override |

### `update-check.yml` — Upstream version poller

Runs daily at 06:00 UTC. Probes SourceForge for new image date tags. When a
newer date is found it bumps `UPSTREAM_DATE` in `config/images.conf` and opens
a PR (`auto/upstream-<date>`). Merging the PR triggers `build.yml`.

---

## Runtime profile switching (host)

Change device identity on a running Waydroid instance without rebuilding images:

```bash
# List available profiles
bash tools/set-spoof-profile.sh --list

# Apply a profile (writes /var/lib/waydroid/data/waydroid-spoof/active.prop)
sudo bash tools/set-spoof-profile.sh pixel-4a

# Restart to activate
waydroid session stop && waydroid session start

# Revert to build-time identity
sudo bash tools/set-spoof-profile.sh --clear
```

`active.prop` is read by `waydroid-spoof-loader` (oneshot init service) on
every boot. The build-time identity from `build.prop` acts as the fallback when
no `active.prop` is present.

---

## Overlay module installation

Waydroid's overlay filesystem (`/var/lib/waydroid/overlay/`) lets you add files
on top of the base images at container start — **no image rebuild required**.

Use `tools/install.sh --overlay-modules` to install runtime components on an
already-deployed system:

```bash
# Add Widevine L3 DRM (enables HD streaming on Netflix, Prime, etc.)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/chr0mx/waydroid-customizer/main/tools/install.sh) \
  --overlay-modules widevine

# Add updated libndk_translation (ARM translation update without rebuild)
sudo bash <(curl -fsSL .../tools/install.sh) --overlay-modules arm-ndk

# Both at once
sudo bash <(curl -fsSL .../tools/install.sh) --overlay-modules widevine,arm-ndk
```

Overlay files are written to:
- `/var/lib/waydroid/overlay/vendor/` — Widevine DRM blobs
- `/var/lib/waydroid/overlay/system/` — ARM translation libs

The container is automatically restarted after overlay installation.

**Note:** `--overlay-modules` without `--variant` runs in overlay-only mode
(no image download or replacement). Combine with `--variant` to do both in
one run.

---

## Upstream update workflow

When a new Waydroid image set is released on SourceForge:

1. `update-check.yml` detects the new date tag.
2. A PR bumps `UPSTREAM_DATE` in `config/images.conf`.
3. Review the PR — verify the new URLs are valid.
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
       "ro.build.fingerprint": "brand/device/device:13/…:user/release-keys",
       "ro.build.version.sdk": "33",
       "ro.build.tags": "release-keys",
       "ro.build.type": "user",
       "ro.secure": "1",
       "ro.debuggable": "0",
       "ro.boot.verifiedbootstate": "green",
       "ro.boot.flash.locked": "1",
       "ro.boot.veritymode": "enforcing",
       "ro.boot.warranty_bit": "0",
       "ro.warranty_bit": "0"
     }
   }
   ```
2. Set `SPOOF_PROFILE=my-device` in `config/pipeline.conf` or as an env var.
3. Rebuild. The profile is copied into the image so the runtime loader can
   reference it, and can also be applied at runtime via `set-spoof-profile.sh`.

---

## ARM translation assets

`modules/arm-translation/assets/` is **gitignored** (binaries are not
redistributed here). See `modules/arm-translation/assets/README.md` for
sourcing instructions.

**Automated (libndk_translation):**
```bash
bash modules/arm-translation/fetch-ndk.sh modules/arm-translation/assets/ndk_translation
```

**Manual (Intel Houdini):**
See `modules/arm-translation/assets/README.md`.

If no ARM translation assets are available, the pipeline completes
successfully but the resulting images will not run ARM-only apps.

---

## License

Scripts and configuration in this repository are released under the MIT License.
Upstream Waydroid/LineageOS images retain their respective licenses.
ARM translation binaries (Houdini, libndk_translation) and Widevine blobs are
governed by their respective upstream licenses and are **not** included in this
repository.
