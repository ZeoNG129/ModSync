<#
================================================================================
 build-exe.ps1  --   把 ModSync.ps1 打包成单个 ModSync.exe
--------------------------------------------------------------------------------
 原理：
   1. 读取 ModSync.ps1，Deflate 压缩后转 Base64；
   2. 生成一个 C# 启动器（WinForms，无控制台窗口），把该 Base64 字符串
      内嵌为 C# 常量，运行时解压回脚本原文；
   3. 用系统自带的 csc.exe 编译成单个 WinExe。

 产物：ModSync.exe（直接放在项目根目录）—— 绿色单文件，拷到任何 Win10/11 机器双击即用，
       不依赖旁边的 .ps1，也不需要安装 Python/Node/.NET SDK。

 重新打包：改完 ModSync.ps1 后，重新运行本脚本即可。
================================================================================
#>

param(
    # 脚本所在目录；不传时自动推断，推断不出来就回退到默认工作区路径
    [string]$ScriptDir = ''
)

$ErrorActionPreference = 'Stop'

$here = $ScriptDir
if ([string]::IsNullOrWhiteSpace($here)) { $here = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($here)) {
    # $PSScriptRoot 在 -File / 点源执行时才有值，这里退一步从脚本自身路径推
    try { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
}
if ([string]::IsNullOrWhiteSpace($here) -or -not (Test-Path -LiteralPath (Join-Path $here 'ModSync.ps1'))) {
    # 以前这里写死成 D:\AAA\ModSync，项目一搬家就指向不存在的目录。
    # 现在宁可明确报错，也不猜一个可能不存在的路径。
    throw '找不到 ModSync.ps1。请用 -ScriptDir "项目目录" 显式指定，或改成 "powershell -File build-exe.ps1" 的方式运行。'
}

$srcScript = Join-Path $here 'ModSync.ps1'
# 产物直接落在项目根目录：这就是个"双击根目录那个 exe 就能用"的绿色工具，
# 没必要再套一层 dist\（那一层当初只是为了配合 启动ModSync.bat，那个 bat 已经删了）。
$outExe    = Join-Path $here 'ModSync.exe'
$iconFile  = Join-Path $here 'icon.ico'
# 中间产物放在本机统一的临时区（D:\cache），项目目录和项目外都不留东西；
# 没有 D:\cache 的机器上退回系统 TEMP，保持脚本可移植。
$cacheRoot = 'D:\cache\ModSync'
if (-not (Test-Path 'D:\cache')) { $cacheRoot = Join-Path $env:TEMP 'ModSync' }
$buildRoot = Join-Path $cacheRoot 'build'
$tmpDir    = Join-Path $buildRoot 'tmp'

if (-not (Test-Path -LiteralPath $srcScript)) { throw "找不到源脚本：$srcScript" }

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 C# 编译器 csc.exe（需要 .NET Framework 4.x，Win10/11 默认自带）' }

Write-Host "[1/4] 读取源脚本：$srcScript"
$scriptText = [System.IO.File]::ReadAllText($srcScript, [System.Text.Encoding]::UTF8)
Write-Host ("      脚本 {0} 字符" -f $scriptText.Length)

Write-Host '[2/4] 压缩并编码脚本内容'
$srcBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptText)
$ms = New-Object System.IO.MemoryStream
$ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Compress)
$ds.Write($srcBytes, 0, $srcBytes.Length)
$ds.Close()
$packed = [Convert]::ToBase64String($ms.ToArray())
$ms.Dispose()
Write-Host ("      {0} 字节 -> 压缩后 Base64 {1} 字符" -f $srcBytes.Length, $packed.Length)

# 第二份：GZip 压缩，仅供「应急手动运行」时解出脚本用
# （不用 Brotli：Windows PowerShell 5.1 基于 .NET Framework，没有 BrotliStream）
$msG = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GZipStream($msG, [System.IO.Compression.CompressionMode]::Compress)
$gz.Write($srcBytes, 0, $srcBytes.Length)
$gz.Close()
$packedGzip = [Convert]::ToBase64String($msG.ToArray())
$msG.Dispose()
Write-Host ("      GZip 版（应急用）{0} 字符" -f $packedGzip.Length)

