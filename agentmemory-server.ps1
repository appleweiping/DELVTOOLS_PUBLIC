param(
    [string]$DevToolsRoot,
    [string]$DataRoot,
    [string]$BaseUrl,
    [string]$Config,
    [string]$InstallRoot,
    [string]$NodeExecutable,
    [string]$IiiExecutable,
    [string]$LogDir,
    [string]$EmbeddingProvider,
    [int]$LogRetentionDays = 14,
    [ValidateRange(1, 600)][int]$StartupWaitSeconds = 90,
    [switch]$ValidateOnly,
    [switch]$InspectOnly
)

$ErrorActionPreference = "Stop"

$script:AgentMemoryInternalRestPort = 6000
$script:DevToolsAgentMemoryViewerHost = '127.0.0.2'
$script:DevToolsAgentMemoryViewerPort = 6002
$script:DevToolsAgentMemoryViewerAuthority = 'agentmemory-viewer.invalid:6002'
$script:AgentMemoryInternalStreamPort = 6667
$script:AgentMemoryInternalEnginePort = 10080
$script:AgentMemoryHostGuardVersion = '1'
$script:AgentMemoryCanonicalTemplateSha256 = 'ff4753d736c4fe71e3adc0d94bf68b09e77b16a465f9ae140b7a4b9ab506dfa2'

function Get-AgentMemoryRequiredSecret {
    $secret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    if ([string]::IsNullOrWhiteSpace($secret) -or
        $secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'AGENTMEMORY_SECRET must be a 32-256 character URL-safe secret.'
    }
    return $secret
}

function Resolve-AgentMemoryPath {
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

function Get-AgentMemoryRuntimeConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )

    return [System.IO.Path]::GetFullPath((Join-Path $LogDir ("agentmemory-iii.active.$HttpPort.yaml")))
}

