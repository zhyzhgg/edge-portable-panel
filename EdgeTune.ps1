#Requires -Version 5.1
<#
.SYNOPSIS
    便携 Edge 一站式瘦身：删无用的程序文件 + 开关组件更新（原「精简安装包」与「组件更新开关」二合一）。

.DESCRIPTION
    菜单：
      1) 全套瘦身 —— 删掉不用的程序文件，并把组件更新关掉（推荐，省 ~300 MB 且不再长）
      2) 只删文件   —— 保留组件更新（Edge 会继续下载组件）
      3) 只关组件更新
      4) 恢复组件更新（下次启动会重新下载缺失组件，可能上百 MB）
      5) 查看状态
      0) 退出

    删除范围（目标随上游版本变化，数量以 StatusJson 实时统计为准）：
      Locales 除 zh-CN/en-US 外全部、VisualElements、edge_feedback、edge_game_assist、
      Installer、PdfPreview、AdSelectionAttestationsPreloaded、Copilot/Office Hub 外壳、
      更新与通知组件（elevation_service / notification_helper /
      msedge_pwa_launcher / platform_experiences_helper）。【保留 msedge_proxy.exe：站点应用/PWA 快捷方式指向它】

    绝不删：msedge.exe / msedge_proxy.exe / msedge.dll / msedge_elf.dll / version.dll / chrome++.ini /
    resources.pak / msedge_*_percent.pak / icudtl.dat / v8_context_snapshot.bin /
    update.bat / debloater-gui.* / default-apps-multi-profile.bat / bypass_windows_defender.bat

    判据（往 $fileTargets 加条目之前先问一句）：Edge 自己会不会按绝对路径 exec / 加载它？
      只看「浏览器还能不能跑」一定会漏 —— msedge_proxy.exe 就这样被删过，结果站点应用/PWA 快捷方式
      全部报「msedge_proxy.exe 已更改或移动」。同类待查：msedge.dll 同目录的 DLL 依赖、
      *_proxy / *launcher 这类代理程序、shell 集成（PDF 预览、通知、默认关联）。

.PARAMETER Root
    便携版根目录，默认从脚本所在目录向上查找含 Edge\msedge.exe 的目录。

.PARAMETER Action
    SlimAll | SlimOnly | IniOff | IniOn | Status。给了就不弹菜单。

.PARAMETER Quiet
    不等待回车（配合 -Action 做自动化）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File EdgeTune.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File EdgeTune.ps1 -Action Status -Quiet
