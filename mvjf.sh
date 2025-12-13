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
	echo "指定されたファイルが存在しません: $input_file"
	exit 1
    fi
    # 出力ディレクトリが存在するか
    if [ ! -d "$outdir" ]; then
	echo "指定された出力ディレクトリが存在しません: $outdir"
	exit 1
    fi
fi

# 優先する番組名リストを記したファイルのパス（必要ならば手で編集する）
LIST_FILE="mvjf.list"

# リストファイルが存在しない場合は作成
if [ ! -f "$LIST_FILE" ]; then
    echo "#番組フォルダ名として優先される番組名のリスト。不完全ならば手動で修正する。" > "$LIST_FILE"
fi

extractProgram() {
    # 引数受け取り
    local input_file="$1"

    # 関数内部で使う変数をlocal宣言（呼び出し元の変数を上書きしないため）
    local BASENAME FILENAME PROGRAM EPISODE ORIGINAL rest temp delimiter found_delimiter second_delimiter pos
    local -a delimiter_order MATCH_LIST
    local -A delimiter_pairs

    # 区切り文字の優先順位リスト
    delimiter_order=("＃" "♯" "#" "第" "最終回" "最終話" "最終首" "(" "（" "話"  "★" "☆" "▼" "◆"  "▽" "【" "「" "『" " "  "　"  "_" "[")

    # 区切り文字と対応するセカンドデリミタを定義
    delimiter_pairs=(
        # ドラマ、シリーズもの
        ["話"]="" 
        ["＃"]="_"
        ["♯"]="_"
        ["#"]="_"
        ["第"]="_"
        ["最終回"]="_"
        ["最終話"]="_"
        ["最終首"]="_"
        ["("]=")"
        ["（"]="）"
        # バラエティーで多い
        ["★"]="_"
        ["☆"]="_"
        ["▼"]="_"
        ["▽"]="_"
        ["◆"]="_"
        [" "]="_"
        # アニメで多い
        ["【"]="】"
        ["「"]="」"
        ["『"]="』"
        # 要検討
        ["["]="."
        ["　"]="_"
        ["_"]="."
    )

    BASENAME=$(basename "$input_file")

    # 先頭文字列削除
    FILENAME=$(echo "$BASENAME" | sed -e 's/^【[^】]*】//' \
                                     -e 's/^プチプチ・アニメ[[:space:]]*//' \
                                     -e 's/^アニメ[[:space:]]*//' \
                                     -e 's/^ミニアニメ[[:space:]]*//' \
                                     -e 's/^限界アニメ[[:space:]]*//' \
                                     -e 's/^ＴＶアニメ[[:space:]]*//' \
                                     -e 's/^ドラマブレイク[[:space:]]*//' \
                                     -e 's/^.*曜ミステリー[[:space:]]*//' \
                                     -e 's/^サスペンス[[:space:]]*//' \
                                     -e 's/^＜[^＞]*＞[[:space:]]*//' \
                                     -e 's/^.国ドラマ[[:space:]]*//' \
                                     -e 's/^懐ドラ[[:space:]]*//' \
                                     -e 's/^韓流朝ドラ６[[:space:]]*//' \
                                     -e 's/^台湾ドラマ[[:space:]]*//' \
                                     -e 's/^大河ドラマ[[:space:]]*//' \
                                     -e 's/^連続テレビ小説[[:space:]]*//' \
                                     -e 's/^時代劇[[:space:]]*//' \
                                     -e 's/^.*曜ドラマ[[:space:]]*//' \
                                     -e 's/^ドラマ２４[[:space:]]*//' \
                                     -e 's/^日５[[:space:]]*//' \
                                     -e 's/^映画[[:space:]]*//' \
                                     -e 's/^映画の時間[[:space:]]*//' \
                                     -e 's/^午後ロー[[:space:]]*//' \
                                     -e 's/^金曜ロードショー[[:space:]]*//' \
                                     -e 's/^土曜プレミアム・映画[[:space:]]*//' \
                                     -e 's/^.*曜劇場[[:space:]]*//')
    
    found_delimiter=""
    for delimiter in "${delimiter_order[@]}"; do
        # pattern matching
        if [[ "$FILENAME" == *"$delimiter"* ]]; then
            found_delimiter="$delimiter"
            break
        fi
    done

    if [[ -n "$found_delimiter" ]]; then
        delimiter="$found_delimiter"
        if [[ "$delimiter" == "話" ]]; then
            # 「数字+話」で分割（全角・半角数字対応）
            if [[ "$FILENAME" =~ ([０-９0-9]{1,2}話) ]]; then
                pos=${BASH_REMATCH[0]}  # マッチした部分
                PROGRAM="${FILENAME%%$pos*}"
                EPISODE="$pos"
            else
                # 「話」の前が数字でない場合
                PROGRAM="${FILENAME}"
#                if [[ "$FILENAME" == *"話"* ]]; then
#                    temp="${FILENAME%話*}"
#                    PROGRAM="${temp%?}"
#                    EPISODE="${FILENAME#${PROGRAM}}"
#                fi
            fi  
        elif [[ "$FILENAME" == *"$delimiter"* ]]; then
            PROGRAM="${FILENAME%%$delimiter*}"
            rest="${FILENAME#*$delimiter}"
            second_delimiter="${delimiter_pairs[$delimiter]}"
            
            if [[ -n "$second_delimiter" && "$rest" == *"$second_delimiter"* ]]; then
                EPISODE="${rest%%$second_delimiter*}"
            else
                EPISODE="$rest"
            fi
            
            if [[ "$delimiter" == "第" || "$delimiter" == "[" || "$delimiter" == "最終回" || "$delimiter" == "最終話" || "$delimiter" == "最終首" ]]; then
                EPISODE="$delimiter$EPISODE"
            fi
        fi
    else
        PROGRAM="$FILENAME"    
    fi

    # 番組名抽出処理
    ORIGINAL=$(echo "$PROGRAM" | sed -e 's/^\[[^]]\]//' -e 's/^\[[^]]\]//' -e 's/\[.*//' ) # [字] 削除

    # ヒューリスティックな抽出（grep -E と sed -E で統一）
    if echo "$ORIGINAL" | grep -qE '^[「『][^」』]+[」』]'; then
        PROGRAM=$(echo "$ORIGINAL" | sed -nE 's/^[「『]([^」』]*)[」』].*/\1/p')
    else
        # フォールバック処理
        PROGRAM=$(echo "$ORIGINAL" | sed -e 's/【[^】]*】//g' \
                                         -e 's/＜[^＞]*＞//g' \
                                         -e 's/[「『][^」』]*[」』].*//g' \
                                         -e 's/◆.*$//' \
                                         -e 's/▼.*$//' \
                                         -e 's/▽.*$//' \
                                         -e 's/【.*$//g' \
                                         -e 's/「.*$//g' \
                                         -e 's/[ 　]*$//g' \
                                         -e 's/^[ 　]*//g' \
                                         -e 's/[ 　].*$//' \
            )
    fi

    EPISODE=$(echo "$EPISODE" | sed -e 's/\[[^]]*\]//g' -e 's/__.*$//' )

#    # 却下するPROGRAM名の判定
#    MATCH_LIST=("アニメ" "ミニアニメ" )
#    # 配列内の要素チェック（完全一致）
#    local is_match=0
#    for item in "${MATCH_LIST[@]}"; do
#        if [[ "$item" == "$PROGRAM" ]]; then
#            is_match=1
#            break
#        fi
#    done

    if [[ -z "$PROGRAM" || $is_match -eq 1 ]]; then
        PROGRAM="$EPISODE"
    fi

    # 【重要】戻り値として標準出力に書き出す
    echo "$PROGRAM"
}


