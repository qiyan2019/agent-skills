#!/usr/bin/env bash
# 执行线（lane）的 worktree 建立与派工前检查。
# 用法：
#   lane.sh new <lane> [--base REF] [--branch NAME] [--repo PATH]
#       建 worktree + 分支，输出 worktree 路径（最后一行）。
#   lane.sh check <worktree 路径>
#       派工前硬检查：必须是独立 worktree、不在主工作区、分支不是 master/main。不通过退出码 1。
#   lane.sh finish <worktree 路径> [--agent NAME]... [--space WS] [--merged-into REF] [--force]
#       收尾：关闭该线 agent 所在 tab、批空间 WS 里 cwd 在本 worktree 下的其余 tab → 归档 TASK/REPORT/REVIEW → 删除 worktree（含构建产物）
#       → 分支已并入 REF 时删除分支。只处理 <仓库名>-worktrees/ 下由 new 建的 worktree。
#       有未提交改动时拒绝，--force 才丢弃。
#   lane.sh space <主题> [--base REF] [--branch NAME] [--repo PATH]
#       建一批的管理空间：经 herdr worktree create 建集成分支（默认 feat/<主题>）的 worktree
#       + 独立 herdr workspace。输出两行：workspace ID、worktree 路径。
#   lane.sh board <workspace ID | 集成 worktree 路径> [--json] [--watch 秒]
#       调度看板：本批每条线的阶段、agent 状态、提交与 REPORT 状态（scripts/board.py）。
#   lane.sh wait <workspace ID | 集成 worktree 路径> [--timeout 秒] [--interval 秒]
#       阻塞到本批出现新的轮到指挥（或 agent 停下没写 REPORT）才返回并输出看板；超时退出码 124。
#   lane.sh close-space <workspace ID> [--merged-into REF] [--force]
#       关闭批空间：workspace 里除根 tab 外还有 tab（子任务没收尾）、或集成 worktree 里还有进程在干活时拒绝；
#       经 herdr worktree remove 删 checkout 并关 workspace；集成分支已并入 REF 时删分支。
# 环境变量：LANE_MIN_FREE_GB（默认 10）磁盘可用低于此值时 new 拒绝执行。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die() { printf 'lane.sh: %s\n' "$*" >&2; exit 1; }

# 主工作区路径（所有 worktree 共用的 .git 所在目录的上一级）
main_worktree_of() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}

free_gb() {
  df -Pk "$1" | awk 'NR==2 { printf "%d", $4 / 1048576 }'
}

cmd_check() {
  local wt="${1:-}"
  [ -n "$wt" ] || die "check 需要 worktree 路径"
  [ -d "$wt" ] || die "目录不存在：$wt"
  wt="$(cd "$wt" && pwd -P)"
  local top main gitdir common branch
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" || die "不是 git 仓库：$wt"
  top="$(cd "$top" && pwd -P)"
  [ "$top" = "$wt" ] || die "路径不是 worktree 根目录：${wt}（根是 ${top}）"
  main="$(cd "$(main_worktree_of "$wt")" && pwd -P)"
  gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)"
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  # 主工作区的 git-dir 与 common-dir 相同；独立 worktree 的 git-dir 在 .git/worktrees/<名> 下
  [ "$wt" != "$main" ] && [ "$gitdir" != "$common" ] || die "拒绝：$wt 是主工作区，执行者必须在独立 worktree 里干活"
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD)" || die "拒绝：$wt 处于 detached HEAD，执行者需要自己的分支"
  case "$branch" in
    master|main) die "拒绝：$wt 的分支是 $branch" ;;
  esac
  printf 'ok worktree=%s branch=%s main=%s free_gb=%s\n' "$wt" "$branch" "$main" "$(free_gb "$wt")"
}

