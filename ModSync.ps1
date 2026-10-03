<#
================================================================================
 ModSync.ps1  --  Minecraft 整合包 客户端/服务端 mod 同步工具
--------------------------------------------------------------------------------
 零安装：只用 Windows 自带的 PowerShell 5.1 + .NET WinForms，
         远程同步所需的 SFTP 客户端库（SSH.NET，MIT）已内嵌进 exe，用户不用装任何东西。

 功能：
   1. 路径配置：客户端 mods 文件夹 + 同步目标（本地/网络文件夹，或 SFTP 远程服务器）。
   2. 变更检测：扫描并比对，列出「新增 / 更新 / 已同步 / 重命名」四类状态。
   3. 选择性同步：在列表中勾选，一键复制到目标端并覆盖旧版本。
   4. 安全提示：同步前弹出明细，列出"将新增 / 将覆盖 / 将删除"的每个文件；
      执行后逐行回填成功/失败结果，末尾给出汇总。
   5. 远程同步：目标端可以是简幻欢这类托管平台的 SFTP（详见 lib\README.md）。

 判定"是否更新"的依据（四级递进，兼顾准确与速度）：
   第 1 级 文件名剥版本 + 大小比对  -> 绝大多数情况在这里就判定完毕，不读文件内容
   第 2 级 同名且同大小时才计算 MD5 -> 区分"真的一致"和"同大小不同内容"
   第 3 级 文件名不同但 mod 同名    -> 识别为版本更替，标记旧文件为「将删除」
   第 4 级 内容一致、仅文件名不同    -> 判为「重命名」，让目标端改名而不是新增
   （SFTP 目标端的 MD5 走服务器上的 md5sum，不会把整个整合包下载下来）
================================================================================
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 读 jar 内部元数据要用（只读打开 ZIP，不解压、不落盘）
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
# PowerShell 5.1 默认只协商到 TLS 1.0，Modrinth / CurseForge 会直接握手失败
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ------------------------------------------------------------------ 全局状态

$script:ConfigDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'McModSync'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'

# 配置档（Profile）：一个整合包 + 一个服务端 = 一套路径。
# 顶级 ClientDir/ServerDir 仅用于兼容旧版配置，迁移后会置空。
# IgnoredMods / IgnoredInfo 放在各档内部：不同整合包的遗忘清单互不影响。
$script:Config = [ordered]@{
    Profiles       = @()   # @( @{ Id; Name; ClientDir; ServerDir; IgnoredMods; IgnoredInfo } )
    CurrentProfile = 0
    UseHash        = $true
    AutoWatch      = $true
    Backup         = $false
    AutoRename     = $true   # 识别重命名并自动改名同步到服务端（内容一致、仅文件名不同）
    CurseForgeApiKey = ''  # 可选：填了才能一键直达 CurseForge 的 mod 页面；只存本机配置文件
    ClientDir      = ''    # 旧字段：仅迁移时读取
    ServerDir      = ''    # 旧字段：仅迁移时读取
    IgnoredMods    = @()   # 旧字段：仅迁移时读取
    IgnoredInfo    = @()   # 旧字段：仅迁移时读取
}

# ---- 当前档位的读写helper，全局统一走这两个，避免到处散落索引逻辑 ----
function Get-CurProfile {
    $list = @($script:Config.Profiles)
    if ($list.Count -eq 0) { return $null }
    $i = [int]$script:Config.CurrentProfile
    if ($i -lt 0 -or $i -ge $list.Count) { $i = 0 }
    return $list[$i]
}
function Set-CurProfileField([string]$field, $value) {
    $list = @($script:Config.Profiles)
    if ($list.Count -eq 0) { return }
    $i = [int]$script:Config.CurrentProfile
    if ($i -lt 0 -or $i -ge $list.Count) { $i = 0 }
    $list[$i].$field = $value
    $script:Config.Profiles = $list
}
function Get-CurClientDir { $p = Get-CurProfile; if ($p) { return [string]$p.ClientDir } else { return '' } }
function Get-CurServerDir { $p = Get-CurProfile; if ($p) { return [string]$p.ServerDir } else { return '' } }
# 遗忘列表统一入口（现在按档存储，不再全局）
function Get-IgnoredMods { $p = Get-CurProfile; if ($p -and $p.IgnoredMods) { return @($p.IgnoredMods) } else { return @() } }
function Get-IgnoredInfo { $p = Get-CurProfile; if ($p -and $p.IgnoredInfo) { return @($p.IgnoredInfo) } else { return @() } }
function Set-IgnoredList($mods, $info) {
    Set-CurProfileField 'IgnoredMods' @($mods)
    Set-CurProfileField 'IgnoredInfo' @($info)
}
function Get-DefaultProfileName {
    return ('整合包 ' + (@($script:Config.Profiles).Count + 1))
}

# 统一构造「配置档」对象：字段必须齐全，缺的补默认值。
# 三处会用到（读配置时的规范化、旧配置迁移、兜底空档），集中在这里就不会漏字段 ——
# 漏一个字段的后果是 Set-CurProfileField 静默失败，用户改了设置却没保存。
function New-ProfileObject($p) {
    $port = 22
    if ($p -and $p.SftpPort) { try { $port = [int]$p.SftpPort } catch { $port = 22 } }
    if ($port -lt 1 -or $port -gt 65535) { $port = 22 }
    $kind = 'Local'
    if ($p -and [string]$p.TargetKind -eq 'Sftp') { $kind = 'Sftp' }
    return [pscustomobject]@{
        Id          = $(if ($p -and $p.Id) { [string]$p.Id } else { [guid]::NewGuid().ToString('N') })
        Name        = $(if ($p -and $p.Name) { [string]$p.Name } else { '未命名' })
        ClientDir   = $(if ($p) { [string]$p.ClientDir } else { '' })
        ServerDir   = $(if ($p) { [string]$p.ServerDir } else { '' })
        # ---- 同步目标：Local = 本地/网络共享文件夹；Sftp = 远程服务器（简幻欢等）----
        TargetKind  = $kind
        SftpHost    = $(if ($p) { [string]$p.SftpHost } else { '' })
        SftpPort    = $port
        SftpUser    = $(if ($p) { [string]$p.SftpUser } else { '' })
        SftpPass    = $(if ($p) { [string]$p.SftpPass } else { '' })   # 只存本机 config.json，绝不进项目/日志/界面明文
        SftpDir     = $(if ($p) { [string]$p.SftpDir } else { '' })
        IgnoredMods = $(if ($p) { @($p.IgnoredMods | Where-Object { $_ }) } else { @() })
        IgnoredInfo = $(if ($p) { @($p.IgnoredInfo | Where-Object { $_ }) } else { @() })
    }
}

$script:Records = @()      # 客户端扫描结果（已应用遗忘过滤）
$script:AllRecords = @()   # 客户端扫描结果（未过滤，供遗忘管理用）
$script:IgnoredCount = 0   # 本次扫描被遗忘过滤掉的数量
$script:Orphans = @()      # 仅服务端存在的文件
$script:Watcher = $null
$script:WatcherDir = ''          # 当前监控的目录（用于自愈时判断是否需要重挂）
$script:LastChange = [datetime]::MinValue
$script:PendingScan = $false
$script:ScanInProgress = $false   # 防重入：扫描期间挡掉新的扫描请求
$script:CancelScan = $false       # 允许用户中断扫描
$script:PendingWatchStart = $false
$script:IgnoreProfileEvent = $false   # 填充配置档下拉框时抑制切换事件
$script:IgnoreTargetEvent = $false    # 填充「同步目标类型」下拉框时抑制切换事件
$script:AutoRenameBusy = $false       # 自动重命名进行中：防止重扫嵌套时反复改名
$script:AutoRenameNote = ''           # 自动重命名的结果提示，交给状态栏显示一次
$script:LastScanOk = $false           # 本次会话是否成功扫描过一次：退出日志靠它区分"没扫成"和"扫了但没变更"
$script:LastScanMsg = '尚未扫描'       # 未成功扫描的原因，供退出日志与状态栏使用
$script:CfgSaveFailed = $false        # 配置写盘失败标志：交给定时器在状态栏提示一次（这类失败不能静默）

# 状态图标与配色
$ICO_NEW = [char]0x25CF   # ● 新增
$ICO_UPD = [char]0x25B2   # ▲ 更新
$ICO_OK  = [char]0x2714   # ✔ 已同步
$ICO_REN = [char]0x2261   # ≡ 重命名（内容一致，只有文件名不同）

# ------------------------------------------------------------------ 通用函数

$script:LogFile = Join-Path $script:ConfigDir 'ModSync.log'
# 日志多路落盘：%LOCALAPPDATA% 写不进去时还有 TEMP 这一路，确保现场永远留得下
$script:LogPaths = @($script:LogFile, (Join-Path $env:TEMP 'McModSync.log'))

function Write-Log([string]$text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    $anyOk = $false
    foreach ($path in $script:LogPaths) {
        try {
            $dir = [System.IO.Path]::GetDirectoryName($path)
            if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
                [System.IO.Directory]::CreateDirectory($dir) | Out-Null
            }
            [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($false)))
            $anyOk = $true
        } catch { }
    }
    if (-not $anyOk) { $script:LastLogError = '所有日志路径均写入失败' }
}

function Write-Cfg {
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        # Depth 给足：配置档下面还有数组，遗忘项本身还是对象，
        # 原来的 4 正好卡在边界上，结构再深一层就会被 ConvertTo-Json 静默截断成字符串
        $json = $script:Config | ConvertTo-Json -Depth 8
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:ConfigFile, $json, $utf8)
        return $true
    } catch {
        # 保存失败不能打断使用，但更不能静默：写日志 + 置标志，由定时器在状态栏提示一次。
        # 否则用户改了路径/配置档却什么都没保存，界面上一点提示都没有。
        $script:CfgSaveFailed = $true
        try { Write-Log ('配置保存失败（本次改动可能不会保留）：' + $_.Exception.Message) } catch { }
        return $false
    }
}

function Read-Cfg {
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $raw = [System.IO.File]::ReadAllText($script:ConfigFile, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            foreach ($k in @($script:Config.Keys)) {
                # 注意：空数组 @() 在 PowerShell 里是 falsy，
                # 所以必须用 $null 判断而不是真值判断，否则会漏掉空列表
                if ($null -ne $obj.$k) { $script:Config[$k] = $obj.$k }
            }

            # 规范化：Profiles 必须是数组，字段必须齐全（含新增的 SFTP 字段，老配置缺了要补默认值）
            $norm = New-Object System.Collections.ArrayList
            foreach ($p in @($script:Config.Profiles)) {
                if (-not $p) { continue }
                [void]$norm.Add((New-ProfileObject $p))
            }
            $script:Config.Profiles = @($norm)

            # 旧格式迁移：把顶层 ClientDir/ServerDir/Ignored* 收进第一个配置档
            $legacyClient = [string]$obj.ClientDir
            $legacyServer = [string]$obj.ServerDir
            $hasLegacy = ($legacyClient -or $legacyServer)
            if ($hasLegacy -and @($script:Config.Profiles).Count -eq 0) {
                $nm = '默认整合包'
                try { if ($legacyClient) { $nm = Split-Path (Split-Path $legacyClient -Parent) -Leaf } } catch { }
                if (-not $nm) { $nm = '默认整合包' }
                $script:Config.Profiles = @(New-ProfileObject ([pscustomobject]@{
                    Id          = [guid]::NewGuid().ToString('N')
                    Name        = $nm
                    ClientDir   = $legacyClient
                    ServerDir   = $legacyServer
                    IgnoredMods = @($obj.IgnoredMods | Where-Object { $_ })
                    IgnoredInfo = @($obj.IgnoredInfo | Where-Object { $_ })
                }))
                Write-Log ('已把旧配置迁移为配置档「{0}」（含 {1} 个遗忘项）' -f $nm, @($obj.IgnoredMods).Count)
            }
            # 迁移后清掉旧字段，避免下次保存又把它们写回去
            $script:Config.ClientDir = ''
            $script:Config.ServerDir = ''
            $script:Config.IgnoredMods = @()
            $script:Config.IgnoredInfo = @()

            $ci = [int]$script:Config.CurrentProfile
            if ($ci -lt 0 -or $ci -ge @($script:Config.Profiles).Count) { $script:Config.CurrentProfile = 0 }
        }
    } catch {
        Write-Log ('读取配置失败，使用默认值：' + $_.Exception.Message)
    }
    # 兜底：至少有一个配置档，界面才有东西可操作
    if (@($script:Config.Profiles).Count -eq 0) {
        $script:Config.Profiles = @(New-ProfileObject ([pscustomobject]@{ Name = '默认整合包' }))
        $script:Config.CurrentProfile = 0
    }
}

function Get-DisplayPath([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return '' }
    $p = $p -replace '/', '\'
    $home2 = [Environment]::GetFolderPath('UserProfile')
    if ($home2 -and $p.StartsWith($home2, [StringComparison]::OrdinalIgnoreCase)) {
        return '%USERPROFILE%' + $p.Substring($home2.Length)
    }
    return $p
}

function Resolve-InputPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim().Trim('"')
    $p = [Environment]::ExpandEnvironmentVariables($p)
    return $p
}

function Get-BytesText([long]$n) {
    if ($n -ge 1073741824) { return ('{0:N2} GB' -f ($n / 1073741824)) }
    if ($n -ge 1048576)    { return ('{0:N2} MB' -f ($n / 1048576)) }
    if ($n -ge 1024)       { return ('{0:N1} KB' -f ($n / 1024)) }
    return "$n B"
}

# MD5 哈希（带缓存）
# 性能关键：必须走 C# 原生实现。
# 早先版本用 PowerShell 循环逐块调用 TransformBlock，处理 690 MB 需要 120 秒以上
# （脚本引擎搬运每个 1MB 块的代价太高），而 C# 原生只要约 2 秒，快 60 倍以上。
$script:HashCache = @{}
$script:HashImpl = 'unknown'

if (-not ('McSync.FastHash' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
namespace McSync {
    public static class FastHash {
        public static string Md5(string path) {
            try {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var md5 = MD5.Create()) {
                    return BitConverter.ToString(md5.ComputeHash(stream)).Replace("-", "");
                }
            } catch { return null; }
        }
    }
}
'@ -ErrorAction Stop
        $script:HashImpl = 'csharp'
    } catch {
        $script:HashImpl = 'powershell-fallback'
    }
} else {
    $script:HashImpl = 'csharp'
}

# CurseForge 文件指纹：MurmurHash2（seed=1），但要先把空白字节（9/10/13/32）剔除再算。
# 拿它去官方 API 反查"这个 jar 属于哪个项目"，是目前唯一能 100% 精确定位 CF 页面的办法。
# 走 C# 原生：要把整个 jar（几 MB）读一遍并按字节过滤，PowerShell 循环会慢到不可用。
$script:CfHashReady = $false
if (-not ('McSync.CfHash' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace McSync {
    public static class CfHash {
        public static uint Fingerprint(string path) {
            byte[] all;
            try {
                var fi = new FileInfo(path);
                if (fi.Length > 120L * 1024 * 1024) { return 0; }   // 超大文件不碰，避免内存尖峰
                all = File.ReadAllBytes(path);
            } catch { return 0; }
            byte[] buf = new byte[all.Length];
            int n = 0;
            for (int i = 0; i < all.Length; i++) {
                byte b = all[i];
                if (b == 9 || b == 10 || b == 13 || b == 32) { continue; }
                buf[n++] = b;
            }
            const uint m = 0x5bd1e995;
            const int r = 24;
            uint h = 1u ^ (uint)n;
            int k = 0, len = n;
            while (len >= 4) {
                uint kk = (uint)(buf[k] | (buf[k+1] << 8) | (buf[k+2] << 16) | (buf[k+3] << 24));
                kk *= m; kk ^= kk >> r; kk *= m;
                h *= m; h ^= kk;
                k += 4; len -= 4;
            }
            if (len == 3) { h ^= (uint)(buf[k+2] << 16); }
            if (len >= 2) { h ^= (uint)(buf[k+1] << 8); }
            if (len >= 1) { h ^= (uint)buf[k]; h *= m; }
            h ^= h >> 13; h *= m; h ^= h >> 15;
            return h;
        }
    }
}
'@ -ErrorAction Stop
        $script:CfHashReady = $true
    } catch {
        Write-Log ('CurseForge 指纹实现不可用（将退回名字匹配）：' + $_.Exception.Message)
    }
} else {
    $script:CfHashReady = $true
}

# 取 jar 的 CF 指纹；拿不到返回 0
function Get-CfFingerprint([string]$path) {
    if (-not $script:CfHashReady) { return 0 }
    try {
        $fp = [McSync.CfHash]::Fingerprint($path)
        if ($fp -eq 0) { return 0 }
        return [uint32]$fp
    } catch {
        Write-Log ('计算 CurseForge 指纹失败：' + $_.Exception.Message)
        return 0
    }
}

