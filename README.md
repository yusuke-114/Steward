**English** · [简体中文](README.zh.md) · [日本語](README.ja.md)

<p align="center">
  <img src="docs/assets/steward-icon.png" alt="Steward icon" width="96">
</p>

# Steward

Drive Claude Code on your Mac from Telegram on your phone.

You send a message while away from your desk; Claude Code works on the Mac; approval requests land back on your phone.

![Steward connection settings](docs/assets/steward-screenshot.png)

## Read First

**Anyone who can message your Steward bot can run commands on your Mac.**

Steward runs outside the macOS sandbox and acts as your user account. Use it only with a private Telegram bot, keep the bot token secret, and keep the Telegram user ID allow list strict.

Full safety, privacy, setup, usage, and limitation notes are on the [Safety & Privacy page](privacy.html).

## Requirements

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code), installed and signed in
- A Telegram bot token and your own Telegram user ID

## Known Issue

Steward 1.0 is currently incompatible with Claude Code 2.1.144. If the app shows `Claude session exited (1)` immediately after connecting, wait for a Steward update before using it with that Claude Code version.

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
