# 桌面 GUI（WinForms）规范与验收流程 v2（2026-11-22）

> 目的：把"界面错位 / 文字被切 / 长任务假死 / 提示口径混乱"从"靠手感"变成"靠规范与脚本可判定"。  
> 适用：`EdgePanel.exe`（C# 宿主 + 内嵌 PowerShell 5.1 WinForms）及 `zh-debloater` 策略管理窗口。

## 1. 布局栅格与按钮尺寸约定

1. **禁止心算右/底边界**：优先使用容器自动排版；必须绝对定位时，坐标由前置控件 `.Right + gap` / `.Bottom + gap` 推导，卡片内边距与窗口外边距统一按 **12–14 px** 栅格对齐，控件距窗口右/下边留白 `>= 8 px`。
2. **顶栏与分组按钮尺寸约定**：
   - 顶栏功能按钮（如「更新面板」「刷新状态」）按 **4 字宽**（基准 80–84 px）设计，留足内边距确保 `1.25×` 缩放下不截断；
   - 底部两张并排卡片（「缓存与备份」「策略 / 系统集成」）顶行按钮保持**同一水平基线**，视觉齐平；
   - 卡片内三列等宽按钮按统一槽宽与间距均分，避免出现单侧留白不均。
3. **多行文字禁止写死高度**：说明段与弹窗正文统一通过实测高度（`Get-TextHeight` / `TextRenderer.MeasureText`）或按内容累加决定高度；**弹窗不写死 `ClientSize.Height`**。
4. **动态长度文本必须给边界**：顶栏状态/进度提示（`$lblHint`）一律 `AutoSize=$false` + 固定宽度 + `TextAlign='MiddleRight'` + `AutoEllipsis=$true`，严禁向右裸延伸压住按钮。
5. **DPI 策略只许一档**：
   - 主窗口显式 `$form.AutoScaleMode = 'None'`，固定基准外框 `888×723`，通过统一缩放函数 `S()` 响应 `EP_UI_SCALE` / `EP_UI_BASE`（默认 1×，`ui-audit.ps1` 校验 1× 与 1.25× 均 PASS）；
   - 弹窗工厂（`New-DialogBtn`、`New-TextInput` 等）接收已缩放坐标，**禁止内部二次乘 `S()`**。

## 2. GDI+ 渲染与深浅色适配规范

