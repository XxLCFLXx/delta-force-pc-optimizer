<#
.SYNOPSIS
    安全与后台体检 —— 只读检查，不修改任何东西。

.DESCRIPTION
    检查项：
        1. Windows Defender 是否被关闭 / 被第三方杀软顶替
        2. 自启动项（Run / RunOnce），并检查目标文件是否还存在
        3. 计划任务：伪装成系统更新、指向可疑目录或裸文件名的
        4. 服务：ImagePath 位于 ProgramData / Users\Public / AppData / Temp / Downloads 的
        5. 进程：随机名（纯小写 6-10 位）+ 可疑路径
        6. 已知的"共享算力/带宽赚钱"类软件残留

    结果同时输出到控制台和 logs\audit_*.log。

    这是只读脚本：不会删除、不会修改任何东西。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\03_security-audit.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限才能看清全部进程与服务，正在请求提权（点「是」）...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('audit_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

$findings = 0
function L($m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Flag($m) {
    $script:findings++
    Add-Content -Path $log -Value ('[!] ' + $m) -Encoding UTF8
    Write-Host ('[!] ' + $m) -ForegroundColor Red
}

$suspiciousPath = 'ProgramData|Users\\Public|\\AppData\\|\\Temp\\|\\Downloads\\'
$shareKeywords = 'honeygain|suanleme|算了么|slmv|oc-supervisord|onething|网心云|wxedge|xmrig|phoenixminer|lolminer|nicehash'

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host '  Security Audit  |  Delta Force PC Optimizer' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan
L ('日志: ' + $log)
L ''

# ---------------------------------------------------------- 1. Defender
L '########## 1. Windows Defender ##########'
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp) {
    foreach ($k in @('AntivirusEnabled','RealTimeProtectionEnabled','BehaviorMonitorEnabled','IsTamperProtected','AntivirusSignatureVersion','AntivirusSignatureLastUpdated')) {
        L ('  {0,-32} = {1}' -f $k, $mp.$k)
    }
    if (-not $mp.AntivirusEnabled) { Flag 'Windows Defender 的杀毒功能处于关闭状态' }
    if (-not $mp.RealTimeProtectionEnabled) { Flag '实时保护关闭 —— 机器处于无防护状态' }
} else {
    Flag 'Get-MpComputerStatus 不可用：Defender 可能被禁用或被第三方杀软接管'
}

$wdKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
$wd = Get-ItemProperty $wdKey -ErrorAction SilentlyContinue
foreach ($n in @('DisableAntiSpyware','DisableAntiVirus')) {
    if ($wd -and $wd.PSObject.Properties.Name -contains $n) { Flag ("注册表被写入 $n = " + $wd.$n + "（常见于杀软杀手/木马）") }
}
$wdSvc = Get-Service WinDefend -ErrorAction SilentlyContinue
L ('  WinDefend 服务: ' + $wdSvc.Status + ' / ' + $wdSvc.StartType)
if ($wdSvc -and $wdSvc.Status -ne 'Running') { Flag 'WinDefend 服务未运行' }

L '  --- 已注册的杀毒软件 ---'
$av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
if ($av) { $av | ForEach-Object { L ('    {0}  state=0x{1:X}' -f $_.displayName, $_.productState) } }
else { L '    无法查询' }

# ---------------------------------------------------------- 2. Startup
L ''
L '########## 2. 自启动项 ##########'
$runKeys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $runKeys) {
    if (-not (Test-Path $k)) { continue }
    $props = (Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties
    foreach ($pr in $props) {
        if ($pr.Name -like 'PS*') { continue }
        $val = [string]$pr.Value
        $exe = ($val -replace '^"', '') -split '"' | Select-Object -First 1
        $exists = $false
        if ($exe -and (Test-Path $exe)) { $exists = $true }
        $tag = ''
        if (-not $exists) { $tag = '  [目标不存在]' }
        elseif ($val -match $suspiciousPath) { $tag = '  [可疑路径]' }
        if ($tag -eq '') {
            L ('  [{0}] {1} = {2}' -f (Split-Path $k -Leaf), $pr.Name, $val)
        } else {
            Flag ('自启动 {0} = {1}{2}' -f $pr.Name, $val, $tag)
        }
    }
}

# ---------------------------------------------------------- 3. Tasks
L ''
L '########## 3. 计划任务（非 Microsoft 路径）##########'
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' }
$taskCount = 0
foreach ($t in $tasks) {
    $taskCount++
    foreach ($a in $t.Actions) {
        $ex = [string]$a.Execute
        if (-not $ex) { continue }
        $reasons = @()
        if ($ex -match $suspiciousPath) { $reasons += '可疑路径' }
        if ($ex -notmatch '\\' -and $ex -match '\.exe') { $reasons += '裸文件名(无完整路径)' }
        if ($ex -match '\\' -and -not (Test-Path $ex)) { $reasons += '目标不存在' }
        if ($ex -match 'Program Files \(x86\)\\[A-Za-z0-9]{5,6}\\') { $reasons += '随机名目录' }
        if ($reasons.Count -gt 0) {
            Flag ('计划任务 {0}{1}  ->  {2} {3}  [{4}]' -f $t.TaskPath, $t.TaskName, $ex, $a.Arguments, ($reasons -join ', '))
        }
    }
}
L ('  已检查 {0} 个非 Microsoft 任务' -f $taskCount)

# ---------------------------------------------------------- 4. Services
L ''
L '########## 4. 服务（可疑路径）##########'
$svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match $suspiciousPath }
if ($svcs) {
    foreach ($s in $svcs) { Flag ('服务 {0}  [{1}]  ->  {2}' -f $s.Name, $s.StartMode, $s.PathName) }
} else {
    L '  未发现路径可疑的服务'
}

