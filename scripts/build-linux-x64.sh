#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/build}"
OUT="$WORK/out"
mkdir -p "$WORK/src" "$WORK/built" "$WORK/templates" "$WORK/buildbot" "$OUT"

g++ -std=c++17 -O2 "$ROOT/scripts/verify_core.cpp" -o "$WORK/verify_core" -ldl

python3 - "$ROOT/cores.json" "$WORK" <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, urllib.request, zipfile

BUILDBOT_BASE = "https://buildbot.libretro.com/nightly/linux/x86_64/latest"

ALLOWED_LIBS = {
    "libc.so.6",
    "libm.so.6",
    "libstdc++.so.6",
    "libgcc_s.so.1",
    "libpthread.so.0",
    "libdl.so.2",
    "librt.so.1",
    "ld-linux-x86-64.so.2",
}

def gh_headers():
    headers = {"User-Agent": "tico-desktop-modules/1.0", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers

def fetch_template_info(switch_repo):
    url = f"https://api.github.com/repos/{switch_repo}/releases/latest"
    req = urllib.request.Request(url, headers=gh_headers())
    with urllib.request.urlopen(req, timeout=30) as r:
        rel = json.loads(r.read().decode("utf-8"))
    version = str(rel.get("tag_name", "")).lstrip("v")
    for asset in rel.get("assets", []):
        name = asset.get("name", "")
        if name.endswith("-module.zip"):
            return version, asset["browser_download_url"]
    raise RuntimeError(f"No *-module.zip asset in latest release of {switch_repo}")

def gcc_major(compiler):
    try:
        out = subprocess.check_output([compiler, "-dumpversion"], text=True).strip()
        return int(out.split(".")[0])
    except Exception:
        return 0

def select_cpp20_compilers():
    if gcc_major("g++") >= 12:
        return []
    for ver in (14, 13, 12):
        cxx = f"g++-{ver}"
        cc = f"gcc-{ver}"
        if shutil.which(cxx) and shutil.which(cc):
            return [f"CXX={cxx}", f"CC={cc}"]
    return []

def download_buildbot_so(buildbot_name, work):
    so_filename = f"{buildbot_name}.so"
    url = f"{BUILDBOT_BASE}/{so_filename}.zip"
    zpath = work / "buildbot" / f"{so_filename}.zip"
    print(f"[buildbot] Downloading {url}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "tico-desktop-modules/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        last_modified = r.headers.get("Last-Modified", "")
        zpath.write_bytes(r.read())
    ext_dir = work / "buildbot" / buildbot_name
    if ext_dir.exists():
        shutil.rmtree(ext_dir)
    with zipfile.ZipFile(zpath) as zf:
        zf.extractall(ext_dir)
    so_path = ext_dir / so_filename
    if not so_path.is_file():
        candidates = list(ext_dir.rglob("*.so"))
        if len(candidates) != 1:
            raise RuntimeError(f"Expected {so_filename} inside {zpath}, found {candidates}")
        so_path = candidates[0]
    return so_path, last_modified

def verify_so_runtime(work, so_name, docker_image):
    if docker_image:
        print(f"[verify] Running verify_core for {so_name} in {docker_image}", flush=True)
        cmd = [
            "docker", "run", "--rm",
            "-v", f"{work}:/work:ro",
            docker_image,
            "bash", "-lc",
            (
                "set -euo pipefail; "
                "apt-get update -qq && "
                "apt-get install -y -qq --no-install-recommends "
                "libgl1 libegl1 libgomp1 libusb-1.0-0 libudev1 liblzma5 libcurl4 libx11-6 libxi6 >/dev/null; "
                f"/work/verify_core /work/built/{so_name}"
            ),
        ]
        subprocess.run(cmd, check=True)
    else:
        subprocess.run([str(work / "verify_core"), str(work / "built" / so_name)], check=True)

def strip_jsonc(text):
    """Drop // and /* */ comments outside strings (module.json files may be JSONC)."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)

def apply_overrides(target, overrides):
    """Set each key of overrides on target; a null value removes the key."""
    for key, value in overrides.items():
        if value is None:
            target.pop(key, None)
        else:
            target[key] = value

def apply_overlay(stage_dir, overlay_dir):
    """Copy this repo's files for a module over the Switch template.

    lang/*.json are merged key by key (the overlay wins), so the template's
    translations stay and the overlay only adds or replaces strings. Every other
    file replaces the template's file of the same path.
    """
    for src in sorted(overlay_dir.rglob("*")):
        if not src.is_file():
            continue
        rel = src.relative_to(overlay_dir)
        dst = stage_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if rel.parts[0] == "lang" and src.suffix == ".json" and dst.is_file():
            merged = json.loads(dst.read_text(encoding="utf-8"))
            merged.update(json.loads(src.read_text(encoding="utf-8")))
            dst.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        else:
            shutil.copy2(src, dst)

def apply_settings_patch(path, patch, cid):
    """Fit the Switch module's settings.json to the desktop core.

    "remove" lists option keys that neither the desktop core nor tico desktop
    reads. "options" maps an option key to fields to set on that option (a null
    value removes the field), for example a new key, choices or default. A
    section or tab left without options is dropped.
    """
    settings = json.loads(strip_jsonc(path.read_text(encoding="utf-8")))
    remove = set(patch.get("remove", []))
    edits = patch.get("options", {})
    seen = set()
    tabs = []
    for tab in settings.get("tabs", []):
        sections = []
        for section in tab.get("sections", []):
            options = []
            for option in section.get("options", []):
                key = option.get("key")
                if key in remove:
                    seen.add(key)
                    continue
                if key in edits:
                    seen.add(key)
                    apply_overrides(option, edits[key])
                options.append(option)
            section["options"] = options
            if options:
                sections.append(section)
        tab["sections"] = sections
        if sections:
            tabs.append(tab)
    settings["tabs"] = tabs
    for key in sorted((remove | set(edits)) - seen):
        print(f"[{cid}] WARNING: settings_patch key not in settings.json: {key}", flush=True)
    kept = {o.get("key") for t in tabs for s in t["sections"] for o in s["options"]}
    for t in tabs:
        for s in t["sections"]:
            for o in s["options"]:
                parent = o.get("depends_on", {}).get("key")
                if parent and parent not in kept:
                    print(f"[{cid}] WARNING: {o.get('key')} depends on removed option {parent}", flush=True)
    path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

SYSTEM_STAMP = ".tico-system-files"

def add_system_files(stage_dir, spec, work, cid):
    """Put the data files a core reads from its system folder in the module.

    The pack (for example libretro's PPSSPP.zip or Dolphin.zip) is unpacked into
    the module's system/ folder with its own layout (PPSSPP/, dolphin-emu/Sys/),
    next to a stamp file naming the pack and its SHA-256.
    """
    url = spec["url"]
    name = url.rsplit("/", 1)[-1]
    zpath = work / "system-packs" / f"{cid}-{name}"
    zpath.parent.mkdir(parents=True, exist_ok=True)
    print(f"[{cid}] Downloading system files {url}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "tico-desktop-modules/1.0"})
    with urllib.request.urlopen(req, timeout=300) as r:
        last_modified = r.headers.get("Last-Modified", "")
        zpath.write_bytes(r.read())
    digest = hashlib.sha256(zpath.read_bytes()).hexdigest()

    dst_root = stage_dir / "system"
    if dst_root.exists():
        shutil.rmtree(dst_root)
    pack_root = spec.get("root", "")
    count = 0
    with zipfile.ZipFile(zpath) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            parts = pathlib.PurePosixPath(info.filename).parts
            unsafe = (
                not parts
                or info.filename.startswith("/")
                or "\\" in info.filename
                or "\0" in info.filename
                or ".." in parts
                or ":" in parts[0]
            )
            if unsafe:
                raise RuntimeError(f"[{cid}] Unsafe path in {name}: {info.filename!r}")
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise RuntimeError(f"[{cid}] Symlink in {name}: {info.filename!r}")
            if pack_root and parts[0] != pack_root:
                raise RuntimeError(f"[{cid}] {name}: {info.filename} is outside {pack_root}/")
            out = dst_root.joinpath(*parts)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(zf.read(info))
            count += 1
    for required in spec.get("must_contain", []):
        if not (dst_root / required).is_file():
            raise RuntimeError(f"[{cid}] {name} does not contain {required}")

    stamp = f"{name} sha256:{digest}"
    if last_modified:
        stamp += f" last-modified:{last_modified}"
    (dst_root / SYSTEM_STAMP).write_text(stamp + "\n", encoding="utf-8")
    print(f"[{cid}] system files: {count} from {name} (sha256 {digest[:12]})", flush=True)
    info = {"url": url, "sha256": digest, "files": count}
    if last_modified:
        info["last_modified"] = last_modified
    return info

cfg = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[1]).resolve().parent
work = pathlib.Path(sys.argv[2])
jobs = str(os.cpu_count() or 4)

raw_filter = os.environ.get("CORE_FILTER", "").strip()
core_filter = {c.strip() for c in raw_filter.split(",") if c.strip()} if raw_filter else None

results = []

for core in cfg["cores"]:
    cid = core["id"]
    if core_filter is not None and cid not in core_filter:
        continue
    if "linux-x64" not in core.get("platforms", cfg["platforms"]):
        print(f"=== Skipping {cid} (not built for linux-x64) ===", flush=True)
        continue

    source = core.get("source", "git")
    upstream_last_modified = ""
    print(f"=== Preparing {cid} (linux-x64, source={source}) ===", flush=True)

    so_name = f"{cid}_libretro.so"
    so_dst = work / "built" / so_name

    if source == "buildbot":
        built_so, upstream_last_modified = download_buildbot_so(core["buildbot_name"], work)
        shutil.copy2(built_so, so_dst)
    else:
        src_dir = work / "src" / cid
        use_submodules = bool(core.get("submodules", False))
        if not (src_dir / ".git").exists():
            clone_cmd = ["git", "clone", "--depth=1"]
            if core.get("ref"):
                clone_cmd += ["--branch", core["ref"]]
            if use_submodules:
                clone_cmd += ["--recurse-submodules", "--shallow-submodules"]
            clone_cmd += [core["repo"], str(src_dir)]
            subprocess.run(clone_cmd, check=True)
        elif use_submodules:
            subprocess.run(
                ["git", "submodule", "update", "--init", "--recursive", "--depth=1"],
                cwd=src_dir, check=True
            )

        build_dir = src_dir / core["subdir"]
        build_system = core.get("build_system", "make")

        if build_system == "cmake":
            cmake_build_dir = work / "cmake" / cid
            cmake_cmd = [
                "cmake",
                "-S", str(build_dir),
                "-B", str(cmake_build_dir),
                "-DCMAKE_BUILD_TYPE=Release",
                *core.get("cmake_args", []),
                *core.get("cmake_args_linux", []),
            ]
            subprocess.run(cmake_cmd, check=True)
            build_cmd = ["cmake", "--build", str(cmake_build_dir), "-j", jobs]
            if core.get("cmake_target"):
                build_cmd += ["--target", core["cmake_target"]]
            subprocess.run(build_cmd, check=True)
            built_so = cmake_build_dir / core["so_out"]
        else:
            make_cmd = ["make", "-f", core["makefile"], "platform=unix", f"-j{jobs}"]
            if core.get("cpp20"):
                make_cmd += select_cpp20_compilers()
            make_cmd += core.get("make_args", [])
            make_cmd += core.get("make_args_linux", [])
            subprocess.run(make_cmd, cwd=build_dir, check=True)
            built_so = build_dir / core["so_out"]

        if not built_so.is_file():
            raise RuntimeError(f"Expected built core not found for {cid}: {built_so}")

        shutil.copy2(built_so, so_dst)
        subprocess.run(["strip", "--strip-unneeded", str(so_dst)], check=False)

    file_out = subprocess.check_output(["file", str(so_dst)], text=True)
    print(f"[{cid}] {file_out.strip()}", flush=True)
    if "ELF 64-bit" not in file_out or "x86-64" not in file_out:
        raise RuntimeError(f"Unexpected binary format for {cid}: {file_out}")

    readelf = subprocess.check_output(["readelf", "-d", str(so_dst)], text=True)
    needed = re.findall(r"\(NEEDED\)\s+Shared library:\s+\[([^\]]+)\]", readelf)
    print(f"[{cid}] DT_NEEDED: {needed}", flush=True)
    allowed = ALLOWED_LIBS | set(core.get("extra_allowed_libs_linux", []))
    unexpected = [lib for lib in needed if lib not in allowed]
    if unexpected:
        raise RuntimeError(f"Non-system runtime dependency in {cid}: {unexpected}\n{readelf}")

    verify_so_runtime(work, so_name, core.get("verify_docker_image_linux", ""))

    if core.get("module_dir"):
        # A console with no Switch module: the whole module lives in this repo
        # (module.json, settings.json, lang/), with its own version.
        src_template = root / core["module_dir"]
        if not (src_template / "module.json").is_file():
            raise RuntimeError(f"{cid}: no module.json in {core['module_dir']}")
        version = str(core["version"])
    else:
        # Fetch Switch module template directly from GitHub Releases
        version, template_url = fetch_template_info(core["switch_repo"])
        zpath = work / "templates" / f"{cid}.zip"
        if not zpath.exists():
            req = urllib.request.Request(template_url, headers={"User-Agent": "tico-desktop-modules/1.0"})
            with urllib.request.urlopen(req, timeout=60) as r, open(zpath, "wb") as f:
                f.write(r.read())
        ext_dir = work / "templates" / "extracted" / cid
        if ext_dir.exists():
            shutil.rmtree(ext_dir)
        with zipfile.ZipFile(zpath) as zf:
            zf.extractall(ext_dir)

        src_template = ext_dir / cid
        if not src_template.is_dir():
            candidates = [p.parent for p in ext_dir.glob("*/module.json")]
            if len(candidates) != 1:
                raise RuntimeError(f"Could not locate module directory in {zpath} for {cid}")
            src_template = candidates[0]

    stage_parent = work / "stage" / cid
    stage_dir = stage_parent / cid
    if stage_parent.exists():
        shutil.rmtree(stage_parent)
    shutil.copytree(src_template, stage_dir)
    for nro in stage_dir.glob("*.nro"):
        nro.unlink()
    if core.get("overlay_dir"):
        apply_overlay(stage_dir, root / core["overlay_dir"])
    shutil.copy2(so_dst, stage_dir / so_name)
    os.chmod(stage_dir / so_name, 0o755)

    mod_path = stage_dir / "module.json"
    mod = json.loads(strip_jsonc(mod_path.read_text(encoding="utf-8")))
    apply_overrides(mod, core.get("module_overrides", {}))
    for system in mod.get("systems", []):
        apply_overrides(system, core.get("system_overrides", {}).get(system.get("slug", ""), {}))
    mod["version"] = version
    mod["is_libretro"] = True
    mod.setdefault("executables", {})["linux-x64"] = so_name
    mod_path.write_text(json.dumps(mod, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if core.get("settings_patch"):
        # The settings file sits beside module.json: use its file name, whatever
        # path the template's "settings" holds.
        settings_name = pathlib.PurePosixPath(mod.get("settings") or "settings.json").name
        apply_settings_patch(stage_dir / settings_name, core["settings_patch"], cid)
    system_files = None
    if core.get("system_files"):
        system_files = add_system_files(stage_dir, core["system_files"], work, cid)

    zip_name = f"{cid}-linux-x64-module.zip"
    zip_path = work / "out" / zip_name
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for file_path in sorted(stage_dir.rglob("*")):
            if file_path.is_file():
                arcname = file_path.relative_to(stage_parent).as_posix()
                zi = zipfile.ZipInfo(arcname)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = (0o100755 if file_path.suffix == ".so" else 0o100644) << 16
                zf.writestr(zi, file_path.read_bytes())

    raw = zip_path.read_bytes()
    entry = {
        "id": cid,
        "version": version,
        "filename": zip_name,
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "source": source,
    }
    if upstream_last_modified:
        entry["upstream_last_modified"] = upstream_last_modified
    if system_files:
        entry["system_files"] = system_files
    results.append(entry)

(work / "out" / "release-summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY
