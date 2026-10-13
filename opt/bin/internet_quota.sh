#!/opt/bin/sh

CONFIG_DIR="/opt/etc/internet_quota"

CONFIG_FILE="$CONFIG_DIR/internet_quota.conf"
STATE_FILE="$CONFIG_DIR/internet_quota.state"
PID_FILE="$CONFIG_DIR/internet_quota.pid"


# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"


if [ -z "$MAC" ]; then
    echo "ERROR: MAC is not configured"
    exit 1
fi

if [ -z "$INTERVAL" ]; then
    INTERVAL=3
fi

if [ -z "$ACTIVE_THRESHOLD" ]; then
    ACTIVE_THRESHOLD=10000
fi

if [ -z "$DAILY_LIMIT" ]; then
    DAILY_LIMIT=7200
fi


# ------------------------------------------------------------
# Format seconds as HH:MM:SS
# ------------------------------------------------------------

format_time()
{
    TOTAL_SECONDS="$1"

    HOURS=$((TOTAL_SECONDS / 3600))
    MINUTES=$(((TOTAL_SECONDS % 3600) / 60))
    SECONDS=$((TOTAL_SECONDS % 60))

    printf "%02d:%02d:%02d" "$HOURS" "$MINUTES" "$SECONDS"
}


# ------------------------------------------------------------
# Get current RX/TX counters
# ------------------------------------------------------------

get_traffic()
{
    RX=0
    TX=0

    OUTPUT=$(ndmc -c "show ip hotspot $MAC" 2>/dev/null)

    RX=$(echo "$OUTPUT" | awk '
        /rxbytes:/ {
            print $2
            exit
        }
    ')

    TX=$(echo "$OUTPUT" | awk '
        /txbytes:/ {
            print $2
            exit
        }
    ')

    case "$RX" in
        ''|*[!0-9]*)
            RX=0
            ;;
    esac

    case "$TX" in
        ''|*[!0-9]*)
            TX=0
            ;;
    esac
}


# ------------------------------------------------------------
# Save current state
# ------------------------------------------------------------

save_state()
{
    TMP_STATE="${STATE_FILE}.tmp"

    {
        echo "DATE=$STATE_DATE"
        echo "ACTIVE_TIME=$ACTIVE_TIME"
        echo "BLOCKED=$BLOCKED"
    } > "$TMP_STATE"

    mv "$TMP_STATE" "$STATE_FILE"
}


# ------------------------------------------------------------
# Load state
# ------------------------------------------------------------

load_state()
{
    TODAY=$(date '+%Y-%m-%d')

    STATE_DATE=""
    ACTIVE_TIME=0
    BLOCKED=0

    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
        
        # Map the saved DATE to STATE_DATE.
        STATE_DATE=${DATE:-}
    fi


    # Validate ACTIVE_TIME
    case "$ACTIVE_TIME" in
        ''|*[!0-9]*)
            ACTIVE_TIME=0
            ;;
    esac


    # Validate BLOCKED
    case "$BLOCKED" in
        0|1)
            ;;
        *)
            BLOCKED=0
            ;;
    esac


    # New day
    if [ "$STATE_DATE" != "$TODAY" ]; then

        if [ "$BLOCKED" -eq 1 ]; then
            ndmc -c "no ip hotspot host $MAC policy" >/dev/null 2>&1
        fi

        STATE_DATE="$TODAY"
        ACTIVE_TIME=0
        BLOCKED=0

        save_state
    fi
}


# ------------------------------------------------------------
# Apply Internet blocking
# ------------------------------------------------------------

apply_no_internet_policy()
{
    ndmc -c "ip hotspot host $MAC policy NoInternet" >/dev/null 2>&1
}


# ------------------------------------------------------------
# Remove Internet blocking
# ------------------------------------------------------------

restore_internet_policy()
{
    ndmc -c "no ip hotspot host $MAC policy" >/dev/null 2>&1
}


# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup()
{
    rm -f "$PID_FILE"
    exit 0
}


# ------------------------------------------------------------
# Create configuration directory if necessary
# ------------------------------------------------------------

if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
fi


# ------------------------------------------------------------
# Prevent multiple instances
# ------------------------------------------------------------

if [ -f "$PID_FILE" ]; then

    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)

    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "internet_quota already running (PID $OLD_PID)"
        exit 1
    fi

    rm -f "$PID_FILE"
fi


echo $$ > "$PID_FILE"

trap cleanup INT TERM QUIT EXIT


# ------------------------------------------------------------
# Load state
# ------------------------------------------------------------

load_state


# ------------------------------------------------------------
# Restore blocking state after script restart
# ------------------------------------------------------------

if [ "$ACTIVE_TIME" -ge "$DAILY_LIMIT" ]; then

    if [ "$BLOCKED" -eq 0 ]; then

        apply_no_internet_policy

        BLOCKED=1
        save_state

    else

        # State says device is already blocked.
        # Re-apply policy in case router was restarted.
        apply_no_internet_policy

    fi

