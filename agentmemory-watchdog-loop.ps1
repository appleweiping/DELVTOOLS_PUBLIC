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
    [string]$SelfHealScript,
    [string]$ServerScript,
    [string]$LogPath,
    [string]$PowerShellExecutable,
    [int]$IntervalSeconds = 0
)

$ErrorActionPreference = "SilentlyContinue"

function Get-AgentMemoryWatchdogLoopSettings {
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
        [string]$SelfHealScript,
        [string]$ServerScript,
        [string]$LogPath,
        [string]$PowerShellExecutable,
        [int]$IntervalSeconds
    )

    $root = $DevToolsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
    $root = [System.IO.Path]::GetFullPath($root)

    $url = $BaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = 'http://localhost:3111' }
    $url = $url.TrimEnd('/')
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost', '127.0.0.1') -or
        $uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw 'The foreground watchdog can manage only an explicit local agentmemory endpoint.'
    }
    $url = "http://127.0.0.1:$($uri.Port)"

    $selfHeal = $SelfHealScript
    if ([string]::IsNullOrWhiteSpace($selfHeal)) { $selfHeal = $env:AGENTMEMORY_SELFHEAL_SCRIPT }
    if ([string]::IsNullOrWhiteSpace($selfHeal)) { $selfHeal = Join-Path $root "agentmemory-selfheal.ps1" }
    if (-not [System.IO.Path]::IsPathRooted($selfHeal)) { $selfHeal = Join-Path $root $selfHeal }
    $selfHeal = [System.IO.Path]::GetFullPath($selfHeal)

    $log = $LogPath
    if ([string]::IsNullOrWhiteSpace($log)) { $log = $env:AGENTMEMORY_WATCHDOG_LOG }
    if ([string]::IsNullOrWhiteSpace($log)) {
        $logDir = if ($env:DEVTOOLS_LOG_DIR) { $env:DEVTOOLS_LOG_DIR } else { Join-Path $root "logs" }
        $log = Join-Path $logDir "agentmemory-watchdog.log"
    } elseif (-not [System.IO.Path]::IsPathRooted($log)) {
        $log = Join-Path $root $log
    }
    $log = [System.IO.Path]::GetFullPath($log)

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = "powershell.exe" }
    $shell = [string](Get-Command $shell -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source

    $seconds = $IntervalSeconds
    if ($seconds -le 0 -and $env:AGENTMEMORY_WATCHDOG_SECONDS) {
        [void][int]::TryParse($env:AGENTMEMORY_WATCHDOG_SECONDS, [ref]$seconds)
    }
    if ($seconds -le 0) { $seconds = 300 }
    if ($seconds -lt 30) { throw "Watchdog interval must be at least 30 seconds." }

    [pscustomobject]@{
        DevToolsRoot         = $root
        DataRoot             = $DataRoot
        BaseUrl              = $url
        Port                 = $uri.Port
        Config               = $Config
        InstallRoot          = $InstallRoot
        NodeExecutable       = $NodeExecutable
        IiiExecutable        = $IiiExecutable
        EmbeddingProvider    = $EmbeddingProvider
        LogDir               = $LogDir
        SelfHealScript       = $selfHeal
        ServerScript         = $ServerScript
        LogPath              = $log
        PowerShellExecutable = $shell
        IntervalSeconds      = $seconds
    }
}

function Open-AgentMemoryWatchdogLoopLock {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 5997)][int]$Port)
    $sharedRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'devtools-agentmemory-locks'
    New-Item -ItemType Directory -Path $sharedRoot -Force | Out-Null
    $lockPath = Join-Path $sharedRoot ("watchdog-loop.$Port.lock")
    try {
        return New-Object System.IO.FileStream(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        $ioException = $_.Exception
        while ($null -ne $ioException -and $ioException -isnot [System.IO.IOException]) {
            $ioException = $ioException.InnerException
        }
        if ($null -ne $ioException) {
            $nativeCode = ([int]$ioException.HResult) -band 0xffff
            if ($nativeCode -in @(32, 33)) { return $null }
        }
        throw
    }
}

function Invoke-AgentMemoryWatchdogOnce {
    param(
        [string]$PowerShellExecutable,
        [string]$SelfHealScript,
        [string]$LogPath,
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
    try {
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
        & $PowerShellExecutable @arguments *> $null
        $invocationSucceeded = $?
        $exitCode = $global:LASTEXITCODE
        if (-not $invocationSucceeded -or $null -eq $exitCode) { return 127 }
        return [int]$exitCode
    } catch {
        try {
            $parent = Split-Path -Parent $LogPath
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Add-Content `
                -LiteralPath $LogPath `
                -Value "[$(Get-Date -Format s)] watchdog self-heal invocation failed" `
                -Encoding UTF8
        } catch { }
        return 1
    }
}

function Invoke-AgentMemoryWatchdogLoop {
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
        [string]$SelfHealScript,
        [string]$ServerScript,
        [string]$LogPath,
        [string]$PowerShellExecutable,
        [int]$IntervalSeconds
    )
    $settings = Get-AgentMemoryWatchdogLoopSettings @PSBoundParameters
    if (-not (Test-Path -LiteralPath $settings.SelfHealScript -PathType Leaf)) {
        throw "Self-heal script is missing."
    }
    $loopLock = Open-AgentMemoryWatchdogLoopLock -Port $settings.Port
    if ($null -eq $loopLock) {
        return 0
    }

    try {
        while ($true) {
            [void](Invoke-AgentMemoryWatchdogOnce `
                -PowerShellExecutable $settings.PowerShellExecutable `
                -SelfHealScript $settings.SelfHealScript `
                -LogPath $settings.LogPath `
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
            Start-Sleep -Seconds $settings.IntervalSeconds
        }
    } finally {
        $loopLock.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AgentMemoryWatchdogLoop `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -EmbeddingProvider $EmbeddingProvider `
        -LogDir $LogDir `
        -SelfHealScript $SelfHealScript `
        -ServerScript $ServerScript `
        -LogPath $LogPath `
        -PowerShellExecutable $PowerShellExecutable `
        -IntervalSeconds $IntervalSeconds)
}
