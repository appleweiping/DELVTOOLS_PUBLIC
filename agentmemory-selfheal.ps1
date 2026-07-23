param(
    [string]$DevToolsRoot,
    [string]$DataRoot,
    [string]$BaseUrl,
    [string]$Config,
    [string]$InstallRoot,
    [string]$NodeExecutable,
    [string]$IiiExecutable,
    [string]$LogDir,
    [string]$ServerScript,
    [string]$PowerShellExecutable,
    [string]$EmbeddingProvider,
    [ValidateRange(1, 300)][int]$HealthTimeoutSeconds = 25,
    [ValidateRange(1, 10)][int]$HealthAttempts = 3,
    [ValidateRange(0, 60)][int]$HealthGapSeconds = 3,
    [ValidateRange(1, 600)][int]$ReloadWaitSeconds = 60,
    [ValidateRange(1, 600)][int]$RestartWaitSeconds = 90,
    [ValidateRange(1, 60)][int]$PollSeconds = 5,
    [ValidateRange(1, 5)][int]$RestartAttempts = 2
)

$ErrorActionPreference = "Continue"
$script:AgentMemoryCanonicalTemplateSha256 = 'ff4753d736c4fe71e3adc0d94bf68b09e77b16a465f9ae140b7a4b9ab506dfa2'

function Get-AgentMemorySelfHealRequiredSecret {
    $secret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    if ([string]::IsNullOrWhiteSpace($secret) -or
        $secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'AGENTMEMORY_SECRET must be a 32-256 character URL-safe secret.'
    }
    return $secret
}

function Resolve-SelfHealPath {
    param(
        [string]$Path,
        [string]$Root,
        [string]$DefaultRelativePath
    )
    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Join-Path $Root $DefaultRelativePath
    } elseif (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $Root $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Test-AgentMemoryCanonicalTemplateBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $digest = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        return [string]::Equals(
            $digest,
            $script:AgentMemoryCanonicalTemplateSha256,
            [System.StringComparison]::Ordinal)
    } catch {
        return $false
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-SelfHealRuntimeConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )

    return [System.IO.Path]::GetFullPath((Join-Path $LogDir ("agentmemory-iii.active.$HttpPort.yaml")))
}

function Get-AgentMemorySelfHealSettings {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$LogDir,
        [string]$ServerScript,
        [string]$PowerShellExecutable,
        [string]$EmbeddingProvider
    )

    $root = $DevToolsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
    $root = [System.IO.Path]::GetFullPath($root)

    $url = $BaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "http://localhost:3111" }
    $url = $url.TrimEnd("/")
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "AGENTMEMORY_URL must be an absolute local HTTP URL."
    }
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @("localhost", "127.0.0.1") -or
        $uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw "Self-heal can manage only a local agentmemory service."
    }
    $url = "http://127.0.0.1:$($uri.Port)"

    $dataPath = $DataRoot
    if ([string]::IsNullOrWhiteSpace($dataPath)) { $dataPath = $env:AGENTMEMORY_DATA_ROOT }
    $dataPath = Resolve-SelfHealPath -Path $dataPath -Root $root -DefaultRelativePath "data"

    $configPath = $Config
    if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = $env:AGENTMEMORY_CONFIG }
    $configPath = Resolve-SelfHealPath -Path $configPath -Root $root -DefaultRelativePath "agentmemory-iii.yaml"

    $packageRoot = $InstallRoot
    if ([string]::IsNullOrWhiteSpace($packageRoot)) { $packageRoot = $env:AGENTMEMORY_INSTALL_ROOT }
    $packageRoot = Resolve-SelfHealPath `
        -Path $packageRoot -Root $root -DefaultRelativePath 'npm-global\agentmemory-runtime'

    $nodePath = $NodeExecutable
    if ([string]::IsNullOrWhiteSpace($nodePath)) { $nodePath = $env:NODE_EXE }
    $nodePath = Resolve-SelfHealPath -Path $nodePath -Root $root -DefaultRelativePath 'node\node.exe'

    $iiiPath = $IiiExecutable
    if ([string]::IsNullOrWhiteSpace($iiiPath)) { $iiiPath = $env:AGENTMEMORY_III_EXE }
    $iiiPath = Resolve-SelfHealPath -Path $iiiPath -Root $packageRoot -DefaultRelativePath 'iii.exe'

    $logs = $LogDir
    if ([string]::IsNullOrWhiteSpace($logs)) { $logs = $env:DEVTOOLS_LOG_DIR }
    $logs = Resolve-SelfHealPath -Path $logs -Root $root -DefaultRelativePath "logs"

    $runtimeConfig = Get-SelfHealRuntimeConfigPath `
        -TemplatePath $configPath `
        -LogDir $logs `
        -HttpPort $uri.Port

    $server = $ServerScript
    if ([string]::IsNullOrWhiteSpace($server)) { $server = $env:AGENTMEMORY_SERVER_SCRIPT }
    $server = Resolve-SelfHealPath -Path $server -Root $root -DefaultRelativePath "agentmemory-server.ps1"

    $guard = Resolve-SelfHealPath `
        -Path $null -Root $root -DefaultRelativePath 'agentmemory-host-guard.mjs'
    $supervisor = Resolve-SelfHealPath `
        -Path $null -Root $root -DefaultRelativePath 'agentmemory-runtime-supervisor.mjs'

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = "powershell.exe" }

    $embedding = $EmbeddingProvider
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = $env:AGENTMEMORY_EMBEDDING_PROVIDER }
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = 'local' }

    [pscustomobject]@{
        DevToolsRoot        = $root
        DataRoot            = $dataPath
        BaseUrl             = $url
        Port                = $uri.Port
        Config              = $configPath
        RuntimeConfig       = $runtimeConfig
        InstallRoot         = $packageRoot
        NodeExecutable      = $nodePath
        IiiExecutable       = $iiiPath
        LogDir              = $logs
        ServerScript        = $server
        GuardScript         = $guard
        SupervisorScript    = $supervisor
        PowerShellExecutable = $shell
        EmbeddingProvider     = $embedding
    }
}

function Get-SelfHealAgentMemoryInstalledVersion {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $manifest = Join-Path $InstallRoot 'node_modules\@agentmemory\agentmemory\package.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw 'The pinned @agentmemory/agentmemory package manifest is missing.'
    }
    try {
        $package = [System.IO.File]::ReadAllText($manifest) | ConvertFrom-Json
    } catch {
        throw 'The agentmemory package manifest is invalid.'
    }
    $version = [string]$package.version
    if ($version -ne '0.9.27') {
        throw "The installed agentmemory version '$version' does not match pinned version 0.9.27."
    }
    return $version
}

function Test-AgentMemoryTemplateContract {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-AgentMemoryCanonicalTemplateBytes -Path $ConfigPath)) { return $false }
    $text = [System.IO.File]::ReadAllText($ConfigPath)
    foreach ($token in @(
            '__AGENTMEMORY_DATA_ROOT_POSIX__',
            '__AGENTMEMORY_HTTP_PORT__',
            '__AGENTMEMORY_INTERNAL_REST_PORT__',
            '__AGENTMEMORY_STREAM_PORT__',
            '__AGENTMEMORY_VIEWER_PORT__',
            '__AGENTMEMORY_ENGINE_PORT__'
        )) {
        if (-not $text.Contains($token)) { return $false }
    }
    if ($text -match '__AGENTMEMORY_(?:INSTALL_ROOT|NODE_EXE|GUARD_SCRIPT|SUPERVISOR_SCRIPT)_POSIX__' -or
        $text -match '(?mi)^\s*(?:-\s*)?name\s*:\s*["'']?iii-exec["'']?\s*(?:#.*)?$' -or
        $text -match '(?mi)^\s*(?:-\s*)?(?:exec|watch)\s*:') {
        return $false
    }
    return $true
}

function Test-SelfHealAgentMemoryInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Test-AgentMemoryHealthOnce {
    param(
        [string]$BaseUrl,
        [string]$Secret,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [int]$TimeoutSeconds = 25
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Secret)) {
            $Secret = Get-AgentMemorySelfHealRequiredSecret
        }
        $healthUri = [System.Uri]$BaseUrl
        $headers = @{ Authorization = "Bearer $Secret" }
        $guard = Invoke-RestMethod `
            -Uri ($BaseUrl.TrimEnd('/') + '/__devtools/agentmemory-host-guard/health') `
            -Headers $headers `
            -TimeoutSec $TimeoutSeconds
        if ($null -eq $guard -or
            $guard.service -isnot [string] -or $guard.service -ne 'devtools-agentmemory-host-guard' -or
            $guard.status -isnot [string] -or $guard.status -ne 'healthy' -or
            $guard.version -isnot [string] -or $guard.version -ne '1' -or
            -not (Test-SelfHealAgentMemoryInteger -Value $guard.listenPort) -or
            [int]$guard.listenPort -ne $healthUri.Port -or
            -not (Test-SelfHealAgentMemoryInteger -Value $guard.upstreamPort) -or
            [int]$guard.upstreamPort -ne 6000) {
            return $false
        }
        $response = Invoke-RestMethod `
            -Uri ($BaseUrl.TrimEnd("/") + "/agentmemory/health") `
            -Headers $headers `
            -TimeoutSec $TimeoutSeconds
        $service = if ($null -ne $response) { $response.PSObject.Properties['service'] } else { $null }
        $status = if ($null -ne $response) { $response.PSObject.Properties['status'] } else { $null }
        $version = if ($null -ne $response) { $response.PSObject.Properties['version'] } else { $null }
        $viewerPort = if ($null -ne $response) { $response.PSObject.Properties['viewerPort'] } else { $null }
        $viewerSkipped = if ($null -ne $response) { $response.PSObject.Properties['viewerSkipped'] } else { $null }
        return ($null -ne $service -and $service.Value -is [string] -and
            $service.Value -eq 'agentmemory' -and
            $null -ne $status -and $status.Value -is [string] -and $status.Value -eq 'healthy' -and
            $null -ne $version -and $version.Value -is [string] -and
            $version.Value -eq $ExpectedVersion -and
            $null -ne $viewerPort -and (Test-SelfHealAgentMemoryInteger -Value $viewerPort.Value) -and
            [int]$viewerPort.Value -eq 6002 -and
            $null -ne $viewerSkipped -and $viewerSkipped.Value -is [bool] -and
            -not [bool]$viewerSkipped.Value)
    } catch {
        return $false
    }
}

function Test-AgentMemoryHealth {
    param(
        [string]$BaseUrl,
        [string]$Secret,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [int]$Attempts = 3,
        [int]$GapSeconds = 3,
        [int]$TimeoutSeconds = 25
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-AgentMemoryHealthOnce `
            -BaseUrl $BaseUrl `
            -Secret $Secret `
            -ExpectedVersion $ExpectedVersion `
                -TimeoutSeconds $TimeoutSeconds) {
            return $true
        }
        if ($attempt -lt $Attempts -and $GapSeconds -gt 0) {
            Start-Sleep -Seconds $GapSeconds
        }
    }
    return $false
}

