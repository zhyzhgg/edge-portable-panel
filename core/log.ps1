# core\log.ps1 —— 日志发射器（零 UI 依赖）
#
# 分层约定：
#   · 本文件只负责「产生日志」：时间戳、级别、磁盘落盘、块缓冲、分发给接收器。
#   · 不引用任何控件/颜色，所以它可以被无窗体的 -RunOnce 模式与单元测试直接使用。
#   · 界面渲染在 ui\log-view.ps1：它通过 Set-LogSink 注册接收器，并按级别决定颜色。
#   · 未注册接收器时**静默**（只写磁盘）—— 这是安全默认，不是缺陷。

$script:LogSink = $null        # function(row) —— UI 层注册；row = { Time; Level; Tag; Text }
$script:logBlock = $null       # 非空时 Write-Log 先攒到块里，End-LogBlock 再整块吐出（避免并行任务行插队）
$script:logBlockDepth = 0

function Set-LogSink([scriptblock]$sink) {
    # UI 层注册渲染器；传 $null 可注销（测试用）
    $script:LogSink = $sink
}

function Start-LogBlock {
    $script:logBlockDepth++
    if ($null -eq $script:logBlock) { $script:logBlock = New-Object System.Collections.ArrayList }   # 空 ArrayList 是假值，必须判 null
}

function End-LogBlock {
    if ($script:logBlockDepth -gt 0) { $script:logBlockDepth-- }
    # 注意：空 ArrayList 在 PowerShell 里是「假值」，必须显式判 null（否则块永远不生效）
    if ($script:logBlockDepth -gt 0 -or ($null -eq $script:logBlock)) { return }
    $rows = $script:logBlock
    $script:logBlock = $null
    foreach ($r in $rows) {
        if ($script:LogSink) { & $script:LogSink $r }
    }
}

function Write-Log([string]$text, [string]$level = 'info', [switch]$Det) {
    $t = (Get-Date).ToString('HH:mm:ss')
    # 级别必须是「2 个全角汉字」宽：实测雅黑 8.5pt 下「完成/警告/失败/信息」都是 39 px
    $tag = switch ($level) { 'ok' { '完成' } 'warn' { '警告' } 'err' { '失败' } default { '信息' } }
    Write-Host ("$t │ $tag │ $text")     # 磁盘日志：全量保留
    if ($Det) { return }                 # 明细只进日志文件，不上界面
    $row = [pscustomobject]@{ Time = $t; Level = $level; Tag = $tag; Text = $text }
    if ($null -ne $script:logBlock) { [void]$script:logBlock.Add($row); return }
    if ($script:LogSink) { & $script:LogSink $row }
}

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
