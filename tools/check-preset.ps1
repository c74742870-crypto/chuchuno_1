# 校验鲸鱼娘 preset 文件（同时支持 DSH 0.1.x 与 0.2.x 两种格式）
#
# 用法:
#   pwsh -File tools/check-preset.ps1                    # 校验 preset/ 下所有文件
#   pwsh -File tools/check-preset.ps1 -Path <某个文件>
#
# 支持:
#   preset/agent.cordis.yml      DSH 0.1.x 格式（目录式 preset）
#   preset/whale-girl.patch.yml  DSH 0.2.x 格式（声明式 @deepseek-ai/dsh-agent-preset）
#
# 目的：在「装上去重启」之前就抓出会炸的写法。

param(
  [string]$Path
)

$ErrorActionPreference = 'Continue'
$script:anyFail = $false

function Fail($m) { Write-Host "❌ $m" -ForegroundColor Red; $script:ok = $false }
function Pass($m) { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }

function Find-JsYaml {
  $cands = @()
  $cands += Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'node_modules\js-yaml' }
  $cands += Join-Path $env:APPDATA 'npm\node_modules\js-yaml'
  $cands += Join-Path $PSScriptRoot '..\node_modules\js-yaml'
  foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c 'package.json'))) { return ($c -replace '\\', '/') }
  }
  return $null
}

