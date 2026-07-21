#!/usr/bin/env node
// ffmpeg codec
const FORCE_CODEC = ''; 
// 手動で固定したい場合はここに書く（hevc_qsv, hevc_vaapi, h264_qsv, h264_vaapi, libx264 から選択
// 空 '' にすると自動判定
// ffmpeg オプションは useCodecPreArgs, useCodecPostArgs.push

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
* ffprobeでTSファイルを解析し、Video Stream数でtsreadex必要性を判定
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
        const stdout = execFileSync(getEnv('FFPROBE'), probeArgs, { encoding: 'utf8', maxBuffer: 1024 * 1024 * 10, stdio: ['ignore', 'pipe', 'ignore'] });
        const data = JSON.parse(stdout);
        const allStreams = data.streams || [];
        const videoStreams = allStreams.filter(s => s.codec_type === 'video');
        const videoStreamCount = videoStreams.length;
        console.log(`Detected ${videoStreamCount} video stream(s) in TS`);
        const needsTsreadex = videoStreamCount >= 2;
        let targetProgramId = null;
        if (data.programs && Array.isArray(data.programs)) {
            for (const prog of data.programs) {
                const progStreams = prog.streams || [];
                const hasVideo = progStreams.some(s => s.codec_type === 'video');
                if (hasVideo && targetProgramId === null) {
                    targetProgramId = prog.program_id;
                    break;
                }
            }
        }
        if (!targetProgramId && videoStreamCount > 0) {
            console.warn('Could not determine program_id from ffprobe output, tsreadex may fail');
        }
        return { videoStreamCount, targetProgramId, needsTsreadex };
    } catch (err) {
        console.error('Error analyzing TS structure:', err.message);
        return { videoStreamCount: 1, targetProgramId: null, needsTsreadex: false };
    }
}

/**
* tsreadex を実行してクリーンなTSを生成
*/
function executeTsreadex(inputPath, programId, outputPath) {
    console.log(`Executing tsreadex: program_id=${programId}, output=${outputPath}`);
    let outFd;
    try {
        outFd = fs.openSync(outputPath, 'w');
        const result = spawnSync('tsreadex',
            ['-n', programId.toString(), inputPath],
            {
                stdio: ['ignore', outFd, 'pipe'],
                timeout: 600000
            }
        );
        if (result.status !== 0) {
            const errMsg = result.stderr ? result.stderr.toString() : 'Unknown error';
            throw new Error(`tsreadex exited with code ${result.status}: ${errMsg}`);
        }
        console.log('tsreadex completed successfully.');
    } catch (err) {
        try { fs.unlinkSync(outputPath); } catch(e){}
        throw err;
    } finally {
        if (outFd !== undefined) fs.closeSync(outFd);
    }
}

// コマンドライン引数の解析
const args = process.argv.slice(2);
let ignoreTags = false;
let inputFile = null;
let jsonFilePath = null;
let audioComponentType = '0';
let chapterFilePath = null;  // chap_out.txt
let trimFilePath = null;     // trim.txt

// オプション引数の解析
const nonOptionArgs = [];
for (let i = 0; i < args.length; i++) {
    if (args[i] === '--ignore-tags') {
        ignoreTags = true;
    } else {
        nonOptionArgs.push(args[i]);
    }
}

// 非オプション引数の解析（新しい順序: input [json|type] [chap_out.txt] [trim.txt]）
if (nonOptionArgs.length > 0) {
    inputFile = nonOptionArgs[0];
}

if (nonOptionArgs.length > 1) {
    const secondArg = nonOptionArgs[1];
    if (secondArg.endsWith('.json')) {
        jsonFilePath = secondArg;
    } else {
        audioComponentType = secondArg;
    }
}

