# 决策：AppContainer 目录权限与「攒满 100 次启动必现全白屏」

> 2026-11-26 立。**先读这篇再改相关代码** —— 这里的取舍是实测过的，凭直觉"优化"会踩回去。

## 一句话

便携版 Edge 装在非 `C:\Program Files` 目录时，Edge 攒满 100 次启动会正式启用
`RendererAppContainer` 强沙箱，而该目录没有 AppContainer 两个包 SID 的读执行权限
→ 沙箱内的 renderer 读不到程序文件 → **一个渲染进程都起不来**。
修法是**给目录补 ACL**，不是关掉沙箱策略。

## 根因链

```
① Edge 每次启动给 Local State 的
   edge.mitigation_manager.renderer_app_container_compatible_count 加 1
② 累计到 100 → 正式给 renderer 启用 AppContainer 强沙箱
③ 便携目录的 ACL 里没有 S-1-15-2-1 / S-1-15-2-2（Windows 只给 Program Files 系配这两个）
④ 沙箱内 renderer 读不到目录里的 DLL → 进程创建不出来
⑤ browser / GPU / utility 不受此限照常运行 ⇒ 窗口能开、所有页面空白、edge://settings 也进不去
```

**三个反直觉点，务必记住**：

- `compatible_count` 是"启用计数"**不是**"失败计数"。到 100 是**开启**沙箱，不是禁用它。
- **没有崩溃转储**是正常的 —— renderer 根本没启动，不是崩了。别拿"0 转储"当"没出事"的证据。
- **换 `Data` 备份能"修好"**只是假象：备份里计数还没到 100，等于续了十几次额度，用满又复发。

## 三个方案的取舍（实测过，别再试）

| 方案 | 安全性 | 持久性 | 结论 |
|---|---|---|---|
| **补 ACL**（现方案） | **满血** AppContainer | 目录级 `(OI)(CI)` 继承，更新出新版本目录自动继承 | **采用** |
| `RendererAppContainerEnabled=0` | 降级为常规 Chromium 沙箱 | 策略可能被微软废弃 | **不用**（曾短暂采用，已回退） |
| 删 `mitigation_manager` | 不变 | 只撑 100 次启动 | 仅作应急 |

**ACL 方案的实测依据**：强制 `RendererAppContainerEnabled=1` + `count=100` + 补 ACL →
9 个 renderer 正常启动，`GetTokenInformation(TokenIsAppContainer)` 抽查 6 个全部 = 1。
**即 `version.dll` 注入与 AppContainer 不冲突**，之前起不来纯粹是目录权限。

## 四个触发点（缺一个就有用户中招）

| 位置 | 覆盖场景 | 失败时 |
|---|---|---|
| `Invoke-UpdateNow` 更新/部署成功后 | **首次部署**（新目录，无继承来源）、换版本 | warn + 手动命令 |
| `$form.Add_Shown` 启动时（同步静默） | 手动拷包、从别处迁移、旧版升上来 | 静默，交给下一行 |
| `startupPromptTimer`（300ms 后） | 承接上一行的失败 | 弹窗 + 一键提权（可"暂不"，下次启动再提醒） |
| `Apply-RecommendedPolicies` / `Import-PolicyReg` UAC helper | 用户主动点按钮 / 同一次提权兜底 | warn / 静默 |

**启动期弹窗互斥**：`$script:startupModalShown` 由 `Prompt-IfEdgeRunning` 置位，
ACL 弹窗要求「未置位 + `$form.Enabled`」才弹，避免连着弹两个模态框。
静默探测的更新提示也加了 `$form.Enabled` 判断，不叠框。

## 为什么代码里有三处 `icacls`

看着冗余，但**不能合并**：

| 位置 | 为什么必须单独一份 |
|---|---|
| `core\_Common.ps1` 的 `Repair-EdgeAppContainerAcl` | 主实现，普通权限路径 |
| `EdgePanel.ps1` 的 UAC helper 脚本内联 | helper 是**独立 powershell 进程**，不加载 `_Common.ps1` |
| `EdgePanel.ps1` 弹窗里的提权 helper | 同上，也是独立进程 |

## 两条红线

1. **不要把 `RendererAppContainerEnabled=0` 加回 `EdgePolicyBaseline.json`** ——
   那会把 renderer 退回常规沙箱，让 ACL 修复失去意义。基线是 132 条，此事与基线无关。
2. **不要把启动期的 ACL 检查删掉或改成"只在点按钮时做"** —— 首装用户不点按钮就白装，
   攒满 100 次后又来报同一个 bug。v1.4.1 就是这么漏的。

## 相关

- 上游同类报告：`bibicadotnet/microsoft-edge-portable#7`（2026-11-06，Edge 156 + Chrome++ 1.19.0）
- 排障记录：`notes\排障_Edge渲染全失效_2026-11-26.md`（含"绝不用原版 exe 挂载生产 Data"那条红线）
- 修复版本：v1.4.2
