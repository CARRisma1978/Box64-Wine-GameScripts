#!/usr/bin/env python3
"""
nfs2se_build.py - build NFSIISE v1.4.0 (Need for Speed II SE wrapper) for
Windows, with the menu texture fix, on the Raspberry Pi itself.

The fix: in the Audio, Graphics and exit Yes/No menus, the game re-uploads
about 300 small textures every frame. Original NFSIISE overwrites textures the
GPU is still using, which makes the Pi's graphics driver wait each time: those
menus ran at about 3 fps, with a jerky pointer and missed clicks. The patched
version gives each upload a fresh texture (and skips unchanged ones): about
65 fps.

What it does:
  1. installs the build tools if missing (apt: git, MinGW-w64 32-bit
     cross-compiler, yasm - needs sudo)
  2. downloads NFSIISE v1.4.0 (with its game-code submodules) from GitHub
  3. downloads the SDL2 development files for MinGW (headers + import library)
  4. applies the texture fix
  5. compiles nfs2se.exe (the same steps as NFSIISE's own "compile_nfs win32")
  6. with --install: copies it into the game folder, keeping the old exe as
     nfs2se-original.exe (only the first time - never overwrites a backup)

Usage (over SSH on the Pi):
  python3 nfs2se_build.py                 build only -> ~/nfs2se-build/nfs2se.exe
  python3 nfs2se_build.py --install       build and copy into the game folder
  python3 nfs2se_build.py --install --game-dir "/path/to/nfs2"
  python3 nfs2se_build.py --no-patch      build plain v1.4.0 (for comparison)

Needs an internet connection (GitHub + Debian package mirrors).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

NFSIISE_REPO = "https://github.com/zaps166/NFSIISE.git"
NFSIISE_TAG = "v1.4.0"
SDL_VERSION = "2.30.9"
SDL_URL = ("https://github.com/libsdl-org/SDL/releases/download/"
           f"release-{SDL_VERSION}/SDL2-devel-{SDL_VERSION}-mingw.tar.gz")

TRIPLET = "i686-w64-mingw32"
APT_PACKAGES = ["git", "yasm", f"gcc-mingw-w64-i686", f"binutils-mingw-w64-i686"]

DEFAULT_WORK = Path.home() / "nfs2se-build"
DEFAULT_GAME = Path.home() / "RetroPie" / "roms" / "windows" / "nfs2"

# The texture fix (src/Glide2x/OpenGL2.c, NFSIISE v1.4.0)
PATCH = r'''--- a/src/Glide2x/OpenGL2.c
+++ b/src/Glide2x/OpenGL2.c
@@ -1098,16 +1098,53 @@
 REALIGN STDCALL void grTexDownloadMipMap(GrChipID_t tmu, uint32_t startAddress, uint32_t evenOdd, GrTexInfo *info)
 {
 	TextureInfo *ti = &g_textures[startAddress >> 2];
-	ti->data = &g_textureMem[startAddress];
+	uint32_t newSize = 256 >> info->largeLod;
+	uint16_t *dataIn  = (uint16_t *)info->data;
+	uint16_t *dataOut = (uint16_t *)&g_textureMem[startAddress];
+
+	/* Skip re-uploading a texture identical to the one already stored at
+	 * this address (some screens re-send unchanged textures every frame). */
+	if (ti->data == (uint8_t *)dataOut && ti->fmt == info->format && ti->size == newSize && ti->id)
+	{
+		uint32_t n = newSize * newSize, i;
+		BOOL same = true;
+		switch (info->format)
+		{
+			case GR_TEXFMT_ARGB_1555:
+				for (i = 0; i < n && same; ++i)
+					same = dataOut[i] == (uint16_t)((dataIn[i] << 1) | (dataIn[i] >> 15));
+				break;
+			case GR_TEXFMT_ARGB_4444:
+				for (i = 0; i < n && same; ++i)
+					same = dataOut[i] == (uint16_t)((dataIn[i] << 4) | (dataIn[i] >> 12));
+				break;
+			default:
+				same = memcmp(dataOut, dataIn, n * (info->format == GR_TEXFMT_P_8 ? 1 : 2)) == 0;
+				break;
+		}
+		if (same)
+			return;
+	}
+
+	ti->data = (uint8_t *)dataOut;
 	ti->palette = NULL;
 	ti->fmt = info->format;
-	ti->size = 256 >> info->largeLod;
-
-	uint16_t *dataIn  = (uint16_t *)info->data;
-	uint16_t *dataOut = (uint16_t *)ti->data;
+	ti->size = newSize;

 	drawTriangles();

+	/* Give the new contents a fresh GL texture instead of overwriting the old
+	 * one: the GPU may still be drawing with the old one this frame, and
+	 * overwriting it makes the driver wait for the GPU (about 1.5 ms each on
+	 * a Raspberry Pi 5 - 300 times a frame in the Audio/Graphics/exit menus,
+	 * which dropped them to 3 fps). The driver frees the old texture when
+	 * the GPU has finished with it. */
+	if (ti->id)
+	{
+		glDeleteTextures(1, &ti->id);
+		ti->id = 0;
+	}
+
 	// ARGB -> RGBA conversion or copy
 	uint32_t sqrSize = ti->size * ti->size, i;
 	switch (ti->fmt)
'''


def step(msg):
    print(f"\n=== {msg}", flush=True)


def run(cmd, cwd=None, **kw):
    print("  $ " + " ".join(str(c) for c in cmd), flush=True)
    subprocess.run([str(c) for c in cmd], cwd=cwd, check=True, **kw)


def fail(msg):
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ensure_tools():
    step("Checking build tools")
    needed = {
        "git": "git",
        "yasm": "yasm",
        f"{TRIPLET}-gcc": "gcc-mingw-w64-i686",
        f"{TRIPLET}-ld": "binutils-mingw-w64-i686",
        f"{TRIPLET}-windres": "binutils-mingw-w64-i686",
    }
    missing = sorted({pkg for tool, pkg in needed.items() if not shutil.which(tool)})
    if not missing:
        print("  all present")
        return
    print("  installing: " + " ".join(missing))
    run(["sudo", "apt-get", "update"])
    run(["sudo", "apt-get", "install", "-y"] + missing)
    still = [t for t in needed if not shutil.which(t)]
    if still:
        fail("still missing after install: " + ", ".join(still))


def get_source(work):
    step(f"Downloading NFSIISE {NFSIISE_TAG}")
    src = work / "NFSIISE"
    if src.exists():
        shutil.rmtree(src)            # always start from a clean copy
    run(["git", "clone", "--branch", NFSIISE_TAG, "--depth", "1", NFSIISE_REPO, src])
    run(["git", "submodule", "update", "--init", "--recursive"], cwd=src)
    if not (src / "src" / "Asm" / "NFS2SE.asm").exists():
        fail("game code submodule (src/Asm/NFS2SE.asm) did not download")
    return src


def get_sdl(work):
    step(f"Getting SDL2 {SDL_VERSION} development files (MinGW)")
    tgz = work / f"SDL2-devel-{SDL_VERSION}-mingw.tar.gz"
    if not tgz.exists():
        print(f"  downloading {SDL_URL}")
        with urllib.request.urlopen(SDL_URL) as r, open(tgz, "wb") as f:
            shutil.copyfileobj(r, f)
    sdl_root = work / f"SDL2-{SDL_VERSION}"
    if not sdl_root.exists():
        with tarfile.open(tgz) as t:
            # only the 32-bit MinGW part is needed
            members = [m for m in t.getmembers()
                       if f"/{TRIPLET}/" in m.name and not m.issym() and not m.islnk()]
            t.extractall(work, members=members)
    sdl = sdl_root / TRIPLET
    if not (sdl / "include" / "SDL2" / "SDL.h").exists() or not (sdl / "lib" / "libSDL2.dll.a").exists():
        fail(f"SDL2 files not found in {sdl}")
    return sdl


def apply_patch(src):
    step("Applying the menu texture fix")
    patch_file = src.parent / "nfs2se-texture-fix.patch"
    patch_file.write_text(PATCH)
    run(["git", "apply", "--check", patch_file], cwd=src)
    run(["git", "apply", patch_file], cwd=src)


def build(src, sdl, out_exe):
    step("Compiling nfs2se.exe")
    s = src / "src"
    for o in s.glob("*.o"):
        o.unlink()
    cflags = ["-Wall", "-m32", "-std=gnu89", "-O2", "-mno-sse2", "-mno-sse", "-mno-mmx",
              f"-I{sdl / 'include'}"]
    c_files = sorted(p.name for p in s.glob("*.c"))
    run([f"{TRIPLET}-windres", "Windows/nfs2se.rc", "icon.o"], cwd=s)
    run([f"{TRIPLET}-gcc"] + cflags + ["-c"] + c_files, cwd=s)
    run(["yasm", "-f", "win32", "Asm/NFS2SE.asm", "-o", "NFS2SE.Win32.o", "--prefix=_"], cwd=s)
    libgcc_dir = Path(subprocess.run([f"{TRIPLET}-gcc", "-print-libgcc-file-name"],
                                     capture_output=True, text=True, check=True).stdout.strip()).parent
    objs = sorted(p.name for p in s.glob("*.o"))
    run([f"{TRIPLET}-ld", "--enable-stdcall-fixup", "-o", out_exe] + objs +
        ["--stack=0x7D00,0x7D00", "--heap=0x2000,0x1000",
         f"-L{sdl / 'lib'}", f"-L{libgcc_dir}",
         "-lws2_32", "-lwinmm", "-lmingwex", "-lmsvcrt", "-lkernel32", "-lopengl32", "-lSDL2",
         "-lgcc", "-subsystem=windows", "-s", "-e", "_start"], cwd=s)
    for o in s.glob("*.o"):
        o.unlink()
    if not out_exe.exists():
        fail("build finished but no exe was produced")
    print(f"  built: {out_exe} ({out_exe.stat().st_size // 1024} KB)")


def install(out_exe, game_dir):
    step(f"Installing into {game_dir}")
    if not game_dir.is_dir():
        fail(f"game folder not found: {game_dir}")
    target = game_dir / "nfs2se.exe"
    backup = game_dir / "nfs2se-original.exe"
    if target.exists() and not backup.exists():
        shutil.copy2(target, backup)
        print(f"  old exe kept as {backup.name}")
    elif backup.exists():
        print(f"  {backup.name} already exists - left as it is")
    shutil.copy2(out_exe, target)
    print(f"  installed {target}")


def main():
    ap = argparse.ArgumentParser(description="Build NFSIISE v1.4.0 for Windows with the menu texture fix.")
    ap.add_argument("--work-dir", type=Path, default=DEFAULT_WORK,
                    help=f"where to download and build (default {DEFAULT_WORK})")
    ap.add_argument("--install", action="store_true",
                    help="copy the result into the game folder (old exe kept as nfs2se-original.exe)")
    ap.add_argument("--game-dir", type=Path, default=DEFAULT_GAME,
                    help=f"game folder for --install (default {DEFAULT_GAME})")
    ap.add_argument("--no-patch", action="store_true", help="build plain v1.4.0 without the fix")
    a = ap.parse_args()

    work = a.work_dir.expanduser().resolve()
    work.mkdir(parents=True, exist_ok=True)
    out_exe = work / ("nfs2se-plain.exe" if a.no_patch else "nfs2se.exe")

    try:
        ensure_tools()
        src = get_source(work)
        sdl = get_sdl(work)
        if not a.no_patch:
            apply_patch(src)
        build(src, sdl, out_exe)
        if a.install:
            install(out_exe, a.game_dir.expanduser())
    except subprocess.CalledProcessError as e:
        fail(f"command failed (exit {e.returncode}) - see the output above")

    step("Done")
    if not a.install:
        print(f"  copy {out_exe} into the game folder as nfs2se.exe (or run again with --install)")


if __name__ == "__main__":
    main()
