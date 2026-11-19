#!/usr/bin/env bash
# 调度看板自测：临时仓库 + 假 herdr，覆盖阶段推导、批归属、合入后记账。
# 用法：scripts/tests/board-test.sh（不碰真实 herdr 与任何已有仓库）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
L="$HERE/lane.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# ---- 假 herdr：agent / pane 数据来自 $TMP/agents.json、$TMP/panes.json ----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_SLOW:-}" ] || sleep "$FAKE_SLOW"
case "$1 $2" in
  "workspace get") printf '{"result":{"workspace":{"workspace_id":"%s","worktree":{"checkout_path":"%s"}}}}' "$3" "$FAKE_INTEG" ;;
  "pane list") printf '{"result":{"panes":%s}}' "$(cat "$FAKE_DIR/panes.json")" ;;
  "agent list") printf '{"result":{"agents":%s}}' "$(cat "$FAKE_DIR/agents.json")" ;;
  "tab close") echo '{}' ;;
  "tab list") printf '{"result":{"tabs":[{"tab_id":"w9:t1"}]}}' ;;
  "worktree remove") echo "worktree remove $*" >> "$FAKE_DIR/removed.log"; echo '{}' ;;
  *) echo "fake herdr: 未实现 $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/herdr"
export PATH="$TMP/bin:$PATH" FAKE_DIR="$TMP"

# ---- 仓库、集成 worktree（模拟 lane.sh space 的产物）----
REPO="$TMP/Repo"
git init -q -b master "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
INTEG="$TMP/Repo-worktrees/space-demo/Repo"
git -C "$REPO" worktree add -q -b feat/demo "$INTEG" master
export FAKE_INTEG="$INTEG"
echo "[{\"pane_id\":\"w9:p1\",\"tab_id\":\"w9:t1\",\"cwd\":\"$INTEG\"}]" > "$TMP/panes.json"
echo '[]' > "$TMP/agents.json"

export LANE_MIN_FREE_GB=0
cd "$REPO"
WT=$("$L" new demo-t1 --base feat/demo 2>/dev/null)
OTHER=$("$L" new other-x --base master 2>/dev/null)   # 别的批，不应出现在看板
# 调用方把 stderr 并进来也只能拿到路径
MIXED=$("$L" new mixed-x --base master 2>&1)
[ "$MIXED" = "$(dirname "$(dirname "$WT")")/mixed-x/$(basename "$WT")" ] && ok "new 的 stdout+stderr 合并后只有路径" || bad "new 合并输出后不是纯路径：$(printf '%s' "$MIXED" | head -c 200)"

board_json() { "$L" board w9 --json; }
field() { board_json | python3 -I -c "import json,sys; d=json.load(sys.stdin); l=[x for x in d['lanes'] if x['lane']=='$1']; print(l[0]['$2'] if l else 'MISSING')"; }
expect() { local got; got="$(field "$1" "$2")"; [ "$got" = "$3" ] && ok "$4（${got}）" || bad "$4：期望 $3，实际 ${got}"; }
at() { python3 -I -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),)*2)' "$1" "$2"; }

expect demo-t1 stage 准备中 "无 TASK.md → 准备中"
[ "$(field other-x stage)" = MISSING ] && ok "其他批的 lane 不显示" || bad "其他批的 lane 出现在看板"

printf '# demo T1：修复会话被重连拉起\n\n正文\n' > "$WT/TASK.md"; at "$WT/TASK.md" 1000
expect demo-t1 title 修复会话被重连拉起 "从 TASK.md 首行取线标题"
expect demo-t1 stage 待启动 "有 TASK.md、无 agent → 待启动"

echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"working\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
expect demo-t1 stage 执行中 "agent 在跑、无 REPORT → 执行中"
expect demo-t1 agent demo-t1-codex "agent 按 cwd 归到线"

printf '## 状态：待裁定\n' > "$WT/REPORT.md"; at "$WT/REPORT.md" 2000
echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"idle\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
expect demo-t1 stage 待裁定 "REPORT 待裁定 → 待裁定"
expect demo-t1 attention True "待裁定标为轮到指挥"
at "$WT/TASK.md" 3000
expect demo-t1 stage 待裁定 "只改了 TASK.md、agent 未在跑 → 仍待裁定"
echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"working\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
expect demo-t1 stage 执行中 "裁定后 agent 在跑 → 执行中"

