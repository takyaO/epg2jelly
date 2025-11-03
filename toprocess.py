#!/usr/bin/env python3
import requests
import json
import os
import glob
import time

# 処理済み番組名ファイル
WORKDIR = os.environ.get('WORKDIR', os.path.expanduser("~") + "/work")
PROCESSED_FILE = os.path.join(WORKDIR, "processed_filenames.json")

# サーバーモード用の設定 - 環境変数から取得、未設定時はデフォルト値
EPGSTATION_URL = os.environ.get('EPGSTATION_URL', 'http://localhost:8888')
BASE_URL = f"{EPGSTATION_URL}/api"
RECORDED_ENDPOINT = '/recorded?isHalfWidth=false&offset=0&limit=1000'
headers = {
    'accept': 'application/json',
}

def load_processed_filenames():
    """ローカルから処理済みのファイル名を読み込む"""
    try:
        if os.path.exists(PROCESSED_FILE):
            with open(PROCESSED_FILE, 'r', encoding='utf-8') as f:
                return set(json.load(f))
        else:
            print(f"processed_filenames.json does not exist. Creating a new one at {PROCESSED_FILE}")
            # ディレクトリが存在することを確認
            os.makedirs(os.path.dirname(PROCESSED_FILE), exist_ok=True)
            # 空のリストでファイルを作成
            with open(PROCESSED_FILE, 'w', encoding='utf-8') as f:
                json.dump([], f, ensure_ascii=False, indent=4)
            return set()
    except Exception as e:
        print(f"Error loading processed filenames: {e}")
        # エラー時は空のセットを返す
        return set()

def save_processed_filenames(processed_filenames):
    """ローカルに処理済みのファイル名を保存する"""
    try:
        # ディレクトリが存在することを確認
        os.makedirs(os.path.dirname(PROCESSED_FILE), exist_ok=True)
        with open(PROCESSED_FILE, 'w', encoding='utf-8') as f:
            json.dump(list(processed_filenames), f, ensure_ascii=False, indent=4)
    except Exception as e:
        print(f"Error saving processed filenames: {e}")
       
# ===== フォルダ監視モード用の関数 =====
def get_recorded_programs_folder(recorded_dir):
    """録画済みの番組情報を取得（ローカルファイル版）"""
    recorded_programs = []
   
    # 指定ディレクトリ内の全.m2tsファイルを検索
    m2ts_files = glob.glob(os.path.join(recorded_dir, '**/*.m2ts'), recursive=True)
    
    for file_path in m2ts_files:
        try:
            # Syncthingの一時ファイルを除外
            if is_syncthing_temp_file(file_path):
                continue
                
            # ファイルが書き込み完了状態かチェック
            if is_file_ready(file_path):
                recorded_programs.append(file_path)
                
        except OSError as e:
            print(f"Error accessing file {file_path}: {e}")
            continue
    
    return recorded_programs

def is_syncthing_temp_file(file_path):
    """Syncthingの一時ファイルかチェック"""
    temp_patterns = ['.syncthing.', '.sttmp', '.stfolder']
    filename = os.path.basename(file_path)
    return any(pattern in filename for pattern in temp_patterns)

def is_file_ready(file_path):
    """ファイルが書き込み完了状態かチェック（改良版）"""
    try:
        # ファイルサイズが安定しているかチェック
        size1 = os.path.getsize(file_path)
        time.sleep(1)  # 1秒待機
        size2 = os.path.getsize(file_path)
        
        # ファイルサイズが変化していなければ完了と判断
        if size1 == size2:
            # 念のため排他ロックもチェック
            try:
                with open(file_path, 'rb') as f:
                    return True
            except IOError:
                return False
        else:
            return False
            
    except OSError:
        return False

def get_unprocessed_filenames_folder(processed_filenames, recorded_dir):
    """未処理の番組のファイル名を取得（フォルダ監視版）"""
    unprocessed_filenames = []
    
    # 録画済みファイルのフルパスを取得
    recorded_files = get_recorded_programs_folder(recorded_dir)
    
    for file_path in recorded_files:
        # ファイルパスからファイル名のみを抽出
        filename = os.path.basename(file_path)
        
        # 処理済みリストにないファイルを未処理として追加
        if filename not in processed_filenames:
            unprocessed_filenames.append(filename)
    
    return unprocessed_filenames

# ===== サーバー監視モード用の関数 =====
def get_recorded_programs_server():
    """録画済みの番組情報を取得（サーバー版）"""
    try:
        response = requests.get(BASE_URL + RECORDED_ENDPOINT, headers=headers, timeout=5)
        response.raise_for_status()  # HTTPエラーを例外として投げる
        return response.json().get('records', [])
    except requests.exceptions.RequestException as e:
        print(f"Error fetching recorded programs: {e}")
        return []

def get_unprocessed_filenames_server(processed_filenames):
    """未処理の番組のファイル名を取得（サーバー監視版）"""
    unprocessed_filenames = []
    for record in get_recorded_programs_server():
        video_files = record.get('videoFiles', [])
        for video_file in video_files:
            filename = video_file.get('filename')
            if filename not in processed_filenames:
                unprocessed_filenames.append(filename)
    return unprocessed_filenames

# ===== メイン処理 =====
def main():
    # 環境変数 WATCHDIR でモードを判定
    watchdir = os.environ.get('WATCHDIR', '').strip()
    
    processed_filenames = load_processed_filenames()
    
    if watchdir:
        # フォルダ監視モード
        if not os.path.exists(watchdir):
            print(f"Error: Watch folder '{watchdir}' does not exist.")
            return
            
        unprocessed_filenames = get_unprocessed_filenames_folder(processed_filenames, watchdir)
    else:
        # サーバー監視モード (デフォルト)
        unprocessed_filenames = get_unprocessed_filenames_server(processed_filenames)
    
    if unprocessed_filenames:
        for filename in unprocessed_filenames:
            print(filename)

if __name__ == '__main__':
    main()

#Time stamp: 2025/11/02
