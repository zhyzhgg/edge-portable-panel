#Requires -Version 5.1
<#
  tests\core-tests.ps1 —— core 层单元测试（纯逻辑 / 文件系统，不依赖界面）

  为什么需要它：
    run-regression.ps1 走的是 EXE 的 -RunOnce 契约，属于「黑盒整机行为」，
    覆盖的是"动作做完了没有"。而 core 里的纯函数（安全目录判定、必需件校验、
    结构漂移、路径解析、持久化）属于「单个判断对不对」，黑盒测不到分支细节。
    分层（1a/1b）之后这些函数可以独立调用，因此这里直接断言。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\core-tests.ps1
    powershell ... -File tests\core-tests.ps1 -Filter pkg     只跑某一组

  退出码：0 = 全部通过；1 = 有失败
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string[]]$Filter = @()
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

$script:Results = New-Object System.Collections.ArrayList

function Add-R([string]$g, [string]$name, [bool]$ok, [string]$detail = '') {
    [void]$script:Results.Add([pscustomobject]@{ Group = $g; Name = $name; Ok = $ok; Detail = $detail })
    $mark = if ($ok) { '  OK  ' } else { ' FAIL ' }
    Write-Host ($mark + '[' + $g + '] ' + $name + $(if ($detail) { '  → ' + $detail } else { '' })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
function Assert-True([string]$g, [string]$n, $cond, [string]$d = '') { Add-R $g $n ([bool]$cond) $d }
function Assert-Eq([string]$g, [string]$n, $expect, $actual) {
    Add-R $g $n ("$expect" -eq "$actual") ('期望 ' + $expect + '，实际 ' + $actual)
}

# ---------------- 环境准备 ----------------
$work = Join-Path $env:TEMP 'ep-core-tests'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$oldRuntime = $env:EP_RUNTIME
$env:EP_RUNTIME = Join-Path $work 'runtime'
$pkgRoot = Join-Path $work 'pkgsim'   # Get-PanelExePath 的兜底查找目录
New-Item -ItemType Directory -Force -Path $pkgRoot | Out-Null
New-Item -ItemType Directory -Force -Path $env:EP_RUNTIME | Out-Null

# core 层：日志 → 路径 → 系统 → 包（顺序与 EdgePanel.ps1 一致）
. (Join-Path $Repo '_Common.ps1')
. (Join-Path $Repo 'core\log.ps1')
. (Join-Path $Repo 'core\paths.ps1')
. (Join-Path $Repo 'core\system.ps1')
. (Join-Path $Repo 'core\pkg.ps1')

# 日志静默：单元测试不需要刷屏，但要能断言顺序
$script:captured = New-Object System.Collections.ArrayList
Set-LogSink { param($row) [void]$script:captured.Add($row) }

Write-Host ''
Write-Host '==== core 层单元测试 ====' -ForegroundColor Cyan
Write-Host ('仓库: ' + $Repo)
Write-Host ('临时区: ' + $work)

function Want([string]$g) { return ($Filter.Count -eq 0 -or $Filter -contains $g) }

# =====================================================================
# 组 A：paths —— 路径解析（$env:EP_RUNTIME / EP_EXEPATH 覆盖优先级）
# =====================================================================
if (Want 'paths') {
    Write-Host ''
    Write-Host '--- 组 paths ---' -ForegroundColor DarkCyan

    $rt = Get-RuntimeCacheDir
    Assert-True 'paths' 'EP_RUNTIME 被采纳' ($rt -like ('*ep-core-tests*')) $rt
    Assert-True 'paths' '运行时目录已创建' (Test-Path -LiteralPath $rt) $rt

    $sc = Get-StatusCachePath
    Assert-True 'paths' 'status.json 落在运行时目录下' ($sc -like (Join-Path $rt 'status.json')) $sc
    Assert-Eq   'paths' 'status 缓存路径可重复取（内部缓存）' $sc (Get-StatusCachePath)

    $oldExe = $env:EP_EXEPATH
    $fakeExe = Join-Path $work 'MyPanel.exe'
    Set-Content -LiteralPath $fakeExe -Value 'x'
    $env:EP_EXEPATH = $fakeExe
    Assert-Eq 'paths' 'EP_EXEPATH 优先（真实存在时采纳）' $fakeExe (Get-PanelExePath)

    # EP_EXEPATH 指向不存在的文件 → 回落到 $pkgRoot 下的默认名
    $env:EP_EXEPATH = (Join-Path $work 'not-there.exe')
    Assert-True 'paths' 'EP_EXEPATH 无效时返回 null（$pkgRoot 下也没有）' ($null -eq (Get-PanelExePath)) ''

    Set-Content -LiteralPath (Join-Path $pkgRoot 'EdgePanel.exe') -Value 'x'
    Assert-Eq 'paths' '回落到 $pkgRoot\EdgePanel.exe' (Join-Path $pkgRoot 'EdgePanel.exe') (Get-PanelExePath)

    if ($oldExe) { $env:EP_EXEPATH = $oldExe } else { Remove-Item Env:\EP_EXEPATH -ErrorAction SilentlyContinue }
}

# =====================================================================
# 组 B：pkg/安全目录 —— Test-SafeDeployDir（防误部署到杂乱目录）
# =====================================================================
if (Want 'pkg') {
    Write-Host ''
    Write-Host '--- 组 pkg ---' -ForegroundColor DarkCyan

    # B1 空目录 → 允许
    $d1 = Join-Path $work 'empty'
    New-Item -ItemType Directory -Force -Path $d1 | Out-Null
    $r1 = Test-SafeDeployDir $d1
    Assert-True 'pkg' '空目录允许部署' ($r1.Ok -eq $true) ($r1.Others -join ',')

    # B2 只有面板 EXE + 备份包 + Data/Cache → 允许
    $d2 = Join-Path $work 'clean'
    New-Item -ItemType Directory -Force -Path (Join-Path $d2 'Data'), (Join-Path $d2 'Cache') | Out-Null
    Set-Content (Join-Path $d2 'EdgePanel.exe') 'x'
    Set-Content (Join-Path $d2 'Edge_Portable_data_20260101.7z') 'x'
    $r2 = Test-SafeDeployDir $d2
    Assert-True 'pkg' '面板EXE+备份包+Data/Cache 允许部署' ($r2.Ok -eq $true) ($r2.Others -join ',')

    # B3 有杂物 → 拒绝，且列出杂物
    $d3 = Join-Path $work 'dirty'
    New-Item -ItemType Directory -Force -Path $d3 | Out-Null
    Set-Content (Join-Path $d3 'readme.txt') 'x'
    New-Item -ItemType Directory -Force -Path (Join-Path $d3 'Documents') | Out-Null
    $r3 = Test-SafeDeployDir $d3
    Assert-True 'pkg' '有杂物时拒绝部署' ($r3.Ok -eq $false)
    Assert-True 'pkg' '杂物被列出（文件）' (@($r3.Others) -contains 'readme.txt') ($r3.Others -join ',')
    Assert-True 'pkg' '杂物被列出（目录带反斜杠）' (@($r3.Others) -contains 'Documents\') ($r3.Others -join ',')

    # B4 目录不存在 → 拒绝
    $r4 = Test-SafeDeployDir (Join-Path $work 'nope')
    Assert-True 'pkg' '目录不存在时拒绝' ($r4.Ok -eq $false)
    Assert-True 'pkg' '不存在时给出原因' (@($r4.Others) -contains '目录不存在') ($r4.Others -join ',')

    # B5 空字符串 → 拒绝
    $r5 = Test-SafeDeployDir ''
    Assert-True 'pkg' '空路径拒绝' ($r5.Ok -eq $false)

    # B6 含 Edge 目录时应当**拒绝**：Test-SafeDeployDir 只放行 Data/Cache/面板EXE/备份包，Edge\ 不在白名单
    $d6 = Join-Path $work 'withedge'
    New-Item -ItemType Directory -Force -Path (Join-Path $d6 'Edge') | Out-Null
    $r6 = Test-SafeDeployDir $d6
    Assert-True 'pkg' '含 Edge 目录时拒绝（Edge 不算可忽略项）' ($r6.Ok -eq $false) ($r6.Others -join ',')
}

# =====================================================================
# 组 C：pkg/必需件 —— Test-EssentialSet（缺件识别，决定"能不能起得来"）
# =====================================================================
if (Want 'pkg') {
    Write-Host ''
    Write-Host '--- 组 essential ---' -ForegroundColor DarkCyan

    $edge = Join-Path $work 'edge'
    $ver = Join-Path $edge '999.0.0.1'
    New-Item -ItemType Directory -Force -Path (Join-Path $ver 'Locales') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ver 'WidevineCdm\_platform_specific\win_x64') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ver 'EBWebView\x64') | Out-Null

    # 先造"全缺"状态
    $empty = Test-EssentialSet $edge
    Assert-True 'essential' '全缺时报出必需件' (@($empty.Required).Count -gt 0) ('缺 ' + @($empty.Required).Count + ' 项')
    Assert-True 'essential' '版本目录被识别' ($empty.Ver -eq '999.0.0.1') $empty.Ver

    # 补齐必需件
    Set-Content (Join-Path $edge 'msedge.exe') 'x'
    Set-Content (Join-Path $edge 'version.dll') 'x'
    Set-Content (Join-Path $edge 'chrome++.ini') 'x'
    Set-Content (Join-Path $ver 'msedge.dll') 'x'
    $after = Test-EssentialSet $edge
    Assert-Eq 'essential' '补齐必需件后 Required 为空' 0 (@($after.Required).Count)
    Assert-True 'essential' '功能件仍报缺（msedge_elf 等）' (@($after.Feature).Count -gt 0) ('缺 ' + @($after.Feature).Count + ' 项')

    # 补齐全部功能件
    foreach ($f in 'msedge.exe', 'msedge_elf.dll', 'ffmpeg.dll', 'd3dcompiler_47.dll',
        'vk_swiftshader.dll', 'icudtl.dat', 'resources.pak', 'v8_context_snapshot.bin') {
        Set-Content (Join-Path $ver $f) 'x'
    }
    Set-Content (Join-Path $ver 'Locales\zh-CN.pak') 'x'
    Set-Content (Join-Path $ver 'Locales\en-US.pak') 'x'
    Set-Content (Join-Path $ver 'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll') 'x'
    Set-Content (Join-Path $ver 'EBWebView\x64\EmbeddedBrowserWebView.dll') 'x'
    Set-Content (Join-Path $edge 'msedge_proxy.exe') 'x'
    $full = Test-EssentialSet $edge
    Assert-Eq 'essential' '全齐后 Required 为空' 0 (@($full.Required).Count)
    Assert-Eq 'essential' '全齐后 Feature 为空' 0 (@($full.Feature).Count)

    # 版本目录不存在时不崩，且必需件带上未替换的占位
    $nov = Join-Path $work 'edge-nover'
    New-Item -ItemType Directory -Force -Path $nov | Out-Null
    $rn = Test-EssentialSet $nov
    Assert-True 'essential' '无版本目录时不抛异常' ($null -ne $rn)
    Assert-True 'essential' '无版本目录时 Ver 为空' ([string]::IsNullOrEmpty($rn.Ver)) ('Ver=' + $rn.Ver)
}

# =====================================================================
# 组 D：pkg/结构漂移 —— Get-PkgSnapshot + Test-StructureDrift
# =====================================================================
if (Want 'drift') {
    Write-Host ''
    Write-Host '--- 组 drift ---' -ForegroundColor DarkCyan

    $e1 = Join-Path $work 'snap1'
    # 版本目录必须叫 x.x.x.x：Get-PkgSnapshot 只对匹配该格式的目录做 {ver} 归一化
    New-Item -ItemType Directory -Force -Path (Join-Path $e1 '120.0.1.1') | Out-Null
    # 用 WriteAllText 精确控制字节数（Set-Content 会额外追加 CRLF，导致 total 断言失真）
    [System.IO.File]::WriteAllText((Join-Path $e1 '120.0.1.1\a.dll'), ('x' * 100))
    [System.IO.File]::WriteAllText((Join-Path $e1 '120.0.1.1\b.dll'), ('x' * 200))

    $snap = Get-PkgSnapshot $e1 'test-scope'
    Assert-True 'drift' '快照含 total' ($snap.total -gt 0) ([string]$snap.total)
    Assert-True 'drift' '快照含 2 个文件条目' ($snap.files.Count -eq 2) ([string]$snap.files.Count)
    Assert-True 'drift' '版本目录被归一化成 {ver}' ($snap.files.ContainsKey('{ver}\a.dll')) (($snap.files.PSObject.Properties.Name) -join ',')
    Assert-Eq 'drift' '快照记录版本号' '120.0.1.1' $snap.version
    Assert-Eq 'drift' '总体积等于两文件之和' 300 $snap.total

    $snapPath = Join-Path $env:EP_RUNTIME 'snap.json'
    Save-PkgSnapshot $snap $snapPath
    Assert-True 'drift' '快照已落盘' (Test-Path -LiteralPath $snapPath)
    $reload = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json
    Assert-True 'drift' '落盘后可回读（files 保留）' ($reload.files.PSObject.Properties.Name.Count -eq 2) ([string]$reload.files.PSObject.Properties.Name.Count)

    # 首次比对：无基线 → 返回快照且不报错
    $first = Test-StructureDrift $e1 'test-scope'
    Assert-True 'drift' '首次比对返回快照' ($null -ne $first)
    # 设计意图：首次比对只返回快照，不落盘——由调用方在「覆盖成功」后才写，避免回滚时基线跟着跑偏
    Assert-True 'drift' '首次比对不落盘（基线延迟到覆盖成功后写）' (-not (Test-Path -LiteralPath (Join-Path $env:EP_RUNTIME 'cache\last_pkg_snapshot.json'))) ''
    # ---- 漂移比对的 5 条分支（原来只测了「首次无基线」这一条）----
    $snapFile = Join-Path $env:EP_RUNTIME 'cache\last_pkg_snapshot.json'

    # 建立基线
    Save-PkgSnapshot (Get-PkgSnapshot $e1 'test-scope') $snapFile
    Assert-True 'drift' '基线已建立' (Test-Path -LiteralPath $snapFile)

    # 分支 C：结构相同 → 不报警
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'test-scope'
    Assert-Eq 'drift' '结构相同不产生任何告警' 0 $script:captured.Count

    # 分支 D：新增文件 → 报「新增 1」
    [System.IO.File]::WriteAllText((Join-Path $e1 '120.0.1.1\c.dll'), ('y' * 50))
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'test-scope'
    $driftText = ($script:captured | ForEach-Object { $_.Text }) -join ' / '
    Assert-True 'drift' '新增文件会报「新增 1」' ($driftText -match '新增 1') $driftText
    Assert-True 'drift' '新增条目被逐条列出' ($driftText -match '\+ \{ver\}\\c\.dll') $driftText
    Save-PkgSnapshot (Get-PkgSnapshot $e1 'test-scope') $snapFile   # 重设基线

    # 分支 E：消失文件 → 报「消失 1」
    Remove-Item -LiteralPath (Join-Path $e1 '120.0.1.1\c.dll') -Force
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'test-scope'
    $driftText2 = ($script:captured | ForEach-Object { $_.Text }) -join ' / '
    Assert-True 'drift' '消失文件会报「消失 1」' ($driftText2 -match '消失 1') $driftText2
    Save-PkgSnapshot (Get-PkgSnapshot $e1 'test-scope') $snapFile

    # 分支 F：scope 变了 → 判定不可比对并重建
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'another-scope'
    $scopeText = ($script:captured | ForEach-Object { $_.Text }) -join ' / '
    Assert-True 'drift' 'scope 变化时判定不可比对' ($scopeText -match '不可比对') $scopeText

    # 分支 G：基线 JSON 损坏 → 告警并重建
    [System.IO.File]::WriteAllText($snapFile, '{ 这不是合法 JSON ')
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'another-scope'
    $brokenText = ($script:captured | ForEach-Object { $_.Text }) -join ' / '
    Assert-True 'drift' '基线损坏时告警并要求重建' ($brokenText -match '损坏') $brokenText

    # 分支 H：上游带回 msedge_renderer.dll → 单独告警
    Save-PkgSnapshot (Get-PkgSnapshot $e1 'test-scope') $snapFile
    [System.IO.File]::WriteAllText((Join-Path $e1 '120.0.1.1\msedge_renderer.dll'), ('z' * 1024))
    $script:captured.Clear()
    $null = Test-StructureDrift $e1 'test-scope'
    $rendText = ($script:captured | ForEach-Object { $_.Text }) -join ' / '
    Assert-True 'drift' 'renderer 回归时提示再瘦身' ($rendText -match 'msedge_renderer') $rendText
    Remove-Item -LiteralPath (Join-Path $e1 '120.0.1.1\msedge_renderer.dll') -Force
    Remove-Item -LiteralPath $snapFile -Force -ErrorAction SilentlyContinue

    # ---- 版本归一化的边界 ----
    # 目录名不是 x.x.x.x → 不做 {ver} 替换，version 为 null
    $e2 = Join-Path $work 'snap-nover'
    New-Item -ItemType Directory -Force -Path (Join-Path $e2 'not-a-version') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $e2 'not-a-version\x.dll'), ('x' * 10))
    $snap2 = Get-PkgSnapshot $e2 'nover'
    Assert-True 'drift' '非版本目录名不做 {ver} 归一化' ($null -eq $snap2.version) ([string]$snap2.version)
    Assert-True 'drift' '非版本目录名保留原相对路径' ($snap2.files.ContainsKey('not-a-version\x.dll')) (($snap2.files.PSObject.Properties.Name) -join ',')

    # x.x.x.x.manifest 文件要归一化成 {ver}.manifest
    $e3 = Join-Path $work 'snap-manifest'
    New-Item -ItemType Directory -Force -Path (Join-Path $e3 '120.0.1.1') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $e3 '120.0.1.1.manifest'), 'm')
    $snap3 = Get-PkgSnapshot $e3 'mani'
    Assert-True 'drift' '版本清单文件归一化成 {ver}.manifest' ($snap3.files.ContainsKey('{ver}.manifest')) (($snap3.files.PSObject.Properties.Name) -join ',')
}