#>
[CmdletBinding()]
param(
    [string]$Root,
    [ValidateSet('SlimAll', 'SlimOnly', 'IniOff', 'IniOn', 'MetricsOff', 'MetricsOn', 'Status', 'StatusJson')]
    [string]$Action,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# 公共函数（包根定位 / 程序目录 / ini 定位）只维护一份
$scriptHome = if ($env:EP_APPDIR) { $env:EP_APPDIR } else { $PSScriptRoot }
. (Join-Path $scriptHome '_Common.ps1')
$flag = '--disable-component-update'
$localesKeep = @('zh-CN.pak', 'en-US.pak')

$dirTargets = @(
    'VisualElements'
    'edge_feedback'
    'edge_game_assist'
    'Installer'
    'PdfPreview'
    'AdSelectionAttestationsPreloaded'
)

$fileTargets = @(
    'copilotapp.exe'
    'mscopilot.exe'
    'msedgewebview2.exe'
    'elevation_service.exe'
    'notification_helper.exe'
    'msedge_pwa_launcher.exe'
    'platform_experiences_helper.exe'
    'mip_core_gn.dll'
    'telclient.dll'
    'oneds.dll'
    'unified_copilot_telemetry.dll'
    'onramp.dll'
    'microsoft_shell_integration.dll'
    'msedge_wer.dll'
    'eventlog_provider.dll'
    'Copilot.dat'
    'show_third_party_software_licenses.bat'
)

$globTargets = @(
    @{ Dir = '.';              Pattern = 'copilot_overlay_*.pak';   Recurse = $false }
    @{ Dir = '.';              Pattern = '*.sig';                  Recurse = $false }
    @{ Dir = 'identity_proxy'; Pattern = '*copilot*.msixbundle';   Recurse = $true }
    @{ Dir = 'identity_proxy'; Pattern = '*copilot*.p7x';          Recurse = $true }
    @{ Dir = 'identity_proxy'; Pattern = '*officehub*.msixbundle'; Recurse = $true }
    @{ Dir = 'identity_proxy'; Pattern = '*officehub*.p7x';        Recurse = $true }
)

$protectedNames = @(
    'msedge.exe', 'msedge.dll', 'msedge_elf.dll', 'msedge_elf_orig.dll', 'version.dll', 'msedge_proxy.exe',
    'resources.pak', 'msedge_100_percent.pak', 'msedge_200_percent.pak',
    'icudtl.dat', 'v8_context_snapshot.bin', 'msedge.ini', 'chrome++.ini',
    'update.bat', 'debloater-gui.bat', 'debloater-gui.ps1',
    'default-apps-multi-profile.bat', 'bypass_windows_defender.bat'
)

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# 包根定位 / 程序目录 / ini 定位 都来自 _Common.ps1（见文件顶部 dot-source），此处不再重复实现。

# ---------- 备份保留策略：只留最近 N 份（只动本脚本产生的 ini 备份，不碰别的项目文件） ----------
function Remove-OldBackups([string]$dir, [int]$keep = 10) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like 'ini.*.bak' -or $_.Name -like 'chrome++.ini.*.bak' })
    if ($files.Count -le $keep) { return 0 }
    $old = @($files | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep)
    $n = 0
    foreach ($f in $old) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { }
    }
    return $n
}
# ---------- ini 读写（保留原编码与行尾空白） ----------
function Read-IniState([string]$ini) {
    $bytes = [System.IO.File]::ReadAllBytes($ini)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $encName = 'ASCII/UTF8'
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode; $encName = 'UTF-16LE' }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true); $encName = 'UTF-8 BOM' }
    $text = [System.IO.File]::ReadAllText($ini, $enc)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($text -split "`r?`n"))
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*command_line\s*=') { $idx = $i; break } }
    $raw = if ($idx -ge 0) { $lines[$idx] -replace '^\s*command_line\s*=\s*', '' } else { '' }
    [pscustomobject]@{
        Ini = $ini; Enc = $enc; EncName = $encName; Nl = $nl; Lines = $lines; Index = $idx
        Value = $raw.TrimEnd(); Trail = $raw.Substring($raw.TrimEnd().Length)
        Off = ($raw -match [regex]::Escape($flag))
    }
}

function Set-ComponentUpdate([string]$ini, [bool]$disable) {
    $s = Read-IniState $ini
    if ($s.Index -lt 0) { Say '[错误] ini 里没有 command_line 行，未改动。' 'Red'; return $false }
    if ($disable -eq $s.Off) { Say ('已经是' + $(if ($disable) { '关闭' } else { '开启' }) + '状态，无需修改。') 'Green'; return $true }

    $newVal = if ($disable) { $s.Value + ' ' + $flag + $s.Trail }
              else { (($s.Value -replace ('\s*' + [regex]::Escape($flag)), '') -replace '\s{2,}', ' ').TrimEnd() + $s.Trail }

    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $bak = Join-Path $backupDir ('ini.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.bak')
    Copy-Item -LiteralPath $ini -Destination $bak -Force
    $pruned = Remove-OldBackups $backupDir 10
    if ($pruned -gt 0) { Say ("  已清理 $pruned 个旧备份（保留最近 10 份）") 'DarkGray' }

    $s.Lines[$s.Index] = 'command_line=' + $newVal
    $out = ($s.Lines -join $s.Nl)
    if (-not $out.EndsWith($s.Nl)) { $out += $s.Nl }
    [System.IO.File]::WriteAllText($ini, $out, $s.Enc)

    Say ('已' + $(if ($disable) { '关闭' } else { '恢复' }) + '组件更新。') 'Green'
    Say ('  command_line = ' + $newVal.Trim())
    Say ('  备份: ' + $bak) 'DarkGray'
    return $true
}

