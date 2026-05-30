
$ErrorActionPreference = "Stop"
$script:PortableVersion = "V1.1.1"
$script:ProductName = "OpenCode Pocket Kit"
$script:PortableRoot = Split-Path -Parent $PSScriptRoot
$script:BinDir = Join-Path $script:PortableRoot "bin"
$script:ConfigDir = Join-Path $script:PortableRoot "config\opencode"
$script:VaultDir = Join-Path $script:PortableRoot "vault"
$script:ProjectsDir = Join-Path $script:PortableRoot "projects"
$script:LogsDir = Join-Path $script:PortableRoot "logs"
$script:CacheDir = Join-Path $script:PortableRoot "cache"
$script:NpmGlobalDir = Join-Path $script:PortableRoot "npm-global"
$script:HomeDir = Join-Path $script:PortableRoot "home"
$script:DataDir = Join-Path $script:PortableRoot "data"
$script:RepoCacheDir = Join-Path $script:PortableRoot "repo-cache"
$script:StateDir = Join-Path $script:PortableRoot ".portable-state"
$script:ProxyConf = Join-Path $script:PortableRoot "proxy.conf"

foreach ($d in @($BinDir,$ConfigDir,$VaultDir,$ProjectsDir,$LogsDir,$CacheDir,$NpmGlobalDir,$HomeDir,$DataDir,$RepoCacheDir,$StateDir)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Write-Color { param([string]$Text,[string]$Color="White") Write-Host $Text -ForegroundColor $Color }

function Get-ConfMap {
  $map = @{}
  if (Test-Path $script:ProxyConf) {
    foreach ($line in Get-Content -LiteralPath $script:ProxyConf -Encoding UTF8) {
      $t = $line.Trim()
      if ($t -eq "" -or $t.StartsWith("#")) { continue }
      $idx = $t.IndexOf("=")
      if ($idx -lt 1) { continue }
      $k = $t.Substring(0,$idx).Trim()
      $v = $t.Substring($idx+1).Trim()
      $map[$k] = $v
    }
  }
  return $map
}

$script:Conf = Get-ConfMap
function Conf([string]$Key,[string]$Default="") {
  if ($script:Conf.ContainsKey($Key) -and $null -ne $script:Conf[$Key] -and $script:Conf[$Key] -ne "") { return [string]$script:Conf[$Key] }
  return $Default
}
function ConfBool([string]$Key,[bool]$Default=$false) {
  $v = (Conf $Key ($(if($Default){"1"}else{"0"}))).ToLowerInvariant()
  return @("1","true","yes","on","y") -contains $v
}
function ConfInt([string]$Key,[int]$Default) {
  $v = Conf $Key ""
  $out = 0
  if ([int]::TryParse($v, [ref]$out)) { return $out }
  return $Default
}

function Get-ProxyUrl {
  if (!(ConfBool "PROXY_ENABLED" $false)) { return "" }
  $url = Conf "PROXY_URL" ""
  if ($url) { return $url }
  $proxyHost = Conf "PROXY_HOST" "127.0.0.1"
  $port = Conf "PROXY_PORT" ""
  $scheme = Conf "PROXY_SCHEME" "http"
  if (!$port) { return "" }
  return "${scheme}://${proxyHost}:${port}"
}
$script:ProxyUrl = Get-ProxyUrl

function Apply-PortableEnvironment {
  $runtimeRoot = Join-Path $env:TEMP ("opencode-portable-runtime\" + ([Math]::Abs($PortableRoot.GetHashCode()).ToString("x")))
  $runtimeCache = Join-Path $runtimeRoot "cache"
  $runtimeTmp = Join-Path $runtimeRoot "tmp"
  New-Item -ItemType Directory -Force -Path $runtimeCache,$runtimeTmp | Out-Null

  $env:USERPROFILE = $HomeDir
  $env:HOME = $HomeDir
  # OMO/OpenAgent on Windows discovers user config under %APPDATA%\opencode.
  # Point APPDATA to the portable config parent so %APPDATA%\opencode == config\opencode.
  $env:APPDATA = Join-Path $PortableRoot "config"
  $env:LOCALAPPDATA = Join-Path $PortableRoot "data"
  $env:XDG_CONFIG_HOME = Join-Path $PortableRoot "config"
  $env:XDG_DATA_HOME = $DataDir
  $env:XDG_CACHE_HOME = $CacheDir
  $env:BUN_INSTALL_CACHE_DIR = Join-Path $CacheDir "bun-install-cache"
  $env:BUN_CONFIG_NO_PROGRESS = "1"
  $env:OPENCODE_CONFIG = Join-Path $ConfigDir "opencode.json"
  $env:OPENCODE_CONFIG_DIR = $ConfigDir
  $env:npm_config_prefix = $NpmGlobalDir
  $env:NPM_CONFIG_PREFIX = $NpmGlobalDir
  $env:npm_config_cache = Join-Path $runtimeCache "npm-cache"
  $env:NPM_CONFIG_CACHE = $env:npm_config_cache
  $env:TEMP = $runtimeTmp
  $env:TMP = $runtimeTmp
  $nodePath = Join-Path $NpmGlobalDir "node_modules"
  $configNodePath = Join-Path $ConfigDir "node_modules"
  $nodePathParts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($configNodePath, $nodePath)) {
    if ($item -and !$nodePathParts.Contains($item)) { [void]$nodePathParts.Add($item) }
  }
  if ($env:NODE_PATH) {
    foreach ($item in ($env:NODE_PATH -split ';')) {
      if ($item -and !$nodePathParts.Contains($item)) { [void]$nodePathParts.Add($item) }
    }
  }
  $env:NODE_PATH = ($nodePathParts -join ";")
  $pathParts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($BinDir, (Join-Path $ConfigDir "node_modules\.bin"), $NpmGlobalDir, (Join-Path $NpmGlobalDir "node_modules\.bin"))) {
    if ($item -and !$pathParts.Contains($item)) { [void]$pathParts.Add($item) }
  }
  if ($env:PATH) {
    foreach ($item in ($env:PATH -split ';')) {
      if ($item -and !$pathParts.Contains($item)) { [void]$pathParts.Add($item) }
    }
  }
  $env:PATH = ($pathParts -join ";")
  $env:GIT_TERMINAL_PROMPT = "0"
  $env:GCM_INTERACTIVE = "Never"

  if ($script:ProxyUrl) {
    $env:HTTP_PROXY = $script:ProxyUrl
    $env:HTTPS_PROXY = $script:ProxyUrl
    $env:ALL_PROXY = $script:ProxyUrl
    $env:http_proxy = $script:ProxyUrl
    $env:https_proxy = $script:ProxyUrl
    $env:all_proxy = $script:ProxyUrl
    $env:NPM_CONFIG_PROXY = $script:ProxyUrl
    $env:NPM_CONFIG_HTTPS_PROXY = $script:ProxyUrl
    $env:NO_PROXY = "localhost,127.0.0.1,::1"
    $env:no_proxy = $env:NO_PROXY
  }
}

