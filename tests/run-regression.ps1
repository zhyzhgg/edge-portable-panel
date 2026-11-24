#Requires -Version 5.1
<#
  EdgePanel 回归套件（阶段 0：先织网，不动产品代码）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-regression.ps1
    powershell ... -File tests\run-regression.ps1 -Only slim,backup      只跑指定场景
    powershell ... -File tests\run-regression.ps1 -KeepFixture           保留 fixture 便于排查
    powershell ... -File tests\run-regression.ps1 -Exe <path>            指定被测 EXE

  设计约束（与本机红线一致）：
    · 全程无 UI：只走 -RunOnce + 文件系统 / ini / 日志断言，不截图、不 UIA、不模拟输入
    · 不联网、不提权：不跑 CheckUpdate / CheckAsync / UpdateDry / ApplyRecommended
    · 不碰真实 Edge：fixture 全在 %TEMP%，EP_NO_CLOSE_EDGE=1 兜底
    · 每个场景独立 fixture + 独立 EP_RUNTIME，互不污染

  退出码：0 = 全部通过；1 = 有失败（便于 CI / 批处理判断）
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [string[]]$Only = @(),
    [switch]$KeepFixture,
    [int]$TimeoutSec = 240
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $repo 'Edge面板.exe' }
$workRoot = Join-Path $env:TEMP 'ep-regression'