cmd_new() {
  local lane="" base="HEAD" branch="" repo="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      -*) die "未知参数：$1" ;;
      *) [ -z "$lane" ] || die "多余参数：$1"; lane="$1"; shift ;;
    esac
  done
  [ -n "$lane" ] || die "new 需要 lane 名"
  printf '%s' "$lane" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || die "lane 名只允许小写字母、数字、. _ -：$lane"
  [ -n "$branch" ] || branch="lane/$lane"

  local main name root wt min free
  main="$(main_worktree_of "$repo")"
  name="$(basename "$main")"
  # 末级目录保持仓库原名：部分工具（如 xcodegen）用目录名生成对象 ID
  root="$(dirname "$main")/${name}-worktrees/$lane"
  wt="$root/$name"
  [ ! -e "$wt" ] || die "已存在：${wt}（每个任务用新 lane，不复用）"

  min="${LANE_MIN_FREE_GB:-10}"
  free="$(free_gb "$main")"
  [ "$free" -ge "$min" ] || die "磁盘可用 ${free} GiB < ${min} GiB，先清理已合入 lane 的构建产物"

  mkdir -p "$root"
  # stdout 只留路径；调用方常写 WT=$(lane.sh new … 2>&1)，所以成功时 stderr 也不能有输出
  git -C "$main" worktree add --quiet -b "$branch" "$wt" "$base"
  # 记下切出这条线的集成分支和切出点，看板据此认批、算提交数（文件在 lane 自己的 git 目录，不入库）
  printf '%s\n%s\n' "$base" "$(git -C "$wt" rev-parse HEAD)" \
    > "$(git -C "$wt" rev-parse --path-format=absolute --git-dir)/lane-base"

  # 任务书 / 回报 / 退回单只在本 worktree，不进版本库（info/exclude 由所有 worktree 共用）
  local exclude
  exclude="$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  for f in /TASK.md /REPORT.md /REVIEW.md; do
    grep -qxF "$f" "$exclude" 2>/dev/null || printf '%s\n' "$f" >> "$exclude"
  done

  cmd_check "$wt" >/dev/null
  printf '%s\n' "$wt"
}

# 关闭某个 agent 所在的 tab；agent 的 cwd 必须在本 worktree 内，避免误关别人的 tab
close_agent_tab() {
  local name="$1" wt="$2" info cwd tab
  if ! info="$(herdr agent get "$name" 2>/dev/null)"; then
    printf 'agent %s 已不存在，跳过\n' "$name" >&2
    return 0
  fi
  # herdr 0.9.5：{"result":{"agent":{"cwd":…,"tab_id":…}}}
  cwd="$(printf '%s' "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["cwd"])')"
  tab="$(printf '%s' "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["tab_id"])')"
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P || printf '%s' "$cwd")"
  case "$cwd/" in
    "$wt"/*) ;;
    *) die "拒绝关闭：agent ${name} 的 cwd 是 ${cwd}，不在 ${wt} 内" ;;
  esac
  herdr tab close "$tab" >/dev/null
  printf '已关闭 agent %s 所在 tab %s\n' "$name" "$tab" >&2
}

# 关闭批空间里所有 pane cwd 落在本 worktree 下的 tab（含 agent 已退出、没起来的 tab）
close_space_tabs_in() {
  local ws="$1" wt="$2" t
  for t in $(herdr pane list --workspace "$ws" | python3 -I -c 'import json,os,sys
wt=sys.argv[1]
seen=[]
for p in json.load(sys.stdin)["result"]["panes"]:
    c=os.path.realpath(p["cwd"])
    if (c==wt or c.startswith(wt+"/")) and p["tab_id"] not in seen: seen.append(p["tab_id"])
print(" ".join(seen))' "$wt"); do
    herdr tab close "$t" >/dev/null
    printf '已关闭批空间 %s 里的 tab %s\n' "$ws" "$t" >&2
  done
}

cmd_finish() {
  local wt="" merged="" force=0 space="" agents=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agents+=("$2"); shift 2 ;;
      --space) space="$2"; shift 2 ;;
      --merged-into) merged="$2"; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "未知参数：$1" ;;
      *) [ -z "$wt" ] || die "多余参数：$1"; wt="$1"; shift ;;
    esac
  done
  [ -n "$wt" ] || die "finish 需要 worktree 路径"
  [ -d "$wt" ] || die "目录不存在：$wt"
  wt="$(cd "$wt" && pwd -P)"

  local main name lanes_root branch dirty lane archive
  main="$(cd "$(main_worktree_of "$wt")" && pwd -P)"
  name="$(basename "$main")"
  lanes_root="$(dirname "$main")/${name}-worktrees"
  # 只删 new 建出来的 lane：<仓库名>-worktrees/<lane>/<仓库名>
  case "$wt" in
    "$lanes_root"/*/"$name") ;;
    *) die "拒绝：${wt} 不是 lane.sh new 建的 worktree（应在 ${lanes_root}/<lane>/${name}）" ;;
  esac
  case "$wt" in
    "$lanes_root"/space-*) die "拒绝：${wt} 是批空间，用 lane.sh close-space <workspace ID> 关闭" ;;
  esac
  [ "$(git -C "$wt" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" ] \
    || die "拒绝：${wt} 是主工作区"
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD || true)"

  dirty="$(git -C "$wt" status --porcelain)"
  if [ -n "$dirty" ] && [ "$force" -ne 1 ]; then
    printf '%s\n' "$dirty" >&2
    die "拒绝：${wt} 有未提交改动（见上）。确认可丢弃后加 --force"
  fi

  # 删除前把终态记进看板（需要 TASK.md 与分支还在）
  [ -z "$space" ] || python3 -I "$SCRIPT_DIR/board.py" record "$wt" --space "$space" ${merged:+--merged-into "$merged"}

  # 先停 agent，再动目录
  if [ "${#agents[@]}" -gt 0 ]; then
    for a in "${agents[@]}"; do close_agent_tab "$a" "$wt"; done
  fi
  [ -z "$space" ] || close_space_tabs_in "$space" "$wt"

  # 归档任务书 / 回报 / 退回单（放 lanes_root/_archive，不在任何 worktree 内，执行者看不到）
  lane="$(basename "$(dirname "$wt")")"
  archive="$lanes_root/_archive/${lane}-$(date +%Y%m%d%H%M%S)"
  for f in TASK.md REPORT.md REVIEW.md; do
    if [ -f "$wt/$f" ]; then mkdir -p "$archive"; cp "$wt/$f" "$archive/"; fi
  done
  [ -d "$archive" ] && printf '已归档到 %s\n' "$archive" >&2

  if [ "$force" -eq 1 ]; then
    git -C "$main" worktree remove --force "$wt"
  else
    git -C "$main" worktree remove "$wt"
  fi
  rmdir "$(dirname "$wt")" 2>/dev/null || true
  printf '已删除 worktree %s\n' "$wt" >&2

  if [ -n "$branch" ]; then
    if [ -n "$merged" ] && git -C "$main" merge-base --is-ancestor "$branch" "$merged"; then
      git -C "$main" branch -D "$branch" >/dev/null
      printf '分支 %s 已并入 %s，已删除\n' "$branch" "$merged" >&2
    else
      printf '保留分支 %s（未指定 --merged-into 或未并入）\n' "$branch" >&2
    fi
  fi
}