# =====================================================================
# 组 E：持久化 —— Save-LastPkgRoot / Get-LastSavedPkgRoot
# =====================================================================
if (Want 'persist') {
    Write-Host ''
    Write-Host '--- 组 persist ---' -ForegroundColor DarkCyan

    $fakeRoot = Join-Path $work 'fake-pkg'
    New-Item -ItemType Directory -Force -Path $fakeRoot | Out-Null
    Save-LastPkgRoot $fakeRoot
    $got = Get-LastSavedPkgRoot
    Assert-Eq 'persist' '记住的包根可读回' $fakeRoot $got

    # 目录被删后仍返回记录（由调用方用 Test-PortableEdgeDir 判断有效性）
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force
    Assert-Eq 'persist' '目录消失后仍返回记录（有效性交给调用方）' $fakeRoot (Get-LastSavedPkgRoot)
}

# =====================================================================
# 组 F：系统 —— Get-DriveFreeMB
# =====================================================================
if (Want 'system') {
    Write-Host ''
    Write-Host '--- 组 system ---' -ForegroundColor DarkCyan

    $mb = Get-DriveFreeMB $work
    Assert-True 'system' '磁盘余量返回正数' ($null -ne $mb -and $mb -gt 0) ([string]$mb)
    # 不存在的盘：DriveInfo 可能返回 0 也可能抛（→null），关键是「不抛异常」
    $bad = Get-DriveFreeMB 'Z:\definitely-not-here'
    Assert-True 'system' '不存在的盘不抛异常（返回 null 或 0）' (($null -eq $bad) -or ($bad -eq 0)) ([string]$bad)
}

