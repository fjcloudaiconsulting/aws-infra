<!-- managed-by: claude-mem-lite -->
# claude-mem-lite 插件契约（完整）

> 由 `claude-mem-lite adopt` 生成、随版本自动刷新；卸载用 `claude-mem-lite unadopt`。
> 精炼触发表由 SessionStart 注入会话上下文（显式 `claude-mem-lite adopt` 过的项目则写在 `CLAUDE.md` 的 `claude-mem-lite` 托管块里）；本文件是其展开。
> 设计背景见 docs/CLAUDE-MD-STEERING-PLAN.md。

> **本文下方所有命令写作 `claude-mem-lite <cmd>`。** 该名字只在全局装过
> （`npm i -g claude-mem-lite`）时才在 PATH 上；否则用等价的
> `node <插件根目录>/cli.mjs <cmd>`，绝对路径见本会话 MCP server 的 instructions。
> 本文件**刻意不写死绝对路径**：它随安装位置与版本变化，而本文件可能被提交进仓库，
> 写死会导致每次升版都改动该文件、且队友拿到的是只在别人机器上存在的路径。

## 被动 recall（hook 已自动跑，你只需采纳）

PreToolUse hook 在你 Read / Edit / Write 文件前已自动 `mem_recall` 该文件：
- **Read** 路径：asymmetric-quiet——最多 1 条 lesson、120 字符、要求带 `lesson_learned`。
- **Edit / Write** 路径：decision-support——最多 3 条、240 字符、高重要度 bugfix/decision 即使无
  lesson 也注入。
- Read→Edit 同文件共享 cooldown（不重复注入正文），但 Read 注入后的首个 Edit 会把 lesson **ID**
  以一行 ack 指令重新浮出。看到 `#NN [bugfix] …` 这类行时：**某条 lesson 改变了你的做法，就在描述
  那处改动的句子末尾加一个裸标签 `(#NN)`**；没用上的 lesson 不必提，也不要逐条列出。纯工具回合不算；
  把 ID 记在工作记忆里，写回时引用。
- 给用户的回复里，除了这个 `(#NN)` 标签，不要再提记忆编号：不要报告保存、延期得到的编号
  （如"已记进项目记忆，编号 #1"），也不要讨论记忆库本身（如"和记忆库里 #1 的记录一致"）。
- 系统按会话追踪引用：被引用的 lesson 在召回排序里上浮，被注入却未引用的下沉（有界的排序乘数）；
  反复注入却从未被引用的，后台维护会把它的 importance 降到 2（无 lesson 的降到 1）。
  写成 `#NN n/a` 的驳回不算采纳：排序上与未引用相同，同样下沉——所以不必写。
  引用是给系统的反馈，不是合规仪式——注入池据此自调。

## 记忆是旧笔记，不是现在的代码

- `E#NN` 是后台根据会话自动写的事件摘要，可能写错：2026-09 的沙箱实测里 43 条中有 6 条事实错误、13 条部分错误。
  `#NN` 可能是 agent 主动保存的笔记，`#NN` 也可能是后台自动整理的会话摘要；主动保存的也可能说得超出当时那次改动的实际范围。两者描述的都是保存那一刻的代码。
- 用一条记忆回答"之前做了什么、为什么"，或据此做设计决定之前，先在代码或 `git log -S` / `git show` 里核对它的具体说法。
- 代码与记忆矛盾时，以代码为准，回复里按代码说；然后用
  `mem_save(type=<原类型>, title=..., lesson_learned="<按代码更正后的说法>", supersedes=[NN])`
  替换那条记忆（事件写 `supersedes=["E#NN"]`），被替换的记录不再被召回。只更正你在代码里亲眼核实过的那一点；拿不准就不写。
- 保存教训时只写这次 diff 能证明的内容：修了什么、为什么这样修；之后才做的或打算做的，不写进去。

## 何时主动调用 MCP 工具

