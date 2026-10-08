# 让 dsh-wx-bridge 在 DSH 0.2.x 上运行
#
# 完整说明见同目录上级: dsh-wx-bridge-patch/porting-to-dsh-0.2.md
#
# 做两件事:
#   1) 授予精确版本豁免 —— 让 0.2.x 不再跳过该插件（写 profile 的 compatibility.json）
#   2) 建立模块重定向联结 —— 把插件对 @deepseek-ai/* 的解析指向 0.2.x 自己的包
#
# 用法:
#   pwsh -File tools/port-to-dsh02.ps1 -DryRun
#   pwsh -File tools/port-to-dsh02.ps1
#
# ⚠️ DSH 对这条路径的原文警告是 "may cause crashes or data loss"。
#    这是带风险豁免，不是官方支持路径。上游适配 0.2.x 后请撤销本方案。

param(
  [string]$Profile = "web",
  [string]$DshHome,
  [string]$DshInstall,
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
if (-not (Test-Path $profileDir)) { Die "找不到 profile 目录: $profileDir" }

# ---- 定位 DSH 安装（优先全局 0.2.x，退回 npx 缓存）----
if (-not $DshInstall) {
  $global = Join-Path $env:APPDATA "npm\node_modules\@deepseek-ai\dsh"
  if (Test-Path (Join-Path $global "package.json")) {
    $DshInstall = $global
  } else {
    $npxDir = Join-Path $env:LOCALAPPDATA "npm-cache\_npx"
    $DshInstall = Get-ChildItem $npxDir -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName "node_modules\@deepseek-ai\dsh" } |
      Where-Object { Test-Path (Join-Path $_ "package.json") } |
      Select-Object -Last 1
  }
}
if (-not $DshInstall -or -not (Test-Path (Join-Path $DshInstall "package.json"))) {
  Die "找不到 DSH 安装目录，请用 -DshInstall 指定"
}

$ver = (Get-Content (Join-Path $DshInstall "package.json") -Raw | ConvertFrom-Json).version
Info "DSH 安装 : $DshInstall"
Info "DSH 版本 : $ver"
Info "Profile  : $profileDir"
Info ""

if ($ver -notmatch '^0\.2\.') {
  Warn "当前 DSH 版本是 $ver；本脚本是为 0.2.x 设计的。0.1.x 不需要这些操作。"
}

$pkgRoot = Join-Path $DshInstall "node_modules\@deepseek-ai"
if (-not (Test-Path $pkgRoot)) {
  Die "找不到 $pkgRoot`n   0.2.x 的依赖应位于 dsh 包自身的 node_modules 下。"
}

$needed = @("dsh-tools", "dsh-llm", "dsh-agent", "schemastery")

# ---- 步骤 1: 版本豁免 ----
$compatFile = Join-Path $profileDir "compatibility.json"
$pluginPkg  = Join-Path $profileDir "node_modules\dsh-wx-bridge\package.json"

Info "--- 步骤 1/2：版本豁免 ---"
if (-not (Test-Path $pluginPkg)) {
  Warn "  该 profile 未安装 dsh-wx-bridge，跳过"
} else {
  $pluginVer = (Get-Content $pluginPkg -Raw | ConvertFrom-Json).version
  $key = "dsh-wx-bridge@$pluginVer"
  Info "  写入 $compatFile"
  Info "    { `"$key`": [`"$ver`"] }"
  if ($DryRun) { Warn "  -DryRun：未写入" }
  else {
    if (Test-Path $compatFile) {
      $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
      Copy-Item $compatFile "$compatFile.$stamp.bak"
      Ok "  已备份 -> compatibility.json.$stamp.bak"
    }
    $obj = @{}
    if (Test-Path $compatFile) {
      try {
        (Get-Content $compatFile -Raw | ConvertFrom-Json).PSObject.Properties |
          ForEach-Object { $obj[$_.Name] = @($_.Value) }
      } catch { Warn "  原文件无法解析，将被覆盖（已备份）" }
    }
    $obj[$key] = @($ver)
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $compatFile -Encoding UTF8
    Ok "  已写入豁免"
  }
}

# ---- 步骤 2: 模块重定向 ----
Info ""
Info "--- 步骤 2/2：模块重定向 ---"
$scope = Join-Path $profileDir "node_modules\@deepseek-ai"
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $scope | Out-Null }

foreach ($n in $needed) {
  $target = Join-Path $pkgRoot $n
  $link   = Join-Path $scope $n
  if (-not (Test-Path $target)) { Warn "  $n 在 $ver 里不存在，跳过"; continue }
  $tver = (Get-Content (Join-Path $target "package.json") -Raw | ConvertFrom-Json).version
  if ($DryRun) { Info "  将联结 $n -> $tver"; continue }
  if (Test-Path $link) { Remove-Item $link -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
  Ok "  $n -> $tver"
}

# ---- 验证 ----
if (-not $DryRun) {
  $pluginDir = Join-Path $profileDir "node_modules\dsh-wx-bridge"
  if (Test-Path $pluginDir) {
    Info ""
    Info "--- 真实 ESM 解析验证 ---"
    $probe = Join-Path $pluginDir "_port_probe.mjs"
    @'
for (const n of ['@deepseek-ai/dsh-tools','@deepseek-ai/dsh-llm','@deepseek-ai/dsh-agent','@deepseek-ai/schemastery']) {
  try { console.log('  ' + n + ' -> ' + import.meta.resolve(n).replace('file:///','')) }
  catch (e) { console.log('  FAIL ' + n + ' ' + e.code) }
}
'@ | Set-Content -Path $probe -Encoding UTF8
    node $probe
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    Info ""
    Warn "  检查上面路径：应指向本次的 DSH 安装，"
    Warn "  而不是 ...\_npx\... （那是旧版本）。"
  }
}

Info ""
Ok "完成。"
Info ""
Warn "接下来："
Info "  1. 重启 dsh web"
Info "  2. 验证插件是否真的加载（关键判据）："
Info "     curl.exe -s -o NUL -w `"%{http_code}`" http://127.0.0.1:3080/chatops/api/status"
Info "     200 + JSON = 成功      404 = 插件仍未加载"
Info ""
Warn "风险与回滚："
Info "  - DSH 对该路径的原文警告是 'may cause crashes or data loss'。"
Info "  - 重装依赖可能清掉 node_modules/@deepseek-ai 联结，届时重跑本脚本。"
Info "  - 回滚：删除 profile 下的 compatibility.json 与 node_modules/@deepseek-ai，再重启。"
Info "  - 上游发布支持 0.2.x 的版本后，请改用上游版本并撤销本方案。"
