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
ffmpeg -v warning -i "$INPUT" -f null - 2>> "$LOG" || true

# --- カテゴリ別カウント ---
COUNT_AUDIO=$(grep -Ei "aac|audio|channel element|submitting packet to decoder" "$LOG" | wc -l)
COUNT_VIDEO=$(grep -Ei "mpeg2video|vist|vdec|invalid mb type|motion_type|ac-tex|Warning MVs|corrupt decoded frame" "$LOG" | wc -l)
COUNT_TS=$(grep -Ei "mpegts|Packet corrupt|corrupt input packet|non[- ]monotone|invalid dts|invalid pts|timestamp" "$LOG" | wc -l)
COUNT_TOTAL=$(grep -i "error" "$LOG" | wc -l)

# --- 要約 ---
SUMMARY="File: $BASENAME
Audio: $COUNT_AUDIO
Video: $COUNT_VIDEO
TS: $COUNT_TS
Total: $COUNT_TOTAL"

# --- 判定 ---
notify() {
    local LEVEL="$1"
    local MSG="$2"
    echo "$MSG"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: $LEVEL" -d "$MSG" "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}

if (( COUNT_AUDIO > 5 )); then
    notify 5 "AUDIO ERRORS in $BASENAME ($COUNT_AUDIO)"
elif (( COUNT_VIDEO > 5 )); then
    notify 4 "VIDEO ERRORS in $BASENAME ($COUNT_VIDEO)"
elif (( COUNT_TS > 5 )); then
    notify 3 "TS CORRUPTION in $BASENAME ($COUNT_TS)"
elif (( COUNT_TOTAL > 0 )); then
    echo "Minor issues detected in $BASENAME ($COUNT_TOTAL)"
else
    echo "OK: $BASENAME"
fi

rm -f "$LOG"
