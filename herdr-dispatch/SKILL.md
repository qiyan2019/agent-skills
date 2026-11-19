---
name: herdr-dispatch
description: "指挥模式：本会话做调度与验收，经 herdr 开一个或多个其他 coding agent（codex / devin / agy / cursor / grok 等）在「一批一个 Feature Space（herdr worktree）+ 每个子任务一个独立 git worktree」里实现，指挥写任务书、派工、裁定、复跑验证、退回返工、合入集成分支，子任务完成即关闭 agent 并清理 worktree。用户说「用 herdr 开 agent 做 / 派 agent 去修 / 你来调度和验收 / 并行开发」或给出多条可并行实现线时使用。只在 herdr 环境（HERDR_ENV=1）可用；herdr CLI 细节见 herdr 技能。"
---

# herdr 指挥 / 执行分工

本会话是**指挥**：拆任务、写任务书、派工、裁定、验收、合入。实现全部交给经 herdr 启动的**执行者** agent。
指挥不在执行者的 worktree 里写实现代码（验收后的小修正除外，单独提交并记录）。
herdr 命令语法以 `herdr --help` 为准，基础用法见 `herdr` 技能。

## 空间结构

```
MainSpace（主仓库所在的 herdr workspace，指挥在这里）
└─ Feature Space（一批一个；herdr worktree：集成分支 feat/<主题> + 独立 workspace）
   ├─ 根 tab：集成 worktree，常驻看板（合入、复跑、台账用 git -C 做）
   ├─ tab「<主题> T1」→ cwd = 子任务 T1 的 git worktree（lane.sh new）
   └─ tab「<主题> V1」→ cwd = 子任务 V1 的 git worktree
```

- 子任务 tab 全部开在 Feature Space 里（`tab create --workspace <WS>`）。子任务用普通 git worktree，不用 herdr worktree。
- 关 Feature Space 会关掉里面所有 tab 和 agent，所以只剩根 tab 时才能关；`lane.sh close-space` 会检查。
- 主仓库原本没有 herdr workspace 时，`herdr worktree create` 会自动建一个；批结束后它若只剩空 shell，关掉。

## 硬规则

1. **一批一个 Feature Space，每个子任务一个独立 worktree**（`lane.sh space` / `lane.sh new`）。派工前 `lane.sh check <worktree>` 必须通过。用户没提也照做。
2. **一个子任务一个新 agent**，不同子任务绝不复用 agent。同一 agent 只接本线的裁定和返工。验证 agent 不能是写这段代码的 agent。
3. **完成即清理**：子任务一结束（合入、验证线交报告、放弃）立刻 `lane.sh finish`，不等整批结束。
4. **执行者互不可见**：任务书 / 回报只放各自 worktree 根目录（`TASK.md` / `REPORT.md` / `REVIEW.md`，不入库）。任务书写明禁止读其他 worktree、其他 pane、agent 会话记录目录和指挥台账。
5. **用哪家 agent 每批问用户**，指定过的沿用到本批结束。
6. **只合入集成分支**。合进 `master` / `main`、push、部署、改用户真实配置，先问用户。
7. 单批并行 ≤ 5 条线，写集冲突的线串行。派工前看 `df -h`，清理后仍不够就停下问用户。

## 流程

### 0. 拆分

- 读相关代码、文档和项目 `CLAUDE.md` / `AGENTS.md`，拆成线。每条线写清**写集**（精确到文件或目录），写集相交的线不同批。
- 跨线共享的接口先**冻结成合同**，在台账写一份，逐字复制进每份任务书。
- 有歧义或需要产品取舍 → 先问用户。
- 写**指挥台账** `docs/plan/yyyy-MM-dd-<主题>-调度.md`（放集成 worktree，只有指挥写）：目标、Feature Space ID、线表（线 / 线标题 / agent / 分支 / worktree / tab / pane / 依赖）、合同、进度记录。

### 1. 建 Feature Space 与子任务 worktree

