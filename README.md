# Box64-Wine-GameScripts

Launch scripts for running classic Windows games from EmulationStation on a **Raspberry Pi 5**, using [Box64](https://github.com/ptitSeb/box64) and [Wine](https://www.winehq.org/). Each game has its own `.sh` script; the shared code they all use is in the `.scripts` folder.

**No games or game files are included.** You need your own copy of each game.

> **Use at your own risk.** These scripts have only been tested on the setup listed below. Some games need patches or extra files that you have to find or make yourself (see each game's notes), and some need a no-CD patch.

> **Keys and registration details are never stored in the scripts.** Games that need them read them from a small text file in the game's folder (listed in each game's notes below). These files are in `.gitignore`. Keep them private and don't upload them.

## What the scripts do

Each script starts its own X session from EmulationStation, runs the game in Wine through Box64, and closes everything when the game ends. Along the way they:

- **Fill the TV without changing its mode.** The game runs at its own resolution, and the Pi's display hardware scales or zooms the picture up to the TV (no GPU work). Scripts that follow the game's window adjust automatically to whatever resolution is picked in the game, with black panels at the sides for 4:3.
- **Keep the mouse and keyboard on the game.** There's no window manager, so the pointer is fenced onto the picture where needed, and a helper keeps the keyboard focus on the game.
- **Mix sound for the Pi's HDMI**, which plays one stream at a time. Games that need two (sound effects plus MIDI music or video soundtracks) get a private mixer just for that game. EmulationStation and the emulators keep using plain ALSA.
- **Play MIDI music** through FluidSynth, started only while the game runs.
- **Set up a separate Wine prefix per game** (`~/wine-prefixes/<game>`), and import registry settings only when they change.
- **Show start-up messages** on screen while the game loads, then a black screen until the game is ready, so resolution changes happen out of sight.
- **Write a log** in the game's folder on each launch.

All settings (resolution, scaling, sound mixer, Box64 options and so on) are at the top of each script, with notes.

To close a stuck game over SSH, run its script with `--kill`, e.g.:

```bash
bash ~/RetroPie/roms/windows/nfsu.sh --kill
```

### The `.scripts` folder

Shared code, loaded by every game script. The files are named `.inc` / `.py` and the folder is hidden, so EmulationStation doesn't list them as games.

| File | What it does |
|---|---|
| `common.inc` | Box64 and Wine settings, starting and stopping Wine, prefix setup, logging, `--kill` |
| `display.inc` | Scaling and zooming the picture to the TV, following the game's window, black panels, mouse fence, keyboard focus |
| `sound.inc` | The private sound mixers (PulseAudio or ALSA) and FluidSynth |
| `bootlog.inc` / `bootlog.py` | The start-up messages and black cover while the game loads |
| `panels.py` | Black panels beside the picture, and the mouse fence |
| `focus.py` | Keeps the keyboard focus on the game |

The Python helpers talk to X directly and need nothing installed beyond `python3`.

## The games

| Script | Game | Game folder (in `roms/windows`) |
|---|---|---|
| `3DPinball.sh` | 3D Pinball for Windows - Space Cadet (Windows XP) | `3DPinball` |
| `aoe2.sh` | Age of Empires II: The Conquerors | `aoe2` |
| `AngryBirds.sh` | Angry Birds (PC) | `Angry Birds` |
| `cmr04.sh` | Colin McRae Rally 04 | `Colin McRae Rally 04` |
| `dxball.sh` | DX-Ball | `dxball` |
| `FS98.sh` | Microsoft Flight Simulator 98 | `Flight Simulator` |
| `hl.sh` | Half-Life (retail WON version, not Steam) | `half-life` |
| `Jazz2.sh` | Jazz Jackrabbit 2 (v1.23) | `Jazz2` |
| `lemmings.sh` | Lemmings (Windows) | `lemmings` |
| `mk4.sh` | Mortal Kombat 4 | `mk4` |
| `MotoGP2.sh` | MotoGP 2 | `MotoGP2` |
| `nfs2.sh` | Need for Speed II: SE | `nfs2` |
| `nfs3.sh` | Need for Speed III: Hot Pursuit | `nfs3` |
| `nfs4.sh` | Need for Speed: High Stakes / Road Challenge | `nfs4` |
| `nfs5.sh` | Need for Speed: Porsche 2000 / Porsche Unleashed | `nfs5` |
| `nfs6.sh` | Need for Speed: Hot Pursuit 2 | `nfs6` |
| `nfsu.sh` | Need for Speed: Underground | `nfsu` |
| `nfsu2.sh` | Need for Speed: Underground 2 | `nfsu2` |
| `outrun.sh` | OutRun 2006: Coast 2 Coast | `OutRun2006 Coast 2 Coast` |
| `Prairie Dog Hunt Pro.sh` | Prairie Dog Hunt Pro (Windows 3.x) | `Prairie Dog Hunt Pro` |
| `quake2.sh` | Quake II (v3.24, OpenGL) | `quake2` |
| `racer.sh` | Star Wars Episode I: Racer | `racer` |
| `SeriousSam.sh` | Serious Sam: The First Encounter (v1.05) | `Serious Sam` |
| `Solitaire.sh` | Solitaire (Windows XP) | `Solitaire` |
| `starwarsgbs.sh` | Star Wars Galactic Battlegrounds: Saga | `starwarsgbs` |
| `tanks.sh` | Pocket Tanks Deluxe | `tanks` |
| `Test Drive 6.sh` | Test Drive 6 | `Test Drive 6` |
| `Toca2.sh` | TOCA 2: Touring Cars | `Toca2` |
| `Worms Armageddon.sh` | Worms Armageddon (3.8) | `Worms Armageddon` |
| `x2.sh` | X2: The Threat | `X2 - The Threat` |

## Fixes and patches for each game

The versions, patches and extras used for each game in my setup, so you can set up your copy the same way. Fixes marked **(game-fixes)** are in this repo's [`game-fixes`](#the-game-fixes-folder) folder, described in full below; everything else you need to get yourself and put in the game's folder.

**No-CD patches:** some games need a no-CD patch to run, because their disc copy protection doesn't work under Wine.

### 3D Pinball - Space Cadet
- From **Windows XP** (SP3 `PINBALL.EXE`, version 5.1.2600.5512).
- Plain GDI graphics, so the only work is zooming the window to fill the TV.
- **Music:** Wine can't play the game's music the way it asks, so the script plays `PINBALL.MID` itself, on a loop, through FluidSynth. The game's own Music option is kept off.
- Esc is blocked (it's the game's "boss key").

### Age of Empires II: The Conquerors
- Possibly **The Conquerors 1.0e** patch.
- Wine's own DirectDraw; the picture is zoomed to full height with the mouse fenced so edge-scrolling works.
- The in-game music is a CD audio track, which Wine only plays from a real CD drive, so there's none. The menu and civilisation themes still play.
- **Product IDs (optional):** put the Product IDs from your own install in `aoe2-pid.txt` in the game folder: Age of Kings on line 1, The Conquerors on line 2 (e.g. `12345-123-1234567-12345`, copied from the registry of a PC where the game is installed). Without it, all zeros are used. Age of Kings runs with that; The Conquerors hasn't been tested without its own ID.

### Angry Birds
- **Sound fix (done by the script):** the game has a start-up race that often leaves it silent under Box64. With `SOUND_PATCH=1`, the script changes 23 bytes in `AngryBirds.exe` so the sound thread waits instead of quitting. The original is kept as `AngryBirds.exe.orig`.
- Sound goes through a private mixer (Wine found no ALSA format it could use directly).
- **Registration:** if you have registered the game, put your registered `settings.lua` and `bi_data.lua` in a `registration` folder in the game folder; the script restores them into a fresh prefix.

### Colin McRae Rally 04
- **LAV Filters** (32-bit, `LAVFilters-x.xx-x86.zip`, contents in `LAVFilters` in the game folder): installed into the prefix once, so the intro and menu videos have their soundtracks. Set `VIDEOS=0` to turn videos off.

### DX-Ball
- MIDI music through FluidSynth, mixed with the sound effects.

### Flight Simulator 98
- Microsoft's **Patch Set 1** (`fs98pat1.exe`).
- **Intro video:** needs Intel's **Indeo 4.1** codec from Windows 95/98 (`ir41_32.dll` renamed to `ir41_32.ax`, plus `ir41_qc.dll` and `ir41_qcx.dll`) in a `codecs` folder. Without it you get an "MCI Error" and no intro, then the game starts.
- **Known issue:** in 3D the ground can be black and the cockpit blank. This is a fault inside Wine; the script's notes list everything tried.

### Half-Life
- Retail WON version (not Steam). Runs in OpenGL; Direct3D is never used, because GoldSrc's Direct3D path hangs the display.
- **CD key (optional):** put your CD key on the first line of `hl-cdkey.txt` in the game folder, with or without the dashes. It's written into the registry on every launch, so a new Wine prefix doesn't ask for it. Without the file, the game asks for the key as normal.

### Jazz Jackrabbit 2
- **Jazz Jackrabbit 2 v1.20** full version, with the official **v1.23** patch.
- **Patched exe (game-fixes):** `jj2-patch` makes `Jazz2-pi.exe` from `Jazz2.exe`, fixing picture damage and crashes on exit. The script runs `Jazz2-pi.exe`, so this is needed.
- Optional: **cnc-ddraw** (`ddraw.dll` + `ddraw.ini` in the game folder) is used instead of Wine's DirectDraw if present. Not used in my setup.

### Lemmings
- MIDI music through FluidSynth, mixed with the sound effects.
- A helper presses OK on the start-up "colour display" warning.

### Mortal Kombat 4
- **GOG version**, which includes the **nGlide 2.10** Glide wrapper and a CD music replacement (Ogg files in `MUSIC`, played through `_inmm.dll`).
- Renders through Glide (nGlide); Direct3D doesn't work (the game rejects Wine's Direct3D devices).

