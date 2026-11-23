
#Requires -Version 5.1
<#
    便携 Edge 面板 —— 单文件 EXE（csc 宿主内嵌全部脚本；本文件即 EdgePanel.ps1）
    集成：瘦身 / 更新 Edge 本体 / 缓存清理与备份 / 推荐策略；由 Host.cs 解包后调用。
    保证"同一逻辑只有一份实现"。
    自测：Edge面板.exe -RunOnce Status（其余模式见 Add_Shown 的 switch 清单）
#>

$ErrorActionPreference = 'Stop'
$script:panelVersion = '1.3.6'
$script:panelUpdateRepo = 'zhyzhgg/edge-portable-panel'   # 自更新源（公开仓库 Releases）
# 面板 EXE 的标准名：打包判定 / 恢复白名单 / 恢复提示三处共用，避免口径分裂
$script:panelExeNameRe = '^(?i)(EdgePanel|Edge面板)\.exe$'
$script:panelProbePs = $null
$script:panelProbeRs = $null
$script:panelProbeHandle = $null
$script:panelProbeTimer = $null
$script:panelProbeDelay = $null
$script:pwaGapChecked = $false
$script:panelProbeDone = $false
$script:panelProbeCancel = $null
$script:policyKey = $env:EP_POLICY_KEY

# ---------- 引导：脚本目录（EXE 解包目录）与包根（EXE 所在目录）----------
# EP_APPDIR = 宿主解出来的脚本目录；EP_EXEDIR = EXE 所在目录（用来定位便携包）
$appDir = $env:EP_APPDIR
if (-not $appDir -or -not (Test-Path (Join-Path $appDir 'EdgeTune.ps1'))) { $appDir = $PSScriptRoot }
$exeDir = $env:EP_EXEDIR
if (-not $exeDir) { $exeDir = $PSScriptRoot }

$RunOnce = ''
if ($env:EP_RUNONCE) { $RunOnce = $env:EP_RUNONCE }
if ($env:EP_ARGS) {
    $mRun = [regex]::Match($env:EP_ARGS, '(?i)-RunOnce\s+([A-Za-z]+)')
    if ($mRun.Success) { $RunOnce = $mRun.Groups[1].Value }
}

$scriptsDir = $appDir
$edgeTune = Join-Path $scriptsDir 'EdgeTune.ps1'
$cleaner = Join-Path $scriptsDir 'Clean-EdgeCaches.ps1'
$runZh = Join-Path $scriptsDir 'zh-debloater\run-zh.ps1'

. (Join-Path $scriptsDir '_Common.ps1')

# 策略基线条数（工具提示/文案用，避免把数字写死在代码里）
$script:baselineCount = 0
$script:baselineSubCount = 0
$script:baselineLoadError = $null   # 基线 JSON 解析失败时记原因，Add_Shown 里报出来
try {
    $baselineFile0 = Join-Path $scriptsDir 'EdgePolicyBaseline.json'
    if (Test-Path -LiteralPath $baselineFile0) {
        # 注意：PS 5.1 的 ConvertFrom-Json 会把整个数组当成"不可枚举"的单个对象输出，
        # 用 @() 包起来只能得到 Count=1（里面才是 132 条）。这里用 foreach 逐条拍平。
        $rawB = [System.IO.File]::ReadAllText($baselineFile0, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $b0 = @()
        foreach ($e in $rawB) { $b0 += $e }
        $script:baseline = $b0            # F3 策略漂移体检逐条比对用
        $activeB0 = Get-ActiveBaselineRecords $b0
        $script:baselineCount = @($activeB0 | Where-Object { -not $_.sub }).Count
        $script:baselineSubCount = @($activeB0 | Where-Object { $_.sub }).Count
    }
} catch { $script:baselineLoadError = $_.Exception.Message }
$pkgRoot = Find-PackageRoot $exeDir
if (-not (Test-Path -LiteralPath (Join-Path $pkgRoot 'Edge\msedge.exe'))) {
    # 脚本装在 <包根>\.runtime\<版本>\ 里，向上找不到 Edge 时用 EXE 所在目录当包根，
    # 绝不能退到脚本目录（那会把 .runtime\版本 误当包根，界面显示一堆 0）
    $pkgRoot = $exeDir
}
if ($env:EP_TEST_PKGROOT) { $pkgRoot = $env:EP_TEST_PKGROOT }   # 自测用：指向假包，避免碰真包
$progDir = Resolve-ProgramDir $pkgRoot
$edgeRoot = Join-Path $pkgRoot 'Edge'
# R10：当前目录没有 Edge 程序（只拷了面板 EXE）时，状态卡显示占位符并禁用依赖包的功能
$script:noPackage = -not (Test-Path -LiteralPath (Join-Path $edgeRoot 'msedge.exe'))

# 策略键名跟着 chrome++.ini 的 policy_key 走（换了安装目录/改了 key 也能对上）
if (-not $script:policyKey) {
    $pkName = 'Portable'
    $iniFile = Resolve-EdgeIni $pkgRoot
    if ($iniFile) {
        $mPk = [regex]::Match((Get-Content -LiteralPath $iniFile -Raw -Encoding UTF8), '(?im)^\s*policy_key\s*=\s*(\S+)')
        if ($mPk.Success -and $mPk.Groups[1].Value.Trim()) { $pkName = $mPk.Groups[1].Value.Trim() }
    }
    $script:policyKey = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge_' + $pkName
}
$script:policyKeyPlain = $script:policyKey -replace '^HKCU:', 'HKEY_CURRENT_USER'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# 物理像素渲染（否则 125%/150% 缩放下发虚、坐标错位）
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiFix {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
"@
try { [void][DpiFix]::SetProcessDpiAwareness(1) } catch { try { [void][DpiFix]::SetProcessDPIAware() } catch { } }

# ---------------- DPI 缩放 ----------------
# 进程是 DPI 感知的（按物理像素绘制），而字体是点制（会随 DPI 放大）。
# 若控件坐标仍用固定像素，125%/150% 下就会"字变大、框不变"→ 截断错位。
# 做法：所有像素坐标统一过 S()（= 原值 × 当前 DPI/96），字体不再手工缩放。
# 2026-11-21 用户拍板：外观**完全回到 .122**（不做 DPI 缩放）。
# 旧版就是"按物理像素布局 + 点制字体随系统 DPI 放大"，用户要的就是那个观感（字大、窗口 870×676）。
# 仍保留 EP_UI_SCALE / EP_UI_BASE 两个环境变量，需要微调时可临时打开（默认 1.0 = 不缩放）。
$script:dpiScale = 1.0
$script:uiBase = 1.0
if ($env:EP_UI_SCALE) {
    $v = 0.0
    if ([double]::TryParse($env:EP_UI_SCALE, [ref]$v) -and $v -ge 0.5 -and $v -le 3.0) { $script:dpiScale = $v }
}
if ($env:EP_UI_BASE) {
    $b = 0.0
    if ([double]::TryParse($env:EP_UI_BASE, [ref]$b) -and $b -ge 0.75 -and $b -le 1.25) { $script:uiBase = $b }
}
$script:dpiScale = [math]::Round($script:dpiScale * $script:uiBase, 4)
function S([int]$v) { [int][math]::Round($v * $script:dpiScale) }
function FS([double]$pt) { return [single]($pt * $script:uiBase) }

# 自绘控件与系统主题工具集（一次 Add-Type，零外部依赖，C# 5 / .NET Framework 4.0）：
#   ThemeHelper —— Win11 原生深色标题栏 (DWMWA_USE_IMMERSIVE_DARK_MODE=20) + 滚动条深色适配
#   UiDraw      —— 圆角路径工具
#   FlatProgress—— 极简锐利直条进度条（8px 纯整数矩形，零 SetClip 锯齿，60fps 缓动 + 变速滑块）
#   CardPanel   —— 双层填充圆角卡片（1px 边在 AA 下四边完整不断线）
#   FlatBtn     —— 主题感知扁平圆角按钮（7 参 ClearType 锐利字体，NotifyDefault=false 根治 2px 焦框）
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class ThemeHelper {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string pszSubAppName, string pszSubIdList);

    public static void ApplyTitleBar(IntPtr hwnd, bool dark) {
        if (hwnd == IntPtr.Zero) return;
        int v = dark ? 1 : 0;
        try { DwmSetWindowAttribute(hwnd, 20, ref v, sizeof(int)); } catch { }
    }

    public static void ApplyDarkScroll(IntPtr hwnd, bool dark) {
        if (hwnd == IntPtr.Zero) return;
        try { SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : null, null); } catch { }
    }
}

public static class UiDraw {
    public static GraphicsPath RoundedRect(float x, float y, float w, float h, float r) {
        GraphicsPath p = new GraphicsPath();
        if (w <= 0f || h <= 0f) return p;
        float d = Math.Min(r * 2f, Math.Min(w, h));
        if (d < 1f) { p.AddRectangle(new RectangleF(x, y, w, h)); return p; }
        p.AddArc(x, y, d, d, 180f, 90f);
        p.AddArc(x + w - d, y, d, d, 270f, 90f);
        p.AddArc(x + w - d, y + h - d, d, d, 0f, 90f);
        p.AddArc(x, y + h - d, d, d, 90f, 90f);
        p.CloseFigure();
        return p;
    }
}

public class FlatProgress : Control {
    private int _target;
    private double _display;
    private bool _indeterminate;
    private double _phase;
    private System.Windows.Forms.Timer _timer;

    public Color BarColor { get; set; }
    public Color TrackColor { get; set; }
    public Color TrackBorderColor { get; set; }

    public FlatProgress() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BarColor = Color.FromArgb(37, 99, 235);
        TrackColor = Color.FromArgb(226, 232, 240);
        TrackBorderColor = Color.FromArgb(203, 213, 225);
        _timer = new System.Windows.Forms.Timer();
        _timer.Interval = 16;
        _timer.Tick += delegate { Animate(); };
    }

    public int Value {
        get { return _target; }
        set {
            int v = value; if (v < 0) v = 0; if (v > 100) v = 100;
            _target = v;
            if (_timer != null && !_timer.Enabled) _timer.Start();
        }
    }

    public bool Indeterminate {
        get { return _indeterminate; }
        set {
            if (_indeterminate == value) return;
            _indeterminate = value;
            if (!value) _display = _target;
            if (_timer != null && !_timer.Enabled) _timer.Start();
            Invalidate();
        }
    }

    protected override void Dispose(bool disposing) {
        if (disposing && _timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
        base.Dispose(disposing);
    }

    private void Animate() {
        if (_timer == null) return;
        bool dirty = false;
        if (_indeterminate) {
            _phase += 0.014;
            if (_phase >= 1.0) _phase -= 1.0;
            dirty = true;
        } else {
            double d = _target - _display;
            if (Math.Abs(d) > 0.06) { _display += d * 0.22; dirty = true; }
            else if (Math.Abs(d) > 0.0) { _display = _target; dirty = true; }
            if (!dirty) _timer.Stop();
        }
        if (dirty) Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        // 纯整数像素直条（类 VS Code / Linear）：彻底消除小圆角与 SetClip 导致的两端畸变/锯齿
        g.SmoothingMode = SmoothingMode.None;
        int w = Width, h = Height;
        if (w <= 2 || h <= 2) return;

        using (SolidBrush tb = new SolidBrush(TrackColor)) {
            g.FillRectangle(tb, 0, 0, w, h);
        }
        using (Pen bp = new Pen(TrackBorderColor, 1)) {
            g.DrawRectangle(bp, 0, 0, w - 1, h - 1);
        }

        int innerW = w - 2;
        int innerH = h - 2;
        if (innerW <= 0 || innerH <= 0) return;

        if (_indeterminate) {
            double t = _phase;
            double ease = (t < 0.5) ? (4.0 * t * t * t) : (1.0 - Math.Pow(-2.0 * t + 2.0, 3.0) / 2.0);
            int pillW = (int)Math.Round(innerW * (0.20 + 0.12 * Math.Sin(t * Math.PI)));
            if (pillW < 12) pillW = Math.Min(innerW, 12);
            int travel = innerW - pillW;
            int px = 1 + (travel > 0 ? (int)Math.Round(ease * travel) : 0);
            using (SolidBrush bb = new SolidBrush(BarColor)) {
                g.FillRectangle(bb, px, 1, pillW, innerH);
            }
        } else {
            int fw = (int)Math.Round(innerW * _display / 100.0);
            if (fw > 0) {
                if (fw > innerW) fw = innerW;
                using (SolidBrush bb = new SolidBrush(BarColor)) {
                    g.FillRectangle(bb, 1, 1, fw, innerH);
                }
            }
        }
    }
}

public class CardPanel : Panel {
    public Color BorderColor { get; set; }
    public int Radius { get; set; }
    public CardPanel() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
        BorderColor = Color.FromArgb(220, 226, 234);
        Radius = 6;
    }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        Color parentBg = (Parent != null) ? Parent.BackColor : SystemColors.Control;
        g.Clear(parentBg);
        float w = Width, h = Height;
        if (w <= 2f || h <= 2f) return;
        // PixelOffsetMode.Half + 满尺寸双层填充：四边精确 1px 闭合，绝不残缺或断线
        using (GraphicsPath outer = UiDraw.RoundedRect(0f, 0f, w, h, Radius))
        using (SolidBrush ob = new SolidBrush(BorderColor)) { g.FillPath(ob, outer); }
        using (GraphicsPath inner = UiDraw.RoundedRect(1f, 1f, w - 2f, h - 2f, Math.Max(1f, Radius - 1f)))
        using (SolidBrush ib = new SolidBrush(BackColor)) { g.FillPath(ib, inner); }
    }
}

public class FlatBtn : Button {
    private bool _hover;
    private bool _down;
    public int Radius { get; set; }
    public Color DisabledBackColor { get; set; }
    public Color DisabledBorderColor { get; set; }
    public Color DisabledForeColor { get; set; }
    public Color HoverBackColor { get; set; }
    public Color HoverBorderColor { get; set; }
    public Color PressBackColor { get; set; }

    public FlatBtn() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Radius = 5;
        FlatStyle = FlatStyle.Flat;
        UseVisualStyleBackColor = false;
        DisabledBackColor = Color.FromArgb(241, 245, 249);
        DisabledBorderColor = Color.FromArgb(226, 232, 240);
        DisabledForeColor = Color.FromArgb(148, 163, 184);
        HoverBackColor = Color.FromArgb(237, 242, 247);
        HoverBorderColor = Color.FromArgb(148, 163, 184);
        PressBackColor = Color.FromArgb(226, 232, 240);
    }

    public override void NotifyDefault(bool value) { base.NotifyDefault(false); }
    protected override bool ShowFocusCues { get { return false; } }
    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }

    private static Color Mix(Color a, Color b, float t) {
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        Color parentBg = (Parent != null) ? Parent.BackColor : SystemColors.Control;
        g.Clear(parentBg);

        Color fill, border, text;
        if (!Enabled) {
            fill = DisabledBackColor;
            border = DisabledBorderColor;
            text = DisabledForeColor;
        } else {
            fill = BackColor;
            border = FlatAppearance.BorderColor;
            text = ForeColor;
            bool isAccentFill = (ForeColor.R > 235 && ForeColor.G > 235 && ForeColor.B > 235 && (fill.R + fill.G + fill.B) < 520);
            if (_down) {
                fill = isAccentFill ? Mix(fill, Color.Black, 0.16f) : PressBackColor;
            } else if (_hover) {
                fill = isAccentFill ? Mix(fill, Color.White, 0.10f) : HoverBackColor;
                if (!isAccentFill) border = HoverBorderColor;
            }
        }

        float w = Width, h = Height;
        if (w > 2f && h > 2f) {
            using (GraphicsPath outer = UiDraw.RoundedRect(0f, 0f, w, h, Radius))
            using (SolidBrush ob = new SolidBrush(border)) { g.FillPath(ob, outer); }
            using (GraphicsPath inner = UiDraw.RoundedRect(1f, 1f, w - 2f, h - 2f, Math.Max(1f, Radius - 1f)))
            using (SolidBrush ib = new SolidBrush(fill)) { g.FillPath(ib, inner); }
        }

        g.PixelOffsetMode = PixelOffsetMode.Default;
        TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                                TextFormatFlags.SingleLine | TextFormatFlags.NoPadding |
                                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        // 7 参数重载：传入当前填充底色 fill 保证 ClearType 锐利；上偏 1px 修正雅黑中文光学居中
        TextRenderer.DrawText(g, Text, Font, new Rectangle(4, 1, Width - 8, Height - 3), text, fill, flags);
    }
}
"@

# ---------------- 系统深色/浅色主题自动检测 ----------------
# 自动读取 Windows「应用模式」；支持环境变量 EP_THEME=dark|light 强制覆盖（测试/截图用）
$script:isDark = $false
if ($env:EP_THEME -eq 'dark') {
    $script:isDark = $true
} elseif ($env:EP_THEME -eq 'light') {
    $script:isDark = $false
} else {
    try {
        $lightVal = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ([int]$lightVal -eq 0) { $script:isDark = $true }
    } catch { }
}

# ---------------- 双主题配色常量 ----------------
if ($script:isDark) {
    $clrBg             = [System.Drawing.Color]::FromArgb(20, 23, 31)     # #14171F 深炭灰画布
    $clrCard           = [System.Drawing.Color]::FromArgb(28, 32, 43)     # #1C202B 卡片表面
    $clrCardEdge       = [System.Drawing.Color]::FromArgb(42, 48, 64)     # #2A3040 卡片细边
    $clrBtnBg          = [System.Drawing.Color]::FromArgb(37, 43, 59)     # #252B3B 次级按钮底
    $clrBtnEdge        = [System.Drawing.Color]::FromArgb(58, 68, 92)     # #3A445C 次级按钮边
    $clrBtnHover       = [System.Drawing.Color]::FromArgb(47, 55, 75)     # #2F374B 悬停底
    $clrBtnHoverEdge   = [System.Drawing.Color]::FromArgb(82, 95, 125)    # #525F7D 悬停边
    $clrBtnPress       = [System.Drawing.Color]::FromArgb(31, 37, 51)     # #1F2533 按下底
    $clrBtnDisBg       = [System.Drawing.Color]::FromArgb(24, 28, 38)     # 禁用底
    $clrBtnDisEdge     = [System.Drawing.Color]::FromArgb(38, 44, 59)     # 禁用边
    $clrBtnDisText     = [System.Drawing.Color]::FromArgb(90, 100, 122)   # 禁用字
    $clrTrack          = [System.Drawing.Color]::FromArgb(38, 44, 59)     # 进度槽
    $clrTrackEdge      = [System.Drawing.Color]::FromArgb(58, 68, 92)     # 进度槽边
    $clrText           = [System.Drawing.Color]::FromArgb(241, 245, 249)  # #F1F5F9 主文字
    $clrMuted          = [System.Drawing.Color]::FromArgb(148, 163, 184)  # #94A3B8 次要文字
    $clrLogText        = [System.Drawing.Color]::FromArgb(203, 213, 225)  # 日志文字
    $clrAccent         = [System.Drawing.Color]::FromArgb(59, 130, 246)   # #3B82F6 强调蓝
    $clrHeader         = [System.Drawing.Color]::FromArgb(15, 17, 23)     # #0F1117 顶栏
    $clrHeaderLine     = [System.Drawing.Color]::FromArgb(38, 44, 59)
    $clrHeaderBtnBg    = [System.Drawing.Color]::FromArgb(30, 36, 48)
    $clrHeaderBtnEdge  = [System.Drawing.Color]::FromArgb(55, 65, 85)
    $clrHeaderBtnHover = [System.Drawing.Color]::FromArgb(42, 50, 66)
    $clrOnDark         = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $clrOnDarkMuted    = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $clrHeaderAccent   = [System.Drawing.Color]::FromArgb(96, 165, 250)
    $clrWarn           = [System.Drawing.Color]::FromArgb(245, 158, 11)
    $clrBad            = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $clrGo             = [System.Drawing.Color]::FromArgb(34, 197, 94)
} else {
    $clrBg             = [System.Drawing.Color]::FromArgb(241, 244, 248)  # #F1F4F8 柔和冷灰画布
    $clrCard           = [System.Drawing.Color]::White                    # #FFFFFF 纯白卡片
    $clrCardEdge       = [System.Drawing.Color]::FromArgb(220, 226, 234)  # #DCE2EA 卡片细边
    $clrBtnBg          = [System.Drawing.Color]::FromArgb(248, 250, 252)  # #F8FAFC 次级按钮底（与白卡片拉开层次）
    $clrBtnEdge        = [System.Drawing.Color]::FromArgb(203, 213, 225)  # #CBD5E1 清晰按钮边
    $clrBtnHover       = [System.Drawing.Color]::FromArgb(237, 242, 247)  # #EDF2F7 悬停底
    $clrBtnHoverEdge   = [System.Drawing.Color]::FromArgb(148, 163, 184)  # #94A3B8 悬停边
    $clrBtnPress       = [System.Drawing.Color]::FromArgb(226, 232, 240)  # #E2E8F0 按下底
    $clrBtnDisBg       = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $clrBtnDisEdge     = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $clrBtnDisText     = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $clrTrack          = [System.Drawing.Color]::FromArgb(226, 232, 240)  # #E2E8F0 进度槽
    $clrTrackEdge      = [System.Drawing.Color]::FromArgb(203, 213, 225)  # #CBD5E1 进度槽边
    $clrText           = [System.Drawing.Color]::FromArgb(15, 23, 42)     # #0F172A 主文字
    $clrMuted          = [System.Drawing.Color]::FromArgb(100, 116, 139)  # #64748B 次要文字
    $clrLogText        = [System.Drawing.Color]::FromArgb(51, 65, 85)     # #334155 日志文字
    $clrAccent         = [System.Drawing.Color]::FromArgb(37, 99, 235)    # #2563EB 主强调蓝
    $clrHeader         = [System.Drawing.Color]::FromArgb(30, 36, 48)     # #1E2430 深石板顶栏
    $clrHeaderLine     = [System.Drawing.Color]::FromArgb(51, 60, 77)
    $clrHeaderBtnBg    = [System.Drawing.Color]::FromArgb(43, 51, 68)
    $clrHeaderBtnEdge  = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $clrHeaderBtnHover = [System.Drawing.Color]::FromArgb(55, 65, 85)
    $clrOnDark         = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $clrOnDarkMuted    = [System.Drawing.Color]::FromArgb(160, 174, 192)
    $clrHeaderAccent   = [System.Drawing.Color]::FromArgb(147, 197, 253)  # 深顶栏上的高可读浅蓝提示
    $clrWarn           = [System.Drawing.Color]::FromArgb(180, 83, 9)
    $clrBad            = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $clrGo             = [System.Drawing.Color]::FromArgb(22, 163, 74)
}
$clrHover = $clrBtnHover

$fontBase  = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 9))
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 8.25))
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 13), [System.Drawing.FontStyle]::Bold)
$fontSub   = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 8.5))
$fontGroup = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 9), [System.Drawing.FontStyle]::Bold)
$fontLog   = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 8.5))
$fontValue = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 9.5), [System.Drawing.FontStyle]::Bold)

function Apply-FlatBtnTheme($b, [bool]$onHeader = $false) {
    $b.DisabledBackColor   = $clrBtnDisBg
    $b.DisabledBorderColor = $clrBtnDisEdge
    $b.DisabledForeColor   = $clrBtnDisText
    if ($onHeader) {
        $b.HoverBackColor   = $clrHeaderBtnHover
        $b.HoverBorderColor = $clrOnDarkMuted
        $b.PressBackColor   = $clrHeader
    } else {
        $b.HoverBackColor   = $clrBtnHover
        $b.HoverBorderColor = $clrBtnHoverEdge
        $b.PressBackColor   = $clrBtnPress
    }
}

[void][System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = '便携 Edge 面板 v' + $script:panelVersion
$form.FormBorderStyle = 'FixedSingle'
# 关键：显式关掉 WinForms 自带的自动缩放。否则（默认 Font 模式）会与下面的手工 S() 叠加，
# 在 125%/150% 屏上变成二次放大。可用环境变量 EP_UI_SCALE 覆盖缩放比（测尺寸用）。
$form.AutoScaleMode = 'None'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size((S 870), (S 676))
$form.StartPosition = 'Manual'
$form.Opacity = 0   # 首帧深色背景与缓存状态全部画完再显形，根治深色模式启动闪白
$form.BackColor = $clrBg
$form.Font = $fontBase
$form.SuspendLayout()
$form.Add_HandleCreated({ [ThemeHelper]::ApplyTitleBar($form.Handle, $script:isDark) })
$form.Add_Load({
    $wa0 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x0 = $wa0.Left + [int][math]::Max(0, (($wa0.Width - $form.Width) / 2))
    $y0 = $wa0.Top + [int][math]::Max(0, (($wa0.Height - $form.Height) / 2))
    $form.Location = New-Object System.Drawing.Point($x0, $y0)
})

# 关闭窗口时置取消标志：长任务（下载等）在循环里检查它，及时停手让窗口能关
$script:closeRequested = $false
$form.Add_FormClosing({
    $script:closeRequested = $true
    # BeginStop 异步停 Runspace：同步 Stop() 会被卡在 stream.Read 的 IO 阻塞拖住（最多 15 秒）
    if ($script:dlPs) { try { [void]$script:dlPs.BeginStop($null, $null) } catch { } }
    if ($script:chkPs) { try { [void]$script:chkPs.BeginStop($null, $null) } catch { } }
    if ($script:refreshPs) { try { [void]$script:refreshPs.BeginStop($null, $null) } catch { } }
    # 打包中的 7za 是独立进程，Kill 防孤儿继续写 .tmp
    if ($script:backupProc -and -not $script:backupProc.HasExited) { try { $script:backupProc.Kill() } catch { } }
    if ($script:policyWatch) { try { $script:policyWatch.Stop(); $script:policyWatch.Dispose() } catch { } }
    if ($script:logTimer) { try { $script:logTimer.Stop(); $script:logTimer.Dispose() } catch { }; $script:logTimer = $null }
    try { Drain-LogQueue } catch { }
    if ($script:startupPromptTimer) { try { $script:startupPromptTimer.Stop(); $script:startupPromptTimer.Dispose() } catch { }; $script:startupPromptTimer = $null }
    foreach ($tm in @($script:panelProbeDelay, $script:panelProbeTimer)) { if ($tm) { try { $tm.Stop(); $tm.Dispose() } catch { } } }
    $script:panelProbeDelay = $null; $script:panelProbeTimer = $null
    if ($script:panelProbeCancel) { try { $script:panelProbeCancel['Stop'] = $true } catch { } }
    if ($script:panelProbePs) { try { [void]$script:panelProbePs.BeginStop($null, $null) } catch { }; $script:panelProbePs = $null }
    $script:panelProbeRs = $null
    if ($script:ghIconPath) { try { $script:ghIconPath.Dispose() } catch { }; $script:ghIconPath = $null }
})

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = S 68
$header.BackColor = $clrHeader
$header.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($clrHeaderLine, 1)
    try { $e.Graphics.DrawLine($pen, 0, ($s.Height - 1), $s.Width, ($s.Height - 1)) } finally { $pen.Dispose() }
})
$form.Controls.Add($header)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '便携 Edge 面板 v' + $script:panelVersion
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $clrOnDark
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point((S 18), (S 6))
$header.Controls.Add($lblTitle)

# 顶栏轻量入口：与左标题 v1.3.4 底基线对齐（1× 落 y=10，避开下方路径行）；GitHub 左侧采用官方 24 网格矢量 Octocat 并缓存路径
$lnkH = S 20
$lnkY = $lblTitle.Top + [int](($lblTitle.PreferredHeight - $lnkH) / 2) - (S 1)
$lnkRepo = New-Object System.Windows.Forms.Label
$lnkRepo.Text = 'GitHub'
$lnkRepo.Font = $fontSmall
$lnkRepo.ForeColor = $clrOnDarkMuted
$lnkRepo.AutoSize = $false
$lnkRepo.TextAlign = 'MiddleLeft'
$lnkRepo.Padding = New-Object System.Windows.Forms.Padding((S 20), 0, 0, 0)
$lnkRepo.Location = New-Object System.Drawing.Point((S 274), $lnkY)
$lnkRepo.Size = New-Object System.Drawing.Size((S 80), $lnkH)
$lnkRepo.Cursor = 'Hand'
# 官方 GitHub Octicons mark-github-24 精确矢量路径（24 网格圆底镂空版，FillMode=Alternate，一次性构建并缓存至关窗释放）
$script:ghIconPath = & {
    $sz = [float](S 16)
    $k = $sz / 24.0
    $ox = 0.5
    $oy = ([float]$lnkH - $sz) / 2.0 - 0.5
    $ghPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ghPath.StartFigure()
    $ghPath.AddBezier(($ox+10.2260*$k), ($oy+17.2840*$k), ($ox+7.2610*$k), ($oy+16.9240*$k), ($ox+5.1720*$k), ($oy+14.7910*$k), ($ox+5.1720*$k), ($oy+12.0280*$k))
    $ghPath.AddBezier(($ox+5.1720*$k), ($oy+12.0280*$k), ($ox+5.1720*$k), ($oy+10.9050*$k), ($ox+5.5760*$k), ($oy+9.6920*$k), ($ox+6.2500*$k), ($oy+8.8840*$k))
    $ghPath.AddBezier(($ox+6.2500*$k), ($oy+8.8840*$k), ($ox+5.9580*$k), ($oy+8.1430*$k), ($ox+6.0030*$k), ($oy+6.5700*$k), ($ox+6.3400*$k), ($oy+5.9190*$k))
    $ghPath.AddBezier(($ox+6.3400*$k), ($oy+5.9190*$k), ($ox+7.2380*$k), ($oy+5.8070*$k), ($ox+8.4510*$k), ($oy+6.2790*$k), ($ox+9.1700*$k), ($oy+6.9290*$k))
    $ghPath.AddBezier(($ox+9.1700*$k), ($oy+6.9290*$k), ($ox+10.0230*$k), ($oy+6.6600*$k), ($ox+10.9220*$k), ($oy+6.5250*$k), ($ox+12.0230*$k), ($oy+6.5250*$k))
    $ghPath.AddBezier(($ox+12.0230*$k), ($oy+6.5250*$k), ($ox+13.1230*$k), ($oy+6.5250*$k), ($ox+14.0220*$k), ($oy+6.6600*$k), ($ox+14.8300*$k), ($oy+6.9070*$k))
    $ghPath.AddBezier(($ox+14.8300*$k), ($oy+6.9070*$k), ($ox+15.5260*$k), ($oy+6.2780*$k), ($ox+16.7620*$k), ($oy+5.8070*$k), ($ox+17.6600*$k), ($oy+5.9190*$k))
    $ghPath.AddBezier(($ox+17.6600*$k), ($oy+5.9190*$k), ($ox+17.9750*$k), ($oy+6.5250*$k), ($ox+18.0200*$k), ($oy+8.0980*$k), ($ox+17.7270*$k), ($oy+8.8610*$k))
    $ghPath.AddBezier(($ox+17.7270*$k), ($oy+8.8610*$k), ($ox+18.4470*$k), ($oy+9.7150*$k), ($ox+18.8280*$k), ($oy+10.8610*$k), ($ox+18.8280*$k), ($oy+12.0280*$k))
    $ghPath.AddBezier(($ox+18.8280*$k), ($oy+12.0280*$k), ($ox+18.8280*$k), ($oy+14.7910*$k), ($ox+16.7390*$k), ($oy+16.8800*$k), ($ox+13.7300*$k), ($oy+17.2620*$k))
    $ghPath.AddBezier(($ox+13.7300*$k), ($oy+17.2620*$k), ($ox+14.4930*$k), ($oy+17.7560*$k), ($ox+15.0100*$k), ($oy+18.8340*$k), ($ox+15.0100*$k), ($oy+20.0690*$k))
    $ghPath.AddLine(($ox+15.0100*$k), ($oy+20.0690*$k), ($ox+15.0100*$k), ($oy+22.4050*$k))
    $ghPath.AddBezier(($ox+15.0100*$k), ($oy+22.4050*$k), ($ox+15.0100*$k), ($oy+23.0790*$k), ($ox+15.5710*$k), ($oy+23.4610*$k), ($ox+16.2450*$k), ($oy+23.1910*$k))
    $ghPath.AddBezier(($ox+16.2450*$k), ($oy+23.1910*$k), ($ox+20.3110*$k), ($oy+21.6410*$k), ($ox+23.5000*$k), ($oy+17.5760*$k), ($ox+23.5000*$k), ($oy+12.5450*$k))
    $ghPath.AddBezier(($ox+23.5000*$k), ($oy+12.5450*$k), ($ox+23.5000*$k), ($oy+6.1880*$k), ($ox+18.3340*$k), ($oy+1.0000*$k), ($ox+11.9780*$k), ($oy+1.0000*$k))
    $ghPath.AddBezier(($ox+11.9780*$k), ($oy+1.0000*$k), ($ox+5.6200*$k), ($oy+1.0000*$k), ($ox+0.5000*$k), ($oy+6.1880*$k), ($ox+0.5000*$k), ($oy+12.5450*$k))
    $ghPath.AddBezier(($ox+0.5000*$k), ($oy+12.5450*$k), ($ox+0.5000*$k), ($oy+17.5310*$k), ($ox+3.6670*$k), ($oy+21.6650*$k), ($ox+7.9350*$k), ($oy+23.2140*$k))
    $ghPath.AddBezier(($ox+7.9350*$k), ($oy+23.2140*$k), ($ox+8.5410*$k), ($oy+23.4390*$k), ($ox+9.1250*$k), ($oy+23.0340*$k), ($ox+9.1250*$k), ($oy+22.4280*$k))
    $ghPath.AddLine(($ox+9.1250*$k), ($oy+22.4280*$k), ($ox+9.1250*$k), ($oy+20.6300*$k))
    $ghPath.AddBezier(($ox+9.1250*$k), ($oy+20.6300*$k), ($ox+8.7833*$k), ($oy+20.7728*$k), ($ox+8.4173*$k), ($oy+20.8489*$k), ($ox+8.0470*$k), ($oy+20.8540*$k))
    $ghPath.AddBezier(($ox+8.0470*$k), ($oy+20.8540*$k), ($ox+6.5640*$k), ($oy+20.8540*$k), ($ox+5.6880*$k), ($oy+20.0460*$k), ($ox+5.0600*$k), ($oy+18.5410*$k))
    $ghPath.AddBezier(($ox+5.0600*$k), ($oy+18.5410*$k), ($ox+4.8130*$k), ($oy+17.9340*$k), ($ox+4.5430*$k), ($oy+17.5750*$k), ($ox+4.0260*$k), ($oy+17.5080*$k))
    $ghPath.AddBezier(($ox+4.0260*$k), ($oy+17.5080*$k), ($ox+3.7560*$k), ($oy+17.4850*$k), ($ox+3.6670*$k), ($oy+17.3730*$k), ($ox+3.6670*$k), ($oy+17.2380*$k))
    $ghPath.AddBezier(($ox+3.6670*$k), ($oy+17.2380*$k), ($ox+3.6670*$k), ($oy+16.9680*$k), ($ox+4.1170*$k), ($oy+16.7670*$k), ($ox+4.5650*$k), ($oy+16.7670*$k))
    $ghPath.AddBezier(($ox+4.5650*$k), ($oy+16.7670*$k), ($ox+5.2170*$k), ($oy+16.7670*$k), ($ox+5.7780*$k), ($oy+17.1710*$k), ($ox+6.3620*$k), ($oy+18.0020*$k))
    $ghPath.AddBezier(($ox+6.3620*$k), ($oy+18.0020*$k), ($ox+6.8120*$k), ($oy+18.6530*$k), ($ox+7.2830*$k), ($oy+18.9450*$k), ($ox+7.8450*$k), ($oy+18.9450*$k))
    $ghPath.AddBezier(($ox+7.8450*$k), ($oy+18.9450*$k), ($ox+8.4060*$k), ($oy+18.9450*$k), ($ox+8.7650*$k), ($oy+18.7430*$k), ($ox+9.2820*$k), ($oy+18.2260*$k))
    $ghPath.AddBezier(($ox+9.2820*$k), ($oy+18.2260*$k), ($ox+9.6640*$k), ($oy+17.8450*$k), ($ox+9.9560*$k), ($oy+17.5080*$k), ($ox+10.2260*$k), ($oy+17.2830*$k))
    $ghPath.CloseFigure()
    $ghPath.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
    $ghPath
}
$lnkRepo.Add_Paint({
    param($s, $e)
    if (-not $script:ghIconPath) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $br = New-Object System.Drawing.SolidBrush($s.ForeColor)
    try { $g.FillPath($br, $script:ghIconPath) } finally { $br.Dispose() }
})
$lnkRepo.Add_Click({ if ($script:panelUpdateRepo) { try { Start-Process ('https://github.com/' + $script:panelUpdateRepo.Trim('/')) } catch { } } })
$lnkRepo.Add_MouseEnter({ $lnkRepo.ForeColor = $clrHeaderAccent; $lnkRepo.Invalidate() })
$lnkRepo.Add_MouseLeave({ $lnkRepo.ForeColor = $clrOnDarkMuted; $lnkRepo.Invalidate() })
$header.Controls.Add($lnkRepo)

