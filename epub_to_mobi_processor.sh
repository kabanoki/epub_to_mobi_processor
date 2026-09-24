#!/bin/bash

# EPUB検証・修正・MOBI変換 統合スクリプト
# 作成日: 2025年1月23日
# 
# 機能:
# 1. EPUBファイルの構造検証
# 2. 包括的エラー修正 (HTML→XHTML変換、アンカーリンク修正等)
# 3. KindleGenによるMOBI変換
# 4. Kindle接続時のMOBI自動転送
# 5. 詳細なログ出力とエラーレポート
#
# 使用方法: 
# ./epub_to_mobi_processor.sh [対象ディレクトリ]
# 
# パラメーター:
#   [対象ディレクトリ] - 処理対象のEPUBファイルが含まれるディレクトリ
#                     省略時はスクリプトが設置されているディレクトリを対象とする
# 
# 例:
#   ./epub_to_mobi_processor.sh                          # スクリプトと同じディレクトリのEPUBを処理
#   ./epub_to_mobi_processor.sh "/path/to/epub/files"    # 指定したディレクトリのEPUBを処理
#   ./epub_to_mobi_processor.sh ~/Documents/Books        # ホームディレクトリのBooksフォルダを処理

set -euo pipefail  # エラー時にスクリプト終了

# ========================================
# 設定値
# ========================================

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# デフォルト対象ディレクトリ（スクリプトが設置されているディレクトリ）
DEFAULT_TARGET_DIR="$SCRIPT_DIR"

# kindlegen実行パス
KINDLEGEN_CMD="kindlegen"

# 作業ディレクトリ（対象ディレクトリ確定後に設定）
WORK_DIR=""

# ログファイル設定
LOG_TO_FILE=false
LOG_FILE="epub_processing_$(date +%Y%m%d_%H%M%S).log"

# 結果用配列
declare -a SUCCESS_FILES=()
declare -a ERROR_FILES=()
declare -a FIXED_FILES=()

# EPUB構造情報用グローバル変数
EPUB_OPF_PATH=""
EPUB_NCX_PATH=""
EPUB_CONTENT_DIR=""

# ========================================
# ユーティリティ関数
# ========================================

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_TO_FILE" = true ]; then
        echo "[$timestamp] $message" | tee -a "$LOG_FILE"
    else
        echo "[$timestamp] $message"
    fi
}

log_error() {
    local message="$1"
    log "❌ ERROR: $message"
}

log_success() {
    local message="$1"
    log "✅ SUCCESS: $message"
}

log_info() {
    local message="$1"
    log "ℹ️  INFO: $message"
}

log_warning() {
    local message="$1"
    log "⚠️  WARNING: $message"
}

find_kindle_documents_dir() {
    local mount_point
    local volume_name
    local lower_volume_name
    local documents_dir

    for mount_point in /Volumes/* /media/"${USER:-}"/* /run/media/"${USER:-}"/*; do
        [ -d "$mount_point" ] || continue

        volume_name="$(basename "$mount_point")"
        lower_volume_name="$(printf '%s' "$volume_name" | tr '[:upper:]' '[:lower:]')"

        if [[ "$lower_volume_name" == kindle* ]]; then
            for documents_dir in "$mount_point/documents" "$mount_point/Documents"; do
                if [ -d "$documents_dir" ]; then
                    printf '%s\n' "$documents_dir"
                    return 0
                fi
            done
        fi
    done

    return 1
}

transfer_mobi_to_kindle_if_connected() {
    local mobi_file="$1"
    local kindle_documents_dir
    local kindle_target_file

    if [ ! -f "$mobi_file" ]; then
        log_warning "Kindle転送をスキップしました（MOBIファイルが見つかりません）: $mobi_file"
        return 0
    fi

    if ! kindle_documents_dir="$(find_kindle_documents_dir)"; then
        log_info "Kindle未接続のためMOBI自動転送をスキップ: $(basename "$mobi_file")"
        return 0
    fi

    kindle_target_file="$kindle_documents_dir/$(basename "$mobi_file")"
    if cp -p "$mobi_file" "$kindle_target_file"; then
        log_success "KindleへMOBI転送完了: $(basename "$mobi_file") → $kindle_documents_dir"
    else
        log_warning "KindleへのMOBI転送に失敗: $(basename "$mobi_file") → $kindle_documents_dir"
    fi
}

normalize_mobi_output_file() {
    local epub_file="$1"
    local epub_name="$2"
    local generated_mobi="${epub_file%.epub}.mobi"
    local target_mobi="${epub_name}.mobi"

    FINAL_MOBI_FILE="$target_mobi"

    if [ -f "$generated_mobi" ] && [ "$generated_mobi" != "$target_mobi" ]; then
        if mv "$generated_mobi" "$target_mobi"; then
            log_info "MOBIファイルをリネーム: $(basename "$generated_mobi") → $(basename "$target_mobi")"
        else
            log_warning "MOBIファイルのリネームに失敗: $generated_mobi"
            FINAL_MOBI_FILE="$generated_mobi"
        fi
    fi
}

cleanup() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        log_info "作業ディレクトリをクリーンアップしました: $WORK_DIR"
    fi
}

# スクリプト終了時にクリーンアップを実行
trap cleanup EXIT

# ========================================
# EPUB検証関数
# ========================================

# EPUB構造を分析してOPFファイルとNCXファイルの場所を特定する
analyze_epub_structure() {
    local epub_dir="$1"
    
    # container.xmlからOPFファイルのパスを取得
    local opf_path=""
    if [ -f "$epub_dir/META-INF/container.xml" ]; then
        opf_path=$(grep -o 'full-path="[^"]*"' "$epub_dir/META-INF/container.xml" | sed 's/full-path="//;s/"$//' | head -1)
    fi
    
    # OPFファイルが見つからない場合、一般的なパターンを探す
    if [ -z "$opf_path" ] || [ ! -f "$epub_dir/$opf_path" ]; then
        for possible_opf in "content.opf" "item/standard.opf" "OPS/content.opf" "OEBPS/content.opf"; do
            if [ -f "$epub_dir/$possible_opf" ]; then
                opf_path="$possible_opf"
                break
            fi
        done
    fi
    
    # NCXファイルの場所を推定
    local ncx_path=""
    if [ -n "$opf_path" ]; then
        local opf_dir=$(dirname "$opf_path")
        for possible_ncx in "$opf_dir/toc.ncx" "toc.ncx" "item/toc.ncx" "OPS/toc.ncx" "OEBPS/toc.ncx"; do
            if [ -f "$epub_dir/$possible_ncx" ]; then
                ncx_path="$possible_ncx"
                break
            fi
        done
    fi
    
    # グローバル変数に設定
    EPUB_OPF_PATH="$opf_path"
    EPUB_NCX_PATH="$ncx_path"
    EPUB_CONTENT_DIR=$(dirname "$opf_path")
    
    log_info "EPUB構造分析結果:"
    log_info "  OPFファイル: ${EPUB_OPF_PATH:-未検出}"
    log_info "  NCXファイル: ${EPUB_NCX_PATH:-未検出}"
    log_info "  コンテンツディレクトリ: ${EPUB_CONTENT_DIR:-未検出}"
}

validate_epub_structure() {
    local epub_dir="$1"
    local epub_name="$2"
    local errors=0
    
    log_info "EPUB構造検証開始: $epub_name"
    
    # EPUB構造を分析
    analyze_epub_structure "$epub_dir"
    
    # 必須ファイルの存在確認
    local required_files=("mimetype" "META-INF/container.xml")
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$epub_dir/$file" ]; then
            log_error "必須ファイルが見つかりません: $file"
            ((errors++))
        fi
    done
    
    # OPFファイルとNCXファイルの確認
    if [ -z "$EPUB_OPF_PATH" ] || [ ! -f "$epub_dir/$EPUB_OPF_PATH" ]; then
        log_error "OPFファイルが見つかりません"
        ((errors++))
    fi
    
    if [ -z "$EPUB_NCX_PATH" ] || [ ! -f "$epub_dir/$EPUB_NCX_PATH" ]; then
        log_warning "NCXファイルが見つかりません（必須ではありませんが推奨）"
    fi
    
    # HTMLファイルとXHTMLファイルの混在確認
    local html_count=$(find "$epub_dir" -name "*.html" 2>/dev/null | wc -l)
    local xhtml_count=$(find "$epub_dir" -name "*.xhtml" 2>/dev/null | wc -l)
    
    if [ "$html_count" -gt 0 ] && [ "$xhtml_count" -gt 0 ]; then
        log_warning "HTMLとXHTMLファイルが混在しています（修正が必要）"
        ((errors++))
    elif [ "$html_count" -gt 0 ]; then
        log_info "HTMLファイルが検出されました（XHTMLに変換します）: $html_count 個"
    fi
    
    log_info "EPUB構造検証完了: $epub_name (エラー数: $errors)"
    return $errors
}

# ========================================
# EPUB修正関数
# ========================================

fix_epub_structure() {
    local epub_dir="$1"
    local epub_name="$2"
    
    log_info "EPUB修正開始: $epub_name"
    
    cd "$epub_dir"
    
    # ステップ1: HTML→XHTML変換
    fix_html_to_xhtml
    
    # ステップ2: 参照ファイル更新
    fix_references
    
    # ステップ3: 存在しないファイル参照の修正
    fix_missing_file_references
    
    # ステップ4: 包括的アンカーリンク修正
    fix_anchor_links_comprehensive

    # ステップ4.5: リンク先に存在しないアンカーの除去
    fix_unresolved_anchors

    # ステップ5: 文字エンコーディング確認
    verify_encoding
    
    log_success "EPUB修正完了: $epub_name"
    cd - > /dev/null
}

fix_html_to_xhtml() {
    log_info "HTML→XHTML変換を実行中..."
    
    local converted=0
    
    # EPUB全体でHTMLファイルを検索して変換
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            local dir=$(dirname "$file")
            local basename=$(basename "$file" .html)
            local newfile="$dir/$basename.xhtml"
            mv "$file" "$newfile"
            log_info "変換: $file → $newfile"
            ((converted++))
        fi
    done < <(find . -name "*.html" -print0 2>/dev/null || true)
    
    log_info "HTML→XHTML変換完了: $converted 個のファイルを変換"
}

fix_references() {
    log_info "参照ファイル更新を実行中..."
    
    # OPFファイル内の参照を更新
    if [ -n "$EPUB_OPF_PATH" ] && [ -f "$EPUB_OPF_PATH" ]; then
        sed -i '' 's/\.html/.xhtml/g' "$EPUB_OPF_PATH"
        log_info "$EPUB_OPF_PATH 内の参照を更新"
    fi
    
    # NCXファイル内の参照を更新
    if [ -n "$EPUB_NCX_PATH" ] && [ -f "$EPUB_NCX_PATH" ]; then
        sed -i '' 's/\.html/.xhtml/g' "$EPUB_NCX_PATH"
        log_info "$EPUB_NCX_PATH 内の参照を更新"
    fi
    
    # XHTMLファイル内の内部リンクを更新
    find . -name "*.xhtml" -exec sed -i '' 's/\.html/.xhtml/g' {} \;
    log_info "XHTML内部リンクを更新"
}

fix_anchor_links_comprehensive() {
    log_info "包括的アンカーリンク修正を実行中..."
    
    # 複雑なアンカーIDパターンの定義
    local patterns=(
        's/#[a-zA-Z0-9-]*-[a-fA-F0-9]\{32\}//g'                          # 32文字16進数
        's/#[0-9a-zA-Z-]*-[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}//g'  # UUID形式
        's/#[a-zA-Z0-9-]*-[a-fA-F0-9]\{16\}//g'                          # 16文字16進数
        's/#[a-zA-Z0-9-]*-[a-fA-F0-9]\{24\}//g'                          # 24文字16進数
        's/#[a-zA-Z0-9-]*-ba3fd9a1b33f4880b1d1cc7965675df0//g'            # 既知の問題パターン
    )
    
    # NCXファイルの修正
    if [ -n "$EPUB_NCX_PATH" ] && [ -f "$EPUB_NCX_PATH" ]; then
        for pattern in "${patterns[@]}"; do
            sed -i '' "$pattern" "$EPUB_NCX_PATH"
        done
        sed -i '' -E 's/(<content src="[^"#]+\.xhtml)#[^"]*"/\1"/g' "$EPUB_NCX_PATH"
        log_info "$EPUB_NCX_PATH のアンカーリンク修正完了"
    fi
    
    # OPFファイルの修正
    if [ -n "$EPUB_OPF_PATH" ] && [ -f "$EPUB_OPF_PATH" ]; then
        for pattern in "${patterns[@]}"; do
            sed -i '' "$pattern" "$EPUB_OPF_PATH"
        done
        log_info "$EPUB_OPF_PATH のアンカーリンク修正完了"
    fi
    
    # XHTMLファイル内の修正
    for pattern in "${patterns[@]}"; do
        find . -name "*.xhtml" -exec sed -i '' "$pattern" {} \;
    done
    log_info "XHTML内アンカーリンク修正完了"
}

# リンク先ファイルに該当IDが存在しないアンカー(#xxx)を除去し、ファイル先頭へのリンクにする
# （KindleGen E24010「Hyperlink not resolved in toc」対策）
fix_unresolved_anchors() {
    log_info "未解決アンカーリンクの検出・修正を実行中..."

    if ! command -v python3 >/dev/null 2>&1; then
        log_warning "python3が見つからないため未解決アンカー修正をスキップします"
        return
    fi

    local output
    set +e
    output=$(python3 - . << 'EOF' 2>&1
import os, re, sys
from urllib.parse import unquote

root = sys.argv[1]
link_re = re.compile(r'((?:href|src)=")([^"#:]*)#([^"]+)(")')
ids_cache = {}

def ids_of(path):
    if path not in ids_cache:
        try:
            with open(path, encoding='utf-8', errors='ignore') as f:
                ids_cache[path] = set(re.findall(r'\b(?:id|name)="([^"]+)"', f.read()))
        except OSError:
            ids_cache[path] = None
    return ids_cache[path]

for dirpath, _, files in os.walk(root):
    for name in files:
        if not name.endswith(('.xhtml', '.ncx')):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding='utf-8', errors='ignore') as f:
            text = f.read()

        def repl(m):
            target = m.group(2)
            target_path = os.path.normpath(os.path.join(dirpath, unquote(target))) if target else path
            ids = ids_of(target_path)
            if ids is None or unquote(m.group(3)) in ids:
                return m.group(0)
            print(f"Unresolved anchor: {os.path.relpath(path, root)} -> {target or name}#{m.group(3)}")
            return m.group(1) + (target or name) + m.group(4)

        new_text = link_re.sub(repl, text)
        if new_text != text:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(new_text)
EOF
)
    set -e

    local count=0
    while read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == "Unresolved anchor:"* ]]; then
            log_warning "アンカー除去 ${line#Unresolved anchor: }"
            ((count++)) || true
        else
            log_warning "$line"
        fi
    done <<< "$output"

    log_info "未解決アンカーリンク修正完了: ${count}件"
}

# Pythonを使用してNCXファイルを検証・修正する関数
fix_ncx_with_python() {
    local ncx_file="$1"
    
    if [ ! -f "$ncx_file" ] || ! command -v python3 >/dev/null 2>&1; then 
        return
    fi
    
    log_info "Pythonを使用してNCXファイルを検証・修正中..."
    
    # Pythonスクリプトを一時ファイルとして作成
    cat << 'EOF' > fix_ncx.py
import xml.etree.ElementTree as ET
import os
import sys

ncx_path = sys.argv[1]
ncx_dir = os.path.dirname(ncx_path) or '.'
modified = False

try:
    tree = ET.parse(ncx_path)
    root = tree.getroot()

    # 名前空間の取得
    ns_url = ''
    if '}' in root.tag:
        ns_url = root.tag.split('}')[0].strip('{')
    
    ns = {'n': ns_url} if ns_url else {}
    
    # デフォルト名前空間を登録（出力時のプレフィックス防止）
    if ns_url:
        ET.register_namespace('', ns_url)

    # navMapを探す
    nav_map = root.find('n:navMap' if ns else 'navMap', ns)
    if nav_map is None:
        sys.exit(0)

    # 再帰的にnavPointをチェックして削除する関数
    def clean_navpoints(parent):
        global modified
        to_remove = []
        
        # 子navPointを取得
        points = parent.findall('n:navPoint' if ns else 'navPoint', ns)
        
        for point in points:
            # まず子要素を再帰的にチェック
            clean_navpoints(point)
            
            # content要素をチェック
            content = point.find('n:content' if ns else 'content', ns)
            if content is not None:
                src = content.get('src')
                if src:
                    file_path = src.split('#')[0] # アンカー除去
                    full_path = os.path.join(ncx_dir, file_path)
                    
                    # ファイルが存在しない場合
                    if not os.path.exists(full_path):
                        print(f"Missing file reference in NCX: {file_path}")
                        to_remove.append(point)
                        modified = True
        
        # 削除実行
        for p in to_remove:
            parent.remove(p)

    clean_navpoints(nav_map)

    if modified:
        tree.write(ncx_path, encoding='utf-8', xml_declaration=True)
        print("NCX file updated.")
    else:
        print("No changes needed in NCX.")

except Exception as e:
    print(f"Error processing NCX: {e}")
    sys.exit(1)
EOF

    # Pythonスクリプト実行
    local output
    local exit_code
    set +e
    output=$(python3 fix_ncx.py "$ncx_file" 2>&1)
    exit_code=$?
    set -e

    while read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == "Missing"* ]]; then
            log_warning "$line"
        elif [[ "$line" == "Error processing NCX:"* ]]; then
            log_warning "$line"
        else
            log_info "$line"
        fi
    done <<< "$output"
    
    rm -f fix_ncx.py

    if [ "$exit_code" -ne 0 ]; then
        log_warning "NCXファイルのPython修正に失敗しました。MOBI変換は継続します: $ncx_file"
    fi
}

# 存在しないファイルへの参照を検出・修正する新機能
fix_missing_file_references() {
    log_info "存在しないファイル参照の検出・修正を実行中..."
    
    # OPFファイル内で参照されているXHTMLファイルをチェック
    if [ -n "$EPUB_OPF_PATH" ] && [ -f "$EPUB_OPF_PATH" ]; then
        declare -a missing_files=()
        
        # OPFファイルから参照されているXHTMLファイル一覧を取得
        while IFS= read -r line; do
            if [[ $line =~ href=\"([^\"]*\.xhtml)\" ]]; then
                local file_path="${BASH_REMATCH[1]}"
                local full_path="$EPUB_CONTENT_DIR/$file_path"
                
                if [ ! -f "$full_path" ]; then
                    missing_files+=("$file_path")
                fi
            fi
        done < "$EPUB_OPF_PATH"
        
        # 欠落ファイルの参照を削除
        if [ ${#missing_files[@]} -gt 0 ] 2>/dev/null; then
            for missing_file in "${missing_files[@]}"; do
                log_warning "存在しないファイル参照を削除: $missing_file"
                local file_id=$(basename "$missing_file" .xhtml)
                
                # OPFファイルから該当行を削除（より安全な方法）
                grep -v "href=\"$missing_file\"" "$EPUB_OPF_PATH" > "${EPUB_OPF_PATH}.tmp" && mv "${EPUB_OPF_PATH}.tmp" "$EPUB_OPF_PATH"
                grep -v "idref=\"$file_id\"" "$EPUB_OPF_PATH" > "${EPUB_OPF_PATH}.tmp" && mv "${EPUB_OPF_PATH}.tmp" "$EPUB_OPF_PATH"
                
                # 目次ファイルからリンクを削除
                find . -name "*.xhtml" -type f | while IFS= read -r xhtml_file; do
                    if grep -q "href=\"$missing_file" "$xhtml_file" 2>/dev/null; then
                        grep -v "href=\"$missing_file" "$xhtml_file" > "${xhtml_file}.tmp" && mv "${xhtml_file}.tmp" "$xhtml_file"
                    fi
                    if grep -q "href=\"$(basename "$missing_file")" "$xhtml_file" 2>/dev/null; then
                        grep -v "href=\"$(basename "$missing_file")" "$xhtml_file" > "${xhtml_file}.tmp" && mv "${xhtml_file}.tmp" "$xhtml_file"
                    fi
                done
                
                # ナビゲーションファイルからリンクを削除
                if [ -f "item/navigation-documents.xhtml" ]; then
                    grep -v "href=\"xhtml/$missing_file" "item/navigation-documents.xhtml" > "item/navigation-documents.xhtml.tmp" && mv "item/navigation-documents.xhtml.tmp" "item/navigation-documents.xhtml"
                fi
            done
            
            log_info "存在しないファイル参照の修正完了: ${#missing_files[@]}個のファイル参照を削除"
        else
            log_info "OPFファイル内のファイル参照は正常です"
        fi
    fi
    
    # NCXファイルの修正（Pythonを使用）
    if [ -n "$EPUB_NCX_PATH" ] && [ -f "$EPUB_NCX_PATH" ]; then
        fix_ncx_with_python "$EPUB_NCX_PATH"
    fi
}

verify_encoding() {
    log_info "文字エンコーディング確認中..."
    
    local non_utf8_files=0
    while IFS= read -r -d '' file; do
        if ! file "$file" | grep -q "UTF-8" 2>/dev/null; then
            log_warning "非UTF-8ファイル検出: $file"
            ((non_utf8_files++))
        fi
    done < <(find . -name "*.xml" -o -name "*.xhtml" -o -name "*.opf" -o -name "*.ncx" -print0)
    
    if [ $non_utf8_files -eq 0 ]; then
        log_info "すべてのファイルがUTF-8エンコーディングです"
    else
        log_warning "UTF-8でないファイルが $non_utf8_files 個見つかりました"
    fi
}

# ========================================
# EPUB再構築関数
# ========================================

rebuild_epub() {
    local source_dir="$1"
    local output_file="$2"
    
    log_info "EPUB再構築開始: $output_file"
    log_info "ソースディレクトリ: $source_dir"
    
    # 出力ファイルのパスを絶対パスに変換（特殊文字対応）
    local output_dir
    local output_basename
    output_dir=$(cd "$(dirname "$output_file")" && pwd)
    output_basename=$(basename "$output_file")
    local abs_output_file="$output_dir/$output_basename"
    log_info "絶対出力パス: $abs_output_file"
    
    cd "$source_dir"
    
    # ファイル一覧を確認
    log_info "ソースディレクトリ内ファイル:"
    if [ "$LOG_TO_FILE" = true ]; then
        find . -type f | head -10 | sed 's/^/  /' | tee -a "$LOG_FILE"
    else
        find . -type f | head -10 | sed 's/^/  /'
    fi
    
    # mimetypeファイルを最初に、無圧縮で追加
    if [ -f "mimetype" ]; then
        log_info "mimetypeファイルを追加中..."
        if [ "$LOG_TO_FILE" = true ]; then
            if ! zip -0 -X "${abs_output_file}" mimetype 2>&1 | tee -a "$LOG_FILE"; then
                log_error "mimetypeファイルの追加に失敗"
                cd - > /dev/null
                return 1
            fi
        else
            if ! zip -0 -X "${abs_output_file}" mimetype; then
                log_error "mimetypeファイルの追加に失敗"
                cd - > /dev/null
                return 1
            fi
        fi
    else
        log_warning "mimetypeファイルが見つかりません"
    fi
    
    # 他のファイルを圧縮して追加
    log_info "その他のファイルを追加中..."
    if [ "$LOG_TO_FILE" = true ]; then
        if ! zip -r "${abs_output_file}" . -x "mimetype" "*.DS_Store" ".*" "*.log" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "ファイルの追加に失敗"
            cd - > /dev/null
            return 1
        fi
    else
        if ! zip -r "${abs_output_file}" . -x "mimetype" "*.DS_Store" ".*" "*.log"; then
            log_error "ファイルの追加に失敗"
            cd - > /dev/null
            return 1
        fi
    fi
    
    cd - > /dev/null
    
    if [ -f "$abs_output_file" ]; then
        local file_size=$(ls -lh "$abs_output_file" | awk '{print $5}')
        log_success "EPUB再構築完了: $abs_output_file (サイズ: $file_size)"
        # 元のパスにコピー（既に絶対パスなので不要だがバックアップとして）
        if [ "$abs_output_file" != "$(cd "$(dirname "$output_file")" && pwd)/$(basename "$output_file")" ]; then
            cp "$abs_output_file" "$output_file" 2>/dev/null || true
        fi
        return 0
    else
        log_error "EPUB再構築失敗: $abs_output_file"
        return 1
    fi
}

# ========================================
# MOBI変換関数
# ========================================

convert_to_mobi() {
    local epub_file="$1"
    local epub_name="$2"
    
    log_info "MOBI変換開始: $epub_name"
    
    # エラー終了を一時的に無効化
    set +e
    
    # kindlegenの実行（戻り値に関係なく出力をキャプチャ）
    local output
    output=$("$KINDLEGEN_CMD" "$epub_file" 2>&1)
    local exit_code=$?
    
    # エラー終了を再有効化
    set -e
    
    # 出力内容を解析して実際の成功・失敗を判定
    log_info "KindleGen出力解析中（終了コード: ${exit_code}）..."
    log_info "出力の最後10行:"
    if [ "$LOG_TO_FILE" = true ]; then
        echo "$output" | tail -10 | sed 's/^/    /' | tee -a "$LOG_FILE"
    else
        echo "$output" | tail -10 | sed 's/^/    /'
    fi
    
    if echo "$output" | grep -q "PRC built successfully\|Mobi file built successfully" 2>/dev/null; then
        # 成功パターン
        if echo "$output" | grep -q "WARNINGS" 2>/dev/null; then
            log_success "MOBI変換成功（警告あり）: $epub_name"
            log_warning "KindleGen警告:"
            if [ "$LOG_TO_FILE" = true ]; then
                echo "$output" | grep -E "Warning|W[0-9]+" | sed 's/^/    /' | tee -a "$LOG_FILE"
            else
                echo "$output" | grep -E "Warning|W[0-9]+" | sed 's/^/    /'
            fi
        else
            log_success "MOBI変換成功: $epub_name"
        fi
        
        normalize_mobi_output_file "$epub_file" "$epub_name"
        transfer_mobi_to_kindle_if_connected "$FINAL_MOBI_FILE"
        
        SUCCESS_FILES+=("$epub_name")
        return 0
        
    elif echo "$output" | grep -q "MOBI file could not be generated because of errors" 2>/dev/null; then
        # 明確な失敗パターン
        log_error "MOBI変換失敗: $epub_name"
        log_error "KindleGenエラー出力:"
        if [ "$LOG_TO_FILE" = true ]; then
            echo "$output" | sed 's/^/    /' | tee -a "$LOG_FILE"
        else
            echo "$output" | sed 's/^/    /'
        fi
        ERROR_FILES+=("$epub_name")
        return 1
        
    else
        # 判定困難な場合は終了コードで判定
        if [ ${exit_code} -eq 0 ]; then
            log_success "MOBI変換成功: $epub_name"
            normalize_mobi_output_file "$epub_file" "$epub_name"
            transfer_mobi_to_kindle_if_connected "$FINAL_MOBI_FILE"
            SUCCESS_FILES+=("$epub_name")
            return 0
        else
            log_error "MOBI変換失敗: $epub_name"
            log_error "KindleGenエラー出力:"
            if [ "$LOG_TO_FILE" = true ]; then
                echo "$output" | sed 's/^/    /' | tee -a "$LOG_FILE"
            else
                echo "$output" | sed 's/^/    /'
            fi
            ERROR_FILES+=("$epub_name")
            return 1
        fi
    fi
}

# ========================================
# メイン処理関数
# ========================================

process_epub_file() {
    local epub_file="$1"
    local epub_name=$(basename "$epub_file" .epub)
    local temp_dir="$WORK_DIR/${epub_name}_extracted"
    
    log_info "======================================"
    log_info "処理開始: $epub_name"
    log_info "======================================"
    
    # EPUBファイル展開
    log_info "EPUBファイル展開中: $epub_name"
    mkdir -p "$temp_dir"
    
    if ! unzip -q "$epub_file" -d "$temp_dir"; then
        log_error "EPUBファイルの展開に失敗: $epub_file"
        ERROR_FILES+=("$epub_name (展開失敗)")
        return 1
    fi
    
    # EPUB構造検証
    if ! validate_epub_structure "$temp_dir" "$epub_name"; then
        log_warning "EPUB構造に問題があります。修正を試行します。"
    fi
    
    # 修正が必要かどうかの判定と修正実行
    local needs_fix=false
    
    # HTML→XHTML変換が必要かチェック
    if find "$temp_dir" -name "*.html" | grep -q . 2>/dev/null; then
        needs_fix=true
    fi
    
    # 複雑なアンカーリンクが存在するかチェック
    if grep -r "#[a-zA-Z0-9-]*-[a-fA-F0-9]" "$temp_dir" >/dev/null 2>&1; then
        needs_fix=true
    fi
    
    if $needs_fix; then
        log_info "修正が必要なため、EPUB修正を実行します"
        fix_epub_structure "$temp_dir" "$epub_name"
        FIXED_FILES+=("$epub_name")
        
        # 修正版EPUBを作成
        local fixed_epub="${epub_file%.epub}_KindleReady.epub"
        if rebuild_epub "$temp_dir" "$fixed_epub"; then
            epub_file="$fixed_epub"  # 修正版を使用
            log_info "修正版EPUBを作成しました: $fixed_epub"
        else
            log_error "修正版EPUB作成に失敗: $epub_name"
            ERROR_FILES+=("$epub_name (修正版作成失敗)")
            return 1
        fi
    else
        log_info "修正不要と判定されました"
    fi
    
    # MOBI変換実行
    convert_to_mobi "$epub_file" "$epub_name"
    
    # 中間EPUBファイルを削除（_KindleReadyファイル）
    if [[ "$epub_file" == *"_KindleReady.epub" ]]; then
        log_info "中間EPUBファイルを削除: $epub_file"
        rm -f "$epub_file"
    fi
    
    # 一時ディレクトリクリーンアップ
    rm -rf "$temp_dir"
    
    log_info "処理完了: $epub_name"
}

show_summary() {
    log_info ""
    log_info "======================================"
    log_info "処理結果サマリー"
    log_info "======================================"
    
    log_info "処理日時: $(date)"
    log_info "ログファイル: $LOG_FILE"
    log_info ""
    
    if [ ${#SUCCESS_FILES[@]} -gt 0 ]; then
        log_success "変換成功 (${#SUCCESS_FILES[@]}個):"
        for file in "${SUCCESS_FILES[@]}"; do
            log_success "  ✅ $file"
        done
        log_info ""
    fi
    
    if [ ${#FIXED_FILES[@]} -gt 0 ]; then
        log_info "修正実行 (${#FIXED_FILES[@]}個):"
        for file in "${FIXED_FILES[@]}"; do
            log_info "  🔧 $file"
        done
        log_info ""
    fi
    
    if [ ${#ERROR_FILES[@]} -gt 0 ]; then
        log_error "処理失敗 (${#ERROR_FILES[@]}個):"
        for file in "${ERROR_FILES[@]}"; do
            log_error "  ❌ $file"
        done
        log_info ""
    fi
    
    log_info "作成されたファイル:"
    if [ "$LOG_TO_FILE" = true ]; then
        ls -lah *.mobi 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' | tee -a "$LOG_FILE"
    else
        ls -lah *.mobi 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    fi
    
    # 中間EPUBファイルは削除されるため表示しない
    # if ls *_KindleReady.epub >/dev/null 2>&1; then
    #     log_info ""
    #     log_info "修正版EPUBファイル:"
    #     ls -lah *_KindleReady.epub | awk '{print "  " $9 " (" $5 ")"}' | tee -a "$LOG_FILE"
    # fi
}

# ========================================
# メイン処理
# ========================================

# ヘルプメッセージ表示
show_help() {
    cat << 'EOF'
EPUB→MOBI変換統合スクリプト

使用方法:
    ./epub_to_mobi_processor.sh [オプション] [対象ディレクトリ]

パラメーター:
    [対象ディレクトリ]  処理対象のEPUBファイルが含まれるディレクトリ
                      省略時はスクリプト設置ディレクトリを対象とする

オプション:
    -h, --help        このヘルプメッセージを表示
    -l, --log         ログファイルを出力する（デフォルトは出力なし）

機能:
    1. EPUBファイルの構造検証
    2. 包括的エラー修正（HTML→XHTML変換、アンカーリンク修正等）
    3. KindleGenによるMOBI変換
    4. Kindle接続時のMOBI自動転送
    5. 詳細なログ出力とエラーレポート

実行例:
    ./epub_to_mobi_processor.sh                    # スクリプトと同じディレクトリのEPUBを処理
    ./epub_to_mobi_processor.sh -l                 # ログファイルを出力して処理
    ./epub_to_mobi_processor.sh /path/to/epub      # 指定ディレクトリのEPUBを処理

出力ファイル:
    ・MOBIファイル: [元ファイル名].mobi
    ・ログファイル: epub_processing_YYYYMMDD_HHMMSS.log (オプション指定時のみ)
    
    Kindleが接続されている場合は、生成されたMOBIファイルをKindleのdocumentsフォルダへ自動転送します
    注意: 修正版EPUB（_KindleReady.epub）は処理完了後に自動削除されます
EOF
}

main() {
    # 引数処理
    local target_dir=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--log)
                LOG_TO_FILE=true
                shift
                ;;
            *)
                if [ -z "$target_dir" ]; then
                    target_dir="$1"
                else
                    echo "エラー: 複数のディレクトリ指定はサポートされていません"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # 対象ディレクトリが未指定の場合はデフォルトを使用
    if [ -z "$target_dir" ]; then
        target_dir="$DEFAULT_TARGET_DIR"
        log_info "対象ディレクトリ: $target_dir (スクリプト設置ディレクトリ)"
    else
        log_info "対象ディレクトリ: $target_dir (引数指定)"
    fi
    
    log_info "======================================"
    log_info "EPUB→MOBI変換処理 開始"
    log_info "======================================"
    
    if [ "$LOG_TO_FILE" = true ]; then
        log_info "ログ出力: 有効 ($LOG_FILE)"
    else
        log_info "ログ出力: 無効"
    fi
    
    # ディレクトリ存在確認
    if [ ! -d "$target_dir" ]; then
        log_error "対象ディレクトリが存在しません: $target_dir"
        exit 1
    fi

    target_dir="$(cd "$target_dir" && pwd)"
    WORK_DIR="$target_dir/epub_work_$$"
    log_info "作業ディレクトリ: $WORK_DIR"
    log_info ""
    
    # kindlegen実行確認
    if ! command -v "$KINDLEGEN_CMD" >/dev/null 2>&1; then
        log_error "kindlegenコマンドが見つかりません: $KINDLEGEN_CMD"
        log_info "kindlegenをインストールするか、スクリプト内のKINDLEGEN_CMDパスを修正してください"
        exit 1
    fi
    
    # 作業ディレクトリ作成
    mkdir -p "$WORK_DIR"
    
    # 対象ディレクトリに移動
    cd "$target_dir"
    
    # EPUBファイル検索
    local all_epub_files=(*.epub)
    local epub_files=()
    for epub in "${all_epub_files[@]}"; do
        [ -f "$epub" ] || continue
        [[ "$epub" == *_KindleReady.epub ]] && continue
        epub_files+=("$epub")
    done

    if [ ${#epub_files[@]} -eq 0 ]; then
        log_error "EPUBファイルが見つかりません: $target_dir"
        exit 1
    fi
    
    log_info "検出されたEPUBファイル: ${#epub_files[@]}個"
    for epub in "${epub_files[@]}"; do
        log_info "  📖 $epub"
    done
    log_info ""
    
    # 各EPUBファイルを処理
    for epub_file in "${epub_files[@]}"; do
        if [ -f "$epub_file" ]; then
            process_epub_file "$epub_file"
        fi
    done
    
    # 結果サマリー表示
    show_summary
    
    log_info "======================================"
    log_info "EPUB→MOBI変換処理 完了"
    log_info "======================================"
}

# スクリプト実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
