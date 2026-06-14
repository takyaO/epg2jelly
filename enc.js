#!/usr/bin/env node
const FORCE_CODEC = ''; // 手動で固定したい場合はここに書く（ h264_qsv, h264_vaapi, libx264 から選択）
                                 // 自動判定に戻したいときは null にする
// モジュールの読み込み
const { spawn } = require('child_process');
const { execFileSync } = require('child_process');
const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os'); // 一時ファイル用

// --- tsreadex 関連 helper 関数群 ---

/**
 * PATH上に tsreadex が存在するかチェック
 */
function checkTsreadexAvailability() {
    try {
        // 'tsreadex -h' で終了コード0かどうか確認
        const result = spawnSync('tsreadex', ['-h'], {
            stdio: ['ignore', 'ignore', 'ignore'],
            shell: false
        });
        return result.status === 0 || result.error === undefined;
    } catch (e) {
        return false;
    }
}

/**
 * ffprobeでTSファイルを解析し、Program数とVideo Stream数を取得
 * @param {string} filePath 
 * @returns {Object} { programCount, videoStreamCount, targetProgramId, needsTsreadex }
 */
function analyzeTsStructure(filePath) {
    try {
        const probeArgs = [
            '-show_programs',
            '-show_streams',
            '-print_format', 'json',
            ...getAnalyze(),
            filePath
        ];
        const stdout = execFileSync(getEnv('FFPROBE'), probeArgs, { encoding: 'utf8', maxBuffer: 1024 * 1024 * 10 });
        const data = JSON.parse(stdout);

        let programCount = 0;
        let targetProgramId = null;
        
        // Program 単位での解析
        if (data.programs && Array.isArray(data.programs)) {
            programCount = data.programs.length;
            
            // 対象Program決定: 映像ストリームを含む最初のProgramを選択
            // (通常、録画対象のサービスが該当する)
            for (const prog of data.programs) {
                const hasVideo = prog.streams && prog.streams.some(s => s.codec_type === 'video');
                if (hasVideo && targetProgramId === null) {
                    targetProgramId = prog.program_id;
                }
            }
        }

        // 全体のVideo Stream数 (Program関係なく、TS内の全Video PID数)
        // streams がトップレベルにある場合も考慮
        let videoStreamCount = 0;
        const allStreams = data.streams || [];
        
        // programs配下のstreamsも含めてカウント
        if (data.programs) {
            data.programs.forEach(p => {
                if (p.streams) allStreams.push(...p.streams);
            });
        }
        
        const uniqueVideoIndices = new Set();
        allStreams.forEach(s => {
            if (s.codec_type === 'video' && s.index !== undefined) {
                if (!uniqueVideoIndices.has(s.index)) {
                    uniqueVideoIndices.add(s.index);
                    videoStreamCount++;
                }
            }
        });

        // 判定ロジック: 
        // 1. Programが複数存在する
        // 2. または、Video Streamが複数存在する (同一TS内に別サービスの映像PIDが含まれている可能性)
        const needsTsreadex = (programCount > 1) || (videoStreamCount > 1);

        return {
            programCount,
            videoStreamCount,
            targetProgramId, // number | null
            needsTsreadex
        };

    } catch (err) {
        console.error('Error analyzing TS structure:', err.message);
        // 解析失敗時は安全側に倒して tsreadex を使わない（従来通り）
        return { programCount: 1, videoStreamCount: 1, targetProgramId: null, needsTsreadex: false };
    }
}

/**
 * tsreadex を実行してクリーンなTSを生成
 * @param {string} inputPath 
 * @param {number} programId 
 * @param {string} outputPath 
 */
function executeTsreadex(inputPath, programId, outputPath) {
    console.log(`Executing tsreadex: program_id=${programId}, output=${outputPath}`);
    
    let outFd;
    try {
        outFd = fs.openSync(outputPath, 'w');
        
        const result = spawnSync('tsreadex', 
            ['-n', programId.toString(), inputPath], 
            {
                stdio: ['ignore', outFd, 'pipe'], // stdoutをファイルに、stderrはメモリに
                timeout: 600000 // 10分タイムアウト (大きなファイル用)
            }
        );
        
        if (result.status !== 0) {
            const errMsg = result.stderr ? result.stderr.toString() : 'Unknown error';
            throw new Error(`tsreadex exited with code ${result.status}: ${errMsg}`);
        }
        
        console.log('tsreadex completed successfully.');
        
    } catch (err) {
        // 失敗したら中途半端なファイルを削除
        try { fs.unlinkSync(outputPath); } catch(e){}
        throw err;
    } finally {
        if (outFd !== undefined) fs.closeSync(outFd);
    }
}

