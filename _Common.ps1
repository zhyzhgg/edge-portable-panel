#Requires -Version 5.1
<#
    公共函数（被 EdgeTune.ps1 / Clean-EdgeCaches.ps1 / zh-debloater\run-zh.ps1 dot-source 引用）
    目的：包根定位规则只写一份，避免三处漂移。
#>

function Find-PackageRoot([string]$start) {
    <#  从 $start 向上找含 Edge\msedge.exe 或 Application\msedge.exe 的目录。
        找不到就原样返回 $start（调用方自己决定怎么报错）。 #>
    $p = $start
    if ([string]::IsNullOrWhiteSpace($p)) { $p = (Get-Location).Path }
    while ($p) {
        if ((Test-Path -LiteralPath (Join-Path $p 'Edge\msedge.exe')) -or
            (Test-Path -LiteralPath (Join-Path $p 'Application\msedge.exe'))) { return $p }
        $parent = Split-Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $start
}

function Resolve-VersionDir([string]$edgeDir, [string]$RequiredFile = 'msedge.dll', [switch]$AllowIncomplete) {
    <#  在 Edge\ 下按版本号降序找版本目录（唯一实现，供 Resolve-ProgramDir 与面板共用）。
        RequiredFile：该目录里必须存在的标志文件（默认 msedge.dll）。
        AllowIncomplete：一个都没有时退回"版本号最大的目录"（允许"目录在、文件还没落"的中间态）。 #>
    if ([string]::IsNullOrWhiteSpace($edgeDir) -or -not (Test-Path -LiteralPath $edgeDir)) { return $null }
    $vers = @(Get-ChildItem -LiteralPath $edgeDir -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
              Sort-Object { [version]$_.Name } -Descending)
    foreach ($v in $vers) {
        if (Test-Path -LiteralPath (Join-Path $v.FullName $RequiredFile)) { return $v.FullName }
    }
    if ($AllowIncomplete -and $vers.Count -gt 0) { return $vers[0].FullName }
    return $null
}

function Resolve-ProgramDir([string]$pkgRoot) {
    <#  返回真正的程序目录：Edge\<版本号>\ 优先，其次 Edge\，再 Application\，最后根本身。 #>
    $edge = Join-Path $pkgRoot 'Edge'
    if (Test-Path -LiteralPath $edge) {
        $v = Resolve-VersionDir $edge 'msedge.exe'
        if ($v) { return $v }
        if (Test-Path -LiteralPath (Join-Path $edge 'msedge.exe')) { return $edge }
    }
    $app = Join-Path $pkgRoot 'Application'
    if (Test-Path -LiteralPath (Join-Path $app 'msedge.exe')) { return $app }
    return $pkgRoot
}

function Get-EdgeProcs([string]$pkgRoot, [int]$timeoutSec = 0) {
    <#  唯一实现：按可执行文件路径前缀判断"属于这个包"的 msedge 进程。
        前缀必须补尾斜杠，否则 X:\Pkg 会误匹配 X:\Pkg_Backup。
        timeoutSec > 0 时遍历有上限（结果里 TimedOut=$true），供 UI 侧使用以免扫描卡住界面。 #>
    $prefix = $pkgRoot.TrimEnd('\') + '\'
    $matched = New-Object System.Collections.ArrayList
    $timedOut = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($pr in @(Get-Process -Name msedge -ErrorAction SilentlyContinue)) {
        if ($timeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $timeoutSec) { $timedOut = $true; break }
        try {
            $pth = $pr.Path
            if ($pth -and $pth.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$matched.Add($pr) }
        } catch { }
    }
    return [pscustomobject]@{ Procs = @($matched); TimedOut = $timedOut }
}

function Resolve-EdgeIni([string]$pkgRoot) {
    <#  便携化配置文件：bibica 的 chrome++.ini / EdgeLite 的 msedge.ini。 #>
    foreach ($rel in @('Edge\chrome++.ini', 'Application\msedge.ini', 'chrome++.ini', 'msedge.ini')) {
        $p = Join-Path $pkgRoot $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Test-EdgeRunningIn([string]$pkgRoot) {
    <#  有没有"属于这个包"的 msedge 在跑（判定逻辑只有 Get-EdgeProcs 一份）。 #>
    return @((Get-EdgeProcs $pkgRoot).Procs).Count
}

function Get-ActiveBaselineRecords($baseline) {
    <#  基线里「当前应当写入注册表」的条目 —— 唯一实现。
        Apply-RecommendedPolicies 与 Get-PolicyDrift 必须都调它：v1.3.5 之前两处各写了一遍过滤条件，
        热修时只对齐了一半，才引出"Edge 159 后红字报缺失 → 点应用删掉 → 再报缺失"的死循环。
        v1.3.6 起 maxMajor 版本上限机制已随 AllowBrowsingWithCopilot 一起移除；将来若要恢复按版本过滤，
        只需改本函数，调用方无需再动。 #>
    return @($baseline | Where-Object { $_ -and -not $_.remove })
}

function Get-ZhWorkDir([string]$fallbackBase) {
    <#  策略管理中文副本共享目录（唯一事实源，EdgePanel.ps1 与 run-zh.ps1 共用，防止双处路径漂移）。 #>
    if ($env:LOCALAPPDATA) {
        return (Join-Path (Join-Path $env:LOCALAPPDATA 'EdgePanel') '_shared\zh-work')
    }
    return (Join-Path $fallbackBase 'work')
}
function Test-PortableEdgeDir([string]$dir) {
    <#  判断目录是否为本项目的便携 Edge 目录（严防误认系统原版 Edge）：
        ① 排除 Windows / Program Files 等系统目录；
        ② 必须同时存在 Edge\msedge.exe + Edge\version.dll + Edge\chrome++.ini。 #>
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\')
        foreach ($sys in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($sys) {
                $sp = $sys.TrimEnd('\')
                if ($full.Equals($sp, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $full.StartsWith($sp + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            }
        }
        return ((Test-Path -LiteralPath (Join-Path $full 'Edge\msedge.exe')) -and
                (Test-Path -LiteralPath (Join-Path $full 'Edge\version.dll')) -and
                (Test-Path -LiteralPath (Join-Path $full 'Edge\chrome++.ini')))
    } catch { return $false }
}

function Find-PortableEdgeDirs([string]$lastSaved = '') {
    <#  快速发现本机便携 Edge 目录（<0.3s，不扫全盘）：
        依次检查 上次记住路径 -> 运行中的便携 msedge -> 固定盘符 1-2 层常见目录 -> 用户目录/桌面。 #>
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $found = New-Object System.Collections.ArrayList
    $addIf = {
        param([string]$cand)
        if ([string]::IsNullOrWhiteSpace($cand)) { return }
        try {
            $full = [System.IO.Path]::GetFullPath($cand).TrimEnd('\')
            if ($seen.Contains($full)) { return }
            if (Test-PortableEdgeDir $full) {
                [void]$seen.Add($full)
                [void]$found.Add($full)
            }
        } catch { }
    }
    if ($lastSaved) { & $addIf $lastSaved }
    # 运行中的便携 msedge 进程
    try {
        foreach ($pr in @(Get-Process -Name msedge -ErrorAction SilentlyContinue)) {
            try {
                if ($pr.Path) {
                    $eDir = Split-Path -Parent $pr.Path
                    if ((Split-Path -Leaf $eDir) -ieq 'Edge') { & $addIf (Split-Path -Parent $eDir) }
                }
            } catch { }
        }
    } catch { }
    $skipNames = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'PerfLogs')
    $subContainers = @('App', 'Apps', 'Tools', 'Portable', 'Software', 'Program', 'Programs', 'Green', 'DevTools')
    foreach ($drv in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $root = $drv.RootDirectory.FullName
        foreach ($d1 in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($skipNames -contains $d1.Name) { continue }
            & $addIf $d1.FullName
            if ($subContainers -contains $d1.Name) {
                foreach ($d2 in @(Get-ChildItem -LiteralPath $d1.FullName -Directory -ErrorAction SilentlyContinue)) {
                    & $addIf $d2.FullName
                }
            }
        }
    }
    foreach ($uRoot in @($env:USERPROFILE, [Environment]::GetFolderPath('Desktop'))) {
        if ($uRoot -and (Test-Path -LiteralPath $uRoot)) {
            foreach ($d in @(Get-ChildItem -LiteralPath $uRoot -Directory -ErrorAction SilentlyContinue)) {
                & $addIf $d.FullName
            }
        }
    }
    return @($found)
}
function Find-PortableEdgeDirsDeep([int]$maxDepth = 4, [scriptblock]$onProgress = $null, [scriptblock]$stopTest = $null) {
    <#  全机固定盘符深度搜索便携 Edge（最多 4 层，纯 .NET 枚举 + 噪声目录剪枝 + 100ms 节流回调）。 #>
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $found = New-Object System.Collections.ArrayList
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin',
                     'System Volume Information', 'Recovery', 'PerfLogs', 'WinSxS', 'MSOCache', 'Config.Msi',
                     'AppData', 'WindowsApps', 'Packages', 'Intel', 'AMD', 'NVIDIA',
                     'node_modules', '.git', '.hg', '.svn', '.venv', 'venv', '__pycache__', '.cache', '.vscode', '.idea',
                     'Temp', 'tmp', 'Cache', 'Caches', 'Logs',
                     'WeChat Files', 'xwechat_files', 'Tencent Files', 'WXWork', 'DingTalk',
                     'Steam', 'SteamLibrary', 'Epic Games', 'WeGameApps', 'Riot Games',
                     'OneDrive', 'iCloudDrive', 'Pictures', 'Videos', 'Music', 'Photos')) {
        [void]$skip.Add($n)
    }
    $q = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($drv in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $q.Enqueue([pscustomobject]@{ Path = $drv.RootDirectory.FullName.TrimEnd('\'); Depth = 0 })
    }
    $visited = 0
    $script:deepStopped = $false
    $script:deepAbort = $false
    $uiSw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastUiMs = -1000
    while ($q.Count -gt 0) {
        $cur = $q.Dequeue()
        $p = $cur.Path
        $dep = $cur.Depth
        $visited++
        # 停止检查放在每轮开头：不依赖 100ms 节流的 UI 回调，点「停止」后最多再走一个目录
        if ($stopTest -and (& $stopTest)) { $script:deepStopped = $true; break }
        if ($onProgress -and (($uiSw.ElapsedMilliseconds - $lastUiMs) -ge 100)) {
            $lastUiMs = $uiSw.ElapsedMilliseconds
            $cont = & $onProgress $p $visited $found.Count
            if ($cont -eq $false) { break }
        }
        if ($dep -gt 0) {
            # 单次原生文件检查快速过滤，命中后再跑完整 Test-PortableEdgeDir，避免对每个目录做多次 Test-Path
            if ([System.IO.File]::Exists($p + '\Edge\msedge.exe') -and (Test-PortableEdgeDir $p)) {
                if (-not $seen.Contains($p)) { [void]$seen.Add($p); [void]$found.Add($p) }
                continue
            }
        }
        if ($dep -ge $maxDepth) { continue }
        $scanRoot = if ($dep -eq 0) { $p + '\' } else { $p }
        $innerSeen = 0
        try {
            foreach ($subPath in [System.IO.Directory]::EnumerateDirectories($scanRoot)) {
                # 内层也要能中断：慢盘/大目录里枚举一卡住，只有外层检查就永远停不下来
                $innerSeen++
                if ($stopTest -and ($innerSeen -band 0x3F) -eq 0 -and (& $stopTest)) { $script:deepStopped = $true; $script:deepAbort = $true; break }
                $name = [System.IO.Path]::GetFileName($subPath)
                if ([string]::IsNullOrEmpty($name) -or $name.StartsWith('$') -or $skip.Contains($name)) { continue }
                try {
                    $attr = [System.IO.File]::GetAttributes($subPath)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                } catch { continue }
                $q.Enqueue([pscustomobject]@{ Path = $subPath; Depth = ($dep + 1) })
            }
        } catch { }
        if ($script:deepAbort) { break }
    }
    return @($found)
}
