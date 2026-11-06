#!/bin/bash
# PreToolUse hook：把权限请求转给 app，阻塞等应答。
#
# 关键：任何失败路径都必须输出一个合法的 deny。
# 若此脚本静默退出或挂死，Claude 会永久僵在这次工具调用上，
# 用户在手机上只看到「没反应」，且无从诊断。宁可误拒，不可死锁。
#
# 三层超时必须保持这个顺序，任何一层单独改动都可能打破 fail-closed 保证：
#   PermissionBridge 300s（app 侧，Swift 里的默认值）
#     < curl --max-time 570s（本脚本，下面）
#     < Claude 对这个 hook 声明的 timeout 600s（HookSettings.swift 里写死）
# 原因：
#   - 300 < 570：手机没人应答时，deny 决定必须由 app 的 PermissionBridge 作出
#     （可记日志、可解释），而不是本脚本因为网络挂起而自己编一个"离线或超时"。
#   - 570 < 600：Claude Code 自己给这个 hook 进程记的时钟，从进程一启动就开始
#     走（比 curl 实际发起请求要早），如果 curl 的上限和 Claude 声明的上限相
#     等甚至更大，Claude 会在本脚本的 deny() 还没来得及打印之前就把整个 hook
#     进程 SIGTERM/SIGKILL 掉——那样连"deny"两个字都输出不出来，是比误拒更坏
#     的静默死亡。留出的 30s 差额，用来覆盖脚本自身的启动、stdin 读取、jq 校验
#     等开销，保证脚本总能在 Claude 动手之前自己说完最后一句话。

# stdin 读取的超时秒数，可用环境变量覆盖（仅供测试用，生产不设置，用默认值）。
STDIN_TIMEOUT="${MACBOT_STDIN_TIMEOUT_SECS:-10}"

deny() {
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"
  exit 0
}

# --- 读取 stdin，且必须有界 ---
#
# 之前的实现是裸 `input=$(cat)`：这是全脚本唯一没有超时保护、且跑在所有
# fail-closed 逻辑之前的阻塞点。它的正确性完全依赖一个从未被验证过的假设——
# "Claude Code 总会在写完 hook 输入后关闭 stdin 的写端"。cli-contracts.md
# 没有记录这个假设，也没有人实测过。这个假设一旦不成立，`cat` 会永远等
# EOF，deny() 永远不会被跑到。
#
# macOS 默认没有 GNU coreutils 的 `timeout(1)`，不能假设它存在。最初尝试的
# "把 cat 放到后台 + 看门狗轮询杀掉它"的办法实测是错的：非交互脚本里默认没
# 开 job control，bash 会把异步（`&`）命令的 stdin 自动重定向到 /dev/null
# （这是 bash 文档里记载的行为，不是这次才发现的 bug），导致背景里的 cat
# 立刻在 /dev/null 上拿到 EOF，跟真正的 stdin 是否关闭毫无关系——看门狗永远
# 逮不到真正卡住的情况。改用 `read -t` 直接读：它是内建命令，天然带超时，
# 不依赖后台进程，也就不会撞上这个 /dev/null 重定向的坑。
#
# 注意 bash 3.2（macOS 系统自带版本）的 `read -t` 超时和"读到 EOF 但没找到
# 分隔符"这两种情况返回码都是失败，无法单纯靠返回码区分；这里改用"实际耗时
# 是否达到超时阈值"来判定——真正的 Claude 调用应当在毫秒级把这几百字节的
# JSON 写完并关闭 stdin，只要读入耗时逼近 STDIN_TIMEOUT，就应当当成异常直接
# deny，而不是继续沿用可能不完整的 $input 往下走。
read_start=$(date +%s)
IFS= read -r -t "$STDIN_TIMEOUT" -d '' input
read_elapsed=$(( $(date +%s) - read_start ))
if [ "$read_elapsed" -ge "$STDIN_TIMEOUT" ]; then
  deny "读取 stdin 超时（Claude 未按预期关闭 hook 的标准输入）"
fi

[ -z "$MACBOT_PORT" ] && deny "控制端未提供端口"

command -v curl >/dev/null 2>&1 || deny "curl 不可用"

# --max-time 570：必须小于 Claude 声明给这个 hook 的 timeout（600，见上方
# 注释与 HookSettings.swift），否则 Claude 会先把本进程杀掉，deny() 根本
# 没机会打印。
response=$(curl -s --max-time 570 \
  -X POST "http://127.0.0.1:${MACBOT_PORT}/permission" \
  -H 'Content-Type: application/json' \
  -d "$input" 2>/dev/null)

[ -z "$response" ] && deny "控制端离线或超时"

# 若 jq 可用，校验响应是合法 JSON 且带有 permissionDecision 字段，
# 避免把损坏的响应（如连接中途被断开的半截 JSON）原样交给 Claude。
# jq 不可用时不做这层校验（不因缺少校验工具本身而拒绝一切请求）。
if command -v jq >/dev/null 2>&1; then
  echo "$response" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1 \
    || deny "控制端返回了无法解析的响应"
fi

echo "$response"
