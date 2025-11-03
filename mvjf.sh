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
    touch 
    echo "#番組フォルダ名として優先される番組名のリスト。不完全ならば手動で修正する。" > "$LIST_FILE"
fi

# 区切り文字の優先順位リスト
delimiter_order=("＃" "♯" "#" "第" "最終回" "最終話" "最終首" "(" "（" "話"  "★" "☆" "▼" "◆"  "▽" "【" "「" "『" " "  "　"  "_" "[")
# 優先順序: "【"  or "　"
# 【を優先させるが、先頭の場合だけ別途対処

# 区切り文字と対応するセカンドデリミタを定義
declare -A delimiter_pairs=(
    # ドラマ、シリーズもの
    ["話"]=""  # 「話」にはセカンドデリミタ不要
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

#先頭の【夜ドラ】 は削除: NHKに多い
FILENAME=$(echo "$BASENAME" | sed 's/^【[^】]*】//')


found_delimiter=""
for delimiter in "${delimiter_order[@]}"; do
    if [[ "$FILENAME" == *"$delimiter"* ]]; then
        found_delimiter="$delimiter"
        break
    fi
done

if [[ -n "$found_delimiter" ]]; then
    delimiter=$found_delimiter
    if [[ "$delimiter" == "話" ]]; then
        # 「数字+話」で分割（全角・半角数字対応）
        if [[ "$FILENAME" =~ ([０-９0-9]{1,2}話) ]]; then
            pos=${BASH_REMATCH[0]}  # マッチした部分（例: "２話"）
            PROGRAM="${FILENAME%%$pos*}"
            EPISODE="$pos"
#            break
#	fi
	else
            # 「話」の前が数字でない場合:  孤独のグルメ全話イッキ見！
            if [[ "$FILENAME" == *"話"* ]]; then
		temp="${FILENAME%話*}"
                PROGRAM="${temp%?}"  
                EPISODE="${FILENAME#${PROGRAM}}"
            fi
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
#        break
    fi
else
    PROGRAM="$FILENAME"    
fi

# 番組名抽出
ORIGINAL=$(echo "$PROGRAM" | sed -e 's/^\[[^]]\]//' -e 's/^\[[^]]\]//' -e 's/\[.*//' ) #  [字] 削除

if echo "$ORIGINAL" | grep -qE 'ドラマ[^「『]*[「『][^」』]+[」』]'; then
    PROGRAM=$(echo "$ORIGINAL" | sed -n 's/.*ドラマ[^「『]*[「『]\([^」』]*\)[」』].*/\1/p') #木曜ドラマ「恋愛禁止」…
elif echo "$ORIGINAL" | grep -qE '劇場[^「『]*[「『][^」』]+[」』]'; then
    PROGRAM=$(echo "$ORIGINAL" | sed -n 's/.*劇場[^「『]*[「『]\([^」』]*\)[」』].*/\1/p') #日曜劇場「１９番目のカルテ」…
elif echo "$ORIGINAL" | grep -qE '^[「『][^」』]+[」』]'; then
    PROGRAM=$(echo "$ORIGINAL" | sed -n 's/^[「『]\([^」』]*\)[」』].*/\1/p') #「放送局占拠」…
elif echo "$ORIGINAL" | grep -qE 'アニメ[^「『]*[「『][^」』]+[」』]'; then
    PROGRAM=$(echo "$ORIGINAL" | sed -n 's/.*アニメ[^「『]*[「『]\([^」』]*\)[」』].*/\1/p') #アニメ「暗殺教室」
elif echo "$ORIGINAL" | grep -qE '日５[^「『]*[「『][^」』]+[」』]'; then
    PROGRAM=$(echo "$ORIGINAL" | sed -n 's/.*日５[^「『]*[「『]\([^」』]*\)[」』].*/\1/p') #日５「魔法少女まどか☆マギカ
else
    PROGRAM=$(echo "$ORIGINAL" | sed -e 's/【[^】]*】//g' \
                                     -e 's/＜[^＞]*＞//g' \
                                     -e 's/[「『][^」』]*[」』].*//g' \
                                     -e 's/◆.*$//' \
                                     -e 's/▼.*$//' \
                                     -e 's/▽.*$//' \
                                     -e 's/^アニメ//' \
                                     -e 's/[ 　]*$//g' \
                                     -e 's/^[ 　]*//g' \
                                     -e 's/[ 　].*$//' \
	   )
fi

EPISODE=$(echo "$EPISODE" | sed -e 's/\[[^]]*\]//g' -e 's/__.*$//' )  # [字] 削除

#却下するPROGRAM名
MATCH_LIST=("アニメ" "プチプチ・アニメ" "ミニアニメ")
if [ -z "$PROGRAM" ]  || [[ " ${MATCH_LIST[@]} " =~ " ${PROGRAM} " ]]; then
    PROGRAM=$EPISODE
fi

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
#Time stamp: 2025/11/03