# 第三份：SSH.NET —— 远程同步（简幻欢这类 SFTP 服务器）要用。
# Windows PowerShell 5.1 / .NET Framework 里没有任何内置 SFTP 客户端，只能把这个库带上。
# 注意这里走 csc 的 /resource 以**压缩后的二进制资源**嵌入，而不是像脚本那样塞进 C# 字符串常量：
# .NET 的字符串常量在程序集里按 UTF-16 存，476K 字符要占 953 KB，白白翻一倍。
$sshDllPath = Join-Path $here 'lib\Renci.SshNet.dll'
$sshResFile = $null
if (Test-Path -LiteralPath $sshDllPath) {
    if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $dllBytes = [System.IO.File]::ReadAllBytes($sshDllPath)
    $sshResFile = Join-Path $tmpDir 'sshnet.bin'
    $fsD = [System.IO.File]::Create($sshResFile)
    $dsD = New-Object System.IO.Compression.DeflateStream($fsD, [System.IO.Compression.CompressionMode]::Compress)
    $dsD.Write($dllBytes, 0, $dllBytes.Length)
    $dsD.Close()
    $fsD.Dispose()
    Write-Host ("      内嵌 SSH.NET：{0:N0} 字节 -> Deflate 后 {1:N0} 字节" -f $dllBytes.Length, (Get-Item -LiteralPath $sshResFile).Length)
} else {
    Write-Host "      没找到 lib\Renci.SshNet.dll —— 打出来的 exe 将不支持 SFTP 远程同步" -ForegroundColor Yellow
}

# 自检：启动器绝不能把脚本塞进命令行
$cmdLineLen = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptText)).Length
if ($cmdLineLen -gt 32767) {
    Write-Host ("      自检：若改用 -EncodedCommand 需 {0:N0} 字符，超 CreateProcess 上限 32767。" -f $cmdLineLen) -ForegroundColor DarkGray
    Write-Host '      本启动器采用「临时脚本文件 + -File」方式，命令行长度固定，不受此限制。' -ForegroundColor DarkGray
}

