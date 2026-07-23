param(
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'

$secretStoreScript = Join-Path $PSScriptRoot 'agentmemory-secret-store.ps1'
if (-not (Test-Path -LiteralPath $secretStoreScript -PathType Leaf)) {
    throw 'Agentmemory watchdog secret-store support is unavailable.'
}
. $secretStoreScript

function Assert-AgentMemoryWatchdogSecret {
    param([string]$Secret)
    $candidate = $Secret
    if ($null -eq $candidate) {
        $candidate = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'Agentmemory watchdog secret format is invalid.'
    }
}

function Resolve-AgentMemoryWatchdogStrictPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ($Path -match '[\x00-\x1f\x7f\u0085\u2028\u2029]' -or
        -not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Watchdog path is invalid: $Name"
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    } catch {
        throw "Watchdog path is invalid: $Name"
    }
    if (-not [string]::Equals($resolved, $Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Watchdog path is not canonical: $Name"
    }
    return $resolved
}

function Test-AgentMemoryWatchdogRunnerPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $boundary = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-AgentMemoryWatchdogSettings {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)

    $resolvedSettingsPath = Resolve-AgentMemoryWatchdogStrictPath `
        -Name 'SettingsPath' -Path $SettingsPath
    if (-not (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf)) {
        throw 'Agentmemory watchdog settings are missing.'
    }
    if ((Get-Item -LiteralPath $resolvedSettingsPath).Length -gt 65536) {
        throw 'Agentmemory watchdog settings exceed the size limit.'
    }
    try {
        $settings = [System.IO.File]::ReadAllText($resolvedSettingsPath) | ConvertFrom-Json
    } catch {
        throw 'Agentmemory watchdog settings are invalid JSON.'
    }
    if ($null -eq $settings -or $settings -is [array]) {
        throw 'Agentmemory watchdog settings schema is invalid.'
    }

    $required = @(
        'SchemaVersion', 'DevToolsRoot', 'DataRoot', 'BaseUrl', 'Config', 'InstallRoot',
        'NodeExecutable', 'IiiExecutable', 'EmbeddingProvider', 'LogDir', 'SelfHealScript',
        'ServerScript', 'PowerShellExecutable', 'SecretBlobPath', 'SecretCiphertextSha256'
    )
    $actual = @($settings.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $required.Count) {
        throw 'Agentmemory watchdog settings schema is invalid.'
    }
    foreach ($name in $required) {
        if ($actual -cnotcontains $name) {
            throw 'Agentmemory watchdog settings schema is invalid.'
        }
    }
    if (($settings.SchemaVersion -isnot [int]) -and
        ($settings.SchemaVersion -isnot [long]) -and
        ($settings.SchemaVersion -isnot [decimal])) {
        throw 'Agentmemory watchdog settings schema version is invalid.'
    }
    if ([decimal]$settings.SchemaVersion -ne 1) {
        throw 'Agentmemory watchdog settings schema version is unsupported.'
    }
    foreach ($name in $required | Where-Object { $_ -ne 'SchemaVersion' }) {
        $value = $settings.PSObject.Properties[$name].Value
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value) -or
            [string]$value -match '[\x00-\x1f\x7f\u0085\u2028\u2029]') {
            throw 'Agentmemory watchdog settings schema is invalid.'
        }
    }

    $pathNames = @(
        'DevToolsRoot', 'DataRoot', 'Config', 'InstallRoot', 'NodeExecutable', 'IiiExecutable',
        'LogDir', 'SelfHealScript', 'ServerScript', 'PowerShellExecutable', 'SecretBlobPath'
    )
    foreach ($name in $pathNames) {
        $settings.$name = Resolve-AgentMemoryWatchdogStrictPath `
            -Name $name -Path ([string]$settings.$name)
    }
    foreach ($name in @('DevToolsRoot', 'DataRoot', 'InstallRoot', 'LogDir')) {
        if (-not (Test-Path -LiteralPath ([string]$settings.$name) -PathType Container)) {
            throw 'Agentmemory watchdog directory dependency is missing.'
        }
    }
    foreach ($name in @(
            'Config', 'NodeExecutable', 'IiiExecutable', 'SelfHealScript', 'ServerScript',
            'PowerShellExecutable', 'SecretBlobPath'
        )) {
        if (-not (Test-Path -LiteralPath ([string]$settings.$name) -PathType Leaf)) {
            throw 'Agentmemory watchdog file dependency is missing.'
        }
    }

    $expectedSettingsDirectory = [System.IO.Path]::GetFullPath([string]$settings.LogDir).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $actualSettingsDirectory = [System.IO.Path]::GetFullPath(
        (Split-Path -Parent $resolvedSettingsPath)
    ).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if (-not [string]::Equals(
            $expectedSettingsDirectory,
            $actualSettingsDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Agentmemory watchdog settings path is outside the configured log directory.'
    }
    $runDirectory = Join-Path ([string]$settings.DataRoot) 'run'
    if (-not (Test-AgentMemoryWatchdogRunnerPathWithin `
            -Path ([string]$settings.SecretBlobPath) -Root $runDirectory)) {
        throw 'Agentmemory watchdog secret blob path is outside the runtime directory.'
    }

    if ([string]$settings.SecretCiphertextSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Agentmemory watchdog ciphertext hash is invalid.'
    }
    if ([string]$settings.EmbeddingProvider -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Agentmemory watchdog embedding provider is invalid.'
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate(
            [string]$settings.BaseUrl,
            [System.UriKind]::Absolute,
            [ref]$uri
        ) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or
        $uri.AbsolutePath -ne '/' -or $uri.Port -lt 1 -or $uri.Port -gt 5997 -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        [string]$settings.BaseUrl -cne "http://127.0.0.1:$($uri.Port)") {
        throw 'Watchdog BaseUrl is outside the supported local contract.'
    }
    return [pscustomobject]@{
        Path = $resolvedSettingsPath
        Value = $settings
    }
}

function Invoke-AgentMemoryWatchdogSelfHeal {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellExecutable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    try {
        $global:LASTEXITCODE = $null
        & $PowerShellExecutable @Arguments *> $null
        $invocationSucceeded = $?
        $exitCode = $global:LASTEXITCODE
        if (-not $invocationSucceeded -or $null -eq $exitCode) { return 127 }
        return [int]$exitCode
    } catch {
        return 127
    }
}

function Invoke-AgentMemoryWatchdogRunner {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)

    $loaded = Read-AgentMemoryWatchdogSettings -SettingsPath $SettingsPath
    $settings = $loaded.Value
    $secret = Read-AgentMemoryWatchdogSecret `
        -Path ([string]$settings.SecretBlobPath) `
        -ExpectedSha256 ([string]$settings.SecretCiphertextSha256)
    Assert-AgentMemoryWatchdogSecret -Secret $secret

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string]$settings.SelfHealScript,
        '-DevToolsRoot', [string]$settings.DevToolsRoot,
        '-DataRoot', [string]$settings.DataRoot,
        '-BaseUrl', [string]$settings.BaseUrl,
        '-Config', [string]$settings.Config,
        '-InstallRoot', [string]$settings.InstallRoot,
        '-NodeExecutable', [string]$settings.NodeExecutable,
        '-IiiExecutable', [string]$settings.IiiExecutable,
        '-EmbeddingProvider', [string]$settings.EmbeddingProvider,
        '-LogDir', [string]$settings.LogDir,
        '-ServerScript', [string]$settings.ServerScript,
        '-PowerShellExecutable', [string]$settings.PowerShellExecutable
    )

    $previousSecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $secret, 'Process')
        try {
            return Invoke-AgentMemoryWatchdogSelfHeal `
                -PowerShellExecutable ([string]$settings.PowerShellExecutable) `
                -Arguments $arguments
        } catch {
            throw 'Agentmemory watchdog self-heal invocation failed.'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previousSecret, 'Process')
        $secret = $null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        throw 'Agentmemory watchdog settings path is required.'
    }
    exit (Invoke-AgentMemoryWatchdogRunner -SettingsPath $SettingsPath)
}