function Set-IniFeature([string]$ini, [string]$feature, [bool]$enable, [string]$Switch = '--enable-features') {
    <#  在 command_line 的 --enable-features= 或 --disable-features= 列表里加/去一个特性。
        必须合并进同一个同名开关（写第二个会把前一个覆盖掉）；没有这一项就追加，列表空了就把整项去掉。 #>
    $s = Read-IniState $ini
    if ($s.Index -lt 0) { Say '[错误] ini 里没有 command_line 行，未改动。' 'Red'; return $false }

    $val = $s.Value
    $lstName = if ($Switch -eq '--disable-features') { '禁用列表' } else { '启用列表' }
    $m = [regex]::Match($val, ([regex]::Escape($Switch) + '=([^\s]*)'))
    $cur = @()
    if ($m.Success -and $m.Groups[1].Value.Trim() -ne '') {
        $cur = @($m.Groups[1].Value -split ',' | Where-Object { $_ -ne '' })
    }
    $has = @($cur | Where-Object { $_ -eq $feature }).Count -gt 0
    if ($enable -eq $has) {
        Say ('特性 ' + $feature + ' 已在' + $lstName + '中，无需修改。') 'Green'
        return $true
    }

    $list = if ($enable) { @(($cur + $feature) | Select-Object -Unique) } else { @($cur | Where-Object { $_ -ne $feature }) }
    $joined = ($list -join ',')
    $newVal = if ($m.Success) {
        if ($joined) { $val.Replace($m.Value, $Switch + '=' + $joined) }
        else { ($val.Replace($m.Value, '') -replace '\s{2,}', ' ').Trim() }
    } else {
        if ($joined) { ($val + ' ' + $Switch + '=' + $joined).Trim() } else { $val }
    }

    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $bak = Join-Path $backupDir ('ini.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.bak')
    Copy-Item -LiteralPath $ini -Destination $bak -Force
    [void](Remove-OldBackups $backupDir 10)

    $s.Lines[$s.Index] = 'command_line=' + $newVal + $s.Trail
    $out = ($s.Lines -join $s.Nl)
    if (-not $out.EndsWith($s.Nl)) { $out += $s.Nl }
    [System.IO.File]::WriteAllText($ini, $out, $s.Enc)

    Say ('已' + $(if ($enable) { '加入' } else { '移出' }) + $lstName + '：' + $feature) 'Green'
    Say ('  command_line = ' + $newVal)
    Say ('  备份: ' + $bak) 'DarkGray'
    return $true
}

# ---------- 瘦身 ----------
function Get-SlimTargets([string]$prog) {
    $list = @()
    $loc = Join-Path $prog 'Locales'
    if (Test-Path -LiteralPath $loc) {
        $list += @(Get-ChildItem -LiteralPath $loc -File -ErrorAction SilentlyContinue |
                   Where-Object { $localesKeep -notcontains $_.Name })
    }
    foreach ($d in $dirTargets) {
        $p = Join-Path $prog $d
        if (Test-Path -LiteralPath $p -PathType Container) {
            $list += @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue)
        }
    }
    foreach ($f in $fileTargets) {
        $p = Join-Path $prog $f
        if (Test-Path -LiteralPath $p -PathType Leaf) { $list += (Get-Item -LiteralPath $p) }
    }
    foreach ($g in $globTargets) {
        $dir = if ($g.Dir -eq '.') { $prog } else { Join-Path $prog $g.Dir }
        if (Test-Path -LiteralPath $dir) {
            $gi = @{ LiteralPath = $dir; File = $true; ErrorAction = 'SilentlyContinue' }
            if ($g.Recurse) { $gi['Recurse'] = $true }
            $list += @(Get-ChildItem @gi | Where-Object { $_.Name -like $g.Pattern })
        }
    }
    $kept = @()
    foreach ($f in $list) {
        if ($protectedNames -contains $f.Name) { continue }
        $kept += $f
    }
    return @($kept | Sort-Object FullName -Unique)
}

