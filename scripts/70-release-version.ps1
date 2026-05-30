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
  $defaultText = if ($Default) { "1" } else { "0" }
  $v = Conf $Name $defaultText
  return @("1", "true", "yes", "on", "y") -contains $v.ToLowerInvariant()
}

function Resolve-CommandPath([string]$Name) {
  # 必须解析到外部可执行文件，不能返回裸命令名。
  # PowerShell 命令名大小写不敏感，如果脚本里有 Invoke-Git/Git 之类函数，
  # 裸命令名可能被解析到函数，从而造成递归调用和“调用深度溢出”。
  $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if (!$cmd) { throw "未找到外部命令：$Name。请确认它已经安装并加入 PATH。" }

  foreach ($prop in @("Path", "Source", "Definition")) {
    try {
      $value = [string]$cmd.$prop
      if (![string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $value).Path
      }
    }
    catch {}
  }

  throw "无法解析外部命令的真实路径：$Name。"
}

function Normalize-ArgList([object[]]$Items) {
  $list = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Items) { return [string[]]@() }
  foreach ($item in $Items) {
    if ($null -eq $item) { continue }
    if (($item -is [System.Array]) -and -not ($item -is [string])) {
      foreach ($sub in $item) {
        if ($null -ne $sub) { [void]$list.Add([string]$sub) }
      }
    }
    else {
      [void]$list.Add([string]$item)
    }
  }
  return [string[]]$list.ToArray()
}

function Invoke-Text {
  param(
    [Parameter(Mandatory = $true)]
    [string]$File,

    [object[]]$CommandArgs = @(),

    [string]$WorkingDirectory = "",
    [switch]$AllowFail
  )

  if ([string]::IsNullOrWhiteSpace($File)) { throw "内部错误：外部命令路径为空。" }
  if (!(Test-Path -LiteralPath $File -PathType Leaf)) { throw "外部命令不存在：$File" }

  $normalizedArgs = Normalize-ArgList $CommandArgs

  $old = (Get-Location).Path
  try {
    if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
    $out = & $File @normalizedArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { [string]$_ }) -join "`r`n"
    if ($code -ne 0 -and !$AllowFail) {
      throw "命令执行失败：$File $($normalizedArgs -join ' ')`r`n$text"
    }
    return [pscustomobject]@{ Code = $code; Out = $text }
  }
  finally {
    Set-Location -LiteralPath $old
  }
}

function Sanitize-PathText([string]$PathText) {
  if ($null -eq $PathText) { return "" }
  $s = [string]$PathText
  $s = $s.Trim()
  $s = $s.Trim([char]0xFEFF)
  $s = $s.Trim('"')
  return $s
}

function Resolve-GitRoot() {
  $candidates = New-Object System.Collections.Generic.List[string]
  try { [void]$candidates.Add((Get-Location).Path) } catch {}
  try { [void]$candidates.Add($ToolRoot) } catch {}
  try { [void]$candidates.Add((Split-Path -Parent $ToolRoot)) } catch {}

  foreach ($candidate in $candidates) {
    $c = Sanitize-PathText $candidate
    if (!$c -or !(Test-Path -LiteralPath $c)) { continue }
    $r = Invoke-Text -File $GitExe -CommandArgs @("-C", $c, "rev-parse", "--show-toplevel") -AllowFail
    if ($r.Code -eq 0 -and $r.Out.Trim()) {
      return (Resolve-Path -LiteralPath (Sanitize-PathText $r.Out)).Path
    }
  }

  $dir = $ToolRoot
  while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return (Resolve-Path -LiteralPath $dir).Path }
    $parent = Split-Path -Parent $dir
    if ($parent -eq $dir) { break }
    $dir = $parent
  }
  throw "当前目录不是 Git 仓库，也无法从脚本位置向上找到 .git。"
}

function Invoke-Git {
  param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [object[]]$GitArgs,

    [switch]$AllowFail
  )

  $normalizedGitArgs = Normalize-ArgList $GitArgs
  if ($normalizedGitArgs.Count -lt 1 -or [string]::IsNullOrWhiteSpace($normalizedGitArgs[0])) {
    throw "内部错误：Git 参数为空。"
  }

  $allArgs = New-Object System.Collections.Generic.List[string]
  [void]$allArgs.Add("-C")
  [void]$allArgs.Add($GitRoot)
  foreach ($a in $normalizedGitArgs) { [void]$allArgs.Add([string]$a) }

  return Invoke-Text -File $GitExe -CommandArgs ([string[]]$allArgs.ToArray()) -AllowFail:$AllowFail
}

