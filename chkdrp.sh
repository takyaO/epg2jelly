#!/bin/bash

# --- 環境変数のロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"

LOGFILE="/tmp/chkdrp.log"
LOG_PATTERN="error"

ffmpeg -v error -i "$1" -f null - 2> $LOGFILE
OUTPUT=$( grep "$LOG_PATTERN" $LOGFILE|tail) # LOG_PATTERN="error" だけ調べる
#OUTPUT=$( grep -i "$LOG_PATTERN" $LOGFILE|tail) # 大文字小文字区別しない

if [ -n "$OUTPUT" ]; then
    echo "ERROR: DROP $1 $OUTPUT"
    if [ -v NTFY_URL ]; then
	curl -H "X-Priority: 4" -d "ERROR: DROP $1 $OUTPUT" $NTFY_URL
    fi
fi

ffmpeg -v warning -i "$1" -f null - 2> $LOGFILE
OUTPUT=$( grep -Eq "non[- ]monotone|Invalid DTS|invalid PTS|corrupt|Packet corrupt|timestamp" $LOGFILE|tail)
if [ -n "$OUTPUT" ]; then
    echo "ERROR: CORRUPT $1 $OUTPUT"
    if [ -v NTFY_URL ]; then
	curl -H "X-Priority: 4" -d "ERROR: CORRUPT $1 $OUTPUT" $NTFY_URL
    fi
    exit 1
fi
