#!/usr/bin/env bash
IFS=$'\n\t'

#ユーザー定義のオプションを設定
#FFMPEG_OPTS=(-c:v h264_qsv -global_quality 22 -preset slow -tune film -rc-lookahead 60 -aq-mode 3 -deblock -1:-1 -threads 12)
#FFMPEG_OPTS_PRE=(-hwaccel qsv -hwaccel_output_format qsv ) #音声と映像がずれるので却下

# 未定義ならば
if [ ${#FFMPEG_OPTS[@]} -eq 0 ]; then
    # 利用可能なエンコーダ一覧を一時的に変数に格納
    AVAILABLE_ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)

    if echo "$AVAILABLE_ENCODERS" | grep -qw "h264_qsv"; then
        # 1. h264_qsv が使用可能な場合 (Intel)
        FFMPEG_OPTS=(-c:v h264_qsv -global_quality 23 -preset medium)
#        FFMPEG_OPTS=(-c:v h264_qsv -global_quality 21 -preset slow)

    elif echo "$AVAILABLE_ENCODERS" | grep -qw "h264_amf"; then
        # 2. h264_amf が使用可能な場合 (AMD)
        FFMPEG_OPTS=(-c:v h264_amf -rc cqp -qp 23 -quality balanced)
#        FFMPEG_OPTS=(-c:v h264_amf -rc cqp -qp 21 -quality slow)
    else
        # 3. どちらも不可な場合（CPUによるソフトウェアエンコード）
        FFMPEG_OPTS=(-c:v libx264 -crf 23 -preset medium)
#        FFMPEG_OPTS=(-c:v libx264 -crf 23 -preset slow)
    fi
fi

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

    # 音声ストリーム数の取得（メタデータ処理用）
    AUDIO_COUNT=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$INPUT" | wc -l | tr -d ' ')
    CODEC_OPT=()
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
    THRESHOLD_MS=20000

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
                if (( SCF < STARTF || SCF >= ENDF )); then
                    continue
                fi

                OUTSEC=$(bc_calc "$OUT_OFFSET + ($SCF - $STARTF) / $FPS")
                START_MS=$(printf "%.0f" "$(bc_calc "$OUTSEC * 1000")")

                DIFF=$((START_MS - LAST_START_MS))
                [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))

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

            OUT_OFFSET=$(bc_calc "$OUT_OFFSET + $DURATION")

            PART="$TEMPDIR/part_${INDEX}.mp4"
            watch_iowait

            nice -n 19 ionice -c 3 ffmpeg "${FFMPEG_OPTS_PRE[@]}" \
		 -ss "$STARTSEC" -i "$INPUT" -t "$DURATION" \
		 -map 0:v -map 0:a \
		 "${FFMPEG_OPTS[@]}" \
		 "${CODEC_OPT[@]}" \
		 "$PART"
	
            echo "file '$PART'" >> "$PARTS_LIST"
            INDEX=$((INDEX+1))
        
            line=${line#*"Trim("}
        done
    done < "$TRIMFILE"

    # --- メタデータの取得・設定 ---
    title=$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$INPUT")
    date=$(ffprobe -v error -show_entries format_tags=date -of default=nw=1:nk=1 "$INPUT")
    description=$(ffprobe -v error -show_entries format_tags=description -of default=nw=1:nk=1 "$INPUT")
    genre=$(ffprobe -v error -show_entries format_tags=genre -of default=nw=1:nk=1 "$INPUT")
    network=$(ffprobe -v error -show_entries format_tags=network -of default=nw=1:nk=1 "$INPUT")
    
    METADATA_OPT=()
    METADATA_OPT+=(-metadata title="$title")
    METADATA_OPT+=(-metadata date="$date")
    METADATA_OPT+=(-metadata description="$description")
    METADATA_OPT+=(-metadata genre="$genre")
    METADATA_OPT+=(-metadata network="$network")

    # 全音声ストリームのメタデータを取得・設定
    for ((i=0; i<AUDIO_COUNT; i++)); do
        AUDIO_LANG=$(ffprobe -v error -select_streams a:$i -show_entries stream_tags=language -of default=nw=1:nk=1 "$INPUT")
        [[ -z "$AUDIO_LANG" ]] && AUDIO_LANG=jpn
        METADATA_OPT+=(-metadata:s:a:$i language="$AUDIO_LANG")
        
        AUDIO_TITLE=$(ffprobe -v error -select_streams a:$i -show_entries stream_tags=title -of default=nw=1:nk=1 "$INPUT")
        if [[ -n "$AUDIO_TITLE" ]]; then
            METADATA_OPT+=(-metadata:s:a:$i title="$AUDIO_TITLE")
        fi
        
        if [[ $i -eq 0 ]]; then
            METADATA_OPT+=(-disposition:a:$i default)
        else
            METADATA_OPT+=(-disposition:a:$i 0)
        fi
    done
    
    # 字幕を含めず、映像と音声を結合
    ffmpeg -hide_banner -loglevel error -y \
        -f concat -safe 0 -i "$PARTS_LIST" \
        -i "$CHAP_META" \
        -map 0:v -map 0:a \
        -c copy \
        -map_metadata -1 \
        "${METADATA_OPT[@]}" \
        "$OUTPUT"

    rm -rf "$TEMPDIR"
    echo "Done: $OUTPUT"
}

