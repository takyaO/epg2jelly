# epg2jelly
Helps integrate the TV recording management server, EPGStation, with media servers like Jellyfin. Transcodes m2ts files to mp4 format during spare times when recording is not active. Converted files are organized in a hierarchical structure within a folder managed by the media server.

**テレビ録画管理サーバー EPGStation** と **Jellyfin** などのメディアサーバーとの連携を支援するツールです。

録画をしていない時間帯に、自動で、**地デジ録画（m2ts形式）を mp4形式に変換**し、

メディアサーバー管理下のフォルダに**階層構造で配置**します。

## プライバシー重視

完全ローカル動作。外部サーバーとの通信は一切ありません。

## 動作要件

1. **EPGStation** 
   
　　https://github.com/l3tnun/docker-mirakurun-epgstation
  
2. **ffmpeg**など

　　内部的に利用するAvisynth+対応FFmpeg、CM解析ツール、TS/字幕ツールを自家ビルドするセットアップスクリプトを用意しています。Debian/Ubuntu系で、次のコマンドを対話端末から実行してください。

```bash
wget https://raw.githubusercontent.com/takyaO/epg2jelly/main/install-dependencies.sh
bash install-dependencies.sh
```

　　ハードウェアエンコード（CPU / VAAPI / Intel QSV）、Intel non-freeドライバー、Wineおよびフォントの導入は選択式です。Wineは使用しませんが、別途ロゴ生成で使用する場合を考えて含めています。NVIDIAのNVENCは現在のenc.jsに未対応のため、VAAPI環境がない場合はCPUエンコードを選んでください。ライセンス条件を確認する項目はプロンプトで同意を求めます。WineはAPTの導入計画を事前検査し、既存パッケージの削除が必要な場合は導入を中止します。

　　インストーラーは既存の `ffmpeg_611` 設定およびL-SMASH-Worksとの互換性を優先し、FFmpeg 6.1.1を既定で使用します。別バージョンを指定する場合は `FFMPEG_VERSION` を設定してください。ソース取得先の変更・停止などで取得に失敗した場合は、警告を表示して処理を停止します。取得先を確認・更新してから再実行してください。

　　上記スクリプトを使わずに、最低限必要となる基本パッケージを手動で入れる場合は `sudo apt install ffmpeg curl jq bc python3` です。このAPT版FFmpegにはAvisynth+対応その他このプロジェクトで必要な機能がありません。

### オプション：DRCS字幕のUnicode変換

録画名に `[字]` が含まれる場合、作業ディレクトリに `drcs-conv.toml` があり、`a2ac` と `fc-match` が利用できれば、DRCSをUnicodeに変換した外部字幕（`.ja.ass`）も出力します。通常モードではエンコード成功後に生成し、トリムモードでは最初の字幕ストリームを一時ASSに抽出する段階でa2acを使い、その一時ASSに既存の時刻補正・トリム処理を適用します。条件を満たさない場合やa2acでの抽出に失敗した場合は、従来どおりffmpegで抽出します。`enc01.sh` 経由で実行すると、既存の処理で `.ja.vtt` に変換されます。いずれの場合も動画エンコードには影響しません。

## インストール手順

1. 設定 docker-mirakurun-epgstation/epgstation/config/config.ymlのrecordedFormat を '%TITLE%' が先頭になるように変更
2. git clone https://github.com/takyaO/epg2jelly.git ファイル一式を~/work/  にコピー
3. 設定 env.shを確認の上で encode.shの動作を確認。番組名リストmvjf.list.templateを mvjf.listにコピー
4. cronに登録

```*/4 * * * * $HOME/work/encode.sh >> $HOME/work/encode.log 2>&1```

**ffmpeg のオプションは enc.js (以下、第３０回参照)**

## 動作イメージ（ショート動画）

