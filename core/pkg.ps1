# core\pkg.ps1 —— 分层：core 层（零 UI 依赖）
#
# 包根识别 / 结构快照 / 漂移比对 / 版本与必需件校验。零 UI 依赖。
# 由 EdgePanel.ps1 搬入，函数体保持原样（move-only）。
function Get-PkgSnapshot([string]$edgeDir, [string]$scope = '') {
    # 只记文件（不记目录、不记 mtime）；版本目录名归一化成 {ver}
    $map = @{}
    $verName = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $edgeDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^\d+\.\d+\.\d+\.\d+$') { $verName = $d.Name; break }
    }
    $sum = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $edgeDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($edgeDir.Length).TrimStart('\')
        if ($verName -and $rel.StartsWith($verName + '\')) { $rel = '{ver}\' + $rel.Substring($verName.Length + 1) }
        if ($rel -match '^\d+\.\d+\.\d+\.\d+\.manifest$') { $rel = '{ver}.manifest' }
        $map[$rel] = [long]$f.Length
        $sum += [long]$f.Length
    }
    $normScope = if ([string]::IsNullOrWhiteSpace($scope)) { $edgeDir } else { $scope }
    return @{ version = $verName; files = $map; total = $sum; scope = $normScope.TrimEnd('\') }
}

function Save-PkgSnapshot($snap, [string]$path) {
    [ordered]@{ version = $snap.version; scope = $snap.scope; taken_at = (Get-Date).ToString('s'); total_bytes = $snap.total; files = $snap.files } |
        ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
}

function Test-StructureDrift([string]$edgeDir, [string]$scope = '') {
    $snapPath = Join-Path (Get-RuntimeCacheDir) 'last_pkg_snapshot.json'
    $new = Get-PkgSnapshot $edgeDir $scope
    if (-not (Test-Path -LiteralPath $snapPath)) {
        Write-Log ('结构基线：首次记录 ' + $new.files.Count + ' 个文件 / ' + [math]::Round($new.total / 1MB, 1) + ' MB（下次更新起比对）')
        return $new     # 由调用方在覆盖成功后才落盘（回滚时基线不跟着跑偏）
    }
    $old = $null
    try { $old = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json } catch { }
    if (-not $old -or -not $old.files) {
        Write-Log '结构基线文件损坏，将在本次更新成功后被重写（本次不比对）' 'warn'
        return $new
    }
    # 基线必须来自「同一个上游包目录」才有可比性：自测夹具、换机、换盘后路径都会变，
    # 拿旧基线硬比只会刷出一屏假的"结构变化"（实测踩到：基线是 11-21 自测用的 160.0.4408.0 假包）。
    $oldScope = ([string]$old.scope).TrimEnd('\')
    if (-not $oldScope -or ($oldScope -ine $new.scope)) {
        $why = if (-not $oldScope) { '旧格式基线没有来源标记' } else { '基线来自 ' + $oldScope }
        Write-Log ('结构基线不可比对（' + $why + '），已重建（本次不比对）')
        return $new
    }
    $oldFiles = @{}
    foreach ($pv in $old.files.PSObject.Properties) { $oldFiles[$pv.Name] = [long]$pv.Value }
    $oldTotal = [long]$old.total_bytes
    $added = @($new.files.Keys | Where-Object { -not $oldFiles.ContainsKey($_) } |
        ForEach-Object { [pscustomobject]@{ p = $_; mb = [math]::Round($new.files[$_] / 1MB, 2) } } | Sort-Object mb -Descending)
    $removed = @($oldFiles.Keys | Where-Object { -not $new.files.ContainsKey($_) } | Sort-Object)
    $changed = @($new.files.Keys | Where-Object { $oldFiles.ContainsKey($_) -and [math]::Abs($new.files[$_] - $oldFiles[$_]) -gt 1MB } |
        ForEach-Object { [pscustomobject]@{ p = $_; mb = [math]::Round(($new.files[$_] - $oldFiles[$_]) / 1MB, 2) } } |
        Sort-Object { [math]::Abs($_.mb) } -Descending)
    $pct = 0
    $pctTxt = '基线过小，不计百分比'
    if ($oldTotal -ge 1MB) {
        $pct = [math]::Round(($new.total - $oldTotal) / $oldTotal * 100, 2)
        $pctTxt = [string]$pct + '%'
    }
    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0) { return $new }   # 同结构：静默
    $bigAdd = @($added | Where-Object { $_.mb -ge 20 })
    $lvl = if ($bigAdd.Count -gt 0 -or $pct -ge 5) { 'err' } else { 'warn' }
    Write-Log ('上游包结构变化：新增 ' + $added.Count + ' / 消失 ' + $removed.Count + ' / 体积变化>1MB ' + $changed.Count +
        '；总量 ' + [math]::Round($oldTotal / 1MB, 1) + ' → ' + [math]::Round($new.total / 1MB, 1) + ' MB（' + $pctTxt + '）') $lvl
    foreach ($a in @($added | Select-Object -First 5)) { Write-Log ('  + ' + $a.p + '  ' + $a.mb + ' MB') $lvl }
    if ($added.Count -gt 5) { Write-Log ('  …另有 ' + ($added.Count - 5) + ' 个新增条目') $lvl }
    foreach ($r in @($removed | Select-Object -First 5)) { Write-Log ('  - ' + $r) $lvl }
    if ($removed.Count -gt 5) { Write-Log ('  …另有 ' + ($removed.Count - 5) + ' 个消失条目') $lvl }
    foreach ($c in @($changed | Select-Object -First 5)) { Write-Log ('  ~ ' + $c.p + '  ' + $c.mb + ' MB') $lvl }
    if (@($added | Where-Object { $_.p -like '*msedge_renderer.dll' }).Count -gt 0) {
        Write-Log '上游包里有 msedge_renderer.dll（你已删除它；若更新后它又出现，用「一键瘦身」再删一次）' 'warn'
    }
    return $new   # 有变化时也要把新快照交给调用方落盘，否则永远拿旧基线重复报警
}

function Test-SafeDeployDir([string]$dir) {
    # 仅允许空目录，或仅含面板 EXE / 本面板备份包 / Data / Cache 的目录执行全新部署，防止把 Edge 铺进杂乱目录
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return @{ Ok = $false; Others = @('目录不存在') } }
    $others = New-Object System.Collections.ArrayList
    foreach ($it in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($it.PSIsContainer) {
            if ($it.Name -ieq 'Data' -or $it.Name -ieq 'Cache') { continue }
            [void]$others.Add($it.Name + '\')
        } else {
            $selfN = if ($env:EP_EXEPATH) { Split-Path -Leaf $env:EP_EXEPATH } else { '' }
            if (($it.Name -match $script:panelExeNameRe) -or ($selfN -and $it.Name -ieq $selfN) -or ($it.Name -match '^(?i)Edge_Portable_.*\.(7z|zip)$')) { continue }
            [void]$others.Add($it.Name)
        }
    }
    return @{ Ok = ($others.Count -eq 0); Others = @($others) }
}

function Get-LocalVersion {
    $exe = Join-Path $edgeRoot 'msedge.exe'
    if (Test-Path -LiteralPath $exe) { return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } else { return '未安装' }
}

function Test-EssentialSet([string]$edgeDir) {
    # 只读检查，返回缺项清单：Required=必需（缺了就起不来） / Feature=功能件（缺了某功能不可用）
    $req = New-Object System.Collections.Generic.List[string]
    $feat = New-Object System.Collections.Generic.List[string]
    $verDir = Resolve-VersionDir $edgeDir -AllowIncomplete
    $verName = if ($verDir) { Split-Path $verDir -Leaf } else { '' }
    foreach ($t in $script:essentialRequired) {
        $rel = if ($verName) { $t -replace '\{ver\}', $verName } else { $t }
        if (-not (Test-Path -LiteralPath (Join-Path $edgeDir $rel))) { $req.Add($rel) }
    }
    if ($verName) {
        foreach ($t in $script:essentialFeature) {
            if ($t -eq 'msedge_proxy.exe') {
                # 快捷方式认包根那份，而上游新包只带 {ver} 那份（更新预检就是在解压出来的上游包上跑）
                # ⇒ 两处有一处即算齐，否则每次更新都会误报"新包功能件缺 1 项"。
                $okProxy = (Test-Path -LiteralPath (Join-Path $edgeDir 'msedge_proxy.exe')) -or (Test-Path -LiteralPath (Join-Path $edgeDir ($verName + '\msedge_proxy.exe')))
                if (-not $okProxy) { $feat.Add('msedge_proxy.exe（包根与版本目录都缺）') }
                continue
            }
            $rel = $t -replace '\{ver\}', $verName
            if (-not (Test-Path -LiteralPath (Join-Path $edgeDir $rel))) { $feat.Add($rel) }
        }
    }
    [pscustomobject]@{ Required = @($req); Feature = @($feat); Ver = $verName }
}

function Test-MsSignature([string]$path) {
    # 判断"是不是微软签过的有效文件"。不单独依赖 Get-AuthenticodeSignature：它靠模块自动加载，
    # 若本进程的 PSModulePath 里混进了 PowerShell 7 的模块目录（例如从 pwsh 7 会话里启动本面板），
    # 5.1 会解析到 PS7 版 Microsoft.PowerShell.Security 并加载失败（实测报"找到命令但无法加载该模块"），
    # 更新预检就会在**下载完 435 MB 之后**中止。这里先试 cmdlet，失败退回纯 .NET 校验。
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($s -and $s.Status -eq 'Valid' -and $s.SignerCertificate -and ($s.SignerCertificate.Subject -match 'Microsoft')) {
            return @{ Ok = $true; Why = 'Authenticode Valid（Microsoft）' }
        }
        return @{ Ok = $false; Why = ('签名状态 ' + $(if ($s) { [string]$s.Status } else { '空' })) }
    } catch {
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($path)
            if (-not $cert) { return @{ Ok = $false; Why = '文件没有签名' } }
            $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = 'NoCheck'   # 离线也能判，避免取吊销列表卡住
            $chainOk = $chain.Build($x)
            if ($chainOk -and ($x.Subject -match 'Microsoft')) { return @{ Ok = $true; Why = ('Microsoft 证书链可信 ' + $x.Thumbprint) } }
            return @{ Ok = $false; Why = ('证书链 ' + $chainOk + ' / ' + $x.Subject) }
        } catch {
            return @{ Ok = $false; Why = ($_.Exception.Message + '（Authenticode 亦不可用）') }
        }
    }
}

function Sync-RootProxy([string]$edgeDir, [switch]$Force) {
    # 站点应用/PWA 快捷方式指向**包根**的 msedge_proxy.exe（Chromium 按运行中 exe 的目录拼出来的），
    # 而上游便携包根从不提供它 ⇒ 默认仅在根上缺失时补齐；传 -Force 时总是用版本目录的新版本刷新。
    # 返回是否真的写入了根文件（调用方不用管日志）。
    $rootProxy = Join-Path $edgeDir 'msedge_proxy.exe'
    if (-not $Force -and (Test-Path -LiteralPath $rootProxy)) { return $false }
    $vd = Resolve-VersionDir $edgeDir -AllowIncomplete
    if (-not $vd) { return $false }
    $src = Join-Path $vd 'msedge_proxy.exe'
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    try {
        Copy-Item -LiteralPath $src -Destination $rootProxy -Force -ErrorAction Stop
        Write-Log '已把 msedge_proxy.exe 放到包根（站点应用/PWA 快捷方式靠它启动）' 'ok'
        return $true
    } catch {
        Write-Log ('包根 msedge_proxy.exe 补齐失败（不影响其它功能）：' + $_.Exception.Message) 'warn'
        return $false
    }
}

function Get-LastPkgFile { return (Join-Path (Get-RuntimeCacheDir) 'last-pkg.txt') }

function Get-LastSavedPkgRoot {
    $f = Get-LastPkgFile
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    try { return ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)).Trim() } catch { return '' }
}

