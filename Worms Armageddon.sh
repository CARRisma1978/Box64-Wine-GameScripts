#!/bin/bash
# =============================================================================
#  Worms Armageddon (3.8) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - WA's own OpenGL renderer -> Wine's opengl32 -> Mesa on the Pi's GPU
#     (no wined3d in the way).
#   - Bare X, no window manager (in a Wine desktop, Wine manages the game's
#     windows itself).
#   - The Wine desktop and the X screen are GAME_RES. The game's window sits
#     in its top-left corner. The menus draw MENU_RES in ITS top-left corner
#     (the window itself is bigger, e.g. 1440x810); a match fills it at the
#     in-game resolution. A helper watches the game's window and has the
#     Pi's display hardware zoom the menus or the match to full TV height
#     (free - no GL work), with black panels beside it and the mouse kept on
#     the picture. The zoom starts at the menu size as soon as X starts, so
#     the menus appear already the right size.
#   - X reports a fixed GAME_RES "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - All registry tweaks go in ONE import, only when something changed.
#
#  To close a stuck game over SSH:
#      bash "$HOME/RetroPie/roms/windows/Worms Armageddon.sh" --kill
#
#  Log (overwritten each launch):
#     \\<pi>\roms\windows\Worms Armageddon\wa-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="wa"                # short name: its Wine prefix
                            #   (~/wine-prefixes/wa) and log
# \\<pi>\roms\windows\Worms Armageddon
GAME_DIR="$HOME/RetroPie/roms/windows/Worms Armageddon"
GAME_EXE="WA.exe"           # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop: the BIGGEST in-game resolution (WA's Options)
# you'll use. Any smaller one picked in the game is followed automatically
# (zoomed to full TV height, black bars beside it, mouse kept on it).
#   1920x1080 = 1:1 on the TV, sharpest, most of the map on screen
#   1280x720  = 1.5x zoom, lighter on the GPU
#    960x540  = exactly 2x - with GAME_FILTER="nearest", clean pixel doubling
GAME_RES="1920x1080"
MENU_RES="640x480"          # size the menus are drawn at (top-left corner)
MENU_FILTER="bilinear"      # menus are zoomed 2.25x - bilinear hides the
                            #   uneven pixels
GAME_FILTER="bilinear"      # only used when GAME_RES is smaller than the TV
                            # (nearest + 960x540 = crisp 2x pixel art)
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (WA is played with the mouse)
MOUSE_FENCE=1               # 1 = keep the mouse on the menu picture (a click on
                            #     the hidden part of the desktop loses focus)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (0 here: vsync is WA's job - the Vsync_* tweaks below)
