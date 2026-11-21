# ui-audit.ps1 —— 面板 GUI 几何体检（外部驱动，不改面板代码）
#
# 做法：用假包根 + 独立运行时目录拉起面板，用 UI Automation 读出每个控件的真实屏幕矩形，
#       换算成窗口内坐标后做四项检查：越界 / 贴边 / 兄弟控件重叠 / 文字疑似截断；
#       每档各存一张真实窗口截图。默认 1× 与 1.25× 各跑一次（1.25× 靠 EP_UI_BASE 模拟大字）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-audit.ps1
#   powershell ... -File tools\ui-audit.ps1 -Scales 1,1.25 -KeepOpen
#
param(
    [string]$Exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Edge面板.exe'),
    [string]$FakePkg = (Join-Path $env:TEMP 'edgepanel-ui-audit-pkg'),
    [double[]]$Scales = @(1.0, 1.25),
    [int]$Margin = 8,          # 允许的最小留白（像素，按窗口内坐标）
    [string]$ShotDir = (Join-Path $env:TEMP 'edgepanel-ui-audit-shots'),
    [switch]$KeepOpen,
    [switch]$Stress,     # 额外跑一档：字号 ×1.25、坐标不放大（模拟高 DPI 机器上"字大框不变"）
    [ValidateSet('auto','light','dark')][string]$Theme = 'auto'  # 可强制验证浅色/深色主题
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('Win32Rect' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public class Win32Rect { [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); }
'@
}

function Stop-Panels {
    Get-Process 'Edge面板' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*EdgePanel.ps1*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 600
}

function Get-WindowEl([int]$timeoutSec = 25) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window)
    for ($i = 0; $i -lt ($timeoutSec * 4); $i++) {
        foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            if ($w.Current.Name -like '便携 Edge 面板*' -and $w.Current.BoundingRectangle.Width -gt 100) { return $w }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
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
    Stop-Panels
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

    $p = Start-Process -FilePath $Exe -PassThru
    $win = Get-WindowEl
    if (-not $win) { Write-Host "[FAIL] $scale× 没等到窗口" -ForegroundColor Red; $failTotal++; try { $p.Kill() } catch { }; continue }
    Start-Sleep -Milliseconds 1500  # 等首帧显形与状态刷新稳定，避免两档控件数竞争

    $wr = $win.Current.BoundingRectangle
    $items = Get-Descendants $win
    # 只检查有实际尺寸、可见的元素
    $nodes = @($items | Where-Object {
            $r = $_.El.Current.BoundingRectangle
            $r.Width -gt 0 -and $r.Height -gt 0 -and -not $_.El.Current.IsOffscreen
        })

    $issues = New-Object System.Collections.ArrayList
    foreach ($n in $nodes) {
        $el = $n.El; $r = $el.Current.BoundingRectangle
        $dt = $el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        $name = ($el.Current.Name -replace '\s+', ' ')
        if ($name.Length -gt 28) { $name = $name.Substring(0, 28) + '…' }
        # 相对窗口的坐标
        $relL = $r.Left - $wr.Left; $relT = $r.Top - $wr.Top
        $relR = $r.Right - $wr.Left; $relB = $r.Bottom - $wr.Top
        # 1) 越界
        if ($relR -gt $wr.Width -or $relB -gt $wr.Height -or $relL -lt 0 -or $relT -lt 0) {
            [void]$issues.Add([pscustomobject]@{ 级别='越界'; 类型=$dt; 文字=$name; 详情=("右 {0:N0} / 下 {1:N0} 超出窗口 {2:N0}×{3:N0}" -f $relR, $relB, $wr.Width, $wr.Height) })
        }
        # 2) 贴边（留白不足）——只对顶着窗口边缘的元素有意义
        elseif ($relR -gt $wr.Width - $Margin -or $relB -gt $wr.Height - $Margin) {
            [void]$issues.Add([pscustomobject]@{ 级别='贴边'; 类型=$dt; 文字=$name; 详情=("距右下边距不足 {0}px" -f $Margin) })
        }
    }

    # 3) 同父兄弟重叠
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

    # 截图（真实窗口）
    $shot = Join-Path $ShotDir ("panel-" + [int]($scale * 100) + ".png")
    try {
        $w = [int]$wr.Width; $h = [int]$wr.Height
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen([int]$wr.Left, [int]$wr.Top, 0, 0, $bmp.Size)
        $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    } catch { $shot = '(截图失败)' }

    $state = if ($issues.Count -eq 0) { 'PASS' } else { 'FAIL' }
    if ($issues.Count -gt 0) { $failTotal++ }
    [void]$report.Add([pscustomobject]@{
            缩放 = "$scale×"; 窗口 = ("{0:N0}×{1:N0}" -f $wr.Width, $wr.Height); 控件数 = $nodes.Count
            结论 = $state; 问题数 = $issues.Count; 截图 = $shot
        })
    Write-Host ("`n=== {0}× 窗口 {1:N0}×{2:N0}，检查 {3} 个控件：{4} ===" -f $scale, $wr.Width, $wr.Height, $nodes.Count, $state) `
        -ForegroundColor ($(if ($state -eq 'PASS') { 'Green' } else { 'Red' }))
    foreach ($it in $issues | Select-Object -First 15) {
        Write-Host ("  [{0}] {1}  {2}  —— {3}" -f $it.级别, $it.类型, $it.文字, $it.详情) -ForegroundColor Yellow
    }
    if ($issues.Count -gt 15) { Write-Host ("  …还有 {0} 条" -f ($issues.Count - 15)) -ForegroundColor Yellow }

    Write-Host ("  截图：{0}" -f $shot)
    if (-not $KeepOpen) { Stop-Panels }
}

Remove-Item Env:EP_UI_BASE,Env:EP_UI_SCALE,Env:EP_THEME -ErrorAction SilentlyContinue
Write-Host "`n===== 汇总 ====="
$report | Format-Table -AutoSize
if ($failTotal -gt 0) { Write-Host "结论：有档位未通过" -ForegroundColor Red; exit 1 } else { Write-Host "结论：全部通过" -ForegroundColor Green; exit 0 }
