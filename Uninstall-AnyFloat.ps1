# AnyFloat 卸载脚本
#
# 停止程序、移除开机自启、删除安装目录。删除前会先把上次被强杀留下的
# "透明+禁用"窗口救回来（跑一次自愈流程），避免卸载完屏幕上还留着一片空白。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-AnyFloat.ps1
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-AnyFloat.ps1 -Force
#
# 参数：
#   -InstallDir <路径>  安装目录（默认 %LOCALAPPDATA%\AnyFloat）
#   -Force              不询问，直接卸载

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'AnyFloat'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'AnyFloat'

Write-Host ""
Write-Host "AnyFloat 卸载" -ForegroundColor Cyan
Write-Host "  安装目录: $InstallDir"
Write-Host ""

if (-not (Test-Path $InstallDir)) {
    Write-Host "  该目录不存在，可能已经卸载过了。" -ForegroundColor Yellow
    # 仍然清理一下可能残留的启动项
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Write-Host ""
    exit 0
}

if (-not $Force) {
    $ans = Read-Host "确认卸载？[y/N]"
    if ($ans -notmatch '^\s*(y|yes|是)\s*$') {
        Write-Host "已取消。" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
}

# ---------- 1. 停止运行中的实例 ----------
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '[\\/]AnyFloat\.ps1' })
if ($running.Count -gt 0) {
    foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Write-Host "1. 已停止 $($running.Count) 个实例" -ForegroundColor Green
}
else { Write-Host "1. 没有正在运行的实例" -ForegroundColor Green }

# ---------- 2. 移除开机自启 ----------
$had = $null -ne (Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue)
Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
Write-Host ("2. 开机自启已移除" + $(if ($had) { '' } else { '（本来就没开启）' })) -ForegroundColor Green

# ---------- 3. 救回被冻结的窗口 ----------
# 强杀进程后，被悬浮的窗口会停在"透明+禁用"状态。构造流程里的 RecoverOrphans 负责恢复，
# 所以删除前先跑一次 -SelfTest（它只做初始化 + 打印，然后退出）。
$tool = Join-Path $InstallDir 'AnyFloat.ps1'
if (Test-Path $tool) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -SelfTest 2>&1 | Out-Null
        Write-Host "3. 已执行崩溃自愈（恢复可能残留的透明窗口）" -ForegroundColor Green
    }
    catch { Write-Host "3. 自愈流程跳过（$($_.Exception.Message)）" -ForegroundColor Yellow }
}

# ---------- 4. 删除目录 ----------
try {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "4. 已删除 $InstallDir" -ForegroundColor Green
}
catch {
    Write-Host "4. 删除失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   可能还有文件被占用，请稍后重试或手动删除该目录。" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "卸载完成。调试日志（如果开过）位于 $env:TEMP\anyfloat.log，可一并删除。" -ForegroundColor Cyan
Write-Host ""
