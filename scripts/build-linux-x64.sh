#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/build}"
OUT="$WORK/out"
mkdir -p "$WORK/src" "$WORK/built" "$WORK/templates" "$OUT"

g++ -std=c++17 -O2 "$ROOT/scripts/verify_core.cpp" -o "$WORK/verify_core" -ldl
curl -fsSL https://content.ticoverse.com/api/manifest -o "$WORK/manifest.json"

python3 - "$ROOT/cores.json" "$WORK" <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, urllib.request, zipfile

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

cfg = json.loads(pathlib.Path(sys.argv[1]).read_text())
work = pathlib.Path(sys.argv[2])
manifest = json.loads((work / "manifest.json").read_text())
by_id = {p["id"]: p for p in manifest.get("packages", [])}
results = []

for core in cfg["cores"]:
    cid = core["id"]
    src_dir = work / "src" / cid
    if not (src_dir / ".git").exists():
        subprocess.run(["git", "clone", "--depth=1", core["repo"], str(src_dir)], check=True)
    build_dir = src_dir / core["subdir"]
    subprocess.run(
        ["make", "-f", core["makefile"], "platform=unix", f"-j{os.cpu_count() or 4}"],
        cwd=build_dir, check=True
    )
    so_name = f"{cid}_libretro.so"
    so_dst = work / "built" / so_name
    shutil.copy2(build_dir / core["so_out"], so_dst)
    subprocess.run(["strip", "--strip-unneeded", str(so_dst)], check=False)

    file_out = subprocess.check_output(["file", str(so_dst)], text=True)
    print(f"[{cid}] {file_out.strip()}")
    if "ELF 64-bit" not in file_out or "x86-64" not in file_out:
        raise RuntimeError(f"Unexpected binary format for {cid}: {file_out}")

    readelf = subprocess.check_output(["readelf", "-d", str(so_dst)], text=True)
    needed = re.findall(r"\(NEEDED\)\s+Shared library:\s+\[([^\]]+)\]", readelf)
    print(f"[{cid}] DT_NEEDED: {needed}")
    unexpected = [lib for lib in needed if lib not in ALLOWED_LIBS]
    if unexpected:
        raise RuntimeError(f"Non-system runtime dependency in {cid}: {unexpected}\n{readelf}")

    subprocess.run([str(work / "verify_core"), str(so_dst)], check=True)

    # Fetch Switch module template for metadata/settings/gamelists/assets/lang
    zpath = work / "templates" / f"{cid}.zip"
    if not zpath.exists():
        req = urllib.request.Request(by_id[cid]["url"], headers={"User-Agent": "tico-desktop-modules/1.0"})
        with urllib.request.urlopen(req, timeout=60) as r, open(zpath, "wb") as f:
            f.write(r.read())
    ext_dir = work / "templates" / "extracted" / cid
    if ext_dir.exists():
        shutil.rmtree(ext_dir)
    with zipfile.ZipFile(zpath) as zf:
        zf.extractall(ext_dir)

    stage_parent = work / "stage" / cid
    stage_dir = stage_parent / cid
    if stage_parent.exists():
        shutil.rmtree(stage_parent)
    shutil.copytree(ext_dir / cid, stage_dir)
    for nro in stage_dir.glob("*.nro"):
        nro.unlink()
    shutil.copy2(so_dst, stage_dir / so_name)
    os.chmod(stage_dir / so_name, 0o755)

    version = by_id[cid]["version"]
    mod_path = stage_dir / "module.json"
    mod = json.loads(mod_path.read_text())
    mod["version"] = version
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
    results.append({
        "id": cid,
        "version": version,
        "filename": zip_name,
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    })

(work / "out" / "release-summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY
