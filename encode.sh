#!/bin/bash

# --- 環境変数のロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Error: env.sh not found at $ENV_FILE"
    exit 1
fi

# --- 設定変数 ---
SCRIPT="$WORKDIR/enc01.sh" # 実行スクリプト
LOCKFILE="/tmp/encode.lock"
TOPROCESS="$WORKDIR/toprocess.py"

STATS_FILE="${WORKDIR}/.encode_stats.dat"
INITIAL_MINGB=10 # mingb (1GBあたり何分かかるか)の初期値: 10GB/min
MIN_GBS=1.0    # 1GB未満は統計に反映しない
MIN_MINS=1.0    # 1分未満は統計に反映しない

DEFERRAL_FILE="$WORKDIR/$(basename "$0").deferrals"
MAX_DEFERRALS=10

# --- ロックファイルチェック ---
if [ -f "$LOCKFILE" ]; then
    echo "Script is already running. Exiting."
    exit 1
fi
touch "$LOCKFILE"

# 延期回数管理
deferral_count=$(cat "$DEFERRAL_FILE" 2>/dev/null || echo "0")
# 最大延期回数チェック
if [[ $deferral_count -ge $MAX_DEFERRALS ]]; then
    echo "WARNING: 最大延期回数($MAX_DEFERRALS)を超えました" >&2
    if [ -v NTFY_URL ]; then
	curl -H "X-Priority: 3" -d "WARNING: $WORKDIR/$(basename "$0")  最大延期回数($MAX_DEFERRALS)を超えました" "$NTFY_URL"
    fi
fi

# --- 未処理ファイルの合計サイズ計算関数 ---
calculate_total_size() {
    local total_bytes=0
    # ファイルのベースディレクトリを決定
    local base_dir=""
    if [ -n "$WATCHDIR" ]; then
        base_dir="$WATCHDIR"
    elif [ -n "$SOURCEDIR" ]; then
        base_dir="$SOURCEDIR"
    else
        echo "Error: Neither WATCHDIR nor SOURCEDIR is set in env.sh"
        return 1
    fi
    # 未処理ファイルのリストを取得し、各ファイルのサイズを計算
    while IFS= read -r filename; do
        file_path="$base_dir/$filename"
        if [ -f "$file_path" ]; then
            size=$(stat -c%s "$file_path") 
            total_bytes=$((total_bytes + size))
        else
            echo "Warning: File not found: $file_path"
        fi
    done < <("$TOPROCESS")
    # GB単位に変換
    local total_gb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / (1024*1024*1024)}")
    echo "$total_gb"
}

# --- メイン処理 ---
if [ -v WATCHDIR ]; then
    # ディレクトリ監視型
    "$SCRIPT"
else
    # 録画サーバー監視型
    # 現在Unix時刻
    timenow=$(date +'%s')

    # --- Ensure stats directory and file exist ---
    if [[ ! -f "$STATS_FILE" ]]; then
	echo "#run_id,gbs,mins,mingb" > "$STATS_FILE"  # ヘッダをつけて初期化
	echo "No previous stats found. Created new $STATS_FILE with initial mingb=$INITIAL_MINGB"
    fi
    # === Load previous mingb or initialize ===
    # 累積データから平均を計算
    total_gbs=$(awk -F, '{sum+=$2} END{print sum}' "$STATS_FILE")
    total_mins=$(awk -F, '{sum+=$3} END{print sum}' "$STATS_FILE")
    if (( $(echo "$total_gbs > 0" | bc -l) )); then
        prev_mingb=$(echo "scale=3; $total_mins / $total_gbs" | bc -l)
    else
        prev_mingb=$INITIAL_MINGB
    fi
    mingb=$prev_mingb
    
    # 未処理ファイルの合計サイズを計算
    gbs=$(calculate_total_size)
    # エンコードにかかる必要時間（分）: 有効２桁で計算
    mins_toencode=$(echo "scale=2; $gbs*$mingb*1.1" | bc) #1割の余裕をもたせておく
    # 録画中件数
    count=$(echo $(curl -s "${EPGSTATION_URL}api/recording?isHalfWidth=false") | rev | cut -c 2-2 | rev)
    if [ "$count" = "0" ]; then
	# 次の予約までの時間 (録画中は負)
	def=$(curl -s "${EPGSTATION_URL}api/reserves?type=normal&limit=1&isHalfWidth=false" | jq -c '.reserves[] | [.startAt]' | cut -c 2- | rev | cut -c 2- | rev)
	# min_toencode 分以上あるならエンコード実行
	if (( $(echo "scale=2; ($def/1000-$timenow)/60 > $mins_toencode" | bc -l) )); then    
	    start_time=$(date +%s)
	    "$SCRIPT"
	    end_time=$(date +%s)
	    duration=$((end_time - start_time))
	    mins=$((duration / 60))

	    # === Record current result ===
	    if (( $(echo "$gbs >= $MIN_GBS && $mins >= $MIN_MINS" | bc -l) )); then
		run_id=$(( $(wc -l < "$STATS_FILE" 2>/dev/null || echo 0) + 1 ))
		echo "$run_id,$gbs,$mins,$mingb" >> "$STATS_FILE"
	    fi

	    if [ -f "$DEFERRAL_FILE" ]; then
		rm  "$DEFERRAL_FILE"
	    fi
	else
	    # 時間が足りない場合: 延期処理
	    new_count=$((deferral_count + 1))
	    echo "$new_count" > "$DEFERRAL_FILE"
	    echo "WARNING: No enough time to encode until the next recording"
	    echo "処理延期 (連続回数: $new_count/$MAX_DEFERRALS)"
	fi
    fi
fi

# lockfile を削除
rm -f "$LOCKFILE"
