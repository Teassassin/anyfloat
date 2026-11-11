# AnyFloat 安装脚本
#
# 把程序复制到 %LOCALAPPDATA%\AnyFloat，可选加入开机自启（当前用户 Run 键），
# 然后立刻启动。不需要管理员权限，不写系统目录。
#
# 用法（右键 → 使用 PowerShell 运行，或在 PowerShell 里执行）：
#   powershell -ExecutionPolicy Bypass -File .\Install-AnyFloat.ps1
#   powershell -ExecutionPolicy Bypass -File .\Install-AnyFloat.ps1 -NoAutoStart
#   powershell -ExecutionPolicy Bypass -File .\Install-AnyFloat.ps1 -AutoStart -Quiet
#
# 参数：
#   -InstallDir <路径>  安装目录（默认 %LOCALAPPDATA%\AnyFloat）
#   -AutoStart          加入开机自启，不询问
#   -NoAutoStart        不加入开机自启，不询问
#   -NoStart            装完不立即启动
#   -Quiet              不打印交互提示

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'AnyFloat'),
    [switch]$AutoStart,
    [switch]$NoAutoStart,
    [switch]$NoStart,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'AnyFloat'

function Say([string]$msg, [string]$color = 'Gray') {
    if (-not $Quiet -or $color -eq 'Red') { Write-Host $msg -ForegroundColor $color }
}
function Fail([string]$msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    exit 1
}

Say ""
Say "AnyFloat 安装" Cyan
Say "  来源: $src"
Say "  目标: $InstallDir"
Say ""

# ---------- 1. 检查来源 ----------
$payload = @(
    'AnyFloat.ps1',
    'Start-AnyFloat.vbs',
    'Uninstall-AnyFloat.ps1',
    'README.md',
    'README.zh-CN.md',
    'CHANGELOG.md',
    'LICENSE',
    'assets\anyfloat.ico'
)
foreach ($rel in $payload) {
    if (-not (Test-Path (Join-Path $src $rel))) { Fail "来源目录缺少 $rel（请在解压后的完整目录里运行本脚本）" }
}
Say "1. 来源检查通过" Green

# ---------- 2. 停掉正在运行的实例 ----------
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '[\\/]AnyFloat\.ps1' })
if ($running.Count -gt 0) {
    Say "2. 停止正在运行的实例（$($running.Count) 个）" Green
    foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}
else { Say "2. 没有正在运行的实例" Green }

# ---------- 3. 复制文件 ----------
$sameDir = ($src.TrimEnd('\') -ieq $InstallDir.TrimEnd('\'))
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$copied = 0
foreach ($rel in $payload) {
    $from = Join-Path $src $rel
    $to = Join-Path $InstallDir $rel
    $toDir = Split-Path $to -Parent
    if (-not (Test-Path $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
    if (-not $sameDir) { Copy-Item $from $to -Force }
    # 从网上下载的 zip 解出来的文件带"来自其他计算机"标记，
    # 不解除的话 -ExecutionPolicy Bypass 之外的各种调用会报"未数字签名"
    try { Unblock-File -Path $to -ErrorAction SilentlyContinue } catch { }
    $copied++
}
Say "3. 已复制 $copied 个文件" Green

# ---------- 4. 开机自启 ----------
$vbs = Join-Path $InstallDir 'Start-AnyFloat.vbs'
if (-not $AutoStart -and -not $NoAutoStart) {
    if ($Quiet) { $AutoStart = $true }
    else {
        $ans = Read-Host "4. 是否开机自动启动（当前用户启动项，随时可用卸载脚本移除）？[Y/n]"
        $AutoStart = -not ($ans -match '^\s*(n|no|否)\s*$')
    }
}
if ($AutoStart) {
    if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    $cmd = 'wscript.exe "' + $vbs + '"'
    New-ItemProperty -Path $runKey -Name $runName -Value $cmd -PropertyType String -Force | Out-Null
    Say "4. 已加入开机自启" Green
}
else {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Say "4. 未加入开机自启" Green
}

# ---------- 5. 启动 ----------
$tool = Join-Path $InstallDir 'AnyFloat.ps1'
if ($NoStart) {
    # 不常驻，但还要跑一次构造流程：上次被强杀的窗口会停在"透明+禁用"状态，靠它自愈
    Say "5. 未启动（-NoStart），仅执行一次崩溃自愈" Green
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest 2>&1 | Out-Null
}
else {
    Start-Process wscript.exe -ArgumentList "`"$vbs`"" -WindowStyle Hidden
    Start-Sleep -Milliseconds 1200
    $ok = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '[\\/]AnyFloat\.ps1' }).Count -gt 0
    if ($ok) { Say "5. 已启动（托盘区有图标）" Green }
    else { Say "5. 启动似乎失败，可直接双击 Start-AnyFloat.vbs 重试" Yellow }
}

Say ""
Say "安装完成" Cyan
Say "  程序目录: $InstallDir"
Say "  开机自启: $(if ($AutoStart) { '已开启' } else { '未开启' })"
Say "  启动方式: 双击 $vbs"
Say "  悬浮窗口: Win+Shift+F（被占用时自动降级为 Ctrl+Alt+F）"
Say "  复原全部: Win+Shift+G"
Say "  卸载    : powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'Uninstall-AnyFloat.ps1')`""
Say ""
