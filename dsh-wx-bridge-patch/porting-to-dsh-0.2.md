# 让 dsh-wx-bridge 在 DSH 0.2.x 上运行

> 状态：**本项目实测可用**（DSH `0.2.0-rc.2` + `dsh-wx-bridge@0.1.0`），
> 但这是**带风险豁免**，不是官方支持路径。

## 症状

DSH 从 0.1.x 升到 0.2.x 后，微信突然连不上。启动时能看到：

```
dsh: skipping profile bundle "dsh-wx-bridge":
Plugin dsh-wx-bridge@0.1.0 is incompatible with dsh 0.2.0-rc.2:
peerDependencies {
  "@deepseek-ai/dsh-agent": "^0.1.0-rc.6",
  "@deepseek-ai/dsh-llm":   "^0.1.0-rc.6"
}
Running it may cause crashes or data loss.

dsh: [cordis.patch.yml] patch: entry "dsh-wx-bridge" not found   ← 连带后果
```

插件被跳过 → `/chatops` 路由不注册 → 微信侧绑定页和状态接口全挂。

自检命令：

```powershell
node "$env:APPDATA\npm\node_modules\@deepseek-ai\dsh\lib\bin.js" --profile web --dump-config 2>&1 |
  Select-String "skip|incompatible|not found"
```

想看当前服务里插件到底加载没有：

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:3080/chatops/api/status
```

- 返回 **200 + JSON** → 插件已加载
- 返回 **404** → 插件没加载（路由不存在）

> ⚠️ 注意 `404` 也可能是**纯文本**的默认 404。插件自己的 404 一定返回
> `{"ok":false}` 这种 JSON，所以只要不是 JSON 就是「根本没注册」。

## 两道关，都要过

### 关 1：版本门禁

DSH 0.2.x 会按插件 `package.json` 的 `peerDependencies` 判断兼容性，
不匹配就**直接跳过整个 bundle**。它提供了一个**精确版本豁免**机制，
豁免记录存在 profile 目录下的 `compatibility.json`：

```json
{
  "dsh-wx-bridge@0.1.0": ["0.2.0-rc.2"]
}
```

格式：`{ "包名@精确版本": ["允许运行的DSH版本", ...] }`

官方路径是在 GUI 的插件管理页里授权（需要 `acceptRisk`，DSH 会明确警告
「may cause crashes or data loss」）。

### 关 2：模块解析（更隐蔽）

插件装在 `<DSH_HOME>/profiles/<profile>/node_modules/dsh-wx-bridge/`，
它 `import '@deepseek-ai/dsh-llm'` 时，Node 会**沿着目录往上找**：

```
profiles/web/node_modules/dsh-wx-bridge/node_modules
profiles/web/node_modules
profiles/node_modules
.dsh/node_modules
C:\Users\<你>\node_modules
...
```

在 0.1.x 时代，`dsh` 装在 npx 缓存里，恰好能被这条链走到。
**升级到全局安装的 0.2.x 后，依赖被放进 `dsh` 包自己的 `node_modules`，
这条链就走不到了。**

结果有两种，都糟：

- 解析失败 → 插件 `apply()` 抛错 → 整个插件不加载
- 解析**成功但错了** → 走到残留的 npx 缓存（旧的 0.1.x），
  把 **0.1.x 的 `dsh-llm` / `dsh-tools` 装进 0.2.x 运行时** —— 这正是 DSH 警告的场景

**修法**：在 profile 的 `node_modules/@deepseek-ai/` 下建立目录联结（junction），
把解析指向 0.2.x 自己的包：

```
profiles/web/node_modules/@deepseek-ai/
├── dsh-tools    -> <dsh安装>\node_modules\@deepseek-ai\dsh-tools
├── dsh-llm      -> ...
├── dsh-agent    -> ...
└── schemastery  -> ...
```

需要哪些包，取决于插件 `import` 了什么。`dsh-wx-bridge` 用到这四个。

## 一键脚本

```powershell
pwsh -File tools/port-to-dsh02.ps1 -DryRun   # 先看
pwsh -File tools/port-to-dsh02.ps1           # 执行
```

脚本会：探测 DSH 安装与版本 → 写 `compatibility.json` 豁免 → 建 4 个联结
→ 用真实 ESM 解析验证指向正确 → 打印后续步骤与回滚方式。

`compatibility.json` 若已存在会先备份。

## 为什么这样可行（实测依据）

0.2.0 里插件用到的东西**都还在**：

| 插件需要 | 0.1.x | 0.2.0 |
|---|---|---|
| `@deepseek-ai/dsh-tools` 的 `defineTool` | ✅ | ✅ |
| `@deepseek-ai/dsh-llm` 的 `createUserMessage` | ✅ | ✅ |
| `@deepseek-ai/dsh-agent` | ✅ | ✅ |
| `@deepseek-ai/schemastery` | ✅ | ✅（3.18.4） |
| host 服务 `webServer` / `agents` / `sessionQuery` / `sessionTitle` / `credentials` / `apiProxy` | ✅ | ✅ |
| `@deepseek-ai/dsh-agent-presets` | ✅ | ❌ **改名**为 `dsh-agent-preset` + `dsh-agent-preset-registry` |

移植后的实测结果：

```
/chatops/api/status   → 200  state=connected online=True
/chatops/api/config   → 200
/dsh-whale/balance.json → 200     （顺带确认鲸鱼挂件也没坏）
/api/dsh-personality/snapshot → 200
dsh --dump-config     → 三个插件全部加载，零跳过零报错
```

## 风险（务必读完）

- DSH 对这条路径的原文警告是 **"may cause crashes or data loss"**。
  你的会话记录、配置都在 `$DSH_HOME` 下，跨大版本跑旧插件确实有写坏的可能。
- **升级或重装插件依赖时，`node_modules/@deepseek-ai` 联结可能被 pnpm 清掉**，
  届时重跑 `port-to-dsh02.ps1`。
- 上游（`CMD128/dsh-wx-bridge`）发布支持 0.2.x 的版本后，
  **应改用上游版本并撤销本方案**。

## 回滚

```powershell
# 撤销豁免与重定向，然后重启 dsh web
Remove-Item "$env:USERPROFILE\.dsh\profiles\web\compatibility.json" -Force
Remove-Item "$env:USERPROFILE\.dsh\profiles\web\node_modules\@deepseek-ai" -Recurse -Force
```

（`compatibility.json` 的备份是同目录的 `compatibility.json.<时间戳>.bak`；
更稳妥的替代方案是直接回退 DSH 到 0.1.5-rc.3。）

## 会话内如何自检

重启后如果要确认「是这台服务」而不只是某个进程，比对：

```powershell
# 监听 3080 的进程用的是哪个安装
(Get-CimInstance Win32_Process -Filter "ProcessId=$((Get-NetTCPConnection -LocalPort 3080 -State Listen).OwningProcess)").CommandLine
```

命令行里出现 `AppData\Roaming\npm\...\dsh\lib\bin.js` 即全局 0.2.x；
出现 `npm-cache\_npx\...` 则是旧的 0.1.x。