X87DOUBLE=0         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # WA's replays and online games rely on exact maths - 1
                    #   is the more accurate choice
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code (3 = an extra for
                    #   LoongArch CPUs only, not the Pi); empty = Box64's
                    #   default (2). Can crash some games - if so, try 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and
                    #   loading): empty = on, one cache shared by all games
                    #   (~/.cache/box64); 1 = on, this game's own cache
                    #   (box64-cache in its prefix); 0 = off
CPU_PERFORMANCE=1   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=1          # Mesa's GL thread. WA calls OpenGL directly (no wined3d
                    #   thread), so this takes GL work off the emulated game
                    #   thread. Compare with FPS_HUD=2 if in doubt

# ----- Sound ------------------------------------------------------------------
SOUND_MIXER=0       # 0 = a game-only ALSA mixer: dmix -> loopback ->
                    #     alsaloop -> HDMI. The HDMI sound stays open for the
                    #     whole game, so no sound loses its start while the
                    #     TV's HDMI audio wakes up. Needs alsa-utils
                    #     (alsaloop) and snd-aloop (loaded by the script)
                    # 1 = straight to the Pi's HDMI sound through ALSA
                    # 2 = a private PulseAudio just for this game
                    # If the chosen mixer can't start: straight to HDMI (1).
                    # EmulationStation and the emulators always use plain ALSA.
                    # HDMI port, PulseAudio buffering: .scripts/settings.cfg

# ----- Registry tweaks --------------------------------------------------------
# Files from the game's Tweaks folder. Uncommented lines are merged (in this
# order) into ONE import, redone whenever the list or a file changes.
# Commenting a line out does NOT undo it - enable its opposite instead (e.g.
# _On -> _Off). Enable only one file from each group. Most can also be set
# in-game in Advanced Options.
TWEAKS=(
    # --- Renderer (pick one) ---
    "Renderer_OpenGL_32bit_Shader_Palette.reg"     # OpenGL, colour
                                                   #   conversion on the
                                                   #   GPU - best on the Pi
  # "Renderer_OpenGL_32bit_Software_Palette.reg"   # OpenGL, colour conversion
                                                   #   on the CPU - fallback
                                                   #   if glitches
  # "Renderer_Direct3D_9_Shader_Palette.reg"       # Direct3D 9, GPU palette -
                                                   #   slower under Wine
  # "Renderer_Direct3D_9_Software_Palette.reg"     # Direct3D 9, CPU palette -
                                                   #   slower under Wine
  # "Renderer_Direct3D_7.reg"                      # Direct3D 7 - slower
                                                   #   under Wine
  # "Renderer_DirectDraw_32bit.reg"                # DirectDraw 32-bit colour -
                                                   #   slower under Wine
  # "Renderer_DirectDraw_8bit.reg"                 # DirectDraw 8-bit, like
                                                   #   the original game -
                                                   #   slower under Wine
  # "HardwareRendering_Enabled.reg"                # Use GPU rendering with
                                                   #   the chosen renderer
                                                   #   (game default)
  # "HardwareRendering_Disabled.reg"               # Force software rendering
  # "UseVRAM_On.reg"                               # Use graphics memory
                                                   #   when hardware
                                                   #   rendering (default)
  # "UseVRAM_Off.reg"                              # Don't use graphics memory

    # --- Vertical sync ---
    "Vsync_Off.reg"                                # Don't wait for vsync -
                                                   #   lower latency, may tear
  # "Vsync_On.reg"                                 # Wait for vsync - no
                                                   #   tearing, more latency
  # "AssistedVsync_On.reg"                         # Extra sync between refresh
                                                   #   and vsync - lower latency
  # "AssistedVsync_Off.reg"                        # No assisted vsync

    # --- Background effects ---
    "BackgroundDebrisParallax_80.reg"              # Background debris
                                                   #   drawn with depth
                                                   #   (parallax) effect
  # "BackgroundDebrisParallax_0.reg"               # Debris without parallax -
                                                   #   slightly faster
    "BackgroundGradientParallax_Enable.reg"        # Sky gradient scrolls with
                                                   #   parallax effect
  # "BackgroundGradientParallax_Disable.reg"       # Fixed sky gradient -
                                                   #   slightly faster
    "SmoothBackgroundGradient_Enable.reg"          # Smooth dithered
                                                   #   sky gradient
  # "SmoothBackgroundGradient_Disable.reg"         # Coarse, banded sky
                                                   #   gradient -
                                                   #   slightly faster

    # --- Display / interface ---
  # "UseHardwareCursors_On.reg"                    # Hardware mouse pointer in
                                                   #   menus - no pointer lag
  # "UseHardwareCursors_Off.reg"                   # Software-drawn
                                                   #   pointer in menus
    "LargerFonts_On.reg"                           # Larger text in
                                                   #   menus and in game
  # "LargerFonts_Off.reg"                          # Normal size text
  # "WindowedMode_On.reg"                          # Run in a window -
                                                   #   not wanted here
  # "WindowedMode_Off.reg"                         # Full screen (default)
  # "UIAnimations_Enabled.reg"                     # In-game menu/panel
                                                   #   animations (default)
  # "UIAnimations_Disabled.reg"                    # No in-game UI animations
  # "FrontendFontDynamicAntialiasing_On.reg"       # Smoothed menu
                                                   #   fonts (default)
  # "FrontendFontDynamicAntialiasing_Off.reg"      # Unsmoothed menu fonts - may
                                                   #   be slightly faster
  # "SlowFrontendWorkaround_Alternative.reg"       # Workaround for
                                                   #   slow/unresponsive menus
                                                   #   on some GPUs
  # "SlowFrontendWorkaround_Off.reg"               # No menu workaround
                                                   #   (default)
  # "TopmostExplosionOnomatopoeia_On.reg"          # Explosion words (POW,
                                                   #   BIFF...) drawn on top
                                                   #   (not in docs)
  # "TopmostExplosionOnomatopoeia_Off.reg"         # Explosion words drawn
                                                   #   normally (not in docs)
  # "Phone_Enable.reg"                             # In-game phone icon for new
                                                   #   chat messages (default)
  # "Phone_Disable.reg"                            # No phone icon
  # "SkipIntro_On.reg"                             # Skip intro videos and
                                                   #   logos at start-up
  # "SkipIntro_Off.reg"                            # Show intro (default)

    # --- Sound ---
  # "StereoEffects_Normal.reg"                     # Stereo sound
                                                   #   effects (default)
  # "StereoEffects_Reversed.reg"                   # Swap left/right
                                                   #   sound effects
  # "StereoEffects_Disabled.reg"                   # Mono sound effects
  # "PlayAudioInBackground_Enable.reg"             # Keep sound effects playing
                                                   #   when not focused
  # "PlayAudioInBackground_Disable.reg"            # Mute when not
                                                   #   focused (default)

    # --- Controls ---
  # "LegacyUtilityKey_Off.reg"                     # Utilities on the key under
                                                   #   Escape (default)
  # "LegacyUtilityKey_On.reg"                      # Utilities on the old
                                                   #   language-dependent key
  # "LegacyUtilityKey_Both.reg"                    # Both keys select utilities
  # "CameraUnlockMouseSpeed_Default.reg"           # Moving the mouse unlocks
                                                   #   the camera (default)
  # "CameraUnlockMouseSpeed_Minimum.reg"           # Camera unlocks on the
                                                   #   slightest mouse movement

    # --- Timing ---
  # "TimerWorkaround_On.reg"                       # Don't use the
                                                   #   high-resolution
                                                   #   timer - only if game
                                                   #   speed is wrong
  # "TimerWorkaround_Off.reg"                      # Use the high-resolution
                                                   #   timer (default)

    # --- Gameplay / schemes / replays ---
  # "OfflineRopeKnocking_On.reg"                   # Rope knocking in
                                                   #   offline multiplayer
                                                   #   and quick CPU games
  # "OfflineRopeKnocking_Off.reg"                  # No offline rope
                                                   #   knocking (default)
  # "ImportRubberWorm_Verbosely.reg"               # Import RubberWorm scheme
                                                   #   settings and tell you
  # "ImportRubberWorm_Quietly.reg"                 # Import RubberWorm scheme
                                                   #   settings with less notice
  # "ImportRubberWorm_Silently.reg"                # Import RubberWorm scheme
                                                   #   settings silently
  # "ImportRubberWorm_Disable.reg"                 # Ignore RubberWorm
                                                   #   scheme settings
  # "EmulateRubberWorm_On.reg"                     # Emulate RubberWorm when
                                                   #   playing old replays
  # "EmulateRubberWorm_Off.reg"                    # No RubberWorm
                                                   #   emulation in replays
  # "EmulateProjectXBugs_On.reg"                   # Emulate Project X bugs when
                                                   #   playing old replays
  # "EmulateProjectXBugs_Off.reg"                  # No Project X emulation
                                                   #   in replays
  # "MapAreaWarnLimit_Default.reg"                 # Warn before loading very
                                                   #   large maps (default)
  # "MapAreaWarnLimit_Unlimited.reg"               # Never warn about large maps

    # --- Online / files ---
  # "UseCommunityServerList_Enabled.reg"           # Use the community
                                                   #   WormNET server list
  # "UseCommunityServerList_Disabled.reg"          # Use the standard
                                                   #   server list
  # "StreamingMode_On.reg"                         # Hide IP addresses on screen
                                                   #   (for streamers)
  # "StreamingMode_Off.reg"                        # Show IP addresses (default)
  # "TimestampFormat_HMS.reg"                      # Time stamps (24-hour)
                                                   #   in chat logs
  # "TimestampFormat_None.reg"                     # No chat time
                                                   #   stamps (default)
  # "RegisterAssociations_Automatically.reg"       # Link replays and
                                                   #   wa:// links to the
                                                   #   game on start-up
  # "RegisterAssociations_Manually.reg"            # Only link them when
                                                   #   asked (default)
  # "LoadWormKitModules_Enabled.reg"               # Load WormKit add-ons
                                                   #   (wk*.dll) on start-up
  # "LoadWormKitModules_Disabled.reg"              # Don't load WormKit
                                                   #   add-ons (default)
  # "CaptureTransparentPNGs_On.reg"                # Screenshots with
                                                   #   transparent background
  # "CaptureTransparentPNGs_Off.reg"               # Normal screenshots
                                                   #   (default)

    # --- Reset ---
  # "ResetRegistryOptions.reg"                     # WIPES ALL GAME SETTINGS -
                                                   #   don't leave enabled
)

# ===================== Shared code =====================
# In the ".scripts" folder next to this script: common.inc (settings.cfg,
# Box64, the Wine prefix, starting X, waiting for the game to close...),
# which also loads display.inc (screen scaling and zoom, black panels, mouse
# fence, keyboard focus, finding the game's window), sound.inc (sound
# mixers, FluidSynth) and the start-up messages on screen (bootlog.inc,
# bootlog.py)
COMMON_INC="$(dirname "$(readlink -f "$0")")/.scripts/common.inc"
if [ ! -f "$COMMON_INC" ]; then
    echo "ERROR: $COMMON_INC not found" | tee "${LOG_FILE:-$GAME_DIR/$GAME_ID-launch.log}"
    sleep 5; exit 1
fi
# shellcheck source=/dev/null
. "$COMMON_INC"

# ===================== Environment =====================
# Wine's own msvcrt (as before)
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;msvcrt=b"

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*};   GH=${GAME_RES#*x}
MW=${MENU_RES%x*};   MH=${MENU_RES#*x}

# ===================== Helpers =====================

# The enabled Tweaks files as one block of REGEDIT4 text (UTF-16 / UTF-8 BOM
# files converted, Windows line endings and headers removed)
tweaks_body() {
    local reg f
    for reg in "${TWEAKS[@]}"; do
        f="$GAME_DIR/Tweaks/$reg"
        [ -f "$f" ] || { echo "WARNING: Tweaks/$reg not found, skipped" >&2; continue; }
        echo; echo "; ----- $reg"
        if [ "$(head -c2 "$f" | od -An -tx1 | tr -d ' \n')" = "fffe" ]; then
            iconv -f UTF-16 -t UTF-8 "$f"
        else
            cat "$f"
        fi | sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | grep -viE '^(REGEDIT4|Windows Registry Editor)'
    done
}

# The prefix (shared code), then the registry: Wine settings + every
# enabled tweak in ONE import, only when something changed, including the
# contents of a tweak file (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    {
        wine_base_reg dsound
        tweaks_body
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"       # (Wine settings +
                                           #   ${#TWEAKS[@]} tweaks)
}

# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen is GAME_RES; the panels
# hide once the game fills it.
ZOOM_FB="$GAME_RES"

# zoom_to, with MENU_FILTER for the menus and GAME_FILTER in a match.
# Returns non-zero if xrandr refused the zoom.
scale_to() {
    local SCALE_FILTER="$GAME_FILTER"
    [ "$1" = "$MW" ] && [ "$2" = "$MH" ] && SCALE_FILTER="$MENU_FILTER"
    zoom_to "$@"
}

# The match resolution saved in WA's Options ("WxH"), from the prefix's
# registry (as of the last time WA saved it). Nothing if not set.
match_res() {
    local x y
    read -r x y < <(awk '
        { l = tolower($0) }
        l ~ /^\[software\\\\team17softwareltd\\\\wormsarmageddon\\\\options\]/ { s = 1; next }
        /^\[/ { s = 0 }
        s && l ~ /^"displayxsize"=dword:/ { x = substr($0, index($0, ":") + 1) }
        s && l ~ /^"displayysize"=dword:/ { y = substr($0, index($0, ":") + 1) }
        END { if (x != "" && y != "") print x, y }' "$WINEPREFIX/user.reg" 2>/dev/null)
    [[ "$x" =~ ^[0-9a-fA-F]{8}$ && "$y" =~ ^[0-9a-fA-F]{8}$ ]] || return 0
    (( 16#$x > 0 && 16#$y > 0 )) && echo "$((16#$x))x$((16#$y))"
    return 0
}

# The game's window (top-left corner of the desktop), followed by the shared
# follow_window. The game always starts in the menus, whose window is
# MENU_RES or a bigger one with the menus in its top-left corner (1440x810
# on a 1920x1080 desktop) - the first such size seen is remembered as the
# menu window (the saved match resolution and GAME_RES excepted). So:
#   narrower than MENU_RES (a dialog box, e.g. a first-run Wine prompt)
#                                  -> the whole desktop
#   MENU_RES or the menu window    -> the menus (MENU_RES, top-left)
#   any other size                 -> a match: the whole window, whatever
#                                     resolution WA is set to
# MENU_FILTER for the menus, GAME_FILTER in a match. It starts from the zoom
# set when X started (START_GEO), so a matching first window causes no
# change at all.
MENU_WIN=""; LAST_SIZE=""
follow_window_map() {           # ($1 $2 = the window's size)
    local size="$1x$2"
    if (( $1 >= MW )) && [ -z "$MENU_WIN" ] && [ "$size" != "$MENU_RES" ] \
            && [ "$size" != "$MATCH" ] && [ "$size" != "$GAME_RES" ]; then
        MENU_WIN="$size"
        echo "Menu window: $MENU_WIN"
    fi
    if (( $1 < MW )); then
        FOLLOW_GEO="$GW $GH 0 0"
    elif [ "$size" = "$MENU_RES" ] || [ "$size" = "$MENU_WIN" ]; then
        FOLLOW_GEO="$MW $MH 0 0"
    elif (( $1 > GW || $2 > GH )); then
        [ "$size" != "$LAST_SIZE" ] && echo "WARNING: game at $size, bigger than GAME_RES $GAME_RES - set GAME_RES to it"
        FOLLOW_GEO="$GW $GH 0 0"
    else
        FOLLOW_GEO="$1 $2 0 0"
    fi
    [ "$size" != "$LAST_SIZE" ] && [ "${FOLLOW_GEO% * *}" != "$1 $2" ] \
        && echo "Window $size -> showing ${FOLLOW_GEO% * *}"
    LAST_SIZE="$size"
    [ "${FOLLOW_GEO% * *}" = "$MW $MH" ] && SCALE_FILTER="$MENU_FILTER" || SCALE_FILTER="$GAME_FILTER"
}

# Background helper (in_x): the match resolution saved in WA's Options,
# then the window followed (shared code)
watch_game_window() {
    MATCH="$(match_res)"
    echo "Match resolution in WA's settings: ${MATCH:-not set - GAME_RES $GAME_RES}"
    SCALE_FILTER="$MENU_FILTER"         # (the starting zoom is the menus)
    FOLLOW_PANELS="$GAME_ID-panels" FOLLOW_FENCE="$MOUSE_FENCE" follow_window 320 0
}

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the game's full size (Wine checks screen modes
    # against the monitor X reports, which otherwise follows the zoom -
    # ~853x480 in the menus - and the switch to GAME_RES for a match could
    # then be refused), then the menu size, with the menus' filter (shared
    # code)
    SCALE_FILTER="$MENU_FILTER" zoom_start "$GAME_RES" "$MW" "$MH"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"     # (over the menu zoom, or
                                                #   the whole TV)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings
    follow_start watch_game_window
    # Wine desktop of GAME_RES: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
