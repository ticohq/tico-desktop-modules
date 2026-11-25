#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/build}"
OUT="$WORK/out"
mkdir -p "$WORK/src" "$WORK/built" "$WORK/templates" "$WORK/buildbot" "$OUT"

clang++ -std=c++17 -O2 "$ROOT/scripts/verify_core.cpp" -o "$WORK/verify_core"

python3 - "$ROOT/cores.json" "$WORK" <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess, sys, urllib.request, zipfile

BUILDBOT_BASE = "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest"

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

def download_buildbot_dylib(buildbot_name, work):
    dylib_filename = f"{buildbot_name}.dylib"
    url = f"{BUILDBOT_BASE}/{dylib_filename}.zip"
    zpath = work / "buildbot" / f"{dylib_filename}.zip"
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
    dylib_path = ext_dir / dylib_filename
    if not dylib_path.is_file():
        candidates = list(ext_dir.rglob("*.dylib"))
        if len(candidates) != 1:
            raise RuntimeError(f"Expected {dylib_filename} inside {zpath}, found {candidates}")
        dylib_path = candidates[0]
    return dylib_path, last_modified

cfg = json.loads(pathlib.Path(sys.argv[1]).read_text())
work = pathlib.Path(sys.argv[2])
jobs = str(os.cpu_count() or 4)

raw_filter = os.environ.get("CORE_FILTER", "").strip()
core_filter = {c.strip() for c in raw_filter.split(",") if c.strip()} if raw_filter else None

results = []

for core in cfg["cores"]:
    cid = core["id"]
    if core_filter is not None and cid not in core_filter:
        continue

    source = core.get("source", "git")
    upstream_last_modified = ""
    print(f"=== Preparing {cid} (macos-arm64, source={source}) ===", flush=True)

    dylib_name = f"{cid}_libretro.dylib"
    dylib_dst = work / "built" / dylib_name

    if source == "buildbot":
        built_dylib, upstream_last_modified = download_buildbot_dylib(core["buildbot_name"], work)
        shutil.copy2(built_dylib, dylib_dst)
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
                "-DCMAKE_OSX_ARCHITECTURES=arm64",
                "-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0",
                *core.get("cmake_args", []),
                *core.get("cmake_args_macos", []),
            ]
            subprocess.run(cmake_cmd, check=True)
            build_cmd = ["cmake", "--build", str(cmake_build_dir), "-j", jobs]
            if core.get("cmake_target"):
                build_cmd += ["--target", core["cmake_target"]]
            subprocess.run(build_cmd, check=True)
            built_dylib = cmake_build_dir / core["dylib_out"]
        else:
            make_cmd = [
                "make", "-f", core["makefile"],
                "platform=osx", "arch=arm64", "OSX_MIN_VER=11.0",
                f"-j{jobs}",
                *core.get("make_args", []),
                *core.get("make_args_macos", []),
            ]
            subprocess.run(make_cmd, cwd=build_dir, check=True)
            built_dylib = build_dir / core["dylib_out"]

        if not built_dylib.is_file():
            raise RuntimeError(f"Expected built core not found for {cid}: {built_dylib}")

        shutil.copy2(built_dylib, dylib_dst)
        subprocess.run(["strip", "-x", str(dylib_dst)], check=False)

    subprocess.run(["codesign", "--force", "--sign", "-", str(dylib_dst)], check=False)

    otool = subprocess.check_output(["otool", "-L", str(dylib_dst)], text=True)
    if "/opt/homebrew" in otool or "/usr/local" in otool:
        raise RuntimeError(f"Non-system runtime dependency in {cid}:\n{otool}")
    subprocess.run([str(work / "verify_core"), str(dylib_dst)], check=True)

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
    shutil.copy2(dylib_dst, stage_dir / dylib_name)
    os.chmod(stage_dir / dylib_name, 0o755)

    mod_path = stage_dir / "module.json"
    mod = json.loads(mod_path.read_text())
    mod["version"] = version
    mod["is_libretro"] = True
    mod.setdefault("executables", {})["macos-arm64"] = dylib_name
    mod_path.write_text(json.dumps(mod, indent=2, ensure_ascii=False) + "\n")

    zip_name = f"{cid}-macos-arm64-module.zip"
    zip_path = work / "out" / zip_name
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for file_path in sorted(stage_dir.rglob("*")):
            if file_path.is_file():
                arcname = file_path.relative_to(stage_parent).as_posix()
                zi = zipfile.ZipInfo(arcname)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = (0o100755 if file_path.suffix == ".dylib" else 0o100644) << 16
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
    results.append(entry)

(work / "out" / "release-summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY
