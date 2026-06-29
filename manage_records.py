#!/usr/bin/env python3
import json
import os
import re
import sys
import curses
import unicodedata
from datetime import datetime
from pathlib import Path

# ==========================================
# 設定: 処理済みリストファイル
# ==========================================
JSON_FILE = "processed_filenames.json"

# --- env.sh から SOURCEDIR を動的に読み込む処理 ---
SCRIPT_DIR = Path(__file__).resolve().parent
ENV_FILE = SCRIPT_DIR / "env.sh"
SOURCEDIR = "recorded"  # デフォルト値（env.sh がない場合のフォールバック）
if ENV_FILE.exists():
    with open(ENV_FILE, "r", encoding="utf-8") as f:
        for line in f:
            # 空白を除去した先頭が '#' ならコメント行として無視
            if line.strip().startswith('#'):
                continue
                
            # 'export SOURCEDIR=...' または 'SOURCEDIR=...' の行を抽出
            match = re.match(r'^\s*(?:export\s+)?(SOURCEDIR)\s*=\s*["\']?(.*?)["\']?\s*$', line)
            if match:
                _, val = match.groups()
                
                # 行末のインラインコメント（ # m2ts ...）があれば除去する
                val = val.split('#')[0].strip()
                # 前後の不要なクォーテーションを再度クリーンアップ
                val = val.strip('"\'')

                val = os.path.expandvars(val)
                val = os.path.expanduser(val)
                
                if not os.path.isabs(val):
                    SOURCEDIR = os.path.abspath(os.path.join(SCRIPT_DIR, val))
                else:
                    SOURCEDIR = val
                break

def load_data():
    if not os.path.exists(JSON_FILE):
        print(f"エラー: '{JSON_FILE}' が見つかりません。")
        sys.exit(1)
    try:
        with open(JSON_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"エラー: {JSON_FILE} のJSONフォーマットが不正です。\n詳細: {e}")
        sys.exit(1)
    
    mtime = os.path.getmtime(JSON_FILE)
    return data, mtime

