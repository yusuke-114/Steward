**English** · [简体中文](README.zh.md) · [日本語](README.ja.md)

# Steward

Drive Claude Code on your Mac from Telegram on your phone.

You send a message while away from your desk; Claude Code works on the Mac; approval requests land back on your phone.

## Read First

**Anyone who can message your Steward bot can run commands on your Mac.**

Steward runs outside the macOS sandbox and acts as your user account. Use it only with a private Telegram bot, keep the bot token secret, and keep the Telegram user ID allow list strict.

Full safety, privacy, setup, usage, and limitation notes are on the [Safety & Privacy page](privacy.html).

## Requirements

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code), installed and signed in
- A Telegram bot token and your own Telegram user ID

## Install

```bash
brew install --cask yusuke-114/tap/steward
```

To uninstall:

```bash
brew uninstall --cask steward
```

Or download the ZIP from [Releases](../../releases).

## Quick Setup

1. Create a bot with [@BotFather](https://t.me/botfather) and copy the token.
2. Get your numeric Telegram user ID from [@userinfobot](https://t.me/userinfobot).
3. Open Steward, add the token, allow-listed user ID, and a project folder.
4. Press **Connect**, then send `/status` from Telegram.

## Links

- [Safety & Privacy](privacy.html)
- [License](LICENSE)
