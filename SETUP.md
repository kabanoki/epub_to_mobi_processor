# プロジェクトセットアップガイド

このドキュメントでは、EPUB→MOBI変換プロジェクトをGitで管理するためのセットアップ手順を説明します。

## 📁 プロジェクト構成

```
epub-to-mobi-converter/
├── README.md                           # メインドキュメント
├── SETUP.md                           # このファイル（セットアップガイド）
├── .gitignore                         # Git除外設定
├── epub_to_mobi_processor.sh          # メインスクリプト（統合処理）
├── EPUB_KindleGen_修正ガイド.mdc       # 技術詳細ガイド
├── convert_epubs_with_error_log.sh    # シンプル変換スクリプト
├── fix_epub_batch.sh                 # 基本修正スクリプト
├── fix_anchors_comprehensive.sh       # アンカー修正スクリプト
├── create_fixed_epubs.sh              # EPUB再作成スクリプト
└── [EPUBファイル群]                    # 変換対象ファイル
```

## 🚀 初期セットアップ

### 1. Gitリポジトリの初期化

```bash
# リポジトリを初期化
git init

# 初期ファイルをステージング
git add README.md SETUP.md .gitignore
git add epub_to_mobi_processor.sh
git add EPUB_KindleGen_修正ガイド.mdc
git add *.sh

# 初回コミット
git commit -m "Initial commit: EPUB to MOBI conversion scripts"
```

### 2. リモートリポジトリの設定（GitHub例）

```bash
# リモートリポジトリを追加
git remote add origin https://github.com/username/epub-to-mobi-converter.git

# ブランチ名をmainに設定
git branch -M main

# 初回プッシュ
git push -u origin main
```

### 3. Git LFSの設定（大きなEPUBファイル用）

EPUBファイルが大きい場合（100MB以上）はGit LFSを使用：

```bash
# Git LFSを初期化
git lfs install

# 大きなEPUBファイルをLFS管理対象にする
git lfs track "*.epub"

# .gitattributesファイルをコミット
git add .gitattributes
git commit -m "Add Git LFS tracking for EPUB files"
```

## 📝 開発ワークフロー

### ブランチ戦略

```bash
# 機能開発用ブランチ
git checkout -b feature/improve-error-handling
git checkout -b feature/add-validation
git checkout -b fix/anchor-link-issue

# 開発完了後にメインブランチにマージ
git checkout main
git merge feature/improve-error-handling
```

### コミットメッセージの規則

```bash
# 機能追加
git commit -m "feat: add comprehensive anchor link fixing"

# バグ修正
git commit -m "fix: resolve EPUB structure detection issue"

# ドキュメント更新
git commit -m "docs: update README with new features"

# リファクタリング
git commit -m "refactor: improve error logging system"

# 設定変更
git commit -m "chore: update .gitignore for log files"
```

## 🔧 開発環境の準備

### 必要なツール

```bash
# macOSの場合
brew install git
brew install bash
brew install gnu-sed  # より強力なsedコマンド

# Git設定
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### エディタ設定

**VS Code用設定（.vscode/settings.json）：**

```json
{
    "files.associations": {
        "*.sh": "shellscript",
        "*.mdc": "markdown"
    },
    "shellcheck.enable": true,
    "bash-ide-vscode.highlightParsingErrors": true
}
```

## 🧪 テスト戦略

### テストディレクトリ構造

```bash
# テスト用ディレクトリ作成
mkdir -p tests/{unit,integration,fixtures}

# テストスクリプト例
touch tests/unit/test_epub_validation.sh
touch tests/integration/test_full_conversion.sh
```

### テストファイル例

```bash
# tests/unit/test_epub_validation.sh
#!/bin/bash
source ../epub_to_mobi_processor.sh

test_validate_epub_structure() {
    # テスト実装
    echo "Testing EPUB structure validation..."
}
```

## 📊 変更履歴の管理

### CHANGELOG.mdの維持

```markdown
# Changelog

## [Unreleased]
### Added
- New feature descriptions

### Changed
- Changes in existing functionality

### Fixed
- Bug fixes

## [1.0.0] - 2025-01-23
### Added
- Initial release
- EPUB to MOBI conversion functionality
```

### バージョンタグの作成

```bash
# バージョンタグを作成
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# すべてのタグを確認
git tag -l
```

## 🚀 継続的インテグレーション

### GitHub Actions例（.github/workflows/test.yml）

```yaml
name: Test EPUB Conversion Scripts

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    
    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y unzip zip
        
    - name: Run shell tests
      run: |
        chmod +x *.sh
        ./tests/run_all_tests.sh
```

## 📝 ドキュメンテーション戦略

### ドキュメントファイル構成

- `README.md` - プロジェクト概要・使用方法
- `SETUP.md` - このファイル（セットアップガイド）
- `EPUB_KindleGen_修正ガイド.mdc` - 技術詳細
- `CHANGELOG.md` - 変更履歴
- `docs/` - 詳細ドキュメント（必要に応じて）

### ドキュメント更新のルール

1. 新機能追加時はREADMEを更新
2. バグ修正時は該当箇所を更新
3. 破壊的変更はCHANGELOGに記載
4. 技術詳細は専用ファイルに分離

## 🔒 セキュリティ考慮事項

### 機密情報の取り扱い

```bash
# 機密情報は環境変数で管理
export KINDLEGEN_PATH="/secure/path/to/kindlegen"

# .env ファイルは .gitignore に追加
echo ".env" >> .gitignore
```

### スクリプトの権限管理

```bash
# 実行権限のみを付与（書き込み権限は削除）
chmod 755 *.sh

# 読み取り専用ファイル
chmod 644 *.md *.mdc
```

## 🤝 コラボレーション

### プルリクエストのガイドライン

1. **ブランチ命名**: `feature/`, `fix/`, `docs/` プレフィックスを使用
2. **説明**: 変更内容と理由を明確に記載
3. **テスト**: 新機能にはテストを追加
4. **ドキュメント**: 必要に応じてREADMEを更新

### コードレビューのポイント

- シェルスクリプトの安全性（`set -euo pipefail`の使用）
- エラーハンドリングの適切性
- ログメッセージの分かりやすさ
- パフォーマンスへの影響

---

**最終更新**: 2025年1月23日  
**対象バージョン**: v1.0.0
