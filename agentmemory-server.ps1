$ErrorActionPreference = 'SilentlyContinue'

# --- 锁定工作目录 (修复记忆漂移根因) ---------------------------------
# agentmemory 的存储路径若是相对路径 (./data),会相对于进程工作目录解析。
# 开机 Startup / 不同启动方式下 cwd 不一致 -> 数据写到不同位置 -> "时好时坏"。
# 这里强制 cwd = D:\devtools,并显式指向绝对路径 config,双保险。
Set-Location 'D:\devtools'

$existing = Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -eq 3111 }
if ($existing) { exit 0 }

$env:PATH = 'D:\devtools;D:\devtools\node;D:\devtools\npm-global;D:\devtools\pwsh;D:\devtools\dotnet;D:\devtools\aris-code;' + $env:PATH
$env:AGENTMEMORY_TOOLS = 'all'
$env:AGENTMEMORY_SLOTS = 'true'
$env:AGENTMEMORY_URL = 'http://localhost:3111'

# 升级免疫 (2026-06-12 根治): config 移到包外。包内 iii-config.yaml 每次
# npm 升级都会被重置回相对路径 -> exec 子进程起不来 -> 端口活/应用死。
# 包外 canonical config 全绝对路径, npm 永远碰不到它。
$config = 'D:\devtools\agentmemory-iii.yaml'
$legacyConfig = 'D:\devtools\npm-global\node_modules\@agentmemory\agentmemory\dist\iii-config.yaml'
if (-not (Test-Path $config)) { $config = $legacyConfig }

$iii = 'D:\devtools\npm-global\iii.exe'

# 日志时间戳化 (2026-06-12): 固定文件名 agentmemory.out.log 曾被遗留进程句柄
# 锁死, Start-Process -RedirectStandardOutput 打不开文件 -> 静默 spawn 失败,
# 服务"明明拉了却没起来"。每次启动用独立文件名, 永不冲突; 顺手清 14 天前的旧日志。
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdout = "D:\devtools\logs\agentmemory.out-$ts.log"
$stderr = "D:\devtools\logs\agentmemory.err-$ts.log"
Get-ChildItem 'D:\devtools\logs\agentmemory.out-*.log', 'D:\devtools\logs\agentmemory.err-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (Test-Path $iii) {
    # 直接用 iii.exe + 绝对路径 config 启动 (与手动验证一致, 最确定)
    Start-Process -FilePath $iii -ArgumentList @('--config', $config) `
        -WorkingDirectory 'D:\devtools' -WindowStyle Minimized `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
} else {
    # 回退: 老的 launcher 方式, 仍锁定工作目录
    Start-Process -FilePath 'D:\devtools\npm-global\agentmemory.cmd' -ArgumentList @('--tools','all') `
        -WorkingDirectory 'D:\devtools' -WindowStyle Minimized `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
}
