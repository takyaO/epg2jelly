#!/usr/bin/env bash
IFS=$'\n\t'

#ffmpeg のオプション
#FFMPEG_OPTS=(-c:v libx264 -crf 21 -preset slow -tune film -rc-lookahead 60 -aq-mode 3 -deblock -1:-1 -threads 10 )
#FFMPEG_OPTS=(-c:v libx264 -crf 21 -preset slow -threads 10)
FFMPEG_OPTS=(-c:v libx264 -crf 23 -preset fast )

# libfdk_aacの利用可否をチェック
if ffmpeg -encoders 2>/dev/null | grep -q "libfdk_aac"; then
    audio_codec="libfdk_aac"
else
    audio_codec="aac"
fi

# --- 環境変数のロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
else
  echo "環境設定ファイルが見つかりません: $ENV_FILE" >&2
  exit 1
fi

# --- デバッグ設定 ---
# VERBOSE=1 ./enc01.sh で詳細ログを出す
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  set -x
fi

# --- 関数群 ---
notify() {
    local LEVEL="$1"
    local MSG="$2"
    if [ -v NTFY_URL ]; then
        curl -H "X-Priority: $LEVEL" -d "$MSG" "$NTFY_URL" >/dev/null 2>&1 || true
    fi
}

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
	    notify 3 "ERROR: IOWAIT > ${THRESHOLD}%: $FILENAME" 
            exit 1
        fi
    done
}

hms_to_sec() {
    awk -F '[:.]' '{ printf "%.3f", ($1*3600)+($2*60)+$3+($4/1000) }' <<< "$1"
}

