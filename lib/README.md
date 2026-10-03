# lib\ —— 内嵌的第三方库

## Renci.SshNet.dll（SSH.NET）

| 项 | 值 |
| --- | --- |
| 版本 | 2023.0.0 |
| 程序集 | `Renci.SshNet, Version=2023.0.0.0, Culture=neutral, PublicKeyToken=1cee9f8bde3db106` |
| 大小 | 844,800 字节 |
| 目标框架 | `net462`（.NET Framework 4.6.2+，Win10/11 自带的 4.8 满足） |
| 许可证 | **MIT** |
| 项目主页 | https://github.com/sshnet/SSH.NET/ |
| 来源 | NuGet 包 `SSH.NET` 2023.0.0 → `lib/net462/Renci.SshNet.dll` |

### 为什么这里会有个第三方库

本项目的硬约束原本是"零第三方依赖"。但**远程同步到简幻欢这类托管平台只能走 SFTP**，
而 **Windows PowerShell 5.1 / .NET Framework 里没有任何内置 SFTP 客户端**
（`System.Net` 只有 FTP，`FtpWebRequest` 完全够不着 SFTP）。

盘过的几条路：

| 方案 | 结论 |
| --- | --- |
| 系统自带的 `sftp.exe` / `scp.exe` | ✘ 密码认证没法非交互传入（OpenSSH 不从 stdin 读密码），而简幻欢不给上传公钥 |
| Posh-SSH 模块 | ✘ 要装模块，且用户执行策略是 `Restricted`，`Import-Module` 会被拒 |
| 面板 HTTP API | ❓ 取决于面板是否开放 API 密钥，不保证有 |
| **内嵌 SSH.NET** | ✅ 自包含、版本可控、密码认证可用，还能跑 `md5sum` 免下载比对 |

所以选它。**代价只有一个：exe 变大**（384 KB → 798 KB）。依然是一个绿色文件、
依然不用装任何东西 —— 用户侧零感知。

### 为什么选 2023.0.0 这个版本

不是随手挑的最新版。2023.0.0 之后的版本（2024.x / 2025.x / 2026.x）的 `net462` 程序集
**额外依赖三个微软组件**（`System.Memory`、`System.Threading.Tasks.Extensions`、
`Microsoft.Bcl.AsyncInterfaces`），单独一个 dll 加载不起来：

```
Could not load file or assembly 'System.Memory, Version=4.0.5.0 ...'
```

实测下来 **2023.0.0 是"单文件、能在 PowerShell 5.1 里独立加载"的最新版本**。
要升级的话，必须把那三个依赖一起内嵌，否则 SFTP 会在加载阶段就失败。

### 怎么验证它还能用

```powershell
# 1) 单元测试会检查脚本里 SFTP 相关函数还在
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ModSync.ps1

# 2) 真连一次（工具界面里点「SFTP 设置...」→「测试连接」最直观）
```

### 怎么升级

1. 从 https://www.nuget.org/packages/SSH.NET/ 下载新版 `.nupkg`（zip 格式）；
2. 解出 `lib/net462/Renci.SshNet.dll`，覆盖本目录的同名文件；
3. **确认它不需要额外依赖**：
   ```powershell
   powershell -NoProfile -Command "Add-Type -Path '.\lib\Renci.SshNet.dll'; New-Object Renci.SshNet.SftpClient('h',22,'u','p')"
   ```
   报 `Could not load file or assembly` 就说明要补依赖，那就别升。
4. 重新打包：`powershell -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1`

### 许可证义务

MIT 许可证要求：再分发时保留版权声明与许可证原文。本项目已经在根目录的
[LICENSE](../LICENSE) 里说明了自己的许可；SSH.NET 的 MIT 声明见其
[nuspec](https://www.nuget.org/packages/SSH.NET/2023.0.0) 的 `license` 字段
（`MIT`）与项目主页。**打包进 exe 再分发是 MIT 明确允许的。**