1. **双层填充画圆角边，禁用 1px `Pen` 描边小圆角**：`CardPanel` 与 `FlatBtn` 统一用外层填边框色、内缩 1 px 填底色，配合 `PixelOffsetMode.Half` 杜绝右下边发虚或残缺。
2. **进度条禁用 `SetClip(GraphicsPath)`**：`FlatProgress` 统一用 **8 px 纯整数像素直条**（`SmoothingMode.None` + `FillRectangle`），配 16 ms 缓动插值与 Cubic ease-in-out 不确定态滑块。
3. **双缓冲文字走 7 参 `TextRenderer.DrawText`**：必须传入当前填充底色 `fill` 并上下内缩 2 px，保证 ClearType 锐利不发虚；`FlatBtn` 覆写 `NotifyDefault(false)` 消除默认焦点的 2 px 黑圈。
4. **深浅色跟随与跨提权传递**：
   - 启动时读 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`（支持 `EP_THEME=dark|light` 覆盖）；
   - 窗体启动前设 `Opacity = 0`，`Shown` 事件刷新后切回 `1`，消除深色启动闪白；
   - `HandleCreated` 调 `DwmSetWindowAttribute(hWnd, 20, ...)` 开启 Win11 原生深色标题栏，列表/日志框调 `uxtheme.dll` `DarkMode_Explorer` 适配深色滚动条；
   - 拉起会自行 UAC 提权的策略 GUI 时，将主题写入 `%LOCALAPPDATA%\EdgePanel\cache\ui-theme.json`，注入端按 **文件 → 环境变量 → 系统注册表** 三级回退。
5. **系统原生 `MessageBox` 平台限制**：WinForms 下的 `[System.Windows.Forms.MessageBox]::Show()` 始终使用系统浅色样式，深色模式下无法变黑，属平台固有限制，不强行用钩子魔改。

## 3. 忙碌态与进度文案规范

1. **`Set-Busy([bool]$busy, [string]$msg)` 语义**：
   - 进入忙碌态（`$busy = $true`）：置 `$script:isBusy = $true`，禁用 `$script:allButtons` 全部按钮防止并发写盘，顶栏 `$lblHint` 切高亮色并显示当前阶段文案；
   - 退出忙碌态（`$busy = $false`）：必须放在 **`try / finally`** 中保证异常也能解锁；退出前检查 `-not $script:closeRequested -and -not $form.IsDisposed`；
   - 空包根约束（`$script:noPackage = $true`）：即使处于空闲态，`$script:pkgButtons`（依赖已有 `Edge\` 的按钮）仍保持禁用；「刷新状态」「从备份恢复」「更新面板」「检查更新」等允许空包根使用的按钮不进 `$script:pkgButtons`。
2. **进度提示文案统一格式（顶栏 `$lblHint`）**：
   - **不确定时长 / 计时型任务**：`<动作>中… 已 <N> 秒（界面仍可用）`，例如：`解压中… 已 4 秒（界面仍可用）`；
   - **可计数遍历型任务**：`<动作> <当前>/<总数> …`，例如：`覆盖文件 120/500 …`；
   - **百分比下载 / 打包型任务**：`<动作> <N>%`，例如：`下载 45%`、`打包 80%`；
   - **空闲态**：统一显示 `就绪`。

## 4. 三色日志用词规范（`Write-Log`）

`Write-Log` 仅保留四档级别（默认 `info` / 成功 `ok` / 警告 `warn` / 错误 `err`），必须先 `Write-Host` 落盘再判 `if ($log -and -not $log.IsDisposed)` 写入文本框，避免关窗后抛 `ObjectDisposedException`。用词按以下口径统一，不再混用：

| 级别 | 前缀 | 适用场景 | 规范用词 |
|---|---|---|---|
| `info` | `·` | 阶段推进、普通状态、参数说明 | `开始…`、`正在…`、`已跳过（原因）`、`已取消（用户主动取消）` |
| `ok` | `OK` | 核心动作或校验全部完成 | `…完成`、`…通过`、`已全部关闭`、`已是最新版本` |
| `warn` | `WARN` | 非阻断异常、降级回退、需要用户留意的边界 | `…不可用（已改用…）`、`…缺 N 项（不阻断）`、`旧数据保留在…`、`已回滚到旧版` |
| `err` | `FAIL` | 阻断性错误、校验不通过、必须终止的操作 | `…失败（原因）`、`…已中止（原因）` |

**用词区分原则**：
- **「失败」**：操作本身执行出错（下载失败、解压失败、拷贝失败）；
- **「已中止」**：预检/护栏主动拦截未动原文件（空间不足已中止、签名不可信已中止）；
- **「已取消」**：用户主动点取消或关闭窗口；
- **「不可用」**：某外部源或可选能力暂不可达，但有降级路径或不影响主流程。

## 5. 长任务异步执行规范（反例与硬要求）

**硬要求**：凡预期耗时 **> 300 ms** 的 I/O、网络、压缩/解压、子进程任务，严禁在 UI 线程同步阻塞，必须遵循：
1. **后台执行**：放入显式创建的独立 Runspace（`[runspacefactory]::CreateRunspace()` + `.Open()` + `$ps.Runspace = $rs`，杜绝默认 Runspace 池异常）或异步子进程；
2. **UI 线程只轮询**：以 100–500 ms 间隔轮询完成状态 / 进度文件，并调用 `[System.Windows.Forms.Application]::DoEvents()` 保持窗口可拖动、可重绘；
3. **响应关窗取消**：循环内每次轮询/每批文件（如每 20 文件或 250 ms）必须检查 `$script:closeRequested`，关窗时立即 `BeginStop()` 或抛取消触发 `catch` 回滚；
4. **完整资源释放**：`finally` 与 `$form.Add_FormClosing` 均需 `Stop()`/`Dispose()` 定时器、Runspace 与子进程句柄。

**典型反例（实测踩坑）**：
- `.193` 及之前版本在 `Invoke-UpdateNow` 中于 UI 线程同步调用 `[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $ex)` 解压 435 MB 上游包（解出 976 MB），`SendMessageTimeout` 实测 UI 线程连续冻结 **11.10 秒**，Windows 直接标记窗口「未响应」。
- `.194` 将解压迁入独立 Runspace + 120 ms 轮询 `DoEvents`，并将覆盖拷贝改为每 20 文件 / 250 ms 泵送一次 `DoEvents` 后，228 次采样冻结次数降为 **0**。

## 6. 机械化验收门槛

1. **每次改动 UI 必须执行**：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-audit.ps1
   ```
   浅色与深色在 `1×`（888×723）与 `1.25×` 档位下均须 **问题数 0**（无越界、无贴边 `< 8 px`、无控件重叠 `> 2×2 px`），并目视检查自动截取的 PNG 确认无文字截断。
   > **判据只看问题数，不看控件数**：`.224` 起工具改纯 Win32 定位、不再经 explorer 的 UIA 代理，跨进程拿到的是简化视图，控件数固定为 **52**（旧工具的 62/59 是历史值，已作废）。
2. **无人值守路径禁弹模态框**：`-RunOnce` / `$Auto` / `-Silent` 路径绝不允许弹出 `MessageBox` 阻塞脚本退出。
3. **策略管理窗口专项**：改 `zh-debloater\translate.ps1` 后必须实测浅色与深色双主题、切页按钮不变白、搜索命中不刺眼、中文标题不裁底。

---

## 7. 对话框与控件对齐（2026-11-22 补，`.205`–`.208` 实测得出）

### 7.1 弹窗一律自绘，宽度按文字实测

