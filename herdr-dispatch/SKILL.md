---
name: herdr-dispatch
description: "指挥模式：本会话做调度与验收，经 herdr 开一个或多个其他 coding agent（codex / devin / agy / cursor / grok 等）在「一批一个 Feature Space（herdr worktree）+ 每个子任务一个独立 git worktree」里实现，指挥写任务书、派工、裁定、复跑验证、退回返工、合入集成分支，子任务完成即关闭 agent 并清理 worktree。用户说「用 herdr 开 agent 做 / 派 agent 去修 / 你来调度和验收 / 并行开发」或给出多条可并行实现线时使用。只在 herdr 环境（HERDR_ENV=1）可用；herdr CLI 细节见 herdr 技能。"
---

# herdr 指挥 / 执行分工

本会话是**指挥**：拆任务、写任务书、派工、裁定、验收、合入。实现全部交给经 herdr 启动的**执行者** agent。
指挥不在执行者的 worktree 里替它写实现代码（验收后的小修正除外，且要单独提交并记录）。

herdr 命令语法以 `herdr --help` / `herdr agent` / `herdr tab` 的输出为准，基础用法见 `herdr` 技能。

## 空间结构

```
MainSpace（主仓库所在的 herdr workspace，指挥在这里）
└─ Feature Space（一批关联子任务一个；herdr worktree：集成分支 feat/<主题> + 独立 workspace，侧栏挂在 MainSpace 下）
   ├─ 根 tab：集成 worktree，`lane.sh space` 自动在这里常驻看板（合入、复跑、台账都用 `git -C` 做，不占这个 pane）
   ├─ tab「<主题> T1」→ cwd = 子任务 T1 的独立 git worktree（lane.sh new，不是 herdr worktree）
   └─ tab「<主题> V1」→ cwd = 子任务 V1 的独立 git worktree
```

- 批里所有子任务的 tab 都开在 Feature Space 里（`tab create --workspace <WS>`），不开在 MainSpace，也不散在别的 workspace。
- 子任务用普通 git worktree，不用 herdr worktree，这样不会每条线多出一个 workspace。
- 关 Feature Space（`herdr worktree remove`）会连带关掉里面所有 tab，并杀掉其中的 agent。所以必须等各子任务都 `finish` 完，只剩根 tab 了才关。`lane.sh close-space` 会做这项检查。
- 主仓库在 herdr 里没有 workspace 时，`herdr worktree create` 会自动建一个当 MainSpace。批结束后如果它是这次新建的、里面只有空 shell，关掉它。

## 硬规则（每次都执行，不等用户提醒）

1. **一批一个 Feature Space，每个子任务一个独立 worktree**：用 `lane.sh space` 建批空间，用 `lane.sh new` 建子任务的 worktree。
   派工前 `lane.sh check <worktree>` 必须通过：主工作区、`master` / `main` 分支、detached HEAD 一律拒绝。
   用户没提 worktree 也照做，这是默认，不是可选项。
2. **一个子任务一个新 agent，不同子任务绝不复用 agent**（哪怕上一个 agent 空闲、同一家、上下文相关）。
   同一 agent 只接自己这个子任务的裁定和返工。**开发与验证分开**，验证 agent 不能是写这段代码的 agent。
3. **完成即清理，不攒**：子任务一结束（合入、验证线交了报告、或放弃）就立刻执行 `lane.sh finish`，关掉它的 agent 和 tab、删掉 worktree 与构建产物，
   不等整批结束。任何一次合入之后，被合入的那条线必须在同一步里清理掉。
4. **执行者之间互不可见**：任务书 / 回报只放各自 worktree 根目录（`TASK.md` / `REPORT.md` / `REVIEW.md`，已被 `lane.sh` 加进 `info/exclude`，不入库）。
   任务书里写明禁止读取其他 worktree、其他 pane、agent 会话记录目录（`~/.claude/projects`、`~/.codex/sessions` 等）和指挥台账。
5. **用哪家 agent 每批问用户**（见下文「执行者启动参数」），用户指定过的沿用到本批结束。
6. **合入只到集成分支**。合进 `master` / `main`、push、部署、改用户真实配置，必须先问用户。
7. 单批并行 ≤ 5 条线，write-write 冲突的线串行。派工前看 `df -h`；按第 3 条及时清理后仍不够，停下问用户，不删别人的东西。

