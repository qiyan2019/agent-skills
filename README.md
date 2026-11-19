# agent-skills

Claude Code / Codex 等 coding agent 用的技能。

| 技能 | 说明 |
|---|---|
| [herdr-dispatch](herdr-dispatch/SKILL.md) | 指挥模式：经 herdr 派多个 coding agent 在独立 git worktree 里并行实现，指挥负责任务书、裁定、验收、合入与清理，附终端看板 |

安装（Claude 与其他 agent 共用本仓库这一份）：

```bash
./install.sh
```

链路：`本仓库/<技能>` → `~/.agents/skills/<技能>` → 各 agent 技能目录（Claude Code、Codex、Devin、agy、Antigravity、Gemini、Cursor、Grok、Factory、OpenCode，只装已存在的目录）。脚本幂等，新增技能或新装 agent 后重跑即可；改技能直接改本仓库，所有 agent 即时生效。

herdr-dispatch 依赖 herdr 与同名 `herdr` 技能、git、python3。自测：`bash herdr-dispatch/scripts/tests/board-test.sh`。
