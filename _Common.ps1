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
