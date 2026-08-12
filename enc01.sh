#!/usr/bin/env bash
IFS=$'\n\t'

# --- 環境変数のロード ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env.sh"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
else
  echo "Env file not found: $ENV_FILE" >&2
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

jls() {
    local filename="$1"
    local output_chap_file="$2"
    local output_file="$3"

    # 引数チェック
    if [[ -z "$filename" || -z "$output_file" || -z "$output_chap_file" ]]; then
        echo "Usage: jls FILENAME OUTPUT_FILE OUTPUT_CHAP_FILE" >&2
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
            echo "Error: Required command '$cmd' not found in PATH. See https://note.com/leal_walrus5520/n/n7181f4b46d5f" >&2
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
    timeout -k 60 1800 chapter_exe -v "$avs_file" -o "$output_chap_file" || {
        echo "ERROR: chapter_exe failed or timed out" >&2
        return 1
    }

    # チャプターファイルの存在チェック
    if [[ ! -f "$output_chap_file" ]]; then
        echo "Error: Chapter output file $output_chap_file was not created" >&2
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
            echo "ERROR: logoframe failed" >&2
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
    join_logo_scp -inlogo lf_out.txt -inscp "$output_chap_file" -incmd JL_標準.txt -o "$output_file" || {
        echo "Error: join_logo_scp failed" >&2
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

    [[ ! -f "$INPUT" ]] && { echo "Error: Input not found" >&2; return 1; }
    command -v chapter_exe >/dev/null || { echo "Error: chapter_exe not found. See https://note.com/leal_walrus5520/n/n7181f4b46d5f" >&2; return 1; }

    local avs_file="join.avs"
    cat > "$avs_file" << EOF
TSFilePath="$INPUT"
LWLibavVideoSource(TSFilePath, repeat=true, dominance=1)
AudioDub(last,LWLibavAudioSource(TSFilePath, av_sync=true))
EOF

    timeout -k 60 1800 chapter_exe -v "$avs_file" -o "$OUTPUT" || {
        echo "Error: chapter_exe failed" >&2
        return 1
    }

}

make_tvshow_nfo() {
    local folder="$1"
    local file="$2"

    local genres network
    # genreの取得
    genres=$(
        ffprobe -v quiet \
            -show_entries format_tags=genre \
            -of default=noprint_wrappers=1:nokey=1 \
            "$file" |
        sed 's/ \/ /\n/g'
    )
    # network（放送局）の取得を追加
    network=$(
        ffprobe -v quiet \
            -show_entries format_tags=network \
            -of default=noprint_wrappers=1:nokey=1 \
            "$file"
    )

    # genre と network のどちらも空なら処理をスキップ
    [ -z "$genres" ] && [ -z "$network" ] && return

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<tvshow>'
        echo "  <title>${folder}</title>"

        # network が存在すれば出力
        if [ -n "$network" ]; then
            echo "  <studio>${network}</studio>"
        fi

        # genre を一行ずつ出力
        if [ -n "$genres" ]; then
            while IFS= read -r genre; do
                echo "  <genre>${genre}</genre>"
            done <<< "$genres"
        fi

        echo '</tvshow>'
    } > tvshow.nfo
}

merge_tvshow_nfo() {
    local src="$1"
    local dst="$2"

    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        return
    fi

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<tvshow>'

        # タイトルは上書き
        grep '<title>' "$src"

        # networkをマージ（重複排除）
        {
            grep '<studio>' "$dst"
            grep '<studio>' "$src"
        } |
        sort -u

        # genreをマージ（重複排除）
        {
            grep '<genre>' "$dst"
            grep '<genre>' "$src"
        } |
        sort -u

        echo '</tvshow>'
    } > "${dst}.tmp"

    mv "${dst}.tmp" "$dst"
}

ass2vtt() {
  local input_file="$1"
  local output_file="$2"

  # 引数のチェック
  if [ -z "$input_file" ] || [ -z "$output_file" ]; then
    echo "Usage: ass2vtt <input.ja.ass> <output.ja.vtt>"
    return 1
  fi

  # 入力ファイルの存在確認
  if [ ! -f "$input_file" ]; then
    echo "Error: Input file '$input_file' not found "
    return 1
  fi

  # ffmpegの存在確認と実行
  if command -v ffmpeg >/dev/null 2>&1; then
    # 余計なログを出さずに変換 (既にファイルがある場合は上書き)
    ffmpeg -i "$input_file" "$output_file" -y -hide_banner -loglevel error
    if [ $? -eq 0 ]; then
      echo "Successfully made: $output_file"
    else
      echo "Error: Failed to convert ass2vtt"
      return 1
    fi
  else
    echo "Error: ffmpeg not available"
    return 1
  fi
}

