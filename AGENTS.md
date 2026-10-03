# AGENTS.md

> 工作区级 AI Agent 指令：Agent 在本工作区内工作前会阅读本文件。
>
> 本文件描述的是**开发这台机器上的这份工作区**，里面的绝对路径（`E:\MC\software\ModSync`、
> `D:\cache\ModSync\`）是实际位置。你 fork 之后请把它们换成自己的目录 ——
> 脚本本身不依赖任何绝对路径，一律从 `$PSScriptRoot` 推导。

## 项目概述

**ModSync** —— Minecraft 整合包「客户端 → 服务端」mod 同步工具。
在 PCL2 更新完整合包后，自动找出客户端 mods 里新增/更新的 mod，勾选后一键同步到服务端
（覆盖旧版本、清理残留旧 jar）。

技术形态：**零依赖 PowerShell 5.1 + .NET WinForms 源码**，再用系统自带 `csc.exe`
把脚本压缩内嵌成单个绿色 exe（用户系统执行策略是 `Restricted`，禁用 .ps1，exe 不受管辖）。

核心能力之一：**重命名同步** —— 客户端 mod 改了名（或 PCL2 换了命名风格）时，
按「内容一致 + 仅文件名不同」判定为 `重命名`，默认自动把服务端那个文件一起改名，
保证双端文件名一致、不留下同一 mod 的两个 jar。见 README「二·六」。

表格支持右键菜单（`Open-FileLocation`）：用 explorer `/select` 精确定位到 jar 本身，
另有重命名、批量加前缀、详情、**复制 ▸**、**打开在线页面 ▸**、遗忘单个。见 README「二·七」。
批量重命名 = 勾选 ≥2 个后统一加前缀（`A.jar` → `[客户端]A.jar`），核心逻辑在
`Build-RenamePlan` / `Invoke-RenamePlan`（纯函数、可单测），界面流程在 `Rename-Batch`。

右键「打开在线页面 ▸」可在浏览器里直达该 mod 的 **MC百科 / CurseForge / Modrinth** 页面，
解析函数为 `Resolve-McmodLink` / `Resolve-CurseForgeLink` / `Resolve-ModrinthLink`
＋ `Get-JarModMeta`（读 jar 元数据）＋ `Get-CfFingerprint`（CurseForge 文件指纹）。见 README「二·八」。

项目在 `E:\MC\software\ModSync`（本文件就在项目根目录里，工作区是 `E:\MC\software` 还是
`E:\MC\software\ModSync` 都会被读到）。**脚本内部一律从 `$PSScriptRoot` 推导自身位置，
不要再写死绝对路径** —— 项目搬过一次家，写死的路径全成了坑：

```
E:\MC\software\ModSync\
├─ ModSync.exe            日常运行入口（绿色单文件，**就放根目录**，双击即用；可单独拷走）
├─ ModSync.ps1            主程序源码（3452 行，中文注释）—— 改功能只改这里
├─ build-exe.ps1          打包器：ModSync.ps1 → 根目录的 ModSync.exe
├─ icon.ico               图标源，打包时以 /win32icon + 嵌入资源两种方式打进 exe
├─ make-icon.ps1          PNG → 多尺寸 icon.ico（6 帧 PNG：256/128/64/48/32/16）
├─ tests\Test-ModSync.ps1 纯逻辑单元测试（零依赖，AST 抽函数，不弹窗）
├─ README.md              使用文档、判定规则、故障排查
├─ AGENTS.md              本文件（给 AI Agent 的项目说明）
└─ docs\打包exe.md        打包原理、重新构建步骤、换图标、应急解包
```

**目录布局是有意为之，别再"优化"回去**：用户要的就是"打开文件夹、双击那个 exe"。
所以 exe 必须在根目录，**不要**再套一层 `dist\`，**也不要**再引入 `.bat` 启动器
（用户明确表示不喜欢 bat；而且 exe 自带脚本快照，本来就不需要旁路启动）。

用户数据**不在**工作区里：`%LOCALAPPDATA%\McModSync\config.json`（路径配置 + 各配置档的遗忘列表）、
`%LOCALAPPDATA%\McModSync\ModSync.log`（写入失败时回退 `%TEMP%\McModSync.log`）。

## 常用命令

```powershell
# 0) 改了判定/改名/同步逻辑，先跑单元测试（零依赖，几秒钟，不弹窗）
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\MC\software\ModSync\tests\Test-ModSync.ps1"

