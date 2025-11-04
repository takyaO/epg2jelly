#!/usr/bin/env bash
IFS=$'\n\t'

#ffmpeg のオプション
FFMPEG_OPTS=(-c:v libx264 -crf 23 -preset fast -b:a 192k)

# オーディオコーデックを追加
if ffmpeg -encoders 2>/dev/null | grep -q "libfdk_aac"; then
    audio_codec="libfdk_aac"
else
    audio_codec="aac"
fi
FFMPEG_OPTS+=(-c:a "$audio_codec")

# --- 環境変数をロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
else
  echo "Not found: $ENV_FILE" >&2
  exit 1
fi

# --- デバッグ設定 ---
# VERBOSE=1 ./enc01.sh で詳細ログを出す
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  set -x
fi

# --- 関数群 ---
bc_calc() {
    echo "scale=6; $1" | bc -l | awk '{printf "%.6f", $0}'
}

watch_iowait() {
    MAX_WAIT=600
    THRESHOLD=10
    INTERVAL=5
    elapsed=0
    echo "Monitoring IOWAIT... (threshold=${THRESHOLD}%, max_wait=${MAX_WAIT}s)"
    while true; do
        read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
        sleep 1
        read cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 < /proc/stat
        total_diff=$(( (user2-user) + (nice2-nice) + (system2-system) + (idle2-idle) + (iowait2-iowait) + (irq2-irq) + (softirq2-softirq) + (steal2-steal) ))
        iowait_diff=$(( iowait2 - iowait ))
        if [ $total_diff -gt 0 ]; then
            IOWAIT=$(awk "BEGIN {printf \"%.1f\", ($iowait_diff*100)/$total_diff}")
        else
            IOWAIT=0
        fi

        echo "  elapsed=${elapsed}s, IOWAIT=${IOWAIT}%"

        if (( $(echo "$IOWAIT < $THRESHOLD" | bc -l) )); then
            echo "IOWAIT < ${THRESHOLD}%, resuming..."
            break
        fi

        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
        if (( elapsed >= MAX_WAIT )); then
            echo "IOWAIT did not drop below ${THRESHOLD}% after ${MAX_WAIT}s. Exiting."
	    if [ -v NTFY_URL ]; then
		curl -H "X-Priority: 3" -d "ERROR: IOWAIT > ${THRESHOLD}%: $FILENAME" "$NTFY_URL"
	    fi
            exit 1
        fi
    done
}