```bash
L=~/.agents/skills/herdr-dispatch/scripts/lane.sh
OUT=$($L space <主题> --base master)      # 输出两行：workspace ID、集成 worktree 路径；根 tab 自动起看板
SPACE=$(echo "$OUT" | sed -n 1p)
INTEG=$(echo "$OUT" | sed -n 2p)
WT=$($L new <主题>-t1 --base feat/<主题>)   # stdout 只有路径
$L check "$WT"
```

- lane 名不能复用。返工在原 lane 上交给原 agent；新的子任务（包括修验收发现的缺陷）一律新开 lane 和新 agent。
- 批空间丢失需要重建时用 `herdr worktree open --cwd <主仓库> --path <集成 worktree> --label <主题> --no-focus`，不要用 `workspace create`（建出来不带 worktree 元数据，`close-space` 认不出）。对已用 `workspace create` 建的同一路径跑这条，会就地补上元数据。

### 2. 写任务书 `$WT/TASK.md`

按 `references/task-template.md` 写：背景（只给本线需要的事实，带 `文件:行号`）、目标、写集、合同 / 行为、验收命令、交付格式、共同约束。

### 3. 启动执行者

```bash
TAB=$(herdr tab create --workspace "$SPACE" --cwd "$WT" --label "<主题> T1" --no-focus)   # 取 .result.root_pane.pane_id
herdr agent start <主题>-<线>-<kind> --kind <kind> --pane <pane_id> --timeout 90000 -- <跳过权限参数> [模型参数]
herdr pane rename <pane_id> "<主题> T1 · <线标题>"
```

- agent 名在 herdr 会话内唯一，重名会报 `agent_name_taken`。
- `agent start` 返回 `agent_not_ready`：`herdr agent read <名> --source visible` 看弹窗。信任目录 → 信任；升级提示 → 跳过；其他 → 问用户。
- 发完 prompt 过 5～10 秒 `agent get` 应为 `working`；仍是 `idle` 且输入框为空，说明 prompt 被吞了，重发。
- 首条 prompt：
  `<主题> <线>：<线标题>。读 TASK.md 并按它执行。遇到任务书与代码事实冲突或需要任务书外的决定，写进 REPORT.md 的「待裁定」后停下等回复。完成后按 TASK.md 的交付格式写 REPORT.md 并停下。`
- **线标题**：6～20 字，动词 + 对象（如「修复登录页重复提交」），台账线表、`TASK.md` 首行、pane 名用同一句。agent 按首条 prompt 生成会话标题，所以线标题必须开头且各线不同；不要写「读 / 执行 / TASK.md」这类各线共有的词。

| kind | 跳过权限 | 常用模型参数 | 启动注意 |
|---|---|---|---|
| codex | `--dangerously-bypass-approvals-and-sandbox` | — | 新仓库弹信任框 → `send-keys enter`；状态会抖动，等 done/idle 再发 prompt |
| devin | `--permission-mode dangerous`（两个独立参数） | `--model swe-2-max` | 新目录弹信任框；刚 start 就报 idle，立刻发的 prompt 会丢 |
| agy | `--dangerously-skip-permissions` | `--model gemini-4-…-high` | 新 worktree 问信任；`Eligibility check failed` 是服务端故障，换别家新 agent |
| cursor | `--force` | `--model grok-4.7-high` | — |

### 4. 监控

- **等待只用一条命令**：`$L wait "$SPACE" --timeout 1800`，放后台跑（不支持后台的 agent 前台阻塞即可）。它阻塞到本批出现新的「轮到指挥」（待裁定 / 受阻 / 待验收，或 agent 停下却没写 REPORT）才返回，输出变化的线和看板；退出码 124 是超时无变化，直接再挂一次。处理完返回的线再挂下一次。
- **禁止自己计时轮询**：不用 agent 自带的定时器 / 计划任务 / 唤醒（agy 的 Schedule、Claude 的 ScheduleWakeup 与 /loop、cron 等），不写 `sleep` 循环，也不在 wait 挂着时反复 `agent get` / `pane read` 查进度。`herdr agent wait` 只用于盯单个 agent 的短时状态（如发 prompt 后等它进入 working）。
- `done` / `idle` 不等于完成。以 `REPORT.md` 已写出且分支上有提交为准：`git -C "$WT" log --oneline <base>..HEAD`。
- `blocked`：`herdr agent read` 看清是什么。写集内的工具审批可批；越权、生产操作、需要用户取舍的问用户。
- 读不全回复时，让它写进 `REPORT.md`。