json_get() {
  # 从 stdin 的 JSON 按点路径取值，例：json_get result.workspace.workspace_id
  python3 -I -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[int(k)] if isinstance(v,list) else v[k]
print(v)' "$1"
}

cmd_space() {
  local topic="" base="HEAD" branch="" repo="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      -*) die "未知参数：$1" ;;
      *) [ -z "$topic" ] || die "多余参数：$1"; topic="$1"; shift ;;
    esac
  done
  [ -n "$topic" ] || die "space 需要主题名"
  printf '%s' "$topic" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || die "主题名只允许小写字母、数字、. _ -：$topic"
  [ -n "$branch" ] || branch="feat/$topic"

  local main name wt min free out ws
  main="$(main_worktree_of "$repo")"
  name="$(basename "$main")"
  wt="$(dirname "$main")/${name}-worktrees/space-${topic}/${name}"
  [ ! -e "$wt" ] || die "已存在：${wt}"
  min="${LANE_MIN_FREE_GB:-10}"
  free="$(free_gb "$main")"
  [ "$free" -ge "$min" ] || die "磁盘可用 ${free} GiB < ${min} GiB"
  git -C "$main" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && die "分支已存在：${branch}（一批一个新集成分支）"

  mkdir -p "$(dirname "$wt")"
  out="$(herdr worktree create --cwd "$main" --branch "$branch" --base "$base" --path "$wt" --label "$topic" --no-focus)" \
    || die "herdr worktree create 失败：$out"
  ws="$(printf '%s' "$out" | json_get result.workspace.workspace_id)"

  local exclude
  exclude="$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  for f in /TASK.md /REPORT.md /REVIEW.md; do
    grep -qxF "$f" "$exclude" 2>/dev/null || printf '%s\n' "$f" >> "$exclude"
  done
  # 根 tab（集成 worktree）常驻看板：手机上点进批空间第一眼就是各线状态；看板只读，不占指挥的操作
  local root_pane
  root_pane="$(herdr pane list --workspace "$ws" | json_get result.panes.0.pane_id)"
  herdr pane run "$root_pane" "$SCRIPT_DIR/lane.sh board $ws --watch 10" >/dev/null
  herdr pane rename "$root_pane" "$topic 看板" >/dev/null
  printf '%s\n%s\n' "$ws" "$wt"
}