function Get-GitRelativePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

  $p = Sanitize-PathText $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }

  # git add 对绝对路径、中文路径、忽略规则叠加时更容易出现难懂报错。
  # 这里统一转换成相对仓库根目录的路径，并使用正斜杠，交给 git 处理。
  if (![IO.Path]::IsPathRooted($p)) {
    $candidate = Join-Path $GitRoot $p
  }
  else {
    $candidate = $p
  }

  $full = [IO.Path]::GetFullPath($candidate)
  $rootFull = [IO.Path]::GetFullPath($GitRoot)
  if (!$rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) { $rootFull += [IO.Path]::DirectorySeparatorChar }

  if (!$full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warn "跳过仓库外路径：$Path"
    return $null
  }

  $rel = $full.Substring($rootFull.Length)
  return ($rel -replace '\\', '/')
}

function Test-GitPathIgnored([string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }

  # 已被 Git 跟踪的文件即使匹配 .gitignore，也应该允许 git add 更新。
  $tracked = Invoke-Git @("ls-files", "--error-unmatch", "--", $RelativePath) -AllowFail
  if ($tracked.Code -eq 0) { return $false }

  $ignored = Invoke-Git @("check-ignore", "-q", "--", $RelativePath) -AllowFail
  return ($ignored.Code -eq 0)
}

function Add-ReleaseChangedFiles([string[]]$Paths) {
  $added = 0
  $unique = @($Paths | Where-Object { $_ } | Select-Object -Unique)

  foreach ($p in $unique) {
    $rel = Get-GitRelativePath $p
    if (!$rel) { continue }

    # 删除操作已经由 git rm 处理过，这里不再 git add 一个不存在的路径。
    $full = Join-Path $GitRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (!(Test-Path -LiteralPath $full)) {
      continue
    }

    if (Test-GitPathIgnored $rel) {
      Write-Warn "跳过被 .gitignore 忽略的未跟踪路径：$rel"
      continue
    }

    [void](Invoke-Git @("add", "--", $rel))
    $added++
  }

  return $added
}

function Test-StagedChangesExist() {
  $r = Invoke-Git @("diff", "--cached", "--quiet") -AllowFail
  return ($r.Code -ne 0)
}

function Get-TextFileState([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = $false
  $encodingName = "utf8-nobom"
  $encoding = [System.Text.UTF8Encoding]::new($false, $true)
  $offset = 0

  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $hasBom = $true
    $encodingName = "utf8-bom"
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $offset = 3
  }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $hasBom = $true
    $encodingName = "utf16le-bom"
    $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
    $offset = 2
  }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $hasBom = $true
    $encodingName = "utf16be-bom"
    $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
    $offset = 2
  }

  $text = if ($bytes.Length -gt $offset) { $encoding.GetString($bytes, $offset, $bytes.Length - $offset) } else { "" }
  return [pscustomobject]@{
    Path         = $Path
    Bytes        = $bytes
    Text         = $text
    Encoding     = $encoding
    EncodingName = $encodingName
    HasBom       = $hasBom
  }
}

function Write-TextPreserveEncoding($State, [string]$Text) {
  $body = $State.Encoding.GetBytes($Text)
  if ($State.HasBom) {
    if ($State.EncodingName -eq "utf8-bom") { $prefix = [byte[]](0xEF, 0xBB, 0xBF) }
    elseif ($State.EncodingName -eq "utf16le-bom") { $prefix = [byte[]](0xFF, 0xFE) }
    elseif ($State.EncodingName -eq "utf16be-bom") { $prefix = [byte[]](0xFE, 0xFF) }
    else { $prefix = [byte[]]@() }
    [System.IO.File]::WriteAllBytes($State.Path, [byte[]]($prefix + $body))
  }
  else {
    [System.IO.File]::WriteAllBytes($State.Path, [byte[]]$body)
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false, $true)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Is-VersionEditableFile([string]$Path) {
  $name = [IO.Path]::GetFileName($Path)
  $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($name.ToUpperInvariant() -eq "VERSION") { return $true }
  if ($ext -in @(".md", ".txt", ".json", ".jsonc", ".ps1", ".conf", ".yml", ".yaml")) { return $true }
  return $false
}

function Replace-VersionInTextFile([string]$Path, [string]$Old, [string]$New) {
  if (!(Test-Path -LiteralPath $Path)) { return $false }
  if (!(Is-VersionEditableFile $Path)) { return $false }

  $state = Get-TextFileState $Path
  $raw = $state.Text
  $newRaw = $raw.Replace("v$Old", "v$New").Replace($Old, $New)
  if ($newRaw -ne $raw) {
    Write-TextPreserveEncoding $state $newRaw
    Write-Info "已更新版本号并保留编码：$Path [$($state.EncodingName)]"
    return $true
  }
  return $false
}

function Get-VersionFromFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return "1.0.0" }
  $state = Get-TextFileState $Path
  $txt = $state.Text.Trim()
  if ($txt -match '(\d+)\.(\d+)\.(\d+)') { return $matches[0] }
  return "1.0.0"
}

