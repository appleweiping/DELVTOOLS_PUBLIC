# Read-only infrastructure health check for a portable devtools installation.

param(
    [switch]$RequirePixelCat,
    [string]$DevToolsRoot,
    [string]$LauncherRoot,
    [string]$AgentResourcesRoot,
    [string]$ArisSkillRoot,
    [string]$AgentMemoryBaseUrl,
    [string]$AgentMemoryDataRoot,
    [string]$AgentMemoryConfig,
    [string]$AgentMemoryInstallRoot,
    [string]$AgentMemoryNodeExecutable,
    [string]$AgentMemoryIiiExecutable,
    [string]$AgentMemoryLogDir,
    [string]$AgentMemoryEmbeddingProvider,
    [string]$AgentMemoryServerScript,
    [string]$PowerShellExecutable,
    [ValidateRange(1, 300)][int]$RequestTimeoutSeconds = 25,
    [ValidateRange(1, 1000)][int]$MinimumMcpTools = 40,
    [ValidateRange(0, 65535)][int]$AgentMemoryViewerPort = 0,
    [int]$PixelCatPort = 8990,
    [int]$KeyRotatorPort = 9100,
    [int]$RetiredHubPort = 9800
)

function Get-DevToolsAgentMemoryRequiredSecret {
    $secret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    if ([string]::IsNullOrWhiteSpace($secret) -or
        $secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'AGENTMEMORY_SECRET must be a 32-256 character URL-safe secret.'
    }
    return $secret
}