extract_ass_sub() {
    if [ "$#" -ne 2 ]; then
        echo "Error: extract_ass_sub expects 2 arguments: INPUT_MP4 OUTPUT_ASS" >&2
        return 1
    fi
    local INPUT="$1"
    local OUTPUT_ASS="$2"
    local TRIMFILE="jls_out.txt"

    # 字幕ストリームが存在するかチェック
    if ! ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$INPUT" | grep -q .; then
        echo "字幕ストリームが存在しないため、ASSの抽出をスキップします。"
        return 0
    fi

    echo "字幕を検出し、Trim情報に基づきASS（カラー保持）を生成します..."
    local TEMPDIR=$(mktemp -d)
    local RAW_ASS="$TEMPDIR/raw_all.ass"

    # 色情報を完全保持するASSとして丸ごと抽出
    ffmpeg -hide_banner -loglevel error -y -i "$INPUT" -map 0:s:0 "$RAW_ASS"

    # Python3を使って、Trim情報を元にASSのタイムスタンプを再計算
    python3 - "$RAW_ASS" "$TRIMFILE" "$OUTPUT_ASS" << 'EOF'
import sys
import re

raw_ass_path = sys.argv[1]
trim_path = sys.argv[2]
out_ass_path = sys.argv[3]
fps = 29.97

# 1. Trim情報を読み込んで時間（秒）に変換
trims = []
try:
    with open(trim_path, 'r', encoding='utf-8') as f:
        content = f.read()
        matches = re.findall(r'Trim\((\d+),\s*(\d+)\)', content)
        for m in matches:
            start_f, end_f = int(m[0]), int(m[1])
            trims.append({
                'start': start_f / fps,
                'end': end_f / fps,
                'duration': (end_f - start_f) / fps
            })
except FileNotFoundError:
    print(f"Error: Trim file {trim_path} not found.")
    sys.exit(1)

def parse_time(t_str):
    # ASSの時間は H:MM:SS.cs (センチ秒)
    h, m, s = t_str.strip().split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)