function Set-VersionFile([string]$Path, [string]$New) {
  if (Test-Path -LiteralPath $Path) {
    $state = Get-TextFileState $Path
    $nl = if ($state.Text.Contains("`r`n")) { "`r`n" } elseif ($state.Text.Contains("`n")) { "`n" } else { "`r`n" }
    Write-TextPreserveEncoding $state ($New + $nl)
  }
  else {
    Write-Utf8NoBom $Path ($New + "`r`n")
  }
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

function Get-VersionTargetFiles() {
  $skipDirs = @(".git", "node_modules", "npm-global", "repo-cache", "logs", ".release", "release-output", "backups", "vault")
  $files = Get-ChildItem -LiteralPath $GitRoot -Recurse -File -Force | Where-Object {
    $full = $_.FullName
    foreach ($sd in $skipDirs) {
      $part = [IO.Path]::DirectorySeparatorChar + $sd + [IO.Path]::DirectorySeparatorChar
      if ($full.IndexOf($part, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    return (Is-VersionEditableFile $full)
  }
  return @($files)
}

function Set-VersionEverywhere([string]$Old, [string]$New) {
  $changed = New-Object System.Collections.Generic.List[string]
  $versionFile = Join-Path $GitRoot (Conf "VERSION_FILE" "VERSION")
  Set-VersionFile $versionFile $New
  [void]$changed.Add($versionFile)

  foreach ($f in (Get-VersionTargetFiles)) {
    if ($f.FullName -eq $versionFile) { continue }
    if (Replace-VersionInTextFile $f.FullName $Old $New) { [void]$changed.Add($f.FullName) }
  }
  return @($changed | Select-Object -Unique)
}

function Ensure-GitIgnoreReleaseRules() {
  $gi = Join-Path $GitRoot ".gitignore"
  $rules = @("/.release/", "/release-output/", "/opencode-pocket-kit-v*.zip", "/*.release.zip")
  $changed = $false

  if (Test-Path -LiteralPath $gi) {
    $state = Get-TextFileState $gi
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($state.Text -split "`r?`n")) {
      if ($line -ne "") { [void]$lines.Add($line) }
    }
    foreach ($r in $rules) {
      if ($lines -notcontains $r) { [void]$lines.Add($r); $changed = $true }
    }
    if ($changed) {
      Write-TextPreserveEncoding $state (($lines -join "`r`n") + "`r`n")
      return @($gi)
    }
    return @()
  }
  else {
    Write-Utf8NoBom $gi (($rules -join "`r`n") + "`r`n")
    return @($gi)
  }
}

function Remove-TrackedReleaseZips() {
  $removed = New-Object System.Collections.Generic.List[string]
  if (!(ConfBool "REMOVE_TRACKED_RELEASE_ZIPS" $true)) { return @() }
  $ls = Invoke-Git @("ls-files")
  $files = @($ls.Out -split "`r?`n" | Where-Object {
      $_ -match '^opencode-pocket-kit-v\d+\.\d+\.\d+\.zip$' -or
      $_ -match '^\.release/' -or
      $_ -match '^release-output/'
    })
  if ($files.Count -gt 0) {
    Write-Warn "检测到发行 zip 或发行输出目录被 Git 跟踪，将从仓库中移除这些构建产物。"
    foreach ($f in $files) {
      [void](Invoke-Git @("rm", "-f", "--", $f) -AllowFail)
      [void]$removed.Add($f)
    }
  }
  return @($removed)
}

function Has-WorkingTreeChanges() {
  $s = Invoke-Git @("status", "--porcelain")
  return -not [string]::IsNullOrWhiteSpace($s.Out)
}

function Require-CleanWorkingTree() {
  $s = Invoke-Git @("status", "--porcelain")
  if (![string]::IsNullOrWhiteSpace($s.Out)) {
    throw "工作区存在未提交更改。请先提交或暂存当前修改，再运行发布脚本。这样可以避免发布脚本把非发布文件一起提交。`r`n$s"
  }
}

function Get-LatestVersionTag() {
  $r = Invoke-Git @("tag", "--list", "v*.*.*", "--sort=-v:refname") -AllowFail
  if ($r.Code -ne 0) { return $null }
  return @($r.Out -split "`r?`n" | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Select-Object -First 1)[0]
}

function Get-PreviousVersionTag([string]$Tag) {
  $r = Invoke-Git @("tag", "--list", "v*.*.*", "--sort=-v:refname") -AllowFail
  if ($r.Code -ne 0) { return $null }
  $tags = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })
  for ($i = 0; $i -lt $tags.Count; $i++) {
    if ($tags[$i] -eq $Tag -and $i + 1 -lt $tags.Count) { return $tags[$i + 1] }
  }
  return $null
}

function Has-NewCommitSinceTag([string]$Tag) {
  if (!$Tag) { return $true }
  $r = Invoke-Git @("rev-list", "$Tag..HEAD", "--count") -AllowFail
  if ($r.Code -ne 0) { return $true }
  $countText = ($r.Out).Trim()
  if (!$countText) { return $false }
  return ([int]$countText) -gt 0
}

function Build-ReleaseNotes([string]$OldTag, [string]$NewTag, [string]$UpperRef) {
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
    $range = if ($OldTag) { "$OldTag..$UpperRef" } else { $UpperRef }
    $log = Invoke-Git @("log", $range, "--pretty=format:- %s (%h)") -AllowFail
    if ($log.Code -eq 0 -and $log.Out.Trim()) {
      foreach ($l in ($log.Out -split "`r?`n")) { [void]$lines.Add($l) }
    }
    else {
      [void]$lines.Add("- 首次发布")
    }
  }

  if ($lines.Count -eq 0) { [void]$lines.Add("OpenCode Pocket Kit $NewTag") }
  $notes = Join-Path $ReleaseDir "release-notes-$NewTag.md"
  Write-Utf8NoBom $notes (($lines -join "`r`n") + "`r`n")
  return $notes
}

