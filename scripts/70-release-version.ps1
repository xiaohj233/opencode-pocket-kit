param(
  [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectName = "OpenCode Pocket Kit"
$ScriptVersion = "1.0.1"

function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Read-ConfigFile([string]$Path) {
  $map = @{}
  if (!(Test-Path -LiteralPath $Path)) { return $map }

  Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    $idx = $line.IndexOf("=")
    if ($idx -lt 0) { return }
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()
    if ($key) { $map[$key] = $val }
  }
  return $map
}

function Conf([hashtable]$Map, [string]$Name, [string]$Default = "") {
  if ($Map.ContainsKey($Name) -and $null -ne $Map[$Name] -and "$($Map[$Name])" -ne "") {
    return "$($Map[$Name])"
  }
  return $Default
}

function Resolve-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (!$cmd) { return $null }
  return $cmd.Source
}

function ConvertTo-CmdArgument([string]$Value) {
  if ($null -eq $Value) { return '""' }
  $s = [string]$Value
  $s = $s -replace '"', '\"'
  return '"' + $s + '"'
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$Arguments
  )

  $cmdLine = (ConvertTo-CmdArgument $FilePath)
  foreach ($arg in $Arguments) {
    $cmdLine += " " + (ConvertTo-CmdArgument $arg)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  if ([string]::IsNullOrWhiteSpace($psi.FileName)) { $psi.FileName = "cmd.exe" }
  $psi.Arguments = "/d /s /c " + '"' + $cmdLine + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  return [pscustomobject]@{
    Code = $p.ExitCode
    Out = $stdout
    Err = $stderr
  }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory=$true)][string[]]$GitArgs,
    [switch]$AllowFail
  )

  $r = Invoke-Capture -FilePath $script:Git -Arguments $GitArgs
  if ($r.Code -ne 0 -and !$AllowFail) {
    throw "git $($GitArgs -join ' ') failed:`n$($r.Err)`n$($r.Out)"
  }
  return $r
}

function Clean-PathText([string]$PathText) {
  if ($null -eq $PathText) { return "" }
  $s = [string]$PathText
  $s = $s.Trim()
  $s = $s.Trim([char]0xFEFF)
  $s = $s.Trim('"')
  $s = $s.Trim("'")
  $s = $s -replace "[\x00-\x1F]", ""
  return $s
}

function Try-GetFullPath([string]$PathText) {
  $clean = Clean-PathText $PathText
  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
  try {
    return [IO.Path]::GetFullPath($clean)
  } catch {
    return $null
  }
}

function Resolve-GitRoot([string]$StartPath) {
  $scriptParent = Split-Path -Parent $PSScriptRoot
  $candidateInputs = New-Object System.Collections.Generic.List[string]

  if (![string]::IsNullOrWhiteSpace($StartPath)) { [void]$candidateInputs.Add($StartPath) }
  if (![string]::IsNullOrWhiteSpace($scriptParent)) { [void]$candidateInputs.Add($scriptParent) }
  try { [void]$candidateInputs.Add((Get-Location).Path) } catch {}

  foreach ($inputPath in $candidateInputs) {
    $candidate = Try-GetFullPath $inputPath
    if (!$candidate) { continue }

    if ((Test-Path -LiteralPath $candidate -PathType Leaf)) {
      $candidate = Split-Path -Parent $candidate
    }
    if (!(Test-Path -LiteralPath $candidate -PathType Container)) { continue }

    $r = Invoke-Capture -FilePath $script:Git -Arguments @("-C", $candidate, "rev-parse", "--show-toplevel")
    if ($r.Code -eq 0 -and $r.Out.Trim()) {
      $top = Try-GetFullPath $r.Out.Trim()
      if ($top) { return $top }
    }

    $dir = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
    while ($dir) {
      if (Test-Path -LiteralPath (Join-Path $dir.FullName ".git")) {
        return $dir.FullName
      }
      $dir = $dir.Parent
    }
  }

  throw "没有找到 Git 仓库根目录。请把脚本放在仓库中，或在仓库根目录运行。"
}

function Get-CurrentBranch {
  $r = Invoke-Git @("-C", $script:GitRoot, "branch", "--show-current")
  $branch = $r.Out.Trim()
  if (!$branch) { throw "当前不在普通分支上，可能处于 detached HEAD。请切换到要发布的分支。" }
  return $branch
}

function Get-LastVersionTag {
  $r = Invoke-Git @("-C", $script:GitRoot, "tag", "--list", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname") -AllowFail
  if ($r.Code -ne 0) { return "" }
  $tags = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() })
  if ($tags.Count -eq 0) { return "" }
  return $tags[0].Trim()
}

function Get-VersionFromFile {
  $versionFile = Join-Path $script:GitRoot "VERSION"
  if (!(Test-Path -LiteralPath $versionFile)) { return "1.0.1" }
  $v = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
  if ($v -match '^v') { $v = $v.Substring(1) }
  if ($v -notmatch '^\d+\.\d+\.\d+$') { return "1.0.1" }
  return $v
}

function Add-VersionStep([string]$Version) {
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
    throw "版本号格式不正确：$Version"
  }

  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  $patch = [int]$Matches[3]

  $patch += 1
  if ($patch -ge 10) {
    $patch = 0
    $minor += 1
  }
  if ($minor -ge 10) {
    $minor = 0
    $major += 1
  }

  return "$major.$minor.$patch"
}

function Has-NewCommitsSinceTag([string]$Tag) {
  if ([string]::IsNullOrWhiteSpace($Tag)) {
    $r = Invoke-Git @("-C", $script:GitRoot, "rev-list", "--count", "HEAD")
  } else {
    $r = Invoke-Git @("-C", $script:GitRoot, "rev-list", "--count", "$Tag..HEAD")
  }
  return ([int]$r.Out.Trim()) -gt 0
}

function Assert-CleanWorkTree {
  $r = Invoke-Git @("-C", $script:GitRoot, "status", "--porcelain")
  if ($r.Out.Trim()) {
    Write-Warn "当前工作区存在未提交更改："
    Write-Host $r.Out
    throw "请先提交或暂存处理这些更改，再执行发布。"
  }
}

function Update-VersionInFiles([string]$OldVersion, [string]$NewVersion) {
  $versionFile = Join-Path $script:GitRoot "VERSION"
  Set-Content -LiteralPath $versionFile -Value $NewVersion -Encoding UTF8

  $excludeDirs = @(".git", "logs", "backups", "repo-cache", "npm-global", "node_modules", "dist", "release")
  $includeExts = @(".md", ".ps1", ".json", ".jsonc", ".conf", ".cmd", ".txt", ".yml", ".yaml")

  $files = Get-ChildItem -LiteralPath $script:GitRoot -Recurse -File -Force | Where-Object {
    $full = $_.FullName
    foreach ($d in $excludeDirs) {
      if ($full -like "*\$d\*") { return $false }
    }
    return $includeExts -contains $_.Extension.ToLowerInvariant() -or $_.Name -eq "VERSION"
  }

  foreach ($file in $files) {
    if ($file.Name -eq "VERSION") { continue }

    $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $new = $raw

    $escapedOld = [Regex]::Escape($OldVersion)
    $new = $new -replace "version-$escapedOld", "version-$NewVersion"
    $new = $new -replace "Version-$escapedOld", "Version-$NewVersion"
    $new = $new -replace "V$escapedOld", "V$NewVersion"
    $new = $new -replace "v$escapedOld", "v$NewVersion"
    $new = $new -replace "(?<!\d)$escapedOld(?!\d)", $NewVersion

    if ($new -ne $raw) {
      Set-Content -LiteralPath $file.FullName -Value $new -Encoding UTF8
      $rel = $file.FullName.Substring($script:GitRoot.Length).TrimStart([char]'\')
      Write-Host "  version updated: $rel"
    }
  }
}

function Build-ReleaseNotes([string]$LastTag, [string]$NewTag, [hashtable]$Config) {
  $mode = (Conf $Config "NOTES_MODE" "git").ToLowerInvariant()
  $manual = ""

  if ($mode -eq "manual" -or $mode -eq "both") {
    Write-Host ""
    Write-Host "请输入发布说明。输入单独一行 END 结束。"
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
      $line = Read-Host "notes"
      if ($line -eq "END") { break }
      [void]$lines.Add($line)
    }
    $manual = ($lines -join "`n").Trim()
  }

  $range = if ([string]::IsNullOrWhiteSpace($LastTag)) { "HEAD" } else { "$LastTag..HEAD" }
  $gitLog = (Invoke-Git @("-C", $script:GitRoot, "log", "--pretty=format:- %s (%h)", $range)).Out.Trim()
  if (!$gitLog) { $gitLog = "- 初始发布" }

  $text = "# $ProjectName $NewTag`n`n"
  if ($manual) {
    $text += "$manual`n`n"
  }
  if ($mode -eq "git" -or $mode -eq "both") {
    $text += "## Git 提交记录`n`n$gitLog`n"
  }

  $tmpBase = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
  $tmp = Join-Path $tmpBase ("opencode-pocket-kit-release-notes-" + [Guid]::NewGuid().ToString("N") + ".md")
  Set-Content -LiteralPath $tmp -Value $text -Encoding UTF8
  return $tmp
}

function Copy-ReleaseTree([string]$Dest, [hashtable]$Config) {
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null

  $excludeDirText = Conf $Config "EXCLUDE_DIRS" ".git,.github,logs,backups,repo-cache,npm-global,node_modules,dist,release"
  $excludeFileText = Conf $Config "EXCLUDE_FILES" "vault\secrets.env.enc"
  $excludeDirs = @($excludeDirText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $excludeFiles = @($excludeFileText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })

  $items = Get-ChildItem -LiteralPath $script:GitRoot -Force
  foreach ($item in $items) {
    if ($excludeDirs -contains $item.Name) { continue }
    $target = Join-Path $Dest $item.Name

    if ($item.PSIsContainer) {
      Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    } else {
      Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    }
  }

  foreach ($rel in $excludeFiles) {
    $path = Join-Path $Dest $rel
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }

  $logDir = Join-Path $Dest "logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Create-ReleaseZip([string]$Version, [hashtable]$Config) {
  $prefix = Conf $Config "ASSET_PREFIX" "opencode-pocket-kit"
  $releaseDir = Join-Path $script:GitRoot "release"
  New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

  $tmpBase = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
  $stage = Join-Path $tmpBase ("opencode-pocket-kit-stage-" + [Guid]::NewGuid().ToString("N"))
  $stageRoot = Join-Path $stage "$prefix-v$Version"
  New-Item -ItemType Directory -Force -Path $stage | Out-Null

  Copy-ReleaseTree $stageRoot $Config

  $zip = Join-Path $releaseDir "$prefix-v$Version.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path $stageRoot -DestinationPath $zip -CompressionLevel Optimal
  Remove-Item -LiteralPath $stage -Recurse -Force

  return $zip
}

function Ensure-GithubRemote([hashtable]$Config) {
  $remote = (Invoke-Git @("-C", $script:GitRoot, "remote", "get-url", "origin") -AllowFail)
  if ($remote.Code -eq 0 -and $remote.Out.Trim()) { return }

  $gh = Resolve-CommandPath "gh"
  if (!$gh) {
    Write-Warn "未找到 GitHub CLI，且仓库没有 origin 远程地址。"
    throw "请先安装 gh，或手动添加 origin。"
  }

  $repoName = Conf $Config "REPO_NAME" "opencode-pocket-kit"
  Write-Warn "当前仓库没有 origin，将尝试用 GitHub CLI 创建仓库：$repoName"

  $r = Invoke-Capture -FilePath $gh -Arguments @("repo", "create", $repoName, "--public", "--source", $script:GitRoot, "--remote", "origin", "--push")
  if ($r.Code -ne 0) {
    throw "gh repo create failed:`n$($r.Err)`n$($r.Out)"
  }
}

function Publish-GithubRelease([string]$Tag, [string]$ZipPath, [string]$NotesPath, [hashtable]$Config) {
  $gh = Resolve-CommandPath "gh"
  if (!$gh) { throw "未找到 GitHub CLI：gh" }

  $auth = Invoke-Capture -FilePath $gh -Arguments @("auth", "status")
  if ($auth.Code -ne 0) {
    throw "GitHub CLI 尚未登录。请先运行：gh auth login"
  }

  $releaseArgs = New-Object System.Collections.Generic.List[string]
  [void]$releaseArgs.Add("release")
  [void]$releaseArgs.Add("create")
  [void]$releaseArgs.Add($Tag)
  [void]$releaseArgs.Add($ZipPath)
  [void]$releaseArgs.Add("--title")
  [void]$releaseArgs.Add("$ProjectName $Tag")
  [void]$releaseArgs.Add("--notes-file")
  [void]$releaseArgs.Add($NotesPath)

  if ((Conf $Config "DRAFT" "0") -eq "1") { [void]$releaseArgs.Add("--draft") }
  if ((Conf $Config "PRERELEASE" "0") -eq "1") { [void]$releaseArgs.Add("--prerelease") }

  $r = Invoke-Capture -FilePath $gh -Arguments $releaseArgs.ToArray()
  if ($r.Code -ne 0) {
    throw "gh release create failed:`n$($r.Err)`n$($r.Out)"
  }
}

try {
  Write-Host "$ProjectName 一键发布版本工具"
  $script:Git = Resolve-CommandPath "git"
  if (!$script:Git) { throw "未找到 git，请先安装 Git 并加入 PATH。" }

  $inputRoot = if (![string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { Split-Path -Parent $PSScriptRoot }
  $script:GitRoot = Resolve-GitRoot $inputRoot
  Set-Location -LiteralPath $script:GitRoot

  Write-Host "仓库目录：$script:GitRoot"

  $configPath = Join-Path $script:GitRoot "release.conf"
  $config = Read-ConfigFile $configPath

  $branch = Conf $config "BRANCH" ""
  if (!$branch) { $branch = Get-CurrentBranch }
  Write-Host "发布分支：$branch"

  $lastTag = Get-LastVersionTag
  if ($lastTag) {
    Write-Host "上一个版本标签：$lastTag"
  } else {
    Write-Host "未找到历史版本标签，将按 VERSION 文件继续。"
  }

  if (!(Has-NewCommitsSinceTag $lastTag)) {
    Write-Ok "没有检测到新提交，不需要发布新版本。"
    exit 0
  }

  Assert-CleanWorkTree

  $oldVersion = Get-VersionFromFile
  $newVersion = Add-VersionStep $oldVersion
  $newTag = "v$newVersion"

  $tagExists = Invoke-Git @("-C", $script:GitRoot, "rev-parse", "-q", "--verify", "refs/tags/$newTag") -AllowFail
  if ($tagExists.Code -eq 0) {
    throw "标签已存在：$newTag"
  }

  Write-Info "版本递增：$oldVersion -> $newVersion"

  Update-VersionInFiles $oldVersion $newVersion

  $notesPath = Build-ReleaseNotes $lastTag $newTag $config
  $zipPath = Create-ReleaseZip $newVersion $config
  Write-Ok "发行包已生成：$zipPath"

  Invoke-Git @("-C", $script:GitRoot, "add", "-A") | Out-Null
  Invoke-Git @("-C", $script:GitRoot, "commit", "-m", "release: $ProjectName $newTag") | Out-Null
  Invoke-Git @("-C", $script:GitRoot, "tag", "-a", $newTag, "-m", "$ProjectName $newTag") | Out-Null

  Ensure-GithubRemote $config

  Invoke-Git @("-C", $script:GitRoot, "push", "origin", $branch) | Out-Null
  Invoke-Git @("-C", $script:GitRoot, "push", "origin", $newTag) | Out-Null

  Publish-GithubRelease $newTag $zipPath $notesPath $config

  Write-Ok "发布完成：$newTag"
  Write-Host "发行包：$zipPath"
  exit 0
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