function Check-File([string]$file) {
  $script:ok = $true
  Write-Host ""
  Write-Host "校验: $file" -ForegroundColor Cyan

  $bytes = [IO.File]::ReadAllBytes($file)
  $txt = [IO.File]::ReadAllText($file)

  if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
    Warn "带 UTF-8 BOM（DSH 一般能吃，但不建议）"
  } else { Pass "无 BOM" }

  if ($txt.Contains([char]9)) { Fail "含制表符 Tab —— YAML 不允许" } else { Pass "无制表符" }

  # 按结构判格式（不按关键字是否出现——注释里提到包名不算）
  $hasInsertRow  = $txt -match "(?m)^\s*-\s*insert:\s*$"
  $hasPluginRow  = $txt -match "(?m)^\s*name:\s*'@deepseek-ai/dsh-agent-preset'\s*$"
  $hasPresetId   = $txt -match "(?m)^\s*id:\s*whale-girl\s*$"
  $hasPersonaRow = $txt -match "(?m)^\s*-?\s*id:\s*persona\s*$"
  $hasPluginsKey = $txt -match "(?m)^\s*plugins:\s*$"

  $isMeta = (-not $hasPluginRow) -and (-not $hasInsertRow) -and (-not $hasPersonaRow) -and $txt -match "(?m)^\s*name:\s*\S"
  $is02   = $hasPluginRow -or $hasInsertRow -or $hasPresetId -or $hasPluginsKey

  if ($isMeta) {
    Write-Host "识别文件类型: preset 元数据（name/description/order）" -ForegroundColor DarkGray
    foreach ($k in @("name", "description")) {
      if ($txt -match "(?m)^\s*$k\s*:\s*\S") { Pass "有 $k" } else { Warn "缺 $k" }
    }
    if ($txt -match "(?m)^\s*order\s*:\s*\d+") { Pass "有 order" } else { Warn "缺 order" }
    $y = Find-JsYaml
    if ($y) {
      $tmp = [IO.Path]::GetTempFileName()
      Set-Content -Path $tmp -Value $txt -Encoding UTF8
      $p = node -e "
const fs=require('fs');
try { const d=require('$y').load(fs.readFileSync(process.argv[1],'utf8')); console.log(JSON.stringify({ok:true,name:d&&d.name})); }
catch(e){ console.log(JSON.stringify({ok:false,err:String(e.message).split('\n')[0]})); }
" $tmp 2>&1 | Select-Object -Last 1
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      if ($p -match '"ok":true') { Pass "YAML 可解析" } else { Fail "YAML 解析失败: $p" }
    }
    if ($script:ok) { Write-Host "→ 通过" -ForegroundColor Green } else { $script:anyFail = $true }
    return
  }

  if ($is02) { Pass "识别格式: 0.2.x 声明式" } else { Pass "识别格式: 0.1.x 目录式" }

  if ($is02) {
    if ($txt -match "(?m)^\s*-\s*insert:\s*$") { Pass "有 - insert: 包装（必需）" }
    else { Fail "缺少 - insert: 包装 —— 顶层裸条目会被当成「覆盖已有行」并报 entry not found" }

    if ($txt -match "(?m)^\s*-?\s*id:\s*preset-whale-girl\s*$") { Pass "行 id = preset-whale-girl" }
    else { Warn "没有 'id: preset-whale-girl'（行 id 建议带 preset- 前缀）" }

    if ($txt -match "(?m)^\s*id:\s*whale-girl\s*$") { Pass "preset id = whale-girl" }
    else { Fail "找不到 'id: whale-girl'" }

    if ($txt -match "(?m)^\s*-?\s*id:\s*persona\s*$") { Pass "含 persona 行" }
    else { Fail "找不到 persona 行 —— preset 会没有人格" }

    $pc = ([regex]::Matches($txt, "(?m)^\s*prefix:\s*\|")).Count
    $sc = ([regex]::Matches($txt, "(?m)^\s*suffix:\s*\|")).Count
    if ($pc -ge 1 -and $sc -ge 1) { Pass "prefix / suffix 都是块标量 |-" }
    else { Fail "prefix 或 suffix 不是块标量（应为 prefix: |-）" }

    $hits = Get-Content $file | Select-String -Pattern '\{\{' | Where-Object { $_.Line -notmatch '^\s*#' }
    if ($hits) {
      Warn "含 $($hits.Count) 处 {{...}} 模板变量（官方 standard 也有，但本仓库刻意不含）"
      Warn "  实测这类变量在本 preset 作用域下会抛 has no value 导致整轮失败，新增请谨慎"
    } else { Pass "persona 文本无 {{...}} 模板变量" }
  } else {
    $lines = Get-Content $file
    $personaLine = ($lines | Select-String -Pattern "^\s*- id: persona\s*$").LineNumber
    if (-not $personaLine) { Fail "找不到 persona 段" }
    else {
      Pass "找到 persona 段 (L$personaLine)"
      $block = ($lines[($personaLine - 1)..([Math]::Min($personaLine + 90, $lines.Count - 1))]) -join "`n"
      if ($block -match 'prefix:\s*\|-') { Pass "prefix 存在" } else { Fail "prefix 缺失或格式不对（应为 prefix: |-）" }
      if ($block -match 'suffix:\s*\|-') { Pass "suffix 存在" } else { Warn "suffix 缺失" }
      if ($block -match "name:\s*'@deepseek-ai/dsh-persona'") { Pass "persona 插件名正确" } else { Warn "persona 行 name 不是 '@deepseek-ai/dsh-persona'" }
    }

    $varHits = Get-Content $file | Select-String -Pattern '\{\{' | Where-Object { $_.Line -notmatch '^\s*#' }
    if ($varHits) {
      Fail "含非注释的 {{ 模板变量 —— 在 0.1.x 目录式 preset 下会导致整轮失败："
      $varHits | ForEach-Object { Write-Host "     L$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor Red }
    } else { Pass "无 {{...}} 模板变量" }
  }

  $yamlDir = Find-JsYaml
  if ($yamlDir) {
    $tmp = [IO.Path]::GetTempFileName()
    ($txt -replace '!!js', 'JS_TAG') | Set-Content -Path $tmp -Encoding UTF8
    $parsed = node -e "
const fs=require('fs');
const yaml=require('$yamlDir');
try { const d=yaml.load(fs.readFileSync(process.argv[1],'utf8')); console.log(JSON.stringify({ok:true,arr:Array.isArray(d)})); }
catch(e){ console.log(JSON.stringify({ok:false,err:String(e.message).split('\n')[0]})); }
" $tmp 2>&1 | Select-Object -Last 1
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($parsed -match '"ok":true') { Pass "YAML 结构可解析" } else { Fail "YAML 解析失败: $parsed" }
  } else {
    Warn "未找到 js-yaml，跳过 YAML 结构解析"
  }

  if ($script:ok) { Write-Host "→ 通过" -ForegroundColor Green }
  else { Write-Host "→ 有问题，先修再装" -ForegroundColor Red; $script:anyFail = $true }
}

if ($Path) {
  if (-not (Test-Path $Path)) { Write-Host "❌ 文件不存在: $Path" -ForegroundColor Red; exit 1 }
  Check-File (Resolve-Path $Path).Path
} else {
  $dir = Join-Path $PSScriptRoot "..\preset"
  if (-not (Test-Path $dir)) { Write-Host "❌ 找不到 preset 目录: $dir" -ForegroundColor Red; exit 1 }
  $files = Get-ChildItem $dir -File | Where-Object { $_.Extension -in @(".yml", ".yaml") }
  if (-not $files) { Write-Host "❌ preset 目录里没有 yml 文件" -ForegroundColor Red; exit 1 }
  foreach ($f in $files) { Check-File $f.FullName }
}

Write-Host ""
if ($script:anyFail) { Write-Host "有文件未通过 —— 先修再装" -ForegroundColor Red; exit 1 }
Write-Host "全部通过" -ForegroundColor Green
exit 0
