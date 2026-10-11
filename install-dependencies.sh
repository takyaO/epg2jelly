#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "\nセットアップに失敗しました (line %s, exit %s)。直前のエラーを確認してください。\n" "$LINENO" "$status" >&2; exit "$status"' ERR

readonly FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.1}"
readonly BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/epg2jelly-install.XXXXXX")"
readonly SOURCE_NOTICE="ソース取得先が利用できません。リポジトリの移転・アーカイブ状況を確認し、新しい取得先を探してから再実行してください。"

cleanup() {
    rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT

ask_yes_no() {
    local prompt="$1" default="$2" answer suffix
    if [[ "$default" == "yes" ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
    while true; do
        read -r -p "$prompt $suffix " answer
        answer="${answer:-$default}"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf 'y または n を入力してください。\n' ;;
        esac
    done
}

require_interactive() {
    if [[ ! -t 0 ]]; then
        printf 'このインストーラーは機能・ライセンス確認のため対話端末で実行してください。\n' >&2
        exit 2
    fi
}

clone_source() {
    local destination="$1"
    shift
    if ! git clone "$@" "$destination"; then
        printf '\n警告: %s\n取得元: %s\n' "$SOURCE_NOTICE" "$*" >&2
        return 1
    fi
}

install_packages() {
    "${SUDO[@]}" apt-get install -y --no-install-recommends "$@"
}

detect_gpu() {
    local vendor
    for vendor in /sys/class/drm/card[0-9]*/device/vendor; do
        [[ -r "$vendor" ]] || continue
        case "$(cat "$vendor")" in
            0x8086) printf 'intel\n'; return ;;
            0x1002) printf 'amd\n'; return ;;
        esac
    done
    printf 'unknown\n'
}

require_interactive
if [[ ! -r /etc/os-release ]] || ! grep -Eq '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
    printf 'このインストーラーはDebian/Ubuntu系のAPT環境専用です。\n' >&2
    exit 2
fi
if ! command -v apt-get >/dev/null; then
    printf 'apt-get が必要です。\n' >&2
    exit 2
fi
if [[ "$EUID" -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null || { printf 'sudo が必要です。\n' >&2; exit 2; }
    SUDO=(sudo)
fi

gpu="$(detect_gpu)"
default_hw=cpu
case "$gpu" in
    intel) default_hw=intel ;;
    amd) default_hw=vaapi ;;
esac
printf '検出GPU: %s\n' "$gpu"
printf 'ハードウェアエンコードの選択:\n  1) 自動推奨 (%s)\n  2) CPUのみ\n  3) VAAPI (Intel/AMD)\n  4) Intel QSV + VAAPI\n' "$default_hw"
read -r -p '選択 [1-4, default 1]: ' hw_choice
case "${hw_choice:-1}" in
    1) hw_mode="$default_hw" ;;
    2) hw_mode=cpu ;;
    3) hw_mode=vaapi ;;
    4) hw_mode=intel ;;
    *) printf '不正な選択です。\n' >&2; exit 2 ;;
esac
if [[ "$hw_mode" == intel && "$gpu" != intel ]]; then
    printf 'Intel QSVを選択しましたがIntel GPUを検出できませんでした。VAAPI/CPUへ切り替えるか、QSVの動作確認は手動で行ってください。\n' >&2
fi

with_intel_nonfree=no
if [[ "$gpu" == intel && "$hw_mode" != cpu ]] && ask_yes_no 'Intel non-free media driverを使いますか? (ベンダーのライセンス条件を確認してください)' no; then
    with_intel_nonfree=yes
fi
intel_driver_package=intel-media-va-driver
if [[ "$with_intel_nonfree" == yes ]]; then
    intel_driver_package=intel-media-va-driver-non-free
fi
with_wine=no
if ask_yes_no 'Wine 32-bit と winetricks も導入しますか? (APT削除検査を行い、削除があれば導入を中止します)' yes; then
    with_wine=yes
fi
with_fonts=no
if [[ "$with_wine" == yes ]] && ask_yes_no 'Wine向け allfonts を導入しますか? (各フォントのライセンス条件を確認してください)' no; then
    with_fonts=yes
fi

