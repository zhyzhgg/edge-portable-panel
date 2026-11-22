#Requires -Version 5.1
<#
.SYNOPSIS
    Edge Debloater GUI —— 只读翻译器：把上游脚本里的英文字面量替换成中文词库里的译文。

.DESCRIPTION
    不修改源文件。读取 src（上游每次下载的新脚本），按词库生成 out（UTF-8 with BOM），
    并对 out 做一次语法自检；自检不过就把 src 原样复制成 out，并在报告里注明。
    只替换「字符串字面量」，绝不改动代码结构。

.PARAMETER Source  上游脚本路径（work\src.ps1）
.PARAMETER Out     译文输出路径（work\out.ps1）
.PARAMETER Map     词库路径（zh-CN.json）
.PARAMETER Report  报告输出路径（work\translate-report.txt）

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File translate.ps1 -Source work\src.ps1 -Out work\out.ps1 -Map zh-CN.json -Report work\translate-report.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string]$Map,
    [string]$Report
)

$ErrorActionPreference = 'Stop'
function Resolve-Full([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return [System.IO.Path]::Combine($PSScriptRoot, $p)
}
$Source = Resolve-Full $Source
$Out = Resolve-Full $Out
$Map = Resolve-Full $Map
if (-not $Report) { $Report = Join-Path (Split-Path $Out -Parent) 'translate-report.txt' } else { $Report = Resolve-Full $Report }

$rep = New-Object System.Collections.Generic.List[string]
function Add-Rep([string]$s) { $script:rep.Add($s); Write-Host $s }

if (-not (Test-Path -LiteralPath $Source)) { Add-Rep "错误：找不到源脚本 $Source"; exit 2 }
if (-not (Test-Path -LiteralPath $Map)) { Add-Rep "错误：找不到词库 $Map"; exit 2 }

# ---------- 读源（保留原编码：UTF-8 无 BOM / 有 BOM 都行） ----------
$srcText = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
# 不用 Get-FileHash：某些宿主（无控制台/精简 PSModulePath）下该 cmdlet 不可用，改用 .NET
function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}
$srcSha = Get-Sha256 $Source

# ---------- 读词库（键区分大小写） ----------
$json = Get-Content -LiteralPath $Map -Raw -Encoding UTF8 | ConvertFrom-Json
$exact = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$exactCount = 0
foreach ($p in $json.exact.PSObject.Properties) { $exact[$p.Name] = [string]$p.Value; $exactCount++ }
$rules = @()
if ($json.rules) { $rules = @($json.rules) }

# ---------- 解析 ----------
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($srcText, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Add-Rep "警告：源脚本本身解析报错 $($errors.Count) 处（上游可能语法异常），仍继续尝试。"
}

# 供报告用的「行号」换算
$lineStarts = New-Object System.Collections.Generic.List[int]
$lineStarts.Add(0)
for ($i = 0; $i -lt $srcText.Length; $i++) { if ($srcText[$i] -eq "`n") { $lineStarts.Add($i + 1) } }
function Get-Line([int]$offset) {
    $lo = 0; $hi = $lineStarts.Count - 1
    while ($lo -lt $hi) {
        $mid = [int](($lo + $hi + 1) / 2)
        if ($lineStarts[$mid] -le $offset) { $lo = $mid } else { $hi = $mid - 1 }
    }
    return $lo + 1
}

# ---------- 收集替换 ----------
$edits = New-Object System.Collections.Generic.List[object]
$hitsExact = 0; $hitsRule = 0
$untranslated = New-Object System.Collections.Generic.List[object]
$skippedGuard = 0