function Create-ReleaseZip([string]$Version, [string]$Ref) {
  $packageName = Conf "PACKAGE_NAME" "opencode-pocket-kit"
  $zip = Join-Path $ReleaseDir "$packageName-v$Version.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  [void](Invoke-Git @("archive", "--format=zip", "--output", $zip, "--prefix", "$packageName/", $Ref))
  if (!(Test-Path -LiteralPath $zip)) { throw "发行包生成失败：$zip" }
  return $zip
}

function Ensure-GhRelease([string]$Tag, [string]$ZipPath, [string]$NotesPath) {
  if (!(ConfBool "CREATE_GITHUB_RELEASE" $true)) { return }
  $gh = Resolve-CommandPath "gh"
  $status = Invoke-Text -File $gh -CommandArgs @("auth", "status") -WorkingDirectory $GitRoot -AllowFail
  if ($status.Code -ne 0) { throw "GitHub CLI 未登录。请先运行：gh auth login" }

  $view = Invoke-Text -File $gh -CommandArgs @("release", "view", $Tag) -WorkingDirectory $GitRoot -AllowFail
  if ($view.Code -eq 0) {
    Write-Warn "GitHub Release 已存在，将覆盖上传发行包资产：$Tag"
    [void](Invoke-Text -File $gh -CommandArgs @("release", "upload", $Tag, $ZipPath, "--clobber") -WorkingDirectory $GitRoot)
  }
  else {
    [void](Invoke-Text -File $gh -CommandArgs @("release", "create", $Tag, $ZipPath, "--title", $Tag, "--notes-file", $NotesPath) -WorkingDirectory $GitRoot)
  }

  $assetName = Split-Path -Leaf $ZipPath
  $assets = Invoke-Text -File $gh -CommandArgs @("release", "view", $Tag, "--json", "assets", "--jq", ".assets[].name") -WorkingDirectory $GitRoot -AllowFail
  if ($assets.Code -ne 0 -or (($assets.Out -split "`r?`n") -notcontains $assetName)) {
    throw "GitHub Release 创建后未检测到发行包资产：$assetName"
  }
  Write-Ok "GitHub Release 已包含发行包资产：$assetName"
}

