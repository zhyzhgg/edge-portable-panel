#Requires -Version 5.1
<#
.SYNOPSIS
    便携 Edge（bibicadotnet/edge-portable-chrome-next-mini）缓存清理脚本。

.DESCRIPTION
    只删缓存类目录，绝不碰书签 / 密码 / 历史 / 登录态 / 扩展本体。
    默认是「只预览」；确认真删要加 -Apply。

    平时用面板：双击便携包根目录里的 EdgePanel.exe，点「清理缓存」。
    面板正是调本脚本（-Apply），所以清理逻辑只此一份。

    手动用：
        powershell -NoProfile -ExecutionPolicy Bypass -File "<...>\tools\scripts\Clean-EdgeCaches.ps1"            # 只预览
        ... -Apply          # 真删
        ... -Apply -ForceClose   # 先关掉本包 Edge 再删

    Edge 还开着时不会硬杀：交互时会问要不要关掉再清；-Quiet 时直接 exit 2。

.PARAMETER Root
    便携版根目录（含 Edge\ 、Data\ 、Cache\ 的那一层），默认脚本所在目录。

.PARAMETER Apply
    真的删除。不加这个参数时只列清单和体积。

.PARAMETER ForceClose
    Edge 还在跑时，先把它关掉再清理（默认遇到运行中的 Edge 直接中止）。

.PARAMETER Quiet
    结束时不等回车（给计划任务/自动化用）。
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Apply,
    [switch]$ForceClose,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# 公共函数（包根定位等）只维护一份
. (Join-Path $PSScriptRoot '_Common.ps1')

# ---- 清理目标（相对 Root 的路径 + 说明）--------------------------------------
# 原则：只清「可再生缓存 / 纯统计」；不碰书签、密码、历史、登录态、扩展本体与配置
$targets = @(
    # —— 网络与代码缓存 ——
    # 注：若 Edge 开了 ClearCachedImagesAndFilesOnExit（策略基线里有这条），这三项
    #     会在每次关闭 Edge 时被自动清空，常态下显示"不存在"。保留它们是为换机、
    #     改策略或 Edge 异常退出（崩溃/强杀）时兜底，成本为零。
    @{ Rel = 'Data\Default\Service Worker\CacheStorage'; Note = 'PWA/网站 Service Worker 缓存（开了退出时清缓存则通常已空）' }
    @{ Rel = 'Data\Default\Code Cache';                  Note = 'JS/WASM 代码缓存（同上前提）' }
    @{ Rel = 'Data\Default\Cache';                       Note = 'HTTP 缓存（同上前提）' }
    @{ Rel = 'Cache';                                    Note = 'chrome++ 指定的独立缓存目录' }

    # —— GPU / 图形管线缓存 ——
    @{ Rel = 'Data\Default\GPUCache';                    Note = 'GPU 缓存' }
    @{ Rel = 'Data\GrShaderCache';                       Note = '显卡着色器缓存' }
    @{ Rel = 'Data\ShaderCache';                         Note = '着色器缓存' }
    @{ Rel = 'Data\Default\DawnWebGPUCache';             Note = 'WebGPU 着色器缓存' }
    @{ Rel = 'Data\Default\DawnGraphiteCache';           Note = 'Graphite 渲染缓存' }
    @{ Rel = 'Data\GPUPersistentCache';                  Note = 'GPU 持久化缓存' }

    # —— 组件 / 扩展下载缓存 ——
    @{ Rel = 'Data\component_crx_cache';                 Note = '扩展 CRX 下载缓存（不是已安装扩展本体）' }
    @{ Rel = 'Data\extensions_crx_cache';                Note = '扩展 CRX 下载缓存（另一路径）' }

    # —— 诊断 / 指标 ——
    @{ Rel = 'Data\BrowserMetrics';                      Note = '诊断指标（正式包 4MB，Edge 不会自动清）' }
    @{ Rel = 'Data\DeferredBrowserMetrics';              Note = '延迟诊断指标' }
    @{ Rel = 'Data\BrowserMetrics-spare.pma';            Note = '指标包备用文件 4MB（写满转正式包并重建，常态存在）' }
    @{ Rel = 'Data\Default\Password_Diagnostics';        Note = '密码诊断日志' }

    # —— Chromium 内部统计与特征库（纯可再生，无用户数据）——
    @{ Rel = 'Data\Default\Site Characteristics Database'; Note = '站点特征库' }
    @{ Rel = 'Data\Default\VideoDecodeStats';            Note = '视频解码统计' }
    @{ Rel = 'Data\Default\optimization_guide_hint_cache_store'; Note = '优化指南提示缓存' }
    @{ Rel = 'Data\Default\AutofillAiModelCache';        Note = '自动填充 AI 模型缓存' }
    @{ Rel = 'Data\Default\BudgetDatabase';              Note = '后台任务配额库' }
    @{ Rel = 'Data\Default\EdgeHubAppUsage';             Note = 'Edge Hub 使用统计' }
    @{ Rel = 'Data\Default\Shared Dictionary';           Note = '共享压缩字典缓存' }

    # —— 跳转列表图标缓存 ——
    @{ Rel = 'Data\Default\JumpListIconsRecentClosed';   Note = '跳转列表图标缓存' }
    @{ Rel = 'Data\Default\JumpListIconsRecentWorkspacesV2'; Note = '跳转列表图标缓存（工作区）' }

    # —— 语音 / 购物 / 钱包 ——
    @{ Rel = 'Data\Default\Speech Recognition';          Note = '语音识别临时数据' }
    @{ Rel = 'Data\Default\Edge Shopping';               Note = '购物功能数据' }
    @{ Rel = 'Data\Default\commerce_subscription_db';    Note = '购物订阅数据库' }
    @{ Rel = 'Data\Default\discount_infos_db';           Note = '优惠信息数据库' }
    @{ Rel = 'Data\Default\discounts_db';                Note = '优惠券数据库' }
    @{ Rel = 'Data\Default\EdgeCoupons';                 Note = 'Edge 优惠券数据' }
    @{ Rel = 'Data\Default\parcel_tracking_db';          Note = '包裹跟踪数据' }
    @{ Rel = 'Data\Default\Edge Wallet';                 Note = '钱包数据（可能含银行卡/地址）' }
)
# 故意不列入（有副作用 / 含状态，删了会重新弹提示、重新下载或丢配置）：
#   Data\Crashpad                          崩溃转储目录；实测仅 308B 元数据，清它没收益
#   Data\Safe Browsing / SmartScreen       安全防护本地库；删了会重新下载且期间校验降级
#   Data\Default\Safe Browsing Network     同上
#   Data\DualEngine                        IE 模式站点列表（是配置不是缓存）
#   Data\Nurturing                         推广活动历史；删了会重新弹推广
#   Data\Ad Blocking                       广告拦截规则；删了期间无拦截
#   Data\Default\Platform Notifications    网站通知权限记录
#   Data\Default\AutofillStrikeDatabase    自动填充防骚扰计数；删了会重新弹保存提示
#   Data\Default\Feature Engagement Tracker IPH 功能引导状态（记录哪些气泡弹过不再弹）；
#                                          删了会重新弹引导，且实测 0 字节，零收益
#   Data\Default\Service Worker\ScriptCache  MV3 扩展脚本缓存；删了扩展会罢工（实测 7MB 但绝不能碰）

