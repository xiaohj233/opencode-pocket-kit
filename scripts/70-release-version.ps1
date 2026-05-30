$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ToolRoot = Split-Path -Parent $ScriptDir
$ConfPath = Join-Path $ToolRoot "release.conf"
$ToolVersion = "release-tool-v13"

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

function Remove-GitLineEndingWarnings([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  if (!(ConfBool "SUPPRESS_GIT_LINE_ENDING_WARNINGS" $true)) { return $Text.Trim() }

  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($Text -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -eq "") { continue }
    if ($t -match "^warning: in the working copy of '.+', (CRLF|LF) will be replaced by (LF|CRLF) the next time Git touches it$") { continue }
    [void]$kept.Add($line)
  }
  return (($kept.ToArray()) -join "`r`n").Trim()
}

function Resolve-CommandPath([string]$Name) {
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

function ConvertTo-StringArray([object]$Items) {
  $list = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Items) { return [string[]]@() }
  foreach ($item in @($Items)) {
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

function Join-ProcessArguments([string[]]$ArgList) {
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($arg in $ArgList) {
    if ($null -eq $arg) { $arg = "" }
    $s = [string]$arg
    if ($s.Length -eq 0) { [void]$parts.Add('""'); continue }
    if ($s -notmatch '[\s"]') { [void]$parts.Add($s); continue }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
      $ch = $s[$i]
      if ($ch -eq '\\') {
        $bs++
        continue
      }
      if ($ch -eq '"') {
        if ($bs -gt 0) { [void]$sb.Append(('\\' * ($bs * 2 + 1))) } else { [void]$sb.Append('\\') }
        [void]$sb.Append('"')
        $bs = 0
        continue
      }
      if ($bs -gt 0) { [void]$sb.Append(('\\' * $bs)); $bs = 0 }
      [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append(('\\' * ($bs * 2))) }
    [void]$sb.Append('"')
    [void]$parts.Add($sb.ToString())
  }
  return ($parts -join ' ')
}

function Invoke-ProcessText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$File,

    [object[]]$CommandArgs = @(),

    [string]$WorkingDirectory = "",
    [switch]$AllowFail
  )

  if ([string]::IsNullOrWhiteSpace($File)) { throw "内部错误：外部命令路径为空。" }
  if (!(Test-Path -LiteralPath $File -PathType Leaf)) { throw "外部命令不存在：$File" }

  $argArray = ConvertTo-StringArray $CommandArgs
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = Join-ProcessArguments $argArray
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
  }
  catch {
    throw "无法启动外部命令：$File`r`n参数：$($psi.Arguments)`r`n$($_.Exception.Message)"
  }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  $code = $p.ExitCode
  $text = (($stdout, $stderr | Where-Object { $_ }) -join "`r`n").TrimEnd()

  if ($code -ne 0 -and !$AllowFail) {
    throw "命令执行失败：$File $($psi.Arguments)`r`n$text"
  }

  return [pscustomobject]@{ Code = $code; Out = $text; Stdout = $stdout; Stderr = $stderr }
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
    $r = Invoke-ProcessText -File $GitExe -CommandArgs @("-C", $c, "rev-parse", "--show-toplevel") -AllowFail
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

  $normalizedGitArgs = ConvertTo-StringArray $GitArgs
  if ($normalizedGitArgs.Count -lt 1 -or [string]::IsNullOrWhiteSpace($normalizedGitArgs[0])) {
    throw "内部错误：Git 参数为空。"
  }

  $all = New-Object System.Collections.Generic.List[string]
  [void]$all.Add("-C")
  [void]$all.Add($GitRoot)
  foreach ($a in $normalizedGitArgs) { [void]$all.Add([string]$a) }
  return Invoke-ProcessText -File $GitExe -CommandArgs ([string[]]$all.ToArray()) -AllowFail:$AllowFail
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
  $status = Invoke-ProcessText -File $gh -CommandArgs @("auth", "status") -WorkingDirectory $GitRoot -AllowFail
  if ($status.Code -ne 0) { throw "GitHub CLI 未登录。请先运行：gh auth login" }

  $view = Invoke-ProcessText -File $gh -CommandArgs @("release", "view", $Tag) -WorkingDirectory $GitRoot -AllowFail
  if ($view.Code -eq 0) {
    Write-Warn "GitHub Release 已存在，将覆盖上传发行包资产：$Tag"
    [void](Invoke-ProcessText -File $gh -CommandArgs @("release", "upload", $Tag, $ZipPath, "--clobber") -WorkingDirectory $GitRoot)
  }
  else {
    [void](Invoke-ProcessText -File $gh -CommandArgs @("release", "create", $Tag, $ZipPath, "--title", $Tag, "--notes-file", $NotesPath) -WorkingDirectory $GitRoot)
  }

  $assetName = Split-Path -Leaf $ZipPath
  $assets = Invoke-ProcessText -File $gh -CommandArgs @("release", "view", $Tag, "--json", "assets", "--jq", ".assets[].name") -WorkingDirectory $GitRoot -AllowFail
  if ($assets.Code -ne 0 -or (($assets.Out -split "`r?`n") -notcontains $assetName)) {
    throw "GitHub Release 创建后未检测到发行包资产：$assetName"
  }
  Write-Ok "GitHub Release 已包含发行包资产：$assetName"
}

