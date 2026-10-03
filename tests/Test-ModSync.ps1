<#
================================================================================
 Test-ModSync.ps1  --  ModSync 纯逻辑单元测试（零依赖）
--------------------------------------------------------------------------------
 用法（在项目目录下）：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ModSync.ps1

 为什么不用 Pester：本项目的硬约束是"零第三方依赖、不加联网依赖"，
   装 Pester 就破例了。这里用最朴素的断言 + 退出码，够用且随时能跑。

 怎么测的：ModSync.ps1 是"一个文件既是库又是界面"，直接跑会弹窗。
   所以这里用 PowerShell 的 AST 解析器把需要的纯函数抽出来单独定义，
   不执行脚本主体、不创建任何窗口。

 覆盖范围（都是判定/改名这类"错了会动用户文件"的逻辑）：
   · Get-ModIdentity          —— mod 身份归组，四级判定的地基
   · Test-CanDeleteOldVersion —— "复制失败就绝不删旧版本"这条安全约束
   · Build-RenamePlan         —— 改名计划（纯函数）
   · Invoke-RenamePlan        —— 改名执行（在临时目录里真改文件）
   · Test-NameMatch / Get-NormName —— 在线页面命中校验，防"送到错误的 mod 页"
   · Get-BytesText / Resolve-InputPath / Get-DisplayPath —— 显示与路径归一化

 不覆盖：Invoke-Scan / Invoke-Sync 的界面流程（依赖 WinForms 控件），
   那部分靠"运行源码做一次真实比对与同步"验收，见 README「三、判定依据」。
================================================================================
#>

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$srcPath = Join-Path (Split-Path -Parent $root) 'ModSync.ps1'
if (-not (Test-Path -LiteralPath $srcPath)) { throw "找不到被测源码：$srcPath" }

# ------------------------------------------------------------------ 断言框架
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList

function Assert-Eq($expected, $actual, $what) {
    if ("$expected" -ne "$actual") {
        throw ("{0}：期望 [{1}]，实际 [{2}]" -f $what, $expected, $actual)
    }
}
function Assert-True($cond, $what) { if (-not $cond) { throw ("{0}：期望为真，实际为假" -f $what) } }
function Assert-False($cond, $what) { if ($cond) { throw ("{0}：期望为假，实际为真" -f $what) } }