### MotoGP 2
- Runs slightly smaller than the TV and is zoomed up, because the game loads many minutes slower when its resolution exactly matches the Wine desktop.

### Need for Speed II: SE
- **[NFSIISE](https://github.com/zaps166/NFSIISE) v1.4.0**, an open-source wrapper for the original game (SDL2 + OpenGL), in place of the original `nfs2se.exe`, which deadlocks under Wine + Box64. Its settings are written by the script on every launch.
- **Game data:** the original Special Edition CD's `fedata` and `gamedata` folders, renamed to lower case as NFSIISE requires.
- **Menu speed fix (game-fixes, optional):** a rebuilt `nfs2se.exe` with a texture fix, so the Audio, Graphics and exit menus run at full speed instead of about 3 fps.

### Need for Speed III: Hot Pursuit
- **No Wine or Box64:** uses a native ARM64 build of the game from the [nfs-recompiled](https://github.com/motor-dev/nfs-recompiled) static recompilation project (`nfs3hp`), which draws straight to the display with SDL3. Build it and copy `nfs3hp` into the game folder with the game's `FEDATA`, `GAMEDATA` and `install.win`.

### Need for Speed: High Stakes / Road Challenge
- **[NFS4 Modern Patch](http://veg.by/en/projects/nfs4/) v0.1.0** (2016) by Evgeny Vrublevsky: reads its settings from `nfs4.ini` instead of the registry, plus many fixes.
- **nGlide 2.10** (Zeus Software), as an alternative renderer.
- The renderer is chosen in the script, not in `nfs4.ini`: set `RENDERER` to `dx7` (Direct3D 7, 32-bit colour, the default) or `nglide` (nGlide, 16-bit). The script writes it into `nfs4.ini` as `ThrashDriver` on every launch.

### Need for Speed: Porsche 2000 / Porsche Unleashed
- European **Need for Speed: Porsche 2000**.
- Possibly the **NFS: Porsche Unleashed Combined Patch v1.0**.
- **nGlide 2.10** (Zeus Software): `Glide.dll`, `Glide2x.dll` and `Glide3x.dll` in the game folder, used by the game's Voodoo2 (Glide) renderer.

### Need for Speed: Hot Pursuit 2
- Official **v2.42** patch.
- **HP2WSFix 2.9.1**, thefirefox12537's fork of [xan1242's widescreen fix](https://github.com/xan1242/HP2WSFix) (`scripts\HP2WSFix.asi`), loaded by the [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) as `dinput.dll`.
- **Known issue:** changing the resolution in the game's options doesn't fully apply until the game is restarted (`RES_CHANGE_FIX` keeps the picture usable meanwhile).

### Need for Speed: Underground
- European **v1.0**. No patches needed.

### Need for Speed: Underground 2
- Official **v1.2** patch.
- The `CARS\CIVIC` and `CARS\RSX` folders.
- **Patched exe (game-fixes):** `nfsu2-lockfix` makes `SPEED2_PATCHED.EXE` from `SPEED2.EXE` (v1.2), fixing a menu crash. The script runs `SPEED2_PATCHED.EXE`, so this is needed.

### OutRun 2006: Coast 2 Coast
- **Patched exe (game-fixes):** `outrun-lockfix` makes `OR2006C2C_PATCHED.EXE`, fixing crashes and freezes while loading. The script runs `OR2006C2C_PATCHED.EXE`, so this is needed.
- **[OutRun2006Tweaks](https://github.com/emoose/OutRun2006Tweaks) v0.6.1** by emoose (`dinput8.dll` in the game folder), loaded automatically when present.
- **Perfect Music Mod** by Danhanado (GameBanana): the full FLAC version, plus the 1.1 patch.
- Antialiasing is always off: any level stops the game at start-up under Wine.

### Prairie Dog Hunt Pro
- A 16-bit Windows 3.x program, which Box64 can't run directly: runs through **[otvdm (winevdm)](https://github.com/otya128/winevdm)** in an `otvdm` folder in the game folder.
- Needs `VBRUN300.DLL` in the game folder.
- **Registration (optional):** put your registration name on line 1 and your code on line 2 of `pdh-registration.txt` in the game folder. On first run the script writes them into `pdhpro.ini` (delete that file to have it made again). Without the file, the game starts unregistered.

### Quake II
- **Quake II v3.24** (Knightmare's unofficial patch), OpenGL renderer (`ref_gl.dll`).
- **Ogg Vorbis music** in `baseq2\music`.

### Star Wars Episode I: Racer
- The script makes a copy of the game's exe, `SWEP1RCR_wine.EXE`, that loads Wine's DirectDraw instead of `PDRAW.DLL` (a Windows-only fix that crashes under Wine).

### Serious Sam: The First Encounter
- Official **v1.05** patch.
- **Patched `Bin\Engine.dll` (game-fixes):** `serioussam-enginefix` changes one byte, fixing "Write attempted on read-only file stream!" at start-up. Needed; the launch script warns in its log if the original is still in place.

### Solitaire
- From **Windows XP**: `sol.exe`, with `cards.dll` from Windows XP's `System32` next to it.

### Star Wars Galactic Battlegrounds: Saga
- **All-In-One Patch** (the script runs its Clone Campaigns exe, `battlegrounds_cc.exe`).
- **Widescreen Patcher v4.0** (`wide_on.exe`, by BoekaBart & Carborunda; it comes with the All-In-One Patch): replaces the 800x600 option with 1280x720.
- **Intro videos converted with ffmpeg:** from the patch's H.264/MP3 to Cinepak video with IMA ADPCM audio, which Wine can decode without extra decoders.
- **Player profile fix (done by the script):** the screen size stored in `player.nf1` is reset to 1280x720 before and after each session.
- The game's exe is in the `Game` subfolder of the game folder.

### Pocket Tanks Deluxe
- **v1.00b** (8 February 2002). No patches needed. The game always runs at 800x600, scaled to full height.

### Test Drive 6
- **Music fix** (from [PCGamingWiki](https://www.pcgamingwiki.com/wiki/Test_Drive_6)): the **Windows Media Source Filter v1.8** and the **DivX 3.11** audio codec, in a `music-fix` folder, plus `drmclien.dll` (from the Media Source Filter package) and `strmdll.dll` in the game folder. The script installs them once per prefix.

### TOCA 2: Touring Cars
- **[SilentPatch for TOCA 2](https://github.com/CookiePLMonster/SilentPatchTOCA2)** (v1.0.1, `SilentPatchTOCA2.asi`), loaded through the [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) as `winmm.dll`.
- The game's exe is in the `Game` subfolder of the game folder.

### Worms Armageddon
- Official **3.8** update.
- Uses the update's own `Tweaks` registry files (OpenGL renderer, larger fonts, vsync off and others), chosen in the script.

### X2: The Threat
- **Version 1.5**.
- **LAV Filters** (32-bit) in a `LAVFilters` folder: MP3 music and WMA speech.
- **Microsoft's 32-bit DirectShow DLLs:** `quartz.dll`, `amstream.dll`, `devenum.dll` and `qasf.dll` from `dxnt.cab` in `directx_feb2010_redist.exe`, placed in a `native-dshow` folder in the game folder: videos and station chatter. The Windows 10/11 copies don't work in Wine.

## The `game-fixes` folder

Fixes for games that crash, freeze or misbehave under Box64 and Wine. Most of them are small changes to the game's exe or a dll. They work on the copy you already have; no game files are included.

```
game-fixes/
├── Jazz Jackrabbit 2/   jj2-patch.py, jj2-patch.ps1
├── NFS Underground 2/   nfsu2-lockfix.py, nfsu2-lockfix.ps1
├── NFS2/                nfs2se_build.py, nfs2se-texture-fix.patch
├── OutRun 2006/         outrun-lockfix.py, outrun-lockfix.ps1
└── Serious Sam/         serioussam-enginefix.py, serioussam-enginefix.ps1
```

### How the patches work

- **Two versions of each:** the `.py` runs on the Pi (or any computer with Python 3); the `.ps1` does exactly the same on Windows with PowerShell, nothing to install. Use whichever is easier.
- **Safe to run:** each one checks that it has the exact game version it was made for, byte for byte, before changing anything. Anything else is refused and nothing is written. Running one again on an already-patched game does nothing.
- **The original is kept:** the exe patches write a new exe next to the original, and the Serious Sam fix keeps a copy of the original dll.
- **Run once.** You only need to run a patch again if you replace the game's files.

**On the Pi:** copy the `.py` into the game's folder, then run the command shown for that game over SSH.

**On Windows:** copy the `.ps1` into the game's folder (for example through the Pi's Samba share), then right-click it → **Run with PowerShell**. The window stays open at the end so you can read the result. If Windows won't run it, right-click the file → **Properties** → tick **Unblock**, or run it from a PowerShell window with:

```powershell
powershell -ExecutionPolicy Bypass -File .\name-of-patch.ps1
```

### Jazz Jackrabbit 2 - `jj2-patch`

For **Jazz Jackrabbit 2 v1.23**. Makes **`Jazz2-pi.exe`** from `Jazz2.exe` (which is not changed). Four changes:

1. **FPU memory copy switched off.** On Pentium-class CPUs the game copies memory 8 bytes at a time through the x87 maths unit, an old speed trick. Box64 does x87 maths with 64-bit doubles, which hold only 53 bits, so one byte in every 8 got damaged: thin lines and noise bands in the picture, and a crash on exit. The game now always uses its plain memory copy.
2. **and 3. Sound timer callbacks** now take the sound lock before checking whether sound is running, not after.
4. **Sound shutdown** now marks sound off and stops the timer before taking the lock and freeing the buffers.

Changes 2 to 4 fix a race between the sound timer and the game's shutdown which, slowed down by emulation, caused an Access Violation or a hang on exit. Every change only alters or reorders existing instructions.

```bash
python3 ~/RetroPie/roms/windows/Jazz2/jj2-patch.py
```

On Windows, put `jj2-patch.ps1` in the Jazz2 folder and run it. Both versions also accept other file names: `jj2-patch.py [source.exe [patched.exe]]`.

### Need for Speed: Underground 2 - `nfsu2-lockfix`

For **NFSU2 v1.2** (`SPEED2.EXE`, MD5 `6445adbf4e8d64be51e96a69bba168a4`). Makes **`SPEED2_PATCHED.EXE`** (the original is not changed).

**The bug:** the game guards some shared data with a home-made lock, an "in use" flag plus a pointer. Taking the lock was two steps (check the flag, then set it later), so two threads could both get in. When one finished, it cleared the pointer the other was still using, and the game crashed in the menus. On a real PC the gap is tiny; under Box64 it's much wider.

**The fix:**

1. The lock routine claims the lock in one atomic step (`LOCK CMPXCHG`). If the lock is already taken, it reports "busy", which every caller already handles.
2. The periodic update routine, which claims the lock itself, gets the same atomic claim.
3. At all 24 places that release the lock, the pointer is now cleared *before* the flag, so nobody can take the lock and then have their pointer wiped.

```bash
cd ~/RetroPie/roms/windows/nfsu2
python3 nfsu2-lockfix.py SPEED2.EXE SPEED2_PATCHED.EXE
```

The `.py` needs both file names. The Windows `.ps1` uses these names by default when run from the nfsu2 folder.

### OutRun 2006: Coast 2 Coast - `outrun-lockfix`

Makes **`OR2006C2C_PATCHED.EXE`** from `OR2006C2C.EXE` (not changed). Fixes three races in the game's background file loader, which under Box64 crashed it (at `0x4245B4` / `0x4245C8`) or froze it on a black screen at 0% CPU, at start-up or when loading:

1. **The loading queue.** While moving a request from the "pending" list to the "active" list, the loader turned off the lists' locking for everyone, not just itself, so another thread adding a request at the same moment could break the list. The loader now leaves the locks alone and moves the request with two small non-locking copies of the list functions, placed in unused space at the end of the code.
2. **The "parts still loading" count.** The main thread added to it and the loader subtracted from it, each in several steps, so a change could be lost and the count never reached 0, leaving the game waiting for ever. Both are now single atomic operations.
3. **Waiting for a file.** The main thread could miss the loader's "finished" signal if the loader finished at just the wrong moment, and then wait for ever. The main thread now checks the count every millisecond instead.

```bash
cd "$HOME/RetroPie/roms/windows/OutRun2006 Coast 2 Coast"
python3 outrun-lockfix.py
```

Or give the exe's path: `python3 outrun-lockfix.py /path/to/OR2006C2C.EXE`. An older (version 1) `OR2006C2C_PATCHED.EXE` can be given as the input: only the missing fixes are added, and the old file is kept as `OR2006C2C_PATCHED.EXE.v1`.

### Serious Sam: The First Encounter - `serioussam-enginefix`

For **Serious Sam TFE v1.05**. Without it the game stops at start-up with *"Fatal Error: Write attempted on read-only file stream!"*.

**The bug:** the engine reads its files through memory that is filled in the first time it's touched. When that happens during a memory copy, Box64 reports it as a *write* even when the copy is *reading*, and the engine then refuses with the message above.

**The fix:** one byte in `Bin\Engine.dll` (offset `0x1D577`, `75` → `EB`) skips that one check, so the memory is filled in as for any read. Nothing else uses the check. The original is saved as `Bin\Engine.dll.orig` (and never overwritten once there).

```bash
cd "$HOME/RetroPie/roms/windows/Serious Sam"
python3 serioussam-enginefix.py
```

To undo it and put the original back:

```bash
python3 serioussam-enginefix.py --undo
```

You can also give the game folder's path, or the dll's: `python3 serioussam-enginefix.py "/path/to/Serious Sam"`. On Windows: `.\serioussam-enginefix.ps1 [path]`, and `-Undo` to undo.

### Need for Speed II: SE - `nfs2se_build` (optional)

A faster `nfs2se.exe` for [NFSIISE](https://github.com/zaps166/NFSIISE) v1.4.0.

**The problem:** in the Audio, Graphics and exit (Yes/No) menus, the game re-sends about 300 small textures every frame. NFSIISE overwrote textures the GPU was still drawing with, which makes the Pi's graphics driver wait each time (about 1.5 ms). Those menus ran at about 3 fps, with a jerky pointer and missed clicks.

**The fix:** each re-sent texture gets a fresh GL texture instead of overwriting the old one, and textures that haven't changed are skipped. The menus run at about 65 fps. The game itself is not affected.

**`nfs2se_build.py`** does the whole job on the Pi: it installs the build tools if missing (git, the 32-bit MinGW cross-compiler and yasm, using `sudo apt-get`), downloads NFSIISE v1.4.0 and the SDL2 development files, applies the fix (built into the script) and compiles `nfs2se.exe`. It needs an internet connection; the first run takes a few minutes.

```bash
python3 nfs2se_build.py              # build only -> ~/nfs2se-build/nfs2se.exe
python3 nfs2se_build.py --install    # build and copy into the nfs2 folder
python3 nfs2se_build.py --no-patch   # build plain v1.4.0, for comparison
```

`--install` keeps your existing `nfs2se.exe` as `nfs2se-original.exe` (only the first time, so a backup is never overwritten). Use `--game-dir "/path/to/nfs2"` if your game folder is somewhere else. Each run starts from a fresh copy of NFSIISE, so running it again is safe.

**`nfs2se-texture-fix.patch`** is the same fix as a source patch, for building NFSIISE yourself. Apply it from the top of the NFSIISE source folder:

```bash
git clone https://github.com/zaps166/NFSIISE.git
cd NFSIISE
git checkout v1.4.0
git submodule update --init --recursive
git apply -p0 /path/to/nfs2se-texture-fix.patch
```

## Requirements

- **Raspberry Pi 5** with **RetroPie** on **Raspberry Pi OS Bookworm Lite 64-bit**.
- **Box64, Wine and their dependencies**, installed with the RetroPie-Setup modules from [Box64-Wine-Install](https://github.com/CARRisma1978/Box64-Wine-Install):
  - `wine-deps`, `box64` and `wine` for every game. Use **Wine 11.18** - later versions don't currently work (see that repo's README).
  - `fluidsynth` for games with MIDI music (3D Pinball, DX-Ball, Lemmings).
  - `pulseaudio` only if you set a game's `SOUND_MIXER=1`.
- A **Windows** system in EmulationStation (set up by the `wine` module).
- `python3`, for the shared helpers and the `.py` patches (or use the `.ps1` patches on Windows).

### Tested on

| | |
|---|---|
| Hardware | Raspberry Pi 5 (16 GB), 1080p over HDMI |
| OS | Raspberry Pi OS Bookworm Lite 64-bit (Debian 12.15) |
| RetroPie | 4.8.12 |
| Box64 | v0.4.5 (30d5c77), with Dynarec |
| Wine | 11.18 WoW64, vanilla (Kron4ek) |
| X server | xorg-server 2:21.1.7-3+rpt3+deb12u13 |

## Installing

1. Copy the `.sh` scripts and the `.scripts` folder into `~/RetroPie/roms/windows/`. The `.scripts` folder must sit next to the scripts.
2. Install each game into its folder under `~/RetroPie/roms/windows/` (see the table above), with any fixes it needs.
3. Run the patches from [`game-fixes`](#the-game-fixes-folder) for the games that need them: Jazz Jackrabbit 2, Need for Speed: Underground 2, OutRun 2006 and Serious Sam (and optionally NFS II SE). The `game-fixes` folder itself doesn't need to be on the Pi.
4. Check the settings at the top of each script, especially `NATIVE_RES` (your TV's resolution).
5. Add the games to EmulationStation's `gamelist.xml` for the Windows system, or restart EmulationStation.

If you edit the scripts on Windows, save them with **Unix (LF)** line endings. In Notepad++: *Edit → EOL Conversion → Unix (LF)*. Scripts with Windows (CRLF) line endings fail on the Pi.

## Credits

These scripts use, or work with, the following projects. None of them are included here.

- [Box64](https://github.com/ptitSeb/box64) by ptitSeb, and [Wine](https://www.winehq.org/) using [Kron4ek's builds](https://github.com/Kron4ek/Wine-Builds)
- [FluidSynth](https://github.com/FluidSynth/fluidsynth), [PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/)
- [nGlide](https://www.zeus-software.com/downloads/nglide) by Zeus Software
- [LAV Filters](https://github.com/Nevcairiel/LAVFilters) by Nevcairiel
- [NFSIISE](https://github.com/zaps166/NFSIISE) by zaps166
- [NFS4 Modern Patch](http://veg.by/en/projects/nfs4/) by Evgeny Vrublevsky
- [HP2WSFix](https://github.com/xan1242/HP2WSFix) by xan1242 (thefirefox12537's fork), and the [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) by ThirteenAG
- The Widescreen Patcher for Star Wars Galactic Battlegrounds by BoekaBart & Carborunda
- The Quake II v3.24 unofficial patch by Knightmare
- The Perfect Music Mod for OutRun 2006 by Danhanado
- [SilentPatch for TOCA 2](https://github.com/CookiePLMonster/SilentPatchTOCA2) by Silent (CookiePLMonster)
- [OutRun2006Tweaks](https://github.com/emoose/OutRun2006Tweaks) by emoose
- [otvdm / winevdm](https://github.com/otya128/winevdm) by otya128
- [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) by FunkyFr3sh
- [nfs-recompiled](https://github.com/motor-dev/nfs-recompiled) by motor-dev
- [PCGamingWiki](https://www.pcgamingwiki.com/) for the Test Drive 6 music fix

## Licence

The scripts and patches in this repo are released under the MIT Licence; see [LICENSE](LICENSE). The NFS II SE texture fix is a change to NFSIISE, which is also MIT-licensed. The games and the third-party tools listed above are covered by their own licences.
