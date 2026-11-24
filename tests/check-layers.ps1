#Requires -Version 5.1
<#
  tests\check-layers.ps1 —— 分层守卫（把「分层」从口头约定变成可验证约束）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\check-layers.ps1

  退出码：0 = 全部合规；1 = 有违规

  检查项：
    1. core\ 不得引用任何 UI（例外：Application::DoEvents —— 消息泵，不碰控件）
    2. ui\   不得直接改文件系统或注册表（那是 core/app 的职责）
    3. core\ 不得反向引用 ui\ / app\
    4. dot-source 顺序必须是 core → ui → app
    5. 同一函数名不得出现在两个文件里（搬迁时最常见的错误）
#>
[CmdletBinding()]
param([string]$Repo)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

$script:Fail = 0
function Bad([string]$msg) { Write-Host ('  FAIL  ' + $msg) -ForegroundColor Red; $script:Fail++ }
function Good([string]$msg) { Write-Host ('  OK    ' + $msg) -ForegroundColor Green }
function Info([string]$msg) { Write-Host ('        ' + $msg) -ForegroundColor DarkGray }

function Get-Files([string]$sub) {
    $d = Join-Path $Repo $sub
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -Filter '*.ps1' -File | Sort-Object Name)
}

# 命中行（排除注释行，避免把说明文字当成违规）
function Find-In([string]$file, [string]$pattern) {
    $hits = @()
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match $pattern) { $hits += [pscustomobject]@{ Line = $n; Text = $line.Trim() } }
    }
    return $hits    # 单元素会被展开，调用处必须用 @() 收拢（否则 .Count 为 $null 导致漏报）
}

Write-Host ''
Write-Host '==== 分层守卫 ====' -ForegroundColor Cyan
Write-Host ('仓库: ' + $Repo)

# ---------- 1. core 不得引用 UI ----------
Write-Host ''
Write-Host '[1] core\ 不得引用 UI' -ForegroundColor DarkCyan
$coreFiles = Get-Files 'core'
if ($coreFiles.Count -eq 0) { Bad '找不到 core\ 目录 —— 守卫无法生效，请检查 -Repo 或目录结构' }
$uiPatterns = [ordered]@{
    '控件窗体 $form'         = '\$form\b'
    'WinForms'               = 'System\.Windows\.Forms\.'
    '主题色 $clrXxx'         = '\$clr[A-Z]'
    'System.Drawing'         = 'System\.Drawing'
    '弹窗调用 Show-Dialog'   = 'Show-Dialog'
    '状态标签 $valXxx'       = '\$val[A-Z]'
    '按钮引用 $btnXxx'       = '\$btn[A-Z]'
    '提示标签 $lbl'          = '\$lbl\w*'
}
foreach ($cf in $coreFiles) {
    foreach ($k in $uiPatterns.Keys) {
        $hits = @(Find-In $cf.FullName $uiPatterns[$k])
        if ($hits.Count -gt 0) {
            Bad ($cf.Name + ' 出现「' + $k + '」(' + $hits.Count + ' 处)，例如 L' + $hits[0].Line + ': ' + $hits[0].Text)
        }
    }
}
if ($script:Fail -eq 0 -and $coreFiles.Count -gt 0) { Good ('core\ ' + $coreFiles.Count + ' 个文件均无 UI 引用') }
Info 'core 通过 Set-UiPump 注入消息泵，不再直接引用 WinForms（无头环境也不会崩）'

# ---------- 2. ui 不得改文件系统 / 注册表 ----------
Write-Host ''
Write-Host '[2] ui\ 不得直接改文件系统或注册表' -ForegroundColor DarkCyan
$uiFiles = Get-Files 'ui'
if ($uiFiles.Count -eq 0) { Bad '找不到 ui\ 目录 —— 守卫无法生效' }
else {
    $before = $script:Fail
    $fsPatterns = @(
        'Remove-Item', 'Move-Item', 'Copy-Item', 'New-Item\s+-ItemType\s+Directory',
        'reg(\.exe)?\s+import', 'Set-ItemProperty', 'New-ItemProperty',
        'Invoke-Packer', 'Invoke-Ps\b'
    )
    foreach ($uf in $uiFiles) {
        foreach ($p in $fsPatterns) {
            $hits = @(Find-In $uf.FullName $p)
            if ($hits.Count -gt 0) {
                Bad ($uf.Name + ' 出现「' + $p + '」(' + $hits.Count + ' 处)，例如 L' + $hits[0].Line + ': ' + $hits[0].Text)
            }
        }
    }
    if ($script:Fail -eq $before) { Good ('ui\ ' + $uiFiles.Count + ' 个文件均不碰文件系统与注册表') }
}

# ---------- 3. core 不得反向引用 ui / app ----------
Write-Host ''
Write-Host '[3] core\ 不得反向引用 ui\ 或 app\' -ForegroundColor DarkCyan
$before = $script:Fail
foreach ($cf in $coreFiles) {
        $hits = @(Find-In $cf.FullName '(?i)(\.\s*\(Join-Path[^\)]*)(ui|app)\\' )
    if ($hits.Count -gt 0) {
        Bad ($cf.Name + ' 反向引用了上层：L' + $hits[0].Line + ': ' + $hits[0].Text)
    }
}
if ($script:Fail -eq $before) { Good 'core\ 无反向引用' }

