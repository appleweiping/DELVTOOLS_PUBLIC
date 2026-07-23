# Read-only local performance and agent-process health report.

param(
    [ValidateRange(0, 60)][int]$CpuSampleSeconds = 3,
    [ValidateRange(1, 200)][int]$Top = 12,
    [string]$DiagnosticDrive,
    [string]$AgentMemoryBaseUrl,
    [int[]]$KeyPorts,
    [switch]$ShowPath
)

$ErrorActionPreference = "SilentlyContinue"

function Format-GB([double]$Bytes) {
    if ($null -eq $Bytes) { return "" }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Resolve-DiagnosticDrive([string]$Drive) {
    $candidate = $Drive
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:DEVTOOLS_DIAGNOSTIC_DRIVE }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = [System.IO.Path]::GetPathRoot($PSScriptRoot)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:SystemDrive }
    if ($candidate -notmatch '^[A-Za-z]:') {
        throw "DiagnosticDrive must be a Windows drive such as D:."
    }
    return $candidate.Substring(0, 2).ToUpperInvariant()
}

function Protect-HealthPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ($env:USERPROFILE -and $Path.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "%USERPROFILE%" + $Path.Substring($env:USERPROFILE.Length)
    }
    return $Path
}

function Get-ProcessAgeHours($Process) {
    try {
        if ($Process.CreationDate) {
            return [Math]::Round(((Get-Date) - $Process.CreationDate).TotalHours, 1)
        }
    } catch { }
    return $null
}

function Get-AgentFamily($Name, $CommandLine) {
    $cmd = [string]$CommandLine
    if ($Name -match "claudeseek" -or $cmd -match "claudeseek") { return "claudeseek" }
    if ($Name -match "opencode" -or $cmd -match "opencode") { return "OpenCode" }
    if ($Name -match "gemini" -or $cmd -match "(?:^|[\\/\s])gemini(?:\.cmd|\.js|\.exe|\s|$)") { return "Gemini" }
    if ($Name -match "hermes" -or $cmd -match "(?:^|[\\/\s])hermes(?:[\\/\s.-]|$)") { return "hermes" }
    if ($Name -match "aris" -or $cmd -match "(?:^|[\\/\s])aris(?:\.cmd|\.exe|\s|$)") { return "ARIS" }
    if ($Name -match "aide" -or $cmd -match "(?:^|[\\/\s])aide(?:[\\/\s.-]|$)") { return "AIDE" }
    if ($Name -match "Codex|codex" -or $cmd -match "codex") { return "Codex" }
    if ($cmd -match "windows-mcp" -or $Name -match "windows-mcp") { return "windows-mcp" }
    if ($Name -match "claude" -or $cmd -match "claude") { return "Claude" }
    if ($cmd -match "agentmemory|AGENTMEMORY") { return "agentmemory" }
    if ($cmd -match "agent-hub|run-as-codex") { return "Retired Agent Hub" }
    if ($cmd -match "key-rotator") { return "key-rotator" }
    if ($Name -match "Code" -or $cmd -match "Microsoft VS Code") { return "VS Code" }
    if ($Name -match "chrome") { return "Chrome" }
    if ($Name -match "msedgewebview2") { return "WebView2" }
    if ($Name -match "python" -or $cmd -match "donebench|experiment-pipeline|run_gpt|run_claude") { return "Python/experiments" }
    if ($Name -match "powershell|pwsh") { return "PowerShell" }
    if ($Name -match "node") { return "Node" }
    if ($Name -match "Unity") { return "Unity" }
    return $null
}

