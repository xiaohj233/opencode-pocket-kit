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

function Get-CommandAliasName {
  $conf = Join-Path $PortableRoot "command.conf"
  $name = "opkcode"
  if (Test-Path -LiteralPath $conf) {
    foreach ($line in Get-Content -LiteralPath $conf -Encoding UTF8) {
      $t = $line.Trim()
      if (!$t -or $t.StartsWith("#")) { continue }
      $idx = $t.IndexOf("=")
      if ($idx -lt 1) { continue }
      $k = $t.Substring(0, $idx).Trim()
      $v = $t.Substring($idx + 1).Trim()
      if ($k -eq "COMMAND_NAME" -and $v) { $name = $v }
    }
  }
  if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
    throw "COMMAND_NAME 只能使用英文字母、数字、短横线和下划线，并且必须以英文字母开头。当前值：$name"
  }
  return $name
}

function Write-AsciiFile([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.ASCIIEncoding
  [IO.File]::WriteAllText($Path, $Text, $enc)
}

$commandName = Get-CommandAliasName
$cmdDir = Join-Path $PortableRoot "cmd"
New-Item -ItemType Directory -Force -Path $cmdDir | Out-Null
$shimPath = Join-Path $cmdDir ($commandName + ".cmd")

$shim = @"
@echo off
setlocal
set "ROOT=%~dp0.."
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"
set "PS_SCRIPT="
for %%F in ("%ROOT%\scripts\20-*.ps1") do set "PS_SCRIPT=%%~fF"
if not defined PS_SCRIPT exit /b 1
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Workspace "%CD%"
exit /b %ERRORLEVEL%
"@
$shim = ($shim -replace "`n", "`r`n")
Write-AsciiFile $shimPath $shim

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
$exists = $false
foreach ($p in $parts) {
  if ([string]::Equals($p.TrimEnd('\'), $cmdDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { $exists = $true }
}
if (!$exists) {
  $newPath = if ($userPath) { $cmdDir + ";" + $userPath } else { $cmdDir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  $env:PATH = $cmdDir + ";" + $env:PATH
  Write-Color "✅ 已将命令目录写入当前用户 PATH： $cmdDir" Green
} else {
  Write-Color "✅ 命令目录已在当前用户 PATH 中： $cmdDir" Green
}

$existing = Get-Command $commandName -ErrorAction SilentlyContinue
if ($existing -and $existing.Source -and ![string]::Equals($existing.Source, $shimPath, [System.StringComparison]::OrdinalIgnoreCase)) {
  Write-Color "⚠️ 检测到同名命令已存在： $($existing.Source)" Yellow
  Write-Color "   如果命令冲突，请修改 command.conf 中的 COMMAND_NAME 后重新运行 注册命令.cmd。" Yellow
}

Write-Color "✅ 已生成命令： $shimPath" Green
Write-Color "✅ 注册完成。重新打开终端后，可以在任意目录运行： $commandName" Green
Write-Color "示例：" Cyan
Write-Color "  cd D:\\YourProject" White
Write-Color "  $commandName" White
