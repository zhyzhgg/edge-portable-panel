#Requires -Version 5.1
<#
    一键编译 Edge面板.exe（使用 Windows 自带 .NET Framework 4.0 csc.exe，零外部依赖）

    用法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1            # 用当前 ResourceVersion 编译到本目录 Edge面板.exe
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Bump      # 先把末位版本号 +1 再编译（改了源码就用这个）
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Out "<便携包根>\EdgePanel.exe"
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -No7zr     # 仅语法/结构验证，产物不含打包器

    说明：
      · EXE 按 build\Host.cs 里的 ResourceVersion 决定解包目录，改了源码却不改版本号，
        运行时会继续用 %LOCALAPPDATA%\EdgePanel\<旧版本>\ 里的旧副本。
      · 所以改 ps1 后要么加 -Bump，要么手工改 build\Host.cs 里那一行。
#>
[CmdletBinding()]
param(
    [switch]$Bump,
    [switch]$No7zr,      # 明知没有 7zr 也要编译（只做语法/结构验证，产物不能备份）
    [string]$Out,
    [string]$Csc = ''
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$hostCs = Join-Path $src 'build\Host.cs'

# 自动定位系统自带 csc.exe（64 位优先，回退 32 位）
if ([string]::IsNullOrWhiteSpace($Csc)) {
    foreach ($cand in @(
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
    )) {
        if (Test-Path -LiteralPath $cand) { $Csc = $cand; break }
    }
}
if (-not $Csc -or -not (Test-Path -LiteralPath $Csc)) { throw "找不到 .NET Framework 4.0 csc.exe，请通过 -Csc 指定路径" }
if (-not (Test-Path -LiteralPath $hostCs)) { throw "找不到 Host.cs：$hostCs" }

# ---- 需要内嵌的资源清单 ----
$resources = [ordered]@{
    'EdgePanel.ps1'                        = 'app/EdgePanel.ps1'
    '_Common.ps1'                          = 'app/_Common.ps1'
    'EdgeTune.ps1'                         = 'app/EdgeTune.ps1'
    'Clean-EdgeCaches.ps1'                 = 'app/Clean-EdgeCaches.ps1'
    'zh-debloater\run-zh.ps1'              = 'app/zh-debloater/run-zh.ps1'
    'zh-debloater\translate.ps1'           = 'app/zh-debloater/translate.ps1'
    'zh-debloater\zh-CN.json'              = 'app/zh-debloater/zh-CN.json'
    'zh-debloater\policy-hints.json'       = 'app/zh-debloater/policy-hints.json'
    'EdgePolicyBaseline.json'              = 'app/EdgePolicyBaseline.json'
}

# 内置 7zr.exe：备份 / 恢复 / 校验都靠它，缺了就是"半残 EXE"，默认强制要求
$sevenZr = Join-Path $src 'tools\7zr.exe'
if (Test-Path -LiteralPath $sevenZr) {
    $resources['tools\7zr.exe'] = 'app/tools/7zr.exe'
} elseif ($No7zr) {
    Write-Warning '按 -No7zr 跳过打包器：产物不能备份/恢复，仅供语法验证'
} else {
    throw ("缺少打包器：$sevenZr`n" +
        "  面板靠它做备份与恢复，缺了会变成'半残 EXE'。`n" +
        "  获取：从原仓库 tools\ 拷入，或从 https://www.7-zip.org/a/7zr.exe 下载（7-Zip 官方，public domain）放到 tools\ 后重试。`n" +
        "  确实只想验证编译：加 -No7zr。")
}

# ---- 预检：文件存在 + .ps1 必须带 UTF-8 BOM + PowerShell 语法解析 ----
foreach ($rel in $resources.Keys) {
    $p = Join-Path $src $rel
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少资源文件：$p" }
    if ($rel -like '*.ps1') {
        $bytes = [System.IO.File]::ReadAllBytes($p)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            throw "编码错误（缺少 UTF-8 BOM，PS 5.1 会把中文读成乱码）：$rel"
        }
        # 只允许一个 BOM：补 BOM 时重复写入会让 PS 5.1 把第二个 BOM 当成命令名，每次启动刷一行报错
        if ($bytes.Length -ge 6 -and $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF) {
            throw "编码错误（UTF-8 BOM 重复，文件头有两个 BOM）：$rel"
        }
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            $first = $errs[0]
            throw ("PowerShell 语法错误（" + $rel + " 第 " + $first.Extent.StartLineNumber + " 行）：" + $first.Message)
        }
    }
}
Write-Host '预检通过：全部 .ps1 均为 UTF-8 BOM 且语法无误' -ForegroundColor DarkGray

# ---- 版本号 + 单源一致性校验（B7）----
$text = [System.IO.File]::ReadAllText($hostCs, [System.Text.Encoding]::UTF8)
$epText = [System.IO.File]::ReadAllText((Join-Path $src 'EdgePanel.ps1'), [System.Text.Encoding]::UTF8)
$mEpVer = [regex]::Match($epText, '\$script:panelVersion\s*=\s*''([^'']+)''')
$mHostVer = [regex]::Match($text, 'ProductVersion\s*=\s*"([^"]+)"')
if (-not $mEpVer.Success -or -not $mHostVer.Success) { throw '版本号校验失败：未能同时读出 EdgePanel.ps1 的 $script:panelVersion 与 Host.cs 的 ProductVersion' }
if (('v' + $mEpVer.Groups[1].Value) -ne $mHostVer.Groups[1].Value) {
    throw ("版本号不一致：EdgePanel.ps1 为 v" + $mEpVer.Groups[1].Value + "，Host.cs 为 " + $mHostVer.Groups[1].Value + "，请先对齐后再编译")
}
$m = [regex]::Match($text, 'ResourceVersion\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw 'Host.cs 里没找到 ResourceVersion' }
$old = $m.Groups[1].Value
$new = $old
if ($Bump) {
    $parts = $old -split '\.'
    $last = [int]$parts[-1]
    $parts[-1] = [string]($last + 1)
    $new = ($parts -join '.')
    $text = $text.Replace('ResourceVersion = "' + $old + '"', 'ResourceVersion = "' + $new + '"')
    [System.IO.File]::WriteAllText($hostCs, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("版本号：{0} → {1}" -f $old, $new) -ForegroundColor Yellow
} else {
    Write-Host ("版本号：{0}（未变动）" -f $old) -ForegroundColor DarkGray
}

# ---- 输出路径（默认本目录 Edge面板.exe，不写死个人盘符）----
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $src 'Edge面板.exe' }
$dir = Split-Path $Out -Parent
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# ---- 编译 ----
$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    '/r:System.Windows.Forms.dll',
    ('/out:' + $Out)
)
foreach ($rel in $resources.Keys) {
    $cscArgs += ('/resource:' + (Join-Path $src $rel) + ',' + $resources[$rel])
}
$cscArgs += $hostCs

& $Csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw ("编译失败（csc 退出码 $LASTEXITCODE）") }

$f = Get-Item -LiteralPath $Out
Write-Host ''
Write-Host ("编译完成：{0}" -f $f.FullName) -ForegroundColor Green
Write-Host ("  {0:N0} 字节 / {1}" -f $f.Length, $f.LastWriteTime) -ForegroundColor Gray
Write-Host ''
Write-Host '提示：把编译好的 Edge面板.exe 复制到便携包根目录（与 Edge\ 同级）双击即可使用。' -ForegroundColor DarkGray