# 1) 改完 ModSync.ps1 后必须重新打包（否则 exe 里跑的还是旧脚本）
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\MC\software\ModSync\build-exe.ps1"

# 2) 调试时不打包，直接跑源码
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "E:\MC\software\ModSync\ModSync.ps1"

# 3) 换图标（再用 build-exe.ps1 重打包才会生效）
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\MC\software\ModSync\make-icon.ps1" -Png "D:\图片\myicon.png"
```

- 构建：
  `build-exe.ps1`（产物**项目根目录的 `ModSync.exe`**；中间文件写在 `D:\cache\ModSync\build\`，成功后自动删掉，失败时保留便于排查）
- 测试：`tests\Test-ModSync.ps1` —— **零依赖**（不用 Pester），用 AST 把纯函数抽出来单独跑，
  覆盖 `Get-ModIdentity` / `Test-CanDeleteOldVersion` / `Build-RenamePlan` / `Invoke-RenamePlan` /
  `Test-NameMatch` 等，并顺带检查 `ModSync.ps1` 的 UTF-8 BOM 还在不在。全通过退出码 0。
  **界面流程（`Invoke-Scan` / `Invoke-Sync`）测不到**，仍需真实运行验收：改动判定逻辑时，
  至少覆盖 README「三、判定依据」里的四级判定：
  ① 文件名剥版本 + 大小比对；② 同名同大小算 MD5；③ 同名不同版本归组删旧；
  ④ 内容一致仅文件名不同 → 重命名（必须两边 MD5 相等才成立）。
  改完可以照这个流程造现场自测：临时目录里放一对「内容相同、名字不同」的 jar，
  用一个指向临时目录的 config.json 启动，看日志是否出现 `识别为重命名` 与 `自动重命名`。

## 关键约束（都是踩过的坑，勿回退）

1. **exe 内嵌的是「打包那一刻」的脚本快照。** 只改 `ModSync.ps1` 不重新打包，
   双击 exe 不会有任何变化；交付前务必重打包并确认 exe 时间戳晚于脚本。
2. **所有 .ps1 必须保持 UTF-8 带 BOM**（`ModSync.ps1` / `build-exe.ps1` / `make-icon.ps1` /
   `tests\Test-ModSync.ps1`）。用户机器上是 Windows PowerShell 5.1，
   对无 BOM 的 .ps1 会按系统 ANSI（中文系统 GBK）解码，导致中文 UI 文案和中文路径全部乱码。
   **坑在于：编辑器/工具保存时经常把 BOM 吃掉**，而且症状不是报错、是一堆乱码语法错误。
   所以改完源码务必确认 BOM 还在，`tests\Test-ModSync.ps1` 会替你把这一关。
3. **启动器不许把脚本塞进命令行。** 走 `-EncodedCommand` 需要约 10 万字符，
   远超 CreateProcess 的 32767 上限，会报「文件名或扩展名太长」。
   必须保持「解压 → 写临时 `.ps1` → `powershell -File`」的路线，`build-exe.ps1` 里有构建期自检。
4. **兼容旧配置。** `Read-Cfg` 里保留了「旧版单档 ClientDir/ServerDir/Ignored* → 配置档 Profiles」
   的迁移逻辑和空列表规范化，改动配置结构时必须继续兼容，否则老用户升级后配置丢失。
5. **运行环境基线**：Windows 7 SP1+ / .NET Framework 4.x / PowerShell 5.1（Win10、11 全自带），
   不引入任何第三方模块、不加联网依赖。
6. **同步是破坏性操作**（覆盖 + 删除服务端旧 jar）。任何相关改动都必须保留
   「将新增 / 将覆盖 / 将删除」的明细确认弹窗和逐行结果回填，不允许静默删除。
   **而且删除必须等新版本先落地**：`Invoke-Sync` 里复制成功的记录才允许删它的旧版本，
   判定点是纯函数 `Test-CanDeleteOldVersion`（有单元测试）。
   复制失败还删旧版本 = 这个 mod 在服务端彻底消失，这是本工具唯一会丢用户文件的方式。
   同理，**写盘失败一律不许静默**：`Write-Cfg` 失败要写日志 + 状态栏提示，
   「没扫成」和「扫了没变更」在日志里必须能分开（`$script:LastScanOk` / `LastScanMsg`）。
7. **重命名的判定必须守住"内容一致"这条线。** 只有候选大小相同、且 MD5 完全相等时才能
   判为 `重命名`；改名动作只能是移动文件本身（`[System.IO.File]::Move`），绝不允许在改名路径上复制或覆盖内容。
   自动执行（`AutoRename` 开关）也只在判定成立时才动手 —— 判定门槛一旦放宽，
   就会变成"静默改用户文件"，这是不可接受的。
8. **调用 explorer.exe 定位文件，必须用 `ProcessStartInfo.Arguments` 直接拼
   `/select,"路径"`。** 走 PowerShell 的 `-Destination` / `-Path` 参数层会再包一层引号或
   当成通配符，路径带空格的整合包（`...\Beebeeblock - The Skyhive\mods`）就会定位失败。
   同理，读 `$r.DstSameBase` / `$r.DstRenameFrom` 前要判空 —— 记录类型不同时它们是 `$null`。
9. **文件名里的 `[` `]` 是 PowerShell 的通配符字符类。** 批量加前缀后的名字形如
   `[客户端]A.jar`，所以：① 所有路径参数一律用 `-LiteralPath`，绝不用 `-Path`；
   ② 改名统一用 `[System.IO.File]::Move($src, $dst)`（字面路径、目标存在就报错），
   不要用 `Move-Item -Destination`（它对不存在的目标恰好按字面处理，但不能依赖这个行为）；
   ③ 自己写测试/脚本时同样要注意 —— `Get-Item '[...].jar'`、`Set-Content '[...].jar'`
   都会因为通配符而"找不到文件"。`-like` 同理会把 `[regex]` 当字符类，判断字面文本用 `.Contains()`。
10. **联网功能（打开在线页面）的四条硬约束。**
    ① **TLS 1.2 必须显式打开**：PowerShell 5.1 默认只到 TLS 1.0，Modrinth / CurseForge 会握手失败。
    ② **读 jar 元数据只能只读打开 ZIP**（`ZipFile::OpenRead` + `GetEntry`，取 `META-INF/neoforge.mods.toml`
    / `META-INF/mods.toml` / `fabric.mod.json` 这一个小文件），**绝不允许解压到磁盘或改动 jar**。
    ③ **命中必须校验名字**（`Test-NameMatch` 归一化比对），对不上就退成"打开该站搜索结果页"——
    宁可多点一下，也不能把用户送到错误的 mod 页面。
    ④ **CurseForge API Key 只存 `%LOCALAPPDATA%\McModSync\config.json`**：绝不写进项目目录、
    绝不写进日志、绝不在界面上明文显示（用密码框）。它的 `mods/search` 接口对个人 Key 返回 403，
    能用的精确路径是 `POST /v1/fingerprints`（文件指纹）→ `GET /v1/mods/{id}`。
    （顺带一个 WinForms 坑：`ToolStripMenuItem` **没有** `Show` 方法，`Show(Control, Point)` 在
    `ToolStripDropDown` / `ContextMenuStrip` 上。要弹出某个子菜单用 `$item.DropDown.Show($ctl, $pt)`
    或 `$item.ShowDropDown()`；写成 `$item.Show(...)` 会在点击时抛「不包含名为 Show 的方法」。）

11. **临时文件一律放本机统一的临时区 `D:\cache\ModSync\`，项目目录和用户软件目录里都不许留东西。**
    - 构建中间产物：`build-exe.ps1` 已改到 `D:\cache\ModSync\build\`（成功即删；机器上没有 `D:\cache` 时退回系统 TEMP，保持可移植）；
    - 自己写补丁脚本/测试夹具：也放 `D:\cache\ModSync\`，用完删掉；
    - 绝不在项目根目录、更不在 `E:\MC\software` 这类软件目录里创建 `_tmp` / `_build` 之类的东西。
    历史教训：打包脚本最初把中间产物放在项目旁的 `_tmp` 里，已被用户点名要求改掉。


## 协作规范

- 改完源码 → **跑测试** → 重打包 → 双击根目录的 `ModSync.exe` 验收；不要手工修改 `ModSync.exe`。
  改完务必确认 `ModSync.ps1` 的 UTF-8 BOM 还在（编辑器经常吃掉它），测试脚本会替你查。
- 中文注释、中文界面文案保持现有风格；新增功能同步补进 `README.md`（含文件清单一节）。
- 遇到 bug 修复后，在 README「七、故障排查」里以「（已修复）」小节记一条，写清现象与原因。
- 文档里的**数字**（行数、exe 体积、构建输出）容易过期，改动后顺手核对一遍；
  拿不准就写"示意"而不是写死一个会过期的值。
