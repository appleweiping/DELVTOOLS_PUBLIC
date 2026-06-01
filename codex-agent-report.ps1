# Report long-lived Codex/agent/experiment processes without stopping them.
# Read-only by default. Does not print full command lines unless -ShowCommandLine is used.

param(
    [double]$MinAgeHours = 2,
    [int]$Top = 40,
    [switch]$ShowCommandLine
)

$ErrorActionPreference = "SilentlyContinue"

function Format-GB([double]$bytes) {
    if ($null -eq $bytes) { return "" }
    return [Math]::Round($bytes / 1GB, 2)
}

function Redact-CommandLine([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return "" }
    $redacted = $cmd
    $redacted = $redacted -replace '(sk-[A-Za-z0-9_\-]{8,})', 'sk-REDACTED'
    $redacted = $redacted -replace '(?i)(api[_-]?key|token|auth[_-]?token|password|secret)\s*=\s*"?[^"\s;]+', '$1=REDACTED'
    if ($redacted.Length -gt 180) {
        return $redacted.Substring(0, 180) + "..."
    }
    return $redacted
}

function Get-Family($name, $cmd) {
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
    if ($name -match "Godot") { return "Godot" }
    return $null
}

Write-Host "=== Codex/Agent Process Report ===" -ForegroundColor Cyan
Write-Host "Read-only. No process will be stopped."
Write-Host "Minimum age: $MinAgeHours hour(s)"
Write-Host ""

$rows = foreach ($wp in Get-CimInstance Win32_Process) {
    $family = Get-Family $wp.Name $wp.CommandLine
    if (-not $family) { continue }

    $gp = Get-Process -Id $wp.ProcessId
    $age = $null
    try {
        if ($wp.CreationDate) {
            $age = [Math]::Round(((Get-Date) - $wp.CreationDate).TotalHours, 1)
        }
    } catch {}

    if ($null -ne $age -and $age -lt $MinAgeHours) { continue }

    $row = [ordered]@{
        Family     = $family
        PID        = $wp.ProcessId
        PPID       = $wp.ParentProcessId
        Name       = $wp.Name
        Age_H      = $age
        Private_GB = if ($gp) { Format-GB $gp.PrivateMemorySize64 } else { "" }
        WS_GB      = if ($gp) { Format-GB $gp.WorkingSet64 } else { "" }
        Path       = $wp.ExecutablePath
    }
    if ($ShowCommandLine) {
        $row["CommandLine"] = Redact-CommandLine $wp.CommandLine
    }
    [pscustomobject]$row
}

$rows |
    Sort-Object Private_GB -Descending |
    Select-Object -First $Top |
    Format-Table -AutoSize -Wrap

Write-Host ""
Write-Host "This is a triage list only. Stop a process manually only after confirming its task is stale." -ForegroundColor DarkGray
