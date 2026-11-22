#Requires -Version 5.1
<#
    便携 Edge 精简设置（Debloater GUI）中文启动器 v2

    与 v1 的差别：提权改在本脚本里做（只弹一次 UAC），并在启动后核实 GUI 真的起来了；
    每一步都写 work\launch.log，失败会把子进程的 stdout/stderr 一并记下来，不会再"闪一下就没"。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipFetch,
    [switch]$Elevated,
    [switch]$NoElevate,
    # 由面板传入的 Edge 目录（脚本被解包到 AppData 时靠它定位便携包）
    [string]$EdgeRoot
)

$ErrorActionPreference = 'Stop'
# 公共函数（包根定位等）只维护一份，在本脚本的上一级目录
. (Join-Path (Split-Path $PSScriptRoot -Parent) '_Common.ps1')
$here = $PSScriptRoot
if ($EdgeRoot) { $edge = $EdgeRoot }
elseif ($env:EP_EXEDIR) { $pkgRoot = Find-PackageRoot $env:EP_EXEDIR; $edge = Join-Path $pkgRoot 'Edge' }
else { $pkgRoot = Find-PackageRoot $here; $edge = Join-Path $pkgRoot 'Edge' }
# 与面板共用 _Common.ps1 的 Get-ZhWorkDir，跨解包键复用中文副本且杜绝双处路径漂移
$work = Get-ZhWorkDir $here
$url = 'https://edgev2.bibica.net/debloater-gui.ps1'
$src = Join-Path $work 'src.ps1'
$out = Join-Path $work 'out.ps1'
$report = Join-Path $work 'translate-report.txt'
$logPath = Join-Path $work 'launch.log'