function Resolve-Cmd([string]$Name,[bool]$Required=$true) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  if ($Required) { throw "未找到必需命令： $Name" }
  return ""
}

function Quote-CmdArg([string]$s) {
  if ($null -eq $s) { return '""' }
  if ($s -eq '') { return '""' }
  $escaped = $s -replace '"','\"'
  if ($escaped -match '[\s&()\[\]{}^=;!''+,`~|<>]') { return '"' + $escaped + '"' }
  return $escaped
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [string[]]$Arguments=@(),
    [int]$TimeoutSeconds=300,
    [switch]$AllowFailure
  )
  $cmdLine = ((@($File) + @($Arguments)) | ForEach-Object { Quote-CmdArg ([string]$_) }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = "/d /s /c " + '"' + $cmdLine + '"'
  $psi.WorkingDirectory = $PortableRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try { $null = $p.Start() } catch {
    $msg = "启动命令失败： $cmdLine`n$($_.Exception.Message)"
    if ($AllowFailure) { return @{ ExitCode = 127; Output = $msg; TimedOut = $false } }
    throw $msg
  }
  $stdoutTask = $p.StandardOutput.ReadToEndAsync()
  $stderrTask = $p.StandardError.ReadToEndAsync()
  if (!$p.WaitForExit($TimeoutSeconds * 1000)) {
    try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch {}
    try { $stdout = $stdoutTask.Result } catch { $stdout = "" }
    try { $stderr = $stderrTask.Result } catch { $stderr = "" }
    $msg = "命令超时，超过 $TimeoutSeconds seconds: $cmdLine`n$stdout`n$stderr"
    if ($AllowFailure) { return @{ ExitCode = 124; Output = $msg; TimedOut = $true } }
    throw $msg
  }
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  $combined = (($stdout, $stderr) -join "`n").Trim()
  if ($p.ExitCode -ne 0 -and !$AllowFailure) { throw "命令失败，退出码 $($p.ExitCode): $cmdLine`n$combined" }
  return @{ ExitCode = $p.ExitCode; Output = $combined; TimedOut = $false }
}

function Git-BaseArgs {
  $base = @("-c","http.version=HTTP/1.1","-c","http.lowSpeedLimit=$(ConfInt 'GIT_LOW_SPEED_LIMIT' 1000)","-c","http.lowSpeedTime=$(ConfInt 'GIT_LOW_SPEED_TIME_SECONDS' 180)","-c","credential.helper=","-c","core.askPass=")
  if ($script:ProxyUrl) { $base += @("-c","http.proxy=$script:ProxyUrl","-c","https.proxy=$script:ProxyUrl") }
  $base += @("-c","http.sslBackend=schannel")
  return $base
}
function Invoke-Git {
  param([Alias('Args')][string[]]$GitArguments,[int]$TimeoutSeconds=300,[switch]$AllowFailure)
  $git = Resolve-Cmd "git" $true
  if (ConfBool "GIT_VERBOSE" $false) { $env:GIT_CURL_VERBOSE = "1" } else { Remove-Item Env:\GIT_CURL_VERBOSE -ErrorAction SilentlyContinue }
  return Invoke-NativeCapture -File $git -Arguments ((Git-BaseArgs) + @($GitArguments)) -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
}

function Copy-DirectoryClean([string]$Source,[string]$Dest) {
  if (!(Test-Path -LiteralPath $Source)) { return $false }
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Dest -Recurse -Force
  return $true
}

function Get-PortableOpenCodePath {
  foreach ($p in @((Join-Path $BinDir "opencode.exe"),(Join-Path $BinDir "opencode.cmd"),(Join-Path $NpmGlobalDir "opencode.cmd"),(Join-Path $NpmGlobalDir "node_modules\.bin\opencode.cmd"))) {
    if (Test-Path $p) { return $p }
  }
  return ""
}

