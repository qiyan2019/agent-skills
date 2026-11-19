#!/usr/bin/env python3
"""herdr 调度看板：汇总一批（Feature Space）里每条线的阶段、agent 状态与进度证据。

用法：
  board.py show <workspace ID | 集成 worktree 路径> [--json] [--watch 秒]
  board.py wait <workspace ID | 集成 worktree 路径> [--timeout 秒] [--interval 秒]
      阻塞到出现「新的」轮到指挥（待裁定 / 受阻 / 待验收，或 agent 停下却没写 REPORT）才返回，
      输出变化的线与当前看板，退出码 0；超时退出码 124。启动时已在轮到指挥的线不算新变化。
      指挥等待执行者只用这一条后台命令，不用 agent 自带定时器或 sleep 轮询。
  board.py busy <路径>
      列出工作目录在该路径下、正在干活的进程（空闲 shell 与看板除外），有则退出码 1。
  board.py record <lane worktree> --space <WS> [--merged-into REF]
      lane.sh finish 删除 worktree 前调用：把这条线的终态记进集成 worktree 的 git 目录
      （lane-board.jsonl，不入库），看板据此显示已合入 / 已结束的线。

数据只从现有事实推导，指挥不需要另外维护状态：
  worktree 与分支（git）、TASK/REPORT/REVIEW.md 的内容与修改时间、herdr agent 状态。
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata

LEDGER = "lane-board.jsonl"
BASE_FILE = "lane-base"  # lane.sh new 写在 lane 的 git 目录里，记录切出这条线的集成分支

# 阶段 → 是否轮到指挥处理
ATTENTION = {"待裁定", "受阻", "待验收"}


def run(args, cwd=None):
    """执行命令，失败返回 None（herdr 不在、分支不存在等都是正常情况）。"""
    try:
        out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out.stdout.strip()


def git(wt, *args):
    return run(["git", "-C", wt, *args])


def herdr_json(*args):
    out = run(["herdr", *args])
    if not out:
        return None
    try:
        return json.loads(out)["result"]
    except (json.JSONDecodeError, KeyError):
        return None


def real(p):
    return os.path.realpath(p)


def under(path, root):
    path, root = real(path), real(root)
    return path == root or path.startswith(root + "/")


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


# ---------- 解析集成 worktree ----------

def resolve_integ(target):
    """返回 (集成 worktree 路径, workspace ID 或 None)。"""
    if os.path.isdir(target):
        top = git(target, "rev-parse", "--show-toplevel")
        if not top:
            sys.exit(f"board: 不是 git 仓库：{target}")
        return real(top), None
    ws = herdr_json("workspace", "get", target)
    if ws is None:
        sys.exit(f"board: workspace 不存在或 herdr 不可用：{target}")
    checkout = (ws["workspace"].get("worktree") or {}).get("checkout_path")
    if checkout:
        return real(checkout), target
    # herdr 有时不带 worktree 字段，改从批空间里的 pane cwd 反查
    panes = (herdr_json("pane", "list", "--workspace", target) or {}).get("panes", [])
    for p in panes:
        cwd = p.get("cwd") or ""
        if re.search(r"-worktrees/space-[^/]+/", cwd + "/"):
            top = git(cwd, "rev-parse", "--show-toplevel")
            if top:
                return real(top), target
    sys.exit(f"board: 找不到 {target} 的集成 worktree（没有 cwd 在 <仓库>-worktrees/space-*/ 下的 pane）")


def repo_layout(integ):
    common = git(integ, "rev-parse", "--path-format=absolute", "--git-common-dir")
    main = os.path.dirname(common)
    name = os.path.basename(main)
    return main, os.path.join(os.path.dirname(main), f"{name}-worktrees"), name


def list_worktrees(main):
    out = git(main, "worktree", "list", "--porcelain") or ""
    items, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                items.append(cur)
            cur = {}
        elif line.startswith("worktree "):
            cur["path"] = real(line[9:])
        elif line.startswith("branch refs/heads/"):
            cur["branch"] = line[18:]
    return items


# ---------- 单条线的事实 ----------

def task_title(wt):
    """TASK.md 首行 `# <主题> <线名>：<线标题>` 取冒号后的线标题。"""
    try:
        with open(os.path.join(wt, "TASK.md"), encoding="utf-8") as f:
            first = f.readline().strip()
    except OSError:
        return ""
    first = first.lstrip("#").strip()
    for sep in ("：", ":"):
        if sep in first:
            return first.split(sep, 1)[1].strip()
    return first


def report_status(wt):
    """REPORT.md 的「## 状态：…」行；没有文件返回 None。"""
    path = os.path.join(wt, "REPORT.md")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*#+\s*状态\s*[：:]\s*(.+)", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        return None
    return ""


