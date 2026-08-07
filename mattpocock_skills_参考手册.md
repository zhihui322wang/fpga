# Agent Skills 完整参考手册

> 融合来源:
> - [mattpocock/skills](https://github.com/mattpocock/skills) — 通用软件工程 skills (工程 + 效率)
> - [HuanghmBuck/skills](https://github.com/HuanghmBuck/skills) — FPGA/Verilog 专用 skills (硬件开发 + 调试 + 文档)
>
> 安装方式:
> ```bash
> claude plugins install mattpocock-skills   # mattpocock 通用 skills
> # FPGA skills 已安装在 ~/fpga_work/ip库/skills-main/
> ```

---

## 一、Why These Skills Exist — 核心设计理念

mattpocock 用 4 个经典软件工程的失败模式来解释 skills 的价值：

### #1: Agent 没做你想要的事

> "No-one knows exactly what they want" — David Thomas & Andrew Hunt, *The Pragmatic Programmer*

**问题**：你和 Agent 之间存在沟通鸿沟。你以为 Agent 懂了，但做出来的东西完全不是你想要的。
**解决方案**：**Grilling（质询）** — 让 Agent 在动手前先追问你的需求，直到每个设计分支都被解决。
**对应 skills**：`/grill-me`、`/grill-with-docs`

### #2: Agent 太啰嗦

> "With a ubiquitous language, conversations among developers and expressions of the code are all derived from the same domain model." — Eric Evans, *Domain-Driven Design*

**问题**：Agent 被丢进一个项目，自己摸索术语 → 用 20 个词表达 1 个概念。
**解决方案**：**共享语言** — 建立 `CONTEXT.md` 让 Agent 解码项目术语。

```
没有共享语言: "a lesson inside a section of a course is made 'real'"
有共享语言:   "materialization cascade"
```

**好处**：命名一致、代码库更好导航、Agent 思考消耗的 token 更少。
**对应 skill**：`/grill-with-docs`（内置 CONTEXT.md 构建）

### #3: 代码跑不通

> "Always take small, deliberate steps. The rate of feedback is your speed limit." — *The Pragmatic Programmer*

**问题**：你和 Agent 对齐了，但代码还是烂 → 缺少**反馈循环**。
**解决方案**：Red-Green-Refactor（先写失败测试 → 修代码 → 重构），给 Agent 持续的反馈。
**对应 skills**：`/tdd`（测试驱动）、`diagnosing-bugs`（严格调试纪律）

### #4: 代码变成了烂泥球

> "The best modules are deep. They allow a lot of functionality to be accessed through a simple interface." — John Ousterhout, *A Philosophy of Software Design*

**问题**：Agent 加速编码 → 也加速了软件熵增 → 代码库复杂度以空前速度增长。
**解决方案**：**关心代码设计** — 每天投入设计，寻找"深模块"机会。
**对应 skills**：`/improve-codebase-architecture`（扫描代码库）、`codebase-design`（深度模块设计）

> 💡 **核心理念**：软件工程基本功比以往任何时候都重要。这些 skills 是把基本功编成可重复的纪律。

---

## 二、Skills 体系总览

```
                        Agent Skills
                       ┌───────────┴───────────┐
                通用软件工程                   FPGA/硬件开发
              (mattpocock)                  (HuanghmBuck)
              ┌─────┴─────┐               ┌──────┴──────┐
         Engineering   Productivity     开发     调试     文档     版本控制
         (17 skills)   (7 skills)      (3)     (2)     (4)      (5)
```

---

## 三、通用软件工程 Skills (mattpocock)

### 3.1 Engineering — 用户调用 (`/` 命令)

| Skill | 链接 | 功能 | 典型场景 |
|-------|------|------|----------|
| **`/grill-with-docs`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/grill-with-docs/SKILL.md) | ⭐ 质询 + 领域建模 — 质询需求同时构建 CONTEXT.md 和 ADR | 开始新功能前："我要加 HTTP 响应处理，grill me" |
| **`/to-spec`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-spec/SKILL.md) | 把当前对话合成 spec 发布到 issue tracker，无需重复提问 | 讨论清楚方案后一键生成 spec |
| **`/to-tickets`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-tickets/SKILL.md) | 把 spec 拆成 tracer-bullet tickets，声明阻塞依赖 | 大功能拆分 — "先做 MAC TX，再做 http_proc" |
| **`/implement`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/implement/SKILL.md) | 按 spec/tickets 实现，在约定边界驱动 `/tdd`，完结前跑 `/code-review` | 拿到 spec 后按部就班实现 |
| **`/triage`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/triage/SKILL.md) | Issue 状态机 — 按角色流转 issue | 仿真跑出来的 bug 太多，先分类优先级 |
| **`/wayfinder`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/wayfinder/SKILL.md) | 超大型工作路线规划 — 拆成 decision tickets 逐个解决 | 跨多天的重构/新功能 |
| **`/improve-codebase-architecture`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/improve-codebase-architecture/SKILL.md) | 扫描代码库 → 生成 HTML 报告 → 质询重构方向 | RTL 模块腐化治理，每几天跑一次 |
| **`/setup-matt-pocock-skills`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/setup-matt-pocock-skills/SKILL.md) | 首次配置向导 | 每个新 repo 跑一次 |
| **`/ask-matt`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/ask-matt/SKILL.md) | 路由咨询 — 不确定用哪个 skill？它帮你选 | "我现在有个 ILA 触发问题" → 推荐 diagnosing-bugs |