function Get-FileHashMd5([string]$path) {
    if ($script:HashCache.ContainsKey($path)) { return $script:HashCache[$path] }

    $result = $null
    if ($script:HashImpl -eq 'csharp') {
        $result = [McSync.FastHash]::Md5($path)
    } else {
        # 兜底实现：仅当 C# 编译不可用时使用（很慢，但功能可用）
        $stream = $null
        $md5 = $null
        try {
            $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $buffer = New-Object byte[] 1048576
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                if ($read -eq $buffer.Length) {
                    $md5.TransformBlock($buffer, 0, $read, $null, 0) | Out-Null
                } else {
                    $md5.TransformFinalBlock($buffer, 0, $read) | Out-Null
                }
            }
            if ($null -eq $md5.Hash) { $md5.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null }
            $result = ([BitConverter]::ToString($md5.Hash)).Replace('-', '')
        } catch {
            $result = $null
        } finally {
            if ($md5) { $md5.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }

    $script:HashCache[$path] = $result
    return $result
}

<#
 从文件名解析 mod 身份（base / key / version）
 例：journeymap-forge-1.20.1-5.9.18.jar
     base    = journeymap-forge-1.20.1-5.9.18
     key     = journeymap            （剥掉加载器、MC 版本、mod 版本，用于跨版本归组）
     version = 5.9.18
 这不是要 100% 解析所有命名风格（不存在这种正则），而是一个"够用且保守"的归组器：
 解析不出来时 key 退化为文件名本身，最坏结果只是退化成"按文件名严格比对"，不会误判。
#>
function Get-ModIdentity([string]$fileName) {
    $base = $fileName
    if ($base.ToLower().EndsWith('.jar')) { $base = $base.Substring(0, $base.Length - 4) }
    $key = $base
    $ver = ''

    $loaders  = 'forge|fabric|neoforge|quilt|liteloader'
    $mcpats   = '1\.(?:7|8|9|10|11|12|13|14|15|16|17|18|19|20|21)(?:\.\d{1,2}){0,2}'
    $mctag    = '(?:mc)?' + $mcpats
    # loader / MC 版本标签只允许出现在版本号之后（作为尾巴），避免误吃 mod 名里的字样
    $loaderRe = '(?i)(?:[-_+.](?:' + $loaders + '))(?=-|_|\+|\.|$)'
    $mcRe     = '(?i)(?:[-_+.](?:' + $mctag + '))(?=-|_|\+|\.|$)'

    # 1) 取 mod 版本号：跳过 MC 版本号（如 ...-forge-1.20.1-2.5.1 中应取 2.5.1）
    foreach ($m in [regex]::Matches($base, '(?<![\d.])(\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.]+)*)')) {
        $tail = $base.Substring($m.Index + $m.Length)
        if ($tail -match ('^' + $mctag + '(?=$|[-_+.])')) { continue }   # 是 MC 版本号，跳过
        if ($tail -match '^[a-zA-Z]') { continue }                      # 形如 1.20.1a，跳过
        $ver = $m.Groups[1].Value
        $key = $base.Substring(0, $m.Index)
        break
    }

    # 2) 剥掉尾部的加载器标签 / MC 版本号
    for ($i = 0; $i -lt 4; $i++) {
        $before = $key
        $key = $key -replace $loaderRe, ''
        $key = $key -replace $mcRe, ''
        if ($key -eq $before) { break }
    }
    $key = $key.Trim(' ', '-', '_', '+', '.')

    # 3) 保守兜底：剥太狠了就退回原文件名
    if ($key.Length -lt 2) { $key = $base }

    return @{ Base = $base; Key = $key.ToLower(); Version = $ver }
}

function Select-Folder([string]$title, [string]$initial) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $title
    $dlg.ShowNewFolderButton = $false
    if ($initial -and (Test-Path -LiteralPath $initial)) {
        try { $dlg.SelectedPath = $initial } catch { }
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

# ------------------------------------------------------------------ 同步目标 UI

# 端口文本框 → 整数（非法就退回默认 22）
function ConvertTo-PortOrDefault([string]$s, [int]$default = 22) {
    $n = 0
    if ([int]::TryParse(([string]$s).Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
    return $default
}

# 目标类型切换时更新界面：按钮文案 + 输入框提示
function Update-TargetUI {
    if (-not $cboTargetKind) { return }
    if ($cboTargetKind.SelectedIndex -eq 1) {
        $btnServer.Text = 'SFTP 设置...'
        $tipTarget.SetToolTip($txtServer, "远程服务器上的 mods 目录，例如 /mods 或 /home/container/mods`n点右边「SFTP 设置...」填主机 / 端口 / 用户名 / 密码。")
    } else {
        $btnServer.Text = '浏览...'
        $tipTarget.SetToolTip($txtServer, '服务端 mods 文件夹路径。局域网/共享目录可以填 \\192.168.1.100\mcserver\mods')
    }
}

# 把界面上的同步目标写回当前配置档（切档 / 新增档 / 关窗之前都要做）
function Save-TargetFromUI {
    if ($cboTargetKind.SelectedIndex -eq 1) {
        Set-CurProfileField 'TargetKind' 'Sftp'
        Set-CurProfileField 'SftpDir' (Normalize-RemoteDir $txtServer.Text)
    } else {
        Set-CurProfileField 'TargetKind' 'Local'
        Set-CurProfileField 'ServerDir' (Resolve-InputPath $txtServer.Text)
    }
}

# 界面上是否已经具备可扫描的目标端（决定启动/切档后要不要自动扫描）
function Test-TargetConfigured {
    if ([string]::IsNullOrWhiteSpace($txtServer.Text)) { return $false }
    if ($cboTargetKind.SelectedIndex -eq 1) {
        $p = Get-CurProfile
        return (-not [string]::IsNullOrWhiteSpace([string]$p.SftpHost))
    }
    return $true
}

# 从当前配置档拼一个 SFTP 目标（对话框里改完字段后用它去测试连接）
function New-SftpTargetFrom([string]$host, [string]$port, [string]$user, [string]$pass, [string]$dir) {
    return [pscustomobject]@{
        Kind = 'Sftp'
        Host = ([string]$host).Trim()
        Port = (ConvertTo-PortOrDefault $port 22)
        User = ([string]$user).Trim()
        Pass = [string]$pass
        Dir  = (Normalize-RemoteDir $dir)
    }
}

# SFTP 设置对话框。确定返回 @{Host;Port;User;Pass}，取消返回 $null。
function Show-SftpDialog {
    $p = Get-CurProfile

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'SFTP 设置 —— 远程服务器'
    $dlg.Size = New-Object System.Drawing.Size(600, 372)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '主机：'
    $l1.Location = New-Object System.Drawing.Point(14, 18)
    $l1.Size = New-Object System.Drawing.Size(80, 22)
    $l1.TextAlign = 'MiddleRight'
    $txtHost = New-Object System.Windows.Forms.TextBox
    $txtHost.Location = New-Object System.Drawing.Point(98, 18)
    $txtHost.Size = New-Object System.Drawing.Size(300, 24)
    $txtHost.Text = [string]$p.SftpHost

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '端口：'
    $l2.Location = New-Object System.Drawing.Point(406, 18)
    $l2.Size = New-Object System.Drawing.Size(52, 22)
    $l2.TextAlign = 'MiddleRight'
    $txtPort = New-Object System.Windows.Forms.TextBox
    $txtPort.Location = New-Object System.Drawing.Point(462, 18)
    $txtPort.Size = New-Object System.Drawing.Size(110, 24)
    $txtPort.Text = [string]$(if ($p.SftpPort) { $p.SftpPort } else { 22 })

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = '用户名：'
    $l3.Location = New-Object System.Drawing.Point(14, 54)
    $l3.Size = New-Object System.Drawing.Size(80, 22)
    $l3.TextAlign = 'MiddleRight'
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(98, 54)
    $txtUser.Size = New-Object System.Drawing.Size(300, 24)
    $txtUser.Text = [string]$p.SftpUser

    $l4 = New-Object System.Windows.Forms.Label
    $l4.Text = '密码：'
    $l4.Location = New-Object System.Drawing.Point(14, 90)
    $l4.Size = New-Object System.Drawing.Size(80, 22)
    $l4.TextAlign = 'MiddleRight'
    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(98, 90)
    $txtPass.Size = New-Object System.Drawing.Size(300, 24)
    $txtPass.UseSystemPasswordChar = $true
    $txtPass.Text = [string]$p.SftpPass

    $l5 = New-Object System.Windows.Forms.Label
    $l5.Text = '远程目录：'
    $l5.Location = New-Object System.Drawing.Point(14, 126)
    $l5.Size = New-Object System.Drawing.Size(80, 22)
    $l5.TextAlign = 'MiddleRight'
    $txtDir = New-Object System.Windows.Forms.TextBox
    $txtDir.Location = New-Object System.Drawing.Point(98, 126)
    $txtDir.Size = New-Object System.Drawing.Size(474, 24)
    $txtDir.Text = [string]$p.SftpDir

    $l6 = New-Object System.Windows.Forms.Label
    $l6.Location = New-Object System.Drawing.Point(14, 156)
    $l6.Size = New-Object System.Drawing.Size(558, 22)
    $l6.ForeColor = [System.Drawing.Color]::FromArgb(110, 115, 122)
    $l6.Text = '远程目录就是面板文件管理器里那个 mods 文件夹。不确定就先留空，点「测试连接」会列出登录后的目录。'

    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.Location = New-Object System.Drawing.Point(14, 182)
    $txtOut.Size = New-Object System.Drawing.Size(558, 108)
    $txtOut.Multiline = $true
    $txtOut.ReadOnly = $true
    $txtOut.ScrollBars = 'Vertical'
    $txtOut.BackColor = [System.Drawing.Color]::White
    $txtOut.Font = New-Object System.Drawing.Font('Consolas', 8.5)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试连接'
    $btnTest.Location = New-Object System.Drawing.Point(14, 298)
    $btnTest.Size = New-Object System.Drawing.Size(110, 30)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.Location = New-Object System.Drawing.Point(348, 298)
    $btnOk.Size = New-Object System.Drawing.Size(108, 30)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(464, 298)
    $btnCancel.Size = New-Object System.Drawing.Size(108, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.Controls.AddRange(@($l1, $txtHost, $l2, $txtPort, $l3, $txtUser, $l4, $txtPass,
                            $l5, $txtDir, $l6, $txtOut, $btnTest, $btnOk, $btnCancel))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $btnTest.Add_Click({
        $btnTest.Enabled = $false
        $txtOut.Text = '正在连接...'
        [System.Windows.Forms.Application]::DoEvents()
        $t = New-SftpTargetFrom $txtHost.Text $txtPort.Text $txtUser.Text $txtPass.Text $txtDir.Text
        $r = Test-TargetConnection $t
        $txtOut.Text = $r.Text
        $btnTest.Enabled = $true
    })

    $ret = $dlg.ShowDialog($form)
    if ($ret -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return $null }
    $out = @{
        Host = $txtHost.Text.Trim()
        Port = (ConvertTo-PortOrDefault $txtPort.Text 22)
        User = $txtUser.Text.Trim()
        Pass = [string]$txtPass.Text
        Dir  = (Normalize-RemoteDir $txtDir.Text)
    }
    $dlg.Dispose()
    return $out
}

# ------------------------------------------------------------------ 界面构建

# 主线程定时器：负责「延迟挂载文件监控」与「文件变动后的防抖重扫」
$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 1500
$watchTimer.Add_Tick({
    # 整个 Tick 包在 try/catch 里：定时器回调里逃逸的异常会危及进程
    try {
        # 0) 写盘类失败提示：配置存不下去、日志两路都写不进，
        #    这类失败原本是完全静默的，用户会误以为设置已经生效
        if ($script:CfgSaveFailed) {
            $script:CfgSaveFailed = $false
            $lblStatus.Text = '⚠ 配置保存失败，本次改动可能不会保留（详见日志）'
            return
        }
        if ($script:LastLogError) {
            $script:LastLogError = ''
            $lblStatus.Text = '⚠ 日志写入失败：两个日志路径都不可写'
            return
        }

        # 1) 监控自愈：目录被删除重建后重新挂载
        Test-WatcherAlive

        # 2) 首次扫描完成后才挂监控，避免启动阶段的事件重入
        #    挂载统一交给 Test-WatcherAlive 处理，避免重复挂载
        if ($script:PendingWatchStart -and -not $script:ScanInProgress) {
            $script:PendingWatchStart = $false
            Test-WatcherAlive
            return
        }
        # 3) 文件变动停止一段时间后自动重扫
        if (-not $script:PendingScan) { return }
        if ($script:ScanInProgress) { return }
        if ((([datetime]::Now) - $script:LastChange).TotalMilliseconds -lt 3000) { return }
        $script:PendingScan = $false
        if (-not $chkWatch.Checked) { return }
        $lblStatus.Text = '检测到客户端 mods 有变动，正在自动重新扫描...'
        Invoke-Scan
    } catch {
        try { Write-Log ('自动重扫异常（已忽略）：' + $_.Exception.ToString()) } catch { }
        try { $lblStatus.Text = '自动重扫出错，已跳过（详情见日志）' } catch { }
    }
})

# UI 线程兜底：WinForms 默认在 UI 线程未处理异常时直接结束进程。
# 这里接管掉，改为记录日志 + 提示，程序继续存活。
# 关键：必须在创建任何窗口之前注册，所以放在 Form 构造之前。
$null = [System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    $msg = $e.Exception.Message
    try { Write-Log ('UI 线程异常（已拦截，程序继续运行）：' + $e.Exception.ToString()) } catch { }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            ("刚才的操作出了点问题，程序会继续运行。`n`n{0}`n`n详细信息已写入日志。" -f $msg),
            'ModSync 提示', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } catch { }
    try { $e.ExceptionHandled = $true } catch { }
})

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Minecraft Mod 同步工具  ·  ModSync'

# 从多尺寸 ICO 里取出最大的一张（256x256）来构造 Icon。
# 直接 New-Object Icon($path) 只会拿到 32x32，放进任务栏会发虚。
try {
    $iconIco = $env:MODSYNC_ICON_ICO
    if ($iconIco -and (Test-Path -LiteralPath $iconIco)) {
        $ib = [System.IO.File]::ReadAllBytes($iconIco)
        $cnt = [BitConverter]::ToUInt16($ib, 4)
        $bestSize = -1; $bestOff = 0; $bestLen = 0
        for ($k = 0; $k -lt $cnt; $k++) {
            $o = 6 + $k * 16
            $w = $ib[$o]; if ($w -eq 0) { $w = 256 }
            $len = [BitConverter]::ToUInt32($ib, $o + 8)
            $off = [BitConverter]::ToUInt32($ib, $o + 12)
            if ($w -gt $bestSize -and $len -gt 0) { $bestSize = $w; $bestOff = $off; $bestLen = $len }
        }
        $pngBytes = New-Object byte[] $bestLen
        [Array]::Copy($ib, [int]$bestOff, $pngBytes, 0, [int]$bestLen)
        $bmp = New-Object System.Drawing.Bitmap((New-Object System.IO.MemoryStream(,$pngBytes)))
        $form.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        Write-Log ('窗口图标已加载：取 ICO 中最大尺寸 {0}x{0}' -f $bestSize)
        $bmp.Dispose()
    } else {
        Write-Log '未拿到窗口图标（环境变量缺失），窗口将显示默认图标'
    }
} catch {
    try { Write-Log ('加载窗口图标失败：' + $_.Exception.Message) } catch { }
}

# 任务栏图标归属：窗口跑在 powershell.exe 子进程里，不显式声明身份的话，
# 任务栏会把图标回退成宿主 powershell.exe 的图标。这里给进程一个独立 AppUserModelID。
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace McSync {
    public static class AppId {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
        public static void Set(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch { } }
    }
}
'@ -ErrorAction SilentlyContinue
    if ('McSync.AppId' -as [type]) { [McSync.AppId]::Set('McModSync.Tool') }
} catch { }

# 及时清掉，避免子进程环境里残留一个已删除的临时路径
try { $env:MODSYNC_ICON_ICO = $null } catch { }

$form.Size = New-Object System.Drawing.Size(1180, 720)
$form.MinimumSize = New-Object System.Drawing.Size(960, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# --- 路径配置区 ---
$grpPath = New-Object System.Windows.Forms.GroupBox
$grpPath.Text = ' 配置档与文件夹（自动保存） '
$grpPath.Location = New-Object System.Drawing.Point(12, 8)
$grpPath.Size = New-Object System.Drawing.Size(1140, 178)
$grpPath.Anchor = 'Top,Left,Right'
$grpPath.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# --- 第 1 行：配置档（一个整合包 + 一个服务端 = 一套路径）---
$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Text = '配置档：'
$lblProfile.Location = New-Object System.Drawing.Point(14, 25)
$lblProfile.Size = New-Object System.Drawing.Size(94, 22)
$lblProfile.TextAlign = 'MiddleRight'

$cboProfile = New-Object System.Windows.Forms.ComboBox
$cboProfile.Location = New-Object System.Drawing.Point(112, 24)
$cboProfile.Size = New-Object System.Drawing.Size(300, 24)
$cboProfile.DropDownStyle = 'DropDownList'
$cboProfile.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$btnProfAdd = New-Object System.Windows.Forms.Button
$btnProfAdd.Text = '新增'
$btnProfAdd.Location = New-Object System.Drawing.Point(420, 23)
$btnProfAdd.Size = New-Object System.Drawing.Size(66, 26)

$btnProfRename = New-Object System.Windows.Forms.Button
$btnProfRename.Text = '重命名'
$btnProfRename.Location = New-Object System.Drawing.Point(490, 23)
$btnProfRename.Size = New-Object System.Drawing.Size(74, 26)

$btnProfDel = New-Object System.Windows.Forms.Button
$btnProfDel.Text = '删除'
$btnProfDel.Location = New-Object System.Drawing.Point(568, 23)
$btnProfDel.Size = New-Object System.Drawing.Size(66, 26)

$lblC = New-Object System.Windows.Forms.Label
$lblC.Text = '客户端 mods：'
$lblC.Location = New-Object System.Drawing.Point(14, 61)
$lblC.Size = New-Object System.Drawing.Size(94, 22)
$lblC.TextAlign = 'MiddleRight'

$txtClient = New-Object System.Windows.Forms.TextBox
$txtClient.Location = New-Object System.Drawing.Point(112, 61)
$txtClient.Size = New-Object System.Drawing.Size(900, 24)
$txtClient.Anchor = 'Top,Left,Right'

$btnClient = New-Object System.Windows.Forms.Button
$btnClient.Text = '浏览...'
$btnClient.Location = New-Object System.Drawing.Point(1020, 60)
$btnClient.Size = New-Object System.Drawing.Size(104, 26)
$btnClient.Anchor = 'Top,Right'

$lblS = New-Object System.Windows.Forms.Label
$lblS.Text = '同步目标：'
$lblS.Location = New-Object System.Drawing.Point(14, 95)
$lblS.Size = New-Object System.Drawing.Size(94, 22)
$lblS.TextAlign = 'MiddleRight'

# 同步目标类型：本地/网络文件夹，或 SFTP 远程服务器（简幻欢这类托管平台给的就是 SFTP）
$cboTargetKind = New-Object System.Windows.Forms.ComboBox
$cboTargetKind.DropDownStyle = 'DropDownList'
$cboTargetKind.Location = New-Object System.Drawing.Point(112, 95)
$cboTargetKind.Size = New-Object System.Drawing.Size(150, 24)
$cboTargetKind.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
[void]$cboTargetKind.Items.Add('本地 / 网络文件夹')
[void]$cboTargetKind.Items.Add('SFTP 远程服务器')
$cboTargetKind.SelectedIndex = 0

$txtServer = New-Object System.Windows.Forms.TextBox
$txtServer.Location = New-Object System.Drawing.Point(270, 95)
$txtServer.Size = New-Object System.Drawing.Size(742, 24)
$txtServer.Anchor = 'Top,Left,Right'

$btnServer = New-Object System.Windows.Forms.Button
$btnServer.Text = '浏览...'
$btnServer.Location = New-Object System.Drawing.Point(1020, 94)
$btnServer.Size = New-Object System.Drawing.Size(104, 26)
$btnServer.Anchor = 'Top,Right'

$tipTarget = New-Object System.Windows.Forms.ToolTip
$tipTarget.SetToolTip($txtServer, '服务端 mods 文件夹路径。局域网/共享目录可以填 \\192.168.1.100\mcserver\mods')

$chkHash = New-Object System.Windows.Forms.CheckBox
$chkHash.Text = '启用 MD5 精确校验（更准，稍慢）'
$chkHash.Location = New-Object System.Drawing.Point(112, 121)
$chkHash.Size = New-Object System.Drawing.Size(250, 22)
$chkHash.Checked = $true

$chkWatch = New-Object System.Windows.Forms.CheckBox
$chkWatch.Text = '实时监控客户端文件夹，PCL2 更新后自动扫描'
$chkWatch.Location = New-Object System.Drawing.Point(374, 121)
$chkWatch.Size = New-Object System.Drawing.Size(320, 22)
$chkWatch.Checked = $true

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = '覆盖前备份服务端旧文件为 .bak'
$chkBackup.Location = New-Object System.Drawing.Point(706, 121)
$chkBackup.Size = New-Object System.Drawing.Size(260, 22)

# 重命名同步：内容完全相同、只有文件名不同的 mod，认出来后直接把服务端那个文件也改名。
# 关掉则退回旧行为（当成"新增"处理，服务端旧名文件会留成多余文件）。
$chkRename = New-Object System.Windows.Forms.CheckBox
$chkRename.Text = '识别重命名并自动同步：我给 mod 改名后，自动把服务端同名文件一起改名（双端文件名保持一致）'
$chkRename.Location = New-Object System.Drawing.Point(112, 147)
$chkRename.Size = New-Object System.Drawing.Size(700, 22)
$chkRename.Checked = $true

# CurseForge API Key（可选）：填了才能用文件指纹 100% 精确地直达 CF 的 mod 页面。
# 只写进本机配置文件，不进项目目录、不写日志。
$lblCfKey = New-Object System.Windows.Forms.Label
$lblCfKey.Text = 'CurseForge Key：'
$lblCfKey.Location = New-Object System.Drawing.Point(812, 147)
$lblCfKey.Size = New-Object System.Drawing.Size(116, 22)
$lblCfKey.TextAlign = 'MiddleRight'

$txtCfKey = New-Object System.Windows.Forms.TextBox
$txtCfKey.Location = New-Object System.Drawing.Point(934, 146)
$txtCfKey.Size = New-Object System.Drawing.Size(198, 24)
$txtCfKey.UseSystemPasswordChar = $true

$tipCfKey = New-Object System.Windows.Forms.ToolTip
$tipCfKey.SetToolTip($txtCfKey, "可选。填了才能一键直达 CurseForge 的 mod 页面（用文件指纹精确匹配）。`n申请地址：https://console.curseforge.com/`n只保存在本机配置文件里。")

$grpPath.Controls.AddRange(@($lblProfile, $cboProfile, $btnProfAdd, $btnProfRename, $btnProfDel,
                            $lblC, $txtClient, $btnClient, $lblS, $cboTargetKind, $txtServer, $btnServer,
                            $chkHash, $chkWatch, $chkBackup, $chkRename, $lblCfKey, $txtCfKey))

# --- 工具栏 ---
$bar = New-Object System.Windows.Forms.Panel
$bar.Location = New-Object System.Drawing.Point(12, 190)
$bar.Size = New-Object System.Drawing.Size(1140, 38)
$bar.Anchor = 'Top,Left,Right'

function New-ToolButton([string]$text, [int]$x, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 4)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    return $b
}

$btnScan     = New-ToolButton '扫描比对 (F5)' 0 130
$btnSelectAll = New-ToolButton '全选' 138 64
$btnUnselect = New-ToolButton '全不选' 206 64
$btnInvert   = New-ToolButton '反选' 274 64
$btnSelectPending = New-ToolButton '只选变更项' 342 98
$btnSync     = New-ToolButton '同步到服务端' 448 118
$btnRefresh  = New-ToolButton '重新扫描' 570 90
$btnOpenLog  = New-ToolButton '打开日志' 668 90
$btnForget   = New-ToolButton '遗忘选中项' 766 96
$btnIgnored  = New-ToolButton '遗忘管理' 868 88
$btnRenameMod = New-ToolButton '重命名选中项' 962 108
$btnOnline   = New-ToolButton '在线页面' 1074 64

$btnSync.Enabled = $false
$bar.Controls.AddRange(@($btnScan, $btnSelectAll, $btnUnselect, $btnInvert, $btnSelectPending, $btnSync, $btnRefresh, $btnOpenLog, $btnForget, $btnIgnored, $btnRenameMod, $btnOnline))

# --- 结果表格 ---
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(12, 232)
$grid.Size = New-Object System.Drawing.Size(1140, 388)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'None'
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 30
$grid.RowTemplate.Height = 24
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.GridColor = [System.Drawing.Color]::FromArgb(225, 228, 232)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersDefaultCellStyle.Alignment = 'MiddleLeft'
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 252)

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.HeaderText = '同步'
$colCheck.Width = 44
$colCheck.SortMode = 'NotSortable'
$colCheck.Resizable = 'False'

$colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colState.HeaderText = '状态'
$colState.Width = 110
$colState.ReadOnly = $true

$colFile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFile.HeaderText = '客户端文件名'
$colFile.Width = 430
$colFile.ReadOnly = $true

$colAct = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colAct.HeaderText = '操作说明'
$colAct.Width = 250
$colAct.ReadOnly = $true

$colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSize.HeaderText = '大小'
$colSize.Width = 90
$colSize.ReadOnly = $true
$colSize.DefaultCellStyle.Alignment = 'MiddleRight'

$colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTime.HeaderText = '修改时间'
$colTime.Width = 130
$colTime.ReadOnly = $true

$colResult = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colResult.HeaderText = '同步结果'
$colResult.AutoSizeMode = 'Fill'
$colResult.FillWeight = 100
$colResult.MinimumWidth = 120
$colResult.ReadOnly = $true

[void]$grid.Columns.Add($colCheck)
[void]$grid.Columns.Add($colState)
[void]$grid.Columns.Add($colFile)
[void]$grid.Columns.Add($colAct)
[void]$grid.Columns.Add($colSize)
[void]$grid.Columns.Add($colTime)
[void]$grid.Columns.Add($colResult)

# --- 表格右键菜单：定位到文件 / 详情 / 重命名 ---
# 「打开位置」用 explorer.exe /select 精确选中那个 jar —— 整合包路径常带空格，
# 所以参数在 Open-FileLocation 里用 ProcessStartInfo 直接拼，绕开 PowerShell 的引号处理。
$script:MenuRec = $null

$miOpenClient = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenClient.Text = '打开客户端文件位置（定位到该 jar）'
$miOpenServer = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenServer.Text = '打开服务端文件位置（定位到该 jar）'
$miOpenServerDir = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenServerDir.Text = '打开服务端 mods 文件夹'
$miRename = New-Object System.Windows.Forms.ToolStripMenuItem
$miRename.Text = '重命名这个 mod…（客户端 + 服务端一起改名）'
$miDetail = New-Object System.Windows.Forms.ToolStripMenuItem
$miDetail.Text = '查看文件详情'
$miCopyPath = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopyPath.Text = '复制客户端完整路径'
$miCopyServerPath = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopyServerPath.Text = '复制服务端完整路径'
$miCopyName = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopyName.Text = '复制文件名'

# --- 二级子菜单：打开在线页面（MC百科 / CurseForge / Modrinth）---
$miOpenMcmod = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenMcmod.Text = 'MC 百科'
$miOpenCf = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenCf.Text = 'CurseForge'
$miOpenMr = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenMr.Text = 'Modrinth'
$miOnline = New-Object System.Windows.Forms.ToolStripMenuItem
$miOnline.Text = '打开在线页面'
[void]$miOnline.DropDownItems.Add($miOpenMcmod)
[void]$miOnline.DropDownItems.Add($miOpenCf)
[void]$miOnline.DropDownItems.Add($miOpenMr)

# --- 二级子菜单：复制 ---
$miCopy = New-Object System.Windows.Forms.ToolStripMenuItem
$miCopy.Text = '复制'
[void]$miCopy.DropDownItems.Add($miCopyName)
[void]$miCopy.DropDownItems.Add($miCopyPath)
[void]$miCopy.DropDownItems.Add($miCopyServerPath)
$miBatchRename = New-Object System.Windows.Forms.ToolStripMenuItem
$miBatchRename.Text = '批量重命名勾选的 mod…（统一加前缀）'
$miForget = New-Object System.Windows.Forms.ToolStripMenuItem
$miForget.Text = '遗忘这个 mod（以后不再出现在结果里）'

$menuGrid = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menuGrid.Items.Add($miOpenClient)
[void]$menuGrid.Items.Add($miOpenServer)
[void]$menuGrid.Items.Add($miOpenServerDir)
[void]$menuGrid.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuGrid.Items.Add($miRename)
[void]$menuGrid.Items.Add($miBatchRename)
[void]$menuGrid.Items.Add($miDetail)
[void]$menuGrid.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuGrid.Items.Add($miOnline)
[void]$menuGrid.Items.Add($miCopy)
[void]$menuGrid.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuGrid.Items.Add($miForget)
$grid.ContextMenuStrip = $menuGrid

# 工具栏「在线页面」按钮专用的迷你菜单。
# 为什么单独做一个 ContextMenuStrip：子菜单的 DropDown 直接 Show() 时定位不可靠
# （窗口没有焦点时会停在 0,0，也就是屏幕左上角），而 ContextMenuStrip.Show(控件, 点) 稳定。
$qMcmod = New-Object System.Windows.Forms.ToolStripMenuItem
$qMcmod.Text = 'MC 百科'
$qCf = New-Object System.Windows.Forms.ToolStripMenuItem
$qCf.Text = 'CurseForge'
$qMr = New-Object System.Windows.Forms.ToolStripMenuItem
$qMr.Text = 'Modrinth'
$menuOnlineQuick = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menuOnlineQuick.Items.Add($qMcmod)
[void]$menuOnlineQuick.Items.Add($qCf)
[void]$menuOnlineQuick.Items.Add($qMr)

# 右键先选中该行（同时记下这一行的记录，供菜单动作使用）
$grid.Add_CellMouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    if ($e.RowIndex -lt 0) { $script:MenuRec = $null; return }
    $script:MenuRec = $grid.Rows[$e.RowIndex].Tag
    if ($e.ColumnIndex -gt 0) {
        $grid.ClearSelection()
        $grid.Rows[$e.RowIndex].Selected = $true
    }
})