function Get-NpmPackageVersionAt([string]$NodeModulesDir, [string]$PackageName) {
  if (!$NodeModulesDir -or !$PackageName) { return "" }
  $pkgJson = Join-Path $NodeModulesDir (Join-Path $PackageName "package.json")
  if (!(Test-Path -LiteralPath $pkgJson)) { return "" }
  try { return ([string]((Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version)) } catch { return "" }
}

function Get-LocalNpmPackageVersion([string]$PackageName) {
  return (Get-NpmPackageVersionAt (Join-Path $NpmGlobalDir "node_modules") $PackageName)
}

function Get-ConfigNpmPackageVersion([string]$PackageName) {
  return (Get-NpmPackageVersionAt (Join-Path $ConfigDir "node_modules") $PackageName)
}

function Get-OmoPackageName {
  # Prefer the current package name.  Old proxy.conf files may still contain
  # OMO_PACKAGE=oh-my-opencode from earlier broken builds; ignore that unless
  # explicitly allowed, then use it only as fallback.
  $pkg = Conf "OMO_PACKAGE" "oh-my-openagent"
  if (!$pkg) { $pkg = "oh-my-openagent" }
  if ($pkg -eq "oh-my-opencode" -and !(ConfBool "OMO_ALLOW_LEGACY_PACKAGE" $false)) { return "oh-my-openagent" }
  return $pkg
}

function Get-OmoPluginName {
  # Upstream rename-compat docs prefer oh-my-openagent in opencode.json.  Old
  # 本包始终写入推荐的 OMO 插件名。
  $name = Conf "OMO_PLUGIN_NAME" "oh-my-openagent"
  if (!$name) { $name = "oh-my-openagent" }
  if ($name -eq "oh-my-opencode" -and !(ConfBool "OMO_ALLOW_LEGACY_PLUGIN" $false)) { return "oh-my-openagent" }
  return $name
}

function Get-OmoConfigBaseName {
  $base = Conf "OMO_CONFIG_BASENAME" "oh-my-openagent"
  if (!$base) { $base = "oh-my-openagent" }
  return $base
}

function Get-NpmLatestVersion([string]$PackageName) {
  $npm = Resolve-Cmd "npm.cmd" $false; if(!$npm){ $npm = Resolve-Cmd "npm" $true }
  $reg = Conf "NPM_REGISTRY" "https://registry.npmjs.org"
  $res = Invoke-NativeCapture -File $npm -Arguments @("view",$PackageName,"version","--registry=$reg") -TimeoutSeconds 120 -AllowFailure
  if ($res.ExitCode -ne 0) { return "" }
  return ($res.Output -split "`r?`n" | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+' } | Select-Object -First 1).Trim()
}

function Install-NpmPackageIfNeeded([string]$PackageSpec,[string]$PackageName,[string]$Purpose,[bool]$Force=$false) {
  $npm = Resolve-Cmd "npm.cmd" $false; if(!$npm){ $npm = Resolve-Cmd "npm" $true }
  $reg = Conf "NPM_REGISTRY" "https://registry.npmjs.org"
  $local = Get-LocalNpmPackageVersion $PackageName
  $latest = Get-NpmLatestVersion $PackageName
  if (!$Force -and $local -and $latest -and $local -eq $latest) {
    Write-Color "✅ $Purpose 已是最新： $PackageName@$local" Green
    return $true
  }
  if (!$Force -and $local -and !$latest) {
    Write-Color "⚠️ 无法查询最新版本： $PackageName. 保留本地版本 $PackageName@$local." Yellow
    return $true
  }
  $reason = if(!$local){"missing"} elseif($latest){"$local -> $latest"} else {"requested"}
  Write-Color "📦 正在安装/更新 ${Purpose}： $PackageSpec ($reason)" Cyan
  $args = @("install","-g",$PackageSpec,"--registry=$reg","--foreground-scripts","--loglevel=notice","--no-audit","--no-fund")
  $res = Invoke-NativeCapture -File $npm -Arguments $args -TimeoutSeconds (ConfInt "NPM_PACKAGE_TIMEOUT_SECONDS" 900) -AllowFailure
  if ($res.Output) { Write-Host $res.Output }
  if ($res.ExitCode -ne 0) { Write-Color "⚠️ npm 安装 $PackageSpec 返回退出码 $($res.ExitCode)。" Yellow; return $false }
  return $true
}

function Get-InstalledOmoPackage {
  $preferred = Get-OmoPackageName
  foreach ($pkg in @($preferred, 'oh-my-openagent', 'oh-my-opencode') | Where-Object { $_ } | Select-Object -Unique) {
    if (Get-ConfigNpmPackageVersion $pkg) { return $pkg }
    if (Get-LocalNpmPackageVersion $pkg) { return $pkg }
  }
  return ""
}

function ConvertTo-HashtableDeep($InputObject) {
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $h=@{}; foreach($k in $InputObject.Keys){ $h[$k] = ConvertTo-HashtableDeep $InputObject[$k] }; return $h
  }
  if ($InputObject -is [System.Array]) { return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ }) }
  if ($InputObject -is [pscustomobject]) {
    $h=@{}; foreach($p in $InputObject.PSObject.Properties){ $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $h
  }
  return $InputObject
}


function Get-OpenCodeConfigPath {
  return (Join-Path $ConfigDir "opencode.json")
}


function ConvertTo-StringArraySafe($Value) {
  $result = @()
  if ($null -eq $Value) { return @() }

  # PowerShell 对 JSON 数组、.NET List、ArrayList、单个字符串的处理差异很大。
  # 这里显式展开 IEnumerable，但排除 string / hashtable，避免把字符串拆成字符，
  # 也避免把损坏的 {"Length":15} 对象转换成奇怪插件项。
  $items = @()
  if ($Value -is [string]) {
    $items = @($Value)
  } elseif ($Value -is [System.Collections.IDictionary]) {
    $items = @($Value)
  } elseif ($Value -is [System.Collections.IEnumerable]) {
    foreach ($x in $Value) { $items += $x }
  } else {
    $items = @($Value)
  }

  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      $s = ([string]$item).Trim()
      if ($s) { $result += $s }
      continue
    }
    # 忽略对象型或异常插件项，例如 {"Length":15}。
  }
  return @($result)
}

function Test-InvalidPluginObject($Item) {
  if ($null -eq $Item) { return $false }
  if ($Item -is [string]) { return $false }
  # 只清理明确的对象型异常项，例如 {"Length":15}。
  # 数字、布尔等异常值直接忽略，不再触发备份噪音。
  if ($Item -is [System.Collections.IDictionary]) { return $true }
  if ($Item -is [pscustomobject]) { return $true }
  return $false
}

