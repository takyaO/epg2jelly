#!/bin/bash

# 番組名を引数として受取り、metadataを出力
BASE_URL="${EPGSTATION_URL:-http://localhost:8888}"
RECORDED_URL="${BASE_URL}/api/recorded?isHalfWidth=false&offset=0&limit=1000"
CHANNELS_URL="${BASE_URL}/api/channels"
TARGET_NAME="$1"

# 1. APIからチャンネル情報のJSONを取得し、変数に格納する
CHANNELS_JSON=$(curl -s -X 'GET' "$CHANNELS_URL" -H 'accept: application/json')

# 2. 録画情報を取得し、jq内でチャンネル情報と照合して置換する
curl -s -X 'GET' "$RECORDED_URL" | \
jq --arg filename "$TARGET_NAME" --argjson channels "$CHANNELS_JSON" '
  # 準備: チャンネルIDをキー、放送局名を値とする辞書(オブジェクト)を作成
  # 例: {"3273601024": "ＮＨＫ総合１・東京", ...}
  ($channels | map({key: (.id | tostring), value: .name}) | from_entries) as $cmap
  
  # 本処理: 対象の番組を抽出し、channelIdを放送局名で上書きする
  | .records[] 
  | select(.videoFiles[0].filename == $filename)
  | .channelId = $cmap[.channelId | tostring]
'
