param([string]$Workspace="")
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
# 运行规则：
# - 启动.cmd 只准备便携环境，并在有密钥库时临时加载密钥。
# - 启动.cmd 不改写 opencode.json。
# - 启动.cmd 不生成 provider/model 配置。
# - 启动.cmd 不生成 OMO 路由 json/jsonc。
# - OMO 插件由 安装.cmd 写入 opencode.json。

function Read-PasswordText($Prompt) {
  $secure = Read-Host $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Derive-KeyMaterial([string]$Password, [byte[]]$Salt) {
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, 200000)
  try {
    $material = $kdf.GetBytes(64)
    return @{
      EncKey = [byte[]]$material[0..31]
      MacKey = [byte[]]$material[32..63]
    }
  } finally { $kdf.Dispose() }
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
  if ($null -eq $A -or $null -eq $B) { return $false }
  if ($A.Length -ne $B.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
  return $diff -eq 0
}

function Unprotect-TextOcenv002([string]$EncPath, [string]$Password) {
  $all = [IO.File]::ReadAllBytes($EncPath)
  $magic = [Text.Encoding]::ASCII.GetBytes("OCENV002")
  if ($all.Length -lt 88) { throw "密钥库格式错误，请重新运行 编辑密钥.cmd 创建。" }
  $fileMagic = [byte[]]$all[0..7]
  if (!(Test-BytesEqual $magic $fileMagic)) {
    $magicText = [Text.Encoding]::ASCII.GetString($fileMagic)
    throw "不支持的密钥库格式 '$magicText'. 本包只支持 OCENV002。请用 编辑密钥.cmd 重新创建 vault\secrets.env.enc。"
  }
  $salt = [byte[]]$all[8..23]
  $iv = [byte[]]$all[24..39]
  $tag = [byte[]]$all[($all.Length - 32)..($all.Length - 1)]
  $body = [byte[]]$all[0..($all.Length - 33)]
  $cipher = [byte[]]$all[40..($all.Length - 33)]
  $keys = Derive-KeyMaterial $Password $salt
  $hmac = [Security.Cryptography.HMACSHA256]::new([byte[]]$keys.MacKey)
  try { $calc = $hmac.ComputeHash($body) } finally { $hmac.Dispose() }
  if (!(Test-BytesEqual $tag $calc)) { throw "密码错误，或密钥库已损坏。" }
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Mode = "CBC"; $aes.Padding = "PKCS7"; $aes.Key = $keys.EncKey; $aes.IV = $iv
  try {
    $decryptor = $aes.CreateDecryptor()
    $plain = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
    return [Text.Encoding]::UTF8.GetString($plain)
  } finally { $aes.Dispose() }
}

Apply-PortableEnvironment

$secrets = Join-Path $VaultDir "secrets.env.enc"
$loaded = 0
if (Test-Path -LiteralPath $secrets) {
  $pwd = Read-PasswordText "输入加密密钥库密码"
  $txt = Unprotect-TextOcenv002 $secrets $pwd
  foreach ($line in ($txt -split "`r?`n")) {
    $t = $line.Trim()
    if (!$t -or $t.StartsWith("#")) { continue }
    $idx = $t.IndexOf("=")
    if ($idx -lt 1) { continue }
    $name = $t.Substring(0, $idx).Trim()
    $value = $t.Substring($idx + 1).Trim()
    [Environment]::SetEnvironmentVariable($name, $value, "Process")
    $loaded++
  }
  Write-Color "✅ 已加载 $loaded 个仅当前窗口有效的临时密钥环境变量。" Green
} else {
  Write-Color "ℹ️ 尚未创建 vault\secrets.env.enc，将在没有 API Key 环境变量的情况下启动。" Yellow
}

$oc = Get-PortableOpenCodePath
if (!$oc) { throw "未找到便携版 opencode，请先运行 安装.cmd。" }

Write-Color "✅ 使用 OpenCode 配置： $env:OPENCODE_CONFIG" DarkGray

$targetWorkspace = $ProjectsDir
if (![string]::IsNullOrWhiteSpace($Workspace)) {
  $targetWorkspace = $Workspace
}
if (!(Test-Path -LiteralPath $targetWorkspace)) {
  throw "工作目录不存在： $targetWorkspace"
}
$resolvedWorkspace = (Resolve-Path -LiteralPath $targetWorkspace).ProviderPath
Write-Color "📁 当前 OpenCode 工作目录： $resolvedWorkspace" Cyan
Set-Location -LiteralPath $resolvedWorkspace
& $oc