# =====================================================================
# 组 G：log —— 块顺序与 -Det 过滤（Write-Log 的行为契约）
# =====================================================================
if (Want 'log') {
    Write-Host ''
    Write-Host '--- 组 log ---' -ForegroundColor DarkCyan

    $script:captured.Clear()
    Start-LogBlock
    Write-Log 'in-block-A'
    Write-Log 'in-block-B'
    Assert-Eq 'log' '块未结束时不外泄' 0 $script:captured.Count
    End-LogBlock
    Assert-Eq 'log' '块结束后整块吐出' 2 $script:captured.Count
    Assert-Eq 'log' '块内顺序保持（A 在前）' 'in-block-A' $script:captured[0].Text
    Assert-Eq 'log' '块内顺序保持（B 在后）' 'in-block-B' $script:captured[1].Text

    $script:captured.Clear()
    Write-Log 'visible-line'
    Write-Log 'detail-line' 'info' -Det
    Assert-Eq 'log' '-Det 明细不上界面' 1 $script:captured.Count
    Assert-Eq 'log' '-Det 之外的照常' 'visible-line' $script:captured[0].Text

    $script:captured.Clear()
    Write-Log 'lvl-ok' 'ok'
    Write-Log 'lvl-warn' 'warn'
    Write-Log 'lvl-err' 'err'
    Assert-Eq 'log' '级别被翻译成中文标签' '完成' $script:captured[0].Tag
    Assert-Eq 'log' 'warn 标签' '警告' $script:captured[1].Tag
    Assert-Eq 'log' 'err 标签' '失败' $script:captured[2].Tag
    Assert-True 'log' 'row 只含 Level 不含颜色' ($null -ne $script:captured[0].Level -and $null -eq $script:captured[0].PSObject.Properties['Clr']) ''

    # 嵌套块
    $script:captured.Clear()
    Start-LogBlock
    Write-Log 'outer-1'
    Start-LogBlock
    Write-Log 'inner-1'
    End-LogBlock
    Assert-Eq 'log' '嵌套内层结束不吐出' 0 $script:captured.Count
    End-LogBlock
    Assert-Eq 'log' '嵌套外层结束一起吐出' 2 $script:captured.Count
}