packages=(
    build-essential cmake ninja-build pkg-config git curl jq bc
    nodejs npm python3
    autoconf automake libtool meson
    libmp3lame-dev libopus-dev libvorbis-dev libvpx-dev libx264-dev libx265-dev
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
    libdav1d-dev libaom-dev libass-dev libfreetype6-dev libgnutls28-dev
    libaribb24-dev libatomic-ops-dev libdevil-dev libsoundtouch-dev libxml2-dev
    libfontconfig1-dev fontconfig libdrm-dev
)
case "$hw_mode" in
    vaapi)
        packages+=(libva-dev v4l-utils)
        if [[ "$gpu" == intel ]]; then
            packages+=("$intel_driver_package")
        else
            packages+=(mesa-va-drivers)
        fi
        ;;
    intel)
        packages+=(libva-dev libvpl-dev "$intel_driver_package" v4l-utils)
        ;;
esac
printf '\nAPT依存パッケージを更新・導入します。\n'
"${SUDO[@]}" apt-get update
install_packages "${packages[@]}"

if [[ "$with_wine" == yes ]]; then
    printf '\nWine 32-bit の安全確認を行います。\n'
    if ! dpkg --print-foreign-architectures | grep -qx i386; then
        "${SUDO[@]}" dpkg --add-architecture i386
    fi
    if ! "${SUDO[@]}" apt-get update; then
        printf '警告: i386用APT更新に失敗したためWineの導入を中止します。\n' >&2
    else
        wine_plan="$BUILD_DIR/wine-apt-plan.txt"
        if ! "${SUDO[@]}" apt-get -s --no-remove install wine32:i386 winetricks >"$wine_plan" 2>&1; then
            printf '警告: WineのAPTシミュレーションに失敗しました。Wineは導入しません。\n' >&2
            sed -n '1,100p' "$wine_plan" >&2
        elif grep -Eq '^(Remv|Remove):? ' "$wine_plan"; then
            printf '警告: Wine導入計画に既存パッケージの削除が含まれるため、システム保護のため導入を中止します。\n' >&2
            grep -E '^(Remv|Remove):? ' "$wine_plan" >&2
        elif ! "${SUDO[@]}" apt-get -y --no-remove install wine32:i386 winetricks; then
            printf '警告: Wineを --no-remove で導入できませんでした。APTによるパッケージ削除は許可していません。\n' >&2
        elif [[ "$with_fonts" == yes ]]; then
            printf 'winetricks allfonts を実行します。追加表示される個別ライセンス確認にも従ってください。\n'
            winetricks allfonts
        fi
    fi
fi

printf '\nソースビルドを開始します (一時作業場所: %s)\n' "$BUILD_DIR"

# AviSynth+ はCM解析ツールとFFmpegの入力に必要。
avisynth="$BUILD_DIR/AviSynthPlus"
clone_source "$avisynth" --depth 1 https://github.com/AviSynth/AviSynthPlus.git
cmake -S "$avisynth" -B "$BUILD_DIR/avisynth-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
ninja -C "$BUILD_DIR/avisynth-build"
"${SUDO[@]}" ninja -C "$BUILD_DIR/avisynth-build" install
"${SUDO[@]}" ldconfig

# FFmpegはenc.jsの音声・字幕・ソフトウェア/VAAPI/QSVオプションに合わせて構成。
ffmpeg_src="$BUILD_DIR/ffmpeg"
if ! curl --fail --location --retry 3 --output "$BUILD_DIR/ffmpeg.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"; then
    printf '\n警告: FFmpeg公式ソースを取得できません。バージョンまたは配布URLを確認し、新しい取得先を探してください。\n' >&2
    exit 1
fi
mkdir "$ffmpeg_src"
tar -xf "$BUILD_DIR/ffmpeg.tar.xz" --strip-components=1 -C "$ffmpeg_src"

ffmpeg_options=(
    --prefix=/usr/local --bindir=/usr/local/bin
    --enable-gpl --enable-version3 --enable-gnutls
    --enable-libaom --enable-libass --enable-libfreetype --enable-libmp3lame
    --enable-libopus --enable-libdav1d --enable-libvorbis --enable-libx264
    --enable-libx265 --enable-libvpx --enable-libaribb24 --enable-avisynth
    --enable-shared --disable-static --disable-doc --disable-debug
)
if [[ "$hw_mode" == vaapi || "$hw_mode" == intel ]]; then
    ffmpeg_options+=(--enable-vaapi)
fi
if [[ "$hw_mode" == intel ]]; then
    ffmpeg_options+=(--enable-libvpl)
fi
# Debian/Ubuntuではpkg-configファイル名がlibaribb24.pcと異なる場合がある。
mkdir -p "$BUILD_DIR/pkgconfig"
export PKG_CONFIG_PATH="$BUILD_DIR/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if ! pkg-config --exists libaribb24 && pkg-config --exists aribb24; then
    aribb24_pc="$(pkg-config --variable=pcfiledir aribb24)/aribb24.pc"
    if [[ -f "$aribb24_pc" ]]; then
        ln -s "$aribb24_pc" "$BUILD_DIR/pkgconfig/libaribb24.pc"
    fi
