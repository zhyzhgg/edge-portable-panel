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
$scriptHome = if ($env:EP_APPDIR) { $env:EP_APPDIR } else { $PSScriptRoot }
. (Join-Path $scriptHome '_Common.ps1')

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
    @{ Rel = 'Data\Crashpad\reports';                    Note = '崩溃转储（仅崩溃后才会长出来，单个 .dmp 可达数十 MB）' }
    @{ Rel = 'Data\Crashpad\attachments';                Note = '崩溃附件' }
    @{ Rel = 'Data\Crashpad\pending';                    Note = '待上报的崩溃转储' }

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

    # —— WebView2（微软账号登录弹窗用）的图形缓存（.230 实测 5.6 MB）——
    @{ Rel = 'Data\OneAuth\WebView2\EBWebView\GrShaderCache';    Note = 'MSA 登录弹窗 WebView2 的着色器缓存' }
    @{ Rel = 'Data\OneAuth\WebView2\EBWebView\ShaderCache';      Note = '同上（WebView2 着色器缓存）' }
    @{ Rel = 'Data\OneAuth\WebView2\EBWebView\Default\GPUCache'; Note = '同上（WebView2 GPU 缓存）' }

    # —— 纯统计 / 诊断日志（可再生，无用户数据；支持通配）——
    @{ Rel = 'Data\Default\load_statistics.db*';                 Note = '站点加载耗时统计库（含 -wal/-shm/-journal 伴生文件，Edge 自动重建）' }
    @{ Rel = 'Data\Default\*_diagnostic.log*';                   Note = '设置与收藏夹同步诊断日志（纯文本，可安全重建）' }
)
# 故意不列入（有副作用 / 含状态，删了会重新弹提示、重新下载或丢配置）：
#   Data\Crashpad\metadata / settings.dat 留着；只清 reports/attachments/pending（崩溃后才会有大文件，平时 0 字节）
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
    'Bookmarks', 'Login Data', 'Login Data For Account', 'History', 'Local State', 'Preferences', 'Secure Preferences',
    'Cookies', 'Network', 'Extensions', 'IndexedDB', 'Local Storage', 'Session Storage',
    'Web Data', 'Favicons', 'Top Sites', 'Shortcuts', 'Managed Search Engines',
    'EdgeLite.mark', 'chrome++.ini', 'msedge.exe'
)