# ---------------- 结果收集 ----------------
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$scenario, [string]$name, [bool]$ok, [string]$detail = '') {
    [void]$script:Results.Add([pscustomobject]@{ Scenario = $scenario; Name = $name; Ok = $ok; Detail = $detail })
    $mark = if ($ok) { '  OK  ' } else { ' FAIL ' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ($mark + '[' + $scenario + '] ' + $name + $(if ($detail) { '  → ' + $detail } else { '' })) -ForegroundColor $color
}

function Assert-True([string]$scenario, [string]$name, $cond, [string]$detail = '') {
    Add-Result $scenario $name ([bool]$cond) $detail
}

function Assert-Path([string]$scenario, [string]$name, [string]$path) {
    Add-Result $scenario $name (Test-Path -LiteralPath $path) $path
}

function Assert-NoPath([string]$scenario, [string]$name, [string]$path) {
    Add-Result $scenario $name (-not (Test-Path -LiteralPath $path)) $path
}

function Get-IniCommandLine([string]$iniPath) {
    if (-not (Test-Path -LiteralPath $iniPath)) { return '' }
    $line = (Get-Content -LiteralPath $iniPath -Encoding UTF8 | Where-Object { $_ -match '^\s*command_line\s*=' } | Select-Object -First 1)
    if (-not $line) { return '' }
    return ($line -replace '^\s*command_line\s*=', '')
}

# ---------------- fixture ----------------
# 造一个"结构完整但内容很小"的假便携包：必需件 / 瘦身目标 / 缓存 / 用户数据全都有
function New-Fixture([string]$root) {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $edge = Join-Path $root 'Edge'
    $ver = Join-Path $edge '120.0.1.1'
    $loc = Join-Path $ver 'Locales'
    foreach ($d in @(
            $edge, $ver, $loc,
            (Join-Path $ver 'Installer'),
            (Join-Path $ver 'PdfPreview'),
            (Join-Path $ver 'VisualElements'),
            (Join-Path $ver 'edge_feedback'),
            (Join-Path $ver 'edge_game_assist'),
            (Join-Path $ver 'AdSelectionAttestationsPreloaded'),
            (Join-Path $ver 'identity_proxy'),
            (Join-Path $ver 'WidevineCdm\_platform_specific\win_x64'),
            (Join-Path $ver 'EBWebView\x64'),
            (Join-Path $root 'Data\Default\Cache\Cache_Data'),
            (Join-Path $root 'Data\Default\Code Cache\js'),
            (Join-Path $root 'Data\Default\GPUCache'),
            (Join-Path $root 'Data\Crashpad\reports'),
            (Join-Path $root 'Data\Default\Extensions\abcdefghijklmnop\1.0_0'),
            (Join-Path $root 'Cache')
        )) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

    # 必需件（Test-EssentialSet 的 required + feature）
    $must = @{
        'Edge\msedge.exe'      = 'stub'
        'Edge\version.dll'     = 'loader'
        'Edge\msedge_proxy.exe' = 'proxy'
    }
    foreach ($k in $must.Keys) { Set-Content -LiteralPath (Join-Path $root $k) -Value $must[$k] -Encoding ASCII }
    $verFiles = @('msedge.exe', 'msedge.dll', 'msedge_elf.dll', 'ffmpeg.dll', 'd3dcompiler_47.dll',
        'vk_swiftshader.dll', 'icudtl.dat', 'resources.pak', 'v8_context_snapshot.bin', 'msedge_100_percent.pak')
    foreach ($f in $verFiles) { Set-Content -LiteralPath (Join-Path $ver $f) -Value ('x' * 64) -Encoding ASCII }
    Set-Content -LiteralPath (Join-Path $ver 'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll') -Value 'wv' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $ver 'EBWebView\x64\EmbeddedBrowserWebView.dll') -Value 'wv2' -Encoding ASCII
    foreach ($p in @('zh-CN.pak', 'en-US.pak', 'fr.pak', 'ja.pak', 'de.pak')) {
        Set-Content -LiteralPath (Join-Path $loc $p) -Value ('l' * 32) -Encoding ASCII
    }

    # 瘦身目标：6 个目录 + 18 个文件 + 3 类通配
    foreach ($d in @('Installer', 'PdfPreview', 'VisualElements', 'edge_feedback', 'edge_game_assist', 'AdSelectionAttestationsPreloaded')) {
        Set-Content -LiteralPath (Join-Path $ver ($d + '\payload.bin')) -Value ('d' * 64) -Encoding ASCII
    }
    Set-Content -LiteralPath (Join-Path $ver 'PdfPreview\PdfPreviewHandler.dll') -Value 'pdf' -Encoding ASCII
    foreach ($f in @('copilotapp.exe', 'mscopilot.exe', 'msedgewebview2.exe', 'elevation_service.exe',
            'notification_helper.exe', 'msedge_pwa_launcher.exe', 'platform_experiences_helper.exe',
            'mip_core_gn.dll', 'telclient.dll', 'oneds.dll', 'unified_copilot_telemetry.dll', 'onramp.dll',
            'microsoft_shell_integration.dll', 'msedge_wer.dll', 'eventlog_provider.dll', 'Copilot.dat',
            'show_third_party_software_licenses.bat', 'msedge_renderer.dll')) {
        Set-Content -LiteralPath (Join-Path $ver $f) -Value ('f' * 64) -Encoding ASCII
    }
    Set-Content -LiteralPath (Join-Path $ver 'copilot_overlay_1.pak') -Value 'ov' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $ver 'leftover.sig') -Value 'sig' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $ver 'identity_proxy\msedgecopilot_8wekyb3d8bbwe.msixbundle') -Value 'msix' -Encoding ASCII

    # 必须保住的东西
    Set-Content -LiteralPath (Join-Path $ver 'keepme.dat') -Value 'keep' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Bookmarks') -Value '{"roots":{"bookmark_bar":{"children":[]}}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Preferences') -Value '{"profile":{"name":"测试"}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'Data\Local State') -Value '{"os_crypt":{"encrypted_key":"AAAA"}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Cookies') -Value 'cookie-db' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Login Data') -Value 'login-db' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Extensions\abcdefghijklmnop\1.0_0\manifest.json') -Value '{"name":"ext"}' -Encoding UTF8

    # 可清缓存
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Cache\Cache_Data\data_0') -Value ('c' * 128) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\Code Cache\js\index') -Value ('c' * 128) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Default\GPUCache\data_0') -Value ('c' * 128) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Data\Crashpad\reports\crash.dmp') -Value ('c' * 128) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'Cache\data_0') -Value ('c' * 128) -Encoding ASCII

    # chrome++.ini：故意只给最小内容，验证脚本会补齐
    $ini = @"
[general]
data_dir=%app%\..\Data
cache_dir=%app%\..\Cache
command_line=--enable-features=msForceNoRoundedCornerAndMargin
ignore_policies=0
win32k=0
policy_key=Portable
"@
    [System.IO.File]::WriteAllText((Join-Path $edge 'chrome++.ini'), $ini, (New-Object System.Text.UTF8Encoding($true)))
    return $root
}