$lnkIssues = New-Object System.Windows.Forms.Label
$lnkIssues.Text = '反馈'
$lnkIssues.Font = $fontSmall
$lnkIssues.ForeColor = $clrOnDarkMuted
$lnkIssues.AutoSize = $false
$lnkIssues.TextAlign = 'MiddleLeft'
# 中文「反馈」字形墨迹略高于拉丁「GitHub」：保留 Location.Y +1px 整数对齐，去掉 Padding 避免压缩可用高度
$lnkIssues.Location = New-Object System.Drawing.Point((S 358), ([int]$lnkY + (S 1)))
$lnkIssues.Size = New-Object System.Drawing.Size((S 40), $lnkH)
$lnkIssues.Cursor = 'Hand'
$lnkIssues.Add_Click({ if ($script:panelUpdateRepo) { try { Start-Process ('https://github.com/' + $script:panelUpdateRepo.Trim('/') + '/issues') } catch { } } })
$lnkIssues.Add_MouseEnter({ $lnkIssues.ForeColor = $clrHeaderAccent })
$lnkIssues.Add_MouseLeave({ $lnkIssues.ForeColor = $clrOnDarkMuted })
$header.Controls.Add($lnkIssues)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = $pkgRoot
$lblSub.Font = $fontSub
$lblSub.ForeColor = $clrOnDarkMuted
$lblSub.AutoSize = $false
$lblSub.AutoEllipsis = $true
$lblSub.Size = New-Object System.Drawing.Size((S 390), (S 20))
$lblSub.Location = New-Object System.Drawing.Point((S 20), (S 44))
$header.Controls.Add($lblSub)
$lblSub.Cursor = 'Hand'
$lblSub.Add_Click({
    param($s, $e)
    if ($e -is [System.Windows.Forms.MouseEventArgs] -and $e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    try { Start-Process explorer.exe -ArgumentList ('"' + $pkgRoot + '"') } catch { }
})
$lblSub.Add_MouseEnter({ $lblSub.ForeColor = $clrHeaderAccent })
$lblSub.Add_MouseLeave({ $lblSub.ForeColor = $clrOnDarkMuted })
$script:menuPkg = New-Object System.Windows.Forms.ContextMenuStrip
$miOpenPkg = $script:menuPkg.Items.Add('打开当前目录')
$miOpenPkg.Add_Click({ try { Start-Process explorer.exe -ArgumentList ('"' + $pkgRoot + '"') } catch { } })
$miSwitchPkg = $script:menuPkg.Items.Add('切换便携 Edge 目录…')
$miSwitchPkg.Add_Click({ Invoke-SwitchPackageRoot })
$lblSub.ContextMenuStrip = $script:menuPkg

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '就绪'
$lblHint.Font = $fontSmall
$lblHint.ForeColor = $clrOnDarkMuted
$lblHint.AutoSize = $false
$lblHint.TextAlign = 'MiddleRight'
$lblHint.AutoEllipsis = $true
# 只占标题那一行（Y 10..36）：包根路径长的机器上，路径标签会向右伸到 452 附近，
# 原来 hint 从 Y23 起会与路径行在 Y42..51 重叠（ui-audit 报 21×9px）。
$lblHint.Location = New-Object System.Drawing.Point((S 416), (S 19))
$lblHint.Size = New-Object System.Drawing.Size((S 246), (S 30))
$header.Controls.Add($lblHint)
# 注：「刷新状态」按钮在 New-Btn 定义之后创建（见下方分组区），避免函数未定义

# ---------------- 状态卡 ----------------
$card = New-Object CardPanel
$card.BackColor = $clrCard
$card.Location = New-Object System.Drawing.Point((S 14), (S 80))
$card.Size = New-Object System.Drawing.Size((S 842), (S 76))
$card.BorderColor = $clrCardEdge
$card.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 4), (S 6), (S 4))
$form.Controls.Add($card)

$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.BackColor = $clrCard
$tbl.Dock = 'Fill'
$tbl.ColumnCount = 6
$tbl.RowCount = 2
$tbl.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
for ($c = 0; $c -lt 6; $c++) { [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 16.66))) }
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 24))))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$card.Controls.Add($tbl)

function Add-Stat([int]$col, [string]$caption) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $caption
    $c.Font = $fontSmall
    $c.ForeColor = $clrMuted
    $c.Dock = 'Fill'
    $c.AutoSize = $false
    $c.TextAlign = 'BottomCenter'
    $tbl.Controls.Add($c, $col, 0)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '—'
    $v.Font = $fontValue
    $v.ForeColor = $clrText
    $v.Dock = 'Fill'
    $v.AutoSize = $false
    $v.AutoEllipsis = $true
    $v.TextAlign = 'MiddleCenter'
    $tbl.Controls.Add($v, $col, 1)
    return $v
}
$valProg    = Add-Stat 0 '程序文件'
$valProfile = Add-Stat 1 '用户数据'
$valDrm     = Add-Stat 2 'DRM'
$valIni     = Add-Stat 3 '组件更新'
$valSlim    = Add-Stat 4 '可瘦身'
$valCache   = Add-Stat 5 '可清理'

# ---------------- 分组与按钮 ----------------
function New-Group([int]$x, [int]$y, [int]$w, [int]$h, [string]$title) {
    $x = S $x; $y = S $y; $w = S $w; $h = S $h
    $g = New-Object CardPanel
    $g.BackColor = $clrCard
    $g.Location = New-Object System.Drawing.Point($x, $y)
    $g.Size = New-Object System.Drawing.Size($w, $h)
    $g.BorderColor = $clrCardEdge
    $g.Radius = 6
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $title
    $t.Font = $fontGroup
    $t.ForeColor = $clrText
    $t.BackColor = $clrCard
    $t.AutoSize = $true
    $t.Location = New-Object System.Drawing.Point((S 14), (S 11))
    $g.Controls.Add($t)
    $form.Controls.Add($g)
    return $g
}
function Enable-DoubleBuffer($c) {
    try {
        $pi = $c.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($pi) { $pi.SetValue($c, $true, $null) }
    } catch { }
}

function New-Btn($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [scriptblock]$onClick, [bool]$primary = $false) {
    $x = S $x; $y = S $y; $w = S $w; $h = S $h
    $b = New-Object FlatBtn   # 子类：NotifyDefault 恒 false，杜绝默认按钮 2px 加粗边框
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.UseVisualStyleBackColor = $false   # 避免系统视觉样式在重绘时覆盖我们设的颜色
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = if ($primary) { $clrAccent } else { $clrBtnEdge }
    $b.FlatAppearance.BorderSize = 1
    if (-not $primary) { $b.FlatAppearance.MouseOverBackColor = $clrHover }
    $b.BackColor = if ($primary) { $clrAccent } else { $clrBtnBg }
    $b.ForeColor = if ($primary) { [System.Drawing.Color]::White } else { $clrText }
    Apply-FlatBtnTheme $b $false
    $b.Cursor = 'Hand'
    $b.Add_Click($onClick)
    Enable-DoubleBuffer $b
    $parent.Controls.Add($b)
    # 统一收集：Set-Busy 全量禁用（防更新/备份中途误点其它写盘按钮造成并发写坏）
    if (-not $script:allButtons) { $script:allButtons = @() }
    $script:allButtons += $b
    return $b
}
function New-Note($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text) {
    $x = S $x; $y = S $y; $w = S $w; $h = S $h
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = $fontSmall
    $l.ForeColor = $clrMuted
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $parent.Controls.Add($l)
    return $l
}

# 统一 12px 模块间距网格（外边距 14px，左右卡各 415px，中缝 12px，内宽 387px）
$gSlim = New-Group 14 168 415 160 '程序瘦身'
$script:btnSlimAll  = New-Btn $gSlim 14  38 189 28 '一键瘦身' { Invoke-Action 'SlimAll' }
$script:btnSlimOnly = New-Btn $gSlim 212 38 189 28 '仅删组件' { Invoke-Action 'SlimOnly' }
$script:btnIniOff   = New-Btn $gSlim 14  74 189 28 '关闭组件更新' { Invoke-Action 'IniOff' }
$script:btnIniOn    = New-Btn $gSlim 212 74 189 28 '恢复组件更新' { Invoke-Action 'IniOn' }
[void](New-Note $gSlim 14 108 387 44 '移除约 380 项非核心组件（保留中/英语言包）、关闭组件更新并启用多线程下载，核心文件不动。')

$gUpdate = New-Group 441 168 415 160 'Edge 更新'
$valCurVer = New-Object System.Windows.Forms.Label
$valCurVer.Text = '当前版本：—'
$valCurVer.Font = $fontBase
$valCurVer.ForeColor = $clrText
# 固定尺寸而不是 AutoSize：AutoSize 的高度随字号线性增长，而 Y 间距是固定 22px 基准，
# 125% 下会被撑到 30px 高从而与下一行重叠 3px（ui-audit 实测 124×3px）。
$valCurVer.AutoSize = $false
$valCurVer.Size = New-Object System.Drawing.Size((S 387), (S 22))
$valCurVer.TextAlign = 'MiddleLeft'
$valCurVer.Location = New-Object System.Drawing.Point((S 14), (S 36))
$gUpdate.Controls.Add($valCurVer)
$valNewVer = New-Object System.Windows.Forms.Label
$valNewVer.Text = '最新版本：未检查'
$valNewVer.Font = $fontBase
$valNewVer.ForeColor = $clrMuted
$valNewVer.AutoSize = $false
$valNewVer.Size = New-Object System.Drawing.Size((S 387), (S 22))
$valNewVer.TextAlign = 'MiddleLeft'
$valNewVer.Location = New-Object System.Drawing.Point((S 14), (S 60))
$gUpdate.Controls.Add($valNewVer)
[void](New-Btn $gUpdate 14  84 123 28 '检查更新' { Invoke-Check })
$script:btnUpdate     = New-Btn $gUpdate 146 84 123 28 '下载并更新' { Invoke-UpdateNow $false } $false
$script:btnUpdateSlim = New-Btn $gUpdate 278 84 123 28 '更新并瘦身' { Invoke-UpdateNow $true } $false
$script:btnUpdate.Enabled = $false
$script:btnUpdateSlim.Enabled = $false
[void](New-Note $gUpdate 14 118 387 34 '可仅更新 Edge 本体，或更新后自动瘦身；chrome++.ini 等便携配置始终保留。')

