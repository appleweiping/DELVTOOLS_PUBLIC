# Codex local performance health check.
# Read-only: prints system pressure, disk/pagefile state, agent process totals, and key ports.

param(
    [int]$CpuSampleSeconds = 3,
    [int]$Top = 12
)

$ErrorActionPreference = "SilentlyContinue"

function Format-GB([double]$bytes) {
    if ($null -eq $bytes) { return "" }
    return [Math]::Round($bytes / 1GB, 2)
}

function Get-ProcessAgeHours($proc) {
    try {
        if ($proc.CreationDate) {
            return [Math]::Round(((Get-Date) - $proc.CreationDate).TotalHours, 1)
        }
    } catch {}
    return $null
}

function Get-AgentFamily($name, $cmd) {
    if ($name -match "Codex|codex" -or $cmd -match "codex") { return "Codex" }
    if ($cmd -match "windows-mcp" -or $name -match "windows-mcp") { return "windows-mcp" }
    if ($name -match "claude" -or $cmd -match "claude") { return "Claude" }
    if ($cmd -match "agentmemory|AGENTMEMORY") { return "agentmemory" }
    if ($cmd -match "agent-hub|run-as-codex") { return "Retired Agent Hub" }
    if ($cmd -match "key-rotator") { return "key-rotator" }
    if ($name -match "Code" -or $cmd -match "Microsoft VS Code") { return "VS Code" }
    if ($name -match "chrome") { return "Chrome" }
    if ($name -match "msedgewebview2") { return "WebView2" }
    if ($name -match "python" -or $cmd -match "donebench|experiment-pipeline|run_gpt|run_claude") { return "Python/experiments" }
    if ($name -match "powershell|pwsh") { return "PowerShell" }
    if ($name -match "node") { return "Node" }
    return $null
}

Write-Host "=== Codex Performance Health ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format s)"
Write-Host ""

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'"
$pageUsage = Get-CimInstance Win32_PageFileUsage
$pageFile = Get-Item -LiteralPath "D:\pagefile.sys" -Force
$pageAllocatedMb = ($pageUsage | Where-Object Name -eq "D:\pagefile.sys" | Select-Object -First 1).AllocatedBaseSize
$pageCurrentMb = ($pageUsage | Where-Object Name -eq "D:\pagefile.sys" | Select-Object -First 1).CurrentUsage