## 流程

### 0. 拆分（指挥）

- 读相关代码、文档和项目 `CLAUDE.md` / `AGENTS.md`，把需求拆成线。每条线写清**写集**（精确到文件或目录），写集相交的线不能同批。
- 跨线共享的接口（协议字段、类型名、RPC 形状）先由指挥**冻结成合同**写进任务书，各线照合同编码，避免互等。
  合同在台账里只写一份，往每份任务书里**逐字复制**，不缩写、不意译。试运行时就踩过：验证线的任务书漏抄了一个判据，结果多出一条本可避免的待裁定。
- 有歧义或需要产品取舍 → 先问用户，再派工。
- 写**指挥台账** `docs/plan/yyyy-MM-dd-<主题>-调度.md`（放在集成 worktree，只有指挥写）：目标、Feature Space 的 workspace ID、线与轮次表（线 / 线标题 / agent / 分支 / worktree / tab / pane / 依赖）、冻结的合同、进度记录。

### 1. 建 Feature Space 与各子任务 worktree

```bash
L=~/.agents/skills/herdr-dispatch/scripts/lane.sh
OUT=$($L space <主题> --base master)     # herdr worktree：集成分支 feat/<主题> + 独立 workspace
SPACE=$(echo "$OUT" | sed -n 1p)        # workspace ID，例 w3
INTEG=$(echo "$OUT" | sed -n 2p)        # 集成 worktree 路径
WT=$($L new <主题>-t1 --base feat/<主题>)  # 子任务 worktree（普通 git worktree），从集成分支 HEAD 切
$L check "$WT"                          # 不通过就停
```

路径形如 `<仓库父目录>/<仓库名>-worktrees/<lane>/<仓库名>`，批空间是 `space-<主题>/<仓库名>`。末级目录保留仓库原名，xcodegen 这类按目录名生成 ID 的工具才不会出错。
lane 名不能复用。返工在原 lane、原分支上做，交给原来那个 agent；新的子任务（哪怕是修上一条线验收时发现的缺陷）一律新开 lane 和新 agent。

### 2. 写任务书 `$WT/TASK.md`

按 `references/task-template.md` 写。必须有：背景（只给这条线需要的事实，带 `文件:行号`）、目标、写集、必须保持的合同 / 行为、验收命令、交付格式、共同约束。
执行者只读 `TASK.md` 和其中点名的文档；不要让它去读整个台账或其他线的任务书。

### 3. 启动执行者

```bash
TAB=$(herdr tab create --workspace "$SPACE" --cwd "$WT" --label "<主题> T1" --no-focus)   # 解析 .result.root_pane.pane_id
herdr agent start <唯一名> --kind <kind> --pane <pane_id> --timeout 90000 -- <该 agent 的跳过权限参数> [模型参数]
herdr pane rename <pane_id> "<主题> T1 · <线标题>"   # 钉住 pane 显示名，见下文「标题」
```

- agent 名在 herdr 会话内唯一（重名报 `agent_name_taken`，pane 里一个字不会敲）。用 `<主题>-<线>-<kind>` 这类名字。
- `agent start` 返回 `agent_not_ready` 时先 `herdr agent read <名> --source visible`：信任目录框 → 信任；升级提示 → 跳过，不升级全局包；其他弹窗 → 问用户。
- **发完 prompt 要确认真的收到了**：过 5～10 秒 `agent get` 应该是 `working`。如果还是 `idle`，并且 `agent read --source visible` 看到输入框是空的，说明 prompt 被吞了，重发一次。实测 devin 刚 `start` 完就报 idle，这时立刻发的 prompt 会丢。
- 首条 prompt 以本线的**线标题**开头，后接固定指令：
  `<主题> <线>：<线标题>。读 TASK.md 并按它执行。遇到任务书与代码事实冲突或需要任务书外的决定，写进 REPORT.md 的「待裁定」后停下等回复。完成后按 TASK.md 的交付格式写 REPORT.md 并停下。`
  例：`login-flow T3：修复登录页重复提交。读 TASK.md 并按它执行。…`