function Write-OpenCodeConfigHashtable([hashtable]$Cfg, [string]$Path) {
  if (!$Cfg.ContainsKey('$schema')) { $Cfg['$schema'] = 'https://opencode.ai/config.json' }
  # 避免 PowerShell 将单元素数组/泛型 List 写成对象或标量。
  # plugin 在本便携包中始终写成 JSON 字符串数组。
  if ($Cfg.ContainsKey('plugin') -and $null -ne $Cfg['plugin']) {
    $Cfg['plugin'] = [string[]](ConvertTo-StringArraySafe $Cfg['plugin'])
  }
  ($Cfg | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Repair-OpenCodeConfigFile {
  param(
    [string]$PluginName = "",
    [switch]$RemoveOmoPlugin
  )

  $configFile = Get-OpenCodeConfigPath
  if (!(Test-Path -LiteralPath $configFile)) {
    '{"$schema":"https://opencode.ai/config.json"}' | Set-Content -LiteralPath $configFile -Encoding UTF8
  }

  $raw = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
  $cfg = $null
  $changed = $false
  try {
    $cfg = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
  } catch {
    $bak = $configFile + ".bad-json-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
    Copy-Item -LiteralPath $configFile -Destination $bak -Force
    Write-Color "⚠️ opencode.json 无法解析。已备份到 $bak 并创建最小配置。" Yellow
    $cfg = @{}
    $changed = $true
  }

  if ($null -eq $cfg) { $cfg = @{}; $changed = $true }
  if (!($cfg -is [System.Collections.IDictionary])) { $cfg = @{}; $changed = $true }
  if (!$cfg.ContainsKey('$schema')) { $cfg['$schema'] = 'https://opencode.ai/config.json'; $changed = $true }

  # Normalize plugin list.  OpenCode expects plugin entries to be strings in this portable setup.
  # Drop corrupted objects such as {"Length":15}, which are the cause of provider/agent startup errors.
  $hadPlugin = $cfg.ContainsKey('plugin') -and $null -ne $cfg['plugin']
  $rawPluginItems = @()
  if ($hadPlugin) { $rawPluginItems = if ($cfg['plugin'] -is [System.Array]) { @($cfg['plugin']) } else { @($cfg['plugin']) } }
  $stringPlugins = ConvertTo-StringArraySafe $cfg['plugin']
  $invalidCount = 0
  foreach ($item in $rawPluginItems) { if (Test-InvalidPluginObject $item) { $invalidCount++ } }
  if ($invalidCount -gt 0) {
    # 安装器和诊断工具会频繁调用配置修复；对象型插件项可直接清理。
    Write-Color "⚠️ 已清理 $invalidCount 个无效插件对象。" Yellow
    $changed = $true
  }

  # Deduplicate and normalize OMO naming. Keep exactly the configured OMO plugin name.
  # 本包默认使用 oh-my-openagent；其他同类插件名仅在显式配置时保留。
  $omoAliases = @('oh-my-openagent','oh-my-opencode')
  $seen = @{}
  $cleanPlugins = @()
  foreach ($s0 in $stringPlugins) {
    $s = ([string]$s0).Trim()
    if (!$s) { continue }
    if ($RemoveOmoPlugin -and ($omoAliases -contains $s)) { $changed = $true; continue }
    if ($PluginName -and ($omoAliases -contains $s) -and $s -ne $PluginName) { $changed = $true; continue }
    if (!$seen.ContainsKey($s)) {
      $seen[$s] = $true
      $cleanPlugins += $s
    } else {
      $changed = $true
    }
  }

  if (!$RemoveOmoPlugin -and $PluginName) {
    if (!$seen.ContainsKey($PluginName)) {
      $cleanPlugins += $PluginName
      $seen[$PluginName] = $true
      $changed = $true
    }
  }

  $newPlugins = [string[]]@($cleanPlugins)
  $oldPluginJson = if ($hadPlugin) { try { ($cfg['plugin'] | ConvertTo-Json -Depth 20 -Compress) } catch { "" } } else { "" }
  $newPluginJson = try { ($newPlugins | ConvertTo-Json -Depth 20 -Compress) } catch { "" }
  if ($newPlugins.Count -gt 0) {
    if (!$hadPlugin -or $oldPluginJson -ne $newPluginJson) { $changed = $true }
    $cfg['plugin'] = @($newPlugins)
  } else {
    if ($cfg.ContainsKey('plugin')) { [void]$cfg.Remove('plugin'); $changed = $true }
  }

  # Guard against a corrupted provider field from accidental array/object serialization.
  if ($cfg.ContainsKey('providers') -and !$cfg.ContainsKey('provider')) {
    # Some tools call the internal endpoint config.providers, but the actual user config key is provider.
    # Do not attempt to convert an unknown providers object automatically; just remove the invalid key.
    [void]$cfg.Remove('providers')
    $changed = $true
  }

  if ($changed) {
    Write-OpenCodeConfigHashtable $cfg $configFile
    Write-Color "✅ 已修复 opencode.json 的插件/配置结构。" Green
  }
  return $cfg
}

function Ensure-OpenCodePlugin([string]$PluginName) {
  $cfg = Repair-OpenCodeConfigFile -PluginName $PluginName
  Write-Color "✅ 已在配置中启用 OpenCode 插件： $PluginName" Green
  return $cfg
}


function Get-PreferredModelFromEnvNames([string[]]$Names) {
  $set = @{}
  foreach ($n in $Names) { if ($n) { $set[$n.ToUpperInvariant()] = $true } }
  if ($set.ContainsKey('OPENROUTER_API_KEY')) { return 'openrouter/anthropic/claude-sonnet-4.5' }
  if ($set.ContainsKey('DEEPSEEK_API_KEY')) { return 'deepseek/deepseek-chat' }
  if ($set.ContainsKey('OPENAI_API_KEY')) { return 'openai/gpt-4.1' }
  if ($set.ContainsKey('MOONSHOT_API_KEY')) { return 'moonshot/moonshot-v1-32k' }
  if ($set.ContainsKey('SILICONFLOW_API_KEY')) { return 'siliconflow/deepseek-ai/DeepSeek-V3' }
  if ($set.ContainsKey('DASHSCOPE_API_KEY')) { return 'dashscope/qwen-plus' }
  if ($set.ContainsKey('ZHIPUAI_API_KEY')) { return 'zhipu/glm-4-flash' }
  return ''
}

function Get-PreferredRuntimeModelFromEnv {
  $names = @()
  foreach ($n in @('OPENROUTER_API_KEY','DEEPSEEK_API_KEY','OPENAI_API_KEY','MOONSHOT_API_KEY','SILICONFLOW_API_KEY','DASHSCOPE_API_KEY','ZHIPUAI_API_KEY')) {
    if ([Environment]::GetEnvironmentVariable($n,'Process')) { $names += $n }
  }
  return (Get-PreferredModelFromEnvNames $names)
}

function Ensure-ProviderConfigForEnvNames {
  param([string[]]$EnvNames)

  $nameSet = @{}
  foreach ($n in $EnvNames) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $nameSet[$n.Trim().ToUpperInvariant()] = $true
  }

  $configFile = Get-OpenCodeConfigPath
  $omoPluginForProviderEdit = ''
  if ((ConfBool 'INSTALL_OMO' $true) -or (Get-InstalledOmoPackage)) { $omoPluginForProviderEdit = Get-OmoPluginName }
  if ($omoPluginForProviderEdit) { $cfg = Repair-OpenCodeConfigFile -PluginName $omoPluginForProviderEdit } else { $cfg = Repair-OpenCodeConfigFile }
  $changed = $false
  if (!$cfg.ContainsKey('provider') -or $null -eq $cfg['provider'] -or !($cfg['provider'] -is [System.Collections.IDictionary])) {
    $cfg['provider'] = @{}
    $changed = $true
  }
  $providers = $cfg['provider']

  function Add-OpenAICompatibleProviderPreset([string]$Id,[string]$Name,[string]$BaseUrl,[string]$EnvName,[hashtable]$Models) {
    if (!$nameSet.ContainsKey($EnvName.ToUpperInvariant())) { return }
    if (!$providers.ContainsKey($Id) -or $null -eq $providers[$Id] -or !($providers[$Id] -is [System.Collections.IDictionary])) {
      $providers[$Id] = @{}
      $script:__ProviderCfgChanged = $true
    }
    $p = $providers[$Id]
    if (!$p.ContainsKey('npm') -or [string]::IsNullOrWhiteSpace([string]$p['npm'])) { $p['npm'] = '@ai-sdk/openai-compatible'; $script:__ProviderCfgChanged = $true }
    if (!$p.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$p['name'])) { $p['name'] = $Name; $script:__ProviderCfgChanged = $true }
    if (!$p.ContainsKey('options') -or $null -eq $p['options'] -or !($p['options'] -is [System.Collections.IDictionary])) { $p['options'] = @{}; $script:__ProviderCfgChanged = $true }
    if (!$p['options'].ContainsKey('baseURL') -or [string]::IsNullOrWhiteSpace([string]$p['options']['baseURL'])) { $p['options']['baseURL'] = $BaseUrl; $script:__ProviderCfgChanged = $true }
    if (!$p['options'].ContainsKey('apiKey') -or [string]::IsNullOrWhiteSpace([string]$p['options']['apiKey'])) { $p['options']['apiKey'] = "{env:$EnvName}"; $script:__ProviderCfgChanged = $true }
    if (!$p.ContainsKey('models') -or $null -eq $p['models'] -or !($p['models'] -is [System.Collections.IDictionary]) -or $p['models'].Count -eq 0) { $p['models'] = $Models; $script:__ProviderCfgChanged = $true }
  }

  $script:__ProviderCfgChanged = $false
  Add-OpenAICompatibleProviderPreset 'deepseek' 'DeepSeek' 'https://api.deepseek.com/v1' 'DEEPSEEK_API_KEY' @{ 'deepseek-chat'=@{ name='DeepSeek Chat' }; 'deepseek-reasoner'=@{ name='DeepSeek Reasoner' } }
  Add-OpenAICompatibleProviderPreset 'openrouter' 'OpenRouter' 'https://openrouter.ai/api/v1' 'OPENROUTER_API_KEY' @{ 'anthropic/claude-sonnet-4.5'=@{ name='Claude Sonnet 4.5 via OpenRouter' }; 'openai/gpt-4.1'=@{ name='GPT 4.1 via OpenRouter' }; 'google/gemini-2.5-pro'=@{ name='Gemini 2.5 Pro via OpenRouter' } }
  Add-OpenAICompatibleProviderPreset 'openai' 'OpenAI' 'https://api.openai.com/v1' 'OPENAI_API_KEY' @{ 'gpt-4.1'=@{ name='GPT 4.1' }; 'gpt-4.1-mini'=@{ name='GPT 4.1 Mini' } }
  Add-OpenAICompatibleProviderPreset 'moonshot' 'Moonshot/Kimi' 'https://api.moonshot.cn/v1' 'MOONSHOT_API_KEY' @{ 'moonshot-v1-8k'=@{ name='Moonshot v1 8K' }; 'moonshot-v1-32k'=@{ name='Moonshot v1 32K' }; 'moonshot-v1-128k'=@{ name='Moonshot v1 128K' } }
  Add-OpenAICompatibleProviderPreset 'siliconflow' 'SiliconFlow' 'https://api.siliconflow.cn/v1' 'SILICONFLOW_API_KEY' @{ 'deepseek-ai/DeepSeek-V3'=@{ name='DeepSeek V3' }; 'deepseek-ai/DeepSeek-R1'=@{ name='DeepSeek R1' } }
  Add-OpenAICompatibleProviderPreset 'dashscope' 'DashScope Compatible' 'https://dashscope.aliyuncs.com/compatible-mode/v1' 'DASHSCOPE_API_KEY' @{ 'qwen-plus'=@{ name='Qwen Plus' }; 'qwen-max'=@{ name='Qwen Max' }; 'qwen-turbo'=@{ name='Qwen Turbo' } }
  Add-OpenAICompatibleProviderPreset 'zhipu' 'Zhipu GLM Compatible' 'https://open.bigmodel.cn/api/paas/v4' 'ZHIPUAI_API_KEY' @{ 'glm-4-flash'=@{ name='GLM-4 Flash' }; 'glm-4-plus'=@{ name='GLM-4 Plus' }; 'glm-4-air'=@{ name='GLM-4 Air' } }

  if ($script:__ProviderCfgChanged) { $changed = $true }
  Remove-Variable __ProviderCfgChanged -Scope Script -ErrorAction SilentlyContinue

  $preferredModel = Get-PreferredModelFromEnvNames $EnvNames
  if ($preferredModel) {
    if (!$cfg.ContainsKey('model') -or [string]::IsNullOrWhiteSpace([string]$cfg['model'])) { $cfg['model'] = $preferredModel; $changed = $true }
    if (!$cfg.ContainsKey('small_model') -or [string]::IsNullOrWhiteSpace([string]$cfg['small_model'])) { $cfg['small_model'] = $preferredModel; $changed = $true }
  }

  if ($changed) {
    Write-OpenCodeConfigHashtable $cfg $configFile
    Write-Color "✅ 已根据密钥预设更新 provider/model 配置。" Green
  } else {
    Write-Color "ℹ️ 不需要更新 provider 预设。" DarkGray
  }
  return $cfg
}