# =====================================================================
# 组 H：Write-CleanerOutput 的 Brief 过滤（界面只留关键行）
# =====================================================================
if (Want 'cleaner') {
    Write-Host ''
    Write-Host '--- 组 cleaner ---' -ForegroundColor DarkCyan

    $lines = @(
        '清理前：1200 MB'
        '扩展占用 Top5:'
        '  1. Bitwarden 114.7 MB'
        '清理后：800 MB'
        '实际释放：400 MB'
        '（附带说明）xxx'
        '[跳过] 某文件'
    )
    $script:captured.Clear()
    Write-CleanerOutput $lines -Brief
    $texts = @($script:captured | ForEach-Object { $_.Text })
    Assert-True 'cleaner' 'Brief 保留「清理前」' (@($texts | Where-Object { $_ -like '清理前*' }).Count -eq 1) ($texts -join ' / ')
    Assert-True 'cleaner' 'Brief 保留「实际释放」' (@($texts | Where-Object { $_ -like '实际释放*' }).Count -eq 1) ($texts -join ' / ')
    Assert-True 'cleaner' 'Brief 过滤掉扩展 Top5 明细' (@($texts | Where-Object { $_ -like '*Bitwarden*' }).Count -eq 0) ($texts -join ' / ')
}

# ---------------- 收尾 ----------------
if ($oldRuntime) { $env:EP_RUNTIME = $oldRuntime } else { Remove-Item Env:\EP_RUNTIME -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

$fail = @($script:Results | Where-Object { -not $_.Ok })
$pass = @($script:Results | Where-Object { $_.Ok })
Write-Host ''
Write-Host ('==== 结果：' + $pass.Count + ' 通过 / ' + $fail.Count + ' 失败 ====') `
    -ForegroundColor $(if ($fail.Count -eq 0) { 'Green' } else { 'Red' })
if ($fail.Count -gt 0) {
    Write-Host '失败明细：' -ForegroundColor Red
    foreach ($f in $fail) { Write-Host ('  [' + $f.Group + '] ' + $f.Name + '  → ' + $f.Detail) -ForegroundColor Red }
    exit 1
}
exit 0