function Resolve-DevToolsHealthPath {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DefaultRelativePath
    )
    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = Join-Path $Root $DefaultRelativePath }
    elseif (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $Root $candidate }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-DevToolsHealthSettings {
    param(
        [string]$DevToolsRoot,
        [string]$LauncherRoot,
        [string]$AgentResourcesRoot,
        [string]$ArisSkillRoot,
        [string]$AgentMemoryBaseUrl,
        [string]$AgentMemoryDataRoot,
        [string]$AgentMemoryConfig,
        [string]$AgentMemoryInstallRoot,
        [string]$AgentMemoryNodeExecutable,
        [string]$AgentMemoryIiiExecutable,
        [string]$AgentMemoryLogDir,
        [string]$AgentMemoryEmbeddingProvider,
        [string]$AgentMemoryServerScript,
        [string]$PowerShellExecutable
    )

    $root = $DevToolsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
    $root = [System.IO.Path]::GetFullPath($root)

    $launcherPath = $LauncherRoot
    if ([string]::IsNullOrWhiteSpace($launcherPath)) { $launcherPath = Join-Path $root "launchers" }
    if (-not [System.IO.Path]::IsPathRooted($launcherPath)) { $launcherPath = Join-Path $root $launcherPath }
    $launcherPath = [System.IO.Path]::GetFullPath($launcherPath)

    $url = $AgentMemoryBaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "http://localhost:3111" }
    $url = $url.TrimEnd("/")
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "AGENTMEMORY_URL must be an absolute local HTTP URL."
    }
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost', '127.0.0.1') -or
        $uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw "AGENTMEMORY_URL must identify the supported local agentmemory endpoint."
    }
    $url = "http://127.0.0.1:$($uri.Port)"

    $resourceRoot = $AgentResourcesRoot
    if ([string]::IsNullOrWhiteSpace($resourceRoot)) { $resourceRoot = $env:DEVTOOLS_AGENT_RESOURCES_ROOT }
    if ([string]::IsNullOrWhiteSpace($resourceRoot)) { $resourceRoot = $env:AGENT_RESOURCES_ROOT }
    if ([string]::IsNullOrWhiteSpace($resourceRoot)) {
        $driveRoot = [System.IO.Path]::GetPathRoot($root)
        $resourceRoot = Join-Path $driveRoot "AGENT_RESOURCE"
    } elseif (-not [System.IO.Path]::IsPathRooted($resourceRoot)) {
        $resourceRoot = Join-Path $root $resourceRoot
    }
    $resourceRoot = [System.IO.Path]::GetFullPath($resourceRoot)

    $skills = $ArisSkillRoot
    if ([string]::IsNullOrWhiteSpace($skills)) { $skills = $env:DEVTOOLS_ARIS_SKILL_ROOT }
    if ([string]::IsNullOrWhiteSpace($skills)) { $skills = Join-Path $resourceRoot ".codex\skills" }
    elseif (-not [System.IO.Path]::IsPathRooted($skills)) { $skills = Join-Path $resourceRoot $skills }
    $skills = [System.IO.Path]::GetFullPath($skills)

    $dataPath = $AgentMemoryDataRoot
    if ([string]::IsNullOrWhiteSpace($dataPath)) { $dataPath = $env:AGENTMEMORY_DATA_ROOT }
    $dataPath = Resolve-DevToolsHealthPath -Path $dataPath -Root $root -DefaultRelativePath 'data'

    $configPath = $AgentMemoryConfig
    if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = $env:AGENTMEMORY_CONFIG }
    $configPath = Resolve-DevToolsHealthPath `
        -Path $configPath -Root $root -DefaultRelativePath 'agentmemory-iii.yaml'

    $installRoot = $AgentMemoryInstallRoot
    if ([string]::IsNullOrWhiteSpace($installRoot)) { $installRoot = $env:AGENTMEMORY_INSTALL_ROOT }
    $installRoot = Resolve-DevToolsHealthPath `
        -Path $installRoot -Root $root -DefaultRelativePath 'npm-global\agentmemory-runtime'

    $nodePath = $AgentMemoryNodeExecutable
    if ([string]::IsNullOrWhiteSpace($nodePath)) { $nodePath = $env:NODE_EXE }
    $nodePath = Resolve-DevToolsHealthPath -Path $nodePath -Root $root -DefaultRelativePath 'node\node.exe'

    $iiiPath = $AgentMemoryIiiExecutable
    if ([string]::IsNullOrWhiteSpace($iiiPath)) { $iiiPath = $env:AGENTMEMORY_III_EXE }
    if ([string]::IsNullOrWhiteSpace($iiiPath)) { $iiiPath = Join-Path $installRoot 'iii.exe' }
    elseif (-not [System.IO.Path]::IsPathRooted($iiiPath)) { $iiiPath = Join-Path $installRoot $iiiPath }
    $iiiPath = [System.IO.Path]::GetFullPath($iiiPath)

    $logPath = $AgentMemoryLogDir
    if ([string]::IsNullOrWhiteSpace($logPath)) { $logPath = $env:DEVTOOLS_LOG_DIR }
    $logPath = Resolve-DevToolsHealthPath -Path $logPath -Root $root -DefaultRelativePath 'logs'

    $serverPath = $AgentMemoryServerScript
    if ([string]::IsNullOrWhiteSpace($serverPath)) { $serverPath = $env:AGENTMEMORY_SERVER_SCRIPT }
    $serverPath = Resolve-DevToolsHealthPath `
        -Path $serverPath -Root $root -DefaultRelativePath 'agentmemory-server.ps1'

    $embedding = $AgentMemoryEmbeddingProvider
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = $env:AGENTMEMORY_EMBEDDING_PROVIDER }
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = 'local' }

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = 'powershell.exe' }
    $shell = [string](Get-Command $shell -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source

    $runtimeConfig = Join-Path $logPath ("agentmemory-iii.active.$($uri.Port).yaml")
    $runtimeConfig = [System.IO.Path]::GetFullPath($runtimeConfig)

    $launcherNames = @(
        "cc.cmd",
        "claude.cmd",
        "codex.cmd",
        "gemini.cmd",
        "opencode.cmd",
        "claudeseek.cmd",
        "aris.cmd",
        "hermes.cmd",
        "pixelcat.cmd"
    )
    $launchers = @($launcherNames | ForEach-Object { Join-Path $launcherPath $_ })
    $launchers += Join-Path $root "agentmemory-server.cmd"

    [pscustomobject]@{
        DevToolsRoot            = $root
        LauncherRoot            = $launcherPath
        AgentResourcesRoot      = $resourceRoot
        ArisSkillRoot           = $skills
        AgentMemoryBaseUrl      = $url
        AgentMemoryHost         = '127.0.0.1'
        AgentMemoryPort         = $uri.Port
        AgentMemoryViewerHost   = '127.0.0.2'
        AgentMemoryViewerPort   = 6002
        AgentMemoryIiiExecutable = $iiiPath
        AgentMemoryDataRoot       = $dataPath
        AgentMemoryConfig         = $configPath
        AgentMemoryInstallRoot    = $installRoot
        AgentMemoryNodeExecutable = $nodePath
        AgentMemoryLogDir         = $logPath
        AgentMemoryEmbeddingProvider = $embedding
        AgentMemoryServerScript   = $serverPath
        AgentMemoryRuntimeConfig  = $runtimeConfig
        PowerShellExecutable      = $shell
        Launchers               = $launchers
    }
}

function Test-DevToolsJsonInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Test-DevToolsAgentMemoryHealthResponse {
    param(
        $Response,
        [Parameter(Mandatory = $true)][int]$ExpectedViewerPort
    )
    if ($null -eq $Response) { return $false }
    return ($Response.service -is [string] -and $Response.service -eq 'agentmemory' -and
        $Response.status -is [string] -and $Response.status -eq 'healthy' -and
        $Response.version -is [string] -and $Response.version -eq '0.9.27' -and
        $null -ne $Response.PSObject.Properties['viewerPort'] -and
        (Test-DevToolsJsonInteger -Value $Response.viewerPort) -and
        [int]$Response.viewerPort -eq $ExpectedViewerPort -and
        $null -ne $Response.PSObject.Properties['viewerSkipped'] -and
        $Response.viewerSkipped -is [bool] -and -not $Response.viewerSkipped)
}

function Test-DevToolsAgentMemoryGuardResponse {
    param(
        $Response,
        [Parameter(Mandatory = $true)][int]$ExpectedPort
    )
    if ($null -eq $Response) { return $false }
    return ($Response.service -is [string] -and
        $Response.service -eq 'devtools-agentmemory-host-guard' -and
        $Response.status -is [string] -and $Response.status -eq 'healthy' -and
        $Response.version -is [string] -and $Response.version -eq '1' -and
        $null -ne $Response.PSObject.Properties['listenPort'] -and
        (Test-DevToolsJsonInteger -Value $Response.listenPort) -and
        [int]$Response.listenPort -eq $ExpectedPort -and
        $null -ne $Response.PSObject.Properties['upstreamPort'] -and
        (Test-DevToolsJsonInteger -Value $Response.upstreamPort) -and
        [int]$Response.upstreamPort -eq 6000)
}

function Test-DevToolsAgentMemorySlotsResponse {
    param($Response)
    if ($null -eq $Response -or $Response.success -isnot [bool] -or -not $Response.success) {
        return $false
    }
    $property = $Response.PSObject.Properties['slots']
    if ($null -eq $property -or $property.Value -isnot [System.Array]) { return $false }
    foreach ($slot in @($property.Value)) {
        if ($null -eq $slot -or $slot.label -isnot [string] -or
            [string]::IsNullOrWhiteSpace($slot.label) -or $slot.scope -isnot [string] -or
            $slot.pinned -isnot [bool] -or
            -not (Test-DevToolsJsonInteger -Value $slot.sizeLimit) -or
            $slot.content -isnot [string]) {
            return $false
        }
    }
    return $true
}

function Test-DevToolsAgentMemoryToolsResponse {
    param(
        $Response,
        [Parameter(Mandatory = $true)][int]$MinimumTools
    )
    if ($null -eq $Response) { return $false }
    $property = $Response.PSObject.Properties['tools']
    if ($null -eq $property -or $property.Value -isnot [System.Array]) { return $false }
    $items = @($property.Value)
    if ($items.Count -lt $MinimumTools) { return $false }
    foreach ($tool in $items) {
        $schemaProperty = if ($null -ne $tool) { $tool.PSObject.Properties['inputSchema'] } else { $null }
        $schema = if ($null -ne $schemaProperty) { $schemaProperty.Value } else { $null }
        if ($null -eq $tool -or $tool.name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($tool.name) -or $null -eq $schema -or
            $null -eq $schema.PSObject.Properties['type'] -or
            $schema.type -isnot [string] -or $schema.type -ne 'object') {
            return $false
        }
    }
    return $true
}

function Invoke-DevToolsAgentMemoryInspection {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellExecutable,
        [Parameter(Mandatory = $true)][string]$ServerScript,
        [Parameter(Mandatory = $true)][string]$DevToolsRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$EmbeddingProvider,
        [Parameter(Mandatory = $true)][string]$LogDir
    )
    if (-not (Test-Path -LiteralPath $ServerScript -PathType Leaf)) { return 127 }
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ServerScript,
        '-DevToolsRoot', $DevToolsRoot,
        '-DataRoot', $DataRoot,
        '-BaseUrl', $BaseUrl,
        '-Config', $Config,
        '-InstallRoot', $InstallRoot,
        '-NodeExecutable', $NodeExecutable,
        '-IiiExecutable', $IiiExecutable,
        '-EmbeddingProvider', $EmbeddingProvider,
        '-LogDir', $LogDir,
        '-InspectOnly'
    )
    $global:LASTEXITCODE = $null
    & $PowerShellExecutable @arguments | Out-Null
    $invocationSucceeded = $?
    $exitCode = $global:LASTEXITCODE
    if (-not $invocationSucceeded -or $null -eq $exitCode) { return 127 }
    return [int]$exitCode
}

function Invoke-DevToolsHealthCheck {
    param(
        [switch]$RequirePixelCat,
        [string]$DevToolsRoot,
        [string]$LauncherRoot,
        [string]$AgentResourcesRoot,
        [string]$ArisSkillRoot,
        [string]$AgentMemoryBaseUrl,
        [string]$AgentMemoryDataRoot,
        [string]$AgentMemoryConfig,
        [string]$AgentMemoryInstallRoot,
        [string]$AgentMemoryNodeExecutable,
        [string]$AgentMemoryIiiExecutable,
        [string]$AgentMemoryLogDir,
        [string]$AgentMemoryEmbeddingProvider,
        [string]$AgentMemoryServerScript,
        [string]$PowerShellExecutable,
        [int]$RequestTimeoutSeconds = 25,
        [int]$MinimumMcpTools = 40,
        [ValidateRange(0, 65535)][int]$AgentMemoryViewerPort = 0,
        [int]$PixelCatPort = 8990,
        [int]$KeyRotatorPort = 9100,
        [int]$RetiredHubPort = 9800
    )

    $settings = Get-DevToolsHealthSettings `
        -DevToolsRoot $DevToolsRoot `
        -LauncherRoot $LauncherRoot `
        -AgentResourcesRoot $AgentResourcesRoot `
        -ArisSkillRoot $ArisSkillRoot `
        -AgentMemoryBaseUrl $AgentMemoryBaseUrl `
        -AgentMemoryDataRoot $AgentMemoryDataRoot `
        -AgentMemoryConfig $AgentMemoryConfig `
        -AgentMemoryInstallRoot $AgentMemoryInstallRoot `
        -AgentMemoryNodeExecutable $AgentMemoryNodeExecutable `
        -AgentMemoryIiiExecutable $AgentMemoryIiiExecutable `
        -AgentMemoryLogDir $AgentMemoryLogDir `
        -AgentMemoryEmbeddingProvider $AgentMemoryEmbeddingProvider `
        -AgentMemoryServerScript $AgentMemoryServerScript `
        -PowerShellExecutable $PowerShellExecutable
    $agentMemorySecret = Get-DevToolsAgentMemoryRequiredSecret
    $agentMemoryHeaders = @{ Authorization = "Bearer $agentMemorySecret" }
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($AgentMemoryViewerPort -gt 0 -and
        $AgentMemoryViewerPort -ne $settings.AgentMemoryViewerPort) {
        throw 'AgentMemoryViewerPort is fixed at 6002 by the authenticated viewer contract.'
    }
    $viewerPort = $settings.AgentMemoryViewerPort

    function Test-LocalPort {
        param(
            [string]$Name,
            [string]$ComputerName,
            [int]$Port,
            [switch]$Required
        )
        Write-Host -NoNewline "$Name ($ComputerName`:$Port)... "
        try {
            $result = Test-NetConnection $ComputerName -Port $Port -WarningAction SilentlyContinue
            if ($result.TcpTestSucceeded) {
                Write-Host "OK" -ForegroundColor Green
                return
            }
        } catch { }

        if ($Required) {
            Write-Host "FAIL" -ForegroundColor Red
            $errors.Add("$Name is not listening on $ComputerName`:$Port")
        } else {
            Write-Host "WARN" -ForegroundColor Yellow
            $warnings.Add("$Name is not listening on $ComputerName`:$Port")
        }
    }

    Write-Host "=== Agent Infrastructure Health Check ===" -ForegroundColor Cyan
    Write-Host ""

    Test-LocalPort `
        -Name "agentmemory" `
        -ComputerName $settings.AgentMemoryHost `
        -Port $settings.AgentMemoryPort `
        -Required

    Write-Host -NoNewline "agentmemory full runtime contract... "
    $inspectionExit = Invoke-DevToolsAgentMemoryInspection `
        -PowerShellExecutable $settings.PowerShellExecutable `
        -ServerScript $settings.AgentMemoryServerScript `
        -DevToolsRoot $settings.DevToolsRoot `
        -DataRoot $settings.AgentMemoryDataRoot `
        -BaseUrl $settings.AgentMemoryBaseUrl `
        -Config $settings.AgentMemoryConfig `
        -InstallRoot $settings.AgentMemoryInstallRoot `
        -NodeExecutable $settings.AgentMemoryNodeExecutable `
        -IiiExecutable $settings.AgentMemoryIiiExecutable `
        -EmbeddingProvider $settings.AgentMemoryEmbeddingProvider `
        -LogDir $settings.AgentMemoryLogDir
    if ($inspectionExit -eq 0) {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "FAIL" -ForegroundColor Red
        $errors.Add('agentmemory full runtime contract inspection failed')
    }

    if ($inspectionExit -eq 0) {
        Write-Host -NoNewline "agentmemory Host guard... "
        try {
            $guard = Invoke-RestMethod `
                -Uri ($settings.AgentMemoryBaseUrl + '/__devtools/agentmemory-host-guard/health') `
                -Headers $agentMemoryHeaders `
                -Method Get `
                -TimeoutSec $RequestTimeoutSeconds
            if (Test-DevToolsAgentMemoryGuardResponse `
                    -Response $guard `
                    -ExpectedPort $settings.AgentMemoryPort) {
                Write-Host 'OK' -ForegroundColor Green
            } else {
                throw 'Unexpected Host guard identity or state'
            }
        } catch {
            Write-Host 'FAIL' -ForegroundColor Red
            $errors.Add('agentmemory authenticated Host guard failed')
        }

        Write-Host -NoNewline "agentmemory health endpoint... "
        try {
            $health = Invoke-RestMethod `
                -Uri ($settings.AgentMemoryBaseUrl + "/agentmemory/health") `
                -Headers $agentMemoryHeaders `
                -Method Get `
                -TimeoutSec $RequestTimeoutSeconds
            if (Test-DevToolsAgentMemoryHealthResponse `
                    -Response $health `
                    -ExpectedViewerPort $settings.AgentMemoryViewerPort) {
                Write-Host "OK" -ForegroundColor Green
            } else {
                throw "Unexpected health identity, state, or version"
            }
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            $errors.Add("agentmemory health endpoint failed")
        }

        Write-Host -NoNewline "agentmemory slots... "
        try {
            $slotResult = Invoke-RestMethod `
                -Uri ($settings.AgentMemoryBaseUrl + "/agentmemory/slots") `
                -Headers $agentMemoryHeaders `
                -Method Get `
                -TimeoutSec $RequestTimeoutSeconds
            if (Test-DevToolsAgentMemorySlotsResponse -Response $slotResult) {
                Write-Host "OK ($(@($slotResult.slots).Count) slots)" -ForegroundColor Green
            } else {
                throw "Unexpected slots response"
            }
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            $errors.Add("agentmemory slots endpoint failed; restart with AGENTMEMORY_SLOTS=true")
        }

        Write-Host -NoNewline "agentmemory MCP proxy tools... "
        try {
            $toolResult = Invoke-RestMethod `
                -Uri ($settings.AgentMemoryBaseUrl + "/agentmemory/mcp/tools") `
                -Headers $agentMemoryHeaders `
                -Method Get `
                -TimeoutSec $RequestTimeoutSeconds
            $toolItems = @($toolResult.tools)
            $toolCount = $toolItems.Count
            if (Test-DevToolsAgentMemoryToolsResponse `
                    -Response $toolResult `
                    -MinimumTools $MinimumMcpTools) {
                Write-Host "OK ($toolCount tools)" -ForegroundColor Green
            } else {
                Write-Host "FAIL ($toolCount tools)" -ForegroundColor Red
                $errors.Add("agentmemory MCP proxy schema/count mismatch ($toolCount tools; expected at least $MinimumMcpTools)")
            }
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            $errors.Add("agentmemory MCP proxy tools endpoint failed")
        }
    } else {
        Write-Host 'Authenticated endpoint probes skipped because runtime ownership is unproven.' -ForegroundColor Yellow
    }

    Test-LocalPort `
        -Name "agentmemory viewer" `
        -ComputerName $settings.AgentMemoryViewerHost `
        -Port $viewerPort
    $pixelCatRequired = $RequirePixelCat -or
        $env:DEVTOOLS_REQUIRE_PIXELCAT -eq "1" -or
        $env:DEVTOOLS_MODE -eq "cc"
    Test-LocalPort `
        -Name "PixelCat for Claude" `
        -ComputerName "localhost" `
        -Port $PixelCatPort `
        -Required:$pixelCatRequired
    Test-LocalPort -Name "key rotator" -ComputerName "localhost" -Port $KeyRotatorPort

    Write-Host -NoNewline "Agent Hub retired... "
    try {
        $hub = Test-NetConnection localhost -Port $RetiredHubPort -WarningAction SilentlyContinue
    } catch {
        $hub = $null
    }
    if ($hub -and $hub.TcpTestSucceeded) {
        Write-Host "WARN" -ForegroundColor Yellow
        $warnings.Add("Retired Agent Hub appears to be listening on port $RetiredHubPort")
    } else {
        Write-Host "OK" -ForegroundColor Green
    }

    Write-Host -NoNewline "agent resources... "
    if (Test-Path -LiteralPath (Join-Path $settings.AgentResourcesRoot "SKILL-INDEX.md") -PathType Leaf) {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "FAIL" -ForegroundColor Red
        $errors.Add("SKILL-INDEX.md was not found under DEVTOOLS_AGENT_RESOURCES_ROOT")
    }

    Write-Host -NoNewline "agent-home junctions... "
    $junctions = @(
        (Join-Path $env:USERPROFILE ".claude"),
        (Join-Path $env:USERPROFILE ".codex")
    )
    $junctionsOk = $true
    foreach ($junction in $junctions) {
        $item = Get-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.LinkType -ne "Junction") {
            $junctionsOk = $false
            $warnings.Add("An expected agent-home junction is missing")
        }
    }
    if ($junctionsOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "WARN" -ForegroundColor Yellow }

    Write-Host -NoNewline "CLI launchers... "
    $launchersOk = $true
    foreach ($launcher in $settings.Launchers) {
        if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
            $launchersOk = $false
            $warnings.Add("Missing launcher: $([System.IO.Path]::GetFileName($launcher))")
        }
    }
    if ($launchersOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "WARN" -ForegroundColor Yellow }

    Write-Host -NoNewline "Codex ARIS skills... "
    $codexSkills = @(Get-ChildItem (Join-Path $settings.ArisSkillRoot "aris-*") -Directory -ErrorAction SilentlyContinue)
    if ($codexSkills.Count -ge 8) {
        Write-Host "OK ($($codexSkills.Count) skills)" -ForegroundColor Green
    } else {
        Write-Host "WARN ($($codexSkills.Count)/8)" -ForegroundColor Yellow
        $warnings.Add("Codex ARIS skills incomplete")
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

    [pscustomobject]@{
        ExitCode = if ($errors.Count -eq 0) { 0 } else { 1 }
        Errors   = @($errors)
        Warnings = @($warnings)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DevToolsHealthCheck `
        -RequirePixelCat:$RequirePixelCat `
        -DevToolsRoot $DevToolsRoot `
        -LauncherRoot $LauncherRoot `
        -AgentResourcesRoot $AgentResourcesRoot `
        -ArisSkillRoot $ArisSkillRoot `
        -AgentMemoryBaseUrl $AgentMemoryBaseUrl `
        -AgentMemoryDataRoot $AgentMemoryDataRoot `
        -AgentMemoryConfig $AgentMemoryConfig `
        -AgentMemoryInstallRoot $AgentMemoryInstallRoot `
        -AgentMemoryNodeExecutable $AgentMemoryNodeExecutable `
        -AgentMemoryIiiExecutable $AgentMemoryIiiExecutable `
        -AgentMemoryLogDir $AgentMemoryLogDir `
        -AgentMemoryEmbeddingProvider $AgentMemoryEmbeddingProvider `
        -AgentMemoryServerScript $AgentMemoryServerScript `
        -PowerShellExecutable $PowerShellExecutable `
        -RequestTimeoutSeconds $RequestTimeoutSeconds `
        -MinimumMcpTools $MinimumMcpTools `
        -AgentMemoryViewerPort $AgentMemoryViewerPort `
        -PixelCatPort $PixelCatPort `
        -KeyRotatorPort $KeyRotatorPort `
        -RetiredHubPort $RetiredHubPort
    exit $result.ExitCode
}
