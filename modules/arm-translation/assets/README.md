# ARM Translation Assets

Place ARM translation binary assets here. The pipeline's `fetch-ndk.sh` script
will attempt to download `libndk_translation` automatically.

For Intel Houdini, you must supply the binaries manually (they are proprietary):

## Directory layout expected

```
assets/
├── houdini/
│   ├── bin/
│   │   ├── houdini          # ARM32 ELF launcher (x86 executable)
│   │   └── houdini64        # ARM64 ELF launcher (x86_64 executable)
│   ├── lib/
│   │   ├── libhoudini.so    # 32-bit translator (x86)
│   │   └── arm/             # ARM32 native libraries (arm32 ELFs)
│   └── lib64/
│       ├── libhoudini.so    # 64-bit translator (x86_64)
│       └── arm64/           # ARM64 native libraries (arm64 ELFs)
└── ndk_translation/
    ├── lib/
    │   └── libndk_translation.so
    ├── lib64/
    │   └── libndk_translation.so
    └── etc/
        └── ndk_translation_config.xml
```

## Sourcing Houdini

Houdini is proprietary to Intel. Common extraction methods:

1. **ChromeOS image** – `chromeos_base_arm_translation` component contains
   `libhoudini.so`. Extract with `unsquashfs` from a downloaded ChromeOS
   recovery image.

2. **Genymotion** – the Genymotion Android VM ships Houdini; you can copy the
   relevant `.so` files if you have a Genymotion license.

3. **Pre-extracted packages** – community tools like `waydroid_script` include
   a Houdini download step (`sudo python3 main.py install houdini`).

## Sourcing libndk_translation

Run the automated fetch script:
```bash
bash modules/arm-translation/fetch-ndk.sh modules/arm-translation/assets/ndk_translation
```

This downloads the community-maintained ChromeOS NDK translation package.
