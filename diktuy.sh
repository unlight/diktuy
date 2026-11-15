#!/bin/bash

umask 077

# ==========================================
# DIKTUY SETTINGS
# ==========================================
API_URL="https://api.diktuy.ru/v1/audio/transcriptions"

# Model prompt: your terms, up to 500 characters
TERMS="Kubernetes, Docker, API, CI/CD, pull request, commit, merge, deploy, backend, frontend, Python, Go, Linux"

AUDIO_RAW="/tmp/diktuy_speech.raw"
AUDIO_OGG="/tmp/diktuy_speech.ogg"
PID_FILE="/tmp/diktuy_record.pid"
LOG_FILE="/tmp/diktuy.log"
LOCK_FILE="/tmp/diktuy.lock"
NOTIFY_ID_FILE="/tmp/diktuy_notification_id"

# Silent notifications: Cinnamon understands the suppress-sound hint
notify() {
    notify-send -h boolean:suppress-sound:true "$@"
}

# Persistent notification that stays until the second key press
show_recording_indicator() {
    close_recording_indicator
    local id
    id=$(gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify \
        "Dictation" 0 "media-record" "Recording" \
        "Press the key again to stop" [] "{'suppress-sound': <true>}" 0 2>/dev/null \
        | awk '{print $2}' | tr -d ',)')

    case "$id" in
        ''|*[!0-9]*) id="" ;;
    esac

    if [ -n "$id" ]; then
        printf '%s' "$id" > "$NOTIFY_ID_FILE"
    else
        notify "Dictation" "Recording... Press the key AGAIN to send" -t 2000 -i audio-input-microphone
    fi
}

close_recording_indicator() {
    if [ -f "$NOTIFY_ID_FILE" ]; then
        local id
        id=$(cat "$NOTIFY_ID_FILE")
        gdbus call --session --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null 2>&1
        rm -f "$NOTIFY_ID_FILE"
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

    # Let the last syllable reach the buffer, then stop arecord
    sleep 0.2
    kill "$PID" 2>/dev/null
    for _ in {1..20}; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$PID" 2>/dev/null
    rm -f "$PID_FILE"

    if [ ! -s "$AUDIO_RAW" ]; then
        notify "Dictation" "Empty recording" -i dialog-error
        rm -f "$AUDIO_RAW"
        exit 1
    fi

    # Check that the microphone actually captured sound
    MAX_AMP=$(sox -r 16000 -c 1 -e signed-integer -b 16 -t raw "$AUDIO_RAW" -n stat 2>&1 | awk '/Maximum amplitude/ {print $3}')
    MAX_AMP=${MAX_AMP:-0}
    if awk "BEGIN{exit !($MAX_AMP < 0.0005)}"; then
        notify "Dictation" "Microphone is silent, check the audio source" -i dialog-error
        rm -f "$AUDIO_RAW"
        exit 1
    fi

    # OGG is about 15 times smaller than WAV, so uploads are much faster
    rm -f "$AUDIO_OGG"
    sox -r 16000 -c 1 -e signed-integer -b 16 -t raw "$AUDIO_RAW" -C 3 "$AUDIO_OGG" 2>/dev/null
    rm -f "$AUDIO_RAW"

    if [ ! -s "$AUDIO_OGG" ]; then
        notify "Dictation" "Failed to prepare audio" -i dialog-error
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

    rm -f "$AUDIO_RAW"

    # arecord writes raw PCM immediately and does not lose the tail on stop.
    # 9>&- closes the lock fd; otherwise arecord holds flock for the entire recording.
    arecord -q -D pulse -f S16_LE -r 16000 -c 1 -B 100000 -t raw "$AUDIO_RAW" 2>/dev/null 9>&- &
    REC_PID=$!

    echo "$REC_PID" > "$PID_FILE"

    show_recording_indicator
fi