`tools/list` 默认暴露 6 个核心工具 + 3 个 defer 工具：
`mem_search` / `mem_recent` / `mem_recall` / `mem_get` / `mem_save` / `mem_timeline` +
`mem_defer` / `mem_defer_list` / `mem_defer_drop`。

### 选 MCP 还是 CLI：按 round-trip,不是执行毫秒

真正的开销是模型往返次数,不是工具执行——暖 MCP 调用 ~25ms、CLI 冷启 ~90ms,在一次推理(秒级)面前都是噪声。按往返次数选路：

1. **被动 hook（0 往返）**：上面的 PreToolUse recall 已自动跑,最快,优先采纳,别重复调。
2. **CLI via Bash（1 往返）**：工具多的会话里 `mem_*` 会被 defer 到 ToolSearch 后面——这时一次 MCP 调用 = ToolSearch + call = **2 往返**,而 Bash 跑一条 CLI 只 **1 往返**。派出去的子 agent 通常也拿不到 `mem_*` 工具,CLI 是它唯一的 1-往返路径。用下面「CLI 速查」表里的命令。
3. **MCP 直调（已加载时 1 往返）**：`mem_*` 已在上下文里(未被 defer)就直接调,暖进程执行最快、省掉 ToolSearch。

一句话：能让 hook 代劳就别调；要显式查,若得先 ToolSearch 才能用 `mem_*`,改跑 CLI。

| 时机 | 工具 | 关键参数 |
|------|------|----------|
| Edit / Write 前 | `mem_recall` | `file="<路径>"`（hook 通常已代劳） |
| Test failure / error | `mem_search` | `query="<错误关键词>", obs_type="bugfix"` |
| Refactor 前 | `mem_search` | `query="<模块>", obs_type="refactor"` |
| 新功能起手 | `mem_search` | `query="<功能区域>"` —— 找 prior art |
| 解决非平凡 bug 后 | `mem_save` | `type="bugfix", lesson_learned="<根因+修法>", importance=2` |
| 非显然架构决策后 | `mem_save` | `type="decision", lesson_learned="<约束+取舍>"` |
| 上下文提到 #NN | `mem_get` | `ids=[NN]` |

## 必做契约（dogfood，本仓库尤其严格）

- **解决非平凡 bug 后**（≠ typo / rename）**必须** `mem_save(type="bugfix",
  lesson_learned="<一行根因+一行修法>", importance=2)`。判据：未来改同一文件的会话看到这条能否避坑？能→存。
- **非显然架构决策后**（≠ 改名/挪代码）调 `mem_save(type="decision",
  lesson_learned="<约束+为何这样选+牺牲了什么>")`。`decision` 命中率显著高于 `change`（当前遥测约
  3:1，会漂移——用 `claude-mem-lite stats` 实测，别套固定倍数）；方向稳健：一条好 decision 抵数条 change。
  别注水：decision 只留给真权衡，不是风格选择。
- **推迟到未来会话**（≠ 在途 todo、≠ 本 PR 跟进）调
  `mem_defer({title, priority:1|2|3, detail:"<约束+为何推迟>"})`。
  触发词：中文「下次/下个会话/不在本轮范围/留给下个会话」；en「next session / defer to next round /
  out of scope for this PR / pick up later」。
- 修掉 deferred 项时 **必须** 给 `mem_save` 加 `closes_deferred=[N]`（N 是 SessionStart
  `### Deferred Work` banner 里的序号，或原始 id `["D#42"]`，混用 OK），让 carry-forward 链闭合。
  若该项无需修（flaky/scope shift）改用 `mem_defer_drop({id, reason})`，reason 必填、作审计。
- **不要为凑 schema 写 `lesson_learned: 'none'`**：写不出能复用的教训就留 NULL，接受低重要度观测。
  Haiku 默认过于激进地填 "none"——手动 save 时覆盖它。

## 维护 / 管理类工具（走 CLI）

以下工具从 `tools/list` 隐藏（缩小启动上下文）；仍注册在 MCP 层、按名 `tools/call` 可命中，
但对 Claude Code 这类只读 tools/list 的调用方只走 CLI：

