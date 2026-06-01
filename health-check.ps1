# Agent infrastructure health check.
# Read-only. Run: powershell D:\devtools\health-check.ps1

$errors = @()
$warnings = @()

Write-Host "=== Agent Infrastructure Health Check ===" -ForegroundColor Cyan
Write-Host ""

function Test-Port($Name, $Port, [switch]$Required) {
    Write-Host -NoNewline "$Name ($Port)... "
    try {
        $r = Test-NetConnection localhost -Port $Port -WarningAction SilentlyContinue
        if ($r.TcpTestSucceeded) {
            Write-Host "OK" -ForegroundColor Green
            return
        }
    } catch {}

    if ($Required) {
        Write-Host "FAIL" -ForegroundColor Red
        $script:errors += "$Name not listening on port $Port"
    } else {
        Write-Host "WARN" -ForegroundColor Yellow
        $script:warnings += "$Name not listening on port $Port"
    }
}

Test-Port -Name "agentmemory" -Port 3111 -Required
Test-Port -Name "agentmemory viewer" -Port 3113
Test-Port -Name "PixelCat" -Port 8990
Test-Port -Name "key rotator" -Port 9100

Write-Host -NoNewline "Agent Hub retired... "
$hub = Test-NetConnection localhost -Port 9800 -WarningAction SilentlyContinue
if ($hub.TcpTestSucceeded) {
    Write-Host "WARN" -ForegroundColor Yellow
    $warnings += "Retired Agent Hub appears to be listening on port 9800"
} else {
    Write-Host "OK" -ForegroundColor Green
}

Write-Host -NoNewline "agent-resources... "
if (Test-Path "D:\agent-resources\SKILL-INDEX.md") {
    Write-Host "OK" -ForegroundColor Green
} else {
    Write-Host "FAIL" -ForegroundColor Red
    $errors += "D:\agent-resources\SKILL-INDEX.md not found"
}

Write-Host -NoNewline "D-drive junctions... "
$junctions = @("C:\Users\admin\.claude", "C:\Users\admin\.codex")
$jOk = $true
foreach ($j in $junctions) {
    $item = Get-Item $j -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne "Junction") {
        $jOk = $false
        $warnings += "$j is not a junction"
    }
}
if ($jOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "WARN" -ForegroundColor Yellow }

Write-Host -NoNewline "CLI launchers... "
$launchers = @("D:\devtools\cc.cmd", "D:\devtools\claude.cmd", "D:\devtools\codex.cmd", "D:\devtools\agentmemory-server.cmd")
$lOk = $true
foreach ($l in $launchers) {
    if (-not (Test-Path $l)) {
        $lOk = $false
        $warnings += "Missing launcher: $l"
    }
}
if ($lOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "WARN" -ForegroundColor Yellow }

Write-Host -NoNewline "Codex ARIS skills... "
$codexSkills = Get-ChildItem "D:\research\Vipin's Knowledgebase\.codex\skills\aris-*" -Directory -ErrorAction SilentlyContinue
if ($codexSkills.Count -ge 8) {
    Write-Host "OK ($($codexSkills.Count) skills)" -ForegroundColor Green
} else {
    Write-Host "WARN ($($codexSkills.Count)/8)" -ForegroundColor Yellow
    $warnings += "Codex ARIS skills incomplete"
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "All checks passed!" -ForegroundColor Green
} else {
    if ($errors.Count -gt 0) {
        Write-Host "ERRORS ($($errors.Count)):" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
}

Write-Host "Read-only check complete. No processes or files were changed." -ForegroundColor DarkGray
