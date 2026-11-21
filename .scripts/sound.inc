# =============================================================================
#  Shared sound code - loaded by common.inc
#
#  The Pi's HDMI sound plays one stream at a time. A private mixer just for
#  the game mixes its sounds into one stream to the TV - for a game that
#  needs two at once (sound effects + MIDI music, or + video soundtracks),
#  and to keep the TV's HDMI sound open for the whole game, so no sound
#  loses its start while it wakes up. EmulationStation and the emulators
#  keep using plain ALSA. Settings read from the game's script:
#    SOUND_MIXER    sound_mixer_start: 0 = none, 1 = PulseAudio, 2 = ALSA
#    HDMI_CARD      vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
#    PA_LATENCY_MS  PulseAudio mixer: sound buffered between the game and
#                   PulseAudio ("" = PulseAudio's default)
#    SOUNDFONT, MIDI_GAIN   FluidSynth
#    DEBUG=1        alsaloop's messages into the log
# =============================================================================

# ----- PulseAudio mixer --------------------------------------------------------
# pulse_mixer_start name
#   A private PulseAudio (files in the prefix's "pulse" folder), playing to
#   HDMI_CARD, used by everything started after this (Wine needs
#   "Audio"="pulse" in its registry). False, with a warning, if PulseAudio
#   isn't installed or didn't start.
PULSE_MIXER_ON=0
pulse_mixer_start() {
    local name="$1" i
    if ! command -v pulseaudio >/dev/null; then
        echo "WARNING: pulseaudio not installed - sound mixer off"
        return 1
    fi
    PA_DIR="$WINEPREFIX/pulse"
    mkdir -p "$PA_DIR"
    cat > "$PA_DIR/$name.pa" <<EOF
load-module module-alsa-sink device=hdmi:CARD=$HDMI_CARD,DEV=0 sink_name=hdmi tsched=0 rate=48000
load-module module-native-protocol-unix socket=$PA_DIR/native auth-anonymous=1
set-default-sink hdmi
EOF
    printf 'autospawn = no\nenable-shm = no\n' > "$PA_DIR/client.conf"
    export PULSE_CLIENTCONFIG="$PA_DIR/client.conf"
    export PULSE_SERVER="unix:$PA_DIR/native"
    [ -n "$PA_LATENCY_MS" ] && export PULSE_LATENCY_MSEC="$PA_LATENCY_MS"
    # A PulseAudio left over from a crash: end it and wait until it's gone
    if pkill -u "$(id -u)" -x pulseaudio; then
        for (( i = 0; i < 40; i++ )); do
            pgrep -u "$(id -u)" -x pulseaudio >/dev/null || break
            sleep 0.05
        done
        pkill -9 -u "$(id -u)" -x pulseaudio 2>/dev/null
    fi
    rm -f "$PA_DIR/native"
    if ! pulseaudio -n -F "$PA_DIR/$name.pa" --daemonize=yes --exit-idle-time=-1 \
            --use-pid-file=no --disable-shm=yes --log-target="file:$PA_DIR/pulse.log"; then
        echo "WARNING: PulseAudio failed to start - see $PA_DIR/pulse.log"
        unset PULSE_SERVER PULSE_CLIENTCONFIG PULSE_LATENCY_MSEC
        return 1
    fi
    PULSE_MIXER_ON=1
    # Ready as soon as its socket appears (at most 5 s)
    for (( i = 0; i < 100; i++ )); do
        [ -S "$PA_DIR/native" ] && { echo "Sound mixer on ($HDMI_CARD)"; return 0; }
        sleep 0.05
    done
    echo "WARNING: PulseAudio started but its socket didn't appear - see $PA_DIR/pulse.log"
    return 0
}

# pulse_mixer_stop - ends it (waits at most 1 s for it to go)
pulse_mixer_stop() {
    [ "$PULSE_MIXER_ON" = "1" ] || return 0
    PULSE_MIXER_ON=0
    pactl exit 2>/dev/null
    local i
    for (( i = 0; i < 20; i++ )); do
        pgrep -u "$(id -u)" -x pulseaudio >/dev/null || return 0
        sleep 0.05
    done
    pkill -u "$(id -u)" -x pulseaudio 2>/dev/null
    return 0
}

# ----- ALSA mixer --------------------------------------------------------------
#  Game (+ FluidSynth) -> plug -> dmix -> Loopback (snd-aloop) -> alsaloop -> HDMI
#  dmix can't write to the Pi's HDMI device directly (it only takes the
#  IEC958 format), so the mix goes through a loopback device, and alsaloop
#  keeps one stream open to the TV for the whole game.