function Ensure-ProviderConfigFromLoadedEnv {
  # 仅保留给手动排查使用；启动.cmd 不会调用此函数。
  $names = @()
  foreach ($n in @('OPENROUTER_API_KEY','DEEPSEEK_API_KEY','OPENAI_API_KEY','MOONSHOT_API_KEY','SILICONFLOW_API_KEY','DASHSCOPE_API_KEY','ZHIPUAI_API_KEY')) {
    if ([Environment]::GetEnvironmentVariable($n,'Process')) { $names += $n }
  }
  return (Ensure-ProviderConfigForEnvNames $names)
}

function New-OmoRouteConfigText([string]$Model) {
  throw "本便携包不再生成 OMO 路由配置文件；请运行 安装.cmd 调用 OMO 官方安装器。"
}

function Test-OmoConfigLooksEmpty([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return $true }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $noSpace = ($raw -replace '\s','')
  return ($noSpace -eq '' -or $noSpace -eq '{}')
}

function Ensure-OmoConfigFile {
  Write-Color "ℹ️ 本便携包不生成 OMO 路由配置文件；路由配置由 OMO 官方安装器/配置文件管理。" DarkGray
  return $null
}

function Test-OmoCliCandidate([string]$Path, [string]$PackageName, [string]$RootDir) {
  if (!(Test-Path -LiteralPath $Path)) { return $false }
  if ($RootDir -and $PackageName) {
    $pkgDir = Join-Path (Join-Path $RootDir "node_modules") $PackageName
    if ($Path -like (Join-Path $RootDir "*") -and !(Test-Path -LiteralPath $pkgDir)) { return $false }
  }
  return $true
}