Write-Host '[3/4] 生成启动器 C# 源码'
$launcher = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class ModSyncLauncher
{
    // 从 exe 里按尺寸取出图标（保留备用；当前方案改用嵌入资源，见 WriteIco）
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr LoadImage(IntPtr hinst, string lpszName, uint uType, int cx, int cy, uint fuLoad);
    const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10, LR_DEFAULTSIZE = 0x40;

    const string PackedScriptB64 =
"__PACKED_SCRIPT__";

    // 同一份脚本的 GZip 压缩版：万一 exe 启动异常，可用 PowerShell 的
    // GZipStream 解出来应急执行（做法见 README）
    const string PackedScriptGzipB64 =
"__PACKED_SCRIPT_GZIP__";

    // 内嵌的 SSH.NET（SFTP 客户端库）不在字符串常量里，而是以「Deflate 压缩后的二进制资源」
    // 形式嵌进来的，资源名 sshnet.bin。Windows PowerShell 5.1 没有内置 SFTP，
    // 远程同步（简幻欢等托管平台）全靠它。运行时解压成临时 .dll，
    // 路径通过环境变量 MODSYNC_SSHNET_DLL 交给脚本；脚本按需加载，纯本地用户不受影响。
    const string SshNetResourceName = "sshnet.bin";

    // 手工封装单条目 ICO（PNG-in-ICO，Vista+ 支持）。
    // 这样 PowerShell 端可以用标准的 System.Drawing.Icon 读取，不必依赖 PNG 转 Icon 的 API。
    static void WriteIco(string path, byte[] png)
    {
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (BinaryWriter bw = new BinaryWriter(fs))
        {
            bw.Write((ushort)0);          // 保留
            bw.Write((ushort)1);          // 类型：图标
            bw.Write((ushort)1);          // 条目数
            bw.Write((byte)0);            // 宽 0 表示 256
            bw.Write((byte)0);            // 高 0 表示 256
            bw.Write((byte)0);            // 调色板
            bw.Write((byte)0);            // 保留
            bw.Write((ushort)1);          // 色彩面
            bw.Write((ushort)32);         // 位深
            bw.Write((uint)png.Length);   // 数据长度
            bw.Write((uint)22);           // 数据偏移（6 + 16）
            bw.Write(png);
        }
    }

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        string script;
        try
        {
            byte[] packed = Convert.FromBase64String(PackedScriptB64);
            using (MemoryStream input = new MemoryStream(packed))
            using (DeflateStream deflate = new DeflateStream(input, CompressionMode.Decompress))
            using (MemoryStream output = new MemoryStream())
            {
                byte[] buffer = new byte[8192];
                int read;
                while ((read = deflate.Read(buffer, 0, buffer.Length)) > 0)
                {
                    output.Write(buffer, 0, read);
                }
                script = Encoding.UTF8.GetString(output.ToArray());
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("内置脚本解压失败：" + ex.Message, "ModSync",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        // ---- 关键：把脚本写成临时文件再执行 ----
        // 不能走 -EncodedCommand：脚本 Base64(UTF-16LE) 后约 10 万字符，
        // 远超 CreateProcess 的 32767 命令行上限，会直接报"文件名或扩展名太长"。
        string tmpScript = Path.Combine(Path.GetTempPath(), "McModSync_" + Guid.NewGuid().ToString("N") + ".ps1");

        // 清理历史残留：上次若被强制结束（任务管理器结束进程），临时脚本会留下来
        try
        {
            foreach (string stale in Directory.GetFiles(Path.GetTempPath(), "McModSync_*.ps1"))
            {
                try { if (File.GetLastWriteTime(stale) < DateTime.Now.AddHours(-1)) { File.Delete(stale); } }
                catch { }
            }
            foreach (string stale in Directory.GetFiles(Path.GetTempPath(), "McModSync_sshnet_*.dll"))
            {
                try { if (File.GetLastWriteTime(stale) < DateTime.Now.AddHours(-1)) { File.Delete(stale); } }
                catch { }
            }
        }
        catch { }

        string tmpIconPng = null;
        string tmpSshDll = null;
        try
        {
            File.WriteAllText(tmpScript, script, new UTF8Encoding(true));

            // 解出内嵌的 SSH.NET（SFTP 用）。它是 Deflate 压缩后的二进制资源（sshnet.bin），
            // 解不出来也不影响本地同步，只是脚本里 Initialize-SshNet 会报"找不到 Renci.SshNet.dll"。
            try
            {
                Assembly asmSsh = Assembly.GetExecutingAssembly();
                string sshRes = null;
                foreach (string rn in asmSsh.GetManifestResourceNames())
                {
                    if (rn.EndsWith(SshNetResourceName, StringComparison.OrdinalIgnoreCase)) { sshRes = rn; break; }
                }
                if (sshRes != null)
                {
                    tmpSshDll = Path.Combine(Path.GetTempPath(),
                        "McModSync_sshnet_" + Guid.NewGuid().ToString("N") + ".dll");
                    using (Stream s = asmSsh.GetManifestResourceStream(sshRes))
                    using (DeflateStream deflate = new DeflateStream(s, CompressionMode.Decompress))
                    using (FileStream fs = new FileStream(tmpSshDll, FileMode.Create, FileAccess.Write))
                    {
                        deflate.CopyTo(fs);
                    }
                }
            }
            catch { tmpSshDll = null; }

            // 把嵌入的完整多尺寸图标导出成临时 ICO，供脚本设置为窗口/任务栏图标。
            // 不用 Icon.ExtractAssociatedIcon：它只能返回 32x32。
            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                string resName = null;
                foreach (string rn in asm.GetManifestResourceNames())
                {
                    if (rn.EndsWith("appicon.ico", StringComparison.OrdinalIgnoreCase)) { resName = rn; break; }
                }
                if (resName != null)
                {
                    tmpIconPng = Path.Combine(Path.GetTempPath(),
                        "McModSyncIcon_" + Guid.NewGuid().ToString("N") + ".ico");
                    using (Stream s = asm.GetManifestResourceStream(resName))
                    using (FileStream fo = new FileStream(tmpIconPng, FileMode.Create, FileAccess.Write))
                    {
                        s.CopyTo(fo);
                    }
                }
            }
            catch { tmpIconPng = null; }

            // 兜底：万一嵌入资源缺失，至少给个图标
            if (tmpIconPng == null)
            {
                try
                {
                    using (Icon appIcon = Icon.ExtractAssociatedIcon(Process.GetCurrentProcess().MainModule.FileName))
                    {
                        if (appIcon != null)
                        {
                            tmpIconPng = Path.Combine(Path.GetTempPath(),
                                "McModSyncIcon_" + Guid.NewGuid().ToString("N") + ".ico");
                            using (Bitmap bmp = appIcon.ToBitmap())
                            using (MemoryStream pngMs = new MemoryStream())
                            {
                                bmp.Save(pngMs, System.Drawing.Imaging.ImageFormat.Png);
                                WriteIco(tmpIconPng, pngMs.ToArray());
                            }
                        }
                    }
                }
                catch { tmpIconPng = null; }
            }

            string host = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(host)) { host = "powershell.exe"; }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = host;
            // 不再加 -WindowStyle Hidden：实测它会让任务栏把窗口图标回退成宿主 powershell.exe 的图标。
            // 控制台窗口本身已由 CreateNoWindow 隐藏，不受影响。
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + tmpScript + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            if (tmpIconPng != null) { psi.EnvironmentVariables["MODSYNC_ICON_ICO"] = tmpIconPng; }
            if (tmpSshDll != null) { psi.EnvironmentVariables["MODSYNC_SSHNET_DLL"] = tmpSshDll; }

            Process proc = Process.Start(psi);
            proc.WaitForExit();

            // 图标文件要等窗口关闭后才能删（Icon 对象仍引用它）
            try { if (tmpIconPng != null && File.Exists(tmpIconPng)) { File.Delete(tmpIconPng); } }
            catch { }
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动失败：" + ex.Message, "ModSync",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            try { if (File.Exists(tmpScript)) { File.Delete(tmpScript); } } catch { }
            // SSH.NET 的 dll 也要等子进程退出后再删（子进程可能还映射着它）
            try { if (tmpSshDll != null && File.Exists(tmpSshDll)) { File.Delete(tmpSshDll); } } catch { }
        }
    }
}
'@

