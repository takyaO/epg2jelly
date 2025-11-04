#!/bin/bash
# --- chkdrp.sh : M2TSエラーチェック＆通知 ---
# 使い方: ./chkdrp.sh input.m2ts

set -euo pipefail

# --- 環境変数のロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

INPUT="$1"
BASENAME=$(basename "$INPUT")

# --- 一時ログファイル ---
LOG_ERR=$(mktemp /tmp/chkdrp.err.XXXXXX.log)
LOG_WARN=$(mktemp /tmp/chkdrp.warn.XXXXXX.log)

# --- ffmpegでログ取得 ---
ffmpeg -v error   -i "$INPUT" -f null - 2> "$LOG_ERR"   || true
ffmpeg -v warning -i "$INPUT" -f null - 2> "$LOG_WARN"  || true

# --- 解析 ---
ERR_COUNT=$(grep -i "error" "$LOG_ERR" | wc -l)
CORRUPT_COUNT=$(grep -Ei "corrupt|timestamp|non[- ]monotone|invalid" "$LOG_WARN" | wc -l)

# --- ログ要約 ---
SUMMARY="File: $BASENAME
Error count: $ERR_COUNT
Corrupt count: $CORRUPT_COUNT"

# --- 判定と通知 ---
if (( ERR_COUNT > 5 )); then
    echo "AUDIO ERROR: $SUMMARY"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: 5" -d "AUDIO ERROR detected in $BASENAME ($ERR_COUNT errors)" "$NTFY_URL"
    fi
elif (( CORRUPT_COUNT > 5 )); then
    echo "CORRUPT: $SUMMARY"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: 4" -d "CORRUPT packets in $BASENAME ($CORRUPT_COUNT warnings)" "$NTFY_URL"
    fi
else
    echo "OK: $SUMMARY"
fi

# --- 後片付け ---
rm -f "$LOG_ERR" "$LOG_WARN"