if (nonOptionArgs.length > 2) {
    // 第3引数は chap_out.txt または trim.txt（後方互換性のため判定）
    const thirdArg = nonOptionArgs[2];
    // trim.txt を検出（Trim( が含まれるか、.txt で chap を含まない）
    if (thirdArg.match(/Trim\s*\(/) || (thirdArg.endsWith('.txt') && !thirdArg.includes('chap') && !thirdArg.includes('meta'))) {
        console.error('Error: trim.txt requires chap_out.txt as preceding argument');
        console.error('Usage: enc.js input.m2ts [metadata.json] [chap_out.txt] [trim.txt]');
        process.exit(1);
    } else {
        chapterFilePath = thirdArg;
        if (!fs.existsSync(chapterFilePath)) {
            console.error(`Error: Chapter file not found: ${chapterFilePath}`);
            process.exit(1);
        }
        console.log('Chapter file specified:', chapterFilePath);
    }
}

if (nonOptionArgs.length > 3) {
    // 第4引数は必ず trim.txt
    trimFilePath = nonOptionArgs[3];
    if (!fs.existsSync(trimFilePath)) {
        console.error(`Error: Trim file not found: ${trimFilePath}`);
        process.exit(1);
    }
    console.log('Trim mode enabled with file:', trimFilePath);
}

// メタデータ変数
let metadataDescription = null;
let metadataTitle = null;
let metadataDate = null;
let metadataGenre = null;
let metadataNetwork = null;

// ジャンル分類表(ARIB STD-B10)
const genreMap = {
    0: "ニュース／報道", 1: "スポーツ", 2: "情報／ワイドショー", 3: "ドラマ",
    4: "音楽", 5: "バラエティ", 6: "映画", 7: "アニメ／特撮",
    8: "ドキュメンタリー／教養", 9: "劇場／公演", 10: "趣味／教育",
    11: "福祉", 12: "予備（未使用・その他）", 13: "予備（未使用・その他）",
    14: "拡張", 15: "その他"
};

const subGenreMap = {
    0: { 0: "定時・総合", 1: "天気", 2: "特集・ドキュメント", 3: "政治・国会", 4: "経済・市況", 5: "海外・国際", 6: "解説", 7: "討論・会談", 8: "報道特番", 9: "ローカル・地域", 10: "交通", 15: "その他" },
    1: { 0: "スポーツニュース", 1: "野球", 2: "サッカー", 3: "ゴルフ", 4: "その他の球技", 5: "相撲・格闘技", 6: "オリンピック・国際大会", 7: "マラソン・陸上・水泳", 8: "モータースポーツ", 9: "マリン・ウィンタースポーツ", 10: "競馬・公営競技", 15: "その他" },
    2: { 0: "芸能・ワイドショー", 1: "ファッション", 2: "暮らし・住まい", 3: "健康・医療", 4: "ショッピング・通販", 5: "グルメ・料理", 6: "イベント", 7: "番組紹介・お知らせ", 15: "その他" },
    3: { 0: "国内ドラマ", 1: "海外ドラマ", 2: "時代劇", 15: "その他" },
    4: { 0: "国内ロック・ポップス", 1: "海外ロック・ポップス", 2: "クラシック・オペラ", 3: "ジャズ・フュージョン", 4: "歌謡曲・演歌", 5: "ライブ・コンサート", 6: "ランキング・リクエスト", 7: "カラオケ・のど自慢", 8: "民謡・邦楽", 9: "童謡・キッズ", 10: "民族音楽・ワールドミュージック", 15: "その他" },
    5: { 0: "クイズ", 1: "ゲーム", 2: "トークバラエティ", 3: "お笑い・コメディ", 4: "音楽バラエティ", 5: "旅バラエティ", 6: "料理バラエティ", 15: "その他" },
    6: { 0: "洋画", 1: "邦画", 2: "アニメ", 15: "その他" },
    7: { 0: "国内アニメ", 1: "海外アニメ", 2: "特撮", 15: "その他" },
    8: { 0: "社会・時事", 1: "歴史・紀行", 2: "自然・動物・環境", 3: "宇宙・科学・医学", 4: "カルチャー・伝統文化", 5: "文学・文芸", 6: "スポーツ", 7: "ドキュメンタリー全般", 8: "インタビュー・討論", 15: "その他" },
    9: { 0: "現代劇・新劇", 1: "ミュージカル", 2: "ダンス・バレエ", 3: "落語・演芸", 4: "歌舞伎・古典", 15: "その他" },
    10: { 0: "旅・釣り・アウトドア", 1: "園芸・ペット・手芸", 2: "音楽・美術・工芸", 3: "囲碁・将棋", 4: "麻雀・パチンコ", 5: "車・オートバイ", 6: "コンピュータ・TVゲーム", 7: "会話・語学", 8: "幼児・小学生", 9: "中学生・高校生", 10: "大学生・受験", 11: "生涯教育・資格", 12: "教育問題", 15: "その他" },
    11: { 0: "高齢者", 1: "障害者", 2: "社会福祉", 3: "ボランティア", 4: "手話", 5: "文字(字幕)", 6: "音声解説", 15: "その他" },
    14: { 0: "BS/地上デジタル放送用番組付属情報", 1: "広帯域CSデジタル放送用拡張", 3: "サーバー型番組付属情報", 4: "IP放送用番組付属情報" },
    15: { 15: "その他" }
};

// JSONファイルが指定された場合の処理
if (jsonFilePath && fs.existsSync(jsonFilePath)) {
    try {
        const fileContent = fs.readFileSync(jsonFilePath, 'utf8').trim();
        if (fileContent) {
            const jsonData = JSON.parse(fileContent);
            if (jsonData.audioComponentType !== undefined) {
                audioComponentType = jsonData.audioComponentType.toString();
            }
            const description = jsonData.description || '';
            const extended = jsonData.extended || '';
            if (description || extended) {
                metadataDescription = [description, extended].filter(Boolean).join('\n');
                console.log('Metadata description will be added:', metadataDescription);
            }
            if (jsonData.name) {
                metadataTitle = jsonData.name;
                console.log('Metadata title will be added:', metadataTitle);
            }
            if (jsonData.startAt) {
                const date = new Date(jsonData.startAt);
                metadataDate = date.toISOString().split('T')[0];
                console.log('Metadata date will be added:', metadataDate);
            }
            if (jsonData.channelId) {
                metadataNetwork = jsonData.channelId;
                console.log('Metadata network will be added:', metadataNetwork);
            }
            const genres = [];
            for (let i = 1; i <= 3; i++) {
                const genreKey = `genre${i}`;
                const subGenreKey = `subGenre${i}`;
                if (jsonData[genreKey] !== undefined && jsonData[genreKey] !== null) {
                    const mainGenre = genreMap[jsonData[genreKey]] || `ジャンル${jsonData[genreKey]}`;
                    let subGenre = null;
                    if (jsonData[subGenreKey] !== undefined && jsonData[subGenreKey] !== null) {
                        const mainGenreCode = jsonData[genreKey];
                        const subGenreCode = jsonData[subGenreKey];
                        const subMap = subGenreMap[mainGenreCode];
                        if (subMap && subMap[subGenreCode] !== undefined) {
                            subGenre = subMap[subGenreCode];
                        } else {
                            subGenre = `サブジャンル${subGenreCode}`;
                        }
                    }
                    const genreText = subGenre ? `${mainGenre} - ${subGenre}` : mainGenre;
                    genres.push(genreText);
                    console.log(`Added genre: ${genreText}`);
                }
            }
            if (genres.length > 0) {
                metadataGenre = genres.join(' / ');
                console.log('Metadata genre will be added:', metadataGenre);
            }
            console.log('Using JSON config - audioComponentType:', audioComponentType);
        } else {
            console.log('JSON file is empty, using legacy mode');
            audioComponentType = nonOptionArgs[1] || '0';
        }
    } catch (error) {
        console.error('Error parsing JSON file:', error.message);
        console.log('Fallback to legacy mode due to JSON parse error');
        audioComponentType = nonOptionArgs[1] || '0';
    }
} else if (jsonFilePath) {
    console.error(`Error: JSON file not found: ${jsonFilePath}`);
    process.exit(1);
} else {
    console.log('Using legacy mode - audioComponentType:', audioComponentType);
}

if (!inputFile) {
    console.error('Usage: node enc.js [--ignore-tags] <input_file_path> [input_file.json|audio_component_type] [chap_out.txt] [trim_file.txt]');
    console.error('Example: node enc.js /path/to/番組名.m2ts input_file.json');
    console.error('Example with chapters: node enc.js /path/to/番組名.m2ts input_file.json chap_out.txt');
    console.error('Example with trim: node enc.js /path/to/番組名.m2ts input_file.json chap_out.txt jls_out.txt');
    console.error('Example with options: node enc.js --ignore-tags /path/to/番組名.m2ts');
    console.error('Legacy: node enc.js /path/to/番組名.m2ts 2');
    process.exit(1);
}

if (!fs.existsSync(inputFile)) {
    console.error(`Error: Input file not found: ${inputFile}`);
    process.exit(1);
}

const inputFileName = path.parse(inputFile).name;
const outputFile = `./${inputFileName}.mp4`;
const epgsConfig = { recordedFileExtension: '.m2ts' };
const ffmpegLogOutOnlyOnError = true;
const progressLogOutMax = 0;
const fixedCutSecond = 3;
const FPS = 29.97;

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

// 動画長を取得（秒）
function getVideoDuration(filePath) {
    try {
        const result = execFileSync(getEnv('FFPROBE'), [
            '-v', 'error',
            '-show_entries', 'format=duration',
            '-of', 'csv=p=0',
            filePath
        ], { encoding: 'utf8' });
        return parseFloat(result.trim());
    } catch (e) {
        console.error('Error getting video duration:', e.message);
        return null;
    }
}

// 通常モード用チャプターファイルパース（bash版chapter()相当）
function parseChapterFileForNormal(chapterFilePath, durationSec, cutSec) {
    if (!fs.existsSync(chapterFilePath)) {
        return null;
    }
    
    const content = fs.readFileSync(chapterFilePath, 'utf8');
    const scRegex = /SCPos:(\d+)/g;
    const scPositions = [];
    let match;
    
    while ((match = scRegex.exec(content)) !== null) {
        scPositions.push(parseInt(match[1]));
    }
    
    if (scPositions.length === 0) {
        return null;
    }
    
    scPositions.sort((a, b) => a - b);
    
    const maxFrame = Math.round(durationSec * FPS);
    const cutMs = cutSec * 1000;
    const thresholdMs = 20000;
    
    const timePoints = [0]; // 0秒から開始
    
    for (const scf of scPositions) {
        if (scf >= maxFrame) continue;
        
        const ms = Math.round((scf / FPS) * 1000) - cutMs;
        if (ms < 0) continue; // カットより前のチャプターは無視
        
        const lastMs = timePoints[timePoints.length - 1];
        if (ms - lastMs > thresholdMs) {
            timePoints.push(ms);
        }
    }
    
    // 動画終端を追加（カット後の長さ）
    const finalDurationMs = Math.round(durationSec * 1000) - cutMs;
    if (finalDurationMs > (timePoints[timePoints.length - 1] || 0)) {
        timePoints.push(finalDurationMs);
    }
    
    // Chapter オブジェクト配列に変換（STARTのみ）
    const result = [];
    for (let i = 0; i < timePoints.length; i++) {
        result.push({
            index: i + 1,
            start: timePoints[i],
            title: `Chapter ${i + 1}`
        });
    }
    
    console.log(`Parsed ${result.length} chapters for normal mode (cut ${cutSec}s applied)`);
    return result;
}

function checkLibaribb24Availability() {
    try {
        const versionResult = execFileSync(getEnv('FFMPEG'), ['-version'], { encoding: 'utf8' });
        const isAvailable = versionResult.includes('libaribb24');
        console.log('libaribb24 available:', isAvailable);
        if (!isAvailable) {
            const configLine = versionResult.split('\n').find(line => line.includes('configuration:'));
            console.log('Build configuration:', configLine);
        }
        return isAvailable;
    } catch (error) {
        console.error('Error in libaribb24 check, assuming available:', error.message);
        return true;
    }
}

function detectSubtitleStreamsInFile(filePath) {
    try {
        const options = [
            ...getAnalyze(),
            '-v', 'error',
            '-select_streams', 's',
            '-show_entries', 'stream=index,codec_name,codec_type,tags:stream_tags=language',
            '-of', 'json',
            filePath
        ];
        const result = execFileSync(getEnv('FFPROBE'), options, { encoding: 'utf8', maxBuffer: 1024 * 1024 * 10 });
        const info = JSON.parse(result);
        const subtitleStreams = [];
        if (info.streams && info.streams.length > 0) {
            for (const stream of info.streams) {
                if (stream.codec_type === 'subtitle') {
                    subtitleStreams.push(stream.index);
                    const lang = stream.tags && stream.tags.language ? stream.tags.language : 'unknown';
                    console.log(`Found subtitle stream in ${path.basename(filePath)}: index=${stream.index}, codec=${stream.codec_name}, language=${lang}`);
                }
            }
        }
        return subtitleStreams;
    } catch (error) {
        console.error(`Error detecting subtitle streams in ${filePath}:`, error.message);
        return [];
    }
}

function detectAllSubtitleStreams() {
    try {
        const options = [
            ...getAnalyze(),
            '-v', 'error',
            '-select_streams', 's',
            '-show_entries', 'stream=index,codec_name,codec_type,tags:stream_tags=language',
            '-of', 'json',
            getEnv('INPUT')
        ];
        const result = execFileSync(getEnv('FFPROBE'), options, { encoding: 'utf8' });
        const info = JSON.parse(result);
        const subtitleStreams = [];
        if (info.streams && info.streams.length > 0) {
            for (const stream of info.streams) {
                if (stream.codec_type === 'subtitle') {
                    const lang = stream.tags && stream.tags.language ? stream.tags.language : 'unknown';
                    subtitleStreams.push(stream.index);
                    console.log(`Found subtitle stream: index=${stream.index}, codec=${stream.codec_name}, language=${lang}`);
                }
            }
        }
        console.log('All subtitle streams found:', subtitleStreams);
        return subtitleStreams;
    } catch (error) {
        console.error('Error detecting subtitle streams:', error.message);
        return [];
    }
}

function getSubTitlesArg(hasLibaribb24) {
    const fix = [];
    const map = [];
    const fileName = getEnv('NAME');
    const isSub = /\[字\]/.test(fileName);
    console.log('Subtitle detection:', { fileName, isSub, hasLibaribb24, ignoreTags });

    if (ignoreTags) {
        console.log('Ignore tags mode: skipping subtitle processing regardless of [字] tag');
        return { fix: fix, map: map, isSub: false };
    }

    if (isSub) {
        if (hasLibaribb24) {
            fix.push('-fix_sub_duration');
            console.log('libaribb24 is available, using -fix_sub_duration');
            const subtitleStreams = detectAllSubtitleStreams();
            console.log('All detected subtitle streams:', subtitleStreams);
            if (subtitleStreams.length > 0) {
                for (let i = 0; i < subtitleStreams.length; i++) {
                    map.push('-map', `0:${subtitleStreams[i]}?`);
                    map.push(`-c:s:${i}`, 'mov_text');
                    map.push(`-metadata:s:s:${i}`, 'language=jpn');
                }
            } else {
                map.push('-map', '0:s?');
                map.push('-c:s', 'mov_text');
                map.push('-metadata:s:s:0', 'language=jpn');
            }
        } else {
            console.log('libaribb24 is not available, skipping subtitle mapping');
        }
    } else {
        console.log('No [字] tag in filename, skipping subtitle processing');
    }
    return { fix: fix, map: map, isSub: isSub };
}

function checkLibfdkAacAvailability() {
    try {
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

function getAudioCodec() {
    const hasLibfdkAac = checkLibfdkAacAvailability();
    const audioCodec = hasLibfdkAac ? 'libfdk_aac' : 'aac';
    console.log(`Using audio codec: ${audioCodec}`);
    return audioCodec;
}

// Linux環境で物理的にIntel GPUが存在するか安全に確認する関数
function isIntelGpuPresent() {
    if (process.platform !== 'linux') {
        return true;
    }
    try {
        const drmPath = '/sys/class/drm';
        if (!fs.existsSync(drmPath)) return false;

        const devices = fs.readdirSync(drmPath);
        for (const device of devices) {
            if (device.startsWith('card') && !device.includes('-')) {
                const vendorPath = path.join(drmPath, device, 'device', 'vendor');
                if (fs.existsSync(vendorPath)) {
                    const vendorId = fs.readFileSync(vendorPath, 'utf8').trim();
                    if (vendorId === '0x8086') {
                        return true; 
                    }
                }
            }
        }
    } catch (e) {
        return true;
    }
    return false; 
}

// 利用可能な映像コーデックを決定
function getVideoCodec() {
    if (FORCE_CODEC) {
        console.log(`Manual override: Using ${FORCE_CODEC}`);
        return FORCE_CODEC;
    }

    // 1. QSV HEVC (Intel環境 H.265)
    const hasHevcQsv = checkHevcQsvAvailability();
    if (hasHevcQsv) {
        console.log('Using hevc_qsv video codec');
        return 'hevc_qsv';
    }

    // 2. VA-API HEVC (Linux汎用 / Intel・AMD等 H.265)
    const hasHevcVaapi = checkHevcVaapiAvailability();
    if (hasHevcVaapi) {
        console.log('Using hevc_vaapi video codec');
        return 'hevc_vaapi';
    }

    // 3. QSV H.264 (Intel環境)
    const hasH264Qsv = checkH264QsvAvailability();
    if (hasH264Qsv) {
        console.log('Using h264_qsv video codec');
        return 'h264_qsv';
    }

    // 4. VA-API H.264 (Linux汎用 / Intel・AMD等)
    const hasH264Vaapi = checkH264VaapiAvailability();
    if (hasH264Vaapi) {
        console.log('Using h264_vaapi video codec');
        return 'h264_vaapi';
    }

    console.log('Hardware codecs not available/not forced, using libx264');
    return 'libx264';
}

function checkHevcQsvAvailability() {
    if (!isIntelGpuPresent()) {
        console.log('hevc_qsv detection - Skipped (No Intel GPU detected)');
        return false;
    }

    try {
        const encodersResult = execFileSync(getEnv('FFMPEG'), ['-encoders'], { encoding: 'utf8' });
        const hasHevcQsv = encodersResult.includes('hevc_qsv') && encodersResult.includes('HEVC');
        console.log(`hevc_qsv detection - Encoders: ${hasHevcQsv}`);
        
        if (hasHevcQsv) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasQsvHwaccel = hwaccelResult.includes('qsv');
                
                if (!hasQsvHwaccel) return false;

                try {
                    const devicesResult = execFileSync(getEnv('FFMPEG'), [
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1', 
                        '-c:v', 'hevc_qsv',
                        '-frames:v', '1', 
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 3000,             
                        killSignal: 'SIGKILL'      
                    });
                    console.log('hevc_qsv device test passed');
                    return true;
                } catch (testError) {
                    console.log('hevc_qsv device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                return false;
            }
        }
        return false;
    } catch (error) {
        return false;
    }
}

function checkH264QsvAvailability() {
    if (!isIntelGpuPresent()) {
        console.log('h264_qsv detection - Skipped (No Intel GPU detected)');
        return false;
    }

    try {
        const encodersResult = execFileSync(getEnv('FFMPEG'), ['-encoders'], { encoding: 'utf8' });
        const hasH264Qsv = encodersResult.includes('h264_qsv') && encodersResult.includes('H.264');
        console.log(`h264_qsv detection - Encoders: ${hasH264Qsv}`);
        
        if (hasH264Qsv) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasQsvHwaccel = hwaccelResult.includes('qsv');
                
                if (!hasQsvHwaccel) return false;

                try {
                    const devicesResult = execFileSync(getEnv('FFMPEG'), [
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1', 
                        '-c:v', 'h264_qsv',
                        '-frames:v', '1', 
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 3000,             
                        killSignal: 'SIGKILL'      
                    });
                    console.log('h264_qsv device test passed');
                    return true;
                } catch (testError) {
                    console.log('h264_qsv device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                return false;
            }
        }
        return false;
    } catch (error) {
        return false;
    }
}

function checkHevcVaapiAvailability() {
    try {
        const encodersResult = execFileSync(getEnv('FFMPEG'), ['-encoders'], { encoding: 'utf8' });
        const hasHevcVaapi = encodersResult.includes('hevc_vaapi') && encodersResult.includes('HEVC');
        console.log(`hevc_vaapi detection - Encoders: ${hasHevcVaapi}`);
        
        if (hasHevcVaapi) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasVaapiHwaccel = hwaccelResult.includes('vaapi');
                
                if (!hasVaapiHwaccel) return false;

                // 【重要】Linux環境でrenderD128が存在すれば明示的に指定、なければ自動選定
                const vaapiDevice = fs.existsSync('/dev/dri/renderD128') ? 'vaapi=va:/dev/dri/renderD128' : 'vaapi=va:';

                try {
                    const testResult = execFileSync(getEnv('FFMPEG'), [
                        '-init_hw_device', vaapiDevice, // 明示的なデバイスパスを使用
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1',
                        '-vf', 'format=nv12,hwupload',
                        '-c:v', 'hevc_vaapi',
                        '-frames:v', '1',
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 3000,
                        killSignal: 'SIGKILL'
                    });
                    console.log('hevc_vaapi device test passed');
                    return true;
                } catch (testError) {
                    console.log('hevc_vaapi device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                return false;
            }
        }
        return false;
    } catch (error) {
        return false;
    }
}

function checkH264VaapiAvailability() {
    try {
        const encodersResult = execFileSync(getEnv('FFMPEG'), ['-encoders'], { encoding: 'utf8' });
        const hasH264Vaapi = encodersResult.includes('h264_vaapi') && encodersResult.includes('H.264');
        console.log(`h264_vaapi detection - Encoders: ${hasH264Vaapi}`);
        
        if (hasH264Vaapi) {
            try {
                const hwaccelResult = execFileSync(getEnv('FFMPEG'), ['-hwaccels'], { encoding: 'utf8' });
                const hasVaapiHwaccel = hwaccelResult.includes('vaapi');
                
                if (!hasVaapiHwaccel) return false;

                // 【重要】Linux環境でrenderD128が存在すれば明示的に指定、なければ自動選定
                const vaapiDevice = fs.existsSync('/dev/dri/renderD128') ? 'vaapi=va:/dev/dri/renderD128' : 'vaapi=va:';

                try {
                    const testResult = execFileSync(getEnv('FFMPEG'), [
                        '-init_hw_device', vaapiDevice, // 明示的なデバイスパスを使用
                        '-f', 'lavfi',
                        '-i', 'nullsrc=size=640x480:d=0.1',
                        '-vf', 'format=nv12,hwupload',
                        '-c:v', 'h264_vaapi',
                        '-frames:v', '1',
                        '-f', 'null', '-'
                    ], {
                        encoding: 'utf8',
                        stdio: ['pipe', 'pipe', 'pipe'],
                        timeout: 3000,
                        killSignal: 'SIGKILL'
                    });
                    console.log('h264_vaapi device test passed');
                    return true;
                } catch (testError) {
                    console.log('h264_vaapi device test failed:', testError.message);
                    return false;
                }
            } catch (hwError) {
                return false;
            }
        }
        return false;
    } catch (error) {
        return false;
    }
}

function isTs() {
    const reg = new RegExp(epgsConfig.recordedFileExtension + '$');
    return (getEnv('INPUT').match(reg) !== null)
}

function getAnalyze() {
    return ['-analyzeduration', '100M', '-probesize', '100M'];
}

function convertSecToTime(second) {
    const date = new Date(0);
    date.setSeconds(second);
    return date.toISOString().substring(11, 19);
}

function getAudioStreamDetails(filePath = null) {
    try {
        const options = [
            ...getAnalyze(),
            '-v', 'error',
            '-select_streams', 'a',
            '-show_entries', 'stream=index,codec_name,channels,bit_rate,sample_rate,tags:stream_tags=language,title',
            '-of', 'json',
            filePath || getEnv('INPUT')  // 指定があれば filePath、なければ INPUT
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
                console.log(`Stream #${streamInfo.index}: ${streamInfo.codec}, ${streamInfo.channels}ch, ${streamInfo.bitrate}bps, lang=${streamInfo.language}, title=${streamInfo.title}`);
            }
        }
        return audioStreams;
    } catch (error) {
        console.error('Error getting audio stream details:', error.message);
        return [];
    }
}

function findMainAudioStream(audioStreams) {
    if (audioStreams.length === 0) return null;
    const japaneseStream = audioStreams.find(stream =>
        stream.language && (stream.language === 'jpn' || stream.language === 'ja'));
    if (japaneseStream) {
        console.log(`Found Japanese audio stream: ${japaneseStream.index}`);
        return japaneseStream;
    }
    const mainByTitle = audioStreams.find(stream =>
        stream.title && (stream.title.includes('主') || stream.title.includes('メイン') ||
                         stream.title.includes('main') || stream.title.includes('primary')));
    if (mainByTitle) {
        console.log(`Found main audio stream by title: ${mainByTitle.index} (${mainByTitle.title})`);
        return mainByTitle;
    }
    console.log(`Using first audio stream as main: ${audioStreams[0].index}`);
    return audioStreams[0];
}

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

    const audioStreams = getAudioStreamDetails();
    if (audioStreams.length === 0) {
        console.error('No audio streams found!');
        return { args: [] };
    }

    if (isDualMono && audioStreams.length >= 1) {
        console.log('Processing as dual mono');
        const mainStreamIndex = audioStreams[0].index;
        args.push('-filter_complex', `[0:${mainStreamIndex}]channelsplit=channel_layout=stereo[left][right]`);
        args.push('-map', '[left]');
        args.push('-map', '[right]');
        args.push('-metadata:s:a:0', 'language=jpn');
        args.push('-metadata:s:a:1', 'language=eng');
        args.push('-c:a', audioCodec);
        args.push('-b:a:0', '192k');
        args.push('-b:a:1', '192k');
        args.push('-ac:0', '1');
        args.push('-ac:1', '1');
        return { args: args };
    }

    if (ignoreTags) {
        console.log('Ignore tags mode: mapping only main audio stream');
        const mainAudioStream = findMainAudioStream(audioStreams);
        if (mainAudioStream) {
            args.push('-map', `0:${mainAudioStream.index}?`);
            args.push(`-metadata:s:a:0`, `language=jpn`);
            console.log(`Mapping only main audio stream: ${mainAudioStream.index}`);
            args.push('-c:a', audioCodec);
            args.push('-b:a', '192k');
            args.push('-ac', '2');
        }
        return { args: args };
    }

    const shouldMapAllAudio = isBilingual || isExplanation || isMultiAudio || isSecondary;
    if (!shouldMapAllAudio) {
        console.log('No audio tags ([二], [解], [多], [副]) found in filename, mapping only main audio stream');
        const mainAudioStream = findMainAudioStream(audioStreams);
        if (mainAudioStream) {
            args.push('-map', `0:${mainAudioStream.index}?`);
            args.push(`-metadata:s:a:0`, `language=jpn`);
            args.push('-c:a', audioCodec);
            args.push('-b:a', '192k');
            args.push('-ac', '2');
        }
        return { args: args };
    }

    console.log('Audio tags found in filename, mapping all audio streams');
    const languageMap = determineAudioLanguages(audioStreams, fileName);
    let audioIndex = 0;
    for (const stream of audioStreams) {
        args.push('-map', `0:${stream.index}?`);
        const lang = languageMap[stream.index] || 'jpn';
        args.push(`-metadata:s:a:${audioIndex}`, `language=${lang}`);
        console.log(`Mapping audio stream ${stream.index} as audio track ${audioIndex} with language: ${lang}`);
        audioIndex++;
    }
    args.push('-c:a', audioCodec);
    args.push('-b:a', '192k');
    args.push('-ac', '2');
    return { args: args };
}

const LANGUAGE_KEYWORDS = [
    { code: 'kor', patterns: [/kor/i, /korean/i, /韓国/, /韓/] },
    { code: 'chi', patterns: [/chi/i, /chinese/i, /中国/, /中/] },
    { code: 'ita', patterns: [/ita/i, /italian/i, /イタリア/, /伊/] },
    { code: 'fra', patterns: [/fra/i, /french/i, /フランス/, /仏/] },
    { code: 'deu', patterns: [/ger/i, /german/i, /deu/i, /ドイツ/, /独/] },
];

function determineAudioLanguages(audioStreams, fileName) {
    const isBilingual = /\[二\]/.test(fileName);
    const languageMap = {};
    for (const stream of audioStreams) {
        if (stream.language) {
            languageMap[stream.index] = stream.language;
        }
    }
    function detectLanguage(text) {
        if (!text) return null;
        const lowerText = text.toLowerCase();
        if (lowerText.includes('jpn') || lowerText.includes('japanese') || lowerText.includes('日本語') || lowerText.includes('主') || lowerText.includes('メイン')) return 'jpn';
        if (lowerText.includes('副') || lowerText.includes('解説') || lowerText.includes('comm') || lowerText.includes('comment')) return 'jpn';
        if (lowerText.includes('eng') || lowerText.includes('english') || lowerText.includes('英語') || lowerText.includes('英')) return 'eng';
        for (const lang of LANGUAGE_KEYWORDS) {
            if (lang.patterns.some(pattern => pattern.test(lowerText))) return lang.code;
        }
        return null;
    }
    for (const stream of audioStreams) {
        if (!languageMap[stream.index] && stream.title) {
            const detected = detectLanguage(stream.title);
            if (detected) languageMap[stream.index] = detected;
        }
    }
    const untaggedStreams = audioStreams.filter(stream => !languageMap[stream.index]);
    if (untaggedStreams.length > 0) {
        if (isBilingual && audioStreams.length >= 2) {
            const mainStream = untaggedStreams.find(stream => stream.index === Math.min(...untaggedStreams.map(s => s.index)));
            const secondaryStream = untaggedStreams.find(stream => stream.index === Math.max(...untaggedStreams.map(s => s.index)));
            if (mainStream) languageMap[mainStream.index] = 'jpn';
            if (secondaryStream && secondaryStream !== mainStream) {
                const inferredFromFileName = detectLanguage(fileName);
                languageMap[secondaryStream.index] = inferredFromFileName || 'eng';
            }
        } else {
            for (const stream of untaggedStreams) {
                languageMap[stream.index] = 'jpn';
            }
        }
    }
    return languageMap;
}

function parseAssTime(timeStr) {
    const [h, m, s] = timeStr.trim().split(':');
    const sec = parseFloat(s.replace(',', '.'));
    return parseInt(h) * 3600 + parseInt(m) * 60 + sec;
}

function formatAssTime(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return `${h}:${m.toString().padStart(2, '0')}:${s.toFixed(2).padStart(5, '0')}`;
}

function parseTrimFile(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');
    const regex = /Trim\((\d+),(\d+)\)/g;
    const segments = [];
    let match;
    while ((match = regex.exec(content)) !== null) {
        const startFrame = parseInt(match[1]);
        const endFrame = parseInt(match[2]);
        const startSec = startFrame / FPS;
        const endSec = endFrame / FPS;
        const duration = endSec - startSec;
        segments.push({
            startFrame,
            endFrame,
            startSec: parseFloat(startSec.toFixed(3)),
            duration: parseFloat(duration.toFixed(3)),
            endSec: parseFloat(endSec.toFixed(3))
        });
    }
    if (segments.length === 0) {
        throw new Error('No valid Trim() segments found in trim file');
    }
    console.log(`Parsed ${segments.length} trim segments`);
    return { segments, fps: FPS };
}

function processSubtitleFile(inputSubPath, outputPath, trimSegments) {
    const content = fs.readFileSync(inputSubPath, 'utf8');
    const lines = content.split('\n');
    const outputLines = [];

    let accumulatedOffset = 0;
    const segmentOffsets = [];
    for (const seg of trimSegments) {
        segmentOffsets.push(accumulatedOffset);
        accumulatedOffset += seg.duration;
    }

    let inEventsSection = false;

    for (const line of lines) {
        // [Events] セクション以降はDialogue行のみ特殊処理
        if (line.trim() === '[Events]') {
            inEventsSection = true;
            outputLines.push(line);
            continue;
        }

        if (inEventsSection && line.startsWith('Dialogue:')) {
            // Dialogue行のトリム処理
            const parts = line.split(',');
            if (parts.length >= 10) {
                const start = parseAssTime(parts[1]);
                const end = parseAssTime(parts[2]);

                let mappedStart = null;
                let mappedEnd = null;

                for (let i = 0; i < trimSegments.length; i++) {
                    const seg = trimSegments[i];
                    if (end <= seg.startSec || start >= seg.endSec) continue;
                    
                    const effStart = Math.max(start, seg.startSec);
                    const effEnd = Math.min(end, seg.endSec);
                    
                    if (effEnd > effStart) {
                        mappedStart = segmentOffsets[i] + (effStart - seg.startSec);
                        mappedEnd = segmentOffsets[i] + (effEnd - seg.startSec);
                        break;
                    }
                }

                if (mappedStart !== null && mappedEnd !== null) {
                    parts[1] = formatAssTime(mappedStart);
                    parts[2] = formatAssTime(mappedEnd);
                    outputLines.push(parts.join(','));
                }
            }
        } else if (line.startsWith('Style:')) {
            const parts = line.split(',');
            if (parts.length > 3) {
                parts[1] = 'sans-serif';  // Fontname
                parts[2] = '24';          // Fontsize
                outputLines.push(parts.join(','));
            } else {
                outputLines.push(line);
            }
        } else {
            // その他のヘッダー行は元ファイルからそのままコピー
            //（PlayResX/Y, ScaledBorderAndShadow, YCbCr Matrix等を保持）
            outputLines.push(line);
        }
    }

    fs.writeFileSync(outputPath, outputLines.join('\n'));
    console.log(`Trimmed subtitle saved: ${outputPath}`);
}

// トリムモード用チャプターパース
function parseChapterFile(filePath, segments) {
    if (!fs.existsSync(filePath)) {
        console.log('No chap_out.txt found');
        return null;
    }
    const content = fs.readFileSync(filePath, 'utf8');
    const scRegex = /SCPos:(\d+)/g;
    const scPositions = [];
    let match;
    while ((match = scRegex.exec(content)) !== null) {
        scPositions.push(parseInt(match[1]));
    }
    scPositions.sort((a, b) => a - b);
    const chapters = [];
    let outOffset = 0;
    let lastStartMs = -1;
    const THRESHOLD_MS = 20000;
    let chapIndex = 0;
    for (const seg of segments) {
        let startMs = Math.round(outOffset * 1000);
        chapIndex++;
        chapters.push({ index: chapIndex, start: startMs, title: `Chapter ${chapIndex}` });
        lastStartMs = startMs;
        for (const scf of scPositions) {
            if (scf < seg.startFrame || scf >= seg.endFrame) continue;
            const outSec = outOffset + ((scf - seg.startFrame) / FPS);
            const startMsNew = Math.round(outSec * 1000);
            const diff = Math.abs(startMsNew - lastStartMs);
            if (diff <= THRESHOLD_MS) continue;
            chapIndex++;
            chapters.push({ index: chapIndex, start: startMsNew, title: `Chapter ${chapIndex}` });
            lastStartMs = startMsNew;
        }
        outOffset += seg.duration;
    }
    return chapters;
}

function createChapterMetadataFile(chapters, baseDir = './') {
    const metaFile = path.join(baseDir, `chapters_${process.pid}.ffmeta`);
    let metaContent = ';FFMETADATA1\n';
    for (const chap of chapters) {
        metaContent += '[CHAPTER]\n';
        metaContent += 'TIMEBASE=1/1000\n';
        metaContent += `START=${chap.start}\n`;
        metaContent += `title=${chap.title}\n`;
    }
    fs.writeFileSync(metaFile, metaContent);
    return metaFile;
}

function concatenateParts(partFiles, outputFile, metadataArgs, chapterFile) {
    return new Promise((resolve, reject) => {
        const listFile = `./concat_${process.pid}.txt`;  

        // 絶対パスに変換
        const listContent = partFiles.map(f => {
            return `file '${path.resolve(f)}'`;
        }).join('\n');
        
        fs.writeFileSync(listFile, listContent);
        
        // デバッグ用：リスト内容を確認
        console.log('Concat list content:', listContent);

        const args = [
            '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'concat', '-safe', '0',
            '-i', listFile,
            ...(chapterFile ? ['-i', chapterFile] : []),
            '-map', '0:v', '-map', '0:a',
            '-c', 'copy',
//            '-map_metadata', '-1',
            ...(chapterFile ? ['-map_chapters', '1'] : []),
            ...metadataArgs,
            outputFile
        ];

        const child = spawn(getEnv('FFMPEG'), args, { stdio: ['ignore', 'pipe', 'pipe'] });
        
        //  エラー詳細をキャプチャして表示
        let stderr = '';
        child.stderr.on('data', data => { stderr += data; });

        child.on('exit', code => {
            try { fs.unlinkSync(listFile); } catch(e){}
            if (code === 0) {
                resolve();
            } else {
                console.error('Concat stderr:', stderr); // エラー詳細表示
                reject(new Error(`Concatenation failed: ${stderr}`));
            }
        });
    });
}

function encodeSegment(inputPath, outputPath, startSec, duration, videoCodec, audioCodec, audioMetadata = []) {
    const vaapiDevice = videoCodec.includes('vaapi') ? ['-vaapi_device', '/dev/dri/renderD128'] : [];

    const args = [
        '-y',
        ...getAnalyze(),
        ...vaapiDevice,
        '-ss', startSec.toString(),
        '-i', inputPath,
        '-t', duration.toString(),
        '-map', '0:v', '-map', '0:a',
        '-c:v', videoCodec,
        ...(videoCodec === 'h264_qsv' ? [
                  '-init_hw_device', 'qsv=qsv:hw',
                  '-filter_hw_device', 'qsv',
                  '-vf', 'format=nv12,hwupload=extra_hw_frames=64,deinterlace_qsv',
                  '-r', '30000/1001',
                  '-aspect', '16:9',
                  '-preset', 'slow',
                  '-global_quality', '21',
                  '-profile:v', 'high',
                  '-level', '4.2'
              ] :
              videoCodec === 'hevc_qsv' ? [
                  '-init_hw_device', 'qsv=qsv:hw',
                  '-filter_hw_device', 'qsv',
                  '-vf', 'format=nv12,hwupload=extra_hw_frames=64,deinterlace_qsv',
                  '-r', '30000/1001',
                  '-aspect', '16:9',
                  '-preset', 'slow',
                  '-global_quality', '23',
                  '-profile:v', 'main'
              ] :
              videoCodec === 'hevc_vaapi' ? [
                  '-vf', 'yadif,format=nv12,hwupload',
                  '-r', '30000/1001',
                  '-aspect', '16:9',
                  '-qp', '23'
              ] :
              videoCodec === 'libx264' ? ['-vf', 'yadif', '-preset', 'slow', '-crf', '23', '-aspect', '16:9'] :
              videoCodec === 'h264_vaapi' ? [
                  '-vf', 'yadif,format=nv12,hwupload',
                  '-r', '30000/1001',
                  '-aspect', '16:9',
                  '-rc_mode', 'ICQ',
                  '-global_quality', '20',
                  '-profile:v', 'high'
              ] : []),
        '-c:a', audioCodec,
        '-b:a', '192k',
        '-ac', '2',
        ...audioMetadata,
        outputPath
    ];    
    
    console.log(`Encoding segment: ${startSec}s for ${duration}s`);
    
    return new Promise((resolve, reject) => {
        const child = spawn(getEnv('FFMPEG'), args, { stdio: ['ignore', 'pipe', 'pipe'] });
        let stderr = '';
        child.stderr.on('data', data => { stderr += data; });
        child.on('exit', code => {
            if (code === 0) {
                if (!fs.existsSync(outputPath) || fs.statSync(outputPath).size === 0) {
                    reject(new Error(`Output file not created: ${outputPath}`));
                } else {
                    resolve();
                }
            } else {
                reject(new Error(`Segment encode failed: ${stderr}`));
            }
        });
    });
}

function getCodecSpecificArgs(useCodec) {
    if (useCodec === 'h264_qsv') {
        return [
            '-init_hw_device', 'qsv=qsv:hw',
            '-filter_hw_device', 'qsv',
            '-vf', 'format=nv12,hwupload=extra_hw_frames=64,deinterlace_qsv',
            '-r', '30000/1001',
            '-aspect', '16:9',
            '-preset', 'slow',
            '-global_quality', '21',
            '-profile:v', 'high',
            '-level', '4.2'
        ];
    } else if (useCodec === 'hevc_qsv') {
        return [
            '-init_hw_device', 'qsv=qsv:hw',
            '-filter_hw_device', 'qsv',
            '-vf', 'format=nv12,hwupload=extra_hw_frames=64,deinterlace_qsv',
            '-r', '30000/1001',
            '-aspect', '16:9',
            '-preset', 'slow',
            '-global_quality', '23',
            '-profile:v', 'main'
        ];
    } else if (useCodec === 'hevc_vaapi') {
        return [
            '-vf', 'yadif,format=nv12,hwupload',
            '-r', '30000/1001',
            '-aspect', '16:9',
            '-qp', '23'
        ];
    } else if (useCodec === 'libx264') {
        return [
            '-vf', 'yadif',
            '-preset', 'slow',
            '-crf', '23',
            '-aspect', '16:9'
        ];
    } else if (useCodec === 'h264_vaapi') {
        return [
            '-vf', 'yadif,format=nv12,hwupload',
            '-r', '30000/1001',
            '-aspect', '16:9',
            '-rc_mode', 'ICQ',
            '-global_quality', '20',
            '-profile:v', 'high'
        ];
    }
    return [];
}

// --- メイン処理 ---
(() => {
    const originalInputFile = inputFile;
    let tempCleanFile = null;
    let shouldDeleteTemp = false;

    // 1. TS解析とクリーニング（tsreadexの出力は/tmp）
    if (isTs()) {
        console.log('Analyzing TS structure...');
        const analysis = analyzeTsStructure(originalInputFile);
        if (analysis.needsTsreadex) {
            if (!checkTsreadexAvailability()) {
                console.error('ERROR: Install tsreadex. このTSはマルチサービスTSのためtsreadexが必要です');
                process.exit(1);
            }
            try {
                const tempDir = os.tmpdir();
                const baseName = path.basename(originalInputFile, path.extname(originalInputFile));
                tempCleanFile = path.join(tempDir, `${baseName}_${process.pid}_clean.ts`);
                executeTsreadex(originalInputFile, analysis.targetProgramId, tempCleanFile);
                inputFile = tempCleanFile;
                shouldDeleteTemp = true;
                console.log(`Switched input to cleaned TS: ${inputFile}`);
            } catch (err) {
                console.error('tsreadex processing failed:', err.message);
                process.exit(1);
            }
        }
    }

    const useCodec = getVideoCodec();
    const audioCodec = getAudioCodec();
    const hasLibaribb24 = checkLibaribb24Availability();

    // トリムモード判定
    if (trimFilePath) {
        // === トリムモード ===
        (async () => {
            const workPrefix = `./work_${process.pid}`;
            const concatListFile = `./concat_${process.pid}.txt`;
            const startTime = process.uptime(); //  開始時間記録

            try {
                const { segments } = parseTrimFile(trimFilePath);

                // 元ファイルの長さを取得（ログ用）
                const durationSec = getVideoDuration(inputFile) || 0;

                // 音声ストリーム情報を取得
                const audioStreams = getAudioStreamDetails(inputFile);
                const languageMap = determineAudioLanguages(audioStreams, inputFileName);

                // 音声メタデータ配列を構築
                const audioMetadata = [];
                let audioIndex = 0;
                for (const stream of audioStreams) {
                    const lang = languageMap[stream.index] || 'jpn';
                    audioMetadata.push(`-metadata:s:a:${audioIndex}`, `language=${lang}`);
                    const langTitle = {
                        'jpn': 'Japanese', 'eng': 'English', 'kor': 'Korean',
                        'chi': 'Chinese', 'fra': 'French', 'deu': 'German', 'ita': 'Italian'
                    }[lang] || lang;
                    audioMetadata.push(`-metadata:s:a:${audioIndex}`, `title=${langTitle}`);  
                    audioIndex++;
                }

                // 字幕抽出
                let rawAssFile = null;
                const hasSubtitles = hasLibaribb24 && /\[字\]/.test(inputFileName) && !ignoreTags;
                if (hasSubtitles) {
                    const subtitleStreams = detectSubtitleStreamsInFile(inputFile);
                    if (subtitleStreams.length > 0) {
                        rawAssFile = `${workPrefix}_raw.ass`;
                        try {
                            execFileSync(getEnv('FFMPEG'), [
                                '-hide_banner', '-loglevel', 'error', '-y',
                                '-fix_sub_duration',
                                '-i', inputFile,
                                '-map', `0:${subtitleStreams[0]}`,
                                '-c:s', 'ass',
                                rawAssFile
                            ], { timeout: 120000 });
                            console.log('Extracted raw ASS:', rawAssFile);
                        } catch (e) {
                            console.error('ASS extraction failed:', e.message);
                        }
                    }
                }

                // セグメントエンコード
                const partFiles = [];
                for (let i = 0; i < segments.length; i++) {
                    const seg = segments[i];
                    const partFile = `${workPrefix}_part_${i}.mp4`;
                    await encodeSegment(inputFile, partFile, seg.startSec, seg.duration, useCodec, audioCodec, audioMetadata);
                    partFiles.push(partFile);
                }

                // メタデータ準備
                const metadataArgs = [];
                if (metadataTitle) metadataArgs.push('-metadata', `title=${metadataTitle}`);
                if (metadataDate) metadataArgs.push('-metadata', `date=${metadataDate}`);
                if (metadataDescription) metadataArgs.push('-metadata', `description=${metadataDescription.replace(/\n/g, ' ')}`);
                if (metadataGenre) metadataArgs.push('-metadata', `genre=${metadataGenre}`);
                if (metadataNetwork) metadataArgs.push('-metadata', `network=${metadataNetwork}`);

                // チャプター生成（カレントディレクトリ）
                const chapters = chapterFilePath ? parseChapterFile(chapterFilePath, segments) : null;
                const chapterMetaFile = chapters ? `${workPrefix}_chapters.ffmeta` : null;
                if (chapterMetaFile && chapters) {
                    let metaContent = ';FFMETADATA1\n';
                    for (const chap of chapters) {
                        metaContent += '[CHAPTER]\n';
                        metaContent += 'TIMEBASE=1/1000\n';
                        metaContent += `START=${chap.start}\n`;
                        metaContent += `title=${chap.title}\n`;
                    }
                    fs.writeFileSync(chapterMetaFile, metaContent);
                    console.log('Created chapter metadata:', chapterMetaFile);
                }

                // 結合時の引数（ログ用）
                const concatArgs = [
                    '-f', 'concat', '-safe', '0', '-i', concatListFile,
                    ...(chapterMetaFile ? ['-i', chapterMetaFile] : []),
                    '-map', '0:v', '-map', '0:a', '-c', 'copy',
                    '-map_metadata', '-1',
                    ...(chapterMetaFile ? ['-map_chapters', '1'] : []),
                    ...metadataArgs
                ];

                await concatenateParts(partFiles, outputFile, metadataArgs, chapterMetaFile);

                // ASS処理
                if (rawAssFile && fs.existsSync(rawAssFile)) {
                    const finalAss = `./${inputFileName}.ja.ass`;
                    processSubtitleFile(rawAssFile, finalAss, segments);
                }

                // 経過時間計算
                const elapsed = parseFloat(process.uptime() - startTime);

                // === ログ出力 ===
                const logs = {
                    mode: 'trim',
                    outputArgs: concatArgs.join(' '),
                    duration: convertSecToTime(durationSec),
                    elapsedTime: convertSecToTime(elapsed),
                    averageSpeed: durationSec > 0 ? Math.floor(durationSec / elapsed) + 'x' : 'N/A',
                    useCodec, 
                    cutSecond: 0, // トリムモードでは適用なし
                    tsreadexUsed: shouldDeleteTemp,
                    subtitlesIncluded: !!rawAssFile,
                    metadataIncluded: metadataArgs.length > 0,
                    metadataNetwork: metadataNetwork,
                    audioCodec: audioCodec,
                    ignoreTags: ignoreTags,
                    segments: segments.length
                };
                console.log('Successfully encoded:', logs);

                // === クリーンアップ ===
                for (const f of partFiles) { try { fs.unlinkSync(f); } catch(e){} }
                try { fs.unlinkSync(concatListFile); } catch(e){}
                if (rawAssFile) { try { fs.unlinkSync(rawAssFile); } catch(e){} }
                if (chapterMetaFile) { try { fs.unlinkSync(chapterMetaFile); } catch(e){} }
                if (shouldDeleteTemp && tempCleanFile) { try { fs.unlinkSync(tempCleanFile); } catch(e){} }
                
                process.exit(0);

            } catch (error) {
                const elapsed = parseFloat(process.uptime() - startTime);
                console.error('Trim mode error:', error);
                console.log(`Work files may remain with prefix: ${workPrefix}`);
                
                // エラー時もログ出力
                console.error('Error details:', {
                    mode: 'trim',
                    elapsedTime: convertSecToTime(elapsed),
                    useCodec,
                    tsreadexUsed: shouldDeleteTemp,
                    error: error.message
                });

                // エラー時もクリーンアップを試行
                try { fs.unlinkSync(concatListFile); } catch(e){}
                if (shouldDeleteTemp && tempCleanFile) { try { fs.unlinkSync(tempCleanFile); } catch(e){} }
                process.exit(1);
            }
        })();

    } else {
        // === 通常モード ===
        const sub = getSubTitlesArg(hasLibaribb24);
        const audio = getAudioArgs(audioCodec);
        const cutSecond = fixedCutSecond;
        const hasValidSubtitles = sub.map.length > 0;
        
        const metadataArgs = [];
        if (metadataDescription) metadataArgs.push('-metadata', `description=${metadataDescription.replace(/\n/g, ' ')}`);
        if (metadataTitle) metadataArgs.push('-metadata', `title=${metadataTitle}`);
        if (metadataDate) metadataArgs.push('-metadata', `date=${metadataDate}`);
        if (metadataNetwork) metadataArgs.push('-metadata', `network=${metadataNetwork}`);
        if (metadataGenre) metadataArgs.push('-metadata', `genre=${metadataGenre}`);

        // 通常モード用チャプター処理（カレントディレクトリ）
        let chapterMetaFile = null;
        let chapterInputArgs = [];
        let chapterMapArgs = [];
        
        if (chapterFilePath) {
            const durationSec = getVideoDuration(getEnv('INPUT'));
            if (durationSec) {
                const chapters = parseChapterFileForNormal(chapterFilePath, durationSec, fixedCutSecond);
                if (chapters && chapters.length > 0) {
                    chapterMetaFile = createChapterMetadataFile(chapters);
                    chapterInputArgs = ['-i', chapterMetaFile];
                    chapterMapArgs = ['-map_chapters', '1'];
                    console.log('Chapter metadata will be embedded:', chapterMetaFile);
                }
            }
        }

        const inputOptions = [
            ...getAnalyze(),
            ...sub.fix,
            '-fflags', '+genpts',
        ];
	
	if (useCodec.includes('vaapi')) {
	    inputOptions.push('-vaapi_device', '/dev/dri/renderD128');
	}

        if (cutSecond > 0) {
            inputOptions.push('-ss', cutSecond.toString());
        }

	const outputArgs = [
	    '-y',
	    ...getAnalyze(),
	    ...inputOptions,
	    '-i', getEnv('INPUT'),
	    ...chapterInputArgs,
	    '-map', '0:0',
	    '-c:v', useCodec,
	    ...getCodecSpecificArgs(useCodec),
	    ...audio.args,
	    ...metadataArgs,
	    ...(hasValidSubtitles ? sub.map : []),
	    ...chapterMapArgs,
	    getEnv('OUTPUT')
	];

        console.log('Input file:', getEnv('INPUT'));
        console.log('Output file:', getEnv('OUTPUT'));

        const startTime = process.uptime();
        const durationSec = getVideoDuration(getEnv('INPUT')) || 0; //  元動画の長さ取得
        const logBuffers = [];
        const child = spawn(getEnv('FFMPEG'), outputArgs, { stdio: ['ignore', 'pipe', 'pipe'] });

        child.stdout.on('data', data => { logBuffers.push(String(data).trim()); });
        child.stderr.on('data', data => {
            const dataStr = String(data);
            if (!dataStr.startsWith('frame=')) logBuffers.push(dataStr.trim());
        });

        child.on('exit', code => {
            const isError = code !== 0;
            if (!ffmpegLogOutOnlyOnError || isError) {
                console.log('FFmpeg messages:', logBuffers.join('\n'));
            }
            
            const elapsed = parseFloat(process.uptime() - startTime);

            // === ログ出力 ===
            const logs = {
                mode: 'normal',
                outputArgs: outputArgs.join(' '),
                duration: convertSecToTime(durationSec),
                elapsedTime: convertSecToTime(elapsed),
                averageSpeed: durationSec > 0 ? Math.floor(durationSec / elapsed) + 'x' : 'N/A',
                useCodec, 
                cutSecond,
                tsreadexUsed: shouldDeleteTemp,
                subtitlesIncluded: hasValidSubtitles,
                metadataIncluded: metadataArgs.length > 0,
                metadataNetwork: metadataNetwork,
                audioCodec: audioCodec,
                ignoreTags: ignoreTags
            };

            if (isError) {
                console.error('Error code:', code, logs);
            } else {
                console.log('Successfully encoded:', logs);
            }

            // クリーンアップ
            if (chapterMetaFile && fs.existsSync(chapterMetaFile)) {
                try { 
                    fs.unlinkSync(chapterMetaFile); 
                    console.log('Cleaned up chapter metadata:', path.basename(chapterMetaFile));
                } catch(e) {
                    console.error('Failed to cleanup chapter metadata:', e.message);
                }
            }
            if (shouldDeleteTemp && tempCleanFile) {
                try { fs.unlinkSync(tempCleanFile); } catch(e){}
            }
            process.exit(code);
        });
    }
})();
// https://note.com/leal_walrus5520/n/n74a7c7561d43
// https://note.com/leal_walrus5520/n/nb560315013e3
// https://note.com/leal_walrus5520/n/n2d01e784a813
// Time stamp: 2026/07/21