if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
try { Add-Content -LiteralPath $logPath -Value ("`r`n===== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " 启动 =====") -Encoding UTF8 } catch { }

function Log([string]$m, [string]$color = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $m -ForegroundColor $color
}

try {
    # ---- 0. 自检 ----
    if (-not (Test-Path -LiteralPath (Join-Path $edge 'msedge.exe'))) {
        Log "错误：找不到 $edge\msedge.exe" 'Red'; throw 'edge folder missing'
    }

    # ---- 1. 提权（只在这里做一次） ----
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $DryRun -and -not $NoElevate) {
        Log '需要管理员权限，正在请求提权（请在弹窗里点"是"）…' 'Yellow'
        $argStr = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Elevated'
        if ($SkipFetch) { $argStr += ' -SkipFetch' }
        Log ("提权命令行：" + $argStr)
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argStr
        exit 0
    }
    Log ("权限：管理员=" + $isAdmin)

    # ---- 2. 取上游最新脚本 ----
    $good = $false
    if (-not $SkipFetch) {
        try {
            & curl.exe -fsSL --max-time 8 $url -o $src 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $src) -and (Get-Item $src).Length -gt 20000) {
                $head = Get-Content $src -TotalCount 8 -Encoding UTF8 -ErrorAction SilentlyContinue
                if (($head -join "`n") -match 'Debloater GUI') {
                    Log ("已下载最新脚本（" + [math]::Round((Get-Item $src).Length / 1KB) + " KB）") 'Green'
                    $good = $true
                } else {
                    Log '下载到的内容不像脚本（可能是错误页），改用本地副本' 'Yellow'
                }
            } else {
                Log ("下载失败（curl 退出码 " + $LASTEXITCODE + "），改用本地副本") 'Yellow'
            }
        } catch { Log ('下载异常：' + $_.Exception.Message + '，改用本地副本') 'Yellow' }
    }
    if (-not $good) {
        $localCopy = Join-Path $edge 'debloater-gui.ps1'
        if (Test-Path $localCopy) {
            Copy-Item $localCopy $src -Force
            Log ('使用 Edge 目录里的副本（' + (Get-Item $src).LastWriteTime + '）')
        } elseif (Test-Path $src) {
            Log ('使用上次下载的副本（' + (Get-Item $src).LastWriteTime + '）')
        } else {
            throw '既下载不到、也没有本地副本'
        }
    }

    # ---- 3. chrome++.ini ----
    $ini = Join-Path $edge 'chrome++.ini'
    if (Test-Path $ini) { Copy-Item $ini (Join-Path $work 'chrome++.ini') -Force }
    else { Log '警告：Edge 目录没有 chrome++.ini，策略键可能不对' 'Yellow' }

    # ---- 4. 翻译（能复用就复用）----
    # 复用条件：中文副本已存在，且不旧于「上游脚本 / 翻译脚本 / 词表」三者中最新的那个
    $mapFile = Join-Path $here 'zh-CN.json'
    $transFile = Join-Path $here 'translate.ps1'
    $reuse = $false
    if ((Test-Path -LiteralPath $out) -and (Test-Path -LiteralPath $src)) {
        try {
            $outTime = (Get-Item -LiteralPath $out).LastWriteTimeUtc
            $newest = (Get-Item -LiteralPath $src).LastWriteTimeUtc
            foreach ($f in @($transFile, $mapFile)) {
                if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).LastWriteTimeUtc -gt $newest) { $newest = (Get-Item -LiteralPath $f).LastWriteTimeUtc }
            }
            $reuse = ($outTime -ge $newest)
        } catch { $reuse = $false }
    }
    if ($reuse) {
        Log '复用上次的中文副本（上游脚本与词表都没变）' 'Green'
    } else {
        # 同进程调用翻译脚本，省掉一次 powershell.exe 冷启动
        & $transFile -Source $src -Out $out -Map $mapFile -Report $report | Out-Null
    }
    if (-not (Test-Path $out)) { throw '翻译没有生成 out.ps1' }
    $b = [System.IO.File]::ReadAllBytes($out)[0..2]
    if ($b[0] -eq 0xEF) { Log '已生成中文副本（UTF-8 with BOM）' 'Green' }
    else { Log '自检未通过 → 本次以英文原文启动（详见 translate-report.txt）' 'Yellow' }

    if ($DryRun) { Log '（-DryRun：不启动界面）'; exit 0 }

    # ---- 5. 启动 GUI（此时已是管理员，脚本不会再二次提权） ----
    $guiOut = Join-Path $work 'gui.out.log'
    $guiErr = Join-Path $work 'gui.err.log'
    Remove-Item $guiOut, $guiErr -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $out) `
        -RedirectStandardOutput $guiOut -RedirectStandardError $guiErr
    Log ("已拉起界面进程 pid=" + $p.Id + "，等待窗口…")

    # 首次窗口会继承 STARTUPINFO 的 SW_HIDE，导致"进程在跑但窗口看不见"——这里主动把它显示出来
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class GuiWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    public static IntPtr FindForm(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var c = new StringBuilder(200); GetClassNameW(h, c, 200);
            if (c.ToString().StartsWith("WindowsForms10.Window")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool ShowIt(IntPtr h) { ShowWindow(h, 5); SetForegroundWindow(h); return IsWindowVisible(h); }
}
"@ -ErrorAction SilentlyContinue

    $shown = $false
    $elevatedRestart = $false
    # GUI 有 142 条策略要建控件，冷启动可能要 5-10 秒；给足 30 秒并每 500ms 重试 ShowWindow
    for ($k = 0; $k -lt 60; $k++) {
        Start-Sleep -Milliseconds 500
        try { $p.Refresh() } catch { }
        try {
            $h = [GuiWin]::FindForm([uint32]$p.Id)
            if ($h -ne [IntPtr]::Zero) {
                if ([GuiWin]::ShowIt($h)) { $shown = $true; Log ('窗口已显示（第 ' + ($k + 1) + ' 次尝试）') 'Green'; break }
            }
        } catch { }
        if ($p.HasExited) {
            # 界面脚本自己会提权（Start-Process -Verb RunAs 隐藏重启），所以父进程退出是正常现象
            Log '界面进程已退出：它自己提权后重启了，请在屏幕上的 UAC 提示里点「是」' 'Yellow'
            $elevatedRestart = $true
            break
        }
    }
    if (-not $shown -and -not $elevatedRestart) {
        Log '没能让窗口显示出来' 'Red'
        foreach ($f in @($guiErr, $guiOut)) {
            if (Test-Path $f) {
                $x = Get-Content $f -Raw -Encoding UTF8
                if ($x -and $x.Trim()) { Log ("--- " + (Split-Path $f -Leaf) + " ---"); Log $x.Trim() 'Red' }
            }
        }
        throw '窗口没能显示（详情见 work\launch.log）'
    }
    Start-Sleep -Milliseconds 500
    $p.Refresh()
    if ($elevatedRestart) {
        Log '界面已交给提权后的实例启动；请在 UAC 提示里点「是」后稍等窗口出现' 'Green'
        exit 0
    }
    if ($p.HasExited -and -not $elevatedRestart) {
        Log ("界面进程已退出，退出码 " + $p.ExitCode) 'Red'
        foreach ($f in @($guiErr, $guiOut)) {
            if (Test-Path $f) {
                $t = Get-Content $f -Raw -Encoding UTF8
                if ($t -and $t.Trim()) { Log ("--- " + (Split-Path $f -Leaf) + " ---"); Log $t.Trim() 'Red' }
            }
        }
        throw '界面没能启动（详情见 work\launch.log）'
    }
    $win = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($win.MainWindowTitle) { Log ('界面已启动，窗口标题：' + $win.MainWindowTitle) 'Green' } else { Log '界面已启动（标题暂为空）' 'Green' }
    exit 0
} catch {
    Log ('失败：' + $_.Exception.Message) 'Red'
    Log '（完整日志：work\launch.log）' 'Red'
    if (-not $DryRun -and -not $NoElevate -and -not $Elevated) { Write-Host ''; Write-Host '按回车键关闭窗口…' -ForegroundColor Yellow; [void](Read-Host) }
    exit 1
}
