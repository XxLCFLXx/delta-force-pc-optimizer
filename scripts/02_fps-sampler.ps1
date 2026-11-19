<#
.SYNOPSIS
    打游戏时的性能采样器 —— 用来判断瓶颈在 CPU 还是 GPU。

.DESCRIPTION
    每 N 秒记录一次 GPU 温度/频率/功耗/占用/显存、CPU 占用与实际频率、
    可用内存与提交内存，输出 CSV 到仓库根目录的 logs\ 下。

    判定方法（跑完看 CSV 的均值）：
        gpu_util_pct 平均 < 80%   -> CPU / 内存瓶颈，降画质无效
        gpu_util_pct 平均 ≈ 99%   -> 真正的 GPU 瓶颈，降画质才有用
        gpu_power_W 长期卡在默认TGP（如 115W）-> 性能模式没开
        mem_avail_MB < 500 且 commit_GB > 物理内存 -> 内存不足在翻页

.PARAMETER Minutes
    采样时长（分钟），默认 10。

.PARAMETER Interval
    采样间隔（秒），默认 2。实际间隔会略长于设定值（取数有开销）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\02_fps-sampler.ps1 -Minutes 10
#>
param(
    [int]$Minutes = 10,
    [int]$Interval = 2
)

$ErrorActionPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$csv = Join-Path $logDir ('perf_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')

$header = 'sample_time,gpu_temp_C,gpu_clock_MHz,gpu_power_W,gpu_util_pct,vram_used_MB,cpu_perf_pct,cpu_util_pct,mem_avail_MB,commit_GB'
Set-Content -Path $csv -Value $header -Encoding UTF8

# 找 nvidia-smi
$smi = $null
foreach ($p in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
    if (Test-Path $p) { $smi = $p; break }
}
if (-not $smi) {
    $c = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($c) { $smi = $c.Source }
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '  FPS Sampler  |  Delta Force PC Optimizer' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ("  时长     : {0} 分钟" -f $Minutes)
Write-Host ("  输出     : {0}" -f $csv)
if ($smi) { Write-Host ("  nvidia-smi: {0}" -f $smi) -ForegroundColor DarkGray }
else { Write-Host '  [!] 没找到 nvidia-smi，GPU 列将为空（AMD/Intel 显卡属正常）' -ForegroundColor Yellow }
Write-Host ''
Write-Host '  现在请启动游戏并正常游玩（尽量打有人的模式）。' -ForegroundColor Yellow
Write-Host '  Ctrl+C 可提前结束。' -ForegroundColor DarkGray
Write-Host ''

$end = (Get-Date).AddMinutes($Minutes)

while ((Get-Date) -lt $end) {
    $t = Get-Date -Format 'HH:mm:ss'

    $gpu = ',,,,'
    if ($smi) {
        $out = & $smi --query-gpu=temperature.gpu,clocks.current.graphics,power.draw,utilization.gpu,memory.used --format=csv,noheader,nounits 2>$null
        if ($out) { $gpu = ($out -join ',') }
    }

    $cpuPerf = (Get-Counter '\Processor Information(_Total)\% Processor Performance').CounterSamples[0].CookedValue
    $cpuUtil = (Get-Counter '\Processor Information(_Total)\% Processor Time').CounterSamples[0].CookedValue
    $memAvail = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
    $commitB = (Get-Counter '\Memory\Committed Bytes').CounterSamples[0].CookedValue

    $line = '{0},{1},{2:N0},{3:N1},{4:N0},{5:N1}' -f $t, $gpu, $cpuPerf, $cpuUtil, $memAvail, ($commitB / 1GB)
    Add-Content -Path $csv -Value $line -Encoding UTF8

    Write-Host ('{0}  GPU[{1}]  CPU {2,5:N0}%  可用 {3,6:N0}MB' -f $t, $gpu, $cpuUtil, $memAvail)
    Start-Sleep -Seconds $Interval
}

Write-Host ''
Write-Host ('采样结束：{0}' -f $csv) -ForegroundColor Green
Write-Host '把这个 CSV 交给 AI，或直接看 gpu_util_pct 的均值判断瓶颈。' -ForegroundColor Yellow
Write-Host ''
Read-Host '按回车退出'