# ---------- 4. dot-source 顺序 ----------
Write-Host ''
Write-Host '[4] dot-source 顺序 core → ui → app' -ForegroundColor DarkCyan
$entry = Join-Path $Repo 'EdgePanel.ps1'
if (-not (Test-Path -LiteralPath $entry)) { Bad '找不到 EdgePanel.ps1 —— 守卫无法生效' }
else {
    $order = @()
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $entry -Encoding UTF8)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match "Join-Path\s+\`$scriptsDir\s+'(core|ui|app)\\") { $order += [pscustomobject]@{ Layer = $matches[1]; Line = $n } }
    }
    $rank = @{ core = 0; ui = 1; app = 2 }
    $prev = -1; $prevLayer = ''
    $bad = $false
    foreach ($o in $order) {
        $r = $rank[$o.Layer]
        if ($r -lt $prev) { Bad ('顺序错误：L' + $o.Line + ' 的 ' + $o.Layer + '\ 出现在 ' + $prevLayer + '\ 之后'); $bad = $true }
        $prev = $r; $prevLayer = $o.Layer
    }
    if (-not $bad) { Good ('dot-source 顺序正确（' + $order.Count + ' 处：' + (($order | ForEach-Object { $_.Layer }) -join ' → ') + '）') }
}

# ---------- 5. 函数名不得跨文件重复 ----------
Write-Host ''
Write-Host '[5] 同一函数名不得出现在两个文件里' -ForegroundColor DarkCyan
$seen = @{}
$dup = 0
$all = @()
$all += $coreFiles
$all += $uiFiles
$all += @(Get-ChildItem -LiteralPath $Repo -Filter '*.ps1' -File | Where-Object { $_.Name -notin @('build.ps1') })
foreach ($pf in ($all | Sort-Object FullName -Unique)) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($pf.FullName, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $key = $fn.Name
        if ($seen.ContainsKey($key)) {
            if ($seen[$key] -ne $pf.Name) {
                Bad ('函数 ' + $key + ' 同时定义在 ' + $seen[$key] + ' 与 ' + $pf.Name)
                $dup++
            }
        } else { $seen[$key] = $pf.Name }
    }
}
if ($dup -eq 0) { Good ('无重复定义（共扫描 ' + $seen.Count + ' 个函数名）') }

# ---------- 6. 磁盘/注册表操作不得用空 catch ----------
Write-Host ''
Write-Host '[6] 磁盘 / 注册表操作不得使用空 catch（失败必须可见）' -ForegroundColor DarkCyan
$riskyOps = '^(Remove-Item|Move-Item|Copy-Item|Rename-Item|Set-Content|Add-Content|New-Item|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|reg)$'
$scanFiles = @()
$scanFiles += $coreFiles
$scanFiles += $uiFiles
foreach ($sub in @('app')) { $scanFiles += Get-Files $sub }
$entryPs1 = Join-Path $Repo 'EdgePanel.ps1'
if (Test-Path -LiteralPath $entryPs1) { $scanFiles += (Get-Item -LiteralPath $entryPs1) }
foreach ($extra in @('EdgeTune.ps1', 'Clean-EdgeCaches.ps1')) {
    $ep = Join-Path $Repo $extra
    if (Test-Path -LiteralPath $ep) { $scanFiles += (Get-Item -LiteralPath $ep) }
}

$silentDisk = 0
foreach ($sf in (@($scanFiles) | Sort-Object FullName -Unique)) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($sf.FullName, [ref]$null, [ref]$null)
    foreach ($tryAst in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
        $hasRisky = $false
        foreach ($ca in $tryAst.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cn = $ca.GetCommandName()
            if ($cn -and $cn -match $riskyOps) { $hasRisky = $true; break }
        }
        # 补 .NET 静态文件/注册表操作：CommandAst 查不到 [IO.File]::WriteAllText 这类调用，
        # 而它们同样会因空 catch 把失败静默吞掉（core\pkg.ps1 的 Save-LastPkgRoot 就曾是漏网之鱼）。
        if (-not $hasRisky) {
            $dotnetWrite = '^(WriteAllText|WriteAllLines|AppendAllText|Delete|Move|Copy|CreateDirectory)$'   # SetValue 多为反射赋值，不列入
            foreach ($m in $tryAst.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                $mn = [string]$m.Member
                if ($mn -and $mn -match $dotnetWrite) { $hasRisky = $true; break }
            }
        }
        if (-not $hasRisky) { continue }
        foreach ($c in $tryAst.CatchClauses) {
            if ($c.Body.Statements.Count -eq 0) {
                Bad ($sf.Name + ':' + $tryAst.Extent.StartLineNumber + ' 磁盘/注册表操作用了空 catch —— 失败会被静默吞掉')
                $silentDisk++
            }
        }
    }
}
if ($silentDisk -eq 0) { Good '无「磁盘操作 + 空 catch」组合' }

# ---------- 汇总 ----------
Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host '==== 分层守卫：全部通过 ====' -ForegroundColor Green
    exit 0
}
Write-Host ('==== 分层守卫：' + $script:Fail + ' 处违规 ====') -ForegroundColor Red
exit 1