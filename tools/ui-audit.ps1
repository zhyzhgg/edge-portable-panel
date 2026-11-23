# ui-audit.ps1 —— 面板 GUI 几何体检（外部驱动，不改面板代码）
#
# 做法：用假包根 + 独立运行时目录拉起面板，用纯 Win32 EnumWindows 按自身拉起的 PID 定位句柄，
#       仅对单个 hwnd 做 UI Automation 窗口内遍历（严禁 RootElement.FindAll 扫描全桌面）；
#       检查越界 / 贴边 / 兄弟控件重叠，每档各存一张真实窗口截图。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-audit.ps1
#   powershell ... -File tools\ui-audit.ps1 -Scales 1,1.25 -NoUia
#
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Edge面板.exe'),
    [string]$FakePkg = (Join-Path $env:TEMP 'edgepanel-ui-audit-pkg'),
    [double[]]$Scales = @(1.0, 1.25),
    [int]$Margin = 8,          # 允许的最小留白（像素，按窗口内坐标）
    [string]$ShotDir = (Join-Path $env:TEMP 'edgepanel-ui-audit-shots'),
    [switch]$KeepOpen,
    [switch]$NoKill,     # 保留本脚本拉起的测试窗口不关闭（默认只优雅关闭自身拉起的 PID）
    [switch]$NoUia,      # 完全跳过 UIA（仅做 Win32 窗口几何校验与真窗截图，零 UIA 调用）
    [switch]$Stress,     # 额外跑一档：字号 ×1.25、坐标不放大（模拟高 DPI 机器上"字大框不变"）
    [ValidateSet('auto','light','dark')][string]$Theme = 'auto'  # 可强制验证浅色/深色主题
)

$ErrorActionPreference = 'Stop'
Write-Host '[ui-audit] 本工具只查询自己启动的进程窗口（纯 Win32 EnumWindows，零全桌面 UIA 枚举）' -ForegroundColor DarkGray
if (-not $NoUia) { Add-Type -AssemblyName UIAutomationClient }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('WinFind' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinFind {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static IntPtr FindByPids(uint[] targets) {
        if (targets == null || targets.Length == 0) return IntPtr.Zero;
        var set = new HashSet<uint>(targets);
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid) || !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString().IndexOf("WindowsForms", StringComparison.OrdinalIgnoreCase) < 0) return true;
            RECT r;
            if (GetWindowRect(h, out r) && (r.R - r.L) > 100 && (r.B - r.T) > 100) {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
}

function Get-ChildPids([int]$hostPid) {
    if ($hostPid -le 0) { return @() }
    try {
        return @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $hostPid) -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ProcessId)
    } catch { return @() }
}