function Test-Case([string]$name, [scriptblock]$body) {
    try {
        & $body
        $script:Pass++
        Write-Host ("  [OK]   " + $name) -ForegroundColor Green
    } catch {
        $script:Fail++
        [void]$script:Failures.Add(("{0} —— {1}" -f $name, $_.Exception.Message))
        Write-Host ("  [FAIL] " + $name) -ForegroundColor Red
        Write-Host ("         " + $_.Exception.Message) -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------------ 抽取纯函数
Write-Host ''
Write-Host "被测源码：$srcPath"

# 先查编码再解析：Windows PowerShell 5.1 会把"无 BOM 的 UTF-8"按系统 ANSI（中文系统 GBK）
# 解码，结果不是报错，而是中文全变乱码、字符串引号错位——报出来一堆莫名其妙的语法错误。
# 这里提前把真正的原因点破，省得下次有人对着乱码排查半天。
$srcBytes = [System.IO.File]::ReadAllBytes($srcPath)
if (-not ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)) {
    throw "ModSync.ps1 缺少 UTF-8 BOM。Windows PowerShell 5.1 会按 GBK 解码，中文界面文案与中文路径全乱码。`n" +
          "修法：`$t = [IO.File]::ReadAllText(`$p, (New-Object Text.UTF8Encoding(`$false))); [IO.File]::WriteAllText(`$p, `$t, (New-Object Text.UTF8Encoding(`$true)))"
}

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw ("ModSync.ps1 存在语法错误（{0} 处），先修好再测：行 {1} {2}" -f `
        $parseErrors.Count, $parseErrors[0].Extent.StartLineNumber, $parseErrors[0].Message)
}

# 需要被抽出来单独定义（执行）的函数名
$wanted = @(
    'Get-ModIdentity', 'Get-BytesText', 'Resolve-InputPath', 'Get-DisplayPath',
    'Get-NormName', 'Test-NameMatch',
    'Build-RenamePlan', 'Invoke-RenamePlan', 'Test-CanDeleteOldVersion',
    'Get-ServerCounterpartForRecord'
)
$found = @{}
$allFuncs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($fd in $allFuncs) {
    if ($wanted -notcontains $fd.Name) { continue }
    . ([scriptblock]::Create($fd.Extent.Text))
    $found[$fd.Name] = $true
}
foreach ($w in $wanted) {
    if (-not $found[$w]) { throw "在 ModSync.ps1 里找不到函数 $w（是不是被改名/删掉了？）" }
}
Write-Host ("已抽取 {0} 个纯函数（不执行脚本主体、不创建窗口）" -f $found.Count)

# 依赖替身：这些函数会碰配置文件/磁盘哈希，测试里用不着真货
$script:IgnoredMoves = New-Object System.Collections.ArrayList
function Move-IgnoredIdentity([string]$oldKey, [string]$oldName, [string]$newKey, [string]$newName) {
    [void]$script:IgnoredMoves.Add("$oldKey -> $newKey")
}
function Get-FileHashMd5([string]$path) { return $null }

# ------------------------------------------------------------------ 临时目录
$tmpRoot = 'D:\cache\ModSync'
if (-not (Test-Path -LiteralPath 'D:\cache')) { $tmpRoot = Join-Path $env:TEMP 'ModSync' }
$work = Join-Path $tmpRoot ('test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cliDir = Join-Path $work 'client'
$srvDir = Join-Path $work 'server'
[void](New-Item -ItemType Directory -Path $cliDir -Force)
[void](New-Item -ItemType Directory -Path $srvDir -Force)
Write-Host "临时工作目录：$work"

try {
    # ============================================================== Get-ModIdentity
    Write-Host ''
    Write-Host 'Get-ModIdentity —— mod 身份归组（四级判定的地基）' -ForegroundColor Cyan

    Test-Case '标准命名：剥掉加载器/MC版本/mod版本' {
        $id = Get-ModIdentity 'journeymap-forge-1.20.1-5.9.18.jar'
        Assert-Eq 'journeymap-forge-1.20.1-5.9.18' $id.Base 'Base'
        Assert-Eq 'journeymap' $id.Key 'Key'
    }

    Test-Case '同一 mod 的两个版本 → Key 相同（这是"删旧版本"能成立的前提）' {
        $a = Get-ModIdentity 'journeymap-forge-1.20.1-5.9.18.jar'
        $b = Get-ModIdentity 'journeymap-forge-1.20.1-5.9.20.jar'
        Assert-Eq $a.Key $b.Key '两个版本的 Key'
        Assert-True ($a.Base -ne $b.Base) 'Base 应当不同'
    }

    Test-Case 'MC版本放最后（AE2 风格）也能剥干净' {
        Assert-Eq 'ae2' (Get-ModIdentity 'AE2-15.2.1-forge-1.20.1.jar').Key 'Key'
    }

    Test-Case '带 +mc1.20.1 后缀（Fabric 风格）也能剥干净' {
        Assert-Eq 'sodium' (Get-ModIdentity 'sodium-fabric-0.5.3+mc1.20.1.jar').Key 'Key'
    }

    Test-Case '普通名字：mymod-1.0 / mymod-2.0 归为同一个 mod' {
        Assert-Eq 'mymod' (Get-ModIdentity 'mymod-1.0.jar').Key 'Key(1.0)'
        Assert-Eq 'mymod' (Get-ModIdentity 'mymod-2.0.jar').Key 'Key(2.0)'
    }

    Test-Case '解析不出东西时退化为文件名本身（保守兜底，不误判）' {
        Assert-Eq 'no_version_here' (Get-ModIdentity 'no_version_here.jar').Key 'Key'
    }

    Test-Case '名字太短时不敢剥（防止把 A-1.0 剥成空）' {
        Assert-Eq 'a-1.0' (Get-ModIdentity 'A-1.0.jar').Key 'Key'
    }

    Test-Case '带 [ ] 的中文文件名不会崩，且 Key 非空' {
        $id = Get-ModIdentity '[客户端]A.jar'
        Assert-Eq '[客户端]a' $id.Key 'Key'
    }

    # ============================================================== 删除安全约束
    Write-Host ''
    Write-Host 'Test-CanDeleteOldVersion —— 复制失败就绝不删旧版本' -ForegroundColor Cyan

    Test-Case '新版本复制成功 → 允许删旧版本' {
        $rec = [pscustomobject]@{ SrcPath = 'C:\x\a.jar' }
        Assert-True (Test-CanDeleteOldVersion @{ 'C:\x\a.jar' = $true } $rec) '应允许删除'
    }

    Test-Case '新版本没复制成功 → 拒绝删旧版本（否则这个 mod 会在服务端消失）' {
        $rec = [pscustomobject]@{ SrcPath = 'C:\x\b.jar' }
        Assert-False (Test-CanDeleteOldVersion @{ 'C:\x\a.jar' = $true } $rec) '应拒绝删除'
    }

    Test-Case '空的成功集合 / 空记录 → 一律拒绝' {
        Assert-False (Test-CanDeleteOldVersion @{} ([pscustomobject]@{ SrcPath = 'C:\x\a.jar' })) '空集合'
        Assert-False (Test-CanDeleteOldVersion @{ 'C:\x\a.jar' = $true } $null) '空记录'
        Assert-False (Test-CanDeleteOldVersion $null ([pscustomobject]@{ SrcPath = 'C:\x\a.jar' })) '空哈希表'
    }

    # ============================================================== Build-RenamePlan
    Write-Host ''
    Write-Host 'Build-RenamePlan —— 批量加前缀的改名计划（纯函数）' -ForegroundColor Cyan

    Test-Case '正常：新文件名 = 前缀 + 原名' {
        $f = Join-Path $cliDir 'modA-1.0.jar'
        [System.IO.File]::WriteAllText($f, 'x')
        $rec = [pscustomobject]@{ SrcPath = $f; FileName = 'modA-1.0.jar'; Key = 'moda' }
        $r = Build-RenamePlan @($rec) '[客户端]' $cliDir $srvDir $false
        Assert-Eq 1 @($r.Plan).Count '计划条数'
        Assert-Eq '[客户端]modA-1.0.jar' $r.Plan[0].NewName '新文件名'
        Assert-Eq 0 @($r.Skipped).Count '跳过条数'
    }

    Test-Case '客户端已有同名文件 → 跳过并写明原因' {
        $f = Join-Path $cliDir 'modA-1.0.jar'
        [System.IO.File]::WriteAllText((Join-Path $cliDir '[客户端]modA-1.0.jar'), 'x')
        $rec = [pscustomobject]@{ SrcPath = $f; FileName = 'modA-1.0.jar'; Key = 'moda' }
        $r = Build-RenamePlan @($rec) '[客户端]' $cliDir $srvDir $false
        Assert-Eq 0 @($r.Plan).Count '计划条数'
        Assert-Eq 1 @($r.Skipped).Count '跳过条数'
        Assert-True ($r.Skipped[0].Why.Contains('已存在同名文件')) '跳过原因'
        Remove-Item -LiteralPath (Join-Path $cliDir '[客户端]modA-1.0.jar') -Force
    }

    Test-Case '前缀为空（新名 = 原名）→ 跳过，不做无意义的改名' {
        $f = Join-Path $cliDir 'modA-1.0.jar'
        $rec = [pscustomobject]@{ SrcPath = $f; FileName = 'modA-1.0.jar'; Key = 'moda' }
        $r = Build-RenamePlan @($rec) '' $cliDir $srvDir $false
        Assert-Eq 0 @($r.Plan).Count '计划条数'
        Assert-True ($r.Skipped[0].Why.Contains('相同')) '跳过原因'
    }

    Test-Case '源文件已不存在 → 跳过（不产生会失败的改名动作）' {
        $rec = [pscustomobject]@{ SrcPath = (Join-Path $cliDir 'ghost.jar'); FileName = 'ghost.jar'; Key = 'ghost' }
        $r = Build-RenamePlan @($rec) '[X]' $cliDir $srvDir $false
        Assert-Eq 0 @($r.Plan).Count '计划条数'
        Assert-True ($r.Skipped[0].Why.Contains('不存在')) '跳过原因'
    }

    Test-Case '勾了"服务端一起改"：服务端同名文件被纳入计划' {
        $f = Join-Path $cliDir 'modD-1.0.jar'
        [System.IO.File]::WriteAllText($f, 'x')
        [System.IO.File]::WriteAllText((Join-Path $srvDir 'modD-1.0.jar'), 'x')
        $rec = [pscustomobject]@{ SrcPath = $f; FileName = 'modD-1.0.jar'; Key = 'modd' }
        $r = Build-RenamePlan @($rec) '[S]' $cliDir $srvDir $true
        Assert-Eq 1 @($r.Plan).Count '计划条数'
        Assert-Eq 'modD-1.0.jar' $r.Plan[0].ServerOld.Name '服务端原文件'
        Assert-Eq (Join-Path $srvDir '[S]modD-1.0.jar') $r.Plan[0].ServerNew '服务端新路径'
    }

    Test-Case '不勾"服务端一起改"：只动客户端' {
        $f = Join-Path $cliDir 'modD-1.0.jar'
        $rec = [pscustomobject]@{ SrcPath = $f; FileName = 'modD-1.0.jar'; Key = 'modd' }
        $r = Build-RenamePlan @($rec) '[C]' $cliDir $srvDir $false
        Assert-Eq 1 @($r.Plan).Count '计划条数'
        Assert-Eq $null $r.Plan[0].ServerOld '服务端原文件应为空'
    }

    # ============================================================== Invoke-RenamePlan
    Write-Host ''
    Write-Host 'Invoke-RenamePlan —— 真正动文件的改名执行' -ForegroundColor Cyan

    Test-Case '客户端改名：文件真的被改了名，内容不动' {
        $a = Join-Path $cliDir 'modE-1.0.jar'
        [System.IO.File]::WriteAllText($a, 'CONTENT-E')
        $rec = [pscustomobject]@{ SrcPath = $a; FileName = 'modE-1.0.jar'; Key = 'mode' }
        $plan = @([pscustomobject]@{
            Rec = $rec; NewName = '[客户端]modE-1.0.jar'
            ClientNew = (Join-Path $cliDir '[客户端]modE-1.0.jar')
            ServerOld = $null; ServerNew = $null
        })
        $res = Invoke-RenamePlan $plan
        Assert-Eq 1 $res.ClientOk '客户端成功数'
        Assert-Eq 0 $res.Fail '失败数'
        Assert-False (Test-Path -LiteralPath $a) '旧名字应该不存在了'
        $new = Join-Path $cliDir '[客户端]modE-1.0.jar'
        Assert-True (Test-Path -LiteralPath $new) '新名字应该存在'
        Assert-Eq 'CONTENT-E' ([System.IO.File]::ReadAllText($new)) '内容必须原样'
    }

    Test-Case '服务端改名：两端同时改名' {
        $c = Join-Path $cliDir 'modF-1.0.jar'
        $s = Join-Path $srvDir 'modF-1.0.jar'
        [System.IO.File]::WriteAllText($c, 'CONTENT-F')
        [System.IO.File]::WriteAllText($s, 'CONTENT-F')
        $rec = [pscustomobject]@{ SrcPath = $c; FileName = 'modF-1.0.jar'; Key = 'modf' }
        $plan = @([pscustomobject]@{
            Rec = $rec; NewName = '[X]modF-1.0.jar'
            ClientNew = (Join-Path $cliDir '[X]modF-1.0.jar')
            ServerOld = (Get-Item -LiteralPath $s); ServerNew = (Join-Path $srvDir '[X]modF-1.0.jar')
        })
        $res = Invoke-RenamePlan $plan
        Assert-Eq 1 $res.ClientOk '客户端成功数'
        Assert-Eq 1 $res.ServerOk '服务端成功数'
        Assert-Eq 0 $res.Fail '失败数'
        Assert-True (Test-Path -LiteralPath (Join-Path $srvDir '[X]modF-1.0.jar')) '服务端新名字应该存在'
    }

    Test-Case '源文件不存在 → 记为失败，且不中断其它项' {
        $g = Join-Path $cliDir 'modG-1.0.jar'
        [System.IO.File]::WriteAllText($g, 'CONTENT-G')
        $okRec  = [pscustomobject]@{ SrcPath = $g; FileName = 'modG-1.0.jar'; Key = 'modg' }
        $badRec = [pscustomobject]@{ SrcPath = (Join-Path $cliDir 'ghost.jar'); FileName = 'ghost.jar'; Key = 'ghost' }
        $plan = @(
            [pscustomobject]@{ Rec = $badRec; NewName = '[X]ghost.jar'; ClientNew = (Join-Path $cliDir '[X]ghost.jar'); ServerOld = $null; ServerNew = $null },
            [pscustomobject]@{ Rec = $okRec;  NewName = '[X]modG-1.0.jar'; ClientNew = (Join-Path $cliDir '[X]modG-1.0.jar'); ServerOld = $null; ServerNew = $null }
        )
        $res = Invoke-RenamePlan $plan
        Assert-Eq 1 $res.ClientOk '成功数'
        Assert-Eq 1 $res.Fail '失败数'
        Assert-True (Test-Path -LiteralPath (Join-Path $cliDir '[X]modG-1.0.jar')) '失败项不应影响后续项'
    }

    # ============================================================== 名字匹配
    Write-Host ''
    Write-Host 'Test-NameMatch / Get-NormName —— 防"把用户送到错误的 mod 页"' -ForegroundColor Cyan

    Test-Case '归一化：大小写、空格、下划线、连字符一律抹平' {
        Assert-Eq 'advancedae' (Get-NormName 'Advanced AE') 'Advanced AE'
        Assert-Eq 'advancedae' (Get-NormName 'advanced_ae') 'advanced_ae'
        Assert-Eq 'advancedae' (Get-NormName 'AdvancedAE') 'AdvancedAE'
        Assert-Eq '' (Get-NormName '') '空串'
    }

    Test-Case 'modId 与显示名任一命中即算匹配' {
        Assert-True (Test-NameMatch 'AdvancedAE' 'advanced_ae' '') '按 modId 命中'
        Assert-True (Test-NameMatch 'Advanced AE' '' 'advanced-ae') '按显示名命中'
    }

    Test-Case 'MC百科那种带别名的标题也能命中' {
        Assert-True (Test-NameMatch '[AAE] 高级AE (AdvancedAE)' 'advancedae' '') '包含匹配'
    }

    Test-Case '短名字（<5）不允许包含匹配，防止 jei 到处乱命中' {
        Assert-True  (Test-NameMatch 'JEI' 'jei' '') '完全相等仍然命中'
        Assert-False (Test-NameMatch 'SomeOtherMod' 'jei' '') '不该包含命中'
        Assert-False (Test-NameMatch '' 'jei' '') '空候选一律不命中'
    }

    # ============================================================== 小工具
    Write-Host ''
    Write-Host '显示与路径归一化' -ForegroundColor Cyan

    Test-Case 'Get-BytesText 各量级' {
        Assert-Eq '0 B'     (Get-BytesText 0) '0'
        Assert-Eq '512 B'   (Get-BytesText 512) '512'
        Assert-Eq '1.0 KB'  (Get-BytesText 1024) '1KB'
        Assert-Eq '1.00 MB' (Get-BytesText 1048576) '1MB'
        Assert-Eq '1.00 GB' (Get-BytesText 1073741824) '1GB'
    }

    Test-Case 'Resolve-InputPath：去空白、去引号、展开环境变量' {
        Assert-Eq 'C:\a b' (Resolve-InputPath '  "C:\a b"  ') '去引号与空白'
        Assert-Eq '' (Resolve-InputPath '   ') '纯空白 → 空串'
        $t = Resolve-InputPath '%TEMP%\x'
        Assert-False ($t.Contains('%')) '环境变量应被展开'
    }

    Test-Case 'Get-DisplayPath：用户目录缩写成 %USERPROFILE%' {
        $p = Join-Path $env:USERPROFILE 'mods'
        Assert-Eq ('%USERPROFILE%' + $p.Substring($env:USERPROFILE.Length)) (Get-DisplayPath $p) '缩写'
        Assert-Eq '' (Get-DisplayPath '') '空串'
    }
}
finally {
    # 收尾：临时文件一律不留（本机约定：临时区就是 D:\cache\ModSync 或系统 TEMP）
    try { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } } catch { }
}

# ------------------------------------------------------------------ 汇总
Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host ("全部通过：{0} / {0}" -f $script:Pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 {0} 项，通过 {1} 项：" -f $script:Fail, $script:Pass) -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("  · " + $f) -ForegroundColor Red }
    exit 1
}