### 3.2 Engineering — AI 可自动调用 (Model-invoked)

| Skill | 链接 | 功能 | 典型场景 |
|-------|------|------|----------|
| **`tdd`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/tdd/SKILL.md) | Red-Green-Refactor 循环，每次一个垂直切片 | 修 MAC TX bug → 先写失败 testbench → 修 RTL → 回归验证 |
| **`code-review`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/code-review/SKILL.md) | 双轴审查 — 标准轴 + Spec 轴，并行子 agent 互不污染 | RTL 改动提交前自审 |
| **`diagnosing-bugs`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/diagnosing-bugs/SKILL.md) | 严格调试循环 — 复现 → 最小化 → 假设 → 插桩 → 修复 → 回归 | ILA 波形异常？按流程排查，不瞎试 |
| **`prototype`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/prototype/SKILL.md) | 抛弃型原型 — 生成 HTML 验证状态机/逻辑 | "这个 GMII→MAC 状态机对吗？"→ 生成原型 |
| **`research`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/research/SKILL.md) | 后台调研 — 高可信度源，产出带引用 Markdown | "RTL8211F PHY 的 RGMII 时序要求是什么？" |
| **`domain-modeling`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/domain-modeling/SKILL.md) | 构建领域模型 — 边界场景压力测试术语 | 建立 GMII/RGMII/fcapz/CDC 术语表 |
| **`codebase-design`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/codebase-design/SKILL.md) | 深度模块设计 — 大行为、小接口、干净接缝 | 设计新 RTL 模块前 |
| **`resolving-merge-conflicts`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/resolving-merge-conflicts/SKILL.md) | 逐块解决 git 冲突 → 追溯原始意图 → 永不 `--abort` | RTL 模块多分支合并冲突 |
| **`wizard`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/wizard/SKILL.md) | 生成 bash 向导 → 引导人完成只能人工做的事 | 配 Vivado license、设 CI secrets |

### 3.3 Productivity — 用户调用 (`/` 命令)

| Skill | 链接 | 功能 | 典型场景 |
|-------|------|------|----------|
| **`/grill-me`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/grill-me/SKILL.md) | ⭐ 无情质询 — 直到设计树每个分支被解决 | 任何复杂任务前："我要加 27 个 ILA 探针，grill me" |
| **`/handoff`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/handoff/SKILL.md) | 当前对话压成交接文档 → 新 agent 无缝接手 | Vivado 编译机器 ↔ 上板调试机器间切换 |
| **`/teach`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/teach/SKILL.md) | 多会话教学 — 有状态的教学工作区 | 学 RGMII 时序、fpga_ila 协议 |
| **`/to-questionnaire`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/to-questionnaire/SKILL.md) | 把决策问题转 Markdown 问卷 | 用哪个 UART 引脚？发给硬件同事确认 |
| **`/wait-what`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/wait-what/SKILL.md) | Agent 说了不懂的 → 立即用 CONTEXT.md 词汇重新解释 | 任何让你困惑的 Agent 输出 |

### 3.4 Productivity — AI 可自动调用

| Skill | 链接 | 功能 |
|-------|------|------|
| **`grilling`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/grilling/SKILL.md) | 质询引擎 — `grill-me`、`grill-with-docs`、`triage`、`wayfinder` 等的底层原语 |
| **`writing-for-agents`** | [SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/productivity/writing-for-agents/SKILL.md) | Agent 文档写作指南 — 怎么写 skills、AGENTS.md、CLAUDE.md |

---