$gCache = New-Group 14 340 415 120 '缓存与备份'
$script:btnClean   = New-Btn $gCache 14  38 123 30 '清理缓存' { Invoke-Action 'Clean' }
$script:btnBackup  = New-Btn $gCache 146 38 123 30 '清理并备份' { Invoke-CleanAndBackup -Force:(([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -ne 0) } $true
$script:btnRestore = New-Btn $gCache 278 38 123 30 '从备份恢复' { Invoke-RestoreBackup }
[void](New-Note $gCache 14 76 387 36 '清理缓存不触碰书签、密码与扩展；备份默认加密，换机时直接点「从备份恢复」。')

$gPolicy = New-Group 441 340 415 120 '策略 / 系统集成'

# 原生 Form / Header 开启双缓冲（CardPanel 已在 C# 构造函数内置 OptimizedDoubleBuffer）
foreach ($c in @($form, $header)) { Enable-DoubleBuffer $c }
$valPolicy = New-Object System.Windows.Forms.Label
$valPolicy.Text = '—'
$valPolicy.Font = $fontBase
$valPolicy.ForeColor = $clrMuted
$valPolicy.AutoSize = $false
$valPolicy.Location = New-Object System.Drawing.Point((S 209), (S 11))
$valPolicy.Size = New-Object System.Drawing.Size((S 192), (S 20))
$valPolicy.TextAlign = 'MiddleRight'
$gPolicy.Controls.Add($valPolicy)
$script:btnPolicy   = New-Btn $gPolicy 14  38 189 30 '打开策略管理' { Open-PolicyGui }
$script:btnRecom    = New-Btn $gPolicy 212 38 189 30 '应用推荐策略' { Apply-RecommendedPolicies } $true
$script:btnDefApps  = New-Btn $gPolicy 14  76 189 30 '设默认浏览器' { Start-EdgeBat 'default-apps-multi-profile.bat' '设默认浏览器' }
$script:btnDefender = New-Btn $gPolicy 212 76 189 30 'Defender 排除' { Start-EdgeBat 'bypass_windows_defender.bat' 'Defender 排除' }
# 顶栏右侧：「更新面板」（预设，有新版绿/无新版灰）+「刷新状态」
$script:btnPanelUpdate = New-Btn $header 672 19 86 30 '更新面板' { Invoke-PanelUpdate }
Apply-FlatBtnTheme $script:btnPanelUpdate $true
$script:btnPanelUpdate.BackColor = $clrHeaderBtnBg
$script:btnPanelUpdate.ForeColor = $clrOnDark
$script:btnPanelUpdate.FlatAppearance.BorderColor = $clrHeaderBtnEdge

$script:btnRefresh = New-Btn $header 768 19 88 30 '刷新状态' { Update-StatusAsync }
Apply-FlatBtnTheme $script:btnRefresh $true
$script:btnRefresh.BackColor = $clrHeaderBtnBg
$script:btnRefresh.ForeColor = $clrOnDark
$script:btnRefresh.FlatAppearance.BorderColor = $clrHeaderBtnEdge
# ---------------- 悬停说明 ----------------
$script:tip = New-Object System.Windows.Forms.ToolTip
$script:tip.AutoPopDelay = 15000
$script:tip.InitialDelay = 350
$script:tip.ReshowDelay = 200
$script:tip.SetToolTip($valProg,   "程序目录（Edge\<版本号>）里的文件数与体积")
$script:tip.SetToolTip($valSlim,   "瘦身还能删掉多少：文件数与体积。显示「已瘦身」表示已经裁过")
$script:tip.SetToolTip($valProfile,"Data 目录下的组件目录数与总体积（不含程序文件）")
$script:tip.SetToolTip($valDrm,    "是否已下载 WidevineCdm（DRM 组件）。没有就播不了受版权保护的视频")
$script:tip.SetToolTip($valIni,    "chrome++.ini 的 command_line 里是否带 --disable-component-update")
$script:tip.SetToolTip($script:btnSlimAll, "删除约 380 项非核心组件、关闭组件更新并启用多线程下载，核心运行文件一律保留")
$script:tip.SetToolTip($valCache,  "常规清理预计可释放体积（含包根目录 Cache\、GPU/着色器缓存、诊断指标与崩溃转储等）")
$script:tip.SetToolTip($script:btnBackup, "清理缓存并备份用户数据（支持加密、保留份数与目录设置，可选附带面板本体或 Edge 本体）")
$script:tip.SetToolTip($script:btnRestore, "从备份包恢复用户数据；含 Edge 本体的完整包可一并恢复程序目录")
$script:tip.SetToolTip($lblSub, "左键单击打开当前目录；右键可切换其他便携 Edge 目录")
$script:tip.SetToolTip($lnkRepo, "打开 GitHub 项目主页")
$script:tip.SetToolTip($lnkIssues, "打开 GitHub Issues 问题列表（可先查看已有记录，避免重复提交）")
$script:tip.SetToolTip($script:btnPanelUpdate, "检查并更新面板本体（有新版变绿，支持直连与镜像站下载并校验 SHA256）")
$script:tip.SetToolTip($script:btnRefresh, "刷新上方全部状态卡与可清理体积")
$script:tip.SetToolTip($script:btnUpdate,     "仅替换 Edge 本体文件（保留 chrome++.ini 等便携配置），不删语言包与组件")
$script:tip.SetToolTip($script:btnUpdateSlim, "替换 Edge 本体后自动执行一键瘦身（删非核心组件 + 关组件更新 + 开多线程下载）")
$script:tip.SetToolTip($script:btnPolicy,     "打开 Edge 策略管理界面（已汉化并适配深浅色模式，可逐条查看或微调）")
$script:tip.SetToolTip($script:btnDefApps,    "调用 default-apps-multi-profile.bat 注册到 HKLM（需 UAC），完成后自动打开系统「默认应用」")
$script:tip.SetToolTip($script:btnDefender,   "调用 bypass_windows_defender.bat，将 Edge 子目录加入 Defender 排除项（不含 Data / Cache）")
$script:tip.SetToolTip($script:btnRecom,   ('将内置 ' + $script:baselineCount + ' 条主策略与 ' + $script:baselineSubCount + ' 条子键项写入隔离注册表键（需 UAC），同步推荐项并保留其它自定义项'))



# ---------------- R10：没有 Edge 包时的降级态 ----------------
$script:pkgButtons = @($script:btnSlimAll, $script:btnSlimOnly, $script:btnIniOff, $script:btnIniOn, $script:btnClean, $script:btnBackup, $script:btnDefApps, $script:btnDefender)
if ($script:noPackage) {
    foreach ($b in $script:pkgButtons) {
        if ($b) { $b.Enabled = $false }
    }
    foreach ($l in @($valProg, $valProfile, $valDrm, $valIni, $valSlim, $valCache)) { $l.Text = '—'; $l.ForeColor = $clrMuted }
}
# ---------------- 日志 ----------------
$logCard = New-Object CardPanel
$logCard.BackColor = $clrCard
$logCard.Location = New-Object System.Drawing.Point((S 14), (S 472))
$logCard.Size = New-Object System.Drawing.Size((S 842), (S 190))
$logCard.BorderColor = $clrCardEdge
$logCard.Padding = New-Object System.Windows.Forms.Padding((S 10), (S 8), (S 10), (S 8))
$form.Controls.Add($logCard)

$log = New-Object System.Windows.Forms.RichTextBox
$log.Multiline = $true
$log.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$log.ReadOnly = $true
$log.DetectUrls = $false
$log.HideSelection = $false
$log.BorderStyle = 'None'
$log.BackColor = $clrCard
$log.ForeColor = $clrLogText
$log.Add_HandleCreated({ [ThemeHelper]::ApplyDarkScroll($log.Handle, $script:isDark) })
$log.Font = $fontLog
$log.Dock = 'Fill'
$logCard.Controls.Add($log)

# 自适应高度：1:1 按 DPI 放大后，小屏（如 1536×864 @125%）上窗口会高于工作区、压到任务栏下面。
# 只在"放不下"时收缩，且只缩日志区（弹性元素），其余布局不动。
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$wantH = (S 676)
$maxH = $wa.Height - (S 28)
if ($maxH -lt $wantH) {
    $form.ClientSize = New-Object System.Drawing.Size((S 870), $maxH)
    $logTop = (S 472)
    $logH = $maxH - $logTop - (S 14)
    if ($logH -lt (S 80)) { $logH = (S 80) }
    $logCard.Size = New-Object System.Drawing.Size((S 842), $logH)
}

# ---------------- 日志 / 忙碌态 ----------------
# ---- 日志管线：磁盘全量；界面走队列 + 60 ms 批量落屏，并支持分块，避免并行任务的行互相插队 ----
$script:logQueue = $null      # ConcurrentQueue，写入端可能是后台线程
$script:logTimer = $null
$script:logBlock = $null      # 非空时 Write-Log 先攒到块里，End-LogBlock 再整块入队
$script:progressStop = $false   # 长任务（深度搜索）的中断标记

function Append-LogRow($row) {
    if (-not $log -or $log.IsDisposed) { return }
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = $clrMuted
    $log.AppendText($row.Time + ' │ ')
    $log.SelectionColor = $row.Clr
    $log.AppendText($row.Tag)
    $log.SelectionColor = $clrMuted
    $log.AppendText(' │ ')
    $log.SelectionColor = $clrLogText
    $log.AppendText($row.Text + "`r`n")
}

$script:draining = $false
function Drain-LogQueue {
    if ($script:draining -or -not $script:logQueue -or $script:logQueue.IsEmpty) { return }
    $script:draining = $true
    try {
        $n = 0
        while ($n -lt 200) {
            $row = $null
            if (-not $script:logQueue.TryDequeue([ref]$row)) { break }
            Append-LogRow $row
            $n++
        }
        if ($n -gt 0 -and $log -and -not $log.IsDisposed) {
            # UI 日志保留最近 1200 行，避免长时间运行后 RichTextBox 追加变慢（磁盘日志仍全量保留）
            if ($log.Lines.Length -gt 1200) {
                $cutLine = $log.Lines.Length - 1200
                $cutIdx = $log.GetFirstCharIndexFromLine($cutLine)
                if ($cutIdx -gt 0) {
                    $ro = $log.ReadOnly
                    $log.ReadOnly = $false
                    $log.Select(0, $cutIdx)
                    $log.SelectedText = ''
                    $log.ReadOnly = $ro
                }
            }
            $log.SelectionStart = $log.TextLength
            $log.SelectionLength = 0
            $log.ScrollToCaret()
        }
    } finally { $script:draining = $false }
}

function Initialize-LogPump {
    if ($script:logTimer) { return }
    $script:logQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    $script:logTimer = New-Object System.Windows.Forms.Timer
    $script:logTimer.Interval = 60
    $script:logTimer.Add_Tick({ Drain-LogQueue })
    $script:logTimer.Start()
}

function Start-LogBlock { if ($script:logBlock) { return }; $script:logBlock = New-Object System.Collections.ArrayList }
function End-LogBlock {
    if (-not $script:logBlock) { return }
    $rows = $script:logBlock
    $script:logBlock = $null
    foreach ($r in $rows) {
        if ($script:logQueue) { $script:logQueue.Enqueue($r) } else { Append-LogRow $r }
    }
}

# 队列在这里初始化：$log 已创建（883 行），且之后的日志都走队列
Initialize-LogPump

function Write-CleanerOutput([object[]]$lines, [switch]$Brief) {
    # Brief 模式（清理并备份用）：界面只留清理前后体积、实际释放与异常项，Top5/网址明细全部走 -Det 进磁盘日志
    Start-LogBlock
    try {
        $inSection = $false
        foreach ($line in @($lines)) {
            $s = [string]$line
            if ([string]::IsNullOrWhiteSpace($s)) { $inSection = $false; continue }
            $s = $s -replace '^\s+', ''
            if ($Brief) {
                if ($s -match '^(清理前|清理后|实际释放|\[跳过\]|失败项)') { Write-Log $s }
                else { Write-Log $s 'info' -Det }
                continue
            }
            if ($s -match '^(当前剩余构成|清理后剩余构成|扩展占用 Top|站点数据 Top)') {
                Write-Log $s; $inSection = $true; continue
            }
            if ($inSection -and $s -match '^\d') { Write-Log $s; continue }
            if ($s -match '^(清理前|清理后|实际释放|预计可释放|差额核对|（想减少占用|（附带说明|\[OK\]|\[跳过\]|失败项|重启 Edge)') {
                $inSection = $false
                Write-Log $s
            } else {
                Write-Log $s 'info' -Det
            }
        }
    } finally { End-LogBlock }
}

function Write-Log([string]$text, [string]$level = 'info', [switch]$Det) {
    $t = (Get-Date).ToString('HH:mm:ss')
    # 级别必须是「2 个全角汉字」宽：实测雅黑 8.5pt 下「完成/警告/失败/信息」都是 39 px
    $tag = switch ($level) { 'ok' { '完成' } 'warn' { '警告' } 'err' { '失败' } default { '信息' } }
    # 仅给 2 字级别列着色（全部复用现有色板）：warn 按用户要求用红色 $clrBad（如需琥珀橙可改为 $clrWarn）
    $tagClr = switch ($level) { 'ok' { $clrGo } 'warn' { $clrBad } 'err' { $clrBad } default { $clrMuted } }
    Write-Host ("$t │ $tag │ $text")     # 磁盘日志：全量保留
    if ($Det) { return }                 # 明细只进日志文件，不上界面
    $row = [pscustomobject]@{ Time = $t; Tag = $tag; Clr = $tagClr; Text = $text }
    if ($script:logBlock) { [void]$script:logBlock.Add($row); return }
    if ($script:logQueue) { $script:logQueue.Enqueue($row); return }
    Append-LogRow $row
}

function Set-Busy([bool]$busy, [string]$msg = '') {
    # 全量按钮禁用/恢复（含次级按钮与策略组——更新删目录期间误点会并发写坏）
    $script:isBusy = $busy
    foreach ($b in $script:allButtons) {
        if ($b) { $b.Enabled = (-not $busy) -and (($b -ne $script:btnUpdate -and $b -ne $script:btnUpdateSlim) -or $script:updateAvailable) }
    }
    # R10：没有 Edge 包时，这些按钮即使在"空闲"态也必须保持禁用
    if ($script:noPackage -and $script:pkgButtons) {
        foreach ($b in $script:pkgButtons) { if ($b) { $b.Enabled = $false } }
    }
    $lblHint.Text = if ($busy) { $msg } else { '就绪' }
    $lblHint.ForeColor = if ($busy) { $clrHeaderAccent } else { $clrOnDarkMuted }
    $form.Invalidate($true)
    $form.Update()
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Ps([string]$scriptPath, [string[]]$argList) {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $argList
    $out = & $exe @all 2>&1
    return @{ Output = @($out); Code = $LASTEXITCODE }
}

# ---------------- 状态刷新 ----------------
function Get-StatusCachePath {
    # 复用 Get-RuntimeCacheDir，路径只解析一次
    if ($script:statusCachePath) { return $script:statusCachePath }
    $script:statusCachePath = Join-Path (Get-RuntimeCacheDir) 'status.json'
    return $script:statusCachePath
}

function Apply-Status([string]$payloadJson, [switch]$FromCache) {
    # 没有 Edge 包时不要把 EXE 目录的数字当状态显示（R10）
    if ($script:noPackage) {
        foreach ($l in @($valProg, $valProfile, $valDrm, $valIni, $valSlim, $valCache)) { $l.Text = '—'; $l.ForeColor = $clrMuted }
        return
    }
    # 统一入口：把后台/同步拿到的 {status, cacheMB} 落到界面上
    try {
        $p = $payloadJson | ConvertFrom-Json
        $s = $p.status | ConvertFrom-Json
        if (-not $s) { throw '状态为空' }
        $valProg.Text = "{0} 个`r`n{1} MB" -f $s.ProgFiles, [int][math]::Round($s.ProgMB)
        $valSlim.Text = if ($s.SlimCount -eq 0) { '已瘦身' } else { "{0} 个`r`n{1} MB" -f $s.SlimCount, [int][math]::Round($s.SlimMB) }
        $valSlim.ForeColor = if ($s.SlimCount -eq 0) { $clrGo } else { $clrWarn }
        $valProfile.Text = "{0} 目录`r`n{1} MB" -f $s.DataDirs, [int][math]::Round($s.DataMB)
        $valDrm.Text = if ($s.HasCdm) { '可用' } else { '不可用' }
        $valDrm.ForeColor = if ($s.HasCdm) { $clrText } else { $clrBad }
        $valIni.Text = if ($s.IniOff) { '已关闭' } else { '开启' }
        $valIni.ForeColor = if ($s.IniOff) { $clrGo } else { $clrText }
        $valCurVer.Text = '当前版本：' + (Get-LocalVersion)
        Set-SlimAllState ($s.SlimCount -eq 0 -and $s.IniOff)
        if ($p.cacheMB) { $valCache.Text = "{0} MB" -f $p.cacheMB } else { $valCache.Text = '—' }
        $cacheNum = 0.0
        if ($p.cacheMB -and [double]::TryParse([string]$p.cacheMB, [ref]$cacheNum)) {
            $valCache.ForeColor = if ($cacheNum -gt 500) { $clrBad } else { $clrText }   # 只有 >500MB 才标红
        } else { $valCache.ForeColor = $clrText }
        Set-CleanButtonState ($cacheNum -gt 500)
        $bkSame = ($p.PSObject.Properties.Name -contains 'backupUpToDate') -and [bool]$p.backupUpToDate
        Set-BackupButtonState (-not $bkSame)
        Update-PolicyCount
        # 只在内容变化时落盘：Add_Shown 从缓存读进来那次是"读→解析→原样写回"，纯无谓 I/O
        try {
            $cf = Get-StatusCachePath
            $oldText = if (Test-Path -LiteralPath $cf) { [System.IO.File]::ReadAllText($cf, [System.Text.Encoding]::UTF8) } else { '' }
            if ($oldText -ne $payloadJson) {
                [System.IO.File]::WriteAllText($cf, $payloadJson, (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch { }
        # 关键文件静默体检：全在就一个字不写，缺了才提示（每次运行最多一条，避免刷屏）
        if (-not $script:essentialChecked) {
            $script:essentialChecked = $true
            try {
                $es = Test-EssentialSet $edgeRoot
                if ($es.Required.Count -gt 0) {
                    Write-Log ('关键文件缺失（必需）：' + ($es.Required -join '、') + ' —— 程序可能起不来，可点「下载并更新」修复') 'err'
                } elseif ($es.Feature.Count -gt 0) {
                    Write-Log ('功能件缺失：' + ($es.Feature -join '、') + '（不影响启动；升级到上游新版通常会自动补回）') 'warn'
                }
            } catch { }
        }
        # 缓存回放（启动首帧）时的 EdgeRunning 是上次的旧值，不能当实时状态报出来
        if (-not $FromCache -and $s.EdgeRunning -gt 0) {
            Write-Log ('本包 Edge 正在运行（' + $s.EdgeRunning + ' 个进程），瘦身/清理/更新会被拒绝') 'warn'
        }
    } catch {
        Write-Log ('刷新状态失败：' + $_.Exception.Message) 'err'
    }
}

# 后台状态采集脚本（按当前 $pkgRoot 动态拼接，切换便携包目录后可重建）
function Build-StatusScript {
    return @"
# 只取以 { 开头的行：子脚本万一往 stderr 写了警告，不能让它污染 JSON（否则整块解析失败）
`$sj = & powershell -NoProfile -ExecutionPolicy Bypass -File '$edgeTune' -Action StatusJson -Quiet -Root '$pkgRoot' 2>&1 |
      ForEach-Object { [string]`$_ } | Where-Object { `$_ -match '^\s*\{' } | Select-Object -Last 1
`$pv = & powershell -NoProfile -ExecutionPolicy Bypass -File '$cleaner' -Quiet -Root '$pkgRoot' 2>&1 | Out-String
# 优先解析子脚本的机器可读行 #EPJSON（不依赖中文文案）；老版本/异常时回退原来的正则
`$cm = [regex]::Match(`$pv, '(?m)^#EPJSON\s*(\{[^\r\n]+\})')
`$cacheMB = ''
if (`$cm.Success) { try { `$cacheMB = [string](`$cm.Groups[1].Value | ConvertFrom-Json).totalMB } catch { } }
if (-not `$cacheMB) {
    `$m = [regex]::Match(`$pv, '预计可释放：([\d\.]+) MB')
    if (`$m.Success) { `$cacheMB = `$m.Groups[1].Value }
}
`$bkSame = `$false
try {
    `$rtRoot = `$env:EP_RUNTIME
    if (-not `$rtRoot) { `$rtRoot = Join-Path `$env:LOCALAPPDATA 'EdgePanel' }
    `$cacheDir = Join-Path `$rtRoot 'cache'
    `$fpFile = Join-Path `$cacheDir 'last-backup-fingerprint.json'
    `$probeFile = Join-Path `$cacheDir 'last-fp-probe.json'
    `$dDir = Join-Path '$pkgRoot' 'Data'
    if ((Test-Path -LiteralPath `$fpFile) -and (Test-Path -LiteralPath `$dDir)) {
        `$lastFp = (Get-Content -LiteralPath `$fpFile -Raw | ConvertFrom-Json).fp
        if (`$lastFp) {
            # 节流策略（便宜的先判，贵的不做）：
            # 1) Windows 上子目录内改文件不一定更新父目录 mtime，所以不能单靠目录 mtime 当绝对信号；
            # 2) 采用「60 秒时间节流 + 目录 mtime/顶层项数快检 + 5 分钟全量兜底」双保险，兼顾性能与准确性。
            `$defDir = Join-Path `$dDir 'Default'
            `$tRoot = (Get-Item -LiteralPath `$dDir).LastWriteTimeUtc.Ticks
            `$tDef  = if (Test-Path -LiteralPath `$defDir) { (Get-Item -LiteralPath `$defDir).LastWriteTimeUtc.Ticks } else { 0 }
            `$topCnt = @(Get-ChildItem -LiteralPath `$dDir -Force -ErrorAction SilentlyContinue).Count
            `$probe = `$null
            if (Test-Path -LiteralPath `$probeFile) {
                try { `$probe = Get-Content -LiteralPath `$probeFile -Raw | ConvertFrom-Json } catch { }
            }
            `$useCached = `$false
            if (`$probe -and `$probe.lastFp -eq `$lastFp -and `$probe.time) {
                `$ageSec = ((Get-Date) - [datetime]::Parse(`$probe.time)).TotalSeconds
                if (`$ageSec -lt 60) {
                    `$useCached = `$true
                } elseif (`$ageSec -lt 300 -and `$probe.tRoot -eq `$tRoot -and `$probe.tDef -eq `$tDef -and `$probe.topCnt -eq `$topCnt) {
                    `$useCached = `$true
                }
            }
            if (`$useCached) {
                `$bkSame = [bool]`$probe.same
            } else {
                `$sb = New-Object System.Text.StringBuilder
                foreach (`$f in (Get-ChildItem -LiteralPath `$dDir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                    [void]`$sb.Append(`$f.FullName).Append('|').Append(`$f.Length).Append('|').Append(`$f.LastWriteTimeUtc.Ticks).Append("`n")
                }
                if (Test-Path -LiteralPath '$cleaner') {
                    `$ci = Get-Item -LiteralPath '$cleaner'
                    [void]`$sb.Append('cleaner|').Append(`$ci.Length).Append('|').Append(`$ci.LastWriteTimeUtc.Ticks).Append("`n")
                }
                `$sha = [System.Security.Cryptography.SHA256]::Create()
                `$curFp = ([BitConverter]::ToString(`$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(`$sb.ToString())))).Replace('-', '')
                `$sha.Dispose()
                `$bkSame = (`$curFp -eq `$lastFp)
                try {
                    if (-not (Test-Path -LiteralPath `$cacheDir)) { New-Item -ItemType Directory -Path `$cacheDir -Force | Out-Null }
                    [ordered]@{ time = (Get-Date).ToString('s'); lastFp = `$lastFp; tRoot = `$tRoot; tDef = `$tDef; topCnt = `$topCnt; same = `$bkSame } |
                        ConvertTo-Json -Compress | Set-Content -LiteralPath `$probeFile -Encoding UTF8
                } catch { }
            }
        }
    }
} catch { }
[pscustomobject]@{
    status         = `$(if (`$sj) { `$sj.Trim() } else { '' })
    cacheMB        = `$cacheMB
    backupUpToDate = `$bkSame
} | ConvertTo-Json -Compress
"@
}
$script:statusScript = Build-StatusScript

$script:downloadScript = @'
param([string[]]$Mirrors, [string]$PartPath, [string]$ZipPath, [string]$ProgressPath)
# 后台下载：先给每个源测速（各拉 1MB），按实测速度排序后再下，越快越先；支持 Range 断点续传。
# 进度写 JSON 文件供界面读取——不在 UI 线程做任何阻塞 IO。
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$PROBE = 1048576   # 每源测速取样 1MB

function Save-Progress([hashtable]$h) {
    try { [System.IO.File]::WriteAllText($ProgressPath, ($h | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

# ---------- 1. 前两个源各做一段 1MB 测速（2 秒上限），其余留作换源兜底 ----------
$scores = @{}
$httpOnly = @($Mirrors | Where-Object { $_ -match '^https?://' })
if ($httpOnly.Count -gt 0) {
    Save-Progress @{ phase = 'speedtest'; msg = '测速中'; src = ''; recv = [long]0; total = [long]0 }
    $deadline = (Get-Date).AddSeconds(10)
    foreach ($u in ($httpOnly | Select-Object -First 2)) {   # 只测前 2 个，其余当换源兜底
        if ((Get-Date) -gt $deadline) { $scores[$u] = 0.0; continue }
        $best = 0.0
        foreach ($startByte in @(0)) {   # 单段采样（2 秒上限）
            $got = 0
            try {
                $req = [System.Net.HttpWebRequest]::Create($u)
                $req.UserAgent = 'EdgePanel/1.0'
                $req.Timeout = 5000
                $req.ReadWriteTimeout = 2500
                $req.AllowAutoRedirect = $true
                $req.AddRange([long]$startByte, [long]($startByte + $PROBE - 1))
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $buf = New-Object byte[] (128 * 1024)
                try {
                    while ($got -lt $PROBE) {
                        $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $PROBE - $got))
                        if ($n -le 0) { break }
                        $got += $n
                        if ($sw.Elapsed.TotalSeconds -gt 2.0) { break }
                    }
                } catch { }
                $secs = [math]::Max(0.05, $sw.Elapsed.TotalSeconds)
                $spd = ($got / 1048576) / $secs
                if ($spd -gt $best) { $best = $spd }
                try { $stream.Dispose(); $resp.Close() } catch { }
            } catch { }
            if ($best -ge 0.8) { break }
        }
        $scores[$u] = [math]::Round($best, 2)
    }
    $speedLine = ($httpOnly | ForEach-Object { ([uri]$_).Host + '=' + $scores[$_] + 'MB/s' }) -join '  '
    Save-Progress @{ phase = 'speedtest'; msg = ('测速完成：' + $speedLine); src = ''; recv = [long]0; total = [long]0 }
}
# 速度高的排前面；测不到速度（0）的按原始顺序垫后（加 Idx 保证 PS 5.1 非稳定排序不打乱同分项）
    $ranked = @()
    $idx = 0
    foreach ($u in $Mirrors) {
        $ranked += [pscustomobject]@{ Url = $u; Score = $(if ($scores.ContainsKey($u)) { $scores[$u] } else { 0.0 }); Idx = $idx }
        $idx++
    }
    $ordered = @($ranked | Sort-Object @{E='Score';Descending=$true}, @{E='Idx';Ascending=$true} | ForEach-Object { $_.Url })
$speedText = ($ordered | ForEach-Object {
    $s = if ($scores.ContainsKey($_)) { $scores[$_] } else { 0 }
    ([uri]$_).Host + ' ' + $s + ' MB/s'
}) -join ' | '
Save-Progress @{ phase = 'speedtest'; msg = ('测速完成：' + $speedText); src = ''; recv = [long]0; total = [long]0 }

# ---------- 2. 按速度顺序下载 ----------
$err = ''
foreach ($u in $ordered) {
    $hostName = if ($u -match '^https?://') { ([uri]$u).Host } else { '本地文件' }
    try {
        $have = if (Test-Path -LiteralPath $PartPath) { (Get-Item -LiteralPath $PartPath).Length } else { [long]0 }
        $req = [System.Net.HttpWebRequest]::Create($u)
        if ($req -is [System.Net.HttpWebRequest]) {
            $req.UserAgent = 'EdgePanel/1.0'
            $req.Timeout = 15000
            $req.ReadWriteTimeout = 15000
            $req.AllowAutoRedirect = $true
            if ($have -gt 0) { $req.AddRange($have) }
        }
        Save-Progress @{ phase = 'download'; src = $hostName; recv = $have; total = [long]0; msg = '连接中' }

        $resp = $req.GetResponse()
        $isPartial = if ($req -is [System.Net.HttpWebRequest]) { $resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent } else { $true }
        if ($have -gt 0 -and -not $isPartial) {
            $have = 0
            Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue
        }
        $totalBytes = if ($resp.ContentLength -gt 0) { $have + $resp.ContentLength } else { [long]0 }
        $fs = [System.IO.File]::Open($PartPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] (256 * 1024)
        $done = [long]$have
        $lastSave = 0.0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $fs.Write($buf, 0, $n)
                $done += $n
                if (($sw.Elapsed.TotalMilliseconds - $lastSave) -ge 400) {
                    $lastSave = $sw.Elapsed.TotalMilliseconds
                    $spd = [math]::Round((($done - $have) / 1MB) / [math]::Max(1.0, $sw.Elapsed.TotalSeconds), 2)
                    Save-Progress @{ phase = 'download'; src = $hostName; recv = $done; total = $totalBytes; spd = $spd; msg = '下载中' }
                }
            }
        } finally {
            $fs.Dispose()
            try { $stream.Dispose() } catch { }
            try { $resp.Close() } catch { }
        }
        $finalLen = (Get-Item -LiteralPath $PartPath).Length
        if ($totalBytes -gt 0 -and $finalLen -ne $totalBytes) {
            throw ('下载不完整：' + $finalLen + ' / ' + $totalBytes + ' 字节')
        }
        Move-Item -LiteralPath $PartPath -Destination $ZipPath -Force
        Save-Progress @{ phase = 'download'; src = $hostName; recv = $finalLen; total = $finalLen; msg = '完成' }
        return (@{ ok = $true; src = $hostName; bytes = $finalLen; speed = $speedText; error = '' } | ConvertTo-Json -Compress)
    } catch {
        $err = $_.Exception.Message
        $kept = if (Test-Path -LiteralPath $PartPath) { (Get-Item -LiteralPath $PartPath).Length } else { 0 }
        Save-Progress @{ phase = 'download'; src = $hostName; recv = $kept; total = [long]0; msg = ('换源：' + $err) }
    }
}
return (@{ ok = $false; src = ''; bytes = 0; speed = $speedText; error = $err } | ConvertTo-Json -Compress)
'@

$script:refreshTimer = New-Object System.Windows.Forms.Timer
$script:refreshTimer.Interval = 150
$script:refreshPs = $null
$script:refreshHandle = $null

function Set-RefreshBusy([bool]$busy) {
    # 刷新按钮解锁需叠加 isBusy 守卫：后台刷新若在其它长任务中途结束，
    # 不能提前解开 Set-Busy 锁定的按钮
    if ($script:btnRefresh) { $script:btnRefresh.Enabled = (-not $busy) -and (-not $script:isBusy) }
    # 忙碌时不覆盖 $lblHint（别冲掉下载/备份进度提示）；非忙碌正常显示刷新中/就绪
    if (-not $script:isBusy) {
        $lblHint.Text = if ($busy) { '刷新中…' } else { '就绪' }
        $lblHint.ForeColor = if ($busy) { $clrHeaderAccent } else { $clrOnDarkMuted }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-BtnState($btn, [bool]$on, [System.Drawing.Color]$onColor, [string]$text = '') {
    # 按钮状态统一切换：on=强调色实心白字，off=白底灰边（三处状态函数共用这一份实现）
    if (-not $btn) { return }
    if ($on) {
        $btn.BackColor = $onColor
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatAppearance.BorderColor = $onColor
    } else {
        $btn.BackColor = $clrBtnBg
        $btn.ForeColor = $clrText
        $btn.FlatAppearance.BorderColor = $clrBtnEdge
    }
    if ($text) { $btn.Text = $text }
}

function Set-UpdateHighlight([bool]$on) {
    # 有新版：按钮变绿并解锁；没新版/查询失败：恢复普通样式并锁回
    if (-not $script:btnUpdateSlim) { return }
    Set-BtnState $script:btnUpdateSlim $on $clrGo $(if ($on) { '更新并瘦身 →' } else { '更新并瘦身' })
    # 静默自动检查不会走 Set-Busy，所以这里必须自己把按钮解锁/锁回；但长任务进行中（isBusy）不许提前解锁
    if (-not $script:isBusy) {
        if ($script:btnUpdate) { $script:btnUpdate.Enabled = $on }
        $script:btnUpdateSlim.Enabled = $on
    }
}

function Set-CleanButtonState([bool]$highlight) {
    Set-BtnState $script:btnClean $highlight $clrAccent
}

function Set-BackupButtonState([bool]$needBackup) {
    # 用户数据相对上次备份有变化 → 蓝色引导；一致（无需重复备份）→ 常规灰色
    Set-BtnState $script:btnBackup $needBackup $clrAccent
}

function Set-SlimAllState([bool]$allDone) {
    # 已经「删过文件 + 组件更新已关闭」→ 按钮用普通底色；否则蓝色引导
    if (-not $script:btnSlimAll) { return }
    $wantBack = if ($allDone) { $clrBtnBg } else { $clrAccent }
    $wantBorder = if ($allDone) { $clrBtnEdge } else { $clrAccent }
    if ($script:btnSlimAll.BackColor -eq $wantBack -and $script:btnSlimAll.FlatAppearance.BorderColor -eq $wantBorder) { return }
    Set-BtnState $script:btnSlimAll (-not $allDone) $clrAccent
}

function Confirm-Action([string]$title, [string]$message) {
    # 统一走自绘深色确认框（确定=绿色 primary）；-RunOnce 自测直接放行
    return (Show-DialogAsk $title $message '确定' '取消')
}


function Update-StatusAsync {
    # 状态与缓存体积都在后台算，界面不再"顿一下"
    if ($script:refreshHandle) { Write-Log '状态正在刷新中，请稍候…' 'warn'; return }

    Set-RefreshBusy $true
    $script:refreshPs = [powershell]::Create()
    [void]$script:refreshPs.AddScript($script:statusScript)
    $script:refreshHandle = $script:refreshPs.BeginInvoke()
    $script:refreshTimer.Start()
}

$script:refreshTimer.Add_Tick({
    # 关窗瞬间 DoEvents 里 Timer 仍可能 Tick：BeginStop 后 EndInvoke 会抛
    # PipelineStoppedException 并误走 Write-Log——直接停表退出
    if ($script:closeRequested -or $form.IsDisposed) { $script:refreshTimer.Stop(); return }
    if (-not $script:refreshHandle -or -not $script:refreshHandle.IsCompleted) { return }
    $script:refreshTimer.Stop()
    $text = ''
    try {
        $out = $script:refreshPs.EndInvoke($script:refreshHandle)
        $text = ($out | Where-Object { $_ -is [string] } | Select-Object -Last 1)
    } catch {
        Write-Log ('后台刷新失败：' + $_.Exception.Message) 'err'
    } finally {
        if ($script:refreshPs) { $script:refreshPs.Dispose() }
        $script:refreshPs = $null
        $script:refreshHandle = $null
        Set-RefreshBusy $false
    }
    if ($text) {
        Start-LogBlock
        try { Apply-Status $text; Write-Log '状态已刷新' 'ok' } finally { End-LogBlock }
    }
    if ($script:pendingAutoCheck) {
        $script:pendingAutoCheck = $false
        Invoke-Check $true   # 静默检查：不打断用户操作，也不闪按钮
    }
})

function Update-Status {
    # 同步版：只在 -RunOnce 自测里用，直接跑与后台同一份脚本，避免两处命令漂移
    try {
        $payload = & ([scriptblock]::Create($script:statusScript)) | Select-Object -Last 1
        if (-not $payload) { throw '没拿到状态' }
        Apply-Status $payload
    } catch {
        Write-Log ('刷新状态失败：' + $_.Exception.Message) 'err'
    }
}


function Import-PolicyReg([string]$regFile, [string]$okLog = '策略导入完成') {
    # 唯一实现：经 UAC helper 导入策略键并解析结果（策略键对普通用户只读，必须提权）
    $stamp = (Get-Date).ToString('HHmmssfff')
    $helper = Join-Path $env:TEMP ('edgepanel-import-' + $stamp + '.ps1')
    $result = Join-Path $env:TEMP ('edgepanel-import-result-' + $stamp + '.txt')
    $helperCode = @'
param([string]$RegFile, [string]$ResultFile)
$lines = New-Object System.Collections.Generic.List[string]
try {
    $out2 = & reg.exe import $RegFile 2>&1
    if ($LASTEXITCODE -eq 0) { $lines.Add('RESULT: OK') }
    else { $lines.Add('RESULT: FAIL ' + (($out2 | Out-String).Trim())) }
} catch {
    $lines.Add('RESULT: FAIL ' + $_.Exception.Message)
} finally {
    [System.IO.File]::WriteAllLines($ResultFile, $lines, (New-Object System.Text.UTF8Encoding($true)))
}
'@
    [System.IO.File]::WriteAllText($helper, $helperCode, (New-Object System.Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue }
    Write-Log '正在请求管理员权限（UAC）以写入策略键…'
    try {
        $psi = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"'),
            '-RegFile', ('"' + $regFile + '"'), '-ResultFile', ('"' + $result + '"')
        )
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList $psi -Verb RunAs -WindowStyle Hidden -Wait | Out-Null
    } catch {
        Write-Log ('已取消（UAC 未确认）：' + $_.Exception.Message) 'warn'
        Remove-Item -LiteralPath $helper, $regFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    $ok = $false
    if (-not (Test-Path -LiteralPath $result)) {
        Write-Log '没有拿到导入结果，请检查 UAC 是否被拒绝' 'err'
    } else {
        foreach ($line in [System.IO.File]::ReadAllLines($result, [System.Text.Encoding]::UTF8)) {
            if ($line -like 'RESULT: OK*') { Write-Log $okLog 'ok'; $ok = $true }
            elseif ($line -like 'RESULT: FAIL*') { Write-Log ('策略导入失败：' + $line.Substring(13).Trim()) 'err' }
        }
    }
    Remove-Item -LiteralPath $helper, $result, $regFile -Force -ErrorAction SilentlyContinue
    return $ok
}

function Apply-RecommendedPolicies {
    # 把内嵌的推荐策略基线写成临时 .reg，经 UAC helper 直接写注册表（条数以基线文件为准）
    $baselineFile = Join-Path $scriptsDir 'EdgePolicyBaseline.json'
    if (-not (Test-Path -LiteralPath $baselineFile)) { Write-Log ('找不到策略基线：' + $baselineFile) 'err'; return }
    try {
        $baseline = [System.IO.File]::ReadAllText($baselineFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Write-Log ('策略基线解析失败：' + $_.Exception.Message) 'err'; return
    }
    # 该写哪些条目：唯一实现见 _Common 的 Get-ActiveBaselineRecords
    $activeRecs = Get-ActiveBaselineRecords $baseline
    # 需要顺手清掉旧值的（基线里标了 remove 的条目）
    $dropRecs = @($baseline | Where-Object { $_ -and $_.remove })
    $mainCount = @($activeRecs | Where-Object { -not $_.sub }).Count
    $subCount  = @($activeRecs | Where-Object { $_.sub }).Count

    $ok = Confirm-Action '应用推荐策略' ("将把推荐的 " + $mainCount + " 条主策略 + " + $subCount + " 条子键项写入注册表（同步推荐项并保留其它自定义项）。`r`n`r`n因为策略键只有管理员能写，会弹一次 UAC。继续吗？")
    if (-not $ok) { Write-Log '已取消应用推荐策略'; return }

    # 生成临时 .reg（UTF-16LE + BOM，regedit 格式）
    $regFile = Join-Path $env:TEMP ('edgepanel-recommended-' + (Get-Date).ToString('HHmmss') + '.reg')
    $regPath = $script:policyKeyPlain
    function Esc([string]$s) { return ($s -replace '\\', '\\\\' -replace '"', '\"') }
    function ValueLine($rec) {
        if ($rec.type -eq 'DWORD') { return ('"{0}"=dword:{1:x8}' -f (Esc $rec.name), [int]$rec.value) }
        return ('"{0}"="{1}"' -f (Esc $rec.name), (Esc ([string]$rec.value)))
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('Windows Registry Editor Version 5.00')
    $out.Add('')
    $out.Add('; 推荐策略基线 —— 由「便携 Edge 面板 v' + $script:panelVersion + '」内嵌基线生成')
    $out.Add('; 主策略 ' + $mainCount + ' 条 + 子键项 ' + $subCount + ' 条')
    $out.Add('')
    $out.Add('[' + $regPath + ']')
    foreach ($r in ($activeRecs | Where-Object { -not $_.sub })) { $out.Add((ValueLine $r)) }
    # 顺手删除"基线里已判定过时"的值（.reg 语法："名称"=- 表示删除该值）
    foreach ($r in ($dropRecs | Where-Object { -not $_.sub })) { $out.Add(('"{0}"=-' -f (Esc $r.name))) }
    foreach ($skName in (@($activeRecs | Where-Object { $_.sub } | ForEach-Object { $_.sub }) | Sort-Object -Unique)) {
        $out.Add('')
        $out.Add('[' + $regPath + '\' + $skName + ']')
        foreach ($r in ($activeRecs | Where-Object { $_.sub -eq $skName })) { $out.Add((ValueLine $r)) }
    }
    [System.IO.File]::WriteAllLines($regFile, $out, [System.Text.Encoding]::Unicode)

    # 复用统一的导入入口（UAC helper 与结果解析只有一份实现）
    $ok = Import-PolicyReg $regFile '推荐策略应用完成'
    if ($ok) { Write-Log '完全退出 Edge 再打开才生效。' 'warn'; try { Show-PolicyDrift } catch { } }
    Update-PolicyCount
}


# ---------------- F9：上游包结构漂移（只在更新时跑） ----------------
function Get-RuntimeCacheDir {
    $root = $env:EP_RUNTIME
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'EdgePanel' }
    $c = Join-Path $root 'cache'
    if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    return $c
}
function Get-PkgSnapshot([string]$edgeDir, [string]$scope = '') {
    # 只记文件（不记目录、不记 mtime）；版本目录名归一化成 {ver}
    $map = @{}
    $verName = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $edgeDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^\d+\.\d+\.\d+\.\d+$') { $verName = $d.Name; break }
    }
    $sum = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $edgeDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($edgeDir.Length).TrimStart('\')
        if ($verName -and $rel.StartsWith($verName + '\')) { $rel = '{ver}\' + $rel.Substring($verName.Length + 1) }
        if ($rel -match '^\d+\.\d+\.\d+\.\d+\.manifest$') { $rel = '{ver}.manifest' }
        $map[$rel] = [long]$f.Length
        $sum += [long]$f.Length
    }
    $normScope = if ([string]::IsNullOrWhiteSpace($scope)) { $edgeDir } else { $scope }
    return @{ version = $verName; files = $map; total = $sum; scope = $normScope.TrimEnd('\') }
}
function Save-PkgSnapshot($snap, [string]$path) {
    [ordered]@{ version = $snap.version; scope = $snap.scope; taken_at = (Get-Date).ToString('s'); total_bytes = $snap.total; files = $snap.files } |
        ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
}
function Test-StructureDrift([string]$edgeDir, [string]$scope = '') {
    $snapPath = Join-Path (Get-RuntimeCacheDir) 'last_pkg_snapshot.json'
    $new = Get-PkgSnapshot $edgeDir $scope
    if (-not (Test-Path -LiteralPath $snapPath)) {
        Write-Log ('结构基线：首次记录 ' + $new.files.Count + ' 个文件 / ' + [math]::Round($new.total / 1MB, 1) + ' MB（下次更新起比对）')
        return $new     # 由调用方在覆盖成功后才落盘（回滚时基线不跟着跑偏）
    }
    $old = $null
    try { $old = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json } catch { }
    if (-not $old -or -not $old.files) {
        Write-Log '结构基线文件损坏，将在本次更新成功后被重写（本次不比对）' 'warn'
        return $new
    }
    # 基线必须来自「同一个上游包目录」才有可比性：自测夹具、换机、换盘后路径都会变，
    # 拿旧基线硬比只会刷出一屏假的"结构变化"（实测踩到：基线是 11-21 自测用的 160.0.4408.0 假包）。
    $oldScope = ([string]$old.scope).TrimEnd('\')
    if (-not $oldScope -or ($oldScope -ine $new.scope)) {
        $why = if (-not $oldScope) { '旧格式基线没有来源标记' } else { '基线来自 ' + $oldScope }
        Write-Log ('结构基线不可比对（' + $why + '），已重建（本次不比对）')
        return $new
    }
    $oldFiles = @{}
    foreach ($pv in $old.files.PSObject.Properties) { $oldFiles[$pv.Name] = [long]$pv.Value }
    $oldTotal = [long]$old.total_bytes
    $added = @($new.files.Keys | Where-Object { -not $oldFiles.ContainsKey($_) } |
        ForEach-Object { [pscustomobject]@{ p = $_; mb = [math]::Round($new.files[$_] / 1MB, 2) } } | Sort-Object mb -Descending)
    $removed = @($oldFiles.Keys | Where-Object { -not $new.files.ContainsKey($_) } | Sort-Object)
    $changed = @($new.files.Keys | Where-Object { $oldFiles.ContainsKey($_) -and [math]::Abs($new.files[$_] - $oldFiles[$_]) -gt 1MB } |
        ForEach-Object { [pscustomobject]@{ p = $_; mb = [math]::Round(($new.files[$_] - $oldFiles[$_]) / 1MB, 2) } } |
        Sort-Object { [math]::Abs($_.mb) } -Descending)
    $pct = 0
    $pctTxt = '基线过小，不计百分比'
    if ($oldTotal -ge 1MB) {
        $pct = [math]::Round(($new.total - $oldTotal) / $oldTotal * 100, 2)
        $pctTxt = [string]$pct + '%'
    }
    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0) { return $new }   # 同结构：静默
    $bigAdd = @($added | Where-Object { $_.mb -ge 20 })
    $lvl = if ($bigAdd.Count -gt 0 -or $pct -ge 5) { 'err' } else { 'warn' }
    Write-Log ('上游包结构变化：新增 ' + $added.Count + ' / 消失 ' + $removed.Count + ' / 体积变化>1MB ' + $changed.Count +
        '；总量 ' + [math]::Round($oldTotal / 1MB, 1) + ' → ' + [math]::Round($new.total / 1MB, 1) + ' MB（' + $pctTxt + '）') $lvl
    foreach ($a in @($added | Select-Object -First 5)) { Write-Log ('  + ' + $a.p + '  ' + $a.mb + ' MB') $lvl }
    if ($added.Count -gt 5) { Write-Log ('  …另有 ' + ($added.Count - 5) + ' 个新增条目') $lvl }
    foreach ($r in @($removed | Select-Object -First 5)) { Write-Log ('  - ' + $r) $lvl }
    if ($removed.Count -gt 5) { Write-Log ('  …另有 ' + ($removed.Count - 5) + ' 个消失条目') $lvl }
    foreach ($c in @($changed | Select-Object -First 5)) { Write-Log ('  ~ ' + $c.p + '  ' + $c.mb + ' MB') $lvl }
    if (@($added | Where-Object { $_.p -like '*msedge_renderer.dll' }).Count -gt 0) {
        Write-Log '上游包里有 msedge_renderer.dll（你已删除它；若更新后它又出现，用「一键瘦身」再删一次）' 'warn'
    }
    return $new   # 有变化时也要把新快照交给调用方落盘，否则永远拿旧基线重复报警
}

# ---------------- F3：策略漂移体检（注册表 vs 内嵌基线） ----------------
function Get-PolicyDrift {
    # 基线（JSON 数组：[{type,name,value} | {type,sub,name,value}]）→ 扁平字典
    # 与 Apply-RecommendedPolicies 共用同一份「该写哪些条目」的判定（Get-ActiveBaselineRecords），
    # 避免两处口径漂移 —— v1.3.5 就是这里只对齐了一半，才让 Edge 159 后出现红字误报死循环。
    $flatBase = @{}
    foreach ($e in (Get-ActiveBaselineRecords $script:baseline)) {
        if (-not $e) { continue }
        $k = if ($e.sub) { [string]$e.sub + '\' + [string]$e.name } else { [string]$e.name }
        $flatBase[$k] = $e.value
    }
    # 注册表 → 扁平字典
    $flatCur = @{}
    if (Test-Path $script:policyKey) {
        $it = Get-Item $script:policyKey
        foreach ($n in @($it.GetValueNames())) { $flatCur[[string]$n] = $it.GetValue($n) }
        foreach ($sk in @($it.GetSubKeyNames())) {
            $sub = Get-Item ($script:policyKey + '\' + $sk)
            foreach ($n in @($sub.GetValueNames())) { $flatCur[[string]$sk + '\' + [string]$n] = $sub.GetValue($n) }
        }
    }
    $missing = @($flatBase.Keys | Where-Object { -not $flatCur.ContainsKey($_) } | Sort-Object)
    $extra = @($flatCur.Keys | Where-Object { -not $flatBase.ContainsKey($_) } | Sort-Object)
    $different = @($flatBase.Keys | Where-Object { $flatCur.ContainsKey($_) -and ("$($flatCur[$_])" -ne "$($flatBase[$_])") } | Sort-Object)
    return @{ Missing = $missing; Extra = $extra; Different = $different; Base = $flatBase; Current = $flatCur }
}

function Show-PolicyDrift {
    # 全对 → 完全静默；缺项红、值异/多余黄
    try { $d = Get-PolicyDrift } catch { Write-Log ('策略漂移检查失败（不阻断）：' + $_.Exception.Message) 'warn'; return }
    if ($d.Missing.Count -eq 0 -and $d.Extra.Count -eq 0 -and $d.Different.Count -eq 0) { return }
    if ($d.Missing.Count -gt 0) {
        Write-Log ('策略漂移：基线里有 ' + $d.Missing.Count + ' 条注册表缺失（多半是 GUI 的 Apply 清空重写过）→ 点「应用推荐策略」补回：' + (($d.Missing | Select-Object -First 4) -join '、')) 'err'
    }
    if ($d.Different.Count -gt 0) {
        Write-Log ('策略漂移：' + $d.Different.Count + ' 条取值与基线不一致：' + (($d.Different | Select-Object -First 4) -join '、')) 'warn'
    }
    if ($d.Extra.Count -gt 0) {
        Write-Log ('策略漂移：注册表有 ' + $d.Extra.Count + ' 条基线外自定义项') 'warn'
    }
}

# ---------------- 上游策略 GUI 的"专属条目丢失"监听（只读 + 询问，绝不自动改写） ----------------
# 上游 debloater-gui.ps1 的 Apply 是"清空整键 → 按勾选重写"（2026-11-22 实测其默认值）：
#   · NewTabPageAllowedBackgroundTypes：上游完全没有这一项（无开关）⇒ 每次 Apply 必被清掉，是真·专属；
#   · SleepingTabsEnabled=1 / SleepingTabsTimeout=900 / TrackingPrevention=2：上游有对应开关与下拉，
#     默认值恰好与本面板推荐值相同 ⇒ 勾着时按同值写回（不漂移），只有取消勾选或改值才漂移（那属于用户在 GUI 里的选择）。
# 因此这里盯这 4 条；提示文案按"上游有没有 UI"分两类说明，避免误说"都没有开关"。
$script:extraOnlyPolicies = @(
    'SleepingTabsEnabled',
    'SleepingTabsTimeout',
    'TrackingPrevention',
    'NewTabPageAllowedBackgroundTypes'
)
$script:upstreamUiPolicies = @(
    'SleepingTabsEnabled',
    'SleepingTabsTimeout',
    'TrackingPrevention'
)   # 上游策略 GUI 里有对应开关/下拉的条目（其余专属条目在上游完全没有 UI）
$script:policyGuiProc = $null
$script:policyGuiStarted = $null
$script:policyWatch = $null
$script:policyWatchHits = 0
$script:policyWatchDeadline = $null

function Get-ExtraPolicyDrift {
    $base = @{}
    foreach ($e in $script:baseline) { if ($e -and -not $e.sub) { $base[[string]$e.name] = $e.value } }
    $bad = @()
    foreach ($n in $script:extraOnlyPolicies) {
        if (-not $base.ContainsKey($n)) { continue }
        $cur = $null
        $has = $false
        try { $cur = (Get-ItemProperty -Path $script:policyKey -Name $n -ErrorAction Stop).$n; $has = $true } catch { }
        if (-not $has -or ("$cur" -ne "$($base[$n])")) { $bad += $n }
    }
    return $bad
}

function Restore-ExtraPolicies([string[]]$names) {
    # 只补这几条「专属策略」（不碰其它键值）：生成只含它们的 .reg，复用 Import-PolicyReg
    if (-not $names -or @($names).Count -eq 0) { return $false }
    $baselineFile = Join-Path $scriptsDir 'EdgePolicyBaseline.json'
    if (-not (Test-Path -LiteralPath $baselineFile)) { Write-Log ('找不到策略基线：' + $baselineFile) 'err'; return $false }
    $all = $null
    try { $all = [System.IO.File]::ReadAllText($baselineFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Write-Log ('策略基线解析失败：' + $_.Exception.Message) 'err'; return $false }
    $picked = @($all | Where-Object { -not $_.sub -and (@($names) -contains [string]$_.name) })
    if ($picked.Count -eq 0) { Write-Log '基线里找不到要补的条目，已跳过' 'warn'; return $false }
    $regFile = Join-Path $env:TEMP ('edgepanel-extra-policies-' + (Get-Date).ToString('HHmmss') + '.reg')
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('Windows Registry Editor Version 5.00')
    $out.Add('')
    $out.Add('; 只补专属策略 ' + $picked.Count + ' 条 —— 便携 Edge 面板 v' + $script:panelVersion)
    $out.Add('[' + $script:policyKeyPlain + ']')
    foreach ($r in $picked) {
        if ($r.type -eq 'DWORD') { $out.Add(('"{0}"=dword:{1:x8}' -f [string]$r.name, [int]$r.value)) }
        else { $out.Add(('"{0}"="{1}"' -f [string]$r.name, ([string]$r.value -replace '"', '\"'))) }
    }
    [System.IO.File]::WriteAllLines($regFile, $out, [System.Text.Encoding]::Unicode)
    $ok = Import-PolicyReg $regFile ('已恢复 ' + $picked.Count + ' 条专属策略')
    if ($ok) { try { Update-PolicyCount } catch { } }
    return $ok
}
function Start-PolicyWatch {
    # 打开上游策略 GUI 后开表：每 1 秒只读检查那 4 条专属策略；
    # 等上游窗口退出后再判（不盖在它界面上），连续 2 次缺失（≈2 秒）即提示。
    try {
        if ($script:policyWatch) { $script:policyWatch.Stop(); $script:policyWatch.Dispose() }
    } catch { }
    $script:policyWatchHits = 0
    $script:policyWatchDeadline = (Get-Date).AddMinutes(30)
    $script:policyWatch = New-Object System.Windows.Forms.Timer
    $script:policyWatch.Interval = 1000
    $script:policyWatch.Add_Tick({
        if ($script:closeRequested -or $form.IsDisposed) { $script:policyWatch.Stop(); return }
        if ($script:isBusy) { $script:policyWatchHits = 0; return }
        if ((Get-Date) -gt $script:policyWatchDeadline) { $script:policyWatch.Stop(); return }
        $guiGone = $true
        try { if ($script:policyGuiProc -and -not $script:policyGuiProc.HasExited) { $guiGone = $false } } catch { }
        if (-not $guiGone) {
            try { if ($script:policyGuiStarted -and ((Get-Date) - $script:policyGuiStarted).TotalSeconds -gt 90) { $guiGone = $true } } catch { }
        }
        if (-not $guiGone) { $script:policyWatchHits = 0; return }
        $bad = @()
        try { $bad = @(Get-ExtraPolicyDrift) } catch { }
        if ($bad.Count -eq 0) { $script:policyWatchHits = 0; return }
        $script:policyWatchHits++
        if ($script:policyWatchHits -lt 2) { return }
        $script:policyWatch.Stop()
        Write-Log ('上游策略工具导致这些推荐策略与基线不一致：' + ($bad -join '、')) 'warn'
        # 分两类说明：A=上游完全没有这一项（无开关，只能被清键误删）；B=上游有开关/下拉（默认值与推荐值相同）
        $noUi = @($bad | Where-Object { $script:upstreamUiPolicies -notcontains $_ })
        $hasUi = @($bad | Where-Object { $script:upstreamUiPolicies -contains $_ })
        $why2 = @()
        if ($noUi.Count -gt 0) { $why2 += ('· ' + ($noUi -join '、') + ' —— 上游没有这个开关，必被删掉') }
        if ($hasUi.Count -gt 0) { $why2 += ('· ' + ($hasUi -join '、') + ' —— 上游有开关；若是你刚在上面主动关的，选「暂不处理」即可') }
        $msg = ("上游策略工具重写注册表后，以下推荐策略未保留：`r`n`r`n" + ($why2 -join "`r`n") + "`r`n`r`n是否立即补回？（仅写入上述条目，其他策略不变，需 UAC 确认）")
        if (Show-DialogAsk '检测到专属策略被覆盖' $msg '立即补回' '暂不处理') {
            [void](Restore-ExtraPolicies $bad)
        } else {
            Write-Log '这次先不补回；下次打开面板还会提示。' 'warn'
        }
    })
    $script:policyWatch.Start()
    Write-Log ('开始盯上游策略工具：它一旦删掉 ' + $script:extraOnlyPolicies.Count + ' 条专属推荐策略，会在你关掉策略窗口后提示')
}

function Update-PolicyCount {
    $key = $script:policyKey
    if (Test-Path $key) {
        $valPolicy.Text = '当前已应用 ' + (Get-Item $key).ValueCount + ' 条策略'
        $valPolicy.ForeColor = $clrText
    } else {
        $valPolicy.Text = '未应用任何策略'
        $valPolicy.ForeColor = $clrMuted
    }
}

$script:packerSupportsZip = $false
function Find-Packer {
    # 内置 7za.exe 是唯一打包器：7z 与 zip/ZipCrypto 都由它一个搞定（不再需要 7za）
    $pZa = Join-Path $scriptsDir 'tools\7za.exe'
    if (Test-Path -LiteralPath $pZa) { $script:packerSupportsZip = $true; return $pZa }
    $script:packerSupportsZip = $false
    return $null
}

# ---------------- 备份密码（DPAPI 存储 + stdin 喂给 7za） ----------------
function Get-BackupPwFile {
    $root = $env:EP_RUNTIME
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'EdgePanel' }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return (Join-Path $root 'backup-pw.bin')
}
function Get-BackupPw {
    $f = Get-BackupPwFile
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $ent = [System.Text.Encoding]::UTF8.GetBytes('EdgePanel.BackupPw.v1')
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($f), $ent, 'CurrentUser')
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch {
        Write-Log ('读不出本机保存的备份密码（' + $_.Exception.Message + '）；请在备份弹窗里点「修改密码…」重设一次') 'warn'
        return $null
    }
}
function Set-BackupPw([string]$plain) {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $ent = [System.Text.Encoding]::UTF8.GetBytes('EdgePanel.BackupPw.v1')
    $enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($plain), $ent, 'CurrentUser')
    [IO.File]::WriteAllBytes((Get-BackupPwFile), $enc)
}

function Get-BackupModeFile { return (Join-Path (Get-RuntimeCacheDir) 'backup-mode.json') }
function Get-BackupCfg {
    # 备份偏好：方式(encrypted/plain)、格式(7z/zip)、保留份数(1-9)、目标目录(空=包根)、附带面板/浏览器(默认不勾，记忆上次)
    $cfg = @{ last = 'encrypted'; fmt = '7z'; keep = 3; dir = ''; panel = $false; full = $false }
    $f = Get-BackupModeFile
    if (Test-Path -LiteralPath $f) {
        try {
            $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($o.last -in @('encrypted', 'plain')) { $cfg.last = [string]$o.last }
            if ($o.fmt -in @('7z', 'zip')) { $cfg.fmt = [string]$o.fmt }
            if ($o.keep) { $k = [int]$o.keep; if ($k -ge 1 -and $k -le 9) { $cfg.keep = $k } }
            if ($o.dir) { $cfg.dir = [string]$o.dir }
            if ($o.PSObject.Properties.Name -contains 'panel') { $cfg.panel = [bool]$o.panel }
            if ($o.PSObject.Properties.Name -contains 'full')  { $cfg.full  = [bool]$o.full }
        } catch { }
    }
    return $cfg
}
function Normalize-Keep($val) {
    $k = 3
    if ($null -ne $val) { [void][int]::TryParse([string]$val, [ref]$k) }
    if ($k -lt 1) { $k = 1 }
    if ($k -gt 9) { $k = 9 }
    return $k
}
function Save-BackupCfg([hashtable]$cfg) {
    try {
        [ordered]@{ last = [string]$cfg.last; fmt = $(if ($cfg.fmt -eq 'zip') { 'zip' } else { '7z' }); keep = (Normalize-Keep $cfg.keep); dir = [string]$cfg.dir; panel = [bool]$cfg.panel; full = [bool]$cfg.full; updated = (Get-Date).ToString('s') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-BackupModeFile) -Encoding UTF8
    } catch { Write-Log ('保存备份配置失败：' + $_.Exception.Message) 'warn' }
}
function Resolve-BackupDir([string]$dir) {
    # 目标目录：空或不可写 → 回退包根（不静默丢备份）
    if ([string]::IsNullOrWhiteSpace($dir)) { return $pkgRoot }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { Write-Log ('备份目录不可用，回退包根：' + $dir) 'warn'; return $pkgRoot }
    }
    try {
        $probe = Join-Path $dir ('.wtest-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
        return $dir
    } catch { Write-Log ('备份目录不可写，回退包根：' + $dir) 'warn'; return $pkgRoot }
}
function Get-DataFingerprint([string]$dataDir) {
    # 指纹 = 排序后的 (路径|大小|mtime) 清单 SHA256；再把清理清单文件的 大小+mtime 拌进去，
    # 这样"清理清单改了但不该跳过"的情况不会被误判成没变化。实测 5,200 余文件约 0.8 秒。
    try {
        $sb = New-Object System.Text.StringBuilder
        foreach ($f in (Get-ChildItem -LiteralPath $dataDir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            [void]$sb.Append($f.FullName).Append('|').Append($f.Length).Append('|').Append($f.LastWriteTimeUtc.Ticks).Append("`n")
        }
        if (Test-Path -LiteralPath $cleaner) {
            $ci = Get-Item -LiteralPath $cleaner
            [void]$sb.Append('cleaner|').Append($ci.Length).Append('|').Append($ci.LastWriteTimeUtc.Ticks).Append("`n")
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())))).Replace('-', '') } finally { $sha.Dispose() }
    } catch { return $null }
}
function Get-FingerprintFile { return (Join-Path (Get-RuntimeCacheDir) 'last-backup-fingerprint.json') }
function Get-LastBackupStamp {
    # 上次成功备份记录：{ fp, time, name }
    $f = Get-FingerprintFile
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { return $null }
}
function Save-LastBackupStamp([string]$fp, [string]$name, [bool]$full = $false, [bool]$panel = $false, [string]$fmt = '7z') {
    try {
        [ordered]@{ fp = [string]$fp; time = (Get-Date).ToString('s'); name = [string]$name; full = [bool]$full; panel = [bool]$panel; fmt = [string]$fmt } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-FingerprintFile) -Encoding UTF8
    } catch { Write-Log ('保存备份指纹失败：' + $_.Exception.Message) 'warn' }
}

