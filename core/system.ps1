# ---------------- UI 泵注入 ----------------
# core 层不能直接引用 WinForms：在未加载 System.Windows.Forms 的进程里
# （例如单元测试、纯 PowerShell 宿主）[System.Windows.Forms.Application] 会抛
# "Unable to find type"，导致本文件所有涉及等待的函数直接崩。
# UI 层通过 Set-UiPump 注册；未注册时是空操作 —— 无头环境下只是不再泵消息，功能照常。
$script:UiPump = $null

function Set-UiPump([scriptblock]$pump) { $script:UiPump = $pump }

function Invoke-UiPump {
    if ($script:UiPump) { & $script:UiPump }
}
# core\system.ps1 —— 分层：core 层（零 UI 依赖）
#
# 进程 / 子进程 / 打包器 / 磁盘 / 网络探测。与控件无关；仅用 Application::DoEvents 做消息泵，长操作时保持界面响应。
# 由 EdgePanel.ps1 搬入，函数体保持原样（move-only）。
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
        Invoke-UiPump
    }
    $left = Get-PackageProcs
    if ($left.Count) { Write-Log ('正常关闭超时，强制结束 ' + $left.Count + ' 个残留进程（未保存的网页数据可能丢失）') 'warn'; $left | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
    $n = (Get-PackageProcs).Count
    if ($n -eq 0) { Write-Log '已全部关闭' 'ok'; return $true } else { Write-Log ('还有 ' + $n + ' 个进程没关掉') 'warn'; return $false }
}

function Invoke-Ps([string]$scriptPath, [string[]]$argList) {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $argList
    $out = & $exe @all 2>&1
    return @{ Output = @($out); Code = $LASTEXITCODE }
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
        Invoke-UiPump
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
                for ($w = 0; $w -lt 10; $w++) { Start-Sleep -Milliseconds 50; Invoke-UiPump }
            }
        }
    }
    throw ('目录改名失败（文件被占用或杀毒软件正在扫描，请稍后重试）：' + $lastErr.Exception.Message)
}

function Get-TextQuick([string]$url, [int]$msLimit = 2500) {
    # 单源可中断 GET：BeginGetResponse + 120ms 轮询 + DoEvents，UI 不冻；超时或关窗立即 Abort 并返回空串
    # 注：下面的等待循环与 Get-RedirectLocation 里那段相似，但**刻意不合并**——
    # 本函数要求 HTTP 错误（404 等）抛出后由外层 catch 返回空串；
    # Get-RedirectLocation 则要从 WebException.Response 里取 302 的 Location。错误语义不同，合并会改行为。
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'EdgePanel/' + $script:panelVersion
        $req.Timeout = $msLimit
        $req.ReadWriteTimeout = $msLimit
        $ar = $req.BeginGetResponse($null, $null)
        $wh = $ar.AsyncWaitHandle
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            while (-not $ar.IsCompleted) {
                if ($script:closeRequested -or $sw.ElapsedMilliseconds -ge $msLimit) { try { $req.Abort() } catch { }; return '' }
                [void]$wh.WaitOne(120)
                Invoke-UiPump
            }
            $resp = $req.EndGetResponse($ar)
            if (-not $resp) { return '' }
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose(); $resp.Close() }
        } finally { try { $wh.Close() } catch { } }
    } catch { return '' }
}

function Get-RedirectLocation([string]$url, [int]$msLimit = 2500) {
    # 只取 302 的 Location：不跟跳转、可中断、DoEvents 保活 UI（原实现是同步 GetResponse，最坏 3×8s 冻界面）
    # 注：等待循环与 Get-TextQuick 相似但**刻意不合并**（那边错误要冒泡，这边要读 Exception.Response），原因同上。
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'EdgePanel/' + $script:panelVersion
        $req.AllowAutoRedirect = $false
        $req.Timeout = $msLimit
        $req.ReadWriteTimeout = $msLimit
        $ar = $req.BeginGetResponse($null, $null)
        $wh = $ar.AsyncWaitHandle
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            while (-not $ar.IsCompleted) {
                if ($script:closeRequested -or $sw.ElapsedMilliseconds -ge $msLimit) { try { $req.Abort() } catch { }; return '' }
                [void]$wh.WaitOne(120)
                Invoke-UiPump
            }
            $resp = $null
            try { $resp = $req.EndGetResponse($ar) } catch { $resp = $_.Exception.Response }
            if (-not $resp) { return '' }
            $loc = [string]$resp.Headers['Location']
            try { $resp.Close() } catch { }
            return $loc
        } finally { try { $wh.Close() } catch { } }
    } catch { return '' }
}

function Get-PanelLatestTagRedirect {
    # 用 releases/latest 的 302 重定向拿最新 tag：**不消耗 GitHub API 配额**（匿名 API 只有 60 次/小时，
    # 频繁检查会被 403 限流）。返回原始 tag（如 'v1.3.4'）；失败返回 ''。
    # 与手动更新/启动探测同口径：仅 2 源（已淘汰 ghfast.top），单源 2.5s，UI 全程可响应。
    if ([string]::IsNullOrWhiteSpace($script:panelUpdateRepo)) { return '' }
    $repoSlug = $script:panelUpdateRepo.Trim('/')
    $page = 'https://github.com/' + $repoSlug + '/releases/latest'
    foreach ($u in @($page, ('https://gh-proxy.org/' + $page))) {
        $loc = Get-RedirectLocation $u 2500
        if (-not $loc) { continue }
        $m = [regex]::Match($loc, '/tag/(v?[0-9][0-9A-Za-z\.\-_]*)$')
        if ($m.Success) { return [string]$m.Groups[1].Value }   # 保留原始 tag（含 v），拼下载地址要用原名
    }
    return ''
}