function Get-DirSizeMB([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 0 }
    if (-not $item.PSIsContainer) { return [math]::Round($item.Length / 1MB, 2) }   # 单文件目标（.db / .log）
    $sum = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

function Test-ProtectedPath([string]$full, [string]$root) {
    # 按路径段精确比对：旧写法 -like "*\$name\*" 属子串匹配，新增目标里一旦出现同名片段就会误伤或漏网
    $rel = $full.Substring($root.TrimEnd('\').Length).TrimStart('\')
    $segs = @($rel -split '\\')
    foreach ($name in $protected) {
        if ($segs -contains $name) { return $name }
        # 只认「同名 + .后缀 / -后缀」的文件变体（Bookmarks.bak、Cookies-journal），
        # 不能用 $name + '*'：那会把 extensions_crx_cache 误判成 Extensions 家族而拒绝清理
        if ($segs.Count -gt 0 -and $segs[-1] -match ('^' + [regex]::Escape($name) + '([-.]|$)')) { return $name }
    }
    return $null
}

# 剩余体积构成：清完到底还剩什么、为什么不动它们（解决"清完还是 475 MB"的困惑）
$script:whyKeep = @{
    'Extensions'               = '扩展本体（程序文件）'
    'IndexedDB'                = '站点/扩展数据库（删 = 清站点数据）'
    'Local Extension Settings' = '扩展配置与规则库（过滤规则、脚本与站点配置）'
    'Local Storage'            = '站点偏好与非 Cookie 登录态'
    'Service Worker'           = '含 ScriptCache，删了 MV3 扩展罢工'
    'Network'                  = 'Cookie 与网络状态库'
    'WebStorage'               = '站点存储元数据'
    'Extension State'          = '扩展启停与权限状态'
    'Sync Data'                = '账号同步状态'
    'Sessions'                 = '会话恢复（重开上次标签）'
    'Default（根层文件）'       = 'Profile 根层数据库（历史/书签/Cookie 等，受保护）'
    '（根层文件）'             = 'Data 根层文件（Local State 等，受保护）'
}

function Get-Composition([string]$dataDir) {
    # 一次全树扫描，按「Default\<子目录>」或「一级目录」聚合，供 Top N 展示
    $agg = @{}
    if (Test-Path -LiteralPath $dataDir) {
        $rootLen = $dataDir.TrimEnd('\').Length + 1
        Get-ChildItem -LiteralPath $dataDir -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $segs = @(($_.FullName.Substring($rootLen)) -split '\\')
            if ($segs[0] -eq 'Default') {
                if ($segs.Count -ge 3) { $key = 'Default\' + $segs[1] } else { $key = 'Default（根层文件）' }
            } elseif ($segs.Count -ge 2) { $key = $segs[0] }
            else { $key = '（根层文件）' }
            if ($agg.ContainsKey($key)) { $agg[$key] += $_.Length } else { $agg[$key] = [double]$_.Length }
        }
    }
    $rows = @()
    foreach ($k in $agg.Keys) { $rows += [pscustomobject]@{ Key = $k; MB = [math]::Round($agg[$k] / 1MB, 1) } }
    return @($rows | Sort-Object MB -Descending)
}

function Pad-Display([string]$s, [int]$width) {
    # 按显示宽度补空格（中文占 2 列），避免中文行错位
    $len = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 0x2E80) { $len += 2 } else { $len += 1 } }
    if ($len -ge $width) { return $s }
    return $s + (' ' * ($width - $len))
}

function Show-Composition($rows, [string]$title) {
    if (-not $rows -or @($rows).Count -eq 0) { return }
    Write-Host ''
    Write-Host $title -ForegroundColor DarkCyan
    $rows | Select-Object -First 5 | ForEach-Object {
        $look = $_.Key -replace '^Default\\', ''
        $why = if ($script:whyKeep.ContainsKey($look)) { $script:whyKeep[$look] }
               elseif ($script:whyKeep.ContainsKey($_.Key)) { $script:whyKeep[$_.Key] }
               else { '未列入清单（保守起见不动）' }
        Write-Host ('  {0,8:N1} MB  {1}{2}' -f $_.MB, (Pad-Display $_.Key 34), $why) -ForegroundColor DarkGray
    }
}

# ---- 空间审计下钻：把 Extensions / IndexedDB 的大户翻译成人能看懂的名字（纯只读诊断）----
function Resolve-ExtensionName([string]$extDir) {
    # 大量扩展的 manifest.name 是 __MSG_xxx__ 占位符，必须去 _locales 里取真名；取不到落回扩展 ID
    $mf = Get-ChildItem -LiteralPath $extDir -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mf) { return $null }
    try { $m = Get-Content -LiteralPath $mf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $n = [string]$m.name
    if ($n -and $n -notmatch '^__MSG_(.+)__$') { return $n }
    if ($n -match '^__MSG_(.+)__$') {
        $key = $matches[1]
        foreach ($lang in @('zh_CN', 'zh', 'en_US', 'en')) {
            $mp = Join-Path $mf.Directory.FullName ('_locales\' + $lang + '\messages.json')
            if (Test-Path -LiteralPath $mp) {
                try {
                    $j = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json
                    $node = $j.$key
                    if ($node -and $node.message) { return [string]$node.message }
                } catch { }
            }
        }
    }
    return $null
}

function Get-ExtensionAudit([string]$dataDir, [int]$top = 5) {
    $extRoot = Join-Path $dataDir 'Default\Extensions'
    $lesRoot = Join-Path $dataDir 'Default\Local Extension Settings'
    if (-not (Test-Path -LiteralPath $extRoot)) { return @() }
    $rows = @()
    foreach ($d in Get-ChildItem -LiteralPath $extRoot -Directory -Force -ErrorAction SilentlyContinue) {
        $mb = Get-DirSizeMB $d.FullName
        $les = Join-Path $lesRoot $d.Name
        if (Test-Path -LiteralPath $les) { $mb += Get-DirSizeMB $les }   # 本体 + 该扩展的配置/规则库
        $name = Resolve-ExtensionName $d.FullName
        if (-not $name) { $name = $d.Name }
        $rows += [pscustomobject]@{ Name = $name; MB = [math]::Round($mb, 1) }
    }
    return @($rows | Sort-Object MB -Descending | Select-Object -First $top)
}

function Get-SiteDataAudit([string]$dataDir, [int]$top = 5) {
    $root = Join-Path $dataDir 'Default\IndexedDB'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $agg = @{}
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
        if ($d.Name -like 'chrome-extension_*') { continue }        # 扩展库不进站点榜
        $hostName = '（其它）'
        if ($d.Name -match '^(?:https?|file)_(.+?)_\d+\.indexeddb\.') { $hostName = $matches[1] }
        $s = (Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object Length -Sum).Sum
        if (-not $s) { $s = 0 }
        if ($agg.ContainsKey($hostName)) { $agg[$hostName] += $s } else { $agg[$hostName] = [double]$s }
    }
    $rows = @()
    foreach ($k in $agg.Keys) { $rows += [pscustomobject]@{ Host = $k; MB = [math]::Round($agg[$k] / 1MB, 1) } }
    return @($rows | Sort-Object MB -Descending | Select-Object -First $top)
}

function Show-StorageAudit([string]$dataDir) {
    # 纯只读：告诉用户大头是谁，绝不在清理脚本里删扩展或站点数据
    $ext = @(Get-ExtensionAudit $dataDir 5)
    if ($ext.Count -gt 0) {
        Write-Host ''
        Write-Host '扩展占用 Top 5（扩展本体 + 配置，只读诊断，本脚本不会删扩展）' -ForegroundColor DarkCyan
        foreach ($r in $ext) { Write-Host ('  {0,8:N1} MB  {1}' -f $r.MB, $r.Name) -ForegroundColor DarkGray }
    }
    $site = @(Get-SiteDataAudit $dataDir 5)
    if ($site.Count -gt 0) {
        Write-Host ''
        Write-Host '站点数据 Top 5（IndexedDB，只读诊断）' -ForegroundColor DarkCyan
        foreach ($r in $site) { Write-Host ('  {0,8:N1} MB  {1}' -f $r.MB, $r.Host) -ForegroundColor DarkGray }
    }
    if ($ext.Count -gt 0 -or $site.Count -gt 0) {
        Write-Host '（想减少占用：扩展可在 edge://extensions 停用或卸载；站点数据可在 edge://settings/content/all 或站点设置中清理）' -ForegroundColor DarkGray
    }
}

# ---- 0. 环境自检 --------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Find-PackageRoot $scriptHome }
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
$running = @((Get-EdgeProcs $Root).Procs)
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
        $still = @((Get-EdgeProcs $Root).Procs)
        if ($still.Count -gt 0) { $still | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        Write-Host '       已关闭，继续清理。' -ForegroundColor Gray
    }
}

# ---- 2. 盘点 ----------------------------------------------------------------
$cacheBefore = Get-DirSizeMB (Join-Path $Root 'Cache')
$compBefore = Get-Composition $data
$before = [math]::Round((($compBefore | Measure-Object MB -Sum).Sum), 1)
$plan = @()
foreach ($t in $targets) {
    $full = Join-Path $Root $t.Rel
    $hits = @()
    if ($t.Rel -match '[*?]') {
        $hits = @(Get-Item -Path $full -Force -ErrorAction SilentlyContinue)      # 通配目标（诊断日志）
    } elseif (Test-Path -LiteralPath $full) {
        $hits = @(Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue)
    }
    if (@($hits).Count -eq 0) {
        $plan += [pscustomobject]@{ Rel = $t.Rel; SizeMB = 0; State = '不存在（跳过）'; Note = $t.Note; Full = $full }
        continue
    }
    foreach ($h in @($hits)) {
        $rel = $h.FullName.Substring($Root.Length).TrimStart('\')
        $bad = Test-ProtectedPath $h.FullName $Root
        if ($bad) {
            $plan += [pscustomobject]@{ Rel = $rel; SizeMB = 0; State = "拒绝（受保护：$bad）"; Note = $t.Note; Full = $h.FullName }
            continue
        }
        $plan += [pscustomobject]@{ Rel = $rel; SizeMB = (Get-DirSizeMB $h.FullName); State = '可清'; Note = $t.Note; Full = $h.FullName }
    }
}

Write-Host ("清理前：Data " + $before + " MB ；Cache " + $cacheBefore + " MB") -ForegroundColor Gray
Write-Host ''
$plan | Where-Object { $_.State -ne '不存在（跳过）' } | Sort-Object SizeMB -Descending | ForEach-Object {
    '{0,9:N1} MB  {1,-52} {2}' -f $_.SizeMB, $_.Rel, $_.State
}
$skipCount = @($plan | Where-Object { $_.State -eq '不存在（跳过）' }).Count
if ($skipCount -gt 0) {
    Write-Host ("（其余 " + $skipCount + " 项本次不存在，已跳过；常态是被上次清理过，或 Edge 退出时按策略自动清了缓存）") -ForegroundColor DarkGray
}
$total = [math]::Round((($plan | Where-Object { $_.State -eq '可清' } | Measure-Object SizeMB -Sum).Sum), 1)
Write-Host ''
Write-Host ("预计可释放：" + $total + " MB") -ForegroundColor Cyan
Write-Host '(书签 / 密码 / 历史 / 登录态 / 扩展本体 / 语言模型 都不在清单里，不会被动到)' -ForegroundColor DarkGray
if (-not $Apply) { Show-Composition $compBefore '当前剩余构成（Top 5，受保护项不清理）' }
if (-not $Apply) { Show-StorageAudit $data }

if (-not $Apply) {
    # 机器可读行：只在预览时输出（面板靠它取数值，不依赖上文中文文案）。
    # 实清理时输出会在面板日志里露出一行内部协议，故不输出。
    $top5 = @($compBefore | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ k = $_.Key; mb = $_.MB } })
    Write-Host ('#EPJSON ' + ([pscustomobject]@{ totalMB = $total; dataMB = $before; cacheMB = $cacheBefore; top = $top5 } | ConvertTo-Json -Compress -Depth 4))
    Write-Host ''
    Write-Host '这是预览。确认真删请加 -Apply：' -ForegroundColor Yellow
    Write-Host ('  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Apply') -ForegroundColor Yellow
    if (-not $Quiet) { [void](Read-Host '按回车退出') }
    exit 0
}

