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
LOG2=$(mktemp /tmp/chkdrp.XXXXXX.log)

# --- ffmpegログ収集（error以上をすべて）---
ffmpeg -v error -i "$INPUT" -f null - 2> "$LOG" || true
# warningレベル
ffmpeg -v warning -i "$INPUT" -f null - 2> "$LOG2" || true

# --- カテゴリ別カウント ---
COUNT_TOTAL=$(grep -i "error" "$LOG" | wc -l)
COUNT_AUDIO=$(grep -Ei "aac|audio|channel element|submitting packet to decoder" "$LOG2" | wc -l)
COUNT_VIDEO=$(grep -Ei "mpeg2video|vist|vdec|invalid mb type|motion_type|ac-tex|Warning MVs|corrupt decoded frame" "$LOG2" | wc -l)
COUNT_TS=$(grep -Ei "mpegts|Packet corrupt|corrupt input packet|non[- ]monotone|invalid dts|invalid pts|timestamp" "$LOG2" | wc -l)

# --- 通知 ---
notify() {
    local LEVEL="$1"
    local MSG="$2"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: $LEVEL" -d "$MSG" "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}
MESSAGE=$(cat <<EOF
CHKDRP: $BASENAME
ERRORS: $COUNT_TOTAL, WARNINGS: $(( COUNT_AUDIO + COUNT_VIDEO + COUNT_TS )) (Audio: $COUNT_AUDIO, Video: $COUNT_VIDEO, TS: $COUNT_TS)
EOF
)

echo "$MESSAGE"
if (( COUNT_TOTAL > 0 )); then
    notify 3 "$MESSAGE"
else
    notify 1 "$MESSAGE"
fi


rm -f "$LOG"
rm -f "$LOG2"