function Save-LastPkgRoot([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    try { [System.IO.File]::WriteAllText((Get-LastPkgFile), $dir.TrimEnd('\'), (New-Object System.Text.UTF8Encoding($false))) } catch { Write-Log ('记住上次目录失败（不影响本次使用）：' + $_.Exception.Message) 'warn' }
}


# ---------------- 包级数据定义（Test-SafeDeployDir / Test-EssentialSet 依赖） ----------------
# 面板 EXE 的合法文件名（用户可能改名成 EdgePanel.exe）：Test-SafeDeployDir 用它放行自身
if (-not $script:panelExeNameRe) { $script:panelExeNameRe = '^(?i)(EdgePanel|Edge面板)\.exe$' }

# ---------------- 关键文件清单（update 预检 / 更新后复核 / 启动体检共用） ----------------
# 路径相对「Edge 目录」；{ver} 由实际版本目录解析。
# 准入规则：只收「瘦身后仍应存在」的文件——即 EdgeTune.ps1 的 $protectedNames 或固定保留集（zh-CN/en-US）。
# 绝不收：*.sig（瘦身会删）、libegl/libglesv2（上游 158 包也不带）、oneauth（本地不登账号）、
#          PdfPreview（便携包没有 shell 注册）、msedge_pwa_launcher（我们主动删）。
$script:essentialRequired = @(
    'msedge.exe'            # 微软签名真身（由 version.dll 注入便携数据目录）
    'version.dll'           # 便携补丁本体
    'chrome++.ini'          # 便携化配置
    '{ver}\msedge.dll'      # 浏览器主体
)
$script:essentialFeature = @(
    '{ver}\msedge.exe'
    '{ver}\msedge_elf.dll'
    '{ver}\ffmpeg.dll'
    '{ver}\d3dcompiler_47.dll'
    '{ver}\vk_swiftshader.dll'
    '{ver}\icudtl.dat'
    '{ver}\resources.pak'
    '{ver}\v8_context_snapshot.bin'
    '{ver}\Locales\zh-CN.pak'
    '{ver}\Locales\en-US.pak'
    '{ver}\WidevineCdm\_platform_specific\win_x64\widevinecdm.dll'
    '{ver}\EBWebView\x64\EmbeddedBrowserWebView.dll'
    'msedge_proxy.exe'      # 站点应用/PWA 快捷方式指向的是**包根**这一份（Chromium 按运行中 exe 的目录拼出来的）；
                            # 版本目录里那份是上游自带，缺了不影响使用（2026-11-21 实测：删掉后应用照常打开）
)