function Publish-ExistingTagIfNeeded([string]$Tag) {
  if (!$Tag -or !(ConfBool "PUBLISH_EXISTING_TAG_WHEN_RELEASE_MISSING" $true)) { return $false }
  if (!(ConfBool "CREATE_GITHUB_RELEASE" $true)) { return $false }
  $gh = Resolve-CommandPath "gh"
  $view = Invoke-Text -File $gh -CommandArgs @("release", "view", $Tag) -WorkingDirectory $GitRoot -AllowFail
  if ($view.Code -eq 0) { return $false }

  Write-Warn "没有新提交，但检测到最新标签 $Tag 还没有 GitHub Release，将补发该标签的发行包。"
  $version = $Tag.TrimStart([char]'v')
  $prev = Get-PreviousVersionTag $Tag
  $notes = Build-ReleaseNotes $prev $Tag $Tag
  $zip = Create-ReleaseZip $version $Tag
  Ensure-GhRelease $Tag $zip $notes
  Write-Ok "已补发 GitHub Release：$Tag"
  return $true
}

try {
  Write-Info "OpenCode Pocket Kit 一键发布版本工具"
  $GitExe = Resolve-CommandPath "git"
  $GitRoot = Resolve-GitRoot
  Write-Info "仓库目录：$GitRoot"

  $releaseDirConf = Conf "RELEASE_DIR" ".release"
  if ([IO.Path]::IsPathRooted($releaseDirConf)) { $ReleaseDir = $releaseDirConf } else { $ReleaseDir = Join-Path $GitRoot $releaseDirConf }
  New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

  $latestTag = Get-LatestVersionTag
  $newCommits = Has-NewCommitSinceTag $latestTag
  if (!$newCommits) {
    if (Publish-ExistingTagIfNeeded $latestTag) { exit 0 }
    Write-Warn "上一个版本标签之后没有新的 Git 提交，无需发布。"
    exit 0
  }

  Require-CleanWorkingTree

  $versionFile = Join-Path $GitRoot (Conf "VERSION_FILE" "VERSION")
  $oldVersion = Get-VersionFromFile $versionFile
  $newVersion = Next-Version $oldVersion
  $newTag = "v$newVersion"
  Write-Info "版本号：$oldVersion -> $newVersion"

  $notes = Build-ReleaseNotes $latestTag $newTag "HEAD"

  $changedFiles = New-Object System.Collections.Generic.List[string]
  foreach ($f in (Set-VersionEverywhere $oldVersion $newVersion)) { [void]$changedFiles.Add($f) }
  foreach ($f in (Ensure-GitIgnoreReleaseRules)) { [void]$changedFiles.Add($f) }
  foreach ($f in (Remove-TrackedReleaseZips)) { [void]$changedFiles.Add($f) }

  $tagExists = Invoke-Git @("rev-parse", "-q", "--verify", "refs/tags/$newTag") -AllowFail
  if ($tagExists.Code -eq 0) { throw "标签已存在：$newTag。请检查 VERSION 或先删除/处理该标签。" }

  if (ConfBool "AUTO_COMMIT_RELEASE_VERSION" $true) {
    $paths = @($changedFiles | Select-Object -Unique)
    if ($paths.Count -gt 0) {
      [void](Add-ReleaseChangedFiles ([string[]]$paths))
      $prefix = Conf "COMMIT_MESSAGE_PREFIX" "release"
      if (Test-StagedChangesExist) {
        [void](Invoke-Git @("commit", "-m", "$prefix`: OpenCode Pocket Kit $newTag"))
      }
      else {
        Write-Warn "没有需要提交的版本文件变更，跳过 release commit。"
      }
    }
  }
  else {
    throw "版本号文件已修改，但配置禁止自动提交。请启用 AUTO_COMMIT_RELEASE_VERSION 或手动处理。"
  }

  [void](Invoke-Git @("tag", "-a", $newTag, "-m", "OpenCode Pocket Kit $newTag"))
  $zip = Create-ReleaseZip $newVersion $newTag

  if (ConfBool "AUTO_PUSH" $true) {
    $branch = (Invoke-Git @("branch", "--show-current")).Out.Trim()
    if ($branch) { [void](Invoke-Git @("push", "origin", $branch)) }
    [void](Invoke-Git @("push", "origin", $newTag))
  }

  Ensure-GhRelease $newTag $zip $notes

  Write-Ok "发布完成: $newTag"
  Write-Ok "发行包: $zip"
  exit 0
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
