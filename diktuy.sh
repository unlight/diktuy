#!/bin/bash

umask 077

# ==========================================
# НАСТРОЙКИ DIKTUY
# ==========================================
API_URL="https://api.diktuy.ru/v1/audio/transcriptions"

# Подсказка для модели: ваши термины, до 500 символов
TERMS="Kubernetes, Docker, API, CI/CD, pull request, commit, merge, deploy, backend, frontend, Python, Go, Linux"

AUDIO_RAW="/tmp/diktuy_speech.raw"
AUDIO_OGG="/tmp/diktuy_speech.ogg"
PID_FILE="/tmp/diktuy_record.pid"
LOG_FILE="/tmp/diktuy.log"
LOCK_FILE="/tmp/diktuy.lock"

# Уведомления без звука: Cinnamon понимает hint suppress-sound
notify() {
    notify-send -h boolean:suppress-sound:true "$@"
}

# Один экземпляр за раз: защита от двойного нажатия
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    notify "Диктовка" "Уже идёт обработка" -t 1500 -i dialog-information
    exit 0
fi

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    # ==========================================
    # ОСТАНОВКА И ОТПРАВКА
    # ==========================================
    PID=$(cat "$PID_FILE")

    # Даём последнему слогу дойти до буфера и останавливаем arecord
    sleep 0.2
    kill "$PID" 2>/dev/null
    for _ in {1..20}; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$PID" 2>/dev/null
    rm -f "$PID_FILE"

    if [ ! -s "$AUDIO_RAW" ]; then
        notify "Диктовка" "Запись пустая" -i dialog-error
        rm -f "$AUDIO_RAW"
        exit 1
    fi

    # Проверяем, что микрофон действительно писал звук
    MAX_AMP=$(sox -r 16000 -c 1 -e signed-integer -b 16 -t raw "$AUDIO_RAW" -n stat 2>&1 | awk '/Maximum amplitude/ {print $3}')
    MAX_AMP=${MAX_AMP:-0}
    if awk "BEGIN{exit !($MAX_AMP < 0.0005)}"; then
        notify "Диктовка" "Микрофон молчит, проверьте источник звука" -i dialog-error
        rm -f "$AUDIO_RAW"
        exit 1
    fi

    # OGG примерно в 15 раз меньше WAV, загрузка заметно быстрее
    rm -f "$AUDIO_OGG"
    sox -r 16000 -c 1 -e signed-integer -b 16 -t raw "$AUDIO_RAW" -C 3 "$AUDIO_OGG" 2>/dev/null
    rm -f "$AUDIO_RAW"

    if [ ! -s "$AUDIO_OGG" ]; then
        notify "Диктовка" "Не удалось подготовить аудио" -i dialog-error
        exit 1
    fi

    API_KEY="$DIKTUY_API_KEY"
    if [ -z "$API_KEY" ]; then
        notify "Диктовка" "Не задана переменная DIKTUY_API_KEY" -i dialog-error
        rm -f "$AUDIO_OGG"
        exit 1
    fi

    # Ключ передаём через файл, чтобы он не светился в списке процессов
    HDR_FILE=$(mktemp)
    chmod 600 "$HDR_FILE"
    printf 'Authorization: Bearer %s\n' "$API_KEY" > "$HDR_FILE"
    trap 'rm -f "$HDR_FILE" "$AUDIO_OGG"' EXIT

    notify "Диктовка" "Распознавание..." -t 8000 -i network-transmit

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

                # 9>&- не даёт xclip унаследовать flock и держать его после выхода
                printf '%s ' "$TEXT" | xclip -selection clipboard 9>&-
                xdotool key shift+Insert

                sleep 0.2
                printf '%s' "$OLD_CLIPBOARD" | xclip -selection clipboard 9>&-
            else
                notify "Диктовка" "Речь не распознана" -t 3000 -i dialog-information
            fi
            ;;
        *)
            printf '[%s] HTTP %s: %s\n' "$(date '+%F %T')" "$HTTP_STATUS" "$TEXT" >> "$LOG_FILE"
            notify "Ошибка $HTTP_STATUS" "$TEXT" -i dialog-error
            echo "HTTP Status: $HTTP_STATUS. Body: $TEXT"
            ;;
    esac
else
    # ==========================================
    # НАЧАЛО ЗАПИСИ
    # ==========================================
    if [ -z "${DIKTUY_API_KEY:-}" ]; then
        notify "Диктовка" "Не задана переменная DIKTUY_API_KEY" -t 3000 -i dialog-error
        exit 1
    fi

    rm -f "$AUDIO_RAW"

    # arecord пишет сырой PCM сразу и не теряет хвост при остановке.
    # 9>&- закрывает fd блокировки, иначе arecord держит flock всё время записи.
    arecord -q -D pulse -f S16_LE -r 16000 -c 1 -B 100000 -t raw "$AUDIO_RAW" 2>/dev/null 9>&- &
    REC_PID=$!

    echo "$REC_PID" > "$PID_FILE"

    notify "Диктовка" "Запись пошла... Нажмите клавишу ЕЩЁ РАЗ для отправки" -t 2000 -i audio-input-microphone
fi