fi
(
    cd "$ffmpeg_src"
    ./configure "${ffmpeg_options[@]}"
    make -j"$(nproc)"
    "${SUDO[@]}" make install
)
"${SUDO[@]}" ldconfig

# L-SMASH本体はL-SMASH-Worksプラグインのビルド依存。
l_smash="$BUILD_DIR/l-smash"
clone_source "$l_smash" --depth 1 https://github.com/vimeo/l-smash.git
(
    cd "$l_smash"
    ./configure --prefix=/usr/local --enable-shared
    make -j"$(nproc)"
    "${SUDO[@]}" make install
)
"${SUDO[@]}" ldconfig

# Avisynth用L-SMASH-Worksプラグイン
lsmash_works="$BUILD_DIR/L-SMASH-Works"
clone_source "$lsmash_works" --depth 1 --branch 1170.0.0.0 \
    https://github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works.git
plugin_src="$lsmash_works/AviSynth"
if ! grep -qF 'last_percent != percent' "$plugin_src/lwlibav_source.cpp"; then
    printf '警告: L-SMASH-Worksの想定ソースと異なります。修正箇所を確認してください。\n' >&2
    exit 1
fi
sed -i \
    -e 's/last_percent != percent/last_percent != percent \&\& (percent == 0 || percent == 100)/' \
    -e 's/\\r/\\n/' \
    "$plugin_src/lwlibav_source.cpp"
if ! grep -qF 'last_percent != percent && (percent == 0 || percent == 100)' "$plugin_src/lwlibav_source.cpp"; then
    printf '警告: L-SMASH-Worksの互換性パッチを適用できませんでした。\n' >&2
    exit 1
fi
LDFLAGS="-Wl,-Bsymbolic" meson setup "$plugin_src/build" "$plugin_src" --prefix=/usr/local
ninja -C "$plugin_src/build" -v
"${SUDO[@]}" ninja -C "$plugin_src/build" install
"${SUDO[@]}" ldconfig

# AviSynth+向けCM解析ツール群
jls="$BUILD_DIR/JoinLogoScpTrialSetLinux"
clone_source "$jls" --depth 1 --recurse-submodules \
    https://github.com/tobitti0/JoinLogoScpTrialSetLinux.git
chapter_src="$jls/modules/chapter_exe/src"
if [[ ! -f "$chapter_src/mvec.cpp" || ! -f "$chapter_src/Makefile" ]]; then
    printf '警告: chapter_exeの想定ソースが見つからず、パッチを適用できません。\n' >&2
    exit 1
fi
for expected_patch in '_mm_load_si128' '(__m128i*)p1 +  0' '(__m128i*)p2 +  0'; do
    if ! grep -qF "$expected_patch" "$chapter_src/mvec.cpp"; then
        printf '警告: chapter_exeの想定コード "%s" が見つかりません。パッチ内容を確認してください。\n' "$expected_patch" >&2
        exit 1
    fi
done
for expected_make_setting in 'CC = gcc' '-std=gnu99' 'CFLAGS = -O3'; do
    if ! grep -qF -- "$expected_make_setting" "$chapter_src/Makefile"; then
        printf '警告: chapter_exeのMakefile設定 "%s" が見つかりません。パッチ内容を確認してください。\n' "$expected_make_setting" >&2
        exit 1
    fi
done
sed -i \
    -e 's/_mm_load_si128/_mm_loadu_si128/g' \
    -e 's/(__m128i\*)p1 +  0/(__m128i*)(p1 + 0)/g' \
    -e 's/(__m128i\*)p2 +  0/(__m128i*)(p2 + 0)/g' \
    "$chapter_src/mvec.cpp"
sed -i \
    -e 's/^CC = gcc/CC = g++/' \
    -e 's/-std=gnu99/-std=gnu++11/' \
    -e 's/-fno-tree-vectorize//g' \
    -e 's/CFLAGS = -O3/CFLAGS = -O3 -msse2/' \
    "$chapter_src/Makefile"
