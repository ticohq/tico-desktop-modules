# tico Desktop Modules

Prebuilt desktop libretro modules for [tico](https://github.com/ticohq/tico), packaged with `module.json` (`executables`), `settings.json`, `gamelists/`, `assets/`, and `lang/` from the official `ticohq` module releases.

## Current Targets

- `macos-arm64` (Apple Silicon, macOS 11+ — system libraries only, verified via `otool -L` and `dlopen`/`retro_init`)
- `linux-x64` (Linux x86_64, Ubuntu 22.04 / GLIBC 2.35+ — system libraries only, verified via `readelf -d` and `dlopen`/`retro_init`)

## Current Modules

- `gambatte` — Game Boy / Game Boy Color
- `fceumm` — NES / Famicom
- `snes9x` — Super Nintendo
- `mgba` — Game Boy Advance
- `genesis_plus_gx` — Sega Genesis / Mega Drive, Master System, Game Gear, SG-1000, Sega CD
- `picodrive` — Sega 32X
- `stella` — Atari 2600
- `bluemsx` — MSX, MSX2, ColecoVision, Spectravideo, SC-3000
- `beetle_cygne` — WonderSwan / WonderSwan Color
- `beetle_vb` — Virtual Boy
- `fbneo` — FinalBurn Neo (Arcade)
- `ppsspp` — PlayStation Portable (libretro buildbot)
- `flycast` — Dreamcast / NAOMI / Atomiswave (libretro buildbot)
- `mupen64plus` — Nintendo 64 (`mupen64plus_next`, libretro buildbot)
- `dolphin` — GameCube / Wii / Triforce (libretro buildbot)

## Building Locally

```bash
./scripts/build-macos-arm64.sh
./scripts/build-linux-x64.sh
```

Set `CORE_FILTER=mgba,stella` to build a subset of cores locally.