function Get-AgentMemoryMaterializedConfig {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$GuardScript,
        [string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )

    $resolvedTemplate = [System.IO.Path]::GetFullPath($TemplatePath)
    if (-not (Test-Path -LiteralPath $resolvedTemplate -PathType Leaf)) {
        throw 'The canonical agentmemory config template is missing.'
    }
    if (-not (Test-AgentMemoryCanonicalTemplateBytes -Path $resolvedTemplate)) {
        throw 'The agentmemory config template bytes do not match the reviewed canonical template.'
    }

    $tokens = [ordered]@{
        '__AGENTMEMORY_DATA_ROOT_POSIX__' = $null
        '__AGENTMEMORY_HTTP_PORT__' = [string]$HttpPort
        '__AGENTMEMORY_INTERNAL_REST_PORT__' = [string]$script:AgentMemoryInternalRestPort
        '__AGENTMEMORY_STREAM_PORT__' = [string]$script:AgentMemoryInternalStreamPort
        '__AGENTMEMORY_VIEWER_PORT__' = [string]$script:DevToolsAgentMemoryViewerPort
        '__AGENTMEMORY_ENGINE_PORT__' = [string]$script:AgentMemoryInternalEnginePort
    }
    $template = [System.IO.File]::ReadAllText($resolvedTemplate)
    foreach ($token in $tokens.Keys) {
        if (-not $template.Contains($token)) {
            throw 'The bundled agentmemory config template is missing a required token.'
        }
    }
    if ($template -match '__AGENTMEMORY_(?:INSTALL_ROOT|NODE_EXE|GUARD_SCRIPT|SUPERVISOR_SCRIPT)_POSIX__' -or
        $template -match '(?mi)^\s*(?:-\s*)?name\s*:\s*["'']?iii-exec["'']?\s*(?:#.*)?$' -or
        $template -match '(?mi)^\s*(?:-\s*)?(?:exec|watch)\s*:') {
        throw 'The canonical iii template must not launch or watch external runtime processes.'
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { [void]$strictUtf8.GetBytes($DataRoot) } catch {
        throw 'AGENTMEMORY_DATA_ROOT contains invalid Unicode.'
    }
    $rawDataRoot = [string]$DataRoot
    $hasForbiddenUnicode = $false
    foreach ($forbiddenCodePoint in @(0x85, 0x2028, 0x2029, 0xfffe, 0xffff)) {
        if ($rawDataRoot.IndexOf([char]$forbiddenCodePoint) -ge 0) {
            $hasForbiddenUnicode = $true
            break
        }
    }
    if ($rawDataRoot.Contains([string][char]34) -or $rawDataRoot.Contains('$') -or
        $rawDataRoot -match '[\x00-\x1f\x7f]' -or $hasForbiddenUnicode) {
        throw 'AGENTMEMORY_DATA_ROOT cannot be represented safely in the agentmemory config.'
    }
    $portableDataRoot = [System.IO.Path]::GetFullPath($rawDataRoot).Replace('\', '/')
    foreach ($token in $tokens.Keys) {
        if ($portableDataRoot.Contains([string]$token)) {
            throw 'AGENTMEMORY_DATA_ROOT cannot contain an agentmemory template token.'
        }
    }
    $tokens['__AGENTMEMORY_DATA_ROOT_POSIX__'] = $portableDataRoot

    $materialized = $template
    foreach ($token in $tokens.Keys) {
        $materialized = $materialized.Replace([string]$token, [string]$tokens[$token])
    }
    if ($materialized -match '__AGENTMEMORY_[A-Z0-9_]+__') {
        throw 'The agentmemory config contains an unresolved token.'
    }
    return $materialized
}

function New-AgentMemoryActiveConfig {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$ActivePath,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )

    $resolvedTemplate = [System.IO.Path]::GetFullPath($TemplatePath)
    $resolvedActive = [System.IO.Path]::GetFullPath($ActivePath)
    if ($resolvedTemplate -eq $resolvedActive) {
        throw 'The generated agentmemory config must not overwrite its tracked template.'
    }
    $materialized = Get-AgentMemoryMaterializedConfig `
        -TemplatePath $resolvedTemplate `
        -DataRoot $DataRoot `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -GuardScript $GuardScript `
        -SupervisorScript $SupervisorScript `
        -HttpPort $HttpPort

    $parent = Split-Path -Parent $resolvedActive
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $staged = Join-Path $parent ('.agentmemory-iii.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        [System.IO.File]::WriteAllText($staged, $materialized, $encoding)
        if (Test-Path -LiteralPath $resolvedActive -PathType Leaf) {
            $backup = Join-Path $parent ('.agentmemory-iii.' + [Guid]::NewGuid().ToString('N') + '.bak')
            try {
                [System.IO.File]::Replace($staged, $resolvedActive, $backup, $true)
            } catch {
                if (-not (Test-Path -LiteralPath $resolvedActive -PathType Leaf) -and
                    (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    [System.IO.File]::Move($backup, $resolvedActive)
                }
                throw
            } finally {
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    [System.IO.File]::Delete($backup)
                }
            }
        } else {
            [System.IO.File]::Move($staged, $resolvedActive)
        }
    } finally {
        if (Test-Path -LiteralPath $staged -PathType Leaf) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-AgentMemoryIiiUsesConfig {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$ConfigPath
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

function Test-AgentMemoryNodeUsesEntry {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
    $entry = Join-Path `
        ([System.IO.Path]::GetFullPath($InstallRoot)) `
        'node_modules\@agentmemory\agentmemory\dist\index.mjs'
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($entry) + '"?\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryNodeUsesGuard {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
    $guard = [System.IO.Path]::GetFullPath($GuardScript).Replace('/', '\')
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($guard) + '"?\s+' +
        '--listen-port\s+' + [string]$HttpPort + '\s+' +
        '--upstream-port\s+' + [string]$script:AgentMemoryInternalRestPort + '\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryNodeUsesSupervisor {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [Parameter(Mandatory = $true)][string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $node = [System.IO.Path]::GetFullPath($NodeExecutable).Replace('/', '\')
    $entry = Join-Path `
        ([System.IO.Path]::GetFullPath($InstallRoot)) `
        'node_modules\@agentmemory\agentmemory\dist\index.mjs'
    $guard = [System.IO.Path]::GetFullPath($GuardScript).Replace('/', '\')
    $supervisor = [System.IO.Path]::GetFullPath($SupervisorScript).Replace('/', '\')
    $iii = [System.IO.Path]::GetFullPath($IiiExecutable).Replace('/', '\')
    $config = [System.IO.Path]::GetFullPath($ConfigPath).Replace('/', '\')
    $normalized = $CommandLine.Replace('/', '\')
    $pattern = '^\s*"?' + [regex]::Escape($node) +
        '"?\s+"?' + [regex]::Escape($supervisor) + '"?\s+' +
        '--iii-executable\s+"?' + [regex]::Escape($iii) + '"?\s+' +
        '--iii-config\s+"?' + [regex]::Escape($config) + '"?\s+' +
        '--agentmemory-entry\s+"?' + [regex]::Escape($entry) + '"?\s+' +
        '--guard-script\s+"?' + [regex]::Escape($guard) + '"?\s+' +
        '--listen-port\s+' + [string]$HttpPort + '\s+' +
        '--upstream-port\s+' + [string]$script:AgentMemoryInternalRestPort + '\s+' +
        '--stream-port\s+' + [string]$script:AgentMemoryInternalStreamPort + '\s+' +
        '--engine-port\s+' + [string]$script:AgentMemoryInternalEnginePort + '\s*$'
    return ($normalized -match $pattern)
}

function Test-AgentMemoryServerProcessDescendsFrom {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][int]$RootProcessId,
        [Parameter(Mandatory = $true)][hashtable]$ProcessMap
    )
    $currentId = $ProcessId
    $seen = @{}
    while ($currentId -gt 0 -and -not $seen.ContainsKey([string]$currentId)) {
        $seen[[string]$currentId] = $true
        if (-not $ProcessMap.ContainsKey([string]$currentId)) { return $false }
        $parentId = [int]$ProcessMap[[string]$currentId].ParentProcessId
        if ($parentId -eq $RootProcessId) { return $true }
        $currentId = $parentId
    }
    return $false
}

function Test-AgentMemoryRuntimeListeners {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
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
    $matchingRoots = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $executableMatches = $false
            if ($null -ne $executableProperty) {
                try {
                    $executableMatches = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedNode,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'node.exe' -and $executableMatches -and
            (Test-AgentMemoryNodeUsesSupervisor `
                -CommandLine $_.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath `
                -GuardScript $GuardScript `
                -SupervisorScript $SupervisorScript `
                -HttpPort $HttpPort)
        })
    if ($matchingRoots.Count -ne 1) { return $false }
    $rootId = [int]$matchingRoots[0].ProcessId

    $expectedIii = [System.IO.Path]::GetFullPath($IiiExecutable)
    $iiiProcesses = @($processes | Where-Object {
            $executableProperty = $_.PSObject.Properties['ExecutablePath']
            $executableMatches = $false
            if ($null -ne $executableProperty) {
                try {
                    $executableMatches = [string]::Equals(
                        [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                        $expectedIii,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch { }
            }
            $_.Name -eq 'iii.exe' -and $executableMatches -and
            [int]$_.ParentProcessId -eq $rootId -and
            (Test-AgentMemoryIiiUsesConfig `
                -CommandLine $_.CommandLine `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath)
        })
    if ($iiiProcesses.Count -ne 1) { return $false }
    $iiiId = [int]$iiiProcesses[0].ProcessId

    $agentNodeIds = @()
    $guardNodeIds = @()
    foreach ($candidate in $processes) {
        if ($candidate.Name -ne 'node.exe') { continue }
        $candidateExecutable = $candidate.PSObject.Properties['ExecutablePath']
        $nodeMatches = $false
        if ($null -ne $candidateExecutable) {
            try {
                $nodeMatches = [string]::Equals(
                    [System.IO.Path]::GetFullPath([string]$candidateExecutable.Value),
                    $expectedNode,
                    [System.StringComparison]::OrdinalIgnoreCase)
            } catch { }
        }
        if (-not $nodeMatches -or [int]$candidate.ProcessId -eq $rootId -or
            [int]$candidate.ParentProcessId -ne $rootId) { continue }
        if (Test-AgentMemoryNodeUsesEntry `
                -CommandLine $candidate.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot) {
            $agentNodeIds += [int]$candidate.ProcessId
        } elseif (Test-AgentMemoryNodeUsesGuard `
                -CommandLine $candidate.CommandLine `
                -NodeExecutable $NodeExecutable `
                -GuardScript $GuardScript `
                -HttpPort $HttpPort) {
            $guardNodeIds += [int]$candidate.ProcessId
        }
    }
    if ($agentNodeIds.Count -ne 1 -or $guardNodeIds.Count -ne 1) { return $false }
    $expectedDirectChildIds = @(
        $iiiId,
        [int]$agentNodeIds[0],
        [int]$guardNodeIds[0]
    )
    $actualDirectChildIds = @($processes | Where-Object {
            [int]$_.ParentProcessId -eq $rootId
        } | ForEach-Object { [int]$_.ProcessId })
    if ($actualDirectChildIds.Count -ne 3 -or
        @($actualDirectChildIds | Where-Object {
                $expectedDirectChildIds -notcontains $_
            }).Count -ne 0) {
        return $false
    }

    $listenerContracts = @(
        [pscustomobject]@{ Port=$HttpPort; Address='127.0.0.1'; Owner=[int]$guardNodeIds[0] },
        [pscustomobject]@{
            Port=$script:DevToolsAgentMemoryViewerPort
            Address=$script:DevToolsAgentMemoryViewerHost
            Owner=[int]$agentNodeIds[0]
        },
        [pscustomobject]@{
            Port=$script:AgentMemoryInternalRestPort; Address='127.0.0.1'; Owner=$iiiId
        },
        [pscustomobject]@{
            Port=$script:AgentMemoryInternalStreamPort; Address='127.0.0.1'; Owner=$iiiId
        },
        [pscustomobject]@{
            Port=$script:AgentMemoryInternalEnginePort; Address='127.0.0.1'; Owner=$iiiId
        }
    )
    foreach ($contract in $listenerContracts) {
        $listeners = @(
            Get-NetTCPConnection -State Listen -LocalPort $contract.Port -ErrorAction SilentlyContinue
        )
        if ($listeners.Count -ne 1) { return $false }
        $addressProperty = $listeners[0].PSObject.Properties['LocalAddress']
        $ownerProperty = $listeners[0].PSObject.Properties['OwningProcess']
        if ($null -eq $addressProperty -or
            [string]$addressProperty.Value -ne [string]$contract.Address -or
            $null -eq $ownerProperty) {
            return $false
        }
        $ownerId = [int]$ownerProperty.Value
        if ($ownerId -ne [int]$contract.Owner) { return $false }
    }
    foreach ($legacyPort in @(($HttpPort + 1), ($HttpPort + 2), ($HttpPort + 46023))) {
        if (@(Get-NetTCPConnection `
                -State Listen -LocalPort $legacyPort -ErrorAction SilentlyContinue).Count -ne 0) {
            return $false
        }
    }
    return $true
}

function ConvertTo-AgentMemoryConfigComparisonText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = @($normalized -split "`n" | Where-Object {
            $_ -notmatch '^# selfheal-reload: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        })
    return (($lines -join "`n").TrimEnd([char]10) + "`n")
}

function Get-AgentMemoryPort([string]$Url) {
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "AGENTMEMORY_URL must be an absolute HTTP(S) URL."
    }
    if ($uri.Scheme -ne "http") {
        throw "AGENTMEMORY_URL must use HTTP for the local engine."
    }
    if ($uri.Host -notin @("localhost", "127.0.0.1")) {
        throw "AGENTMEMORY_URL must address an explicit loopback host."
    }
    if ($uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "AGENTMEMORY_URL cannot contain credentials, a path, query, or fragment."
    }
    if ($uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw 'AGENTMEMORY_URL port must be at or below the supported public-port ceiling (5997).'
    }
    return $uri.Port
}

function Test-AgentMemoryIntegerValue {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Test-AgentMemoryServiceIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][int]$ExpectedViewerPort,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 25
    )

    try {
        $response = Invoke-RestMethod `
            -Uri ($BaseUrl.TrimEnd('/') + '/agentmemory/health') `
            -Headers @{ Authorization = "Bearer $Secret" } `
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
            $null -ne $viewerPort -and (Test-AgentMemoryIntegerValue -Value $viewerPort.Value) -and
            [int]$viewerPort.Value -eq $ExpectedViewerPort -and
            $null -ne $viewerSkipped -and $viewerSkipped.Value -is [bool] -and
            -not [bool]$viewerSkipped.Value)
    } catch {
        return $false
    }
}

function Invoke-AgentMemoryViewerRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$HostHeader,
        [AllowNull()][string]$Authorization,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 25
    )

    $expectedUri = "http://$($script:DevToolsAgentMemoryViewerHost):$($script:DevToolsAgentMemoryViewerPort)/agentmemory/health"
    if (-not [string]::Equals($Uri, $expectedUri, [System.StringComparison]::Ordinal)) {
        throw 'The viewer probe URI must be the fixed authenticated viewer health endpoint.'
    }
    if (-not [string]::Equals(
            $HostHeader,
            $script:DevToolsAgentMemoryViewerAuthority,
            [System.StringComparison]::Ordinal)) {
        throw 'The viewer probe Host header must be the reserved internal authority.'
    }
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $response = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $client.DefaultRequestHeaders.Host = $HostHeader
        if (-not [string]::IsNullOrEmpty($Authorization)) {
            if (-not $client.DefaultRequestHeaders.TryAddWithoutValidation(
                    'Authorization', $Authorization)) {
                throw 'The viewer Authorization header could not be constructed.'
            }
        }
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body       = [string]$body
        }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-AgentMemoryViewerIsolation {
    param(
        [Parameter(Mandatory = $true)][string]$Secret,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 25
    )

    $viewerUri = "http://$($script:DevToolsAgentMemoryViewerHost):$($script:DevToolsAgentMemoryViewerPort)/agentmemory/health"
    $replacement = if ($Secret[0] -eq 'A') { 'B' } else { 'A' }
    $wrongSecret = $replacement + $Secret.Substring(1)
    try {
        $missing = Invoke-AgentMemoryViewerRequest `
            -Uri $viewerUri `
            -HostHeader $script:DevToolsAgentMemoryViewerAuthority `
            -Authorization $null `
            -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $missing -or [int]$missing.StatusCode -ne 401) { return $false }

        $wrong = Invoke-AgentMemoryViewerRequest `
            -Uri $viewerUri `
            -HostHeader $script:DevToolsAgentMemoryViewerAuthority `
            -Authorization "Bearer $wrongSecret" `
            -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $wrong -or [int]$wrong.StatusCode -ne 401) { return $false }

        $accepted = Invoke-AgentMemoryViewerRequest `
            -Uri $viewerUri `
            -HostHeader $script:DevToolsAgentMemoryViewerAuthority `
            -Authorization "Bearer $Secret" `
            -TimeoutSeconds $TimeoutSeconds
        # The pinned 0.9.27 viewer authenticates before proxying with Fetch.
        # Fetch must reject internal port 6000 as a WHATWG bad port, so a
        # correct credential proves the isolated path by returning 502 rather
        # than exposing a second working API surface.
        return ($null -ne $accepted -and [int]$accepted.StatusCode -eq 502)
    } catch {
        return $false
    }
}

function Test-AgentMemoryHostGuardIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$ExpectedPort,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 25
    )
    try {
        $response = Invoke-RestMethod `
            -Uri ($BaseUrl.TrimEnd('/') + '/__devtools/agentmemory-host-guard/health') `
            -Headers @{ Authorization = "Bearer $Secret" } `
            -TimeoutSec $TimeoutSeconds
        return ($null -ne $response -and
            $response.service -is [string] -and
            $response.service -eq 'devtools-agentmemory-host-guard' -and
            $response.status -is [string] -and $response.status -eq 'healthy' -and
            $response.version -is [string] -and
            $response.version -eq $script:AgentMemoryHostGuardVersion -and
            (Test-AgentMemoryIntegerValue -Value $response.listenPort) -and
            [int]$response.listenPort -eq $ExpectedPort -and
            (Test-AgentMemoryIntegerValue -Value $response.upstreamPort) -and
            [int]$response.upstreamPort -eq $script:AgentMemoryInternalRestPort)
    } catch {
        return $false
    }
}