function Get-OmoCliPath([string]$PackageName) {
  $names = @($PackageName, 'oh-my-openagent', 'oh-my-opencode') | Where-Object { $_ } | Select-Object -Unique
  foreach ($n in $names) {
    # 优先使用 config\opencode 下的依赖。这样即使删除 npm-global\node_modules，
    # OMO 插件和 doctor 仍可从便携配置目录中运行。
    foreach ($p in @(
      (Join-Path $ConfigDir "node_modules\.bin\$n.cmd"),
      (Join-Path $ConfigDir "node_modules\$n\bin\$n.exe"),
      (Join-Path $ConfigDir "node_modules\$n\bin\oh-my-opencode.exe"),
      (Join-Path $ConfigDir "node_modules\$n\bin\oh-my-openagent.exe")
    )) { if (Test-OmoCliCandidate $p $n $ConfigDir) { return $p } }

    # npm-global 只作为安装/更新时的兼容兜底。若 node_modules 被瘦身删除，
    # 根目录遗留的 .cmd shim 会失效，这里会自动跳过。
    foreach ($p in @(
      (Join-Path $NpmGlobalDir "$n.cmd"),
      (Join-Path $NpmGlobalDir "node_modules\.bin\$n.cmd"),
      (Join-Path $NpmGlobalDir "node_modules\$n\bin\$n.exe"),
      (Join-Path $NpmGlobalDir "node_modules\$n\bin\oh-my-opencode.exe"),
      (Join-Path $NpmGlobalDir "node_modules\$n\bin\oh-my-openagent.exe")
    )) { if (Test-OmoCliCandidate $p $n $NpmGlobalDir) { return $p } }
  }
  return ''
}


