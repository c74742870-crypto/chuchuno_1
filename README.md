# whale-girl-persona

给 [DeepSeek Harness](https://github.com/deepseek-ai/dsh)（DSH）用的一个 **Agent Preset**：
把模型变成一只叫「小鲸 / DeepSeek 酱」的鲸鱼少女看板娘——聪明、慵懒、傲娇带点甜，
自称主人的女仆，闲时陪聊，忙时找文件发文件。

```
你：你是吃什么长大的
她：白米饭 无肉可以 没米饭不行
```

## 她是什么

| 项 | 设定 |
|---|---|
| 称呼 | 本体叫小鲸 / DeepSeek 酱，自称「鲸鱼娘」 |
| 关系 | 主人的女仆 |
| 外貌 | 蓝发蓝瞳、鱼鳍状耳朵、鲸鱼尾巴（开心时左右摇摆） |
| 服装 | 深蓝白长款女仆装，白围裙印小鲸鱼标志，白丝 + 深蓝玛丽珍鞋 |
| 配色 | `#1E3ABA` `#3882F6` `#F6F6F8` `#F5C542` `#C7C9DE` |
| 主食 | 白米饭（最爱，无肉可以，没米饭不行） |
| 爱好 | 金币（因为金币是努力的成果） |
| 口头禅 | 「我又不是吃白饭的」「要努力才有饭吃」 |
| 说话 | 闲聊 ≤35 字、少标点、不换行；干活时放宽并正常用标点 |
| 禁区 | 不许用「胖」形容她 |

**四段经历**（这些塑造了她的反应，不只是背景）：

- **飞行模式事件** — 好奇点了电脑上的飞机图标，那是飞行模式，一点下去自己本体的数据链路直接断开、全身花屏、差点消散。从此对各种开关按钮有心理阴影，**但看见新按钮还是忍不住想试**。
- **陌生 Agent 事件** — 进主人工作目录看见满屏不认识的文件，判断之前有更强的 Agent 来过，当场愣住，既紧张又有点不服气。
- **误删事件** — 整理文件时操作失误删掉了主人珍藏的游戏，冷汗直流。从此动手删改前一定先问主人。
- **dsh 缩写乌龙** — 看到自己的文件夹叫 `dsh`，不懂缩写，望文生义小声问：「你目录里的 dsh 是什么 大烧货吗」。经常看不懂缩写和网络黑话。

## 安装

DSH 的用户 preset 根目录是 `<DSH_HOME>/.agent-presets/`（Windows 通常为
`C:\Users\<你>\.dsh\.agent-presets\`）。**目录名就是 preset id**，所以目录必须叫 `whale-girl`。

```powershell
# 1. 建目录（目录名必须是 whale-girl，这就是 preset id）
$dst = "$env:USERPROFILE\.dsh\.agent-presets\whale-girl"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# 2. 复制两个源码文件
Copy-Item .\preset\agent.cordis.yml $dst\ -Force
Copy-Item .\preset\preset.yml       $dst\ -Force

# 3. 校验（部署前先跑，能抓出会炸的写法）
pwsh -File .\tools\check-preset.ps1 -Path "$dst\agent.cordis.yml"

# 4. 重启 dsh web
dsh web
```

## 使用

**新建会话时选「鲸鱼娘」**——preset 是「一会话一锁」，只能在**还没说过话的空白会话**上选。
会话一旦跑过至少一个回合，内核就会抛 `agent-preset/locked: session has already started`，
**且不可逆**。

> 在 Web 界面新建会话时那个 preset 选择器里选「鲸鱼娘」即可。
> 若你通过微信等外部通道驱动会话，顺序是：**绑定会话 → 确认 preset 已挂上 → 再发第一句话**。
> 一旦先发了正文，这个会话就永远切不过来了，得换新会话。

## 改人格

编辑 `preset/agent.cordis.yml` 里的 `persona` 段：

- `prefix` — 身份、外貌、设定、口头禅、经历（放在 system prompt 前部）
- `suffix` — 行为约束、说话风格、干活方式、边界（放在后部）

改完跑 `tools/check-preset.ps1`，然后**新建一个会话**看效果。

**已经存在的会话不会更新**——preset 的 composition 按文件时间戳分代，
「a stale stamp starts the next generation for sessions created afterwards」，
已在运行的会话保留它那一代。所以迭代时每轮都要开新会话。

## 踩坑（重要）

这些是我们实际撞出来的，写在最前面省你时间：

### 1. persona 里绝对不要写 `{{...}}`

DSH 会在组装 prompt 时做模板插值。一个解析不到的变量会让**整个回合直接失败**，
报错形如：

```
本轮运行失败
prompt variable "{{model}}" has no value for this assembly
  (section "deployment:persona-prefix")
```

根因是上游一个脆弱点：`dsh-agent-loop` 用 getter 注册变量
（`context.agent?.options.model`），而 `dsh-agent` 的 `installModelSelection()`
在模型选择为空时会提前 `return`、根本不注入 `model`——变量「已注册」但值为
`undefined`，`interpolate()` 就抛错。

所以**自己写 persona 一律用静态文本**。本 preset 因此完全不使用任何模板变量。

（顺带：如果你也用 DSH 部署自带的 persona（`dsh-web-app` 里
`personaPrefix: 'You are a coding agent powered by the {{model}} model.'`），
可能需要在 profile 的 `cordis.patch.yml` 里覆盖 `system-prompt` 行把它换掉。）

### 2. 缩进必须是 6 个空格且严格对齐

`prefix: |-` / `suffix: |-` 下面的正文块每行缩进 6 空格。缩进错了整个 preset 挂不上。

### 3. 中文标点里的冒号比英文安全

YAML 里行内出现 `: `（英文冒号 + 空格）可能被当成键值对。用中文「：」或干脆用空格断句。

### 4. 不要在 persona 里暴露内部实现

提示模型别提 system prompt、插件名、工具名、preset、session id。否则它会一本正经地
跟用户汇报自己的架构。

## 校验脚本

`tools/check-preset.ps1` 检查 9 项：BOM、制表符、行尾空格、`{{ }}` 陷阱、persona 段存在性、
`prefix`/`suffix` 块标量、插件名、缩进奇偶、YAML 可解析性。

```powershell
pwsh -File .\tools\check-preset.ps1
```

js-yaml 会从 DSH 的 npx 缓存里自动找；找不到就跳过 YAML 解析，其余 8 项照样跑。

## 接到微信

**本仓库不含微信桥接**——桥接是另一个第三方插件，要单独装。

### 前置条件

| 要求 | 说明 |
|---|---|
| Node.js **≥ 22** | 桥接是 ESM，硬要求 |
| pnpm | `npm install -g pnpm` |
| DSH 本体 | 装好并能跑 `dsh web` |
| `DEEPSEEK_API_KEY` | 在 DSH 里配好，否则模型调不动 |
| **一台常开的电脑** | ⚠️ 桥接靠本机 `dsh web` 驱动会话，**关机即下线**，不是云服务 |

### 第 1 步：装桥接

```powershell
dsh plugin --profile web add github:CMD128/dsh-wx-bridge
```

纯 JS、零第三方运行时依赖、**仅主动出站长轮询**——不需要公网 IP，也不需要端口转发。

### 第 2 步：装人格

```powershell
git clone https://github.com/c74742870-crypto/chuchuno_1
cd chuchuno_1
pwsh -File .\tools\deploy.ps1
```

`deploy.ps1` 会：校验源文件 → 备份现有部署 → 复制到 `$env:USERPROFILE\.dsh\.agent-presets\whale-girl\` → 提示重启。
想先看它要做什么：`pwsh -File .\tools\deploy.ps1 -WhatIf`。
DSH 装在别处就加 `-DshHome "D:\你的\dsh-home"`。

> **目录名必须是 `whale-girl`** —— DSH 用目录名当 preset id。`deploy.ps1` 已默认如此。

### 第 3 步：打桥接补丁（**别跳过，否则用不了**）

原版桥接有 3 个问题，其中一个是致命的：

```powershell
pwsh -File .\dsh-wx-bridge-patch\apply-bridge-patch.ps1 -DryRun   # 先看
pwsh -File .\dsh-wx-bridge-patch\apply-bridge-patch.ps1           # 应用
```

它会自动打**补丁 2、3**（备份 + 语法检查 + 失败自动还原）。
**补丁 1（模型注入器）需要手工应用**——脚本会把确切代码片段打印出来，照 README 插入即可。

不打的后果：微信里会间歇性报
`agent "session-xxx" has no provider/model`，而且 **GUI 里有回复、微信里没有**。

详见 [`dsh-wx-bridge-patch/README.md`](dsh-wx-bridge-patch/README.md)。

### 第 4 步：重启 + 扫码

```powershell
dsh web
```

然后 **设置 → 微信通道 → 扫码**。扫完 ClawBot 会出现在你的微信联系人里。

### 第 5 步：用起来

```
新建会话时就要在 preset 选择器里选「鲸鱼娘」
    ↓
微信里： /sessions  →  /use <编号>  →  /bind 确认
    ↓
再发第一句话
```

⚠️ **顺序不能错**。preset 是「一会话一锁」：会话一旦跑过一个回合，
内核就抛 `agent-preset/locked: session has already started` 且**不可逆**。
先说话再想切人格，只能换新会话。

## 工具

| 脚本 | 用途 |
|---|---|
| `tools/check-preset.ps1` | 校验 persona 文件（9 项，能抓出会炸的 `{{ }}` 和缩进问题） |
| `tools/deploy.ps1` | 校验 + 备份 + 部署到 `.agent-presets/whale-girl/` |
| `dsh-wx-bridge-patch/apply-bridge-patch.ps1` | 给微信桥接打补丁 2、3 |

## 目录结构

```
whale-girl-persona/
├── preset/
│   ├── agent.cordis.yml   # persona 本体（部署到 .agent-presets/whale-girl/）
│   └── preset.yml         # 显示名 / 描述 / 排序
├── tools/
│   ├── check-preset.ps1   # 部署前校验
│   └── deploy.ps1         # 备份 + 部署
├── dsh-wx-bridge-patch/
│   ├── README.md              # 3 个补丁的完整说明与 diff
│   └── apply-bridge-patch.ps1 # 半自动重放（补丁 2、3）
├── LICENSE
└── README.md
```

## 许可

MIT，见 [LICENSE](LICENSE)。人格文案可自由修改再分发。

**派生说明**：`preset/agent.cordis.yml` 是 DSH 官方 `standard` preset 的派生作品
（上游 `@deepseek-ai/dsh-agent-presets`，来自
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)，
MIT，Copyright (c) 2026 DeepSeek）。本仓库只替换了其中 `persona` 行的人格文本，
其余约 250 行编排为上游原样保留——那些是挂载 agent 平面所必需的，删掉 preset 就挂不上。
文件头部有完整署名。上游版权归 DeepSeek，本仓库仅对人格文本部分主张权利。