[自家製ネットフリックス](https://youtube.com/shorts/5582veqBuvs)

## 解説記事

以下の連載の構築の一部を、修正してまとめたものです。詳細や拡張機能（オプション）については、記事を参照してください。


### テレビ録画メディアサーバー構築入門：索引

過去回の概要一覧

[第1回：はじめに。準備が必要なもの](https://note.com/leal_walrus5520/n/n7e545ac19282)

おすすめPCなど

[第2回：Ubuntu OS インストール。はじめてのlinux](https://note.com/leal_walrus5520/n/nbd924785e428)

新PCが使えるようになる

[第3回：デバイス認識。EPGStation, Mirakurunインストール](https://note.com/leal_walrus5520/n/n08853af15047)

テレビ録画できるようになる

[第4回：AviSynth, chapter_exe, logoframe, join_logo_scp, ffmpeg](https://note.com/leal_walrus5520/n/n7181f4b46d5f)

昔風のインストール作業

[第5回：CMカット。ロゴファイル作成](https://note.com/leal_walrus5520/n/ndc191af72c04)

市民的自由（著作物の私的使用）

[第6回：作業フォルダ、メディアフォルダ。Jellyfin インストール](https://note.com/leal_walrus5520/n/n98e738cae3b4)

視聴環境が整う

[第7回：処理済み判定、番組名でフォルダ整理](https://note.com/leal_walrus5520/n/n8ae31f665314)

メディアサーバーでのファイル管理対策

[第8回：空き時間に編集自動化](https://note.com/leal_walrus5520/n/nd83ae9364893)

全自動化完了

[第9回：録画ルール設定、処理済み動画自動削除](https://note.com/leal_walrus5520/n/nda8b12ec193a)

コンセプトと使用方法

[第10回：スマホに自動通知](https://note.com/leal_walrus5520/n/ncf432124c304)

ちゃんと動いているか不安になるので

[第11回：使用雑感。不具合対策。再起動法](https://note.com/leal_walrus5520/n/n04258fe6dec1)

感想とか

[第12回：外部データベース連携。TMDB登録方法](https://note.com/leal_walrus5520/n/n84f23ed19dc0)

見た目がよくなる

[第13回：ライブラリ追加「映画」](https://note.com/leal_walrus5520/n/nb685324a21cb)

ますます、カッコよくなる

[第14回：ダッシュボード（ホームページ）](https://note.com/leal_walrus5520/n/nf5238d79826d)

スマホで便利に

[第15回：ネットダウンローダー](https://note.com/leal_walrus5520/n/n30be9048ce52)

TVerとか、youtubeとか

[第16回：ハードウェアアクセラレーション](https://note.com/leal_walrus5520/n/n0769ac49efaa)

Jellyfinおすすめ設定

[第17回：スマートテレビ](https://note.com/leal_walrus5520/n/nf497415924f0)

リビングの大画面で

[第18回：外部ストレージ増設](https://note.com/leal_walrus5520/n/nc76a1cf19496)

録画マニアへの入り口

[第19回：トラブルシューティング](https://note.com/leal_walrus5520/n/nd02caee3ebd9)

戦いは続く

[第20回：イントロスキップ](https://note.com/leal_walrus5520/n/nbd448d336d29)

豊富なプラグインで、ますます便利に

[第21回：多重化](https://note.com/leal_walrus5520/n/n74a7c7561d43)

字幕や副音声をとりこむ

[第22回：QSVデコード](https://note.com/leal_walrus5520/n/nca83c32ca458)

動画処理効率化

[第23回：PX-Q1UD](https://note.com/leal_walrus5520/n/nc8a2971a385b)

難ありチューナーを扱うコツ

[第24回：MP4にメタデータを埋め込む](https://note.com/leal_walrus5520/n/nb560315013e3)

放送波中の諸情報を有効利用

[第25回：サーバー分離](https://note.com/leal_walrus5520/n/n2df9b408649f)

録画サーバーとメディアサーバーを物理的に分ける

[第26回：録画 予約 支援アプリ](https://note.com/leal_walrus5520/n/ncaf1feb3808c)

スマホから録画予約管理

[第27回：自動字幕生成: AI連携](https://note.com/leal_walrus5520/n/n5309adb7ef00)

OpenAI Whisperを使ってみる

[第28回：Jellyfinサーバーアップデート](https://note.com/leal_walrus5520/n/nc6592d16ff7c)

アプデに備えて

[第29回：マルチチャンネル対応](https://note.com/leal_walrus5520/n/n2d01e784a813)

バグ対策

[第30回：正式リリース(Ver.1.0)](https://note.com/leal_walrus5520/n/n6bb1f4231910)

enc.js マニュアル

[第31回：アップデート ver 1.1](https://note.com/leal_walrus5520/n/n10bdb083fad5)

インストーラーの説明


