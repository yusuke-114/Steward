[English](README.md) · **简体中文** · [日本語](README.ja.md)

<p>
  <img src="docs/assets/steward-icon.png" alt="Steward icon" width="96">
</p>

# Steward

从手机上的 Telegram 操作你 Mac 上的 Claude Code。

人在外面发一条消息，Claude Code 在 Mac 上工作；需要确认的操作会推回你的手机。

![Steward 连接设置](docs/assets/steward-screenshot.png)

## 先读

**能给你的 Steward bot 发消息的人，就能在你的 Mac 上执行命令。**

Steward 不在 macOS 沙箱内运行，并以你的用户身份行动。只应该配合私有 Telegram bot 使用，妥善保管 bot token，并严格设置 Telegram user ID 白名单。

完整的安全、隐私、配置、使用和限制说明见 [安全与隐私页面](privacy.zh.html)。

## Steward 与 Remote Control、Dispatch

| | Steward | [Remote Control](https://code.claude.com/docs/en/remote-control) | [Dispatch](https://claude.com/docs/cowork/guide/dispatch) |
|---|---|---|---|
| 支持任意登录方式（API key、Bedrock、Vertex AI、公司网关） | ✅ | ❌ 仅 claude.ai 订阅 | ❌ 仅 Pro / Max |
| 手机上开新会话 | ✅ | ❌ 只能接着用 Mac 上已开的会话 | ✅ |
| 手机上切换项目 | ✅ `/project` | ❌ | ✅ |
| 直接执行 shell 命令 | ✅ `!git status` | ❌ 需经 Claude | ❌ 需经 Claude |

Steward 不接触 Claude 的登录凭据，直接沿用 `claude` 现有的登录。

对比基于 2026 年 9 月的官方文档。

## 需要什么

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code) 已安装并登录
- 一个 Telegram bot token 和你自己的 Telegram user ID

## 安装

```bash
brew install --cask yusuke-114/tap/steward
```

升级到最新版：

```bash
brew upgrade --cask steward
```

卸载（请用这条命令，不要直接把 app 拖进废纸篓）：

```bash
brew uninstall --cask steward
```

或从 [Releases](../../releases) 下载 ZIP。

### 安装失败：`App source '/Applications/Steward.app' is not there`

说明之前是直接把 Steward 拖进了废纸篓，Homebrew 还以为它装着。运行下面这条命令即可重新安装，你的设置会保留：

```bash
brew uninstall --cask --force steward && brew install --cask yusuke-114/tap/steward
```

## 快速配置

1. 用 [@BotFather](https://t.me/botfather) 创建 bot，复制 token。
2. 用 [@userinfobot](https://t.me/userinfobot) 获取你的数字 Telegram user ID。
3. 打开 Steward，填入 token、白名单 user ID，并添加项目目录。
4. 点击 **Connect**，然后从 Telegram 发送 `/status` 验证。

## 链接

- [安全与隐私](privacy.zh.html)
- [许可证](LICENSE)