# alsa_dmix_clear key
#   dmix keeps its mix in a shared memory block (+ a semaphore) named by its
#   ipc_key. One left behind by a program that was killed can make the next
#   one fail ("unable to create IPC shm instance" - e.g. FluidSynth then has
#   no sound). Removed when nothing is using it.
alsa_dmix_clear() {
    command -v ipcs >/dev/null || return 0
    local key id nattch
    key="$(printf '0x%08x' "$1")"
    while read -r id nattch; do
        if [ "$nattch" = "0" ]; then
            ipcrm -m "$id" 2>/dev/null && echo "Removed a left-over sound mixer memory block ($key)"
        fi
    done < <(ipcs -m 2>/dev/null | awk -v k="$key" 'tolower($1) == k {print $2, $6}')
    # The semaphore too - only once no memory block with this key is left
    ipcs -m 2>/dev/null | awk -v k="$key" 'tolower($1) == k {f = 1} END {exit !f}' && return 0
    while read -r id; do
        ipcrm -s "$id" 2>/dev/null
    done < <(ipcs -s 2>/dev/null | awk -v k="$key" 'tolower($1) == k {print $2}')
    return 0
}

# alsa_mixer_start name
#   name = prefix for its ALSA device names (e.g. lem -> lem_dmix). dmix's
#   ipc_key (its shared memory block's number) is 55555 for every game: only
#   one runs at a time, and a block left behind by a crash is cleared before
#   each start (alsa_dmix_clear). Exports ALSA_CONFIG_PATH: everything
#   started after this plays into the mix. False, with a warning, if it
#   couldn't start.
ALOOP_PID=""
ALOOP_LOADED=0
ALSA_MIXER_KEY=""
alsa_mixer_start() {
    local name="$1" key=55555
    if ! command -v alsaloop >/dev/null; then
        echo "WARNING: alsaloop not found (sudo apt install alsa-utils) - sound mixer off"
        return 1
    fi
    if ! grep -q Loopback /proc/asound/cards; then
        sudo -n modprobe snd-aloop || { echo "WARNING: could not load snd-aloop - sound mixer off"; return 1; }
        ALOOP_LOADED=1
        sleep 1
    fi
    pkill -u "$(id -u)" -x alsaloop 2>/dev/null && sleep 0.2     # leftover from a crash
    ALSA_MIXER_KEY="$key"
    alsa_dmix_clear "$key"
    local conf="$WINEPREFIX/$name-asound.conf" main="$WINEPREFIX/$name-alsa.conf"
    cat > "$conf" <<EOF
pcm.${name}_hdmi {
    type plug
    slave.pcm "hdmi:CARD=$HDMI_CARD,DEV=0"
}
pcm.${name}_dmix {
    type dmix
    ipc_key $key
    ipc_perm 0666
    slave {
        pcm "hw:Loopback,0,0"
        format S16_LE
        rate 48000
        channels 2
        period_size 1024
        buffer_size 8192
    }
}
pcm.!default {
    type asym
    playback.pcm { type plug slave.pcm "${name}_dmix" }
    capture.pcm "null"
}
EOF
    # A private copy of ALSA's main config without the part that loads
    # ~/.asoundrc and /etc/asound.conf: they're read AFTER any extra file,
    # so RetroPie's ~/.asoundrc "default" would replace the one above.
    # Only what's started after this uses it.
    awk '/^@hooks \[/ {s = 1} !s {print} s && /^\]/ {s = 0}' /usr/share/alsa/alsa.conf > "$main"
    export ALSA_CONFIG_PATH="$main:$conf"
    # -a off = fixed format (not the loopback's idle 1-channel setting, which HDMI refuses)
    local out=/dev/null; [ "$DEBUG" = "1" ] && out=/dev/stdout
    alsaloop -C hw:Loopback,1,0 -P "${name}_hdmi" -a off -r 48000 -f S16_LE -c 2 -t 100000 \
        >>"$out" 2>&1 &
    ALOOP_PID=$!
    echo "Sound mixer on ($HDMI_CARD)"
}

# alsa_mixer_stop - also clears dmix's memory block if it was left behind
alsa_mixer_stop() {
    [ -n "$ALOOP_PID" ] && kill "$ALOOP_PID" 2>/dev/null && wait "$ALOOP_PID" 2>/dev/null
    ALOOP_PID=""
    [ -n "$ALSA_MIXER_KEY" ] && alsa_dmix_clear "$ALSA_MIXER_KEY"
    [ "$ALOOP_LOADED" = "1" ] && sudo -n modprobe -r snd-aloop 2>/dev/null
    ALOOP_LOADED=0
    return 0
}

