#!/bin/bash
# hook.sh 的失败路径矩阵。
#
# 为什么不放在 Swift 测试目标里：在 GUI 宿主的 XCTest 进程里驱动一个会 fork
# curl/jq/date 的 shell 脚本，实测会产生两类与产品无关的挂死（脚手架在超时
# 路径上 readDataToEndOfFile 永久阻塞；hook.sh 本身在测试宿主下不退出）。
# 而 Claude Code 在生产里就是从一个普通进程 spawn hook.sh 的——本脚本的调用
# 方式与生产一致，比 XCTest 里那套更贴近真实。
#
# 用法：Tests/hook-failure-matrix.sh
# 退出码 0 表示全部通过，非 0 表示有用例失败。

set -u
# 可用 HOOK_UNDER_TEST 指向别的脚本——验证本矩阵自身能否抓到坏实现时需要。
HOOK="${HOOK_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)/cli-ai-from-phone/Permission/hook.sh}"
PASS=0; FAIL=0
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# 断言 stdout 里的 permissionDecision 等于期望值，且退出码为 0。
expect_decision() {
  local label="$1" expected="$2" stdout="$3" code="$4"
  local got
  # 严格解析：必须是合法 JSON 且 permissionDecision 位于 hookSpecificOutput 之内，
  # 不接受出现在 stdout 任意位置的同名子串。
  got=$(printf '%s' "$stdout" | python3 -c '
import sys, json
for line in sys.stdin.read().splitlines():
    try:
        o = json.loads(line)
    except Exception:
        continue
    v = o.get("hookSpecificOutput", {}).get("permissionDecision")
    if v:
        print(v); break
' 2>/dev/null)
  if [ "$got" = "$expected" ] && [ "$code" = "0" ]; then
    echo "  ✓ $label → $got (exit $code)"; PASS=$((PASS+1))
  else
    echo "  ✗ $label → 期望 decision=$expected exit=0，实得 decision=${got:-<空>} exit=$code"
    echo "      stdout: ${stdout:-<空>}"; FAIL=$((FAIL+1))
  fi
}

# 在后台起一个只回一次固定响应的 mock server，回显它的端口。
start_mock() {
  local body="$1" portfile
  portfile=$(mktemp)
  python3 - "$body" "$portfile" <<'PY' &
import socket, sys, threading
body, portfile = sys.argv[1], sys.argv[2]
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
# accept 必须有超时：若被测脚本在发起 curl 之前就崩掉/静默退出，
# 无超时的 accept 会让本矩阵永久挂起——一个会挂死的门禁等于没有门禁。
s.settimeout(15)
open(portfile, "w").write(str(s.getsockname()[1]))
def serve():
    try:
        c, _ = s.accept()
    except socket.timeout:
        s.close(); return
    c.recv(65536)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
              % (len(body.encode()), body.encode()))
    c.close(); s.close()
threading.Thread(target=serve).start()
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$portfile" ] && break; sleep 0.1; done
  MOCK_PORT=$(cat "$portfile"); rm -f "$portfile"
}

# 有界回收 mock server：即使它还在 accept 上等，也不许拖住整个矩阵。
stop_mock() {
  local waited=0
  while kill -0 "$MOCK_PID" 2>/dev/null && [ "$waited" -lt 20 ]; do
    sleep 0.5; waited=$((waited+1))
  done
  kill -9 "$MOCK_PID" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
}

echo "hook.sh 失败路径矩阵"
echo "脚本: $HOOK"
echo ""

echo "[1] 未提供 MACBOT_PORT"
OUT=$(printf '%s' "$INPUT" | env -u MACBOT_PORT MACBOT_STDIN_TIMEOUT_SECS=3 bash "$HOOK" 2>/dev/null); CODE=$?
expect_decision "无端口" "deny" "$OUT" "$CODE"

echo "[2] 端口已设但无人监听"
OUT=$(printf '%s' "$INPUT" | MACBOT_PORT=59999 MACBOT_STDIN_TIMEOUT_SECS=3 bash "$HOOK" 2>/dev/null); CODE=$?
expect_decision "控制端离线" "deny" "$OUT" "$CODE"

echo "[3] stdin 永不关闭（Critical：必须有界，不得永久挂起）"
# 用命名管道而不是 `writer | hook`：管道写法下命令替换要等整条管道结束，
# 也就是要等 writer 睡完，测出来的是 writer 的寿命而不是 hook.sh 的耗时。
# FIFO 让 writer 只负责把写端按住，计时只包住 hook.sh 自己。
FIFO=$(mktemp -u); mkfifo "$FIFO"
sleep 60 > "$FIFO" &
WPID=$!
START=$(date +%s)
OUT=$(MACBOT_PORT=59999 MACBOT_STDIN_TIMEOUT_SECS=3 bash "$HOOK" < "$FIFO" 2>/dev/null); CODE=$?
ELAPSED=$(( $(date +%s) - START ))
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null; rm -f "$FIFO"
expect_decision "stdin 超时（耗时 ${ELAPSED}s）" "deny" "$OUT" "$CODE"
if [ "$ELAPSED" -gt 10 ]; then
  echo "  ✗ 耗时 ${ELAPSED}s 远超 3s 阈值——有界读取失效"; FAIL=$((FAIL+1))
else
  echo "  ✓ 有界性确认：${ELAPSED}s 内返回，未等到 writer 的 60s"; PASS=$((PASS+1))
fi

echo "[4] 合法应答原样透传"
start_mock '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"来自 Telegram"}}'
OUT=$(printf '%s' "$INPUT" | MACBOT_PORT=$MOCK_PORT MACBOT_STDIN_TIMEOUT_SECS=3 bash "$HOOK" 2>/dev/null); CODE=$?
stop_mock
expect_decision "allow 透传" "allow" "$OUT" "$CODE"

echo "[5] 畸形响应必须被拒绝，不得原样交给 Claude"
start_mock 'this is not json at all {{{'
OUT=$(printf '%s' "$INPUT" | MACBOT_PORT=$MOCK_PORT MACBOT_STDIN_TIMEOUT_SECS=3 bash "$HOOK" 2>/dev/null); CODE=$?
stop_mock
expect_decision "畸形响应" "deny" "$OUT" "$CODE"

echo ""
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
