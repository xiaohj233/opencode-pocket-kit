$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ToolRoot = Split-Path -Parent $ScriptDir
$ConfPath = Join-Path $ToolRoot "release.conf"
$ToolVersion = "1.0.0"

function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-ConfFile([string]$Path) {
  $map = @{}
  if (!(Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#")) { continue }
    $i = $t.IndexOf("=")
    if ($i -lt 0) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    if ($k) { $map[$k] = $v }
  }
  return $map
}

$Conf = Read-ConfFile $ConfPath
function Conf([string]$Name, [string]$Default = "") {
  if ($Conf.ContainsKey($Name) -and $null -ne $Conf[$Name]) { return [string]$Conf[$Name] }
  return $Default
}
function ConfBool([string]$Name, [bool]$Default = $false) {
  $v = Conf $Name ($(if ($Default) { "1" } else { "0" }))
  return @("1", "true", "yes", "on", "y") -contains $v.ToLowerInvariant()
}

function Quote-CmdArg([string]$Arg) {
  if ($null -eq $Arg) { return '""' }
  if ($Arg -eq "") { return '""' }
  if ($Arg -notmatch '[\s"&()<>|^]') { return $Arg }
  $escaped = $Arg.Replace('"', '\"')
  return '"' + $escaped + '"'
}

function Resolve-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (!$cmd) { throw "未找到命令：$Name。请先安装或加入 PATH。" }

  $candidates = @()
  foreach ($prop in @("Path", "Source", "Definition")) {
    try {
      $v = [string]$cmd.$prop
      if ($v -and $v.Trim()) { $candidates += $v.Trim() }
    } catch { }
  }

  foreach ($c in $candidates) {
    $clean = $c.Trim('"')
    if ($clean -and (Test-Path -LiteralPath $clean)) { return (Resolve-Path -LiteralPath $clean).Path }
  }

  if ($Name -and $Name.Trim()) { return $Name }
  throw "命令解析失败：$Name"
}

function Invoke-Text([string]$Exe, [string[]]$NativeArgs, [string]$WorkingDirectory = $null, [switch]$AllowFail) {
  if ([string]::IsNullOrWhiteSpace($Exe)) { throw "内部错误：Invoke-Text 收到空命令名。" }

  $cmdExe = $env:ComSpec
  if ([string]::IsNullOrWhiteSpace($cmdExe) -or !(Test-Path -LiteralPath $cmdExe)) {
    $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
  }
  if (!(Test-Path -LiteralPath $cmdExe)) { throw "找不到 cmd.exe，无法执行外部命令。" }

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add((Quote-CmdArg $Exe))
  foreach ($a in $NativeArgs) { [void]$parts.Add((Quote-CmdArg ([string]$a))) }
  $cmdLine = ($parts -join " ")

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cmdExe
  $psi.Arguments = "/d /s /c " + '"' + $cmdLine + '"'
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

  $p = [System.Diagnostics.Process]::Start($psi)
  if (!$p) { throw "无法启动进程：$Exe" }
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0 -and !$AllowFail) {
    throw "命令失败：$cmdLine`n$out`n$err"
  }
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err; CommandLine = $cmdLine }
}

function Resolve-GitRoot() {
  $git = Resolve-CommandPath "git"
  $tryDirs = @($ToolRoot, (Get-Location).Path)
  foreach ($d in $tryDirs) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    $r = Invoke-Text $git @("-C", $d, "rev-parse", "--show-toplevel") -AllowFail
    if ($r.Code -eq 0) {
      $root = ($r.Out -split "`r?`n" | Select-Object -First 1).Trim()
      if ($root -and (Test-Path -LiteralPath $root)) { return (Resolve-Path -LiteralPath $root).Path }
    }
  }

  $cur = $ToolRoot
  while ($cur) {
    if (Test-Path -LiteralPath (Join-Path $cur ".git")) { return (Resolve-Path -LiteralPath $cur).Path }
    $parent = Split-Path -Parent $cur
    if (!$parent -or $parent -eq $cur) { break }
    $cur = $parent
  }
  throw "当前目录不是 Git 仓库，也无法从脚本位置向上找到 .git。"
}

function Git([string[]]$GitArgs, [switch]$AllowFail) {
  return Invoke-Text $GitExe (@("-C", $GitRoot) + $GitArgs) -AllowFail:$AllowFail
}

function Get-VersionFromFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return "1.0.0" }
  $txt = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
  if ($txt -match '(\d+)\.(\d+)\.(\d+)') { return $matches[0] }
  return "1.0.0"
}

function Next-Version([string]$Version) {
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "版本号格式不正确：$Version" }
  $major = [int]$matches[1]
  $minor = [int]$matches[2]
  $patch = [int]$matches[3]
  $patch++
  if ($patch -ge 10) { $patch = 0; $minor++ }
  if ($minor -ge 10) { $minor = 0; $major++ }
  return "$major.$minor.$patch"
}

