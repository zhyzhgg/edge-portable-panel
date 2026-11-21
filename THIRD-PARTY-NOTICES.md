# 第三方声明（THIRD-PARTY NOTICES）

本仓库**只包含面板自身的代码**，不分发浏览器本体、便携补丁或任何第三方二进制。
下列项目仅作为运行/构建依赖或参考，权利归各自作者。

## 运行时依赖

| 项目 | 用途 | 许可 | 是否随本仓库分发 |
|---|---|---|---|
| **7-Zip** `7zr.exe`（26.04） | 备份 / 恢复 / 校验压缩包 | © Igor Pavlov，**public domain** | **否**。需自行放入 `tools\7zr.exe`（<https://www.7-zip.org/a/7zr.exe>）；编译时会被内嵌进 `EdgePanel.exe` |
| **.NET Framework 4.0** `csc.exe` | 编译宿主 | 随 Windows 提供 | 否 |

## 上游/协作项目

| 项目 | 关系 | 说明 |
|---|---|---|
| [bibicadotnet/edge-portable-chrome-next-mini](https://github.com/bibicadotnet/edge-portable-chrome-next-mini) | 便携包格式来源 | 本面板按该项目的发布格式（`Edge\<ver>\`、`Data\`、`chrome++.ini`）工作，**不包含其代码** |
| **Chrome++ Next Mini**（作者 shuax） | 便携化补丁 `version.dll` | 由上游便携包提供，**不随本仓库分发** |
| **Edge Debloater GUI**（策略面板上游） | 策略管理界面 | 运行时从上游地址下载脚本，本仓库只做中文翻译与主题注入，**不内嵌其代码** |
| **Microsoft Edge** | 被管理的浏览器 | 不随本仓库分发 |

## 免责声明

本项目是**个人自用工具**，与 Microsoft、Bitwarden、上述任何上游作者均无关联，也未获其背书。
瘦身会删除浏览器安装目录内的部分文件，策略会改变浏览器行为，**风险自负**；请在了解后果的前提下使用，并自行保留备份。