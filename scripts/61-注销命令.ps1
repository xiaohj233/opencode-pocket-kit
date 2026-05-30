$ErrorActionPreference = "Stop"
$CommonScript = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "00-*.ps1" -File | Select-Object -First 1
if (!$CommonScript) {
  Write-Host "[致命] 未找到公共函数脚本 00-*.ps1" -ForegroundColor Red
  exit 1
}
try { . $CommonScript.FullName } catch {
  Write-Host "[致命] 无法加载公共函数脚本：$($CommonScript.FullName)" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  exit 1
}

$cmdDir = Join-Path $PortableRoot "cmd"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
$newParts = @()
$removed = $false
foreach ($p in $parts) {
  if ([string]::Equals($p.TrimEnd('\'), $cmdDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    $removed = $true
    continue
  }
  $newParts += $p
}
if ($removed) {
  [Environment]::SetEnvironmentVariable("Path", ($newParts -join ';'), "User")
  Write-Color "✅ 已从当前用户 PATH 移除命令目录： $cmdDir" Green
} else {
  Write-Color "ℹ️ 当前用户 PATH 中没有发现命令目录： $cmdDir" Yellow
}
Write-Color "注销完成。已经打开的终端可能需要关闭后重新打开。" Cyan