trim() {
    local INPUT="$1"
    local TRIMFILE="$2"
    local OUTPUT="$3"
    local FPS=29.97

    if [ ! -s "$TRIMFILE" ]; then
        echo "No trim info. Copying input to output..."
        ffmpeg -hide_banner -loglevel error -y -i "$INPUT" -c copy -map 0 "$OUTPUT"
        exit 0
    fi

    TEMPDIR=$(mktemp -d)
    PARTS_LIST="$TEMPDIR/parts.txt"
    INDEX=0
    > "$PARTS_LIST"

    if ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$INPUT" | grep -q .; then
        SUB_OPT=(-c:s copy -map 0)
    else
        SUB_OPT=()
    fi

    while read -r line; do
        while [[ "$line" =~ Trim\(([0-9]+),([0-9]+)\) ]]; do
            STARTF="${BASH_REMATCH[1]}"
            ENDF="${BASH_REMATCH[2]}"

            STARTSEC=$(bc_calc "$STARTF / $FPS")
            ENDSEC=$(bc_calc "$ENDF / $FPS")
            DURATION=$(bc_calc "$ENDSEC - $STARTSEC")

            PART="$TEMPDIR/part_${INDEX}.mp4"
            watch_iowait

            if (( $(echo "$STARTSEC >= 5" | bc -l) )); then
                START_BEFORE=$(echo "$STARTSEC - 5" | bc -l | sed 's/^\./0./')
                ffmpeg -ss "$START_BEFORE" -i "$INPUT" -ss 5 -t "$DURATION" "${FFMPEG_OPTS[@]}"  "${SUB_OPT[@]}" "$PART"
            else
                ffmpeg -i "$INPUT" -ss "$STARTSEC" -t "$DURATION" "${FFMPEG_OPTS[@]}" "${SUB_OPT[@]}" "$PART"
            fi

            echo "file '$PART'" >> "$PARTS_LIST"
            INDEX=$((INDEX+1))
            line=${line#*"Trim("}
        done
    done < "$TRIMFILE"

    TITLE=$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$INPUT")
    DATE=$(ffprobe -v error -show_entries format_tags=date -of default=nw=1:nk=1 "$INPUT")
    DESC=$(ffprobe -v error -show_entries format_tags=description -of default=nw=1:nk=1 "$INPUT")
    GENRE=$(ffprobe -v error -show_entries format_tags=genre -of default=nw=1:nk=1 "$INPUT")

    ffmpeg -hide_banner -loglevel error -y \
        -f concat -safe 0 -i "$PARTS_LIST" \
        -c copy -map 0 \
        -map_metadata -1 \
        -metadata title="$TITLE" \
        -metadata date="$DATE" \
        -metadata description="$DESC" \
        -metadata genre="$GENRE" \
        "$OUTPUT"

    rm -rf "$TEMPDIR"
    echo "Done: $OUTPUT"
}

jls() {
    local filename="$1"
    local output_file="$2"

    # 引数チェック
    if [[ -z "$filename" || -z "$output_file" ]]; then
        echo "Usage: jls FILENAME OUTPUT_FILE" >&2
        return 1
    fi

    # 入力ファイルの存在チェック
    if [[ ! -f "$filename" ]]; then
        echo "Error: Input file '$filename' not found" >&2
        return 1
    fi

    # 必要なコマンドの存在チェック
    local required_commands=("ffmpeg" "chapter_exe" "logoframe" "join_logo_scp")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Required command '$cmd' not found in PATH" >&2
            return 1
        fi
    done

    # 必要なファイルの存在チェック
    if [[ ! -f "JL_標準.txt" ]]; then
        echo "Error: Required file 'JL_標準.txt' not found in current directory" >&2
        return 1
    fi

    local avs_file="join.avs"
    
    # avsファイルの作成
    cat > "$avs_file" << EOF
TSFilePath="$filename"
LWLibavVideoSource(TSFilePath, repeat=true, dominance=1)
AudioDub(last,LWLibavAudioSource(TSFilePath, av_sync=true))
EOF

    # chapter_exeの実行（タイムアウト付き）
    timeout -k 60 1800 chapter_exe -v "$avs_file" -o chap_out.txt || {
        echo "chapter_exe failed or timed out" >&2
        return 1
    }

    # チャプターファイルの存在チェック
    if [[ ! -f "chap_out.txt" ]]; then
        echo "Error: Chapter output file 'chap_out.txt' was not created" >&2
        return 1
    fi

    # lgdファイルの存在チェック（条件付き）
    if [[ -n "$GRSTRING" && ! -f "$GRSTRING.lgd" ]]; then
        echo "Warning: $GRSTRING.lgd not found, but continuing..." >&2
        # エラーにしないで続行
    fi

    # logoframeの実行（lgdファイルが存在する場合のみ）
    if [[ -n "$GRSTRING" && -f "$GRSTRING.lgd" ]]; then
        logoframe "$avs_file" -logo "$GRSTRING.lgd" -oa lf_out.txt || {
            echo "logoframe failed" >&2
            return 1
        }
    else
        # lgdファイルがない場合は空のファイルを作成
        echo ""> lf_out.txt
    fi

    # ロゴファイルの存在チェック
    if [[ ! -f "lf_out.txt" ]]; then
        echo "Error: Logo frame output file 'lf_out.txt' was not created" >&2
        return 1
    fi

    # join_logo_scpの実行
    join_logo_scp -inlogo lf_out.txt -inscp chap_out.txt -incmd JL_標準.txt -o "$output_file" || {
        echo "join_logo_scp failed" >&2
        return 1
    }

    # 出力ファイルの存在チェック
    if [[ ! -f "$output_file" ]]; then
        echo "Error: Output file '$output_file' was not created" >&2
        return 1
    fi

    echo "Successfully created: $output_file"
}

# --- メイン処理 ---
"$WORKDIR/toprocess.py" | while IFS= read -r FILE; do
    cd "$SOURCEDIR"
    if [ -f "$FILE" ]; then
        FILENAME=${FILE%.*}
        GRSTRING=$(echo "$FILENAME" | sed -n 's/.*\(GR[0-9][0-9]\).*/\1/p')

        cd "$WORKDIR"
	if [ "${CHKDRP}" != "false"  ]; then
	    ./chkdrp.sh "$SOURCEDIR/$FILE" 
	fi
        ./epg.sh "$FILE" > epg.json
        ./enc.js "$SOURCEDIR/$FILE" epg.json  || {
            echo "enc.js failed" >&2
		if [ -v NTFY_URL ]; then
                    curl -H "X-Priority: 3" -d "ERROR: enc.js failed: $FILENAME" "$NTFY_URL"
		fi
		exit 1
	}

        if [ -f "$FILENAME.mp4" ] && [ "${CMCUT}" != "false" ] && [ "$GRSTRING" != "$NHK1" ] && [ "$GRSTRING" != "$NHK2" ]; then
            jls "$FILENAME.mp4" jls_out.txt
            trim "$FILENAME.mp4" jls_out.txt temp$$.mp4
            if [ -s temp$$.mp4 ]; then
                rm "$FILENAME.mp4"
                mv temp$$.mp4 "$FILENAME.mp4"
            else
                echo "Error: trim failed" >&2
		if [ -v NTFY_URL ]; then
                    curl -H "X-Priority: 3" -d "ERROR: trim failed: $FILENAME" "$NTFY_URL"
		fi
                ./mvjf.sh "$FILENAME.mp4" "$OUTDIR"
                rm "$FILENAME.mp4.lwi"
                ./processed.py "$FILE"
                exit 1
            fi
            rm "$FILENAME.mp4.lwi"
        fi

        if [ -s "$FILENAME.mp4" ]; then
            ./mvjf.sh "$FILENAME.mp4" "$OUTDIR"
	    if [ -v NTFY_URL ]; then
		curl -H "X-Priority: 2" -d "mp4 created: $FILENAME" "$NTFY_URL"
	    fi
        else
            echo "ERROR: mp4 not created" >&2
	    if [ -v NTFY_URL ]; then
		curl -H "X-Priority: 3" -d "ERROR: mp4 not created: $FILENAME" "$NTFY_URL"
	    fi
            exit 1
        fi

        ./processed.py "$FILE" || true
    fi
done