// --- 既存の helper 関数 (変更なし or 軽微な修正) ---

// コマンドライン引数の解析
const args = process.argv.slice(2);
// 新しいオプションフラグ
let ignoreTags = false;
let splitTracks = false;
let inputFile = null;
let jsonFilePath = null;
let audioComponentType = '0';
// オプション引数の解析（最初にオプションを処理）
const nonOptionArgs = [];
for (let i = 0; i < args.length; i++) {
    if (args[i] === '--ignore-tags') {
        ignoreTags = true;
    } else if (args[i] === '--split-tracks') {
        splitTracks = true;
    } else {
        nonOptionArgs.push(args[i]);
    }
}
// 非オプション引数の解析
if (nonOptionArgs.length > 0) {
    inputFile = nonOptionArgs[0];
}
if (nonOptionArgs.length > 1) {
    // 第2引数がJSONファイルかaudioComponentTypeかを判定
    const secondArg = nonOptionArgs[1];
    if (secondArg.endsWith('.json')) {
        jsonFilePath = secondArg;
    } else {
        audioComponentType = secondArg;
    }
}
let metadataDescription = null;
let metadataTitle = null;
let metadataDate = null;
let metadataGenre = null;
// ジャンル分類表(ARIB STD-B10)
const genreMap = {
    0: "ニュース／報道",
    1: "スポーツ",
    2: "情報／ワイドショー",
    3: "ドラマ",
    4: "音楽",
    5: "バラエティ",
    6: "映画",
    7: "アニメ／特撮",
    8: "ドキュメンタリー／教養",
    9: "劇場／公演",
    10: "趣味／教育",
    11: "福祉",
    12: "予備（未使用・その他）",
    13: "予備（未使用・その他）",
    14: "予備（未使用・その他）",
    15: "予備（未使用・その他）"
};
const subGenreMap = {
    0: "一般",
    1: "天気",
    2: "特集／ドキュメント",
    3: "解説",
    4: "討論",
    5: "会見",
    6: "特別番組",
    7: "その他"
};
// JSONファイルが指定された場合の処理
if (jsonFilePath && fs.existsSync(jsonFilePath)) {
    try {
        const fileContent = fs.readFileSync(jsonFilePath, 'utf8').trim();

        // ファイルが空でない場合のみ処理
        if (fileContent) {
            const jsonData = JSON.parse(fileContent);

            // audioComponentTypeの取得
            if (jsonData.audioComponentType !== undefined) {
                audioComponentType = jsonData.audioComponentType.toString();
            }

            // 概要メタデータの生成
            const description = jsonData.description || '';
            const extended = jsonData.extended || '';
            if (description || extended) {
                metadataDescription = [description, extended].filter(Boolean).join('\n');
                console.log('Metadata description will be added:', metadataDescription);
            }

            // タイトルメタデータの生成
            if (jsonData.name) {
                metadataTitle = jsonData.name;
                console.log('Metadata title will be added:', metadataTitle);
            }

            // 日付メタデータの生成
            if (jsonData.startAt) {
                const date = new Date(jsonData.startAt);
                metadataDate = date.toISOString().split('T')[0]; // YYYY-MM-DD形式
                console.log('Metadata date will be added:', metadataDate);
            }
    // ジャンルメタデータの生成
    const genres = [];
    console.log('Genre data from JSON:', {
genre1: jsonData.genre1,
subGenre1: jsonData.subGenre1,
genre2: jsonData.genre2,
subGenre2: jsonData.subGenre2,
genre3: jsonData.genre3,
subGenre3: jsonData.subGenre3
    });

    for (let i = 1; i <= 3; i++) {
const genreKey = `genre${i}`;
const subGenreKey = `subGenre${i}`;

console.log(`Processing ${genreKey}:`, jsonData[genreKey], `${subGenreKey}:`, jsonData[subGenreKey]);

// genreがundefinedまたはnullでない場合に処理（0は有効な値）
if (jsonData[genreKey] !== undefined && jsonData[genreKey] !== null) {
    const mainGenre = genreMap[jsonData[genreKey]] || `ジャンル${jsonData[genreKey]}`;
    const subGenre = (jsonData[subGenreKey] !== undefined && jsonData[subGenreKey] !== null)
  ? (jsonData[subGenreKey] !== 0 ? subGenreMap[jsonData[subGenreKey]] || `サブジャンル${jsonData[subGenreKey]}` : null)
  : null;

    const genreText = subGenre ? `${mainGenre} - ${subGenre}` : mainGenre;
    genres.push(genreText);
    console.log(`Added genre: ${genreText}`);
} else {
    console.log(`Skipping ${genreKey} - undefined or null`);
}
    }
    if (genres.length > 0) {
metadataGenre = genres.join(' / ');
console.log('Final metadata genre:', metadataGenre);
    } else {
console.log('No valid genres found');
    }
            if (genres.length > 0) {
                metadataGenre = genres.join(' / ');
                console.log('Metadata genre will be added:', metadataGenre);
            }

            console.log('Using JSON config - audioComponentType:', audioComponentType);
        } else {
            console.log('JSON file is empty, using legacy mode');
            // 空の場合は従来の動作: 第2引数がaudio_component_type
            audioComponentType = nonOptionArgs[1] || '0';
        }
    } catch (error) {
        console.error('Error parsing JSON file:', error.message);
        console.log('Fallback to legacy mode due to JSON parse error');
        // エラー時は従来の動作: 第2引数がaudio_component_type
        audioComponentType = nonOptionArgs[1] || '0';
    }
} else if (jsonFilePath) {
    console.error(`Error: JSON file not found: ${jsonFilePath}`);
    process.exit(1);
} else {
    // 従来の動作: 第2引数がaudio_component_type
    console.log('Using legacy mode - audioComponentType:', audioComponentType);
}
if (!inputFile) {
    console.error('Usage: node enc.js [--ignore-tags] [--split-tracks] <input_file_path> [input_file.json|audio_component_type]');
    console.error('Example: node enc.js /path/to/番組名.m2ts input_file.json');
    console.error('Example with options: node enc.js --ignore-tags --split-tracks /path/to/番組名.m2ts');
    console.error('Legacy: node enc.js /path/to/番組名.m2ts 2');
    process.exit(1);
}
// 入力ファイルの存在確認
if (!fs.existsSync(inputFile)) {
    console.error(`Error: Input file not found: ${inputFile}`);
    process.exit(1);
}
// 出力ファイル名の生成（カレントディレクトリに出力）
const inputFileName = path.parse(inputFile).name;
const outputFile = `./${inputFileName}.mp4`;
// 固定設定
const epgsConfig = {
    recordedFileExtension: '.m2ts'
};
// エンコード設定
const ffmpegLogOutOnlyOnError = true;
const progressLogOutMax = 0; // 進捗表示を無効化
// 固定で3秒カット
const fixedCutSecond = 3;
// 環境変数代替関数
function getEnv(variableName) {
    const envs = {
        INPUT: inputFile,
        OUTPUT: outputFile,
        NAME: inputFileName,
        AUDIOCOMPONENTTYPE: audioComponentType,
        FFMPEG: 'ffmpeg',
        FFPROBE: 'ffprobe'
    };
    return envs[variableName];
}

