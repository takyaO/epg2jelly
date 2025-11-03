# ディレクトリ
export WORKDIR="$HOME/work/" # 作業ディレクトリ（このファイルのディレクトリ）
export SOURCEDIR="$HOME/docker-mirakurun-epgstation/recorded/" # m2ts (変換前) のソースディレクトリ
OUTDIR="$HOME/media/" # mp4 (変換後) の出力先ディレクトリ

# オプション
CMCUT=false   # CMカットしないなら false
CHKDRP=false #動画エラーチェックしないなら false
export WATCHDIR=false # false: サーバー(EPGSTATION_URL)監視、true: ディレクトリ(SOURCEDIR) 監視
export EPGSTATION_URL="http://localhost:8888/" #ディレクトリ監視なら設定不要
#NTFY_URL="" # ntfy.sh通知先： 未設定ならコメントアウト
# NHKチャンネルID: CMCUT=falseなら設定不要
#NHK1="GR26"
#NHK2="GR27"