else

    if [ "$BLOCKED" -eq 0 ]; then
        restore_internet_policy
    fi

fi


# ------------------------------------------------------------
# Traffic monitoring variables
# ------------------------------------------------------------

PREV_RX=0
PREV_TX=0
PREV_TIME=0
PREV_STATE="IDLE"

FIRST_SAMPLE=1


# ------------------------------------------------------------
# Main monitoring loop
# ------------------------------------------------------------

while true
do

    # --------------------------------------------------------
    # Check date
    # --------------------------------------------------------

    TODAY=$(date '+%Y-%m-%d')

    if [ "$STATE_DATE" != "$TODAY" ]; then

        if [ "$BLOCKED" -eq 1 ]; then
            restore_internet_policy
        fi

        STATE_DATE="$TODAY"
        ACTIVE_TIME=0
        BLOCKED=0

        save_state

        PREV_RX=0
        PREV_TX=0
        PREV_TIME=0
        PREV_STATE="IDLE"

        FIRST_SAMPLE=1
    fi


    # --------------------------------------------------------
    # Read current traffic counters
    # --------------------------------------------------------

    get_traffic

    NOW=$(date '+%s')
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')


    # --------------------------------------------------------
    # First sample
    # --------------------------------------------------------

    if [ "$FIRST_SAMPLE" -eq 1 ]; then

        PREV_RX=$RX
        PREV_TX=$TX
        PREV_TIME=$NOW
        PREV_STATE="IDLE"

        FIRST_SAMPLE=0

        echo "$TIMESTAMP RX=$RX TX=$TX DELTA_RX=0 DELTA_TX=0 TOTAL=0 STATE=IDLE ACTIVE_TIME=$(format_time "$ACTIVE_TIME")"

        sleep "$INTERVAL"

        continue
    fi


    # --------------------------------------------------------
    # Calculate traffic delta
    # --------------------------------------------------------

    DELTA_RX=$((RX - PREV_RX))
    DELTA_TX=$((TX - PREV_TX))


    # --------------------------------------------------------
    # Protect against counter reset
    # --------------------------------------------------------

    if [ "$DELTA_RX" -lt 0 ]; then
        DELTA_RX=0
    fi

    if [ "$DELTA_TX" -lt 0 ]; then
        DELTA_TX=0
    fi


    TOTAL=$((DELTA_RX + DELTA_TX))


    # --------------------------------------------------------
    # Calculate REAL elapsed time
    # --------------------------------------------------------

    ELAPSED=$((NOW - PREV_TIME))

    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi


    # --------------------------------------------------------
    # Determine current interval state
    # --------------------------------------------------------

    if [ "$TOTAL" -ge "$ACTIVE_THRESHOLD" ]; then
        STATE="ACTIVE"
    else
        STATE="IDLE"
    fi


    # --------------------------------------------------------
    # Account previous interval
    #
    # The traffic delta calculated above belongs to the interval
    # between PREV_TIME and NOW.
    #
    # PREV_STATE describes that interval's activity.
    #
    # Therefore elapsed time is charged according to PREV_STATE.
    # --------------------------------------------------------

    if [ "$PREV_STATE" = "ACTIVE" ] && [ "$BLOCKED" -eq 0 ]; then

        ACTIVE_TIME=$((ACTIVE_TIME + ELAPSED))


        # ----------------------------------------------------
        # Daily quota exhausted
        # ----------------------------------------------------

        if [ "$ACTIVE_TIME" -ge "$DAILY_LIMIT" ]; then

            ACTIVE_TIME="$DAILY_LIMIT"

            apply_no_internet_policy

            BLOCKED=1

            save_state

            echo "$TIMESTAMP RX=$RX TX=$TX DELTA_RX=$DELTA_RX DELTA_TX=$DELTA_TX TOTAL=$TOTAL STATE=$STATE ELAPSED=${ELAPSED}s ACTIVE_TIME=$(format_time "$ACTIVE_TIME") QUOTA_EXHAUSTED=YES"

            PREV_RX=$RX
            PREV_TX=$TX
            PREV_TIME=$NOW
            PREV_STATE="$STATE"

            sleep "$INTERVAL"

            continue
        fi


        save_state
    fi


    # --------------------------------------------------------
    # Output current status
    # --------------------------------------------------------

    echo "$TIMESTAMP RX=$RX TX=$TX DELTA_RX=$DELTA_RX DELTA_TX=$DELTA_TX TOTAL=$TOTAL STATE=$STATE ELAPSED=${ELAPSED}s ACTIVE_TIME=$(format_time "$ACTIVE_TIME")"


    # --------------------------------------------------------
    # Save current values
    # --------------------------------------------------------

    PREV_RX=$RX
    PREV_TX=$TX
    PREV_TIME=$NOW
    PREV_STATE="$STATE"


    # --------------------------------------------------------
    # Wait until next measurement
    # --------------------------------------------------------

    sleep "$INTERVAL"

done