$launcher = $launcher.Replace('__PACKED_SCRIPT__', $packed)
$launcher = $launcher.Replace('__PACKED_SCRIPT_GZIP__', $packedGzip)

if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$csFile = Join-Path $tmpDir 'Launcher.cs'
[System.IO.File]::WriteAllText($csFile, $launcher, (New-Object System.Text.UTF8Encoding($true)))

# 把完整的多尺寸 icon.ico 作为嵌入资源打进 exe。
# 启动器运行时原样导出给脚本，窗口/任务栏都能拿到全部尺寸
# （256/128/64/48/32/16）。早先只给 32x32，任务栏里会发虚或回退成宿主图标。
$embedIcon = $null
if (Test-Path -LiteralPath $iconFile) {
    try {
        $embedIcon = Join-Path $tmpDir 'appicon.ico'
        Copy-Item -LiteralPath $iconFile -Destination $embedIcon -Force
        Write-Host ("      嵌入完整图标：{0} 字节（多尺寸）" -f (Get-Item $embedIcon).Length)
    } catch {
        Write-Host ("      图标嵌入失败（不影响使用）：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $embedIcon = $null
    }
}

Write-Host '[4/4] 编译'
$cscArgs = New-Object System.Collections.ArrayList
[void]$cscArgs.Add('/nologo')
[void]$cscArgs.Add('/target:winexe')
[void]$cscArgs.Add('/platform:anycpu')
[void]$cscArgs.Add('/optimize+')
[void]$cscArgs.Add('/utf8output')
[void]$cscArgs.Add('/codepage:65001')
[void]$cscArgs.Add('/reference:System.dll')
[void]$cscArgs.Add('/reference:System.Drawing.dll')
if (Test-Path -LiteralPath $iconFile) {
    [void]$cscArgs.Add('/win32icon:' + $iconFile)
    Write-Host "      使用图标：$iconFile"
}
# 把多尺寸图标作为嵌入资源打进 exe（资源名必须与启动器里查找的名字一致）
if ($embedIcon -and (Test-Path -LiteralPath $embedIcon)) {
    [void]$cscArgs.Add('/resource:' + $embedIcon + ',appicon.ico')
}
# 内嵌 SSH.NET（Deflate 压缩后的二进制资源，见上文；启动器按 sshnet.bin 查找）
if ($sshResFile -and (Test-Path -LiteralPath $sshResFile)) {
    [void]$cscArgs.Add('/resource:' + $sshResFile + ',sshnet.bin')
}
[void]$cscArgs.Add('/out:' + $outExe)
[void]$cscArgs.Add($csFile)

$logFile = Join-Path $tmpDir 'csc.log'
$cscOut = & $csc @($cscArgs.ToArray()) 2>&1
$cscOut | Out-File -LiteralPath $logFile -Encoding UTF8

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outExe)) {
    Write-Host '编译失败，编译器输出：' -ForegroundColor Red
    $cscOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "编译失败，详见 $logFile"
}

$cscOut | Where-Object { $_ -match 'warning' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }

$exeSize = (Get-Item -LiteralPath $outExe).Length
Write-Host ''
Write-Host '构建成功' -ForegroundColor Green
Write-Host ("  产物：{0}" -f $outExe)
Write-Host ("  大小：{0:N0} 字节 ({1:N1} KB)" -f $exeSize, ($exeSize / 1KB))
Write-Host ''
Write-Host '下一步：双击项目根目录的 ModSync.exe 测试（它会自己弹出界面）'
Write-Host '提示：ModSync.exe 是绿色单文件，可以单独拷到桌面或 U 盘，不需要旁边的任何文件。'

# 清理中间产物：整个 _build 目录一并删掉（成功才删；失败时保留供排查）
Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
