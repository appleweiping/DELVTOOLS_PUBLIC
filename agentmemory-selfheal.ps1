param(
    [string]$DataRoot = "D:\devtools\data",
    [string]$Config = "D:\devtools\agentmemory-iii.yaml",
    [string]$LogDir = "D:\devtools\logs"
)

# agentmemory 持久化自愈 v3.1 (2026-06-12, 升级免疫根治版)。
#
# 历史:
#   v1 只看端口 -> 漏掉「端口活/应用死」(2026-06-10)。
#   v2 用正则把包内 iii-config.yaml 的相对路径改绝对 -> 但 npm 升级随时把
#      config 重置回相对路径, 修补方永远慢一步 (2026-06-12 复发)。
#   v3 根治: canonical config 移到包外 (D:\devtools\agentmemory-iii.yaml,
#      全绝对路径, npm 碰不到)。selfheal 不再打补丁。
#   v3.1: full-restart 加两次重试 (并发写 yaml 时引擎可能读到半写文件)。
#
# 流程 (全部幂等, 健康时 8 秒内 no-op):
#   0) 外部 config 丢失 -> 记 CONFIG-MISSING (server.ps1 有 legacy 回退)
#   1) 端口不在听 -> 拉起
#   2) 端口在听但 /agentmemory/health 非 200 -> 对「运行中进程实际加载的
#      config」追加时间戳注释, 触发 iii 引擎热重载, exec 子进程重生
#   3) 仍不健康 -> 杀 iii + agentmemory node 整组重启, 最多 2 次
#   4) 结果写日志 (notes 全 ASCII, 防 GBK/UTF8 乱码); 不健康发 signals 告警

$ErrorActionPreference = "Continue"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$log = Join-Path $LogDir "agentmemory-selfheal.log"
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$notes = @()

function Test-AmHealth {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:3111/agentmemory/health" -UseBasicParsing -TimeoutSec 8
        return ([int]$r.StatusCode -eq 200)
    } catch { return $false }
}

# 找出运行中 iii 进程实际加载的 config (热重载必须 touch 同一个文件)
function Get-RunningIiiConfig {
    $p = Get-CimInstance Win32_Process -Filter "Name='iii.exe'" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($p -and $p.CommandLine -match '--config\s+"?([^"]+?\.ya?ml)"?') { return $Matches[1].Trim() }
    return $null
}

# --- 0. 外部 canonical config 必须在 ---------------------------------------
if (Test-Path $Config) { $notes += "config-ok" } else { $notes += "CONFIG-MISSING($Config)" }

# --- 1. 端口不在听 -> 拉起服务 -------------------------------------------
$listening = @(Get-NetTCPConnection -State Listen -LocalPort 3111 -ErrorAction SilentlyContinue).Count
if ($listening -eq 0) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\devtools\agentmemory-server.ps1"
    Start-Sleep -Seconds 20
    $listening = @(Get-NetTCPConnection -State Listen -LocalPort 3111 -ErrorAction SilentlyContinue).Count
    $notes += "service-was-down-restarted(now-listening=$listening)"
} else {
    $notes += "service-up"
}

# --- 2. 端口在听但应用层死 -> 热重载运行中进程的 config ---------------------
$healthy = Test-AmHealth
if (-not $healthy -and $listening -gt 0) {
    $liveConfig = Get-RunningIiiConfig
    if (-not $liveConfig -or -not (Test-Path $liveConfig)) { $liveConfig = $Config }
    if (Test-Path $liveConfig) {
        $raw = Get-Content $liveConfig -Raw -Encoding UTF8
        $marker = "# selfheal-reload: "
        $lines = $raw -split "`n" | Where-Object { $_ -notmatch [regex]::Escape($marker) }
        $bumped = (($lines -join "`n").TrimEnd()) + "`n$marker$stamp`n"
        Set-Content -Path $liveConfig -Value $bumped -Encoding UTF8 -NoNewline
        Start-Sleep -Seconds 25
        $healthy = Test-AmHealth
        $notes += "app-layer-dead-hot-reloaded(config=$liveConfig healthy=$healthy)"
    }
}

# --- 3. 仍不健康 -> 最后手段: 整组重启, 最多 2 次 ---------------------------
if (-not $healthy) {
    foreach ($attempt in 1, 2) {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*agentmemory*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Get-Process -Name iii -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\devtools\agentmemory-server.ps1"
        Start-Sleep -Seconds 25
        $healthy = Test-AmHealth
        $notes += "full-restart#$attempt(healthy=$healthy)"
        if ($healthy) { break }
        Start-Sleep -Seconds 10
    }
}

$notes += "health=$(if ($healthy) { 'healthy' } else { 'STILL-FAILING' })"

# --- 4. 落日志 + 告警信号 (尽力而为) ---------------------------------------
$line = "[$stamp] " + ($notes -join " | ")
Add-Content -Path $log -Value $line -Encoding UTF8
if (-not $healthy) {
    try {
        Invoke-RestMethod -Method Post -Uri "http://localhost:3111/agentmemory/signals/send" `
            -ContentType "application/json" -TimeoutSec 5 `
            -Body (@{ from = "agentmemory-selfheal"; to = "all"; type = "error"; content = $line } | ConvertTo-Json) | Out-Null
    } catch { }
}
Write-Output $line
