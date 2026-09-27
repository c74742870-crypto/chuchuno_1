# 部署 whale-girl preset 到 DSH
#
# 用法:
#   pwsh -File tools/deploy.ps1
#   pwsh -File tools/deploy.ps1 -DshHome "D:\my-dsh-home"
#   pwsh -File tools/deploy.ps1 -WhatIf      # 只看要做啥，不落盘
#
# 动作: 校验源文件 -> 备份现有部署 -> 复制 preset -> 提示重启

param(
  [string]$DshHome,
  [string]$PresetId = "whale-girl",
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m }
function Ok($m)   { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "❌ $m" -ForegroundColor Red; exit 1 }

# ---- 解析 DSH_HOME（与 DSH 自身一致：先环境变量，再 ~/.dsh）----
if (-not $DshHome) {
  $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
}
if (-not (Test-Path $DshHome)) {
  Die "DSH_HOME 不存在: $DshHome`n   请先安装并至少运行一次 DSH（dsh web）。若装在别处，用 -DshHome 指定。"
}

$repoRoot  = Resolve-Path (Join-Path $PSScriptRoot "..")
$srcPreset = Join-Path $repoRoot "preset"
$agentFile = Join-Path $srcPreset "agent.cordis.yml"
$metaFile  = Join-Path $srcPreset "preset.yml"

$presetRoot = Join-Path $DshHome ".agent-presets"
$targetDir  = Join-Path $presetRoot $PresetId
$targetFile = Join-Path $targetDir "agent.cordis.yml"
$targetMeta = Join-Path $targetDir "preset.yml"

Info "DSH_HOME : $DshHome"
Info "源目录   : $srcPreset"
Info "目标目录 : $targetDir"
Info ""

# ---- 1. 源文件存在性 ----
foreach ($f in @($agentFile, $metaFile)) {
  if (-not (Test-Path $f)) { Die "源文件缺失: $f" }
}
Ok "源文件存在"

# ---- 2. 部署前校验 ----
Info "--- 运行校验 ---"
& (Join-Path $PSScriptRoot "check-preset.ps1") -Path $agentFile
if ($LASTEXITCODE -ne 0) { Die "校验未通过，已中止部署（避免把一个会整轮失败的 preset 装上去）" }

if ($WhatIf) {
  Info ""
  Warn "-WhatIf：到此为止，未写入任何文件"
  exit 0
}

# ---- 3. 备份现有部署 ----
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

if (Test-Path $targetFile) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backup = Join-Path $targetDir "agent.cordis.yml.$stamp.bak"
  Copy-Item $targetFile $backup -Force
  Ok "已备份旧版 -> $(Split-Path $backup -Leaf)"
} else {
  Info "（目标目录为空，无需备份）"
}

# ---- 4. 复制 ----
Copy-Item $agentFile $targetFile -Force
Copy-Item $metaFile  $targetMeta -Force
Ok "已部署 agent.cordis.yml 与 preset.yml"

# ---- 5. 提示重启 ----
$meta = Get-Content $targetMeta -Raw -ErrorAction SilentlyContinue
$display = if ($meta -match '(?m)^name:\s*(.+)$') { $Matches[1].Trim() } else { $PresetId }

Info ""
Ok "完成。preset id = $PresetId，显示名 = $display"
Info ""
Warn "接下来必须做两件事，否则不会生效："
Info "  1. 重启 dsh web（preset 是进程启动时读取的）"
Info "  2. 在 Web 界面【新建一个会话】，并在 preset 选择器里选「$display」"
Info ""
Info "  注意：preset 是「一会话一锁」。已经说过话的会话永远切不过来，"
Info "        必须用新会话。若通过微信驱动，顺序是："
Info "        新建会话时选好人格 -> 微信 /sessions -> /use <编号> -> /bind 确认 -> 再发第一句话"
Info ""
Info "回滚：删掉或还原目标目录里的 agent.cordis.yml.<时间戳>.bak"