# ---- 绝不允许被删的（防御：目标路径里出现这些名字直接拒绝）---------------------
$protected = @(
    'Bookmarks', 'Login Data', 'History', 'Local State', 'Preferences', 'Secure Preferences',
    'Cookies', 'Network', 'Extensions', 'IndexedDB', 'Local Storage', 'Session Storage',
    'Web Data', 'Favicons', 'Top Sites', 'Shortcuts', 'Managed Search Engines',
    'EdgeLite.mark', 'chrome++.ini', 'msedge.exe'
)

function Get-DirSizeMB([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

function Test-ProtectedPath([string]$full, [string]$root) {
    $rel = $full.Substring($root.TrimEnd('\').Length).TrimStart('\')
    foreach ($name in $protected) {
        if ($rel -eq $name -or $rel -like "$name\*" -or $rel -like "*\$name" -or $rel -like "*\$name\*") { return $name }
    }
    return $null
}

# ---- 0. 环境自检 --------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Find-PackageRoot $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
$exe = Join-Path $Root 'Edge\msedge.exe'
$data = Join-Path $Root 'Data'

Write-Host ''
Write-Host '==== 便携 Edge 缓存清理 ====' -ForegroundColor Cyan
Write-Host ("根目录 : " + $Root)
Write-Host ("模式   : " + $(if ($Apply) { '实际清理（-Apply）' } else { '仅预览（加 -Apply 才会删）' }))
Write-Host ''

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host ("[错误] 找不到 " + $exe + "，这不是便携版根目录？") -ForegroundColor Red
    if (-not $Quiet) { [void](Read-Host '按回车退出') }
    exit 1
}
if (-not (Test-Path -LiteralPath $data)) {
    Write-Host ("[错误] 找不到 " + $data) -ForegroundColor Red
    if (-not $Quiet) { [void](Read-Host '按回车退出') }
    exit 1
}

# ---- 1. Edge 是否在跑 ---------------------------------------------------------
$pkgPrefix = $Root.TrimEnd('\') + '\'
$running = @(Get-Process -Name msedge -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($pkgPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    Write-Host ("[提示] 本便携版有 " + $running.Count + " 个 msedge 进程在运行（pid " + (($running | ForEach-Object Id) -join ', ') + "）") -ForegroundColor Yellow
    $doClose = $false
    if (-not $Apply) {
        Write-Host '       预览模式不做处理；真清理前需要先完全退出 Edge。' -ForegroundColor Yellow
    } elseif ($ForceClose) {
        $doClose = $true
    } elseif ($Quiet) {
        Write-Host '[中止] 非交互模式下不替你关浏览器：先退出 Edge，或加 -ForceClose。' -ForegroundColor Red
        exit 2
    } else {
        Write-Host '       缓存文件被占用，现在删可能删不干净。' -ForegroundColor Yellow
        $ans = Read-Host '       关掉 Edge 并继续清理？(Y = 关掉后清理，其它 = 取消)'
        if ($ans -match '^[Yy]') {
            $doClose = $true
        } else {
            Write-Host '已取消，没有删除任何文件。' -ForegroundColor DarkGray
            [void](Read-Host '按回车退出')
            exit 2
        }
    }
    if ($doClose) {
        Write-Host '       正在关闭 Edge…' -ForegroundColor Yellow
        $running | ForEach-Object { try { [void]$_.CloseMainWindow() } catch { } }
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $stillAlive = @(Get-Process -Id ($running | ForEach-Object Id) -ErrorAction SilentlyContinue)
            if ($stillAlive.Count -eq 0) { break }
        }
        $still = @(Get-Process -Name msedge -ErrorAction SilentlyContinue |
                   Where-Object { $_.Path -and $_.Path.StartsWith($pkgPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($still.Count -gt 0) { $still | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        Write-Host '       已关闭，继续清理。' -ForegroundColor Gray
    }
}

# ---- 2. 盘点 ----------------------------------------------------------------
$before = Get-DirSizeMB $data
$cacheBefore = Get-DirSizeMB (Join-Path $Root 'Cache')
$plan = @()
foreach ($t in $targets) {
    $full = Join-Path $Root $t.Rel
    $bad = Test-ProtectedPath $full $Root
    if ($bad) {
        $plan += [pscustomobject]@{ Rel = $t.Rel; SizeMB = 0; State = "拒绝（受保护：$bad）"; Note = $t.Note; Full = $full }
        continue
    }
    if (-not (Test-Path -LiteralPath $full)) {
        $plan += [pscustomobject]@{ Rel = $t.Rel; SizeMB = 0; State = '不存在（跳过）'; Note = $t.Note; Full = $full }
        continue
    }
    $plan += [pscustomobject]@{ Rel = $t.Rel; SizeMB = (Get-DirSizeMB $full); State = '可清'; Note = $t.Note; Full = $full }
}

Write-Host ("清理前：Data " + $before + " MB ；Cache " + $cacheBefore + " MB") -ForegroundColor Gray
Write-Host ''
$plan | Sort-Object SizeMB -Descending | ForEach-Object {
    '{0,9:N1} MB  {1,-52} {2}' -f $_.SizeMB, $_.Rel, $_.State
}
$total = [math]::Round((($plan | Where-Object { $_.State -eq '可清' } | Measure-Object SizeMB -Sum).Sum), 1)
Write-Host ''
Write-Host ("预计可释放：" + $total + " MB") -ForegroundColor Cyan
Write-Host '(书签 / 密码 / 历史 / 登录态 / 扩展本体 / 语言模型 都不在清单里，不会被动到)' -ForegroundColor DarkGray

if (-not $Apply) {
    # 机器可读行：只在预览时输出（面板靠它取数值，不依赖上文中文文案）。
    # 实清理时输出会在面板日志里露出一行内部协议，故不输出。
    Write-Host ('#EPJSON ' + ([pscustomobject]@{ totalMB = $total; dataMB = $before; cacheMB = $cacheBefore } | ConvertTo-Json -Compress))
    Write-Host ''
    Write-Host '这是预览。确认真删请加 -Apply：' -ForegroundColor Yellow
    Write-Host ('  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Apply') -ForegroundColor Yellow
    if (-not $Quiet) { [void](Read-Host '按回车退出') }
    exit 0
}

# ---- 3. 执行 ----------------------------------------------------------------
Write-Host ''
$freed = 0.0
$failed = @()
foreach ($p in $plan | Where-Object { $_.State -eq '可清' }) {
    $sizeBefore = $p.SizeMB
    try {
        Remove-Item -LiteralPath $p.Full -Recurse -Force -ErrorAction Stop
        $freed += $sizeBefore
        Write-Host ("  [OK]   " + $p.Rel + "  (-" + $sizeBefore + " MB)") -ForegroundColor Green
    } catch {
        $failed += [pscustomobject]@{ Rel = $p.Rel; Error = $_.Exception.Message }
        Write-Host ("  [跳过] " + $p.Rel + "  " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

$after = Get-DirSizeMB $data
$cacheAfter = Get-DirSizeMB (Join-Path $Root 'Cache')
Write-Host ''
Write-Host ("清理后：Data " + $after + " MB ；Cache " + $cacheAfter + " MB") -ForegroundColor Gray
Write-Host ("实际释放：" + [math]::Round($freed, 1) + " MB" + $(if ($failed.Count) { "（" + $failed.Count + " 项失败，通常是文件仍被占用）" } else { '' })) -ForegroundColor Cyan
if ($failed.Count) {
    Write-Host '失败项：' -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host ('  - ' + $_.Rel + ' : ' + $_.Error) -ForegroundColor Yellow }
    Write-Host '提示：完全退出 Edge 后重跑一次即可。' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '重启 Edge 生效（缓存会随使用慢慢重建，属正常）。' -ForegroundColor DarkGray
if (-not $Quiet) { [void](Read-Host '按回车退出') }
exit 0