# ---------------------------------------------------------- 5. Processes
L ''
L '########## 5. 进程（随机名 + 可疑路径）##########'
$procs = Get-Process -ErrorAction SilentlyContinue
$hit = 0
foreach ($p in $procs) {
    $path = ''
    try { $path = [string]$p.Path } catch { $path = '' }
    $randName = ($p.Name -match '^[a-z]{6,10}$')
    $susPath = ($path -match $suspiciousPath) -or ($path -match 'Program Files \(x86\)\\[A-Za-z0-9]{5,6}\\')
    if ($randName -and ($susPath -or -not $path)) {
        $hit++
        Flag ('进程 {0}  PID={1}  内存={2:N0}MB  路径={3}' -f $p.Name, $p.Id, ($p.WS / 1MB), $path)
    }
}
if ($hit -eq 0) { L '  未发现随机名可疑进程' }

L '  --- CPU 占用最高的 10 个进程 ---'
(Get-Counter '\Process(*)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples |
    Where-Object { $_.InstanceName -notin @('_total', 'idle') -and $_.CookedValue -gt 1 } |
    Sort-Object CookedValue -Descending | Select-Object -First 10 |
    ForEach-Object { L ('    {0,7:N1} %   {1}' -f $_.CookedValue, $_.InstanceName) }

# ---------------------------------------------------------- 6. Sharing software
L ''
L '########## 6. 共享算力 / 带宽类软件 ##########'
$shareHit = 0
Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { ($_.Name + $_.DisplayName + $_.PathName) -match $shareKeywords } | ForEach-Object {
    $shareHit++
    Flag ('共享类服务 {0}  [{1}]  ->  {2}' -f $_.Name, $_.StartMode, $_.PathName)
}
foreach ($p in $procs) {
    if (($p.Name + [string]$p.Path) -match $shareKeywords) {
        $shareHit++
        Flag ('共享类进程 {0}  PID={1}' -f $p.Name, $p.Id)
    }
}
if ($shareHit -eq 0) { L '  未发现已知的共享算力/带宽软件' }
L '  提示：这类软件会持续占用 CPU/GPU/硬盘/上行带宽，打游戏前务必退出。'

# ---------------------------------------------------------- Summary
L ''
L '########## 结论 ##########'
$cpu = (Get-Counter '\Processor Information(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
$mem = (Get-Counter '\Memory\Available MBytes' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
$commit = (Get-Counter '\Memory\Committed Bytes' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
L ('  系统 CPU 占用 : {0:N1} %' -f $cpu)
L ('  可用内存      : {0:N0} MB' -f $mem)
L ('  提交内存      : {0:N1} GB' -f ($commit / 1GB))
L ('  C 盘剩余      : {0:N1} GB' -f ((Get-PSDrive C).Free / 1GB))
L ''
if ($findings -eq 0) {
    Write-Host '  未发现明显风险项。' -ForegroundColor Green
} else {
    Write-Host ('  共发现 {0} 个需要人工确认的项，见上方 [红线]。' -f $findings) -ForegroundColor Red
    Write-Host '  建议：把本日志交给 AI，让它按「先备份、再隔离」的原则生成处置脚本。' -ForegroundColor Yellow
}
if ($cpu -gt 30) { Write-Host ('  空载/当前 CPU {0:N0}% 偏高 —— 后台可能有东西在偷跑。' -f $cpu) -ForegroundColor Yellow }
if ($mem -lt 800) { Write-Host ('  可用内存仅 {0:N0}MB —— 内存紧张，可能在翻页。' -f $mem) -ForegroundColor Yellow }

Write-Host ''
L '完成'
Write-Host ('日志: ' + $log) -ForegroundColor DarkGray
Write-Host ''
Read-Host '按回车退出'
