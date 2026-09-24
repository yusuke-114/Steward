**English** · [简体中文](README.zh.md) · [日本語](README.ja.md)

# Steward

Drive Claude Code on your Mac from Telegram on your phone.

You're out, you send a message, Claude gets to work. When it wants to change something, the request lands on your phone for approval.

---

## ⚠️ Read this first

**Anyone who can message this bot can run any command on your Mac.**

Steward runs as you, outside the sandbox — it can do whatever you could do sitting at the keyboard. The only thing standing in the way is the **Telegram user ID allow list**: messages from anyone else are dropped silently.

- Treat the bot token like a password. If it leaks, revoke it with `/revoke` at [@BotFather](https://t.me/botfather)
- Never leave the allow list empty, and never add someone you don't know
- In this version the token is stored in plain text under `~/Library/Preferences/` (mode 600, not encrypted)

---

## Requirements

- macOS 26.0+
- [Claude Code](https://claude.com/claude-code), installed and signed in
- A Telegram bot token and your own user ID

Steward looks for `claude` in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. If it isn't there, set the path in Settings.

## Install

```bash
brew install --cask steward
```

Or download the DMG from [Releases](../../releases).

## Setup

1. Message [@BotFather](https://t.me/botfather), send `/newbot`, copy the token
2. Message [@userinfobot](https://t.me/userinfobot), copy your numeric ID
3. Open Steward → **Connection**: paste the token and your ID → **Projects**: add a project folder
4. Hit **Connect**, then send `/status` from your phone to check

---

## Usage

| Send | Result |
|---|---|
| Any text | Goes to Claude Code |
| `!command` | Runs a shell command in the project folder |
| `/project` | Lists your projects |
| `/project name` | Switches project |
| `/stop` `/status` `/help` | Stop / status / help |

**The `!` prefix skips approval** — that's a command you typed deliberately. If you want the approval step, just ask normally ("run swiftformat for me") without the prefix.

Sessions are continuous: switch away and back, restart the app, or recover from a `claude` crash — the conversation picks up where it left off.

## Permissions

Any tool not on the allow list gets pushed to your phone on every call:

```
🔐 Approval needed

Bash
rm -rf build/

Reply: 1 allow / 0 deny / 2 always allow
```

Reply `1`/`yes` to allow, `0`/`no` to deny, `2`/`always` to allow for the rest of the session. **After 5 minutes with no answer it auto-denies** and tells you.

The default allow list is read-only tools only: `Read` `Grep` `Glob` `TodoWrite`. Adjust it under **Permissions** — note that **`Bash` takes a separate confirmation to enable**, because it is the one switch that turns this app into unattended arbitrary code execution.

You can also add narrower rules like `Bash(rake swiftformat)`. **These are passed to Claude Code exactly as written; Steward does not validate them** — how broadly a pattern matches is Claude Code's decision, so if you're unsure, don't grant it.

## Troubleshooting

| Problem | Fix |
|---|---|
| Claude Code not found | Install it, or paste the output of `which claude` into Settings |
| "Developer cannot be verified" | System Settings → Privacy & Security → Open Anyway |
| No response from the bot | Check the **Logs** tab — every message, route, approval and exit code is there |
| Invalid token | The status shows an invalid token and stops polling; check with BotFather |

---

## Privacy

Steward collects nothing: no analytics, no telemetry, no crash reporting. Logs live in memory only. The only outbound request it makes is to the Telegram Bot API.

Your messages travel through Telegram, and what you send to Claude goes to Anthropic via the local `claude` process. See the [privacy policy](privacy.html).

## Known limitations

- One active session at a time (you can switch projects, not run them in parallel)
- Not on the Mac App Store (the sandbox can't execute a `claude` you installed yourself)
- The matching semantics of scoped rules are unverified
- No auto-update

---

## How it works

```
Telegram ──long poll──▶ Steward ──▶ claude -p --output-format stream-json
                           ▲
                           └──curl── PreToolUse hook (blocks until you answer)
```

Claude Code's headless mode runs as a subprocess and speaks a structured event stream. Approvals go through a PreToolUse hook: the hook blocks while POSTing the request to Steward's local endpoint, Steward pushes it to your phone, and your answer travels back the same way.

**Three timeouts, strictly increasing.** Changing any one of them in isolation can break the guarantee:

```
Steward waits for you 300s  <  the hook's curl 570s  <  Claude's hook timeout 600s
```

Steward has to time out first, so that a denial is a decision it made and logged — not something a script invented because it couldn't explain its own failure.

**Every failure falls toward denial.** The hook can't reach Steward, the response is corrupt, stdin never closes — every path prints an explicit denial and exits cleanly. You're on a phone: a wrong denial you can retry, a permanent hang you cannot diagnose.

---

## License

Apache License 2.0. See [LICENSE](LICENSE).
