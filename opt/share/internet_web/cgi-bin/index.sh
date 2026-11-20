#!/opt/bin/sh

# ============================================================
# Internet Quota Web Interface
# ============================================================

export PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin

CONFIG_FILE="/opt/etc/internet_web/internet_web.conf"
QUOTA_INIT="/opt/etc/init.d/S99internet_quota"
PID_FILE="/opt/etc/internet_quota/internet_quota.pid"

# ------------------------------------------------------------
# Load web configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo "ERROR: Web configuration not found: $CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"

# ------------------------------------------------------------
# Handle POST requests
# ------------------------------------------------------------

if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    BODY=""
    CONTENT_LENGTH=${CONTENT_LENGTH:-0}

    case "$CONTENT_LENGTH" in
        ''|*[!0-9]*)
            CONTENT_LENGTH=0
            ;;
    esac

    if [ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le 64 ]; then
        BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    fi

    RESULT=""
    NEW_LIMIT=""

    case "$BODY" in
        action=reset)
            if [ -x "$QUOTA_INIT" ]; then
                "$QUOTA_INIT" reset >/dev/null 2>&1
                RESET_RC=$?
            else
                RESET_RC=1
            fi

            if [ "$RESET_RC" -eq 0 ]; then
                RESULT="reset_ok"
            else
                RESULT="reset_error"
            fi
            ;;

        action=set_limit\&hours=1)
            NEW_LIMIT=3600
            ;;
        action=set_limit\&hours=2)
            NEW_LIMIT=7200
            ;;
        action=set_limit\&hours=3)
            NEW_LIMIT=10800
            ;;
        action=set_limit\&hours=4)
            NEW_LIMIT=14400
            ;;

        action=service_start)
            if [ -x "$QUOTA_INIT" ]; then
                "$QUOTA_INIT" start >/dev/null 2>&1
                SERVICE_RC=$?
            else
                SERVICE_RC=1
            fi

            if [ "$SERVICE_RC" -eq 0 ]; then
                RESULT="service_start_ok"
            else
                RESULT="service_start_error"
            fi
            ;;

        action=service_stop)
            if [ -x "$QUOTA_INIT" ]; then
                "$QUOTA_INIT" stop >/dev/null 2>&1
                SERVICE_RC=$?
            else
                SERVICE_RC=1
            fi

            if [ "$SERVICE_RC" -eq 0 ]; then
                RESULT="service_stop_ok"
            else
                RESULT="service_stop_error"
            fi
            ;;

        *)
            RESULT="bad_request"
            ;;
    esac

    # --------------------------------------------------------
    # Change daily limit
    # --------------------------------------------------------

    if [ -n "$NEW_LIMIT" ]; then
        if [ ! -f "$QUOTA_CONFIG" ]; then
            RESULT="limit_error"
        elif [ "$(grep -c '^DAILY_LIMIT=' "$QUOTA_CONFIG")" -ne 1 ]; then
            RESULT="limit_error"
        else
            TMP_CONFIG="${QUOTA_CONFIG}.tmp.$$"

            if awk -v limit="$NEW_LIMIT" '
                /^DAILY_LIMIT=/ {
                    print "DAILY_LIMIT=" limit
                    count++
                    next
                }
                { print }
                END {
                    if (count != 1)
                        exit 2
                }
            ' "$QUOTA_CONFIG" > "$TMP_CONFIG"; then
                if mv "$TMP_CONFIG" "$QUOTA_CONFIG"; then
                    if "$QUOTA_INIT" restart >/dev/null 2>&1; then
                        RESULT="limit_ok"
                    else
                        RESULT="limit_restart_error"
                    fi
                else
                    rm -f "$TMP_CONFIG"
                    RESULT="limit_error"
                fi
            else
                rm -f "$TMP_CONFIG"
                RESULT="limit_error"
            fi
        fi
    fi

    # Redirect after POST to prevent duplicate submissions.
    echo "Status: 303 See Other"
    echo "Location: index.sh?result=$RESULT"
    echo "Cache-Control: no-store"
    echo
    exit 0
fi

# ------------------------------------------------------------
# Default values
# ------------------------------------------------------------

