# 校验 DSH Agent Preset 的 agent.cordis.yml
#
# 用法:
#   pwsh -File tools/check-preset.ps1
#   pwsh -File tools/check-preset.ps1 -Path "C:\Users\me\.dsh\.agent-presets\whale-girl\agent.cordis.yml"
#
# 目的: 在「开新会话测试」之前就抓出会炸的写法，省一轮迭代。
# 背景见 README 的「踩坑」一节 —— 一个 {{ }} 写法就能让整轮对话直接失败。

param(
  [string]$Path = (Join-Path $PSScriptRoot "..\preset\agent.cordis.yml")
)

$ErrorActionPreference = 'Continue'
$ok = $true

function Fail($m) { Write-Host "❌ $m" -ForegroundColor Red; $script:ok = $false }
function Pass($m) { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "⚠️  $m" -ForegroundColor Yellow }

# 解析 js-yaml：先在 DSH 安装目录里找，找不到就退化为「跳过 YAML 解析」。
function Find-JsYaml {
  $candidates = @()
  $candidates += Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'node_modules\js-yaml' }
  $candidates += Join-Path $PSScriptRoot '..\node_modules\js-yaml'
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'package.json'))) { return ($c -replace '\\', '/') }
  }
  return $null
}

$resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
if (-not $resolved) { Fail "文件不存在: $Path"; exit 1 }
$file = $resolved.Path

Write-Host "校验: $file" -ForegroundColor Cyan
Write-Host ""

$bytes = [IO.File]::ReadAllBytes($file)
$txt = [IO.File]::ReadAllText($file)

# 1. 编码
if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
  Warn "文件带 UTF-8 BOM，DSH 一般能吃，但不建议"
} else { Pass "无 BOM" }

# 2. 制表符（YAML 大忌）
if ($txt.Contains([char]9)) { Fail "含制表符 Tab —— YAML 不允许，必须换空格" } else { Pass "无制表符" }

# 3. 行尾空格
$trailing = (Get-Content $file | Select-String -Pattern '\s+$').Count
if ($trailing -gt 0) { Warn "$trailing 行有行尾空格（无害，不整洁）" } else { Pass "无行尾空格" }

# 4. {{ }} 陷阱 —— 最致命的错误，会导致整轮对话失败
$varHits = Get-Content $file | Select-String -Pattern '\{\{' | Where-Object { $_.Line -notmatch '^\s*#' }
if ($varHits) {
  Fail "发现非注释的 {{ 模板变量 —— 会抛 'has no value' 导致整轮失败:"
  $varHits | ForEach-Object { Write-Host "     L$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor Red }
  Write-Host "     提示: DSH 内置 {{model}} / {{cwd}} 在部分组装路径下无值。" -ForegroundColor Red
  Write-Host "     自己写 persona 时请一律用静态文本，切勿引入 {{...}}。" -ForegroundColor Red
} else { Pass "无 {{ 模板变量陷阱" }

# 5. persona 段
$lines = Get-Content $file
$personaLine = ($lines | Select-String -Pattern "^\s*- id: persona\s*$").LineNumber
if (-not $personaLine) { Fail "找不到 persona 段（- id: persona）" }
else {
  Pass "找到 persona 段 (L$personaLine)"
  $block = ($lines[($personaLine - 1)..([Math]::Min($personaLine + 90, $lines.Count - 1))]) -join "`n"
  if ($block -match 'prefix:\s*\|-') { Pass "prefix 存在（块标量 |-）" } else { Fail "prefix 缺失或格式不对（应为 prefix: |-）" }
  if ($block -match 'suffix:\s*\|-') { Pass "suffix 存在（块标量 |-）" } else { Warn "suffix 缺失" }
  if ($block -match 'name:\s*''@deepseek-ai/dsh-persona''') { Pass "persona 插件名正确" } else { Warn "persona 行 name 不是 '@deepseek-ai/dsh-persona'" }

  # 6. 奇数缩进
  $odd = $lines | Select-Object -Skip ($personaLine - 1) -First 70 |
    Where-Object { $_ -match '^\s+\S' } |
    Where-Object { ($_ -replace '^(\s*).*$', '$1').Length % 2 -ne 0 }
  if ($odd) {
    Warn "persona 附近有奇数缩进行（可能没事，但留意）:"
    $odd | Select-Object -First 3 | ForEach-Object { Write-Host "     $_" -ForegroundColor Yellow }
  } else { Pass "缩进为偶数（对齐正常）" }
}

# 7. YAML 结构解析（尽力而为）
$yamlDir = Find-JsYaml
if ($yamlDir) {
  $tmp = [IO.Path]::GetTempFileName()
  # !!js 是 DSH 自定义标签，普通 js-yaml 会拒；先替换掉再解析，只为验证结构。
  ($txt -replace '!!js', 'JS_TAG') | Set-Content -Path $tmp -Encoding UTF8
  $parsed = node -e "
const fs=require('fs');
const yaml=require('$yamlDir');
try {
  const d=yaml.load(fs.readFileSync(process.argv[1],'utf8'));
  console.log(JSON.stringify({ok:true, count: Array.isArray(d)?d.length:-1}));
} catch(e){ console.log(JSON.stringify({ok:false, err:String(e.message).split('\n')[0]})); }
" $tmp 2>&1 | Select-Object -Last 1
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  if ($parsed -match '"ok":true') { Pass "YAML 结构可解析" }
  else { Fail "YAML 解析失败: $parsed" }
} else {
  Warn "未找到 js-yaml，跳过 YAML 结构解析（其余检查仍有效）"
}

Write-Host ""
if ($ok) { Write-Host "结论: 通过，可以部署并开新会话测试了" -ForegroundColor Green }
else { Write-Host "结论: 有问题，先修再测（否则会整轮失败）" -ForegroundColor Red }
exit ([int](-not $ok))
