# ui\log-view.ps1 —— 把日志渲染到 RichTextBox（界面层）
#
# 分层约定：
#   · 依赖 core\log.ps1 提供的 Set-LogSink / Write-Log；本文件只做渲染与节流。
#   · 依赖已创建的 $log（RichTextBox）与主题色 $clrMuted / $clrLogText / $clrBad / $clrGo。
#   · 因此本文件必须在 $log 创建之后 dot-source（见 EdgePanel.ps1 相应位置）。
#   · 颜色映射留在这里：core 只报级别（ok/warn/err/info），不关心颜色。

$script:logQueue = $null      # ConcurrentQueue，写入端可能是后台线程
$script:logTimer = $null
$script:draining = $false

function Get-LogRowColor([string]$level) {
    # 级别列着色（全部复用现有色板）：warn 按用户要求用红色 $clrBad
    switch ($level) { 'ok' { $clrGo } 'warn' { $clrBad } 'err' { $clrBad } default { $clrMuted } }
}

function Append-LogRow($row) {
    if (-not $log -or $log.IsDisposed) { return }
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = $clrMuted
    $log.AppendText($row.Time + ' │ ')
    $log.SelectionColor = (Get-LogRowColor $row.Level)
    $log.AppendText($row.Tag)
    $log.SelectionColor = $clrMuted
    $log.AppendText(' │ ')
    $log.SelectionColor = $clrLogText
    $log.AppendText($row.Text + "`r`n")
}

function Drain-LogQueue {
    # 空 ConcurrentQueue 同样是「假值」，判存在必须显式比 null
    if ($script:draining -or ($null -eq $script:logQueue) -or $script:logQueue.IsEmpty) { return }
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

# ---- 注册接收器：core 的每一行日志在这里变成界面行 ----
Set-LogSink {
    param($row)
    if ($null -ne $script:logQueue) { $script:logQueue.Enqueue($row); return }
    Append-LogRow $row
}

# 队列在这里初始化：$log 已创建，且之后的日志都走队列
Initialize-LogPump