function Publish-ExistingTagIfNeeded([string]$Tag) {
  if (!$Tag -or !(ConfBool "PUBLISH_EXISTING_TAG_WHEN_RELEASE_MISSING" $true)) { return $false }
  if (!(ConfBool "CREATE_GITHUB_RELEASE" $true)) { return $false }
  $gh = Resolve-CommandPath "gh"
  $view = Invoke-ProcessText -File $gh -CommandArgs @("release", "view", $Tag) -WorkingDirectory $GitRoot -AllowFail
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

function ConvertTo-RepoRelativePath([string]$Path) {
  $full = (Resolve-Path -LiteralPath $Path).Path
  $root = (Resolve-Path -LiteralPath $GitRoot).Path
  if (!$full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  $rel = $full.Substring($root.Length)
  $rel = $rel.TrimStart([char]'\', [char]'/')
  return ($rel -replace '\\', '/')
}

function Is-GitTracked([string]$RepoRelativePath) {
  if (!$RepoRelativePath) { return $false }
  $r = Invoke-Git @("ls-files", "--error-unmatch", "--", $RepoRelativePath) -AllowFail
  return $r.Code -eq 0
}

function Is-GitIgnored([string]$RepoRelativePath) {
  if (!$RepoRelativePath) { return $false }
  $r = Invoke-Git @("check-ignore", "-q", "--", $RepoRelativePath) -AllowFail
  return $r.Code -eq 0
}

function Add-ReleasePaths([string[]]$Paths) {
  $rels = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($Paths | Select-Object -Unique)) {
    if (!$p) { continue }
    $rel = ConvertTo-RepoRelativePath $p
    if (!$rel) { continue }
    $tracked = Is-GitTracked $rel
    $ignored = Is-GitIgnored $rel
    if ($ignored -and -not $tracked) {
      Write-Warn "跳过被 .gitignore 忽略的未跟踪文件：$rel"
      continue
    }
    [void]$rels.Add($rel)
  }
  if ($rels.Count -eq 0) { return }
  foreach ($rel in $rels) {
    $r = Invoke-Git @("add", "--", $rel) -AllowFail
    $filteredOut = Remove-GitLineEndingWarnings $r.Out
    if ($r.Code -ne 0) { throw "git add 失败：$rel`r`n$filteredOut" }
    if ($filteredOut) { Write-Warn $filteredOut }
  }
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
    $paths = [string[]]@($changedFiles | Select-Object -Unique)
    if ($paths.Count -gt 0) { Add-ReleasePaths $paths }
    $staged = Invoke-Git @("diff", "--cached", "--name-only")
    if ($staged.Out.Trim()) {
      $prefix = Conf "COMMIT_MESSAGE_PREFIX" "release"
      [void](Invoke-Git @("commit", "-m", "$prefix`: OpenCode Pocket Kit $newTag"))
    }
    else {
      Write-Warn "没有检测到已暂存的版本文件修改，跳过发布提交。"
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

  Write-Ok "发布完成：$newTag"
  Write-Ok "发行包：$zip"
  exit 0
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
