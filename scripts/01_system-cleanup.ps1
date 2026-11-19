<#
.SYNOPSIS
    系统垃圾清理 —— 默认只预览，加 -Apply 才真正删除。

.DESCRIPTION
    清理内容：
        %TEMP%                          用户临时文件
        C:\Windows\Temp                 系统临时文件（需管理员）
        SoftwareDistribution\Download   Windows 更新缓存（需管理员）
        回收站

    另外会报告：C 盘剩余空间、页面文件配置、是否建议调整。

.PARAMETER Apply
    真正执行清理。不加此参数时只统计大小，不做任何改动。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\01_system-cleanup.ps1
    powershell -ExecutionPolicy Bypass -File .\scripts\01_system-cleanup.ps1 -Apply
#>
param([switch]$Apply)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 真正清理时才需要管理员
if ($Apply -and -not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权（请在弹窗点「是」）...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply"
    exit
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('cleanup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

function L($m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Get-FolderSize($path) {
    if (-not (Test-Path $path)) { return 0 }
    $m = Get-ChildItem $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    return [double]$m.Sum
}

Write-Host ''
Write-Host '========== System Cleanup ==========' -ForegroundColor Cyan
L ('模式: ' + $(if ($Apply) { '执行清理' } else { '仅预览（加 -Apply 才会删除）' }))
L ('日志: ' + $log)

$freeBefore = (Get-PSDrive C).Free / 1GB
L ('C盘剩余: {0:N2} GB' -f $freeBefore)

$targets = @(
    @{ Name = '用户临时文件'; Path = $env:TEMP },
    @{ Name = '系统临时文件'; Path = "$env:SystemRoot\Temp" },
    @{ Name = 'Windows 更新缓存'; Path = "$env:SystemRoot\SoftwareDistribution\Download" }
)

$totalBytes = 0
foreach ($t in $targets) {
    $size = Get-FolderSize $t.Path
    $totalBytes += $size
    L ('  {0,-16} {1,8:N2} GB' -f $t.Name, ($size / 1GB))
    if ($Apply -and (Test-Path $t.Path)) {
        Get-ChildItem $t.Path -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'dsh-*' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        L ('      已清理: ' + $t.Path)
    }
}
L ('  可清理合计       {0,8:N2} GB' -f ($totalBytes / 1GB))

if ($Apply) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    L '  已清空回收站'
    $freeAfter = (Get-PSDrive C).Free / 1GB
    L ('C盘剩余: {0:N2} GB  ->  {1:N2} GB   (释放 {2:N2} GB)' -f $freeBefore, $freeAfter, ($freeAfter - $freeBefore))
}

# 页面文件体检
Write-Host ''
L '--- 页面文件 ---'
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
if ($cs) {
    L ('  系统托管: ' + $cs.AutomaticManagedPagefile)
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    if ($pf) {
        foreach ($p in $pf) { L ('  {0}  初始 {1} MB / 最大 {2} MB' -f $p.Name, $p.InitialSize, $p.MaximumSize) }
    } else {
        L '  未检测到固定大小的页面文件（可能为系统托管）'
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        L ('  物理内存: {0:N1} GB' -f ($os.TotalVisibleMemorySize / 1MB))
        L ('  可用内存: {0:N1} GB' -f ($os.FreePhysicalMemory / 1MB))
    }
} else {
    L '  无法读取（需要管理员权限）'
}

Write-Host ''
L '完成'
if (-not $Apply) { Write-Host '这只是预览。确认无误后加 -Apply 真正清理。' -ForegroundColor Yellow }
Write-Host ('日志: ' + $log) -ForegroundColor DarkGray
Write-Host ''
Read-Host '按回车退出'
