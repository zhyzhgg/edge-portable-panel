# core\paths.ps1 —— 分层：core 层（零 UI 依赖）
#
# 路径解析：运行时目录 / 状态缓存 / 面板 EXE。纯字符串运算，零 UI 依赖。
# 由 EdgePanel.ps1 搬入，函数体保持原样（move-only）。
function Get-RuntimeCacheDir {
    $root = $env:EP_RUNTIME
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'EdgePanel' }
    $c = Join-Path $root 'cache'
    if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    return $c
}

function Get-StatusCachePath {
    # 复用 Get-RuntimeCacheDir，路径只解析一次
    if ($script:statusCachePath) { return $script:statusCachePath }
    $script:statusCachePath = Join-Path (Get-RuntimeCacheDir) 'status.json'
    return $script:statusCachePath
}

function Get-PanelExePath {
    # 当前正在运行的面板 EXE：宿主用 EP_EXEPATH 传真实路径（用户可能把它改名成 EdgePanel.exe / Edge面板.exe）
    $p = [string]$env:EP_EXEPATH
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    foreach ($c in @('EdgePanel.exe', 'Edge面板.exe')) {
        $q = Join-Path $pkgRoot $c
        if (Test-Path -LiteralPath $q) { return $q }
    }
    return $null
}
