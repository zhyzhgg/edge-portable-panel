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

function Resolve-ProgramDir([string]$pkgRoot) {
    <#  返回真正的程序目录：Edge\<版本号>\ 优先，其次 Edge\，再 Application\，最后根本身。 #>
    $edge = Join-Path $pkgRoot 'Edge'
    if (Test-Path -LiteralPath $edge) {
        $vers = @(Get-ChildItem -LiteralPath $edge -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                  Sort-Object { [version]$_.Name } -Descending)
        foreach ($v in $vers) {
            if (Test-Path -LiteralPath (Join-Path $v.FullName 'msedge.exe')) { return $v.FullName }
        }
        if (Test-Path -LiteralPath (Join-Path $edge 'msedge.exe')) { return $edge }
    }
    $app = Join-Path $pkgRoot 'Application'
    if (Test-Path -LiteralPath (Join-Path $app 'msedge.exe')) { return $app }
    return $pkgRoot
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
    <#  有没有"属于这个包"的 msedge 在跑（按可执行文件路径前缀判断）。
        前缀必须补尾斜杠：否则 X:\Pkg 会误匹配 X:\Pkg_Backup。 #>
    $prefix = $pkgRoot.TrimEnd('\') + '\'
    return @(Get-Process -Name msedge -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count
}