foreach ($t in $tokens) {
    if ($t.Kind -ne 'StringLiteral' -and $t.Kind -ne 'StringExpandable') { continue }
    $text = $t.Text
    if (-not $text -or $text.Length -lt 2) { continue }
    $q = $text[0]
    if ($q -ne '"' -and $q -ne "'") { continue }                      # 跳过 here-string 等
    if ($text.Length -ge 2 -and $text[1] -eq $q) { continue }         # @" / @'
    if ($text[$text.Length - 1] -ne $q) { continue }

    $raw = $text.Substring(1, $text.Length - 2)
    if ($raw.Length -eq 0) { continue }

    # 安全闸：Name= / SubKey= / Value= / Type= 的取值不译（策略名、注册表值名必须保持英文）
    $start = $t.Extent.StartOffset
    $backLen = [Math]::Min(60, $start)
    $back = $srcText.Substring($start - $backLen, $backLen)
    if ($back -match '(?i)(?<![A-Za-z0-9_])(Name|SubKey|Value|Type)\s*=\s*$') { $skippedGuard++; continue }

    $zh = $null
    if ($exact.TryGetValue($raw, [ref]$zh)) {
        if ($zh -ne $raw) {
            $edits.Add([pscustomobject]@{ Start = $start; Len = $text.Length; New = $q + $zh + $q; Raw = $raw; Zh = $zh; Rule = 'exact' })
            $hitsExact++
        }
        continue
    }

    $applied = $false
    foreach ($r in $rules) {
        if ($r.type -eq 'prefix') {
            if ($raw.StartsWith($r.find, [System.StringComparison]::Ordinal)) {
                $newRaw = $r.replace + $raw.Substring($r.find.Length)
                $edits.Add([pscustomobject]@{ Start = $start; Len = $text.Length; New = $q + $newRaw + $q; Raw = $raw; Zh = $newRaw; Rule = 'prefix' })
                $hitsRule++; $applied = $true; break
            }
        } elseif ($r.type -eq 'regex') {
            $m = [regex]::Match($raw, $r.find)
            if ($m.Success) {
                $newRaw = [regex]::Replace($raw, $r.find, $r.replace)
                if ($newRaw -ne $raw) {
                    $edits.Add([pscustomobject]@{ Start = $start; Len = $text.Length; New = $q + $newRaw + $q; Raw = $raw; Zh = $newRaw; Rule = 'regex' })
                    $hitsRule++; $applied = $true; break
                }
            }
        }
    }
    if ($applied) { continue }

    # 未命中但看起来像 UI 文案 → 进待补译清单
    if ($raw.Length -ge 8 -and $raw -match '\s' -and $raw -notmatch '^(https?:|HK|C:\\|\\\\)' -and $raw -notmatch '^\$') {
        $untranslated.Add([pscustomobject]@{ Line = (Get-Line $start); Raw = $raw })
    }
}

# ---------- 生成译文（从后往前替换，保证偏移有效） ----------
$sb = New-Object System.Text.StringBuilder $srcText
$sorted = $edits | Sort-Object Start -Descending
foreach ($e in $sorted) { [void]$sb.Remove($e.Start, $e.Len); [void]$sb.Insert($e.Start, $e.New) }
$outText = $sb.ToString()

# ---------- 语法自检 ----------
$t2 = $null; $e2 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($outText, [ref]$t2, [ref]$e2)
$ok = (-not $e2 -or $e2.Count -eq 0)

