
$ErrorActionPreference = "Stop"
$ScriptVersion = "v14-working-tree-zip-encoding-safe"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Get-ScriptRootPath {
  if ($PSScriptRoot) { return [IO.Path]::GetFullPath($PSScriptRoot) }
  return [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
}

function Get-RepoCandidateRoot {
  $scriptDir = Get-ScriptRootPath
  return [IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
}

function Resolve-ExternalCommand([string]$Name) {
  $items = @(Get-Command $Name -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
  if ($items.Count -eq 0 -and $Name -notmatch '\.exe$') {
    $items = @(Get-Command ($Name + '.exe') -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
  }
  foreach ($item in $items) {
    foreach ($p in @($item.Path, $item.Source, $item.Definition)) {
      if ($p -and (Test-Path -LiteralPath $p)) { return [IO.Path]::GetFullPath($p) }
    }
  }
  throw "找不到外部命令：$Name"
}

function Quote-Arg([string]$Arg) {
  if ($null -eq $Arg) { return '""' }
  if ($Arg -eq '') { return '""' }
  if ($Arg -notmatch '[\s"]') { return $Arg }
  return '"' + ($Arg -replace '"','\"') + '"'
}

function Invoke-External {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet,
    [switch]$SuppressLineEndingWarnings
  )
  if ([string]::IsNullOrWhiteSpace($FilePath)) { throw "内部错误：外部命令路径为空。" }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (($ArgumentList | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
  $psi.WorkingDirectory = $Global:GitRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($SuppressLineEndingWarnings) {
    $stderrLines = @()
    foreach ($line in ($stderr -split "`r?`n")) {
      if ($line -match 'warning: in the working copy of .+ will be replaced by .+ the next time Git touches it') { continue }
      if ($line.Trim().Length -gt 0) { $stderrLines += $line }
    }
    $stderr = ($stderrLines -join "`n")
  }

  if (!$Quiet) {
    if ($stdout.Trim().Length -gt 0) { Write-Host $stdout.TrimEnd() }
    if ($stderr.Trim().Length -gt 0) { Write-Host $stderr.TrimEnd() -ForegroundColor Yellow }
  }

  if ($p.ExitCode -ne 0 -and !$AllowFailure) {
    $msg = "命令执行失败：$FilePath"
    if ($stderr.Trim().Length -gt 0) { $msg += "`n$stderr" }
    elseif ($stdout.Trim().Length -gt 0) { $msg += "`n$stdout" }
    throw $msg
  }

  return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
  $args2 = @('-C', $Global:GitRoot) + $GitArgs
  return Invoke-External -FilePath $Global:GitExe -ArgumentList $args2 -Quiet
}

function Invoke-GitVisible {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
  $args2 = @('-C', $Global:GitRoot) + $GitArgs
  return Invoke-External -FilePath $Global:GitExe -ArgumentList $args2 -SuppressLineEndingWarnings:($Global:SuppressGitWarnings -eq '1')
}

function Invoke-Gh {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GhArgs)
  return Invoke-External -FilePath $Global:GhExe -ArgumentList $GhArgs -Quiet
}

function Read-Conf([string]$Path) {
  $map = @{}
  if (!(Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
    $t = $line.Trim()
    if (!$t -or $t.StartsWith('#')) { continue }
    $idx = $t.IndexOf('=')
    if ($idx -lt 0) { continue }
    $k = $t.Substring(0, $idx).Trim()
    $v = $t.Substring($idx + 1).Trim()
    $map[$k] = $v
  }
  return $map
}

function Get-FileEncodingInfo([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return [pscustomobject]@{ Name='utf8-bom'; Encoding=(New-Object Text.UTF8Encoding($true)); PreambleLength=3 }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return [pscustomobject]@{ Name='utf16le-bom'; Encoding=[Text.Encoding]::Unicode; PreambleLength=2 }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return [pscustomobject]@{ Name='utf16be-bom'; Encoding=[Text.Encoding]::BigEndianUnicode; PreambleLength=2 }
  }
  return [pscustomobject]@{ Name='utf8-nobom'; Encoding=(New-Object Text.UTF8Encoding($false)); PreambleLength=0 }
}

function Read-TextPreserve([string]$Path) {
  $enc = Get-FileEncodingInfo $Path
  $bytes = [IO.File]::ReadAllBytes($Path)
  $text = $enc.Encoding.GetString($bytes, $enc.PreambleLength, $bytes.Length - $enc.PreambleLength)
  return [pscustomobject]@{ Text=$text; Encoding=$enc.Encoding; EncodingName=$enc.Name }
}

function Write-TextPreserve([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
  $preamble = $Encoding.GetPreamble()
  $body = $Encoding.GetBytes($Text)
  $out = New-Object byte[] ($preamble.Length + $body.Length)
  [Array]::Copy($preamble, 0, $out, 0, $preamble.Length)
  [Array]::Copy($body, 0, $out, $preamble.Length, $body.Length)
  [IO.File]::WriteAllBytes($Path, $out)
}

function Increment-Version([string]$Version) {
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "版本号格式不正确：$Version" }
  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  $patch = [int]$Matches[3]
  if ($patch -lt 9) { $patch++ }
  else {
    $patch = 0
    if ($minor -lt 9) { $minor++ }
    else { $minor = 0; $major++ }
  }
  return "$major.$minor.$patch"
}

function Ensure-GitIgnoreLine([string]$Line) {
  $path = Join-Path $Global:GitRoot '.gitignore'
  if (Test-Path -LiteralPath $path) {
    $data = Read-TextPreserve $path
    $lines = @($data.Text -split "`r?`n")
    if ($lines -contains $Line) { return }
    $newText = $data.Text.TrimEnd("`r", "`n") + "`n" + $Line + "`n"
    Write-TextPreserve $path $newText $data.Encoding
  } else {
    [IO.File]::WriteAllText($path, $Line + "`n", (New-Object Text.UTF8Encoding($false)))
  }
}

function Update-VersionInFiles([string]$OldVersion, [string]$NewVersion) {
  $targets = @()
  $includeExt = @('.md', '.ps1', '.json', '.jsonc', '.conf', '.txt')
  foreach ($file in Get-ChildItem -LiteralPath $Global:GitRoot -Recurse -File -Force) {
    $rel = Get-RelativePath $Global:GitRoot $file.FullName
    if (Should-ExcludeFromPackage $rel) { continue }
    if ($file.Extension -in @('.cmd', '.bat', '.zip', '.exe', '.dll', '.png', '.jpg', '.jpeg', '.gif', '.ico')) { continue }
    if ($file.Name -eq 'VERSION' -or $includeExt -contains $file.Extension.ToLowerInvariant()) { $targets += $file.FullName }
  }

  foreach ($path in $targets | Select-Object -Unique) {
    $data = Read-TextPreserve $path
    if ($data.Text.Contains($OldVersion)) {
      $newText = $data.Text.Replace($OldVersion, $NewVersion)
      Write-TextPreserve $path $newText $data.Encoding
      Write-Host "已更新版本号并保留编码：$path [$($data.EncodingName)]"
    }
  }
}

function Get-RelativePath([string]$Base, [string]$FullPath) {
  $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $targetFull = [IO.Path]::GetFullPath($FullPath)
  $baseUri = New-Object Uri($baseFull)
  $targetUri = New-Object Uri($targetFull)
  $rel = $baseUri.MakeRelativeUri($targetUri).ToString()
  $rel = [Uri]::UnescapeDataString($rel)
  return ($rel -replace '/', '\')
}

function Should-ExcludeFromPackage([string]$RelPath) {
  $r = ($RelPath -replace '/', '\').TrimStart('\')
  $lower = $r.ToLowerInvariant()
  $prefixes = @(
    '.git\', '.release\', 'node_modules\', 'npm-global\node_modules\',
    'config\opencode\node_modules\', 'repo-cache\', 'logs\', 'backups\',
    'home\', 'projects\', 'data\runtime\'
  )
  foreach ($p in $prefixes) { if ($lower.StartsWith($p)) { return $true } }
  $names = @('vault\secrets.env.enc')
  foreach ($n in $names) { if ($lower -eq $n) { return $true } }
  if ($lower.EndsWith('.zip')) { return $true }
  if ($lower.EndsWith('.bak')) { return $true }
  return $false
}

function New-ReleaseZipFromWorkingTree([string]$ZipPath, [string]$TopDir) {
  if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
  Add-Type -AssemblyName System.IO.Compression | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $fs = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew)
  try {
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
    try {
      $files = Get-ChildItem -LiteralPath $Global:GitRoot -Recurse -File -Force
      foreach ($file in $files) {
        $rel = Get-RelativePath $Global:GitRoot $file.FullName
        if (Should-ExcludeFromPackage $rel) { continue }
        $entryName = ($TopDir.TrimEnd('/') + '/' + ($rel -replace '\\','/'))
        $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]$file.LastWriteTime
        $inStream = [IO.File]::OpenRead($file.FullName)
        try {
          $outStream = $entry.Open()
          try { $inStream.CopyTo($outStream) }
          finally { $outStream.Dispose() }
        } finally { $inStream.Dispose() }
      }
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
}

function Get-LatestTag {
  $result = Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $Global:GitRoot, 'describe', '--tags', '--abbrev=0') -AllowFailure -Quiet
  if ($result.ExitCode -eq 0) { return $result.Stdout.Trim() }
  return ''
}

function Get-CommitNotes([string]$SinceTag) {
  if ($SinceTag) {
    $r = Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $Global:GitRoot, 'log', '--pretty=format:%h %s', "$SinceTag..HEAD") -AllowFailure -Quiet
  } else {
    $r = Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $Global:GitRoot, 'log', '--pretty=format:%h %s', '-20') -AllowFailure -Quiet
  }
  if ($r.ExitCode -eq 0 -and $r.Stdout.Trim()) { return $r.Stdout.Trim() }
  return '本次发布包含最新提交。'
}

function Test-GhReleaseExists([string]$Tag) {
  $r = Invoke-External -FilePath $Global:GhExe -ArgumentList @('release', 'view', $Tag) -AllowFailure -Quiet
  return ($r.ExitCode -eq 0)
}

try {
  Write-Host "OpenCode Pocket Kit 一键发布版本工具"
  $candidate = Get-RepoCandidateRoot
  $Global:GitExe = Resolve-ExternalCommand 'git'
  $Global:GhExe = Resolve-ExternalCommand 'gh'

  $rootResult = Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $candidate, 'rev-parse', '--show-toplevel') -Quiet
  $Global:GitRoot = [IO.Path]::GetFullPath($rootResult.Stdout.Trim())
  Write-Host "仓库目录：$Global:GitRoot"

  $confPath = Join-Path $Global:GitRoot 'release.conf'
  $conf = Read-Conf $confPath
  $projectName = if ($conf['PROJECT_NAME']) { $conf['PROJECT_NAME'] } else { 'opencode-pocket-kit' }
  $versionFile = if ($conf['VERSION_FILE']) { $conf['VERSION_FILE'] } else { 'VERSION' }
  $releaseDirName = if ($conf['RELEASE_DIR']) { $conf['RELEASE_DIR'] } else { '.release' }
  $Global:SuppressGitWarnings = if ($conf['SUPPRESS_GIT_LINE_ENDING_WARNINGS']) { $conf['SUPPRESS_GIT_LINE_ENDING_WARNINGS'] } else { '1' }

  $versionPath = Join-Path $Global:GitRoot $versionFile
  if (!(Test-Path -LiteralPath $versionPath)) { [IO.File]::WriteAllText($versionPath, "1.0.0`n", (New-Object Text.UTF8Encoding($false))) }
  $oldVersion = ([IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8)).Trim()
  $latestTag = Get-LatestTag

  $statusBefore = (Invoke-Git status --porcelain).Stdout.Trim()
  $hasWorktreeChanges = ($statusBefore.Length -gt 0)
  if ($latestTag) {
    $countText = (Invoke-Git rev-list "$latestTag..HEAD" --count).Stdout.Trim()
    $commitCount = if ($countText) { [int]$countText } else { 0 }
  } else {
    $countText = (Invoke-Git rev-list HEAD --count).Stdout.Trim()
    $commitCount = if ($countText) { [int]$countText } else { 0 }
  }

  if ($commitCount -eq 0 -and !$hasWorktreeChanges) {
    Write-Ok "没有检测到上次发布后的新提交或未提交改动，跳过发布。"
    exit 0
  }

  $newVersion = Increment-Version $oldVersion
  $tag = "v$newVersion"
  Write-Host "版本号：$oldVersion -> $newVersion"

  $vfData = Read-TextPreserve $versionPath
  Write-TextPreserve $versionPath ($newVersion + "`n") $vfData.Encoding
  Update-VersionInFiles $oldVersion $newVersion

  Ensure-GitIgnoreLine '.release/'
  Ensure-GitIgnoreLine '*.release.zip'

  # If older release assets were accidentally tracked, remove them from the Git index only.
  $trackedZip = (Invoke-Git ls-files '*.zip').Stdout.Trim()
  if ($trackedZip) {
    foreach ($line in ($trackedZip -split "`r?`n")) {
      if ($line -match '^opencode-pocket-kit-v.*\.zip$' -or $line -match '^\.release/') {
        [void](Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $Global:GitRoot, 'rm', '--cached', '--ignore-unmatch', '--', $line) -AllowFailure -Quiet)
      }
    }
  }

  [void](Invoke-GitVisible add -A)
  $staged = (Invoke-Git diff --cached --name-only).Stdout.Trim()
  if ($staged) {
    [void](Invoke-GitVisible commit -m "release: $tag")
  } else {
    Write-Warn "没有需要提交的版本文件改动，继续尝试创建发布。"
  }

  $tagExists = (Invoke-External -FilePath $Global:GitExe -ArgumentList @('-C', $Global:GitRoot, 'rev-parse', '-q', '--verify', "refs/tags/$tag") -AllowFailure -Quiet).ExitCode -eq 0
  if (!$tagExists) { [void](Invoke-GitVisible tag $tag) }

  [void](Invoke-GitVisible push)
  [void](Invoke-GitVisible push origin $tag)

  $releaseDir = Join-Path $Global:GitRoot $releaseDirName
  New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
  $zipName = "$projectName-v$newVersion.zip"
  $zipPath = Join-Path $releaseDir $zipName
  New-ReleaseZipFromWorkingTree -ZipPath $zipPath -TopDir "$projectName-v$newVersion"
  Write-Ok "发行包已生成：$zipPath"

  $notesPath = Join-Path $releaseDir "release-notes-$newVersion.md"
  $notes = "# $projectName $tag`n`n" + (Get-CommitNotes $latestTag) + "`n"
  [IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding($false)))

  if (Test-GhReleaseExists $tag) {
    [void](Invoke-External -FilePath $Global:GhExe -ArgumentList @('release', 'upload', $tag, $zipPath, '--clobber'))
    [void](Invoke-External -FilePath $Global:GhExe -ArgumentList @('release', 'edit', $tag, '--notes-file', $notesPath) -AllowFailure -Quiet)
  } else {
    [void](Invoke-External -FilePath $Global:GhExe -ArgumentList @('release', 'create', $tag, $zipPath, '--title', $tag, '--notes-file', $notesPath))
  }

  $assetList = (Invoke-External -FilePath $Global:GhExe -ArgumentList @('release', 'view', $tag, '--json', 'assets', '--jq', '.assets[].name') -Quiet).Stdout
  if ($assetList -match [regex]::Escape($zipName)) {
    Write-Ok "GitHub Release 已包含发行包资产：$zipName"
  } else {
    throw "GitHub Release 中没有找到发行包资产：$zipName"
  }

  Write-Ok "发布完成：$tag"
  Write-Host "发行包：$zipPath"
} catch {
  Write-Fail $_.Exception.Message
  exit 1
}