MAC="unknown"
INTERVAL=0
ACTIVE_THRESHOLD=0
DAILY_LIMIT=0

STATE_DATE=""
ACTIVE_TIME=0
BLOCKED=0

# ------------------------------------------------------------
# Load quota configuration
# ------------------------------------------------------------

if [ -f "$QUOTA_CONFIG" ]; then
    . "$QUOTA_CONFIG"
fi

MAC=${MAC:-unknown}
INTERVAL=${INTERVAL:-0}
ACTIVE_THRESHOLD=${ACTIVE_THRESHOLD:-0}
DAILY_LIMIT=${DAILY_LIMIT:-0}

# ------------------------------------------------------------
# Load device name and IP address from Keenetic
# ------------------------------------------------------------

DEVICE_NAME=""
DEVICE_IP=""

if [ "$MAC" != "unknown" ]; then
    DEVICE_INFO=$(ndmc -c "show ip hotspot $MAC" 2>/dev/null)

    DEVICE_NAME=$(printf '%s\\n' "$DEVICE_INFO" |
        awk '$1 == "hostname:" { print $2; exit }')

    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME=$(printf '%s\\n' "$DEVICE_INFO" |
            awk '$1 == "name:" { print $2; exit }')
    fi

    DEVICE_IP=$(printf '%s\\n' "$DEVICE_INFO" |
        awk '$1 == "ip:" { print $2; exit }')
fi

# Fall back to the MAC address if Keenetic has no device name.
DEVICE_NAME=${DEVICE_NAME:-$MAC}
DEVICE_IP=${DEVICE_IP:-"Не определён"}

# ------------------------------------------------------------
# Load quota state
# ------------------------------------------------------------

if [ -f "$QUOTA_STATE" ]; then
    unset DATE ACTIVE_TIME BLOCKED
    . "$QUOTA_STATE"

    STATE_DATE=${DATE:-}
    ACTIVE_TIME=${ACTIVE_TIME:-0}
    BLOCKED=${BLOCKED:-0}
fi

# ------------------------------------------------------------
# Validate numeric values
# ------------------------------------------------------------

case "$ACTIVE_TIME" in
    ''|*[!0-9]*) ACTIVE_TIME=0 ;;
esac

case "$DAILY_LIMIT" in
    ''|*[!0-9]*) DAILY_LIMIT=0 ;;
esac

case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=0 ;;
esac

case "$ACTIVE_THRESHOLD" in
    ''|*[!0-9]*) ACTIVE_THRESHOLD=0 ;;
esac

case "$BLOCKED" in
    0|1) ;;
    *) BLOCKED=0 ;;
esac

# ------------------------------------------------------------
# Current date and time
# ------------------------------------------------------------

TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%Y-%m-%d %H:%M:%S')

# If state belongs to another day, display zero usage.
# The quota service performs the actual daily reset.
if [ "$STATE_DATE" != "$TODAY" ]; then
    ACTIVE_TIME=0
    BLOCKED=0
fi

# ------------------------------------------------------------
# Calculate remaining quota
# ------------------------------------------------------------

REMAINING=$((DAILY_LIMIT - ACTIVE_TIME))
if [ "$REMAINING" -lt 0 ]; then
    REMAINING=0
fi

# ------------------------------------------------------------
# Format seconds as HH:MM:SS
# ------------------------------------------------------------

format_time()
{
    TOTAL="$1"
    HOURS=$((TOTAL / 3600))
    MINUTES=$(((TOTAL % 3600) / 60))
    SECONDS=$((TOTAL % 60))
    printf "%02d:%02d:%02d" "$HOURS" "$MINUTES" "$SECONDS"
}

# ------------------------------------------------------------
# Select currently configured daily limit
# ------------------------------------------------------------

LIMIT_1_SELECTED=""
LIMIT_2_SELECTED=""
LIMIT_3_SELECTED=""
LIMIT_4_SELECTED=""

case "$DAILY_LIMIT" in
    3600)  LIMIT_1_SELECTED="selected" ;;
    7200)  LIMIT_2_SELECTED="selected" ;;
    10800) LIMIT_3_SELECTED="selected" ;;
    14400) LIMIT_4_SELECTED="selected" ;;
