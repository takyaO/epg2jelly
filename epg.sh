#!/bin/bash

#番組名を引数として受取り、metadataを出力

BASE_URL="${EPGSTATION_URL:-http://localhost:8888/}"
URL="${BASE_URL}api/recorded?isHalfWidth=false&offset=0&limit=1000"
TARGET_NAME="$1"
curl -s -X 'GET' $URL | jq --arg filename "$TARGET_NAME" '
  .records[] | select(.videoFiles[0].filename == $filename)
'