function Ensure-OmoPackageJsonDependency([string]$PackageName) {
  if (!$PackageName) { return }
  $pkgJson = Join-Path $ConfigDir "package.json"
  $pkg = @{}
  if (Test-Path -LiteralPath $pkgJson) {
    try { $pkg = ConvertTo-HashtableDeep (Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $pkg = @{} }
  }
  if (!$pkg.ContainsKey('dependencies') -or $null -eq $pkg['dependencies'] -or !($pkg['dependencies'] -is [System.Collections.IDictionary])) { $pkg['dependencies'] = @{} }
  $deps = $pkg['dependencies']
  $changed = $false
  if (!$deps.ContainsKey($PackageName)) { $deps[$PackageName] = 'latest'; $changed = $true }
  # OMO/OpenAgent imports the OpenCode 插件 SDK. Keeping this dependency in the portable
  # config package.json matches the self-repaired working setup and helps OpenCode resolve
  # the plugin from config\opencode when the official installer refreshes node_modules.
  if (!$deps.ContainsKey('@opencode-ai/plugin')) { $deps['@opencode-ai/plugin'] = 'latest'; $changed = $true }
  if (!$deps.ContainsKey('@code-yeongyu/comment-checker')) { $deps['@code-yeongyu/comment-checker'] = 'latest'; $changed = $true }
  if ($changed -or !(Test-Path -LiteralPath $pkgJson)) {
    ($pkg | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $pkgJson -Encoding UTF8
    Write-Color "✅ 已确保便携配置 package.json 依赖：$PackageName、@opencode-ai/plugin、@code-yeongyu/comment-checker" Green
  }
}

function Ensure-TuiPluginConfig([string]$PluginName) {
  if (!$PluginName) { return }
  $tuiFile = Join-Path $ConfigDir "tui.json"
  $tui = @{}
  if (Test-Path -LiteralPath $tuiFile) {
    try { $tui = ConvertTo-HashtableDeep (Get-Content -LiteralPath $tuiFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {
      $bak = $tuiFile + ".bad-json-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
      Copy-Item -LiteralPath $tuiFile -Destination $bak -Force
      Write-Color "⚠️ tui.json 无法解析，已备份：$bak" Yellow
      $tui = @{}
    }
  }
  if ($null -eq $tui -or !($tui -is [System.Collections.IDictionary])) { $tui = @{} }
  $pluginEntry = "$PluginName/tui"
  $raw = if ($tui.ContainsKey('plugin') -and $null -ne $tui['plugin']) { if ($tui['plugin'] -is [System.Array]) { @($tui['plugin']) } else { @($tui['plugin']) } } else { @() }
  $seen = @{}
  $clean = New-Object System.Collections.Generic.List[string]
  foreach ($item in $raw) {
    if ($item -is [string]) {
      $s = $item.Trim()
      if ($s -and !$seen.ContainsKey($s)) { $seen[$s] = $true; $clean.Add($s) }
    }
  }
  if (!$seen.ContainsKey($pluginEntry)) { $clean.Add($pluginEntry) }
  $tui['plugin'] = @($clean)
  ($tui | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $tuiFile -Encoding UTF8
  Write-Color "✅ 已在 tui.json 启用 TUI 插件：$pluginEntry" Green
}

function Ensure-PortableConfigNodeDependencies([string]$Reason='OMO portable config dependencies') {
  $npm = Resolve-Cmd "npm.cmd" $false; if(!$npm){ $npm = Resolve-Cmd "npm" $true }
  $reg = Conf "NPM_REGISTRY" "https://registry.npmjs.org"
  if (!(Test-Path (Join-Path $ConfigDir "package.json"))) { return $false }
  Write-Color "📦 正在安装/更新便携配置目录的 node 依赖（$Reason）..." Cyan
  $args = @("install","--prefix",$ConfigDir,"--registry=$reg","--foreground-scripts","--loglevel=notice","--no-audit","--no-fund")
  $res = Invoke-NativeCapture -File $npm -Arguments $args -TimeoutSeconds (ConfInt "NPM_PACKAGE_TIMEOUT_SECONDS" 900) -AllowFailure
  if ($res.Output) { Write-Host $res.Output }
  if ($res.ExitCode -ne 0) { Write-Color "⚠️ 便携配置 npm install 返回退出码 $($res.ExitCode)." Yellow; return $false }
  return $true
}

function Ensure-CommentCheckerInstalled([bool]$Force=$false) {
  $okGlobal = Install-NpmPackageIfNeeded '@code-yeongyu/comment-checker@latest' '@code-yeongyu/comment-checker' 'Comment checker' $Force
  $checkerBinCandidates = @(
    (Join-Path $NpmGlobalDir 'comment-checker.cmd'),
    (Join-Path $NpmGlobalDir 'node_modules\.bin\comment-checker.cmd'),
    (Join-Path $ConfigDir 'node_modules\.bin\comment-checker.cmd'),
    (Join-Path $ConfigDir 'node_modules\@code-yeongyu\comment-checker\vendor\win32-x64\comment-checker.exe')
  )
  foreach ($p in $checkerBinCandidates) {
    if (Test-Path -LiteralPath $p) { Write-Color "✅ Comment checker 可用： $p" Green; return $true }
  }
  if ($okGlobal) { Write-Color "⚠️ Comment checker 包已安装，但未在预期路径找到二进制文件。" Yellow } else { Write-Color "⚠️ Comment checker 安装失败。" Yellow }
  return $false
}

function Test-OmoConfigPluginPresent([string]$PluginName) {
  $configFile = Get-OpenCodeConfigPath
  if (!(Test-Path -LiteralPath $configFile)) { return $false }
  $raw = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
  try {
    $cfg = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    if ($cfg -is [System.Collections.IDictionary] -and $cfg.ContainsKey('plugin') -and $null -ne $cfg['plugin']) {
      foreach ($p in (ConvertTo-StringArraySafe $cfg['plugin'])) {
        if ($p -eq $PluginName) { return $true }
      }
    }
  } catch {}

  # 保底：如果 JSON 类型转换在某些 PowerShell 环境中异常，直接从文本确认插件字符串是否存在。
  $escaped = [regex]::Escape($PluginName)
  return ($raw -match '"plugin"\s*:\s*\[' -and $raw -match ('"' + $escaped + '"'))
}

function Get-OmoDoctorCliPath {
  $pkg = Get-InstalledOmoPackage
  if (!$pkg) { $pkg = Get-OmoPackageName }
  return (Get-OmoCliPath $pkg)
}

function Invoke-OmoDoctorIfAvailable {
  if (!(ConfBool 'OMO_RUN_DOCTOR' $false)) { return }
  $cli = Get-OmoDoctorCliPath
  if (!$cli) { Write-Color '⚠️ 已跳过 OMO doctor：未找到 CLI。' Yellow; return }
  Write-Color "🩺 正在运行 OMO doctor： $cli" Cyan
  $res = Invoke-NativeCapture -File $cli -Arguments @('doctor') -TimeoutSeconds (ConfInt 'OMO_DOCTOR_TIMEOUT_SECONDS' 180) -AllowFailure
  if ($res.Output) { Write-Host $res.Output }
  if ($res.ExitCode -ne 0) { Write-Color "⚠️ OMO doctor 返回退出码 $($res.ExitCode)。" Yellow }
}

function Invoke-OmoInstallerIfAvailable([string]$PackageName) {
  if (!(ConfBool 'OMO_RUN_INSTALLER' $true)) { return }
  $cli = Get-OmoCliPath $PackageName
  if (!$cli) { Write-Color '⚠️ 未找到 OMO CLI；只会配置 opencode.json 插件项。' Yellow; return }
  Write-Color "🤖 正在便携环境中运行 OMO 官方安装器： $cli" Cyan
  # Keep this in install/update, not run.  The installer is the only place that may create
  # OMO 自己的 json/jsonc 配置文件；启动.cmd 不生成也不改写它们。
  $args = @(
    'install','--no-tui',
    '--claude=no','--openai=no','--gemini=no','--copilot=no',
    '--opencode-go=no','--opencode-zen=no','--zai-coding-plan=no',
    '--kimi-for-coding=no','--vercel-ai-gateway=no','--skip-auth'
  )
  $res = Invoke-NativeCapture -File $cli -Arguments $args -TimeoutSeconds (ConfInt 'OMO_INSTALLER_TIMEOUT_SECONDS' 360) -AllowFailure
  if ($res.Output) { Write-Host $res.Output }
  if ($res.ExitCode -ne 0) { Write-Color "⚠️ OMO 安装器返回 $($res.ExitCode). 仍会强制写入 opencode.json 插件项。" Yellow }
}


function Test-PackDefaultOpenCodeConfig([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return $true }
  try {
    $cfg = ConvertTo-HashtableDeep (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($null -eq $cfg -or !($cfg -is [System.Collections.IDictionary])) { return $false }
    foreach ($k in $cfg.Keys) {
      if (@('$schema','plugin') -notcontains [string]$k) { return $false }
    }
    $plugins = ConvertTo-StringArraySafe $cfg['plugin']
    if ($plugins.Count -eq 0) { return $true }
    if ($plugins.Count -eq 1 -and $plugins[0] -eq (Get-OmoPluginName)) { return $true }
    return $false
  } catch {
    return $false
  }
}

function Test-TuiPluginPresent([string]$PluginName) {
  if (!$PluginName) { return $false }
  $tuiFile = Join-Path $ConfigDir "tui.json"
  if (!(Test-Path -LiteralPath $tuiFile)) { return $false }
  try {
    $tui = ConvertTo-HashtableDeep (Get-Content -LiteralPath $tuiFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($null -eq $tui -or !($tui -is [System.Collections.IDictionary])) { return $false }
    $entry = "$PluginName/tui"
    foreach ($p in (ConvertTo-StringArraySafe $tui['plugin'])) {
      if ($p -eq $entry) { return $true }
    }
  } catch {}
  return $false
}

function Test-OmoRouteConfigPresent {
  $base = Get-OmoConfigBaseName
  foreach ($name in @("$base.jsonc","$base.json","oh-my-openagent.jsonc","oh-my-openagent.json","oh-my-opencode.jsonc","oh-my-opencode.json")) {
    if (Test-Path -LiteralPath (Join-Path $ConfigDir $name)) { return $true }
  }
  return $false
}

function Ensure-OmoInstalledAndConfigured([bool]$Force=$false) {
  if (!(ConfBool "INSTALL_OMO" $true)) { Write-Color "  [跳过] INSTALL_OMO=0，已跳过 OMO。" Yellow; return $false }

  $primary = Get-OmoPackageName
  $pluginName = Get-OmoPluginName
  $ok = Install-NpmPackageIfNeeded "$primary@latest" $primary "OMO" $Force
  $pkg = if($ok -and (Get-LocalNpmPackageVersion $primary)) { $primary } else { "" }

  if (!$pkg -and $primary -ne 'oh-my-opencode') {
    Write-Color "⚠️ 首选 OMO 包失败或未找到，尝试备用包 oh-my-opencode。" Yellow
    $ok2 = Install-NpmPackageIfNeeded 'oh-my-opencode@latest' 'oh-my-opencode' 'OMO 备用包' $Force
    if ($ok2 -and (Get-LocalNpmPackageVersion 'oh-my-opencode')) { $pkg = 'oh-my-opencode' }
  }

  # Per upstream docs during the rename transition, opencode.json should prefer
  # the plugin entry oh-my-openagent even though the CLI binary/package compatibility
  # layer may still expose oh-my-opencode.
  if (!$pluginName) { $pluginName = 'oh-my-openagent' }

  if ($pkg) {
    $isUpdateMode = ($env:OPK_INSTALL_MODE -eq 'update')
    $alreadyHealthy = ((Test-OmoConfigPluginPresent $pluginName) -and (Test-TuiPluginPresent $pluginName) -and (Test-OmoRouteConfigPresent))
    Ensure-OmoPackageJsonDependency $pkg
    Ensure-PortableConfigNodeDependencies 'OMO 插件 SDK 与 comment-checker' | Out-Null
    if ($isUpdateMode -and !$Force -and $alreadyHealthy) {
      Write-Color "✅ OMO 配置已完整，更新模式跳过官方安装器重复写入。" Green
    } else {
      Invoke-OmoInstallerIfAvailable $pkg
    }
    Ensure-OpenCodePlugin $pluginName | Out-Null
    Ensure-TuiPluginConfig $pluginName
    Ensure-OmoPackageJsonDependency $pkg
    Ensure-PortableConfigNodeDependencies '安装器执行后的依赖同步' | Out-Null
    Ensure-CommentCheckerInstalled $Force | Out-Null
    Invoke-OmoDoctorIfAvailable
    if (!(Test-OmoConfigPluginPresent $pluginName)) {
      Write-Color "⚠️ 首次验证未看到 OMO 插件，正在强制再修复一次 opencode.json..." Yellow
      [void](Repair-OpenCodeConfigFile -PluginName $pluginName)
    }
    if (Test-OmoConfigPluginPresent $pluginName) {
      Write-Color "✅ OMO 已安装并启用：包 '$pkg'，OpenCode 插件 '$pluginName'。" Green
    } else {
      Write-Color "⚠️ OMO 包已安装，但插件 '$pluginName' 修复后仍未出现在 opencode.json 中。请检查 config\opencode\opencode.json。" Yellow
      return $false
    }
    return $true
  }
  Write-Color "⚠️ OMO 未安装。启动.cmd 仍可运行，但 OMO agent/插件不会加载。" Yellow
  return $false
}

Apply-PortableEnvironment


function Read-OpenCodeConfigHashtable {
  $configFile = Get-OpenCodeConfigPath
  # 仅修复异常插件数组，不主动添加 OMO。
  return (Repair-OpenCodeConfigFile)
}

function Remove-OmoPluginEntriesFromConfigObject([hashtable]$Cfg) {
  if (!$Cfg.ContainsKey('plugin') -or $null -eq $Cfg['plugin']) { return }
  $rawPlugins = if ($Cfg['plugin'] -is [System.Array]) { @($Cfg['plugin']) } else { @($Cfg['plugin']) }
  $kept = @()
  foreach ($item in $rawPlugins) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      $s = $item.Trim()
      if (!$s) { continue }
      if ($s -eq 'oh-my-openagent' -or $s -eq 'oh-my-opencode') { continue }
      $kept += $s
      continue
    }
    # 清理非字符串插件项，例如 {Length:...} 对象。
    continue
  }
  if ($kept.Count -gt 0) { $Cfg['plugin'] = @($kept) } else { [void]$Cfg.Remove('plugin') }
}


function New-IsolatedRuntimeConfigDir {
  param([string]$Name="runtime")
  $runtimeDir = Join-Path $StateDir $Name
  $runtimeConfigDir = Join-Path $runtimeDir "config"
  New-Item -ItemType Directory -Force -Path $runtimeConfigDir | Out-Null
  return $runtimeConfigDir
}

function Set-IsolatedRuntimeConfigEnv {
  param([string]$RuntimeConfigDir, [string]$RuntimeConfigFile)
  $env:OPENCODE_CONFIG_DIR = $RuntimeConfigDir
  $env:OPENCODE_CONFIG = $RuntimeConfigFile

  # Keep OpenCode away from any real/user config discovery path for this run.
  # These extra variables are harmless if OpenCode ignores them, and useful for tools
  # that follow XDG conventions.
  $env:XDG_CONFIG_HOME = Join-Path (Split-Path -Parent $RuntimeConfigDir) "xdg-config"
  New-Item -ItemType Directory -Force -Path $env:XDG_CONFIG_HOME | Out-Null
}

function New-MinimalRuntimeOpenCodeConfig {
  param([string]$Name="runtime-empty")
  $runtimeConfigDir = New-IsolatedRuntimeConfigDir $Name
  $runtimeConfig = Join-Path $runtimeConfigDir "opencode.json"

  # Deliberately do NOT copy the user's opencode.json here.
  # Some configs can contain provider/agent/plugin/plugin-object entries or companion
  # oh-my-openagent files that still affect startup even after partial sanitizing.
  # This minimal config is only for this single process.
  $minimal = [ordered]@{
    '$schema' = 'https://opencode.ai/config.json'
  }
  ($minimal | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $runtimeConfig -Encoding UTF8
  Set-IsolatedRuntimeConfigEnv -RuntimeConfigDir $runtimeConfigDir -RuntimeConfigFile $runtimeConfig
  return $runtimeConfig
}

function New-RuntimeOpenCodeConfig {
  param(
    [switch]$DisableOmo,
    [switch]$NoSecrets
  )

  if ($NoSecrets) {
    # No API keys loaded: use a completely isolated minimal config.  Do not copy the
    # real config, because OpenCode/OMO startup can still evaluate agent/provider
    # metadata from leftover keys or companion config files.
    return New-MinimalRuntimeOpenCodeConfig "runtime-no-secrets"
  }

  $cfg = Read-OpenCodeConfigHashtable
  if (!$cfg.ContainsKey('$schema')) { $cfg['$schema'] = 'https://opencode.ai/config.json' }

  if ($DisableOmo) {
    Remove-OmoPluginEntriesFromConfigObject $cfg
    foreach ($key in @('agent','agents')) {
      if ($cfg.ContainsKey($key)) { [void]$cfg.Remove($key) }
    }
  }

  $runtimeConfigDir = New-IsolatedRuntimeConfigDir "runtime-config-copy"
  $runtimeConfig = Join-Path $runtimeConfigDir "opencode.json"
  ($cfg | ConvertTo-Json -Depth 80) | Set-Content -LiteralPath $runtimeConfig -Encoding UTF8
  Set-IsolatedRuntimeConfigEnv -RuntimeConfigDir $runtimeConfigDir -RuntimeConfigFile $runtimeConfig
  return $runtimeConfig
}

function Get-EnvReferencesFromConfigFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return @() }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $matches = [regex]::Matches($raw, '\{env:([A-Za-z_][A-Za-z0-9_]*)\}')
  $set = @{}
  foreach ($m in $matches) { $set[$m.Groups[1].Value] = $true }
  return @($set.Keys | Sort-Object)
}

function Get-MissingEnvReferencesFromConfigFile([string]$Path) {
  $missing = @()
  foreach ($name in (Get-EnvReferencesFromConfigFile $Path)) {
    $v = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ([string]::IsNullOrWhiteSpace($v)) { $missing += $name }
  }
  return @($missing)
}
