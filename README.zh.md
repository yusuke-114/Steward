[English](README.md) · **简体中文** · [日本語](README.ja.md)

# Steward

从手机上的 Telegram 操作你 Mac 上的 Claude Code。

人在外面，发条消息就能让 Claude 干活。它要动手改东西时，请求会推到你手机上等你点头。

---

## ⚠️ 先读这一段

**能给这个 bot 发消息的人，就能在你的 Mac 上执行任意命令。**

Steward 以你的身份运行、不在沙箱里，能做的事和你坐在电脑前一样。唯一的防线是 **Telegram user ID 白名单**——不在列表里的账号，消息被静默丢弃。

- bot token 要当密码保管。泄漏了去 [@BotFather](https://t.me/botfather) 用 `/revoke` 作废重发
- 别把白名单留空，也别加不认识的人
- 当前版本 token 明文存在 `~/Library/Preferences/`（权限 600，未加密）

---

## 需要什么

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code) 已安装并登录
- 一个 Telegram bot token + 你自己的 user ID

Steward 会自动在 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 里找 `claude`，找不到可以在设置里手填路径。

## 安装

```bash
brew install --cask steward
```

或从 [Releases](../../releases) 下载 DMG。

## 配置

1. 找 [@BotFather](https://t.me/botfather) 发 `/newbot`，拿到 token
2. 找 [@userinfobot](https://t.me/userinfobot) 发任意消息，拿到你的数字 ID
3. 打开 Steward → **Connection** 填 token 和 user ID → **Projects** 添加项目目录
4. 点 **Connect**，手机上发 `/status` 验证

---

## 怎么用

| 发什么 | 结果 |
|---|---|
| 任意文字 | 交给 Claude Code |
| `!命令` | 直接在项目目录执行 shell |
| `/project` | 列出所有项目 |
| `/project 名字` | 切换项目 |
| `/stop` `/status` `/help` | 停止 / 状态 / 帮助 |

**`!` 前缀不经过权限确认**——那是你自己明确要跑的。想保留确认就正常说「帮我跑一下 xxx」。

会话是连续的：切走再切回、重启 app、`claude` 崩溃后重连，都会接上之前的对话。

## 权限

不在白名单里的工具，每次调用都推到你手机上：

```
🔐 Approval needed

Bash
rm -rf build/

Reply: 1 allow / 0 deny / 2 always allow
```

回 `1`/`yes` 允许，`0`/`no` 拒绝，`2`/`always` 本次会话内始终允许。**5 分钟没人答自动拒绝**并通知你。

默认白名单只有只读操作：`Read` `Grep` `Glob` `TodoWrite`。在 **Permissions** 里可以调整，其中 **`Bash` 需要单独确认才能开启**——它是唯一一个把这个 app 变成「无人值守的任意代码执行」的开关。

也可以加更窄的规则如 `Bash(rake swiftformat)`。**这些原样传给 Claude Code，Steward 不校验**——匹配多宽由 Claude Code 决定，不确定就别放行。

## 排查

| 问题 | 怎么办 |
|---|---|
| 找不到 Claude Code | 装一个，或在设置里手填 `which claude` 的路径 |
| 无法验证开发者 | 系统设置 → 隐私与安全性 → 仍要打开 |
| 发消息没反应 | 看 **Logs** 栏——每条消息、路由、权限请求、退出码都在那 |
| Token 无效 | 状态会显示无效并停止轮询，去 BotFather 确认 |

---

## 隐私

Steward 不收集任何数据：无埋点、无分析、无崩溃上报，日志只存内存。唯一的出站请求是 Telegram Bot API。

你的消息经过 Telegram，你发给 Claude 的内容经由本机 `claude` 进程送往 Anthropic。详见 [隐私政策](privacy.zh.html)。

## 已知限制

- 同一时刻只有一个活跃会话（可切项目，不能并行）
- 不上架 Mac App Store（沙箱下无法执行用户装的 `claude`）
- 细粒度规则的匹配语义未经验证
- 无自动更新

---

## 它是怎么工作的

```
Telegram ──长轮询──▶ Steward ──▶ claude -p --output-format stream-json
                        ▲
                        └──curl── PreToolUse hook（阻塞等你回答）
```

Claude Code 的 headless 模式起一个子进程，结构化事件流收发消息。权限请求走 PreToolUse hook：hook 阻塞着把请求 POST 到 Steward 的本地端点，Steward 推到你手机，答案原路返回。

**三层超时严格递增**，任何一层单独改动都可能破坏保证：

```
Steward 等你回答 300s  <  hook 的 curl 570s  <  Claude 给 hook 的超时 600s
```

Steward 必须最先超时，这样「拒绝」是由它作出并记进日志的，而不是由一个说不清自己为什么失败的脚本凭空捏造。

**所有失败都向「拒绝」倒。** hook 联系不上 Steward、响应损坏、读不到输入——每条路径都输出明确的拒绝并正常退出。因为你人在手机上：误拒能重试，永久挂死无法诊断。

---

## License

Apache License 2.0。详见 [LICENSE](LICENSE)。
