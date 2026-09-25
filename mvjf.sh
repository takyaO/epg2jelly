#!/bin/bash
DRY_RUN=false
while getopts ":n" opt; do
    case ${opt} in
        n )
            DRY_RUN=true
            ;;
        \? )
            echo "Invalid option: -$OPTARG"
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

# 移動対象ファイル名と出力先ディレクトリを受け取る
input_file="$1"
outdir="$2"

# ドライランモードならチェックしない
if [ "$DRY_RUN" = "false" ]; then
    # 引数のチェック
    if [ "$#" -ne 2 ]; then
        echo "Usage: $0 [-n] <input_file> <output_directory>"
        exit 1
    fi
    # ファイルが存在するか
    if [ ! -f "$input_file" ]; then
        echo "File not found: $input_file"
        exit 1
    fi
    # 出力ディレクトリが存在するか
    if [ ! -d "$outdir" ]; then
        echo "Output directory not found: $outdir"
        exit 1
    fi
fi

# 優先する番組名リストを記したファイルのパス
LIST_FILE="mvjf.list"

# --------------------------------------------------
# 番組名リストとの照合・自動登録から除外する一般語リスト
# --------------------------------------------------
GENERIC_WORDS=("ニュース" "気象情報" "天気予報")

# 一般語判定関数
is_generic_word() {
    local target="$1"
    local word
    for word in "${GENERIC_WORDS[@]}"; do
        if [ "$target" = "$word" ]; then
            return 0
        fi
    done
    return 1
}

# リストファイルが存在しない場合は作成
if [ ! -f "$LIST_FILE" ]; then
    echo "#番組フォルダ名として優先される番組名のリスト。Program names to be used as folder names" > "$LIST_FILE"
fi

