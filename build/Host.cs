using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyTitle("EdgePanel")]
[assembly: AssemblyDescription("便携 Edge 一体化运维面板")]
[assembly: AssemblyProduct("便携 Edge 面板")]
[assembly: AssemblyCompany("EdgePanel")]
[assembly: AssemblyVersion("1.3.6.0")]
[assembly: AssemblyFileVersion("1.3.6.229")]
[assembly: AssemblyInformationalVersion("v1.3.6")]

// 便携 Edge 面板 —— 单文件 EXE 宿主
// 职责：把内嵌资源解包到「用户目录」%LOCALAPPDATA%\\EdgePanel\\<版本>\\（包根保持干净，不释放 .runtime），
//       再用「无窗口」方式启动 powershell.exe 跑 EdgePanel.ps1。不引用 PowerShell 引擎，避免版本/加载歧义。
// 可用环境变量 EP_RUNTIME 覆盖运行时根（测试版隔离用）。
internal static class Host
{
    // 资源版本号：内容变了就改这里，触发重新解包
    private const string ResourceVersion = "2026-11-21.229";   // 解包目录键（每次改内容 -Bump）
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
            bool allowed = full.StartsWith(defRoot.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)
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
            baseDir = PrepareAndExtract(runtimeRoot);
            _runtimeRoot = runtimeRoot;
        }
        catch (Exception ex1)
        {
            WriteLog("extract failed: " + ex1.Message);
            // winexe 静默退出会让"双击没反应"——弹窗说明原因与日志位置
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "便携 Edge 面板启动失败：无法创建运行时目录。\r\n\r\n" +
                    "原因（概要）：" + Truncate(ex1.Message, 200) + "\r\n\r\n" +
                    "详细日志：" + runtimeRoot + "\\logs\\",
                    "便携 Edge 面板", System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error);
            }
            catch { }
            return 2;
        }

        // _earlyLog（7zr 解包被跳过等原因）落盘：此前只写内存从未读出
        if (_earlyLog.Length > 0) WriteLog(_earlyLog.ToString());

        string mainScript = Path.Combine(baseDir, "EdgePanel.ps1");
        if (!File.Exists(mainScript))
        {
            WriteLog("main script missing: " + mainScript);
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "便携 Edge 面板启动失败：主脚本缺失（" + mainScript + "）。\r\n\r\n" +
                    "请重新覆盖安装 Edge面板.exe。", "便携 Edge 面板",
                    System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
            }
            catch { }
            return 3;
        }

        Environment.SetEnvironmentVariable("EP_APPDIR", baseDir);
        Environment.SetEnvironmentVariable("EP_EXEDIR", exeDir);
        // 面板自更新需要知道"当前正在运行的 EXE 是哪一份"（用户可能把它改名成 EdgePanel.exe）
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
            // 子进程是 Windows PowerShell，输出按系统 ANSI 代码页（中文机 = GBK）编码；
            // 用 Encoding.Default 解码才能拿到正确中文，日志再以 UTF-8 写盘。
            StandardOutputEncoding = Encoding.Default,
            StandardErrorEncoding = Encoding.Default
        };

        try
        {
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
    }

    private static string Truncate(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return s;
        return s.Length <= max ? s : s.Substring(0, max) + "…";
    }

    // 准备运行时目录：建目录 → 解包当前版本（带完成标记，避免重复覆写）→ 清掉旧版本
    private static string PrepareAndExtract(string runtimeRoot)
    {
        if (!Directory.Exists(runtimeRoot)) Directory.CreateDirectory(runtimeRoot);

        string baseDir = Path.Combine(runtimeRoot, ResourceVersion);
        // 完成标记：上一次解包成功则跳过——双开第二实例 / Defender 扫描 7zr 时
        // 覆写会抛 IOException，曾经被误判成"目录不可写"而静默分裂回退
        string marker = Path.Combine(baseDir, ".extracted");
        if (!(File.Exists(marker) && File.Exists(Path.Combine(baseDir, "EdgePanel.ps1"))))
        {
            ExtractAll(baseDir);
            try { File.WriteAllBytes(marker, new byte[0]); } catch { }
        }
        else if (!File.Exists(Path.Combine(baseDir, @"tools\7zr.exe")))
        {
            // 标记在但 7zr 缺失（杀软拦截或事后删除）→ 只补解包 7zr，兑现
            // "重启面板自动恢复"的承诺；不覆写其它已存在文件
            try
            {
                string res = "app/tools/7zr.exe";
                Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(res);
                if (s != null)
                {
                    using (s)
                    using (var fs = new FileStream(Path.Combine(baseDir, @"tools\7zr.exe"), FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        s.CopyTo(fs);
                    }
                    Append(_earlyLog, "7zr.exe was missing, re-extracted");
                }
            }
            catch (Exception ex) { Append(_earlyLog, "7zr re-extract failed: " + ex.Message); }
        }
        PruneOldVersions(runtimeRoot, ResourceVersion);
        return baseDir;
    }

    private static void Append(StringBuilder sb, string line)
    {
        lock (sb) { sb.AppendLine(line); }
    }

    // 只删「版本目录」，logs / cache 这些兄弟目录不能碰
    private static void PruneOldVersions(string runtimeRoot, string current)
    {
        try
        {
            if (!Directory.Exists(runtimeRoot)) return;
            foreach (string dir in Directory.GetDirectories(runtimeRoot))
            {
                string name = Path.GetFileName(dir);
                if (string.Equals(name, current, StringComparison.OrdinalIgnoreCase)) continue;
                if (!Regex.IsMatch(name, @"^\d{4}-\d{2}-\d{2}\.\d+$")) continue;   // 只认版本号命名的目录
                try { Directory.Delete(dir, true); } catch { }
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
            if (!name.StartsWith("app/", StringComparison.Ordinal)) continue;
            string rel = name.Substring(4).Replace('/', '\\');
            string dest = Path.Combine(baseDir, rel);
            string dir = Path.GetDirectoryName(dest);
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

            // 7zr.exe 单独容错：杀软常拦它；拦截只影响备份功能，不应让面板起不来
            try
            {
                using (Stream s = asm.GetManifestResourceStream(name))
                {
                    if (s == null) continue;
                    using (var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        s.CopyTo(fs);
                    }
                }
            }
            catch (Exception ex)
            {
                if (rel.EndsWith("7zr.exe", StringComparison.OrdinalIgnoreCase))
                {
                    Append(_earlyLog, "7zr extract skipped (AV lock?): " + ex.Message);
                }
                else { throw; }   // 非 7zr 的资源解包失败仍要抛出（走正常的回退路径）
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