def derive_stage(wt, agent_status, has_agent):
    """按事实推导阶段，规则见 SKILL.md「看板」。"""
    status = report_status(wt)
    t_task = mtime(os.path.join(wt, "TASK.md"))
    t_report = mtime(os.path.join(wt, "REPORT.md"))
    t_review = mtime(os.path.join(wt, "REVIEW.md"))
    if agent_status == "blocked":
        return "受阻"
    if status is None:
        if has_agent:
            return "执行中"
        return "待启动" if t_task else "准备中"
    if t_review and t_report and t_review > t_report:
        return "返工中"
    if "受阻" in status:
        return "受阻"
    if "待裁定" in status:
        # 裁定写回 TASK.md 并发了 prompt，执行者在跑：轮到执行者。
        # 只看 TASK.md 修改时间不够：指挥改任务书别处也会变新。
        return "执行中" if agent_status == "working" else "待裁定"
    if "完成" in status:
        return "待验收"
    return "执行中"


def last_commit(wt, base):
    count = git(wt, "rev-list", "--count", f"{base}..HEAD") if base else None
    line = git(wt, "log", "-1", "--format=%h%x09%ct%x09%s", f"{base}..HEAD") if base else None
    if not line:
        return int(count or 0), None
    h, ct, subject = line.split("\t", 2)
    return int(count or 0), {"hash": h, "time": int(ct), "subject": subject}


def lane_base(wt):
    """lane.sh new 记下的 (集成分支名, 切出点 commit)；旧 lane 没有记录时返回 (None, None)。

    提交数按切出点算：合入集成分支后再按分支名算会变成 0。
    """
    gitdir = git(wt, "rev-parse", "--path-format=absolute", "--git-dir")
    try:
        with open(os.path.join(gitdir, BASE_FILE), encoding="utf-8") as f:
            lines = f.read().split()
    except (OSError, TypeError):
        return None, None
    return (lines[0] if lines else None), (lines[1] if len(lines) > 1 else None)


def agents_in(agents, wt):
    return [a for a in agents if a.get("cwd") and under(a["cwd"], wt)]


def lane_info(wt, branch, base, agents):
    mine = agents_in(agents, wt)
    agent = mine[0] if mine else None
    status = agent.get("agent_status") if agent else None
    commits, last = last_commit(wt, base)
    times = [t for t in (mtime(os.path.join(wt, f)) for f in ("TASK.md", "REPORT.md", "REVIEW.md")) if t]
    if last:
        times.append(last["time"])
    stage = derive_stage(wt, status, agent is not None)
    return {
        "lane": os.path.basename(os.path.dirname(wt)),
        "title": task_title(wt),
        "stage": stage,
        "attention": stage in ATTENTION,
        "agent": agent.get("name") if agent else None,
        "kind": agent.get("agent") if agent else None,
        "agent_status": status,
        "pane_id": agent.get("pane_id") if agent else None,
        "branch": branch,
        "base": base,
        "commits": commits,
        "last_commit": last,
        "report_status": report_status(wt),
        "updated": int(max(times)) if times else None,
        "worktree": wt,
    }


# ---------- 汇总 ----------

def collect(target):
    integ, ws = resolve_integ(target)
    main, lanes_root, _ = repo_layout(integ)
    integ_branch = git(integ, "symbolic-ref", "--quiet", "--short", "HEAD")
    agents = (herdr_json("agent", "list") or {}).get("agents", [])
    space_cwds = []
    if ws:
        panes = (herdr_json("pane", "list", "--workspace", ws) or {}).get("panes", [])
        space_cwds = [real(p["cwd"]) for p in panes if p.get("cwd")]

    lanes = []
    for w in list_worktrees(main):
        wt = w["path"]
        if not under(wt, lanes_root) or os.path.basename(os.path.dirname(wt)).startswith("space-"):
            continue
        base_ref, base_commit = lane_base(wt)
        # 归属本批：lane.sh new 记下的集成分支相符，或这条线的 tab 开在本批空间里（旧 lane 没有记录）
        in_batch = (base_ref == integ_branch) or any(under(c, wt) for c in space_cwds)
        if not in_batch:
            continue
        lanes.append(lane_info(wt, w.get("branch"), base_commit or integ_branch, agents))

    finished = []
    gitdir = git(integ, "rev-parse", "--path-format=absolute", "--git-dir")
    try:
        with open(os.path.join(gitdir, LEDGER), encoding="utf-8") as f:
            finished = [json.loads(l) for l in f if l.strip()]
    except OSError:
        pass

    return {
        "workspace_id": ws,
        "integration": {"worktree": integ, "branch": integ_branch},
        "generated": int(time.time()),
        "lanes": sorted(lanes, key=lambda l: l["lane"]),
        "finished": finished,
    }