# 量出文本在给定宽度下需要多高（对话框按内容自适应，避免 DPI/字号变大时文字被切）
function Get-TextHeight([string]$text, $font, [int]$width) {
    try {
        $bmp = New-Object System.Drawing.Bitmap(8, 8)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $sz = $g.MeasureString($text, $font, [single]$width)
        $g.Dispose(); $bmp.Dispose()
        return [int][math]::Ceiling($sz.Height)
    } catch { return [int]([math]::Ceiling($font.GetHeight() * 2)) }
}

function New-DialogBase([string]$title, [int]$width, [switch]$NoClose) {
    # 所有弹窗共用外壳：Owner + 样式 + 字体 + 背景 + Win11 深色标题栏
    $dlg = New-Object System.Windows.Forms.Form
    try { $dlg.Owner = $form } catch { }
    $dlg.Text = $title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.AutoScaleMode = 'None'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    if ($NoClose) {
        $dlg.ControlBox = $false
        $dlg.ShowInTaskbar = $false
    }
    $dlg.StartPosition = 'Manual'
    $dlg.Font = $fontBase
    $dlg.BackColor = $clrBg
    $dlg.ForeColor = $clrText
    $dlg.Add_HandleCreated({ [ThemeHelper]::ApplyTitleBar($dlg.Handle, $script:isDark) })
    return $dlg
}

function New-TextInput($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text = '', [string]$align = 'Center', [switch]$Password) {
    # 圆角扁平输入框（与 FlatBtn 同款 5px 圆角 + 双层 1px 边，内部 TextBox 按 PreferredHeight 精确垂直居中）
    $shell = New-Object CardPanel
    $shell.Location = New-Object System.Drawing.Point($x, $y)
    $shell.Size = New-Object System.Drawing.Size($w, $h)
    $shell.BackColor = $clrBtnBg
    $shell.BorderColor = $clrBtnEdge
    $shell.Radius = 5
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.Text = $text
    $tb.TextAlign = $align
    $tb.Font = $fontBase
    $tb.BackColor = $clrBtnBg
    $tb.ForeColor = $clrText
    if ($Password) { $tb.UseSystemPasswordChar = $true }
    $padX = S 6
    $th = $tb.PreferredHeight
    $ty = [int][math]::Max(2, [math]::Floor(($h - $th) / 2))
    $tb.Location = New-Object System.Drawing.Point($padX, $ty)
    $tb.Size = New-Object System.Drawing.Size([math]::Max(10, ($w - 2 * $padX)), $th)
    $shell.Controls.Add($tb)
    $parent.Controls.Add($shell)
    return @{ Shell = $shell; Box = $tb }
}

function New-DialogBtn($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [ValidateSet('primary','secondary','danger')][string]$variant = 'secondary', [string]$dialogResult = 'None', [scriptblock]$onClick = $null) {
    # 弹窗内按钮统一走这里：primary / secondary / danger 三种克制样式（双主题感知）
    $b = New-Object FlatBtn
    Apply-FlatBtnTheme $b $false
    $b.Text = $text
    $b.Font = $fontBase
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Cursor = 'Hand'
    if ($dialogResult -ne 'None') { $b.DialogResult = $dialogResult }
    switch ($variant) {
        'primary' { $b.BackColor = $clrAccent; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = $clrAccent }
        'danger'  { $b.BackColor = $clrBad;    $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = $clrBad }
        default   { $b.BackColor = $clrBtnBg;  $b.ForeColor = $clrText; $b.FlatAppearance.BorderColor = $clrBtnEdge }
    }
    if ($onClick) { $b.Add_Click($onClick) }
    $parent.Controls.Add($b)
    return $b
}

function Add-DialogFooter($dlg, [int]$dlgWidth, [int]$contentBottomY, [string]$okText, [ValidateSet('primary','danger')][string]$okVariant = 'primary', [string]$cancelText = '取消') {
    # 统一底部操作栏：顶部 1px 分割线 + 卡片底色 + 右侧「主按钮 + 取消」
    $pad = S 16
    $barH = S 56
    $footer = New-Object System.Windows.Forms.Panel
    $footer.BackColor = $clrCard
    $footer.Location = New-Object System.Drawing.Point(0, ($contentBottomY + (S 16)))
    $footer.Size = New-Object System.Drawing.Size($dlgWidth, $barH)
    $footer.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($clrCardEdge, 1)
        $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0)
        $pen.Dispose()
    })
    $dlg.Controls.Add($footer)

    # 宽度按文字实测 + 内边距（下限沿用设计值），避免长文案被截断成「关闭 Edge 并…」
    $btnH = S 30; $btnY = S 13; $gap = S 10
    $padX = S 18
    $wOk = [int][math]::Max((S 112), ([System.Windows.Forms.TextRenderer]::MeasureText($okText, $fontBase).Width + 2 * $padX))
    $wCancel = [int][math]::Max((S 92), ([System.Windows.Forms.TextRenderer]::MeasureText($cancelText, $fontBase).Width + 2 * $padX))
    # 两个按钮 + 间距不得超过底栏可用宽度（超了等比压缩，宁窄也不出界）
    $availW = $dlgWidth - 2 * $pad
    if (($wOk + $wCancel + $gap) -gt $availW) {
        $scaleW = ([double]($availW - $gap)) / ($wOk + $wCancel)
        $wOk = [int][math]::Floor($wOk * $scaleW)
        $wCancel = [int][math]::Floor($wCancel * $scaleW)
    }
    $btnCancel = New-DialogBtn $footer ($dlgWidth - $pad - $wCancel) $btnY $wCancel $btnH $cancelText 'secondary' 'Cancel'
    $btnOk     = New-DialogBtn $footer ($dlgWidth - $pad - $wCancel - $gap - $wOk) $btnY $wOk $btnH $okText $okVariant 'OK'

    $dlg.ClientSize = New-Object System.Drawing.Size($dlgWidth, ($footer.Top + $barH))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    Show-DialogCentered $dlg
    return @{ Footer = $footer; Ok = $btnOk; Cancel = $btnCancel }
}

function Show-DialogCentered($dlg) {
    # Owner 在部分场景不生效，直接按面板矩形算坐标最稳
    try {
        $dlg.StartPosition = 'Manual'
        $dlg.Location = New-Object System.Drawing.Point(
            ($form.Left + [int](($form.Width - $dlg.Width) / 2)),
            ($form.Top + [int](($form.Height - $dlg.Height) / 2)))
    } catch { }
}

function Show-DialogAsk([string]$title, [string]$message, [string]$okText = '确定', [string]$cancelText = '取消', [switch]$Danger, [switch]$FocusCancel) {
    # 统一的自绘确认框（深色主题）：确定=绿色 primary；取消=secondary；-Danger 时确定变红
    if ($RunOnce) { return $true }
    if (-not $form -or $form.IsDisposed) { return $true }
    $w = S 470; $pad = S 18; $inner = $w - 2 * $pad
    $dlg = New-DialogBase $title $w
    $probe = New-Object System.Windows.Forms.Label
    $probe.AutoSize = $true
    $probe.MaximumSize = New-Object System.Drawing.Size($inner, 0)
    $probe.Text = $message
    $probe.Font = $fontBase
    $h = [int]$probe.PreferredHeight
    $probe.Dispose()
    if ($h -lt (S 18)) { $h = S 18 }
    $lb = New-Object System.Windows.Forms.Label
    $lb.AutoSize = $false
    $lb.Text = $message
    $lb.Font = $fontBase
    $lb.ForeColor = $clrText
    $lb.BackColor = [System.Drawing.Color]::Transparent
    $lb.Location = New-Object System.Drawing.Point($pad, $pad)
    $lb.Size = New-Object System.Drawing.Size($inner, $h)
    $dlg.Controls.Add($lb)
    $okVariant = if ($Danger) { 'danger' } else { 'primary' }
    $ft = Add-DialogFooter $dlg $w ($pad + $h) $okText $okVariant $cancelText
    if ($FocusCancel) { try { $dlg.ActiveControl = $ft.Cancel } catch { } }
    $res = $dlg.ShowDialog($form)
    try { $dlg.Dispose() } catch { }
    return ($res -eq 'OK')
}


function Show-BackupDialog([bool]$edgeRunning, [hashtable]$cfg) {
    # 一次问完：关 Edge（若在运行）+ 加密 + 保留份数 + 目标目录。整框按文字实测高度排版。
    $w = S 560
    $pad = S 16
    $inner = $w - 2 * $pad
    $dlg = New-DialogBase '备份用户数据' $w

    $lead = if ($edgeRunning) { '备份前将先关闭 Edge 并清理缓存，' } else { '备份前将先清理缓存，' }
    $textTop = $lead + "书签、扩展与登录状态均完整保留。"
    $hTop = Get-TextHeight $textTop $fontBase $inner

    $lb = New-Object System.Windows.Forms.Label
    $lb.AutoSize = $false
    $lb.Size = New-Object System.Drawing.Size($inner, ($hTop + (S 4)))
    $lb.Location = New-Object System.Drawing.Point($pad, $pad)
    $lb.ForeColor = $clrText
    $lb.Text = $textTop
    $dlg.Controls.Add($lb)

    # ── 第 1 行：加密 ──
    $rowY = $pad + $hTop + (S 14)
    # 同第 3 行：glyph 只画方块，文字走独立 Label，三者（方块/文字/状态）同高 26 同 Y
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = ''
    $chk.AutoSize = $false
    $chk.CheckAlign = 'MiddleCenter'
    $chk.Size = New-Object System.Drawing.Size((S 20), (S 26))
    $chk.Checked = ($cfg.last -eq 'encrypted')
    $chk.ForeColor = $clrText
    $chk.Location = New-Object System.Drawing.Point(($pad + (S 2)), $rowY)
    $dlg.Controls.Add($chk)

    $chkLbl = New-Object System.Windows.Forms.Label
    $chkLbl.AutoSize = $false
    $chkLbl.Size = New-Object System.Drawing.Size(([int][math]::Max((S 76), ([System.Windows.Forms.TextRenderer]::MeasureText('加密备份', $fontBase).Width + (S 10)))), (S 26))
    $chkLbl.TextAlign = 'MiddleLeft'
    $chkLbl.ForeColor = $clrText
    $chkLbl.Text = '加密备份'
    $chkLbl.Location = New-Object System.Drawing.Point(($pad + (S 22)), $rowY)
    $chkLbl.Add_Click({ $chk.Checked = -not $chk.Checked })
    $dlg.Controls.Add($chkLbl)

    $pwStatus = New-Object System.Windows.Forms.Label
    $pwStatus.AutoSize = $false
    $pwStatus.TextAlign = 'MiddleLeft'
    $pwStatus.Size = New-Object System.Drawing.Size((S 130), (S 26))
    $pwStatus.ForeColor = $clrMuted
    $pwStatus.Location = New-Object System.Drawing.Point(($chkLbl.Right + (S 8)), $rowY)
    $dlg.Controls.Add($pwStatus)

    $btnPw = New-DialogBtn $dlg ($w - $pad - (S 104)) $rowY (S 104) (S 26) '修改密码…' 'secondary'
    $btnCheck = New-DialogBtn $dlg ($w - $pad - (S 104) - (S 94)) $rowY (S 88) (S 26) '校验备份' 'secondary'

    $refreshPw = { if (Get-BackupPw) { $pwStatus.Text = '已保存密码' } else { $pwStatus.Text = '未设置密码' } }
    & $refreshPw
    $btnPw.Add_Click({
        $newPw = Show-PwDialog '备份密码' '设置备份密码。忘记密码后，备份文件将无法打开。' $true
        if (-not $newPw) { return }
        if ($newPw -notmatch '^[\x21-\x7E]{6,64}$' -or $newPw -match '["\\]') { Write-Log '密码只能用 6–64 位字母、数字和常见符号（不能含引号或反斜杠）' 'err'; return }
        try { Set-BackupPw $newPw } catch { Write-Log ('密码保存失败：' + $_.Exception.Message) 'err'; return }
        $chk.Checked = $true
        & $refreshPw
    })
    $btnCheck.Add_Click({
        # 备份包健康检查：对目录内全部历史备份逐个跑只读 7za t 并汇总（提前发现旧包密码不匹配或文件损坏）
        $dirNow = Resolve-BackupDir $script:pendingBackupDir
        $pkgs2 = @(Get-ChildItem -LiteralPath $dirNow -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(?i)Edge_Portable_(Data|Full)_.*\.(7z|zip)$' } |
            Sort-Object { $m = [regex]::Match($_.Name, '(\d{8}-\d{6})'); if ($m.Success) { $m.Groups[1].Value } else { $_.Name } } -Descending)
        if ($pkgs2.Count -eq 0) { Write-Log ('该目录里还没有备份可校验：' + $dirNow) 'warn'; return }
        $packer2 = Find-Packer
        if (-not $packer2) { Write-Log '找不到 7za，无法校验' 'err'; return }
        $pw2 = Get-BackupPw
        Write-Log ('开始校验目录内全部 ' + $pkgs2.Count + ' 份备份（只读，不解压）…')
        $okN = 0; $badList = @(); $idx2 = 0
        foreach ($pk2 in $pkgs2) {
            $idx2++
            Write-Log ('校验中 ' + $idx2 + '/' + $pkgs2.Count + '：' + $pk2.Name + ' …')
            try { $lblHint.Text = ('校验 ' + $idx2 + '/' + $pkgs2.Count) } catch { }
            $kind2 = if ($pk2.Name -like '*_Full_*') { '完整包' } else { '数据包' }
            # 密码走 stdin：t/l 不带 -p 时 7za 会从 stdin 读；-p<密码> 在 PS 5.1 下遇引号/反斜杠会被拆坏参数（实测）
            $tArgs = @('t', $pk2.FullName)
            $r = Invoke-Packer $packer2 $tArgs $dirNow $pw2
            if ($r.Code -eq 0) {
                $okN++
                Write-Log ('  [正常] ' + $pk2.Name + '（' + $kind2 + '）') 'ok'
            } else {
                $why2 = if ($pw2) { '密码不匹配或文件损坏' } else { '需要密码或文件损坏' }
                $badList += ($pk2.Name + '：' + $why2)
                Write-Log ('  [异常] ' + $pk2.Name + '（' + $kind2 + '，' + $why2 + '，退出码 ' + $r.Code + '）') 'err'
            }
        }
        if ($badList.Count -eq 0) {
            Write-Log ('健康检查完成：全部 ' + $okN + ' 份备份均可正常解开') 'ok'
        } else {
            Write-Log ('健康检查完成：' + $okN + ' 份正常，' + $badList.Count + ' 份打不开（' + ($badList -join '；') + '）') 'err'
        }
        try { $lblHint.Text = '就绪' } catch { }
    })

    # ── 说明行 ──
    $noteText = '不加密时，谁拿到备份文件都能直接打开。'
    $noteY = $rowY + (S 30)
    $hNote = Get-TextHeight $noteText $fontSmall $inner
    $note = New-Object System.Windows.Forms.Label
    $note.AutoSize = $false
    $note.Size = New-Object System.Drawing.Size($inner, ($hNote + (S 2)))
    $note.Location = New-Object System.Drawing.Point($pad, $noteY)
    $note.ForeColor = $clrMuted
    $note.Text = $noteText
    $dlg.Controls.Add($note)

    # ── 第 2 行：保留份数 + 目标目录 ──
    $row2Y = $noteY + $hNote + (S 12)
    $lbKeep = New-Object System.Windows.Forms.Label
    $lbKeep.AutoSize = $true
    $lbKeep.Text = '保留最近'
    $lbKeep.ForeColor = $clrText
    $lbKeep.Location = New-Object System.Drawing.Point($pad, ($row2Y + (S 4)))
    $dlg.Controls.Add($lbKeep)

    $keepInput = New-TextInput $dlg ($pad + (S 70)) $row2Y (S 44) (S 26) ([string]$cfg.keep)
    $boxKeep = $keepInput.Box

    $lbKeep2 = New-Object System.Windows.Forms.Label
    $lbKeep2.AutoSize = $true
    $lbKeep2.Text = '份'
    $lbKeep2.ForeColor = $clrText
    $lbKeep2.Location = New-Object System.Drawing.Point(($pad + (S 120)), ($row2Y + (S 4)))
    $dlg.Controls.Add($lbKeep2)

    $script:pendingBackupDir = [string]$cfg.dir
    $lbDir = New-Object System.Windows.Forms.Label
    $lbDir.AutoSize = $false
    $lbDir.Size = New-Object System.Drawing.Size((S 236), (S 20))
    $lbDir.AutoEllipsis = $true
    $lbDir.ForeColor = $clrMuted
    $lbDir.Location = New-Object System.Drawing.Point(($pad + (S 156)), ($row2Y + (S 4)))
    $dlg.Controls.Add($lbDir)

    $btnDir = New-DialogBtn $dlg ($w - $pad - (S 64)) $row2Y (S 64) (S 26) '更改…' 'secondary'
    $btnOpen = New-DialogBtn $dlg ($w - $pad - (S 64) - (S 6) - (S 54)) $row2Y (S 54) (S 26) '打开' 'secondary'
    $btnOpen.Add_Click({ try { Start-Process explorer.exe -ArgumentList ('"' + (Resolve-BackupDir $script:pendingBackupDir) + '"') } catch { } })

    $showDir = {
        $d = $script:pendingBackupDir
        if ([string]::IsNullOrWhiteSpace($d)) { $lbDir.Text = '备份到：包根目录' }
        else { $lbDir.Text = '备份到：' + $d }
    }
    & $showDir
    $btnDir.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = '选择备份保存位置'
        if ($script:pendingBackupDir -and (Test-Path -LiteralPath $script:pendingBackupDir)) { $fb.SelectedPath = $script:pendingBackupDir }
        if ($fb.ShowDialog() -eq 'OK') { $script:pendingBackupDir = $fb.SelectedPath; & $showDir }
    })

    # ── 格式行：7z（高压缩）/ zip（Win10 自带解压兼容，需内置 7za.exe）──
    [void](Find-Packer)
    $fmtY = $row2Y + (S 30) + (S 10)
    $lbFmt = New-Object System.Windows.Forms.Label
    $lbFmt.Text = '压缩格式'
    $lbFmt.AutoSize = $false
    $lbFmt.Size = New-Object System.Drawing.Size(([int][math]::Max((S 64), ([System.Windows.Forms.TextRenderer]::MeasureText('压缩格式', $fontBase).Width + (S 10)))), (S 24))
    $lbFmt.TextAlign = 'MiddleLeft'
    $lbFmt.ForeColor = $clrText
    $lbFmt.Location = New-Object System.Drawing.Point($pad, $fmtY)
    $dlg.Controls.Add($lbFmt)

    $rb7z = New-Object System.Windows.Forms.RadioButton
    $rb7z.Text = '7z（高压缩）'
    $rb7z.AutoSize = $true
    $rb7z.ForeColor = $clrText
    $rb7z.Location = New-Object System.Drawing.Point(($lbFmt.Right + (S 6)), ($fmtY + (S 2)))
    $dlg.Controls.Add($rb7z)

    $rbZip = New-Object System.Windows.Forms.RadioButton
    $rbZip.Text = 'zip（Win10 直接解压）'
    $rbZip.AutoSize = $true
    $rbZip.ForeColor = $clrText
    $wRb7z = [System.Windows.Forms.TextRenderer]::MeasureText($rb7z.Text, $fontBase).Width + (S 28)
    $rbZip.Location = New-Object System.Drawing.Point(($lbFmt.Right + (S 6) + $wRb7z), ($fmtY + (S 2)))
    $rbZip.Enabled = [bool]$script:packerSupportsZip
    if (-not $script:packerSupportsZip) { $script:tip.SetToolTip($rbZip, '需在编译时放入 tools\7za.exe 才支持 zip 格式') }
    $dlg.Controls.Add($rbZip)

    $useZip0 = ($cfg.fmt -eq 'zip') -and [bool]$script:packerSupportsZip
    $rb7z.Checked = (-not $useZip0)
    $rbZip.Checked = $useZip0

    # ── 第 3/4 行：面板程序（默认不勾，记忆上次）+ 浏览器程序（默认不勾，记忆上次）──
    $panelY = $fmtY + (S 28) + (S 6)
    $fullY = $panelY + (S 26) + (S 4)

    $chkPanel = New-Object System.Windows.Forms.CheckBox
    $chkPanel.Text = ''
    $chkPanel.AutoSize = $false
    $chkPanel.CheckAlign = 'MiddleCenter'
    $chkPanel.Size = New-Object System.Drawing.Size((S 20), (S 26))
    $chkPanel.Checked = [bool]$cfg.panel
    $chkPanel.ForeColor = $clrText
    $chkPanel.Location = New-Object System.Drawing.Point(($pad + (S 2)), $panelY)
    $dlg.Controls.Add($chkPanel)

    $chkLblPanel = New-Object System.Windows.Forms.Label
    $chkLblPanel.AutoSize = $false
    $chkLblPanel.Size = New-Object System.Drawing.Size(($inner - (S 26)), (S 26))
    $chkLblPanel.TextAlign = 'MiddleLeft'
    $chkLblPanel.ForeColor = $clrText
    $chkLblPanel.Text = '包含面板程序（约 +1 MB，换机解压可双击部署）'
    $chkLblPanel.Location = New-Object System.Drawing.Point(($pad + (S 22)), $panelY)
    $chkLblPanel.Add_Click({ $chkPanel.Checked = -not $chkPanel.Checked })
    $dlg.Controls.Add($chkLblPanel)
    # 勾选框只画方块、文字交给同高的独立 Label —— 两者都在 26px 行内垂直居中，彻底消除基线偏差
    $chkFull = New-Object System.Windows.Forms.CheckBox
    $chkFull.Text = ''
    $chkFull.AutoSize = $false
    $chkFull.CheckAlign = 'MiddleCenter'
    $chkFull.Size = New-Object System.Drawing.Size((S 20), (S 26))
    $chkFull.Checked = [bool]$cfg.full
    $chkFull.ForeColor = $clrText
    $chkFull.Location = New-Object System.Drawing.Point(($pad + (S 2)), $fullY)
    $dlg.Controls.Add($chkFull)

    $chkLblFull = New-Object System.Windows.Forms.Label
    $chkLblFull.AutoSize = $false
    $chkLblFull.Size = New-Object System.Drawing.Size(($inner - (S 26)), (S 26))
    $chkLblFull.TextAlign = 'MiddleLeft'
    $chkLblFull.ForeColor = $clrText
    $chkLblFull.Text = '包含浏览器程序（约 +218 MB，离线换机直接用）'
    $chkLblFull.Location = New-Object System.Drawing.Point(($pad + (S 22)), $fullY)
    $chkLblFull.Add_Click({ $chkFull.Checked = -not $chkFull.Checked })
    $dlg.Controls.Add($chkLblFull)

    $fullNoteText = '所有备份共用上方保留份数，按时间自动轮转。'
    $fullNoteY = $fullY + (S 26) + (S 2)
    $hFullNote = Get-TextHeight $fullNoteText $fontSmall $inner
    $fullNote = New-Object System.Windows.Forms.Label
    $fullNote.AutoSize = $false
    $fullNote.Font = $fontSmall
    $fullNote.Size = New-Object System.Drawing.Size($inner, ($hFullNote + (S 2)))
    $fullNote.Location = New-Object System.Drawing.Point($pad, $fullNoteY)
    $fullNote.ForeColor = $clrMuted
    $fullNote.Text = $fullNoteText
    $dlg.Controls.Add($fullNote)

    # ── 统一底部操作栏（恢复入口已挪到主界面「缓存与备份」组）──
    [void](Add-DialogFooter $dlg $w ($fullNoteY + $hFullNote) '开始备份' 'primary')
    $res = $dlg.ShowDialog()
    $enc = [bool]$chk.Checked
    $keep = Normalize-Keep $boxKeep.Text
    $dirOut = [string]$script:pendingBackupDir
    $script:pendingBackupDir = ''
    $dlg.Dispose()
    $fmtOut = if ($rbZip.Checked -and $script:packerSupportsZip) { 'zip' } else { '7z' }
    return @{ Start = ($res -eq 'OK'); Encrypt = $enc; Fmt = $fmtOut; Keep = $keep; Dir = $dirOut; Full = [bool]$chkFull.Checked; Panel = [bool]$chkPanel.Checked }
}
function Show-PwDialog([string]$title, [string]$note, [bool]$confirm) {
    # 按文字实测高度自适应；密码框统一走 New-TextInput，与备份弹窗视觉一致
    $w = S 460
    $pad = S 16
    $inner = $w - 2 * $pad
    $dlg = New-DialogBase $title $w

    $hNote = Get-TextHeight $note $fontBase $inner
    $lb = New-Object System.Windows.Forms.Label
    $lb.AutoSize = $false
    $lb.Size = New-Object System.Drawing.Size($inner, ($hNote + (S 4)))
    $lb.Location = New-Object System.Drawing.Point($pad, $pad)
    $lb.ForeColor = $clrMuted
    $lb.Text = $note
    $dlg.Controls.Add($lb)

    $y = $pad + $hNote + (S 12)
    $in1 = New-TextInput $dlg $pad $y $inner (S 28) '' 'Left' -Password
    $t1 = $in1.Box
    $y = $y + (S 28) + (S 10)
    $t2 = $null
    if ($confirm) {
        $in2 = New-TextInput $dlg $pad $y $inner (S 28) '' 'Left' -Password
        $t2 = $in2.Box
        $y = $y + (S 28) + (S 10)
    }

    [void](Add-DialogFooter $dlg $w ($y - (S 4)) '确定' 'primary')
    $dlg.Add_Shown({ $t1.Focus() })
    $res = $dlg.ShowDialog()
    $v1 = $t1.Text
    $v2 = if ($t2) { $t2.Text } else { '' }
    $dlg.Dispose()
    if ($res -ne 'OK') { return $null }
    if ($confirm -and $v1 -ne $v2) { Write-Log '两次输入的密码不一致，没保存' 'warn'; return $null }
    if ([string]::IsNullOrWhiteSpace($v1)) { return $null }
    return $v1
}