if grep -qF '_mm_load_si128' "$chapter_src/mvec.cpp" ||
    ! grep -qF '(__m128i*)(p1 + 0)' "$chapter_src/mvec.cpp" ||
    ! grep -qF '(__m128i*)(p2 + 0)' "$chapter_src/mvec.cpp" ||
    ! grep -qF 'CC = g++' "$chapter_src/Makefile" ||
    ! grep -qF 'CFLAGS = -O3 -msse2' "$chapter_src/Makefile"; then
    printf '警告: chapter_exeへの互換性パッチが正しく適用されませんでした。\n' >&2
    exit 1
fi
make -C "$chapter_src" -j"$(nproc)"
"${SUDO[@]}" install -m 0755 "$chapter_src/chapter_exe" /usr/local/bin/chapter_exe
logoframe_src="$jls/modules/logoframe/src"
make -C "$logoframe_src" -j"$(nproc)"
"${SUDO[@]}" install -m 0755 "$logoframe_src/logoframe" /usr/local/bin/logoframe
join_logo_src="$jls/modules/join_logo_scp/src"
make -C "$join_logo_src" -j"$(nproc)"
"${SUDO[@]}" install -m 0755 "$join_logo_src/join_logo_scp" /usr/local/bin/join_logo_scp

# TS解析補助
obuparse="$BUILD_DIR/obuparse"
clone_source "$obuparse" --depth 1 https://github.com/dwbuiten/obuparse.git
make -C "$obuparse" -j"$(nproc)"
"${SUDO[@]}" make -C "$obuparse" install

tsreadex="$BUILD_DIR/tsreadex"
clone_source "$tsreadex" --depth 1 https://github.com/xtne6f/tsreadex.git
make -C "$tsreadex" -j"$(nproc)"
"${SUDO[@]}" install -m 0755 "$tsreadex/tsreadex" /usr/local/bin/tsreadex

epgdump="$BUILD_DIR/epgdump"
clone_source "$epgdump" --depth 1 https://github.com/stz2012/epgdump.git
make -C "$epgdump" -j"$(nproc)"
"${SUDO[@]}" make -C "$epgdump" install

# DRCS字幕用 a2ac。サブモジュールも同時に取得。
arib2ass="$BUILD_DIR/arib2ass-cstyle"
clone_source "$arib2ass" --depth 1 --recurse-submodules \
    https://codeberg.org/moex3/arib2ass-cstyle.git
make -C "$arib2ass" -j"$(nproc)"
"${SUDO[@]}" install -m 0755 "$arib2ass/a2ac" /usr/local/bin/a2ac
"${SUDO[@]}" ldconfig

printf '\nインストール完了。確認結果:\n'
for command_name in ffmpeg ffprobe tsreadex epgdump chapter_exe logoframe join_logo_scp a2ac; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '  %-14s %s\n' "$command_name" "$(command -v "$command_name")"
    else
        printf '  %-14s 見つかりません\n' "$command_name"
        exit 1
    fi
done
if [[ ! -f /usr/local/lib/libobuparse.so.2 || ! -f /usr/local/include/obuparse.h ]]; then
    printf 'obuparseの共有ライブラリまたはヘッダーが見つかりません。\n' >&2
    exit 1
fi

ffmpeg_buildconf="$(/usr/local/bin/ffmpeg -hide_banner -buildconf)"
ffmpeg_encoders="$(/usr/local/bin/ffmpeg -hide_banner -encoders)"
for required_option in --enable-avisynth --enable-libaribb24; do
    if ! grep -qF -- "$required_option" <<<"$ffmpeg_buildconf"; then
        printf 'FFmpegに必須オプション %s が含まれていません。\n' "$required_option" >&2
        exit 1
    fi
done
for required_encoder in libx264; do
    if ! grep -qw "$required_encoder" <<<"$ffmpeg_encoders"; then
        printf 'FFmpegに期待するエンコーダー %s がありません。\n' "$required_encoder" >&2
        exit 1
    fi
done
if [[ "$hw_mode" == vaapi || "$hw_mode" == intel ]]; then
    for required_encoder in h264_vaapi hevc_vaapi; do
        if ! grep -qw "$required_encoder" <<<"$ffmpeg_encoders"; then
            printf 'FFmpegに期待するVAAPIエンコーダー %s がありません。\n' "$required_encoder" >&2
            exit 1
        fi
    done
fi
if [[ "$hw_mode" == intel ]]; then
    for required_encoder in h264_qsv hevc_qsv; do
        if ! grep -qw "$required_encoder" <<<"$ffmpeg_encoders"; then
            printf 'FFmpegに期待するIntel QSVエンコーダー %s がありません。\n' "$required_encoder" >&2
            exit 1
        fi
    done
fi
printf '\nFFmpegのビルド機能を確認しました。実機でエンコードテストしてください。\n'
