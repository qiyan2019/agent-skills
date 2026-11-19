#!/usr/bin/env bash
# 安装本仓库技能：仓库目录 → ~/.agents/skills/<技能>（共用中转点）→ 各 agent 技能目录
# 幂等：已是正确软链则跳过；目标处存在非软链的实体目录时不覆盖，只告警
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HUB="$HOME/.agents/skills"

# 不扫描 ~/.agents/skills 的 agent 才需要额外软链；只装到已存在的目录
# Codex / Devin / Gemini CLI / OpenCode / Grok / cursor-agent 原生扫描 ~/.agents/skills，
# 不要再加进来（Gemini 会报 Skill conflict），实测记录见 README
AGENT_DIRS=(
  "$HOME/.claude/skills"                  # Claude Code
  "$HOME/.gemini/antigravity-cli/skills"  # agy（Antigravity CLI）
  "$HOME/.gemini/antigravity/skills"      # Antigravity IDE
  "$HOME/.factory/skills"                 # Factory droid
)

# link <源> <链接路径>：建立或校正软链
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    if [ "$(readlink "$dst")" = "$src" ]; then
      echo "ok    $dst"
      return
    fi
    rm "$dst"
  elif [ -e "$dst" ]; then
    echo "skip  $dst（已存在实体目录，请手动处理）" >&2
    return
  fi
  ln -s "$src" "$dst"
  echo "link  $dst -> $src"
}

mkdir -p "$HUB"
for skill_md in "$REPO"/*/SKILL.md; do
  name="$(basename "$(dirname "$skill_md")")"
  link "$REPO/$name" "$HUB/$name"
  for dir in "${AGENT_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    link "$HUB/$name" "$dir/$name"
  done
done