$menuGrid.Add_Opening({
    param($sender, $e)
    # 键盘调出菜单（或右键落点不明）时，退回到当前选中行
    if (-not $script:MenuRec -and $grid.SelectedRows.Count -gt 0) { $script:MenuRec = $grid.SelectedRows[0].Tag }
    if (-not $script:MenuRec) { $e.Cancel = $true; return }
    $srv = Get-ServerFileForRecord $script:MenuRec
    $isSftp = ($cboTargetKind.SelectedIndex -eq 1)
    if ($isSftp) {
        # 远程路径没法用资源管理器"定位"，这两项灰掉；复制路径仍然可用
        $miOpenServer.Enabled = $false
        $miOpenServer.ToolTipText = '远程（SFTP）服务器上的文件，资源管理器定位不了；用「复制 ▸ 服务端完整路径」'
        $miOpenServerDir.Enabled = $false
        $miCopyServerPath.Enabled = [bool]$srv
    } else {
        $miOpenServer.Enabled = [bool]$srv
        $miOpenServer.ToolTipText = $(if ($srv) { $srv } else { '服务端没有这个 mod 的对应文件' })
        $miCopyServerPath.Enabled = [bool]$srv
        $miOpenServerDir.Enabled = [bool](Resolve-InputPath $txtServer.Text)
    }

    # 「批量重命名」要勾选 ≥2 个才有意义，没勾够就灰掉并说明怎么用
    $nChecked = @($grid.Rows | Where-Object { $_.Tag -and [bool]$_.Cells[0].Value }).Count
    $miBatchRename.Enabled = ($nChecked -ge 2)
    $miBatchRename.Text = $(if ($nChecked -ge 2) { "批量重命名勾选的 $nChecked 个 mod…（统一加前缀）" }
                            else { '批量重命名勾选的 mod…（先在「同步」列勾选 ≥2 个）' })
})

$miOpenClient.Add_Click({ Open-FileLocation $script:MenuRec.SrcPath })
$miOpenServer.Add_Click({
    $srv = Get-ServerFileForRecord $script:MenuRec
    if ($srv) { Open-FileLocation $srv }
})
$miOpenServerDir.Add_Click({
    $d = Resolve-InputPath $txtServer.Text
    if ($d) { Open-FileLocation $d }
})
$miRename.Add_Click({ Rename-Record $script:MenuRec })
$miDetail.Add_Click({ Show-RecordDetail $script:MenuRec })
$miCopyPath.Add_Click({
    if (-not $script:MenuRec) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$script:MenuRec.SrcPath)
        $lblStatus.Text = "已复制路径：$($script:MenuRec.SrcPath)"
    } catch {
        Write-Log ('复制路径失败：' + $_.Exception.Message)
    }
})
$miCopyServerPath.Add_Click({
    $srv = Get-ServerFileForRecord $script:MenuRec
    if (-not $srv) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$srv)
        $lblStatus.Text = "已复制服务端路径：$srv"
    } catch {
        Write-Log ('复制服务端路径失败：' + $_.Exception.Message)
    }
})
$miCopyName.Add_Click({
    if (-not $script:MenuRec) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$script:MenuRec.FileName)
        $lblStatus.Text = "已复制文件名：$($script:MenuRec.FileName)"
    } catch {
        Write-Log ('复制文件名失败：' + $_.Exception.Message)
    }
})
$miOpenMcmod.Add_Click({ Open-ModSite 'mcmod' })
$miOpenCf.Add_Click({ Open-ModSite 'curseforge' })
$miOpenMr.Add_Click({ Open-ModSite 'modrinth' })

# 工具栏迷你菜单：作用于"当前选中行"
$qMcmod.Add_Click({ [void](Open-ModSiteForSelected 'mcmod') })
$qCf.Add_Click({ [void](Open-ModSiteForSelected 'curseforge') })
$qMr.Add_Click({ [void](Open-ModSiteForSelected 'modrinth') })

# 工具栏「在线页面」：对当前选中的那一行弹出站点菜单（不用右键也能跳）
$btnOnline.Add_Click({
    $rec = $null
    if ($grid.SelectedRows.Count -gt 0) { $rec = $grid.SelectedRows[0].Tag }
    if (-not $rec) {
        [void](Open-ModSiteForSelected 'mcmod')   # 借它的提示（会告诉用户怎么选行）
        return
    }
    $script:MenuRec = $rec
    # 弹出位置：贴在按钮"正右方"（菜单左上角 = 按钮右上角再往右 2px），鼠标往右一挪就能点。
    # 用独立 ContextMenuStrip（定位可靠）；若右侧实在放不下（窗口贴着屏幕右缘），
    # 退成"按钮正下方、右边缘对齐"，保证一定看得见。
    $ps = $menuOnlineQuick.PreferredSize
    $btnRect = $btnOnline.RectangleToScreen($btnOnline.ClientRectangle)
    $scr = [System.Windows.Forms.Screen]::FromControl($btnOnline).WorkingArea
    if (($btnRect.Right + 2 + $ps.Width) -le $scr.Right) {
        $menuOnlineQuick.Show($btnOnline, (New-Object System.Drawing.Point(($btnOnline.Width + 2), 0)))
    } else {
        $formRect = $form.RectangleToScreen($form.ClientRectangle)
        $offX = $btnOnline.Width - $ps.Width
        if (($btnRect.Left + $offX) -lt $formRect.Left) { $offX = $formRect.Left - $btnRect.Left }
        $menuOnlineQuick.Show($btnOnline, (New-Object System.Drawing.Point($offX, $btnOnline.Height)))
    }
})

