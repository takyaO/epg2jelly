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
            0x10de) printf 'nvidia\n'; return ;;
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
    intel) default_hw=vaapi ;;
    amd) default_hw=vaapi ;;
esac
printf '検出GPU: %s\n' "$gpu"
printf 'ハードウェアエンコードの選択:\n  1) 自動推奨 (%s)\n  2) CPUのみ (libx264)\n  3) VAAPI (Intel/AMDなど、対応ドライバーが必要)\n  4) Intel QSV + VAAPI (Intel GPUとlibvpl >= 2.6が必要)\n' "$default_hw"
read -r -p '選択 [1-4, default 1]: ' hw_choice
case "${hw_choice:-1}" in
    1) hw_mode="$default_hw" ;;
    2) hw_mode=cpu ;;
    3) hw_mode=vaapi ;;
    4) hw_mode=intel ;;
    *) printf '不正な選択です。\n' >&2; exit 2 ;;
esac
if [[ "$hw_mode" == intel && "$gpu" != intel ]]; then
    printf 'Intel QSVにはIntel GPUが必要ですが、検出結果は %s です。CPUまたはVAAPIを選択してください。\n' "$gpu" >&2
    exit 2
fi

intel_driver_package=intel-media-va-driver
if [[ "$gpu" == intel && "$hw_mode" == vaapi ]]; then
    printf 'Intel VAAPIドライバーはGPU世代に合わせて選択してください:\n  1) iHD (Broadwell以降向け、推奨)\n  2) i965 (Ivy Bridge / Haswellなど旧世代向け)\n'
    read -r -p '選択 [1-2, default 1]: ' intel_driver_choice
    case "${intel_driver_choice:-1}" in
        1) intel_driver_package=intel-media-va-driver ;;
        2) intel_driver_package=i965-va-driver ;;
        *) printf '不正なIntel VAAPIドライバー選択です。\n' >&2; exit 2 ;;
    esac
fi
if [[ "$gpu" == intel && "$hw_mode" == intel ]]; then
    if ask_yes_no 'Intel non-free iHD media driverを使いますか? (ライセンス条件を確認してください)' no; then
        intel_driver_package=intel-media-va-driver-non-free
    fi
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
    build-essential cmake ninja-build checkinstall pkg-config git curl jq bc nasm yasm
    nodejs npm python3
    autoconf automake libtool meson
    libmp3lame-dev libopus-dev libvorbis-dev libvpx-dev libx264-dev libx265-dev
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
    libdav1d-dev libaom-dev libass-dev libfreetype6-dev libgnutls28-dev
    libaribb24-dev libatomic-ops-dev libdevil-dev libsoundtouch-dev libxml2-dev
    libfontconfig1-dev fontconfig libdrm-dev libfdk-aac-dev
)
case "$hw_mode" in
    vaapi)
        packages+=(libva-dev v4l-utils)
        if [[ "$gpu" == intel ]]; then
            packages+=("$intel_driver_package")
        elif [[ "$gpu" == amd ]]; then
            packages+=(mesa-va-drivers)
        else
            printf '警告: %s GPU向けのVAAPIドライバーは自動選択できません。\n' "$gpu" >&2
            printf 'GPUベンダー提供のVAAPIエンコード対応ドライバーを別途導入してください。利用できない場合はCPUエンコードを選択してください。\n' >&2
        fi
        ;;
    intel)
        packages+=(libva-dev libvpl-dev libvpl2 "$intel_driver_package" v4l-utils)
        ;;
esac
printf '\nAPT依存パッケージを更新・導入します。\n'
"${SUDO[@]}" apt-get update
if [[ "$hw_mode" == intel ]]; then
    vpl_version="$(apt-cache policy libvpl-dev | awk '/Candidate:/ { print $2; exit }')"
    if [[ -z "$vpl_version" || "$vpl_version" == '(none)' ]] ||
        ! dpkg --compare-versions "$vpl_version" ge 2.6; then
        printf '警告: Intel QSVにはlibvpl-dev >= 2.6が必要ですが、APT候補は %s です。\n' "${vpl_version:-取得不可}" >&2
        printf 'QSVビルドは続行できません。使用ディストリビューションの対応パッケージを確認するか、VAAPI/CPUを選択してください。\n' >&2
        exit 2
    fi
fi
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
clone_source "$avisynth" https://github.com/AviSynth/AviSynthPlus.git
if [[ "$(git -C "$avisynth" rev-parse --is-shallow-repository)" == true ]]; then
    if ! git -C "$avisynth" fetch --unshallow --tags origin; then
        printf '\n警告: AviSynth+のタグ・履歴を取得できませんでした。%s\n' "$SOURCE_NOTICE" >&2
        exit 1
    fi
elif ! git -C "$avisynth" fetch --tags origin; then
    printf '\n警告: AviSynth+のタグを取得できませんでした。%s\n' "$SOURCE_NOTICE" >&2
    exit 1
fi
if ! git -C "$avisynth" describe --tags --abbrev=0 >/dev/null 2>&1; then
    printf 'AviSynth+のHEADから到達できるGitタグがありません。タグ付きリリースを取得できるか確認してください。\n' >&2
    exit 1