- **标题**：线标题是 6～20 字、说清这条线做什么的一句话（动词 + 对象，如「修复 herdr 会话停止后被重连拉起」），台账线表与 `TASK.md` 首行用同一句。
  - 为什么：claude / codex / devin / agy 都按首条 prompt 生成会话标题，herdr 把它当 pane 显示名（`pane list` 的 `label`，来自 agent 自报的 `title` 或 `terminal_title`）。
    首条 prompt 全批一样时，所有执行者都叫「Execute TASK.md And Report」（2026-11-17 在 agy 上实测），tab 的 `--label` 盖不住它。
  - `herdr pane rename` 设的手动名优先于 agent 标题（同日实测：rename 后 `label` 变为手动值，`title` 字段不变）。所以起完 agent 立刻 rename，标题生成不理想也不影响侧栏辨认。
  - 线标题里不要写「读 / 执行 / TASK.md / REPORT」这类所有线共有的词，否则生成的标题还是会落到这些词上。
  - 新格式实测（2026-11-17，herdr 0.9.5，四家各一条，先 rename 再发 prompt）：agent 自己生成的标题都落到了线标题上。
    codex `<线标题> | codex`；devin `devin: <线标题>`；claude 取线标题里的关键词；
    agy 是线标题的英译（agy 会译成英文）。agent 晚于 rename 报上来的标题没有覆盖手动名。
  - 有的 herdr 客户端（解析 `herdr api snapshot`）pane 行标题优先用 herdr **agent 名**，没有 agent 名才用 `label`；
    任务 / 通知标题用 agent 自报的 `title` → `terminal_title`，不看 rename。所以 agent 名要取得可读（`<主题>-<线>-<kind>`），首条 prompt 带线标题。

执行者启动参数（用户历史实际用过的；kind 列表以 `herdr agent` 输出为准）：

| kind | 跳过权限 | 常用模型参数 | 已知启动坑 |
|---|---|---|---|
| codex | `--dangerously-bypass-approvals-and-sandbox` | — | 新仓库弹「Trust this folder?」（信任落到仓库根，所有 lane 共用一次）→ `send-keys enter`；有时弹升级提示，选跳过。信任后状态会 blocked→working→done 抖一下，等到 done/idle 再发 prompt |
| devin | `--permission-mode dangerous`（**两个独立参数**，经变量传要防止被当成一个） | `--model swe-2-max` | 首次进新目录弹信任框，`send-keys enter` |
| agy | `--dangerously-skip-permissions` | `--model gemini-4-…-high` | 新 worktree 问是否信任；`Eligibility check failed … loadCodeAssist: EOF` 是服务端故障，退出后换别家**新** agent |
| cursor | `--force` | `--model grok-4.7-high` | — |

### 4. 监控

- 等待用 `herdr agent wait <名> --timeout <ms>`（能后台跑就后台跑，不要短间隔轮询；一条线常跑几十分钟）。
- `done` / `idle` **不等于完成**（agent 启动阶段也会报 done）。以 `REPORT.md` 已写出 + 分支上有提交为准：`git -C "$WT" log --oneline <base>..HEAD`。
- `blocked`：`herdr agent read` 看清是什么。工具审批类按任务书写集判断；越权操作、生产操作、需要用户取舍的 → 问用户，不替用户点。
- 读不全回复（备用屏）时让它把内容写进 `REPORT.md`，指挥直接读文件。

#### 看板

```bash
$L board "$SPACE"               # 一次性表格；也可传集成 worktree 路径
$L board "$SPACE" --watch 10    # 每 10 秒刷新；lane.sh space 已在根 tab 里自动起好这一条
$L board "$SPACE" --json        # 结构化输出，给别的工具读
```

每条线一行：线、线标题（`TASK.md` 首行冒号后）、阶段、agent·状态、提交数、最后提交、最近更新；底部「轮到指挥」列出待裁定 / 受阻 / 待验收的线。
已 `finish` 的线在「已结束」区（已合入 / 已结束 / 未合入）。阶段全部从事实推导，指挥不用另外维护：

| 条件（自上而下取第一条） | 阶段 |
|---|---|
| herdr agent `blocked` | 受阻 ⚠ |
| 无 REPORT：有 agent / 有 TASK.md / 都没有 | 执行中 / 待启动 / 准备中 |
| REVIEW.md 比 REPORT.md 新 | 返工中 |
| REPORT 状态「受阻」 | 受阻 ⚠ |
| REPORT 状态「待裁定」：agent working / 否则 | 执行中 / 待裁定 ⚠ |
| REPORT 状态「完成」 | 待验收 ⚠ |