## 四、FPGA/硬件开发 Skills (HuanghmBuck)

> 安装路径: `~/fpga_work/ip库/skills-main/`
> 这些 skills 已集成在你的 Claude Code 环境中，可直接用 `/` 命令或触发词调用。

### 4.1 开发设计

| Skill | 触发词 | 功能 | 典型场景 |
|-------|--------|------|----------|
| **`/verilog-design`** | Verilog设计、RTL设计、模块设计、写模块、I2C/SPI/UART/MDIO/RGMII/GMII 等 | ⭐ RTL 设计指导 — 接口时序参考 + 三段式状态机 + CDC 处理 + 异步复位同步撤离 + 流水线优化 + 自动生成 Testbench + 代码格式化 | "帮我写一个 GMII 接收模块" → 自动查时序文档，生成完整 RTL |
| **`/doc-lld`** | 详细设计文档、LLD、接口板逻辑设计方案 | 从 RTL 目录自动解析模块端口/参数/子模块实例化 → 按标准模板生成 Markdown 详细设计文档 | `/doc-lld rtl/` → 生成完整的接口板逻辑设计方案 |
| **`format`** | (AI 自动触发) | 三步格式化: `reorder-module.py` (结构重排) → `verible-verilog-format` (语法格式化) → `verible-verilog-lint` (lint + auto-fix) | RTL 代码写完后的格式整理 |

### 4.2 仿真调试

| Skill | 触发词 | 功能 | 典型场景 |
|-------|--------|------|----------|
| **`/unit-sim`** | 仿真、unit-sim、单元仿真、跑仿真、simulate、sim | ⭐ 单元仿真全自动化 — 自动找 TB → 选工具(Verilator/iverilog/ModelSim) → 编译 → 运行 → 打开 GTKWave 波形 | `/unit-sim rtl/mac_tx.v` → 自动编译运行 + 打开波形 |
| **`/debug-ila`** | debug_ila、加调试、加 ILA、插桩、抓信号 | ⭐ fpga_ila 一键插桩 — 指定信号 → 自动添加 `soft_ila_top_fcapz` + `ila_hub_top` + 总线 + `signals.json` + `fpga_ila_files.f` | `/debug-ila rtl/webserver_cpu_top.v:gmii_tx_en,gmii_txd` → 自动插入 ILA 核 |

**`/unit-sim` 自动化流程：**
```
输入模块文件
  ├─ 1. 解析模块层级依赖
  ├─ 2. 语法检查（所有依赖模块）
  ├─ 3. 查找/生成 Testbench
  ├─ 4. 确定仿真目录 (sim/)
  ├─ 5. 选择仿真工具 (Verilator / iverilog / ModelSim)
  ├─ 6. 选择仿真模式 (带波形/不带波形)
  ├─ 7. 执行仿真
  └─ 8. 打开 GTKWave 波形
```

**`/debug-ila` 支持三种信号指定方式：**
```
方式 A — 信号名:  /debug-ila rtl/cpu_channel.v:rpkt_pop,rpkt_len
方式 B — 行范围:  /debug-ila rtl/top.v:29~32 (VSCode 复制相对路径格式)
方式 C — VSCode 选中 → 右键 → Copy Relative Path → 粘贴
```
- 支持**空白工程**（从零添加）和**已有 ILA**（追加新核，自动更新总线位宽）

### 4.3 文档与博客

| Skill | 触发词 | 功能 | 典型场景 |
|-------|--------|------|----------|
| **`/md2html`** | 转html、生成网页、md2html | Markdown → HTML，支持 Mermaid 结构图和 Wavedrom 时序图 | RTL 设计文档转为可发布的网页 |
| **`/md2pdf`** | 转pdf、转docx、生成pdf | Markdown → PDF/DOCX | 生成设计文档 PDF 交付 |
| **`/blog-publish`** | 发布、上传、发表、推送博客 | Markdown → HTML → 自动发布到 buckfpga.uk | "把这篇 ILA 调试经验发到博客" |
| **`/blog-unpublish`** | 下架、取消发布、撤销发布、删除博客 | 从 buckfpga.uk 下架已发布的博客 | "那篇博客下掉" |

### 4.4 版本控制

