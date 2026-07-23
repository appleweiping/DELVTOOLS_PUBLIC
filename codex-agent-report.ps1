# Read-only report for long-lived local agent and experiment processes.

param(
    [double]$MinAgeHours = 2,
    [int]$Top = 40,
    [switch]$ShowPath,
    [switch]$ShowCommandLine
)

$ErrorActionPreference = "SilentlyContinue"

function Format-GB([double]$Bytes) {
    if ($null -eq $Bytes) { return "" }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Protect-DiagnosticPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ($env:USERPROFILE -and $Path.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "%USERPROFILE%" + $Path.Substring($env:USERPROFILE.Length)
    }
    return $Path
}

function Redact-CommandLine([string]$CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return "" }
    $redacted = $CommandLine
    $redacted = $redacted -replace '(?i)\b(?:sk|ghp|github_pat)-?[A-Za-z0-9_-]{8,}\b', 'REDACTED'
    $redacted = $redacted -replace '(?i)(authorization\s*:\s*bearer)\s+[^\s,;]+', '$1 REDACTED'
    $redacted = $redacted -replace '(?i)(--?(?:api[-_]?key|auth[-_]?token|access[-_]?token|token|password|secret))(?:\s+|=)(?:"[^"]*"|''[^'']*''|[^\s;]+)', '$1=REDACTED'
    $redacted = $redacted -replace '(?i)(\b(?:api[_-]?key|auth[_-]?token|access[_-]?token|token|password|secret)\b\s*=\s*)(?:"[^"]*"|''[^'']*''|[^\s;]+)', '$1REDACTED'
    $redacted = $redacted -replace '(?i)(https?://)[^/@\s]+:[^/@\s]+@', '$1REDACTED@'
    if ($env:USERPROFILE) {
        $redacted = $redacted.Replace($env:USERPROFILE, "%USERPROFILE%")
    }
    if ($redacted.Length -gt 240) {
        return $redacted.Substring(0, 240) + "..."
    }
    return $redacted
}

function Get-Family($Name, $CommandLine) {
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

function Invoke-CodexAgentReport {
    param(
        [double]$MinAgeHours = 2,
        [int]$Top = 40,
        [switch]$ShowPath,
        [switch]$ShowCommandLine
    )

    Write-Host "=== Codex/Agent Process Report ===" -ForegroundColor Cyan
    Write-Host "Read-only. No process will be stopped."
    Write-Host "Minimum age: $MinAgeHours hour(s)"
    Write-Host ""

    $rows = foreach ($windowsProcess in Get-CimInstance Win32_Process) {
        $family = Get-Family $windowsProcess.Name $windowsProcess.CommandLine
        if (-not $family) { continue }

        $process = Get-Process -Id $windowsProcess.ProcessId
        $age = $null
        try {
            if ($windowsProcess.CreationDate) {
                $age = [Math]::Round(((Get-Date) - $windowsProcess.CreationDate).TotalHours, 1)
            }
        } catch { }
        if ($null -ne $age -and $age -lt $MinAgeHours) { continue }

        $row = [ordered]@{
            Family     = $family
            PID        = $windowsProcess.ProcessId
            PPID       = $windowsProcess.ParentProcessId
            Name       = $windowsProcess.Name
            Age_H      = $age
            Private_GB = if ($process) { Format-GB $process.PrivateMemorySize64 } else { "" }
            WS_GB      = if ($process) { Format-GB $process.WorkingSet64 } else { "" }
        }
        if ($ShowPath) {
            $row["Path"] = Protect-DiagnosticPath $windowsProcess.ExecutablePath
        }
        if ($ShowCommandLine) {
            $row["CommandLine"] = Redact-CommandLine $windowsProcess.CommandLine
        }
        [pscustomobject]$row
    }

    $rows |
        Sort-Object Private_GB -Descending |
        Select-Object -First $Top |
        Format-Table -AutoSize -Wrap

    Write-Host ""
    Write-Host "This is a triage list only. Stop a process manually only after confirming its task is stale." -ForegroundColor DarkGray
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CodexAgentReport `
        -MinAgeHours $MinAgeHours `
        -Top $Top `
        -ShowPath:$ShowPath `
        -ShowCommandLine:$ShowCommandLine
}