def save_data_and_exit(data, original_mtime):
    current_mtime = os.path.getmtime(JSON_FILE) if os.path.exists(JSON_FILE) else 0
    save_path = JSON_FILE
    
    if current_mtime != original_mtime:
        timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
        save_path = f"processed_filenames_escape_{timestamp}.json"
        msg = f"\n[警告] 起動後に '{JSON_FILE}' が別プロセスで更新されました。\n安全のため '{save_path}' に保存しました。"
    else:
        msg = f"\n'{JSON_FILE}' を更新して終了しました。"

    with open(save_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
        
    print(msg)
    sys.exit(0)

def format_line(text, max_cols):
    cols = 0
    res = []
    for c in text:
        char_w = 2 if unicodedata.east_asian_width(c) in ('F', 'W', 'A') else 1
        if cols + char_w > max_cols:
            break
        res.append(c)
        cols += char_w
    return "".join(res) + " " * (max_cols - cols)

def ask_confirmation(stdscr, h, w, prompt_text):
    msg = format_line(prompt_text, w - 1)
    try:
        stdscr.addstr(h - 3, 0, msg, curses.color_pair(2))
    except curses.error:
        pass
    stdscr.refresh()
    while True:
        c = stdscr.getch()
        if c in [ord('y'), ord('Y')]:
            return True
        elif c in [ord('n'), ord('N')]:
            return False

def show_message(stdscr, h, w, message):
    msg = format_line(message, w - 1)
    try:
        stdscr.addstr(h - 3, 0, msg, curses.color_pair(3))
    except curses.error:
        pass
    stdscr.refresh()
    curses.napms(1000)

def main(stdscr):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_WHITE)
    curses.init_pair(2, curses.COLOR_WHITE, curses.COLOR_RED)
    curses.init_pair(3, curses.COLOR_GREEN, -1)

    data, original_mtime = load_data()
    selected_files = set()
    
    current_row = 0
    offset = 0

    while True:
        stdscr.clear()
        h, w = stdscr.getmaxyx()
        
        list_height = h - 3 
        
        for i in range(list_height):
            idx = offset + i
            if idx < len(data):
                filename = data[idx]
                mark = "x" if filename in selected_files else " "
                
                display_text = f"[{mark}] {filename}"
                formatted_text = format_line(display_text, w - 1)
                
                try:
                    if idx == current_row:
                        stdscr.addstr(i, 0, formatted_text, curses.color_pair(1))
                    else:
                        stdscr.addstr(i, 0, formatted_text)
                except curses.error:
                    pass

        # メニューバーのテキスト変更 (qとxの案内を追加)
        menu1 = format_line("[↑/↓]:移動 [Space]:選択/解除 [q]:保存終了 [x]:破棄終了", w - 1)
        menu2 = format_line("[1]:不在ファイル一括削除 [2]:選択項目を削除 [3]:日付タグでソート", w - 1)
        
        try:
            stdscr.addstr(h - 2, 0, menu1, curses.A_REVERSE)
            stdscr.addstr(h - 1, 0, menu2, curses.A_REVERSE)
        except curses.error:
            pass
        
        stdscr.refresh()

        key = stdscr.getch()

        if key == curses.KEY_UP:
            if current_row > 0:
                current_row -= 1
                if current_row < offset:
                    offset -= 1
                    
        elif key == curses.KEY_DOWN:
            if current_row < len(data) - 1:
                current_row += 1
                if current_row >= offset + list_height:
                    offset += 1
                    
        elif key == ord(' '):
            if data:
                filename = data[current_row]
                if filename in selected_files:
                    selected_files.remove(filename)
                else:
                    selected_files.add(filename)
                    
        elif key == ord('1'):
            missing = [f for f in data if not os.path.exists(os.path.join(SOURCEDIR, f))]
            if not missing:
                show_message(stdscr, h, w, "不在ファイルはありません (全て存在します)")
            else:
                prompt = f"不在ファイル {len(missing)}件 を一括削除しますか？ (y/n): "
                if ask_confirmation(stdscr, h, w, prompt):
                    data = [f for f in data if f not in missing]
                    selected_files.difference_update(missing)
                    current_row = min(current_row, max(0, len(data) - 1))
                    show_message(stdscr, h, w, "一括削除を完了しました")
                    
        elif key == ord('2'):
            if not selected_files:
                show_message(stdscr, h, w, "ファイルが選択されていません (Spaceキーで選択)")
            else:
                prompt = f"選択中の {len(selected_files)}件 を削除しますか？ (y/n): "
                if ask_confirmation(stdscr, h, w, prompt):
                    data = [f for f in data if f not in selected_files]
                    selected_files.clear()
                    current_row = min(current_row, max(0, len(data) - 1))
                    show_message(stdscr, h, w, "選択項目を削除しました")
                    
        elif key == ord('3'):
            def extract_date_tag(filename):
                match = re.search(r'__S(\d{4})E(\d{4})-(\d{4})', filename)
                return match.group(0) if match else filename

            data.sort(key=extract_date_tag)
            show_message(stdscr, h, w, "日付タグでソートしました")
            
        elif key == ord('q'):
            # 保存して終了フラグ
            return data, original_mtime, True

        elif key == ord('x'):
            # 保存せずに終了するか確認
            prompt = "変更を保存せずに終了しますか？ (y/n): "
            if ask_confirmation(stdscr, h, w, prompt):
                return None, None, False

        elif key == curses.KEY_RESIZE:
            current_row = 0
            offset = 0

    return None, None, False

if __name__ == "__main__":
    try:
        final_data, mtime, should_save = curses.wrapper(main)
        if should_save:
            save_data_and_exit(final_data, mtime)
        else:
            print("\n変更は保存されずに終了しました。")
            sys.exit(0)
    except KeyboardInterrupt:
        print("\n強制終了されました。ファイルは保存されていません。")
        sys.exit(1)

# https://note.com/leal_walrus5520/n/n8ae31f665314
# Time stamp: 2026/06/29
