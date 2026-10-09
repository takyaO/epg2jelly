#!/bin/bash

# 番組名を引数として受取り、metadataを出力
BASE_URL="${EPGSTATION_URL:-http://localhost:8888}"
RECORDED_URL="${BASE_URL}/api/recorded?isHalfWidth=false&offset=0&limit=1000"
CHANNELS_URL="${BASE_URL}/api/channels"
TARGET_NAME="$1"

# 引数が空の場合は何もせず正常終了
if [ -z "$TARGET_NAME" ]; then
  exit 0
fi

# 1. APIからチャンネル情報のJSONを取得（失敗時は空配列 [] を代入）
CHANNELS_JSON=$(curl -sf -X 'GET' "$CHANNELS_URL" -H 'accept: application/json' 2>/dev/null)
if ! echo "$CHANNELS_JSON" | jq -e . >/dev/null 2>&1; then
  CHANNELS_JSON="[]"
fi

# 2. 録画情報を取得し、jq内でチャンネル情報と照合して置換する
curl -sf -X 'GET' "$RECORDED_URL" 2>/dev/null | \
jq -r --arg filename "$TARGET_NAME" --argjson channels "$CHANNELS_JSON" '
  # チャンネルマップ作成（channelsが配列でない場合や空の場合も安全に処理）
  (($channels | try map({key: (.id | tostring), value: .name}) | from_entries) catch {}) as $cmap
  
  # 本処理: .records が存在しない、null、エラーレスポンスの場合は何も出力しない
  | (.records? // [])[]? 
  | select(.videoFiles?[0]?.filename == $filename)
  | .channelId = ($cmap[.channelId | tostring] // .channelId)
' 2>/dev/null