fi
cmake -S "$avisynth" -B "$BUILD_DIR/avisynth-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
avisynth_pc="$BUILD_DIR/avisynth-build/avs_core/avisynth.pc"
if [[ ! -f "$avisynth_pc" ]]; then
    printf 'AviSynth+のバージョン情報ファイルが見つかりません: %s\n' "$avisynth_pc" >&2
    exit 1
fi
avisynth_version="$(awk '$1 == "Version:" { print $2; exit }' "$avisynth_pc")"
if [[ -z "$avisynth_version" ]]; then
    printf 'AviSynth+のバージョンを %s から読み取れません。\n' "$avisynth_pc" >&2
    exit 1
fi
avisynth_pkgversion="${avisynth_version}-$(date --rfc-3339=date | tr -d '-')-git"
(
    cd "$BUILD_DIR/avisynth-build"
    "${SUDO[@]}" checkinstall \
        --pkgname=avisynth \
        --pkgversion="$avisynth_pkgversion" \
        --backup=no \
        --deldoc=yes \
        --delspec=yes \
        --deldesc=yes \
        --strip=yes \
        --stripso=yes \
        --addso=yes \
        --fstrans=no \
        --default \
        ninja install
)
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
    --enable-libopus --enable-libdav1d --enable-libvorbis --enable-libfdk-aac --enable-libx264
    --enable-libx265 --enable-libvpx --enable-libaribb24 --enable-avisynth
    --enable-shared --enable-nonfree --disable-static --disable-doc --disable-debug
)
if [[ "$hw_mode" == vaapi || "$hw_mode" == intel ]]; then
    ffmpeg_options+=(--enable-vaapi)
fi
if [[ "$hw_mode" == intel ]]; then
    vpl_version="$(pkg-config --modversion libvpl)"
    if ! dpkg --compare-versions "$vpl_version" ge 2.6; then
        printf 'Intel QSV用libvplのバージョンが古すぎます: %s (必要: >= 2.6)\n' "$vpl_version" >&2
        exit 1
    fi
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

# L-SMASHのAV1 parserが必要とするobuparseを先にインストール。
obuparse="$BUILD_DIR/obuparse"
clone_source "$obuparse" --depth 1 https://github.com/dwbuiten/obuparse.git
make -C "$obuparse" -j"$(nproc)"
"${SUDO[@]}" make -C "$obuparse" install
"${SUDO[@]}" ldconfig
if [[ ! -f /usr/local/include/obuparse.h || ! -f /usr/local/lib/libobuparse.so.2 ]]; then
    printf 'obuparseのインストールを確認できません (/usr/local/include/obuparse.h, /usr/local/lib/libobuparse.so.2)。\n' >&2
    exit 1
fi

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
for expected_make_setting in 'CC = gcc' '-std=gnu99'; do
    if ! grep -qF -- "$expected_make_setting" "$chapter_src/Makefile"; then
        printf '警告: chapter_exeのMakefile設定 "%s" が見つかりません。パッチ内容を確認してください。\n' "$expected_make_setting" >&2
        exit 1
    fi
done
if ! grep -qE '^CFLAGS[[:space:]]*=' "$chapter_src/Makefile"; then
    printf '警告: chapter_exeのMakefileにCFLAGS定義がありません。パッチ内容を確認してください。\n' >&2
    exit 1
fi
sed -i \
    -e 's/_mm_load_si128/_mm_loadu_si128/g' \
    -e 's/(__m128i\*)p1 +  0/(__m128i*)(p1 + 0)/g' \
    -e 's/(__m128i\*)p2 +  0/(__m128i*)(p2 + 0)/g' \
    "$chapter_src/mvec.cpp"
sed -i \
    -e 's/^CC = gcc/CC = g++/' \
    -e 's/-std=gnu99/-std=gnu++11/' \
    -e 's/-fno-tree-vectorize//g' \
    -e '/^CFLAGS[[:space:]]*=/ { /-msse2/! s/$/ -msse2/; }' \
    "$chapter_src/Makefile"
if grep -qF '_mm_load_si128' "$chapter_src/mvec.cpp" ||
    ! grep -qF '(__m128i*)(p1 + 0)' "$chapter_src/mvec.cpp" ||
    ! grep -qF '(__m128i*)(p2 + 0)' "$chapter_src/mvec.cpp" ||
    ! grep -qF 'CC = g++' "$chapter_src/Makefile" ||
    ! grep -qF -- '-std=gnu++11' "$chapter_src/Makefile" ||
    grep -qF -- '-fno-tree-vectorize' "$chapter_src/Makefile" ||
    ! grep -qE '^CFLAGS[[:space:]]*=.*[[:space:]]-msse2([[:space:]]|$)' "$chapter_src/Makefile"; then
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

ffmpeg_buildconf="$(/usr/local/bin/ffmpeg -hide_banner -buildconf)"
ffmpeg_encoders="$(/usr/local/bin/ffmpeg -hide_banner -encoders)"
for required_option in --enable-avisynth --enable-libaribb24; do
    if ! grep -qF -- "$required_option" <<<"$ffmpeg_buildconf"; then
        printf 'FFmpegに必須オプション %s が含まれていません。\n' "$required_option" >&2
        exit 1
    fi
done
for required_encoder in libx264 libfdk_aac; do
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