- 批归属：`lane.sh new` 在 lane 的 git 目录写 `lane-base`（集成分支名 + 切出点 commit），看板按它认批、按切出点数提交（合入后按分支名数会变 0）。
  没有这份记录的旧 lane，按「tab 开在本批空间里」认批，提交数按集成分支算。
- 已结束区来自 `finish --space` 在删除前写的 `<集成 worktree 的 git 目录>/lane-board.jsonl`；不带 `--space` 的 finish 不记账。
- 看板只读，不改任何状态；herdr 不可用时 agent 列显示「—」。
- **常驻位置固定在批空间的根 tab**：`lane.sh space` 建完就在根 pane 里跑 `board --watch 10` 并改名「<主题> 看板」，在客户端里点开批空间，第一个 tab 就是它。
  不另开 tab：`close-space` 只在剩根 tab 时才放行，多一个 tab 就会被拒绝。看板在跑时 `close-space` 照常可以关（2026-11-17 实测）。
  老的批空间（在加这个功能前建的）手动补：`herdr pane run <根 pane> "<lane.sh 绝对路径> board <WS> --watch 10"`。
- **按屏宽换布局**：每轮重新取终端宽度，≥132 列用表格，更窄用卡片（每条线三行，「轮到指挥」放在第二行，线名去掉批主题前缀，每行截到屏宽）。
  手机客户端窗格约 44～47 列走卡片，桌面宽窗口走表格。
- **常驻模式的终端处理**（`--watch` 且输出是终端时）：
  - 用备用屏、关闭自动换行。手机附着时 pane 会从 Mac 的宽度缩到 44～47 列，主屏上的旧画面会被终端重新折行（2026-11-17 用户截图）；关掉自动换行后，超宽行只会被截断。
  - 收到 SIGWINCH 立刻重画，不等刷新周期。收到 SIGTERM / SIGHUP / Ctrl-C 退出前，恢复终端设置。
  - 用 OSC 2 把终端标题设成「<主题> 看板」，否则客户端顶栏可能显示进程名「Python」。
  - herdr 只在有客户端在看这个 workspace 时，才按布局调整 pty 尺寸（实测分屏后布局是 49 列，`stty size` 仍是 95 列）。所以缩窄测试用自测里的伪终端用例，不用 herdr 分屏。
- **批空间丢了要重建**（herdr 重启等原因，workspace 不在了）：用 `herdr worktree open --cwd <主仓库> --path <集成 worktree> --label <主题> --no-focus`，**不要用 `workspace create --cwd`**。
  后者建出来的 workspace 不带 `worktree` 元数据：herdr 侧栏和客户端都不会把它挂到主项目下，`close-space` 也认不出（2026-11-17 实测）。重建后在根 pane 补起看板。
  已经用 `workspace create` 建了的，对同一路径跑上面这条 `worktree open` 就能**就地补上**：herdr 返回 `already_open: true`，给原 workspace 补上 `worktree`，ID、tab、agent 都不变（2026-11-17 实测）。不用搬 pane。
- 自测：`scripts/tests/board-test.sh`（临时仓库 + 假 herdr，不碰真实环境）。

### 5. 裁定

执行者写了「待裁定」并停下时：指挥读代码核实（不采信执行者转述），把裁定写回该线 `TASK.md` 末尾「裁定记录」（每条带 `文件:行号` 依据和理由），同时记进台账，然后 prompt 它「看 TASK.md 裁定记录，继续」。
超出指挥权限的（产品取舍、付费 / 安全 / 已发布行为）问用户。

### 6. 验收（指挥亲自做，不信回报）

1. `git -C "$WT" diff <base>...HEAD --stat` 与全量 diff：有没有越出写集？越界改动要有 REPORT 里的理由，否则退回。
2. **复跑**任务书里的关键验证命令，不只看 REPORT 的输出摘要。测试失败要和基线（集成分支 HEAD 的同一命令）对照**失败集合**，新增失败为 0 才算过。
3. 检查回报里的说法是否属实（"退出码 0"、"全过"、"与基线一致" 这类最常不实）。
4. UI / 视觉改动看截图本身，对照设计和用户裁定；项目有 lint / 截图回归规则的按项目规则跑。
5. 不过 → 写 `$WT/REVIEW.md`（编号列出问题、依据、要求），prompt「看 REVIEW.md 返工，完成后更新 REPORT.md」。返工后从第 1 步重新验。

