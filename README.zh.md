[English](README.md) · **简体中文** · [日本語](README.ja.md)

# Steward

从手机上的 Telegram 操作你 Mac 上的 Claude Code。

人在外面发一条消息，Claude Code 在 Mac 上工作；需要确认的操作会推回你的手机。

## 先读

**能给你的 Steward bot 发消息的人，就能在你的 Mac 上执行命令。**

Steward 不在 macOS 沙箱内运行，并以你的用户身份行动。只应该配合私有 Telegram bot 使用，妥善保管 bot token，并严格设置 Telegram user ID 白名单。

完整的安全、隐私、配置、使用和限制说明见 [安全与隐私页面](privacy.zh.html)。

## 需要什么

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code) 已安装并登录
- 一个 Telegram bot token 和你自己的 Telegram user ID

## 安装

```bash
brew install --cask yusuke-114/tap/steward
```

卸载：

```bash
brew uninstall --cask steward
```

或从 [Releases](../../releases) 下载 ZIP。

## 快速配置

1. 用 [@BotFather](https://t.me/botfather) 创建 bot，复制 token。
2. 用 [@userinfobot](https://t.me/userinfobot) 获取你的数字 Telegram user ID。
3. 打开 Steward，填入 token、白名单 user ID，并添加项目目录。
4. 点击 **Connect**，然后从 Telegram 发送 `/status` 验证。

## 链接

- [安全与隐私](privacy.zh.html)
- [许可证](LICENSE)