def format_time(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    # ASSのフォーマット要件 (0:00:00.00) に合わせる
    return f"{h}:{m:02d}:{s:05.2f}"

out_lines = []

# 2. ASSを1行ずつ読み込んで処理（ASSは1セリフ1行なので処理がシンプル）
try:
    with open(raw_ass_path, 'r', encoding='utf-8') as f:
        for line in f:
            if line.startswith('Dialogue:'):
                # Format: Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                parts = line.split(',', 9)
                if len(parts) >= 10:
                    start_t = parse_time(parts[1])
                    end_t = parse_time(parts[2])
                    
                    mapped_start = None
                    mapped_end = None
                    accumulated_offset = 0
                    
                    for trim in trims:
                        if end_t <= trim['start']:
                            pass
                        elif start_t >= trim['end']:
                            accumulated_offset += trim['duration']
                        else:
                            eff_start = max(start_t, trim['start'])
                            eff_end = min(end_t, trim['end'])
                            if eff_end > eff_start:
                                mapped_start = accumulated_offset + (eff_start - trim['start'])
                                mapped_end = accumulated_offset + (eff_end - trim['start'])
                            break
                            
                    # 該当区間ならタイムスタンプを書き換えて保存
                    if mapped_start is not None and mapped_end is not None:
                        parts[1] = format_time(mapped_start)
                        parts[2] = format_time(mapped_end)
                        out_lines.append(','.join(parts))
            else:
                # [V4+ Styles] セクションの Format 行と Style 行をターゲットにする
                if line.startswith('Style:'):
                    # ASSのStyle行のカンマ区切りパラメータを分解
                    # Format: Name, Fontname, Fontsize, PrimaryColour, ...
                    style_parts = line.split(',')
                    if len(style_parts) > 3:
                        # 1. フォント名をブラウザやOSを問わない汎用フォントに強制変更
                        style_parts[1] = 'sans-serif'
                        # 2. デフォルトのフォントサイズを適正サイズに調整
                        style_parts[2] = '18' 
                        
                        line = ','.join(style_parts)
                
                # ダイアログ（セリフ）行以外のヘッダーは、上記の置換を経てそのままコピー
                out_lines.append(line)
except FileNotFoundError:
    print(f"Error: Raw ASS {raw_ass_path} not found.")
    sys.exit(1)

# 3. 新しいASSを保存
with open(out_ass_path, 'w', encoding='utf-8') as f:
    f.writelines(out_lines)

EOF

    rm -rf "$TEMPDIR"
    echo "字幕のASS出力が完了しました: $OUTPUT_ASS"
}