# ---------- 终端渲染 ----------

def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def clip(s, n):
    s = s or ""
    if width(s) <= n:
        return s + " " * (n - width(s))
    out = ""
    for c in s:
        if width(out + c) > n - 1:
            break
        out += c
    return out + "…" + " " * (n - 1 - width(out))


def ago(ts, now):
    if not ts:
        return "—"
    d = max(0, now - ts)
    if d < 60:
        return f"{int(d)}秒前"
    if d < 3600:
        return f"{int(d // 60)}分前"
    if d < 86400:
        return f"{int(d // 3600)}时前"
    return f"{int(d // 86400)}天前"


STAGE_COLOR = {"待裁定": "31", "受阻": "31", "待验收": "33", "返工中": "35", "执行中": "36"}
WIDE_MIN = 132  # 表格各列加间隔的总宽；更窄（手机客户端窗格约 44～47 列）用卡片布局


def color(s, stage, tty):
    code = STAGE_COLOR.get(stage)
    return f"\033[{code}m{s}\033[0m" if (tty and code) else s


def todo_line(data, name):
    todo = [l for l in data["lanes"] if l["attention"]]
    if not todo:
        return "轮到指挥：无", None
    return "轮到指挥：" + "；".join(f"{name(l['lane'])} {l['stage']}" for l in todo), "待裁定"


def render(data, tty, cols):
    return render_wide(data, tty) if cols >= WIDE_MIN else render_compact(data, tty, cols)


def render_wide(data, tty):
    now = int(time.time())
    integ = data["integration"]
    lines = [f"批空间 {data['workspace_id'] or '—'} · 集成分支 {integ['branch']} · {time.strftime('%H:%M:%S')}", ""]
    cols = [("线", 22), ("线标题", 30), ("阶段", 8), ("agent", 16), ("提交", 4), ("最后提交", 34), ("更新", 6)]
    lines.append("  ".join(clip(n, w) for n, w in cols))
    for l in data["lanes"]:
        agent = f"{l['kind']}·{l['agent_status']}" if l["agent"] else "—"
        lc = l["last_commit"]
        row = [l["lane"], l["title"], ("⚠ " if l["attention"] else "") + l["stage"], agent,
               str(l["commits"]), f"{lc['hash']} {lc['subject']}" if lc else "—", ago(l["updated"], now)]
        text = "  ".join(clip(v, w) for v, (_, w) in zip(row, cols))
        lines.append(color(text, l["stage"], tty))
    if not data["lanes"]:
        lines.append("（没有进行中的线）")
    if data["finished"]:
        lines += ["", "已结束："]
        for f in data["finished"]:
            lines.append(f"  {clip(f['lane'], 22)}  {clip(f.get('title', ''), 30)}  {clip(f['outcome'], 8)}  "
                         f"{f.get('head') or '—'}  {time.strftime('%m-%d %H:%M', time.localtime(f['time']))}")
    text, stage = todo_line(data, lambda n: n)
    lines += ["", color(text, stage, tty)]
    return "\n".join(lines)


def render_compact(data, tty, cols):
    """窄屏卡片：每条线三行，轮到指挥放最上面；每行截到屏宽，不靠列对齐。"""
    now = int(time.time())
    branch = data["integration"]["branch"] or ""
    topic = branch.rsplit("/", 1)[-1]

    def short(lane):
        # 线名去掉批主题前缀：login-flow-t3 → t3
        return lane[len(topic) + 1:] if topic and lane.startswith(topic + "-") else lane

    def fit(s):
        return clip(s, cols).rstrip()

    lines = [fit(f"{data['workspace_id'] or '—'} · {branch} · {time.strftime('%H:%M')}")]
    text, stage = todo_line(data, short)
    lines += [color(fit(text), stage, tty), "-" * (cols - 1)]
    for l in data["lanes"]:
        agent = f"{l['kind']}·{l['agent_status']}" if l["agent"] else "无 agent"
        tag = f"[{l['stage']}]"
        lines.append(color(tag, l["stage"], tty) + fit(f"{tag} {short(l['lane'])} · {agent}")[len(tag):])
        lines.append(fit("  " + (l["title"] or "（无线标题）")))
        lc = l["last_commit"]
        commit = f"{lc['hash']} {lc['subject']}" if lc else "—"
        lines.append(fit(f"  提交 {l['commits']} · {ago(l['updated'], now)} · {commit}"))
    if not data["lanes"]:
        lines.append("（没有进行中的线）")
    if data["finished"]:
        lines += ["-" * (cols - 1), "已结束："]
        for f in data["finished"]:
            lines.append(fit(f"  {short(f['lane'])} {f['outcome']} {f.get('head') or '—'} {f.get('title', '')}"))
    return "\n".join(lines)


