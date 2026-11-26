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
function Test-EdgeAclApplicable([string]$dir) {
    <#  这个目录到底需不需要 AppContainer ACL：
        ① 目录不存在（全新部署前）→ 不需要，返回 $false
        ② 非 NTFS 分区（exFAT/FAT32 U 盘）不支持 ACL → 不需要，返回 $false
        返回 $true 才表示"该目录存在且支持 ACL，应当检查"。 #>
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $false }
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($dir))
        if (-not $root) { return $true }
        $di = New-Object System.IO.DriveInfo($root)
        if ($di.DriveFormat -and $di.DriveFormat -ne 'NTFS') { return $false }
        return $true
    } catch { return $true }   # 盘符判断不出来时不拦着，走正常检查
}

function Test-EdgeAppContainerAcl([string]$dir) {
    <#  便携版 Edge 若装在非 Program Files 目录，Windows 不会给该目录授予 AppContainer 的
        两个包 SID（S-1-15-2-1 / S-1-15-2-2）读执行权限。Edge 攒满 100 次启动后正式启用
        RendererAppContainer 强沙箱，此时 renderer 读不到目录内 DLL，一个渲染进程都起不来
        （窗口能开、所有页面空白，含 edge://settings）。本函数只做只读检查。
        注意：目录不存在 / 非 NTFS 时返回 $true —— 语义是"无需处理"，不是"检查失败"。 #>
    if (-not (Test-EdgeAclApplicable $dir)) { return $true }
    try {
        $acl = Get-Acl -LiteralPath $dir
        $ids = @($acl.Access | ForEach-Object { [string]$_.IdentityReference })
        $hasAll = @($ids | Where-Object { $_ -match 'S-1-15-2-1|ALL APPLICATION PACKAGES' }).Count -gt 0
        $hasRestricted = @($ids | Where-Object { $_ -match 'S-1-15-2-2|所有受限制的应用程序包|RESTRICTED APPLICATION PACKAGES' }).Count -gt 0
        return ($hasAll -and $hasRestricted)
    } catch { return $false }
}

function Repair-EdgeAppContainerAcl([string]$dir) {
    <#  幂等补齐上面那两个 SID 的 (OI)(CI)(RX)。便携包目录的 Owner 通常是当前用户，
        普通权限即可改 ACL，不需要 UAC。返回 $true 表示最终没问题（含"本就不需要"）。
        失败不抛异常 —— 由调用方决定怎么提示，绝不静默改写其它配置。 #>
    if (Test-EdgeAppContainerAcl $dir) { return $true }
    if (-not (Test-EdgeAclApplicable $dir)) { return $true }   # 目录不存在/非 NTFS：无需处理
    try {
        $null = & icacls.exe $dir /grant '*S-1-15-2-1:(OI)(CI)(RX)' '*S-1-15-2-2:(OI)(CI)(RX)' 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        return (Test-EdgeAppContainerAcl $dir)
    } catch { return $false }
}