# ---------------- 运行一次面板 ----------------
function Invoke-Panel([string]$action, [string]$pkgRoot, [string]$runtime) {
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '-RunOnce ' + $action
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $pkgRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(936)
    $psi.EnvironmentVariables['EP_TEST_PKGROOT'] = $pkgRoot
    $psi.EnvironmentVariables['EP_RUNTIME'] = $runtime
    $psi.EnvironmentVariables['EP_NO_PROMPT'] = '1'
    $psi.EnvironmentVariables['EP_NO_PANEL_PROBE'] = '1'
    $psi.EnvironmentVariables['EP_NO_CLOSE_EDGE'] = '1'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $p.Kill() } catch { } }
    $sw.Stop()
    $err = ''
    try { $err = $p.StandardError.ReadToEnd() } catch { }
    $code = if ($timedOut) { -9 } else { $p.ExitCode }
    $p.Dispose()

    $log = ''
    $logDir = Join-Path $runtime 'logs'
    if (Test-Path -LiteralPath $logDir) {
        $lf = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($lf) { $log = (Get-Content -LiteralPath $lf.FullName -Encoding UTF8 -Raw) }
    }
    return [pscustomobject]@{
        Action   = $action
        Code     = $code
        TimedOut = $timedOut
        Err      = $err.Trim()
        Log      = $log
        Sec      = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

# 一次运行 = 跑 + 通用断言（退出码 / stderr / 超时）
function Invoke-Case([string]$scenario, [string]$action, [string]$pkgRoot, [string]$runtime) {
    $r = Invoke-Panel $action $pkgRoot $runtime
    Assert-True $scenario ($action + ' 退出码=0') ($r.Code -eq 0) ('实际 ' + $r.Code + '，' + $r.Sec + 's')
    Assert-True $scenario ($action + ' 未超时') (-not $r.TimedOut) ($TimeoutSec.ToString() + 's')
    Assert-True $scenario ($action + ' stderr 为空') ([string]::IsNullOrWhiteSpace($r.Err)) $r.Err
    return $r
}

# ---------------- 场景 ----------------
function Test-ScenarioStatus {
    $sc = 'status'
    $pkg = New-Fixture (Join-Path $workRoot 'status\pkg')
    $rt = Join-Path $workRoot 'status\rt'
    $r = Invoke-Case $sc 'Status' $pkg $rt
    Assert-True $sc '状态刷新走默认分支' ($r.Log -match '自测模式：仅刷新状态')
    Assert-True $sc '读到了包根' ($r.Log -match '面板已启动')
}

function Test-ScenarioSlim {
    $sc = 'slim'
    $pkg = New-Fixture (Join-Path $workRoot 'slim\pkg')
    $rt = Join-Path $workRoot 'slim\rt'
    $ver = Join-Path $pkg 'Edge\120.0.1.1'
    $ini = Join-Path $pkg 'Edge\chrome++.ini'

    # 1) 仅删组件
    $null = Invoke-Case $sc 'SlimOnly' $pkg $rt
    Assert-NoPath $sc 'renderer 已删' (Join-Path $ver 'msedge_renderer.dll')
    Assert-NoPath $sc 'PWA launcher 已删' (Join-Path $ver 'msedge_pwa_launcher.exe')
    Assert-NoPath $sc 'Installer 目录已删' (Join-Path $ver 'Installer')
    Assert-NoPath $sc 'PdfPreview 目录已删' (Join-Path $ver 'PdfPreview')
    Assert-NoPath $sc '通配 *.sig 已删' (Join-Path $ver 'leftover.sig')
    Assert-NoPath $sc 'identity_proxy 里的 copilot 包已删' (Join-Path $ver 'identity_proxy\msedgecopilot_8wekyb3d8bbwe.msixbundle')
    Assert-Path $sc 'msedge.dll 保留' (Join-Path $ver 'msedge.dll')
    Assert-Path $sc 'resources.pak 保留' (Join-Path $ver 'resources.pak')
    Assert-Path $sc '无关文件保留' (Join-Path $ver 'keepme.dat')
    Assert-Path $sc '用户数据保留' (Join-Path $pkg 'Data\Default\Bookmarks')
    $locNames = @(Get-ChildItem -LiteralPath (Join-Path $ver 'Locales') -File | ForEach-Object { $_.Name }) | Sort-Object
    Assert-True $sc 'Locales 只剩中英' (($locNames -join ',') -eq 'en-US.pak,zh-CN.pak') ($locNames -join ',')

    # 2) 一键瘦身（含 ini 三项）
    $null = Invoke-Case $sc 'SlimAll' $pkg $rt
    $cl = Get-IniCommandLine $ini
    Assert-True $sc 'ini 含 --disable-component-update' ($cl -match '--disable-component-update') $cl
    Assert-True $sc 'ini 含 --no-first-run' ($cl -match '--no-first-run') $cl
    Assert-True $sc 'ini 含 --disable-breakpad' ($cl -match '--disable-breakpad') $cl
    Assert-True $sc 'ini 含 ParallelDownloading' ($cl -match 'ParallelDownloading') $cl

    # 3) 关 / 恢复组件更新：只动那一个开关，静态开关必须留下
    $null = Invoke-Case $sc 'IniOn' $pkg $rt
    $cl = Get-IniCommandLine $ini
    Assert-True $sc 'IniOn 去掉了 --disable-component-update' ($cl -notmatch '--disable-component-update') $cl
    Assert-True $sc 'IniOn 保留 --no-first-run' ($cl -match '--no-first-run') $cl
    Assert-True $sc 'IniOn 保留 --disable-breakpad' ($cl -match '--disable-breakpad') $cl
    $null = Invoke-Case $sc 'IniOff' $pkg $rt
    $cl = Get-IniCommandLine $ini
    Assert-True $sc 'IniOff 又加回 --disable-component-update' ($cl -match '--disable-component-update') $cl
}

function Test-ScenarioClean {
    $sc = 'clean'
    $pkg = New-Fixture (Join-Path $workRoot 'clean\pkg')
    $rt = Join-Path $workRoot 'clean\rt'
    $null = Invoke-Case $sc 'Clean' $pkg $rt
    Assert-NoPath $sc 'HTTP 缓存已清' (Join-Path $pkg 'Data\Default\Cache\Cache_Data\data_0')
    Assert-NoPath $sc '代码缓存已清' (Join-Path $pkg 'Data\Default\Code Cache\js\index')
    Assert-NoPath $sc 'GPU 缓存已清' (Join-Path $pkg 'Data\Default\GPUCache\data_0')
    Assert-NoPath $sc '崩溃转储已清' (Join-Path $pkg 'Data\Crashpad\reports\crash.dmp')
    Assert-NoPath $sc '包根 Cache 已清' (Join-Path $pkg 'Cache\data_0')
    Assert-Path $sc '书签保留' (Join-Path $pkg 'Data\Default\Bookmarks')
    Assert-Path $sc '密码库保留' (Join-Path $pkg 'Data\Default\Login Data')
    Assert-Path $sc 'Cookie 保留' (Join-Path $pkg 'Data\Default\Cookies')
    Assert-Path $sc 'Local State 保留' (Join-Path $pkg 'Data\Local State')
    Assert-Path $sc '扩展本体保留' (Join-Path $pkg 'Data\Default\Extensions\abcdefghijklmnop\1.0_0\manifest.json')
}

function Test-ScenarioBackup {
    $sc = 'backup'
    $pkg = New-Fixture (Join-Path $workRoot 'backup\pkg')
    $rt = Join-Path $workRoot 'backup\rt'
    $bm = Join-Path $pkg 'Data\Default\Bookmarks'
    $before = (Get-Content -LiteralPath $bm -Raw -Encoding UTF8)

    $r = Invoke-Case $sc 'BackupPlain' $pkg $rt
    Assert-True $sc '备份走到第 3 步校验' ($r.Log -match '步骤 3/3') ''
    $pkgs = @(Get-ChildItem -LiteralPath $pkg -Filter '*.7z' -File -ErrorAction SilentlyContinue)
    Assert-True $sc '包根生成了 7z 备份' ($pkgs.Count -ge 1) ($pkgs.Count.ToString() + ' 个')

    # 改掉书签，恢复后应回到备份时的内容
    Set-Content -LiteralPath $bm -Value '{"roots":{"bookmark_bar":{"children":[{"name":"改动"}]}}}' -Encoding UTF8
    $rr = Invoke-Case $sc 'Restore' $pkg $rt
    $after = (Get-Content -LiteralPath $bm -Raw -Encoding UTF8)
    Assert-True $sc '恢复后书签回到备份版本' ($after.Trim() -eq $before.Trim()) ''
    Assert-True $sc '恢复日志有瘦身结论' ($rr.Log -match '恢复后瘦身') ''
}

function Test-ScenarioRefresh {
    $sc = 'refresh'
    $pkg = New-Fixture (Join-Path $workRoot 'refresh\pkg')
    $rt = Join-Path $workRoot 'refresh\rt'
    $r = Invoke-Case $sc 'RefreshAsync' $pkg $rt
    # 用「状态已刷新」作为异步刷新真正完成的证据（原来 -or 自测模式 是恒真）
    Assert-True $sc '异步刷新确实完成（状态已刷新）' ($r.Log -match '状态已刷新')
}

# ---------------- 主流程 ----------------
Write-Host ''
Write-Host '==== EdgePanel 回归套件 ====' -ForegroundColor Cyan
Write-Host ('被测 EXE : ' + $Exe)
Write-Host ('工作目录 : ' + $workRoot)
Write-Host ''

if (-not (Test-Path -LiteralPath $Exe)) { Write-Host ('找不到被测 EXE：' + $Exe) -ForegroundColor Red; exit 1 }
if (@(Get-Process -Name 'EdgePanel', 'Edge面板' -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host '面板正在运行，请先关掉再跑回归' -ForegroundColor Red; exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $repo 'tools\7za.exe'))) {
    Write-Host '缺少 tools\7za.exe，备份/恢复用例无法执行' -ForegroundColor Red; exit 1
}