$tipOnline = New-Object System.Windows.Forms.ToolTip
$tipOnline.SetToolTip($btnOnline, "对当前选中（或右键）的那一行，打开 MC百科 / CurseForge / Modrinth 的 mod 页面。`n快捷键：Ctrl+1 = MC百科，Ctrl+2 = CurseForge，Ctrl+3 = Modrinth")
$miBatchRename.Add_Click({
    $checked = @($grid.Rows | Where-Object { $_.Tag -and [bool]$_.Cells[0].Value } | ForEach-Object { $_.Tag })
    if ($checked.Count -lt 2) {
        [System.Windows.Forms.MessageBox]::Show('请先在「同步」列勾选至少 2 个 mod，再点批量重命名。', '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Rename-Batch $checked
})
$miForget.Add_Click({ Forget-Records @($script:MenuRec) })

$lblEmpty = New-Object System.Windows.Forms.Label
$lblEmpty.Text = '尚未扫描。请先填写上面两个文件夹路径，然后点「扫描比对」或按 F5。'
$lblEmpty.ForeColor = [System.Drawing.Color]::Gray
$lblEmpty.BackColor = [System.Drawing.Color]::White
$lblEmpty.AutoSize = $false
$lblEmpty.TextAlign = 'MiddleCenter'
$lblEmpty.Location = New-Object System.Drawing.Point(12, 232)
$lblEmpty.Size = New-Object System.Drawing.Size(1140, 388)
$lblEmpty.Anchor = 'Top,Bottom,Left,Right'

# --- 状态栏 ---
$status = New-Object System.Windows.Forms.StatusStrip
$status.SizingGrip = $false
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = '就绪'
$lblStatus.Spring = $true
$lblStatus.TextAlign = 'MiddleLeft'
$progress = New-Object System.Windows.Forms.ToolStripProgressBar
$progress.Width = 220
$progress.Visible = $false
[void]$status.Items.Add($lblStatus)
[void]$status.Items.Add($progress)

$form.Controls.AddRange(@($grpPath, $bar, $grid, $lblEmpty, $status))

# ------------------------------------------------------------------ 配置档管理

# 每档独立保存自己的遗忘清单，避免在 A 整合包遗忘的 mod 影响到 B 整合包
function Refresh-ProfileCombo {
    $script:IgnoreProfileEvent = $true
    try {
        $names = @()
        foreach ($p in @($script:Config.Profiles)) { $names += [string]$p.Name }
        $cboProfile.Items.Clear()
        foreach ($n in $names) { [void]$cboProfile.Items.Add($n) }
        $idx = [int]$script:Config.CurrentProfile
        if ($idx -lt 0 -or $idx -ge $names.Count) { $idx = 0 }
        if ($names.Count -gt 0) { $cboProfile.SelectedIndex = $idx }
    } finally {
        $script:IgnoreProfileEvent = $false
    }
}

function Load-CurrentProfileToUI {
    $p = Get-CurProfile
    if (-not $p) { return }
    $txtClient.Text = $(if ($p.ClientDir) { Get-DisplayPath $p.ClientDir } else { '' })
    # 目标类型决定这个框里放什么：本地路径（缩写显示）还是远程目录。
    # 程序化改下拉框会触发 SelectedIndexChanged，用标志位压掉，否则会来回互相覆盖。
    $script:IgnoreTargetEvent = $true
    try {
        if ([string]$p.TargetKind -eq 'Sftp') {
            $cboTargetKind.SelectedIndex = 1
            $txtServer.Text = [string]$p.SftpDir
        } else {
            $cboTargetKind.SelectedIndex = 0
            $txtServer.Text = $(if ($p.ServerDir) { Get-DisplayPath $p.ServerDir } else { '' })
        }
    } finally {
        $script:IgnoreTargetEvent = $false
    }
    Update-TargetUI
    # 切了配置档，之前解析好的目标端作废
    $script:ActiveTarget = $null
    Disconnect-SftpTarget
}

function Switch-Profile([int]$idx) {
    if ($idx -lt 0 -or $idx -ge @($script:Config.Profiles).Count) { return }
    if ($idx -eq [int]$script:Config.CurrentProfile) { return }

    # 先保存当前档的路径，再切过去
    Set-CurProfileField 'ClientDir' (Resolve-InputPath $txtClient.Text)
    Save-TargetFromUI
    $script:Config.CurrentProfile = $idx
    Write-Cfg
    Load-CurrentProfileToUI
    $script:IgnoredCount = 0
    Write-Log ('切换配置档 -> 「{0}」 | 客户端={1} | 目标={2}' -f (Get-CurProfile).Name, (Get-CurClientDir), (Get-TargetLabel (Get-CurTarget)))

    # 换文件夹后监控要重挂，随即重新扫描
    try { if ($script:Watcher) { $script:Watcher.Dispose(); $script:Watcher = $null } } catch { }
    $script:WatcherDir = ''
    $script:PendingWatchStart = $true
    if ($txtClient.Text -and (Test-TargetConfigured)) {
        Invoke-Scan
    } else {
        $lblStatus.Text = '该配置档还没设置好同步目标，请先选择'
    }
}

function Add-Profile {
    $name = Show-InputBox '新增配置档' '给这个配置档起个名字（例如整合包名）：' (Get-DefaultProfileName)
    if ($null -eq $name) { return }
    $name = $name.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.Forms.MessageBox]::Show('名称不能为空。', '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    # 保存当前档，然后追加新档并切过去
    Set-CurProfileField 'ClientDir' (Resolve-InputPath $txtClient.Text)
    Save-TargetFromUI
    $list = @($script:Config.Profiles)
    # 用 New-ProfileObject 而不是手写对象：字段齐全，以后再加字段也不会漏
    $list += (New-ProfileObject ([pscustomobject]@{ Name = $name }))
    $script:Config.Profiles = $list
    $script:Config.CurrentProfile = $list.Count - 1
    Write-Cfg
    Refresh-ProfileCombo
    Load-CurrentProfileToUI
    $grid.Rows.Clear()
    $script:Records = @()
    $script:AllRecords = @()
    $btnSync.Enabled = $false
    Write-Log ('新增配置档「{0}」' -f $name)
    $lblStatus.Text = "已新增配置档「$name」，请选择它的客户端与服务端文件夹"
}

function Rename-Profile {
    $p = Get-CurProfile
    if (-not $p) { return }
    $name = Show-InputBox '重命名配置档' '输入新的名称：' $p.Name
    if ($null -eq $name) { return }
    $name = $name.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $old = $p.Name
    Set-CurProfileField 'Name' $name
    Write-Cfg
    Refresh-ProfileCombo
    Write-Log ('配置档重命名：「{0}」->「{1}」' -f $old, $name)
    $lblStatus.Text = "配置档已重命名为「$name」"
}

function Remove-Profile {
    $list = @($script:Config.Profiles)
    if ($list.Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show('至少要保留一个配置档，无法删除。', '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $p = Get-CurProfile
    $ignoredN = @($p.IgnoredMods).Count
    $msg = "确定删除配置档「{0}」吗？`n`n客户端：{1}`n服务端：{2}" -f $p.Name,
        $(if ($p.ClientDir) { $p.ClientDir } else { '(未设置)' }),
        $(if ($p.ServerDir) { $p.ServerDir } else { '(未设置)' })
    if ($ignoredN -gt 0) { $msg += "`n`n该档的 $ignoredN 个遗忘记录也会一并删除。" }
    $msg += "`n`n（只删除配置记录，不会动你磁盘上的任何 mod 文件）"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '删除配置档',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $idx = [int]$script:Config.CurrentProfile
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $idx) { [void]$keep.Add($list[$i]) } }
    $script:Config.Profiles = @($keep)
    if ($idx -ge @($keep).Count) { $idx = @($keep).Count - 1 }
    if ($idx -lt 0) { $idx = 0 }
    $script:Config.CurrentProfile = $idx
    Write-Cfg
    Refresh-ProfileCombo
    Load-CurrentProfileToUI
    Write-Log ('删除配置档「{0}」' -f $p.Name)
    try { if ($script:Watcher) { $script:Watcher.Dispose(); $script:Watcher = $null } } catch { }
    $script:WatcherDir = ''
    $script:PendingWatchStart = $true
    if ($txtClient.Text -and $txtServer.Text) { Invoke-Scan }
}

# 通用单行输入框（改名 / 新增配置档用）
function Show-InputBox([string]$title, [string]$prompt, [string]$default) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $title
    $dlg.Size = New-Object System.Drawing.Size(460, 190)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $prompt
    $lbl.Location = New-Object System.Drawing.Point(16, 14)
    $lbl.Size = New-Object System.Drawing.Size(412, 22)
    $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(16, 42)
    $tb.Size = New-Object System.Drawing.Size(412, 24)
    $tb.Text = $default
    $tb.SelectAll()
    $dlg.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.Location = New-Object System.Drawing.Point(214, 92)
    $ok.Size = New-Object System.Drawing.Size(100, 32)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(328, 92)
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $ret = $dlg.ShowDialog($form)
    $val = $tb.Text
    $dlg.Dispose()
    if ($ret -eq [System.Windows.Forms.DialogResult]::OK) { return $val } else { return $null }
}

# ------------------------------------------------------------------ 遗忘管理

# 按身份标识（key）过滤，这样同一个 mod 以后即使换了版本号，也不会再冒出来
function Apply-IgnoredFilter {
    $ignored = @{}
    foreach ($k in @(Get-IgnoredMods)) {
        if ($k) { $ignored[[string]$k] = $true }
    }
    if ($ignored.Count -eq 0) {
        $script:Records = @($script:AllRecords)
        $script:IgnoredCount = 0
        return
    }
    $keep = New-Object System.Collections.ArrayList
    $hidden = 0
    foreach ($r in $script:AllRecords) {
        if ($ignored.ContainsKey($r.Key)) { $hidden++ } else { [void]$keep.Add($r) }
    }
    $script:Records = @($keep)
    $script:IgnoredCount = $hidden
}

# 确认对话框（自绘）
# 不能用 MessageBox：待确认的 mod 一多，文本会把对话框撑得超出屏幕，
# 按钮被挤出可视区域点不到（这正是"选太多就点不到确定"的原因）。
# 通用明细确认对话框（同步 / 遗忘共用）
# 不用 MessageBox：它会被长内容撑得超出屏幕，把按钮挤出可视区域。
# 这里固定窗口尺寸，条目默认折叠 10 条，可展开、可滚动，按钮位置恒定。
function Show-ListConfirm {
    param(
        [string]$Title = '确认',
        [string]$Prompt = '',
        [object[]]$Items = @(),
        [string]$OkText = '确定',
        [System.Drawing.Color]$ItemColor = [System.Drawing.Color]::Black,
        [string]$Note = ''
    )

    $script:confirmExpanded = $false
    $collapsedMax = 10
    $total = @($Items).Count

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    # 注意：Size 是窗口总高度，实测客户区会少掉 39px（标题栏+边框）。
    # 底部按钮底边在 y=566，故总高需 ≥ 605；这里取 620 留出余量。
    $dlg.Size = New-Object System.Drawing.Size(660, 620)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = $Prompt
    $l1.Location = New-Object System.Drawing.Point(16, 14)
    $l1.Size = New-Object System.Drawing.Size(612, 24)
    $dlg.Controls.Add($l1)

    # 可滚动容器：条目再多也能滚着看完，不会超出对话框
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(16, 42)
    $panel.Size = New-Object System.Drawing.Size(612, 408)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'
    $panel.AutoScroll = $true
    $dlg.Controls.Add($panel)

    $list = New-Object System.Windows.Forms.Label
    $list.AutoSize = $false
    $list.BackColor = [System.Drawing.Color]::White
    $list.Location = New-Object System.Drawing.Point(0, 0)
    $list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $list.TextAlign = 'TopLeft'
    $list.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $list.ForeColor = $ItemColor
    $panel.Controls.Add($list)

    $btnExpand = New-Object System.Windows.Forms.Button
    $btnExpand.Location = New-Object System.Drawing.Point(16, 460)
    $btnExpand.Size = New-Object System.Drawing.Size(210, 30)
    $btnExpand.FlatStyle = 'System'
    $dlg.Controls.Add($btnExpand)

    $refresh = {
        if ($script:confirmExpanded) {
            $list.Text = (($Items | ForEach-Object { '  ' + $_ }) -join [Environment]::NewLine)
            $btnExpand.Text = '收起清单'
        } else {
            $shown = @($Items | Select-Object -First $collapsedMax)
            $body = (($shown | ForEach-Object { '  ' + $_ }) -join [Environment]::NewLine)
            if ($total -gt $collapsedMax) {
                $body += [Environment]::NewLine + [Environment]::NewLine +
                         ("  …… 另有 {0} 项未显示" -f ($total - $collapsedMax))
            }
            $list.Text = $body
            $btnExpand.Text = "展开查看全部 $total 项"
        }
        $lines = ($list.Text -split "`n").Count
        $needH = [int]($lines * 17) + 16
        $w = $panel.ClientSize.Width - 4
        if ($w -lt 100) { $w = 596 }
        $list.Size = New-Object System.Drawing.Size($w, [Math]::Max($needH, $panel.ClientSize.Height))
    }
    & $refresh

    if ($total -gt $collapsedMax) {
        $btnExpand.Add_Click({
            $script:confirmExpanded = -not $script:confirmExpanded
            & $refresh
        })
    } else {
        $btnExpand.Visible = $false
    }

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = $Note
    $l2.Location = New-Object System.Drawing.Point(16, 496)
    $l2.Size = New-Object System.Drawing.Size(612, 34)
    $l2.ForeColor = [System.Drawing.Color]::FromArgb(110, 115, 122)
    $dlg.Controls.Add($l2)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $OkText
    $btnOk.Location = New-Object System.Drawing.Point(394, 532)
    $btnOk.Size = New-Object System.Drawing.Size(112, 34)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(514, 532)
    $btnCancel.Size = New-Object System.Drawing.Size(112, 34)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $ret = $dlg.ShowDialog($form)
    $dlg.Dispose()
    return ($ret -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-ForgetConfirm([int]$count, [object[]]$names) {
    $script:confirmOk = $false
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '确认遗忘'
    # 总高度要容下标题栏 + 底部按钮（按钮底边 y=402），留足余量避免被裁切
    $dlg.Size = New-Object System.Drawing.Size(560, 490)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = "将遗忘以下 $count 个 mod："
    $l1.Location = New-Object System.Drawing.Point(16, 14)
    $l1.Size = New-Object System.Drawing.Size(510, 22)
    $dlg.Controls.Add($l1)

    # 默认只显示前 10 个，其余折叠起来，避免列表过长把对话框撑爆；
    # 需要时点「展开」按钮查看完整清单。
    $collapsedMax = 10
    $total = $names.Count

    # 列表放在可滚动容器里：展开后即使几百项也能滚着看完，
    # 不会超出对话框，也不会把底部按钮挤出去。
    $listPanel = New-Object System.Windows.Forms.Panel
    $listPanel.Location = New-Object System.Drawing.Point(16, 40)
    $listPanel.Size = New-Object System.Drawing.Size(512, 250)
    $listPanel.BackColor = [System.Drawing.Color]::White
    $listPanel.BorderStyle = 'FixedSingle'
    $listPanel.AutoScroll = $true
    $dlg.Controls.Add($listPanel)

    $txt = New-Object System.Windows.Forms.Label
    $txt.AutoSize = $false
    $txt.BackColor = [System.Drawing.Color]::White
    $txt.Location = New-Object System.Drawing.Point(0, 0)
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $txt.TextAlign = 'TopLeft'
    $txt.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $listPanel.Controls.Add($txt)

    $btnExpand = New-Object System.Windows.Forms.Button
    $btnExpand.Location = New-Object System.Drawing.Point(16, 296)
    $btnExpand.Size = New-Object System.Drawing.Size(200, 30)
    $btnExpand.FlatStyle = 'System'
    $dlg.Controls.Add($btnExpand)

    $script:fhExpanded = $false
    $refreshList = {
        $lineH = 17
        if ($script:fhExpanded) {
            $txt.Text = (($names | ForEach-Object { '  · ' + $_ }) -join [Environment]::NewLine)
            $btnExpand.Text = '收起清单'
        } else {
            $shown = @($names | Select-Object -First $collapsedMax)
            $body = (($shown | ForEach-Object { '  · ' + $_ }) -join [Environment]::NewLine)
            if ($total -gt $collapsedMax) {
                $body += [Environment]::NewLine + [Environment]::NewLine +
                         ("  …… 另有 {0} 个未显示" -f ($total - $collapsedMax))
            }
            $txt.Text = $body
            $btnExpand.Text = "展开查看全部 $total 个"
        }
        # 按实际行数撑高内容，容器出现滚动条后自动扣除其宽度，避免横向滚动
        $lines = ($txt.Text -split "`n").Count
        $needH = [int]($lines * $lineH) + 16
        $w = $listPanel.ClientSize.Width - 4
        if ($w -lt 100) { $w = 496 }
        $txt.Size = New-Object System.Drawing.Size($w, [Math]::Max($needH, $listPanel.ClientSize.Height))
    }
    & $refreshList

    if ($total -gt $collapsedMax) {
        $btnExpand.Add_Click({
            $script:fhExpanded = -not $script:fhExpanded
            & $refreshList
        })
    } else {
        $btnExpand.Visible = $false
    }

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '遗忘后它们的差异不再出现在列表里，可以随时用「遗忘管理」恢复。'
    $l2.Location = New-Object System.Drawing.Point(16, 336)
    $l2.Size = New-Object System.Drawing.Size(512, 22)
    $l2.ForeColor = [System.Drawing.Color]::FromArgb(110, 115, 122)
    $dlg.Controls.Add($l2)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定遗忘'
    $btnOk.Location = New-Object System.Drawing.Point(294, 368)
    $btnOk.Size = New-Object System.Drawing.Size(112, 34)
    $btnOk.Anchor = 'Bottom,Right'
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(414, 368)
    $btnCancel.Size = New-Object System.Drawing.Size(112, 34)
    $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $btnOk.Add_Click({ $script:confirmOk = $true })
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    return [bool]$script:confirmOk
}

function Forget-Selected {
    $targets = New-Object System.Collections.ArrayList
    foreach ($row in $grid.Rows) {
        $r = $row.Tag
        if (-not $r) { continue }
        if (-not [bool]$row.Cells[0].Value) { continue }
        [void]$targets.Add($r)
    }
    if ($targets.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先在列表里勾选要遗忘的 mod。`n`n遗忘后，这些 mod 的差异不会再出现在扫描结果里。",
            '没有选中项', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    Forget-Records @($targets)
}

# 遗忘若干条记录（工具栏「遗忘选中项」与右键菜单「遗忘这个 mod」共用）
function Forget-Records([object[]]$targets) {
    $targets = @($targets | Where-Object { $_ })
    if ($targets.Count -eq 0) { return }

    $ok = Show-ForgetConfirm $targets.Count @($targets | ForEach-Object { $_.FileName })
    if (-not $ok) { return }

    $ignored = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-IgnoredMods)) { if ($k) { [void]$ignored.Add([string]$k) } }
    $info = New-Object System.Collections.ArrayList
    foreach ($i in @(Get-IgnoredInfo)) { if ($i) { [void]$info.Add($i) } }

    foreach ($r in $targets) {
        if (-not $ignored.Contains($r.Key)) {
            [void]$ignored.Add($r.Key)
            [void]$info.Add([pscustomobject]@{
                Key      = $r.Key
                FileName = $r.FileName
                Time     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            })
            Write-Log ('遗忘 mod：{0}（身份标识 {1}）' -f $r.FileName, $r.Key)
        }
    }
    Set-IgnoredList @($ignored) @($info)
    Write-Cfg

    Apply-IgnoredFilter
    Show-Results
    $lblStatus.Text = "已遗忘 $($targets.Count) 个 mod；当前列表 $($script:Records.Count) 项，共隐藏 $($script:IgnoredCount) 项"
}

function Show-IgnoredManager {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '遗忘管理'
    $dlg.Size = New-Object System.Drawing.Size(740, 480)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $info = New-Object System.Windows.Forms.Label
    $info.Text = '以下 mod 已被遗忘，扫描结果中不再列出。勾选后点「恢复选中」即可重新显示。'
    $info.Location = New-Object System.Drawing.Point(14, 12)
    $info.Size = New-Object System.Drawing.Size(700, 22)
    $dlg.Controls.Add($info)

    $lv = New-Object System.Windows.Forms.DataGridView
    $lv.Location = New-Object System.Drawing.Point(14, 40)
    $lv.Size = New-Object System.Drawing.Size(700, 340)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.AllowUserToAddRows = $false
    $lv.RowHeadersVisible = $false
    $lv.SelectionMode = 'FullRowSelect'
    $lv.MultiSelect = $true
    $lv.AutoSizeColumnsMode = 'None'
    $lv.BackgroundColor = [System.Drawing.Color]::White
    $lv.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $lv.EnableHeadersVisualStyles = $false
    $lv.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)

    $c0 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $c0.HeaderText = '恢复'; $c0.Width = 50
    $c1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c1.HeaderText = '遗忘时的文件名'; $c1.Width = 380; $c1.ReadOnly = $true
    $c2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c2.HeaderText = '身份标识（跨版本生效）'; $c2.Width = 190; $c2.ReadOnly = $true
    $c3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c3.HeaderText = '遗忘时间'; $c3.Width = 120; $c3.ReadOnly = $true
    [void]$lv.Columns.Add($c0); [void]$lv.Columns.Add($c1)
    [void]$lv.Columns.Add($c2); [void]$lv.Columns.Add($c3)
    $dlg.Controls.Add($lv)

    # 用配置里的 key 顺序填充；备注信息缺失时用 key 兜底
    $infoMap = @{}
    foreach ($it in @(Get-IgnoredInfo)) {
        if ($it -and $it.Key) { $infoMap[[string]$it.Key] = $it }
    }
    foreach ($k in @(Get-IgnoredMods)) {
        if (-not $k) { continue }
        $meta = $infoMap[[string]$k]
        $fn = if ($meta) { $meta.FileName } else { '(无记录)' }
        $tm = if ($meta) { $meta.Time } else { '' }
        $idx = $lv.Rows.Add()
        $lv.Rows[$idx].Cells[0].Value = $false
        $lv.Rows[$idx].Cells[1].Value = $fn
        $lv.Rows[$idx].Cells[2].Value = [string]$k
        $lv.Rows[$idx].Cells[3].Value = $tm
        $lv.Rows[$idx].Tag = [string]$k
    }

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = '恢复选中'
    $btnRestore.Location = New-Object System.Drawing.Point(14, 394)
    $btnRestore.Size = New-Object System.Drawing.Size(110, 32)
    $btnRestore.Anchor = 'Bottom,Left'

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '恢复全部'
    $btnAll.Location = New-Object System.Drawing.Point(132, 394)
    $btnAll.Size = New-Object System.Drawing.Size(110, 32)
    $btnAll.Anchor = 'Bottom,Left'

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '关闭'
    $btnClose.Location = New-Object System.Drawing.Point(594, 394)
    $btnClose.Size = New-Object System.Drawing.Size(110, 32)
    $btnClose.Anchor = 'Bottom,Right'
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $dlg.Controls.AddRange(@($btnRestore, $btnAll, $btnClose))
    $dlg.AcceptButton = $btnClose

    # 只要动过遗忘列表就需要刷新主界面
    $changed = $false

    $applyChange = {
        param($keysToRemove)
        $removeMap = @{}
        foreach ($k in $keysToRemove) { $removeMap[[string]$k] = $true }
        $keep = New-Object System.Collections.ArrayList
        foreach ($k in @(Get-IgnoredMods)) {
            if ($k -and -not $removeMap.ContainsKey([string]$k)) { [void]$keep.Add([string]$k) }
        }
        $keepInfo = New-Object System.Collections.ArrayList
        foreach ($it in @(Get-IgnoredInfo)) {
            if ($it -and $it.Key -and -not $removeMap.ContainsKey([string]$it.Key)) { [void]$keepInfo.Add($it) }
        }
        Set-IgnoredList @($keep) @($keepInfo)
        Write-Cfg
        Write-Log ('恢复遗忘 {0} 个' -f $keysToRemove.Count)
    }

    $btnRestore.Add_Click({
        $keys = New-Object System.Collections.ArrayList
        foreach ($row in $lv.Rows) {
            if ([bool]$row.Cells[0].Value) { [void]$keys.Add($row.Tag) }
        }
        if ($keys.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('请先勾选要恢复的 mod。', '提示',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        & $applyChange $keys
        foreach ($row in @($lv.Rows)) {
            if ([bool]$row.Cells[0].Value) { $lv.Rows.Remove($row) }
        }
        $changed = $true
    })

    $btnAll.Add_Click({
        if ($lv.Rows.Count -eq 0) { return }
        $keys = New-Object System.Collections.ArrayList
        foreach ($row in $lv.Rows) { [void]$keys.Add($row.Tag) }
        & $applyChange $keys
        $lv.Rows.Clear()
        $changed = $true
    })

    $dlg.Add_FormClosed({
        if ($changed) {
            Apply-IgnoredFilter
            Show-Results
            $lblStatus.Text = "已恢复遗忘；当前列表 $($script:Records.Count) 项，仍隐藏 $($script:IgnoredCount) 项"
        }
    })

    [void]$dlg.ShowDialog($form)
}

# ------------------------------------------------------------------ 扫描逻辑

# ================================================================== 同步目标（本地 / SFTP）
# 本工具原本只能同步到本地文件夹（或 UNC 共享）。简幻欢这类托管平台给的是 SFTP，
# 而 Windows PowerShell 5.1 / .NET Framework 里**没有任何内置 SFTP 客户端**，
# 所以内嵌了 SSH.NET（MIT 许可，见 lib\README.md）—— 依然是一个绿色 exe、不用装任何东西。
#
# 所有"目标端"操作都收在这一层：上层（扫描 / 同步 / 改名）只调下面这几个函数，
# 完全不关心对面是本地磁盘还是远程服务器。

$script:SshNetReady = $false
$script:SshNetPath  = ''
$script:SshNetError = ''

# 惰性加载 SSH.NET：只在真的用到 SFTP 时才加载，纯本地用户一点不受影响。
function Initialize-SshNet {
    if ($script:SshNetReady) { return $true }
    if ('Renci.SshNet.SftpClient' -as [type]) { $script:SshNetReady = $true; return $true }

    $cand = New-Object System.Collections.ArrayList
    if ($env:MODSYNC_SSHNET_DLL) { [void]$cand.Add($env:MODSYNC_SSHNET_DLL) }   # exe 启动器解压出来的
    $bases = New-Object System.Collections.ArrayList
    if ($PSScriptRoot) { [void]$bases.Add($PSScriptRoot) }
    try { $mp = Split-Path -Parent $MyInvocation.MyCommand.Path; if ($mp) { [void]$bases.Add($mp) } } catch { }
    foreach ($b in $bases) { [void]$cand.Add((Join-Path $b 'lib\Renci.SshNet.dll')) }   # 开发态：直接跑源码

    foreach ($p in $cand) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        try {
            Add-Type -Path $p -ErrorAction Stop
            if ('Renci.SshNet.SftpClient' -as [type]) {
                $script:SshNetReady = $true
                $script:SshNetPath = $p
                return $true
            }
        } catch { $script:SshNetError = $_.Exception.Message }
    }
    if (-not $script:SshNetError) {
        $script:SshNetError = '找不到 Renci.SshNet.dll。跑源码时它应该在 lib\ 目录下；跑 exe 时说明打包漏了。'
    }
    return $false
}

# 远程目录归一化：统一用 /，去掉尾部斜杠（根目录除外）
function Normalize-RemoteDir([string]$d) {
    if ([string]::IsNullOrWhiteSpace($d)) { return '' }
    $d = ($d.Trim() -replace '\\', '/')
    if ($d.Length -gt 1) { $d = $d.TrimEnd('/') }
    if (-not $d.StartsWith('/')) { $d = '/' + $d }
    return $d
}
function Join-RemotePath([string]$dir, [string]$name) {
    if ([string]::IsNullOrEmpty($dir) -or $dir -eq '/') { return '/' + $name }
    return $dir.TrimEnd('/') + '/' + $name
}

# 当前配置档的同步目标。Local 用 ServerDir；Sftp 用 Sftp* 字段。
function Get-CurTarget {
    $p = Get-CurProfile
    if ($p -and [string]$p.TargetKind -eq 'Sftp') {
        return [pscustomobject]@{
            Kind = 'Sftp'
            Host = [string]$p.SftpHost
            Port = [int]$(if ($p.SftpPort) { $p.SftpPort } else { 22 })
            User = [string]$p.SftpUser
            Pass = [string]$p.SftpPass
            Dir  = (Normalize-RemoteDir ([string]$p.SftpDir))
        }
    }
    return [pscustomobject]@{
        Kind = 'Local'; Host = ''; Port = 0; User = ''; Pass = ''
        Dir  = (Resolve-InputPath (Get-CurServerDir))
    }
}
# 目标端的一句话描述，给状态栏/日志用
function Get-TargetLabel($t) {
    if (-not $t) { return '(未设置)' }
    if ($t.Kind -eq 'Sftp') { return ("SFTP {0}@{1}:{2}{3}" -f $t.User, $t.Host, $t.Port, $t.Dir) }
    return ("本地 {0}" -f $t.Dir)
}

# 本次操作实际使用的目标端。扫描时解析好（本地路径会被归一化）放这里，
# 下游的同步/改名逻辑统一读它，不用把 target 一路当参数传下去。
$script:ActiveTarget = $null
function Get-ActiveTarget {
    if ($script:ActiveTarget) { return $script:ActiveTarget }
    return (Get-CurTarget)
}

$script:SftpClient = $null
$script:SshClient  = $null
$script:SshExecOk  = $null   # $null=未探测 / $true=可执行命令 / $false=只能 SFTP

function Disconnect-SftpTarget {
    foreach ($o in @($script:SftpClient, $script:SshClient)) {
        try { if ($o) { if ($o.IsConnected) { $o.Disconnect() }; $o.Dispose() } } catch { }
    }
    $script:SftpClient = $null
    $script:SshClient  = $null
    $script:SshExecOk  = $null
}

function Connect-SftpTarget($t) {
    if ($script:SftpClient -and $script:SftpClient.IsConnected) { return $script:SftpClient }
    if (-not (Initialize-SshNet)) { throw $script:SshNetError }
    if ([string]::IsNullOrWhiteSpace($t.Host)) { throw '还没有填写 SFTP 主机地址。点「SFTP 设置...」填一下。' }
    if ([string]::IsNullOrWhiteSpace($t.User)) { throw '还没有填写 SFTP 用户名。点「SFTP 设置...」填一下。' }
    Disconnect-SftpTarget
    $c = New-Object Renci.SshNet.SftpClient($t.Host, [int]$t.Port, $t.User, $t.Pass)
    $c.ConnectionInfo.Timeout = [TimeSpan]::FromSeconds(20)
    $c.OperationTimeout = [TimeSpan]::FromSeconds(180)
    try { $c.Connect() } catch {
        try { $c.Dispose() } catch { }
        throw ("连不上 SFTP：{0}:{1} —— {2}" -f $t.Host, $t.Port, $_.Exception.Message)
    }
    $script:SftpClient = $c
    return $c
}

# 独立的命令通道：用来在服务器上跑 md5sum / cp，省掉下载整个 jar 的流量。
# 有些面板只给 SFTP 不给 shell，这里探测失败就返回 $null，上层自动退化为"只比大小"。
function Get-SshExecSession($t) {
    if ($script:SshExecOk -eq $false) { return $null }
    if ($script:SshClient -and $script:SshClient.IsConnected) { return $script:SshClient }
    if (-not (Initialize-SshNet)) { return $null }
    try {
        $s = New-Object Renci.SshNet.SshClient($t.Host, [int]$t.Port, $t.User, $t.Pass)
        $s.ConnectionInfo.Timeout = [TimeSpan]::FromSeconds(20)
        $s.Connect()
        $r = $s.RunCommand('echo MODSYNC_OK')
        if ($r.ExitStatus -ne 0 -or ([string]$r.Result) -notmatch 'MODSYNC_OK') {
            try { $s.Dispose() } catch { }
            $script:SshExecOk = $false
            return $null
        }
        $script:SshClient = $s
        $script:SshExecOk = $true
        return $s
    } catch {
        $script:SshExecOk = $false
        Write-Log ('SSH 命令通道不可用（远程哈希/服务端备份会退化）：' + $_.Exception.Message)
        return $null
    }
}

# shell 单引号转义：' -> '\''
function Quote-ShArg([string]$s) {
    return "'" + ($s -replace "'", "'\''") + "'"
}

function Get-RemoteMd5([string]$path) {
    $s = Get-SshExecSession (Get-CurTarget)
    if (-not $s) { return $null }
    try {
        $r = $s.RunCommand('md5sum -- ' + (Quote-ShArg $path))
        if ($r.ExitStatus -ne 0) { return $null }
        $m = [regex]::Match([string]$r.Result, '(?m)^([0-9a-fA-F]{32})\s')
        if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- 目标端操作（本地/SFTP 分派）

# 列出目标端的 .jar。返回对象的形状与 FileInfo 一致（Name/FullName/Length/LastWriteTime），
# 所以上层的判定逻辑一行都不用改。
function Get-TargetJarFiles($t) {
    if ($t.Kind -eq 'Sftp') {
        if ([string]::IsNullOrWhiteSpace($t.Dir)) { throw '还没有填写远程 mods 目录（例如 /mods）。' }
        $c = Connect-SftpTarget $t
        try { $list = $c.ListDirectory($t.Dir) } catch {
            throw ("读不到远程目录 {0} —— {1}" -f $t.Dir, $_.Exception.Message)
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($f in $list) {
            if ($f.IsDirectory) { continue }
            if (-not $f.Name.ToLower().EndsWith('.jar')) { continue }
            [void]$out.Add([pscustomobject]@{
                Name          = $f.Name
                FullName      = (Join-RemotePath $t.Dir $f.Name)
                Length        = [long]$f.Length
                LastWriteTime = $f.LastWriteTimeUtc.ToLocalTime()
                Remote        = $true
            })
        }
        return @($out | Sort-Object Name)
    }
    return @(Get-ChildItem -LiteralPath $t.Dir -File -Filter '*.jar' -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Test-TargetFile($t, [string]$path) {
    if ($t.Kind -eq 'Sftp') {
        try { return (Connect-SftpTarget $t).Exists($path) } catch { return $false }
    }
    return (Test-Path -LiteralPath $path)
}
function Get-TargetFileSize($t, [string]$path) {
    if ($t.Kind -eq 'Sftp') { return [long](Connect-SftpTarget $t).GetAttributes($path).Size }
    return [long](Get-Item -LiteralPath $path).Length
}
function Copy-LocalFileToTarget($t, [string]$src, [string]$dstPath) {
    if ($t.Kind -eq 'Sftp') {
        $c = Connect-SftpTarget $t
        # 共享读打开：客户端 mods 里可能正被 PCL2 之类读着
        $fs = [System.IO.File]::Open($src, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $c.UploadFile($fs, $dstPath, $true) } finally { $fs.Dispose() }
        return
    }
    Copy-Item -LiteralPath $src -Destination $dstPath -Force
}
function Remove-TargetFile($t, [string]$path) {
    if ($t.Kind -eq 'Sftp') { (Connect-SftpTarget $t).DeleteFile($path); return }
    Remove-Item -LiteralPath $path -Force
}
function Move-TargetFile($t, [string]$from, [string]$to) {
    if ($t.Kind -eq 'Sftp') { (Connect-SftpTarget $t).RenameFile($from, $to); return }
    [System.IO.File]::Move($from, $to)
}
# 目标端原地复制一份（覆盖前备份用）。SFTP 协议本身没有"服务端复制"，
# 优先借服务器的 cp（零流量），没有命令通道才退回"下载再上传"。
function Copy-TargetFileInPlace($t, [string]$from, [string]$to) {
    if ($t.Kind -eq 'Local') { Copy-Item -LiteralPath $from -Destination $to -Force; return }
    $s = Get-SshExecSession $t
    if ($s) {
        try {
            $r = $s.RunCommand('cp -- ' + (Quote-ShArg $from) + ' ' + (Quote-ShArg $to))
            if ($r.ExitStatus -eq 0) { return }
        } catch { }
    }
    $ms = New-Object System.IO.MemoryStream
    try {
        $c = Connect-SftpTarget $t
        $c.DownloadFile($from, $ms)
        $ms.Position = 0
        $c.UploadFile($ms, $to, $true)
    } finally { $ms.Dispose() }
}
# 目标端某个文件的 MD5。本地直接算；远程走 md5sum，拿不到就返回 $null（上层退化为只比大小）。
function Get-TargetFileMd5($t, [string]$path) {
    if ($t.Kind -eq 'Local') { return (Get-FileHashMd5 $path) }
    return (Get-RemoteMd5 $path)
}

# 「测试连接」：把能探到的信息一次性告诉用户，出错也给出人话原因
function Test-TargetConnection($t) {
    $lines = New-Object System.Collections.ArrayList
    try {
        if ($t.Kind -eq 'Local') {
            if ([string]::IsNullOrWhiteSpace($t.Dir)) { throw '还没有填写服务端 mods 文件夹。' }
            if (-not (Test-Path -LiteralPath $t.Dir)) { throw ("路径不存在：{0}" -f $t.Dir) }
            $n = @(Get-ChildItem -LiteralPath $t.Dir -File -Filter '*.jar' -ErrorAction SilentlyContinue).Count
            [void]$lines.Add('✅ 本地文件夹可用')
            [void]$lines.Add(("   路径：{0}" -f $t.Dir))
            [void]$lines.Add(("   现有 jar：{0} 个" -f $n))
            return @{ Ok = $true; Text = ($lines -join "`r`n") }
        }

        Disconnect-SftpTarget
        $c = Connect-SftpTarget $t
        [void]$lines.Add('✅ SFTP 连接成功')
        [void]$lines.Add(("   服务端：{0}" -f $c.ConnectionInfo.ServerVersion))
        [void]$lines.Add(("   主机  ：{0}:{1}   用户：{2}" -f $t.Host, $t.Port, $t.User))

        $showDir = $t.Dir
        if ([string]::IsNullOrWhiteSpace($showDir)) {
            $showDir = $c.WorkingDirectory
            [void]$lines.Add('⚠ 还没填远程 mods 目录，下面列的是登录后的默认目录，找到 mods 后把它填进去：')
        }
        try { $list = @($c.ListDirectory($showDir) | Where-Object { $_.Name -notin @('.', '..') }) }
        catch { throw ("能连上，但读不了目录 {0} —— {1}" -f $showDir, $_.Exception.Message) }

        $jars = @($list | Where-Object { -not $_.IsDirectory -and $_.Name.ToLower().EndsWith('.jar') })
        [void]$lines.Add(("   目录  ：{0}" -f $showDir))
        [void]$lines.Add(("   内容  ：{0} 项，其中 jar {1} 个" -f $list.Count, $jars.Count))
        if ($list.Count -gt 0) {
            [void]$lines.Add('   前几项：')
            foreach ($it in ($list | Select-Object -First 8)) {
                [void]$lines.Add(("     {0} {1}" -f $(if ($it.IsDirectory) { '[目录]' } else { '      ' }), $it.Name))
            }
        }

        $s = Get-SshExecSession $t
        if ($s) {
            $r = $s.RunCommand('command -v md5sum || echo NO_MD5SUM')
            $hasMd5 = ([string]$r.Result) -notmatch 'NO_MD5SUM'
            [void]$lines.Add($(if ($hasMd5) {
                '✅ 服务器有 md5sum —— 内容比对不用把整个整合包下载下来'
            } else {
                '⚠ 服务器没有 md5sum —— 内容比对只能靠文件大小（退化为更快的模式）'
            }))
        } else {
            [void]$lines.Add('⚠ 服务器不允许执行命令（只开了 SFTP）—— 内容比对只能靠文件大小')
        }
        return @{ Ok = $true; Text = ($lines -join "`r`n") }
    } catch {
        return @{ Ok = $false; Text = ('❌ ' + $_.Exception.Message) }
    }
}

function Set-Busy([bool]$busy, [string]$text) {
    $btnScan.Enabled = -not $busy
    $btnRefresh.Enabled = -not $busy
    $btnSync.Enabled = (-not $busy) -and ($script:Records.Count -gt 0)
    $progress.Visible = $busy
    if ($text) { $lblStatus.Text = $text }
    if ($busy) {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    } else {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $progress.Value = 0
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-ValidDir([string]$path, [string]$label) {
    $p = Resolve-InputPath $path
    if ([string]::IsNullOrWhiteSpace($p)) {
        throw "请先填写「$label」文件夹路径。"
    }
    if (-not (Test-Path -LiteralPath $p)) {
        throw "「$label」路径不存在：`n$p"
    }
    $item = Get-Item -LiteralPath $p
    if (-not $item.PSIsContainer) {
        throw "「$label」不是一个文件夹：`n$p"
    }
    return $item.FullName
}

function Invoke-Scan {
    $clientDir = $null
    $target = $null
    try {
        $clientDir = Get-ValidDir $txtClient.Text '客户端 mods'
        $target = Get-CurTarget
        if ($target.Kind -eq 'Local') {
            $target.Dir = Get-ValidDir $txtServer.Text '服务端 mods'
        } else {
            # SFTP：连接和目录先验通，别扫到一半才炸
            if ([string]::IsNullOrWhiteSpace($target.Host)) {
                throw "还没有配置 SFTP 服务器。`n`n点「SFTP 设置...」填上主机、端口、用户名、密码。"
            }
            if ([string]::IsNullOrWhiteSpace($target.Dir)) {
                throw "还没有填写远程 mods 目录（例如 /mods）。`n`n就是面板文件管理器里那个 mods 文件夹的路径。"
            }
            if (-not (Initialize-SshNet)) { throw $script:SshNetError }
            $null = Connect-SftpTarget $target
            try { $null = (Connect-SftpTarget $target).ListDirectory($target.Dir) }
            catch { throw ("连上了服务器，但读不了远程目录 {0}：`n{1}" -f $target.Dir, $_.Exception.Message) }
        }
    } catch {
        # 未成功扫描：记下原因。退出日志靠它区分「没扫成」和「扫了但没变更」——
        # 路径失效时如果只写"客户端 0 个 mod"，看起来像是"没事可做"，排查时会走弯路。
        $script:LastScanOk = $false
        $script:LastScanMsg = '目标端不可用，未执行扫描：' + ($_.Exception.Message -replace '\s+', ' ')
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '目标端不可用',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Set-Busy $false '未扫描：目标端不可用'
        return
    }

    $serverDir = $target.Dir
    $script:ActiveTarget = $target

    # 归一化后回填，避免 "C:\a\" 与 "C:\a" 被视为不同
    $txtClient.Text = Get-DisplayPath $clientDir
    if ($target.Kind -eq 'Local') { $txtServer.Text = Get-DisplayPath $serverDir }

    # 重入保护：扫描期间 DoEvents 会泵消息，可能让文件监控/按钮再次触发扫描，
    # 形成嵌套扫描把界面拖死。这里直接挡掉。
    if ($script:ScanInProgress) {
        Write-Log '扫描请求被忽略：已有扫描正在进行（防重入）'
        return
    }
    $script:ScanInProgress = $true
    $script:CancelScan = $false
    $script:HashCache = @{}
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log ('扫描开始 | 客户端={0} | 目标={1} | 哈希校验={2} | 哈希实现={3}' -f
        $clientDir, (Get-TargetLabel $target), $chkHash.Checked, $script:HashImpl)

    Set-Busy $true '正在读取文件列表...'
    $useHash = $chkHash.Checked

    try {
        $srcFiles = @(Get-ChildItem -LiteralPath $clientDir -File -Filter '*.jar' -ErrorAction SilentlyContinue |
                      Sort-Object Name)
        $dstFiles = @(Get-TargetJarFiles $target)
        $tEnum = $scanSw.ElapsedMilliseconds
        Write-Log ("枚举完成：客户端 {0} 个 / 目标端 {1} 个，耗时 {2} ms" -f $srcFiles.Count, $dstFiles.Count, $tEnum)

        # --- 服务端文件索引：按 base 名 和 mod key 双向挂载 ---
        $idxByBase = @{}
        $idxByKey = @{}
        $dstIndexed = New-Object System.Collections.ArrayList
        foreach ($f in $dstFiles) {
            $id = Get-ModIdentity $f.Name
            $rec = [pscustomobject]@{
                Name = $f.Name; Full = $f.FullName; Size = [long]$f.Length
                Time = $f.LastWriteTime; Base = $id.Base.ToLower(); Key = $id.Key
                Hash = $null; Used = $false
            }
            [void]$dstIndexed.Add($rec)
            if (-not $idxByBase.ContainsKey($rec.Base)) { $idxByBase[$rec.Base] = New-Object System.Collections.ArrayList }
            [void]$idxByBase[$rec.Base].Add($rec)
            if (-not $idxByKey.ContainsKey($rec.Key)) { $idxByKey[$rec.Key] = New-Object System.Collections.ArrayList }
            [void]$idxByKey[$rec.Key].Add($rec)
        }

        $records = New-Object System.Collections.ArrayList
        $hashCount = 0
        $i = 0
        $total = $srcFiles.Count

        foreach ($f in $srcFiles) {
            if ($script:CancelScan) { break }   # 用户按了 Esc
            $i++
            if (($i % 8) -eq 0 -or $i -eq $total) {
                $lblStatus.Text = "正在比对客户端 mod：$i / $total ...（按 Esc 可取消）"
                $progress.Maximum = [Math]::Max($total, 1)
                $progress.Value = [Math]::Min($i, $progress.Maximum)
                [System.Windows.Forms.Application]::DoEvents()
            }

            $id = Get-ModIdentity $f.Name
            $base = $id.Base.ToLower()
            $size = [long]$f.Length

            $state = ''
            $action = ''
            $needHash = $false

            $sameBase = $null
            if ($idxByBase.ContainsKey($base)) { $sameBase = $idxByBase[$base][0] }

            $oldVersions = New-Object System.Collections.ArrayList
            if ($sameBase) {
                $sameBase.Used = $true
                if ($sameBase.Size -eq $size) {
                    # 同名同大小 —— 只有开了哈希校验才需要读内容
                    $needHash = $true
                    $state = '已同步'
                    $action = '与目标端一致，无需操作'
                } else {
                    # 同名不同大小，一定不同，零 I/O 判定
                    $state = '更新'
                    $action = "覆盖同名文件（旧 $($sameBase.Size) 字节）"
                }
            } else {
                $siblings = @()
                if ($idxByKey.ContainsKey($id.Key)) { $siblings = @($idxByKey[$id.Key]) }
                foreach ($s in $siblings) {
                    if ($s.Base -ne $base) {
                        $s.Used = $true
                        [void]$oldVersions.Add($s)
                    }
                }
                if ($oldVersions.Count -gt 0) {
                    $state = '更新'
                    $names = ($oldVersions | ForEach-Object { $_.Name }) -join '、'
                    $action = "新增并删除旧版本：$names"
                } else {
                    $state = '新增'
                    $action = '目标端不存在，新增文件'
                }
            }

            $hash = $null
            if ($useHash -and $needHash) {
                $hashCount++
                if (($hashCount % 5) -eq 0) {
                    $lblStatus.Text = "正在校验文件内容（MD5）：第 $hashCount 个 ..."
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $hash = Get-FileHashMd5 $f.FullName
                if ($hash -and $sameBase) {
                    if ($null -eq $sameBase.Hash) { $sameBase.Hash = Get-TargetFileMd5 $target $sameBase.Full }
                    if ($sameBase.Hash -and $sameBase.Hash -eq $hash) {
                        $state = '已同步'
                        $action = '内容一致，无需操作'
                    } else {
                        $state = '更新'
                        $action = '同名但内容不同，需要覆盖'
                    }
                }
            } elseif ($state -eq '已同步') {
                $action = '文件名与大小一致（未开启哈希校验）'
            }

            $checked = ($state -ne '已同步')
            [void]$records.Add([pscustomobject]@{
                Checked = $checked
                SrcPath = $f.FullName
                FileName = $f.Name
                Base = $base
                Key = $id.Key
                Version = $id.Version
                Size = $size
                Time = $f.LastWriteTime
                StatusKind = $state
                Action = $action
                OldVersions = $oldVersions
                SrcHash = $hash
                DstSameBase = $sameBase
                DstRenameFrom = $null   # 重命名时：目标端被改名的那个旧文件
                Result = ''
            })
        }

        # --- 第 4 级判定：内容完全相同、只有文件名不同 = 重命名 ---
        # 典型场景：用户在客户端把 mod 改成自己习惯的名字（或 PCL2 换了一套命名风格），
        # 服务端还留着旧名字。认出来之后，"同步"就只是给服务端那个文件改个名：
        # 不复制内容、不会在服务端留下同一个 mod 的两个 jar。
        # 代价控制：只看「客户端标为新增」× 「服务端没被认领」的候选，先按大小预筛，
        # 大小不同的直接跳过，只有大小相同才读内容算 MD5（通常只有个位数个文件）。
        if ($chkRename.Checked) {
            $renSrc = @($records | Where-Object { $_.StatusKind -eq '新增' })
            $renDst = @($dstIndexed | Where-Object { -not $_.Used })
            if ($renSrc.Count -gt 0 -and $renDst.Count -gt 0) {
                $dstBySize = @{}
                foreach ($d in $renDst) {
                    $szKey = [string]$d.Size
                    if (-not $dstBySize.ContainsKey($szKey)) { $dstBySize[$szKey] = New-Object System.Collections.ArrayList }
                    [void]$dstBySize[$szKey].Add($d)
                }
                foreach ($r in $renSrc) {
                    if ($script:CancelScan) { break }
                    $szKey = [string]$r.Size
                    if (-not $dstBySize.ContainsKey($szKey)) { continue }
                    $pool = @($dstBySize[$szKey] | Where-Object { -not $_.Used })
                    if ($pool.Count -eq 0) { continue }

                    $lblStatus.Text = "正在确认是否只是改了名：$($r.FileName)"
                    [System.Windows.Forms.Application]::DoEvents()

                    $srcHash = Get-FileHashMd5 $r.SrcPath
                    if (-not $srcHash) { continue }

                    $hits = New-Object System.Collections.ArrayList
                    foreach ($d in $pool) {
                        if ($null -eq $d.Hash) { $d.Hash = Get-TargetFileMd5 $target $d.Full }
                        if ($d.Hash -and $d.Hash -eq $srcHash) { [void]$hits.Add($d) }
                    }
                    if ($hits.Count -eq 0) { continue }

                    # 多个候选内容都相同时，优先挑 mod 身份相同的那个，其余保持不动
                    $pick = $hits[0]
                    foreach ($h in $hits) { if ($h.Key -eq $r.Key) { $pick = $h; break } }
                    $pick.Used = $true
                    $r.StatusKind = '重命名'
                    $r.DstRenameFrom = $pick
                    $r.SrcHash = $srcHash
                    $r.Checked = $true
                    $r.Action = "内容一致，服务端改名：$($pick.Name) → $($r.FileName)"
                    if ($hits.Count -gt 1) {
                        $r.Action += "（服务端另有 $($hits.Count - 1) 个同内容文件，保持不动）"
                    }
                    Write-Log ("识别为重命名：{0} -> {1}（MD5 {2}）" -f $pick.Name, $r.FileName, $srcHash.Substring(0, 8))
                }
            }
        }

        # 仅服务端存在的文件（未被任何客户端文件认领）
        $orphans = New-Object System.Collections.ArrayList
        foreach ($d in $dstIndexed) {
            if (-not $d.Used) { [void]$orphans.Add($d) }
        }

        $script:AllRecords = @($records)   # 全量（遗忘管理要用）
        $script:Orphans = @($orphans)

        Apply-IgnoredFilter                # 按遗忘列表过滤出最终展示的记录

        $script:LastScanOk = $true
        $script:LastScanMsg = ''
        Show-Results
        Write-Log ("扫描完成：耗时 {0} ms（比对 {1} ms，哈希 {2} 次，遗忘隐藏 {3} 项，重命名 {4} 项）" -f
            $scanSw.ElapsedMilliseconds, ($scanSw.ElapsedMilliseconds - $tEnum), $script:HashCache.Count, $script:IgnoredCount,
            @($records | Where-Object { $_.StatusKind -eq '重命名' }).Count)
    } catch {
        $script:LastScanOk = $false
        $script:LastScanMsg = '扫描异常：' + $_.Exception.Message
        Write-Log ("扫描异常：{0}" -f $_.Exception.ToString())
        [System.Windows.Forms.MessageBox]::Show("扫描失败：`n$($_.Exception.Message)", '错误',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        $lblStatus.Text = '扫描失败'
    } finally {
        $script:ScanInProgress = $false
        Set-Busy $false
        if ($script:Records.Count -gt 0) { $btnSync.Enabled = $true }

        # 自动重命名必须放在这里：它改完名字会触发一次重扫，
        # 而重扫会被防重入标志挡掉，所以必须等上面那行先执行完。
        Invoke-AutoRename
    }
}

function Show-Results {
    $grid.SuspendLayout()
    $grid.Rows.Clear()

    $order = @{ '重命名' = 0; '更新' = 1; '新增' = 2; '已同步' = 3 }
    $sorted = @($script:Records | Sort-Object @{ Expression = { $order[$_.StatusKind] } }, FileName)

    foreach ($r in $sorted) {
        $newRowIdx = $grid.Rows.Add()
        $row = $grid.Rows[$newRowIdx]
        $row.Cells[0].Value = $r.Checked
        $row.Cells[2].Value = $r.FileName
        $row.Cells[3].Value = $r.Action
        $row.Cells[4].Value = Get-BytesText $r.Size
        $row.Cells[5].Value = $r.Time.ToString('yyyy-MM-dd HH:mm')
        $row.Cells[6].Value = ''
        $row.Tag = $r

        switch ($r.StatusKind) {
            '重命名' {
                $row.Cells[1].Value = "$ICO_REN 重命名"
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(30, 95, 190)
                $row.Cells[1].Style.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            }
            '新增' {
                $row.Cells[1].Value = "$ICO_NEW 新增"
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
                $row.Cells[1].Style.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            }
            '更新' {
                $row.Cells[1].Value = "$ICO_UPD 更新"
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0)
                $row.Cells[1].Style.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            }
            default {
                $row.Cells[1].Value = "$ICO_OK 已同步"
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(140, 145, 152)
            }
        }
    }

    $grid.ResumeLayout()

    $nRen = @($script:Records | Where-Object { $_.StatusKind -eq '重命名' }).Count
    $nNew = @($script:Records | Where-Object { $_.StatusKind -eq '新增' }).Count
    $nUpd = @($script:Records | Where-Object { $_.StatusKind -eq '更新' }).Count
    $nOk  = @($script:Records | Where-Object { $_.StatusKind -eq '已同步' }).Count
    $nOrp = $script:Orphans.Count

    $lblEmpty.Visible = ($grid.Rows.Count -eq 0)
    if ($grid.Rows.Count -eq 0) {
        $lblEmpty.Text = '两个文件夹都没有找到 .jar 文件，请确认路径是否正确。'
    }

    $msg = "客户端 $($script:AllRecords.Count) 个 jar："
    if ($nRen -gt 0) { $msg += "重命名 $nRen，" }
    $msg += "新增 $nNew，更新 $nUpd，已同步 $nOk"
    if ($script:IgnoredCount -gt 0) { $msg += "（已遗忘隐藏 $($script:IgnoredCount) 项）" }
    if ($nOrp -gt 0) { $msg += "；服务端另有 $nOrp 个文件客户端不存在（不会被改动）" }
    if ($script:AutoRenameNote) { $msg += "；$($script:AutoRenameNote)"; $script:AutoRenameNote = '' }
    $lblStatus.Text = $msg

    $hasPending = (($nRen + $nNew + $nUpd) -gt 0)
    $btnSync.Enabled = $hasPending -and ($grid.Rows.Count -gt 0)
}

# ------------------------------------------------------------------ 同步逻辑

function Get-SyncPlan {
    $copies = New-Object System.Collections.ArrayList
    $deletes = New-Object System.Collections.ArrayList
    $renames = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList

    foreach ($row in $grid.Rows) {
        $r = $row.Tag
        if (-not $r) { continue }
        $isChecked = [bool]$row.Cells[0].Value
        $r.Checked = $isChecked
        if (-not $isChecked) { continue }

        if ($r.StatusKind -eq '重命名') {
            $from = $r.DstRenameFrom
            if (-not $from) {
                [void]$skipped.Add(@{ Rec = $r; Why = '缺少重命名来源信息，请重新扫描' })
                continue
            }
            if (-not (Test-TargetFile $script:ActiveTarget $from.Full)) {
                [void]$skipped.Add(@{ Rec = $r; Why = "服务端原文件已不存在：$($from.Name)" })
                continue
            }
            if (-not (Test-Path -LiteralPath $r.SrcPath)) {
                [void]$skipped.Add(@{ Rec = $r; Why = '客户端源文件已不存在（可能被移动或删除）' })
                continue
            }
            $fi = Get-Item -LiteralPath $r.SrcPath
            if ([long]$fi.Length -ne [long]$r.Size) {
                [void]$skipped.Add(@{ Rec = $r; Why = '扫描后源文件大小已变化，请重新扫描' })
                continue
            }
            [void]$renames.Add(@{ Rec = $r; From = $from })
            continue
        }

        if ($r.StatusKind -eq '已同步') {
            [void]$skipped.Add(@{ Rec = $r; Why = '内容已一致，无需同步' })
            continue
        }

        if (-not (Test-Path -LiteralPath $r.SrcPath)) {
            [void]$skipped.Add(@{ Rec = $r; Why = '客户端源文件已不存在（可能被移动或删除）' })
            continue
        }
        $fi = Get-Item -LiteralPath $r.SrcPath
        if ([long]$fi.Length -ne [long]$r.Size) {
            [void]$skipped.Add(@{ Rec = $r; Why = '扫描后源文件大小已变化，请重新扫描' })
            continue
        }

        [void]$copies.Add(@{ Rec = $r })

        # 同一 mod 在目标端的旧版本：随本次同步一并移除，避免新旧 jar 冲突
        # （真正的删除在执行阶段，并且会先确认这个新版本确实复制成功了）
        foreach ($old in @($r.OldVersions)) {
            [void]$deletes.Add(@{ Rec = $r; Old = $old })
        }
    }
    return @{ Copies = $copies; Deletes = $deletes; Renames = $renames; Skipped = $skipped }
}

# 纯判定：这条记录的旧版本现在能不能删。
# 抽成独立函数有两个理由：① 它是"复制失败就绝不删旧版本"这条安全约束的唯一实现点，
# 逻辑必须一眼看得见；② 纯函数才能被 tests\Test-ModSync.ps1 直接覆盖。
function Test-CanDeleteOldVersion($copiedSrc, $rec) {
    if (-not $copiedSrc -or -not $rec) { return $false }
    return $copiedSrc.ContainsKey([string]$rec.SrcPath)
}

function Invoke-Sync {
    $plan = Get-SyncPlan

    if ($plan.Copies.Count -eq 0 -and $plan.Renames.Count -eq 0) {
        $extra = ''
        if ($plan.Skipped.Count -gt 0) { $extra = "`n`n已勾选的 $($plan.Skipped.Count) 项被跳过：" + (($plan.Skipped | Select-Object -First 5 | ForEach-Object { "`n  · $($_.Rec.FileName) —— $($_.Why)" }) -join '') }
        [System.Windows.Forms.MessageBox]::Show("没有需要同步的文件。$extra", '无需同步',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    # 同步一律以「当前生效目标」为准。注意不要在这里重新读 $txtServer：
    # SFTP 模式下那个文本框装的是远程目录，而 ActiveTarget 里的本地路径是校验过、归一化过的。
    $target = Get-ActiveTarget
    $script:ActiveTarget = $target
    $serverDir = $target.Dir

    # ---------- 安全提示：同步前明细 ----------
    $overwrite = @()
    foreach ($c in $plan.Copies) {
        $r = $c.Rec
        if ($r.DstSameBase) {
            $overwrite += $r
        }
    }
    $newAdd = @($plan.Copies | Where-Object { -not $_.Rec.DstSameBase })

    # 组装明细条目（按类别分组，便于核对）
    $items = New-Object System.Collections.ArrayList
    if ($plan.Renames.Count -gt 0) {
        [void]$items.Add("【将重命名 $($plan.Renames.Count) 个（内容已校验一致，只改文件名，不动内容）】")
        foreach ($rn in $plan.Renames) { [void]$items.Add("> $($rn.From.Name)  ->  $($rn.Rec.FileName)") }
    }
    if ($newAdd.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【将新增 $($newAdd.Count) 个】")
        foreach ($c in $newAdd) { [void]$items.Add("+ $($c.Rec.FileName)") }
    }
    if ($overwrite.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【将覆盖 $($overwrite.Count) 个已存在的文件】")
        foreach ($r in $overwrite) {
            [void]$items.Add("~ $($r.FileName)   [覆盖旧文件 $($r.DstSameBase.Name)]")
        }
    }
    if ($plan.Deletes.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【将从服务端删除 $($plan.Deletes.Count) 个旧版本文件】")
        [void]$items.Add("! 不删除会导致同名 mod 新旧两个 jar 同时存在，服务端可能直接崩溃")
        foreach ($d in $plan.Deletes) { [void]$items.Add("- $($d.Old.Name)") }
    }
    if ($plan.Skipped.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【跳过 $($plan.Skipped.Count) 个】")
        foreach ($s in $plan.Skipped) { [void]$items.Add("! $($s.Rec.FileName) —— $($s.Why)") }
    }

    $noteText = "目标端：$(Get-TargetLabel $target)"
    if ($chkBackup.Checked) { $noteText += "`n选项：覆盖前会把服务端原文件备份为 原名.bak" }
    $noteText += "`n建议先关闭服务端，避免 jar 被占用。"

    $promptText = "即将把 {0} 个 mod 文件同步到服务端" -f $plan.Copies.Count
    if ($plan.Renames.Count -gt 0) { $promptText += "，并把 $($plan.Renames.Count) 个文件改名" }
    $promptText += "，共 $($items.Count) 项明细："

    $ok = Show-ListConfirm -Title '同步前确认 —— 请核对以下变更' `
        -Prompt $promptText `
        -Items @($items) -OkText '确认同步' `
        -ItemColor ([System.Drawing.Color]::FromArgb(60, 60, 60)) -Note $noteText
    if (-not $ok) {
        $lblStatus.Text = '已取消同步'
        return
    }

    # ---------- 执行 ----------
    Set-Busy $true '正在同步...'
    $script:SyncLog = New-Object System.Collections.ArrayList
    $okCount = 0
    $renCount = 0
    $failCount = 0
    $keptOldCount = 0
    $copiedSrc = @{}   # 复制成功的记录（按客户端源路径）。删除旧版本前必须先查它。
    $step = 0
    $totalSteps = $plan.Copies.Count + $plan.Deletes.Count + $plan.Renames.Count

    # 先做重命名：只动文件名，内容已在扫描阶段用 MD5 校验过完全一致
    foreach ($rn in $plan.Renames) {
        $r = $rn.Rec
        $from = $rn.From
        $step++
        $lblStatus.Text = "正在重命名 $step / $totalSteps ：$($from.Name) -> $($r.FileName)"
        $progress.Maximum = [Math]::Max($totalSteps, 1)
        $progress.Value = [Math]::Min($step, $progress.Maximum)
        [System.Windows.Forms.Application]::DoEvents()

        $dstPath = Join-RemotePath $serverDir $r.FileName
        if ($target.Kind -eq 'Local') { $dstPath = Join-Path $serverDir $r.FileName }
        $renamed = $false
        try {
            if (Test-TargetFile $target $dstPath) { throw "服务端已存在同名文件：$($r.FileName)" }
            if ($chkBackup.Checked) {
                $bak = "$($from.Full).bak"
                if (Test-TargetFile $target $bak) { $bak = "$($from.Full)." + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.bak' }
                Copy-TargetFileInPlace $target $from.Full $bak
            }
            # 改名只走 Move-TargetFile（本地是 File.Move，远程是 SFTP RenameFile）：
            # 目标存在就报错，绝不允许在改名路径上覆盖内容。
            Move-TargetFile $target $from.Full $dstPath
            $r.Result = "已重命名：$($from.Name) → $($r.FileName)"
            $renCount++
            $renamed = $true
            [void]$script:SyncLog.Add("REN   $($from.Name) -> $($r.FileName)")
        } catch {
            $r.Result = '失败：' + $_.Exception.Message
            $failCount++
            [void]$script:SyncLog.Add("FAIL  重命名 $($from.Name) -> $($r.FileName)：$($_.Exception.Message)")
        }
        # 遗忘项记账放在 try 之外：文件名已经改好了，这里再出错也不该把结果报成"改名失败"
        if ($renamed) {
            try { [void](Move-IgnoredIdentity $from.Key $from.Name $r.Key $r.FileName) }
            catch { Write-Log ('遗忘项随改名迁移失败（不影响文件本身）：' + $_.Exception.Message) }
        }
    }

    foreach ($c in $plan.Copies) {
        $r = $c.Rec
        $step++
        $lblStatus.Text = "正在同步 $step / $totalSteps ：$($r.FileName)"
        $progress.Maximum = [Math]::Max($totalSteps, 1)
        $progress.Value = [Math]::Min($step, $progress.Maximum)
        [System.Windows.Forms.Application]::DoEvents()

        $dstPath = Join-RemotePath $serverDir $r.FileName
        if ($target.Kind -eq 'Local') { $dstPath = Join-Path $serverDir $r.FileName }
        $note = ''
        try {
            if ((Test-TargetFile $target $dstPath) -and $chkBackup.Checked) {
                $bak = "$dstPath.bak"
                if (Test-TargetFile $target $bak) {
                    $bak = "$dstPath." + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.bak'
                }
                Copy-TargetFileInPlace $target $dstPath $bak
                $note = ' (已备份 .bak)'
            }
            Copy-LocalFileToTarget $target $r.SrcPath $dstPath
            $r.Result = '成功' + $note
            $okCount++
            $copiedSrc[[string]$r.SrcPath] = $true
            [void]$script:SyncLog.Add("OK    $($r.FileName)$note")
        } catch {
            $r.Result = '失败：' + $_.Exception.Message
            $failCount++
            [void]$script:SyncLog.Add("FAIL  $($r.FileName) -> $($_.Exception.Message)")
        }
    }

    foreach ($d in $plan.Deletes) {
        $step++
        $lblStatus.Text = "正在清理旧版本 $step / $totalSteps ：$($d.Old.Name)"
        $progress.Value = [Math]::Min($step, $progress.Maximum)
        [System.Windows.Forms.Application]::DoEvents()

        # 顺序约束（重要）：新版本没复制成功，就绝不删旧版本。
        # 复制可能因为磁盘满、无写权限、共享断开而失败；此时若把旧 jar 删掉，
        # 这个 mod 在服务端就彻底没了——宁可留下新旧两份让用户自己处理。
        if (-not (Test-CanDeleteOldVersion $copiedSrc $d.Rec)) {
            $keptOldCount++
            [void]$script:SyncLog.Add("KEEP  保留旧版本 $($d.Old.Name)（新版本未复制成功，删掉会让这个 mod 在服务端消失）")
            continue
        }

        try {
            if (Test-TargetFile $target $d.Old.Full) {
                Remove-TargetFile $target $d.Old.Full
                [void]$script:SyncLog.Add("DEL   $($d.Old.Name)")
            }
        } catch {
            $failCount++
            [void]$script:SyncLog.Add("FAIL  删除 $($d.Old.Name) -> $($_.Exception.Message)")
        }
    }

    Set-Busy $false

    # 回填每行结果
    foreach ($row in $grid.Rows) {
        $r = $row.Tag
        if (-not $r) { continue }
        if ($r.Result) {
            $row.Cells[6].Value = $r.Result
            if ($r.Result.StartsWith('失败')) {
                $row.Cells[6].Style.ForeColor = [System.Drawing.Color]::FromArgb(200, 40, 40)
            } else {
                $row.Cells[6].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
            }
        }
    }

    # ---------- 结果反馈 ----------
    $summary = "同步完成。`n`n重命名：$renCount 个`n成功复制：$okCount 个`n删除旧版本：$($plan.Deletes.Count - $keptOldCount) 个`n失败：$failCount 个"
    if ($keptOldCount -gt 0) {
        $summary += "`n`n⚠ 有 $keptOldCount 个旧版本被保留：对应的新版本没有复制成功。`n" +
                    "（直接删旧版本会让这些 mod 在服务端彻底消失，所以留着了。）`n" +
                    "处理办法：解决复制失败的原因后重新扫描同步；确认不需要的旧 jar 请手动删除。"
    }
    if ($failCount -gt 0) {
        $summary += "`n`n失败详情：`n" + (($script:SyncLog | Where-Object { $_.StartsWith('FAIL') } | Select-Object -First 10) -join "`n")
        $summary += "`n`n常见原因：服务端正在运行、文件被占用、或没有目标文件夹的写入权限。"
    }
    $summary += "`n`n请重新扫描以刷新列表状态。"

    [System.Windows.Forms.MessageBox]::Show($summary,
        $(if ($failCount -gt 0) { '同步完成（有失败）' } else { '同步成功' }),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($failCount -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null

    $lblStatus.Text = "同步结束：成功 $okCount，失败 $failCount" + $(if ($keptOldCount -gt 0) { "，保留旧版本 $keptOldCount" } else { '' })
    Invoke-Scan
}

# ------------------------------------------------------------------ 重命名

# 遗忘项跟着改名一起搬：用户遗忘的是「这个 mod」，不是「这个文件名」。
# 所以 mod 改名后，遗忘记录必须一起迁移，否则它会作为新名字重新冒出来。
function Move-IgnoredIdentity([string]$oldKey, [string]$oldName, [string]$newKey, [string]$newName) {
    if (-not $oldKey -or -not $newKey) { return }
    if ($oldKey -eq $newKey) { return }
    $list = @(Get-IgnoredMods)
    if ($list -notcontains $oldKey) { return }

    $keep = New-Object System.Collections.ArrayList
    $moved = $false
    foreach ($k in $list) {
        if ([string]$k -eq $oldKey) {
            if (-not $moved -and -not ($keep -contains $newKey)) { [void]$keep.Add($newKey); $moved = $true }
        } elseif (-not ($keep -contains [string]$k)) {
            [void]$keep.Add([string]$k)
        }
    }
    $info = New-Object System.Collections.ArrayList
    foreach ($it in @(Get-IgnoredInfo)) {
        if (-not $it) { continue }
        if ([string]$it.Key -eq $oldKey) {
            [void]$info.Add([pscustomobject]@{ Key = $newKey; FileName = $newName; Time = $it.Time })
        } else {
            [void]$info.Add($it)
        }
    }
    Set-IgnoredList @($keep) @($info)
    Write-Cfg
    Write-Log ("遗忘项已随改名迁移：{0}（{1}）→ {2}（{3}）" -f $oldKey, $oldName, $newKey, $newName)
}

# 自动重命名：扫描判定为「重命名」的项直接改名同步到服务端，不弹确认框。
# 安全性来自判定本身——只有内容 MD5 完全一致、且目标端没被别的客户端文件认领的项
# 才会被标成重命名，所以这里只"改名字"：不复制、不覆盖、不删除任何内容。
function Invoke-AutoRename {
    if (-not $chkRename.Checked) { return }
    if ($script:AutoRenameBusy) { return }

    $targets = @($script:Records | Where-Object { $_.StatusKind -eq '重命名' })
    if ($targets.Count -eq 0) { return }

    $tgt = Get-ActiveTarget
    if ([string]::IsNullOrWhiteSpace($tgt.Dir)) { return }
    if ($tgt.Kind -eq 'Local' -and -not (Test-Path -LiteralPath $tgt.Dir)) { return }
    $serverDir = $tgt.Dir

    $script:AutoRenameBusy = $true
    $done = 0
    $failed = 0
    $firstError = ''
    try {
        foreach ($r in $targets) {
            $from = $r.DstRenameFrom
            if (-not $from) { continue }
            $fromName = [string]$from.Name
            $dstPath = Join-RemotePath $serverDir $r.FileName
            if ($tgt.Kind -eq 'Local') { $dstPath = Join-Path $serverDir $r.FileName }
            try {
                if (-not (Test-TargetFile $tgt $from.Full)) { continue }
                if (Test-TargetFile $tgt $dstPath) { throw "服务端已存在同名文件：$($r.FileName)" }
                Move-TargetFile $tgt $from.Full $dstPath
                $done++
                Write-Log ("自动重命名：{0} -> {1}" -f $fromName, $r.FileName)
                # 记账紧跟其后但独立捕获：文件已经改名成功，记账再出错也不能算"改名失败"，
                # 否则会误报失败、还会跳过下面的重扫，列表状态就留在脏状态里了
                try { [void](Move-IgnoredIdentity $from.Key $fromName $r.Key $r.FileName) }
                catch { Write-Log ('遗忘项随自动改名迁移失败（不影响文件本身）：' + $_.Exception.Message) }
            } catch {
                $failed++
                if (-not $firstError) { $firstError = $_.Exception.Message }
                Write-Log ("自动重命名失败：{0} -> {1}：{2}" -f $fromName, $r.FileName, $_.Exception.Message)
            }
        }

        if ($done -gt 0) {
            Write-Log ("自动重命名完成：成功 {0}，失败 {1}" -f $done, $failed)
            $script:AutoRenameNote = "已自动重命名 $done 项（双端文件名已一致）"
            Invoke-Scan     # 双端文件名已一致，重扫一次把列表刷新干净
        }
    } finally {
        $script:AutoRenameBusy = $false
    }

    if ($failed -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            ("有 {0} 个文件自动改名失败（已跳过，列表里仍标着「重命名」）：`n`n{1}`n`n常见原因：服务端正在运行、jar 被占用、或没有写入权限。" -f $failed, $firstError),
            '自动重命名失败', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

# 手动重命名：把勾选的那一个 mod 在「客户端 + 服务端」同时改名，一步到位。
# 适合"我想主动改个名字"或"服务端那边先改了名"的情况。
function Rename-Selected {
    $picked = @($grid.Rows | Where-Object { $_.Tag -and [bool]$_.Cells[0].Value })
    if ($picked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先在「同步」列勾选要重命名的 mod。`n`n勾 1 个 = 改成任意新名字；`n勾多个 = 统一加前缀（如 [客户端]、[服务端]）。",
            '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    if ($picked.Count -gt 1) {
        Rename-Batch @($picked | ForEach-Object { $_.Tag })
        return
    }
    Rename-Record $picked[0].Tag
}

# 对单条记录执行重命名（工具栏「重命名选中项」与右键菜单共用同一套逻辑）
function Rename-Record($r) {
    if (-not $r) { return }
    if (-not (Test-Path -LiteralPath $r.SrcPath)) {
        [System.Windows.Forms.MessageBox]::Show('客户端源文件已不存在，请重新扫描。', '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $input = Show-InputBox '重命名 mod' '新文件名（只写主名也行，会自动补 .jar）' $r.FileName
    if (-not $input) { return }
    $newName = $input.Trim().Trim('"')
    try { $newName = Split-Path $newName -Leaf } catch { }
    if ([string]::IsNullOrWhiteSpace($newName)) { return }
    if ($newName.IndexOfAny([char[]]@('\', '/', ':', '*', '?', '"', '<', '>', '|')) -ge 0) {
        [System.Windows.Forms.MessageBox]::Show('文件名里不能包含 \ / : * ? " < > | 这些字符。', '名字无效',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (-not $newName.ToLower().EndsWith('.jar')) { $newName += '.jar' }
    if ($newName -eq $r.FileName) { return }

    $clientDir = Split-Path -Parent $r.SrcPath
    $clientNew = Join-Path $clientDir $newName
    if (Test-Path -LiteralPath $clientNew) {
        [System.Windows.Forms.MessageBox]::Show("客户端已经存在同名文件：`n$newName", '名字冲突',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # 服务端要一起改名的那个文件：优先同名，其次内容完全一致的那个
    $tgt = Get-ActiveTarget
    $serverDir = $tgt.Dir
    $serverOld = Get-ServerCounterpartForRecord $r $serverDir

    $items = New-Object System.Collections.ArrayList
    [void]$items.Add("+ 客户端：$($r.FileName)   ->   $newName")
    if ($serverOld) {
        [void]$items.Add("+ 服务端：$($serverOld.Name)   ->   $newName")
    } else {
        [void]$items.Add('! 服务端没找到对应文件（同名或内容一致），这次只改客户端')
    }
    $ok = Show-ListConfirm -Title '重命名确认' -Prompt '即将按下面的方案改名（只动文件名，内容不变）：' `
        -Items @($items) -OkText '确认改名' `
        -ItemColor ([System.Drawing.Color]::FromArgb(60, 60, 60)) `
        -Note '改名后两端文件名保持一致。服务端 mod 若正被运行中的服务端占用，改名会失败。'
    if (-not $ok) { return }

    $doneClient = $false
    $doneServer = $false
    $err = ''
    try {
        [System.IO.File]::Move($r.SrcPath, $clientNew)
        $doneClient = $true
    } catch { $err = "客户端改名失败：$($_.Exception.Message)" }

    if ($doneClient -and $serverOld) {
        try {
            $serverNew = Join-RemotePath $serverDir $newName
            if ($tgt.Kind -eq 'Local') { $serverNew = Join-Path $serverDir $newName }
            if (Test-TargetFile $tgt $serverNew) { throw "服务端已存在同名文件：$newName" }
            Move-TargetFile $tgt $serverOld.FullName $serverNew
            $doneServer = $true
        } catch { if (-not $err) { $err = "服务端改名失败：$($_.Exception.Message)" } }
    }

    if ($doneClient) { [void](Move-IgnoredIdentity $r.Key $r.FileName (Get-ModIdentity $newName).Key $newName) }
    Write-Log ("手动重命名：{0} -> {1}（客户端 {2}，服务端 {3}）" -f $r.FileName, $newName,
        $(if ($doneClient) { '成功' } else { '失败' }), $(if ($doneServer) { '成功' } else { '未改' }))

    $cTxt = $(if ($doneClient) { "已改名为 $newName" } else { '未改动' })
    $sTxt = $(if ($doneServer) { "已改名为 $newName" } elseif ($serverOld) { '未改动（需手动处理）' } else { '无需改动' })
    $txt = "客户端：$cTxt`n服务端：$sTxt"
    if ($err) { $txt += "`n`n错误：$err" }
    [System.Windows.Forms.MessageBox]::Show($txt, $(if ($err) { '重命名未完全成功' } else { '重命名完成' }),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($err) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null

    if ($doneClient -or $doneServer) { Invoke-Scan }
}

# ------------------------------------------------------------------ 批量重命名（统一加前缀）

# 「统一加前缀」对话框：新文件名 = 前缀 + 原名。
# 带 [客户端] / [服务端] 两个预设按钮 + 前 3 个改名结果的实时预览，
# 另外可以决定"服务端同名文件是否一起改"（比如只想给客户端的标记一下）。
function Show-PrefixDialog([int]$count, [object[]]$samples) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "批量重命名 —— 共 $count 个 mod"
    $dlg.Size = New-Object System.Drawing.Size(560, 320)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "给勾选的 $count 个 mod 统一加前缀：新文件名 = 前缀 + 原文件名"
    $lbl.Location = New-Object System.Drawing.Point(16, 14)
    $lbl.Size = New-Object System.Drawing.Size(520, 22)
    $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(16, 58)
    $tb.Size = New-Object System.Drawing.Size(300, 24)
    $tb.Text = '[客户端]'
    $tb.SelectAll()
    $dlg.Controls.Add($tb)

    $btnP1 = New-Object System.Windows.Forms.Button
    $btnP1.Text = '[客户端]'
    $btnP1.Location = New-Object System.Drawing.Point(326, 56)
    $btnP1.Size = New-Object System.Drawing.Size(88, 26)
    $dlg.Controls.Add($btnP1)

    $btnP2 = New-Object System.Windows.Forms.Button
    $btnP2.Text = '[服务端]'
    $btnP2.Location = New-Object System.Drawing.Point(420, 56)
    $btnP2.Size = New-Object System.Drawing.Size(88, 26)
    $dlg.Controls.Add($btnP2)

    $lblPrevTitle = New-Object System.Windows.Forms.Label
    $lblPrevTitle.Text = '改完是这样（前 3 个）：'
    $lblPrevTitle.Location = New-Object System.Drawing.Point(16, 92)
    $lblPrevTitle.Size = New-Object System.Drawing.Size(520, 20)
    $lblPrevTitle.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $dlg.Controls.Add($lblPrevTitle)

    $lblPrev = New-Object System.Windows.Forms.Label
    $lblPrev.Location = New-Object System.Drawing.Point(16, 114)
    $lblPrev.Size = New-Object System.Drawing.Size(520, 74)
    $lblPrev.ForeColor = [System.Drawing.Color]::FromArgb(30, 95, 190)
    $dlg.Controls.Add($lblPrev)

    $chkSrv = New-Object System.Windows.Forms.CheckBox
    $chkSrv.Text = '服务端同名（或内容一致）的文件一起改名'
    $chkSrv.Location = New-Object System.Drawing.Point(16, 192)
    $chkSrv.Size = New-Object System.Drawing.Size(420, 24)
    $chkSrv.Checked = $true
    $dlg.Controls.Add($chkSrv)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.Location = New-Object System.Drawing.Point(316, 232)
    $ok.Size = New-Object System.Drawing.Size(100, 32)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(430, 232)
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $refresh = {
        $pre = $tb.Text
        $lines = @()
        foreach ($s in $samples) { $lines += ('  ' + $pre + $s) }
        if ($lines.Count -eq 0) { $lines = @('  （没有可预览的样本）') }
        $lblPrev.Text = ($lines -join "`r`n")
    }
    $tb.Add_TextChanged($refresh)
    $btnP1.Add_Click({ $tb.Text = '[客户端]'; $tb.Focus() })
    $btnP2.Add_Click({ $tb.Text = '[服务端]'; $tb.Focus() })
    & $refresh

    $ret = $dlg.ShowDialog($form)
    $val = $tb.Text
    $alsoSrv = [bool]$chkSrv.Checked
    $dlg.Dispose()
    if ($ret -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{ Prefix = $val; AlsoServer = $alsoSrv }
    }
    return $null
}

# 算出批量改名方案（纯逻辑，不碰界面，便于单测）
# 返回 @{ Plan = @(每项: Rec/NewName/ClientNew/ServerOld/ServerNew); Skipped = @(Rec/Why) }
function Build-RenamePlan([object[]]$records, [string]$prefix, [string]$clientDir, [string]$serverDir, [bool]$alsoServer, $tgt = $null) {
    # $tgt 不给就是纯本地（测试和旧调用都走这条），给了才按目标端类型分派
    if (-not $tgt) { $tgt = [pscustomobject]@{ Kind = 'Local'; Dir = $serverDir } }
    $plan = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach ($r in @($records)) {
        if (-not $r) { continue }
        if (-not (Test-Path -LiteralPath $r.SrcPath)) {
            [void]$skipped.Add(@{ Rec = $r; Why = '客户端文件已不存在（可能被移动或删除）' })
            continue
        }
        $newName = $prefix + $r.FileName
        if ($newName -eq $r.FileName) {
            [void]$skipped.Add(@{ Rec = $r; Why = '新名字与原名字相同' })
            continue
        }
        $clientNew = Join-Path $clientDir $newName
        if (Test-Path -LiteralPath $clientNew) {
            [void]$skipped.Add(@{ Rec = $r; Why = "客户端已存在同名文件：$newName" })
            continue
        }
        $srvOld = $null
        $srvNew = $null
        if ($alsoServer) {
            $srvOld = Get-ServerCounterpartForRecord $r $serverDir
            if ($srvOld) {
                $srvNew = Join-RemotePath $serverDir $newName
                if ($tgt.Kind -eq 'Local') { $srvNew = Join-Path $serverDir $newName }
                if (Test-TargetFile $tgt $srvNew) {
                    [void]$skipped.Add(@{ Rec = $r; Why = "服务端已存在同名文件：$newName" })
                    continue
                }
            }
        }
        [void]$plan.Add([pscustomobject]@{
            Rec = $r; NewName = $newName; ClientNew = $clientNew; ServerOld = $srvOld; ServerNew = $srvNew
        })
    }
    return @{ Plan = $plan; Skipped = $skipped }
}

# 执行改名方案（同样是纯逻辑）。客户端先全部改完，再动服务端。
function Invoke-RenamePlan([object[]]$plan, $tgt = $null) {
    if (-not $tgt) { $tgt = [pscustomobject]@{ Kind = 'Local'; Dir = '' } }
    $details = New-Object System.Collections.ArrayList
    $res = @{ ClientOk = 0; ServerOk = 0; Fail = 0; FirstError = ''; Details = $details }
    foreach ($p in @($plan)) {
        try {
            # 用 .NET 的 File.Move：字面路径，不会被文件名里的 [ ] 当成通配符
            [System.IO.File]::Move($p.Rec.SrcPath, $p.ClientNew)
            $res.ClientOk++
            [void]$details.Add("OK    $($p.Rec.FileName) -> $($p.NewName)")
            # 记账独立捕获：文件已经改好名了，这里再出错也不能把这一项算成改名失败
            try { [void](Move-IgnoredIdentity $p.Rec.Key $p.Rec.FileName (Get-ModIdentity $p.NewName).Key $p.NewName) }
            catch { [void]$details.Add("WARN  遗忘项迁移失败（文件已改名）：$($_.Exception.Message)") }
        } catch {
            $res.Fail++
            if (-not $res.FirstError) { $res.FirstError = $_.Exception.Message }
            [void]$details.Add("FAIL  $($p.Rec.FileName) -> $($p.NewName)：$($_.Exception.Message)")
        }
    }
    foreach ($p in @($plan)) {
        if (-not $p.ServerOld) { continue }
        try {
            Move-TargetFile $tgt $p.ServerOld.FullName $p.ServerNew
            $res.ServerOk++
            [void]$details.Add("OK    [服务端] $($p.ServerOld.Name) -> $($p.NewName)")
        } catch {
            $res.Fail++
            if (-not $res.FirstError) { $res.FirstError = $_.Exception.Message }
            [void]$details.Add("FAIL  [服务端] $($p.ServerOld.Name) -> $($p.NewName)：$($_.Exception.Message)")
        }
    }
    return $res
}

# 批量重命名（界面流程）：勾选多个 → 统一加前缀 → 明细确认 → 执行 → 重扫
function Rename-Batch([object[]]$records) {
    $targets = @($records | Where-Object { $_ })
    if ($targets.Count -eq 0) { return }

    $samples = @($targets | Select-Object -First 3 | ForEach-Object { $_.FileName })
    $ask = Show-PrefixDialog $targets.Count $samples
    if (-not $ask) { return }
    $prefix = ([string]$ask.Prefix).Trim()
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        [System.Windows.Forms.MessageBox]::Show('前缀是空的，文件名不会有任何变化，已取消。', '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    if ($prefix.IndexOfAny([char[]]@('\', '/', ':', '*', '?', '"', '<', '>', '|')) -ge 0) {
        [System.Windows.Forms.MessageBox]::Show('前缀里不能包含 \ / : * ? " < > | 这些字符。', '前缀无效',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $clientDir = Split-Path -Parent $targets[0].SrcPath
    $tgt = Get-ActiveTarget
    $serverDir = $tgt.Dir
    $built = Build-RenamePlan $targets $prefix $clientDir $serverDir ([bool]$ask.AlsoServer) $tgt
    $plan = @($built.Plan)
    $skipped = @($built.Skipped)

    $items = New-Object System.Collections.ArrayList
    if ($plan.Count -gt 0) {
        [void]$items.Add("【客户端 $($plan.Count) 个】")
        foreach ($p in $plan) { [void]$items.Add("  $($p.Rec.FileName)  ->  $($p.NewName)") }
    }
    $srvItems = @($plan | Where-Object { $_.ServerOld })
    if ($srvItems.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【服务端 $($srvItems.Count) 个（同名 / 内容一致的那个一起改）】")
        foreach ($p in $srvItems) { [void]$items.Add("  $($p.ServerOld.Name)  ->  $($p.NewName)") }
    }
    if ($skipped.Count -gt 0) {
        if ($items.Count -gt 0) { [void]$items.Add('') }
        [void]$items.Add("【跳过 $($skipped.Count) 个】")
        foreach ($s in $skipped) { [void]$items.Add("! $($s.Rec.FileName) —— $($s.Why)") }
    }

    if ($plan.Count -eq 0) {
        $why = @($skipped | Select-Object -First 10 | ForEach-Object { "· $($_.Rec.FileName) —— $($_.Why)" }) -join "`n"
        [System.Windows.Forms.MessageBox]::Show("没有可以改名的地方：`n`n$why", '无需改名',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $ok = Show-ListConfirm -Title '批量重命名确认' `
        -Prompt ("统一加前缀「{0}」，新文件名 = 前缀 + 原名，共 {1} 项明细：" -f $prefix, $items.Count) `
        -Items @($items) -OkText '确认改名' `
        -ItemColor ([System.Drawing.Color]::FromArgb(60, 60, 60)) `
        -Note '只改文件名，内容不动。服务端 mod 若正被运行中的服务端占用，改名会失败。'
    if (-not $ok) { return }

    Set-Busy $true '正在批量重命名...'
    $res = Invoke-RenamePlan $plan $tgt
    Set-Busy $false

    foreach ($d in @($res.Details)) { Write-Log ('批量重命名 ' + $d) }
    Write-Log ("批量重命名完成：客户端 {0}，服务端 {1}，失败 {2}" -f $res.ClientOk, $res.ServerOk, $res.Fail)

    $txt = "批量重命名完成（前缀 $prefix）`n`n客户端改名：$($res.ClientOk) 个`n服务端改名：$($res.ServerOk) 个`n跳过：$($skipped.Count) 个`n失败：$($res.Fail) 个"
    if ($res.Fail -gt 0) { $txt += "`n`n第一条错误：$($res.FirstError)`n`n（服务端正在运行时 jar 会被占用，关掉它再试一次。）" }
    $txt += "`n`n接下来会自动重新扫描刷新列表。"
    [System.Windows.Forms.MessageBox]::Show($txt,
        $(if ($res.Fail -gt 0) { '重命名完成（有失败）' } else { '重命名完成' }),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($res.Fail -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null

    $lblStatus.Text = "批量重命名：客户端 $($res.ClientOk)，服务端 $($res.ServerOk)，跳过 $($skipped.Count)，失败 $($res.Fail)"
    if ($res.ClientOk -gt 0 -or $res.ServerOk -gt 0) { Invoke-Scan }
}

# ------------------------------------------------------------------ 网站在线链接（MC百科 / CurseForge / Modrinth）

# 通用请求头。带个正常的 UA：Modrinth 要求标识自己，MC百科对空 UA 也不友好。
$script:HttpHeaders = @{
    'User-Agent' = 'ModSync/1.1 (local desktop tool)'
    'Accept'     = 'application/json, text/html;q=0.9'
}
$script:JarMetaCache = @{}
$script:LinkCache = $null
$script:LinkCacheFile = Join-Path $script:ConfigDir 'linkcache.json'

# 按条目名取 ZIP 内容。先走 GetEntry 的快路径，取不到再遍历一次做分隔符归一化：
# ZIP 规范要求正斜杠，但个别打包工具（含 .NET 自己的 CreateFromDirectory）会写成反斜杠，
# 那种 jar 光靠 GetEntry 是找不到元数据的。
function Get-ZipEntryAny($zip, [string]$name) {
    $e = $zip.GetEntry($name)
    if ($e) { return $e }
    $want = $name.ToLower()
    foreach ($it in $zip.Entries) {
        if ((($it.FullName -replace '\\', '/').ToLower()) -eq $want) { return $it }
    }
    return $null
}

# ---- jar 元数据：不解压、不写盘，只读 ZIP 里那一个小文本文件 ----
# 1.20.5+ 的 NeoForge 用 META-INF/neoforge.mods.toml；老 Forge 用 META-INF/mods.toml；
# Fabric/Quilt 用 fabric.mod.json。返回 ModId / 显示名 / 版本 / 作者填的官网。
function Get-JarModMeta([string]$path) {
    $ck = $null
    try {
        $fi = Get-Item -LiteralPath $path
        $ck = $path + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
    } catch { }
    if ($ck -and $script:JarMetaCache.ContainsKey($ck)) { return $script:JarMetaCache[$ck] }

    $out = [ordered]@{ ModId = ''; DisplayName = ''; Version = ''; Homepage = ''; Source = '' }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            foreach ($n in @('META-INF/neoforge.mods.toml', 'META-INF/mods.toml')) {
                $e = Get-ZipEntryAny $zip $n
                if (-not $e) { continue }
                $sr = New-Object System.IO.StreamReader($e.Open())
                $txt = $sr.ReadToEnd(); $sr.Close()
                $out.ModId = [regex]::Match($txt, '(?m)^\s*modId\s*=\s*"([^"]+)"').Groups[1].Value
                $out.DisplayName = [regex]::Match($txt, '(?m)^\s*displayName\s*=\s*"([^"]+)"').Groups[1].Value
                $out.Version = [regex]::Match($txt, '(?m)^\s*version\s*=\s*"([^"]+)"').Groups[1].Value
                $out.Homepage = [regex]::Match($txt, '(?m)^\s*displayURL\s*=\s*"([^"]+)"').Groups[1].Value
                $out.Source = $n
                break
            }
            if (-not $out.ModId) {
                $e = Get-ZipEntryAny $zip 'fabric.mod.json'
                if ($e) {
                    $sr = New-Object System.IO.StreamReader($e.Open())
                    $js = $sr.ReadToEnd(); $sr.Close()
                    $j = $js | ConvertFrom-Json
                    $out.ModId = [string]$j.id
                    $out.DisplayName = [string]$j.name
                    $out.Version = [string]$j.version
                    if ($j.contact) {
                        $out.Homepage = [string]$(if ($j.contact.homepage) { $j.contact.homepage } else { $j.contact.sources })
                    }
                    $out.Source = 'fabric.mod.json'
                }
            }
        } finally { $zip.Dispose() }
    } catch {
        Write-Log ('读取 jar 元数据失败：{0} → {1}' -f (Split-Path $path -Leaf), $_.Exception.Message)
    }
    if (-not $out.DisplayName) { $out.DisplayName = $out.ModId }
    $obj = [pscustomobject]$out
    if ($ck) { $script:JarMetaCache[$ck] = $obj }
    return $obj
}

# ---- 名字匹配：判断"查到的页面"是不是我们要的那个 mod ----
function Get-NormName([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace '[^a-zA-Z0-9]', '').ToLower()
}
# 全部归一化成"只有小写字母数字"再比：AdvancedAE = advanced-ae = Advanced AE
function Test-NameMatch([string]$candidate, [string]$modId, [string]$displayName) {
    $c = Get-NormName $candidate
    if (-not $c) { return $false }
    foreach ($t in @((Get-NormName $modId), (Get-NormName $displayName))) {
        if ($t -and $c -eq $t) { return $true }
    }
    # MC百科 的标题常写成「[AAE] 高级AE (AdvancedAE)」这种带中括号/别名的形式，允许包含匹配，
    # 但要求目标名足够长（≥5），避免 "jei" 这种短名在长标题里乱命中
    foreach ($t in @((Get-NormName $modId), (Get-NormName $displayName))) {
        if ($t.Length -ge 5 -and $c.Contains($t)) { return $true }
    }
    return $false
}

# ---- 链接缓存：解析成功的精确链接落盘，第二次点击瞬间打开、断网也能用 ----
function Get-LinkCache {
    if ($null -ne $script:LinkCache) { return $script:LinkCache }
    $script:LinkCache = @{}
    try {
        if (Test-Path -LiteralPath $script:LinkCacheFile) {
            $raw = [System.IO.File]::ReadAllText($script:LinkCacheFile, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                $h = @{}
                foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = [string]$q.Value }
                $script:LinkCache[$p.Name] = $h
            }
        }
    } catch {
        Write-Log ('读取链接缓存失败（忽略）：' + $_.Exception.Message)
        $script:LinkCache = @{}
    }
    return $script:LinkCache
}
function Save-LinkCache {
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($script:LinkCacheFile, ($script:LinkCache | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Log ('写链接缓存失败（忽略）：' + $_.Exception.Message)
    }
}
function Get-CachedLink([string]$key, [string]$site) {
    if (-not $key) { return '' }
    $c = Get-LinkCache
    if ($c.ContainsKey($key) -and $c[$key].ContainsKey($site)) { return [string]$c[$key][$site] }
    return ''
}
function Set-LinkCache([string]$key, [string]$site, [string]$url) {
    if (-not $key -or -not $url) { return }
    $c = Get-LinkCache
    if (-not $c.ContainsKey($key)) { $c[$key] = @{} }
    $c[$key][$site] = $url
    Save-LinkCache
}

function Get-WebText([string]$url, [int]$timeoutSec = 8) {
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $timeoutSec -UseBasicParsing -Headers $script:HttpHeaders -ErrorAction Stop
        return [string]$r.Content
    } catch {
        Write-Log ('抓取失败：{0} → {1}' -f $url, $_.Exception.Message)
        return $null
    }
}

# ---- Modrinth：官方免费 API，不需要 key ----
function Resolve-ModrinthLink($rec, $meta) {
    $q = [string]$(if ($meta.DisplayName) { $meta.DisplayName } else { $rec.FileName })
    # ① 文件 SHA1 精确查：只有"从 Modrinth 下载的 jar"才命中，命中就是 100% 精确
    try {
        $sha1 = (Get-FileHash -LiteralPath $rec.SrcPath -Algorithm SHA1).Hash.ToLower()
        $v = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version_file/$sha1?algorithm=sha1" `
                -Headers $script:HttpHeaders -TimeoutSec 8 -ErrorAction Stop
        if ($v.project_id) {
            $p = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$($v.project_id)" `
                    -Headers $script:HttpHeaders -TimeoutSec 8 -ErrorAction Stop
            if ($p.slug) { return @{ Url = "https://modrinth.com/mod/$($p.slug)"; Note = "精确（按文件哈希定位：$($p.title)）" } }
        }
    } catch { }
    # ② 名字搜索：取前 3 条，优先完全同名，其次标题包含 mod 名
    try {
        $r = Invoke-RestMethod -Uri ("https://api.modrinth.com/v2/search?query=" + [uri]::EscapeDataString($q) + "&limit=3") `
                -Headers $script:HttpHeaders -TimeoutSec 8 -ErrorAction Stop
        $hits = @($r.hits)
        $pick = $null
        foreach ($h in $hits) {
            if ((Get-NormName $h.title) -eq (Get-NormName $q) -or
                ((Get-NormName $meta.ModId) -and (Get-NormName $h.slug).Contains((Get-NormName $meta.ModId)))) { $pick = $h; break }
        }
        if (-not $pick -and $hits.Count -gt 0 -and (Test-NameMatch $hits[0].title $meta.ModId $meta.DisplayName)) { $pick = $hits[0] }
        if ($pick) { return @{ Url = "https://modrinth.com/mod/$($pick.slug)"; Note = "精确（名字匹配：$($pick.title)）" } }
    } catch { }
    return @{ Url = 'https://modrinth.com/mods?q=' + [uri]::EscapeDataString($q); Note = '未找到精确页面，已打开搜索结果' }
}

# ---- MC 百科：抓搜索页，从结果里取 class 编号 ----
function Resolve-McmodLink($rec, $meta) {
    $q = [string]$(if ($meta.DisplayName) { $meta.DisplayName } else { $rec.FileName })
    $searchUrl = 'https://search.mcmod.cn/s?key=' + [uri]::EscapeDataString($q)
    $html = Get-WebText $searchUrl 9
    if ($html) {
        $items = New-Object System.Collections.ArrayList
        $rx = [regex]'href="(?:https:)?//(?:www\.)?mcmod\.cn/class/(\d+)\.html"[^>]*>([\s\S]{0,200}?)</a>'
        foreach ($m in $rx.Matches($html)) {
            $id = $m.Groups[1].Value
            $ti = (($m.Groups[2].Value -replace '<[^>]+>', '') -replace '\s+', ' ').Trim()
            if (-not $ti) { continue }
            $dup = $false
            foreach ($it in $items) { if ($it.Id -eq $id) { $dup = $true; break } }
            if (-not $dup) { [void]$items.Add([pscustomobject]@{ Id = $id; Title = $ti }) }
            if ($items.Count -ge 4) { break }
        }
        $pick = $null
        foreach ($it in $items) {
            if ((Get-NormName $it.Title) -eq (Get-NormName $meta.DisplayName) -or
                (Get-NormName $it.Title) -eq (Get-NormName $meta.ModId)) { $pick = $it; break }
        }
        if (-not $pick -and $items.Count -gt 0 -and (Test-NameMatch $items[0].Title $meta.ModId $meta.DisplayName)) { $pick = $items[0] }
        if ($pick) {
            return @{ Url = "https://www.mcmod.cn/class/$($pick.Id).html"; Note = "精确（$($pick.Title)）" }
        }
    }
    return @{ Url = $searchUrl; Note = '未找到精确页面，已打开搜索结果' }
}

# ---- CurseForge：有 key 走文件指纹（100% 精确），没 key 用 cfwidget 校验 slug ----
function Get-CfSlugCandidates($meta, $rec) {
    $list = New-Object System.Collections.ArrayList
    $base = [string]$(if ($meta.DisplayName) { $meta.DisplayName } elseif ($meta.ModId) { $meta.ModId } else { $rec.FileName })
    $base = $base -replace '\.jar$', ''
    foreach ($s in @([string]$meta.ModId, [string]$meta.DisplayName, (Get-ModIdentity $rec.FileName).Key, $base)) {
        if (-not $s) { continue }
        foreach ($x in @((($s -replace '[^a-zA-Z0-9]+', '-').Trim('-')).ToLower(), ($s -replace '[^a-zA-Z0-9]', '').ToLower())) {
            if ($x -and -not $list.Contains($x)) { [void]$list.Add($x) }
        }
    }
    return @($list | Select-Object -First 4)
}

function Invoke-CfApi([string]$apiPath, [string]$apiKey, [string]$method = 'GET', [string]$jsonBody = '') {
    $hdr = @{ 'x-api-key' = $apiKey; 'Accept' = 'application/json'; 'User-Agent' = $script:HttpHeaders['User-Agent'] }
    $prm = @{ Uri = 'https://api.curseforge.com' + $apiPath; Headers = $hdr; Method = $method; TimeoutSec = 8; ErrorAction = 'Stop' }
    if ($jsonBody) { $prm['Body'] = $jsonBody; $prm['ContentType'] = 'application/json' }
    return (Invoke-RestMethod @prm)
}

function Resolve-CurseForgeLink($rec, $meta, [string]$apiKey) {
    $q = [string]$(if ($meta.DisplayName) { $meta.DisplayName } else { $rec.FileName })
    $searchUrl = 'https://www.curseforge.com/minecraft/search?class=mc-mods&search=' + [uri]::EscapeDataString($q)

    # ① mod 自己填的官网链接就是 CurseForge 页面 → 直接用，零成本
    if ($meta.Homepage -match '(?i)curseforge\.com/minecraft/mc-mods/([^/?#]+)') {
        return @{ Url = "https://www.curseforge.com/minecraft/mc-mods/$($Matches[1])"; Note = '精确（mod 自带的官网链接）' }
    }

    # ② 有 API Key：文件指纹 → 精确项目（实测 8/8 命中）
    if ($apiKey -and $script:CfHashReady) {
        $fp = Get-CfFingerprint $rec.SrcPath
        if ($fp -gt 0) {
            try {
                $body = @{ fingerprints = @([uint32]$fp) } | ConvertTo-Json -Compress
                $q1 = Invoke-CfApi '/v1/fingerprints' $apiKey 'POST' $body
                $ex = @($q1.data.exactMatches)
                if ($ex.Count -gt 0) {
                    $mid = [int]$ex[0].id
                    $md = (Invoke-CfApi "/v1/mods/$mid" $apiKey).data
                    $u = [string]$md.links.websiteUrl
                    if (-not $u -and $md.slug) { $u = "https://www.curseforge.com/minecraft/mc-mods/$($md.slug)" }
                    if ($u) { return @{ Url = $u; Note = "精确（文件指纹：$($md.name)）" } }
                }
            } catch {
                $msg = $_.Exception.Message
                try {
                    $rs = $_.Exception.Response
                    if ($rs) {
                        $sr = New-Object System.IO.StreamReader($rs.GetResponseStream())
                        $b = $sr.ReadToEnd(); $sr.Close()
                        if ($b) { $msg = ($b -replace '\s+', ' ').Trim() }
                    }
                } catch { }
                Write-Log ('CurseForge 指纹查询失败：' + $msg)
                if ($msg -match '(?i)api key') {
                    $script:CfKeyRejected = $true
                }
            }
        }
    }

    # ③ 免 key：用 cfwidget 校验猜出来的 slug（它返回标题，能验证是不是同一个 mod）
    foreach ($cand in (Get-CfSlugCandidates $meta $rec)) {
        try {
            $cw = Invoke-RestMethod -Uri "https://api.cfwidget.com/minecraft/mc-mods/$cand" `
                    -Headers $script:HttpHeaders -TimeoutSec 6 -ErrorAction Stop
            if (Test-NameMatch ([string]$cw.title) $meta.ModId $meta.DisplayName) {
                return @{ Url = "https://www.curseforge.com/minecraft/mc-mods/$cand"; Note = "精确（cfwidget 校验：$($cw.title)）" }
            }
        } catch { }
    }

    $extra = ''
    if ($script:CfKeyRejected) { $extra = '（API Key 被 CurseForge 拒绝，请检查设置里的 Key）' }
    elseif (-not $apiKey) { $extra = '（未填 CurseForge API Key，只能搜名字）' }
    return @{ Url = $searchUrl; Note = "未找到精确页面，已打开搜索结果$extra" }
}

# ---- 打开网页 ----
function Open-Url([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return }
    try {
        Start-Process $url          # 交给系统 ShellExecute → 默认浏览器
        Write-Log ('打开网页：' + $url)
    } catch {
        Write-Log ('打开网页失败：' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show("无法打开浏览器：`n$($_.Exception.Message)`n`n网址：`n$url", '打开网页',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

# 对"当前选中的那一行"打开在线页面。工具栏按钮 / Ctrl+1~3 快捷键都走这里。
# 返回 $true 表示已找到目标行（无论最后能不能解析出精确页面）。
function Open-ModSiteForSelected([string]$site) {
    $rec = $null
    if ($grid.SelectedRows.Count -gt 0) { $rec = $grid.SelectedRows[0].Tag }
    if (-not $rec) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先点选表格里的一行。`n`n更快的做法：在某一行上点右键 →「打开在线页面 ▸」，`n或者用快捷键 Ctrl+1 / Ctrl+2 / Ctrl+3。",
            '打开在线页面', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }
    $script:MenuRec = $rec
    Open-ModSite $site
    return $true
}

# ---- 右键菜单入口：解析 + 打开（带等待提示，失败也一定给出可用的页面）----
function Open-ModSite([string]$site) {
    $rec = $script:MenuRec
    if (-not $rec) { return }
    $siteName = switch ($site) { 'mcmod' { 'MC百科' } 'curseforge' { 'CurseForge' } default { 'Modrinth' } }

    $meta = Get-JarModMeta $rec.SrcPath
    $cacheKey = [string]$(if ($meta.ModId) { $meta.ModId } else { $rec.Key })

    $cached = Get-CachedLink $cacheKey $site
    if ($cached) {
        Open-Url $cached
        $lblStatus.Text = "已打开 $siteName（缓存）：$($meta.DisplayName)"
        return
    }

    $oldCursor = $form.Cursor
    $script:CfKeyRejected = $false
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = "正在查询 $siteName ..."
        [System.Windows.Forms.Application]::DoEvents()

        $res = switch ($site) {
            'mcmod'      { Resolve-McmodLink $rec $meta }
            'curseforge' { Resolve-CurseForgeLink $rec $meta ([string]$txtCfKey.Text).Trim() }
            default      { Resolve-ModrinthLink $rec $meta }
        }
    } finally {
        $form.Cursor = $oldCursor
    }

    if ($res -and $res.Url) {
        if ($res.Note -like '精确*') { Set-LinkCache $cacheKey $site $res.Url }
        Open-Url $res.Url
        $lblStatus.Text = "$siteName：$($res.Note)｜$($res.Url)"
    } else {
        $lblStatus.Text = "$siteName：查询失败"
    }
}

# ------------------------------------------------------------------ 打开位置与详情

# 在资源管理器里定位到某个文件（选中它本身）；路径是文件夹就直接打开文件夹。
# 文件已经不在了（被移动/删除）→ 退一步打开它所在的文件夹，并把这件事写进状态栏。
function Open-FileLocation([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        [System.Windows.Forms.MessageBox]::Show('这一项没有可打开的路径。', '打开位置',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $target = $null
    $isFolder = $false
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($item) {
            $target = $item.FullName
            $isFolder = [bool]$item.PSIsContainer
        }
    }
    if (-not $target) {
        $parent = $null
        try { $parent = Split-Path -Parent $path } catch { }
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            $target = (Get-Item -LiteralPath $parent).FullName
            $isFolder = $true
            $lblStatus.Text = "原文件已不在，改为打开所在文件夹：$target"
            Write-Log ("打开位置：原文件不存在，退回到文件夹 {0}（原路径 {1}）" -f $target, $path)
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "路径不存在或无法访问：`n$path`n`n（服务器路径需要先连接上；网络共享断开时会这样。）", '打开位置',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
    }

    try {
        # 用 ProcessStartInfo 直接给 explorer.exe 传参：
        # PowerShell 层再加引号会把 "/select,C:\带 空格\a.jar" 拼坏。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'explorer.exe'
        if ($isFolder) { $psi.Arguments = '"' + $target + '"' }
        else           { $psi.Arguments = '/select,"' + $target + '"' }
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        if (-not $isFolder) { $lblStatus.Text = "已定位到文件：$target" }
        Write-Log ("打开位置：{0}" -f $target)
    } catch {
        Write-Log ('打开资源管理器失败：' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show("无法打开资源管理器：`n$($_.Exception.Message)", '打开位置',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

# 找出某条记录在服务端对应的那个文件（改名用）：
# 先看服务端有没有同名文件；没有就按"大小相同 + MD5 相同"认内容一致的那个。
# 返回 FileInfo；找不到返回 $null。
function Get-ServerCounterpartForRecord($r, [string]$serverDir, $tgt = $null) {
    if (-not $r) { return $null }
    if (-not $tgt) { $tgt = Get-ActiveTarget }
    if ([string]::IsNullOrWhiteSpace($serverDir)) { return $null }
    if ($tgt.Kind -eq 'Local' -and -not (Test-Path -LiteralPath $serverDir)) { return $null }

    # 统一返回 @{Name; FullName}，本地/远程调用方一视同仁
    $samePath = Join-RemotePath $serverDir $r.FileName
    if ($tgt.Kind -eq 'Local') { $samePath = Join-Path $serverDir $r.FileName }
    if (Test-TargetFile $tgt $samePath) { return [pscustomobject]@{ Name = $r.FileName; FullName = $samePath } }

    $srcHash = Get-FileHashMd5 $r.SrcPath
    if (-not $srcHash) { return $null }
    foreach ($f in @(Get-TargetJarFiles $tgt)) {
        if ([long]$f.Length -ne [long]$r.Size) { continue }
        if ((Get-TargetFileMd5 $tgt $f.FullName) -eq $srcHash) {
            return [pscustomobject]@{ Name = $f.Name; FullName = $f.FullName }
        }
    }
    return $null
}

# 右键菜单「打开服务端文件位置」用：优先"将被覆盖/将被改名"的那个文件，其次服务端同名文件
function Get-ServerFileForRecord($r) {
    if (-not $r) { return '' }
    if ($r.DstSameBase -and $r.DstSameBase.Full) { return [string]$r.DstSameBase.Full }
    if ($r.DstRenameFrom -and $r.DstRenameFrom.Full) { return [string]$r.DstRenameFrom.Full }
    $tgt = Get-ActiveTarget
    $f = Get-ServerCounterpartForRecord $r $tgt.Dir $tgt
    if ($f) { return [string]$f.FullName }
    return ''
}

# 文件详情（双击某行 / 右键菜单「查看文件详情」共用）
function Show-RecordDetail($r) {
    if (-not $r) { return }
    $info = @"
文件名：$($r.FileName)
状态：$($r.StatusKind)
大小：$(Get-BytesText $r.Size)
修改时间：$($r.Time)
版本号：$(if ($r.Version) { $r.Version } else { '(未识别)' })
归组标识：$($r.Key)

客户端路径：$($r.SrcPath)
操作说明：$($r.Action)
$(if ($r.DstSameBase) { "`n覆盖目标：$($r.DstSameBase.Full)" })
$(if ($r.DstRenameFrom) { "`n将重命名（内容已校验一致）：`n  $($r.DstRenameFrom.Full)`n  ->  $($r.FileName)" })
$(if ($r.OldVersions.Count -gt 0) { "`n将删除的旧版本：`n" + (($r.OldVersions | ForEach-Object { '  ' + $_.Full }) -join "`n") })

提示：在某一行上点右键，可以直接定位到该文件所在的文件夹。
"@
    [System.Windows.Forms.MessageBox]::Show($info, '文件详情',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ------------------------------------------------------------------ 勾选辅助

function Set-AllChecked([bool]$value, [string]$onlyKind = '') {
    foreach ($row in $grid.Rows) {
        $r = $row.Tag
        if (-not $r) { continue }
        if ($onlyKind -and $r.StatusKind -ne $onlyKind) { continue }
        if ($onlyKind -and $r.StatusKind -eq '已同步') { continue }
        $row.Cells[0].Value = $value
    }
    $grid.Refresh()
}

# ------------------------------------------------------------------ 实时监控

function Update-Watcher {
    try {
        if ($script:Watcher) {
            $script:Watcher.EnableRaisingEvents = $false
            $script:Watcher.Dispose()
            $script:Watcher = $null
        }
        $script:PendingScan = $false
        if (-not $chkWatch.Checked) { return }

        $dir = Resolve-InputPath $txtClient.Text
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return }

        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $dir
        $w.Filter = '*.jar'
        $w.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
        # PCL 更新整合包时会瞬间产生大量文件事件，默认 8KB 缓冲区很容易溢出
        $w.InternalBufferSize = 65536
        $script:WatcherDir = $dir

        # 事件回调不在 UI 线程上，这里只记录时间戳与标志位。
        # 回调内部绝不触发任何扫描/UI 操作：一旦异常逃逸到监视器的事件分发里，
        # 整个进程都可能被带崩（这正是"PCL 一更新就退出"的疑似路径）。
        $handler = {
            try {
                $script:LastChange = [datetime]::Now
                $script:PendingScan = $true
            } catch { }
        }
        $w.Add_Changed($handler)
        $w.Add_Created($handler)
        $w.Add_Deleted($handler)
        $w.Add_Renamed($handler)

        # 缓冲区溢出/目录被删除等错误：只记录，绝不上抛
        $w.Add_Error({
            param($s, $e)
            try { Write-Log ('文件监控警告：' + $e.GetException().Message) } catch { }
        })

        $script:Watcher = $w
        $w.EnableRaisingEvents = $true
        Write-Log ('文件监控已挂载：{0}' -f $dir)
    } catch {
        try { Write-Log ('挂载文件监控失败：' + $_.Exception.Message) } catch { }
        try { $lblStatus.Text = "无法监控客户端文件夹：$($_.Exception.Message)" } catch { }
    }
}

# 监控自愈：目录被 PCL 删除重建后，原监视器会失效，这里负责重新挂上
function Test-WatcherAlive {
    try {
        if (-not $chkWatch.Checked) { return }
        $dir = Resolve-InputPath $txtClient.Text
        if ([string]::IsNullOrWhiteSpace($dir)) { return }
        if (-not (Test-Path -LiteralPath $dir)) { return }   # 目录暂时不在，等它回来
        if ($script:Watcher -and $script:WatcherDir -eq $dir) { return }
        Write-Log ('重新挂载文件监控：{0}' -f $dir)
        Update-Watcher
    } catch {
        try { Write-Log ('监控自愈失败：' + $_.Exception.Message) } catch { }
    }
}

# ------------------------------------------------------------------ 事件绑定

$cboProfile.Add_SelectedIndexChanged({
    if ($script:IgnoreProfileEvent) { return }
    $idx = $cboProfile.SelectedIndex
    if ($idx -ge 0) { Switch-Profile $idx }
})
$btnProfAdd.Add_Click({ Add-Profile })
$btnProfRename.Add_Click({ Rename-Profile })
$btnProfDel.Add_Click({ Remove-Profile })

$btnClient.Add_Click({
    $p = Select-Folder '选择【客户端】的 mods 文件夹' (Resolve-InputPath $txtClient.Text)
    if ($p) {
        $txtClient.Text = Get-DisplayPath $p
        Set-CurProfileField 'ClientDir' $p
        Write-Cfg
        Update-Watcher
    }
})

# 切换目标类型：立刻保存 + 更新界面 + 断开旧连接
$cboTargetKind.Add_SelectedIndexChanged({
    if ($script:IgnoreTargetEvent) { return }
    Set-CurProfileField 'TargetKind' $(if ($cboTargetKind.SelectedIndex -eq 1) { 'Sftp' } else { 'Local' })
    if ($cboTargetKind.SelectedIndex -eq 1) {
        # 切到 SFTP 时，把本地路径先收起来，框里换成远程目录
        Set-CurProfileField 'ServerDir' (Resolve-InputPath $txtServer.Text)
        $txtServer.Text = [string](Get-CurProfile).SftpDir
    } else {
        Set-CurProfileField 'SftpDir' (Normalize-RemoteDir $txtServer.Text)
        $txtServer.Text = $(if ((Get-CurProfile).ServerDir) { Get-DisplayPath (Get-CurProfile).ServerDir } else { '' })
    }
    Write-Cfg
    Update-TargetUI
    $script:ActiveTarget = $null
    Disconnect-SftpTarget
    $lblStatus.Text = '同步目标已切换，按 F5 重新扫描'
})

$btnServer.Add_Click({
    if ($cboTargetKind.SelectedIndex -eq 1) {
        # SFTP 模式：弹出连接设置；顺便把对话框里的远程目录回填到主界面
        $r = Show-SftpDialog
        if ($r) {
            Set-CurProfileField 'SftpHost' $r.Host
            Set-CurProfileField 'SftpPort' $r.Port
            Set-CurProfileField 'SftpUser' $r.User
            Set-CurProfileField 'SftpPass' $r.Pass
            Set-CurProfileField 'SftpDir'  $r.Dir
            $txtServer.Text = $r.Dir
            Write-Cfg
            Disconnect-SftpTarget
            $script:ActiveTarget = $null
            $lblStatus.Text = "SFTP 设置已保存：$($r.User)@$($r.Host):$($r.Port)$($r.Dir)（按 F5 扫描）"
        }
        return
    }
    $p = Select-Folder '选择【服务端】的 mods 文件夹' (Resolve-InputPath $txtServer.Text)
    if ($p) {
        $txtServer.Text = Get-DisplayPath $p
        Set-CurProfileField 'ServerDir' $p
        Write-Cfg
    }
})

$txtClient.Add_Leave({
    Set-CurProfileField 'ClientDir' (Resolve-InputPath $txtClient.Text)
    Write-Cfg
    Update-Watcher
})

$txtServer.Add_Leave({
    if ($cboTargetKind.SelectedIndex -eq 1) {
        Set-CurProfileField 'SftpDir' (Normalize-RemoteDir $txtServer.Text)
    } else {
        Set-CurProfileField 'ServerDir' (Resolve-InputPath $txtServer.Text)
    }
    Write-Cfg
})

$chkHash.Add_CheckedChanged({
    $script:Config.UseHash = $chkHash.Checked
    Write-Cfg
    if ($script:Records.Count -gt 0) { $lblStatus.Text = '哈希校验设置已变更，按 F5 重新扫描生效' }
})

$chkWatch.Add_CheckedChanged({
    $script:Config.AutoWatch = $chkWatch.Checked
    Write-Cfg
    Update-Watcher
})

$chkBackup.Add_CheckedChanged({
    $script:Config.Backup = $chkBackup.Checked
    Write-Cfg
})

$chkRename.Add_CheckedChanged({
    $script:Config.AutoRename = $chkRename.Checked
    Write-Cfg
})

$txtCfKey.Add_Leave({
    $v = ([string]$txtCfKey.Text).Trim()
    if ($v -ne [string]$script:Config.CurseForgeApiKey) {
        $script:Config.CurseForgeApiKey = $v
        Write-Cfg
        Write-Log $(if ($v) { 'CurseForge API Key 已更新' } else { 'CurseForge API Key 已清空' })
    }
})

$btnScan.Add_Click({ Invoke-Scan })
$btnRefresh.Add_Click({ Invoke-Scan })
$btnSync.Add_Click({ Invoke-Sync })
$btnOpenLog.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:LogFile) {
            Start-Process explorer.exe "/select,`"$($script:LogFile)`""
        } else {
            Start-Process explorer.exe "`"$($script:ConfigDir)`""
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("无法打开日志目录：`n$($_.Exception.Message)`n`n路径：$($script:ConfigDir)",
            '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})
$btnForget.Add_Click({ Forget-Selected })
$btnIgnored.Add_Click({ Show-IgnoredManager })
$btnRenameMod.Add_Click({ Rename-Selected })
$btnSelectAll.Add_Click({ Set-AllChecked $true })
$btnUnselect.Add_Click({ Set-AllChecked $false })
$btnInvert.Add_Click({
    foreach ($row in $grid.Rows) {
        $row.Cells[0].Value = -not [bool]$row.Cells[0].Value
    }
    $grid.Refresh()
})
$btnSelectPending.Add_Click({
    Set-AllChecked $false
    foreach ($row in $grid.Rows) {
        $r = $row.Tag
        if ($r -and $r.StatusKind -ne '已同步') { $row.Cells[0].Value = $true }
    }
    $grid.Refresh()
})

$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -eq 0) { return }
    Show-RecordDetail $grid.Rows[$e.RowIndex].Tag
})

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        $e.Handled = $true
        Invoke-Scan
    } elseif ($e.Control -and @([System.Windows.Forms.Keys]::D1, [System.Windows.Forms.Keys]::NumPad1) -contains $e.KeyCode) {
        $e.Handled = $true
        [void](Open-ModSiteForSelected 'mcmod')
    } elseif ($e.Control -and @([System.Windows.Forms.Keys]::D2, [System.Windows.Forms.Keys]::NumPad2) -contains $e.KeyCode) {
        $e.Handled = $true
        [void](Open-ModSiteForSelected 'curseforge')
    } elseif ($e.Control -and @([System.Windows.Forms.Keys]::D3, [System.Windows.Forms.Keys]::NumPad3) -contains $e.KeyCode) {
        $e.Handled = $true
        [void](Open-ModSiteForSelected 'modrinth')
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        # 扫描中按 Esc 中断，避免长时间卡住没法操作
        if ($script:ScanInProgress) {
            $script:CancelScan = $true
            $e.Handled = $true
            $lblStatus.Text = '正在取消...'
        }
    }
})

$form.Add_Shown({
    Read-Cfg
    Refresh-ProfileCombo
    Load-CurrentProfileToUI
    $chkHash.Checked   = [bool]$script:Config.UseHash
    $chkWatch.Checked  = [bool]$script:Config.AutoWatch
    $chkBackup.Checked = [bool]$script:Config.Backup
    $chkRename.Checked = [bool]$script:Config.AutoRename
    $txtCfKey.Text = [string]$script:Config.CurseForgeApiKey
    Write-Log ('配置已载入：配置档「{0}」| 在线链接：CurseForge Key={1}，链接缓存={2} 条' -f `
        (Get-CurProfile).Name,
        $(if ($script:Config.CurseForgeApiKey) { '已填写' } else { '未填写' }),
        (Get-LinkCache).Count)

    $lblStatus.Text = '正在扫描，请稍候...'
    [System.Windows.Forms.Application]::DoEvents()

    # 先扫描，扫描完成后再挂文件监控（延迟挂载是修复"启动即卡死"的关键之一：
    # 首次扫描时 DoEvents 会泵消息，此时若监控已就绪，事件重入会把界面拖死）
    if ($txtClient.Text -and (Test-TargetConfigured)) {
        Invoke-Scan
    } else {
        $script:LastScanMsg = '未填写客户端路径或同步目标，未执行扫描'
        $lblStatus.Text = '请先选择客户端 mods 文件夹和同步目标（选择后会自动保存）'
    }

    $script:PendingWatchStart = $true
    $watchTimer.Start()
})

$form.Add_FormClosing({
    # 先落退出日志：任何一步失败都不该让这次退出变成"无声消失"
    try {
        if (-not $script:LastScanOk) {
            # 没扫成 ≠ 扫了没变更：这两种情况在日志里必须一眼能分开
            Write-Log ('退出：本次会话未成功扫描（{0}）| 客户端={1} | 目标={2}' -f `
                $script:LastScanMsg, (Get-CurClientDir), (Get-TargetLabel (Get-CurTarget)))
        } else {
            $pending = @($script:Records | Where-Object { $_.Checked -and $_.StatusKind -ne '已同步' }).Count
            Write-Log ('退出：配置档「{0}」客户端 {1} 个 mod，待同步变更 {2} 个 | 客户端={3} | 目标={4}' -f `
                (Get-CurProfile).Name, $script:Records.Count, $pending, (Get-CurClientDir), (Get-TargetLabel (Get-CurTarget)))
        }
    } catch { }

    try {
        Set-CurProfileField 'ClientDir' (Resolve-InputPath $txtClient.Text)
        Save-TargetFromUI
        Write-Cfg
    } catch { }

    try { $watchTimer.Stop() } catch { }
    try { if ($script:Watcher) { $script:Watcher.Dispose() } } catch { }
    Disconnect-SftpTarget
})

Write-Log ('在线链接功能：CurseForge 指纹实现={0}' -f $(if ($script:CfHashReady) { '可用' } else { '不可用' }))
Write-Log ('启动：PowerShell {0} | 运行方式={1} | 哈希实现={2}' -f $PSVersionTable.PSVersion,
    $(if ($MyInvocation.MyCommand.Path) { "脚本 $($MyInvocation.MyCommand.Path)" } else { '临时脚本(exe 内置副本)' }),
    $script:HashImpl)

# 全局兜底：任何未处理异常都记录现场，绝不再无声退出
$null = [System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    try { Write-Log ('未处理异常：' + $e.ExceptionObject.ToString()) } catch { }
})

try {
    [void]$form.ShowDialog()
    Write-Log '正常退出'
} catch {
    Write-Log ('主流程异常：' + $_.Exception.ToString())
    try {
        [System.Windows.Forms.MessageBox]::Show(
            ("程序遇到错误并即将退出：`n`n{0}`n`n详细信息已写入日志：`n{1}" -f $_.Exception.Message, $script:LogPaths[0]),
            'ModSync 错误', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}
