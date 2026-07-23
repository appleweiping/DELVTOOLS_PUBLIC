param(
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'

function Test-AgentLauncherRunnerInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Invoke-AgentLauncherVerificationRunner {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)

    if (-not [System.IO.Path]::IsPathRooted($SettingsPath)) {
        throw 'Launcher-verifier settings path must be absolute.'
    }
    $resolved = [System.IO.Path]::GetFullPath($SettingsPath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw 'Launcher-verifier task settings are missing.'
    }
    if ((Get-Item -LiteralPath $resolved).Length -gt 65536) {
        throw 'Launcher-verifier task settings exceed the size limit.'
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $settings = [System.IO.File]::ReadAllText($resolved, $encoding) | ConvertFrom-Json
    } catch {
        throw 'Launcher-verifier task settings are invalid UTF-8 JSON.'
    }

    $required = @(
        'schemaVersion', 'RepoRoot', 'LauncherRoot', 'ProfilePath',
        'CmdAutorunPath', 'PowerShellExecutable', 'VerifierPath'
    )
    $actual = @($settings.PSObject.Properties.Name)
    if ($actual.Count -ne $required.Count) {
        throw 'Launcher-verifier task settings have an unexpected schema.'
    }
    foreach ($name in $required) {
        if ($actual -notcontains $name) {
            throw "Launcher-verifier task setting is missing: $name"
        }
    }
    if (-not (Test-AgentLauncherRunnerInteger -Value $settings.schemaVersion) -or
        [int]$settings.schemaVersion -ne 1) {
        throw 'Launcher-verifier task settings use an unsupported schema version.'
    }

    $pathNames = @(
        'RepoRoot', 'LauncherRoot', 'ProfilePath', 'CmdAutorunPath',
        'PowerShellExecutable', 'VerifierPath'
    )
    foreach ($name in $pathNames) {
        $value = $settings.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or
            $value -match '[\x00-\x1f\x7f\x85\u2028\u2029]' -or
            -not [System.IO.Path]::IsPathRooted($value)) {
            throw "Launcher-verifier task path is invalid: $name"
        }
        $settings.$name = [System.IO.Path]::GetFullPath($value)
    }

    $expectedVerifier = Join-Path $settings.RepoRoot 'tools\agent-launcher-verify.ps1'
    if (-not [string]::Equals(
            [System.IO.Path]::GetFullPath($expectedVerifier),
            $settings.VerifierPath,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Launcher-verifier task settings select an unexpected verifier script.'
    }
    foreach ($requiredFile in @($settings.PowerShellExecutable, $settings.VerifierPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw 'Launcher-verifier task dependency is missing.'
        }
    }
    $shell = Get-Command $settings.PowerShellExecutable -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    if (-not [string]::Equals(
            [System.IO.Path]::GetFullPath([string]$shell.Source),
            $settings.PowerShellExecutable,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Launcher-verifier task PowerShell executable could not be proven exactly.'
    }

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $settings.VerifierPath,
        '-RepoRoot', $settings.RepoRoot,
        '-LauncherRoot', $settings.LauncherRoot,
        '-ProfilePath', $settings.ProfilePath,
        '-CmdAutorunPath', $settings.CmdAutorunPath,
        '-Apply', '-Quiet'
    )
    & ([string]$shell.Source) @arguments
    $childSucceeded = $?
    $childExitCode = $LASTEXITCODE
    if (-not $childSucceeded -or $null -eq $childExitCode) { return 127 }
    return [int]$childExitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        throw 'Launcher-verifier task settings path is required.'
    }
    exit (Invoke-AgentLauncherVerificationRunner -SettingsPath $SettingsPath)
}