# ---------- 子命令 ----------

class Resized(Exception):
    """终端尺寸变了：打断 sleep 立刻重画。"""


# SIGWINCH 只在 sleep 时用异常打断；采集数据（git / herdr 子进程）期间抛异常会把整个看板打崩，
# 所以那时只记下标记，画完这一轮立刻重画。
RESIZE = {"sleeping": False, "pending": False}


def on_resize(signum, frame):
    if RESIZE["sleeping"]:
        raise Resized()
    RESIZE["pending"] = True


class Stopped(Exception):
    """收到 SIGTERM / SIGHUP（关 tab、close-space）：退出前恢复终端。"""


def on_stop(signum, frame):
    raise Stopped()


def watch_loop(target, interval):
    """常驻模式：备用屏 + 关自动换行，尺寸一变立刻按新宽度重画。

    手机客户端附着时 pane 会从桌面的宽度缩到 44～47 列：主屏上的旧画面会被终端重新折行，
    而 10 秒一轮又来不及重画。备用屏不进滚动区、关掉自动换行后超宽行只会被截断。
    """
    topic = None
    out = sys.stdout
    signal.signal(signal.SIGWINCH, on_resize)
    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGHUP, on_stop)
    out.write("\033[?1049h\033[?7l\033[?25l")  # 进备用屏、关自动换行、藏光标
    try:
        while True:
            data = collect(target)
            if topic is None:
                topic = (data["integration"]["branch"] or "").rsplit("/", 1)[-1]
                out.write(f"\033]2;{topic} 看板\007")  # 终端标题：客户端顶栏不再显示进程名 Python
            frame = render(data, True, shutil.get_terminal_size().columns)
            out.write("\033[H\033[2J" + frame.replace("\n", "\r\n"))
            out.flush()
            # 先标记 sleeping 再查 pending：两者之间到达的 SIGWINCH 会走异常分支，不会漏到下一轮
            RESIZE["sleeping"] = True
            try:
                if not RESIZE["pending"]:
                    time.sleep(interval)
            except Resized:
                pass
            finally:
                RESIZE["sleeping"] = False
                RESIZE["pending"] = False
    except (KeyboardInterrupt, Stopped):
        pass
    finally:
        out.write("\033[?25h\033[?7h\033[?1049l")
        out.flush()


def cmd_show(argv):
    target, as_json, watch = None, False, None
    it = iter(argv)
    for a in it:
        if a == "--json":
            as_json = True
        elif a == "--watch":
            watch = float(next(it, "5"))
        elif target is None:
            target = a
        else:
            sys.exit(f"board: 多余参数：{a}")
    if not target:
        sys.exit("board: 需要 workspace ID 或集成 worktree 路径")
    if watch and not as_json and sys.stdout.isatty():
        watch_loop(target, watch)
        return
    while True:
        data = collect(target)
        if as_json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(render(data, sys.stdout.isatty(), shutil.get_terminal_size().columns))
        if not watch:
            return
        time.sleep(watch)


STOPPED = "停下（无 REPORT）"  # agent 不在跑却没写 REPORT：prompt 被吞、在对话里提问或异常退出


def wait_key(lane):
    """这条线需要指挥处理的原因；不需要返回 None。"""
    if lane["attention"]:
        return lane["stage"]
    if lane["agent"] and lane["agent_status"] in ("idle", "done") and lane["report_status"] is None:
        return STOPPED
    return None