// --- 不要な字幕関連関数は削除 ---
// checkLibaribb24Availability, detectAllSubtitleStreams, getSubTitlesArg は削除済み

// libfdk_aacの利用可能性をチェック
function checkLibfdkAacAvailability() {
    try {
        // エンコーダーリストを確認
        const encodersOptions = ['-encoders'];
        const encodersResult = execFileSync(getEnv('FFMPEG'), encodersOptions, { encoding: 'utf8' });
        const hasLibfdkAac = encodersResult.includes('libfdk_aac') && encodersResult.includes('AAC');

        console.log(`libfdk_aac detection - Encoders: ${hasLibfdkAac}`);

        return hasLibfdkAac;
    } catch (error) {
        console.error('Error checking libfdk_aac availability:', error.message);
        return false;
    }
}
// 利用可能な音声コーデックを決定
function getAudioCodec() {
    const hasLibfdkAac = checkLibfdkAacAvailability();
    const audioCodec = hasLibfdkAac ? 'libfdk_aac' : 'aac';
    console.log(`Using audio codec: ${audioCodec}`);
    return audioCodec;
}
function getVideoCodec() {
    // 1. まず手動設定（FORCE_CODEC）があるか確認
    if (FORCE_CODEC) {
        console.log(`Manual override: Using ${FORCE_CODEC}`);
        return FORCE_CODEC;
    }
    // 2. QSVのチェック
    const hasH264Qsv = checkH264QsvAvailability();
    if (hasH264Qsv) {
        console.log('Using h264_qsv video codec');
        return 'h264_qsv';
    }
    // 3. VA-APIのチェック
    const hasH264Vaapi = checkH264VaapiAvailability();
    if (hasH264Vaapi) {
        console.log('Using h264_vaapi video codec');
        return 'h264_vaapi';
    }
    // 4. Fallback
    console.log('Hardware codecs not available/not forced, using libx264');
    return 'libx264';
}
function checkH264QsvAvailability() {
    try {
        // エンコーダーリストを確認
        const encodersOptions = ['-encoders'];
        const encodersResult = execFileSync(getEnv('FFMPEG'), encodersOptions, { encoding: 'utf8' });
        const hasH264Qsv = encodersResult.includes('h264_qsv') && encodersResult.includes('H.264');
        console.log(`h264_qsv detection - Encoders: ${hasH264Qsv}`);
        // ハードウェアデバイスの可用性もチェック
        if (hasH264Qsv) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasQsvHwaccel = hwaccelResult.includes('qsv');
                console.log(`h264_qsv hardware acceleration available: ${hasQsvHwaccel}`);
                // ハードウェアアクセラレーションがない場合は利用不可と判断
                if (!hasQsvHwaccel) {
                    console.log('h264_qsv encoder exists but no QSV hardware acceleration available');
                    return false;
                }

                // QSVデバイスの確認（より詳細なチェック）- フレーム数制限を追加
                try {
                    const devicesResult = execFileSync(getEnv('FFMPEG'), [
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1', // 0.1秒の短いテスト
                        '-c:v', 'h264_qsv',
                        '-frames:v', '1', // 1フレームのみ
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 10000 // 10秒タイムアウト
                    });
                    console.log('h264_qsv device test passed');
                    return true;
                } catch (testError) {
                    console.log('h264_qsv device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                console.log('Could not verify QSV hardware acceleration, assuming h264_qsv is not available');
                return false;
            }
        }
        return false;
    } catch (error) {
        console.error('Error checking h264_qsv availability:', error.message);
        return false;
    }
}
function checkH264VaapiAvailability() {
    try {
        // エンコーダーリストを確認
        const encodersOptions = ['-encoders'];
        const encodersResult = execFileSync(getEnv('FFMPEG'), encodersOptions, { encoding: 'utf8' });
       const hasH264Vaapi = encodersResult.includes('h264_vaapi') && encodersResult.includes('H.264');
        console.log(`h264_vaapi detection - Encoders: ${hasH264Vaapi}`);
        // ハードウェアデバイスの可用性もチェック
        if (hasH264Vaapi) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasVaapiHwaccel = hwaccelResult.includes('vaapi');
                console.log(`h264_vaapi hardware acceleration available: ${hasVaapiHwaccel}`);
                if (!hasVaapiHwaccel) {
                    console.log('h264_vaapi encoder exists but no VAAPI hardware acceleration available');
                    return false;
                }

                // VAAPIデバイスの確認（より詳細なチェック）- フレーム数制限を追加
                try {
                    const testResult = execFileSync(getEnv('FFMPEG'), [
                        '-init_hw_device', 'vaapi=va:',
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1',
                        '-vf', 'format=nv12,hwupload',
                        '-c:v', 'h264_vaapi',
                        '-frames:v', '1',
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 10000 // 10秒タイムアウト
                    });
                    console.log('h264_vaapi device test passed');
                    return true;
                } catch (testError) {
                    console.log('h264_vaapi device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                console.log('Could not verify VAAPI hardware acceleration, assuming h264_vaapi is not available');
                return false;
            }
        }
        return false;
    } catch (error) {
        console.error('Error checking h264_vaapi availability:', error.message);
        return false;
    }
}

