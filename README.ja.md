[English](README.md) · [简体中文](README.zh.md) · **日本語**

<p align="center">
  <img src="docs/assets/steward-icon.png" alt="Steward icon" width="96">
</p>

# Steward

スマホの Telegram から、Mac 上の Claude Code を動かします。

外出先でメッセージを送ると Claude Code が Mac で作業し、確認が必要な操作はスマホに届きます。

![Steward 接続設定](docs/assets/steward-screenshot.png)

## 最初に読んでください

**Steward bot にメッセージを送れる人は、あなたの Mac でコマンドを実行できます。**

Steward は macOS サンドボックス外で、あなたのユーザー権限として動作します。必ず非公開の Telegram bot と組み合わせ、bot token を秘密に保ち、Telegram ユーザー ID の許可リストを厳密に設定してください。

安全、プライバシー、セットアップ、使い方、制限事項の詳細は [Safety & Privacy ページ](privacy.ja.html) をご覧ください。

## 必要なもの

- macOS 26.0 以降
- [Claude Code](https://claude.com/claude-code)（インストール済み、ログイン済み）
- Telegram bot token と自分の Telegram ユーザー ID

## インストール

```bash
brew install --cask yusuke-114/tap/steward
```

アンインストール:

```bash
brew uninstall --cask steward
```

または [Releases](../../releases) から ZIP をダウンロードしてください。

## クイックセットアップ

1. [@BotFather](https://t.me/botfather) で bot を作成し、token をコピーします。
2. [@userinfobot](https://t.me/userinfobot) で自分の数値 Telegram ユーザー ID を取得します。
3. Steward を開き、token、許可するユーザー ID、プロジェクトフォルダを追加します。
4. **Connect** を押し、Telegram から `/status` を送って確認します。

## リンク

- [Safety & Privacy](privacy.ja.html)
- [License](LICENSE)