function Show-ProgressWindow([string]$title, [switch]$Stoppable, [switch]$TopMost) {
    # 通用进度窗：上行左阶段右百分比耗时 + 中间 8px 锐利直条 + 下行单行省略文件名（留白充裕，适配双主题）
    $w = S 460
    $pad = S 16
    $inner = $w - 2 * $pad
    $dlg = New-DialogBase $title $w -NoClose
    $dlg.BackColor = $clrCard

    $metaW = S 116
    $lbStatus = New-Object System.Windows.Forms.Label
    $lbStatus.AutoSize = $false
    $lbStatus.Font = $fontGroup
    $lbStatus.Size = New-Object System.Drawing.Size(($inner - $metaW - (S 8)), (S 22))
    $lbStatus.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbStatus.ForeColor = $clrText
    $lbStatus.TextAlign = 'MiddleLeft'
    $lbStatus.Text = '准备中…'
    $dlg.Controls.Add($lbStatus)

    $lbMeta = New-Object System.Windows.Forms.Label
    $lbMeta.AutoSize = $false
    $lbMeta.Font = $fontSmall
    $lbMeta.Size = New-Object System.Drawing.Size($metaW, (S 22))
    $lbMeta.Location = New-Object System.Drawing.Point(($w - $pad - $metaW), $pad)
    $lbMeta.ForeColor = $clrMuted
    $lbMeta.TextAlign = 'MiddleRight'
    $lbMeta.Text = ''
    $dlg.Controls.Add($lbMeta)

    $bar = New-Object FlatProgress
    $bar.BackColor = $clrCard
    $bar.BarColor = $clrAccent
    $bar.TrackColor = $clrTrack
    $bar.TrackBorderColor = $clrTrackEdge
    $bar.Value = 0
    $bar.Indeterminate = $true
    $bar.Size = New-Object System.Drawing.Size($inner, (S 8))
    $bar.Location = New-Object System.Drawing.Point($pad, ($pad + (S 30)))
    $dlg.Controls.Add($bar)

    $lbFile = New-Object System.Windows.Forms.Label
    $lbFile.AutoSize = $false
    $lbFile.AutoEllipsis = $true
    $lbFile.Font = $fontSmall
    $lbFile.Size = New-Object System.Drawing.Size($inner, (S 18))
    $lbFile.Location = New-Object System.Drawing.Point($pad, ($pad + (S 48)))
    $lbFile.ForeColor = $clrMuted
    $lbFile.TextAlign = 'MiddleLeft'
    $lbFile.Text = ''
    $dlg.Controls.Add($lbFile)

    $stopBtn = $null
    $baseH = $pad + (S 48) + (S 18) + $pad
    if ($Stoppable) {
        # 可中断任务（如深度搜索）：给一个明确的「停止」出口，别让用户只能干等
        $script:progressStop = $false
        $stopBtn = New-Object FlatBtn
        $stopBtn.Text = '停止'
        $stopBtn.Font = $fontSmall
        $stopBtn.Size = New-Object System.Drawing.Size((S 72), (S 26))
        $stopBtn.Location = New-Object System.Drawing.Point(($w - $pad - (S 72)), ($baseH + (S 4)))
        Apply-FlatBtnTheme $stopBtn $false
        $stopBtn.Add_Click({ $script:progressStop = $true; $stopBtn.Enabled = $false; $stopBtn.Text = '停止中…' })
        $dlg.Controls.Add($stopBtn)
        $baseH = $baseH + (S 34)
    }
    $dlg.ClientSize = New-Object System.Drawing.Size($w, $baseH)
    if ($TopMost) { $dlg.TopMost = $true }
    Show-DialogCentered $dlg
    $dlg.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return @{ Form = $dlg; Status = $lbStatus; Meta = $lbMeta; File = $lbFile; Bar = $bar; StopBtn = $stopBtn; Start = (Get-Date) }
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

function Invoke-Packer([string]$packer, [string[]]$argList, [string]$workDir, [string]$stdinPw, [int]$timeoutSec = 600) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $packer
    $psi.Arguments = (($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.WorkingDirectory = $workDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($stdinPw) { $psi.RedirectStandardInput = $true }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($stdinPw) {
        try { $p.StandardInput.WriteLine($stdinPw); $p.StandardInput.Flush() } catch { }
        try { $p.StandardInput.Close() } catch { }
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $sw7 = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    while (-not $p.WaitForExit(20)) {
        if ($script:closeRequested) { try { $p.Kill(); [void]$p.WaitForExit(1000) } catch { }; break }
        if ($timeoutSec -gt 0 -and $sw7.Elapsed.TotalSeconds -ge $timeoutSec) {
            $timedOut = $true
            try { $p.Kill(); [void]$p.WaitForExit(1000) } catch { }
            break
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $exitCode = if ($timedOut) { -2 } elseif ($p.HasExited) { $p.ExitCode } else { -1 }
    $outStr = if ($outTask.Wait(1500)) { $outTask.Result } else { '' }
    $errStr = if ($errTask.Wait(1500)) { $errTask.Result } else { '' }
    if ($timedOut) { $errStr = ('7za 执行超时（>' + $timeoutSec + ' 秒），已强制中止。' + $errStr) }
    $res = @{ Code = $exitCode; Out = $outStr; Err = $errStr; TimedOut = $timedOut }
    $p.Dispose()
    return $res
}

function Get-DriveFreeMB([string]$dirPath) {
    # 直调 .NET DriveInfo（底层 Win32 GetDiskFreeSpaceEx），避免 Get-PSDrive 枚举 Provider 偶发卡顿
    try {
        $rootDrive = [System.IO.Path]::GetPathRoot($dirPath)
        if (-not $rootDrive) { return $null }
        $di = New-Object System.IO.DriveInfo($rootDrive)
        return [math]::Round($di.AvailableFreeSpace / 1MB, 0)
    } catch { return $null }
}

function Move-DirWithRetry([string]$srcDir, [string]$dstDir, [int]$maxTries = 3) {
    # 针对解压后杀软瞬时扫盘占用的轻量重试（3 次 × 500ms）
    $lastErr = $null
    for ($t = 1; $t -le $maxTries; $t++) {
        try {
            Move-Item -LiteralPath $srcDir -Destination $dstDir -Force -ErrorAction Stop
            return
        } catch {
            $lastErr = $_
            if ($t -lt $maxTries) {
                Write-Log ('目录改名被占用（疑似杀毒软件正在扫描），0.5 秒后重试（' + $t + '/' + $maxTries + '）…') 'warn'
                for ($w = 0; $w -lt 10; $w++) { Start-Sleep -Milliseconds 50; [System.Windows.Forms.Application]::DoEvents() }
            }
        }
    }
    throw ('目录改名失败（文件被占用或杀毒软件正在扫描，请稍后重试）：' + $lastErr.Exception.Message)
}

function Invoke-CleanAndBackup([bool]$plaintext = $false, [switch]$Force, [switch]$Silent, [switch]$Full, [switch]$Panel) {
    # 一键：备份用户数据。$Silent 供"更新前自动备份"用：不弹窗、失败返回 $false。
    $packer = Find-Packer
    if (-not $packer) {
        Write-Log '面板内置的 7za 不在（多半被杀毒软件删了）。关掉面板重新打开会自动解包恢复。' 'err'
        return $false
    }
    $dataDir = Join-Path $pkgRoot 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) { Write-Log ('找不到数据目录：' + $dataDir) 'err'; return $false }

    # 1) 读偏好（方式 / 保留份数 / 目标目录）
    $cfg = Get-BackupCfg
    $encrypt = ($cfg.last -ne 'plain')
    $fmt = if ($cfg.fmt -eq 'zip' -and $script:packerSupportsZip) { 'zip' } else { '7z' }
    $keep = Normalize-Keep $cfg.keep
    $targetDir = Resolve-BackupDir $cfg.dir
    $full = [bool]$Full
    $panel = [bool]$Panel
    $running = @(Get-PackageProcs).Count

    if ($Silent) {
        if ($plaintext) { $encrypt = $false }
    } elseif ($RunOnce) {
        if ($plaintext) { $encrypt = $false }
    } else {
        try {
            $ans = Show-BackupDialog ($running -gt 0) $cfg
            if (-not $ans.Start) { Write-Log '已取消备份'; return $false }
            $encrypt = [bool]$ans.Encrypt
            $fmt = if ($ans.Fmt -eq 'zip' -and $script:packerSupportsZip) { 'zip' } else { '7z' }
            $keep = [int]$ans.Keep
            $full = [bool]$ans.Full
            $panel = [bool]$ans.Panel
            $cfg.last = $(if ($encrypt) { 'encrypted' } else { 'plain' })
            $cfg.fmt = $fmt
            $cfg.keep = $keep
            $cfg.dir = [string]$ans.Dir
            $cfg.panel = $panel
            $cfg.full = $full
            $targetDir = Resolve-BackupDir $cfg.dir
        } catch {
            Write-Log ('备份没能开始：' + $_.Exception.Message) 'err'
            return $false
        }
    }
    if (-not $Silent) { Save-BackupCfg $cfg }

    # 空间预检：打包时目标目录会同时存在 .tmp（≈数据体积），至少留 500 MB
    try {
        $freeMB = Get-DriveFreeMB $targetDir
        if ($null -ne $freeMB -and $freeMB -lt 500) { Write-Log ('磁盘剩余空间不足（' + $freeMB + ' MB，至少要 500 MB），已中止备份') 'err'; return $false }
    } catch { }

    Write-Log '开始：清理缓存 + 备份用户数据…'

    # 2) Edge 必须先退出，否则文件被占用、数据也不一致
    if ($running -gt 0) {
        if (-not (Close-Edge)) { Write-Log 'Edge 没能完全关闭，已中止备份' 'err'; return $false }
    }
    Write-Log ('打包器：' + $packer)

    # 3) 加密就用本机存好的密码；没有就当场设一个
    $pw = $null
    if ($encrypt) {
        $pw = Get-BackupPw
        if (-not $pw) {
            if ($RunOnce -or $Silent) {
                Write-Log '没有可用密码，这次改做未加密备份' 'warn'
                $encrypt = $false
            } else {
                $pw = Show-PwDialog '备份密码' '设置备份密码。忘记密码后，备份文件将无法打开。' $true
                if (-not $pw) { Write-Log '没设密码，已取消备份' 'warn'; return $false }
                if ($pw -notmatch '^[\x21-\x7E]{6,64}$' -or $pw -match '["\\]') { Write-Log '密码只能用 6–64 位字母、数字和常见符号（不能含引号或反斜杠）' 'err'; return $false }
                try { Set-BackupPw $pw } catch { Write-Log ('密码保存失败，已取消：' + $_.Exception.Message) 'err'; return $false }
            }
        }
    }
    Write-Log ('本次备份：' + $(if ($encrypt) { '已加密' } else { '未加密' }))
    if (-not $Silent) { Set-Busy $true '清理中…' }
    $fpNow = $null
    try {
        # 3) 常规清理
        Write-Log '步骤 1/3：常规清理缓存…'
        $rc = Invoke-Ps $cleaner @('-Apply', '-Quiet', '-Root', $pkgRoot)
        Write-CleanerOutput $rc.Output -Brief
        if ($rc.Code -ne 0) { Write-Log ('清理返回码 ' + $rc.Code + '，继续备份') 'warn' }


        # 4.5) 无变化跳过（D12）：清理之后再算指纹——Edge 一上网就改 BrowserMetrics 等文件，
        #      清理前的指纹几乎不可能与上次一致，必须先清再算。
        $fpNow = Get-DataFingerprint $dataDir
        if ($fpNow -and -not $Force) {
            $lastStamp = Get-LastBackupStamp
            # 勾选项也算"内容"：数据没变、但上次只打了数据包、这次勾了面板 → 不能当没变化跳过
            $lastFmt = if ($lastStamp -and ($lastStamp.PSObject.Properties.Name -contains 'fmt') -and $lastStamp.fmt) { [string]$lastStamp.fmt } else { '7z' }
            $sameShape = $lastStamp -and ([bool]$lastStamp.full -eq $full) -and ([bool]$lastStamp.panel -eq $panel) -and ($lastFmt -eq $fmt)
            if ($lastStamp -and $lastStamp.fp -eq $fpNow -and $sameShape) {
                Write-Log ('数据与上次备份一致（指纹 ' + $fpNow.Substring(0, 12) + '…），本次跳过打包。要强制备份：按住 Shift 点「清理并备份」') 'ok'
                Set-BackupButtonState $false
                return $true
            }
        }

        # 5) 打包到 .tmp，校验通过才改名（旧备份绝不先删）
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $prefix = if ($full) { 'Edge_Portable_Full_' } else { 'Edge_Portable_Data_' }
        $ext = if ($fmt -eq 'zip') { '.zip' } else { '.7z' }
        $out = Join-Path $targetDir ($prefix + $stamp + $ext)
        $tmp = Join-Path $targetDir ('Edge_Portable.tmp' + $ext)
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-Log ('步骤 2/3：打包到 ' + (Split-Path $out -Leaf) + ' …')
        $lblHint.Text = '打包中…'
        [System.Windows.Forms.Application]::DoEvents()
        $script:backupDlg = $null
        $script:backupPct = 0
        try { $script:backupDlg = Show-ProgressWindow '正在备份' } catch { }   # 进度窗只是锦上添花，失败不影响备份

        if ($fmt -eq 'zip') {
            # zip 偏向压缩率选 -mx7（Deflate Maximum）+ 多线程；加密走 ZipCrypto 以兼容 Win10/11 资源管理器自带解压
            $mxLevel = if ($env:EP_TEST_LIGHT -eq '1') { '-mx1' } else { '-mx7' }
            $argList = @('a', '-tzip', $mxLevel, '-mmt=on', '-bsp1', '-bso1')
            if ($pw) { $argList += @('-p', '-mem=ZipCrypto') }
        } else {
            $mxLevel = if ($env:EP_TEST_LIGHT -eq '1') { '-mx1' } else { '-mx4' }
            $argList = @('a', '-t7z', $mxLevel, '-mmt=on', '-md=16m', '-bsp1', '-bso1')
            if ($pw) { $argList += @('-p', '-mhe=on') }
        }
        # 两个可选项互相独立：面板程序（约 1 MB）/ 浏览器程序（约 218 MB）；文件名前缀只按"带不带 Edge"分
        $panelIncluded = $false
        if ($full) {
            $argList += @($tmp, 'Data', 'Edge', '-x!Edge\_old', '-x!Edge\_old\*')
        } else {
            $argList += @($tmp, 'Data')
        }
        if ($panel) {
            $selfExe = Get-PanelExePath
            $selfName = if ($selfExe) { Split-Path -Leaf $selfExe } else { '' }
            $inPkg = $selfExe -and ((Split-Path -Parent $selfExe).TrimEnd('\') -eq $pkgRoot.TrimEnd('\'))
            if ($selfExe -and (Test-Path -LiteralPath $selfExe) -and ($selfName -match $script:panelExeNameRe)) {
                # 即使跨目录运行面板，传入完整路径也能将面板 EXE 置于归档顶层
                $argList += $(if ($inPkg) { $selfName } else { $selfExe })
                $panelIncluded = $true
            } elseif ($selfName) {
                Write-Log ('面板文件名不在白名单（' + $selfName + '），未打入备份包；请使用标准文件名 EdgePanel.exe 或 Edge面板.exe') 'warn'
            } else {
                Write-Log '未定位到当前面板 EXE，未打入备份包' 'warn'
            }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $packer
        $psi.Arguments = (($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
        $psi.WorkingDirectory = $pkgRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($pw) { $psi.RedirectStandardInput = $true }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:backupProc = $proc
        if ($pw) {
            try { $proc.StandardInput.WriteLine($pw); $proc.StandardInput.Flush() } catch { }
            try { $proc.StandardInput.Close() } catch { }
        }
        $errTask = $proc.StandardError.ReadToEndAsync()
        $n = 0
        # 非阻塞读：ReadLine() 会在 7za 闷头压 16 MB 块时整条线程冻住好几秒（进度窗和秒表都不动）。
        # 这里改成 ReadLineAsync + 30ms 轮询 + 每 120ms 固定刷一次 UI，秒表与进度条都能平稳走。
        $pctNow = 0
        $curName = ''
        $lastUi = [Environment]::TickCount
        $lastPump = [Environment]::TickCount
        $readTask = $proc.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($readTask.IsCompleted) {
                $line = $readTask.Result
                if ($null -eq $line) {
                    if ($proc.HasExited) { break }
                    $readTask = $proc.StandardOutput.ReadLineAsync()
                } else {
                    $n++
                    if ($line -match '(\d+)%') { $pctNow = [int]$matches[1]; if ($pctNow -gt 100) { $pctNow = 100 } }
                    if ($line -match 'Compressing[:]?\s*(.+)$') { $curName = $matches[1].Trim() }
                    elseif ($line -match '^\s*\d+%\s+\S+\s+\S+\s+(.+)$') { $curName = $matches[1].Trim() }
                    $readTask = $proc.StandardOutput.ReadLineAsync()
                }
            } else {
                Start-Sleep -Milliseconds 15
            }
            $nowTick = [Environment]::TickCount
            if (($nowTick - $lastUi) -ge 120) {
                $lastUi = $nowTick
                if ($pctNow -ge $script:backupPct) { $script:backupPct = $pctNow }
                if ($script:backupDlg) {
                    if ($script:backupPct -gt 0 -and $script:backupDlg.Bar.Indeterminate) { $script:backupDlg.Bar.Indeterminate = $false }
                    if ($script:backupPct -ge $script:backupDlg.Bar.Value) { $script:backupDlg.Bar.Value = $script:backupPct }
                    $secs = [int]((Get-Date) - $script:backupDlg.Start).TotalSeconds
                    $script:backupDlg.Status.Text = '正在打包用户数据…'
                    if ($script:backupDlg.Meta) { $script:backupDlg.Meta.Text = ($script:backupDlg.Bar.Value.ToString() + '% · ' + $secs + ' 秒') }
                    $script:backupDlg.File.Text = $curName
                }
                try { $lblHint.Text = ('打包 ' + $script:backupPct + '%') } catch { }
            }
            # 消息泵按 16ms 放行（≈60fps）：进度条缓动才有帧可走；文字仍 120ms 节流
            if (($nowTick - $lastPump) -ge 16) {
                $lastPump = $nowTick
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        $tail = $proc.StandardOutput.ReadToEnd()
        $errRaw = $errTask.Result
        $code = $proc.ExitCode
        $proc.Dispose()
        $script:backupProc = $null
        Get-ChildItem -LiteralPath $targetDir -Filter ('Edge_Portable.tmp' + $ext + '.tmp*') -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

        if ($code -ne 0) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            $errText = if ($errRaw -and $errRaw.Trim()) { '：' + (($errRaw -split "`r?`n" | Where-Object { $_.Trim() }) -join ' / ') } else { '' }
            Write-Log ('打包失败（7za 退出码 ' + $code + '，非 0 一律判失败）' + $errText) 'err'
            if ($tail) { Write-Log $tail 'err' }
            return $false
        }

        # 6) 打包后校验：完整性 + 加密断言
        Write-Log '步骤 3/3：校验备份包…'
        # 打包已结束：进度窗别急着关，置满并切文案，盖住校验那 1–2 秒的空白
        if ($script:backupDlg) {
            try {
                $script:backupDlg.Bar.Indeterminate = $true
                $script:backupDlg.Status.Text = '正在校验备份包…'
                if ($script:backupDlg.Meta) { $script:backupDlg.Meta.Text = '校验中' }
                $script:backupDlg.File.Text = '校验完成后将自动关闭'
                [System.Windows.Forms.Application]::DoEvents()
            } catch { }
        }
        # 密码走 stdin（不带 -p 时 7za 会从 stdin 读），避免 -p<密码> 被 PowerShell 拆坏
        $verifyArgs = @('t', $tmp)
        $vt = Invoke-Packer $packer $verifyArgs $pkgRoot $pw
        if ($vt.Code -ne 0) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Log ('校验失败（7za t 退出码 ' + $vt.Code + '），已删除临时包，旧备份未动') 'err'
            return $false
        }
        if ($pw) {
            $listArgs = @('l', '-slt', $tmp)
            $lt = Invoke-Packer $packer $listArgs $pkgRoot $pw
            # 逐条解析：7-Zip 对 0 字节文件不做加密（没有内容可加密，Encrypted 记 -），
            # 所以断言只针对"非空文件"；空文件单独计数并在日志里说明，避免误判成加密失败。
            $raw = [string]$lt.Out
            $blocks = @($raw -split '(?m)^Path = ' | Where-Object { $_ -match '(?m)^Size = ' })
            $files = 0
            $encFiles = 0
            $empty = 0
            foreach ($b in $blocks) {
                if ($b -match '(?m)^Attributes = D') { continue }
                $sz = 0
                $mSz = [regex]::Match($b, '(?m)^Size = (\d+)')
                if ($mSz.Success) { $sz = [int]$mSz.Groups[1].Value }
                if ($sz -le 0) { $empty++; continue }
                $files++
                if ($b -match '(?m)^Encrypted = \+') { $encFiles++ }
            }
            $isEncMethod = if ($fmt -eq 'zip') { ($raw -match '(?m)^Method = .*ZipCrypto') } else { ($raw -match '(?m)^Method = .*7zAES') }
            if ($lt.Code -ne 0 -or -not $isEncMethod -or $files -lt 1 -or $encFiles -lt $files) {
                # 断言不通过＝包没按预期加密：删掉临时包并中止，绝不能改名上线、更不能删旧备份
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                Write-Log ('加密没生效（已加密 ' + $encFiles + ' / 共 ' + $files + ' 个文件），已丢弃这次生成的临时文件，旧备份没动') 'err'
                return $false
            } else {
                $encOkMsg = if ($fmt -eq 'zip') { '已确认整套 ZIP 备份均已 ZipCrypto 加密（兼容 Win10 自带解压）' } else { '已确认整套 7z 备份均已加密（文件名已隐藏）' }
                Write-Log $encOkMsg 'ok'
            }
        }
        Write-Log '完整性校验通过' 'ok'

        # 7) 改名 + 合并轮转：数据包与完整包共用保留最近 N 份额度，严格按文件名时间戳倒序（避免 Full_ 字母序排在 Data_ 前面）
        Move-Item -LiteralPath $tmp -Destination $out -Force
        $all = @(Get-ChildItem -LiteralPath $targetDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(?i)Edge_Portable_(Data|Full)_.*\.(7z|zip)$' } |
            Sort-Object { $m = [regex]::Match($_.Name, '(\d{8}-\d{6})'); if ($m.Success) { $m.Groups[1].Value } else { $_.Name } } -Descending)
        $kept = @($all | Select-Object -First $keep)
        $all | Select-Object -Skip $keep | ForEach-Object {
            $delKind = if ($_.Name -like '*_Full_*') { '完整包' } else { '数据包' }
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; Write-Log ('已删除较旧' + $delKind + '：' + $_.Name) 'warn' } catch { Write-Log ('删除较旧' + $delKind + '失败（' + $_.Name + '）：' + $_.Exception.Message) 'warn' }
        }
        $mb = [math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
        $kindParts = @('Data\')
        if ($full) { $kindParts += 'Edge\' }
        if ($panelIncluded) { $kindParts += '面板 EXE' }
        $kindTag = if ($full) { '完整包' } else { '数据包' }
        Write-Log ('备份完成：' + (Split-Path $out -Leaf) + '（' + $mb + ' MB，' + $kindTag + '（' + ($kindParts -join ' + ') + '），' + $(if ($encrypt) { '已加密' } else { '未加密' }) + '，当前共保留 ' + $kept.Count + ' 份）') 'ok'
        if ($fpNow) { Save-LastBackupStamp $fpNow (Split-Path $out -Leaf) $full $panel $fmt; Set-BackupButtonState $false }
        if ($full) {
            Write-Log ('完整包用法：解压到任意目录即可用（含 ' + ($kindParts -join ' + ') + '）。') 'warn'
        } elseif ($panelIncluded) {
            Write-Log '包里带面板：换机时解压双击 EdgePanel.exe，点「更新并瘦身」即可就地装好 Edge（无需另外下面板）。' 'warn'
        } else {
            Write-Log '恢复方法：直接在面板点「从备份恢复」即可一键还原（含完整校验与回滚保护）。' 'warn'
        }
        if (($full -or $panelIncluded) -and $keep -le 1) {
            Write-Log ('提示：当前保留份数为 1，下次日常备份会覆盖这份' + $kindTag + '；如需保留请把份数调到 2 以上。') 'warn'
        }
        return $true
    } catch {
        Write-Log ('执行失败：' + $_.Exception.Message) 'err'
        return $false
    } finally {
        $script:backupProc = $null
        if ($script:backupDlg) {
            try { $script:backupDlg.Form.Close() } catch { }
            try { $script:backupDlg.Form.Dispose() } catch { }
            $script:backupDlg = $null
        }
        if (-not $Silent -and -not $script:closeRequested -and -not $form.IsDisposed) {
            Set-Busy $false
            Update-StatusAsync
        }
    }
}
# ---------------- D1：从备份恢复（含 5 道护栏） ----------------
function Get-BackupPackages {
    # 备份目录里的候选包（数据包 + 完整包），按时间戳倒序（最新的在前）
    $dir = Resolve-BackupDir (Get-BackupCfg).dir
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(?i)Edge_Portable_(Data|Full)_.*\.(7z|zip)$' } |
            Sort-Object { $m = [regex]::Match($_.Name, '(\d{8}-\d{6})'); if ($m.Success) { $m.Groups[1].Value } else { $_.Name } } -Descending)
}

function Test-ArchiveSafe([string]$path, [string]$pw, [string]$packer) {
    # 只读检查：能否打开 + 条目是否安全 + 顶层结构 + 解压后总大小
    $args = @('l', '-slt', $path)
    # 密码走 stdin：不带 -p 时 7za 需要密码才读 stdin，对/错密码可区分（实测三种特殊字符均正常）
    $r = Invoke-Packer $packer $args $pkgRoot $pw
    $out = @{ Ok = $false; Reason = ''; TotalBytes = 0; HasData = $false; HasEdge = $false }
    if ($r.Code -ne 0) {
        $out.Reason = if ($pw) { '密码不对，或者包已损坏' } else { '包打不开（可能需要密码，或已损坏）' }
        return $out
    }
    $raw = [string]$r.Out
    $blocks = @($raw -split '(?m)^Path = ' | Where-Object { $_ -match '(?m)^Size = ' })
    $tops = @{}
    $total = [long]0
    foreach ($b in $blocks) {
        $lines = $b -split "`n"
        $p0 = $lines[0].Trim()
        if (-not $p0) { continue }
        # 路径穿越 / 绝对路径一律拒绝
        if ($p0 -match '^[A-Za-z]:' -or $p0 -match '\.\.' -or $p0.StartsWith('\') -or $p0.StartsWith('/')) {
            $out.Reason = ('包里含有不安全路径：' + $p0)
            return $out
        }
        $mSz = [regex]::Match($b, '(?m)^Size = (\d+)')
        if ($mSz.Success) { $total += [long]$mSz.Groups[1].Value }
        $top = ($p0 -split '\\')[0]
        if ($top) { $tops[$top] = $true }
    }
    # 完整包可能带一份面板 EXE（换机时解压即用）：只放行已知的两个名字，其它顶层项一律拒收
    $bad = @($tops.Keys | Where-Object { $_ -ne 'Data' -and $_ -ne 'Edge' -and $_ -notmatch $script:panelExeNameRe })
    if ($bad.Count -gt 0) {
        $out.Reason = ('包顶层不是 Data/Edge（发现：' + ($bad -join '、') + '），不像是本面板生成的备份')
        return $out
    }
    $out.HasData = $tops.ContainsKey('Data')
    $out.HasEdge = $tops.ContainsKey('Edge')
    if (-not $out.HasData) { $out.Reason = '包里没有 Data 目录'; return $out }
    $out.TotalBytes = $total
    $out.Ok = $true
    return $out
}

function Get-LastPkgFile { return (Join-Path (Get-RuntimeCacheDir) 'last-pkg.txt') }
function Get-LastSavedPkgRoot {
    $f = Get-LastPkgFile
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    try { return ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)).Trim() } catch { return '' }
}
function Save-LastPkgRoot([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    try { [System.IO.File]::WriteAllText((Get-LastPkgFile), $dir.TrimEnd('\'), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Test-SafeDeployDir([string]$dir) {
    # 仅允许空目录，或仅含面板 EXE / 本面板备份包 / Data / Cache 的目录执行全新部署，防止把 Edge 铺进杂乱目录
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return @{ Ok = $false; Others = @('目录不存在') } }
    $others = New-Object System.Collections.ArrayList
    foreach ($it in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($it.PSIsContainer) {
            if ($it.Name -ieq 'Data' -or $it.Name -ieq 'Cache') { continue }
            [void]$others.Add($it.Name + '\')
        } else {
            if (($it.Name -match $script:panelExeNameRe) -or ($it.Name -match '^(?i)Edge_Portable_.*\.(7z|zip)$')) { continue }
            [void]$others.Add($it.Name)
        }
    }
    return @{ Ok = ($others.Count -eq 0); Others = @($others) }
}

function Prompt-IfEdgeRunning {
    if ($env:EP_NO_PROMPT -eq '1' -or $RunOnce -or $script:closeRequested -or $form.IsDisposed) { return }
    $running = @(Get-PackageProcs)
    if ($running.Count -gt 0) {
        Write-Log ('检测到本包 Edge 正在运行（' + $running.Count + ' 个进程）') 'warn'
        $ansRun = $(if (Show-DialogAsk 'Edge 正在运行' ("当前便携包 Edge 正在运行（" + $running.Count + " 个进程）。`r`n`r`n" + "执行瘦身、清理或更新前需先退出浏览器。`r`n`r`n" + "是否现在关闭？（先正常关闭窗口，8 秒未退出将强制结束，不影响系统其他浏览器）") '关闭并继续' '暂不') { 'Yes' } else { 'No' })
        if ($ansRun -eq 'Yes') { Close-Edge }
        else { Write-Log '保持运行；等你要瘦身/清理/备份时，面板会再问一次要不要关。' 'warn' }
    }
}

function Show-PkgPickerDialog([string[]]$foundDirs, [string]$curExeDir, [string]$lastSaved, [bool]$allowDeployHere) {
    # 统一目录选择弹窗：支持多份便携 Edge 选择、空目录全新部署二选一（默认选中上次或首个已发现便携 Edge）、以及手动浏览目录
    $w = S 560
    $pad = S 16
    $inner = $w - 2 * $pad
    $dlg = New-DialogBase '选择便携 Edge 目录' $w
    $tipText = '检测到本机已有便携 Edge，请选择要管理的目录（或浏览指定其他目录）。'
    $hTip = Get-TextHeight $tipText $fontSmall $inner
    $tip = New-Object System.Windows.Forms.Label
    $tip.AutoSize = $false
    $tip.Font = $fontSmall
    $tip.Size = New-Object System.Drawing.Size($inner, ($hTip + (S 2)))
    $tip.Location = New-Object System.Drawing.Point($pad, $pad)
    $tip.ForeColor = $clrMuted
    $tip.Text = $tipText
    $dlg.Controls.Add($tip)

    $lbY = $pad + $hTip + (S 10)
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'
    $list.IntegralHeight = $false
    $list.Font = $fontSmall
    $list.BorderStyle = 'None'
    $list.BackColor = $clrCard
    $list.ForeColor = $clrText
    $list.Add_HandleCreated({ [ThemeHelper]::ApplyDarkScroll($list.Handle, $script:isDark) })
    $listBox = New-Object CardPanel
    $listBox.BackColor = $clrCard
    $listBox.Location = New-Object System.Drawing.Point($pad, $lbY)
    $listBox.Size = New-Object System.Drawing.Size($inner, (S 132))
    $listBox.BorderColor = $clrCardEdge
    $listBox.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 6), (S 6), (S 6))
    $listBox.Controls.Add($list)
    $dlg.Controls.Add($listBox)

    $choices = New-Object System.Collections.ArrayList
    $defIdx = 0
    foreach ($d in @($foundDirs)) {
        $verDir = Resolve-VersionDir (Join-Path $d 'Edge') 'msedge.exe'
        $verTxt = if ($verDir) { Split-Path -Leaf $verDir } else { '已就绪' }
        $mark = if ($lastSaved -and $d.Equals($lastSaved, [System.StringComparison]::OrdinalIgnoreCase)) { '（上次）' } else { '' }
        $idx = $choices.Add([pscustomobject]@{ Kind = 'existing'; Path = $d })
        [void]$list.Items.Add(('{0} ｜ {1}{2}' -f $d, $verTxt, $mark))
        if ($mark) { $defIdx = $idx }
    }
    if ($allowDeployHere -and $curExeDir) {
        [void]$choices.Add([pscustomobject]@{ Kind = 'deploy'; Path = $curExeDir })
        [void]$list.Items.Add(('在当前目录全新部署 ｜ ' + $curExeDir))
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = $defIdx }

    $browseY = $lbY + (S 132) + (S 8)
    $script:pickedBrowseDir = ''
    $btnDeep = New-Object FlatBtn
    $btnDeep.Text = '深度搜索本机…'
    $btnDeep.Font = $fontSmall
    $btnDeep.Location = New-Object System.Drawing.Point($pad, $browseY)
    $btnDeep.Size = New-Object System.Drawing.Size((S 124), (S 26))
    Apply-FlatBtnTheme $btnDeep $false
    $btnDeep.Add_Click({
        $btnDeep.Enabled = $false
        $prog = $null
        try {
            $script:progressStop = $false
            $prog = Show-ProgressWindow '正在深度搜索便携 Edge' -Stoppable -TopMost
            $deepSw = [Diagnostics.Stopwatch]::StartNew()
            if ($prog) {
                $prog.Bar.Indeterminate = $true
                $prog.Status.Text = '正在扫描本机固定盘符（最多 4 层，60 秒自动停止）…'
                if ($prog.Meta) { $prog.Meta.Text = '搜索中' }
                [System.Windows.Forms.Application]::DoEvents()
            }
            $deepDirs = @(Find-PortableEdgeDirsDeep 4 {
                param($curP, $vis, $hit)
                if ($script:closeRequested -or $dlg.IsDisposed -or $script:progressStop) { return $false }
                if ($deepSw.Elapsed.TotalSeconds -ge 60) { $script:progressStop = $true; return $false }
                if ($prog) {
                    $prog.File.Text = $curP
                    if ($prog.Meta) { $prog.Meta.Text = ('已扫描 ' + $vis + ' 目录 / 发现 ' + $hit + ' 份 / ' + [int]$deepSw.Elapsed.TotalSeconds + 's') }
                }
                [System.Windows.Forms.Application]::DoEvents()
                return $true
            })
            if ($script:progressStop -and $prog) { Write-Log ('深度搜索已停止（已扫 ' + $vis + ' 个目录）') 'warn' }
            $list.Items.Clear()
            $choices.Clear()
            $newDef = 0
            foreach ($d in $deepDirs) {
                $vd = Resolve-VersionDir (Join-Path $d 'Edge') 'msedge.exe'
                $vt = if ($vd) { Split-Path -Leaf $vd } else { '已就绪' }
                $mk = if ($lastSaved -and $d.Equals($lastSaved, [System.StringComparison]::OrdinalIgnoreCase)) { '（上次）' } else { '' }
                $ix = $choices.Add([pscustomobject]@{ Kind = 'existing'; Path = $d })
                [void]$list.Items.Add(('{0} ｜ {1}{2}' -f $d, $vt, $mk))
                if ($mk) { $newDef = $ix }
            }
            if ($allowDeployHere -and $curExeDir -and (-not ($deepDirs -contains $curExeDir.TrimEnd('\')))) {
                [void]$choices.Add([pscustomobject]@{ Kind = 'deploy'; Path = $curExeDir })
                [void]$list.Items.Add(('在当前目录全新部署 ｜ ' + $curExeDir))
            }
            if ($list.Items.Count -gt 0) { $list.SelectedIndex = $newDef }
            Write-Log ('深度搜索完成：发现 ' + $deepDirs.Count + ' 份便携 Edge') 'ok'
        } finally {
            if ($prog) { try { $prog.Close() } catch { } }
            if (-not $btnDeep.IsDisposed) { $btnDeep.Enabled = $true }
        }
    })
    $dlg.Controls.Add($btnDeep)

    $btnBrowse = New-Object FlatBtn
    $btnBrowse.Text = '浏览其他目录…'
    $btnBrowse.Font = $fontSmall
    $btnBrowse.Location = New-Object System.Drawing.Point(($pad + (S 132)), $browseY)
    $btnBrowse.Size = New-Object System.Drawing.Size((S 124), (S 26))
    Apply-FlatBtnTheme $btnBrowse $false
    $btnBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = '选择便携 Edge 根目录（包含 Edge\msedge.exe）'
        if ($fb.ShowDialog() -eq 'OK') {
            if (Test-PortableEdgeDir $fb.SelectedPath) {
                $script:pickedBrowseDir = $fb.SelectedPath
                $dlg.DialogResult = 'OK'
                $dlg.Close()
            } else {
                Write-Log ('所选目录不是便携 Edge 目录：' + $fb.SelectedPath) 'warn'
            }
        }
    })
    $dlg.Controls.Add($btnBrowse)

    [void](Add-DialogFooter $dlg $w ($browseY + (S 26)) '确定' 'primary')
    $res = $dlg.ShowDialog()
    $sel = $list.SelectedIndex
    $browsed = $script:pickedBrowseDir
    $script:pickedBrowseDir = ''
    $dlg.Dispose()
    if ($res -ne 'OK') { return $null }
    if ($browsed) { return [pscustomobject]@{ Kind = 'existing'; Path = $browsed } }
    if ($sel -ge 0 -and $sel -lt $choices.Count) { return $choices[$sel] }
    return $null
}

function Switch-PackageRoot([string]$newRoot, [switch]$CheckRunning) {
    if ([string]::IsNullOrWhiteSpace($newRoot)) { return }
    $norm = [System.IO.Path]::GetFullPath($newRoot).TrimEnd('\')
    $script:pkgRoot = $norm
    $script:progDir = Resolve-ProgramDir $norm
    $script:edgeRoot = Join-Path $norm 'Edge'
    $script:noPackage = -not (Test-Path -LiteralPath (Join-Path $script:edgeRoot 'msedge.exe'))
    # 同步刷新策略键（跟随新目录的 chrome++.ini policy_key）
    $pkName = 'Portable'
    $iniFile = Resolve-EdgeIni $norm
    if ($iniFile) {
        try {
            $mPk = [regex]::Match((Get-Content -LiteralPath $iniFile -Raw -Encoding UTF8), '(?im)^\s*policy_key\s*=\s*(\S+)')
            if ($mPk.Success -and $mPk.Groups[1].Value.Trim()) { $pkName = $mPk.Groups[1].Value.Trim() }
        } catch { }
    }
    $script:policyKey = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge_' + $pkName
    $script:policyKeyPlain = $script:policyKey -replace '^HKCU:', 'HKEY_CURRENT_USER'
    $script:statusScript = Build-StatusScript
    if ($lblSub) { $lblSub.Text = $norm }
    if (-not $script:noPackage) { Save-LastPkgRoot $norm }
    # 切换目录后重置依赖旧目录的缓存态，触发新目录的必需件体检、版本复核与策略漂移体检
    $script:essentialChecked = $false
    $script:updateAvailable = $false
    Set-UpdateHighlight $false
    $valNewVer.Text = '最新版本：未检查'
    $valNewVer.ForeColor = $clrMuted
    $script:pendingAutoCheck = $true
    Set-Busy $false
    Update-PolicyCount
    try { Show-PolicyDrift } catch { }
    Write-Log ('已切换目标目录：' + $norm) 'ok'
    if ($CheckRunning) { Prompt-IfEdgeRunning }
    if (-not $script:closeRequested -and -not $form.IsDisposed) { Update-StatusAsync }
}

function Invoke-SwitchPackageRoot {
    if ($script:isBusy) { Write-Log '当前有任务执行中，请稍后再切换目录' 'warn'; return }
    $lastSaved = Get-LastSavedPkgRoot
    $found = @(Find-PortableEdgeDirs $lastSaved)
    $safeHere = Test-SafeDeployDir $exeDir
    $allowDeploy = $safeHere.Ok -and (-not ($found -contains $exeDir.TrimEnd('\')))
    $pick = Show-PkgPickerDialog $found $exeDir $lastSaved $allowDeploy
    if ($pick -and $pick.Path) {
        Switch-PackageRoot $pick.Path -CheckRunning
    }
}

function Show-RestorePicker($packages) {
    $w = S 560
    $pad = S 16
    $inner = $w - 2 * $pad
    $dlg = New-DialogBase '从备份恢复' $w
    $tipText = '数据包仅恢复用户数据；完整包一并恢复浏览器程序（不覆盖当前面板）。'
    $hTip = Get-TextHeight $tipText $fontSmall $inner
    $tip = New-Object System.Windows.Forms.Label
    $tip.AutoSize = $false
    $tip.Font = $fontSmall
    $tip.Size = New-Object System.Drawing.Size($inner, ($hTip + (S 2)))
    $tip.Location = New-Object System.Drawing.Point($pad, $pad)
    $tip.ForeColor = $clrMuted
    $tip.Text = $tipText
    $dlg.Controls.Add($tip)

    $lbY = $pad + $hTip + (S 10)
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'
    $list.IntegralHeight = $false
    $list.Font = $fontSmall
    $list.BorderStyle = 'None'
    $list.BackColor = $clrCard
    $list.ForeColor = $clrText
    $list.Add_HandleCreated({ [ThemeHelper]::ApplyDarkScroll($list.Handle, $script:isDark) })
    $listBox = New-Object CardPanel
    $listBox.BackColor = $clrCard
    $listBox.Location = New-Object System.Drawing.Point($pad, $lbY)
    $listBox.Size = New-Object System.Drawing.Size($inner, (S 132))
    $listBox.BorderColor = $clrCardEdge
    $listBox.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 6), (S 6), (S 6))
    $listBox.Controls.Add($list)
    $dlg.Controls.Add($listBox)
    foreach ($pk in $packages) {
        $mb = [math]::Round($pk.Length / 1MB, 1)
        $kind = if ($pk.Name -like '*_Full_*') { '完整包' } else { '数据包' }
        [void]$list.Items.Add(('{0} ｜ {1} ｜ {2} MB' -f $pk.Name, $kind, $mb))
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    [void](Add-DialogFooter $dlg $w ($lbY + (S 132)) '开始恢复' 'primary')
    $res = $dlg.ShowDialog()
    $idx = $list.SelectedIndex
    $dlg.Dispose()
    if ($res -ne 'OK' -or $idx -lt 0) { return $null }
    return $packages[$idx]
}

function Invoke-RestoreBackup([switch]$Auto) {
    # 从备份恢复用户数据（完整包还可铺回 Edge 本体）。全部护栏：只读校验 → 空间预检 → 关 Edge → 临时目录解压 → 原子切换
    $packer = Find-Packer
    if (-not $packer) { Write-Log '面板内置的 7za 不在，无法恢复' 'err'; return }
    Write-Log '打开恢复：正在扫描备份目录…'
    $pkgs = Get-BackupPackages
    if ($pkgs.Count -eq 0) {
        Write-Log ('备份目录里没有可恢复的包：' + (Resolve-BackupDir (Get-BackupCfg).dir)) 'err'
        return
    }
    if ($Auto) { $pick = $pkgs[0]; Write-Log ('自动选择最新备份：' + $pick.Name) }
    else {
        $pick = Show-RestorePicker $pkgs
        if (-not $pick) { Write-Log '已取消恢复'; return }
    }
    $isFull = $pick.Name -like 'Edge_Portable_Full_*'

    # ① 密码：先试本机 DPAPI，不行再手输（新机器没有 backup-pw.bin 就走这条）
    # 先按"有没有本机密码"试一次：没有密码时按明文包试（l 不带 -p 能打开就说明是明文包）
    $pw = Get-BackupPw
    $safe = Test-ArchiveSafe $pick.FullName $pw $packer
    if (-not $safe -or -not $safe.Ok) {
        if ($Auto) { Write-Log ('自测模式：包打不开（' + $safe.Reason + '），不弹密码框，直接中止') 'err'; return }
        if ($pw) { Write-Log ('本机保存的密码打不开这个包：' + $safe.Reason + '；请手动输入') 'warn' }
        for ($k = 0; $k -lt 3; $k++) {
            $in = Show-PwDialog '恢复密码' ('这个备份包需要密码，输对才能恢复：' + $pick.Name) $false
            if (-not $in) { Write-Log '已取消恢复'; return }
            $safe = Test-ArchiveSafe $pick.FullName $in $packer
            if ($safe.Ok) {
                $pw = $in
                if (-not (Get-BackupPw)) { try { Set-BackupPw $in; Write-Log '密码已存到本机，下次自动用' 'ok' } catch { Write-Log ('密码保存失败（下次恢复需重输）：' + $_.Exception.Message) 'warn' } }
                break
            }
            Write-Log ('密码不对（第 ' + ($k + 1) + ' 次）：' + $safe.Reason) 'warn'
        }
        if (-not $safe.Ok) { Write-Log '密码连续错误，已中止恢复' 'err'; return }
    }
    Write-Log ('备份包校验通过：' + $pick.Name + '（解压后约 ' + [math]::Round($safe.TotalBytes / 1MB, 0) + ' MB）') 'ok'

    $swRestore = [Diagnostics.Stopwatch]::StartNew()
    # ② 空间预检：直调 DriveInfo（避免 Get-PSDrive 偶发卡顿），解压后体积 + 300 MB 余量
    Write-Log '恢复[2/7] 空间预检…'
    $needMB = [math]::Round($safe.TotalBytes / 1MB, 0) + 300
    $freeMB = Get-DriveFreeMB $pkgRoot
    if ($null -ne $freeMB -and $freeMB -lt $needMB) {
        Write-Log ('空间不足：需要约 ' + $needMB + ' MB，当前剩 ' + $freeMB + ' MB，已中止') 'err'
        return
    }

    # ③ 关 Edge 前置（绝不带锁硬切 Data\；支持 EP_NO_CLOSE_EDGE=1 测试护栏）
    Write-Log '恢复[3/7] 检查本包 Edge 进程…'
    if ($env:EP_NO_CLOSE_EDGE -eq '1') {
        Write-Log '（测试模式：跳过关闭 Edge）'
    } else {
        $runningEdge = @(Get-PackageProcs)
        if ($runningEdge.Count -gt 0) {
            if (-not $Auto -and -not $RunOnce) {
                $ansClose = $(if (Show-DialogAsk '需要先关闭 Edge' ("当前便携包 Edge 正在运行（" + $runningEdge.Count + " 个进程），恢复数据前需先关闭。`r`n`r`n是否立即关闭 Edge 并继续恢复？") '关闭并继续' '取消') { 'Yes' } else { 'No' })
                if ($ansClose -ne 'Yes') { Write-Log '已取消恢复（请先手动关闭本包 Edge 后重试）' 'warn'; return }
            }
            if (-not (Close-Edge)) { Write-Log 'Edge 没能完全关闭，已中止恢复（请手动关闭 Edge 后重试）' 'err'; return }
        }
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $tmp = Join-Path $pkgRoot ('_restore_tmp_' + $stamp)
    $oldData = Join-Path $pkgRoot ('Data_old_' + $stamp)
    $oldEdge = Join-Path $pkgRoot ('Edge_old_' + $stamp)
    $curData = Join-Path $pkgRoot 'Data'
    $movedData = $false
    $movedEdge = $false
    $prog = $null
    $busyEntered = $false
    try {
        # R2：Set-Busy 移入 try 内，确保任何异常都能在 finally 恢复按钮可用
        Set-Busy $true '恢复中…'
        $busyEntered = $true
        try {
            $prog = Show-ProgressWindow '正在恢复备份'
        } catch {
            # R4：不再静默吞异常
            Write-Log ('进度窗创建失败（不影响恢复继续）：' + $_.Exception.Message) 'warn'
        }
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        # ④ 解压到同盘临时目录（绝不直接往包根解；600 秒看门狗防死挂）
        Write-Log '恢复[4/7] 正在解压到临时目录…'
        if ($prog) { $prog.Status.Text = '正在解压备份包…'; if ($prog.Meta) { $prog.Meta.Text = '解压中' }; $prog.Bar.Indeterminate = $true; [System.Windows.Forms.Application]::DoEvents() }
        $xr = Invoke-Packer $packer @('x', '-y', ('-o' + $tmp), $pick.FullName) $pkgRoot $pw 600
        if ($xr.Code -ne 0) {
            $xWhy = if ($xr.TimedOut) { $xr.Err } else { '解压失败（7za 退出码 ' + $xr.Code + '）' }
            throw $xWhy
        }
        Write-Log ('恢复[4/7] 解压完成（已用 ' + [math]::Round($swRestore.Elapsed.TotalSeconds, 1) + ' 秒）')
        # 完整包里可能带了一份面板 EXE：只提示、不覆盖（本机正在运行、且可能比包里新）
        $tmpExe = @(Get-ChildItem -LiteralPath $tmp -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:panelExeNameRe })
        if ($tmpExe.Count -gt 0) {
            Write-Log ('包里带面板 ' + $tmpExe[0].Name + '（' + [math]::Round($tmpExe[0].Length / 1MB, 1) + ' MB）：本机保留当前面板不覆盖；换机时可直接从包里取出这个 EXE 使用') 'warn'
        }

        # ⑤ 关键条目校验：Local State + Default\Preferences（Bookmarks/Cookies 只提示）
        Write-Log '恢复[5/7] 校验解压结果关键文件…'
        $tmpData = Join-Path $tmp 'Data'
        if (-not (Test-Path -LiteralPath $tmpData)) { throw '解压结果里没有 Data 目录' }
        $lsFile = Join-Path $tmpData 'Local State'
        $prefFile = Join-Path $tmpData 'Default\Preferences'
        if (-not (Test-Path -LiteralPath $lsFile) -or (Get-Item -LiteralPath $lsFile).Length -lt 10) { throw '备份里的 Local State 缺失或为空，拒绝覆盖现有数据' }
        if (-not (Test-Path -LiteralPath $prefFile) -or (Get-Item -LiteralPath $prefFile).Length -lt 10) { throw '备份里的 Default\Preferences 缺失或为空，拒绝覆盖现有数据' }
        if (-not (Test-Path -LiteralPath (Join-Path $tmpData 'Default\Bookmarks'))) { Write-Log '提示：这个包里没有书签文件（可能当时就没收藏）' 'warn' }

        # ⑥ 完整包：先把 Edge 本体铺回来（R5：改名前后打日志 + 杀软瞬时占用重试）
        if ($isFull) {
            $tmpEdge = Join-Path $tmp 'Edge'
            if (-not (Test-Path -LiteralPath $tmpEdge)) { throw '完整包里没有 Edge 目录' }
            if ($prog) { $prog.Status.Text = '正在替换 Edge 程序文件…'; [System.Windows.Forms.Application]::DoEvents() }
            Write-Log '恢复[6/7] 正在改名切换 Edge 本体…'
            if (Test-Path -LiteralPath $edgeRoot) { Move-DirWithRetry $edgeRoot $oldEdge; $movedEdge = $true }
            Move-DirWithRetry $tmpEdge $edgeRoot
            # 完整备份是整个 Edge\ 目录：如果备份早于 2026-11-21（那时包根还没有 proxy），恢复会把
            # PWA 快捷方式的目标一起换掉 ⇒ 这里立刻补齐（有就什么都不做）
            try { [void](Sync-RootProxy $edgeRoot) } catch { }
            Write-Log ('已用完整包里的 Edge 本体替换（旧本体在 ' + (Split-Path $oldEdge -Leaf) + '，确认正常后可手动删）') 'warn'
        }

        # ⑦ 原子切换 Data：现用改名 → 新数据改名上位（R5：前后日志 + 3 次重试）
        if ($prog) { $prog.Status.Text = '正在切换用户数据…'; [System.Windows.Forms.Application]::DoEvents() }
        Write-Log '恢复[6/7] 正在改名切换用户数据…'
        if (Test-Path -LiteralPath $curData) { Move-DirWithRetry $curData $oldData; $movedData = $true }
        Move-DirWithRetry $tmpData $curData
        Write-Log '恢复[6/7] 用户数据改名切换完成' 'ok'

        # ⑧ 本体就位 → 复核 → 瘦身
        Write-Log '恢复[7/7] 复核程序文件与瘦身状态…'
        $script:noPackage = -not (Test-Path -LiteralPath (Join-Path $edgeRoot 'msedge.exe'))
        if (-not $script:noPackage) {
            $post = Test-EssentialSet $edgeRoot
            if ($post.Required.Count -gt 0) { Write-Log ('恢复后关键文件缺失（必需）：' + ($post.Required -join '、')) 'err' }
            else { Write-Log ('关键文件复核：必需 ' + $script:essentialRequired.Count + ' 项齐全') 'ok' }
            if ($prog) { $prog.Status.Text = '正在瘦身…'; [System.Windows.Forms.Application]::DoEvents() }
            $rs = Invoke-Ps $edgeTune @('-Action', 'SlimAll', '-Quiet', '-Root', $pkgRoot)
            foreach ($line in $rs.Output) { $s2 = [string]$line; if (-not [string]::IsNullOrWhiteSpace($s2)) { Write-Log ($s2 -replace '^\s+', '') } }
        }
    } catch {
        # 失败回滚：把旧数据/旧本体改回来，清掉临时目录
        Write-Log ('恢复失败（已用 ' + [math]::Round($swRestore.Elapsed.TotalSeconds, 1) + ' 秒）：' + $_.Exception.Message) 'err'
        try {
            if ($movedData -and -not (Test-Path -LiteralPath $curData) -and (Test-Path -LiteralPath $oldData)) {
                Move-Item -LiteralPath $oldData -Destination $curData -Force; Write-Log '已把原来的 Data 改回来' 'warn'
            }
            if ($movedEdge -and -not (Test-Path -LiteralPath $edgeRoot) -and (Test-Path -LiteralPath $oldEdge)) {
                Move-Item -LiteralPath $oldEdge -Destination $edgeRoot -Force; Write-Log '已把原来的 Edge 改回来' 'warn'
            }
        } catch { Write-Log ('回滚也失败了，请手动检查包根：' + $_.Exception.Message) 'err' }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        return
    } finally {
        if ($prog) { try { $prog.Form.Close() } catch { }; try { $prog.Form.Dispose() } catch { }; $prog = $null }
        if ($busyEntered -and -not $script:closeRequested -and -not $form.IsDisposed) { Set-Busy $false }
    }

    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log ('恢复完成（总用时 ' + [math]::Round($swRestore.Elapsed.TotalSeconds, 1) + ' 秒）。') 'ok'
    if ($movedData) { Write-Log ('旧数据保留在 ' + (Split-Path $oldData -Leaf) + '：确认新数据一切正常后再手动删除它') 'warn' }
    if ($movedEdge) { Write-Log ('旧程序保留在 ' + (Split-Path $oldEdge -Leaf) + '：确认能正常启动后再手动删除它') 'warn' }

    # ⑨ 空包根（新机只放了面板+备份包）：提示装本体
    if ($Auto) { Write-Log '（自测模式：跳过收尾提问）' }
    elseif ($script:noPackage) {
        $ans = $(if (Show-DialogAsk '需要安装 Edge 本体' "用户数据已恢复，但当前目录缺少 Edge 程序本体。`r`n`r`n是否立即下载并部署便携 Edge？（自动瘦身，不覆盖刚恢复的数据）" '现在安装' '暂不') { 'Yes' } else { 'No' })
        if ($ans -eq 'Yes') { Invoke-UpdateNow $true }
        else { Write-Log '请稍后点「更新并瘦身」装一套 Edge 本体' 'warn' }
    } else {
        $ans2 = $(if (Show-DialogAsk '应用推荐策略' '要顺便把推荐策略也应用一遍吗？（会弹一次 UAC）' '应用' '暂不') { 'Yes' } else { 'No' })
        if ($ans2 -eq 'Yes') { Apply-RecommendedPolicies }
    }
    if (-not $script:closeRequested -and -not $form.IsDisposed) { Update-StatusAsync }
}
function Invoke-Action([string]$kind) {
    if ($kind -eq 'IniOn') {
        $askI = "恢复组件更新会把 --disable-component-update 从 chrome++.ini 去掉，Edge 之后会重新自动下载组件（体积会涨回来）。继续吗？"
        if (-not (Confirm-Action '恢复组件更新' $askI)) { Write-Log '已取消'; return }
    }
    # 动作 → 脚本/参数/起始日志的唯一映射：首次执行与重试共用（原来 switch 写了两遍）
    $map = @{
        'SlimAll'  = @{ Script = $edgeTune; Args = @('-Action', 'SlimAll', '-Quiet', '-Root', $pkgRoot);  Log = '开始一键瘦身（删文件 + 关闭组件更新）…' }
        'SlimOnly' = @{ Script = $edgeTune; Args = @('-Action', 'SlimOnly', '-Quiet', '-Root', $pkgRoot); Log = '开始删除无用文件…' }
        'IniOff'   = @{ Script = $edgeTune; Args = @('-Action', 'IniOff', '-Quiet', '-Root', $pkgRoot);   Log = '关闭组件更新…' }
        'IniOn'    = @{ Script = $edgeTune; Args = @('-Action', 'IniOn', '-Quiet', '-Root', $pkgRoot);    Log = '恢复组件更新…' }
        'Clean'    = @{ Script = $cleaner;  Args = @('-Apply', '-Quiet', '-Root', $pkgRoot);              Log = '清理缓存…' }
    }
    if (-not $map.ContainsKey($kind)) { Write-Log ('未知动作：' + $kind) 'err'; return }
    $job = $map[$kind]
    Set-Busy $true '处理中…'
    try {
        Write-Log $job.Log
        $r = Invoke-Ps $job.Script $job.Args
        if ($kind -eq 'Clean') { Write-CleanerOutput $r.Output }
        else {
            foreach ($line in $r.Output) {
                $s = [string]$line
                if (-not [string]::IsNullOrWhiteSpace($s)) { Write-Log ($s -replace '^\s+', '') }
            }
        }
        if ($r.Code -eq 0) {
            Write-Log '完成' 'ok'
        } elseif ($r.Code -eq 2) {
            Write-Log '被拒绝：本包 Edge 还在运行' 'warn'
            $ans = if ($RunOnce) { 'No' } else {
                $(if (Show-DialogAsk '需要先关闭 Edge' ("本包 Edge 正在运行，缓存/程序文件被占用。`r`n`r`n现在关掉它并继续吗？（会关闭你正在用的 Edge 窗口）") '关闭并继续' '取消') { 'Yes' } else { 'No' })
            }
            if ($ans -eq 'Yes') {
                if (-not (Close-Edge)) { Write-Log 'Edge 没能完全关闭，已中止重试' 'err'; return }
                Write-Log '重试…'
                $r = Invoke-Ps $job.Script $job.Args
                if ($kind -eq 'Clean') { Write-CleanerOutput $r.Output }
                else {
                    foreach ($line in $r.Output) {
                        $s2 = [string]$line
                        if (-not [string]::IsNullOrWhiteSpace($s2)) { Write-Log ($s2 -replace '^\s+', '') }
                    }
                }
                if ($r.Code -eq 0) { Write-Log '完成（已重试成功）' 'ok' }
                elseif ($r.Code -eq 2) { Write-Log '未完成：Edge 仍未完全关闭' 'warn' }
                else { Write-Log ('未完成：脚本返回码 ' + $r.Code) 'warn' }
            }
        } else {
            Write-Log ('脚本返回码 ' + $r.Code) 'err'
        }
    } catch {
        Write-Log ('执行失败：' + $_.Exception.Message) 'err'
    } finally {
        # 关窗守卫：窗体已销毁时不再碰控件、不拉孤儿 Runspace
        if (-not $script:closeRequested -and -not $form.IsDisposed) {
            Set-Busy $false
            Update-StatusAsync
        }
    }
}

function Open-PolicyGui {
    if (-not (Test-Path $runZh)) { Write-Log ('找不到 ' + $runZh) 'err'; return }
    # 防重入：连点两次会起两个 run-zh → 两次 UAC
    if ($script:policyGuiProc) { try { if (-not $script:policyGuiProc.HasExited) { Write-Log '策略管理窗口已经打开，请先在它里面操作' 'warn'; return } } catch { } }
    try {
        $env:EP_THEME = if ($script:isDark) { 'dark' } else { 'light' }
        # 上游策略 GUI 会自己提权重启，环境变量在提权后丢失 ⇒ 再写一份跨提权可读的主题文件
        try {
            $themeDir = Get-RuntimeCacheDir
            [ordered]@{ theme = [string]$env:EP_THEME; updated = (Get-Date).ToString('s') } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $themeDir 'ui-theme.json') -Encoding UTF8
        } catch { Write-Log ('主题文件写入失败（策略窗口可能跟随系统色）：' + $_.Exception.Message) 'warn' }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $zhDir = Split-Path $runZh -Parent
        # 与 run-zh.ps1 共用 _Common.ps1 的 Get-ZhWorkDir，机制化杜绝双处路径漂移
        $outPs1 = Join-Path (Get-ZhWorkDir $zhDir) 'out.ps1'
        if (-not (Test-Path -LiteralPath $outPs1)) {
            $legacy = Join-Path (Join-Path $zhDir 'work') 'out.ps1'
            if (Test-Path -LiteralPath $legacy) { $outPs1 = $legacy }
        }
        $upSrc = Join-Path $edgeRoot 'debloater-gui.ps1'
        # 快路径：中文副本已生成且不比上游脚本旧 ⇒ 直接拉起它，省掉"下载 + 翻译 + 一次冷启动"
        $fast = $false
        try {
            if (Test-Path -LiteralPath $outPs1) {
                $fast = if (Test-Path -LiteralPath $upSrc) { ((Get-Item -LiteralPath $outPs1).LastWriteTime -ge (Get-Item -LiteralPath $upSrc).LastWriteTime) } else { $true }
            }
        } catch { }
        if ($fast) {
            # 快路径跳过 run-zh，所以它那步「复制 chrome++.ini」要在这里补上：
            # out.ps1 靠同目录的 chrome++.ini 读 policy_key，过期会导致策略读写到错误的键
            try {
                $iniSrc = Join-Path $edgeRoot 'chrome++.ini'
                if (Test-Path -LiteralPath $iniSrc) {
                    $iniDst = Join-Path (Split-Path $outPs1 -Parent) 'chrome++.ini'
                    $needCopy = $true
                    if (Test-Path -LiteralPath $iniDst) {
                        $needCopy = ((Get-Item -LiteralPath $iniSrc).LastWriteTime -gt (Get-Item -LiteralPath $iniDst).LastWriteTime)
                    }
                    if ($needCopy) { Copy-Item -LiteralPath $iniSrc -Destination $iniDst -Force }
                }
            } catch { Write-Log ('chrome++.ini 同步失败（策略键可能不对）：' + $_.Exception.Message) 'warn' }
            Write-Log '启动中文策略界面（快路径直接提权拉起，请在 UAC 中点「是」）…'
            $hostExe = [string]$env:EP_EXEPATH
            if ($hostExe -and (Test-Path -LiteralPath $hostExe)) {
                # 经 GUI 子系统宿主（winexe）提权，再以 CreateNoWindow 拉起 PowerShell：彻底消除蓝窗闪现（0.00 s）
                $script:policyGuiProc = Start-Process -FilePath $hostExe `
                    -ArgumentList @('--elevated-run', ('"' + $outPs1 + '"'), ('"' + $zhDir + '"')) `
                    -WorkingDirectory $zhDir -Verb RunAs -PassThru
            } else {
                $script:policyGuiProc = Start-Process -FilePath $psExe `
                    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $outPs1 + '"')) `
                    -WorkingDirectory $zhDir -Verb RunAs -PassThru
            }
        } else {
            Write-Log '启动中文策略界面（首次需下载/翻译上游脚本，稍慢；之后会快）…'
            $useSkip = Test-Path -LiteralPath $upSrc
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runZh + '"'), '-NoElevate', '-EdgeRoot', ('"' + $edgeRoot + '"'))
            if ($useSkip) { $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runZh + '"'), '-NoElevate', '-SkipFetch', '-EdgeRoot', ('"' + $edgeRoot + '"')) }
            $script:policyGuiProc = Start-Process -FilePath $psExe -ArgumentList $a -WorkingDirectory $zhDir -WindowStyle Hidden -PassThru
        }
        $script:policyGuiStarted = Get-Date
        Write-Log '已拉起策略界面' 'ok'
        try { Start-PolicyWatch } catch { }   # 只读监听那几条专属推荐策略
    } catch { Write-Log ('启动失败：' + $_.Exception.Message) 'err' }
}


function Start-EdgeBat([string]$fileName, [string]$label) {
    # 原样调用 Edge\ 下的上游批处理：脚本自己提权、自己跑；面板只负责拉起，不改写它们
    $bat = Join-Path $edgeRoot $fileName
    if (-not (Test-Path -LiteralPath $bat)) { Write-Log ('找不到 ' + $bat) 'err'; return }
    $isDefender = $fileName -like '*defender*'
    if ($isDefender) {
        $ask = "会调用包内脚本，把 Edge 子目录加入 Windows Defender 排除列表（需要管理员权限，会弹 UAC）。`r`n`r`n排除范围仅 Edge\ 目录，不含 Data / Cache。继续吗？"
    } else {
        $ask = "会调用包内脚本，把 Edge Portable 注册为默认浏览器（需要管理员权限，会弹 UAC），完成后会打开系统「默认应用」页面让你确认。继续吗？"
    }
    if (-not (Confirm-Action $label $ask)) { Write-Log ('已取消「' + $label + '」'); return }
    Write-Log ('启动「' + $label + '」：独立控制台窗口，脚本自带 UAC 提权')
    try {
        Start-Process -FilePath $bat -WorkingDirectory $edgeRoot | Out-Null
        Write-Log '已在独立窗口启动，请在弹出的窗口里操作' 'ok'
        if ($isDefender) {
            Write-Log '提示：该脚本排除的是 Edge 子目录（%~dp0），不含 Data / Cache。' 'warn'
        } else {
            Write-Log '提示：注册完成后它会打开「默认应用」设置页，请在那里选中 Edge Portable。' 'warn'
        }
    } catch {
        Write-Log ('启动失败（可能取消了 UAC）：' + $_.Exception.Message) 'warn'
    }
}
function Get-PackageProcs {
    # 适配层：廉价预判 + 5 秒上限 + 超时告警；枚举与判定只有 _Common 的 Get-EdgeProcs 一份实现
    if (-not (Test-Path -LiteralPath (Join-Path $edgeRoot 'msedge.exe'))) { return @() }
    $r = Get-EdgeProcs $pkgRoot 5
    if ($r.TimedOut) { Write-Log '枚举 Edge 进程超时（>5 秒），已中止继续扫描以避免界面卡顿' 'warn' }
    return @($r.Procs)
}

function Close-Edge {
    # 自测/无人值守护栏：EP_NO_CLOSE_EDGE=1 时绝不碰任何 Edge 进程
    # （我曾在用户开着浏览器的机器上跑备份自测，虽然 Get-PackageProcs 按包根前缀过滤、没关到用户的 Edge，
    #  但重型 7z 压缩仍可能拖垮桌面；加这个开关让测试彻底与用户会话解耦）
    if ($env:EP_NO_CLOSE_EDGE -eq '1') { Write-Log '（测试模式：跳过关闭 Edge）'; return $true }
    $procs = Get-PackageProcs
    if ($procs.Count -eq 0) { Write-Log '本包 Edge 没有在运行'; return $true }
    Write-Log ('关闭本包 Edge（' + $procs.Count + ' 个进程）…')
    $procs | ForEach-Object { try { [void]$_.CloseMainWindow() } catch { } }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 400
        if ((Get-PackageProcs).Count -eq 0) { break }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $left = Get-PackageProcs
    if ($left.Count) { Write-Log ('正常关闭超时，强制结束 ' + $left.Count + ' 个残留进程（未保存的网页数据可能丢失）') 'warn'; $left | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
    $n = (Get-PackageProcs).Count
    if ($n -eq 0) { Write-Log '已全部关闭' 'ok'; return $true } else { Write-Log ('还有 ' + $n + ' 个进程没关掉') 'warn'; return $false }
}

# ---------------- 更新（等价于上游 update.bat） ----------------
$script:updateAvailable = $false
Set-UpdateHighlight $false
$script:latestInfo = $null

$script:protectedOnUpdate = @('chrome++.ini', 'default-apps-multi-profile.bat')

function Get-LocalVersion {
    $exe = Join-Path $edgeRoot 'msedge.exe'
    if (Test-Path -LiteralPath $exe) { return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } else { return '未安装' }
}

# ---------------- 关键文件清单（update 预检 / 更新后复核 / 启动体检共用） ----------------
# 路径相对「Edge 目录」；{ver} 由实际版本目录解析。
# 准入规则：只收「瘦身后仍应存在」的文件——即 EdgeTune.ps1 的 $protectedNames 或固定保留集（zh-CN/en-US）。
# 绝不收：*.sig（瘦身会删）、libegl/libglesv2（上游 158 包也不带）、oneauth（本地不登账号）、
#          PdfPreview（便携包没有 shell 注册）、msedge_pwa_launcher（我们主动删）。
$script:essentialRequired = @(
    'msedge.exe'            # 微软签名真身（由 version.dll 注入便携数据目录）
    'version.dll'           # 便携补丁本体
    'chrome++.ini'          # 便携化配置
    '{ver}\msedge.dll'      # 浏览器主体
)
$script:essentialFeature = @(
    '{ver}\msedge.exe'
    '{ver}\msedge_elf.dll'
    '{ver}\ffmpeg.dll'
    '{ver}\d3dcompiler_47.dll'
    '{ver}\vk_swiftshader.dll'
    '{ver}\icudtl.dat'
    '{ver}\resources.pak'
    '{ver}\v8_context_snapshot.bin'
    '{ver}\Locales\zh-CN.pak'
    '{ver}\Locales\en-US.pak'
    '{ver}\WidevineCdm\_platform_specific\win_x64\widevinecdm.dll'
    '{ver}\EBWebView\x64\EmbeddedBrowserWebView.dll'
    'msedge_proxy.exe'      # 站点应用/PWA 快捷方式指向的是**包根**这一份（Chromium 按运行中 exe 的目录拼出来的）；
                            # 版本目录里那份是上游自带，缺了不影响使用（2026-11-21 实测：删掉后应用照常打开）
)

function Sync-RootProxy([string]$edgeDir, [switch]$Force) {
    # 站点应用/PWA 快捷方式指向**包根**的 msedge_proxy.exe（Chromium 按运行中 exe 的目录拼出来的），
    # 而上游便携包根从不提供它 ⇒ 默认仅在根上缺失时补齐；传 -Force 时总是用版本目录的新版本刷新。
    # 返回是否真的写入了根文件（调用方不用管日志）。
    $rootProxy = Join-Path $edgeDir 'msedge_proxy.exe'
    if (-not $Force -and (Test-Path -LiteralPath $rootProxy)) { return $false }
    $vd = Resolve-VersionDir $edgeDir -AllowIncomplete
    if (-not $vd) { return $false }
    $src = Join-Path $vd 'msedge_proxy.exe'
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    try {
        Copy-Item -LiteralPath $src -Destination $rootProxy -Force -ErrorAction Stop
        Write-Log '已把 msedge_proxy.exe 放到包根（站点应用/PWA 快捷方式靠它启动）' 'ok'
        return $true
    } catch {
        Write-Log ('包根 msedge_proxy.exe 补齐失败（不影响其它功能）：' + $_.Exception.Message) 'warn'
        return $false
    }
}

function Test-MsSignature([string]$path) {
    # 判断"是不是微软签过的有效文件"。不单独依赖 Get-AuthenticodeSignature：它靠模块自动加载，
    # 若本进程的 PSModulePath 里混进了 PowerShell 7 的模块目录（例如从 pwsh 7 会话里启动本面板），
    # 5.1 会解析到 PS7 版 Microsoft.PowerShell.Security 并加载失败（实测报"找到命令但无法加载该模块"），
    # 更新预检就会在**下载完 435 MB 之后**中止。这里先试 cmdlet，失败退回纯 .NET 校验。
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($s -and $s.Status -eq 'Valid' -and $s.SignerCertificate -and ($s.SignerCertificate.Subject -match 'Microsoft')) {
            return @{ Ok = $true; Why = 'Authenticode Valid（Microsoft）' }
        }
        return @{ Ok = $false; Why = ('签名状态 ' + $(if ($s) { [string]$s.Status } else { '空' })) }
    } catch {
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($path)
            if (-not $cert) { return @{ Ok = $false; Why = '文件没有签名' } }
            $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = 'NoCheck'   # 离线也能判，避免取吊销列表卡住
            $chainOk = $chain.Build($x)
            if ($chainOk -and ($x.Subject -match 'Microsoft')) { return @{ Ok = $true; Why = ('Microsoft 证书链可信 ' + $x.Thumbprint) } }
            return @{ Ok = $false; Why = ('证书链 ' + $chainOk + ' / ' + $x.Subject) }
        } catch {
            return @{ Ok = $false; Why = ($_.Exception.Message + '（Authenticode 亦不可用）') }
        }
    }
}

function Test-EssentialSet([string]$edgeDir) {
    # 只读检查，返回缺项清单：Required=必需（缺了就起不来） / Feature=功能件（缺了某功能不可用）
    $req = New-Object System.Collections.Generic.List[string]
    $feat = New-Object System.Collections.Generic.List[string]
    $verDir = Resolve-VersionDir $edgeDir -AllowIncomplete
    $verName = if ($verDir) { Split-Path $verDir -Leaf } else { '' }
    foreach ($t in $script:essentialRequired) {
        $rel = if ($verName) { $t -replace '\{ver\}', $verName } else { $t }
        if (-not (Test-Path -LiteralPath (Join-Path $edgeDir $rel))) { $req.Add($rel) }
    }
    if ($verName) {
        foreach ($t in $script:essentialFeature) {
            if ($t -eq 'msedge_proxy.exe') {
                # 快捷方式认包根那份，而上游新包只带 {ver} 那份（更新预检就是在解压出来的上游包上跑）
                # ⇒ 两处有一处即算齐，否则每次更新都会误报"新包功能件缺 1 项"。
                $okProxy = (Test-Path -LiteralPath (Join-Path $edgeDir 'msedge_proxy.exe')) -or (Test-Path -LiteralPath (Join-Path $edgeDir ($verName + '\msedge_proxy.exe')))
                if (-not $okProxy) { $feat.Add('msedge_proxy.exe（包根与版本目录都缺）') }
                continue
            }
            $rel = $t -replace '\{ver\}', $verName
            if (-not (Test-Path -LiteralPath (Join-Path $edgeDir $rel))) { $feat.Add($rel) }
        }
    }
    [pscustomobject]@{ Required = @($req); Feature = @($feat); Ver = $verName }
}

# ---------------- 检查更新（后台线程，UI 不卡） ----------------
$script:chkTimer = New-Object System.Windows.Forms.Timer
$script:chkTimer.Interval = 150
$script:chkPs = $null
$script:chkHandle = $null

$script:checkScript = @'
$urls = @(
    'https://raw.githubusercontent.com/bibicadotnet/edge-portable-chrome-next-mini/refs/heads/main/latest-versions.json',
    'https://cdn.jsdelivr.net/gh/bibicadotnet/edge-portable-chrome-next-mini@main/latest-versions.json',
    'https://ghfast.top/https://raw.githubusercontent.com/bibicadotnet/edge-portable-chrome-next-mini/refs/heads/main/latest-versions.json',
    'https://gh-proxy.com/https://raw.githubusercontent.com/bibicadotnet/edge-portable-chrome-next-mini/refs/heads/main/latest-versions.json',
    'https://raw.gitmirror.com/bibicadotnet/edge-portable-chrome-next-mini/main/latest-versions.json'
)
Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# 五个源同时发，谁先回来用谁（不再一个接一个等超时）
$hc = New-Object System.Net.Http.HttpClient
$hc.Timeout = [TimeSpan]::FromSeconds(6)
$pending = New-Object System.Collections.ArrayList
foreach ($u in $urls) {
    try { [void]$pending.Add([pscustomobject]@{ Url = $u; Task = $hc.GetStringAsync($u) }) }
    catch { }
}
$errors = @()
$ok = $null
$deadline = (Get-Date).AddSeconds(8)
while (-not $ok -and $pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $arr = [System.Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Task })
    $i = [System.Threading.Tasks.Task]::WaitAny($arr, 400)
    if ($i -lt 0) { continue }
    $entry = $pending[$i]
    $pending.RemoveAt($i)
    if ($entry.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
        try {
            $d = $entry.Task.Result | ConvertFrom-Json
            if ($d.channels.stable.version) {
                $ok = [pscustomobject]@{ ok = $true; host = ([uri]$entry.Url).Host; version = $d.channels.stable.version; url = $d.channels.stable.download_url; chromeNext = $d.channels.stable.chromeNext }
            } else { $errors += ([uri]$entry.Url).Host + ' 内容无效' }
        } catch { $errors += ([uri]$entry.Url).Host + ' 解析失败' }
    } else {
        $errors += ([uri]$entry.Url).Host + ' ' + $entry.Task.Exception.GetBaseException().Message
    }
}
try { $hc.Dispose() } catch { }
if ($ok) { return ($ok | ConvertTo-Json -Compress) }
return ([pscustomobject]@{ ok = $false; errors = @($errors) } | ConvertTo-Json -Compress)
'@

function Complete-Check([string]$jsonText) {
    $silent = $script:chkSilent
    $script:chkSilent = $false
    if (-not $silent) { Set-Busy $false }
    else { if (-not $script:isBusy) { $lblHint.Text = '就绪'; $lblHint.ForeColor = $clrOnDarkMuted } }
    Apply-CheckResult $jsonText
}

function Invoke-Check([bool]$silent = $false) {
    if ($script:chkHandle) { Write-Log '正在检查中，请稍候…' 'warn'; return }
    $script:chkSilent = $silent
    if ($silent) {
        # 自动检查：只更新右上角提示，不禁用任何按钮（否则清理缓存等按钮会闪一下禁用态）
        $lblHint.Text = '检查更新…'
        $lblHint.ForeColor = $clrHeaderAccent
    } else {
        Set-Busy $true '检查更新…'
    }
    Write-Log '正在查询线上版本（后台进行，界面可以继续操作）…'
    $script:chkPs = [powershell]::Create()
    [void]$script:chkPs.AddScript($script:checkScript)
    $script:chkHandle = $script:chkPs.BeginInvoke()
    $script:chkTimer.Start()
}

$script:chkTimer.Add_Tick({
    if (-not $script:chkHandle -or -not $script:chkHandle.IsCompleted) { return }
    if ($script:closeRequested -or $form.IsDisposed) { $script:chkTimer.Stop(); return }
    $script:chkTimer.Stop()
    $text = ''
    try {
        $out = $script:chkPs.EndInvoke($script:chkHandle)
        $text = ($out | Where-Object { $_ -is [string] } | Select-Object -Last 1)
    } catch {
        $text = ([pscustomobject]@{ ok = $false; errors = @($_.Exception.Message) } | ConvertTo-Json -Compress)
    } finally {
        if ($script:chkPs) { $script:chkPs.Dispose() }
        $script:chkPs = $null
        $script:chkHandle = $null
    }
    Complete-Check $text
})

function Apply-CheckResult([string]$jsonText, [bool]$logSource = $true) {
    # 异步回调与同步自测共用的结果处理：版本比对 + 颜色 + 高亮
    try {
        $res = $jsonText | ConvertFrom-Json
        if ($res.ok) {
            $script:latestInfo = [pscustomobject]@{ version = $res.version; download_url = $res.url; chromeNext = $res.chromeNext }
            $valNewVer.Text = '最新版本：' + $res.version
            if ($logSource) { Write-Log ('版本源：' + $res.host + ' → ' + $res.version) }
            # 本地版本可能是 '未安装'（空包根）——TryParse 失败视为待安装，直接提示有新版
            $localVer = $null
            $localText = Get-LocalVersion
            $localOk = [version]::TryParse($localText, [ref]$localVer)
            if ((-not $localOk) -or ([version]$res.version -gt $localVer)) {
                $script:updateAvailable = $true
                Set-UpdateHighlight $true
                $valNewVer.ForeColor = $clrGo
                Write-Log ($(if ($localOk) { '发现新版本：' + $localText + ' → ' + $res.version } else { '本包未安装 Edge，线上版本：' + $res.version + '（点「更新并瘦身」就地安装）' })) 'warn'
            } else {
                $script:updateAvailable = $false
                Set-UpdateHighlight $false
                $valNewVer.ForeColor = $clrMuted
                Write-Log '已经是最新版本' 'ok'
            }
        } else {
            $script:updateAvailable = $false
            Set-UpdateHighlight $false
            $valNewVer.Text = '最新版本：查询失败'
            $valNewVer.ForeColor = $clrBad
            Write-Log ('所有版本源都失败：' + ($res.errors -join ' | ')) 'err'
            Write-Log 'GitHub / jsDelivr 在国内直连常被拦，先开代理再点「检查更新」通常就好。' 'warn'
        }
    } catch {
        Write-Log ('检查结果解析失败：' + $_.Exception.Message) 'err'
    }
}

function Invoke-CheckSync {
    # 自测模式用：同步采集，展示与异步检查共用 Apply-CheckResult
    try {
        $raw = & ([scriptblock]::Create($script:checkScript)) | Select-Object -Last 1
        $res = $raw | ConvertFrom-Json
        if (-not $res.ok) { throw ('所有版本源都失败：' + ($res.errors -join ' | ')) }
        Apply-CheckResult $raw
    } catch {
        $script:updateAvailable = $false
        Set-UpdateHighlight $false
        $valNewVer.Text = '最新版本：查询失败'
        Write-Log ('检查更新失败：' + $_.Exception.Message) 'err'
    } finally {
        Set-Busy $false
    }
}

function Invoke-UpdateNow([bool]$withSlim = $false) {
    # 测试钩子：EP_UPDATE_URL 指向本地 zip 时可演练下载/解压（配合 EP_UPDATEDRY=1 不落盘）
    if ($env:EP_UPDATE_URL) {
        $script:latestInfo = [pscustomobject]@{ version = $env:EP_UPDATE_VERSION; download_url = $env:EP_UPDATE_URL }
    }
    $dry = ($env:EP_UPDATEDRY -eq '1')
    if (-not $script:latestInfo) { Write-Log '请先点「检查更新」' 'warn'; return }
    $target = $script:latestInfo
    $local = Get-LocalVersion
    if ($target.version -eq $local) { Write-Log '已经是最新版本，无需更新' 'ok'; return }
    if ($script:noPackage -and -not $dry) {
        $safe = Test-SafeDeployDir $pkgRoot
        if (-not $safe.Ok) {
            $sample = (($safe.Others | Select-Object -First 5) -join '、')
            Write-Log ('当前目录不是空目录，已阻止部署（发现无关项：' + $sample + '）') 'err'
            if (-not $RunOnce) {
                [void](Show-DialogAsk '无法在非空目录部署' ("当前目录包含非备份/非面板文件（" + $sample + "），不允许直接部署便携 Edge。`r`n`r`n请将面板移至空目录，或右键左上角路径切换至已有便携 Edge 目录。") '知道了' '关闭')
            }
            return
        }
    }
    if (-not $RunOnce) {
        $ans = $(if (Show-DialogAsk '确认更新 Edge' (("将把 Edge 本体从 " + $local + " 更新到 " + $target.version + "。" + "`r`n`r`n" + "过程：关闭本包 Edge → 下载 → 解压 → 覆盖程序文件（保留 chrome++.ini 等 2 项）→ 删除旧版本目录。" + "`r`n`r`n" + $(if ($withSlim) { "更新完成后会自动执行「一键瘦身 + 关闭组件更新」。" } else { "本次只更新程序文件，瘦身需要你另行点击。" }) + "`r`n`r`n继续吗？")) '开始更新' '取消') { 'Yes' } else { 'No' })
        if ($ans -ne 'Yes') { Write-Log '已取消更新'; return }
    }
    Set-Busy $true '更新中…'
    $temp = Join-Path $env:TEMP ('edge-update-' + (Get-Date).ToString('HHmmss'))
    $script:dlLast = $null   # F7：本次更新开始时清空上次的下载现场（失败时才有意义）
    try {
        if (-not $dry) {
            if (-not (Close-Edge)) { throw 'Edge 没能完全关闭，已中止（避免覆盖正在运行的文件）' }
        }
        if (-not (Test-Path $temp)) { New-Item -ItemType Directory -Path $temp -Force | Out-Null }
        $zip = Join-Path $temp 'update.zip'
        $part = $zip + '.part'
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        # 下载源：按实测速度排序（GitHub 直连在国内会直接卡住，放最后兜底）
        $dl = $target.download_url
        if ($dl -match '^https?://') {
            $mirrors = @(
                ('https://gh-proxy.org/' + $dl),
                ('https://ghfast.top/' + $dl),
                ('https://gh-proxy.com/' + $dl),
                ('https://ghproxy.net/' + $dl),
                ('https://gh.llkk.cc/' + $dl),
                $dl
            )
        } else { $mirrors = @($dl) }   # 本地演练文件不套加速前缀
        foreach ($u in $mirrors) { Write-Log ('候选下载源：' + $u) }

        # 下载丢到后台 Runspace：UI 线程只轮询进度文件，窗口任何时候都能关
        $progFile = Join-Path $temp 'progress.json'
        Remove-Item -LiteralPath $progFile -Force -ErrorAction SilentlyContinue
        $script:dlPs = [powershell]::Create()
        [void]$script:dlPs.AddScript($script:downloadScript).AddArgument([string[]]$mirrors).AddArgument($part).AddArgument($zip).AddArgument($progFile)
        $dlHandle = $script:dlPs.BeginInvoke()
        $lblHint.Text = '下载中…'
        $lastPaint = 0
        while (-not $dlHandle.IsCompleted) {
            # BeginStop（异步）：同步 Stop() 会阻塞在 stream.Read 的 IO 上（最多 15 秒）
            if ($script:closeRequested) { try { [void]$script:dlPs.BeginStop($null, $null) } catch { }; throw '已取消下载' }
            Start-Sleep -Milliseconds 150
            [System.Windows.Forms.Application]::DoEvents()
            $now = [Environment]::TickCount
            if (($now - $lastPaint) -ge 400) {
                $lastPaint = $now
                try {
                    $po = [System.IO.File]::ReadAllText($progFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $script:dlLast = $po   # F7：取消/失败时把源与已收字节带进日志
                    if ($po.phase -eq 'speedtest') {
                        $lblHint.Text = if ($po.msg -like '测速完成*') { '测速完成，准备下载' } else { '测速中…（给各源各拉 1MB 比速度）' }
                    } else {
                        $recv = [double]$po.recv / 1MB
                        $total = [double]$po.total / 1MB
                        if ($total -gt 0) {
                            $pct = [int]($recv * 100 / $total)
                            $spd = if ($po.spd) { [double]$po.spd } else { [double]0 }
                            $lblHint.Text = ('下载中 {0}%  {1} MB/s' -f $pct, $spd)
                        } else {
                            $lblHint.Text = ('下载中 {0:N1} MB' -f $recv)
                        }
                    }
                } catch { }
            }
        }
        if ($script:closeRequested) { throw '已取消下载' }   # 关窗时后台被 BeginStop，别报成"所有源失败"
        try {
            $dlOut = $script:dlPs.EndInvoke($dlHandle)
            $dlText = (@($dlOut) | Where-Object { $_ -is [string] } | Select-Object -Last 1)
        } catch {
            $dlText = (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
        } finally {
            if ($script:dlPs) { try { $script:dlPs.Dispose() } catch { } }
            $script:dlPs = $null   # 统一置空：防二次释放，也让 FormClosing 的判空可靠
        }
        $dlRes = $null
        try { $dlRes = $dlText | ConvertFrom-Json } catch { }
        if (-not $dlRes -or -not $dlRes.ok) {
            $why = if ($dlRes) { $dlRes.error } else { '未知错误' }
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            throw ('所有下载源都失败（' + $why + '）；GitHub 直连在国内常被拦，先开代理再试')
        }
        $sizeMb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
        if ($dlRes.speed) { Write-Log ('各源实测速度：' + $dlRes.speed) }
        $speedAllZero = $false
        if ($dlRes.speed) {
            $nums = @([regex]::Matches([string]$dlRes.speed, '(\d+(?:\.\d+)?)\s*MB/s') | ForEach-Object { [double]$_.Groups[1].Value })
            if ($nums.Count -gt 0 -and (@($nums) | Measure-Object -Maximum).Maximum -le 0) { $speedAllZero = $true }
        }
        $zeroNote = if ($speedAllZero) { '（各源测速全 0，按默认顺序取的源）' } else { '' }
        Write-Log ('下载完成：' + $sizeMb + ' MB（源 ' + $dlRes.src + '）' + $zeroNote + '；临时目录 ' + $temp + ' 结束时自动删除') 'ok'

        Write-Log '解压…'
        $ex = Join-Path $temp 'ex'
        if (-not (Test-Path -LiteralPath $ex)) { New-Item -ItemType Directory -Path $ex -Force | Out-Null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        # 435 MB 压缩包解出 976 MB：同步跑会占住 UI 线程十几秒，Windows 直接标「未响应」（实测 11.1 秒）。
        # 跟下载一样丢到独立 runspace，UI 只 DoEvents，解压期间窗口仍可拖动/关闭。
        $exRs = [runspacefactory]::CreateRunspace(); $exRs.Open()
        $exPs = [powershell]::Create(); $exPs.Runspace = $exRs
        [void]$exPs.AddScript('[void][System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem"); [System.IO.Compression.ZipFile]::ExtractToDirectory($args[0], $args[1])').AddArgument($zip).AddArgument($ex)
        $exHandle = $exPs.BeginInvoke()
        $exT0 = Get-Date
        try {
            while (-not $exHandle.IsCompleted) {
                if ($script:closeRequested) { try { [void]$exPs.BeginStop($null, $null) } catch { }; throw '已取消解压' }
                Start-Sleep -Milliseconds 120
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
                $secNow = [int]((Get-Date) - $exT0).TotalSeconds
                try { $lblHint.Text = ('解压中… 已 ' + $secNow + ' 秒（界面仍可用）'); $form.Refresh() } catch { }
            }
            [void]$exPs.EndInvoke($exHandle)      # 内层抛的异常会在这里冒出来
        } catch {
            if ($script:closeRequested) { throw '已取消解压' }
            throw ('解压失败：' + $_.Exception.Message)
        } finally {
            try { $exPs.Dispose() } catch { }
            try { $exRs.Dispose() } catch { }
        }
        Remove-Item -LiteralPath $zip -Force
        $extracted = Get-ChildItem $ex -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Edge' } | Select-Object -First 1
        if (-not $extracted) { throw '压缩包里没找到 Edge 目录' }

        # ---- 预检（在删旧文件之前）：必需文件齐不齐 + 浏览器本体签名可信不可信 ----
        $pre = Test-EssentialSet $extracted.FullName
        if ($pre.Required.Count -gt 0) {
            throw ('新包缺少必需文件（' + ($pre.Required -join '、') + '），已中止更新；旧版未动')
        }
        $sigTarget = if ($pre.Ver) { Join-Path (Join-Path $extracted.FullName $pre.Ver) 'msedge.exe' } else { Join-Path $extracted.FullName 'msedge.exe' }
        if (-not (Test-Path -LiteralPath $sigTarget)) { $sigTarget = Join-Path $extracted.FullName 'msedge.exe' }
        $sigCheck = Test-MsSignature $sigTarget
        if (-not $sigCheck.Ok) {
            throw ('新包的 msedge.exe 签名不可信（' + $sigCheck.Why + '），已中止更新；旧版未动')
        }
        Write-Log ('预检通过：必需 ' + $script:essentialRequired.Count + ' 项齐全，msedge.exe 签名 ' + $sigCheck.Why + '（' + (Split-Path $sigTarget -Leaf) + '）') 'ok'
        # F9：上游包结构漂移（只在这里跑；本地瘦身目录不参与比对）
        $newSnap = $null
        try { $newSnap = Test-StructureDrift $extracted.FullName $pkgRoot } catch { Write-Log ('结构比对失败（不阻断）：' + $_.Exception.Message) 'warn' }
        # F8：上游包始终带 msedge_renderer.dll，而本地是用户手动删掉的 —— 每次更新提示一次（不在启动体检里反复吵）
        try {
            $rNew = if ($pre.Ver) { Join-Path (Join-Path $extracted.FullName $pre.Ver) 'msedge_renderer.dll' } else { Join-Path $extracted.FullName 'msedge_renderer.dll' }
            $rLoc = Join-Path (Resolve-ProgramDir $pkgRoot) 'msedge_renderer.dll'
            if ((Test-Path -LiteralPath $rNew) -and -not (Test-Path -LiteralPath $rLoc)) {
                $rMb = [math]::Round((Get-Item -LiteralPath $rNew).Length / 1MB, 1)
                Write-Log ('新包带 msedge_renderer.dll（' + $rMb + ' MB）——你本地是删掉的；更新完成后记得点一次「一键瘦身」再删掉它') 'warn'
            }
        } catch { }
        if ($pre.Feature.Count -gt 0) { Write-Log ('新包功能件缺 ' + $pre.Feature.Count + ' 项（不阻断）：' + ($pre.Feature -join '、')) 'warn' }
        if ($dry) {
            $dfiles = @(Get-ChildItem -LiteralPath $extracted.FullName -Recurse -File -ErrorAction SilentlyContinue)
            $dmb = [math]::Round((($dfiles | Measure-Object Length -Sum).Sum / 1MB), 2)
            Write-Log ('[演练] 压缩包内 Edge 目录：' + $dfiles.Count + ' 个文件 / ' + $dmb + ' MB；未删除、未覆盖任何东西') 'ok'
            if ($withSlim) {
                Write-Log '[演练] 顺带验证「更新后自动瘦身」段：现在跑一键瘦身 + 关组件更新（幂等）' 'warn'
                $rs = Invoke-Ps $edgeTune @('-Action', 'SlimAll', '-Quiet', '-Root', $pkgRoot)
                foreach ($line in $rs.Output) {
                    $s4 = [string]$line
                    if (-not [string]::IsNullOrWhiteSpace($s4)) { Write-Log ($s4 -replace '^\s+', '') }
                }
                if ($rs.Code -eq 0) { Write-Log '[演练] 自动瘦身段执行成功' 'ok' } else { Write-Log ('[演练] 自动瘦身返回码 ' + $rs.Code) 'warn' }
            }
            else { Write-Log '[演练] 本次不执行瘦身（「下载并更新」模式）' 'warn' }
            return
        }

        # 空间预检：暂存期间旧版与新文件会同时存在（≈旧版体积 + 新版体积）；复用 DriveInfo 避开 Get-PSDrive 卡顿
        $freeMB = Get-DriveFreeMB $pkgRoot
        if ($null -ne $freeMB -and $freeMB -lt 1536) {
            throw ('可用空间不足：所在盘剩 ' + [math]::Round($freeMB / 1024, 1) + ' GB，更新需要约 1.5 GB 用于暂存旧版')
        }

        # ── 更新前自动备份（D8）：此时 Edge 已关闭、安装包已预检通过、还没动旧版 ──
try {
    $script:updateBackupOk = $true
    $fpU = Get-DataFingerprint (Join-Path $pkgRoot 'Data')
    $lastU = Get-LastBackupStamp
    $needBackup = $true
    if ($fpU -and $lastU -and $lastU.fp -eq $fpU) {
        Write-Log '更新前备份：数据与上次备份一致，跳过（指纹相同）'
        $needBackup = $false
    } elseif ($lastU -and $lastU.time) {
        try {
            $ageH = ((Get-Date) - [datetime]::Parse($lastU.time)).TotalHours
            if ($ageH -lt 24) { Write-Log ('更新前备份：' + [math]::Round($ageH, 1) + ' 小时前刚备份过，跳过'); $needBackup = $false }
        } catch { }
    }
    if ($needBackup) {
        Write-Log '更新前自动备份：开始（沿用上次的方式与目录，不弹窗）…'
        $okB = Invoke-CleanAndBackup -Silent
        if (-not $okB) {
            $script:updateBackupOk = $false
            Write-Log '更新前自动备份失败' 'err'
        }
    }
} catch {
    $script:updateBackupOk = $false
    Write-Log ('更新前自动备份异常：' + $_.Exception.Message) 'err'
}
if (-not $script:updateBackupOk -and -not $dry -and -not $RunOnce) {
    $ansB = $(if (Show-DialogAsk '更新前备份失败' "更新前自动备份失败。`r`n`r`n是否跳过备份并继续更新 Edge？（更新不会改动用户数据，但本次将无新备份可回滚）" '跳过备份继续' '中止' -Danger -FocusCancel) { 'Yes' } else { 'No' })
    if ($ansB -ne 'Yes') { Write-Log '已取消更新（因为更新前备份失败）'; return }
    Write-Log '用户选择跳过备份继续更新' 'warn'
}

# 旧版先挪进 Edge\_old\（同盘改名，近 0 耗时）：新文件拷完 + 校验通过才删，
        # 拷到 358 MB 的 msedge.dll 中途被杀软锁 / 断电 / 空间不足时可以把 _old 挪回来，绝不变砖。
        $oldDir = Join-Path $edgeRoot '_old'
        if (Test-Path -LiteralPath $oldDir) { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
        $staged = @()
        Write-Log '把旧版挪进 Edge\_old\（可回滚）…'
        foreach ($f in @('msedge.exe', 'msedge_proxy.exe', 'version.dll')) {
            $fp = Join-Path $edgeRoot $f
            if (Test-Path -LiteralPath $fp) {
                Move-Item -LiteralPath $fp -Destination (Join-Path $oldDir $f) -Force
                $staged += $f
            }
        }
        if ($local -ne '未安装') {
            $vd = Join-Path $edgeRoot $local
            if (Test-Path -LiteralPath $vd) { Move-Item -LiteralPath $vd -Destination (Join-Path $oldDir $local) -Force; $staged += $local }
        }
        Write-Log ('已暂存 ' + $staged.Count + ' 项；开始拷贝新文件…')

        try {
            Write-Log '覆盖新文件…'
            $base = $extracted.FullName
            # 逐条推进 + 定期 DoEvents：976 MB / 500 个文件，同步拷贝也会让窗口短暂"未响应"
            $allItems = @(Get-ChildItem -LiteralPath $base -Recurse -Force)
            $nItem = 0
            $lastPump = Get-Date
            foreach ($item in $allItems) {
                if ($script:closeRequested) { throw '用户关闭窗口，已取消覆盖' }
                $nItem++
                $rel = $item.FullName.Substring($base.Length + 1)
                $dest = Join-Path $edgeRoot $rel
                if ($item.PSIsContainer) {
                    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                } else {
                    if (-not (($script:protectedOnUpdate -contains $item.Name) -and (Test-Path -LiteralPath $dest))) {
                        $dir = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                        Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
                    }
                }
                if ((($nItem % 20) -eq 0) -or (((Get-Date) - $lastPump).TotalMilliseconds -ge 250)) {
                    $lastPump = Get-Date
                    try {
                        $lblHint.Text = ('覆盖文件 {0}/{1} …' -f $nItem, $allItems.Count)
                        [System.Windows.Forms.Application]::DoEvents()
                    } catch { }
                }
            }
            # 包根 proxy：PWA/站点应用快捷方式指向它，而上游包根从不提供。必须在下面的复核之前补，
            # 否则复核会先报"功能件缺失"、紧接着又被补回来，日志自相矛盾。
            try {
                if (-not (Sync-RootProxy $edgeRoot)) {
                    $stagedProxy = Join-Path $oldDir 'msedge_proxy.exe'
                    if ((Test-Path -LiteralPath $stagedProxy) -and -not (Test-Path -LiteralPath (Join-Path $edgeRoot 'msedge_proxy.exe'))) {
                        Move-Item -LiteralPath $stagedProxy -Destination (Join-Path $edgeRoot 'msedge_proxy.exe') -Force
                        Write-Log '已把包根的 msedge_proxy.exe 补回（站点应用/PWA 快捷方式靠它启动）' 'ok'
                    }
                }
            } catch { Write-Log ('包根 proxy 补回失败（不影响更新）：' + $_.Exception.Message) 'warn' }
            # 拷完先复核必需文件，缺了同样回滚（不等到用户下次启动才发现）
            $mid = Test-EssentialSet $edgeRoot
            if ($mid.Required.Count -gt 0) { throw ('拷贝后仍缺必需文件：' + ($mid.Required -join '、')) }
        } catch {
            $why = $_.Exception.Message
            Write-Log ('拷贝失败，正在回滚：' + $why) 'warn'
            foreach ($f in @('msedge.exe', 'msedge_proxy.exe', 'version.dll')) { Remove-Item -LiteralPath (Join-Path $edgeRoot $f) -Force -ErrorAction SilentlyContinue }
            $nv = Resolve-VersionDir $edgeRoot -AllowIncomplete
            if ($nv) { Remove-Item -LiteralPath $nv -Recurse -Force -ErrorAction SilentlyContinue }
            foreach ($f in $staged) { Move-Item -LiteralPath (Join-Path $oldDir $f) -Destination (Join-Path $edgeRoot $f) -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $oldDir) { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue }
            throw ('已回滚到旧版：' + $why)
        }
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log '新文件已就位，旧版暂存已清除' 'ok'
        $new = Get-LocalVersion
        if ($new -eq $target.version) {
            Write-Log ('更新成功：' + $new) 'ok'
            if ($withSlim) {
                Write-Log '更新完成，接着执行「一键瘦身 + 关闭组件更新」…'
                $rs = Invoke-Ps $edgeTune @('-Action', 'SlimAll', '-Quiet', '-Root', $pkgRoot)
                foreach ($line in $rs.Output) {
                    $s3 = [string]$line
                    if (-not [string]::IsNullOrWhiteSpace($s3)) { Write-Log ($s3 -replace '^\s+', '') }
                }
                if ($rs.Code -eq 0) { Write-Log '自动瘦身与组件更新关闭已完成' 'ok' }
                else { Write-Log ('自动瘦身返回码 ' + $rs.Code + '：请稍后手动点「一键瘦身」') 'warn' }
            }
            else { Write-Log '已只完成更新（未瘦身）。需要省空间请点「一键瘦身」，或用「更新并瘦身」。' 'warn' }
        }
        else {
            Write-Log ('更新可能不完整：期望 ' + $target.version + '，实际 ' + $new) 'warn'
            Write-Log '新包会把裁掉的组件带回来，请手动点一次「一键瘦身」' 'warn'
        }
        # ---- 更新后复核（不论版本号是否对上都要跑）----
        # 必需件缺了只红字报告、不回滚：文件已就位，回滚反而丢掉刚下的新包；功能件只黄字。
        $post = Test-EssentialSet $edgeRoot
        if ($post.Required.Count -gt 0) {
            Write-Log ('关键文件缺失（必需）：' + ($post.Required -join '、') + ' —— 程序可能起不来') 'err'
        } else {
            Write-Log ('关键文件复核：必需 ' + $script:essentialRequired.Count + ' 项齐全') 'ok'
        }
        # 策略存在性判定（A 方案）：只认策略键是否存在（Test-Path），存在一律不动，完全不存在才询问是否应用
        if (Test-Path $script:policyKey) {
            $curPolCnt = 0
            try { $curPolCnt = (Get-Item $script:policyKey).ValueCount } catch { }
            Write-Log ('本地已有策略键（主键 ' + $curPolCnt + ' 条），保持不动')
        } elseif ($RunOnce) {
            Write-Log '本地暂无策略键（自测模式跳过弹窗询问）'
        } else {
            $ansPol = $(if (Show-DialogAsk '应用推荐策略' '更新完成。本地还没有推荐策略，现在应用吗？（会弹一次 UAC）' '应用' '暂不') { 'Yes' } else { 'No' })
            if ($ansPol -eq 'Yes') { Apply-RecommendedPolicies }
            else { Write-Log '稍后可点「应用推荐策略」手动应用' 'warn' }
        }
        # F9：覆盖成功后（含复核）才把新结构写回基线；中途回滚则保持旧基线
        if ($newSnap) { try { Save-PkgSnapshot $newSnap (Join-Path (Get-RuntimeCacheDir) 'last_pkg_snapshot.json') } catch { } }
        # 空包根就地安装成功后必须解除 R10 降级态，否则状态卡永远显示 — 、按钮永久锁死
        $script:noPackage = -not (Test-Path -LiteralPath (Join-Path $edgeRoot 'msedge.exe'))
        if ($post.Feature.Count -gt 0) {
            Write-Log ('功能件缺失（不影响启动，对应功能不可用）：' + ($post.Feature -join '、')) 'warn'
        }
        # ---- 上游换便携补丁了吗？只提醒，不阻断 ----
        $upNext = if ($target.chromeNext) { ([string]$target.chromeNext).TrimStart('v', 'V') } else { '' }
        $vdll = Join-Path $edgeRoot 'version.dll'
        if ($upNext -and (Test-Path -LiteralPath $vdll)) {
            $locNext = ([string](Get-Item -LiteralPath $vdll).VersionInfo.FileVersion).Trim()
            if ($locNext -and $locNext -ne $upNext) {
                Write-Log ('上游便携补丁版本变了：本地 ' + $locNext + ' → 上游 ' + $upNext + '；首次启动后留意数据目录是否仍在 Data\') 'warn'
            }
        }
        $script:updateAvailable = $false
        Set-UpdateHighlight $false
    } catch {
$ctx = ''
        if ($script:dlLast) {
            $srcTxt = if ($script:dlLast.src) { [string]$script:dlLast.src } else { '未确定' }
            $recvMb = [math]::Round(([long]$script:dlLast.recv) / 1MB, 1)
            $totMb = if ([long]$script:dlLast.total -gt 0) { [string][math]::Round(([long]$script:dlLast.total) / 1MB, 1) + ' MB' } else { '未知' }
            $ctx = '（源 ' + $srcTxt + '；已收 ' + $recvMb + ' MB / 总量 ' + $totMb + '；阶段 ' + $script:dlLast.phase + '）'
        }
        Write-Log ('更新失败：' + $_.Exception.Message + $ctx) 'err'
    } finally {
        # 关窗路径：进程即将退出，同步 Dispose() 同样会阻塞在 Stopping 的 Runspace 上——
        # 只 BeginStop + 置空，不 Dispose；非关窗路径才正常释放
        if ($script:dlPs) {
            if ($script:closeRequested) { try { [void]$script:dlPs.BeginStop($null, $null) } catch { } }
            else { try { $script:dlPs.Dispose() } catch { } }
            $script:dlPs = $null
        }
        for ($k = 0; $k -lt 20; $k++) {
            if (-not (Test-Path -LiteralPath $temp)) { break }
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $temp) { Start-Sleep -Milliseconds 150 }
            if (-not $script:closeRequested) { [System.Windows.Forms.Application]::DoEvents() }
        }
        # 关窗重入守卫：窗体已销毁时操作控件/拉起后台任务会崩或留下孤儿 Runspace
        if (-not $script:closeRequested -and -not $form.IsDisposed) {
            Set-Busy $false
            Update-StatusAsync
        }
    }
}


# ---------------- 面板自更新（预设：复用国内镜像站 + SHA256 校验 + .old 回退） ----------------
function Set-PanelUpdateHighlight([bool]$hasNew) {
    if (-not $script:btnPanelUpdate) { return }
    if ($hasNew) {
        $script:btnPanelUpdate.BackColor = $clrGo
        $script:btnPanelUpdate.ForeColor = [System.Drawing.Color]::White
        $script:btnPanelUpdate.FlatAppearance.BorderColor = $clrGo
        $script:btnPanelUpdate.Text = '有新版本'   # 与「更新面板」同 4 字宽，1.25× 下绝不截断
    } else {
        $script:btnPanelUpdate.BackColor = $clrHeaderBtnBg
        $script:btnPanelUpdate.ForeColor = $clrOnDark
        $script:btnPanelUpdate.FlatAppearance.BorderColor = $clrHeaderBtnEdge
        $script:btnPanelUpdate.Text = '更新面板'
    }
}

try {
    foreach ($staleNm in @('edgepanel-apply-update.cmd', 'edgepanel-apply-update.ps1')) {
        $staleP = Join-Path $env:TEMP $staleNm
        if (Test-Path -LiteralPath $staleP) { Remove-Item -LiteralPath $staleP -Force -ErrorAction SilentlyContinue }
    }
} catch { }

function Get-PanelLatestTagRedirect {
    # 用 releases/latest 的 302 重定向拿最新 tag：**不消耗 GitHub API 配额**（匿名 API 只有 60 次/小时，
    # 频繁检查会被 403 限流）。返回原始 tag（如 'v1.3.4'）；失败返回 ''。
    if ([string]::IsNullOrWhiteSpace($script:panelUpdateRepo)) { return '' }
    $repoSlug = $script:panelUpdateRepo.Trim('/')
    $page = 'https://github.com/' + $repoSlug + '/releases/latest'
    foreach ($u in @($page, ('https://gh-proxy.org/' + $page), ('https://ghfast.top/' + $page))) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.UserAgent = 'EdgePanel/' + $script:panelVersion
            $req.AllowAutoRedirect = $false
            $req.Timeout = 8000
            $req.ReadWriteTimeout = 8000
            $resp = $null
            try { $resp = $req.GetResponse() } catch { $resp = $_.Exception.Response }
            if (-not $resp) { continue }
            $loc = [string]$resp.Headers['Location']
            try { $resp.Close() } catch { }
            if (-not $loc) { continue }
            $m = [regex]::Match($loc, '/tag/(v?[0-9][0-9A-Za-z\.\-_]*)$')
            if ($m.Success) { return [string]$m.Groups[1].Value }   # 保留原始 tag（含 v），拼下载地址要用原名
        } catch { }
    }
    return ''
}

function Test-PwaRegistrationGap {
    # 便携模式固有限制：装过站点应用（有 _crx__ 缓存目录）但 Edge 内部没有登记（Preferences.web_apps 为空）
    # 命中时只在启动日志写一行提示，不弹窗、不阻断；每次启动只判一次
    try {
        if ($script:pwaGapChecked) { return }
        $script:pwaGapChecked = $true
        $dataDefault = Join-Path $pkgRoot 'Data\Default'
        if (-not (Test-Path -LiteralPath $dataDefault)) { return }
        $wa = Join-Path $dataDefault 'Web Applications'
        if (-not (Test-Path -LiteralPath $wa)) { return }
        $hasCache = @(Get-ChildItem -LiteralPath $wa -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like '_crx__*' }).Count -gt 0
        if (-not $hasCache) { return }
        $prefFile = Join-Path $dataDefault 'Preferences'
        if (-not (Test-Path -LiteralPath $prefFile)) { return }
        $pref = $null
        try { $pref = [System.IO.File]::ReadAllText($prefFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return }
        $apps = 0
        try { if ($pref.web_apps -and $pref.web_apps.web_apps) { $apps = @($pref.web_apps.web_apps.PSObject.Properties).Count } } catch { }
        if ($apps -gt 0) { return }
        Write-Log '装过站点应用但 Edge 内部未登记（便携模式固有限制）：三点菜单「应用 → 管理应用」会是灰的。要看列表可在收藏夹加 edge://apps（页面为空属正常）' 'warn'
    } catch { }
}

function Start-PanelUpdateProbe {
    # 启动后静默探测面板自身有没有新版：30 分钟本地缓存免重复联网；后台 runspace 用可中断异步请求，
    # 单源 2.5s、仅 2 源（去 ghfast.top）、总预算 <=8s；关窗时通过 $panelProbeCancel 立即 Abort。
    if ($script:panelProbeDone) { return }
    if ($script:closeRequested -or $form.IsDisposed) { return }
    if ([string]::IsNullOrWhiteSpace($script:panelUpdateRepo)) { return }
    if ($env:EP_NO_PANEL_PROBE -eq '1' -or $env:EP_NO_PROMPT -eq '1') { return }
    $script:panelProbeDone = $true
    # 30 分钟内已探测过：直接复用缓存，0 网络请求（手动点「更新面板」始终实时直查）
    $probeCachePath = Join-Path (Get-RuntimeCacheDir) 'panel-probe-cache.json'
    try {
        if (Test-Path -LiteralPath $probeCachePath) {
            $pc = Get-Content -LiteralPath $probeCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pc -and $pc.time -and $pc.tag -and (((Get-Date) - [datetime]::Parse($pc.time)).TotalMinutes -lt 30)) {
                $curV = $null; $newV = $null
                $ct = ([string]$pc.tag).Trim().TrimStart('v', 'V')
                if ([version]::TryParse($script:panelVersion, [ref]$curV) -and [version]::TryParse($ct, [ref]$newV) -and ($newV -gt $curV)) {
                    Set-PanelUpdateHighlight $true
                    Write-Log ('静默探测（缓存）：面板有新版本 v' + $script:panelVersion + ' → v' + $ct) 'warn'
                }
                return
            }
        }
    } catch { }
    $repoSlug = $script:panelUpdateRepo.Trim('/')
    $page = 'https://github.com/' + $repoSlug + '/releases/latest'
    $api = 'https://api.github.com/repos/' + $repoSlug + '/releases/latest'
    $cancelBox = [hashtable]::Synchronized(@{ Stop = $false })
    $script:panelProbeCancel = $cancelBox
    $probe = @'
param([string]$Page, [string]$Api, $Cancel, [string]$CachePath)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$swAll = [Diagnostics.Stopwatch]::StartNew()
function Save-ProbeCache([string]$tv) {
    try {
        $tmp = $CachePath + '.tmp.' + $PID
        [ordered]@{ tag = $tv; time = (Get-Date).ToString('s') } | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
        [System.IO.File]::Copy($tmp, $CachePath, $true)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}
function Invoke-AbortableGet([string]$url, [bool]$noRedirect, [int]$msLimit) {
    if ($Cancel['Stop'] -or $swAll.ElapsedMilliseconds -ge 8000) { return $null }
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'EdgePanel-Probe'
    $req.AllowAutoRedirect = (-not $noRedirect)
    $req.Timeout = $msLimit
    $req.ReadWriteTimeout = $msLimit
    $ar = $req.BeginGetResponse($null, $null)
    $wh = $ar.AsyncWaitHandle
    $swOne = [Diagnostics.Stopwatch]::StartNew()
    while (-not $ar.IsCompleted) {
        if ($Cancel['Stop'] -or $swOne.ElapsedMilliseconds -ge $msLimit -or $swAll.ElapsedMilliseconds -ge 8000) {
            try { $req.Abort() } catch { }
            try { [void]$wh.WaitOne(50) } catch { }
            try { $wh.Close() } catch { }
            return $null
        }
        [void]$wh.WaitOne(120)
    }
    try { return $req.EndGetResponse($ar) } catch { return $_.Exception.Response } finally { try { $wh.Close() } catch { } }
}
# ① 优先走 releases/latest 的 302（仅 2 源：直连 + gh-proxy.org，单源 2.5s，总预算 <=8s）
foreach ($u in @($Page, ('https://gh-proxy.org/' + $Page))) {
    if ($Cancel['Stop'] -or $swAll.ElapsedMilliseconds -ge 8000) { return 'ERR|' }
    try {
        $resp = Invoke-AbortableGet $u $true 2500
        if ($resp) {
            $loc = [string]$resp.Headers['Location']
            try { $resp.Close() } catch { }
            $m = [regex]::Match([string]$loc, '/tag/(v?[0-9][0-9A-Za-z\.\-_]*)$')
            if ($m.Success) {
                $tv = $m.Groups[1].Value
                Save-ProbeCache $tv
                return ('OK|' + $tv)
            }
        }
    } catch { }
}
# ② 重定向拿不到再退回 API（仅 2 源，受 8s 总预算约束）
foreach ($u in @($Api, ('https://gh-proxy.org/' + $Api))) {
    if ($Cancel['Stop'] -or $swAll.ElapsedMilliseconds -ge 8000) { return 'ERR|' }
    try {
        $resp = Invoke-AbortableGet $u $false 2500
        if ($resp) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $sr.Dispose(); $resp.Close()
            $o = $txt | ConvertFrom-Json
            if ($o.tag_name) {
                $tv = [string]$o.tag_name
                Save-ProbeCache $tv
                return ('OK|' + $tv)
            }
        }
    } catch { }
}
return ('ERR|')
'@
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($probe).AddArgument($page).AddArgument($api).AddArgument($cancelBox).AddArgument($probeCachePath)
        $script:panelProbeRs = $rs
        $script:panelProbePs = $ps
        $script:panelProbeHandle = $ps.BeginInvoke()
    } catch {
        Write-Log ('面板更新静默探测未能启动：' + $_.Exception.Message) 'warn'
        try { if ($ps) { $ps.Dispose() } } catch { }
        try { if ($rs) { $rs.Dispose() } } catch { }
        $script:panelProbePs = $null; $script:panelProbeRs = $null; $script:panelProbeHandle = $null
        return
    }
    Write-Log '正在后台检查面板更新（不影响使用）…'
    $script:panelProbeTimer = New-Object System.Windows.Forms.Timer
    $script:panelProbeTimer.Interval = 500
    $script:panelProbeTimer.Add_Tick({
        if ($script:closeRequested -or $form.IsDisposed) {
            if ($script:panelProbeTimer) { try { $script:panelProbeTimer.Stop(); $script:panelProbeTimer.Dispose() } catch { }; $script:panelProbeTimer = $null }
            return
        }
        if (-not $script:panelProbeHandle -or -not $script:panelProbeHandle.IsCompleted) { return }
        try { $script:panelProbeTimer.Stop(); $script:panelProbeTimer.Dispose() } catch { }
        $script:panelProbeTimer = $null
        $raw = ''
        try { $raw = [string](@($script:panelProbePs.EndInvoke($script:panelProbeHandle)) | Where-Object { $_ } | Select-Object -Last 1) } catch { }
        try { $script:panelProbePs.Dispose() } catch { }
        try { $script:panelProbeRs.Dispose() } catch { }
        $script:panelProbePs = $null
        $script:panelProbeRs = $null
        $script:panelProbeHandle = $null
        if ($raw -notlike 'OK|*') { Write-Log '面板更新静默检查未取得版本信息（网络或限流），下次启动再试' 'warn'; return }
        $tagText = ([string]($raw.Substring(3))).Trim().TrimStart('v', 'V')
        $curV = $null; $newV = $null
        if (-not ([version]::TryParse($script:panelVersion, [ref]$curV) -and [version]::TryParse($tagText, [ref]$newV))) { return }
        if ($newV -le $curV) { return }
        Set-PanelUpdateHighlight $true
        Write-Log ('静默探测：面板有新版本 v' + $script:panelVersion + ' → v' + $tagText) 'warn'
        if ($script:isBusy) { return }
        if ($RunOnce) { return }
        $ansP = $(if (Show-DialogAsk '面板有新版本' ("发现面板新版本：v" + $script:panelVersion + " → v" + $tagText + "`r`n`r`n是否立即通过镜像下载并更新？（校验 SHA256 后自动重启；选「暂不」顶栏按钮将保持绿色，随时可手动更新）") '现在更新' '暂不' -FocusCancel) { 'Yes' } else { 'No' })
        if ($ansP -eq 'Yes') { Invoke-PanelUpdate -SkipConfirm }
    })
    $script:panelProbeTimer.Start()
}

function Invoke-PanelUpdate([switch]$SkipConfirm) {
    if ([string]::IsNullOrWhiteSpace($script:panelUpdateRepo)) {
        Write-Log '面板更新源尚未配置：GitHub 仓库上线后，在 EdgePanel.ps1 顶部填入 $script:panelUpdateRepo = ''用户名/仓库名'' 即可启用镜像检查与更新。' 'warn'
        return
    }
    Set-Busy $true '检查面板更新…'
    $rs = $null; $ps = $null
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $rawApi = 'https://api.github.com/repos/' + $script:panelUpdateRepo.Trim('/') + '/releases/latest'
        Write-Log ('正在检查面板更新：' + $script:panelUpdateRepo + ' …')
        $rel = $null
        $apiErr = ''
        foreach ($apiUrl in @($rawApi, ('https://gh-proxy.org/' + $rawApi), ('https://ghfast.top/' + $rawApi))) {
            try {
                $req = [System.Net.HttpWebRequest]::Create($apiUrl)
                $req.UserAgent = 'EdgePanel/' + $script:panelVersion
                $req.Timeout = 8000
                $resp = $req.GetResponse()
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $rel = $sr.ReadToEnd() | ConvertFrom-Json
                $sr.Dispose(); $resp.Close()
                if ($rel -and $rel.tag_name) { break }
            } catch { $apiErr = $_.Exception.Message }
        }
        $rawTag = ''
        $tagVerText = ''
        $exeAsset = $null
        $shaAsset = $null
        if ($rel -and $rel.tag_name) {
            $rawTag = [string]$rel.tag_name
            $exeAsset = @($rel.assets | Where-Object { $_.name -like '*.exe' }) | Select-Object -First 1
            $shaAsset = @($rel.assets | Where-Object { $_.name -match '(?i)sha256' }) | Select-Object -First 1
        } else {
            # API 可能被匿名限流（60 次/小时）：改走 releases/latest 的 302，零配额
            $rawTag = Get-PanelLatestTagRedirect
            if (-not $rawTag) { throw ('无法连接 GitHub（API：' + $apiErr + '）') }
            Write-Log ('Release API 不可用（' + $apiErr + '），已改用 releases/latest 重定向取得版本：' + $rawTag) 'warn'
        }
        # 比较用去掉 v 的版本号；拼下载地址必须用**原始 tag**（我们的 Release tag 形如 v1.3.4）
        $tagVerText = ([string]$rawTag).TrimStart('v', 'V')
        $curV = $null; $newV = $null
        if (-not ([version]::TryParse($script:panelVersion, [ref]$curV) -and [version]::TryParse($tagVerText, [ref]$newV))) {
            $tagForLog = if ($rawTag) { $rawTag } else { '(空)' }
            Write-Log ('无法解析线上版本号：' + $tagForLog) 'warn'
            Set-PanelUpdateHighlight $false
            return
        }
        if ($newV -le $curV) {
            Set-PanelUpdateHighlight $false
            Write-Log ('面板已是最新版本（v' + $script:panelVersion + '）') 'ok'
            return
        }

        if (-not $exeAsset) {
            # 约定式地址：Release 附件名固定为 EdgePanel.exe / SHA256SUMS.txt
            $dlBase = 'https://github.com/' + $script:panelUpdateRepo.Trim('/') + '/releases/download/' + $(if ($rawTag) { $rawTag } else { $tagVerText })
            $panelLatestInfo = @{ Version = $tagVerText; ExeUrl = ($dlBase + '/EdgePanel.exe'); ShaUrl = ($dlBase + '/SHA256SUMS.txt'); Digest = '' }
        } else {
            $panelLatestInfo = @{ Version = $tagVerText; ExeUrl = [string]$exeAsset.browser_download_url; ShaUrl = $(if ($shaAsset) { [string]$shaAsset.browser_download_url } else { '' }); Digest = $(if ($exeAsset.digest) { [string]$exeAsset.digest } else { '' }) }
        }
        Set-PanelUpdateHighlight $true
        Write-Log ('发现面板新版本：v' + $script:panelVersion + ' → v' + $tagVerText) 'warn'
        if ($RunOnce) { return }
        if (-not $SkipConfirm) {
            $ans = $(if (Show-DialogAsk '更新便携 Edge 面板' ("发现面板新版本：v" + $script:panelVersion + " → v" + $tagVerText + "`r`n`r`n将通过国内镜像站下载新版 EXE、校验 SHA256，并保留旧版为 .old。现在更新吗？") '现在更新' '取消') { 'Yes' } else { 'No' })
            if ($ans -ne 'Yes') { Write-Log '已取消面板更新'; return }
        }

        $dlUrl = $panelLatestInfo.ExeUrl
        $mirrors = @(
            ('https://gh-proxy.org/' + $dlUrl),
            ('https://ghfast.top/' + $dlUrl),
            ('https://gh-proxy.com/' + $dlUrl),
            ('https://ghproxy.net/' + $dlUrl),
            ('https://gh.llkk.cc/' + $dlUrl),
            $dlUrl
        )
        $tmpDir = Join-Path $env:TEMP ('edgepanel-selfupd-' + (Get-Date).ToString('HHmmss'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $newExe = Join-Path $tmpDir 'Edge面板.new.exe'
        $partExe = $newExe + '.part'
        $progFile = Join-Path $tmpDir 'progress.json'

        # 显式创建并绑定 Runspace（B9），避免换宿主时抛 No runspace available
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:downloadScript).AddArgument([string[]]$mirrors).AddArgument($partExe).AddArgument($newExe).AddArgument($progFile)
        $h = $ps.BeginInvoke()
        while (-not $h.IsCompleted) {
            if ($script:closeRequested) { try { [void]$ps.BeginStop($null, $null) } catch { }; throw '已取消下载' }
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
        }
        $dlOut = ($ps.EndInvoke($h) | Where-Object { $_ -is [string] } | Select-Object -Last 1)
        $dlRes = $dlOut | ConvertFrom-Json
        if (-not $dlRes -or -not $dlRes.ok -or -not (Test-Path -LiteralPath $newExe)) { throw ('下载新版面板失败：' + $(if ($dlRes) { $dlRes.error } else { '未知错误' })) }

        # SHA256 强制校验：优先用 GitHub API asset.digest，其次拉 SHA256SUMS.txt；两者均不可得时中止替换（绝不静默降级）
        $expectSha = ''
        if ($panelLatestInfo.Digest) {
            $mDig = [regex]::Match($panelLatestInfo.Digest, '(?i)\b([0-9a-f]{64})\b')
            if ($mDig.Success) { $expectSha = $mDig.Groups[1].Value.ToLowerInvariant() }
        }
        if (-not $expectSha -and $panelLatestInfo.ShaUrl) {
            $shaText = ''
            foreach ($su in @(('https://gh-proxy.org/' + $panelLatestInfo.ShaUrl), ('https://ghfast.top/' + $panelLatestInfo.ShaUrl), $panelLatestInfo.ShaUrl)) {
                try {
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('User-Agent', 'EdgePanel/' + $script:panelVersion)
                    $shaText = $wc.DownloadString($su)
                    $wc.Dispose()
                    if ($shaText) { break }
                } catch { }
            }
            $mSha = [regex]::Match($shaText, '(?i)\b([0-9a-f]{64})\b')
            if ($mSha.Success) { $expectSha = $mSha.Groups[1].Value.ToLowerInvariant() }
        }
        if (-not $expectSha) { throw '未能获取新版 SHA256 校验值（已尝试 API digest 与 SHA256SUMS.txt），为安全起见已中止替换' }
        $shaObj = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::OpenRead($newExe)
        try { $gotSha = ([BitConverter]::ToString($shaObj.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $fs.Dispose(); $shaObj.Dispose() }
        if ($gotSha -ne $expectSha) { throw 'SHA256 校验不通过，已中止替换' }
        Write-Log '新版面板 SHA256 校验通过' 'ok'

        # 替换"当前正在运行的这个 EXE"：宿主通过 EP_EXEPATH 传入真实路径（用户可能把文件改名成 EdgePanel.exe）
        $curExe = [string]$env:EP_EXEPATH
        if (-not $curExe -or -not (Test-Path -LiteralPath $curExe)) {
            $curExe = ''
            foreach ($nm in @('EdgePanel.exe', 'Edge面板.exe')) {
                $cand = Join-Path $exeDir $nm
                if (Test-Path -LiteralPath $cand) { $curExe = $cand; break }
            }
        }
        if (-not $curExe) { throw ('未找到当前面板 EXE（已查 EP_EXEPATH、EdgePanel.exe、Edge面板.exe）') }
        $failLog = Join-Path $exeDir 'update-failed.txt'
        # 用 PowerShell 助手脚本做替换（不再用 .cmd）：
        # ① .cmd 里的 `timeout /t 1 /nobreak` 在无控制台窗口下会卡住（实测整个替换挂死不退出）；
        # ② .cmd 还必须按 ANSI 写盘，中文文件名容易踩编码；
        # ③ 也顺手避开 `cmd /c move /y + del %~f0` 这套杀软最容易误报的组合。
        $helperPath = Join-Path $env:TEMP 'edgepanel-apply-update.ps1'
        $helperBody = @'
param([string]$CurExe, [string]$NewExe, [string]$TmpDir, [string]$FailLog)
Start-Sleep -Milliseconds 1200
$ok = $false
$lastErr = ''
$bakDone = $false
for ($i = 0; $i -lt 24; $i++) {
    try {
        # 备份只在第一轮做一次，之后不再碰它：老写法每轮「先删 .old 再重建」——
        # 一旦 $CurExe 在重试过程中被外部删掉／被独占，就会把唯一的备份也一起丢掉。
        if (-not $bakDone -and (Test-Path -LiteralPath $CurExe)) {
            $bakTmp = $CurExe + '.old.tmp'
            $bakDst = $CurExe + '.old'
            $srcLen = (Get-Item -LiteralPath $CurExe -ErrorAction Stop).Length
            Copy-Item -LiteralPath $CurExe -Destination $bakTmp -Force -ErrorAction Stop
            if ((Get-Item -LiteralPath $bakTmp -ErrorAction Stop).Length -ne $srcLen) {
                Remove-Item -LiteralPath $bakTmp -Force -ErrorAction SilentlyContinue
                throw '旧版备份文件大小校验不一致'
            }
            if (Test-Path -LiteralPath $bakDst) { Remove-Item -LiteralPath $bakDst -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $bakTmp -Destination $bakDst -Force -ErrorAction Stop
            $bakDone = $true
        }
        Move-Item -LiteralPath $NewExe -Destination $CurExe -Force -ErrorAction Stop
        $ok = $true
        break
    } catch {
        $lastErr = $_.Exception.Message
        Start-Sleep -Milliseconds 500
    }
}
if ($ok) {
    try { if (Test-Path -LiteralPath $FailLog) { Remove-Item -LiteralPath $FailLog -Force -ErrorAction SilentlyContinue } } catch { }
    try { Start-Process -FilePath $CurExe } catch { }
    try { Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
} else {
    # 失败自愈（面板此前已自己退出，不补这一步用户看到的就是"窗口消失、再也不出现"）：
    # ① 极端情况目标 EXE 已不在（被外部删掉/清掉）→ 从 .old 还原；
    # ② 无论哪种失败，都把旧面板重新拉起来；并置 EP_NO_PANEL_PROBE=1，避免拉起后又弹一次更新提示形成死循环。
    $restored = $false
    try {
        if (-not (Test-Path -LiteralPath $CurExe) -and (Test-Path -LiteralPath ($CurExe + '.old'))) {
            Copy-Item -LiteralPath ($CurExe + '.old') -Destination $CurExe -Force -ErrorAction Stop
            $restored = $true
        }
    } catch { }
    try {
        $msg = ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] 替换失败（24 次重试均失败）：' + $lastErr +
                '；当前面板：' + $CurExe + $(if ($restored) { '（已从 .old 还原）' } else { '' }) +
                '；旧版备份：' + $CurExe + '.old；新版文件仍在：' + $NewExe)
        Set-Content -LiteralPath $FailLog -Value $msg -Encoding UTF8
    } catch { }
    try {
        if (Test-Path -LiteralPath $CurExe) {
            $env:EP_NO_PANEL_PROBE = '1'
            Start-Process -FilePath $CurExe
        }
    } catch { }
}
try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue } catch { }
'@
        [System.IO.File]::WriteAllText($helperPath, $helperBody, (New-Object System.Text.UTF8Encoding($true)))
        Write-Log '新版面板已就绪，即将退出并自动重启更新…' 'ok'
        # 含路径的元素自己加引号：-ArgumentList 不会替你加。这条尤其致命——
        # 面板所在目录带空格（如 C:\Program Files\... 或把便携包放进带空格的文件夹）时参数整体错位，
        # Copy-Item 每次必失败、连 update-failed.txt 的路径也一起错位 ⇒ 更新静默失败且无任何提示。
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $helperPath + '"'), ('"' + $curExe + '"'), ('"' + $newExe + '"'), ('"' + $tmpDir + '"'), ('"' + $failLog + '"')) `
            -WindowStyle Hidden | Out-Null
        $form.Close()

    } catch {
        Write-Log ('面板更新失败：' + $_.Exception.Message) 'err'
    } finally {
        if ($ps) { try { $ps.Dispose() } catch { } }
        if ($rs) { try { $rs.Close(); $rs.Dispose() } catch { } }
        if (-not $script:closeRequested -and -not $form.IsDisposed) { Set-Busy $false }
    }
}

# ---------------- 启动 ----------------
function Start-AutoClose([int]$ms, [string]$why = '') {
    # 自测模式用：到点自己关窗（$script: 作用域，避免闭包取不到变量）
    $script:autoClose = New-Object System.Windows.Forms.Timer
    $script:autoClose.Interval = $ms
    $script:autoClose.Add_Tick({
        $script:autoClose.Stop()
        $script:autoClose.Dispose()
        if ($why) { Write-Log $why }
        $form.Close()
    })
    $script:autoClose.Start()
}

$form.Add_Shown({
    try {
        # Edge 运行检测延后一拍：不在 Add_Shown（ShowDialog 首事件）里弹模态框——
        # 那样对话框关闭后事件处理器会被中止（实测），后续启动逻辑全不执行。
        $script:startupPromptTimer = New-Object System.Windows.Forms.Timer
        $script:startupPromptTimer.Interval = 300
        $script:startupPromptTimer.Add_Tick({
            $script:startupPromptTimer.Stop()
            if ($script:closeRequested -or $form.IsDisposed) { return }
            $script:startupPromptTimer.Dispose()
            if ($env:EP_NO_PROMPT -eq '1') { return }
            # 若面板未放在便携 Edge 目录内：自动扫描本机便携 Edge 并弹出统一选择窗（默认选中上次/首个已发现目录）
            if ($script:noPackage -and -not $env:EP_TEST_PKGROOT -and -not $RunOnce) {
                $lastSaved = Get-LastSavedPkgRoot
                # 记住的目录仍然有效 → 静默接管（右键左上角路径可切换），避免每次双击都弹选择窗
                if ($lastSaved -and (Test-PortableEdgeDir $lastSaved)) {
                    Write-Log ('沿用上次的便携 Edge 目录：' + $lastSaved)
                    Switch-PackageRoot $lastSaved -CheckRunning
                    return
                }
                $found = @(Find-PortableEdgeDirs $lastSaved)
                if ($found.Count -gt 0) {
                    $safeHere = Test-SafeDeployDir $exeDir
                    $pick = Show-PkgPickerDialog $found $exeDir $lastSaved $safeHere.Ok
                    if ($pick -and $pick.Kind -eq 'existing' -and $pick.Path) {
                        Switch-PackageRoot $pick.Path -CheckRunning
                        return
                    }
                }
            }
            Prompt-IfEdgeRunning
        })
        $script:startupPromptTimer.Start()
        # 上次被强杀可能留下 edge-update-* 半成品，超过 30 分钟没动的一律清掉
        Get-ChildItem $env:TEMP -Directory -Filter 'edge-update-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-30) } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        # 只有在手动指定了缩放（EP_UI_SCALE / EP_UI_BASE）时才打这行；默认恒等缩放不打扰日志
if ($env:EP_UI_SCALE -or $env:EP_UI_BASE) {
    Write-Log ('界面缩放（手动）：' + $script:dpiScale + '× → 窗口 ' + $form.ClientSize.Width + '×' + $form.ClientSize.Height + ' px')
}
Write-Log ('面板已启动；包根：' + $pkgRoot)
        Write-Log ('程序目录：' + $progDir)
        Write-Log ('策略键：' + $script:policyKey)
    if ($script:baselineLoadError) { Write-Log ('策略基线读取失败：' + $script:baselineLoadError + ' —— 漂移体检本次不可用') 'err' }
    try { Show-PolicyDrift } catch { }   # F3：启动时比对一次策略漂移（全对静默）
        if (-not (Test-Path -LiteralPath (Join-Path $pkgRoot 'Edge\msedge.exe'))) { Write-Log ('这个目录还没有 Edge 程序：点「更新并瘦身」就地装一套完整的便携包（会把 Edge\ 铺到 ' + $pkgRoot + '）') 'warn' }
        if ($RunOnce) {
            Update-Status
            $form.Refresh()
            $form.Opacity = 1
        } else {
            # 先用上次状态把界面填满（毫秒级），画完首帧再把 Opacity 置 1，彻底消除深色启动闪白
            $cacheFile = Get-StatusCachePath
            if (Test-Path -LiteralPath $cacheFile) {
                try { Apply-Status ([System.IO.File]::ReadAllText($cacheFile, [System.Text.Encoding]::UTF8)) -FromCache } catch { }
            }
            $form.Refresh()
            $form.Opacity = 1
            $script:pendingAutoCheck = $true
            Update-StatusAsync
            # 启动 6 秒后静默探测面板自身更新（避开启动时的状态刷新与 Edge 版本查询，不抢带宽）
            try {
                $script:panelProbeDelay = New-Object System.Windows.Forms.Timer
                $script:panelProbeDelay.Interval = 6000
                $script:panelProbeDelay.Add_Tick({
                    try { $script:panelProbeDelay.Stop(); $script:panelProbeDelay.Dispose() } catch { }
                    $script:panelProbeDelay = $null
                    Start-PanelUpdateProbe
                    try { Test-PwaRegistrationGap } catch { }
                })
                $script:panelProbeDelay.Start()
            } catch { }
        }
        if ($RunOnce) {
            Write-Log ('自测模式：' + $RunOnce)
            switch ($RunOnce) {
                'Clean'      { Invoke-Action 'Clean' }
                'SlimOnly'   { Invoke-Action 'SlimOnly' }
                'SlimAll'    { Invoke-Action 'SlimAll' }
                'IniOff'     { Invoke-Action 'IniOff' }
                'IniOn'      { Invoke-Action 'IniOn' }
                'CheckUpdate'{ Invoke-CheckSync }
                'CheckAsync' { Invoke-Check; Start-AutoClose 20000 '自测：异步检查超时，关闭' }
                'RefreshAsync' { Update-StatusAsync; Start-AutoClose 12000 '自测：异步刷新结束，关闭' }
                'ApplyRecommended' { Apply-RecommendedPolicies }
                'BackupAll' { Invoke-CleanAndBackup }
        'BackupPlain' { Invoke-CleanAndBackup $true }   # 自测：一次不加密的备份
        'BackupForce' { Invoke-CleanAndBackup -Force }   # 自测：忽略指纹强制备份
        'BackupFull' { Invoke-CleanAndBackup -Force -Full }   # 自测：带本体完整包
        'BackupPanel' { Invoke-CleanAndBackup -Force -Panel }   # 自测：数据 + 面板
        'BackupFullPanel' { Invoke-CleanAndBackup -Force -Full -Panel }   # 自测：数据 + 面板 + Edge 本体
        'Restore' { Invoke-RestoreBackup -Auto }   # 自测：恢复最新备份（跳过选包与提问）
        'RestoreTwice' {
            # R6 自测：连续两轮恢复压测，检验连续操作下是否退化/卡顿
            for ($round = 1; $round -le 2; $round++) {
                $swR = [Diagnostics.Stopwatch]::StartNew()
                Write-Log ('[压测] 第 ' + $round + '/2 轮恢复开始…')
                Invoke-RestoreBackup -Auto
                Write-Log ('[压测] 第 ' + $round + '/2 轮结束，耗时 ' + [math]::Round($swR.Elapsed.TotalSeconds, 1) + ' 秒') 'ok'
            }
        }
        'DialogSmoke' {
            # 自测：构造备份弹窗 → 1.5 秒后自动关掉 → 记录构造结果（不点任何业务按钮）
            $t2 = New-Object System.Windows.Forms.Timer
            $t2.Interval = 1500
            $t2.Add_Tick({ $t2.Stop(); foreach ($f2 in @([System.Windows.Forms.Application]::OpenForms)) { try { $f2.Close() } catch { } } })
            $t2.Start()
            try {
                $r = Show-BackupDialog $false (Get-BackupCfg)
                Write-Log ('对话框冒烟：构造成功 Start=' + $r.Start + ' Keep=' + $r.Keep + ' Full=' + $r.Full) 'ok'
            } catch {
                Write-Log ('对话框冒烟失败：' + $_.Exception.Message) 'err'
            }
            Start-AutoClose 3000
        }
                'HighlightTest' { Set-UpdateHighlight $true; Start-AutoClose 15000 }
                'UpdateDry'  { Invoke-UpdateNow }
                'UpdateDrySlim' { Invoke-UpdateNow $true }
                default      { Write-Log '自测模式：仅刷新状态' }
            }
            if ($RunOnce -notin @('CheckAsync', 'RefreshAsync', 'HighlightTest')) { $form.Close() }
        }
    } catch {
        $form.Opacity = 1
        Write-Log ('Add_Shown 异常：' + $_.Exception.ToString()) 'err'
    }
})

$form.ResumeLayout($false)
[void]$form.ShowDialog()




