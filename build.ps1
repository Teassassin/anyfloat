# AnyFloat 打包脚本
#
# 把发布需要的文件打成一个 zip（不含 AGENTS.md / dev/ / .git），
# 同时校验编码约束（.ps1 必须带 BOM，.vbs 必须无 BOM 且纯 ASCII）——
# 这两条踩过坑，打包前挡掉比发布后发现强。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Version 0.2.0
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Check     # 只校验，不打包

[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutDir = 'dist',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

function Fail([string]$msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:problems++
}

$script:problems = 0

# ---------- 版本号：默认取 CHANGELOG 里最新的 [x.y.z] ----------
if (-not $Version) {
    $cl = Join-Path $root 'CHANGELOG.md'
    if (Test-Path $cl) {
        $m = [regex]::Match((Get-Content $cl -Raw), '##\s*\[(\d+\.\d+\.\d+)\]')
        if ($m.Success) { $Version = $m.Groups[1].Value }
    }
}
if (-not $Version) { $Version = '0.0.0' }

Write-Host ""
Write-Host "AnyFloat build  v$Version" -ForegroundColor Cyan
Write-Host "  源目录: $root"
Write-Host ""

# ---------- 发布清单 ----------
# 刻意不含：AGENTS.md、dev/、.git、build.ps1 —— 这些属于开发仓库
# README.zh-CN.md 是可选的：开发仓库只有一份中文 README.md
$required = @(
    'AnyFloat.ps1',
    'Start-AnyFloat.vbs',
    'Install-AnyFloat.ps1',
    'Uninstall-AnyFloat.ps1',
    'README.md',
    'CHANGELOG.md',
    'LICENSE',
    'assets\anyfloat.ico',
    'assets\anyfloat_logo.svg',
    'assets\anyfloat_banner.png',
    'docs\demo.gif'
)
$optional = @('README.zh-CN.md')

$files = @($required) + @($optional | Where-Object { Test-Path (Join-Path $root $_) })

Write-Host "1. 检查发布清单"
$missing = @()
foreach ($rel in $required) {
    if (-not (Test-Path (Join-Path $root $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Fail "缺少文件: $m" }
}
else { Write-Host "   $($files.Count) 个文件齐全" -ForegroundColor Green }

# ---------- 编码约束 ----------
Write-Host "2. 检查编码约束"
foreach ($rel in ($files | Where-Object { $_ -like '*.ps1' })) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    $b = [System.IO.File]::ReadAllBytes($p)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        Fail "$rel 缺少 UTF-8 BOM（PS 5.1 会按 GBK 解析，中文注释会吃掉引号）"
    }
}
foreach ($rel in ($files | Where-Object { $_ -like '*.vbs' })) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    $b = [System.IO.File]::ReadAllBytes($p)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        Fail "$rel 带了 BOM（wscript 会报 (1,1) 无效字符）"
    }
    if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) {
        Fail "$rel 含非 ASCII 字符（wscript 只认 ASCII）"
    }
}
if ($script:problems -eq 0) { Write-Host "   编码约束全部满足" -ForegroundColor Green }

# ---------- 语法自检 ----------
Write-Host "3. 语法自检"
foreach ($rel in @('AnyFloat.ps1', 'Install-AnyFloat.ps1', 'Uninstall-AnyFloat.ps1')) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) { Fail "$rel 第 $($e.Extent.StartLineNumber) 行: $($e.Message)" }
    }
}
if ($script:problems -eq 0) { Write-Host "   解析通过" -ForegroundColor Green }

if ($script:problems -gt 0) {
    Write-Host ""
    Write-Host "构建失败：$($script:problems) 个问题" -ForegroundColor Red
    exit 1
}
if ($Check) {
    Write-Host ""
    Write-Host "校验通过（-Check 模式，未打包）" -ForegroundColor Green
    exit 0
}

# ---------- 组装 ----------
$outPath = Join-Path $root $OutDir
$stage   = Join-Path $outPath "anyfloat-v$Version"
$zipPath = Join-Path $outPath "anyfloat-v$Version.zip"

Write-Host "4. 组装"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($rel in $files) {
    $dst = Join-Path $stage $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item (Join-Path $root $rel) $dst -Force
}
$total = (Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("   暂存 $($files.Count) 个文件，共 {0:N0} KB" -f ($total / 1KB))

# ---------- 打包 ----------
Write-Host "5. 打包"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
# 手工建条目：CreateFromDirectory 在 .NET Framework 下会把路径写成反斜杠，不符合 zip 规范
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in $files) {
        $entry = $rel -replace '\\', '/'
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, (Join-Path $stage $rel), $entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}
finally { $zip.Dispose() }

$zipSize = (Get-Item $zipPath).Length
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
$hashFile = "$zipPath.sha256"
"$hash  anyfloat-v$Version.zip" | Set-Content $hashFile -Encoding ASCII

Remove-Item $stage -Recurse -Force

# ---------- 校验 zip 内容 ----------
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = $zip.Entries | ForEach-Object { $_.FullName }
} finally { $zip.Dispose() }

Write-Host "6. 校验产物"
$bad = @($names | Where-Object { $_ -match 'AGENTS\.md|(^|/)dev/|\.git|build\.ps1' })
if ($bad.Count -gt 0) { foreach ($b in $bad) { Fail "zip 里混入了不该发布的文件: $b" } }
$miss = @($files | Where-Object { $names -notcontains ($_ -replace '\\', '/') })
if ($miss.Count -gt 0) { foreach ($m in $miss) { Fail "zip 里缺少: $m" } }
if ($script:problems -gt 0) {
    Write-Host ""
    Write-Host "构建失败：$($script:problems) 个问题" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "完成" -ForegroundColor Green
Write-Host ("  {0}  ({1:N0} KB)" -f $zipPath, ($zipSize / 1KB))
Write-Host "  SHA256 $hash"
Write-Host "  $hashFile"
Write-Host ""
Write-Host "  安装：解压后右键 Install-AnyFloat.ps1 → 使用 PowerShell 运行" -ForegroundColor DarkGray
