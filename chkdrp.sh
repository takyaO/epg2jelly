#!/bin/bash
# --- chkdrp.sh : M2TS/TSファイルの破損・メモリ爆発予兆検査 ---
# 使い方: ./chkdrp.sh input.m2ts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

INPUT="$1"
BASENAME=$(basename "$INPUT")

# --- 一時ログファイル ---
LOG=$(mktemp /tmp/chkdrp.XXXXXX.log)

# --- FFmpegの実行 ---
# M2TSは正常でも終了コードが1になりがち(終了コードによる成否判定はしない)
set +e
ffmpeg -v warning -i "$INPUT" -f null - 2> "$LOG"
set -e

# =================================================================
#  判定：キーワードの仕分け
# =================================================================

# 1. 【CRITICAL】メモリ爆発（同期待ちループ）を引き起こす可能性あり
CRITICAL_PATTERN="0 channels|unspecified sample format|no TS found at start|no PTS found"

# 2. 【WARN】パケットは壊れているが、FFmpegが「捨てて進む」ことができる警告
WARN_PATTERN="start time for stream|Could not find codec parameters|channel element|Invalid frame dimensions|PES packet size mismatch|Packet corrupt|corrupt decoded frame|Input buffer exhausted"

# --- カウント実行 ---
COUNT_CRITICAL=$(grep -Ei "$CRITICAL_PATTERN" "$LOG" | wc -l || true)
COUNT_WARN=$(grep -Ei "$WARN_PATTERN" "$LOG" | wc -l || true)

# --- 通知処理 ---
notify() {
    local LEVEL="$1"
    local MSG="$2"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: $LEVEL" -d "$MSG" "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}

if (( COUNT_CRITICAL > 0 )); then
    #  パターン1：危険（要警戒）
    RESULT_STR="CRITICAL"
    MESSAGE=$(cat <<EOF
CHKDRP: $BASENAME
$RESULT_STR :  危険を検知. Critical_Lines: $COUNT_CRITICAL, Total_Warnings: $COUNT_WARN
EOF
    )
    echo "$MESSAGE"
    notify 4 "$MESSAGE"
    exit 1
elif (( COUNT_WARN > 0 )); then
    #  パターン2：軽微な警告あり（通常ドロップ・問題なし）
    RESULT_STR="WARNING"
    MESSAGE=$(cat <<EOF
CHKDRP: $BASENAME
$RESULT_STR :  軽微なドロップ. Total_Warnings: $COUNT_WARN
EOF
    )
    echo "$MESSAGE"
    notify 1 "$MESSAGE"

else
    #  パターン3：完全正常
    RESULT_STR="SUCCESS"
    MESSAGE=$(cat <<EOF
CHKDRP: $BASENAME
$RESULT_STR :  エラー・警告なし
EOF
    )
    echo "$MESSAGE"
    notify 1 "$MESSAGE"
fi

# ログを削除; 正常終了(0)
rm -f "$LOG"
exit 0