def cmd_wait(argv):
    target, timeout, interval = None, 0.0, 15.0
    it = iter(argv)
    for a in it:
        if a == "--timeout":
            timeout = float(next(it, "0"))
        elif a == "--interval":
            interval = float(next(it, "15"))
        elif target is None:
            target = a
        else:
            sys.exit(f"board: 多余参数：{a}")
    if not target:
        sys.exit("board: wait 需要 workspace ID 或集成 worktree 路径")
    start = time.time()
    data = collect(target)
    # 启动时的状态视为已报告过；同一原因只报一次，原因消失后再出现会重新报
    reported = {l["lane"]: wait_key(l) for l in data["lanes"]}
    streak = {}
    while True:
        if not data["lanes"]:
            print("本批没有进行中的线")
            return
        if timeout and time.time() - start >= timeout:
            print(f"超时 {int(timeout)} 秒：没有新的轮到指挥，可直接再次 wait")
            sys.exit(124)
        time.sleep(interval)
        data = collect(target)
        fresh = []
        for l in data["lanes"]:
            key = wait_key(l)
            prev_key, n = streak.get(l["lane"], (None, 0))
            streak[l["lane"]] = (key, n + 1 if prev_key == key else 1)
            if key is None:
                reported[l["lane"]] = None
                continue
            # codex 等的状态会在 working / idle 间抖动：「停下」要连续两次采样一致才算
            need = 2 if key == STOPPED else 1
            if reported.get(l["lane"]) != key and streak[l["lane"]][1] >= need:
                reported[l["lane"]] = key
                fresh.append(f"{l['lane']} {key}")
        if fresh:
            print("新轮到指挥：" + "；".join(fresh))
            print(render(data, False, shutil.get_terminal_size().columns))
            return


def cmd_record(argv):
    wt, space, merged = None, None, None
    it = iter(argv)
    for a in it:
        if a == "--space":
            space = next(it, None)
        elif a == "--merged-into":
            merged = next(it, None)
        elif wt is None:
            wt = a
        else:
            sys.exit(f"board: 多余参数：{a}")
    if not wt or not space:
        sys.exit("board: record 需要 <worktree> --space <WS>")
    wt = real(wt)
    integ, _ = resolve_integ(space)
    integ_branch = git(integ, "symbolic-ref", "--quiet", "--short", "HEAD")
    branch = git(wt, "symbolic-ref", "--quiet", "--short", "HEAD")
    commits, last = last_commit(wt, lane_base(wt)[1] or integ_branch)
    if merged and branch and run(["git", "-C", wt, "merge-base", "--is-ancestor", branch, merged]) is not None:
        outcome = "已合入" if commits else "已结束"
    else:
        outcome = "未合入"
    entry = {
        "lane": os.path.basename(os.path.dirname(wt)),
        "title": task_title(wt),
        "outcome": outcome,
        "branch": branch,
        "commits": commits,
        "head": last["hash"] if last else None,
        "report_status": report_status(wt),
        "time": int(time.time()),
    }
    gitdir = git(integ, "rev-parse", "--path-format=absolute", "--git-dir")
    with open(os.path.join(gitdir, LEDGER), "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print(f"已记入看板：{entry['lane']} {outcome}", file=sys.stderr)


# 不算「在干活」的进程：pane 里空闲的交互式 shell 与看板本身
IDLE_ARGS = {"-zsh", "zsh", "-bash", "bash", "-fish", "fish", "-sh", "sh"}


def ancestors():
    """本进程及其祖先（执行 close-space 的指挥自己的 shell 链），不算占用。"""
    pids, pid = set(), os.getpid()
    while pid > 1 and pid not in pids:
        pids.add(pid)
        ppid = run(["ps", "-o", "ppid=", "-p", str(pid)])
        pid = int(ppid) if ppid and ppid.strip().isdigit() else 1
    return pids


def cmd_busy(argv):
    """列出工作目录在 <路径> 下、正在干活的进程；有则退出码 1。

    close-space 前调用：只按 tab 数判断，会打断集成 worktree 里正在跑的发布或构建。
    """
    if len(argv) != 1:
        sys.exit("board: busy 需要一个路径")
    root, mine = real(argv[0]), ancestors()
    out = run(["lsof", "-a", "-d", "cwd", "-Fpn"]) or ""
    busy, pid = [], None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid and pid not in mine and under(line[1:], root):
            args = run(["ps", "-o", "args=", "-p", str(pid)]) or ""
            # 查不到命令行 = 已退出（多是本检查自己的 lsof 子进程，继承了当前目录）
            if not args.strip() or args.strip() in IDLE_ARGS or "board.py show" in args:
                continue
            busy.append(f"{pid} {args[:160]}")
    for b in busy:
        print(b)
    sys.exit(1 if busy else 0)


def main():
    cmds = {"show": cmd_show, "wait": cmd_wait, "record": cmd_record, "busy": cmd_busy}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