function Stop-AuditProc([int]$hostPid) {
    # 绝不全局强杀系统上其它面板（避免误杀用户正开着的面板及反复强杀拖垮 explorer）
    if ($hostPid -le 0) { return }
    $childIds = Get-ChildPids $hostPid
    $targets = @($childIds) + @($hostPid)
    # 先优雅关窗（CloseMainWindow），最多等 3 秒，仍未退出再 Kill
    foreach ($tid in $targets) {
        try {
            $pr = Get-Process -Id $tid -ErrorAction SilentlyContinue
            if ($pr -and -not $pr.HasExited) { [void]$pr.CloseMainWindow() }
        } catch { }
    }
    for ($w = 0; $w -lt 15; $w++) {
        $alive = @($targets | Where-Object { $x = Get-Process -Id $_ -ErrorAction SilentlyContinue; $x -and -not $x.HasExited })
        if ($alive.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    foreach ($tid in $targets) {
        try {
            $pr = Get-Process -Id $tid -ErrorAction SilentlyContinue
            if ($pr -and -not $pr.HasExited) { $pr.Kill() }
        } catch { }
    }
    Start-Sleep -Milliseconds 300
}

function Get-PanelHwnd([int]$hostPid, [int]$timeoutSec = 15) {
    # 纯 Win32 按自身 PID 及子 powershell.exe PID 定位窗口；500ms 轮询、上限 15s，零 UIA 注入
    $rounds = [Math]::Max(1, [int]($timeoutSec * 2))
    $knownChildren = @()
    for ($i = 0; $i -lt $rounds; $i++) {
        if ($knownChildren.Count -eq 0) { $knownChildren = Get-ChildPids $hostPid }
        $pidList = New-Object 'System.Collections.Generic.List[uint32]'
        [void]$pidList.Add([uint32]$hostPid)
        foreach ($cid in $knownChildren) { if ($cid -gt 0) { [void]$pidList.Add([uint32]$cid) } }
        $hwnd = [WinFind]::FindByPids($pidList.ToArray())
        if ($hwnd -ne [IntPtr]::Zero) { return $hwnd }
        Start-Sleep -Milliseconds 500
    }
    return [IntPtr]::Zero
}

function Get-Descendants($el) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $out = New-Object System.Collections.ArrayList
    function Walk($node, $depth) {
        if ($depth -gt 8) { return }
        $child = $walker.GetFirstChild($node)
        while ($child -ne $null) {
            [void]$out.Add([pscustomobject]@{ El = $child; Depth = $depth; Parent = $node })
            Walk $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }
    Walk $el 0
    return $out
}

if (-not (Test-Path -LiteralPath $Exe)) {
    foreach ($cand in @((Join-Path (Split-Path $PSScriptRoot -Parent) 'Edge面板.exe'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'EdgePanel.exe'))) {
        if (Test-Path -LiteralPath $cand) { $Exe = $cand; break }
    }
}
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "未找到 Edge面板.exe（当前路径：$Exe）。请先运行 build.ps1，或用 -Exe 指定路径。"
}
$report = New-Object System.Collections.ArrayList
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
$failTotal = 0

foreach ($scale in $Scales) {
    $env:EP_ALLOW_MULTI = '1'   # 与用户可能正开着的面板隔离，无需杀用户面板
    $rt = Join-Path $env:TEMP ('ui-audit-rt-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $env:EP_RUNTIME = $rt
    $env:EP_TEST_PKGROOT = $FakePkg
    $env:EP_NO_PROMPT = '1'
    if ($Theme -ne 'auto') { $env:EP_THEME = $Theme } else { Remove-Item Env:EP_THEME -ErrorAction SilentlyContinue }
    $env:EP_UI_BASE = [string]$scale
    if ($Stress -and [math]::Abs($scale - 1.0) -lt 0.001) {
        $env:EP_UI_BASE = '1.25'
        $env:EP_UI_SCALE = '0.8'
    } else {
        Remove-Item Env:EP_UI_SCALE -ErrorAction SilentlyContinue
    }
    Remove-Item Env:EP_RUNONCE -ErrorAction SilentlyContinue

    # 先把鼠标挪开：面板恰好出现在光标下时会弹 ToolTip（如"应用推荐策略"的长提示），
    # 它会被 UIA 当子节点枚举成"越界/重叠"，属纯测试噪声
    try {
        $oldPos = [System.Windows.Forms.Cursor]::Position
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(2, 2)
        Start-Sleep -Milliseconds 120
    } catch { $oldPos = $null }
    $p = Start-Process -FilePath $Exe -PassThru
    $hwnd = Get-PanelHwnd $p.Id 15
    if ($hwnd -eq [IntPtr]::Zero) { Write-Host "[FAIL] $scale× 没等到窗口" -ForegroundColor Red; $failTotal++; if (-not $NoKill) { Stop-AuditProc $p.Id }; continue }
    Start-Sleep -Milliseconds 1500  # 等首帧显形与状态刷新稳定，避免两档控件数竞争

    $rect = New-Object WinFind+RECT
    [void][WinFind]::GetWindowRect($hwnd, [ref]$rect)
    $winL = $rect.L; $winT = $rect.T
    $winW = $rect.R - $rect.L; $winH = $rect.B - $rect.T

    $issues = New-Object System.Collections.ArrayList
    $nodes = @()
    if (-not $NoUia) {
        # 只对找到的单个 hwnd 构造 UIA 元素，绝不触碰 RootElement
        $win = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $wr = $win.Current.BoundingRectangle
        $winL = [int]$wr.Left; $winT = [int]$wr.Top
        $winW = [int]$wr.Width; $winH = [int]$wr.Height
        $items = Get-Descendants $win
        # 过滤掉 ToolTip 窗口：它是 form 的拥有窗口，UIA 会把它当子节点枚举出来，
        # 长文案 tooltip 会被误判成"控件越界/重叠"（纯测试工具噪声，不是界面缺陷）
        $nodes = @($items | Where-Object {
                $r = $_.El.Current.BoundingRectangle
                $cls = ''
                try { $cls = [string]$_.El.Current.ClassName } catch { }
                $ct = ''
                try { $ct = [string]$_.El.Current.ControlType.ProgrammaticName } catch { }
                $r.Width -gt 0 -and $r.Height -gt 0 -and -not $_.El.Current.IsOffscreen -and
                $cls -ne 'tooltips_class32' -and $ct -ne 'ControlType.ToolTip'
            })

        foreach ($n in $nodes) {
            $el = $n.El; $r = $el.Current.BoundingRectangle
            $dt = $el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
            $name = ($el.Current.Name -replace '\s+', ' ')
            if ($name.Length -gt 28) { $name = $name.Substring(0, 28) + '…' }
            $relL = $r.Left - $wr.Left; $relT = $r.Top - $wr.Top
            $relR = $r.Right - $wr.Left; $relB = $r.Bottom - $wr.Top
            if ($relR -gt $wr.Width -or $relB -gt $wr.Height -or $relL -lt 0 -or $relT -lt 0) {
                [void]$issues.Add([pscustomobject]@{ 级别='越界'; 类型=$dt; 文字=$name; 详情=("右 {0:N0} / 下 {1:N0} 超出窗口 {2:N0}×{3:N0}" -f $relR, $relB, $wr.Width, $wr.Height) })
            } elseif ($relR -gt $wr.Width - $Margin -or $relB -gt $wr.Height - $Margin) {
                [void]$issues.Add([pscustomobject]@{ 级别='贴边'; 类型=$dt; 文字=$name; 详情=("距右下边距不足 {0}px" -f $Margin) })
            }
        }

        $byParent = $nodes | Group-Object { $_.Parent.GetHashCode() }
        foreach ($g in $byParent) {
            $arr = @($g.Group)
            for ($i = 0; $i -lt $arr.Count; $i++) {
                for ($j = $i + 1; $j -lt $arr.Count; $j++) {
                    $ra = $arr[$i].El.Current.BoundingRectangle
                    $rb = $arr[$j].El.Current.BoundingRectangle
                    $a = New-Object System.Drawing.Rectangle([int]$ra.Left, [int]$ra.Top, [int]$ra.Width, [int]$ra.Height)
                    $b = New-Object System.Drawing.Rectangle([int]$rb.Left, [int]$rb.Top, [int]$rb.Width, [int]$rb.Height)
                    $inter = [System.Drawing.Rectangle]::Intersect($a, $b)
                    if ($inter.Width -gt 2 -and $inter.Height -gt 2) {
                        $ta = ($arr[$i].El.Current.Name -replace '\s+', ' '); if ($ta.Length -gt 18) { $ta = $ta.Substring(0, 18) + '…' }
                        $tb = ($arr[$j].El.Current.Name -replace '\s+', ' '); if ($tb.Length -gt 18) { $tb = $tb.Substring(0, 18) + '…' }
                        [void]$issues.Add([pscustomobject]@{ 级别='重叠'; 类型='—'; 文字="$ta ／ $tb"; 详情=("重叠 {0}×{1}px" -f $inter.Width, $inter.Height) })
                    }
                }
            }
        }
    } elseif ($winW -lt 200 -or $winH -lt 200) {
        [void]$issues.Add([pscustomobject]@{ 级别='尺寸异常'; 类型='Window'; 文字='主窗口'; 详情=("Win32 尺寸异常：{0}×{1}" -f $winW, $winH) })
    }

    # 截图（真实窗口）
    $shot = Join-Path $ShotDir ("panel-" + [int]($scale * 100) + ".png")
    try {
        $bmp = New-Object System.Drawing.Bitmap($winW, $winH)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($winL, $winT, 0, 0, $bmp.Size)
        $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    } catch { $shot = '(截图失败)' }

    $state = if ($issues.Count -eq 0) { 'PASS' } else { 'FAIL' }
    if ($issues.Count -gt 0) { $failTotal++ }
    $cntLabel = if ($NoUia) { '跳过(NoUia)' } else { [string]$nodes.Count }
    [void]$report.Add([pscustomobject]@{
            缩放 = "$scale×"; 窗口 = ("{0:N0}×{1:N0}" -f $winW, $winH); 控件数 = $cntLabel
            结论 = $state; 问题数 = $issues.Count; 截图 = $shot
        })
    Write-Host ("`n=== {0}× 窗口 {1:N0}×{2:N0}，控件 {3}：{4} ===" -f $scale, $winW, $winH, $cntLabel, $state) `
        -ForegroundColor ($(if ($state -eq 'PASS') { 'Green' } else { 'Red' }))
    foreach ($it in $issues | Select-Object -First 15) {
        Write-Host ("  [{0}] {1}  {2}  —— {3}" -f $it.级别, $it.类型, $it.文字, $it.详情) -ForegroundColor Yellow
    }
    if ($issues.Count -gt 15) { Write-Host ("  …还有 {0} 条" -f ($issues.Count - 15)) -ForegroundColor Yellow }

    Write-Host ("  截图：{0}" -f $shot)
    if (-not $KeepOpen -and -not $NoKill) { Stop-AuditProc $p.Id }
}

Remove-Item Env:EP_UI_BASE,Env:EP_UI_SCALE,Env:EP_THEME,Env:EP_ALLOW_MULTI -ErrorAction SilentlyContinue
Write-Host "`n===== 汇总 ====="
$report | Format-Table -AutoSize
if ($failTotal -gt 0) { Write-Host "结论：有档位未通过" -ForegroundColor Red; exit 1 } else { Write-Host "结论：全部通过" -ForegroundColor Green; exit 0 }