# ---------- 注入：策略悬停提示（鼠标放上去显示一句话解释） ----------
$injectNote = '未注入（无词表或无锚点）'
if ($ok) {
    $hintPath = Join-Path $PSScriptRoot 'policy-hints.json'
    if (Test-Path -LiteralPath $hintPath) {
        $hj = Get-Content -LiteralPath $hintPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hintLines = New-Object System.Collections.Generic.List[string]
        $hintLines.Add('$script:PolicyHints = @{')
        $hintCount = 0
        foreach ($prop in $hj.PSObject.Properties) {
            if ($prop.Name.StartsWith('_')) { continue }
            $k = ([string]$prop.Name) -replace "'", "''"
            $raw = $prop.Value
            if ($raw -is [string]) {
                $text = '【功能】' + $raw
            } else {
                $adv = [string]$raw.advice
                # 建议文字本身已带「建议/不建议/看情况/可勾/必须」开头时，不再重复加标签
                $advLine = if ($adv -match '^(建议|不建议|看情况|可勾|必须|可有可无)') { $adv } else { '建议：' + $adv }
                $text = '【功能】' + ([string]$raw.what) + '`n【勾选后】' + ([string]$raw.effect) + '`n【建议】' + $advLine
            }
            $esc = $text -replace '"', '`"' -replace '\$', '`$'
            $hintLines.Add("    '$k' = `"$esc`"")
            $hintCount++
        }
        $hintLines.Add('}')

        # 特殊项（URLBlocklist / ExtensionInstallForcelist / CookiesAllowedForUrls…）
        $specCount = 0
        if ($hj._specials) {
            $hintLines.Add('$script:SpecialsHints = @{')
            foreach ($prop in $hj._specials.PSObject.Properties) {
                $k = ([string]$prop.Name) -replace "'", "''"
                $esc = ([string]$prop.Value) -replace "`r`n", '`n' -replace "`n", '`n' -replace '"', '`"' -replace '\$', '`$'
                $hintLines.Add("    '$k' = `"$esc`"")
                $specCount++
            }
            $hintLines.Add('}')
        }
        # 自定义组（跟踪防护 / 睡眠标签 / DoH）
        $custCount = 0
        if ($hj._custom) {
            $hintLines.Add('$script:CustomHints = @{')
            foreach ($prop in $hj._custom.PSObject.Properties) {
                $k = ([string]$prop.Name) -replace "'", "''"
                $esc = ([string]$prop.Value) -replace "`r`n", '`n' -replace "`n", '`n' -replace '"', '`"' -replace '\$', '`$'
                $hintLines.Add("    '$k' = `"$esc`"")
                $custCount++
            }
            $hintLines.Add('}')
        }
        if (-not $hj._specials) { $hintLines.Add('$script:SpecialsHints = @{}') }
        if (-not $hj._custom) { $hintLines.Add('$script:CustomHints = @{}') }

        $hintBlock = ($hintLines -join "`r`n") + "`r`n"

        $before = $outText
        $anchorPolicies = '$script:Policies = [ordered]@{'
        if ($outText.Contains($anchorPolicies)) {
            $outText = $outText.Replace($anchorPolicies, $hintBlock + $anchorPolicies)
        }

        $tipPolicy = @'
$chk.Tag = $policy
            if ($script:PolicyHints.ContainsKey($policy.Name)) { $script:ToolTip.SetToolTip($chk, $script:PolicyHints[$policy.Name]) } else { $script:ToolTip.SetToolTip($chk, $policy.Description) }
'@
        $nPolicy = 0
        if ($outText.Contains('$chk.Tag = $policy')) { $outText = $outText.Replace('$chk.Tag = $policy', $tipPolicy.TrimEnd()); $nPolicy = 1 }

        $tipSpec = @'
$chk.Tag = $key # store key name
               $script:ToolTip.SetToolTip($chk, $(if ($script:SpecialsHints.ContainsKey($key)) { $script:SpecialsHints[$key] } else { "$policyName - $($spec.Description)" }))
'@
        $nSpec = 0
        if ($outText.Contains('$chk.Tag = $key # store key name')) { $outText = $outText.Replace('$chk.Tag = $key # store key name', $tipSpec.TrimEnd()); $nSpec = 1 }

        # 自定义组三个控件
        $nCustom = 0
        # 锚点放在「下拉框已加入容器」之后，确保控件变量已创建
        $customMap = @{
            '$groupCustom.Controls.Add($script:CmbTracking)'        = 'TrackingPrevention|$script:ChkTrackingEnabled|$script:CmbTracking'
            '$groupCustom.Controls.Add($script:CmbSleepingTimeout)' = 'SleepingTabsTimeout|$script:ChkSleepingEnabled|$script:CmbSleepingTimeout'
            '$groupCustom.Controls.Add($script:CmbDohTemplate)'     = 'DnsOverHttpsMode|$script:ChkDohEnabled|$script:CmbDohTemplate'
        }
        foreach ($anchor in $customMap.Keys) {
            if (-not $outText.Contains($anchor)) { continue }
            $parts = $customMap[$anchor] -split '\|'
            $key = $parts[0]; $chkVar = $parts[1]; $cmbVar = $parts[2]
            $add = @"
$anchor
        if (`$script:CustomHints.ContainsKey('$key')) { `$script:ToolTip.SetToolTip($chkVar, `$script:CustomHints['$key']); `$script:ToolTip.SetToolTip($cmbVar, `$script:CustomHints['$key']) }
"@
            $outText = $outText.Replace($anchor, $add)
            $nCustom++
        }

        # 注入后再解析一次，失败就整体回退到注入前
        $t3 = $null; $e3 = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($outText, [ref]$t3, [ref]$e3)
        if ($e3 -and $e3.Count -gt 0) {
            $outText = $before
            $injectNote = "失败已回退（解析错误：$($e3[0].Message)）"
        } else {
            $injectNote = "成功：策略解释 $hintCount 条，特殊项 $specCount 条，自定义组 $custCount 条；悬停挂载：复选框 $nPolicy / 特殊项 $nSpec / 自定义控件 $nCustom"
        }

        # 覆盖率核对：策略表里的每一条都必须有解释，否则鼠标停上去会退回英文原描述
        $tableNames = @([regex]::Matches($outText, "Name='([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $hintKeys = @($hj.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') } | ForEach-Object { $_.Name })
        $covMissing = @($tableNames | Where-Object { $hintKeys -notcontains $_ })
        $covExtra = @($hintKeys | Where-Object { $tableNames -notcontains $_ })
        $covNote = "策略表 $($tableNames.Count) 条 / 有解释 " + ($tableNames.Count - $covMissing.Count) + " 条"
        if ($covMissing.Count -eq 0) { $covNote += "；无缺口" }
        else { $covNote += "；**缺 $($covMissing.Count) 条**（这些会显示英文原描述）：" + (($covMissing | Select-Object -First 12) -join ', ') + $(if ($covMissing.Count -gt 12) { ' …' } else { '' }) }
        if ($covExtra.Count) { $covNote += "；提示里多出 $($covExtra.Count) 条（表里没有，可删）：" + (($covExtra | Select-Object -First 8) -join ', ') }
    } else {
        $injectNote = "未注入（找不到 $hintPath）"
    }
}


# ---------- 注入：DPI 防裁切 + 浅/深色零闪白 + 深色动态拦截（防切页变白/黑字/亮黄条），语法自检失败自动回退 ----------
$darkNote = '未注入（未找到 ShowDialog 锚点）'
if ($ok) {
    $mShow = [regex]::Match($outText, '(?m)^([ \t]*)(?:\[void\]\s*)?(\$[A-Za-z0-9_]+)\.ShowDialog\(\)')
    if ($mShow.Success) {
        $formVar = $mShow.Groups[2].Value
        $darkSnippet = @"
# --- 由 EdgePanel 自动注入：DPI 标题防裁切 + 浅/深色无闪白 + 深色动态事件拦截 ---
try {
    `$epDark = `$false
    # 主题优先取"跨提权存活"的主题文件：上游 GUI 会自己提权重启，环境变量在那一步会丢，
    # 只剩注册表可读 ⇒ 面板浅色时会被系统深色拉回去（2026-11-21 实测）。
    `$epThemeFile = Join-Path `$env:LOCALAPPDATA 'EdgePanel\cache\ui-theme.json'
    `$epThemeFrom = ''
    try {
        if (Test-Path -LiteralPath `$epThemeFile) {
            `$epT = [string](Get-Content -LiteralPath `$epThemeFile -Raw -ErrorAction Stop | ConvertFrom-Json).theme
            if (`$epT -eq 'dark') { `$epDark = `$true; `$epThemeFrom = 'file' }
            elseif (`$epT -eq 'light') { `$epDark = `$false; `$epThemeFrom = 'file' }
        }
    } catch { }
    if (-not `$epThemeFrom) {
        if (`$env:EP_THEME -eq 'dark') { `$epDark = `$true }
        elseif (`$env:EP_THEME -ne 'light') {
            try {
                `$lv = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
                if ([int]`$lv -eq 0) { `$epDark = `$true }
            } catch { }
        }
    }
    # 浅色/深色共用：修复 DPI-Aware 下顶栏大号标题被固定高度切底，并统一无闪白显形
    `$script:epInTheme = `$false
    # 按"实际文字高度"修裁切，而不是按字号猜：
    # 上游顶栏 `$bannerLabel 固定 Size 500×20，而 11pt 粗体中文实测要高 26px ⇒ 底部被切（"Edge"看成"Edoe"）。
    # 做法：把同一容器内的 Label 逐个量出需要的高度（含中文按雅黑实测并释放临时 Font），仅当与上方 X 轴重叠的 Label 相撞时顺移 2px。
    function Ep-FixHeaderTitle(`$ctrl) {
        if (-not `$ctrl) { return }
        if (`$ctrl.Controls -and `$ctrl.Controls.Count -gt 0) {
            `$labs = @(`$ctrl.Controls | Where-Object { `$_ -is [System.Windows.Forms.Label] } | Sort-Object Top)
            if (`$labs.Count -gt 0) {
                foreach (`$l in `$labs) {
                    `$w = if (`$l.Width -gt 20) { `$l.Width } else { 500 }
                    # 关键：上游字体是 Segoe UI，量出来的高度是"拉丁指标"（偏矮）；中文走字体回退后实际更高。
                    `$tmpFnt = `$null
                    `$fnt = `$l.Font
                    try {
                        if ([string]`$l.Text -match '[\u4e00-\u9fff]') {
                            try { `$tmpFnt = New-Object System.Drawing.Font('Microsoft YaHei UI', `$l.Font.Size, `$l.Font.Style); `$fnt = `$tmpFnt } catch { `$fnt = `$l.Font }
                        }
                        `$h = [System.Windows.Forms.TextRenderer]::MeasureText([string]`$l.Text, `$fnt, (New-Object System.Drawing.Size(`$w, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
                    } finally {
                        if (`$tmpFnt) { `$tmpFnt.Dispose() }
                    }
                    if (`$h -lt 1) { `$h = `$l.Height }
                    if (`$h -gt `$l.Height) { `$h = `$h + 2 }
                    if (-not `$l.AutoSize -and `$l.Height -lt `$h) { `$l.Height = `$h }
                }
                # 仅在真正发生碰撞时纵向顺移（避免误伤并排或间隔摆放的 Label）
                `$maxBottom = 0
                for (`$i = 0; `$i -lt `$labs.Count; `$i++) {
                    `$cur = `$labs[`$i]
                    for (`$j = 0; `$j -lt `$i; `$j++) {
                        `$prev = `$labs[`$j]
                        if (`$cur.Left -lt `$prev.Right -and `$cur.Right -gt `$prev.Left -and `$cur.Top -lt (`$prev.Bottom + 2)) {
                            `$cur.Top = `$prev.Bottom + 2
                        }
                    }
                    if (`$cur.Bottom -gt `$maxBottom) { `$maxBottom = `$cur.Bottom }
                }
                `$deficit = (`$maxBottom + 2) - `$ctrl.ClientSize.Height
                if (`$deficit -gt 0 -and `$ctrl -isnot [System.Windows.Forms.Form]) { `$ctrl.Height = `$ctrl.Height + `$deficit + 2 }
            }
        }
        foreach (`$ch in @(`$ctrl.Controls)) { Ep-FixHeaderTitle `$ch }
    }
    Ep-FixHeaderTitle $formVar
    # 抗版本漂移收紧分类标签栏：按行为特征定位 FlowLayoutPanel（含 >=5 个 Button），收窄 Padding/Margin 避免「高级覆盖项」孤立折到第 3 行
    function Ep-CompactTabFlow(`$ctrl) {
        if (-not `$ctrl) { return }
        if (`$ctrl -is [System.Windows.Forms.FlowLayoutPanel]) {
            `$btns = @(`$ctrl.Controls | Where-Object { `$_ -is [System.Windows.Forms.Button] })
            if (`$btns.Count -ge 5) {
                if (`$ctrl.Parent) {
                    `$availW = `$ctrl.Parent.ClientSize.Width - `$ctrl.Left - 12
                    if (`$availW -gt `$ctrl.Width) { `$ctrl.Width = `$availW }
                }
                foreach (`$b in `$btns) {
                    `$b.AutoSize = `$true
                    `$b.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
                    `$b.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 2)
                }
                return
            }
        }
        foreach (`$ch in @(`$ctrl.Controls)) { Ep-CompactTabFlow `$ch }
    }
    Ep-CompactTabFlow $formVar
    $formVar.Opacity = 0
    $formVar.Add_Shown({ try { `$this.Refresh(); `$this.Opacity = 1 } catch { `$this.Opacity = 1 } })

    if (`$epDark) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EpDebloatTheme {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void Title(IntPtr h) { if (h == IntPtr.Zero) return; int v = 1; try { DwmSetWindowAttribute(h, 20, ref v, 4); } catch { } }
    public static void Scroll(IntPtr h) { if (h == IntPtr.Zero) return; try { SetWindowTheme(h, "DarkMode_Explorer", null); } catch { } }
}
'@ -ErrorAction SilentlyContinue
        `$cBg      = [System.Drawing.Color]::FromArgb(20, 23, 31)
        `$cCard    = [System.Drawing.Color]::FromArgb(28, 32, 43)
        `$cBtn     = [System.Drawing.Color]::FromArgb(37, 43, 59)
        `$cBtnAct  = [System.Drawing.Color]::FromArgb(37, 99, 235)   # 选中分类按钮高亮蓝
        `$cSearch  = [System.Drawing.Color]::FromArgb(30, 58, 95)    # 搜索命中深蓝底（替代刺眼亮黄）
        `$cEdge    = [System.Drawing.Color]::FromArgb(58, 68, 92)
        `$cTxt     = [System.Drawing.Color]::FromArgb(241, 245, 249)
        `$cMuted   = [System.Drawing.Color]::FromArgb(100, 116, 139)  # 已弃用/禁用策略弱化灰（明显区别于正常项）
        function Ep-PaintDark(`$ctrl) {
            if (-not `$ctrl) { return }
            `$bc = `$ctrl.BackColor
            `$isLightBg = (`$bc.A -eq 0) -or ((`$bc.R + `$bc.G + `$bc.B) -gt 520)
            `$isNeutral = ([math]::Abs(`$bc.R - `$bc.G) -lt 25 -and [math]::Abs(`$bc.G - `$bc.B) -lt 25)
            if (`$ctrl -is [System.Windows.Forms.Form]) {
                `$ctrl.BackColor = `$cBg; `$ctrl.ForeColor = `$cTxt
                `$ctrl.Add_HandleCreated({ [EpDebloatTheme]::Title(`$this.Handle) })
            } elseif (`$ctrl -is [System.Windows.Forms.Button]) {
                `$ctrl.UseVisualStyleBackColor = `$false
                `$ctrl.FlatStyle = 'Flat'
                `$ctrl.FlatAppearance.BorderSize = 1
                if (`$isNeutral) {
                    `$isActiveTab = (`$bc.R -ge 250 -and `$bc.G -ge 250 -and `$bc.B -ge 250)
                    `$ctrl.BackColor = if (`$isActiveTab) { `$cBtnAct } else { `$cBtn }
                    `$ctrl.ForeColor = `$cTxt
                    `$ctrl.FlatAppearance.BorderColor = if (`$isActiveTab) { `$cBtnAct } else { `$cEdge }
                    # 动态拦截：上游切换分类菜单时会把按钮 BackColor 刷回 White / LightGray，这里即时转成深色
                    `$ctrl.Add_BackColorChanged({
                        if (`$script:epInTheme) { return }
                        `$b0 = `$this.BackColor
                        `$neut = ([math]::Abs(`$b0.R - `$b0.G) -lt 25 -and [math]::Abs(`$b0.G - `$b0.B) -lt 25)
                        if (`$neut -and (`$b0.R + `$b0.G + `$b0.B) -gt 520) {
                            `$script:epInTheme = `$true
                            try {
                                `$act = (`$b0.R -ge 250 -and `$b0.G -ge 250 -and `$b0.B -ge 250)
                                `$this.BackColor = if (`$act) { `$cBtnAct } else { `$cBtn }
                                `$this.ForeColor = `$cTxt
                                `$this.FlatAppearance.BorderColor = if (`$act) { `$cBtnAct } else { `$cEdge }
                            } finally { `$script:epInTheme = `$false }
                        }
                    })
                } else {
                    `$ctrl.FlatAppearance.BorderColor = `$ctrl.BackColor
                }
            } elseif (`$ctrl -is [System.Windows.Forms.ComboBox]) {
                `$ctrl.FlatStyle = 'Flat'
                `$ctrl.BackColor = `$cBtn; `$ctrl.ForeColor = `$cTxt
            } elseif (`$ctrl -is [System.Windows.Forms.TextBoxBase] -or `$ctrl -is [System.Windows.Forms.ListControl]) {
                if (`$ctrl -is [System.Windows.Forms.TextBoxBase]) { `$ctrl.BorderStyle = 'FixedSingle' }
                if (`$isLightBg -and `$isNeutral) { `$ctrl.BackColor = `$cCard; `$ctrl.ForeColor = `$cTxt }
                `$ctrl.Add_HandleCreated({ [EpDebloatTheme]::Scroll(`$this.Handle) })
            } elseif (`$ctrl -is [System.Windows.Forms.GroupBox]) {
                # 显式设 ForeColor（不能跳过继承值，否则 VisualStyle 会画成纯黑标题看不清）
                `$ctrl.BackColor = `$cCard
                `$ctrl.ForeColor = `$cTxt
            } elseif (`$ctrl -is [System.Windows.Forms.CheckBox]) {
                `$origFc = `$ctrl.ForeColor
                `$origGray = (`$origFc.R -ge 90 -and `$origFc.R -le 190 -and [math]::Abs(`$origFc.R - `$origFc.G) -lt 15 -and [math]::Abs(`$origFc.G - `$origFc.B) -lt 15)
                `$tipStr = ''
                if (`$script:ToolTip) { try { `$tipStr = [string]`$script:ToolTip.GetToolTip(`$ctrl) } catch { } }
                `$isDep = (-not `$ctrl.Enabled) -or (-not `$ctrl.AutoCheck) -or `$origGray -or (`$tipStr -match '已弃用|Deprecated|无法启用')
                `$ctrl.BackColor = [System.Drawing.Color]::Transparent
                if (`$isDep) {
                    `$ctrl.ForeColor = `$cMuted
                    try { `$ctrl.Font = New-Object System.Drawing.Font(`$ctrl.Font, (`$ctrl.Font.Style -bor [System.Drawing.FontStyle]::Strikeout)) } catch { }
                } else {
                    `$ctrl.ForeColor = `$cTxt
                }
                # 动态拦截：搜索跳转后上游会把命中项 BackColor 设为亮黄（Color.Yellow），即时转为深蓝高亮（保留弃用项灰字）
                `$ctrl.Add_BackColorChanged({
                    if (`$script:epInTheme) { return }
                    `$b1 = `$this.BackColor
                    if (`$b1.R -gt 200 -and `$b1.G -gt 200 -and `$b1.B -lt 120) {
                        `$script:epInTheme = `$true
                        try {
                            `$this.BackColor = `$cSearch
                            `$isD = (-not `$this.Enabled) -or (-not `$this.AutoCheck) -or (`$this.Font -and `$this.Font.Strikeout)
                            `$this.ForeColor = if (`$isD) { `$cMuted } else { `$cTxt }
                        } finally { `$script:epInTheme = `$false }
                    }
                })
            } elseif (`$ctrl -is [System.Windows.Forms.Label]) {
                if (`$isLightBg -and `$isNeutral) { `$ctrl.BackColor = [System.Drawing.Color]::Transparent }
                `$fc = `$ctrl.ForeColor
                `$isNeutralTxt = ([math]::Abs(`$fc.R - `$fc.G) -lt 25 -and [math]::Abs(`$fc.G - `$fc.B) -lt 25)
                if (`$isNeutralTxt -or (`$fc.R + `$fc.G + `$fc.B) -lt 360) { `$ctrl.ForeColor = `$cTxt }
            } elseif (`$ctrl -is [System.Windows.Forms.Panel] -or `$ctrl -is [System.Windows.Forms.TabPage]) {
                if (`$isLightBg -and `$isNeutral) { `$ctrl.BackColor = `$cCard; `$ctrl.ForeColor = `$cTxt }
                `$ctrl.Add_HandleCreated({ [EpDebloatTheme]::Scroll(`$this.Handle) })
            }
            foreach (`$ch in @(`$ctrl.Controls)) { Ep-PaintDark `$ch }
        }
        `$script:epInTheme = `$true
        try { Ep-PaintDark $formVar } finally { `$script:epInTheme = `$false }
        if ($formVar.IsHandleCreated) { [EpDebloatTheme]::Title($formVar.Handle) }
        # 深色锐利 ToolTip（OwnerDraw + TextRenderer 7 参 ClearType）
        if (`$script:ToolTip) {
            `$script:ToolTip.OwnerDraw = `$true
            `$script:ToolTip.BackColor = `$cCard
            `$script:ToolTip.ForeColor = `$cTxt
            `$epTipFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
            `$script:ToolTip.Add_Popup({
                param(`$s, `$e)
                try {
                    `$txt = `$s.GetToolTip(`$e.AssociatedControl)
                    if (`$txt) {
                        `$sz = [System.Windows.Forms.TextRenderer]::MeasureText(`$txt, `$epTipFont, (New-Object System.Drawing.Size(440, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
                        `$e.ToolTipSize = New-Object System.Drawing.Size((`$sz.Width + 18), (`$sz.Height + 14))
                    }
                } catch { }
            })
            `$script:ToolTip.Add_Draw({
                param(`$s, `$e)
                `$bg = New-Object System.Drawing.SolidBrush(`$cCard)
                `$bd = New-Object System.Drawing.Pen(`$cEdge, 1)
                `$e.Graphics.FillRectangle(`$bg, `$e.Bounds)
                `$e.Graphics.DrawRectangle(`$bd, 0, 0, (`$e.Bounds.Width - 1), (`$e.Bounds.Height - 1))
                `$bg.Dispose(); `$bd.Dispose()
                `$rect = New-Object System.Drawing.Rectangle(9, 7, (`$e.Bounds.Width - 18), (`$e.Bounds.Height - 14))
                [System.Windows.Forms.TextRenderer]::DrawText(`$e.Graphics, `$e.ToolTipText, `$epTipFont, `$rect, `$cTxt, `$cCard, [System.Windows.Forms.TextFormatFlags]::WordBreak)
            })
        }
    }
} catch { try { $formVar.Opacity = 1 } catch { } }
"@
        $beforeDark = $outText
        $idxShow = $mShow.Index
        $outText = $outText.Insert($idxShow, $darkSnippet + "`r`n")
        $dpiHead = @'
try {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class EpDebloatDpi { [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' -ErrorAction SilentlyContinue
    try { [void][EpDebloatDpi]::SetProcessDpiAwareness(1) } catch { try { [void][EpDebloatDpi]::SetProcessDPIAware() } catch { } }
} catch { }
'@
        $mWf = [regex]::Match($outText, '(?m)^[ \t]*Add-Type\s+-AssemblyName\s+System\.Windows\.Forms')
        if ($mWf.Success) { $outText = $outText.Insert($mWf.Index, $dpiHead + "`r`n") }
        $t4 = $null; $e4 = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($outText, [ref]$t4, [ref]$e4)
        if ($e4 -and $e4.Count -gt 0) {
            $outText = $beforeDark
            $darkNote = "失败已回退（解析错误：$($e4[0].Message)）"
        } else {
            $darkNote = "成功：已挂载 DPI 防裁切、浅/深色无闪白与深色动态事件拦截（目标窗体 $formVar）"
        }
    }
}

if ($ok) {
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Out, $outText, $utf8Bom)
} else {
    Copy-Item -LiteralPath $Source -Destination $Out -Force
    $script:parseErrs = @($e2 | Select-Object -First 5 | ForEach-Object { "  第 $($_.Extent.StartLineNumber) 行: $($_.Message)" })
}

# ---------- 报告 ----------
Add-Rep ""
Add-Rep "==== Edge Debloater 中文化 · 翻译报告 ===="
Add-Rep ("时间        : " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Rep ("源脚本      : $Source")
Add-Rep ("  大小/哈希 : " + (Get-Item $Source).Length + " bytes / " + $srcSha.Substring(0, 16))
Add-Rep ("词库        : $Map  (exact 条目 $exactCount, 规则 $($rules.Count))")
Add-Rep ("输出        : $Out  (" + $(if ($ok) { 'UTF-8 with BOM' } else { '原文（自检失败，未翻译）' }) + ")")
Add-Rep ("自检        : " + $(if ($ok) { '通过' } else { '失败 → 已回退为原文，请检查词库正则' }))
if (-not $ok -and $script:parseErrs) { foreach ($pe in $script:parseErrs) { Add-Rep $pe } }
Add-Rep ("悬停注入    : $injectNote")
Add-Rep ("深色注入    : $darkNote")
Add-Rep ("解释覆盖    : $covNote")
Add-Rep ("替换统计    : exact $hitsExact 条 / 规则 $hitsRule 条 / 共 $($edits.Count) 处；安全闸跳过(Name/SubKey/Value/Type) $skippedGuard 处")
Add-Rep ("$PSScriptRoot 出现次数: " + ([regex]::Matches($srcText, '\$PSScriptRoot')).Count + "（若 >1 且用途不是 chrome++.ini，请改用 -InPlace 模式）")
Add-Rep ""
Add-Rep "---- 逐条替换（行号 / 原文 → 译文）----"
foreach ($e in ($edits | Sort-Object Start)) {
    $one = ($e.Raw -replace '\s+', ' ')
    $two = ($e.Zh -replace '\s+', ' ')
    if ($one.Length -gt 70) { $one = $one.Substring(0, 70) + '…' }
    if ($two.Length -gt 70) { $two = $two.Substring(0, 70) + '…' }
    Add-Rep ("  {0,5}  [{1}] {2}  →  {3}" -f (Get-Line $e.Start), $e.Rule, $one, $two)
}
Add-Rep ""
Add-Rep "---- 待补译清单（$($untranslated.Count) 条，上游改动后可照单补 zh-CN.json）----"
foreach ($u in ($untranslated | Sort-Object Line)) {
    $one = ($u.Raw -replace '\s+', ' ')
    if ($one.Length -gt 90) { $one = $one.Substring(0, 90) + '…' }
    Add-Rep ("  {0,5}  {1}" -f $u.Line, $one)
}

$rep | Set-Content -LiteralPath $Report -Encoding UTF8
Write-Host ""
Write-Host "报告: $Report"
Write-Host $(if ($ok) { "OK 已生成译文" } else { "FAIL 已回退原文" })