function Show-Status([string]$pkgRoot, [string]$prog, [string]$ini) {
    $files = @(Get-ChildItem $prog -Recurse -File -Force -ErrorAction SilentlyContinue)
    $mb = if ($files.Count) { [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 }
    $targets = Get-SlimTargets $prog
    $tmb = if ($targets.Count) { [math]::Round((($targets | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 }
    $data = Join-Path $pkgRoot 'Data'
    $compDirs = if (Test-Path $data) { @(Get-ChildItem $data -Directory -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    $dataMb = if (Test-Path $data) { [math]::Round(((Get-ChildItem $data -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 }

    Say ''
    Say '==== 便携 Edge 瘦身 · 状态 ====' 'Cyan'
    Say ('程序目录 : ' + $prog)
    Say ('  文件 ' + $files.Count + ' 个 / ' + $mb + ' MB')
    Say ('  待删     : ' + $targets.Count + ' 个 / ' + $tmb + ' MB' + $(if ($targets.Count -eq 0) { '（已瘦身过）' } else { '' }))
    Say ('profile  : ' + $(if (Test-Path $data) { "$compDirs 个目录 / $dataMb MB" } else { 'Data 不存在' }))
    Say ('  DRM      : ' + $(if (Test-Path (Join-Path $data 'WidevineCdm')) { 'WidevineCdm 已安装' } else { '无 CDM（DRM 不可用）' }))
    if ($ini) {
        $s = Read-IniState $ini
        Say ('组件更新 : ' + $(if ($s.Off) { '【已关闭】不再下载组件' } else { '【已开启】会自动下载组件' })) $(if ($s.Off) { 'Yellow' } else { 'Green' })
        Say ('  ini      : ' + $ini)
        Say ('  command_line = ' + $s.Value)
    } else { Say '组件更新 : 没找到 ini（chrome++.ini / msedge.ini）' 'Yellow' }
}

function Show-StatusJson([string]$pkgRoot, [string]$prog, [string]$ini) {
    $files = @(Get-ChildItem $prog -Recurse -File -Force -ErrorAction SilentlyContinue)
    $progMb = if ($files.Count) { [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 }
    $targets = Get-SlimTargets $prog
    $tMb = if ($targets.Count) { [math]::Round((($targets | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 }
    $data = Join-Path $pkgRoot 'Data'
    $dataDirs = 0; $dataMb = 0
    if (Test-Path -LiteralPath $data) {
        $dataDirs = @(Get-ChildItem $data -Directory -Force -ErrorAction SilentlyContinue).Count
        $dataMb = [math]::Round(((Get-ChildItem $data -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
    }
    $off = $false; $cmdLine = ''; $metricsOff = $false
    if ($ini) { $s = Read-IniState $ini; $off = $s.Off; $cmdLine = $s.Value; $metricsOff = ($cmdLine -match '--disable-features=[^\s]*\bPersistentHistograms\b') }
    [pscustomobject]@{
        Root       = $pkgRoot
        Prog       = $prog
        ProgFiles  = $files.Count
        ProgMB     = $progMb
        SlimCount  = $targets.Count
        SlimMB     = $tMb
        DataDirs   = $dataDirs
        DataMB     = $dataMb
        HasCdm     = (Test-Path (Join-Path $data 'WidevineCdm'))
        Ini        = $ini
        IniOff     = $off
        MetricsOff = $metricsOff
        CmdLine    = $cmdLine
        EdgeRunning = (Test-EdgeRunningIn $pkgRoot)
    } | ConvertTo-Json -Compress
}
function Move-RootProxy([string]$pkgRoot, [string]$programDir) {
    # 版本目录里的 msedge_proxy.exe 对功能没用（站点应用/PWA 快捷方式只认**包根**那份），
    # 上游每版又都会带一份 ⇒ 瘦身时顺手归位：包根缺就移过去，包根已有就删掉版本目录这份。
    # 幂等；只是瘦身的常规动作，失败也不阻断（可手工删）。
    if ([string]::IsNullOrWhiteSpace($programDir)) { return }
    $verProxy = Join-Path $programDir 'msedge_proxy.exe'
    if (-not (Test-Path -LiteralPath $verProxy)) { return }
    $rootProxy = Join-Path (Join-Path $pkgRoot 'Edge') 'msedge_proxy.exe'
    try {
        $sz = [math]::Round((Get-Item -LiteralPath $verProxy).Length / 1MB, 1)
        if (-not (Test-Path -LiteralPath $rootProxy)) {
            $dir = Split-Path $rootProxy -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Move-Item -LiteralPath $verProxy -Destination $rootProxy -Force -ErrorAction Stop
            Say ('msedge_proxy.exe 已移至包根（' + $sz + ' MB，版本目录内已移除）')
        } else {
            Remove-Item -LiteralPath $verProxy -Force -ErrorAction Stop
            Say ('已移除版本目录内的 msedge_proxy.exe（' + $sz + ' MB，包根已有副本）')
        }
    } catch {
        Say ('msedge_proxy.exe 归位失败（不影响其它功能）：' + $_.Exception.Message) 'Yellow'
    }
}

function Invoke-Slim([string]$prog, [string]$pkgRoot = '') {
    # 归位与「要不要删文件」无关：瘦身过了也要能把它挪回包根，所以放在最前面
    if ([string]::IsNullOrWhiteSpace($pkgRoot)) {
        $parent = Split-Path $prog -Parent
        $pkgRoot = if ((Split-Path $prog -Leaf) -eq 'Edge') { $parent } else { Split-Path $parent -Parent }
    }
    Move-RootProxy $pkgRoot $prog
    $files = Get-SlimTargets $prog
    if ($files.Count -eq 0) { Say '程序目录已经没有可删的文件（瘦身过了）。' 'Green'; return }
    $mb = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)
    Say ''
    Say ('开始删除：' + $files.Count + ' 个文件 / ' + $mb + ' MB') 'Cyan'
    $freed = 0.0; $fail = 0
    foreach ($f in $files) {
        try { $sz = $f.Length / 1MB; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $sz }
        catch { $fail++ }
    }
    foreach ($d in $dirTargets) {
        $p = Join-Path $prog $d
        if (Test-Path -LiteralPath $p -PathType Container) {
            if (@(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($g in $globTargets) {
        if ($g.Dir -eq '.') { continue }
        $dir = Join-Path $prog $g.Dir
        if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Say ('已删除，释放约 ' + [math]::Round($freed, 1) + ' MB' + $(if ($fail) { "（$fail 个失败，多半被占用）" } else { '' })) 'Green'
}


# ---------- 主流程 ----------
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Find-PackageRoot $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Find-PackageRoot (Get-Location).Path }
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not (Test-Path -LiteralPath $Root)) { Say ('[错误] 根目录不存在：' + $Root) 'Red'; exit 1 }
# 备份目录优先放运行时目录（包根保持干净，不再生成 .backups）；无 EP_RUNTIME 时退回包内 .backups
$backupDir = if ($env:EP_RUNTIME) { Join-Path $env:EP_RUNTIME 'ini-backups' } else { Join-Path $Root '.backups' }   # 必须在 $Root 规范化之后求值

$prog = Resolve-ProgramDir $Root
$ini = Resolve-EdgeIni $Root

function Do-SlimAll([string]$pkgRoot, [string]$programDir, [string]$iniPath) {
    $n = Test-EdgeRunningIn $pkgRoot
    if ($n -gt 0) { Say ('[中止] 本包有 ' + $n + ' 个进程在跑，先完全退出 Edge。') 'Red'; return $false }
    Invoke-Slim $programDir $pkgRoot
    if ($iniPath) {
        [void](Set-ComponentUpdate $iniPath $true)
        # 多线程下载：Chromium 的 ParallelDownloading 只能走 --enable-features（没有对应注册表策略，
        # 且 SmartScreen 那类"下载检查"策略在个人电脑上无效），这里顺手并入同一个 --enable-features 列表。
        [void](Set-IniFeature $iniPath 'ParallelDownloading' $true)
    } else { Say '找不到 ini，跳过组件更新开关。' 'Yellow' }
    return $true
}

function Do-SlimOnly([string]$pkgRoot, [string]$programDir) {
    $n = Test-EdgeRunningIn $pkgRoot
    if ($n -gt 0) { Say ('[中止] 本包有 ' + $n + ' 个进程在跑，先完全退出 Edge。') 'Red'; return $false }
    Invoke-Slim $programDir $pkgRoot
    return $true
}

if ($Action) {
    $rc = 0
    switch ($Action) {
        'Status'  { Show-Status $Root $prog $ini }
        'StatusJson' { Show-StatusJson $Root $prog $ini }
        'SlimAll' { if (-not (Do-SlimAll $Root $prog $ini)) { $rc = 2 } }
        'SlimOnly'{ if (-not (Do-SlimOnly $Root $prog)) { $rc = 2 } }
        'IniOff'  { if ($ini) { if (-not (Set-ComponentUpdate $ini $true)) { $rc = 1 } } else { Say '找不到 ini' 'Red'; $rc = 1 } }
        'IniOn'      { if ($ini) { if (-not (Set-ComponentUpdate $ini $false)) { $rc = 1 } } else { Say '找不到 ini' 'Red'; $rc = 1 } }
        'MetricsOff' { if ($ini) { if (-not (Set-IniFeature $ini 'PersistentHistograms' $true '--disable-features')) { $rc = 1 } } else { Say '找不到 ini' 'Red'; $rc = 1 } }
        'MetricsOn'  { if ($ini) { if (-not (Set-IniFeature $ini 'PersistentHistograms' $false '--disable-features')) { $rc = 1 } } else { Say '找不到 ini' 'Red'; $rc = 1 } }
    }
    if (-not $Quiet) { [void](Read-Host '按回车退出') }
    exit $rc
}

if (-not $Quiet) {
    Show-Status $Root $prog $ini        # 打开即显示当前状态
    Say ''
    Say '请选择：' 'Cyan'
    Say '  1) 全套瘦身 —— 删不用的文件 + 关闭组件更新（推荐）'
    Say '  2) 只删文件   —— 组件更新保持原样'
    Say '  3) 只关闭组件更新'
    Say '  4) 恢复组件更新（下次启动会重新下载组件）'
    Say '  5) 刷新状态（不做改动）'
    Say '  0) 退出'
    Say ''
    $sel = Read-Host '输入编号'
    $ok = $true
    $did = $true
    switch ($sel) {
        '1' { $ok = Do-SlimAll $Root $prog $ini }
        '2' { $ok = Do-SlimOnly $Root $prog }
        '3' { if ($ini) { $ok = Set-ComponentUpdate $ini $true } else { Say '找不到 ini' 'Red'; $ok = $false } }
        '4' { if ($ini) { $ok = Set-ComponentUpdate $ini $false } else { Say '找不到 ini' 'Red'; $ok = $false } }
        '5' { $did = $false }
        default { Say '已退出，未做修改。' 'DarkGray'; exit 0 }
    }
    Show-Status $Root $prog $ini        # 动作完成后回显最新状态
    Say ''
    if ($did) {
        if ($ok) { Say '（改动已完成。删文件/改 ini 后需要重新启动 Edge 才全部生效。）' 'DarkGray' }
        else     { Say '（本次没有完成：见上面的红字提示，Edge 完全退出后重跑本脚本。）' 'Red' }
    }
    [void](Read-Host '按回车退出')
}
exit 0
