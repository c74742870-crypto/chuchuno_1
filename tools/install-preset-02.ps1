# 安装鲸鱼娘 Agent Preset 到 DSH 0.2.x 的 profile
#
# 背景：DSH 0.2.x 不再从 <DSH_HOME>/.agent-presets/ 扫描 preset，
# 改为在 composition 里声明一行 @deepseek-ai/dsh-agent-preset。
# 本脚本把 preset/whale-girl.patch.yml 内联进 profile 的 cordis.patch.yml。
#
# 用法:
#   pwsh -File tools/install-preset-02.ps1 -DryRun      # 先看
#   pwsh -File tools/install-preset-02.ps1              # 执行
#   pwsh -File tools/install-preset-02.ps1 -Profile web -DshHome "D:\my-dsh"
#
# 特性: 幂等（用标记块替换旧内容，不叠加）；改前备份；改后 dump-config 校验。

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
$profileDir = Join-Path $DshHome "profiles\$Profile"
$patchFile  = Join-Path $profileDir "cordis.patch.yml"
$repoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..")
$srcFile    = Join-Path $repoRoot "preset\whale-girl.patch.yml"

if (-not (Test-Path $profileDir)) { Die "找不到 profile 目录: $profileDir" }
if (-not (Test-Path $srcFile))    { Die "找不到 preset 源文件: $srcFile" }

$BEGIN = "# >>> whale-girl preset (managed by install-preset-02.ps1) >>>"
$END   = "# <<< whale-girl preset <<<"

Info "DSH_HOME  : $DshHome"
Info "profile   : $Profile"
Info "补丁文件  : $patchFile"
Info "preset 源 : $srcFile"
Info ""

# ---- 1. 构造待写入块 ----
# 源文件结构（insert 行的子项缩进 4 空格）：
#     - insert:
#         - id: preset-whale-girl
# 目标结构（profile 补丁里的顶层 insert 行）：
#     - insert:
#         - id: preset-whale-girl
# 即与源文件完全一致，无需再缩进。这里只做「校验 + 原样搬运」，
# 并额外防御：若源文件缩进不是 4，则先归零再统一缩进到 4。
$srcLines = Get-Content $srcFile
$idx = -1
for ($i = 0; $i -lt $srcLines.Count; $i++) {
  if ($srcLines[$i] -match '^\s*-\s*insert:\s*$') { $idx = $i; break }
}
if ($idx -lt 0) { Die "源文件里找不到 '- insert:' 行" }

# 检测子项当前缩进（以第一条 - id: 为准）
$childIndent = $null
foreach ($line in $srcLines[($idx + 1)..($srcLines.Count - 1)]) {
  if ($line -match '^(\s*)-\s*id:') { $childIndent = $Matches[1].Length; break }
}
if ($null -eq $childIndent) { Die "源文件 insert 下找不到 '- id:' 子项" }
Info "源文件子项缩进: $childIndent 空格（期望 4）"

$block = New-Object System.Collections.ArrayList
[void]$block.Add($BEGIN)
[void]$block.Add($srcLines[$idx].TrimEnd())
foreach ($line in $srcLines[($idx + 1)..($srcLines.Count - 1)]) {
  if ($line.Trim() -eq "") { [void]$block.Add(""); continue }
  # 先去掉原缩进，再统一加 4 空格
  $stripped = if ($childIndent -gt 0 -and $line.Length -ge $childIndent) { $line.Substring($childIndent) } else { $line.TrimStart() }
  [void]$block.Add("    $stripped")
}
[void]$block.Add($END)

Info "将写入 $($block.Count) 行"

if ($DryRun) {
  Info ""
  Info "--- 预览（前 7 行）---"
  $block[0..6] | ForEach-Object { "  [$_]" }
  Info "--- 预览（末 2 行）---"
  $block[($block.Count - 2)..($block.Count - 1)] | ForEach-Object { "  [$_]" }
  Info ""
  Warn "-DryRun：未写入任何文件"
  exit 0
}

# ---- 2. 读现有补丁，剔除上一次写入的块（幂等）----
$existing = if (Test-Path $patchFile) { Get-Content $patchFile } else { @() }
$kept = New-Object System.Collections.ArrayList
$skipping = $false
$removed = 0
foreach ($line in $existing) {
  if ($line.Trim() -eq $BEGIN) { $skipping = $true; $removed++; continue }
  if ($line.Trim() -eq $END)   { $skipping = $false; continue }
  if ($skipping) { continue }
  [void]$kept.Add($line)
}
if ($removed -gt 0) { Ok "已移除上一次写入的块（幂等替换）" }

# ---- 3. 备份 ----
if (Test-Path $patchFile) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  Copy-Item $patchFile "$patchFile.$stamp.bak"
  Ok "已备份 -> cordis.patch.yml.$stamp.bak"
}

# ---- 4. 写回 ----
$out = New-Object System.Collections.ArrayList
foreach ($l in $kept) { [void]$out.Add($l) }
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq "") { $out.RemoveAt($out.Count - 1) }
[void]$out.Add("")
[void]$out.Add("# ── 鲸鱼娘 Agent Preset（DSH 0.2.x 声明式定义）──")
[void]$out.Add("# 由 tools/install-preset-02.ps1 写入；勿手工编辑块内内容，重复运行本脚本会替换它。")
foreach ($l in $block) { [void]$out.Add($l) }
($out -join "`r`n") + "`r`n" | Set-Content -Path $patchFile -Encoding UTF8
Ok "已写入 $patchFile"

# ---- 5. 校验 ----
Info ""
Info "--- 校验 ---"
$dshBin = Join-Path $env:APPDATA "npm\node_modules\@deepseek-ai\dsh\lib\bin.js"
if (-not (Test-Path $dshBin)) {
  Warn "找不到全局 dsh，跳过校验。请手动运行:"
  Info "  dsh --profile $Profile --dump-config | Select-String 'preset-whale-girl'"
} else {
  $node = if (Test-Path "D:\dsh\node.exe") { "D:\dsh\node.exe" } else { "node" }
  $dump = & $node $dshBin --profile $Profile --dump-config 2>&1
  $warn = $dump | Select-String -Pattern "^dsh:"
  if ($warn) {
    Warn "dsh 报了警告/错误："
    $warn | Select-Object -First 6 | ForEach-Object { Info "    $($_.Line.Trim())" }
  } else { Ok "dump-config 无警告" }

  if ($dump | Select-String -Pattern "id: preset-whale-girl" -Quiet) { Ok "preset-whale-girl 已在 roster 中" }
  else { Die "preset-whale-girl 未出现在 roster —— 检查上面的警告，或用 .bak 还原" }

  foreach ($p in @("preset-standard","preset-minimal","preset-ptc","preset-cordis")) {
    if ($dump | Select-String -Pattern "id: $p" -Quiet) { Ok "官方 preset 仍在: $p" } else { Warn "官方 preset 消失: $p" }
  }
}

Info ""
Ok "完成。"
Info ""
Warn "接下来：重启 dsh web，然后在 Web 界面【新建会话】时选「鲸鱼娘」。"
Info "  preset 是「一会话一锁」，已说过话的会话切不过来，必须用新会话。"
Info ""
Info "卸载：删掉补丁文件里两个标记之间的内容，或还原 .bak，再重启。"
