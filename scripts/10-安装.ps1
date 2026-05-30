
param([string]$Mode="install")
$ErrorActionPreference = "Stop"
$CommonScript = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "00-*.ps1" -File | Select-Object -First 1
if (!$CommonScript) {
  Write-Host "[致命] 未找到公共函数脚本 00-*.ps1" -ForegroundColor Red
  exit 1
}
try {
  . $CommonScript.FullName
} catch {
  Write-Host "[致命] 无法加载公共函数脚本：$($CommonScript.FullName)" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  exit 1
}
$Mode = if($Mode){$Mode.ToLowerInvariant()}else{"install"}
$env:OPK_INSTALL_MODE = $Mode
if (ConfBool "CLEAN_OLD_LOGS_ON_INSTALL" $true) {
  try {
    Get-ChildItem -LiteralPath $LogsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne ".keep" } | Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {}
}
$log = Join-Path $LogsDir ("install-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$transcriptStarted = $false
try {
  Start-Transcript -Path $log -Force | Out-Null
  $transcriptStarted = $true
  Write-Color "🔍 正在检查系统依赖..." Cyan
  Write-Color "🚀 正在启动 OpenCode Pocket Kit 安装 $PortableVersion ($Mode)" Cyan
  Write-Color "📁 根目录： $PortableRoot" DarkGray
  Write-Color "📁 配置目录： $ConfigDir" DarkGray
  Write-Color "📁 npm 全局目录： $NpmGlobalDir" DarkGray
  Write-Color "📁 仓库缓存： $RepoCacheDir" DarkGray
  Write-Color "🌐 代理配置： $ProxyConf" DarkGray
  if ($ProxyUrl) { Write-Color "🌐 已为 Git/npm/PowerShell 启用代理： $ProxyUrl" Green } else { Write-Color "🌐 未启用代理" Yellow }
  $npmRegistry = Conf "NPM_REGISTRY" "https://registry.npmjs.org"
  Write-Color "📦 npm 源： $npmRegistry" DarkGray

  $git = Resolve-Cmd "git" $true
  $npm = Resolve-Cmd "npm.cmd" $false; if (!$npm) { $npm = Resolve-Cmd "npm" $true }
  Write-Color "🔧 git： $git" DarkGray
  Write-Color "🔧 npm： $npm" DarkGray

  $forceUpdate = ($Mode -eq "force" -or $Mode -eq "reinstall")
  $configFile = Join-Path $ConfigDir "opencode.json"
  $freshConfigInstall = !(Test-Path -LiteralPath $configFile)
  $configWasPackDefault = Test-PackDefaultOpenCodeConfig $configFile
  $portable = Get-PortableOpenCodePath
  $opencodePkgOk = Install-NpmPackageIfNeeded "opencode-ai@latest" "opencode-ai" "OpenCode 本体" $forceUpdate

  $candidate = Join-Path $NpmGlobalDir "node_modules\opencode-ai\bin\opencode.exe"
  $target = Join-Path $BinDir "opencode.exe"
  if (Test-Path $candidate) {
    $needCopy = $true
    if ((Test-Path $target) -and !$forceUpdate) {
      try {
        $srcInfo = Get-Item -LiteralPath $candidate
        $dstInfo = Get-Item -LiteralPath $target
        if ($srcInfo.Length -eq $dstInfo.Length -and $srcInfo.LastWriteTimeUtc -le $dstInfo.LastWriteTimeUtc.AddSeconds(2)) { $needCopy = $false }
      } catch { $needCopy = $true }
    }
    if ($needCopy) {
      for ($i=0; $i -lt 45; $i++) {
        try { Copy-Item -LiteralPath $candidate -Destination $target -Force; break } catch { Start-Sleep -Milliseconds 500 }
      }
    }
  }
  $portable = Get-PortableOpenCodePath
  if (!$portable) { throw "npm 安装后仍未找到便携版 opencode，请检查上方 npm 输出。" }
  Write-Color "✅ 便携版 opencode 已就绪： $portable" Green

  if (!(Test-Path -LiteralPath $configFile)) {
    '{"$schema":"https://opencode.ai/config.json"}' | Set-Content -LiteralPath $configFile -Encoding UTF8
  }

  Write-Color "🤖 正在安装并启用 Oh-My-OpenAgent / OMO..." Cyan
  Ensure-OmoInstalledAndConfigured $forceUpdate | Out-Null

  if ($freshConfigInstall -or $configWasPackDefault) {
    # 初始配置场景下清理安装器产生的临时配置备份，避免首次运行留下噪音文件。
    Get-ChildItem -LiteralPath $ConfigDir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'opencode.json.backup-*' -or $_.Name -like 'opencode.json.bad-plugin-*.bak' } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }

  Write-Color "✅ 本体和 OMO 安装完成。安装入口将继续执行网络测试和可选组件下载。" Green
  Write-Color "📝 日志： $log" DarkGray
} catch {
  Write-Host "[致命] 安装失败：" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  exit 1
} finally {
  if ($transcriptStarted) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
}