$system = [pscustomobject]@{
    "RAM_Total_GB"     = Format-GB $cs.TotalPhysicalMemory
    "RAM_Free_GB"      = Format-GB ($os.FreePhysicalMemory * 1KB)
    "RAM_Used_Pct"     = [Math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
    "Commit_GB"        = Format-GB $mem.CommittedBytes
    "CommitLimit_GB"   = Format-GB $mem.CommitLimit
    "D_Free_GB"        = Format-GB $d.FreeSpace
    "D_Used_Pct"       = [Math]::Round((1 - ($d.FreeSpace / $d.Size)) * 100, 1)
    "Pagefile_Allocated_GB" = if ($pageAllocatedMb) { [Math]::Round($pageAllocatedMb / 1024, 2) } else { Format-GB $pageFile.Length }
    "Pagefile_InUse_GB"     = if ($pageCurrentMb) { [Math]::Round($pageCurrentMb / 1024, 2) } else { "" }
}
$system | Format-List

Write-Host "=== Pagefile Usage ===" -ForegroundColor Cyan
$pageUsage |
    Select-Object Name, CurrentUsage, PeakUsage, AllocatedBaseSize |
    Format-Table -AutoSize

Write-Host "=== Pressure Notes ===" -ForegroundColor Cyan
if (($mem.CommittedBytes / $mem.CommitLimit) -gt 0.85) {
    Write-Host "WARN: Commit charge is above 85%; Codex and all UI apps may feel slow." -ForegroundColor Yellow
}
if (($os.FreePhysicalMemory * 1KB) -lt 4GB) {
    Write-Host "WARN: Free RAM is below 4GB; Windows will page aggressively." -ForegroundColor Yellow
}
if (($d.FreeSpace / $d.Size) -lt 0.15) {
    Write-Host "WARN: D: has less than 15% free space; pagefile and large outputs can contend." -ForegroundColor Yellow
}
if (($mem.CommittedBytes / $mem.CommitLimit) -le 0.85 -and ($os.FreePhysicalMemory * 1KB) -ge 4GB -and ($d.FreeSpace / $d.Size) -ge 0.15) {
    Write-Host "OK: No immediate memory or D: pressure threshold crossed." -ForegroundColor Green
}
Write-Host ""

Write-Host "=== Top CPU Sample (${CpuSampleSeconds}s) ===" -ForegroundColor Cyan
$logical = [Math]::Max((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 1)
$p1 = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, PrivateMemorySize64
Start-Sleep -Seconds $CpuSampleSeconds
$p2 = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, PrivateMemorySize64
$cpuRows = foreach ($p in $p2) {
    $old = $p1 | Where-Object Id -eq $p.Id | Select-Object -First 1
    if ($old -and $null -ne $p.CPU -and $null -ne $old.CPU) {
        [pscustomobject]@{
            PID        = $p.Id
            Name       = $p.ProcessName
            CPU_Pct    = [Math]::Round((($p.CPU - $old.CPU) / $CpuSampleSeconds) / $logical * 100, 1)
            Private_GB = Format-GB $p.PrivateMemorySize64
            WS_GB      = Format-GB $p.WorkingSet64
        }
    }
}
$cpuRows | Sort-Object CPU_Pct -Descending | Select-Object -First $Top | Format-Table -AutoSize

Write-Host "=== Top Memory ===" -ForegroundColor Cyan
Get-Process |
    Sort-Object PrivateMemorySize64 -Descending |
    Select-Object -First $Top Id, ProcessName,
        @{n="Private_GB"; e={ Format-GB $_.PrivateMemorySize64 }},
        @{n="WS_GB"; e={ Format-GB $_.WorkingSet64 }} |
    Format-Table -AutoSize

Write-Host "=== Agent/App Family Totals ===" -ForegroundColor Cyan
$procRows = Get-CimInstance Win32_Process | ForEach-Object {
    $gp = Get-Process -Id $_.ProcessId
    $family = Get-AgentFamily $_.Name $_.CommandLine
    if ($family) {
        [pscustomobject]@{
            Family     = $family
            PID        = $_.ProcessId
            Private_MB = if ($gp) { [double]($gp.PrivateMemorySize64 / 1MB) } else { 0 }
            WS_MB      = if ($gp) { [double]($gp.WorkingSet64 / 1MB) } else { 0 }
            AgeHours   = Get-ProcessAgeHours $_
        }
    }
}
$procRows |
    Group-Object Family |
    ForEach-Object {
        [pscustomobject]@{
            Family     = $_.Name
            Count      = $_.Count
            Private_GB = [Math]::Round(($_.Group | Measure-Object Private_MB -Sum).Sum / 1024, 2)
            WS_GB      = [Math]::Round(($_.Group | Measure-Object WS_MB -Sum).Sum / 1024, 2)
            Oldest_H   = [Math]::Round(($_.Group | Measure-Object AgeHours -Maximum).Maximum, 1)
        }
    } |
    Sort-Object Private_GB -Descending |
    Format-Table -AutoSize

Write-Host "=== Key Local Ports ===" -ForegroundColor Cyan
$ports = @(8990, 9100, 3111, 3113, 9800)
$portRows = foreach ($port in $ports) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen
    if ($listeners) {
        foreach ($listener in $listeners) {
            $p = Get-Process -Id $listener.OwningProcess
            [pscustomobject]@{
                Port    = $port
                Status  = "listening"
                PID     = $listener.OwningProcess
                Process = if ($p) { $p.ProcessName } else { "" }
                Path    = if ($p) { $p.Path } else { "" }
            }
        }
    } else {
        [pscustomobject]@{
            Port    = $port
            Status  = "not listening"
            PID     = ""
            Process = ""
            Path    = ""
        }
    }
}
$portRows | Format-Table -AutoSize

Write-Host "Read-only check complete. No processes or files were changed." -ForegroundColor DarkGray
