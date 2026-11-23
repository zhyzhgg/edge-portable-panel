using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyTitle("EdgePanel")]
[assembly: AssemblyDescription("便携 Edge 一体化运维面板")]
[assembly: AssemblyProduct("便携 Edge 面板")]
[assembly: AssemblyCompany("EdgePanel")]
[assembly: AssemblyVersion("1.3.6.0")]
[assembly: AssemblyFileVersion("1.3.6.266")]
[assembly: AssemblyInformationalVersion("v1.3.6")]

// 便携 Edge 面板 —— 单文件 EXE 宿主
// 职责：把内嵌资源解包到「用户目录」%LOCALAPPDATA%\\EdgePanel\\<版本>\\（包根保持干净，不释放 .runtime），
//       再用「无窗口」方式启动 powershell.exe 跑 EdgePanel.ps1。不引用 PowerShell 引擎，避免版本/加载歧义。
// 可用环境变量 EP_RUNTIME 覆盖运行时根（测试版隔离用）。
internal static class Host
{
    // 资源版本号：内容变了就改这里，触发重新解包
    private const string ResourceVersion = "2026-11-21.266";   // 解包目录键（每次改内容 -Bump）
    private const string ProductVersion = "v1.3.6";   // 必须与 EdgePanel.ps1 的 $script:panelVersion 一致（build.ps1 自动校验）
    private const string FallbackFolderName = "EdgePanel";

    // 本次运行实际使用的运行时根目录（logs/cache 都挂在它下面）
    private static string _runtimeRoot;