printf '## 状态：完成\n' > "$WT/REPORT.md"; at "$WT/REPORT.md" 4000
expect demo-t1 stage 待验收 "REPORT 完成 → 待验收"
printf '1. 问题\n' > "$WT/REVIEW.md"; at "$WT/REVIEW.md" 5000
expect demo-t1 stage 返工中 "REVIEW 比 REPORT 新 → 返工中"
at "$WT/REPORT.md" 6000
expect demo-t1 stage 待验收 "返工后更新 REPORT → 待验收"

echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"blocked\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
expect demo-t1 stage 受阻 "agent blocked → 受阻"
echo '[]' > "$TMP/agents.json"

# wait：阻塞到出现新的轮到指挥才返回；启动时已在轮到指挥的线不算新变化
WAIT_OUT="$TMP/wait.out"
set +e; "$L" wait w9 --interval 0.2 --timeout 1 > "$WAIT_OUT" 2>&1; rc=$?; set -e
[ "$rc" -eq 124 ] && ok "wait 启动时已待验收不触发，超时退出码 124" || bad "wait 超时退出码：$rc $(head -c 200 "$WAIT_OUT")"

mv "$WT/REPORT.md" "$TMP/REPORT.bak"
echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"working\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
"$L" wait w9 --interval 0.2 --timeout 10 > "$WAIT_OUT" 2>&1 & wait_pid=$!
python3 -I -c 'import time; time.sleep(0.6)'
echo "[{\"name\":\"demo-t1-codex\",\"agent\":\"codex\",\"agent_status\":\"idle\",\"pane_id\":\"w9:p2\",\"cwd\":\"$WT\"}]" > "$TMP/agents.json"
set +e; wait "$wait_pid"; rc=$?; set -e
[ "$rc" -eq 0 ] && grep -q "新轮到指挥：demo-t1 停下（无 REPORT）" "$WAIT_OUT" \
  && ok "wait：agent 停下没写 REPORT 时返回" || bad "wait 停下无报告：$rc $(head -c 300 "$WAIT_OUT")"

"$L" wait w9 --interval 0.2 --timeout 10 > "$WAIT_OUT" 2>&1 & wait_pid=$!
python3 -I -c 'import time; time.sleep(0.6)'
mv "$TMP/REPORT.bak" "$WT/REPORT.md"; at "$WT/REPORT.md" 7000
set +e; wait "$wait_pid"; rc=$?; set -e
[ "$rc" -eq 0 ] && grep -q "新轮到指挥：demo-t1 待验收" "$WAIT_OUT" && grep -q "轮到指挥：" "$WAIT_OUT" \
  && ok "wait：写出 REPORT 完成后返回并附看板" || bad "wait 待验收：$rc $(head -c 300 "$WAIT_OUT")"
echo '[]' > "$TMP/agents.json"

git -C "$WT" commit -q --allow-empty -m "fix: 一个提交"
expect demo-t1 commits 1 "提交数按切出点计"

# 文本输出能渲染
COLUMNS=140 "$L" board w9 | grep -q "轮到指挥：demo-t1 待验收" && ok "文本看板列出轮到指挥的线" || bad "文本看板缺少轮到指挥"

# 窄屏（手机客户端窗格约 44 列）：每行不超宽，线名去掉批主题前缀，轮到指挥在第二行
narrow="$(COLUMNS=44 "$L" board w9)"
printf '%s\n' "$narrow" | python3 -I -c '
import sys,unicodedata
w=lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
bad=[l for l in sys.stdin.read().splitlines() if w(l)>44]
sys.exit(1 if bad else 0)' && ok "44 列下每行不超宽" || bad "44 列下有行超宽"
printf '%s\n' "$narrow" | grep -q '^\[待验收\] t1 · ' && ok "窄屏线名去掉主题前缀" || bad "窄屏线名：$(printf '%s' "$narrow" | sed -n 4p)"
[ "$(printf '%s\n' "$narrow" | sed -n 2p)" = "轮到指挥：t1 待验收" ] && ok "窄屏轮到指挥在顶部" || bad "窄屏第二行：$(printf '%s' "$narrow" | sed -n 2p)"
COLUMNS=140 "$L" board w9 | grep -q '^线 ' && ok "宽屏用表格" || bad "宽屏没有表头"

# 常驻模式：伪终端从 196 列缩到 46 列，不等刷新周期（30 秒）就按卡片重画，且每行不超宽
python3 -I - "$L" <<'PY' && ok "常驻模式缩窄后 2 秒内按卡片重画，SIGTERM 退出时恢复终端" || bad "常驻模式缩窄重画或退出恢复失败"
import fcntl, os, pty, re, select, struct, sys, termios, time
def setsize(fd, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, cols, 0, 0))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], [sys.argv[1], "board", "w9", "--watch", "30"])
setsize(fd, 196)
def read_for(sec):
    buf, end = b"", time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: break
    return buf.decode("utf-8", "replace")
