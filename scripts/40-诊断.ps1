$ErrorActionPreference = "Continue"
$CommonScript = Join-Path $PSScriptRoot "00-公共函数.ps1"
try { . $CommonScript } catch {
  Write-Host "[致命] 无法加载 00-公共函数.ps1" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  exit 1
}
Apply-PortableEnvironment

function Show-PathStatus([string]$Label,[string]$Path) {
  if (Test-Path -LiteralPath $Path) { Write-Host ("[存在] {0}" -f $Path) -ForegroundColor Green } else { Write-Host ("[缺失] {0}" -f $Path) -ForegroundColor DarkYellow }
}

Write-Host ""
Write-Host "========== 便携环境 ==========" -ForegroundColor Cyan
Write-Host "PSScriptRoot          = $PSScriptRoot"
Write-Host "当前目录     = $(Get-Location)"
Write-Host "ProjectsDir           = $ProjectsDir"
Write-Host "VaultDir              = $VaultDir"
Write-Host "OPENCODE_CONFIG       = $env:OPENCODE_CONFIG"
Write-Host "OPENCODE_CONFIG_DIR   = $env:OPENCODE_CONFIG_DIR"
Write-Host "APPDATA               = $env:APPDATA"
Write-Host "USERPROFILE           = $env:USERPROFILE"
Write-Host "HOME                  = $env:HOME"
Write-Host "NODE_PATH             = $env:NODE_PATH"
Write-Host "便携 OpenCode     = $(Get-PortableOpenCodePath)"

Write-Host ""
Write-Host "========== 配置文件检查 ==========" -ForegroundColor Cyan
Show-PathStatus "opencode" (Join-Path $ConfigDir "opencode.json")
Show-PathStatus "tui" (Join-Path $ConfigDir "tui.json")
Show-PathStatus "package" (Join-Path $ConfigDir "package.json")

Write-Host ""
Write-Host "========== OMO 路由配置候选 ==========" -ForegroundColor Cyan
foreach ($p in @(
  (Join-Path $ConfigDir "oh-my-opencode.jsonc"),
  (Join-Path $ConfigDir "oh-my-opencode.json"),
  (Join-Path $ConfigDir "oh-my-openagent.jsonc"),
  (Join-Path $ConfigDir "oh-my-openagent.json"),
  (Join-Path $ProjectsDir ".opencode\oh-my-opencode.jsonc"),
  (Join-Path $ProjectsDir ".opencode\oh-my-opencode.json"),
  (Join-Path $ProjectsDir ".opencode\oh-my-openagent.jsonc"),
  (Join-Path $ProjectsDir ".opencode\oh-my-openagent.json")
)) { Show-PathStatus "route" $p }

Write-Host ""
Write-Host "========== 工具链检查 ==========" -ForegroundColor Cyan
foreach ($cmd in @("node","npm","git","opencode","gh","bun","bunx")) {
  $c = Get-Command $cmd -ErrorAction SilentlyContinue
  if ($c) { Write-Host "[正常] $cmd => $($c.Source)" -ForegroundColor Green } else { Write-Host "[警告] $cmd 未在 PATH 中找到" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "========== OpenCode 版本 ==========" -ForegroundColor Cyan
$oc = Get-PortableOpenCodePath
if ($oc) { try { & $oc --version } catch { Write-Host $_ -ForegroundColor Yellow } } else { Write-Host "[缺失] 未找到便携版 opencode" -ForegroundColor Yellow }

Write-Host ""
Write-Host "========== OMO 配置状态 ==========" -ForegroundColor Cyan
$pluginName = Get-OmoPluginName
if (Test-OmoConfigPluginPresent $pluginName) {
  Write-Host "[正常] opencode.json 已启用插件： $pluginName" -ForegroundColor Green
} else {
  Write-Host "[警告] opencode.json 未检测到插件： $pluginName。请重新运行 安装.cmd。" -ForegroundColor Yellow
}
$tuiFile = Join-Path $ConfigDir "tui.json"
$tuiOk = $false
if (Test-Path -LiteralPath $tuiFile) {
  try {
    $tuiRaw = Get-Content -LiteralPath $tuiFile -Raw -Encoding UTF8
    $tuiOk = ($tuiRaw -match ([regex]::Escape($pluginName + '/tui')))
  } catch { $tuiOk = $false }
}
if ($tuiOk) { Write-Host "[正常] tui.json 已启用 TUI 插件： $pluginName/tui" -ForegroundColor Green } else { Write-Host "[警告] tui.json 未检测到 TUI 插件： $pluginName/tui。请重新运行 安装.cmd。" -ForegroundColor Yellow }
$omoPkg = Get-InstalledOmoPackage
if ($omoPkg) { Write-Host "[正常] 检测到 OMO 包： $omoPkg" -ForegroundColor Green } else { Write-Host "[警告] 便携 npm 目录中未检测到 OMO 包" -ForegroundColor Yellow }

Write-Host ""
Write-Host "========== Comment Checker 检查 ==========" -ForegroundColor Cyan
$checkerCandidates = @(
  (Join-Path $NpmGlobalDir "comment-checker.cmd"),
  (Join-Path $NpmGlobalDir "node_modules\.bin\comment-checker.cmd"),
  (Join-Path $ConfigDir "node_modules\.bin\comment-checker.cmd"),
  (Join-Path $ConfigDir "node_modules\@code-yeongyu\comment-checker\vendor\win32-x64\comment-checker.exe")
)
$foundChecker = $false
foreach ($p in $checkerCandidates) { if (Test-Path -LiteralPath $p) { Write-Host "[OK] $p" -ForegroundColor Green; $foundChecker=$true } }
if (!$foundChecker) { Write-Host "[警告] 未找到 comment-checker 二进制文件。请运行 安装.cmd 安装便携依赖。" -ForegroundColor Yellow }

Write-Host ""
Write-Host "========== OMO Doctor ==========" -ForegroundColor Cyan
$cli = Get-OmoDoctorCliPath
if ($cli) {
  Write-Host "[信息] 使用本地 OMO CLI： $cli" -ForegroundColor DarkGray
  $res = Invoke-NativeCapture -File $cli -Arguments @('doctor') -TimeoutSeconds (ConfInt 'OMO_DOCTOR_TIMEOUT_SECONDS' 180) -AllowFailure
  if ($res.Output) { Write-Host $res.Output }
  if ($res.Output -match 'GitHub CLI not authenticated') {
    Write-Host "[提示] GitHub CLI 登录不会自动处理。只有需要 GitHub 自动化时，才需要自行运行 gh auth login。" -ForegroundColor Yellow
  }
} else {
  Write-Host "[警告] 未找到 OMO CLI。请运行 安装.cmd。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========== 完成 ==========" -ForegroundColor Cyan
