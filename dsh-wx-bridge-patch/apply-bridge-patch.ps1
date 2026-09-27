# 给 dsh-wx-bridge 应用补丁 2 和 3（去掉回复外壳、去掉发送提示）
#
# 用法:
#   pwsh -File dsh-wx-bridge-patch/apply-bridge-patch.ps1
#   pwsh -File dsh-wx-bridge-patch/apply-bridge-patch.ps1 -DryRun
#   pwsh -File dsh-wx-bridge-patch/apply-bridge-patch.ps1 -Profile web
#
# 补丁 1（模型注入器）不在此脚本内自动应用 —— 它要新增一个类方法并在三处插入调用，
# 不同版本行号/缩进可能不同，盲替换风险太高。脚本会把确切片段打印出来。
# 详见同目录 README.md。

param(
  [string]$Profile = "web",
  [string]$DshHome,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m }
function Ok($m)   { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "❌ $m" -ForegroundColor Red; exit 1 }

if (-not $DshHome) {
  $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
}

$bridgeDir = Join-Path $DshHome "profiles\$Profile\node_modules\dsh-wx-bridge"
$bridgeJs  = Join-Path $bridgeDir "lib\bridge.js"

if (-not (Test-Path $bridgeJs)) {
  Die "找不到 $bridgeJs`n   请确认已安装: dsh plugin --profile $Profile add github:CMD128/dsh-wx-bridge`n   或用 -Profile / -DshHome 指定正确位置。"
}

Info "目标文件: $bridgeJs"
Info ""

# 读成单个字符串（保留换行），做精确替换
$raw = [IO.File]::ReadAllText($bridgeJs)
# 统一换行为 CRLF，便于随后写回（原文件是 CRLF）
$rawNorm = $raw -replace "`r`n", "`n"

$patched = $rawNorm
$applied = @()
$skipped = @()

# ---------------- 补丁 2：turn/end 改发纯文本 ----------------
$old2 = @'
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
'@ -replace "`r`n", "`n"

$new2 = @'
      if (this.pushEnabledFor(sessionId)) {
        const ring = this.logRings.get(sessionId) ?? []
        const last = ring[ring.length - 1]
        // [patch 2] 直接发 assistant 纯文本，不再套「✅ [标题] 任务完成：」外壳。
        // 本段是回复送达微信的唯一通道（assistant/message 只写 logRings，不投递），
        // 所以只能改它、不能删它。也不再截 300 字，超长由通道按 maxChunkBytes 分段。
        const kind = data.reason?.kind ?? 'unknown'
        const text = last ?? (kind === 'completed' ? '(无文本输出)' : `⚠️ 本轮结束（${kind}）`)
        for (const windowKey of this.auth.windowsForSession(sessionId)) {
          void this.channel.say(windowKey, text)
        }
      }
'@ -replace "`r`n", "`n"

if ($patched.Contains($old2)) {
  $patched = $patched.Replace($old2, $new2)
  $applied += "补丁 2（回复外壳 -> 纯文本）"
} elseif ($patched.Contains($new2)) {
  $skipped += "补丁 2（已是打过补丁的状态）"
} else {
  $skipped += "补丁 2（未找到匹配代码 —— 可能上游已改，请手工核对 README）"
}

# ---------------- 补丁 3：删掉「🚀 已发送给」 ----------------
$old3 = "      await this.channel.say(windowKey, ``🚀 已发送给 [`${this.titleOf(agent.session)}]，完成后通知你。``)"
$new3 = "      // [patch 3] 原本这里会回一条「🚀 已发送给 [...]，完成后通知你。」"

if ($patched.Contains($old3)) {
  $patched = $patched.Replace($old3, $new3)
  $applied += "补丁 3（去掉「🚀 已发送给」）"
} elseif ($patched.Contains($new3)) {
  $skipped += "补丁 3（已是打过补丁的状态）"
} else {
  $skipped += "补丁 3（未找到匹配代码 —— 请手工核对 README）"
}

# ---------------- 结果 ----------------
Info "--- 结果 ---"
foreach ($a in $applied) { Ok $a }
foreach ($s in $skipped) { Warn $s }
Info ""

if ($applied.Count -eq 0) {
  Info "没有需要改的内容。"
} elseif ($DryRun) {
  Warn "-DryRun：未写入。去掉 -DryRun 才会真正落盘。"
} else {
  # 备份
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $bak = "$bridgeJs.$stamp.bak"
  Copy-Item $bridgeJs $bak -Force
  Ok "已备份 -> $(Split-Path $bak -Leaf)"

  # 写回
  $out = ($patched -replace "`n", "`r`n")
  [IO.File]::WriteAllText($bridgeJs, $out)

  # 语法检查
  Info ""
  Info "--- 语法检查 ---"
  node --check $bridgeJs
  if ($LASTEXITCODE -ne 0) {
    Copy-Item $bak $bridgeJs -Force
    Die "语法检查未通过，已自动还原备份。请检查补丁片段与你的插件版本是否匹配。"
  }
  Ok "语法通过"
}

# ---------------- 补丁 1 提示 ----------------
Info ""
Warn "补丁 1（模型注入器）需要手工应用 —— 这一步才是让微信能正常回话的关键。"
Info ""
Info "在 lib/bridge.js 的 SessionBridge 类里新增以下方法（放在 seedAgentOptions() 之后）:"
Info ""
Write-Host @'
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
        this.logger?.warn?.(`dsh-wechat: installModelSelection failed for ${sessionId}: ${res?.error?.message ?? 'unknown'}`)
      }
    } catch (error) {
      this.logger?.warn?.(`dsh-wechat: installModelSelection threw: ${error?.message ?? error}`)
    }
  }
'@ -ForegroundColor Gray
Info ""
Info "然后在三处 await this.ctx.agents.resume(...) 之后各加一行:"
Info "    await this.installModelSelection(<对应的 sessionId>)" -ForegroundColor Gray
Info "  调用点: useSession() / defaultAgent() / forwardPrompt() 的冷会话唤醒分支"
Info "  详见同目录 README.md 的「补丁 1」一节。"
Info ""
Info "全部改完后重启 dsh web 生效。"