extract_vtt_sub() {
    if [ "$#" -ne 2 ]; then
        echo "Error: extract_vtt_sub expects 2 arguments: INPUT_MP4 OUTPUT_VTT" >&2
        return 1
    fi
    local INPUT="$1"
    local OUTPUT_VTT="$2"
    local TRIMFILE="jls_out.txt"

    # 字幕ストリームが存在するかチェック
    if ! ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$INPUT" | grep -q .; then
        echo "字幕ストリームが存在しないため、VTTの抽出をスキップします。"
        return 0
    fi

    echo "字幕ストリームを検出し、Trim情報に基づきVTTを生成します..."
    local TEMPDIR=$(mktemp -d)
    local RAW_VTT="$TEMPDIR/raw_all.vtt"

    # CMカット前の元動画から、すべての字幕を一旦VTTとして丸ごと抽出
    ffmpeg -hide_banner -loglevel error -y -i "$INPUT" -map 0:s:0 "$RAW_VTT"

    # Python3を使って、Trim情報を元にVTTのタイムスタンプを再計算
    python3 - "$RAW_VTT" "$TRIMFILE" "$OUTPUT_VTT" << 'EOF'
import sys
import re

raw_vtt_path = sys.argv[1]
trim_path = sys.argv[2]
out_vtt_path = sys.argv[3]
fps = 29.97

# 1. Trim情報を読み込んで時間（秒）に変換
trims = []
try:
    with open(trim_path, 'r', encoding='utf-8') as f:
        content = f.read()
        matches = re.findall(r'Trim\((\d+),\s*(\d+)\)', content)
        for m in matches:
            start_f, end_f = int(m[0]), int(m[1])
            trims.append({
                'start': start_f / fps,
                'end': end_f / fps,
                'duration': (end_f - start_f) / fps
            })
except FileNotFoundError:
    print(f"Error: Trim file {trim_path} not found.")
    sys.exit(1)

def parse_time(t_str):
    parts = t_str.strip().split(':')
    sec_milli = parts[-1].split('.')
    s = float(sec_milli[0]) + (float(sec_milli[1]) / 1000.0 if len(sec_milli) > 1 else 0)
    m = int(parts[-2])
    h = int(parts[-3]) if len(parts) > 2 else 0
    return h * 3600 + m * 60 + s

def format_time(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"

# 2. VTTを読み込んで解析・処理
try:
    with open(raw_vtt_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except FileNotFoundError:
    print(f"Error: Raw VTT {raw_vtt_path} not found.")
    sys.exit(1)

out_lines = []
i = 0

# 最初のタイムスタンプ(-->)が出現するまでの行（STYLEタグやメタデータ）をすべて保持
while i < len(lines) and '-->' not in lines[i]:
    out_lines.append(lines[i])
    i += 1

# --- タイムスタンプ行以降の処理 ---
while i < len(lines):
    line = lines[i]
    if '-->' in line:
        times = line.split('-->')
        start_t = parse_time(times[0])
        end_t = parse_time(times[1])
        
        # テキストブロック（インラインタグ含む）を読み取る
        text_lines = []
        i += 1
        while i < len(lines) and lines[i].strip() != '' and '-->' not in lines[i]:
            text_lines.append(lines[i])
            i += 1
            
        # どのTrim区間に入るかを計算
        mapped_start = None
        mapped_end = None
        accumulated_offset = 0
        
        for trim in trims:
            if end_t <= trim['start']:
                pass
            elif start_t >= trim['end']:
                accumulated_offset += trim['duration']
            else:
                eff_start = max(start_t, trim['start'])
                eff_end = min(end_t, trim['end'])
                
                if eff_end > eff_start:
                    mapped_start = accumulated_offset + (eff_start - trim['start'])
                    mapped_end = accumulated_offset + (eff_end - trim['start'])
                break
                
        # 該当区間なら書き出し
        if mapped_start is not None and mapped_end is not None:
            out_lines.append(f"{format_time(mapped_start)} --> {format_time(mapped_end)}\n")
            out_lines.extend(text_lines)
            out_lines.append("\n")
    else:
        # 空行などのスキップ
        i += 1

# 3. 新しいVTTを保存
with open(out_vtt_path, 'w', encoding='utf-8') as f:
    f.writelines(out_lines)

EOF

    rm -rf "$TEMPDIR"
    echo "字幕のVTT出力が完了しました: $OUTPUT_VTT"
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
    command -v chapter_exe >/dev/null || { echo "chapter_exe not found. See https://note.com/leal_walrus5520/n/n7181f4b46d5f" >&2; return 1; }

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
    local THRESHOLD_MS=20000 

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

        # タイトルは既存のdstを維持
        grep '<title>' "$dst"

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
			    if ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$FILENAME.mp4" | grep -q .; then
				echo "字幕ストリームを検出しました。VTTファイルを生成します。"
			    
				extract_vtt_sub "$FILENAME.mp4" "temp$$.vtt"
				extract_ass_sub "$FILENAME.mp4" "temp$$.ass"

				rm "$FILENAME.mp4"
				mv temp$$.mp4 "$FILENAME.mp4"

				mv "temp$$.vtt" "${FILENAME%.mp4}.ja.vtt"
				mv "temp$$.ass" "${FILENAME%.mp4}.ja.ass"
			    else
				echo "字幕ストリームはありません。動画の置き換えのみ実行します。"

				rm "$FILENAME.mp4"
				mv "temp$$.mp4" "$FILENAME.mp4"
			    fi			    
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

		if ! grep -q "映画" tvshow.nfo; then
                    folder=$(./mvjf.sh -n "$FILENAME.mp4" | sed -n 's/^Using folder name: //p') #mvjf.sh のDRY_RUN=trueの出力を使用
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
                    echo "WARNING: tvshow.nfo not moved as it contains 映画"
                fi
		
		./mvjf.sh "$FILENAME.mp4" "$OUTDIR"
		if [ -f "$FILENAME.ja.vtt" ]; then
		    ./mvjf.sh "$FILENAME.ja.vtt" "$OUTDIR"
		fi		    
		if [ -f "$FILENAME.ja.ass" ]; then
		    ./mvjf.sh "$FILENAME.ja.ass" "$OUTDIR"
		fi		    
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
