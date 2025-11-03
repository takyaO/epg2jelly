# ディレクトリ
WORKDIR="$HOME/work/" # 作業ディレクトリ（このファイルのディレクトリ）
SOURCEDIR="$HOME/docker-mirakurun-epgstation/recorded/" # m2ts (変換前) のソースディレクトリ
OUTDIR="$HOME/media/" # mp4 (変換後) の出力先ディレクトリ

# オプション
CMCUT=false   # CMカットしないなら false
CHKDRP=false #動画エラーチェックしないなら false
#export WATCHDIR="" #監視ディレクトリ（ディレクトリ監視型）：EPGSTATION_URLを監視（サーバー監視型）ならコメントアウト（未定義）
EPGSTATION_URL="http://localhost:8888/" #監視ディレクトリ型なら設定不要

# ntfy.sh通知先
#NTFY_URL="" # 未設定ならコメントアウト

# NHKチャンネルID: CMCUT=falseなら設定不要
#NHK1="GR26"
#NHK2="GR27"

