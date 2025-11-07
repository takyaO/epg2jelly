#!/bin/bash
# --- chkdrp.sh : M2TS/TSファイルの破損検査 ---
# 使い方: ./chkdrp.sh input.m2ts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

INPUT="$1"
BASENAME=$(basename "$INPUT")

# --- 一時ログ ---
LOG=$(mktemp /tmp/chkdrp.XXXXXX.log)

# --- ffmpegログ収集（error以上をすべて）---
ffmpeg -v error -i "$INPUT" -f null - 2> "$LOG" || true
# warningレベルも追記
#ffmpeg -v warning -i "$INPUT" -f null - 2>> "$LOG" || true

# --- カテゴリ別カウント ---
COUNT_AUDIO=$(grep -Ei "aac|audio|channel element|submitting packet to decoder" "$LOG" | wc -l)
COUNT_VIDEO=$(grep -Ei "mpeg2video|vist|vdec|invalid mb type|motion_type|ac-tex|Warning MVs|corrupt decoded frame" "$LOG" | wc -l)
COUNT_TS=$(grep -Ei "mpegts|Packet corrupt|corrupt input packet|non[- ]monotone|invalid dts|invalid pts|timestamp" "$LOG" | wc -l)
#COUNT_TOTAL=$(grep -i "error" "$LOG" | wc -l)

# --- 通知 ---
notify() {
    local LEVEL="$1"
    local MSG="$2"
    echo "$MSG"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: $LEVEL" -d "$MSG" "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}
MESSAGE=$(cat <<EOF
CHKDRP:  $BASENAME
Audio errors : $COUNT_AUDIO
Video errors: $COUNT_VIDEO
TS      errors: $COUNT_TS
EOF
)

echo "$MESSAGE"
notify 2 "$MESSAGE"

rm -f "$LOG"