esac

# ------------------------------------------------------------
# Internet status
# ------------------------------------------------------------

if [ "$BLOCKED" -eq 1 ]; then
    INTERNET_STATUS="Заблокирован"
else
    INTERNET_STATUS="Разрешён"
fi

# ------------------------------------------------------------
# Quota service status
# ------------------------------------------------------------

SERVICE_STATUS="Остановлен"
SERVICE_RUNNING=0

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    case "$PID" in
        ''|*[!0-9]*)
            ;;
        *)
            if [ -d "/proc/$PID" ]; then
                SERVICE_STATUS="Работает"
                SERVICE_RUNNING=1
            fi
            ;;
    esac
fi

# ------------------------------------------------------------
# Result message
# ------------------------------------------------------------

RESULT_MESSAGE=""

case "${QUERY_STRING:-}" in
    result=reset_ok)
        RESULT_MESSAGE="Квота успешно сброшена."
        ;;
    result=reset_error)
        RESULT_MESSAGE="Ошибка сброса квоты. Проверь журнал сервиса."
        ;;
    result=limit_ok)
        RESULT_MESSAGE="Дневной лимит успешно изменён."
        ;;
    result=limit_error)
        RESULT_MESSAGE="Ошибка изменения конфигурации лимита."
        ;;
    result=limit_restart_error)
        RESULT_MESSAGE="Лимит сохранён, но перезапуск сервиса завершился ошибкой. Проверь его статус."
        ;;
    result=service_start_ok)
        RESULT_MESSAGE="Команда запуска службы выполнена."
        ;;
    result=service_start_error)
        RESULT_MESSAGE="Не удалось запустить службу. Проверь журнал сервиса."
        ;;
    result=service_stop_ok)
        RESULT_MESSAGE="Команда остановки службы выполнена. Накопленное время сохранено."
        ;;
    result=service_stop_error)
        RESULT_MESSAGE="Не удалось остановить службу. Проверь её статус."
        ;;
    result=bad_request)
        RESULT_MESSAGE="Некорректный запрос."
        ;;
esac

# ------------------------------------------------------------
# CGI response headers
# ------------------------------------------------------------

echo "Content-Type: text/html; charset=UTF-8"
echo "Cache-Control: no-cache, no-store, must-revalidate"
echo "Pragma: no-cache"
echo "Expires: 0"
echo

# ------------------------------------------------------------
# HTML
# ------------------------------------------------------------