if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$scenarios = [ordered]@{
    'status'  = { Test-ScenarioStatus }
    'slim'    = { Test-ScenarioSlim }
    'clean'   = { Test-ScenarioClean }
    'backup'  = { Test-ScenarioBackup }
    'refresh' = { Test-ScenarioRefresh }
}

$swAll = [Diagnostics.Stopwatch]::StartNew()
foreach ($k in $scenarios.Keys) {
    if ($Only.Count -gt 0 -and ($Only -notcontains $k)) { continue }
    Write-Host ('--- 场景：' + $k + ' ---') -ForegroundColor DarkCyan
    try { & $scenarios[$k] } catch {
        Add-Result $k '场景异常' $false $_.Exception.Message
    }
}
# core 单元测试：纯逻辑/文件系统的分支级断言（与上面的 EXE 黑盒互补）
$coreTests = Join-Path $PSScriptRoot 'core-tests.ps1'
if (Test-Path -LiteralPath $coreTests) {
    Write-Host '--- 场景：core-tests（core 单元测试）---' -ForegroundColor DarkCyan
    $cOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $coreTests 2>&1
    $cRc = $LASTEXITCODE
    $cSummary = @($cOut | Where-Object { $_ -match '结果：' }) | Select-Object -Last 1
    foreach ($cl in @($cOut | Where-Object { $_ -match 'FAIL' })) { Write-Host ('    ' + $cl) -ForegroundColor DarkYellow }
    Add-Result 'core-tests' 'core 单元测试通过' ($cRc -eq 0) (([string]$cSummary).Trim())
}