PROGRAM=$(extractProgram "$input_file")

# リストファイルから既存のフォルダ名を検索（上から順に）
matched_folder="$PROGRAM"
if [ -f "$LIST_FILE" ]; then
    while IFS= read -r existing; do
        if [[ -n "$existing" ]]; then
            # 部分一致チェック：新しいフォルダ名が既存の文字列を含む、または既存の文字列が新しいフォルダ名を含む
            if [[ "$PROGRAM" == *"$existing"* ]] || [[ "$existing" == *"$PROGRAM"* ]]; then
                matched_folder="$existing"
                break  # 最初に見つかったものを使う
            fi
        fi
    done < "$LIST_FILE"
fi

PROGRAM="$matched_folder"


# 最終的なディレクトリパス
#final_dir="$outdir/$PROGRAM/$EPISODE"
final_dir="$outdir/$PROGRAM"

if [ "$DRY_RUN" = "true" ]; then
   # ドライランモードの場合、移動操作を行わない
   echo "Dry run mode: $final_dir/$(basename "$input_file")"
   echo "Using folder name: $PROGRAM"
else
    # ディレクトリを作成（存在しない場合のみ）
    mkdir -p "$final_dir" || {
	echo "ディレクトリの作成に失敗しました: $final_dir"
	exit 1
    }
    # ファイルを移動
    mv "$input_file" "$final_dir" || {
	echo "ファイルの移動に失敗しました: $input_file -> $final_dir"
	exit 1
    }
    echo "ファイルが正常に移動されました: $final_dir/$(basename "$input_file")"
    
    # リストファイルにフォルダ名が存在しない場合のみ追加
    if ! grep -qxF "$PROGRAM" "$LIST_FILE"; then
        echo "$PROGRAM" >> "$LIST_FILE"
        echo "フォルダ名をリストファイルに追加しました: $PROGRAM"
    else
        echo "フォルダ名は既にリストファイルに存在します: $PROGRAM"
    fi
fi

#https://note.com/leal_walrus5520/n/n8ae31f665314
#Time stamp: 2025/12/13