// 補助関数
function isTs() {
    const reg = new RegExp(epgsConfig.recordedFileExtension + '$');
    return (getEnv('INPUT').match(reg) !== null)
}
function getAnalyze() {
    return ['-analyzeduration', '100M', '-probesize', '100M']; // 10Mから100Mに変更
}
function getFFprobe(showOptions) {
    try {
        const options = [].concat(getAnalyze(), '-v', '0', showOptions, '-of', 'json',  getEnv('INPUT'));
        const stdout = execFileSync(getEnv('FFPROBE'), options);
        return JSON.parse(stdout);
    } catch (error) {
        console.error('getFFprobe error:', error.message);
        return null;
    }
}
function convertTimeToSec(time) {
    const times = time.split(':');
    return parseFloat(times[0]) * 3600 + parseFloat(times[1]) * 60 + parseFloat(times[2]);
}
function convertSecToTime(second) {
    const date = new Date(0);
    date.setSeconds(second);
    return date.toISOString().substring(11, 19);
}
// 音声ストリームの詳細情報を取得する関数
function getAudioStreamDetails() {
    try {
        const options = [
            ...getAnalyze(),
            '-v', 'error',
            '-select_streams', 'a',
            '-show_entries', 'stream=index,codec_name,channels,bit_rate,sample_rate,tags:stream_tags=language,title:stream_tags=title',
            '-of', 'json',
            getEnv('INPUT')
        ];

        const result = execFileSync(getEnv('FFPROBE'), options, { encoding: 'utf8' });
        const info = JSON.parse(result);
        const audioStreams = [];

        if (info.streams && info.streams.length > 0) {
            console.log('All audio streams with details:');
            for (const stream of info.streams) {
                const streamInfo = {
                    index: stream.index,
                    codec: stream.codec_name,
                    channels: stream.channels,
                    bitrate: stream.bit_rate,
                    sampleRate: stream.sample_rate,
                    language: (stream.tags && stream.tags.language) ? stream.tags.language : null,
                    title: (stream.tags && stream.tags.title) ? stream.tags.title : null
                };
                audioStreams.push(streamInfo);
                console.log(`  Stream #${streamInfo.index}: ${streamInfo.codec}, ${streamInfo.channels}ch, ${streamInfo.bitrate}bps, lang=${streamInfo.language}, title=${streamInfo.title}`);
            }
        }

        return audioStreams;
    } catch (error) {
        console.error('Error getting audio stream details:', error.message);
        return [];
    }
}
// メイン音声ストリームを特定する関数
function findMainAudioStream(audioStreams) {
    if (audioStreams.length === 0) return null;

    // まずは言語タグが日本語のストリームを探す
    const japaneseStream = audioStreams.find(stream =>
        stream.language && (stream.language === 'jpn' || stream.language === 'ja'));

    if (japaneseStream) {
        console.log(`Found Japanese audio stream: ${japaneseStream.index}`);
        return japaneseStream;
    }

    // 次にタイトルから判断
    const mainByTitle = audioStreams.find(stream =>
        stream.title && (stream.title.includes('主') || stream.title.includes('メイン') ||
                        stream.title.includes('main') || stream.title.includes('primary')));

    if (mainByTitle) {
        console.log(`Found main audio stream by title: ${mainByTitle.index} (${mainByTitle.title})`);
        return mainByTitle;
    }

    // どれもなければ最初のストリームをメインとする
    console.log(`Using first audio stream as main: ${audioStreams[0].index}`);
    return audioStreams[0];
}
// 音声の設定を取得する関数
function getAudioArgs(audioCodec) {
    const fileName = getEnv('NAME');
    const audioComponentType = parseInt(getEnv('AUDIOCOMPONENTTYPE'), 10);
    const isDualMono = audioComponentType == 2;
    const isBilingual = /\[二\]/.test(fileName);
    const isExplanation = /\[解\]/.test(fileName);
    const isMultiAudio = /\[多\]/.test(fileName);
    const isSecondary = /\[副\]/.test(fileName);
    const args = [];

    console.log('Audio component type:', audioComponentType, 'isDualMono:', isDualMono,
                'isBilingual:', isBilingual, 'isExplanation:', isExplanation,
                'isMultiAudio:', isMultiAudio, 'isSecondary:', isSecondary,
                'audioCodec:', audioCodec, 'ignoreTags:', ignoreTags);
    // 音声ストリームの詳細情報を取得
    const audioStreams = getAudioStreamDetails();

    if (audioStreams.length === 0) {
        console.error('No audio streams found!');
        return { args: [] };
    }
    // 音声多重放送(デュアルモノ) - audioComponentTypeが2の場合のみ処理
    if (isDualMono && audioStreams.length >= 1) {
        console.log('Processing as dual mono');
        const mainStreamIndex = audioStreams[0].index;
        // 左右チャンネルを分割して2つのモノラルストリームを作成
        args.push('-filter_complex', `[0:${mainStreamIndex}]channelsplit=channel_layout=stereo[left][right]`);
        // 左チャンネル（日本語）
        args.push('-map', '[left]');
        // 右チャンネル（英語）
        args.push('-map', '[right]');
        // メタデータ設定（日本語→英語の順序）
        args.push('-metadata:s:a:0', 'language=jpn');
        args.push('-metadata:s:a:1', 'language=eng');
        // 音声エンコード設定（選択されたコーデックを使用）
        args.push('-c:a', audioCodec);
        args.push('-b:a:0', '192k');
        args.push('-b:a:1', '192k');
        args.push('-ac:0', '1');
        args.push('-ac:1', '1');
        return { args: args };
    }
    // ignoreTagsがtrueの場合はメイン音声のみマップ
    if (ignoreTags) {
        console.log('Ignore tags mode: mapping only main audio stream');

        // メイン音声ストリームを特定
        const mainAudioStream = findMainAudioStream(audioStreams);
        if (mainAudioStream) {
            args.push('-map', `0:${mainAudioStream.index}?`);
            args.push(`-metadata:s:a:0`, `language=jpn`);
            console.log(`Mapping only main audio stream: ${mainAudioStream.index}`);

            // 音声エンコード設定
            args.push('-c:a', audioCodec);
            args.push('-b:a', '192k');
            args.push('-ac', '2');
        }
        return { args: args };
    }
    // 音声タグがない場合はメイン音声ストリームのみマップ
    const shouldMapAllAudio = isBilingual || isExplanation || isMultiAudio || isSecondary;

    if (!shouldMapAllAudio) {
        console.log('No audio tags ([二], [解], [多], [副]) found in filename, mapping only main audio stream');

        // メイン音声ストリームを特定
        const mainAudioStream = findMainAudioStream(audioStreams);
        if (mainAudioStream) {
            args.push('-map', `0:${mainAudioStream.index}?`);
            args.push(`-metadata:s:a:0`, `language=jpn`);
            console.log(`Mapping only main audio stream: ${mainAudioStream.index}`);

            // 音声エンコード設定
            args.push('-c:a', audioCodec);
            args.push('-b:a', '192k');
            args.push('-ac', '2');
        }
        return { args: args };
    }
    // 音声タグがある場合はすべての音声ストリームをマップ
    console.log('Audio tags found in filename, mapping all audio streams');

    // 言語の決定
    const languageMap = determineAudioLanguages(audioStreams, fileName);

    // 音声ストリームのマッピングと言語設定
    let audioIndex = 0;
    for (const stream of audioStreams) {
        args.push('-map', `0:${stream.index}?`);
        const lang = languageMap[stream.index] || 'jpn'; // デフォルトは日本語
        args.push(`-metadata:s:a:${audioIndex}`, `language=${lang}`);
        console.log(`Mapping audio stream ${stream.index} as audio track ${audioIndex} with language: ${lang}`);
        audioIndex++;
    }
    // 音声エンコード設定（選択されたコーデックを使用）
    args.push('-c:a', audioCodec);
    args.push('-b:a', '192k');
    args.push('-ac', '2');
    return { args: args };
}
// 音声ストリームの言語を推測する関数
function determineAudioLanguages(audioStreams, fileName) {
    const isBilingual = /\[二\]/.test(fileName);
    const isExplanation = /\[解\]/.test(fileName);
    const isMultiAudio = /\[多\]/.test(fileName);
    const isSecondary = /\[副\]/.test(fileName);

    const languageMap = {};

    console.log('Determining audio languages:', { isBilingual, isExplanation, isMultiAudio, isSecondary });

    // 既存の言語タグを確認
    for (const stream of audioStreams) {
        if (stream.language) {
            languageMap[stream.index] = stream.language;
            console.log(`Stream ${stream.index} has explicit language tag: ${stream.language}`);
        }
    }

    // ストリームタイトルから言語を推測
    for (const stream of audioStreams) {
        if (!languageMap[stream.index] && stream.title) {
            const title = stream.title.toLowerCase();
            if (title.includes('eng') || title.includes('english') || title.includes('英語')) {
                languageMap[stream.index] = 'eng';
                console.log(`Stream ${stream.index} title suggests English: ${stream.title}`);
            } else if (title.includes('jpn') || title.includes('japanese') || title.includes('日本語') || title.includes('主') || title.includes('メイン')) {
                languageMap[stream.index] = 'jpn';
                console.log(`Stream ${stream.index} title suggests Japanese: ${stream.title}`);
            } else if (title.includes('副') || title.includes('解説') || title.includes('comm') || title.includes('comment')) {
                // 副音声や解説は日本語と推測
                languageMap[stream.index] = 'jpn';
                console.log(`Stream ${stream.index} title suggests Japanese (secondary): ${stream.title}`);
            }
        }
    }

    // 言語タグがない場合の推測ロジック
    const untaggedStreams = audioStreams.filter(stream => !languageMap[stream.index]);

    if (untaggedStreams.length > 0) {
        if (isBilingual && audioStreams.length >= 2) {
            // [二]がある場合：最初のストリームを日本語、2番目を英語と推測
            // ただし、既に言語が設定されているストリームを考慮
            const mainStream = untaggedStreams.find(stream => stream.index === Math.min(...untaggedStreams.map(s => s.index)));
            const secondaryStream = untaggedStreams.find(stream => stream.index === Math.max(...untaggedStreams.map(s => s.index)));

            if (mainStream) languageMap[mainStream.index] = 'jpn';
            if (secondaryStream && secondaryStream !== mainStream) languageMap[secondaryStream.index] = 'eng';

            console.log('Bilingual content: assuming lower index stream is Japanese, higher index is English');
        } else {
            // その他の場合：すべて日本語と推測
            for (const stream of untaggedStreams) {
                languageMap[stream.index] = 'jpn';
            }
            console.log('Assuming all untagged streams are Japanese');
        }
    }

    return languageMap;
}