# 分层守卫：静态架构约束（core 不碰 UI、ui 不碰文件系统、无重复定义、dot-source 顺序）
$guardScript = Join-Path $PSScriptRoot 'check-layers.ps1'
if (Test-Path -LiteralPath $guardScript) {
    Write-Host '--- 场景：layers（分层守卫）---' -ForegroundColor DarkCyan
    $gOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardScript 2>&1
    $gRc = $LASTEXITCODE
    foreach ($gl in @($gOut | Where-Object { $_ -match 'FAIL' })) { Write-Host ('    ' + $gl) -ForegroundColor DarkYellow }
    Add-Result 'layers' '分层守卫通过' ($gRc -eq 0) ('exit=' + $gRc)
}

$swAll.Stop()

# 收尾体检：不留进程、不留 %TEMP% 会话目录
$leftProcs = @(Get-Process -Name 'EdgePanel', 'Edge面板' -ErrorAction SilentlyContinue).Count
$leftDirs = @(Get-ChildItem $env:TEMP -Directory -Filter 'EdgePanel-*' -ErrorAction SilentlyContinue).Count
Add-Result 'env' '无残留面板进程' ($leftProcs -eq 0) ($leftProcs.ToString())
Add-Result 'env' '无残留会话目录' ($leftDirs -eq 0) ($leftDirs.ToString())

$fail = @($script:Results | Where-Object { -not $_.Ok })
$pass = @($script:Results | Where-Object { $_.Ok })

Write-Host ''
Write-Host ('==== 结果：' + $pass.Count + ' 通过 / ' + $fail.Count + ' 失败 / 用时 ' + [math]::Round($swAll.Elapsed.TotalSeconds, 1) + ' 秒 ====') `
    -ForegroundColor $(if ($fail.Count -eq 0) { 'Green' } else { 'Red' })
if ($fail.Count -gt 0) {
    Write-Host '失败明细：' -ForegroundColor Red
    foreach ($f in $fail) { Write-Host ('  [' + $f.Scenario + '] ' + $f.Name + '  → ' + $f.Detail) -ForegroundColor Red }
}

if (-not $KeepFixture) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ('fixture 已保留：' + $workRoot) -ForegroundColor DarkGray
}

if ($fail.Count -gt 0) { exit 1 } else { exit 0 }