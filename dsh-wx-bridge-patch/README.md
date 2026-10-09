# dsh-wx-bridge 必要补丁

把 DSH 接到微信需要第三方插件 [`CMD128/dsh-wx-bridge`](https://github.com/CMD128/dsh-wx-bridge)：

```powershell
dsh plugin --profile web add github:CMD128/dsh-wx-bridge
```

**但原版有 4 个问题**，会让体验很差甚至不可用。本目录记录我们实测出来的修法。

> 这些补丁改的是 `node_modules` 里的第三方插件文件，**插件升级会被覆盖**，
> 届时按本文重放。`tools/apply-bridge-patch.ps1` 是半自动重放脚本。

| # | 问题 | 严重度 | 类型 |
|---|---|---|---|
| 1 | 微信唤醒冷会话时绕过模型注入器，间歇性整轮失败 | **致命** | 改源码 |
| 2 | 每轮回复都套一层「✅ [标题] 任务完成：」外壳 | 体验 | 改源码 |
| 3 | 每轮还先发一条「🚀 已发送给 [...]」 | 体验 | 改源码 |
| 4 | **DSH 0.2.x 下每条消息都被拒：`format v4 message requires a producer-owned source kind`** | **致命（仅 0.2.x）** | 改源码 |

> ⚠️ 在 **DSH 0.2.x** 上，先解决 [版本门禁与模块解析](porting-to-dsh-0.2.md)，
> **再**打补丁 4。否则插件根本不会加载，改什么都没用。

---

## 补丁 1（致命）：补装模型选择注入器

### 症状

微信里间歇性出现，而且**GUI 里同一会话能看到回复、微信里没有**：

```
本轮运行失败
agent "session-xxxxxxxx" has no provider/model:
set AgentOptions.provider and AgentOptions.model
or supply both via the agent/request waterfall
```

有时前几轮正常，某一轮突然失败。

### 根因

`wx-bridge` 唤醒冷会话用的是**底层 API**：

```js
await this.ctx.agents.resume({ resumeSessionId, agentOptions: this.seedAgentOptions() })
```

它**绕过**了 `dsh-api-session-controller` 的 `composeAgent()`，而 agent 的模型选择
注入器正是在那里安装的（`api-session-controller/lib/index.js`，`composeAgent` 的 `setup` 回调）：

```js
setup: async (agentCtx, agent) => {
  this.installSelection(agent);          // ← 被绕过
  await presets.mount(agentCtx, resolvedId);
}
```

注入器缺失 → `agent/request` 瀑布没人写入 provider/model →
`dsh-agent-loop` 的 `prepareRequest()` 抛错（`lib/index.js`）：

```js
if (!proposedConfig.provider || !proposedConfig.model) throw new Error(...)
```

### 修法

在 `lib/bridge.js` 的 `SessionBridge` 类里**新增一个方法**，并在**三处 `resume` 之后**调用。

#### 1) 新增方法

放在 `seedAgentOptions()` 方法之后：

```js
  /**
   * 补装模型选择注入器。
   *
   * wx-bridge 用 `ctx.agents.resume()` 直接唤醒冷会话，绕过了
   * dsh-api-session-controller 的 `composeAgent()` —— agent 的模型选择注入器
   * 正是在那里通过 `installSelection(agent)` 安装的。
   *
   * 注入器缺失会导致 agent-loop 的 prepareRequest() 抛
   * "has no provider/model"。修法：调 controller 的正规 API
   * `sessions.selectModel`，其内部会执行
   * `this.selectionFor(agent).current = selection`，从而补装注入器。
   * 传回当前已在用的模型，因此不改变用户的模型选择。
   */
  async installModelSelection(sessionId) {
    try {
      const apiProxy = this.ctx.apiProxy ?? this.ctx.get?.('apiProxy')
      if (!apiProxy?.sessions?.models || !apiProxy?.sessions?.selectModel) return
      const r = await apiProxy.sessions.models({ sessionId })
      const sel = r?.ok ? r.value?.selected : null
      const provider = sel?.provider
      const model = sel?.model
      if (!provider || !model) return
      const res = await apiProxy.sessions.selectModel({ sessionId, provider, model })
      if (!res?.ok) {
        this.logger?.warn?.(
          `dsh-wechat: installModelSelection failed for ${sessionId}: ${res?.error?.message ?? 'unknown'}`,
        )
      }
    } catch (error) {
      this.logger?.warn?.(`dsh-wechat: installModelSelection threw: ${error?.message ?? error}`)
    }
  }
```

#### 2) 三处调用点

**a. `useSession()` 里，冷会话 resume 分支之后**（`this.auth.setBinding(...)` 之后）：

```js
    this.auth.setBinding(windowKey, entry.id)
    // [patch 1] 冷会话被上面 resume() 唤醒，但那条路径绕过了 installSelection，
    // 必须补装模型选择注入器，否则后续回合会抛 "has no provider/model"。
    await this.installModelSelection(entry.id)
    return `✅ 已绑定会话：${entry.title}\n直接发消息即作为 prompt 发送。`
```

**b. `defaultAgent()` 里，resume 之后**：

```js
      const handle = await this.ctx.agents.resume({ resumeSessionId: defaultId, agentOptions: this.seedAgentOptions() })
      // [patch 1] 同上
      await this.installModelSelection(defaultId)
      return handle?.agent ?? handle ?? null
```

**c. `forwardPrompt()` 里，冷会话唤醒分支之后**：

```js
        await this.ctx.agents.resume({ resumeSessionId: sessionId, agentOptions: this.seedAgentOptions() })
        // [patch 1] 同上
        await this.installModelSelection(sessionId)
        agent = this.liveAgentOf(sessionId)
```

### 验证

改完 `node --check lib/bridge.js` 必须通过，然后重启 `dsh web`。
在微信里 `/use <编号>` 绑定一个**冷会话**（📦 未加载的），再发消息——应当不再报错。

---

## 补丁 2：去掉「✅ 任务完成」外壳，改发纯文本

### ⚠️ 先读这条，别踩我们踩过的坑

`lib/bridge.js` 的 `onSessionEvent` 里：

```js
if (event.type === 'assistant/message') {
  const text = messageText(data.message)
  if (text) { /* 只写入 logRings 环形缓冲 */ }
  return          // ← 不投递任何消息
}
...
if (event.type === 'turn/end') {
  if (this.pushEnabledFor(sessionId)) {
    ... void this.channel.say(windowKey, ...)   // ← 唯一的投递点
  }
}
```

**`turn/end` 那段推送就是回复送达微信的唯一通道。**
它看起来像「重复推送」，其实不是——关掉它微信就完全收不到回复了。
（我们试过把 `push.onSessionComplete` 设为 `false`，结果微信一片安静，GUI 里却正常。）

所以**不要关它**，而是把外壳去掉，让它直接发 assistant 的原文。

### 修法

把 `turn/end` 分支里这一段：

```js
      if (this.pushEnabledFor(sessionId)) {
        const kind = data.reason?.kind ?? 'unknown'
        const ring = this.logRings.get(sessionId) ?? []
        const last = ring[ring.length - 1]
        const excerpt = last ? last.slice(0, 300) : '(无文本输出)'
        for (const windowKey of this.auth.windowsForSession(sessionId)) {
          const icon = kind === 'completed' ? '✅' : '⚠️'
          void this.channel.say(
            windowKey,
            `${icon} [${this.titleOf(session)}] 任务${kind === 'completed' ? '完成' : `结束(${kind})`}：\n${excerpt}`,
          )
        }
      }
```

替换为：

```js
      if (this.pushEnabledFor(sessionId)) {
        const ring = this.logRings.get(sessionId) ?? []
        const last = ring[ring.length - 1]
        // [patch 2] 直接发 assistant 纯文本，不再套「✅ [标题] 任务完成：」外壳。
        // 也不再截 300 字：通道按 reply.maxChunkBytes 自动分段。
        const kind = data.reason?.kind ?? 'unknown'
        const text = last ?? (kind === 'completed' ? '(无文本输出)' : `⚠️ 本轮结束（${kind}）`)
        for (const windowKey of this.auth.windowsForSession(sessionId)) {
          void this.channel.say(windowKey, text)
        }
      }
```

要点：
- **不再 `slice(0, 300)`** —— 原截断是为「摘要」设计的，现在发全文。
- **`kind !== 'completed'` 时仍给一行提示**，否则失败会静默，用户什么都看不到。

---

## 补丁 3：去掉「🚀 已发送给 [...]」

`forwardPrompt()` 尾部，**删掉这一行**：

```js
      await this.channel.say(windowKey, `🚀 已发送给 [${this.titleOf(agent.session)}]，完成后通知你。`)
```

改完后该处应是：

```js
      agent.followup(message)
      this.turnStatus.set(agent.session.id, 'running')
```

**保留** `catch` 里的 `❌ 发送失败：...` —— 那是真错误，必须可见。

---

## 补丁 4（仅 DSH 0.2.x，致命）：消息 source 必须用「生产者自有 kind」

### 症状

微信里**每一条消息都回**：

```
本轮运行失败
format v4 message requires a producer-owned source kind
```

GUI 里看起来正常，只有经微信驱动的那一轮失败。

### 根因

DSH 0.2.x 引入了 **session format v4**，它**拒绝**旧式的 `plugin` 包装写法。
`dsh-session-format-v3-to-v4/lib/index.js`：

```js
function source(message) {
  const value = message["source"];
  if (!isSessionFormatJsonObject(value) || typeof value["kind"] !== "string"
      || value["kind"].length === 0 || value["kind"] === "plugin")
    throw new SessionFormatError("format v4 message requires a producer-owned source kind");
}
```

而 wx-bridge 建消息时用的正是被禁的写法（`lib/bridge.js` 的 `forwardPrompt()`）：

```js
source: { kind: 'plugin', plugin: 'dsh-wechat' },     // ❌ v4 原生准入直接拒绝
```

注意：**v3 迁移路径会自动转换旧数据**（`rewritePluginSource` 把 `{kind:'plugin', plugin:X}`
改写成 `{kind:'plugin:X'}`），但**新产生的消息没有迁移这一步，直接被拒**。

### 修法

v4 要的「生产者自有 kind」，正是上游迁移函数 `producerKind()` 的兜底返回值：

```js
function producerKind(plugin, role) {
  ...
  return `plugin:${plugin}`;          // dsh-wechat → plugin:dsh-wechat
}
```

且只有 `kind` 一个字段时，上游迁移等价于 `{ kind: 'plugin:dsh-wechat' }`。

所以把 `lib/bridge.js` 里那一处改成：

```js
      const message = createUserMessage({
        content: [{ type: 'text', text }],
        // DSH 0.2.x 的 session format v4 拒绝旧式 { kind: 'plugin', plugin: X } 包装，
        // 要求「生产者自有 kind」，即 plugin:<plugin>。
        source: { kind: 'plugin:dsh-wechat' },
      })
```

**这处只有一行**，但漏了它整个微信通道就完全不可用。

### 自查

```powershell
Select-String -Path "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-wx-bridge\lib\bridge.js" `
  -Pattern "kind: 'plugin'"
```

有输出 = 还没打补丁，必然失败。

---

## 半自动重放

```powershell
pwsh -File tools/apply-bridge-patch.ps1            # 默认改 web profile
pwsh -File tools/apply-bridge-patch.ps1 -DryRun    # 只看会改什么
```

脚本会：备份原文件 → 用精确字符串替换应用补丁 2 和 3 →
提示补丁 1 需要手工插入（因为要新增方法，位置依版本而异）。

**补丁 1 之所以不自动做**：它要新增一个类方法并在三处插入调用，
不同版本的行号/缩进可能不同，盲替换风险高。脚本会把确切片段打印给你。

## 为什么不用 `pnpm patch`

该包以 `github:CMD128/dsh-wx-bridge` 安装，`pnpm patch <pkg>@<version>`
解析不到版本号，所以只能直接改 `node_modules`。

## 升级后怎么办

```powershell
dsh plugin --profile web update dsh-wx-bridge
# 然后重放本目录的补丁
pwsh -File tools/apply-bridge-patch.ps1
```

## 其他已知限制（非 bug，是设计）

- **只支持文字**：收到图片会回一句「当前版本不支持图片识别」。语音同理。
- **每轮两条消息**：补丁 2+3 应用后变成一条。
- **电脑必须开着**：桥接靠本机 `dsh web` 驱动会话，休眠/关机 = 机器人下线。
- **没有公网部署**：仅主动出站长轮询，无需端口转发或公网 IP。
- **单 owner**：扫码绑定者即唯一受信用户。