- 统一入口：`Show-DialogAsk($title,$msg,$okText,$cancelText,[-Danger],[-FocusCancel])`，外壳走 `New-DialogBase` + `Add-DialogFooter`；
- **禁止**再用系统 `MessageBox`（无深色变体，深色主题下会突兀）；
- **底栏按钮宽度必须按文字实测计算**，不许写死：
  ```powershell
  $wOk     = [int][math]::Max((S 112), ([System.Windows.Forms.TextRenderer]::MeasureText($okText, $fontBase).Width + 2 * (S 18)))
  $wCancel = [int][math]::Max((S 92),  ([System.Windows.Forms.TextRenderer]::MeasureText($cancelText, $fontBase).Width + 2 * (S 18)))
  # 两个按钮 + 间距超出底栏可用宽度时等比压缩，宁窄不出界
  ```
  反例：`.205` 之前写死 `S 112`，「关闭 Edge 并继续」实测 120 px（1×）被截成「关闭 Edge 并…」。
- 危险动作用 `-Danger`（主按钮变红）+ `-FocusCancel`（焦点默认落在取消）；`-RunOnce` 下 `Show-DialogAsk` 直接返回 `$true`，不弹窗。

### 7.2 勾选框：glyph 与文字必须拆成两个控件

`CheckBox` 在 `AutoSize=$true` 时高度 = 字体行高 + 默认 Padding(3,3,3,3)，**glyph 与文字在同一个盒子内天然差 1–2 px**，靠调外层 Y 或改高度治不好。规范做法：

```powershell
# 方块：只画 glyph，20×26，MiddleCenter
$chk.Text = ''; $chk.AutoSize = $false; $chk.CheckAlign = 'MiddleCenter'
$chk.Size = New-Object System.Drawing.Size((S 20), (S 26))
$chk.Location = New-Object System.Drawing.Point(($pad + (S 2)), $rowY)

# 文字：独立 Label，同 Y 同高 26，MiddleLeft；点文字也能切换
$lbl.Size = New-Object System.Drawing.Size((S 76), (S 26))
$lbl.TextAlign = 'MiddleLeft'
$lbl.Location = New-Object System.Drawing.Point(($pad + (S 22)), $rowY)
$lbl.Add_Click({ $chk.Checked = -not $chk.Checked })
```

同一行里的状态文字（如「已保存密码」）也必须**同 Y 同高 26**，三者矩形完全一致才能对齐。

### 7.3 深色主题下"已弃用/禁用"条目的样式

- 正常项：`ForeColor = $cTxt`（`#F1F5F9`）；
- 弃用/禁用项：`ForeColor = $cMuted`（`#64748B`）+ `Font` 加 `Strikeout`；
- 判定：`-not $ctrl.Enabled` / `-not $ctrl.AutoCheck` / 原 `ForeColor` 偏灰 / tooltip 含「已弃用|Deprecated|无法启用」；
- 搜索命中高亮（深蓝底）时**保留灰字**，不要刷回亮白（否则弃用项与正常项又分不出来）。

### 7.4 验收补充

- 改对话框后，除 `ui-audit`（只覆盖主面板）外，**必须人工目视**至少一次：深浅两主题各弹一个确认框，检查按钮文字完整、勾选行基线齐平；
- `ui-audit` 判定标准是**问题数 0**，不是固定控件数；`.224` 起控件数固定 **52**（见 §6.1 注），此前记的 62 / 59 是旧工具的历史值，已作废。

---

## 路径行与目录切换（2026-11-23 定稿）

- **路径行**：`$lblSub` 按 `Format-MiddleEllipsisPath` 做**中段省略**（保留盘符+首段+末段，如 `D:\App\…\Edge_Portable`），省略上限按实测文字宽算；左键单击打开目录。
- **切换入口**：路径文字末尾放一个**无边框下箭头 `▾`**（宽 18–24px、与路径同高、悬停变强调色）。不用文字按钮（占宽），也不用右键菜单（不可发现）。切换后调用 `Update-PathLabel` 重排：标签宽度随文字收缩，箭头始终贴文字末尾。
- **路径来源**：记忆的包根仍有效时**静默接管**（不弹窗）；只有"面板不在任何便携目录里"才弹目录选择窗，默认选中上次/首个已发现目录，并附带"在当前目录全新部署"。
- **目录选择弹窗**：列表 + 「深度搜索本机…」（进度窗带停止按钮、60 秒上限、置顶）+「浏览其他目录…」。
- **备份/恢复里的目录**：恢复弹窗用「选择目录…」（`FolderBrowserDialog`）扫该目录下的备份包，并把目录记进 `backup-mode.json` 的 `rdir`，下次打开自动并入候选并标注「（上次目录）」。

## 弹窗文案与控件宽度（2026-11-23）

- 任何**按点制字号渲染**的标签，宽度一律 `TextRenderer::MeasureText` 实测后设置，禁止写死像素——写死 64px 的「压缩格式」在 125% 系统 DPI 下折行压到上一行（`.247` 修）。
- 同一组控件的**文字长度**要成组考虑：中英混排会破坏对齐（「包含面板程序」对「包含 Edge 程序」），统一改成纯中文。
- 说明文字不要留"最后一行只有一两个字"：按可用宽调措辞或换行点，宁可缩句。
