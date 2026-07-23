param(
    [string]$DevToolsRoot,
    [string]$DataRoot,
    [string]$BaseUrl,
    [string]$Config,
    [string]$InstallRoot,
    [string]$NodeExecutable,
    [string]$IiiExecutable,
    [string]$EmbeddingProvider,
    [string]$LogDir,
    [string]$LogPath,
    [string]$SelfHealScript,
    [string]$ServerScript,
    [string]$PowerShellExecutable,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 25,
    [ValidateRange(0, 300)][int]$RecoveryDelaySeconds = 5,
    [ValidateRange(1, 1000)][int]$MinimumMcpTools = 40
)

$ErrorActionPreference = "Stop"

function Get-AgentMemoryDailyRequiredSecret {
    $secret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    if ([string]::IsNullOrWhiteSpace($secret) -or
        $secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'AGENTMEMORY_SECRET must be a 32-256 character URL-safe secret.'
    }
    return $secret
}

function Get-AgentMemoryCanonicalDailyBaseUrl {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $candidate = $BaseUrl.TrimEnd('/')
    $uri = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost', '127.0.0.1') -or
        $uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw 'The daily health check can inspect only an explicit local agentmemory endpoint.'
    }
    return "http://127.0.0.1:$($uri.Port)"
}

function Test-AgentMemoryDailyInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Get-AgentMemoryDailySettings {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$EmbeddingProvider,
        [string]$LogDir,
        [string]$LogPath,
        [string]$SelfHealScript,
        [string]$ServerScript,
        [string]$PowerShellExecutable
    )

    $root = $DevToolsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
    $root = [System.IO.Path]::GetFullPath($root)

    $url = $BaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "http://localhost:3111" }
    $url = Get-AgentMemoryCanonicalDailyBaseUrl -BaseUrl $url

    $log = $LogPath
    if ([string]::IsNullOrWhiteSpace($log)) { $log = $env:AGENTMEMORY_HEALTH_LOG }
    if ([string]::IsNullOrWhiteSpace($log)) {
        $logDir = if ($env:DEVTOOLS_LOG_DIR) { $env:DEVTOOLS_LOG_DIR } else { Join-Path $root "logs" }
        $log = Join-Path $logDir "agentmemory-health-errors.log"
    } elseif (-not [System.IO.Path]::IsPathRooted($log)) {
        $log = Join-Path $root $log
    }
    $log = [System.IO.Path]::GetFullPath($log)

    $selfHeal = $SelfHealScript
    if ([string]::IsNullOrWhiteSpace($selfHeal)) { $selfHeal = $env:AGENTMEMORY_SELFHEAL_SCRIPT }
    if ([string]::IsNullOrWhiteSpace($selfHeal)) { $selfHeal = Join-Path $root "agentmemory-selfheal.ps1" }
    if (-not [System.IO.Path]::IsPathRooted($selfHeal)) { $selfHeal = Join-Path $root $selfHeal }
    $selfHeal = [System.IO.Path]::GetFullPath($selfHeal)

    $server = $ServerScript
    if ([string]::IsNullOrWhiteSpace($server)) { $server = $env:AGENTMEMORY_SERVER_SCRIPT }
    if ([string]::IsNullOrWhiteSpace($server)) { $server = Join-Path $root 'agentmemory-server.ps1' }
    elseif (-not [System.IO.Path]::IsPathRooted($server)) { $server = Join-Path $root $server }
    $server = [System.IO.Path]::GetFullPath($server)

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = "powershell.exe" }

    [pscustomobject]@{
        DevToolsRoot         = $root
        DataRoot             = $DataRoot
        BaseUrl              = $url
        Config               = $Config
        InstallRoot          = $InstallRoot
        NodeExecutable       = $NodeExecutable
        IiiExecutable        = $IiiExecutable
        EmbeddingProvider    = $EmbeddingProvider
        LogDir               = $LogDir
        LogPath              = $log
        SelfHealScript       = $selfHeal
        ServerScript         = $server
        PowerShellExecutable = $shell
    }
}

