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
- `swanstation` — PlayStation (libretro buildbot, Linux only)
- `melondsds` — Nintendo DS (melonDS DS, libretro buildbot, Linux only)
- `azahar` — Nintendo 3DS (libretro buildbot, Linux only)
- `yabasanshiro` — Sega Saturn (libretro buildbot, Linux only)
- `pcsx2` — PlayStation 2 (ParaLLEl PS2, libretro buildbot, Linux only)
- `beetle_pce_fast` — PC Engine / TurboGrafx-16, PC Engine CD (`mednafen_pce_fast`, libretro buildbot, Linux only)
- `beetle_ngp` — Neo Geo Pocket / Color (`mednafen_ngp`, libretro buildbot, Linux only)
- `handy` — Atari Lynx (libretro buildbot, Linux only)
- `prosystem` — Atari 7800 (libretro buildbot, Linux only)
- `pokemini` — Pokémon Mini (libretro buildbot, Linux only)
- `neocd` — Neo Geo CD (libretro buildbot, Linux only)
- `dosbox_pure` — MS-DOS (libretro buildbot, Linux only)
- `cemu` — Wii U (libretro buildbot, Linux only)
- `vita3k` — PlayStation Vita (libretro buildbot, Linux only)
- `rpcs3` — PlayStation 3 (libretro buildbot, Linux only)
- `xemu` — Xbox (libretro buildbot, Linux only)
- `xenia_edge` — Xbox 360 (Xenia Edge, libretro buildbot, Linux only, experimental)

## Modules Built on Another Core's Template

When a Switch module runs a standalone emulator, its `settings.json` does not
match the desktop libretro core. Such a core takes the Switch module of the same
console as its template (`switch_repo`) and adds, in `cores.json`:

- `platforms` — the targets the core is built for (default: all of them).
- `overlay_dir` — files in this repository copied over the template, for example
  a `settings.json` written for the core's own options. Files in `lang/` are
  merged key by key into the template's.
- `module_overrides` — keys set in `module.json` (`null` removes a key).
- `system_overrides` — keys set on one console of `module.json`, by its slug.

## Modules Written Here (No Switch Module)

A console that has no Switch module has no template to start from. Its whole
module lives in `modules/<id>/` (`module.json`, `settings.json`, `lang/`), and
its entry in `cores.json` names it with `module_dir` and gives the module's own
`version` instead of `switch_repo`. The build adds `version`, `is_libretro` and
`executables` to `module.json` as it does for templates. These modules carry no
console art or game lists yet.

## Cores That Need a Newer Linux Than the Build Runner

The build checks each core with `dlopen` and `retro_init`. A core built against
a newer glibc or libstdc++ than the runner's Ubuntu 22.04 is checked in a
container instead, and the system libraries it links to must be installed there:

- `verify_docker_image_linux` — the image the check runs in, for example
  `ubuntu:24.04`.
- `verify_packages_linux` — Ubuntu packages added to the container's base set,
  for example `libssl3t64` for Vita3K or `libasound2t64` for RPCS3.

## Fitting a Switch `settings.json` to the Desktop Core

The desktop core can be a different build or version than the Switch module's,
so some of the template's options do not exist on the desktop or accept other
values. `settings_patch` in `cores.json` fixes that on `linux-x64`:

- `remove` — option keys that neither the desktop core nor tico reads. A section
  or tab left without options is dropped.
- `options` — fields set on an option, by its key in the template (`null`
  removes a field), for example a new `key`, `choices` or `default`.
- `insert` — new options placed right after an option of the template, by its
  key, in the same section. Their labels go in the core's `overlay_dir` `lang/`.

A `settings_patch` at the top of `cores.json` applies to every module before the
core's own. It removes the Switch display options (screen mode and size, the
on-screen counters, integer scale, frame generation).

The build warns when a listed key is no longer in the template, or when an
option depends on a removed one. Keys of the top-level patch that a module does
not have are skipped silently.

## Data Files a Core Reads From Its System Folder

Some cores need files that are neither BIOS nor part of the `.so`: PPSSPP's
assets (fonts, `compat.ini`, translations) and Dolphin's `Sys` folder
(`codehandler.bin`, shaders, game settings). `system_files` in `cores.json`
names libretro's pack for them on `linux-x64`:

- `url` — the pack, from `https://buildbot.libretro.com/assets/system/`.
- `root` — the pack's single top-level folder (`PPSSPP`, `dolphin-emu`).
- `must_contain` — files the build checks are in the pack.

The pack is unpacked into the module's `system/` folder with its own layout
(`PPSSPP/`, `dolphin-emu/Sys/`), next to a `.tico-system-files` stamp (the
pack's name, SHA-256 and date).

The packs carry their own license files: PPSSPP's assets are GPL-2.0-or-later
(`PPSSPP/LICENSE.TXT`; the `flash0` fonts are PPSSPP's free replacements), and
Dolphin's `Sys` is GPL-2.0-or-later (`dolphin-emu/license.txt`), with GameCube
fonts based on Droid Sans under Apache-2.0 (`Sys/GC/font-licenses.txt`).

## Building Locally

```bash
./scripts/build-macos-arm64.sh
./scripts/build-linux-x64.sh
```

Set `CORE_FILTER=mgba,stella` to build a subset of cores locally.