| 场景 | CLI |
|------|-----|
| 清理过期记忆 | `claude-mem-lite maintain scan --ops purge_stale` → `maintain execute --ops purge_stale --confirm`（删行必须 `--confirm`） |
| 深度优化（Haiku） | `claude-mem-lite optimize`（默认 preview；`--run` 执行，`--task re-enrich,normalize,cluster-merge,smart-compress`） |
| 压缩旧条目 | `claude-mem-lite compress`（默认 preview；`--execute` 执行，`--age-days N`） |
| FTS5 索引检查 / 重建 | `claude-mem-lite fts-check <check\|rebuild>` |
| tier 分组浏览 | `claude-mem-lite browse [--tier active]` |
| 导出 JSON/JSONL | `claude-mem-lite export [--format jsonl]` |
| 统计总量 / 健康 | `claude-mem-lite stats [--days 30]` |
| 删除 / 更新某条 | `claude-mem-lite delete <id>[,<id>]` · `claude-mem-lite update <id> [--title ...]` |

## CLI 速查（常用检索）

| 命令 | 用途 |
|------|------|
| `claude-mem-lite search "query"` | FTS5 全文搜索（默认排除低信号 `Modified X` 等；加 `--include-noise` 找文件变更记录） |
| `claude-mem-lite search "err" --type bugfix` | 按类型过滤 |
| `claude-mem-lite recall "file.mjs"` | 文件相关记忆 |
| `claude-mem-lite recent 5` | 最近 5 条 |
| `claude-mem-lite get 42,43` | 按 ID 展开 |
| `claude-mem-lite timeline --anchor 42` | 时间线上下文 |

## CLI 速查（写入 / 记录）

写入类工具多从 `tools/list` 隐藏 → 只能走 CLI。下表带**硬上限**（超限直接报错，别撞了才知道）；完整 flag 见 `claude-mem-lite help`。

| 命令 | 签名（含硬约束） |
|------|------------------|
| 存观测 | `claude-mem-lite save "<text>" --type bugfix\|decision --lesson "<≤500 字符>" [--importance 1-3] [--closes-deferred N] [--supersedes 12,E#34]` — `<text>` **必填定位参数**；`--lesson` 超 500 直接 fail；`--supersedes` 替换代码已推翻的旧记忆 |
| 推迟工作 | `claude-mem-lite defer add "<title ≤200>" [--priority 1\|2\|3] [--detail "<约束+为何推迟>"]` — 标题 >200 挪到 `--detail` |
| 改某条 | `claude-mem-lite update <id> [--lesson "<≤500>"] [--title T] [--type T] [--importance 1-3] [--narrative T] [--concepts "a b c"]` |
| 事件日志 | `claude-mem-lite activity save --type <bugfix\|lesson\|bug\|discovery\|refactor\|feature\|observation\|decision> "<title>" [--body T] [--files f1,f2]` |

`maintain` / `optimize` / `compress` 见上方「维护 / 管理类工具」；`maintain --ops` 取值 `cleanup,decay,boost,demote_pinned,dedup,purge_stale,vacuum`，省略时默认 `cleanup,decay,boost,demote_pinned`（顺序有意义：demote_pinned 必须在 boost 之后）；`--retain-days` ∈ [7,365]。

## 卸载 / 关闭

- `claude-mem-lite unadopt`：移除 CLAUDE.md 托管块 + `.claude/plugin_claude_mem_lite.md`；
  CLAUDE.md 里你自己的内容（sentinel 之外）不动。
- 本项目永久关闭自动 adopt：`claude-mem-lite adopt --disable`（`--enable` 重新武装）。
- 全局禁用自动 adopt：环境变量 `MEM_NO_AUTO_ADOPT=1`。
- 关闭版本漂移自动刷新（保留你对托管块的手改）：`CLAUDE_MEM_NO_TEMPLATE_REFRESH=1`。