function Invoke-CodexHealth {
    param(
        [int]$CpuSampleSeconds = 3,
        [int]$Top = 12,
        [string]$DiagnosticDrive,
        [string]$AgentMemoryBaseUrl,
        [int[]]$KeyPorts,
        [switch]$ShowPath
    )

    $drive = Resolve-DiagnosticDrive $DiagnosticDrive
    $baseUrl = $AgentMemoryBaseUrl
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = "http://localhost:3111" }
    $agentMemoryUri = [System.Uri]$baseUrl
    $ports = @($KeyPorts)
    if ($ports.Count -eq 0) {
        $ports = @($agentMemoryUri.Port, 6002, 8990, 9100, 9800) | Select-Object -Unique
    }

    Write-Host "=== Codex Performance Health ===" -ForegroundColor Cyan
    Write-Host "Time: $(Get-Date -Format s)"
    Write-Host ""

    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
    $pageUsage = Get-CimInstance Win32_PageFileUsage
    $pageFilePath = "$drive\pagefile.sys"
    $pageFile = Get-Item -LiteralPath $pageFilePath -Force
    $pageAllocatedMb = ($pageUsage | Where-Object Name -eq $pageFilePath | Select-Object -First 1).AllocatedBaseSize
    $pageCurrentMb = ($pageUsage | Where-Object Name -eq $pageFilePath | Select-Object -First 1).CurrentUsage

    $ramUsedPercent = if ($operatingSystem.TotalVisibleMemorySize) {
        [Math]::Round((1 - ($operatingSystem.FreePhysicalMemory / $operatingSystem.TotalVisibleMemorySize)) * 100, 1)
    } else { 0 }
    $diskUsedPercent = if ($disk.Size) { [Math]::Round((1 - ($disk.FreeSpace / $disk.Size)) * 100, 1) } else { 0 }
    $commitRatio = if ($memory.CommitLimit) { $memory.CommittedBytes / $memory.CommitLimit } else { 0 }

    [pscustomobject]@{
        RAM_Total_GB          = Format-GB $computerSystem.TotalPhysicalMemory
        RAM_Free_GB           = Format-GB ($operatingSystem.FreePhysicalMemory * 1KB)
        RAM_Used_Pct          = $ramUsedPercent
        Commit_GB             = Format-GB $memory.CommittedBytes
        CommitLimit_GB        = Format-GB $memory.CommitLimit
        Diagnostic_Drive      = $drive
        Drive_Free_GB         = Format-GB $disk.FreeSpace
        Drive_Used_Pct        = $diskUsedPercent
        Pagefile_Allocated_GB = if ($pageAllocatedMb) { [Math]::Round($pageAllocatedMb / 1024, 2) } else { Format-GB $pageFile.Length }
        Pagefile_InUse_GB     = if ($pageCurrentMb) { [Math]::Round($pageCurrentMb / 1024, 2) } else { "" }
    } | Format-List

    Write-Host "=== Pagefile Usage ===" -ForegroundColor Cyan
    $pageUsage |
        Select-Object Name, CurrentUsage, PeakUsage, AllocatedBaseSize |
        Format-Table -AutoSize

    Write-Host "=== Pressure Notes ===" -ForegroundColor Cyan
    if ($commitRatio -gt 0.85) {
        Write-Host "WARN: Commit charge is above 85%; agent and UI apps may feel slow." -ForegroundColor Yellow
    }
    if (($operatingSystem.FreePhysicalMemory * 1KB) -lt 4GB) {
        Write-Host "WARN: Free RAM is below 4GB; Windows will page aggressively." -ForegroundColor Yellow
    }
    if ($disk.Size -and ($disk.FreeSpace / $disk.Size) -lt 0.15) {
        Write-Host "WARN: The diagnostic drive has less than 15% free space." -ForegroundColor Yellow
    }
    if ($commitRatio -le 0.85 -and
        ($operatingSystem.FreePhysicalMemory * 1KB) -ge 4GB -and
        (-not $disk.Size -or ($disk.FreeSpace / $disk.Size) -ge 0.15)) {
        Write-Host "OK: No immediate memory or disk pressure threshold crossed." -ForegroundColor Green
    }
    Write-Host ""

    Write-Host "=== Top CPU Sample (${CpuSampleSeconds}s) ===" -ForegroundColor Cyan
    $logical = [Math]::Max((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 1)
    $before = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, PrivateMemorySize64
    if ($CpuSampleSeconds -gt 0) { Start-Sleep -Seconds $CpuSampleSeconds }
    $after = Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, PrivateMemorySize64
    $sampleWindow = [Math]::Max($CpuSampleSeconds, 1)
    $cpuRows = foreach ($process in $after) {
        $old = $before | Where-Object Id -eq $process.Id | Select-Object -First 1
        if ($old -and $null -ne $process.CPU -and $null -ne $old.CPU) {
            [pscustomobject]@{
                PID        = $process.Id
                Name       = $process.ProcessName
                CPU_Pct    = [Math]::Round((($process.CPU - $old.CPU) / $sampleWindow) / $logical * 100, 1)
                Private_GB = Format-GB $process.PrivateMemorySize64
                WS_GB      = Format-GB $process.WorkingSet64
            }
        }
    }
    $cpuRows | Sort-Object CPU_Pct -Descending | Select-Object -First $Top | Format-Table -AutoSize

    Write-Host "=== Top Memory ===" -ForegroundColor Cyan
    Get-Process |
        Sort-Object PrivateMemorySize64 -Descending |
        Select-Object -First $Top Id, ProcessName,
            @{n = "Private_GB"; e = { Format-GB $_.PrivateMemorySize64 }},
            @{n = "WS_GB"; e = { Format-GB $_.WorkingSet64 }} |
        Format-Table -AutoSize

    Write-Host "=== Agent/App Family Totals ===" -ForegroundColor Cyan
    $processRows = Get-CimInstance Win32_Process | ForEach-Object {
        $process = Get-Process -Id $_.ProcessId
        $family = Get-AgentFamily $_.Name $_.CommandLine
        if ($family) {
            [pscustomobject]@{
                Family     = $family
                PID        = $_.ProcessId
                Private_MB = if ($process) { [double]($process.PrivateMemorySize64 / 1MB) } else { 0 }
                WS_MB      = if ($process) { [double]($process.WorkingSet64 / 1MB) } else { 0 }
                AgeHours   = Get-ProcessAgeHours $_
            }
        }
    }
    $processRows |
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
    $portRows = foreach ($port in $ports) {
        $listeners = Get-NetTCPConnection -LocalPort $port -State Listen
        if ($listeners) {
            foreach ($listener in $listeners) {
                $process = Get-Process -Id $listener.OwningProcess
                $row = [ordered]@{
                    Port    = $port
                    Status  = "listening"
                    PID     = $listener.OwningProcess
                    Process = if ($process) { $process.ProcessName } else { "" }
                }
                if ($ShowPath) { $row["Path"] = if ($process) { Protect-HealthPath $process.Path } else { "" } }
                [pscustomobject]$row
            }
        } else {
            [pscustomobject]@{ Port = $port; Status = "not listening"; PID = ""; Process = "" }
        }
    }
    $portRows | Format-Table -AutoSize

    Write-Host "Read-only check complete. No processes or files were changed." -ForegroundColor DarkGray
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CodexHealth `
        -CpuSampleSeconds $CpuSampleSeconds `
        -Top $Top `
        -DiagnosticDrive $DiagnosticDrive `
        -AgentMemoryBaseUrl $AgentMemoryBaseUrl `
        -KeyPorts $KeyPorts `
        -ShowPath:$ShowPath
}