function Wait-AgentMemoryHealthy {
    param(
        [string]$BaseUrl,
        [string]$Secret,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [int]$MaxSeconds,
        [int]$PollSeconds = 5,
        [int]$TimeoutSeconds = 25
    )
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    do {
        if (Test-AgentMemoryHealthOnce `
                -BaseUrl $BaseUrl `
                -Secret $Secret `
                -ExpectedVersion $ExpectedVersion `
                -TimeoutSeconds $TimeoutSeconds) {
            return $true
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $PollSeconds }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Test-AgentMemoryProcessDescendsFrom {
    param(
        [int]$ProcessId,
        [int[]]$AncestorIds,
        [hashtable]$ProcessMap
    )
    $ancestors = @{}
    foreach ($ancestorId in @($AncestorIds)) { $ancestors[[string]$ancestorId] = $true }
    $seen = @{}
    $currentId = $ProcessId
    while ($currentId -gt 0 -and -not $seen.ContainsKey([string]$currentId)) {
        if ($ancestors.ContainsKey([string]$currentId)) { return $true }
        $seen[[string]$currentId] = $true
        if (-not $ProcessMap.ContainsKey([string]$currentId)) { return $false }
        $currentId = [int]$ProcessMap[[string]$currentId].ParentProcessId
    }
    return $false
}

function Get-AgentMemoryInstanceEvidence {
    param(
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$SupervisorScript,
        [string]$IiiExecutable,
        [ValidateRange(1, 5997)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($SupervisorScript)) {
        $SupervisorScript = Join-Path (Split-Path -Parent $GuardScript) `
            'agentmemory-runtime-supervisor.mjs'
    }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $processMap = @{}
    foreach ($process in $processes) {
        $processMap[[string][int]$process.ProcessId] = $process
    }
    $expectedNode = [System.IO.Path]::GetFullPath($NodeExecutable)
    $matchingSupervisorIds = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $_.Name -eq 'node.exe' -and
            $null -ne $executableProperty -and
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                $expectedNode,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-AgentMemoryRuntimeSupervisorNodeCommandLine `
                -CommandLine $_.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath `
                -GuardScript $GuardScript `
                -SupervisorScript $SupervisorScript `
                -Port $Port)
        } | ForEach-Object { [int]$_.ProcessId })
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        if ($matchingSupervisorIds -contains $processId) {
            $targets.Add([pscustomobject]@{ Id = $processId; Depth = 0 })
            continue
        }
        $depth = 0
        $currentId = $processId
        $seen = @{}
        $matched = $false
        while ($currentId -gt 0 -and -not $seen.ContainsKey([string]$currentId)) {
            $seen[[string]$currentId] = $true
            if (-not $processMap.ContainsKey([string]$currentId)) { break }
            $parentId = [int]$processMap[[string]$currentId].ParentProcessId
            $depth++
            if ($matchingSupervisorIds -contains $parentId) {
                $matched = $true
                break
            }
            $currentId = $parentId
        }
        if ($matched) {
            $targets.Add([pscustomobject]@{ Id = $processId; Depth = $depth })
        }
    }
    $orderedTargetIds = @($targets | Sort-Object Depth -Descending | ForEach-Object { [int]$_.Id })
    $matchingIiiIds = @()
    $validListenerOwnerIds = @()
    $expectedIii = [System.IO.Path]::GetFullPath($IiiExecutable)
    foreach ($supervisorId in $matchingSupervisorIds) {
        $directChildren = @($processes | Where-Object {
                [int]$_.ParentProcessId -eq [int]$supervisorId
            })
        $iiiChildren = @($directChildren | Where-Object {
                $executableProperty = $_.PSObject.Properties['ExecutablePath']
                $_.Name -eq 'iii.exe' -and $null -ne $executableProperty -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                    $expectedIii,
                    [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-AgentMemoryIiiCommandLine `
                    -CommandLine $_.CommandLine `
                    -IiiExecutable $IiiExecutable `
                    -ConfigPath $ConfigPath)
            })
        $agentChildren = @($directChildren | Where-Object {
                $executableProperty = $_.PSObject.Properties['ExecutablePath']
                $_.Name -eq 'node.exe' -and $null -ne $executableProperty -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                    $expectedNode,
                    [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-AgentMemoryServerNodeCommandLine `
                    -CommandLine $_.CommandLine `
                    -NodeExecutable $NodeExecutable `
                    -InstallRoot $InstallRoot)
            })
        $guardChildren = @($directChildren | Where-Object {
                $executableProperty = $_.PSObject.Properties['ExecutablePath']
                $_.Name -eq 'node.exe' -and $null -ne $executableProperty -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                    $expectedNode,
                    [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-AgentMemoryHostGuardNodeCommandLine `
                    -CommandLine $_.CommandLine `
                    -NodeExecutable $NodeExecutable `
                    -GuardScript $GuardScript `
                    -Port $Port)
            })
        $matchingIiiIds += @($iiiChildren | ForEach-Object { [int]$_.ProcessId })
        if ($matchingSupervisorIds.Count -eq 1 -and $directChildren.Count -eq 3 -and
            $iiiChildren.Count -eq 1 -and $agentChildren.Count -eq 1 -and
            $guardChildren.Count -eq 1) {
            $validListenerOwnerIds = @(
                [int]$iiiChildren[0].ProcessId,
                [int]$agentChildren[0].ProcessId,
                [int]$guardChildren[0].ProcessId
            )
        }
    }

    [pscustomobject]@{
        Processes       = $processes
        ProcessMap      = $processMap
        MatchingSupervisorIds = $matchingSupervisorIds
        MatchingIiiIds  = $matchingIiiIds
        TargetIds       = $orderedTargetIds
        ValidListenerOwnerIds = $validListenerOwnerIds
    }
}

function Get-RunningAgentMemoryIiiConfig {
    param(
        [string]$ExpectedConfig,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$IiiExecutable,
        [int]$Port
    )
    $expected = [System.IO.Path]::GetFullPath($ExpectedConfig)
    $evidence = Get-AgentMemoryInstanceEvidence `
        -ConfigPath $expected `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -GuardScript $GuardScript `
        -IiiExecutable $IiiExecutable `
        -Port $Port
    if (@($evidence.MatchingSupervisorIds).Count -gt 0) { return $expected }
    return $null
}

function Set-AgentMemoryReloadMarker {
    param(
        [string]$ConfigPath,
        [string]$Timestamp
    )
    $resolvedConfig = [System.IO.Path]::GetFullPath($ConfigPath)
    $raw = [System.IO.File]::ReadAllText($resolvedConfig)
    $marker = "# selfheal-reload: "
    $lines = $raw -split "`r?`n" | Where-Object { $_ -notmatch ('^' + [regex]::Escape($marker)) }
    $updated = (($lines -join "`r`n").TrimEnd()) + "`r`n$marker$Timestamp`r`n"
    $parent = Split-Path -Parent $resolvedConfig
    $staged = Join-Path $parent ('.agentmemory-reload.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.agentmemory-reload.' + [Guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText($staged, $updated, (New-Object System.Text.UTF8Encoding($false)))
        try {
            [System.IO.File]::Replace($staged, $resolvedConfig, $backup, $true)
        } catch {
            if (-not (Test-Path -LiteralPath $resolvedConfig -PathType Leaf) -and
                (Test-Path -LiteralPath $backup -PathType Leaf)) {
                [System.IO.File]::Move($backup, $resolvedConfig)
            }
            throw
        }
    } finally {
        foreach ($temporaryPath in @($staged, $backup)) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Open-AgentMemorySelfHealLock {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$Port,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )
    $sharedRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'devtools-agentmemory-locks'
    New-Item -ItemType Directory -Path $sharedRoot -Force | Out-Null
    $lockPath = Join-Path $sharedRoot ("selfheal.$Port.lock")
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return New-Object System.IO.FileStream(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for the agentmemory self-heal lock.' }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function Invoke-AgentMemoryServerProcess {
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
        [string]$LogDir,
        [string]$EmbeddingProvider,
        [switch]$ValidateOnly
    )

    $startedProcess = $null
    try {
        $encodeArgument = {
            param([AllowEmptyString()][string]$Value)
            if ($null -eq $Value -or
                $Value.IndexOf([char]0) -ge 0 -or
                $Value.IndexOf("`r") -ge 0 -or
                $Value.IndexOf("`n") -ge 0) {
                throw 'A server-controller argument is invalid.'
            }
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append('"')
            $backslashes = 0
            foreach ($character in $Value.ToCharArray()) {
                if ($character -eq '\') {
                    $backslashes++
                    continue
                }
                if ($character -eq '"') {
                    if ($backslashes -gt 0) {
                        [void]$builder.Append((('\' * ($backslashes * 2)) -join ''))
                    }
                    [void]$builder.Append('\')
                    [void]$builder.Append('"')
                    $backslashes = 0
                    continue
                }
                if ($backslashes -gt 0) {
                    [void]$builder.Append((('\' * $backslashes) -join ''))
                    $backslashes = 0
                }
                [void]$builder.Append($character)
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append((('\' * ($backslashes * 2)) -join ''))
            }
            [void]$builder.Append('"')
            return $builder.ToString()
        }
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $encodeArgument $ServerScript),
            '-DevToolsRoot', (& $encodeArgument $DevToolsRoot),
            '-DataRoot', (& $encodeArgument $DataRoot),
            '-BaseUrl', (& $encodeArgument $BaseUrl),
            '-Config', (& $encodeArgument $Config),
            '-InstallRoot', (& $encodeArgument $InstallRoot),
            '-NodeExecutable', (& $encodeArgument $NodeExecutable),
            '-IiiExecutable', (& $encodeArgument $IiiExecutable),
            '-LogDir', (& $encodeArgument $LogDir),
            '-EmbeddingProvider', (& $encodeArgument $EmbeddingProvider)
        )
        if ($ValidateOnly) { $arguments += '-ValidateOnly' }

        $controllerPort = ([System.Uri]$BaseUrl).Port
        if ($controllerPort -lt 1 -or $controllerPort -gt 5997) {
            throw 'The server-controller port is invalid.'
        }
        $controllerStdout = Join-Path $LogDir "agentmemory-controller.out.$controllerPort.log"
        $controllerStderr = Join-Path $LogDir "agentmemory-controller.err.$controllerPort.log"
        $startedProcess = Start-Process `
            -FilePath $PowerShellExecutable `
            -ArgumentList $arguments `
            -WorkingDirectory $DevToolsRoot `
            -NoNewWindow `
            -RedirectStandardOutput $controllerStdout `
            -RedirectStandardError $controllerStderr `
            -PassThru `
            -ErrorAction Stop
        if ($null -eq $startedProcess -or
            $null -eq $startedProcess.PSObject.Methods['WaitForExit'] -or
            $null -eq $startedProcess.PSObject.Properties['Handle']) {
            return 127
        }
        # Force Process to retain its exact OS handle before the short-lived
        # controller can exit; otherwise ExitCode can be unavailable after a
        # fast exit even though WaitForExit completed.
        $processHandle = $startedProcess.Handle
        if ($null -eq $processHandle -or $processHandle -eq [IntPtr]::Zero) {
            return 127
        }
        $startedProcess.WaitForExit()
        $exitCodeProperty = $startedProcess.PSObject.Properties['ExitCode']
        if ($null -eq $exitCodeProperty -or $null -eq $exitCodeProperty.Value) {
            return 127
        }
        return [int]$exitCodeProperty.Value
    } catch {
        return 127
    } finally {
        if ($null -ne $startedProcess) { $startedProcess.Dispose() }
    }
}

function Test-AgentMemoryServerNodeCommandLine {
    param(
        [string]$CommandLine,
        [string]$NodeExecutable,
        [string]$InstallRoot
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try {
        $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
        $root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    } catch { return $false }
    $normalized = $CommandLine -replace '/', '\'
    $entry = Join-Path $root 'node_modules\@agentmemory\agentmemory\dist\index.mjs'
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($entry) + '"?\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryRuntimeSupervisorNodeCommandLine {
    param(
        [string]$CommandLine,
        [string]$NodeExecutable,
        [string]$InstallRoot,
        [string]$IiiExecutable,
        [string]$ConfigPath,
        [string]$GuardScript,
        [string]$SupervisorScript,
        [ValidateRange(1, 5997)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try {
        $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
        $entry = Join-Path ([System.IO.Path]::GetFullPath($InstallRoot)) `
            'node_modules\@agentmemory\agentmemory\dist\index.mjs'
        $iii = [System.IO.Path]::GetFullPath($IiiExecutable).Replace('/', '\')
        $config = [System.IO.Path]::GetFullPath($ConfigPath).Replace('/', '\')
        $guard = [System.IO.Path]::GetFullPath($GuardScript).Replace('/', '\')
        $supervisor = [System.IO.Path]::GetFullPath($SupervisorScript).Replace('/', '\')
    } catch { return $false }
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($supervisor) + '"?\s+' +
        '--iii-executable\s+"?' + [regex]::Escape($iii) + '"?\s+' +
        '--iii-config\s+"?' + [regex]::Escape($config) + '"?\s+' +
        '--agentmemory-entry\s+"?' + [regex]::Escape($entry) + '"?\s+' +
        '--guard-script\s+"?' + [regex]::Escape($guard) + '"?\s+' +
        '--listen-port\s+' + [string]$Port + '\s+' +
        '--upstream-port\s+6000\s+' +
        '--stream-port\s+6667\s+' +
        '--engine-port\s+10080\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryHostGuardNodeCommandLine {
    param(
        [string]$CommandLine,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [ValidateRange(1, 5997)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try {
        $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
        $guard = [System.IO.Path]::GetFullPath($GuardScript).Replace('/', '\')
    } catch { return $false }
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($guard) + '"?\s+' +
        '--listen-port\s+' + [string]$Port + '\s+' +
        '--upstream-port\s+6000\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryIiiCommandLine {
    param(
        [string]$CommandLine,
        [string]$IiiExecutable,
        [string]$ConfigPath
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    try {
        $iii = [System.IO.Path]::GetFullPath($IiiExecutable).Replace('/', '\')
        $config = [System.IO.Path]::GetFullPath($ConfigPath).Replace('/', '\')
    } catch {
        return $false
    }
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($iii) +
        '"?\s+--config(?:\s+|=)"?' + [regex]::Escape($config) + '"?\s*$'
    return ($normalized -match $pattern)
}

function Get-AgentMemoryStrictOrphanEvidence {
    param(
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$SupervisorScript,
        [string]$IiiExecutable,
        [ValidateRange(1, 5997)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($SupervisorScript)) {
        $SupervisorScript = Join-Path (Split-Path -Parent $GuardScript) `
            'agentmemory-runtime-supervisor.mjs'
    }
    $result = [pscustomobject]@{
        CandidateDetected = $false
        RecoverySafe = $false
        ParentId = $null
        TargetIds = @()
        TargetIdentities = @()
        ValidListenerOwnerIds = @()
    }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $processMap = @{}
    foreach ($process in $processes) {
        $processMap[[string][int]$process.ProcessId] = $process
    }
    try {
        $expectedNode = [System.IO.Path]::GetFullPath($NodeExecutable)
        $expectedIii = [System.IO.Path]::GetFullPath($IiiExecutable)
    } catch {
        return $result
    }

    # An exact live supervisor always owns lifecycle decisions. Orphan recovery
    # is deliberately unavailable when even one such root exists.
    $supervisors = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $matchesExecutable = $false
            if ($null -ne $executableProperty) {
                try {
                    $matchesExecutable = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedNode,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'node.exe' -and $matchesExecutable -and
            (Test-AgentMemoryRuntimeSupervisorNodeCommandLine `
                -CommandLine $_.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath `
                -GuardScript $GuardScript `
                -SupervisorScript $SupervisorScript `
                -Port $Port)
        })
    if ($supervisors.Count -ne 0) { return $result }

    $iiiProcesses = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $matchesExecutable = $false
            if ($null -ne $executableProperty) {
                try {
                    $matchesExecutable = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedIii,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'iii.exe' -and $matchesExecutable -and
            (Test-AgentMemoryIiiCommandLine `
                -CommandLine $_.CommandLine `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath)
        })
    $agentProcesses = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $matchesExecutable = $false
            if ($null -ne $executableProperty) {
                try {
                    $matchesExecutable = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedNode,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'node.exe' -and $matchesExecutable -and
            (Test-AgentMemoryServerNodeCommandLine `
                -CommandLine $_.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot)
        })
    $guardProcesses = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $matchesExecutable = $false
            if ($null -ne $executableProperty) {
                try {
                    $matchesExecutable = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedNode,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'node.exe' -and $matchesExecutable -and
            (Test-AgentMemoryHostGuardNodeCommandLine `
                -CommandLine $_.CommandLine `
                -NodeExecutable $NodeExecutable `
                -GuardScript $GuardScript `
                -Port $Port)
        })
    $candidateCount = $iiiProcesses.Count + $agentProcesses.Count + $guardProcesses.Count
    $result.CandidateDetected = ($candidateCount -gt 0)
    if ($iiiProcesses.Count -ne 1 -or
        $agentProcesses.Count -gt 1 -or $guardProcesses.Count -gt 1) {
        return $result
    }

    $presentProcesses = @()
    foreach ($candidate in @($iiiProcesses) + @($agentProcesses) + @($guardProcesses)) {
        $presentProcesses += $candidate
    }
    $candidateIds = @($presentProcesses | ForEach-Object { [int]$_.ProcessId })
    $parentIds = @(
        $presentProcesses |
            ForEach-Object { [int]$_.ParentProcessId } |
            Select-Object -Unique
    )
    if ($parentIds.Count -ne 1 -or [int]$parentIds[0] -le 0) { return $result }
    $parentId = [int]$parentIds[0]

    # A present parent might be a restarted supervisor or a PID-reuse victim.
    # Either case is ambiguous and must never authorize termination.
    if ($processMap.ContainsKey([string]$parentId)) { return $result }
    $sameParentIds = @($processes | Where-Object {
            [int]$_.ParentProcessId -eq $parentId
        } | ForEach-Object { [int]$_.ProcessId })
    if ($sameParentIds.Count -ne $candidateIds.Count -or
        @($sameParentIds | Where-Object { $candidateIds -notcontains $_ }).Count -ne 0) {
        return $result
    }

    # During startup the vanished supervisor can leave any non-empty subset of
    # its three direct children. Any descendant or extra peer makes that subset
    # impossible to bound safely.
    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        if ($candidateIds -contains $processId) { continue }
        if (Test-AgentMemoryProcessDescendsFrom `
                -ProcessId $processId `
                -AncestorIds $candidateIds `
                -ProcessMap $processMap) {
            return $result
        }
    }

    foreach ($candidate in $presentProcesses) {
        $creationProperty = $candidate.PSObject.Properties['CreationDate']
        if ($null -eq $creationProperty -or $null -eq $creationProperty.Value) {
            return $result
        }
    }
    $iiiProcess = if ($iiiProcesses.Count -eq 1) { $iiiProcesses[0] } else { $null }
    $agentProcess = if ($agentProcesses.Count -eq 1) { $agentProcesses[0] } else { $null }
    $guardProcess = if ($guardProcesses.Count -eq 1) { $guardProcesses[0] } else { $null }
    $listenerContracts = @(
        [pscustomobject]@{ Port=$Port; Address='127.0.0.1'; Process=$guardProcess },
        [pscustomobject]@{ Port=6002; Address='127.0.0.2'; Process=$agentProcess },
        [pscustomobject]@{ Port=6000; Address='127.0.0.1'; Process=$iiiProcess },
        [pscustomobject]@{ Port=6667; Address='127.0.0.1'; Process=$iiiProcess },
        [pscustomobject]@{ Port=10080; Address='127.0.0.1'; Process=$iiiProcess }
    )
    foreach ($contract in $listenerContracts) {
        $listeners = @(
            Get-NetTCPConnection -State Listen -LocalPort $contract.Port -ErrorAction SilentlyContinue
        )
        if ($listeners.Count -eq 0) { continue }
        if ($listeners.Count -ne 1 -or $null -eq $contract.Process) { return $result }
        $portProperty = $listeners[0].PSObject.Properties['LocalPort']
        $addressProperty = $listeners[0].PSObject.Properties['LocalAddress']
        $ownerProperty = $listeners[0].PSObject.Properties['OwningProcess']
        if ($null -eq $portProperty -or [int]$portProperty.Value -ne [int]$contract.Port -or
            $null -eq $addressProperty -or
            [string]$addressProperty.Value -ne [string]$contract.Address -or
            $null -eq $ownerProperty -or
            [int]$ownerProperty.Value -ne [int]$contract.Process.ProcessId) {
            return $result
        }
    }
    foreach ($retiredPort in @(($Port + 1), ($Port + 2), ($Port + 46023))) {
        if (@(Get-NetTCPConnection `
                    -State Listen -LocalPort $retiredPort -ErrorAction SilentlyContinue).Count -ne 0) {
            return $result
        }
    }

    $result.RecoverySafe = $true
    $result.ParentId = $parentId
    # Stop public ingress first when present, then the app and engine.
    $identities = @()
    foreach ($roleAndProcess in @(
            [pscustomobject]@{ Role='guard'; Process=$guardProcess },
            [pscustomobject]@{ Role='agent'; Process=$agentProcess },
            [pscustomobject]@{ Role='iii'; Process=$iiiProcess }
        )) {
        if ($null -eq $roleAndProcess.Process) { continue }
        $identities += [pscustomobject]@{
                Id=[int]$roleAndProcess.Process.ProcessId
                ParentId=$parentId
                Role=[string]$roleAndProcess.Role
                CreationDate=[string]$roleAndProcess.Process.CreationDate
            }
    }
    $result.TargetIdentities = $identities
    $result.TargetIds = @($identities | ForEach-Object { [int]$_.Id })
    $result.ValidListenerOwnerIds = @($result.TargetIds)
    return $result
}

function Test-AgentMemoryStrictOrphanTargetIdentity {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Identity,
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$IiiExecutable,
        [ValidateRange(1, 5997)][int]$Port
    )
    if ([int]$Process.ProcessId -ne [int]$Identity.Id -or
        [int]$Process.ParentProcessId -ne [int]$Identity.ParentId) {
        return $false
    }
    $creationProperty = $Process.PSObject.Properties['CreationDate']
    if ($null -eq $creationProperty -or $null -eq $creationProperty.Value -or
        -not [string]::Equals(
            [string]$creationProperty.Value,
            [string]$Identity.CreationDate,
            [System.StringComparison]::Ordinal)) {
        return $false
    }
    $executableProperty = $Process.PSObject.Properties['ExecutablePath']
    if ($null -eq $executableProperty) { return $false }
    try {
        $actualExecutable = [System.IO.Path]::GetFullPath([string]$executableProperty.Value)
        $expectedExecutable = if ([string]$Identity.Role -eq 'iii') {
            [System.IO.Path]::GetFullPath($IiiExecutable)
        } else {
            [System.IO.Path]::GetFullPath($NodeExecutable)
        }
    } catch {
        return $false
    }
    if (-not [string]::Equals(
            $actualExecutable,
            $expectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    switch ([string]$Identity.Role) {
        'iii' {
            return ($Process.Name -eq 'iii.exe' -and
                (Test-AgentMemoryIiiCommandLine `
                    -CommandLine $Process.CommandLine `
                    -IiiExecutable $IiiExecutable `
                    -ConfigPath $ConfigPath))
        }
        'agent' {
            return ($Process.Name -eq 'node.exe' -and
                (Test-AgentMemoryServerNodeCommandLine `
                    -CommandLine $Process.CommandLine `
                    -NodeExecutable $NodeExecutable `
                    -InstallRoot $InstallRoot))
        }
        'guard' {
            return ($Process.Name -eq 'node.exe' -and
                (Test-AgentMemoryHostGuardNodeCommandLine `
                    -CommandLine $Process.CommandLine `
                    -NodeExecutable $NodeExecutable `
                    -GuardScript $GuardScript `
                    -Port $Port))
        }
        default { return $false }
    }
}

function Stop-AgentMemoryStrictOrphanGroup {
    param(
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$SupervisorScript,
        [string]$IiiExecutable,
        [ValidateRange(1, 5997)][int]$Port
    )
    # Re-query immediately before termination so a stale earlier snapshot or
    # reused parent PID cannot authorize a stop.
    $evidence = Get-AgentMemoryStrictOrphanEvidence `
        -ConfigPath $ConfigPath `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -GuardScript $GuardScript `
        -SupervisorScript $SupervisorScript `
        -IiiExecutable $IiiExecutable `
        -Port $Port
    $result = [pscustomobject]@{
        CandidateDetected = [bool]$evidence.CandidateDetected
        Stopped = $false
    }
    if (-not $evidence.RecoverySafe) { return $result }
    $identities = @($evidence.TargetIdentities)
    for ($index = 0; $index -lt $identities.Count; $index++) {
        $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $snapshotMap = @{}
        foreach ($process in $snapshot) {
            $snapshotMap[[string][int]$process.ProcessId] = $process
        }
        if ($snapshotMap.ContainsKey([string][int]$evidence.ParentId)) {
            return $result
        }
        $knownIds = @($identities | ForEach-Object { [int]$_.Id })
        $sameParentIds = @($snapshot | Where-Object {
                [int]$_.ParentProcessId -eq [int]$evidence.ParentId
            } | ForEach-Object { [int]$_.ProcessId })
        if (@($sameParentIds | Where-Object { $knownIds -notcontains $_ }).Count -ne 0) {
            return $result
        }
        foreach ($remainingIdentity in @($identities[$index..($identities.Count - 1)])) {
            if (-not $snapshotMap.ContainsKey([string][int]$remainingIdentity.Id) -or
                -not (Test-AgentMemoryStrictOrphanTargetIdentity `
                    -Process $snapshotMap[[string][int]$remainingIdentity.Id] `
                    -Identity $remainingIdentity `
                    -ConfigPath $ConfigPath `
                    -InstallRoot $InstallRoot `
                    -NodeExecutable $NodeExecutable `
                    -GuardScript $GuardScript `
                    -IiiExecutable $IiiExecutable `
                    -Port $Port)) {
                return $result
            }
        }
        foreach ($process in $snapshot) {
            $processId = [int]$process.ProcessId
            if ($knownIds -contains $processId) { continue }
            if (Test-AgentMemoryProcessDescendsFrom `
                    -ProcessId $processId `
                    -AncestorIds $knownIds `
                    -ProcessMap $snapshotMap) {
                return $result
            }
        }
        Stop-Process -Id ([int]$identities[$index].Id) -Force -ErrorAction SilentlyContinue
        $identityGone = $false
        foreach ($probe in 1..30) {
            $current = @(
                Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { [int]$_.ProcessId -eq [int]$identities[$index].Id }
            )
            if ($current.Count -eq 0) {
                $identityGone = $true
                break
            }
            if ($current.Count -ne 1 -or
                -not (Test-AgentMemoryStrictOrphanTargetIdentity `
                    -Process $current[0] `
                    -Identity $identities[$index] `
                    -ConfigPath $ConfigPath `
                    -InstallRoot $InstallRoot `
                    -NodeExecutable $NodeExecutable `
                    -GuardScript $GuardScript `
                    -IiiExecutable $IiiExecutable `
                    -Port $Port)) {
                # The original identity is gone but its PID was reused. Never
                # target the replacement and never continue a partial cleanup.
                return $result
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $identityGone) { return $result }
    }
    $shutdownComplete = $false
    $allManagedPorts = @(
        $Port, 6002, 6000, 6667, 10080,
        ($Port + 1), ($Port + 2), ($Port + 46023)
    )
    foreach ($probe in 1..30) {
        $remainingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $identityStillPresent = $false
        foreach ($identity in $identities) {
            if (@($remainingProcesses | Where-Object {
                        [int]$_.ProcessId -eq [int]$identity.Id
                    }).Count -ne 0) {
                $identityStillPresent = $true
                break
            }
        }
        $occupiedPort = $false
        if (-not $identityStillPresent) {
            foreach ($managedPort in $allManagedPorts) {
                if (@(Get-NetTCPConnection `
                            -State Listen -LocalPort $managedPort -ErrorAction SilentlyContinue).Count -ne 0) {
                    $occupiedPort = $true
                    break
                }
            }
        }
        if (-not $identityStillPresent -and -not $occupiedPort) {
            $shutdownComplete = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $shutdownComplete) { return $result }
    $result.Stopped = $true
    return $result
}

function Stop-AgentMemoryProcessGroup {
    param(
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$IiiExecutable,
        [int]$Port
    )
    $evidence = Get-AgentMemoryInstanceEvidence `
        -ConfigPath $ConfigPath `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -GuardScript $GuardScript `
        -IiiExecutable $IiiExecutable `
        -Port $Port
    foreach ($targetId in $evidence.TargetIds) {
        Stop-Process -Id $targetId -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AgentMemorySelfHeal {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$LogDir,
        [string]$ServerScript,
        [string]$PowerShellExecutable,
        [string]$EmbeddingProvider,
        [int]$HealthTimeoutSeconds = 25,
        [int]$HealthAttempts = 3,
        [int]$HealthGapSeconds = 3,
        [int]$ReloadWaitSeconds = 60,
        [int]$RestartWaitSeconds = 90,
        [int]$PollSeconds = 5,
        [int]$RestartAttempts = 2
    )

    $settings = Get-AgentMemorySelfHealSettings `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -LogDir $LogDir `
        -ServerScript $ServerScript `
        -PowerShellExecutable $PowerShellExecutable `
        -EmbeddingProvider $EmbeddingProvider

    if (-not (Test-Path -LiteralPath $settings.ServerScript -PathType Leaf)) {
        throw 'The agentmemory server controller script is missing.'
    }
    if (-not (Test-Path -LiteralPath $settings.IiiExecutable -PathType Leaf)) {
        throw 'The pinned iii executable is missing.'
    }
    if (-not (Test-Path -LiteralPath $settings.NodeExecutable -PathType Leaf)) {
        throw 'The trusted Node executable is missing.'
    }
    if (-not (Test-Path -LiteralPath $settings.GuardScript -PathType Leaf)) {
        throw 'The tracked agentmemory Host guard is missing.'
    }
    if (-not (Test-Path -LiteralPath $settings.SupervisorScript -PathType Leaf)) {
        throw 'The tracked agentmemory runtime supervisor is missing.'
    }
    $agentMemoryEntry = Join-Path $settings.InstallRoot `
        'node_modules\@agentmemory\agentmemory\dist\index.mjs'
    if (-not (Test-Path -LiteralPath $agentMemoryEntry -PathType Leaf)) {
        throw 'The pinned agentmemory runtime entry is missing.'
    }
    $expectedVersion = Get-SelfHealAgentMemoryInstalledVersion -InstallRoot $settings.InstallRoot
    $secret = Get-AgentMemorySelfHealRequiredSecret
    $shellCommand = Get-Command $settings.PowerShellExecutable -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $settings.PowerShellExecutable = [string]$shellCommand.Source

    $controllerLock = $null
    try {
        $controllerLock = Open-AgentMemorySelfHealLock -Port $settings.Port

    New-Item -ItemType Directory -Path $settings.LogDir -Force | Out-Null
    $logPath = Join-Path $settings.LogDir "agentmemory-selfheal.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $notes = New-Object System.Collections.Generic.List[string]
    if (-not (Test-AgentMemoryTemplateContract -ConfigPath $settings.Config)) {
        $line = "[$timestamp] CONFIG-MISSING-OR-INVALID | health=STILL-FAILING"
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        Write-Output $line
        return 1
    }
    $notes.Add("config-ok")

    # Run bounded orphan recovery even when public ingress never started. A
    # supervisor killed during startup may leave only iii or one Node child.
    $orphanStopResult = Stop-AgentMemoryStrictOrphanGroup `
        -ConfigPath $settings.RuntimeConfig `
        -InstallRoot $settings.InstallRoot `
        -NodeExecutable $settings.NodeExecutable `
        -GuardScript $settings.GuardScript `
        -SupervisorScript $settings.SupervisorScript `
        -IiiExecutable $settings.IiiExecutable `
        -Port $settings.Port
    if ($orphanStopResult.CandidateDetected -and -not $orphanStopResult.Stopped) {
        $notes.Add('strict-orphan-recovery-unverified')
        $notes.Add('health=STILL-FAILING')
        $line = "[$timestamp] " + ($notes -join ' | ')
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        Write-Output $line
        return 1
    }
    $strictOrphanStopped = [bool]$orphanStopResult.Stopped
    if ($strictOrphanStopped) { $notes.Add('strict-orphan-group-stopped') }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $settings.Port -ErrorAction SilentlyContinue)
    $listening = $listeners.Count
    $initialContractProven = $false
    if ($listening -gt 0) {
        # First reject configuration drift without contacting the service.
        $configValidationExit = Invoke-AgentMemoryServerProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -ServerScript $settings.ServerScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -LogDir $settings.LogDir `
            -EmbeddingProvider $settings.EmbeddingProvider `
            -ValidateOnly
        if ($configValidationExit -ne 0) {
            $notes.Add('runtime-config-unverified')
            $notes.Add('health=STILL-FAILING')
            $line = "[$timestamp] " + ($notes -join ' | ')
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Output $line
            return 1
        }
        $ownershipEvidence = Get-AgentMemoryInstanceEvidence `
            -ConfigPath $settings.RuntimeConfig `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -GuardScript $settings.GuardScript `
            -IiiExecutable $settings.IiiExecutable `
            -Port $settings.Port
        $listenerOwned = $true
        $singleExactSupervisor = (@($ownershipEvidence.MatchingSupervisorIds).Count -eq 1)
        foreach ($listener in $listeners) {
            $ownerProperty = $listener.PSObject.Properties['OwningProcess']
            if ($null -eq $ownerProperty -or
                ($ownershipEvidence.ValidListenerOwnerIds -notcontains [int]$ownerProperty.Value -and
                    (-not $singleExactSupervisor -or
                        $ownershipEvidence.TargetIds -notcontains [int]$ownerProperty.Value))) {
                $listenerOwned = $false
                break
            }
        }
        if (-not $listenerOwned) {
            $notes.Add('runtime-ownership-unverified')
            $notes.Add('health=STILL-FAILING')
            $line = "[$timestamp] " + ($notes -join ' | ')
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Output $line
            return 1
        }
        # The server inspector proves the complete listener/process contract
        # before it transmits AGENTMEMORY_SECRET. A failed proof authorizes no
        # health probe, but an exact owned tree may still be recovered below.
        $contractInspectionExit = Invoke-AgentMemoryServerProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -ServerScript $settings.ServerScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -LogDir $settings.LogDir `
            -EmbeddingProvider $settings.EmbeddingProvider
        $initialContractProven = ($contractInspectionExit -eq 0)
        if (-not $initialContractProven) {
            $notes.Add('runtime-listener-contract-unhealthy')
        }
    }
    if ($listening -eq 0) {
        $stoppedEvidence = Get-AgentMemoryInstanceEvidence `
            -ConfigPath $settings.RuntimeConfig `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -GuardScript $settings.GuardScript `
            -IiiExecutable $settings.IiiExecutable `
            -Port $settings.Port
        if (-not $strictOrphanStopped -and
            @($stoppedEvidence.MatchingSupervisorIds).Count -gt 1) {
            $notes.Add('multiple-runtime-supervisors-unverified')
            $notes.Add('health=STILL-FAILING')
            $line = "[$timestamp] " + ($notes -join ' | ')
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Output $line
            return 1
        }
        if (-not $strictOrphanStopped -and
            @($stoppedEvidence.MatchingSupervisorIds).Count -eq 1) {
            Stop-AgentMemoryProcessGroup `
                -ConfigPath $settings.RuntimeConfig `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -GuardScript $settings.GuardScript `
                -IiiExecutable $settings.IiiExecutable `
                -Port $settings.Port
            Start-Sleep -Seconds 3
            $notes.Add('partial-runtime-group-stopped')
        }
        $startExit = Invoke-AgentMemoryServerProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -ServerScript $settings.ServerScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -LogDir $settings.LogDir `
            -EmbeddingProvider $settings.EmbeddingProvider
        $healthy = $false
        if ($startExit -eq 0) {
            $healthy = Wait-AgentMemoryHealthy `
                -BaseUrl $settings.BaseUrl `
                -Secret $secret `
                -ExpectedVersion $expectedVersion `
                -MaxSeconds $RestartWaitSeconds `
                -PollSeconds $PollSeconds `
                -TimeoutSeconds $HealthTimeoutSeconds
        }
        $notes.Add("service-was-down-restarted(healthy=$healthy)")
        $listening = @(Get-NetTCPConnection -State Listen -LocalPort $settings.Port -ErrorAction SilentlyContinue).Count
    } else {
        $notes.Add("service-up")
        $healthy = $false
        if ($initialContractProven) {
            $healthy = Test-AgentMemoryHealth `
                -BaseUrl $settings.BaseUrl `
                -Secret $secret `
                -ExpectedVersion $expectedVersion `
                -Attempts $HealthAttempts `
                -GapSeconds $HealthGapSeconds `
                -TimeoutSeconds $HealthTimeoutSeconds
        }
    }

    if ($healthy -and $listening -gt 0) {
        $contractExit = Invoke-AgentMemoryServerProcess `
            -PowerShellExecutable $settings.PowerShellExecutable `
            -ServerScript $settings.ServerScript `
            -DevToolsRoot $settings.DevToolsRoot `
            -DataRoot $settings.DataRoot `
            -BaseUrl $settings.BaseUrl `
            -Config $settings.Config `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -IiiExecutable $settings.IiiExecutable `
            -LogDir $settings.LogDir `
            -EmbeddingProvider $settings.EmbeddingProvider
        if ($contractExit -ne 0) {
            $healthy = $false
            $notes.Add('runtime-listener-contract-unhealthy')
        }
    }

    if (-not $healthy -and $listening -gt 0) {
        $liveConfig = Get-RunningAgentMemoryIiiConfig `
            -ExpectedConfig $settings.RuntimeConfig `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -GuardScript $settings.GuardScript `
            -IiiExecutable $settings.IiiExecutable `
            -Port $settings.Port
        if ($liveConfig -and (Test-Path -LiteralPath $liveConfig -PathType Leaf)) {
            Set-AgentMemoryReloadMarker -ConfigPath $liveConfig -Timestamp $timestamp
            $contractExit = Invoke-AgentMemoryServerProcess `
                -PowerShellExecutable $settings.PowerShellExecutable `
                -ServerScript $settings.ServerScript `
                -DevToolsRoot $settings.DevToolsRoot `
                -DataRoot $settings.DataRoot `
                -BaseUrl $settings.BaseUrl `
                -Config $settings.Config `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -IiiExecutable $settings.IiiExecutable `
                -LogDir $settings.LogDir `
                -EmbeddingProvider $settings.EmbeddingProvider
            $healthy = $false
            if ($contractExit -eq 0) {
                $healthy = Wait-AgentMemoryHealthy `
                    -BaseUrl $settings.BaseUrl `
                    -Secret $secret `
                    -ExpectedVersion $expectedVersion `
                    -MaxSeconds $ReloadWaitSeconds `
                    -PollSeconds $PollSeconds `
                    -TimeoutSeconds $HealthTimeoutSeconds
            } else {
                $notes.Add('post-reload-listener-contract-unhealthy')
            }
            $notes.Add("app-layer-hot-reloaded(healthy=$healthy)")
        }
    }

    if (-not $healthy) {
        $postReloadListeners = @(
            Get-NetTCPConnection -State Listen -LocalPort $settings.Port -ErrorAction SilentlyContinue
        )
        $restartEvidence = Get-AgentMemoryInstanceEvidence `
            -ConfigPath $settings.RuntimeConfig `
            -InstallRoot $settings.InstallRoot `
            -NodeExecutable $settings.NodeExecutable `
            -GuardScript $settings.GuardScript `
            -IiiExecutable $settings.IiiExecutable `
            -Port $settings.Port

        $postReloadListenerOwned = $true
        $singleExactSupervisor = (@($restartEvidence.MatchingSupervisorIds).Count -eq 1)
        foreach ($listener in $postReloadListeners) {
            $ownerProperty = $listener.PSObject.Properties['OwningProcess']
            if ($null -eq $ownerProperty -or
                ($restartEvidence.ValidListenerOwnerIds -notcontains [int]$ownerProperty.Value -and
                    (-not $singleExactSupervisor -or
                        $restartEvidence.TargetIds -notcontains [int]$ownerProperty.Value))) {
                $postReloadListenerOwned = $false
                break
            }
        }
        if (-not $postReloadListenerOwned) {
            $notes.Add('restart-ownership-unverified')
            $notes.Add('health=STILL-FAILING')
            $line = "[$timestamp] " + ($notes -join ' | ')
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Output $line
            return 1
        }

        if ($postReloadListeners.Count -eq 0 -and
            @($restartEvidence.MatchingSupervisorIds).Count -eq 0) {
            $startExit = Invoke-AgentMemoryServerProcess `
                -PowerShellExecutable $settings.PowerShellExecutable `
                -ServerScript $settings.ServerScript `
                -DevToolsRoot $settings.DevToolsRoot `
                -DataRoot $settings.DataRoot `
                -BaseUrl $settings.BaseUrl `
                -Config $settings.Config `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -IiiExecutable $settings.IiiExecutable `
                -LogDir $settings.LogDir `
                -EmbeddingProvider $settings.EmbeddingProvider
            if ($startExit -eq 0) {
                $healthy = Wait-AgentMemoryHealthy `
                    -BaseUrl $settings.BaseUrl `
                    -Secret $secret `
                    -ExpectedVersion $expectedVersion `
                    -MaxSeconds $RestartWaitSeconds `
                    -PollSeconds $PollSeconds `
                    -TimeoutSeconds $HealthTimeoutSeconds
            }
            if ($healthy) {
                $contractExit = Invoke-AgentMemoryServerProcess `
                    -PowerShellExecutable $settings.PowerShellExecutable `
                    -ServerScript $settings.ServerScript `
                    -DevToolsRoot $settings.DevToolsRoot `
                    -DataRoot $settings.DataRoot `
                    -BaseUrl $settings.BaseUrl `
                    -Config $settings.Config `
                    -InstallRoot $settings.InstallRoot `
                    -NodeExecutable $settings.NodeExecutable `
                    -IiiExecutable $settings.IiiExecutable `
                    -LogDir $settings.LogDir `
                    -EmbeddingProvider $settings.EmbeddingProvider
                if ($contractExit -ne 0) {
                    $healthy = $false
                    $notes.Add('post-reload-start-listener-contract-unhealthy')
                }
            }
            $notes.Add("reload-exit-restarted(healthy=$healthy)")
        }

        if ($healthy) {
            $restartEvidence = $null
        } else {
            $restartEvidence = Get-AgentMemoryInstanceEvidence `
                -ConfigPath $settings.RuntimeConfig `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -GuardScript $settings.GuardScript `
                -IiiExecutable $settings.IiiExecutable `
                -Port $settings.Port
        }
        if (-not $healthy -and @($restartEvidence.MatchingSupervisorIds).Count -ne 1) {
            $notes.Add('restart-ownership-unverified')
            $notes.Add('health=STILL-FAILING')
            $line = "[$timestamp] " + ($notes -join ' | ')
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Output $line
            return 1
        }
        if ($healthy) {
            $notes.Add('restart-not-required')
        } else {
        foreach ($attempt in 1..$RestartAttempts) {
            Stop-AgentMemoryProcessGroup `
                -ConfigPath $settings.RuntimeConfig `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -GuardScript $settings.GuardScript `
                -IiiExecutable $settings.IiiExecutable `
                -Port $settings.Port
            Start-Sleep -Seconds 3
            $restartStartExit = Invoke-AgentMemoryServerProcess `
                -PowerShellExecutable $settings.PowerShellExecutable `
                -ServerScript $settings.ServerScript `
                -DevToolsRoot $settings.DevToolsRoot `
                -DataRoot $settings.DataRoot `
                -BaseUrl $settings.BaseUrl `
                -Config $settings.Config `
                -InstallRoot $settings.InstallRoot `
                -NodeExecutable $settings.NodeExecutable `
                -IiiExecutable $settings.IiiExecutable `
                -LogDir $settings.LogDir `
                -EmbeddingProvider $settings.EmbeddingProvider
            $healthy = $false
            if ($restartStartExit -eq 0) {
                $healthy = Wait-AgentMemoryHealthy `
                    -BaseUrl $settings.BaseUrl `
                    -Secret $secret `
                    -ExpectedVersion $expectedVersion `
                    -MaxSeconds $RestartWaitSeconds `
                    -PollSeconds $PollSeconds `
                    -TimeoutSeconds $HealthTimeoutSeconds
            }
            if ($healthy) {
                $contractExit = Invoke-AgentMemoryServerProcess `
                    -PowerShellExecutable $settings.PowerShellExecutable `
                    -ServerScript $settings.ServerScript `
                    -DevToolsRoot $settings.DevToolsRoot `
                    -DataRoot $settings.DataRoot `
                    -BaseUrl $settings.BaseUrl `
                    -Config $settings.Config `
                    -InstallRoot $settings.InstallRoot `
                    -NodeExecutable $settings.NodeExecutable `
                    -IiiExecutable $settings.IiiExecutable `
                    -LogDir $settings.LogDir `
                    -EmbeddingProvider $settings.EmbeddingProvider
                if ($contractExit -ne 0) {
                    $healthy = $false
                    $notes.Add('post-restart-listener-contract-unhealthy')
                }
            }
            $notes.Add("full-restart#$attempt(healthy=$healthy)")
            if ($healthy) { break }
            Start-Sleep -Seconds 10
        }
        }
    }

    $healthLabel = if ($healthy) { "healthy" } else { "STILL-FAILING" }
    $notes.Add("health=$healthLabel")
    $line = "[$timestamp] " + ($notes -join " | ")
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8

    Write-Output $line
    if ($healthy) { return 0 }
    return 1
    } finally {
        if ($null -ne $controllerLock) { $controllerLock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AgentMemorySelfHeal `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -LogDir $LogDir `
        -ServerScript $ServerScript `
        -PowerShellExecutable $PowerShellExecutable `
        -EmbeddingProvider $EmbeddingProvider `
        -HealthTimeoutSeconds $HealthTimeoutSeconds `
        -HealthAttempts $HealthAttempts `
        -HealthGapSeconds $HealthGapSeconds `
        -ReloadWaitSeconds $ReloadWaitSeconds `
        -RestartWaitSeconds $RestartWaitSeconds `
        -PollSeconds $PollSeconds `
        -RestartAttempts $RestartAttempts)
}