# ----- FluidSynth (MIDI music) -------------------------------------------------
# fluidsynth_start name
#   A MIDI synth (SOUNDFONT, MIDI_GAIN) for the game, playing into the
#   default ALSA device (the ALSA mixer, if started). name = its MIDI port's
#   name. Waits until its MIDI port is there (otherwise the game can start
#   before the soundfont has loaded and find no MIDI device), then checks
#   it really opened the sound device - if not, clears the mixer's
#   left-over memory block and tries once more. Its messages: in the log.
FLUID_PID=""
fluidsynth_start() {
    local name="$1" try flog="$WINEPREFIX/fluidsynth.log" i ok
    command -v fluidsynth >/dev/null || { echo "WARNING: fluidsynth not installed - no music"; return 1; }
    [ -f "$SOUNDFONT" ] || { echo "WARNING: soundfont not found: $SOUNDFONT - no music"; return 1; }
    pkill -u "$(id -u)" -x fluidsynth 2>/dev/null && sleep 0.5     # leftover from a crash
    for try in 1 2; do
        : > "$flog"
        fluidsynth -a alsa -m alsa_seq -o midi.alsa_seq.id="$name" \
            -o audio.realtime-prio=0 -o midi.realtime-prio=0 \
            -r 48000 -z 1024 -c 8 -g "${MIDI_GAIN:-1}" -is "$SOUNDFONT" >>"$flog" 2>&1 &
        FLUID_PID=$!
        ok=0
        for (( i = 0; i < 40; i++ )); do                 # at most 10 s
            kill -0 "$FLUID_PID" 2>/dev/null || break    # (ended - failed)
            if aconnect -o 2>/dev/null | grep -qi fluid; then ok=1; break; fi
            sleep 0.25
        done
        # Its sound device is opened before the MIDI port appears - any
        # complaint about it is in its messages by now
        sleep 0.2
        if [ -s "$flog" ]; then
            echo "FluidSynth:"; sed 's/^/    /' "$flog"
        fi
        if ! kill -0 "$FLUID_PID" 2>/dev/null; then
            ok=0
        elif grep -qiE "failed to open|couldn't (open|create)|audio driver|IPC shm" "$flog"; then
            ok=0
        fi
        [ "$ok" = "1" ] && { echo "Music on (FluidSynth)"; return 0; }
        kill "$FLUID_PID" 2>/dev/null; wait "$FLUID_PID" 2>/dev/null
        FLUID_PID=""
        [ "$try" = "1" ] || break
        echo "WARNING: FluidSynth didn't start properly - trying once more"
        [ -n "$ALSA_MIXER_KEY" ] && alsa_dmix_clear "$ALSA_MIXER_KEY"
        sleep 0.5
    done
    echo "WARNING: FluidSynth failed twice - no music this time (see the messages above)"
    return 1
}

fluidsynth_stop() {
    [ -n "$FLUID_PID" ] && kill "$FLUID_PID" 2>/dev/null && wait "$FLUID_PID" 2>/dev/null
    FLUID_PID=""
    return 0
}

# ----- The game's sound mixer (its SOUND_MIXER setting) -------------------------
# sound_mixer_start name [note]
#   Starts the mixer the game's SOUND_MIXER asks for:
#     0 = none - Wine plays straight to the TV through ALSA
#     1 = a private PulseAudio (pulse_mixer_start; Wine needs "Audio"="pulse")
#     2 = the ALSA mixer (alsa_mixer_start)
#   name = a short name for its files. Exports PULSE_SERVER /
#   ALSA_CONFIG_PATH: Wine started after this plays into the mix. If it
#   can't start: a warning (+ note, e.g. "no sound in this game without
#   it"), SOUND_MIXER=0 and false.
sound_mixer_start() {
    local name="$1" note="${2:+ - $2}"
    case "$SOUND_MIXER" in
        1) pulse_mixer_start "$name" && return 0
           echo "WARNING: PulseAudio sound mixer didn't start$note" ;;
        2) alsa_mixer_start "$name" && return 0
           echo "WARNING: ALSA sound mixer didn't start - plain ALSA instead$note" ;;
        *) echo "Sound mixer off (SOUND_MIXER=$SOUND_MIXER) - plain ALSA$note"
           return 0 ;;
    esac
    SOUND_MIXER=0
    return 1
}

# sound_mixer_stop - ends whichever was started
sound_mixer_stop() {
    pulse_mixer_stop
    alsa_mixer_stop
}

# ----- Clean-up ------------------------------------------------------------------
# sound_kill - ends this user's sound mixers and FluidSynth, however they
#   were started (for "--kill"; a normal exit uses the _stop functions)
sound_kill() {
    local p
    for p in pulseaudio alsaloop fluidsynth; do
        pkill -u "$(id -u)" -x "$p" 2>/dev/null
    done
    return 0
}
