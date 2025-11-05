# ディレクトリ
export WORKDIR="$HOME/work/" # 作業ディレクトリ（このファイルのディレクトリ）
export SOURCEDIR="$HOME/docker-mirakurun-epgstation/recorded/" # m2ts (変換前) のソースディレクトリ
export OUTDIR="$HOME/media/" # mp4 (変換後) の出力先ディレクトリ

# オプション
export CMCUT=false   # false: CMカットなし
export CHKDRP=false # false: 動画チェックなし
export WATCHDIR=false # false: サーバー(EPGSTATION_URL)監視、true: ディレクトリ(SOURCEDIR) 監視
export EPGSTATION_URL="http://localhost:8888" #
#export NTFY_URL="" # ntfy.sh 未設定ならコメントアウト
#NHKチャンネルID: CMCUT=falseなら設定不要
#export NHK1="GR26"
#export NHK2="GR27"