function Test-AgentMemoryEndpoint {
    param(
        [string]$Name,
        [string]$Path,
        [string]$BaseUrl,
        [string]$Secret,
        [int[]]$AllowedStatus = @(200),
        [int]$TimeoutSeconds = 25
    )

    $BaseUrl = Get-AgentMemoryCanonicalDailyBaseUrl -BaseUrl $BaseUrl
    if ([string]::IsNullOrWhiteSpace($Secret)) {
        $Secret = Get-AgentMemoryDailyRequiredSecret
    }
    $uri = $BaseUrl + "/" + $Path.TrimStart("/")
    try {
        $response = Invoke-WebRequest `
            -Uri $uri `
            -Headers @{ Authorization = "Bearer $Secret" } `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds
        $status = [int]$response.StatusCode
        if ($AllowedStatus -notcontains $status) {
            return "FAIL $Name returned HTTP $status"
        }
        return $null
    } catch {
        $status = "ERR"
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        }
        if ($AllowedStatus -contains $status) { return $null }
        return "FAIL $Name returned HTTP $status"
    }
}

function Get-AgentMemoryCheckFailures {
    param(
        [string]$BaseUrl,
        [string]$Secret,
        [int]$TimeoutSeconds = 25,
        [int]$MinimumMcpTools = 40,
        [string]$ExpectedVersion = '0.9.27'
    )

    $BaseUrl = Get-AgentMemoryCanonicalDailyBaseUrl -BaseUrl $BaseUrl
    if ([string]::IsNullOrWhiteSpace($Secret)) {
        $Secret = Get-AgentMemoryDailyRequiredSecret
    }
    $headers = @{ Authorization = "Bearer $Secret" }
    $failures = New-Object System.Collections.Generic.List[string]

    try {
        $guard = Invoke-RestMethod `
            -Uri ($BaseUrl + '/__devtools/agentmemory-host-guard/health') `
            -Headers $headers `
            -Method Get `
            -TimeoutSec $TimeoutSeconds
        $expectedPort = ([System.Uri]$BaseUrl).Port
        if ($null -eq $guard -or
            $guard.service -isnot [string] -or $guard.service -ne 'devtools-agentmemory-host-guard' -or
            $guard.status -isnot [string] -or $guard.status -ne 'healthy' -or
            $guard.version -isnot [string] -or $guard.version -ne '1' -or
            -not (Test-AgentMemoryDailyInteger -Value $guard.listenPort) -or
            [int]$guard.listenPort -ne $expectedPort -or
            -not (Test-AgentMemoryDailyInteger -Value $guard.upstreamPort) -or
            [int]$guard.upstreamPort -ne 6000) {
            $failures.Add('FAIL authenticated Host guard identity mismatch')
        }
    } catch {
        $failures.Add('FAIL authenticated Host guard unavailable')
    }

    try {
        $health = Invoke-RestMethod `
            -Uri ($BaseUrl + '/agentmemory/health') `
            -Headers $headers `
            -Method Get `
            -TimeoutSec $TimeoutSeconds
        $expectedViewerPort = 6002
        if ($null -eq $health -or $health.service -isnot [string] -or
            $health.status -isnot [string] -or $health.version -isnot [string] -or
            $health.service -ne 'agentmemory' -or $health.status -ne 'healthy' -or
            $health.version -ne $ExpectedVersion -or
            $null -eq $health.PSObject.Properties['viewerPort'] -or
            -not (Test-AgentMemoryDailyInteger -Value $health.viewerPort) -or
            [int]$health.viewerPort -ne $expectedViewerPort -or
            $null -eq $health.PSObject.Properties['viewerSkipped'] -or
            $health.viewerSkipped -isnot [bool] -or $health.viewerSkipped) {
            $failures.Add('FAIL health identity, pinned version, or viewer contract mismatch')
        }
    } catch {
        $failures.Add('FAIL health endpoint unavailable')
    }

    try {
        $flags = Invoke-RestMethod `
            -Uri ($BaseUrl + '/agentmemory/config/flags') `
            -Headers $headers `
            -Method Get `
            -TimeoutSec $TimeoutSeconds
        $flagsProperty = if ($null -ne $flags) { $flags.PSObject.Properties['flags'] } else { $null }
        $flagItems = @()
        if ($null -ne $flagsProperty -and $flagsProperty.Value -is [System.Array]) {
            $flagItems = @($flagsProperty.Value)
        }
        $validFlags = ($null -ne $flags -and $flags.version -is [string] -and
            $flags.version -eq $ExpectedVersion -and $null -ne $flagsProperty -and
            $flagsProperty.Value -is [System.Array] -and $flagItems.Count -gt 0)
        foreach ($flag in $flagItems) {
            if ($null -eq $flag -or $flag.key -isnot [string] -or
                [string]::IsNullOrWhiteSpace($flag.key) -or
                $null -eq $flag.PSObject.Properties['enabled'] -or
                $flag.enabled -isnot [bool]) {
                $validFlags = $false
                break
            }
        }
        if (-not $validFlags) { $failures.Add('FAIL config flags schema or version mismatch') }
    } catch {
        $failures.Add('FAIL config flags endpoint unavailable')
    }

    try {
        $tools = Invoke-RestMethod `
            -Uri ($BaseUrl + '/agentmemory/mcp/tools') `
            -Headers $headers `
            -Method Get `
            -TimeoutSec $TimeoutSeconds
        $toolsProperty = if ($null -ne $tools) { $tools.PSObject.Properties['tools'] } else { $null }
        $toolItems = @()
        if ($null -ne $toolsProperty -and $toolsProperty.Value -is [System.Array]) {
            $toolItems = @($toolsProperty.Value)
        }
        $validTools = ($null -ne $toolsProperty -and $toolsProperty.Value -is [System.Array])
        foreach ($tool in $toolItems) {
            $schemaProperty = if ($null -ne $tool) { $tool.PSObject.Properties['inputSchema'] } else { $null }
            $schema = if ($null -ne $schemaProperty) { $schemaProperty.Value } else { $null }
            if ($null -eq $tool -or $tool.name -isnot [string] -or
                [string]::IsNullOrWhiteSpace($tool.name) -or $null -eq $schema -or
                $null -eq $schema.PSObject.Properties['type'] -or
                $schema.type -isnot [string] -or $schema.type -ne 'object') {
                $validTools = $false
                break
            }
        }
        if (-not $validTools) {
            $failures.Add('FAIL MCP proxy tools schema mismatch')
        } elseif ($toolItems.Count -lt $MinimumMcpTools) {
            $toolCount = $toolItems.Count
            $failures.Add("DEGRADED MCP proxy exposed only $toolCount tools; expected at least $MinimumMcpTools.")
        }
    } catch {
        $failures.Add("FAIL MCP proxy tool count check failed")
    }

    try {
        $slots = Invoke-RestMethod `
            -Uri ($BaseUrl + '/agentmemory/slots') `
            -Headers $headers `
            -Method Get `
            -TimeoutSec $TimeoutSeconds
        $slotsProperty = if ($null -ne $slots) { $slots.PSObject.Properties['slots'] } else { $null }
        $validSlots = ($null -ne $slots -and $slots.success -is [bool] -and $slots.success -and
            $null -ne $slotsProperty -and $slotsProperty.Value -is [System.Array])
        if ($validSlots) {
            foreach ($slot in @($slotsProperty.Value)) {
                if ($null -eq $slot -or $slot.label -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($slot.label) -or
                    $slot.scope -isnot [string] -or $slot.pinned -isnot [bool] -or
                    -not (Test-AgentMemoryDailyInteger -Value $slot.sizeLimit) -or
                    $slot.content -isnot [string]) {
                    $validSlots = $false
                    break
                }
            }
        }
        if (-not $validSlots) {
            $failures.Add('FAIL slots schema or enabled-state mismatch')
        }
    } catch {
        $failures.Add('FAIL slots endpoint unavailable')
    }

    return @($failures | ForEach-Object { $_ })
}

function Invoke-AgentMemorySelfHealProcess {
    param(
        [string]$PowerShellExecutable,
        [string]$SelfHealScript,
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$EmbeddingProvider,
        [string]$LogDir,
        [string]$ServerScript
    )
    if (-not (Test-Path -LiteralPath $SelfHealScript -PathType Leaf)) {
        throw "Self-heal script is missing."
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SelfHealScript)
    $overrides = [ordered]@{
        DevToolsRoot = $DevToolsRoot
        DataRoot = $DataRoot
        BaseUrl = $BaseUrl
        Config = $Config
        InstallRoot = $InstallRoot
        NodeExecutable = $NodeExecutable
        IiiExecutable = $IiiExecutable
        EmbeddingProvider = $EmbeddingProvider
        LogDir = $LogDir
        ServerScript = $ServerScript
        PowerShellExecutable = $PowerShellExecutable
    }
    foreach ($entry in $overrides.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $arguments += '-' + [string]$entry.Key
            $arguments += [string]$entry.Value
        }
    }
    $global:LASTEXITCODE = $null
    & $PowerShellExecutable @arguments | Out-Null
    $invocationSucceeded = $?
    $exitCode = $global:LASTEXITCODE
    if (-not $invocationSucceeded -or $null -eq $exitCode) { return 127 }
    return [int]$exitCode
}

function Invoke-AgentMemoryInspectionProcess {
    param(
        [string]$PowerShellExecutable,
        [string]$ServerScript,
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$EmbeddingProvider,
        [string]$LogDir
    )
    if (-not (Test-Path -LiteralPath $ServerScript -PathType Leaf)) {
        return 127
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ServerScript)
    $overrides = [ordered]@{
        DevToolsRoot = $DevToolsRoot
        DataRoot = $DataRoot
        BaseUrl = $BaseUrl
        Config = $Config
        InstallRoot = $InstallRoot
        NodeExecutable = $NodeExecutable
        IiiExecutable = $IiiExecutable
        EmbeddingProvider = $EmbeddingProvider
        LogDir = $LogDir
    }
    foreach ($entry in $overrides.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $arguments += '-' + [string]$entry.Key
            $arguments += [string]$entry.Value
        }
    }
    $arguments += '-InspectOnly'
    $global:LASTEXITCODE = $null
    & $PowerShellExecutable @arguments | Out-Null
    $invocationSucceeded = $?
    $exitCode = $global:LASTEXITCODE
    if (-not $invocationSucceeded -or $null -eq $exitCode) { return 127 }
    return [int]$exitCode
}

function Write-AgentMemoryDailyLog {
    param(
        [string]$LogPath,
        [string]$Message
    )
    $parent = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $Message -Encoding UTF8
}

function Invoke-AgentMemoryDailyCheck {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$EmbeddingProvider,
        [string]$LogDir,
        [string]$LogPath,
        [string]$SelfHealScript,
        [string]$ServerScript,
        [string]$PowerShellExecutable,
        [int]$TimeoutSeconds = 25,
        [int]$RecoveryDelaySeconds = 5,
        [int]$MinimumMcpTools = 40
    )

    $settings = Get-AgentMemoryDailySettings `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -EmbeddingProvider $EmbeddingProvider `
        -LogDir $LogDir `
        -LogPath $LogPath `
        -SelfHealScript $SelfHealScript `
        -ServerScript $ServerScript `
        -PowerShellExecutable $PowerShellExecutable
    $secret = Get-AgentMemoryDailyRequiredSecret

    $inspectionExit = Invoke-AgentMemoryInspectionProcess `
        -PowerShellExecutable $settings.PowerShellExecutable `
        -ServerScript $settings.ServerScript `
        -DevToolsRoot $settings.DevToolsRoot `
        -DataRoot $settings.DataRoot `
        -BaseUrl $settings.BaseUrl `
        -Config $settings.Config `
        -InstallRoot $settings.InstallRoot `
        -NodeExecutable $settings.NodeExecutable `
        -IiiExecutable $settings.IiiExecutable `
        -EmbeddingProvider $settings.EmbeddingProvider `
        -LogDir $settings.LogDir
    $runtimeProven = ($inspectionExit -eq 0)
    if ($runtimeProven) {
        $failures = @(Get-AgentMemoryCheckFailures `
            -BaseUrl $settings.BaseUrl `
            -Secret $secret `
            -TimeoutSeconds $TimeoutSeconds `
            -MinimumMcpTools $MinimumMcpTools)
    } else {
        $failures = @('FAIL runtime listeners are not the exact loopback-only pinned process set')
    }
    if ($failures.Count -eq 0) { return 0 }

    # Recovery can replace the listener set. Revoke the previous proof before
    # any mutation and restore it only after a fresh post-recovery inspection.
    $runtimeProven = $false
    try {
        [void](Invoke-AgentMemorySelfHealProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -SelfHealScript $settings.SelfHealScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -EmbeddingProvider $settings.EmbeddingProvider `
            -LogDir $settings.LogDir `
            -ServerScript $settings.ServerScript)
        if ($RecoveryDelaySeconds -gt 0) { Start-Sleep -Seconds $RecoveryDelaySeconds }
        $inspectionExit = Invoke-AgentMemoryInspectionProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -ServerScript $settings.ServerScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -EmbeddingProvider $settings.EmbeddingProvider `
            -LogDir $settings.LogDir
        $runtimeProven = ($inspectionExit -eq 0)
        if ($runtimeProven) {
            $recheck = @(Get-AgentMemoryCheckFailures `
                -BaseUrl $settings.BaseUrl `
                -Secret $secret `
                -TimeoutSeconds $TimeoutSeconds `
                -MinimumMcpTools $MinimumMcpTools)
        } else {
            $recheck = @('FAIL runtime listeners are not the exact loopback-only pinned process set')
        }
        if ($recheck.Count -eq 0) {
            $recovered = "[$((Get-Date).ToString('s'))] health check failed but self-heal recovered: " +
                ($failures -join " | ")
            Write-AgentMemoryDailyLog -LogPath $settings.LogPath -Message $recovered
            return 0
        }
        $failures = $recheck
    } catch {
        $runtimeProven = $false
    }

    $timestamp = (Get-Date).ToString("s")
    $message = "[$timestamp] agentmemory daily health check failed after self-heal: " + ($failures -join " | ")
    Write-AgentMemoryDailyLog -LogPath $settings.LogPath -Message $message

    if ($runtimeProven) {
        try {
            Invoke-RestMethod `
                -Method Post `
                -Uri ($settings.BaseUrl + "/agentmemory/signals/send") `
                -Headers @{ Authorization = "Bearer $secret" } `
                -ContentType "application/json" `
                -TimeoutSec 5 `
                -Body (@{
                    from = "agentmemory-health-daily"
                    to = "all"
                    type = "error"
                    content = $message
                } | ConvertTo-Json -Depth 4) | Out-Null
        } catch {
            Write-AgentMemoryDailyLog `
                -LogPath $settings.LogPath `
                -Message "[$timestamp] signal send failed"
        }
    }

    Write-Error $message -ErrorAction Continue
    return 1
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AgentMemoryDailyCheck `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -EmbeddingProvider $EmbeddingProvider `
        -LogDir $LogDir `
        -LogPath $LogPath `
        -SelfHealScript $SelfHealScript `
        -ServerScript $ServerScript `
        -PowerShellExecutable $PowerShellExecutable `
        -TimeoutSeconds $TimeoutSeconds `
        -RecoveryDelaySeconds $RecoveryDelaySeconds `
        -MinimumMcpTools $MinimumMcpTools)
}