| Skill | 触发词 | 功能 | 典型场景 |
|-------|--------|------|----------|
| **`/git-push`** | push、上传代码 | 推送代码到 GitHub (zhihuiw 账号 + 强制覆盖) | `git push RiscV_WebSoC_3` |
| **`/git-pull`** | pull、下载、sync | 从 GitHub 拉取项目代码 | `git pull RiscV_WebSoC_3` |
| **`/git-list`** | 版本历史、commit、changelog | 显示项目版本历史和 commit 详情 | `git list RiscV_WebSoC_3` |
| **`/git-diff`** | 版本对比 | Meld 可视化目录级版本对比 | "对比今天和昨天的 RTL 改动" |
| **`/git-share`** | 分享仓库、add collaborator | 管理 GitHub private repo 协作者 | "把这个 repo 分享给同事" |

---

## 五、FPGA 开发场景 → Skills 组合推荐

### 场景 1: 设计新 RTL 模块

```
/grill-me                    ← 先质询清楚需求
    ↓
/verilog-design              ← 按接口时序规范写 RTL
    ↓
format                       ← 自动格式化 + lint
    ↓
/unit-sim rtl/my_module.v   ← 单元仿真验证
    ↓
/doc-lld rtl/               ← 生成详细设计文档
```

### 场景 2: 调试 FPGA 硬件 Bug

```
/grill-me                    ← 明确"Bug 现象是什么"
    ↓
diagnosing-bugs              ← 严格调试纪律: 假设 → 最小化 → 插桩 → 修复
    ↓
/debug-ila rtl/top.v:信号    ← 插入 ILA 探针抓关键信号
    ↓
make run && make wave        ← 仿真验证
```

### 场景 3: 大型功能开发

```
/grill-with-docs             ← 质询 + 构建共享语言
    ↓
/to-spec                     ← 谈话内容合成 spec
    ↓
/to-tickets                  ← spec 拆成 tickets
    ↓
/implement                   ← 按 ticket 逐个实现 (内置 tdd + code-review)
    ↓
git-push Project             ← 推送上板验证
```

### 场景 4: 项目文档交付

```
/doc-lld rtl/               ← 生成 LLD 文档
    ↓
/md2pdf doc/lld.md          ← 转为 PDF
    ↓
/md2html doc/lld.md         ← 转为网页（含 Mermaid/Wavedrom 图）
    ↓
/blog-publish               ← （可选）发布到博客
```

### 场景 5: 跨机器工作交接

```
/handoff                     ← 当前机器的所有上下文 → 交接文档
    ↓
另一台机器 → agent 加载交接文档继续
```

---

## 六、快速参考卡片

### 开始任何任务前: `/grill-me` 或 `/grill-with-docs`

```
/grill-me                    ← 纯质询，通用
/grill-with-docs             ← 质询 + 建 CONTEXT.md + ADR
```

### 写代码时:

```
/verilog-design              ← FPGA RTL 设计 (接口时序 + 规范)
tdd                          ← 先写测试再写代码
code-review                  ← 提交前自审
codebase-design              ← 设计深度模块
```

### 调试时:

```
diagnosing-bugs              ← 标准调试流程
/debug-ila                   ← FPGA ILA 插桩
/unit-sim                    ← 单元仿真自动化
```

### 项目管理:

```
/to-spec                     ← 谈话 → spec
/to-tickets                  ← spec → tickets
/triage                      ← issue 分类
/wayfinder                   ← 超大任务路标
/improve-codebase-architecture  ← 代码腐化治理
```

### 文档 & 输出:

```
/doc-lld                     ← FPGA 详细设计文档
/md2html                     ← Markdown → HTML (含 Mermaid/Wavedrom)
/md2pdf                      ← Markdown → PDF/DOCX
/blog-publish / blog-unpublish  ← 博客发布/下架
```

### Git 操作:

```
/git-push / /git-pull / /git-list / /git-diff / /git-share
```

---

## 七、Matt Pocock 官方 In-Progress Skills

| Skill | 功能 | 状态 |
|-------|------|------|
| **`/loop-me`** | 发现生活中可委托的循环模式 → 生成 workflow spec | 开发中 |
| **`/claude-handoff`** | 交接给后台 agent 继续工作 | 开发中 |
| **`setup-ts-deep-modules`** | TypeScript 深模块配置 | 开发中 |
| **`writing-beats`** | 分节写作 | 开发中 |
| **`writing-fragments`** | 片段写作 | 开发中 |
| **`writing-shape`** | 结构写作 | 开发中 |

---

> 📅 生成日期: 2026-08-07
> 🔗 Matt Pocock 原仓库: [github.com/mattpocock/skills](https://github.com/mattpocock/skills)
> 📂 FPGA Skills 本地路径: `~/fpga_work/ip库/skills-main/`