    // 单实例：同一个便携包只允许一个面板（两个实例同时更新会互踩 Edge\_old 与新文件）
    private static System.Threading.Mutex _single;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // 把已经打开的面板窗口顶到前面（找不到就返回 false）
    private static bool ActivateExistingPanel()
    {
        IntPtr found = IntPtr.Zero;
        try
        {
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                var sb = new StringBuilder(256);
                GetWindowTextW(h, sb, 256);
                if (sb.ToString().StartsWith("便携 Edge 面板"))
                {
                    found = h;
                    return false;   // 找到就停
                }
                return true;
            }, IntPtr.Zero);
        }
        catch { }
        if (found == IntPtr.Zero) return false;
        try { ShowWindow(found, 9); } catch { }          // SW_RESTORE
        try { SetForegroundWindow(found); } catch { }
        return true;
    }

    [STAThread]
    private static int RunElevatedScript(string scriptPath, string workDir)
    {
        // 仅允许执行本面板运行时目录（%LOCALAPPDATA%\EdgePanel\ 或 EP_RUNTIME）下的 .ps1，防止滥用
        try
        {
            string full = Path.GetFullPath(scriptPath);
            string defRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FallbackFolderName);
            string ovRoot = Environment.GetEnvironmentVariable("EP_RUNTIME");
            string tmpPrefix = Path.Combine(Path.GetTempPath(), "EdgePanel-");
            bool allowed = full.StartsWith(defRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)
                || full.StartsWith(tmpPrefix, StringComparison.OrdinalIgnoreCase)
                || (!string.IsNullOrEmpty(ovRoot) && full.StartsWith(ovRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
            if (!allowed || !full.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase) || !File.Exists(full)) return 5;
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + full + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = (!string.IsNullOrEmpty(workDir) && Directory.Exists(workDir)) ? workDir : Path.GetDirectoryName(full)
            };
            using (var p = Process.Start(psi))
            {
                if (p != null) { p.WaitForExit(); return p.ExitCode; }
            }
            return 0;
        }
        catch { return 6; }
    }

    private static int Main(string[] args)
    {
        // 零蓝窗提权模式：GUI 子系统本身无控制台，提权后再以 CreateNoWindow 拉起 PowerShell，彻底消除蓝窗闪现（跳过单实例 Mutex）
        if (args != null && args.Length >= 2 && string.Equals(args[0], "--elevated-run", StringComparison.OrdinalIgnoreCase))
        {
            string wd = args.Length >= 3 ? args[2] : null;
            return RunElevatedScript(args[1], wd);
        }

        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        // ---- 单实例守卫（必须放在解包之前：避免第二个实例重复解包、重复写日志）----
        // 键按「EXE 所在目录」算：同一个便携包只允许一个面板；把 EXE 拷到另一个包根则是另一个实例。
        // 测试钩子：EP_ALLOW_MULTI=1 时跳过（自测要并发拉起时用）。
        if (Environment.GetEnvironmentVariable("EP_ALLOW_MULTI") != "1")
        {
            string mutexKey;
            try
            {
                using (var sha = System.Security.Cryptography.SHA1.Create())
                {
                    byte[] hb = sha.ComputeHash(Encoding.UTF8.GetBytes(exeDir.TrimEnd('\\').ToLowerInvariant()));
                    var sbKey = new StringBuilder();
                    for (int i = 0; i < 8; i++) sbKey.Append(hb[i].ToString("X2"));
                    mutexKey = sbKey.ToString();
                }
            }
            catch { mutexKey = (exeDir.GetHashCode() & 0x7FFFFFFF).ToString("X8"); }
            bool createdNew;
            try
            {
                _single = new System.Threading.Mutex(true, "Local\\EdgePanel_" + mutexKey, out createdNew);
            }
            catch { createdNew = true; }   // 拿不到互斥体也不该挡住启动
            if (!createdNew)
            {
                bool activated = false;
                for (int i = 0; i < 10 && !activated; i++)   // 新实例可能还在建窗口，最多等 3 秒
                {
                    activated = ActivateExistingPanel();
                    if (!activated) System.Threading.Thread.Sleep(300);
                }
                if (!activated)
                {
                    try
                    {
                        System.Windows.Forms.MessageBox.Show(
                            "这个便携包的面板已经在运行了。\r\n\r\n" +
                            "为避免两个面板同时更新/瘦身把文件写坏，同一便携包只允许开一个。",
                            "便携 Edge 面板", System.Windows.Forms.MessageBoxButtons.OK,
                            System.Windows.Forms.MessageBoxIcon.Information);
                    }
                    catch { }
                }
                return 0;
            }
        }

        // 运行时目录固定放用户目录：包根保持干净（不再释放 .runtime）。
        // EP_RUNTIME 可覆盖（测试版隔离 / 特殊部署用）；不设就落到 %LOCALAPPDATA%\EdgePanel。
        string overrideRoot = Environment.GetEnvironmentVariable("EP_RUNTIME");
        string runtimeRoot = string.IsNullOrEmpty(overrideRoot)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FallbackFolderName)
            : overrideRoot;

        string baseDir = null;
        try
        {
            _runtimeRoot = runtimeRoot;
            baseDir = PrepareSessionDir(runtimeRoot);
        }
        catch (Exception ex1)
        {
            WriteLog("extract failed: " + ex1.Message);
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "便携 Edge 面板启动失败：无法准备临时运行目录。\r\n\r\n" +
                    "原因（概要）：" + Truncate(ex1.Message, 200) + "\r\n\r\n" +
                    "详细日志：" + runtimeRoot + "\\logs\\",
                    "便携 Edge 面板", System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error);
            }
            catch { }
            return 2;
        }

        if (_earlyLog.Length > 0) WriteLog(_earlyLog.ToString());

        try
        {
            string mainScript = Path.Combine(baseDir, "EdgePanel.ps1");
            if (!File.Exists(mainScript))
            {
                WriteLog("main script missing: " + mainScript);
                try
                {
                    System.Windows.Forms.MessageBox.Show(
                        "便携 Edge 面板启动失败：主脚本缺失（" + mainScript + "）。\r\n\r\n" +
                        "请重新覆盖安装 EdgePanel.exe。", "便携 Edge 面板",
                        System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
                }
                catch { }
                return 3;
            }

            Environment.SetEnvironmentVariable("EP_APPDIR", baseDir);
            Environment.SetEnvironmentVariable("EP_EXEDIR", exeDir);
            try { Environment.SetEnvironmentVariable("EP_EXEPATH", Assembly.GetExecutingAssembly().Location); } catch { }
            Environment.SetEnvironmentVariable("EP_RUNTIME", _runtimeRoot);
            Environment.SetEnvironmentVariable("EP_ARGS", string.Join(" ", args));

            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + mainScript + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = baseDir,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.Default,
                StandardErrorEncoding = Encoding.Default
            };

            using (var p = Process.Start(psi))
            {
                var sb = new StringBuilder();
                p.OutputDataReceived += (s, e) => { if (e.Data != null) Append(sb, e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) Append(sb, "[err] " + e.Data); };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                string text = sb.ToString();
                if (text.Length > 0) WriteLog(text);
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            WriteLog("launch failed: " + ex);
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "便携 Edge 面板启动失败：无法启动 PowerShell。\r\n\r\n" + Truncate(ex.Message, 200),
                    "便携 Edge 面板", System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error);
            }
            catch { }
            return 4;
        }
        finally
        {
            // 退出即删整个临时会话目录（程序脚本、JSON 与 7za.exe 不长期留在磁盘）
            if (!string.IsNullOrEmpty(baseDir))
            {
                try { if (Directory.Exists(baseDir)) Directory.Delete(baseDir, true); } catch { }
            }
        }
    }

    private static string Truncate(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return s;
        return s.Length <= max ? s : s.Substring(0, max) + "…";
    }

    // 临时会话目录（%TEMP%\EdgePanel-<pid>-<8hex>\）：程序文件不落 %LOCALAPPDATA%，退出即删，崩溃由下次启动自清
    private static string PrepareSessionDir(string runtimeRoot)
    {
        if (!Directory.Exists(runtimeRoot)) Directory.CreateDirectory(runtimeRoot);
        string tag = Process.GetCurrentProcess().Id.ToString() + "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        string sessionDir = Path.Combine(Path.GetTempPath(), "EdgePanel-" + tag);
        ExtractAll(sessionDir);
        PruneRuntimeAndTemp(runtimeRoot, sessionDir);
        return sessionDir;
    }

    private static void Append(StringBuilder sb, string line)
    {
        lock (sb) { sb.AppendLine(line); }
    }

    // 启动自清：清历史版本目录、超 1 小时临时会话、超 30 天日志、超 1 天 cache 临时文件、超 7 天 _shared 中间产物
    private static void PruneRuntimeAndTemp(string runtimeRoot, string currentSessionDir)
    {
        DateTime now = DateTime.UtcNow;
        // ① 清理 %LOCALAPPDATA%\EdgePanel\ 下的所有旧版本程序目录（2026-xx-xx.NNN），只保留用户状态
        try
        {
            if (Directory.Exists(runtimeRoot))
            {
                foreach (string dir in Directory.GetDirectories(runtimeRoot))
                {
                    string name = Path.GetFileName(dir);
                    if (!Regex.IsMatch(name, @"^\d{4}-\d{2}-\d{2}\.\d+$")) continue;
                    try { Directory.Delete(dir, true); } catch { }
                }
            }
        }
        catch { }

        // ② 清扫 %TEMP%\EdgePanel-* 超过 1 小时的崩溃残留
        try
        {
            string tmpRoot = Path.GetTempPath();
            foreach (string dir in Directory.GetDirectories(tmpRoot, "EdgePanel-*"))
            {
                if (string.Equals(dir.TrimEnd('\\'), currentSessionDir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    if ((now - Directory.GetLastWriteTimeUtc(dir)).TotalHours >= 1.0)
                    {
                        // 同机可能同时开着多个面板实例（各管不同便携包），别把还在跑的实例的会话删了
                        bool inUse = false;
                        Match pm = Regex.Match(Path.GetFileName(dir), @"^EdgePanel-(\d+)-");
                        if (pm.Success)
                        {
                            int otherPid;
                            if (int.TryParse(pm.Groups[1].Value, out otherPid))
                            {
                                try { Process.GetProcessById(otherPid); inUse = true; } catch { inUse = false; }
                            }
                        }
                        if (!inUse) Directory.Delete(dir, true);
                    }
                }
                catch { }
            }
        }
        catch { }

        // ③ logs\host-*.log 保留最近 30 天
        try
        {
            string logDir = Path.Combine(runtimeRoot, "logs");
            if (Directory.Exists(logDir))
            {
                foreach (string f in Directory.GetFiles(logDir, "host-*.log"))
                {
                    try { if ((now - File.GetLastWriteTimeUtc(f)).TotalDays >= 30.0) File.Delete(f); } catch { }
                }
            }
        }
        catch { }

        // ④ cache\*.tmp.* 超过 1 天清理
        try
        {
            string cacheDir = Path.Combine(runtimeRoot, "cache");
            if (Directory.Exists(cacheDir))
            {
                foreach (string f in Directory.GetFiles(cacheDir, "*.tmp.*"))
                {
                    try { if ((now - File.GetLastWriteTimeUtc(f)).TotalDays >= 1.0) File.Delete(f); } catch { }
                }
            }
        }
        catch { }

        // ⑤ _shared\ 翻译中间产物超过 7 天清理
        try
        {
            string sharedDir = Path.Combine(runtimeRoot, "_shared");
            if (Directory.Exists(sharedDir))
            {
                foreach (string f in Directory.GetFiles(sharedDir, "*", SearchOption.AllDirectories))
                {
                    try { if ((now - File.GetLastWriteTimeUtc(f)).TotalDays >= 7.0) File.Delete(f); } catch { }
                }
            }
        }
        catch { }
    }

    private static void ExtractAll(string baseDir)
    {
        if (!Directory.Exists(baseDir)) Directory.CreateDirectory(baseDir);

        Assembly asm = Assembly.GetExecutingAssembly();
        foreach (string name in asm.GetManifestResourceNames())
        {
            bool isDeflate = name.StartsWith("appz/", StringComparison.Ordinal);
            bool isRaw = !isDeflate && name.StartsWith("app/", StringComparison.Ordinal);
            if (!isDeflate && !isRaw) continue;
            string rel = name.Substring(isDeflate ? 5 : 4).Replace('/', '\\');
            string dest = Path.Combine(baseDir, rel);
            string dir = Path.GetDirectoryName(dest);
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

            // 7za.exe 单独容错：杀软拦截只影响备份功能，不应让面板起不来
            try
            {
                using (Stream s = asm.GetManifestResourceStream(name))
                {
                    if (s == null) continue;
                    using (var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        if (isDeflate)
                        {
                            using (var ds = new DeflateStream(s, CompressionMode.Decompress))
                            {
                                ds.CopyTo(fs);
                            }
                        }
                        else
                        {
                            s.CopyTo(fs);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                if (rel.EndsWith("7za.exe", StringComparison.OrdinalIgnoreCase) || rel.EndsWith("7zr.exe", StringComparison.OrdinalIgnoreCase))
                {
                    Append(_earlyLog, "packer extract skipped (AV lock?): " + ex.Message);
                }
                else { throw; }
            }
        }
    }

    private static readonly StringBuilder _earlyLog = new StringBuilder();

    private static void WriteLog(string text)
    {
        try
        {
            string root = _runtimeRoot;
            if (string.IsNullOrEmpty(root))
            {
                root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    FallbackFolderName);
            }
            string dir = Path.Combine(root, "logs");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, "host-" + DateTime.Now.ToString("yyyyMMdd") + ".log");
            File.AppendAllText(file,
                "===== " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " =====\r\n" + text + "\r\n",
                Encoding.UTF8);
        }
        catch { }
    }
}
