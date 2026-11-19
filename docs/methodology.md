# 方法论：怎么用 AI 一步步把问题查出来

> 比脚本更值钱的是**流程**：查一步 → 写一个脚本 → 跑 → 读日志 → 决定下一步。
> 本文记录这套流程、Windows 上的技术坑，以及"让 AI 生成可回滚脚本"的模板。

---

## 一、为什么"照抄优化清单"没用

网上的优化清单（关服务、改注册表、清缓存）是**针对平均情况**的，而低帧数的原因千差万别：

- 可能是 GPU 瓶颈 —— 那降画质有用
- 可能是 CPU 瓶颈 —— 那降画质**一点用都没有**
- 可能是后台木马 —— 那什么设置都不管用
- 可能是内存不足 —— 那要加内存

**所以第一步永远是：判断瓶颈在哪。**

---

## 二、四步流程

```
第 1 步  只读摸底
        ├─ 硬件底账（机型 / CPU / GPU / 内存通道 / 刷新率 / 硬盘）
        ├─ 空载 CPU、可用内存、提交内存、页面文件
        ├─ 电源模式、GPU 功耗墙、驱动版本、HAGS / GameDVR
        └─ 游戏配置（分辨率 / 窗口模式 / 画质 / 超分 / 内部渲染分辨率 / 帧上限）

第 2 步  找矛盾点
        └─ 例：最低画质 + 内部渲染 58% + RTX 3070 → 本该 120+ 帧
           → 说明瓶颈不在 GPU 侧，转向 CPU / 内存 / 后台

第 3 步  实时采样（打游戏时抓 10 分钟）
        └─ GPU 占用 < 80% = CPU / 内存瓶颈；GPU 占用 ≈ 99% = 真 GPU 瓶颈

第 4 步  分级处置 + 每一步用数字验证
        └─ 停服务 → 测变化；杀进程 → 测变化；查持久化 → 删 → 复查
```

---

## 三、让 AI 生成"可回滚脚本"的模板

直接让 AI 改系统很危险。正确做法是让它**生成脚本**，你审核后执行。给 AI 的指令里必须包含：

```
请生成一个 PowerShell 脚本，要求：
1. 开头自动检测管理员权限，没有就 Start-Process -Verb RunAs 重新启动自己
2. 所有改动前先备份（注册表用 reg export，文件用复制）
3. 每一项改动都写日志（时间戳 + 动作 + 结果），日志写到 logs\ 目录
4. 记录"处理前"和"处理后"的关键指标（如系统 CPU 占用）
5. 删除文件时先 Move-Item 到 C:\Quarantine_日期\，不要直接删
6. 改服务时优先设为 Manual 而不是 Disabled（可恢复）
7. 结尾打印回滚方法
```

生成的脚本骨架大致是：

```powershell
# ---------- 自动提权（双击即可，会弹 UAC） ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk   = Join-Path $here 'backup'
$log  = Join-Path $here ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
New-Item -ItemType Directory -Force -Path $bk | Out-Null

function L($m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}

# 备份
reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' (Join-Path $bk 'HKCU_Run.reg') /y | Out-Null

# 处理前基线
$before = (Get-Counter '\Processor Information(_Total)\% Processor Time').CounterSamples[0].CookedValue
L ('处理前 CPU = ' + $before + ' %')

# ……执行改动……

# 处理后对比
$after = (Get-Counter '\Processor Information(_Total)\% Processor Time').CounterSamples[0].CookedValue
L ('处理后 CPU = ' + $after + ' %')
```

---

## 四、Windows 上的技术坑（给 AI 的注意事项）

### 1. 权限不足会导致"看起来执行成功但没生效"

低权限下 `Remove-ItemProperty` 可能**报告成功但值还在**。脚本里必须**改完再读一遍验证**：

```powershell
Remove-ItemProperty $k -Name $n
if ((Get-Item $k).Property -contains $n) { L "删除失败: $n" } else { L "已删除: $n" }
```

### 2. 命名管道在受限环境会被拦

某些受限环境（沙箱 / 低权限作业对象）下，把原生命令输出接管道会失败：

```powershell
& nvidia-smi --query-gpu=name | Select-String ...   # ❌ 可能失败
reg export ... | Out-Null                           # ❌ 可能失败
```

**解法**：原生命令直接调用（不接管道），或把解析逻辑放进提权脚本里跑。

### 3. 进程列表可能被过滤

受限环境下 `Get-Process` 可能只返回一小部分进程，`\Process(*)\% Processor Time` 的实例列表同样被过滤。

**解法**：

- `\Processor Information(_Total)\% Processor Time` **不受影响**，用它判断真实总负载
- 用 `\Process(_Total)\% Processor Time` 与总负载对比，差值就是"看不见的进程"占的 CPU
- 进程明细交给**提权脚本**枚举

### 4. 脚本编码

`.ps1` 必须存成 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 里中文会乱码甚至解析出错。

```powershell
$enc = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($path, [IO.File]::ReadAllText($path), $enc)
```

### 5. `.bat` 与中文路径

`.bat` 里引用中文文件名会因为 cmd 代码页解析失败而**静默不执行**。脚本和路径尽量用**纯 ASCII**。

### 6. `explorer.exe xxx.bat` 不会执行

只会打开所在文件夹。真正能跑的是 `Start-Process -Verb RunAs`。

### 7. 采样间隔会漂

`Get-Counter` 单次调用有开销，"每 2 秒采一次"实际可能变成 6 秒。分析时按**实际行数 / 时间戳**计算，不要假设间隔。

---

## 五、判定规则速查

| 现象 | 大概率原因 | 先查什么 |
| :--- | :--- | :--- |
| 画质已最低但帧数仍低 | 不是 GPU 瓶颈 | 采样看 GPU 占用，< 80% 就是 CPU/内存 |
| 空载 CPU 就 50%+ | 挖矿 / 共享算力 / 后台软件 | 提权后枚举进程，看随机名 |
| 空载可用内存 < 500MB | 常驻软件太多 / 内存不足 | 任务管理器看 Top，考虑加内存 |
| GPU 功耗卡在默认 TGP | 性能模式没开 | Fn+Q / 厂商控制中心 |
| 帧数 30/60 整数跳变 | 垂直同步 / 半刷新率 | 关垂直同步、确认刷新率 |
| 只有第一次进图卡，之后顺 | 着色器 / PSO 编译 | 正常现象，别清缓存 |
| 越玩越卡、读图特别慢 | 内存不足翻页 / 硬盘是 QLC | 看提交内存、硬盘型号 |
| 突然出现"安全组件"类进程 | 木马伪装 | 查签名、查计划任务 |

---

## 六、红线

- ❌ 向游戏注入 DLL、替换游戏 DLL、挂钩 DXGI（**反作弊封号**）
- ❌ 来源不明的"一键优化"脚本、破解版优化工具
- ❌ 清待机内存、关 HPET、关 MPO、改 Timer Resolution、关 SysMain（收益 ≈ 0，风险不小）
- ❌ 直接删系统文件（先隔离，观察几天再删）
- ❌ 装多个杀毒软件互相打架
- ❌ 用"共享算力赚钱"软件的同时打竞技游戏

---

## 七、换一台电脑怎么起手

1. 把 `docs/prompt.md` 的内容复制给那台电脑上的 AI
2. 让它先跑**只读摸底**，用表格给你结果
3. 跑 `scripts/02_fps-sampler.ps1` 采样，先定瓶颈
4. 确认是 CPU 瓶颈后，再让它按证据一步步生成处置脚本
5. **每一步都看"处理前后"的数字对比**，没变化说明没打中，继续查