is_ignored_list_entry() {
    local line="$1"
    [[ -z "$line" ]] && return 0
    [[ "$line" =~ ^[[:space:]]*$ ]] && return 0
    [[ "$line" =~ ^[[:space:]]*# ]] && return 0
    return 1
}

extractProgram() {
    # 引数受け取り
    local input_file="$1"
    # 関数内部で使う変数をlocal宣言
    local FILENAME PROGRAM EPISODE ORIGINAL rest temp delimiter found_delimiter second_delimiter pos
    local -a delimiter_order MATCH_LIST
    local -A delimiter_pairs

    # 区切り文字の優先順位リスト
    delimiter_order=("＃" "♯" "#" "第" "EP" "Ep" "ep" "最終回" "最終話" "最終首" "(" "（" "話"  "★" "☆" "▼" "◆"  "▽" "【" "「" "『"　" " " " "_" "[")

    # 区切り文字と対応するセカンドデリミタを定義
    delimiter_pairs=(
        ["話"]=" "
        ["＃"]="_"
        ["♯"]="_"
        ["#"]="_"
        ["第"]="_"
        ["EP"]="_"
        ["Ep"]="_"
        ["ep"]="_"
        ["最終回"]="_"
        ["最終話"]="_"
        ["最終首"]="_"
        ["("]=")"
        ["（"]="）"
        ["★"]="_"
        ["☆"]="_"
        ["▼"]="_"
        ["▽"]="_"
        ["◆"]="_"
        [" "]="_"
        ["　"]="_"
        ["【"]="】"
        ["「"]="」"
        ["『"]="』"
        ["["]="."
        ["_"]="."
    )

    # 先頭文字列削除
    FILENAME=$(printf '%s' "$input_file" | \
        sed -e 's/[\/:*?"<>|]//g'  | \
        sed -e 's/^【[^】]*】//' \
            -e 's/^\[[^]]*\]//' -e 's/^\[[^]]*\]//' \
            -e 's/^火アニバル[[:space:]]*//' \
            -e 's/^プチプチ・アニメ[[:space:]]*//' \
            -e 's/^アニメ[[:space:]]*//' \
            -e 's/^ミニアニメ[[:space:]]*//' \
            -e 's/^限界アニメ[[:space:]]*//' \
            -e 's/^ＴＶアニメ[[:space:]]*//' \
            -e 's/^TVアニメ[[:space:]]*//' \
            -e 's/^ドラマブレイク[[:space:]]*//' \
            -e 's/^ドラマ２４[[:space:]]*//' \
            -e 's/^.*曜ミステリー[[:space:]]*//' \
            -e 's/^サスペンス[[:space:]]*//' \
            -e 's/^＜[^＞]*＞[[:space:]]*//' \
            -e 's/^.国ドラマ[[:space:]]*//' \
            -e 's/^懐ドラ[[:space:]]*//' \
            -e 's/^夜ドラ[[:space:]]*//' \
            -e 's/^韓流朝ドラ６[[:space:]]*//' \
            -e 's/^台湾ドラマ[[:space:]]*//' \
            -e 's/^大河ドラマ[[:space:]]*//' \
            -e 's/^連続テレビ小説[[:space:]]*//' \
            -e 's/^時代劇[[:space:]]*//' \
            -e 's/^.*曜ドラマ[[:space:]]*//' \
            -e 's/^ドラマ９[[:space:]]*//' \
            -e 's/^ドラマストリーム[[:space:]]*//' \
            -e 's/^日５[[:space:]]*//' \
            -e 's/^映画[[:space:]]*//' \
            -e 's/^映画の時間[[:space:]]*//' \
            -e 's/^午後ロー[[:space:]]*//' \
            -e 's/^金曜ロードショー[[:space:]]*//' \
            -e 's/^土曜プレミアム・映画[[:space:]]*//' \
            -e 's/^ドラマ[[:space:]]*//' \
            -e 's/^.*テレビ[^[:space:]]*ドラマ[[:space:]]*//' \
                -e 's/^.*曜劇場[[:space:]]*//' \
                -e 's/__S.*$//'
    )

    found_delimiter=""
    for delimiter in "${delimiter_order[@]}"; do
        # 先頭（1文字目）を除いた 2文字目以降に区切り文字が含まれているかチェック
        if [[ "${FILENAME:1}" == *"$delimiter"* ]]; then
            found_delimiter="$delimiter"
            break
        fi
    done

    if [ -n "$found_delimiter" ]; then
        delimiter="$found_delimiter"
        if [ "$delimiter" = "話" ]; then
            if [[ "$FILENAME" =~ ([０-９0-9]{1,2}話) ]]; then
                pos=${BASH_REMATCH[0]}
                PROGRAM="${FILENAME%%$pos*}"
                EPISODE="$pos"
            else
                PROGRAM="${FILENAME}"
            fi
        # EP, Ep, ep の後に数字が続く場合のみ区切り文字として処理
        elif [[ "$delimiter" =~ ^(EP|Ep|ep)$ ]]; then
            if [[ "$FILENAME" =~ ([Ee][Pp][０-９0-9]{1,3}) ]]; then
                pos=${BASH_REMATCH[0]}
                PROGRAM="${FILENAME%%$pos*}"
                EPISODE="$pos"
            else
                PROGRAM="${FILENAME}"
            fi
        else
            PROGRAM="${FILENAME%%$delimiter*}"
            rest="${FILENAME#*$delimiter}"
            second_delimiter="${delimiter_pairs[$delimiter]}"

            if [ -n "$second_delimiter" ] && [[ "$rest" == *"$second_delimiter"* ]]; then
                EPISODE="${rest%%$second_delimiter*}"
            else
                EPISODE="$rest"
            fi
            if [ "$delimiter" = "第" ] || [ "$delimiter" = "[" ] || [ "$delimiter" = "最終回" ] || [ "$delimiter" = "最終話" ] || [ "$delimiter" = "最終首" ]; then
                EPISODE="$delimiter$EPISODE"
            fi
        fi
    else
        PROGRAM="$FILENAME"
    fi

    # 番組名抽出処理
    ORIGINAL=$(printf '%s' "$PROGRAM" | sed -e 's/\[.*//'  ) # [字] 削除
    if echo "$ORIGINAL" | grep -qE '^[「『][^」』]+[」』]'; then
        PROGRAM=$(echo "$ORIGINAL" | sed -nE 's/^[「『]([^」』]*)[」』].*/\1/p')
    else
        # フォールバック処理（全角スペースと半角スペースを末尾・先頭から確実に除去）
        PROGRAM=$(printf '%s' "$ORIGINAL" | sed -e 's/【[^】]*】//g' \
						-e 's/＜[^＞]*＞//g' \
						-e 's/[「『][^」』]*[」』].*//g' \
						-e 's/◆.*$//' \
						-e 's/▼.*$//' \
						-e 's/▽.*$//' \
						-e 's/【.*$//g' \
						-e 's/「.*$//g' \
						-e 's/[[:space:] ]*$//g' \
						-e 's/^[[:space:] ]*//g' )
    fi
    EPISODE=$(printf '%s' "$EPISODE" | sed -e 's/\[[^]]*\]//g' -e 's/__.*$//' )
    if [ -z "$PROGRAM" ]; then
        PROGRAM="$EPISODE"
    fi
    echo "$PROGRAM"
}

base="$(basename "$input_file")"
matched_folder=""

# --------------------------------------------------
# 1. まず basename で最長一致照合
# --------------------------------------------------
min_pos=-1 # 最小の出現位置を保存（-1は未設定）
max_len=-1 # マッチした文字列の最大長を保存

if [ -f "$LIST_FILE" ]; then
    while IFS= read -r existing; do
        if ! is_ignored_list_entry "$existing"; then
            pos=-1
            len="${#existing}"

            # パターン1: $base の中に $existing が含まれる場合
            if [[ "$base" == *"$existing"* ]]; then
                prefix="${base%%"$existing"*}"
                pos="${#prefix}"
            # パターン2: $existing の中に $base が含まれる場合
            elif [[ "$existing" == *"$base"* ]]; then
                pos=0
            fi

            # マッチ判定
            if [[ $pos -ne -1 ]]; then
                # 更新条件:
                # 1. 初めてマッチした (min_pos == -1)
                # 2. より先頭に近い位置でマッチした (pos < min_pos)
                # 3. 同じ出現位置だが、より長い文字列でマッチした (pos == min_pos && len > max_len)
                if [[ $min_pos -eq -1 ]] || [[ $pos -lt $min_pos ]] || ( [[ $pos -eq $min_pos ]] && [[ $len -gt $max_len ]] ); then
                    min_pos=$pos
                    max_len=$len
                    matched_folder="$existing"
                fi
            fi
        fi
    done < "$LIST_FILE"
fi

# --------------------------------------------------
# 2. ヒットしなければ extractProgram で抽出し、再照合
# --------------------------------------------------
if [ -z "$matched_folder" ]; then
    PROGRAM=$(extractProgram "$base")

    # extractProgram 結果が一般語でない場合のみ mvjf.list と再照合を行う
    if ! is_generic_word "$PROGRAM"; then
        if [ -f "$LIST_FILE" ]; then
            max_match_len=-1
            while IFS= read -r existing; do
                if ! is_ignored_list_entry "$existing"; then
                    if [[ "$PROGRAM" == *"$existing"* ]] || [[ "$existing" == *"$PROGRAM"* ]]; then
                        len="${#existing}"
                        # ここでも最長一致を採用（breakせずに最後までリストを見る）
                        if [[ $len -gt $max_match_len ]]; then
                            max_match_len=$len
                            matched_folder="$existing"
                        fi
                    fi
                fi
            done < "$LIST_FILE"
        fi
        PROGRAM="${matched_folder:-$PROGRAM}"
    fi
else
    # 最初の照合でヒットした場合
    PROGRAM="$matched_folder"
fi

# 最終的なディレクトリパス
final_dir="$outdir/$PROGRAM"
if [ "$DRY_RUN" = "true" ]; then
    echo "Using folder name: $PROGRAM"
else
    mkdir -p -- "$final_dir" || {
        echo "Failed to create directory: $final_dir"
        exit 1
    }
    mv -- "$input_file" "$final_dir/" || {
        echo "Failed to move file: $input_file -> $final_dir"
        exit 1
    }
    echo "File moved successfully: mv '$input_file' '$final_dir' "

    # 一般語の場合は mvjf.list への書き込みもスキップする
    if ! is_generic_word "$PROGRAM"; then
        if ! grep -qxF "$PROGRAM" "$LIST_FILE"; then
            echo "$PROGRAM" >> "$LIST_FILE"
            echo "Added program name to $LIST_FILE: $PROGRAM"
        else
            echo "Used program name listed in $LIST_FILE: $PROGRAM"
        fi
    else
        echo "Used generic program name (skipped $LIST_FILE update): $PROGRAM"
    fi
fi

#https://note.com/leal_walrus5520/n/n8ae31f665314
#Time stamp: 2026/09/10