**看板**：`$L board "$SPACE" [--watch 秒] [--json]`。`lane.sh space` 已在根 tab 起好 `--watch 10`，按屏宽自动切换表格 / 卡片。
阶段从文件和 agent 状态推导，指挥不用维护：

| 条件（自上而下取第一条） | 阶段 |
|---|---|
| agent `blocked` | 受阻 ⚠ |
| 无 REPORT：有 agent / 有 TASK.md / 都没有 | 执行中 / 待启动 / 准备中 |
| REVIEW.md 比 REPORT.md 新 | 返工中 |
| REPORT「受阻」 | 受阻 ⚠ |
| REPORT「待裁定」：agent working / 否则 | 执行中 / 待裁定 ⚠ |
| REPORT「完成」 | 待验收 ⚠ |

⚠ 的线列在底部「轮到指挥」。已 `finish --space` 的线显示在「已结束」区。看板不要另开 tab，否则 `close-space` 会拒绝。

### 5. 裁定

读代码核实（不采信执行者转述），把裁定写到该线 `TASK.md` 末尾「裁定记录」（带 `文件:行号` 和理由）并记进台账，然后 prompt「看 TASK.md 裁定记录，继续」。超出指挥权限的问用户。

### 6. 验收（亲自做，不信回报）

1. `git -C "$WT" diff <base>...HEAD`：越出写集的改动要有 REPORT 里的理由，否则退回。
2. **复跑**关键验证命令。测试失败要和集成分支 HEAD 的失败集合对比，新增失败为 0 才算过。
3. 核实「退出码 0」「全过」「与基线一致」这类说法。
4. UI 改动看截图本身；项目有 lint / 截图回归规则就按规则跑。
5. 不过 → 写 `$WT/REVIEW.md`（编号列出问题、依据、要求），prompt「看 REVIEW.md 返工，完成后更新 REPORT.md」，返工后从第 1 步重验。

### 7. 合入与清理（同一步）

1. `git -C "$INTEG" merge --no-ff <lane 分支>`，冲突由指挥解决（生成文件按项目规则重新生成），合入后复跑受影响测试。
2. 把 REPORT 结论、复跑结果、未覆盖项和残留风险摘进台账。
3. 立刻清理：`$L finish "$WT" --agent <agent 名> --space "$SPACE" --merged-into feat/<主题>`。
   脚本会关掉 agent 及其 tab、归档 `TASK/REPORT/REVIEW.md` 到 `<仓库名>-worktrees/_archive/`、删 worktree、删已并入的分支。
   有未提交改动时拒绝：执行者漏提交的退回；只是构建产物就加 `--force`。
4. 不合入的线也照样 `finish`：没有提交的验证线带 `--merged-into <基线分支>`；要留的未入库文件先复制到 `_archive/`。有提交但没合入的分支会保留，删不删问用户。
5. 中途换掉的 agent，当场关掉它的 tab。
6. 每次派工、裁定、退回、合入、清理都在台账「进度记录」追加一行。
7. 全部合入后在集成分支跑全量验证，向用户报告，问是否合进主分支。
8. **批结束就主动关批空间**：没有进行中的线、用户对集成分支已有决定、发布部署已完成时，不再询问。
   - 先搬走集成 worktree 里要留的未入库文件：证据复制到 `<仓库名>-worktrees/_archive/<主题>-space/` 并更新台账；发布产物挪到主仓库同名目录（同名冲突时停下问）；缓存不留。
   - `$L close-space "$SPACE" --merged-into master`：看板随之关闭；集成分支已并入才删分支。
   - 还有子任务 tab，或集成 worktree 里有进程在跑（发布、构建、测试）时会拒绝。等进程结束，不要加 `--force`。
   - 关完用 `herdr workspace list` 和 `git worktree list` 核对。

## 汇报给用户

每批结束时给：各线状态、复跑的命令与结果、已覆盖 / 未覆盖场景、残留风险、需要用户决定的事。