cat <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="refresh" content="10">
    <title>Квота интернета</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: Arial, sans-serif;
            background: #f2f3f5;
            color: #222;
            margin: 0;
            padding: 24px 12px;
        }
        .container { max-width: 680px; margin: 0 auto; }
        .card {
            background: #fff;
            border-radius: 12px;
            padding: 24px;
            box-shadow: 0 2px 8px rgba(0,0,0,.10);
        }
        h1 { margin: 0 0 22px; font-size: 25px; }
        table { width: 100%; border-collapse: collapse; }
        td {
            padding: 12px 4px;
            border-bottom: 1px solid #eee;
            overflow-wrap: anywhere;
        }
        td.label { width: 48%; color: #666; }
        td.value { font-weight: bold; text-align: right; }
        .status { font-size: 17px; }
        .actions {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-top: 22px;
        }
        .button {
            display: inline-block;
            padding: 11px 16px;
            border: 0;
            border-radius: 7px;
            font-size: 15px;
            text-decoration: none;
            cursor: pointer;
            text-align: center;
        }
        .refresh { background: #e8edf3; color: #222; }
        .reset { background: #b42318; color: #fff; }
        .start { background: #18794e; color: #fff; }
        .stop { background: #8a4b08; color: #fff; }
        .message {
            margin-top: 16px;
            padding: 11px;
            border-radius: 7px;
            background: #eef5ee;
            overflow-wrap: anywhere;
        }
        .limit-form {
            flex: 1 1 100%;
            margin: 0;
            padding-top: 8px;
        }
        .limit-form label {
            display: block;
            margin-bottom: 8px;
            color: #555;
        }
        .limit-form select {
            padding: 10px;
            border: 1px solid #ccc;
            border-radius: 6px;
            font-size: 15px;
            background: white;
            min-width: 120px;
        }
        .limit-form button { margin-left: 8px; }
        .service-form { margin: 0; flex: 1 1 auto; }
        .service-form button { width: 100%; }
        .footer {
            margin-top: 20px;
            color: #888;
            font-size: 12px;
            line-height: 1.7;
        }
        @media (max-width: 420px) {
            .card { padding: 17px; }
            td { padding: 10px 3px; font-size: 14px; }
            .button { width: 100%; }
            .limit-form select { width: 100%; }
            .limit-form button { margin: 10px 0 0; }
        }
    </style>
</head>
<body>
<div class="container">
    <div class="card">
        <h1>Квота интернета</h1>
        <table>
            <tr><td class="label">Устройство</td><td class="value">$DEVICE_NAME</td></tr>
            <tr><td class="label">IP-адрес</td><td class="value">$DEVICE_IP</td></tr>
            <tr><td class="label">MAC-адрес</td><td class="value">$MAC</td></tr>
            <tr><td class="label">Дата</td><td class="value">$TODAY</td></tr>
            <tr><td class="label">Доступ в интернет</td><td class="value status">$INTERNET_STATUS</td></tr>
            <tr><td class="label">Использовано сегодня</td><td class="value">$(format_time "$ACTIVE_TIME")</td></tr>
            <tr><td class="label">Осталось</td><td class="value">$(format_time "$REMAINING")</td></tr>
            <tr><td class="label">Дневной лимит</td><td class="value">$(format_time "$DAILY_LIMIT")</td></tr>
            <tr><td class="label">Порог активности</td><td class="value">$ACTIVE_THRESHOLD байт</td></tr>
            <tr><td class="label">Интервал проверки</td><td class="value">$INTERVAL сек.</td></tr>
            <tr><td class="label">Сервис квоты</td><td class="value">$SERVICE_STATUS</td></tr>
        </table>

        <div class="actions">
            <a class="button refresh" href="index.sh">Обновить</a>

            <form method="post" action="index.sh" class="service-form">
                <button class="button start" type="submit" name="action" value="service_start" $([ "$SERVICE_RUNNING" -eq 1 ] && printf 'disabled')>
                    Запустить службу
                </button>
            </form>

            <form method="post" action="index.sh" class="service-form"
                  onsubmit="return confirm('Остановить мониторинг квоты? Накопленное время сохранится, но автоматический контроль будет приостановлен.');">
                <button class="button stop" type="submit" name="action" value="service_stop" $([ "$SERVICE_RUNNING" -eq 0 ] && printf 'disabled')>
                    Остановить службу
                </button>
            </form>

            <form method="post" action="index.sh"
                  onsubmit="return confirm('Сбросить использованное время за сегодня?');"
                  style="margin: 0; flex: 1 1 auto;">
                <button class="button reset" type="submit" name="action" value="reset" style="width: 100%;">
                    Сбросить квоту
                </button>
            </form>

            <form method="post" action="index.sh" class="limit-form">
                <input type="hidden" name="action" value="set_limit">
                <label for="hours">Дневной лимит:</label>
                <select id="hours" name="hours">
                    <option value="1" $LIMIT_1_SELECTED>1 час</option>
                    <option value="2" $LIMIT_2_SELECTED>2 часа</option>
                    <option value="3" $LIMIT_3_SELECTED>3 часа</option>
                    <option value="4" $LIMIT_4_SELECTED>4 часа</option>
                </select>
                <button class="button refresh" type="submit">Сохранить лимит</button>
            </form>
        </div>

HTML

if [ -n "$RESULT_MESSAGE" ]; then
    printf '        <div class="message">%s</div>\n' "$RESULT_MESSAGE"
fi

cat <<HTML
        <div class="footer">
            Обновлено: $NOW<br>
            Автоматическое обновление: 10 секунд
        </div>
    </div>
</div>
</body>
</html>
HTML
EOF