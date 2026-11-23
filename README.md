# 便携 Edge 面板（EdgePanel）

面向 Windows 用户的**便携版 Microsoft Edge 一键部署与运维面板**——单文件 EXE，双击即用，零外部依赖。  
将 `EdgePanel.exe` 放入任意空目录并点击「更新并瘦身」，即可自动完成下载、解压、微软签名校验、结构比对与瘦身；已有便携包用户将其放入包根目录即可接管日常瘦身、清理、加密备份恢复、策略管理与版本更新。

> 个人开源维护工具，与 Microsoft 及上游便携打包项目无隶属关系。瘦身会删除程序目录内的非核心组件，策略会修改浏览器行为，请按需使用、风险自负。

## 核心能力矩阵

| 模块 | 能力说明 |
|---|---|
| **一键部署** | 空目录放入单文件 `EdgePanel.exe` → 点击「更新并瘦身」，自动拉取上游[便携版 Microsoft Edge](https://github.com/bibicadotnet/edge-portable-chrome-next-mini/)、铺开 `Edge\` 目录并补齐根部 `msedge_proxy.exe`（保障 PWA/站点应用快捷方式可用） |
| **一键瘦身** | 裁撤约 380 项非核心组件（多余语言包、Copilot 外壳、更新与通知链、遥测日志、诊断模板）并关闭组件更新；上游包解出约 976.7 MB → 瘦身后程序目录约 555 MB（105 个文件），核心运行文件一律保留 |
| **缓存清理** | 精准清理 Edge 不会自动回收的可再生缓存（GPU/着色器、WebView2 图形缓存、崩溃转储、诊断指标与日志、站点统计库等）；书签、密码、历史、登录态、Cookies、扩展本体等保护名单明确排除、绝不触碰；清理后还会列出「剩余体积构成 Top 5」，并把扩展占用（翻译成扩展名）与站点数据（按域名归并）各下钻 Top 5，逐项说明为什么不动它们 |
| **加密备份 / 恢复** | 清理后调用内置 7za 打包 `Data\`（默认 AES 加密 + `-mhe=on` 隐藏文件名），支持 `7za t` 完整性校验；备份弹窗有两个独立可选项：**面板本体**（约 +1 MB，默认勾选，换机解压双击即可就地拉取 Edge）与**Edge 本体 `Edge\`**（约 +218 MB，离线换机用）；一键恢复内置 5 道护栏（只读校验、动态空间预检、关 Edge 前置、同盘临时目录原子切换、失败自动回滚），且不会覆盖本机正在用的面板 |
| **策略管理** | 内置 129 条主策略 + 2 条子键项（另含 1 条清理失效旧值条目），写入独立隔离键 `HKCU\SOFTWARE\Policies\Microsoft\Edge_Portable`，不污染系统标准 Edge；附带中文策略管理 GUI 与策略漂移体检 |
| **更新 Edge 本体** | 多镜像实测测速 → 断点续传下载 → 必需件与微软数字签名预检 → 上游结构漂移比对 → `Edge\_old\` 改名暂存 → 异步解压与覆盖 → 复核通过后删旧，任何步骤失败自动回滚 |
| **面板自更新** | 启动 6 秒后后台静默探测（优先 `releases/latest` 302 重定向，零 GitHub API 配额消耗）；发现新版后顶栏按钮变绿并提示，校验 SHA256 后由独立助手进程在面板退出后完成替换与自动重启，失败自动从 `.old` 还原并拉起旧版 |

## 快速开始（3 步）

1. **下载面板**：前往本仓库 [Releases](https://github.com/zhyzhgg/edge-portable-panel/releases) 下载最新 `EdgePanel.exe` 与 `SHA256SUMS.txt`（可选校验）。
2. **放置位置（任选其一）**：
   - **空目录全新部署**：新建一个不含特殊权限限制的文件夹（如 `D:\Edge_Portable\`），只放入 `EdgePanel.exe`，双击启动后点「检查更新」→「更新并瘦身」，自动装出一套可直接运行的便携 Edge。
   - **接管已有便携包**：把 `EdgePanel.exe` 直接放进现有便携包根目录（与 `Edge\`、`Data\` 同级），双击启动即可读取当前状态并执行瘦身、清理、备份、策略与更新。
3. **日常维护**：面板自动跟随 Windows 深/浅色模式（也支持环境变量 `EP_THEME=light|dark` 强制指定）；所有运行时脚本与日志均落在 `%LOCALAPPDATA%\EdgePanel\`，便携包根目录保持干净。

## 系统要求与文件校验

- **系统要求**：Windows 10 / Windows 11（64 位），仅依赖系统自带的 **.NET Framework 4.0** 与 **Windows PowerShell 5.1**，无需安装任何运行库或外部模块。
- **SHA256 校验**：下载后可在 PowerShell 中核对哈希是否与 Release 附件 `SHA256SUMS.txt` 一致：

```powershell
Get-FileHash .\EdgePanel.exe -Algorithm SHA256
```

## 杀软误报说明

本工具采用 **C# 单文件自解包宿主 + 拉起 PowerShell 5.1 WinForms** 架构，内置官方 7-Zip `7za.exe` 且带有自更新替换逻辑，属于无数字签名的开源单文件 EXE，容易被部分杀毒软件（如火绒、Windows Defender 等）的通用启发式引擎误判为 `Trojan/Agent.*`。

- 全部源码公开可审，无任何第三方闭源载荷或后台上报。
- 若遇到拦截或误删，请将便携包目录加入杀软信任区并顺手上报误报；也可直接拉取源码在本地运行 `一键编译.bat` 自行编译。

## 更新机制与版本号约定

- **单源版本对齐**：公开仓库的 Release Tag、源码 `EdgePanel.ps1` 的 `$script:panelVersion` 与 `build\Host.cs` 的 `ProductVersion` 严格保持一致（例如 `v1.3.4` ↔ `'1.3.4'` ↔ `"v1.3.4"`），`build.ps1` 编译前自动强校验。
- **同版本号热修说明**：自更新仅比对语义化版本号（`v1.3.4` → `v1.3.5`）。若某次小修以“附件热修”方式直接替换当前 Release 的 `EdgePanel.exe`（未升版本号），已安装同版本号的用户不会收到自动弹窗，需手动重新下载覆盖；正式升级版本号（如发布 `v1.3.5`）后旧版面板会自动探测提示。
- **零配额探测**：版本检查优先走 `releases/latest` 的 302 跳转提取 `Location` 中的 Tag，不消耗 GitHub 匿名 API 配额（60 次/小时），仅在重定向失败时回退至 Release API 与国内镜像代理。
- **源码可能领先发布包**：`main` 上的清理/界面增强先合入源码，随下一次 Release 才进入可下载的 EXE。如需体验最新改动可自行编译，或等待下一次正式发布。

## 已知限制

- 主窗口客户区固定 `870×676`（外形约 `888×723`）紧凑布局，不做 WinForms 自动 DPI 缩放（高分屏如需等比放大，可设置环境变量 `EP_UI_SCALE=1.25`）。
- 深色模式下系统原生 `MessageBox` 弹窗仍保持 Windows 浅色外观（WinForms 平台限制）。
- 仅面向单机单用户本地维护，暂不提供云端多机同步（换机请使用「清理并备份」+「从备份恢复」）。
- 恢复数据或更新本体前必须关闭当前便携包的 Edge 进程（避免 Profile 锁文件占用）。

## 免责声明

- 「瘦身」会删除 `Edge\` 版本目录内约 380 项非核心文件；若后续需要某些被裁功能，可随时点「下载并更新」恢复完整程序文件。
- 「应用推荐策略」会向当前用户隔离键写入 129 条主策略与 2 条子键项（另含 1 条用于清理失效旧值），可能改变自动填充、侧边栏、Copilot 等浏览器默认行为；可随时在「打开策略管理」中逐项调整或一键还原。
- 重要数据请定期执行加密备份并妥善保管密码（密码丢失无法解开加密备份包）。

## 从源码构建（3 步）

1. 下载 [7-Zip Extra](https://www.7-zip.org/download.html)（Public Domain），把包内 **x86 的 `7za.exe`**（约 855 KB）放到仓库 `tools\7za.exe`——它是唯一内置打包器，7z 与 zip 都靠它（zip 用 ZipCrypto 加密，Win10/11 自带解压可直接打开）。
2. 双击 `一键编译.bat`，或在仓库目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

3. `build.ps1` 会自动完成全部 `.ps1` 的 UTF-8 BOM 预检、PowerShell 5.1 语法解析与三方版本号校验，并调用系统自带 `.NET Framework 4.0 csc.exe` 在本目录输出单文件 EXE。

## 发布流程（维护者）

发版请严格遵循**先推源码、再发 Release**，避免 Release 产物与仓库源码脱节：

1. 修改代码并同步版本号：改内容务必递增解包键（`.\build.ps1 -Bump`）；若发新版本，需同步更新 `EdgePanel.ps1` 的 `$script:panelVersion` 与 `build\Host.cs` 的 `ProductVersion`。
2. **中立文件名编译后再复制**（规避杀软拦截 `csc.exe` 直写运行目录）：

```powershell
.\build.ps1 -Bump -Out '%TEMP%\ep_build.exe'
Copy-Item '%TEMP%\ep_build.exe' '<发布暂存目录>\EdgePanel.exe' -Force
Get-FileHash '<发布暂存目录>\EdgePanel.exe' -Algorithm SHA256
```

3. 先提交并推送源码到 `main`（若遇 `schannel` TLS 握手失败，可加 `git -c http.sslBackend=openssl push origin main`）。
4. 创建与 `$script:panelVersion` 一致的 Git Tag（如 `v1.3.5`）并发布 Release，附件固定命名为 **`EdgePanel.exe`** 与 **`SHA256SUMS.txt`**（格式：`<64位十六进制哈希>  EdgePanel.exe`）。

## 工程文档

- [GUI 规范与验收流程](docs/GUI规范_WinForms_v2_2026-11-22.md)：布局栅格、深浅色渲染、长任务异步、机械化验收门槛。
- [踩坑与教训](docs/踩坑与教训_2026-11-22.md)：24 个版本的返工与两次桌面假死复盘，末附一页速查表。
- [同类项目借鉴结论](docs/参考_同类项目_结论_2026-11-23.md)：ChromeDebloater / CentBrowser 等的能力对照，哪些已落地、哪些明确不做。

## 许可

本仓库代码基于 [MIT](LICENSE) 许可开源；第三方组件与上游项目说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
