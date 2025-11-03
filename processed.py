#!/usr/bin/env python3
import requests
import json
import os

# 処理済み番組名ファイル
WORKDIR = os.environ.get('WORKDIR', os.path.expanduser("~") + "/work")
PROCESSED_FILE = os.path.join(WORKDIR, "processed_filenames.json")

def load_processed_filenames():
    """ローカルから処理済みのファイル名を読み込む"""
    if os.path.exists(PROCESSED_FILE):
        with open(PROCESSED_FILE, 'r', encoding='utf-8') as f:
            return set(json.load(f))
    else:
        print("processed_filenames.json does not exist. Creating an empty one.")
        with open(PROCESSED_FILE, 'w', encoding='utf-8') as f:
            json.dump([], f)
        return set()

def save_processed_filenames(processed_filenames):
    """ローカルに処理済みのファイル名を保存する"""
    with open(PROCESSED_FILE, 'w', encoding='utf-8') as f:
        json.dump(list(processed_filenames), f, ensure_ascii=False, indent=4)

def add_filename_to_processed(filename):
    """指定したファイル名を「処理済み」に追加する"""
    processed_filenames = load_processed_filenames()
    
    if filename in processed_filenames:
        print(f"File '{filename}' is already marked as processed.")
    else:
        processed_filenames.add(filename)
        save_processed_filenames(processed_filenames)
        print(f"File '{filename}' has been marked as processed.")

if __name__ == '__main__':
    import sys
    if len(sys.argv) != 2:
        print("Usage: python processed.py <filename>")
        sys.exit(1)
    
    filename = sys.argv[1]
    add_filename_to_processed(filename)