// --- メイン処理 (大きく変更) ---
(() => {
    const originalInputFile = inputFile; // 元のファイルパスを保存
    let tempCleanFile = null;
    let shouldDeleteTemp = false;

    // 1. TSファイルの場合、構造解析を行う
    if (isTs()) {
        console.log('Analyzing TS structure...');
        const analysis = analyzeTsStructure(originalInputFile);
        
        console.log(`TS Analysis: Programs=${analysis.programCount}, Videos=${analysis.videoStreamCount}, TargetPID=${analysis.targetProgramId}, NeedsTsreadex=${analysis.needsTsreadex}`);
        
        // 2. tsreadex が必要か判定
        if (analysis.needsTsreadex) {
            // 3. tsreadex の存在確認
            if (!checkTsreadexAvailability()) {
                console.error('ERROR: Install tsreadex. このTSはマルチサービスTSのためtsreadexが必要なのでインストールしてください');
                process.exit(1);
            }
            
            // 4. 一時ファイル生成と tsreadex 実行
            try {
                const tempDir = os.tmpdir();
                const baseName = path.basename(originalInputFile, path.extname(originalInputFile));
                tempCleanFile = path.join(tempDir, `${baseName}_${process.pid}_clean.ts`);
                
                if (!analysis.targetProgramId) {
                    throw new Error('Target program_id could not be determined from TS structure.');
                }
                
                executeTsreadex(originalInputFile, analysis.targetProgramId, tempCleanFile);
                
                // 成功したら入力ファイルを差し替え
                inputFile = tempCleanFile;
                shouldDeleteTemp = true;
                console.log(`Switched input to cleaned TS: ${inputFile}`);
                
            } catch (err) {
                console.error('tsreadex processing failed:', err.message);
                // 失敗時は元のファイルで続行すべきか、それとも終了すべきか？
                // 仕様上「処理を終了」が適切（中途半端なクリーンアップを防ぐため）
                process.exit(1);
            }
        }
    }

    // ここから先は、inputFile が tsreadex 経由の場合クリーンなTSを指し示している
    // getEnv('INPUT') は inputFile を参照するので、既存の解析関数は全てクリーンなTSを見る

    const useCodec = getVideoCodec();
    console.log(`Final video codec selection: ${useCodec}`);

    const useCodecPreArgs = [];
    const useCodecPostArgs = [];
    if (useCodec === 'h264_qsv') {
        useCodecPreArgs.push('-fflags', '+genpts');
        useCodecPostArgs.push('-vf', 'yadif'); //cmcutで最適
        useCodecPostArgs.push('-r', '30000/1001');
        useCodecPostArgs.push('-aspect', '16:9');
        useCodecPostArgs.push('-preset', 'slow');
        useCodecPostArgs.push('-global_quality', '21');
        useCodecPostArgs.push('-profile:v', 'high');
        useCodecPostArgs.push('-level', '4.2');
//        useCodecPostArgs.push('-look_ahead', '1');
        useCodecPostArgs.push('-extbrc', '1');
        useCodecPostArgs.push('-b_strategy', '1');
//        useCodecPostArgs.push('-threads', '10');
    } else if (useCodec === 'libx264') {
        useCodecPreArgs.push('-fflags', '+genpts');
        useCodecPostArgs.push('-vf', 'yadif');
        useCodecPostArgs.push('-preset', 'slow');
        useCodecPostArgs.push('-crf', '23');
    } else if (useCodec === 'h264_vaapi') {
        useCodecPreArgs.push('-hwaccel', 'vaapi');
        useCodecPreArgs.push('-hwaccel_device', '/dev/dri/renderD128');
        //deinterlace option 1
        useCodecPreArgs.push('-hwaccel_output_format', 'vaapi'); // これによりVRAM直結になる
        useCodecPostArgs.push('-vf', 'deinterlace_vaapi,scale_vaapi=w=1280:h=720');
        useCodecPostArgs.push('-r', '30000/1001');
        useCodecPostArgs.push('-aspect', '16:9');
        // 画質設定：yadifの精度を活かすために ICQ モードを使用
        useCodecPostArgs.push('-rc_mode', 'ICQ');
        useCodecPostArgs.push('-global_quality', '20'); // x264のCRF23相当なら20〜21あたりが目安
        useCodecPostArgs.push('-profile:v', 'high');
        useCodecPostArgs.push('-level', '4.2');
        useCodecPostArgs.push('-compression_level', '1'); // 最高圧縮設定
    }

    // 音声コーデックを決定
    const audioCodec = getAudioCodec();

    // 字幕関連処理は削除 (仕様に基づき)
    // const hasLibaribb24 = checkLibaribb24Availability(); 
    // const sub = getSubTitlesArg(hasLibaribb24);
    
    const audio = getAudioArgs(audioCodec);

    // 固定で3秒カット
    const cutSecond = fixedCutSecond;
    const ss = cutSecond > 0 ? ['-ss', cutSecond.toString()] : [];

    // メタデータ引数の準備
    const metadataArgs = [];
    if (metadataDescription) {
        // メタデータの改行をスペースに置換して問題を回避
        const cleanDescription = metadataDescription.replace(/\n/g, ' ');
        metadataArgs.push('-metadata', `description=${cleanDescription}`);
    }
    if (metadataTitle) {
        metadataArgs.push('-metadata', `title=${metadataTitle}`);
    }
    if (metadataDate) {
        metadataArgs.push('-metadata', `date=${metadataDate}`);
    }
    if (metadataGenre) {
        metadataArgs.push('-metadata', `genre=${metadataGenre}`);
    }

    // FFmpeg引数の組み立て (字幕マップを削除)
    let outputArgs;

    // 字幕なしシンプル版（仕様より）
    outputArgs = [
        '-y',
        ...getAnalyze(),
        ...useCodecPreArgs,  // 入力ファイルの前に追加
        ...ss,
        '-i', getEnv('INPUT'),
        '-map', '0:0',       // Video
        '-c:v', useCodec,
        ...audio.args,       // Audio maps (-map 0:x ...) and codec settings
        ...useCodecPostArgs, // 入力ファイルの後に追加
        ...metadataArgs,     // メタデータを追加
        // --- 字幕関連オプション削除 ---
        getEnv('OUTPUT')
    ];

    console.log('Input file:', getEnv('INPUT'));
    console.log('Output file:', getEnv('OUTPUT'));
    console.log('FFmpeg command:', 'ffmpeg', outputArgs.join(' '));

    // 実行処理
    const durationInfo = getFFprobe('-show_format');
    const duration = durationInfo && durationInfo.format ? durationInfo.format.duration : 0;
    const startTime = process.uptime();
    const logBuffers = [];
    
    const child = spawn(getEnv('FFMPEG'), outputArgs, {
        stdio: ['ignore', 'pipe', 'pipe']
    });
    
    // 標準出力も捕捉
    child.stdout.on('data', data => {
        logBuffers.push(String(data).trim());
    });
    child.stderr.on('data', data => {
        const dataStr = String(data);
        if (!dataStr.startsWith('frame=')) {
            logBuffers.push(dataStr.trim());
        }
    });
    
    child.on('exit', code => {
        const isError = code !== 0;

        if (!ffmpegLogOutOnlyOnError || isError) {
            console.log('FFmpeg messages:', logBuffers.join('\n'));
        }
        
        const elapsed = parseFloat(process.uptime() - startTime);
        const logs = {
            outputArgs: outputArgs.join(' '),
            duration: convertSecToTime(duration),
            elapsedTime: convertSecToTime(elapsed),
            averageSpeed: duration > 0 ? Math.floor(duration / elapsed) + 'x' : 'N/A',
            useCodec, cutSecond,
            tsreadexUsed: shouldDeleteTemp,
            metadataIncluded: metadataArgs.length > 0,
            audioCodec: audioCodec,
            ignoreTags: ignoreTags
        };

        if (isError) {
            console.error('Error code:' + code, logs);
        } else {
            console.log('Successfully encoded:', logs);
        }
        
        // 6. 後処理: 一時ファイル削除
        if (shouldDeleteTemp && tempCleanFile) {
            try {
                fs.unlinkSync(tempCleanFile);
                console.log(`Cleaned up temporary file: ${tempCleanFile}`);
            } catch (e) {
                console.error(`Failed to delete temp file ${tempCleanFile}:`, e.message);
            }
        }
        
        process.exit(code);
    });
    
    child.on('error', error => {
        console.error('Spawn error:', error);
        
        // エラー時も一時ファイル削除を試みる
        if (shouldDeleteTemp && tempCleanFile) {
            try { fs.unlinkSync(tempCleanFile); } catch(e){}
        }
        
        process.exit(1);
    });
    
    process.on('SIGINT', () => {
        child.kill('SIGINT');
        // SIGINT時も一時ファイル削除を試みる
        if (shouldDeleteTemp && tempCleanFile) {
            try { fs.unlinkSync(tempCleanFile); } catch(e){}
        }
    });
    
})();
// https://note.com/leal_walrus5520/n/nb560315013e3
// Time stamp: 2026/06/14
