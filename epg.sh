#!/bin/bash

BASE_URL="${EPGSTATION_URL:-http://localhost:8888}"
RECORDED_URL="${BASE_URL}/api/recorded?isHalfWidth=false&offset=0&limit=1000"
CHANNELS_URL="${BASE_URL}/api/channels"

FILE_PATH="$1"
TARGET_NAME=$(basename "$FILE_PATH")

if [ -z "$TARGET_NAME" ]; then
  exit 0
fi

# ==========================================
# 1. EPGStation API から情報の取得を試みる
# ==========================================
CHANNELS_JSON=$(curl -sf -X 'GET' "$CHANNELS_URL" -H 'accept: application/json' 2>/dev/null)
if ! echo "$CHANNELS_JSON" | jq -e . >/dev/null 2>&1; then
  CHANNELS_JSON="[]"
fi

RESULT=$(curl -sf -X 'GET' "$RECORDED_URL" 2>/dev/null | \
jq --arg filename "$TARGET_NAME" --argjson channels "$CHANNELS_JSON" '
  # 準備: チャンネルIDをキー、放送局名を値とする辞書(オブジェクト)を作成
  ($channels | map({key: (.id | tostring), value: .name}) | from_entries) as $cmap

  # 本処理: 対象の番組を抽出し、channelIdを放送局名で上書きする
  | (.records? // [])[]?
  | select(.videoFiles[0].filename == $filename)
  | .channelId = ($cmap[.channelId | tostring] // .channelId)
' 2>/dev/null)

if [ -n "$RESULT" ] && [ "$RESULT" != "null" ]; then
  echo "$RESULT"
  exit 0
fi

# ==========================================
# 2. フォールバック: epgdump XML から抽出 (ジャンル判定改修)
# ==========================================
if command -v epgdump >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -f "$FILE_PATH" ]; then
  
  python3 - "$TARGET_NAME" "$FILE_PATH" 2>/dev/null << 'EOF'
import sys
import re
import subprocess
import xml.etree.ElementTree as ET
import json
from datetime import datetime

target_filename = sys.argv[1]
m2ts_file = sys.argv[2]

clean_target = re.sub(r'__.*', '', target_filename)
clean_target = re.sub(r'\[.*?\]|【.*?】|\.m2ts$|\.ts$', '', clean_target).strip()

cmd = ['epgdump', 'll', m2ts_file, '-']
try:
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    xml_data = result.stdout
except Exception:
    sys.exit(0)

try:
    root = ET.fromstring(xml_data)
except Exception:
    sys.exit(0)

channels = {}
for ch in root.findall('channel'):
    ch_id = ch.get('id')
    name_tag = ch.find("display-name[@lang='ja_JP']")
    if ch_id and name_tag is not None:
        channels[ch_id] = name_tag.text

genre_map = {
    "ニュース／報道": 0, "ニュース": 0, "報道": 0,
    "スポーツ": 1,
    "情報／ワイドショー": 2, "情報": 2, "ワイドショー": 2,
    "ドラマ": 3,
    "音楽": 4,
    "バラエティ": 5,
    "映画": 6,
    "アニメ／特撮": 7, "アニメ": 7, "特撮": 7,
    "ドキュメンタリー／教養": 8, "ドキュメンタリー": 8, "教養": 8, "紀行": 8,
    "劇場／公演": 9, "劇場": 9, "公演": 9,
    "趣味／教育": 10, "趣味": 10, "教育": 10,
    "福祉": 11,
    "予備": 12,
    "拡張": 14,
    "その他": 15
}

target_prog = None

for prog in root.findall('programme'):
    title_tag = prog.find("title[@lang='ja_JP']")
    if title_tag is None or not title_tag.text:
        continue
    
    prog_title_clean = re.sub(r'\[.*?\]|【.*?】', '', title_tag.text).strip()
    
    if prog_title_clean and clean_target:
        if (prog_title_clean in clean_target) or (clean_target in prog_title_clean):
            target_prog = prog
            break

if not target_prog:
    sys.exit(0)

title_tag = target_prog.find("title[@lang='ja_JP']")
desc_tag = target_prog.find("desc[@lang='ja_JP']")
cat_tag = target_prog.find("category[@lang='ja_JP']")
ch_id = target_prog.get('channel')
start_str = target_prog.get('start')

name_text = title_tag.text if title_tag is not None else ""
desc_text = desc_tag.text if desc_tag is not None else ""
cat_text = cat_tag.text if cat_tag is not None else ""

startAt_ms = 0
if start_str:
    try:
        dt_start = datetime.strptime(start_str, "%Y%m%d%H%M%S %z")
        startAt_ms = int(dt_start.timestamp() * 1000)
    except Exception:
        pass

# 【修正】ジャンルコード判定ロジックの改善
cat_str = cat_text.strip()
genre_val = 15

if cat_str.isdigit():
    # epgdump が直接数値 ("8" 等) を返している場合
    genre_val = int(cat_str)
elif cat_str:
    # 長いキーワード(完全名)から順にマッチングして誤誤爆を防ぐ
    genre_map_sorted = sorted(genre_map.items(), key=lambda x: len(x[0]), reverse=True)
    for k, v in genre_map_sorted:
        if k in cat_str:
            genre_val = v
            break

output = {
    "name": name_text,
    "description": desc_text,
    "startAt": startAt_ms,
    "channelId": channels.get(ch_id, ""),
    "genre1": genre_val
}

print(json.dumps(output, ensure_ascii=False, indent=2))
EOF

  if [ $? -eq 0 ]; then
    exit 0
  fi
fi

exit 0
