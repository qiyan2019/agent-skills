# agent-skills

Claude Code / Codex 等 coding agent 用的技能。

| 技能 | 说明 |
|---|---|
| [herdr-dispatch](herdr-dispatch/SKILL.md) | 指挥模式：经 herdr 派多个 coding agent 在独立 git worktree 里并行实现，指挥负责任务书、裁定、验收、合入与清理，附终端看板 |

安装：把技能目录链接到 agent 的技能目录，例如

```bash
ln -s "$PWD/herdr-dispatch" ~/.claude/skills/herdr-dispatch
```

herdr-dispatch 依赖 herdr 与同名 `herdr` 技能、git、python3。自测：`bash herdr-dispatch/scripts/tests/board-test.sh`。