trim() {
    if [ "$#" -ne 2 ]; then
        echo "Error: trim expects 2 arguments: INPUT OUTPUT" >&2
        return 1
    fi
    local INPUT="$1"
    local OUTPUT="$2"
    local TRIMFILE="jls_out.txt"
    local CHAPFILE="chap_out.txt"    
    local FPS=29.97

    if [ ! -s "$CHAPFILE" ]; then
        echo "No chapter/trim info. Copying input to output..."
        ffmpeg -hide_banner -loglevel error -y \
            -i "$INPUT" -c copy -map 0 "$OUTPUT"
        return 0
    fi

    TEMPDIR=$(mktemp -d)
    PARTS_LIST="$TEMPDIR/parts.txt"
    INDEX=0
    > "$PARTS_LIST"

    # --- ストリーム判定 ---
    if ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$INPUT" | grep -q .; then
        HAS_SUBS=yes
        # 字幕ストリーム(1つ目)の言語タグを取得する
        SUB_LANG=$(ffprobe -v error -select_streams s:0 -show_entries stream_tags=language -of default=nw=1:nk=1 "$INPUT")
    else
        HAS_SUBS=no
        SUB_LANG=""
    fi

    # 音声ストリーム数
    AUDIO_COUNT=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$INPUT" | wc -l | tr -d ' ')

    STREAM_OPT=()
    CODEC_OPT=()

    if [[ "$HAS_SUBS" == "yes" || "$AUDIO_COUNT" -gt 1 ]]; then
        STREAM_OPT+=(-map 0 -copy_unknown)
    fi

    if [[ "$HAS_SUBS" == "yes" ]]; then
        CODEC_OPT+=(-c:s copy)
    fi

    if [[ "$AUDIO_COUNT" -gt 0 ]]; then
        for ((i=0; i<"$AUDIO_COUNT"; i++)); do
            CODEC_OPT+=(-c:a:"$i" "$audio_codec" -b:a:"$i" 192k)
        done
    fi

    # chap_out.txt から SCPos のみを抽出（昇順）
    mapfile -t SC_FRAMES < <(
	grep 'SCPos:' "$CHAPFILE" \
	    | grep -v '^[[:space:]]*#' \
	    | grep -o 'SCPos:[0-9]\+' \
	    | sed 's/SCPos://' \
	    | sort -n
    )
    
    CHAP_META="chapters.ffmeta"
    echo ";FFMETADATA1" > "$CHAP_META"
    OUT_OFFSET=0
    CHAP_INDEX=0
    LAST_START_MS=-1
    THRESHOLD_MS=20000   # 

    while read -r line; do
	while [[ "$line" =~ Trim\(([0-9]+),([0-9]+)\) ]]; do
            STARTF="${BASH_REMATCH[1]}"
            ENDF="${BASH_REMATCH[2]}"

            STARTSEC=$(bc_calc "$STARTF / $FPS")
            ENDSEC=$(bc_calc "$ENDF / $FPS")
            DURATION=$(bc_calc "$ENDSEC - $STARTSEC")

            # --- Trim開始チャプター ---
            OUTSEC="$OUT_OFFSET"
            START_MS=$(printf "%.0f" "$(bc_calc "$OUTSEC * 1000")")

            CHAP_INDEX=$((CHAP_INDEX+1))
            {
		echo "[CHAPTER]"
		echo "TIMEBASE=1/1000"
		echo "START=$START_MS"
		echo "title=Chapter $CHAP_INDEX"
            } >> "$CHAP_META"

            LAST_START_MS="$START_MS"

            # --- SCPos によるチャプター ---
            for SCF in "${SC_FRAMES[@]}"; do
		# Trim区間外は無視
		if (( SCF < STARTF || SCF >= ENDF )); then
                    continue
		fi

		OUTSEC=$(bc_calc "$OUT_OFFSET + ($SCF - $STARTF) / $FPS")
		START_MS=$(printf "%.0f" "$(bc_calc "$OUTSEC * 1000")")

		DIFF=$((START_MS - LAST_START_MS))
		[ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))

		# 近すぎるチャプターは抑止
		if [ "$DIFF" -le "$THRESHOLD_MS" ]; then
                    continue
		fi

		CHAP_INDEX=$((CHAP_INDEX+1))
		{
                    echo "[CHAPTER]"
                    echo "TIMEBASE=1/1000"
                    echo "START=$START_MS"
                    echo "title=Chapter $CHAP_INDEX"
		} >> "$CHAP_META"

		LAST_START_MS="$START_MS"
            done

            # --- 出力時間を進める ---
            OUT_OFFSET=$(bc_calc "$OUT_OFFSET + $DURATION")

            PART="$TEMPDIR/part_${INDEX}.mp4"
            watch_iowait

            if (( $(echo "$STARTSEC >= 5" | bc -l) )); then
                START_BEFORE=$(echo "$STARTSEC - 5" | bc -l | sed 's/^\./0./')
                ffmpeg -ss "$START_BEFORE" -i "$INPUT" -ss 5 -t "$DURATION" \
                       "${FFMPEG_OPTS[@]}" \
                       "${CODEC_OPT[@]}" "${STREAM_OPT[@]}" \
                       -map_metadata 0 \
                       -avoid_negative_ts make_zero \
                       "$PART"
            else
                ffmpeg -i "$INPUT" -ss "$STARTSEC" -t "$DURATION" \
                       "${FFMPEG_OPTS[@]}" \
                       "${CODEC_OPT[@]}" "${STREAM_OPT[@]}" \
                       -map_metadata 0 \
                       -avoid_negative_ts make_zero \
                       "$PART"
            fi

            echo "file '$PART'" >> "$PARTS_LIST"
            INDEX=$((INDEX+1))
	    
            line=${line#*"Trim("}
	done
    done < "$TRIMFILE"

    title=$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$INPUT")
    date=$(ffprobe -v error -show_entries format_tags=date -of default=nw=1:nk=1 "$INPUT")
    description=$(ffprobe -v error -show_entries format_tags=description -of default=nw=1:nk=1 "$INPUT")
    genre=$(ffprobe -v error -show_entries format_tags=genre -of default=nw=1:nk=1 "$INPUT")
    
    METADATA_OPT=()
    METADATA_OPT+=(-metadata title="$title")
    METADATA_OPT+=(-metadata date="$date")
    METADATA_OPT+=(-metadata description="$description")
    METADATA_OPT+=(-metadata genre="$genre")

    # 字幕があり、言語タグが取得できていれば設定（なければ jpn を強制しても良い）
    if [[ -n "$SUB_LANG" ]]; then
        METADATA_OPT+=(-metadata:s:s:0 language="$SUB_LANG")
    fi

    # 音声言語取得
    AUDIO_LANG=$(ffprobe -v error \
			 -select_streams a:0 \
			 -show_entries stream_tags=language \
			 -of default=nw=1:nk=1 "$INPUT")

    # フォールバック
    [[ -z "$AUDIO_LANG" ]] && AUDIO_LANG=jpn

    METADATA_OPT+=(-metadata:s:a:0 language="$AUDIO_LANG")
    METADATA_OPT+=(-disposition:a:0 default)
    
    ffmpeg -hide_banner -loglevel error -y \
           -f concat -safe 0 -i "$PARTS_LIST" \
	   -i "$CHAP_META" \
           -c copy -map 0 \
           -map_metadata -1 \
           "${METADATA_OPT[@]}" \
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

chapter() {
    if [ "$#" -ne 2 ]; then
        echo "Error: chapter expects 2 arguments: INPUT OUTPUT" >&2
        return 1
    fi

    local INPUT="$1"
    local OUTPUT="$2"
    local CHAPFILE="chap_out.txt"
    local FPS=29.97
    local CHAP_META="chapters.ffmeta"

    [[ ! -f "$INPUT" ]] && { echo "Input not found" >&2; return 1; }
    command -v chapter_exe >/dev/null || { echo "chapter_exe not found" >&2; return 1; }

    # ---- 1. Avisynthファイル作成と解析 ----
    local avs_file="join.avs"
    cat > "$avs_file" << EOF
TSFilePath="$INPUT"
LWLibavVideoSource(TSFilePath, repeat=true, dominance=1)
AudioDub(last,LWLibavAudioSource(TSFilePath, av_sync=true))
EOF

    timeout -k 60 1800 chapter_exe -v "$avs_file" -o "$CHAPFILE" || {
        echo "chapter_exe failed" >&2
        return 1
    }

    # ---- 2. 動画長とフレーム情報の取得 ----
    # DUR_MS を確実に取得
    DUR_MS=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | awk '{printf "%.0f", $1*1000}')
    MAX_FRAME=$(printf "%.0f" "$(echo "$DUR_MS / 1000 * $FPS" | bc -l)")

    # シーンチェンジフレームを取得してミリ秒に変換
    local -a TIME_POINTS=(0) # 0秒を初期値として追加
    local THRESHOLD_MS=3000 

    while read -r SCF; do
        (( SCF >= MAX_FRAME )) && continue
        
        # ミリ秒変換
        local MS=$(printf "%.0f" "$(echo "($SCF / $FPS) * 1000" | bc -l)")
        
        # 前のポイントとの間隔チェック
        local LAST_MS=${TIME_POINTS[-1]}
        if (( MS - LAST_MS > THRESHOLD_MS )); then
            TIME_POINTS+=("$MS")
        fi
    done < <(grep -Eo 'SCPos:[0-9]+' "$CHAPFILE" | sed 's/SCPos://' | sort -n)

    # 最後に動画の終端を追加
    TIME_POINTS+=("$DUR_MS")

    # ---- 3. FFMETADATA作成 ----
    echo ";FFMETADATA1" > "$CHAP_META"
    
    local NUM_CHAPS=$((${#TIME_POINTS[@]} - 1))
    
    if (( NUM_CHAPS <= 0 )); then
        echo "No valid chapter points found. Copying input..."
        ffmpeg -hide_banner -loglevel error -y -i "$INPUT" -map 0 -c copy "$OUTPUT"
        return 0
    fi

    for ((i=0; i<NUM_CHAPS; i++)); do
        local START=${TIME_POINTS[$i]}
        local END=${TIME_POINTS[$((i+1))]}
        {
            echo "[CHAPTER]"
            echo "TIMEBASE=1/1000"
            echo "START=$START"
            echo "END=$END"
            echo "title=Chapter $((i+1))"
        } >> "$CHAP_META"
    done

    # ---- 4. 動画への書き込み ----
    echo "Writing $NUM_CHAPS chapters..."

    # -map_metadata 0 は元のタグを引き継ぎ、-map_chapters 1 で上書きする構成
    ffmpeg -hide_banner -loglevel error -y \
        -i "$INPUT" \
        -i "$CHAP_META" \
        -map 0 \
        -map_metadata 0 \
        -map_chapters 1 \
        -c copy \
        "$OUTPUT"

    echo "Done: $OUTPUT"
    # 一時ファイルのクリーンアップ（必要に応じて）
    # rm "$avs_file" "$CHAPFILE" "$CHAP_META"
}

# --- メイン処理 ---
"$WORKDIR/toprocess.py" | while IFS= read -r FILE; do
    cd "$SOURCEDIR"
    if [ -f "$FILE" ]; then
	start_time=$(date +%s)
        FILENAME=${FILE%.*}
        GRSTRING=$(echo "$FILENAME" | sed -n 's/.*\(GR[0-9][0-9]\).*/\1/p')

        cd "$WORKDIR"
	if [ "${CHKDRP}" != "false"  ]; then
	    ./chkdrp.sh "$SOURCEDIR/$FILE" 
	fi
        ./epg.sh "$FILE" > epg.json
        ./enc.js "$SOURCEDIR/$FILE" epg.json  || {
            echo "enc.js failed" >&2
	    notify 4 "ERROR: enc.js failed: $FILENAME"
	}

        if [ -f "$FILENAME.mp4" ]; then
	    if [ -s "$FILENAME.mp4" ]; then	    
		if [ "${CMCUT}" != "false" ] && [ "$GRSTRING" != "$NHK1" ] && [ "$GRSTRING" != "$NHK2" ]; then
		    jls "$FILENAME.mp4" jls_out.txt
		    if [ $? -eq 0 ]; then
			trim "$FILENAME.mp4" temp$$.mp4
			if [ -s "temp$$.mp4" ]; then
			    rm "$FILENAME.mp4"
			    mv temp$$.mp4 "$FILENAME.mp4"
			else
			    echo "Error: trim failed" >&2
			    notify 3 "ERROR: trim failed: $FILENAME"
			fi
		    else
			echo "Error: jls failed" >&2
			notify 3 "ERROR: jls failed: $FILENAME"
		    fi
		    if [ -e "$FILENAME.mp4.lwi" ]; then
			rm "$FILENAME.mp4.lwi"
		    fi
		else
		    chapter "$FILENAME.mp4" temp$$.mp4
		    if [ $? -eq 0 ] && [ -s "temp$$.mp4" ] && [ "$(stat -c%s "temp$$.mp4")" -gt "$(stat -c%s "$FILENAME.mp4")" ]; then
			rm "$FILENAME.mp4"
			mv temp$$.mp4 "$FILENAME.mp4"
		    else
			if [ -e "temp$$.mp4" ]; then
			    rm -f "temp$$.mp4"
			fi
		    fi
		    if [ -e "$FILENAME.mp4.lwi" ]; then
			rm "$FILENAME.mp4.lwi"
		    fi
		fi
		./mvjf.sh "$FILENAME.mp4" "$OUTDIR"
		notify 2 "mp4 created: $FILENAME"
            else
		echo "ERROR: mp4 not created" >&2
		notify 4 "ERROR: mp4 not created: $FILENAME"
            fi
	fi	

        ./processed.py "$FILE" || true
	end_time=$(date +%s)
	duration=$((end_time - start_time))
	minutes=$((duration / 60))
	seconds=$((duration % 60))
	echo "RUN TIME; $minutes min $seconds sec"
    fi
done
