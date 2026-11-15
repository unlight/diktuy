#!/bin/bash

umask 077

# ==========================================
# DIKTUY SETTINGS
# ==========================================
API_URL="https://api.diktuy.ru/v1/audio/transcriptions"

# Model prompt: your terms, up to 500 characters
TERMS="Kubernetes, Docker, API, CI/CD, pull request, commit, merge, deploy, backend, frontend, Python, Go, Linux"

AUDIO_OGG="/tmp/diktuy_speech.ogg"
PID_FILE="/tmp/diktuy_record.pid"
LOG_FILE="/tmp/diktuy.log"
LOCK_FILE="/tmp/diktuy.lock"
INDICATOR_PID_FILE="/tmp/diktuy_indicator.pid"

# Silent notifications: Cinnamon understands the suppress-sound hint
notify() {
    notify-send -h boolean:suppress-sound:true "$@"
}

# Persistent on-screen indicator, closed on the second key press
show_recording_indicator() {
    close_recording_indicator
    local previous_window pid win primary mw mx my x y
    local -a geometry
    previous_window=$(xdotool getactivewindow 2>/dev/null)

    primary=$(xrandr --query 2>/dev/null | grep ' connected primary ' | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)
    if [ -n "$primary" ]; then
        mw=${primary%%x*}
        mx=${primary#*+}
        mx=${mx%%+*}
        my=${primary##*+}
        x=$((mx + mw - 300 - 40))
        y=$((my + 40))
        geometry=(-geometry "300x80+${x}+${y}")
    fi

    xmessage -name DiktuyRecording -title "Diktuy Recording" \
        -buttons "" -borderwidth 0 -bg '#202020' -fg '#ff5555' \
        "${geometry[@]}" "REC  Press the key again to stop" \
        9>&- >/dev/null 2>&1 &
    pid=$!
    printf '%s' "$pid" > "$INDICATOR_PID_FILE"

    for _ in {1..30}; do
        win=$(xdotool search --onlyvisible --name '^Diktuy Recording$' 2>/dev/null | head -n1)
        [ -n "$win" ] && break
        sleep 0.05
    done

    if [ -z "$win" ]; then
        notify "Dictation" "Recording... Press the key AGAIN to send" -t 2000 -i audio-input-microphone
        return 0
    fi

    wmctrl -i -r "$win" -b add,above,skip_taskbar,skip_pager
    [ -n "$previous_window" ] && xdotool windowactivate "$previous_window" 2>/dev/null
}

close_recording_indicator() {
    if [ -f "$INDICATOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$INDICATOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null && [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "xmessage" ]; then
            kill "$pid" 2>/dev/null
            for _ in {1..10}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.05
            done
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$INDICATOR_PID_FILE"
    fi
}

# Single instance at a time: protects against double presses
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    notify "Dictation" "Already processing" -t 1500 -i dialog-information
    exit 0
fi

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    # ==========================================
    # STOP AND UPLOAD
    # ==========================================
    close_recording_indicator
    PID=$(cat "$PID_FILE")

    # Let the last syllable reach the encoder, then finalize the OGG
    sleep 0.2
    kill -INT "$PID" 2>/dev/null
    for _ in {1..20}; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$PID" 2>/dev/null
    rm -f "$PID_FILE"

    if [ ! -s "$AUDIO_OGG" ]; then
        notify "Dictation" "Empty recording" -i dialog-error
        rm -f "$AUDIO_OGG"
        exit 1
    fi

    # Check that the microphone actually captured sound
    AUDIO_STAT=$(sox "$AUDIO_OGG" -n stat 2>&1)
    if [ $? -ne 0 ]; then
        notify "Dictation" "Failed to read recording" -i dialog-error
        rm -f "$AUDIO_OGG"
        exit 1
    fi
    MAX_AMP=$(printf '%s\n' "$AUDIO_STAT" | awk '/Maximum amplitude/ {print $3}')
    MAX_AMP=${MAX_AMP:-0}
    if awk "BEGIN{exit !($MAX_AMP < 0.0005)}"; then
        notify "Dictation" "Microphone is silent, check the audio source" -i dialog-error
        rm -f "$AUDIO_OGG"
        exit 1
    fi

    API_KEY="$DIKTUY_API_KEY"
    if [ -z "$API_KEY" ]; then
        notify "Dictation" "DIKTUY_API_KEY is not set" -i dialog-error
        rm -f "$AUDIO_OGG"
        exit 1
    fi

    # Pass the key via a file so it does not appear in the process list
    HDR_FILE=$(mktemp)
    chmod 600 "$HDR_FILE"
    printf 'Authorization: Bearer %s\n' "$API_KEY" > "$HDR_FILE"
    trap 'rm -f "$HDR_FILE" "$AUDIO_OGG"' EXIT

    notify "Dictation" "Transcribing..." -t 8000 -i network-transmit

    for attempt in 1 2; do
        RESPONSE=$(curl -sS --connect-timeout 5 -m 30 -w '\n%{http_code}' -X POST "$API_URL" \
          -H @"$HDR_FILE" \
          -F "file=@${AUDIO_OGG}" \
          -F "language=auto" \
          -F "prompt=${TERMS}" \
          -F "response_format=text")

        HTTP_STATUS=$(printf '%s' "$RESPONSE" | tail -n1)
        TEXT=$(printf '%s\n' "$RESPONSE" | sed '$d')

        case "$HTTP_STATUS" in
            000|5*) [ "$attempt" = 1 ] && sleep 1 ;;
            *) break ;;
        esac
    done

    case "$HTTP_STATUS" in
        200)
            if [ -n "$TEXT" ]; then
                OLD_CLIPBOARD=$(xclip -selection clipboard -o 2>/dev/null)

                # 9>&- prevents xclip from inheriting flock and holding it after exit
                printf '%s ' "$TEXT" | xclip -selection clipboard 9>&-
                xdotool key shift+Insert

                sleep 0.2
                printf '%s' "$OLD_CLIPBOARD" | xclip -selection clipboard 9>&-
            else
                notify "Dictation" "Speech not recognized" -t 3000 -i dialog-information
            fi
            ;;
        *)
            printf '[%s] HTTP %s: %s\n' "$(date '+%F %T')" "$HTTP_STATUS" "$TEXT" >> "$LOG_FILE"
            notify "Error $HTTP_STATUS" "$TEXT" -i dialog-error
            echo "HTTP Status: $HTTP_STATUS. Body: $TEXT"
            ;;
    esac
else
    # ==========================================
    # START RECORDING
    # ==========================================
    if [ -z "${DIKTUY_API_KEY:-}" ]; then
        notify "Dictation" "DIKTUY_API_KEY is not set" -t 3000 -i dialog-error
        exit 1
    fi

    rm -f "$AUDIO_OGG"

    # ffmpeg records OGG directly; SIGINT writes the container trailer.
    # 9>&- closes the lock fd; otherwise ffmpeg holds flock for the entire recording.
    ffmpeg -hide_banner -loglevel error -nostdin -f pulse -i "${PULSE_SOURCE:-default}" \
        -ac 1 -ar 16000 -c:a libvorbis -q:a 3 -y "$AUDIO_OGG" \
        9>&- >/dev/null 2>&1 &
    REC_PID=$!

    echo "$REC_PID" > "$PID_FILE"

    show_recording_indicator
fi
