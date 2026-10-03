<#
================================================================================
 make-icon.ps1  --  把一张 PNG 图片转成多尺寸 Windows 图标 icon.ico
--------------------------------------------------------------------------------
 用法：
   powershell -ExecutionPolicy Bypass -File make-icon.ps1 -Png 图片路径

 说明：
   生成一个真正的多尺寸 ICO（默认 256/128/64/48/32/16 六档），每档都是
   独立的 32bpp PNG 帧。Windows 会按显示场景自己挑合适的一档：
   资源管理器小图标取 16/32，任务栏取 32/48，高分屏大图标取 256。
   只做单档的话，系统就得靠缩放凑合，小图标会发虚。

   ⚠ 256×256 那一档必须是 PNG 格式：ModSync.ps1 启动时是自己解析 ICO 目录、
   取最大一档的字节直接当 PNG 交给 System.Drawing.Bitmap 的（因为
   New-Object Icon($path) 只能拿到 32×32）。那一档写成 BMP/DIB 就读不出来了。

   生成的 icon.ico 放到 ModSync 目录下，重新运行 build-exe.ps1 即会被自动嵌入 exe。
   不生成图标也不影响使用，exe 会用系统默认图标。
================================================================================
#>

param(
    [Parameter(Mandatory = $true)][string]$Png,
    [string]$Out = '',
    [int[]]$Sizes = @(256, 128, 64, 48, 32, 16)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Png)) { throw "找不到图片：$Png" }

if ([string]::IsNullOrWhiteSpace($Out)) {
    # 输出目录一律从脚本自身位置推导，不写死任何绝对路径
    $dir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($dir)) {
        try { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw '无法确定脚本所在目录，请用 -Out 显式指定 icon.ico 的输出路径。'
    }
    $Out = Join-Path $dir 'icon.ico'
}

Write-Host "源图：$Png"
$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Png).Path)
Write-Host ("原始尺寸：{0} x {1}" -f $src.Width, $src.Height)

# 居中裁成正方形，作为所有尺寸的统一缩放源
$side = [Math]::Min($src.Width, $src.Height)
$sx = [int](($src.Width - $side) / 2)
$sy = [int](($src.Height - $side) / 2)
$srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)

# --- 逐档渲染成 PNG 字节 ---
$frames = New-Object System.Collections.ArrayList
foreach ($s in ($Sizes | Sort-Object -Descending -Unique)) {
    if ($s -lt 1 -or $s -gt 256) { continue }

    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    # SourceCopy：直接覆盖像素，避免缩小带 alpha 的图时边缘出现半透明黑边
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $s, $s)), $srcRect,
                 [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [void]$frames.Add(@{ Size = $s; Bytes = $ms.ToArray() })
    $ms.Dispose()
}
$src.Dispose()

if ($frames.Count -eq 0) { throw '没有任何有效尺寸（Sizes 必须在 1..256 之间）。' }

# --- 手写 ICO：6 字节文件头 + 每档 16 字节目录项 + 各档数据 ---
$offset = 6 + 16 * $frames.Count
$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0)                 # 保留
$bw.Write([uint16]1)                 # 类型：1 = 图标
$bw.Write([uint16]$frames.Count)     # 帧数

foreach ($f in $frames) {
    $dim = [byte]$(if ($f.Size -ge 256) { 0 } else { $f.Size })   # 0 表示 256
    $bw.Write($dim)                  # 宽
    $bw.Write($dim)                  # 高
    $bw.Write([byte]0)               # 调色板颜色数（真彩色填 0）
    $bw.Write([byte]0)               # 保留
    $bw.Write([uint16]1)             # 色彩面
    $bw.Write([uint16]32)            # 位深
    $bw.Write([int]$f.Bytes.Length)  # 该帧数据长度
    $bw.Write([int]$offset)          # 该帧数据偏移
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.Bytes) }
$bw.Flush()
$bw.Close()
$fs.Dispose()

# --- 自检：把刚写出的文件重新解析一遍，确认帧数与尺寸都对 ---
$ib = [System.IO.File]::ReadAllBytes($Out)
if ($ib.Length -lt 6 -or $ib[0] -ne 0 -or $ib[1] -ne 0 -or $ib[2] -ne 1 -or $ib[3] -ne 0) {
    throw "自检失败：写出的不是合法 ICO 文件（$Out）"
}
$cnt = [BitConverter]::ToUInt16($ib, 4)
if ($cnt -ne $frames.Count) { throw "自检失败：期望 $($frames.Count) 帧，实际 $cnt 帧" }

Write-Host ("图标已生成：{0}  ({1:N0} 字节，{2} 档尺寸)" -f $Out, $ib.Length, $cnt)
for ($k = 0; $k -lt $cnt; $k++) {
    $o = 6 + $k * 16
    $w = $ib[$o]; if ($w -eq 0) { $w = 256 }
    $len = [BitConverter]::ToUInt32($ib, $o + 8)
    $off = [BitConverter]::ToUInt32($ib, $o + 12)
    $fmt = $(if ($ib[$off] -eq 0x89 -and $ib[$off + 1] -eq 0x50) { 'PNG' } else { 'BMP/DIB' })
    Write-Host ("   {0,3}x{0,-3}  {1,6:N0} 字节  {2}" -f $w, $len, $fmt)
}
Write-Host '现在重新运行 build-exe.ps1，新图标会被自动嵌入 ModSync.exe。'