### 7. 合入与清理（合入和清理是一步，不拆开）

1. 合入集成分支：`git -C "$INTEG" merge --no-ff <lane 分支>`。冲突由指挥解决（生成文件按项目规则重新生成，不要手改）。合入后在集成 worktree 复跑受影响的测试。
2. 先把要留的证据摘进台账：REPORT 的结论、指挥复跑的结果、未覆盖项和残留风险。
3. **立刻清理这条线**：
   ```bash
   $L finish "$WT" --agent <该线 agent 名> --space "$SPACE" --merged-into feat/<主题>
   ```
   脚本依次做这几件事：核对 agent 的 cwd 在本 worktree 内，再关掉它所在的 tab（agent 退出）；把 Feature Space 里 cwd 还落在本 worktree 下的其余 tab 也关掉（agent 已经退出或没起来的 tab）；把 `TASK/REPORT/REVIEW.md` 归档到 `<仓库名>-worktrees/_archive/`（不在任何 worktree 里，执行者看不到）；删除 worktree 和里面的构建产物；分支已经并入时删掉分支。
   - 有未提交改动时会拒绝。先看清是什么：执行者漏提交的就退回；只是没被 git 忽略的构建产物，就加 `--force`。
4. **不合入的线也照样清理**：验证线交了报告、线被放弃、agent 起不来换了别家，都在结论写进台账后立刻 `finish`。
   - 验证线没有提交：带 `--merged-into <它的基线分支>`，分支是基线的祖先，会被安全删除。
   - 验证脚本这类未入库文件要先复制到 `_archive/`，再加 `--force`。
   - 有提交但没合入的分支，脚本会保留，删不删问用户。
5. agent 起不来、或中途换掉时，旧 agent 的 tab 当场关掉，不留空闲的 agent。
6. 每次派工、裁定、退回、合入、清理，都在台账「进度记录」追加一行：日期、线、agent 名、commit、指挥复跑的命令与结果、退回原因、清理结果。
7. 每批结束前用 `herdr tab list --workspace "$SPACE"` 和 `git worktree list` 核对：Feature Space 里只剩还在进行中的子任务 tab。
8. 全部合入后：在集成分支跑全量验证，向用户报告，并询问是否合进主分支。
9. **批结束就主动关批空间，不等用户提醒**（用户 2026-11-17：「任务结束，应该主动关闭 worktree，并且关闭面板」）。
   - 「结束」指：看板上没有进行中的线；用户对集成分支已经有了决定（合进主分支，或者暂不合入）；这批要做的发布、部署都已完成。到这一步不用再问，直接关。
   - 先搬走集成 worktree 里要留的未入库文件，关闭时会连 checkout 一起删：
     - 台账引用的验收截图、日志等证据：复制到 `<仓库名>-worktrees/_archive/<主题>-space/`，并在台账里写上新位置。
     - 发布产物（如 `build/` 下按 build 号存放的归档，里面可能有符号化要用的 dSYM）：挪到主仓库的同名目录（同盘 `mv`，名字冲突时停下问）。
     - `DerivedData` 之类的缓存不留。
   - 然后关闭：
     ```bash
     $L close-space "$SPACE" --merged-into master    # 集成分支已并入 master 才删分支，没并入就保留
     ```
   - 关闭会连同根 tab 的看板一起关掉，不用单独停。台账已经提交在集成分支上，不会丢。
   - `close-space` 遇到以下情况会拒绝：还有子任务 tab；集成 worktree 里还有进程在干活（发布、构建、测试等，用 `board.py busy` 判断，空闲 shell 和看板不算）。
     被拒绝时，等这些进程结束再关；它们结束前不要加 `--force`。2026-11-17 实测就遇到过：批已经结束，但发布脚本还在集成 worktree 里跑。
   - 关完用 `herdr workspace list` 和 `git worktree list` 核对：批空间和集成 worktree 都已经不在了。

## 汇报给用户

每批结束时给：各线状态（合入 / 退回中 / 待裁定）、指挥复跑的命令与结果、已覆盖 / 未覆盖场景、残留风险、需要用户决定的事。