# ---- 3. 执行 ----------------------------------------------------------------
Write-Host ''
$freed = 0.0
$freedInData = 0.0
$failed = @()
foreach ($p in $plan | Where-Object { $_.State -eq '可清' }) {
    $sizeNow = Get-DirSizeMB $p.Full      # 执行前现算：预览与执行之间 Edge 可能又写了东西
    try {
        Remove-Item -LiteralPath $p.Full -Recurse -Force -ErrorAction Stop
        $freed += $sizeNow
        if ($p.Full.StartsWith($data + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $freedInData += $sizeNow }
        Write-Host ("  [OK]   " + $p.Rel + "  (-" + $sizeNow + " MB)") -ForegroundColor Green
    } catch {
        $failed += [pscustomobject]@{ Rel = $p.Rel; Error = $_.Exception.Message }
        Write-Host ("  [跳过] " + $p.Rel + "  " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

$compAfter = Get-Composition $data
$after = [math]::Round((($compAfter | Measure-Object MB -Sum).Sum), 1)
$cacheAfter = Get-DirSizeMB (Join-Path $Root 'Cache')
$freedR = [math]::Round($freed, 1)
Write-Host ''
Write-Host ("清理后：Data " + $after + " MB ；Cache " + $cacheAfter + " MB") -ForegroundColor Gray
Write-Host ("实际释放：" + $freedR + " MB" + $(if ($failed.Count) { "（" + $failed.Count + " 项失败，通常是文件仍被占用）" } else { '' })) -ForegroundColor Cyan
$delta = [math]::Round($before - $after, 1)
if ([math]::Abs($delta - ([math]::Round($freedInData, 1))) -gt 1) {
    # 差额不为 0 的四种可能，按可能性排序（不要一口咬定是某一种）
    Write-Host ("（差额核对：Data 实际减少 " + $delta + " MB，清单里位于 Data 的合计 " + [math]::Round($freedInData, 1) + " MB（另有 " + [math]::Round($freedR - $freedInData, 1) + " MB 是 Data 之外的 Cache 目录）。常见原因：① 删除时个别文件仍被占用，只删掉一部分；② 目标里有父子路径重叠，重复计算；③ 后台仍有 msedge/msedgewebview2 在读写；④ 本脚本不碰、但 Edge 退出时自己清掉的缓存）") -ForegroundColor DarkGray
}
if ($failed.Count) {
    Write-Host '失败项：' -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host ('  - ' + $_.Rel + ' : ' + $_.Error) -ForegroundColor Yellow }
    Write-Host '提示：完全退出 Edge 后重跑一次即可。' -ForegroundColor Yellow
}
Show-Composition $compAfter '清理后剩余构成（Top 5，受保护项不清理）'
Show-StorageAudit $data
Write-Host ''
Write-Host '重启 Edge 生效（缓存会随使用慢慢重建，属正常）。' -ForegroundColor DarkGray
if (-not $Quiet) { [void](Read-Host '按回车退出') }
exit 0
