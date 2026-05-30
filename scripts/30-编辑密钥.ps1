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
# OCENV002 格式，不兼容 OCENV001：
# magic(8) + salt(16) + iv(16) + ciphertext(n) + hmac_sha256(32)
# PBKDF2-HMACSHA1(password, salt, 200000) -> 64 字节
#   前 32 字节：AES-256-CBC 密钥
#   后 32 字节：HMAC-SHA256 密钥

function Read-PasswordText($Prompt) {
  $secure = Read-Host $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-RandomBytes([int]$Length) {
  $bytes = New-Object byte[] $Length
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
    return $bytes
  } finally {
    $rng.Dispose()
  }
}

function Derive-KeyMaterial([string]$Password, [byte[]]$Salt) {
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, 200000)
  try {
    $material = $kdf.GetBytes(64)
    return @{
      EncKey = [byte[]]$material[0..31]
      MacKey = [byte[]]$material[32..63]
    }
  } finally {
    $kdf.Dispose()
  }
}

function Protect-TextOcenv002([string]$Text, [string]$EncPath, [string]$Password) {
  $plain = [Text.Encoding]::UTF8.GetBytes($Text)
  $magic = [Text.Encoding]::ASCII.GetBytes("OCENV002")
  $salt = New-RandomBytes 16
  $iv = New-RandomBytes 16
  $keys = Derive-KeyMaterial $Password $salt

  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Mode = "CBC"
  $aes.Padding = "PKCS7"
  $aes.Key = $keys.EncKey
  $aes.IV = $iv
  try {
    $encryptor = $aes.CreateEncryptor()
    $cipher = $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
  } finally {
    $aes.Dispose()
  }

  $body = [byte[]]($magic + $salt + $iv + $cipher)
  $hmac = [Security.Cryptography.HMACSHA256]::new([byte[]]$keys.MacKey)
  try {
    $tag = $hmac.ComputeHash($body)
  } finally {
    $hmac.Dispose()
  }

  [IO.File]::WriteAllBytes($EncPath, [byte[]]($body + $tag))
}

Write-Color "OpenCode Pocket Kit 加密密钥编辑器（OCENV002）。" Cyan
Write-Color "请输入 KEY=VALUE 格式的密钥变量，每行一个，空行结束。" Cyan
Write-Host ""

$lines = @()
while ($true) {
  $line = Read-Host "ENV"
  if ([string]::IsNullOrWhiteSpace($line)) { break }
  if ($line.Trim().StartsWith("#")) { $lines += $line; continue }
  if ($line.IndexOf("=") -lt 1) {
    Write-Color "已忽略无效行，因为不是 KEY=VALUE： $line" Yellow
    continue
  }
  $lines += $line
}

if ($lines.Count -eq 0) { throw "没有输入任何变量。" }

$envNames = @()
foreach ($l in $lines) {
  $t = $l.Trim()
  if (!$t -or $t.StartsWith("#")) { continue }
  $idx = $t.IndexOf("=")
  if ($idx -lt 1) { continue }
  $envNames += $t.Substring(0, $idx).Trim()
}


do {
  $p1 = Read-PasswordText "设置密钥库密码"
  $p2 = Read-PasswordText "再次输入密码"
  if ($p1 -ne $p2) { Write-Color "两次密码不一致。" Red }
} while ($p1 -ne $p2)

$enc = Join-Path $VaultDir "secrets.env.enc"

Protect-TextOcenv002 (($lines -join "`n") + "`n") $enc $p1
Write-Color "✅ 已保存 OCENV002 加密密钥库： $enc" Green

# 注意：本版本不会把 provider/model 写入 opencode.json。
# OMO 的模型路由由 OMO 自身配置负责，密钥只在 启动.cmd 启动时作为临时环境变量注入。

Write-Color "下一步：运行 启动.cmd，并输入刚才设置的密码。" Cyan
