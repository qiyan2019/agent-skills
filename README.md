# agent-skills

Claude Code / Codex 等 coding agent 用的技能。

| 技能 | 说明 |
|---|---|
| [herdr-dispatch](herdr-dispatch/SKILL.md) | 指挥模式：经 herdr 派多个 coding agent 在独立 git worktree 里并行实现，指挥负责任务书、裁定、验收、合入与清理，附终端看板 |

安装（Claude 与其他 agent 共用本仓库这一份）：

```bash
./install.sh
```

链路：`本仓库/<技能>` → `~/.agents/skills/<技能>`（通用目录，大多数 agent 原生扫描）→ 仅对不扫描它的 agent 再软链一次。脚本幂等，新增技能后重跑即可；改技能直接改本仓库，所有 agent 即时生效。

| agent | 是否原生扫描 `~/.agents/skills` | 依据（2026-11-19 实测，探针技能只放在 `~/.agents/skills`） |
|---|---|---|
| Codex 0.169 | 是 | `codex debug prompt-input` 列出探针 |
| Devin CLI | 是 | `devin skills paths` / `devin skills list` |
| Gemini CLI | 是 | `gemini skills list`；再在 `~/.gemini/skills` 放同名链接会报 Skill conflict |
| OpenCode 1.19 | 是 | `opencode debug skill` |
| Grok CLI | 是 | `grok inspect` |
| cursor-agent | 是 | `cursor-agent -p` 列出探针 |
| Claude Code | 否 | 只读 `~/.claude/skills`，需软链 |
| agy（Antigravity CLI） | 否 | `agy -p` 未列出探针，需软链 `~/.gemini/antigravity-cli/skills` |
| Antigravity IDE | 未实测 | 与 agy 同源，保守软链 `~/.gemini/antigravity/skills` |
| Factory droid | 未实测（未登录） | 内置文档只列 `~/.factory/skills`，保守软链 |

herdr-dispatch 依赖 herdr 与同名 `herdr` 技能、git、python3。自测：`bash herdr-dispatch/scripts/tests/board-test.sh`。
