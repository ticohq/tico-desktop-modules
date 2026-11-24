# tico Desktop Modules

Prebuilt desktop libretro modules for [tico](https://github.com/ticohq/tico), packaged with `module.json` (`executables`), `settings.json`, `gamelists/`, `assets/`, and `lang/` from the official `ticohq` module releases.

## Current Targets

- `macos-arm64` (Apple Silicon, macOS 11+ — system libraries only, verified via `otool -L` and `dlopen`/`retro_init`)
- `linux-x64` (Linux x86_64, Ubuntu 22.04 / GLIBC 2.35+ — system libraries only, verified via `readelf -d` and `dlopen`/`retro_init`)

## Current Modules

- `gambatte` — Game Boy / Game Boy Color
- `fceumm` — NES / Famicom
- `snes9x` — Super Nintendo

## Building Locally

```bash
./scripts/build-macos-arm64.sh
./scripts/build-linux-x64.sh
```
