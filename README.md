# 便携 Edge 面板（EdgePanel）

面向[便携版 Microsoft Edge](https://github.com/bibicadotnet/edge-portable-chrome-next-mini) 的单文件 Windows 管理面板。

**C# 宿主 + 内嵌 PowerShell 5.1 WinForms，零外部运行时依赖**：一个 `EdgePanel.exe` 双击即用，不需要安装 .NET 之外的任何东西。

> 个人自用工具，与 Microsoft 及任何上游项目无关。瘦身会删除安装目录内的部分文件、策略会改变浏览器行为，**风险自负**。

## 能做什么

| 功能 | 说明 |
|---|---|
| **瘦身** | 删约 380 项无用文件（多余语言包、Copilot 外壳、更新与通知组件、遥测与日志、诊断模板）+ 关闭组件更新；`msedge.exe` / `msedge.dll` 等核心文件一律保留 |
| **缓存清理** | 33 项 Edge 不会自动清理的缓存（GPU/着色器/诊断指标等），9 类明确排除（书签、密码、历史、登录态、扩展本体、语言模型…） |
| **更新本体** | 多镜像测速 → 断点续传下载 → 预检（必需件 + 签名） → `Edge\_old` 暂存 → 覆盖 → 复核 → 删旧；可选「更新并瘦身」 |
| **备份 / 恢复** | 清理后打包 `Data\`（可选加密 + 掩藏文件名），`7zr t` + 全条目加密断言；一键恢复带 5 道护栏（只读校验、动态空间预检、关 Edge 前置、临时目录原子切换、失败回滚） |
| **策略管理** | 130 条推荐策略（隔离在 `HKCU\...\Edge_Portable`，不污染标准分支）+ 中文策略 GUI + 漂移体检 |
| **深色/浅色** | 跟随系统主题，支持 `EP_THEME=light|dark` 强制切换 |

## 编译

1. 把 `7zr.exe`（[7-Zip 官方](https://www.7-zip.org/a/7zr.exe)，public domain）放到 `tools\7zr.exe`；
2. 双击 `一键编译.bat`，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

3. 产物是脚本同目录的 `EdgePanel.exe`。`build.ps1` 会自动校验：全部 `.ps1` 的 UTF-8 BOM、PowerShell 语法、以及版本号单源一致性（`Host.cs` 的 `ProductVersion` 必须等于 `EdgePanel.ps1` 的 `$script:panelVersion`）。

编译需要 Windows 自带的 .NET Framework 4.0 `csc.exe`（无需安装 SDK）。

## 部署

把 `EdgePanel.exe` 放到便携包根目录（与 `Edge\`、`Data\` 同级）双击即可。

> **杀软提示**：本程序是"自解包 + 拉起 PowerShell"的结构，加上自更新会下载并替换自身，容易被启发式引擎误判。若被拦截，请加入信任列表。

## 自更新

面板顶栏有「更新面板」按钮：有新版变绿（文案变「有新版本」），点击后走国内镜像下载并校验 SHA256，再替换自身。

它读取的是**本仓库的 Releases**，源地址写在 `EdgePanel.ps1` 顶部：

```powershell
$script:panelUpdateRepo = '<owner>/<repo>'
```

**公开仓库不需要任何令牌**：查 Release、下载资产都是匿名 HTTPS。

## 校验下载的文件

```powershell
Get-FileHash .\EdgePanel.exe -Algorithm SHA256
```

与 Release 附带的 `SHA256SUMS.txt` 比对。

## 目录结构

```
EdgePanel.ps1              主脚本（UI + 全部业务逻辑）
_Common.ps1                公共函数
EdgeTune.ps1               瘦身
Clean-EdgeCaches.ps1       缓存清理
EdgePolicyBaseline.json    策略基线（130 主 + 2 子）
build\Host.cs              单文件 EXE 宿主（解包到 %LOCALAPPDATA% 后拉起 PowerShell）
build.ps1 / 一键编译.bat    构建
tools\ui-audit.ps1         GUI 几何体检（UI Automation 量控件矩形，判越界/贴边/重叠）
zh-debloater\              策略 GUI 的中文启动器 / 翻译器 / 词库
docs\                      GUI 规范、便携化与原版的差异说明
```

## 已知限制

- 主窗口固定 888×723，**不做 DPI 自动缩放**（坐标按 DPI 手动乘）；
- 深色模式下系统原生 `MessageBox` 仍是浅色（WinForms 平台限制）；
- 恢复数据前必须关闭 Edge（会持有 profile 锁文件）；
- 只支持单机单用户，不支持多机同步（备份上传未实现）。

## 许可

代码：[MIT](LICENSE)。第三方依赖与上游项目见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。