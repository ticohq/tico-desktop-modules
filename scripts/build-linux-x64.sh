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
    shutil.copy2(so_dst, stage_dir / so_name)
    os.chmod(stage_dir / so_name, 0o755)

    mod_path = stage_dir / "module.json"
    mod = json.loads(mod_path.read_text())
    mod["version"] = version
    mod["is_libretro"] = True
    mod.setdefault("executables", {})["linux-x64"] = so_name
    mod_path.write_text(json.dumps(mod, indent=2, ensure_ascii=False) + "\n")

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
    results.append(entry)

(work / "out" / "release-summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY
