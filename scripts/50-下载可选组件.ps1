
param([string]$Action="test")
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
$Action = if ($Action) { $Action.Trim().ToLowerInvariant() } else { "test" }
if (@("network","check","probe") -contains $Action) { $Action = "test" }
if (@("all","download","skills-all") -contains $Action) { $Action = "skills" }
if (@("sp","superpower") -contains $Action) { $Action = "superpowers" }

$log = Join-Path $LogsDir ("network-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$transcriptStarted = $false
try {
  Start-Transcript -Path $log -Force | Out-Null
  $transcriptStarted = $true
  Write-Color "🌐 OpenCode Pocket Kit 下载工具 $PortableVersion" Cyan
  Write-Color "📁 根目录： $PortableRoot" DarkGray
  if ($ProxyUrl) { Write-Color "🌐 已启用代理： $ProxyUrl" Green } else { Write-Color "🌐 未启用代理" Yellow }
  Write-Color "📝 日志： $log" DarkGray
  $git = Resolve-Cmd "git" $true
  Write-Color "🔧 git： $git" DarkGray

  function Test-GitRepo($Name,$Url) {
    Write-Color "`n[测试] git ls-remote $Name" Cyan
    $res = Invoke-Git -GitArguments @("ls-remote","--heads",$Url,"HEAD") -TimeoutSeconds (ConfInt "GIT_LSREMOTE_TIMEOUT_SECONDS" 90) -AllowFailure
    if ($res.ExitCode -eq 0) { Write-Color "  [通过] $Name 可访问" Green; return $true }
    Write-Color "  [失败] $Name" Red
    if ($res.Output) { Write-Host $res.Output }
    return $false
  }

  function Test-CacheHasPaths($Dest,[string[]]$Paths) {
    if (!(Test-Path $Dest)) { return $false }
    foreach($p in $Paths) {
      $basePath = $p -replace '/\*\*$',''
      $basePath = $basePath -replace '\*\*$',''
      # repaired
      if (!$basePath) { continue }
      $candidate = Join-Path $Dest ($basePath -replace '/', '\')
      if (!(Test-Path $candidate)) { return $false }
    }
    return $true
  }

  function Get-RepoHead($Dest) {
    if (!(Test-Path (Join-Path $Dest ".git"))) { return "" }
    $r = Invoke-Git -GitArguments @("-C",$Dest,"rev-parse","HEAD") -TimeoutSeconds 60 -AllowFailure
    if ($r.ExitCode -eq 0) { return (($r.Output -split "`r?`n") | Select-Object -First 1).Trim() }
    return ""
  }

  function Get-RemoteHead($Url) {
    $r = Invoke-Git -GitArguments @("ls-remote",$Url,"HEAD") -TimeoutSeconds (ConfInt "GIT_LSREMOTE_TIMEOUT_SECONDS" 90) -AllowFailure
    if ($r.ExitCode -ne 0 -or !$r.Output) { return "" }
    $first = ($r.Output -split "`r?`n" | Select-Object -First 1).Trim()
    if ($first -match '^([0-9a-fA-F]{40})') { return $Matches[1] }
    return ""
  }

  function Sparse-Clone($Name,$Url,[string[]]$Paths) {
    Write-Color "`n[下载] $Name" Cyan
    $dest = Join-Path $RepoCacheDir $Name
    $timeout = ConfInt "GIT_CLONE_TIMEOUT_SECONDS" 600

    if ((Test-Path $dest) -and (Test-CacheHasPaths $dest $Paths)) {
      $localHead = Get-RepoHead $dest
      $remoteHead = Get-RemoteHead $Url
      if ($localHead -and $remoteHead -and $localHead -eq $remoteHead) {
        Write-Color "  [跳过] 缓存已是最新： $dest" Green
        return $true
      }
      if ($localHead -and !$remoteHead) {
        Write-Color "  [保留] 缓存存在，但暂时无法检查远端 HEAD： $dest" Yellow
        return $true
      }
      Write-Color "  [信息] 现有缓存将被更新/替换： $dest" DarkGray
    } elseif (Test-Path $dest) {
      Write-Color "  [信息] 现有缓存不完整，将被替换： $dest" DarkGray
    }

    $tmp = Join-Path $env:TEMP ("$Name.git-" + [Guid]::NewGuid().ToString("N"))
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
    $cloneArgs = @("clone","--depth","1","--filter=blob:none","--no-checkout",$Url,$tmp)
    $res = Invoke-Git -GitArguments $cloneArgs -TimeoutSeconds $timeout -AllowFailure
    if ($res.ExitCode -ne 0) {
      Write-Color "  [失败] clone 失败" Red
      if ($res.Output) { Write-Host $res.Output }
      Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
      return $false
    }
    $res = Invoke-Git -GitArguments @("-C",$tmp,"sparse-checkout","init","--no-cone") -TimeoutSeconds 60 -AllowFailure
    if ($res.ExitCode -ne 0) { Write-Color "  [失败] sparse-checkout 初始化失败" Red; if($res.Output){Write-Host $res.Output}; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; return $false }
    $res = Invoke-Git -GitArguments (@("-C",$tmp,"sparse-checkout","set") + $Paths) -TimeoutSeconds 120 -AllowFailure
    if ($res.ExitCode -ne 0) { Write-Color "  [失败] sparse-checkout 设置失败" Red; if($res.Output){Write-Host $res.Output}; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; return $false }
    $res = Invoke-Git -GitArguments @("-C",$tmp,"checkout") -TimeoutSeconds $timeout -AllowFailure
    if ($res.ExitCode -ne 0) { Write-Color "  [失败] checkout 失败" Red; if($res.Output){Write-Host $res.Output}; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; return $false }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-Color "  [完成] 已缓存： $dest" Green
    return $true
  }

  function Copy-Skill($RepoName,$Rel,$SkillName) {
    $src = Join-Path (Join-Path $RepoCacheDir $RepoName) $Rel
    $dst = Join-Path (Join-Path $ConfigDir "skills") $SkillName
    if (Copy-DirectoryClean $src $dst) { Write-Color "    [完成] $SkillName" Green; return $true }
    Write-Color "    [缺失] $SkillName 源目录不存在： $src" Yellow
    return $false
  }

  function Install-SuperpowersFromCache {
    New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir "skills"),(Join-Path $ConfigDir "plugins") | Out-Null
    $sp = Join-Path $RepoCacheDir "superpowers-official"
    if (!(Test-Path $sp)) { Write-Color "    [缺失] Superpowers 缓存不存在： $sp" Yellow; return $false }
    Copy-DirectoryClean $sp (Join-Path $ConfigDir "superpowers") | Out-Null
    $ok = $true
    $pluginSrc = Join-Path $sp ".opencode\plugins\superpowers.js"
    if (Test-Path $pluginSrc) {
      Copy-Item -LiteralPath $pluginSrc -Destination (Join-Path $ConfigDir "plugins\superpowers.js") -Force
      Write-Color "    [完成] Superpowers 插件" Green
    } else { Write-Color "    [缺失] Superpowers 插件 源目录不存在： $pluginSrc" Yellow; $ok = $false }
    $spSkills = Join-Path $sp "skills"
    if (Test-Path $spSkills) {
      Copy-DirectoryClean $spSkills (Join-Path $ConfigDir "skills\superpowers") | Out-Null
      Write-Color "    [完成] Superpowers skills" Green
    } else { Write-Color "    [缺失] Superpowers skills 源目录不存在： $spSkills" Yellow; $ok = $false }
    return $ok
  }

  function Install-RegularSkillsFromCache {
    New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir "skills") | Out-Null
    foreach($s in @("webapp-testing","frontend-design","pdf")){ Copy-Skill "anthropics-skills" "skills\$s" $s | Out-Null }
    foreach($s in @("tavily-best-practices","tavily-cli","tavily-crawl","tavily-dynamic-search","tavily-extract","tavily-map","tavily-research","tavily-search")){ Copy-Skill "tavily-skills" "skills\$s" $s | Out-Null }
    Copy-Skill "agent-browser" "skills\agent-browser" "agent-browser" | Out-Null
    Copy-Skill "awesome-copilot" "skills\refactor" "refactor" | Out-Null

    $uiSrc = Join-Path $RepoCacheDir "ui-ux-pro-max-skill"
    $uiDst = Join-Path (Join-Path $ConfigDir "skills") "ui-ux-pro-max-skill"
    if (Test-Path (Join-Path $uiSrc "SKILL.md")) {
      Copy-DirectoryClean $uiSrc $uiDst | Out-Null
      Write-Color "    [完成] ui-ux-pro-max-skill" Green
    } elseif (Test-Path $uiSrc) {
      $skillFile = Get-ChildItem -LiteralPath $uiSrc -Filter "SKILL.md" -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\.git(\\|$)' } | Select-Object -First 1
      if ($skillFile) {
        Copy-DirectoryClean $skillFile.Directory.FullName $uiDst | Out-Null
        Write-Color "    [完成] ui-ux-pro-max-skill (found nested SKILL.md: $($skillFile.Directory.Name))" Green
      } else {
        Write-Color "    [缺失] ui-ux-pro-max-skill 下没有找到 SKILL.md： $uiSrc" Yellow
      }
    } else {
      Write-Color "    [缺失] ui-ux-pro-max-skill 源目录不存在： $uiSrc" Yellow
    }
  }

  $repos = @(
    @{Name="superpowers-official"; Url="https://github.com/obra/superpowers.git"; Paths=@(".opencode/**","skills/**","lib/**","package.json","README.md")},
    @{Name="anthropics-skills"; Url="https://github.com/anthropics/skills.git"; Paths=@("skills/webapp-testing/**","skills/frontend-design/**","skills/pdf/**")},
    @{Name="tavily-skills"; Url="https://github.com/tavily-ai/skills.git"; Paths=@("skills/tavily-best-practices/**","skills/tavily-cli/**","skills/tavily-crawl/**","skills/tavily-dynamic-search/**","skills/tavily-extract/**","skills/tavily-map/**","skills/tavily-research/**","skills/tavily-search/**")},
    @{Name="agent-browser"; Url="https://github.com/vercel-labs/agent-browser.git"; Paths=@("skills/agent-browser/**")},
    @{Name="awesome-copilot"; Url="https://github.com/github/awesome-copilot.git"; Paths=@("skills/refactor/**")},
    @{Name="ui-ux-pro-max-skill"; Url="https://github.com/nextlevelbuilder/ui-ux-pro-max-skill.git"; Paths=@("SKILL.md","README.md","references/**","scripts/**","**/SKILL.md")}
  )

  if ($Action -eq "help" -or $Action -eq "/?" -or $Action -eq "-h" -or $Action -eq "--help") {
    Write-Host ""
    Write-Host "用法：安装入口 [test|skills|superpowers]"
    Write-Host "  test         通过 proxy.conf 测试 GitHub 和 npm"
    Write-Host "  skills       下载/安装全部可选 skills 与 Superpowers"
    Write-Host "  superpowers  只下载/安装 Superpowers"
    exit 0
  }

  if ($Action -eq "test") {
    $ok = $true
    foreach($r in $repos) { if (!(Test-GitRepo $r.Name $r.Url)) { $ok = $false } }
    $npm = Resolve-Cmd "npm.cmd" $false; if(!$npm){$npm=Resolve-Cmd "npm" $true}
    Write-Color "`n[测试] npm view opencode-ai version" Cyan
    $nr = Invoke-NativeCapture -File $npm -Arguments @("view","opencode-ai","version","--registry=$(Conf 'NPM_REGISTRY' 'https://registry.npmjs.org')") -TimeoutSeconds 120 -AllowFailure
    if($nr.ExitCode -eq 0){Write-Color "  [通过] npm 可访问： $($nr.Output)" Green}else{Write-Color "  [失败] npm" Red; if($nr.Output){Write-Host $nr.Output}; $ok=$false}
    if($ok){Write-Color "`n✅ 网络测试通过。安装.cmd/更新.cmd 可以下载可选 skills。" Green}else{Write-Color "`n❌ 网络测试失败。请先修正 proxy.conf 或代理软件。" Red}
    exit ($(if($ok){0}else{1}))
  }

  if ($Action -eq "superpowers") {
    Sparse-Clone $repos[0].Name $repos[0].Url $repos[0].Paths | Out-Null
    Install-SuperpowersFromCache | Out-Null
    Write-Color "`n✅ Superpowers 下载步骤完成。" Green
    exit 0
  }

  if ($Action -ne "skills") { Write-Color "❌ 未知操作： $Action" Red; Write-Color "用法：安装入口 [test|skills|superpowers]" Yellow; exit 2 }

  foreach($r in $repos) { Sparse-Clone $r.Name $r.Url $r.Paths | Out-Null }
  Install-RegularSkillsFromCache
  Install-SuperpowersFromCache | Out-Null
  Write-Color "`n✅ Skills 下载步骤完成。有变化的仓库已更新，未变化的缓存已跳过。" Green
} catch {
  Write-Host "[致命] 下载/网络步骤失败：" -ForegroundColor Red
  Write-Host $_ -ForegroundColor Red
  exit 1
} finally {
  if ($transcriptStarted) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
}