# --- メイン処理 ---
"$WORKDIR/toprocess.py" | while IFS= read -r FILE; do
    cd "$SOURCEDIR"
    if [ -f "$FILE" ]; then
	start_time=$(date +%s)
        FILENAME=${FILE%.*}
        GRSTRING=$(echo "$FILENAME" | sed -n 's/.*\(GR[0-9][0-9]\).*/\1/p')

        cd "$WORKDIR"
	chkdrp_status=0
	if [ "${CHKDRP}" != "false"  ]; then
            ./chkdrp.sh "$SOURCEDIR/$FILE"
            chkdrp_status=$?
	fi
	./epg.sh "$FILE" > epg.json
    
	# Trim(CMカット)の対象番組かどうかの判定
	if [ "${CMCUT}" != "false" ] && [ "$GRSTRING" != "$NHK1" ] && [ "$GRSTRING" != "$NHK2" ]; then
        
            TARGET_TS="$SOURCEDIR/$FILE"
            CLEANED_TS=""
        
            # エラーが検出された場合
            if [ $chkdrp_status -ne 0 ]; then
		echo "Critical errors detected. Running tsreadex to clean streams..."
		CLEANED_TS="${FILE}"
            
		#-x 18/38/39: EITなどのテーブルを除外, -n -1: 全サービスを保持
		tsreadex -x 18/38/39 -n -1 -a 13 -b 5 -c 1 -u 1 -d 13 "$TARGET_TS" > "$CLEANED_TS"
		
		if [ $? -eq 0 ] && [ -s "$CLEANED_TS" ]; then
                    TARGET_TS="$CLEANED_TS"
                    echo "tsreadex completed. Using cleaned TS for Trim processing."
		else
                    echo "Warning: tsreadex failed or output empty. Falling back to original TS."
                    notify 4 "Error: tsreadex failed: $FILENAME"
                    rm -f "$CLEANED_TS"
                    CLEANED_TS=""
		fi
            fi

            echo "Start trim processing $(basename "$TARGET_TS")"
            jls "$TARGET_TS" chap_out.txt jls_out.txt
            if [ $? -eq 0 ]; then
		# 3.9GB を KB 単位に換算 (3.9 * 1024 * 1024 = 4089446); 暴走防止策
		ulimit -v 4089446                
		./enc.js "$TARGET_TS" epg.json chap_out.txt jls_out.txt || {
                    echo "Error: enc.js failed in trim mode" >&2
                    notify 4 "Error: enc.js failed in trim mode: $FILENAME"
		}
            else
		notify 4 "Error: jls failed: $FILENAME"
            fi
        
            # 処理が終わったら tsreadex で生成した一時ファイルをクリーンアップ
            if [ -n "$CLEANED_TS" ] && [ -f "$CLEANED_TS" ]; then
		rm -f "$CLEANED_TS"
            fi
	    
	    # Trim対象外 (NHKなど)
	else
            echo "Start processing $FILE "
            chapter "$SOURCEDIR/$FILE" chap_out.txt
            if [ $? -eq 0 ]; then 
		./enc.js "$SOURCEDIR/$FILE" epg.json chap_out.txt|| {
                    echo "Error: enc.js failed with chap_out.txt" >&2
                    notify 4 "Error: enc.js failed with chap_out.txt: $FILENAME"
		}
            else
		notify 3 "Error: chapter failed: $FILENAME"
		./enc.js "$SOURCEDIR/$FILE" epg.json || {
                    echo "Error: enc.js failed" >&2
                    notify 4 "Error: enc.js failed: $FILENAME"
		}
            fi
	fi

	if [ -e "$SOURCEDIR/$FILE.lwi" ]; then
		rm "$SOURCEDIR/$FILE.lwi"
	fi
	if [ -e "$FILE.lwi" ]; then
		rm "$FILE.lwi"
	fi

	if ! grep -q "映画" tvshow.nfo; then
            folder=$(./mvjf.sh -n "$FILENAME.mp4" | sed -n 's/^Using folder name: //p') #mvjf.sh のDRY_RUN=trueの出力を使用
	    if [ -s "$FILENAME.mp4" ]; then	    
		make_tvshow_nfo "$folder" "$FILENAME.mp4"

		# 1. コピー先のディレクトリパスを定義
		dst_dir="$OUTDIR/$folder"
		dst="$dst_dir/tvshow.nfo"

		# 2. ディレクトリが存在しない場合は作成
		if [ ! -d "$dst_dir" ]; then
                    mkdir -p "$dst_dir"
		fi

		# 3. 既存のファイルをチェックしてマージまたはコピー
		if [ -f "$dst" ]; then
                    merge_tvshow_nfo tvshow.nfo "$dst"
		else
                    cp tvshow.nfo "$dst"
		fi
	    else
		echo "WARNING: tvshow.nfo not created for $FILENAME.mp4"		
	    fi
        else
            echo "WARNING: tvshow.nfo not moved as it contains 映画"
        fi

	if [ -s "$FILENAME.mp4" ]; then	    
	    ./mvjf.sh "$FILENAME.mp4" "$OUTDIR"
	    notify 2 "mp4 created: $FILENAME"
	    if [ -f "$FILENAME.ja.ass" ]; then
		ass2vtt "$FILENAME.ja.ass" "$FILENAME.ja.vtt"
		./mvjf.sh "$FILENAME.ja.ass" "$OUTDIR"
		./mvjf.sh "$FILENAME.ja.vtt" "$OUTDIR"
	    fi		    
	else
	    echo "Error: mp4 not created" >&2
	    notify 4 "Error: mp4 not created: $FILENAME"
	fi

        ./processed.py "$FILE" || true
	end_time=$(date +%s)
	duration=$((end_time - start_time))
	minutes=$((duration / 60))
	seconds=$((duration % 60))
	echo "RUN TIME; $minutes min $seconds sec"
    fi
done
# https://note.com/leal_walrus5520/n/n98e738cae3b4
# https://note.com/leal_walrus5520/n/n8ae31f665314
# Time stamp: 2026/08/12