function Replace-VersionInTextFile([string]$Path, [string]$Old, [string]$New) {
  if (!(Test-Path -LiteralPath $Path)) { return }
  $name = [IO.Path]::GetFileName($Path)
  $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  $allowed = @(".md", ".txt", ".json", ".jsonc", ".ps1", ".cmd", ".conf", ".yml", ".yaml")
  if ($allowed -notcontains $ext -and $name.ToUpperInvariant() -ne "VERSION") { return }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $newRaw = $raw.Replace("v$Old", "v$New").Replace($Old, $New)
  if ($newRaw -ne $raw) { Write-Utf8NoBom $Path $newRaw }
}

function Set-VersionEverywhere([string]$Old, [string]$New) {
  $versionFile = Join-Path $GitRoot (Conf "VERSION_FILE" "VERSION")
  Write-Utf8NoBom $versionFile ($New + "`r`n")

  $skipDirs = @(".git", "node_modules", "npm-global", "repo-cache", "logs", ".release", "release-output", "backups", "vault")
  $files = Get-ChildItem -LiteralPath $GitRoot -Recurse -File -Force | Where-Object {
    $full = $_.FullName
    foreach ($sd in $skipDirs) {
      $part = [IO.Path]::DirectorySeparatorChar + $sd + [IO.Path]::DirectorySeparatorChar
      if ($full.IndexOf($part, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    return $true
  }
  foreach ($f in $files) { Replace-VersionInTextFile $f.FullName $Old $New }
}

function Ensure-GitIgnoreReleaseRules() {
  $gi = Join-Path $GitRoot ".gitignore"
  $rules = @("/.release/", "/release-output/", "/opencode-pocket-kit-v*.zip", "/*.release.zip")
  $existing = @()
  if (Test-Path -LiteralPath $gi) { $existing = @(Get-Content -LiteralPath $gi -Encoding UTF8) }
  $changed = $false
  foreach ($r in $rules) {
    if ($existing -notcontains $r) { $existing += $r; $changed = $true }
  }
  if ($changed) { Write-Utf8NoBom $gi (($existing -join "`r`n") + "`r`n") }
}

function Remove-TrackedReleaseZips() {
  if (!(ConfBool "REMOVE_TRACKED_RELEASE_ZIPS" $true)) { return }
  $ls = Git @("ls-files")
  $files = @($ls.Out -split "`r?`n" | Where-Object {
    $_ -match '^opencode-pocket-kit-v\d+\.\d+\.\d+\.zip$' -or
    $_ -match '^\.release/' -or
    $_ -match '^release-output/'
  })
  if ($files.Count -gt 0) {
    Write-Warn "检测到发行 zip 或发行输出目录被 Git 跟踪，将从仓库中移除这些构建产物。"
    foreach ($f in $files) { [void](Git @("rm", "-f", "--", $f) -AllowFail) }
  }
}

function Has-WorkingTreeChanges() {
  $s = Git @("status", "--porcelain")
  return -not [string]::IsNullOrWhiteSpace($s.Out)
}

function Get-LatestVersionTag() {
  $r = Git @("tag", "--list", "v*.*.*", "--sort=-v:refname") -AllowFail
  if ($r.Code -ne 0) { return $null }
  return @($r.Out -split "`r?`n" | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Select-Object -First 1)[0]
}

function Has-NewCommitSinceTag([string]$Tag) {
  if (!$Tag) { return $true }
  $r = Git @("rev-list", "$Tag..HEAD", "--count") -AllowFail
  if ($r.Code -ne 0) { return $true }
  $countText = ($r.Out).Trim()
  if (!$countText) { return $false }
  return ([int]$countText) -gt 0
}

function Build-ReleaseNotes([string]$OldTag, [string]$NewTag) {
  $mode = (Conf "RELEASE_NOTES_MODE" "git").ToLowerInvariant()
  $lines = New-Object System.Collections.Generic.List[string]

  if ($mode -eq "manual" -or $mode -eq "both") {
    Write-Host "请输入本次发布说明。输入空行结束："
    while ($true) {
      $line = Read-Host ">"
      if ([string]::IsNullOrWhiteSpace($line)) { break }
      [void]$lines.Add($line)
    }
    if ($lines.Count -gt 0) { [void]$lines.Add("") }
  }

  if ($mode -eq "git" -or $mode -eq "both") {
    [void]$lines.Add("## Git 提交记录")
    $range = if ($OldTag) { "$OldTag..HEAD" } else { "HEAD" }
    $log = Git @("log", $range, "--pretty=format:- %s (%h)") -AllowFail
    if ($log.Code -eq 0 -and $log.Out.Trim()) {
      foreach ($l in ($log.Out -split "`r?`n")) { [void]$lines.Add($l) }
    } else {
      [void]$lines.Add("- 首次发布")
    }
  }

  if ($lines.Count -eq 0) { [void]$lines.Add("OpenCode Pocket Kit $NewTag") }
  $notes = Join-Path $ReleaseDir "release-notes-$NewTag.md"
  Write-Utf8NoBom $notes (($lines -join "`r`n") + "`r`n")
  return $notes
}

function Create-ReleaseZip([string]$Version) {
  $packageName = Conf "PACKAGE_NAME" "opencode-pocket-kit"
  $zip = Join-Path $ReleaseDir "$packageName-v$Version.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  [void](Git @("archive", "--format=zip", "--output", $zip, "HEAD"))
  if (!(Test-Path -LiteralPath $zip)) { throw "发行包生成失败：$zip" }
  return $zip
}

function Ensure-GhRelease([string]$Tag, [string]$ZipPath, [string]$NotesPath) {
  if (!(ConfBool "CREATE_GITHUB_RELEASE" $true)) { return }
  $gh = Resolve-CommandPath "gh"
  $status = Invoke-Text $gh @("auth", "status") -WorkingDirectory $GitRoot -AllowFail
  if ($status.Code -ne 0) { throw "GitHub CLI 未登录。请先运行：gh auth login" }

  $view = Invoke-Text $gh @("release", "view", $Tag) -WorkingDirectory $GitRoot -AllowFail
  if ($view.Code -eq 0) {
    Write-Warn "GitHub Release 已存在，将覆盖上传发行包资产：$Tag"
    [void](Invoke-Text $gh @("release", "upload", $Tag, $ZipPath, "--clobber") -WorkingDirectory $GitRoot)
  } else {
    [void](Invoke-Text $gh @("release", "create", $Tag, $ZipPath, "--title", $Tag, "--notes-file", $NotesPath) -WorkingDirectory $GitRoot)
  }

  $assetName = Split-Path -Leaf $ZipPath
  $assets = Invoke-Text $gh @("release", "view", $Tag, "--json", "assets", "--jq", ".assets[].name") -WorkingDirectory $GitRoot -AllowFail
  if ($assets.Code -ne 0 -or (($assets.Out -split "`r?`n") -notcontains $assetName)) {
    throw "GitHub Release 创建后未检测到发行包资产：$assetName"
  }
  Write-Ok "GitHub Release 已包含发行包资产：$assetName"
}

try {
  Write-Info "OpenCode Pocket Kit 一键发布版本工具"
  $GitExe = Resolve-CommandPath "git"
  $GitRoot = Resolve-GitRoot
  Write-Info "仓库目录：$GitRoot"

  $releaseDirConf = Conf "RELEASE_DIR" ".release"
  if ([IO.Path]::IsPathRooted($releaseDirConf)) { $ReleaseDir = $releaseDirConf } else { $ReleaseDir = Join-Path $GitRoot $releaseDirConf }
  New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

  Ensure-GitIgnoreReleaseRules
  Remove-TrackedReleaseZips

  $latestTag = Get-LatestVersionTag
  $dirtyBefore = Has-WorkingTreeChanges
  $newCommits = Has-NewCommitSinceTag $latestTag
  if (!$dirtyBefore -and !$newCommits) {
    Write-Warn "上一个版本标签之后没有新的 Git 提交，也没有未提交更改。无需发布。"
    exit 0
  }

  $versionFile = Join-Path $GitRoot (Conf "VERSION_FILE" "VERSION")
  $oldVersion = Get-VersionFromFile $versionFile
  $newVersion = Next-Version $oldVersion
  $newTag = "v$newVersion"
  Write-Info "版本号：$oldVersion -> $newVersion"

  Set-VersionEverywhere $oldVersion $newVersion
  Ensure-GitIgnoreReleaseRules
  Remove-TrackedReleaseZips

  if (Has-WorkingTreeChanges) {
    if (ConfBool "AUTO_COMMIT_CHANGES" $true) {
      [void](Git @("add", "-A"))
      [void](Git @("reset", "--", ".release", "release-output", "opencode-pocket-kit-v$newVersion.zip") -AllowFail)
      $prefix = Conf "COMMIT_MESSAGE_PREFIX" "release"
      [void](Git @("commit", "-m", "$prefix`: OpenCode Pocket Kit $newTag"))
    } else {
      throw "存在未提交更改。请先提交，或在 release.conf 中设置 AUTO_COMMIT_CHANGES=1。"
    }
  }

  $tagExists = Git @("rev-parse", "-q", "--verify", "refs/tags/$newTag") -AllowFail
  if ($tagExists.Code -eq 0) { throw "标签已存在：$newTag。请检查 VERSION 或先删除/处理该标签。" }
  [void](Git @("tag", "-a", $newTag, "-m", "OpenCode Pocket Kit $newTag"))

  $zip = Create-ReleaseZip $newVersion
  $notes = Build-ReleaseNotes $latestTag $newTag

  if (ConfBool "AUTO_PUSH" $true) {
    $branch = (Git @("branch", "--show-current")).Out.Trim()
    if ($branch) { [void](Git @("push", "origin", $branch)) }
    [void](Git @("push", "origin", $newTag))
  }

  Ensure-GhRelease $newTag $zip $notes

  Write-Ok "发布完成：$newTag"
  Write-Ok "发行包：$zip"
  exit 0
} catch {
  Write-Err $_.Exception.Message
  exit 1
}