function Get-AgentMemoryInstalledVersion {
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

function Open-AgentMemoryInstanceLock {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$Port,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )
    $sharedRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'devtools-agentmemory-locks'
    New-Item -ItemType Directory -Path $sharedRoot -Force | Out-Null
    $lockPath = Join-Path $sharedRoot ("instance.$Port.lock")
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
            if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for the agentmemory instance lock.' }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function Test-AgentMemoryExactIiiProcessExists {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$IiiExecutable
    )
    $expectedExecutable = [System.IO.Path]::GetFullPath($IiiExecutable)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $executableProperty = $process.PSObject.Properties['ExecutablePath']
        if ($process.Name -eq 'iii.exe' -and $null -ne $executableProperty -and
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                $expectedExecutable,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-AgentMemoryIiiUsesConfig `
                -CommandLine $process.CommandLine `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath)) {
            return $true
        }
    }
    return $false
}

function Test-AgentMemoryExactSupervisorProcessExists {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [Parameter(Mandatory = $true)][string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )
    $expectedNode = [System.IO.Path]::GetFullPath($NodeExecutable)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $executableProperty = $process.PSObject.Properties['ExecutablePath']
        if ($process.Name -eq 'node.exe' -and $null -ne $executableProperty -and
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
                $expectedNode,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-AgentMemoryNodeUsesSupervisor `
                -CommandLine $process.CommandLine `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot `
                -IiiExecutable $IiiExecutable `
                -ConfigPath $ConfigPath `
                -GuardScript $GuardScript `
                -SupervisorScript $SupervisorScript `
                -HttpPort $HttpPort)) {
            return $true
        }
    }
    return $false
}

function Stop-AgentMemoryExactProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$RootProcessId,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [Parameter(Mandatory = $true)][string]$SupervisorScript,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$HttpPort
    )
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $processMap = @{}
    foreach ($process in $processes) { $processMap[[string][int]$process.ProcessId] = $process }
    if (-not $processMap.ContainsKey([string]$RootProcessId)) { return }
    $rootProcess = $processMap[[string]$RootProcessId]
    $executableProperty = $rootProcess.PSObject.Properties['ExecutablePath']
    if ($rootProcess.Name -ne 'node.exe' -or $null -eq $executableProperty -or
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath([string]$executableProperty.Value),
            [System.IO.Path]::GetFullPath($NodeExecutable),
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-AgentMemoryNodeUsesSupervisor `
            -CommandLine $rootProcess.CommandLine `
            -NodeExecutable $NodeExecutable `
            -InstallRoot $InstallRoot `
            -IiiExecutable $IiiExecutable `
            -ConfigPath $ConfigPath `
            -GuardScript $GuardScript `
            -SupervisorScript $SupervisorScript `
            -HttpPort $HttpPort)) {
        return
    }
    $targets = New-Object System.Collections.Generic.List[object]
    $targets.Add([pscustomobject]@{ Id = $RootProcessId; Depth = 0 })
    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        if ($processId -eq $RootProcessId) { continue }
        $depth = 0
        $currentId = $processId
        $seen = @{}
        while ($currentId -gt 0 -and -not $seen.ContainsKey([string]$currentId)) {
            $seen[[string]$currentId] = $true
            if (-not $processMap.ContainsKey([string]$currentId)) { break }
            $parentId = [int]$processMap[[string]$currentId].ParentProcessId
            $depth++
            if ($parentId -eq $RootProcessId) {
                $targets.Add([pscustomobject]@{ Id = $processId; Depth = $depth })
                break
            }
            $currentId = $parentId
        }
    }
    foreach ($target in @($targets | Sort-Object Depth -Descending)) {
        Stop-Process -Id ([int]$target.Id) -Force -ErrorAction SilentlyContinue
    }
}

function Wait-AgentMemoryServerReady {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$IiiExecutable,
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$GuardScript,
        [Parameter(Mandatory = $true)][string]$SupervisorScript,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$Port,
        [ValidateRange(1, 600)][int]$MaxSeconds = 90
    )
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    do {
        # Listener/process ownership must be established before any request
        # carries AGENTMEMORY_SECRET to either local HTTP surface.
        if ((Test-AgentMemoryRuntimeListeners `
                -ConfigPath $ConfigPath `
                -IiiExecutable $IiiExecutable `
                -NodeExecutable $NodeExecutable `
                -InstallRoot $InstallRoot `
                -GuardScript $GuardScript `
                -SupervisorScript $SupervisorScript `
                -HttpPort $Port) -and
            (Test-AgentMemoryHostGuardIdentity `
                -BaseUrl $BaseUrl `
                -Secret $Secret `
                -ExpectedPort $Port) -and
            (Test-AgentMemoryServiceIdentity `
                -BaseUrl $BaseUrl `
                -Secret $Secret `
                -ExpectedVersion $ExpectedVersion `
                -ExpectedViewerPort $script:DevToolsAgentMemoryViewerPort) -and
            (Test-AgentMemoryViewerIsolation -Secret $Secret)) {
            return $true
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-AgentMemoryServerSettings {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$LogDir,
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
    $port = Get-AgentMemoryPort $url
    $url = "http://127.0.0.1:$port"

    $dataPath = $DataRoot
    if ([string]::IsNullOrWhiteSpace($dataPath)) { $dataPath = $env:AGENTMEMORY_DATA_ROOT }
    $dataPath = Resolve-AgentMemoryPath -Path $dataPath -Root $root -DefaultRelativePath "data"

    $configPath = $Config
    if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = $env:AGENTMEMORY_CONFIG }
    $configPath = Resolve-AgentMemoryPath -Path $configPath -Root $root -DefaultRelativePath "agentmemory-iii.yaml"

    $packageRoot = $InstallRoot
    if ([string]::IsNullOrWhiteSpace($packageRoot)) { $packageRoot = $env:AGENTMEMORY_INSTALL_ROOT }
    $packageRoot = Resolve-AgentMemoryPath `
        -Path $packageRoot -Root $root -DefaultRelativePath 'npm-global\agentmemory-runtime'

    $nodePath = $NodeExecutable
    if ([string]::IsNullOrWhiteSpace($nodePath)) { $nodePath = $env:NODE_EXE }
    $nodePath = Resolve-AgentMemoryPath -Path $nodePath -Root $root -DefaultRelativePath 'node\node.exe'

    $iiiPath = $IiiExecutable
    if ([string]::IsNullOrWhiteSpace($iiiPath)) { $iiiPath = $env:AGENTMEMORY_III_EXE }
    $iiiPath = Resolve-AgentMemoryPath -Path $iiiPath -Root $packageRoot -DefaultRelativePath "iii.exe"

    $logs = $LogDir
    if ([string]::IsNullOrWhiteSpace($logs)) { $logs = $env:DEVTOOLS_LOG_DIR }
    $logs = Resolve-AgentMemoryPath -Path $logs -Root $root -DefaultRelativePath "logs"

    $runtimeConfig = Get-AgentMemoryRuntimeConfigPath `
        -TemplatePath $configPath `
        -LogDir $logs `
        -HttpPort $port

    $embedding = $EmbeddingProvider
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = $env:AGENTMEMORY_EMBEDDING_PROVIDER }
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = "local" }

    $guardScript = Resolve-AgentMemoryPath `
        -Path $null -Root $root -DefaultRelativePath 'agentmemory-host-guard.mjs'
    $supervisorScript = Resolve-AgentMemoryPath `
        -Path $null -Root $root -DefaultRelativePath 'agentmemory-runtime-supervisor.mjs'

    [pscustomobject]@{
        DevToolsRoot       = $root
        DataRoot           = $dataPath
        BaseUrl            = $url
        Port               = $port
        StreamPort         = $script:AgentMemoryInternalStreamPort
        ViewerHost         = $script:DevToolsAgentMemoryViewerHost
        ViewerPort         = $script:DevToolsAgentMemoryViewerPort
        EnginePort         = $script:AgentMemoryInternalEnginePort
        InternalRestPort   = $script:AgentMemoryInternalRestPort
        LegacyStreamPort   = $port + 1
        LegacyViewerPort   = $port + 2
        LegacyEnginePort   = $port + 46023
        Config             = $configPath
        RuntimeConfig      = $runtimeConfig
        InstallRoot        = $packageRoot
        NodeExecutable     = $nodePath
        GuardScript        = $guardScript
        SupervisorScript   = $supervisorScript
        IiiExecutable      = $iiiPath
        LogDir             = $logs
        EmbeddingProvider  = $embedding
    }
}

function Invoke-AgentMemoryServer {
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$LogDir,
        [string]$EmbeddingProvider,
        [int]$LogRetentionDays = 14,
        [int]$StartupWaitSeconds = 90,
        [switch]$ValidateOnly,
        [switch]$InspectOnly
    )

    if ($ValidateOnly -and $InspectOnly) {
        throw 'ValidateOnly and InspectOnly are mutually exclusive.'
    }

    $settings = Get-AgentMemoryServerSettings `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -LogDir $LogDir `
        -EmbeddingProvider $EmbeddingProvider
    if (-not (Test-Path -LiteralPath $settings.DevToolsRoot -PathType Container)) {
        throw "DEVTOOLS_ROOT does not exist."
    }
    if (-not (Test-Path -LiteralPath $settings.Config -PathType Leaf)) {
        throw "The canonical agentmemory config is missing; package-internal fallback configuration is forbidden."
    }
    if (-not (Test-Path -LiteralPath $settings.IiiExecutable -PathType Leaf)) {
        throw 'The pinned iii executable is missing; automatic package installation is forbidden.'
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
    $expectedVersion = Get-AgentMemoryInstalledVersion -InstallRoot $settings.InstallRoot
    $instanceLock = $null
    if (-not $ValidateOnly -and -not $InspectOnly) {
        $instanceLock = Open-AgentMemoryInstanceLock -Port $settings.Port
    }
    try {

    $expectedConfig = Get-AgentMemoryMaterializedConfig `
        -TemplatePath $settings.Config `
        -DataRoot $settings.DataRoot `
        -InstallRoot $settings.InstallRoot `
        -NodeExecutable $settings.NodeExecutable `
        -GuardScript $settings.GuardScript `
        -SupervisorScript $settings.SupervisorScript `
        -HttpPort $settings.Port

    if ($ValidateOnly) {
        if (-not (Test-Path -LiteralPath $settings.RuntimeConfig -PathType Leaf) -or
            -not [string]::Equals(
                (ConvertTo-AgentMemoryConfigComparisonText `
                    -Text ([System.IO.File]::ReadAllText($settings.RuntimeConfig))),
                (ConvertTo-AgentMemoryConfigComparisonText -Text $expectedConfig),
                [System.StringComparison]::Ordinal)) {
            throw 'The active agentmemory config does not match the requested template and settings.'
        }
        return 0
    }

    $secret = Get-AgentMemoryRequiredSecret

    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $settings.Port -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        if ($listeners.Count -ne 1) {
            throw 'The configured agentmemory port has multiple listeners and cannot be adopted safely.'
        }
        if (-not (Test-Path -LiteralPath $settings.RuntimeConfig -PathType Leaf) -or
            -not [string]::Equals(
                (ConvertTo-AgentMemoryConfigComparisonText `
                    -Text ([System.IO.File]::ReadAllText($settings.RuntimeConfig))),
                (ConvertTo-AgentMemoryConfigComparisonText -Text $expectedConfig),
                [System.StringComparison]::Ordinal)) {
            throw 'The running agentmemory instance does not match the requested configuration; stop it before applying changes.'
        }
        if (-not (Test-AgentMemoryRuntimeListeners `
                -ConfigPath $settings.RuntimeConfig `
                -IiiExecutable $settings.IiiExecutable `
                -NodeExecutable $settings.NodeExecutable `
                -InstallRoot $settings.InstallRoot `
                -GuardScript $settings.GuardScript `
                -SupervisorScript $settings.SupervisorScript `
                -HttpPort $settings.Port)) {
            throw 'The complete agentmemory listener set cannot be proven loopback-only and owned by the requested process tree.'
        }
        if (-not (Test-AgentMemoryHostGuardIdentity `
                -BaseUrl $settings.BaseUrl `
                -Secret $secret `
                -ExpectedPort $settings.Port)) {
            throw 'The configured agentmemory port is not owned by the authenticated Host guard.'
        }
        if (-not (Test-AgentMemoryServiceIdentity `
                -BaseUrl $settings.BaseUrl `
                -Secret $secret `
                -ExpectedVersion $expectedVersion `
                -ExpectedViewerPort $settings.ViewerPort)) {
            throw 'The configured agentmemory port is occupied by an unverified service.'
        }
        if (-not (Test-AgentMemoryViewerIsolation -Secret $secret)) {
            throw 'The fixed authenticated agentmemory viewer isolation contract cannot be proven.'
        }
        return 0
    }
    if ($InspectOnly) {
        throw 'No running agentmemory listener is available for read-only inspection.'
    }
    if (Test-AgentMemoryExactSupervisorProcessExists `
            -ConfigPath $settings.RuntimeConfig `
            -IiiExecutable $settings.IiiExecutable `
            -NodeExecutable $settings.NodeExecutable `
            -InstallRoot $settings.InstallRoot `
            -GuardScript $settings.GuardScript `
            -SupervisorScript $settings.SupervisorScript `
            -HttpPort $settings.Port) {
        throw 'An exact agentmemory supervisor using this active config is already running or unhealthy.'
    }
    if (Test-AgentMemoryExactIiiProcessExists `
            -ConfigPath $settings.RuntimeConfig `
            -IiiExecutable $settings.IiiExecutable) {
        throw 'An agentmemory instance using this exact active config is already starting or unhealthy.'
    }
    $reservedPorts = @(
        [pscustomobject]@{ Port=$settings.ViewerPort; Name='agentmemory viewer' },
        [pscustomobject]@{ Port=$settings.InternalRestPort; Name='internal iii REST' },
        [pscustomobject]@{ Port=$settings.StreamPort; Name='internal iii stream' },
        [pscustomobject]@{ Port=$settings.EnginePort; Name='internal iii worker-manager' },
        [pscustomobject]@{ Port=$settings.LegacyStreamPort; Name='retired public stream' },
        [pscustomobject]@{ Port=$settings.LegacyViewerPort; Name='retired public viewer' },
        [pscustomobject]@{ Port=$settings.LegacyEnginePort; Name='retired public worker-manager' }
    )
    foreach ($reserved in $reservedPorts) {
        $occupied = Get-NetTCPConnection `
            -State Listen -LocalPort $reserved.Port -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($occupied) { throw "The $($reserved.Name) port is already occupied." }
    }

    New-Item -ItemType Directory -Path $settings.LogDir -Force | Out-Null
    [void](New-AgentMemoryActiveConfig `
        -TemplatePath $settings.Config `
        -ActivePath $settings.RuntimeConfig `
        -DataRoot $settings.DataRoot `
        -InstallRoot $settings.InstallRoot `
        -NodeExecutable $settings.NodeExecutable `
        -GuardScript $settings.GuardScript `
        -SupervisorScript $settings.SupervisorScript `
        -HttpPort $settings.Port)

    $pathEntries = @(
        (Split-Path -Parent $settings.NodeExecutable),
        $settings.InstallRoot,
        (Join-Path $settings.DevToolsRoot "pwsh"),
        (Join-Path $settings.DevToolsRoot "dotnet")
    )
    $env:PATH = (($pathEntries + @($env:PATH)) -join [System.IO.Path]::PathSeparator)
    $env:AGENTMEMORY_TOOLS = 'all'
    $env:AGENTMEMORY_SLOTS = 'true'
    $env:AGENTMEMORY_URL = $settings.BaseUrl
    $env:AGENTMEMORY_DATA_ROOT = $settings.DataRoot
    $env:AGENTMEMORY_INSTALL_ROOT = $settings.InstallRoot
    $env:NODE_EXE = $settings.NodeExecutable
    $env:NODE_OPTIONS = $null
    $env:NODE_PATH = $null
    $env:NoDefaultCurrentDirectoryInExePath = '1'
    $env:EMBEDDING_PROVIDER = $settings.EmbeddingProvider
    # The pinned viewer derives its fixed port as III_REST_PORT + 2. Its Fetch
    # proxy is intentionally blocked from port 6000; the separate Host guard
    # is the only working authenticated REST surface and owns R.
    $env:III_REST_PORT = [string]$settings.InternalRestPort
    $env:III_STREAM_PORT = [string]$settings.StreamPort
    $env:III_ENGINE_PORT = [string]$settings.EnginePort
    $env:III_ENGINE_URL = "ws://127.0.0.1:$($settings.EnginePort)"
    # 0.9.27 recognizes only 127.0.0.1/::1/localhost as loopback. Binding the
    # equally local 127.0.0.2 address intentionally activates its inbound
    # Bearer enforcement and disables viewer port fallback.
    $env:AGENTMEMORY_VIEWER_HOST = $settings.ViewerHost
    $env:VIEWER_ALLOWED_HOSTS = $script:DevToolsAgentMemoryViewerAuthority
    $env:VIEWER_ALLOWED_ORIGINS = "http://$($script:DevToolsAgentMemoryViewerAuthority)"

    $activeConfig = $settings.RuntimeConfig

    if ($LogRetentionDays -ge 0) {
        Get-ChildItem -LiteralPath $settings.LogDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^agentmemory\.(out|err)-.*\.log$' -and
                $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays)
            } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdout = Join-Path $settings.LogDir "agentmemory.out-$timestamp.log"
    $stderr = Join-Path $settings.LogDir "agentmemory.err-$timestamp.log"

    $env:AGENTMEMORY_III_CONFIG = $activeConfig
    $supervisorArguments = @(
        ('"{0}"' -f $settings.SupervisorScript),
        '--iii-executable', ('"{0}"' -f $settings.IiiExecutable),
        '--iii-config', ('"{0}"' -f $activeConfig),
        '--agentmemory-entry', ('"{0}"' -f $agentMemoryEntry),
        '--guard-script', ('"{0}"' -f $settings.GuardScript),
        '--listen-port', [string]$settings.Port,
        '--upstream-port', [string]$settings.InternalRestPort,
        '--stream-port', [string]$settings.StreamPort,
        '--engine-port', [string]$settings.EnginePort
    )
    $startedProcess = Start-Process -FilePath $settings.NodeExecutable `
        -ArgumentList $supervisorArguments `
        -WorkingDirectory $settings.DevToolsRoot `
        -NoNewWindow `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru
    if (-not (Wait-AgentMemoryServerReady `
            -BaseUrl $settings.BaseUrl `
            -ExpectedVersion $expectedVersion `
            -ConfigPath $activeConfig `
            -IiiExecutable $settings.IiiExecutable `
            -NodeExecutable $settings.NodeExecutable `
            -InstallRoot $settings.InstallRoot `
            -GuardScript $settings.GuardScript `
            -SupervisorScript $settings.SupervisorScript `
            -Secret $secret `
            -Port $settings.Port `
            -MaxSeconds $StartupWaitSeconds)) {
        if ($null -ne $startedProcess -and $null -ne $startedProcess.PSObject.Properties['Id']) {
            Stop-AgentMemoryExactProcessTree `
                -RootProcessId ([int]$startedProcess.Id) `
                -ConfigPath $activeConfig `
                -IiiExecutable $settings.IiiExecutable `
                -NodeExecutable $settings.NodeExecutable `
                -InstallRoot $settings.InstallRoot `
                -GuardScript $settings.GuardScript `
                -SupervisorScript $settings.SupervisorScript `
                -HttpPort $settings.Port
        }
        throw 'The pinned agentmemory instance did not become ready before the startup deadline.'
    }
    return 0
    } finally {
        if ($null -ne $instanceLock) { $instanceLock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AgentMemoryServer `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -LogDir $LogDir `
        -EmbeddingProvider $EmbeddingProvider `
        -LogRetentionDays $LogRetentionDays `
        -StartupWaitSeconds $StartupWaitSeconds `
        -ValidateOnly:$ValidateOnly `
        -InspectOnly:$InspectOnly)
}