cmd_close_space() {
  local ws="" merged="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --merged-into) merged="$2"; shift 2 ;;
      --force) force=1; shift ;;
      -*) die "未知参数：$1" ;;
      *) [ -z "$ws" ] || die "多余参数：$1"; ws="$1"; shift ;;
    esac
  done
  [ -n "$ws" ] || die "close-space 需要 workspace ID"

  local info wt branch tabs ntabs main
  info="$(herdr workspace get "$ws")" || die "workspace 不存在：$ws"
  wt="$(printf '%s' "$info" | json_get result.workspace.worktree.checkout_path)" \
    || die "拒绝：${ws} 不是 herdr worktree 的 workspace"
  case "$wt" in
    */*-worktrees/space-*/*) ;;
    *) die "拒绝：${ws} 的 checkout ${wt} 不是 lane.sh space 建的" ;;
  esac
  # 子任务的 tab 都开在批空间里：只剩根 tab 才说明各线都已 finish
  tabs="$(herdr tab list --workspace "$ws")"
  ntabs="$(printf '%s' "$tabs" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tabs"]))')"
  if [ "$ntabs" -gt 1 ] && [ "$force" -ne 1 ]; then
    printf '%s' "$tabs" | python3 -I -c 'import json,sys
for t in json.load(sys.stdin)["result"]["tabs"]: print(" ", t["tab_id"], t.get("label",""), t.get("agent_status",""))' >&2
    die "拒绝：批空间里还有 ${ntabs} 个 tab（见上），先 finish 各子任务；关闭会杀掉其中的 agent"
  fi
  # 还有进程在集成 worktree 里干活（发布、构建、测试……）时拒绝：关闭会删掉 checkout、打断它们
  local busy
  if ! busy="$(python3 -I "$SCRIPT_DIR/board.py" busy "$wt")" && [ "$force" -ne 1 ]; then
    printf '%s\n' "$busy" >&2
    die "拒绝：集成 worktree 里还有进程在跑（见上），等它们结束再关"
  fi
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD || true)"
  main="$(main_worktree_of "$wt")"

  if [ "$force" -eq 1 ]; then
    herdr worktree remove --workspace "$ws" --force >/dev/null
  else
    herdr worktree remove --workspace "$ws" >/dev/null || die "herdr worktree remove 失败（有未提交改动？确认后加 --force）"
  fi
  rmdir "$(dirname "$wt")" 2>/dev/null || true
  printf '已关闭批空间 %s，删除 %s\n' "$ws" "$wt" >&2

  if [ -n "$branch" ]; then
    if [ -n "$merged" ] && git -C "$main" merge-base --is-ancestor "$branch" "$merged"; then
      git -C "$main" branch -D "$branch" >/dev/null
      printf '集成分支 %s 已并入 %s，已删除\n' "$branch" "$merged" >&2
    else
      printf '保留集成分支 %s\n' "$branch" >&2
    fi
  fi
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  space) shift; cmd_space "$@" ;;
  close-space) shift; cmd_close_space "$@" ;;
  check) shift; cmd_check "$@" ;;
  board) shift; exec python3 -I "$SCRIPT_DIR/board.py" show "$@" ;;
  wait) shift; exec python3 -I "$SCRIPT_DIR/board.py" wait "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  *) die "用法：lane.sh new <lane> [--base REF] [--branch NAME] [--repo PATH] | lane.sh check <worktree> | lane.sh finish <worktree> [--agent NAME]... [--space WS] [--merged-into REF] [--force] | lane.sh board <WS|集成 worktree> [--json] [--watch 秒] | lane.sh wait <WS|集成 worktree> [--timeout 秒] | lane.sh space <主题> [--base REF] | lane.sh close-space <workspace ID> [--merged-into REF] [--force]" ;;
esac