read_for(1.5)                      # 首屏（宽屏或卡片都行，丢弃）
setsize(fd, 46)                    # 内核对前台进程组发 SIGWINCH
out = read_for(2)
os.kill(pid, 15)                   # 关 tab 时发的信号
tail = read_for(1)                 # macOS 退出时要等 pty 输出被读走，必须继续读
os.waitpid(pid, 0)
frame = out.split("\x1b[H\x1b[2J")[-1]
plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07", "", frame)
import unicodedata
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
lines = [l for l in plain.replace("\r", "").split("\n") if l]
restored = "\x1b[?7h\x1b[?1049l" in tail   # 退出时恢复自动换行并离开备用屏
ok = restored and bool(lines) and lines[0].startswith("w9 · feat/demo") and all(w(l) <= 46 for l in lines)
sys.exit(0 if ok else 1)
PY

# 采集数据期间连续改尺寸（手机附着时会这样）：看板不能崩，最后一帧按最终宽度
FAKE_SLOW=0.3 python3 -I - "$L" <<'PY' && ok "采集期间收到尺寸变化不崩溃，按最终宽度重画" || bad "采集期间收到尺寸变化崩溃或没按最终宽度重画"
import fcntl, os, pty, re, select, struct, sys, termios, time, unicodedata
def setsize(fd, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, cols, 0, 0))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], [sys.argv[1], "board", "w9", "--watch", "30"])
setsize(fd, 196)
def read_for(sec):
    buf, end = b"", time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: break
    return buf.decode("utf-8", "replace")
out = ""
for i in range(20):                # 4 秒内来回改 20 次，必然有落在采集（假 herdr 每次 0.3 秒）期间的
    setsize(fd, 46 if i % 2 else 120)
    out += read_for(0.2)
setsize(fd, 46)
out += read_for(4)
alive = os.waitpid(pid, os.WNOHANG) == (0, 0)
os.kill(pid, 15); read_for(1); os.waitpid(pid, 0)
frame = out.split("\x1b[H\x1b[2J")[-1]
plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07", "", frame)
w = lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
lines = [l for l in plain.replace("\r", "").split("\n") if l]
ok = alive and "Traceback" not in out and lines and lines[0].startswith("w9 · feat/demo") and all(w(l) <= 46 for l in lines)
sys.exit(0 if ok else 1)
PY

# 合入后 finish：记账为已合入，提交数仍是 1
git -C "$INTEG" merge -q --no-ff -m "merge" lane/demo-t1
"$L" finish "$WT" --space w9 --merged-into feat/demo --force 2>/dev/null
got="$(board_json | python3 -I -c 'import json,sys; f=json.load(sys.stdin)["finished"]; print(f[0]["outcome"], f[0]["commits"], f[0]["title"]) if f else print("NONE")')"
[ "$got" = "已合入 1 修复会话被重连拉起" ] && ok "finish 记账：${got}" || bad "finish 记账：${got}"
[ "$(field demo-t1 stage)" = MISSING ] && ok "finish 后不在进行中列表" || bad "finish 后仍在进行中列表"

# close-space：集成 worktree 里有进程在干活（如发布）时拒绝，结束后放行
(cd "$INTEG" && exec sleep 30) & busy_pid=$!
python3 -I -c 'import time; time.sleep(0.5)'
if "$L" close-space w9 --merged-into master >/dev/null 2>"$TMP/close.err"; then
  bad "有进程在集成 worktree 里时 close-space 没拒绝"
else
  grep -q "sleep 30" "$TMP/close.err" && [ ! -s "$TMP/removed.log" ] \
    && ok "有进程在集成 worktree 里时 close-space 拒绝并列出进程" || bad "close-space 拒绝信息不对：$(cat "$TMP/close.err")"
fi
kill "$busy_pid"; wait "$busy_pid" 2>/dev/null || true
(cd "$INTEG" && "$L" close-space w9 --merged-into master >/dev/null 2>&1) \
  && grep -q "worktree remove" "$TMP/removed.log" && ok "进程结束后 close-space 放行（从集成 worktree 里执行也不算占用）" \
  || bad "进程结束后 close-space 仍失败"

exit $fail
