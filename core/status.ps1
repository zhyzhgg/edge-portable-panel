# core\status.ps1 —— 分层：core 层（零 UI 依赖）
#
# 状态采集脚本生成。零 UI 依赖（脚本内容由 Runspace 执行，结果写 status.json）。
# 由 EdgePanel.ps1 搬入，函数体保持原样（move-only）。
# 后台状态采集脚本（按当前 $pkgRoot 动态拼接，切换便携包目录后可重建）
function Build-StatusScript {
    # 路径里若含单引号（如 D:\User's Edge），直接插进下面的单引号字符串会让生成的脚本语法报错；
    # 这里先按 PowerShell 单引号规则把它转义成两个单引号。
    $pk = ([string]$pkgRoot) -replace "'", "''"
    return @"
# 只取以 { 开头的行：子脚本万一往 stderr 写了警告，不能让它污染 JSON（否则整块解析失败）
`$sj = & powershell -NoProfile -ExecutionPolicy Bypass -File '$edgeTune' -Action StatusJson -Quiet -Root '$pk' 2>&1 |
      ForEach-Object { [string]`$_ } | Where-Object { `$_ -match '^\s*\{' } | Select-Object -Last 1
`$pv = & powershell -NoProfile -ExecutionPolicy Bypass -File '$cleaner' -Quiet -Root '$pk' 2>&1 | Out-String
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
    `$dDir = Join-Path '$pk' 'Data'
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
            if (`$probe -and `$probe.root -eq '$pk' -and `$probe.lastFp -eq `$lastFp -and `$probe.time) {
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
                    [ordered]@{ root = '$pk'; time = (Get-Date).ToString('s'); lastFp = `$lastFp; tRoot = `$tRoot; tDef = `$tDef; topCnt = `$topCnt; same = `$bkSame } |
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
