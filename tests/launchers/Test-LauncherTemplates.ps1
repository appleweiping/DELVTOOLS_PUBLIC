[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$launcherRoot = Join-Path $repoRoot 'launchers'
$exampleRoot = Join-Path $repoRoot 'examples'
$catalogPath = Join-Path $repoRoot 'docs\launcher-catalog.md'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

function Stop-AgentTestProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$TargetProcessId,
        [Parameter(Mandatory = $true)][DateTime]$ExpectedStartTime,
        [AllowEmptyString()][string]$ExpectedCommandMarker = ''
    )

    if ($TargetProcessId -le 0) {
        return $false
    }

    $candidate = $null
    try {
        $candidate = [System.Diagnostics.Process]::GetProcessById($TargetProcessId)

        # Pin the original kernel process object with an open handle before
        # checking identity. Windows cannot recycle this PID while it is held.
        $null = $candidate.Handle
        $actualStart = $candidate.StartTime.ToUniversalTime()
        $expectedStart = $ExpectedStartTime.ToUniversalTime()
        $startMatches = if ([string]::IsNullOrEmpty($ExpectedCommandMarker)) {
            $actualStart.Ticks -eq $expectedStart.Ticks
        } else {
            # CIM creation timestamps can differ from Process.StartTime by a
            # sub-millisecond conversion remainder; the GUID marker is the
            # second identity factor for residual-process cleanup.
            [Math]::Abs(($actualStart - $expectedStart).TotalMilliseconds) -le 10
        }
        if (-not $startMatches) {
            return $false
        }

        if (-not [string]::IsNullOrEmpty($ExpectedCommandMarker)) {
            $record = Get-CimInstance `
                -ClassName Win32_Process `
                -Filter ("ProcessId = {0}" -f $TargetProcessId) `
                -ErrorAction Stop
            if ($null -eq $record -or
                [string]::IsNullOrEmpty($record.CommandLine) -or
                $record.CommandLine.IndexOf(
                    $ExpectedCommandMarker,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -lt 0) {
                return $false
            }
        }

        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        try {
            & $taskkill /PID $TargetProcessId /T /F 2>$null | Out-Null
        } catch {
            # Exiting after identity verification is harmless. The pinned
            # handle ensures the PID cannot identify a different process.
        }
        return $true
    } catch [System.ArgumentException] {
        return $false
    } catch [System.InvalidOperationException] {
        return $false
    } catch {
        return $false
    } finally {
        if ($null -ne $candidate) {
            $candidate.Dispose()
        }
    }
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [hashtable]$Environment = @{},
        [int]$TimeoutMs = 15000
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            $null = $startInfo.EnvironmentVariables.Remove($key)
        } else {
            $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start test process: $FileName $Arguments"
    }
    $processStartTime = $process.StartTime

    $timedOut = -not $process.WaitForExit($TimeoutMs)
    if ($timedOut) {
        $null = Stop-AgentTestProcessTree `
            -TargetProcessId $process.Id `
            -ExpectedStartTime $processStartTime
        $null = $process.WaitForExit(5000)
        if (-not $process.HasExited) {
            try {
                $process.Kill()
            } catch [System.InvalidOperationException] {
                # A concurrent exit is equivalent to successful cleanup.
            }
            $null = $process.WaitForExit(5000)
        }
    }

    $result = [pscustomobject]@{
        ProcessId = $process.Id
        TimedOut = $timedOut
        ExitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
    }
    $process.Dispose()
    return $result
}

function Get-MarkerProcesses([string]$Marker) {
    return @(
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine.IndexOf($Marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
    )
}

$expectedLaunchers = [ordered]@{
    'codex.cmd'       = @('CODEX_EXE')
    'codex-light.cmd' = @('CODEX_EXE')
    'claude.cmd'      = @('CLAUDE_EXE')
    'cc.cmd'          = @('CLAUDE_EXE')
    'opencode.cmd'    = @('OPENCODE_EXE')
    'aris.cmd'        = @('ARIS_EXE')
    'gemini.cmd'      = @('GEMINI_EXE')
    'claudeseek.cmd'  = @('CLAUDESEEK_EXE')
    'hermes.cmd'      = @('HERMES_EXE')
    'pixelcat.cmd'    = @('PIXELCAT_EXE')
    'uv.cmd'          = @('UV_EXE')
    'uvx.cmd'         = @('UVX_EXE')
    'bun.cmd'         = @('BUN_EXE')
    'key-rotator.cmd' = @('KEY_ROTATOR_SCRIPT', 'NODE_EXE')
}

foreach ($entry in $expectedLaunchers.GetEnumerator()) {
    $path = Join-Path $launcherRoot $entry.Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure "Missing launcher: launchers/$($entry.Key)"
        continue
    }

    $text = [System.IO.File]::ReadAllText($path)
    foreach ($override in @($entry.Value)) {
        if ($text -notmatch [regex]::Escape($override)) {
            Add-Failure "launchers/$($entry.Key) does not document or consume $override."
        }
    }
}

$keyRotatorLauncherPath = Join-Path $launcherRoot 'key-rotator.cmd'
if (Test-Path -LiteralPath $keyRotatorLauncherPath -PathType Leaf) {
    $keyRotatorLauncherText = [System.IO.File]::ReadAllText($keyRotatorLauncherPath)
    if ($keyRotatorLauncherText -match '(?im)\bwhere(?:\.exe)?\b') {
        Add-Failure 'launchers/key-rotator.cmd must not discover Node.js through where.exe or PATH.'
    }
}

$cmdFiles = @(
    Get-ChildItem -LiteralPath $launcherRoot -Filter '*.cmd' -File
    Get-ChildItem -LiteralPath $exampleRoot -Filter '*.cmd' -File
)

foreach ($file in $cmdFiles) {
    $relativePath = $file.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/'
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasUtf16Bom = $bytes.Length -ge 2 -and (
        ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or
        ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)
    )
    if ($hasUtf8Bom -or $hasUtf16Bom) {
        Add-Failure "$relativePath has a BOM."
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -match '(?<!\r)\n') {
        Add-Failure "$relativePath contains LF-only line endings."
    }
    if ($text -match '(?im)(?:^|[^%A-Za-z])[A-Za-z]:\\') {
        Add-Failure "$relativePath contains a hard-coded drive path."
    }
    if ($text -match '(?i)https?://') {
        Add-Failure "$relativePath contains a hard-coded endpoint."
    }
    if ($text -match '(?i)(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})') {
        Add-Failure "$relativePath contains a credential-shaped literal."
    }
}

foreach ($file in Get-ChildItem -LiteralPath $launcherRoot -Filter '*.cmd' -File) {
    $relativePath = "launchers/$($file.Name)"
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if ($text -notmatch '(?i)%~dp0') {
        Add-Failure "$relativePath does not anchor paths to its own directory."
    }
    if ($text -notmatch '(?i)DEVTOOLS_ROOT') {
        Add-Failure "$relativePath does not support DEVTOOLS_ROOT."
    }
}

if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    Add-Failure 'Missing docs/launcher-catalog.md.'
} else {
    $catalog = [System.IO.File]::ReadAllText($catalogPath)
    foreach ($launcher in $expectedLaunchers.Keys) {
        if ($catalog -notmatch [regex]::Escape($launcher)) {
            Add-Failure "docs/launcher-catalog.md does not list $launcher."
        }
    }
    if ($catalog -notmatch '(?i)not vendored|not included') {
        Add-Failure 'docs/launcher-catalog.md does not state that independent project source is not vendored.'
    }
}

$syncLaunchers = [ordered]@{
    'codex.cmd'       = 'CODEX_EXE'
    'codex-light.cmd' = 'CODEX_EXE'
    'claude.cmd'      = 'CLAUDE_EXE'
    'cc.cmd'          = 'CLAUDE_EXE'
    'opencode.cmd'    = 'OPENCODE_EXE'
    'aris.cmd'        = 'ARIS_EXE'
    'gemini.cmd'      = 'GEMINI_EXE'
    'claudeseek.cmd'  = 'CLAUDESEEK_EXE'
    'hermes.cmd'      = 'HERMES_EXE'
    'uv.cmd'          = 'UV_EXE'
    'uvx.cmd'         = 'UVX_EXE'
    'bun.cmd'         = 'BUN_EXE'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devtools-launcher-tests-" + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($tempRoot)
try {
    $probePath = Join-Path $tempRoot 'sync-probe.cmd'
    $probeLines = @(
        '@echo off',
        'setlocal',
        'set "PROBE_LAST_ARG="',
        ':probe_next',
        'if "%~1"=="" goto probe_done',
        'set "PROBE_LAST_ARG=%~1"',
        'shift',
        'goto probe_next',
        ':probe_done',
        '> "%LAUNCHER_PROBE_OUTPUT%" echo(%PROBE_LAST_ARG%',
        'endlocal & exit /b %LAUNCHER_PROBE_EXIT%'
    )
    [System.IO.File]::WriteAllText(
        $probePath,
        (($probeLines -join "`r`n") + "`r`n"),
        [System.Text.Encoding]::ASCII
    )

    foreach ($entry in $syncLaunchers.GetEnumerator()) {
        $launcherPath = Join-Path $launcherRoot $entry.Key
        $outputPath = Join-Path $tempRoot ($entry.Key + '.argument.txt')
        $environment = @{
            DEVTOOLS_ROOT = $repoRoot
            DEVTOOLS_LOCAL_CMD = (Join-Path $tempRoot 'missing-devtools.local.cmd')
            LAUNCHER_LITERAL_ARGUMENT = '%SENTINEL%'
            SENTINEL = 'expanded-by-call'
            LAUNCHER_PROBE_OUTPUT = $outputPath
            LAUNCHER_PROBE_EXIT = '37'
        }
        $environment[$entry.Value] = $probePath
        $arguments = '/d /v:on /c ""{0}" "!LAUNCHER_LITERAL_ARGUMENT!""' -f $launcherPath

        try {
            $result = Invoke-CapturedProcess -FileName $env:ComSpec -Arguments $arguments -Environment $environment
            if ($result.TimedOut) {
                Add-Failure "launchers/$($entry.Key) did not return within 15 seconds."
                continue
            }
            if ($result.ExitCode -ne 37) {
                Add-Failure "launchers/$($entry.Key) returned $($result.ExitCode), expected child exit code 37."
            }
            if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                Add-Failure "launchers/$($entry.Key) did not run the argument probe."
                continue
            }

            $actualArgument = ([System.IO.File]::ReadAllText($outputPath)).TrimEnd("`r", "`n")
            if ($actualArgument -cne '%SENTINEL%') {
                Add-Failure "launchers/$($entry.Key) reparsed literal %SENTINEL% as '$actualArgument'."
            }
        } catch {
            Add-Failure "launchers/$($entry.Key) runtime probe failed: $($_.Exception.Message)"
        }
    }

    $nativeLauncherPath = Join-Path $launcherRoot 'uv.cmd'
    $nativeEnvironment = @{
        DEVTOOLS_ROOT = $repoRoot
        DEVTOOLS_LOCAL_CMD = (Join-Path $tempRoot 'missing-devtools.local.cmd')
        UV_EXE = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    $nativeArguments = '/d /v:off /c ""{0}" -NoProfile -Command "exit 41""' -f $nativeLauncherPath
    try {
        $nativeResult = Invoke-CapturedProcess -FileName $env:ComSpec -Arguments $nativeArguments -Environment $nativeEnvironment
        if ($nativeResult.TimedOut) {
            Add-Failure 'launchers/uv.cmd did not return from a native executable within 15 seconds.'
        } elseif ($nativeResult.ExitCode -ne 41) {
            Add-Failure "launchers/uv.cmd returned $($nativeResult.ExitCode), expected native executable exit code 41."
        }
    } catch {
        Add-Failure "launchers/uv.cmd native executable probe failed: $($_.Exception.Message)"
    }

    $claudeseekEntryPath = Join-Path $tempRoot 'claudeseek-entry.js'
    $claudeseekOutputPath = Join-Path $tempRoot 'claudeseek-entry.argument.txt'
    [System.IO.File]::WriteAllText($claudeseekEntryPath, '', [System.Text.Encoding]::ASCII)
    $claudeseekEnvironment = @{
        DEVTOOLS_ROOT = $repoRoot
        DEVTOOLS_LOCAL_CMD = (Join-Path $tempRoot 'missing-devtools.local.cmd')
        CLAUDESEEK_EXE = $null
        CLAUDESEEK_ENTRY = $claudeseekEntryPath
        NODE_EXE = $probePath
        LAUNCHER_LITERAL_ARGUMENT = '%SENTINEL%'
        SENTINEL = 'expanded-by-call'
        LAUNCHER_PROBE_OUTPUT = $claudeseekOutputPath
        LAUNCHER_PROBE_EXIT = '43'
    }
    $claudeseekLauncherPath = Join-Path $launcherRoot 'claudeseek.cmd'
    $claudeseekArguments = '/d /v:on /c ""{0}" "!LAUNCHER_LITERAL_ARGUMENT!""' -f $claudeseekLauncherPath
    try {
        $claudeseekResult = Invoke-CapturedProcess -FileName $env:ComSpec -Arguments $claudeseekArguments -Environment $claudeseekEnvironment
        if ($claudeseekResult.TimedOut) {
            Add-Failure 'launchers/claudeseek.cmd entry-point mode did not return within 15 seconds.'
        } elseif ($claudeseekResult.ExitCode -ne 43) {
            Add-Failure "launchers/claudeseek.cmd entry-point mode returned $($claudeseekResult.ExitCode), expected 43."
        }
        if (-not (Test-Path -LiteralPath $claudeseekOutputPath -PathType Leaf)) {
            Add-Failure 'launchers/claudeseek.cmd entry-point mode did not run the argument probe.'
        } else {
            $claudeseekArgument = ([System.IO.File]::ReadAllText($claudeseekOutputPath)).TrimEnd("`r", "`n")
            if ($claudeseekArgument -cne '%SENTINEL%') {
                Add-Failure "launchers/claudeseek.cmd entry-point mode reparsed literal %SENTINEL% as '$claudeseekArgument'."
            }
        }
    } catch {
        Add-Failure "launchers/claudeseek.cmd entry-point probe failed: $($_.Exception.Message)"
    }

    $emptyScriptPath = Join-Path $tempRoot 'empty-key-rotator-script.js'
    [System.IO.File]::WriteAllText($emptyScriptPath, '', [System.Text.Encoding]::ASCII)

    $isolatedRoot = Join-Path $tempRoot 'isolated-devtools-root'
    $pathHijackRoot = Join-Path $tempRoot 'path-hijack'
    $null = [System.IO.Directory]::CreateDirectory($isolatedRoot)
    $null = [System.IO.Directory]::CreateDirectory($pathHijackRoot)
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $pathHijackRoot 'node.exe')
    $pathHijackEnvironment = @{
        DEVTOOLS_ROOT = $isolatedRoot
        DEVTOOLS_LOCAL_CMD = (Join-Path $tempRoot 'missing-devtools.local.cmd')
        KEY_ROTATOR_LOCAL_CMD = (Join-Path $tempRoot 'missing-key-rotator.local.cmd')
        KEY_ROTATOR_SCRIPT = $emptyScriptPath
        NODE_EXE = $null
        PATH = $pathHijackRoot + [System.IO.Path]::PathSeparator + $env:PATH
        ROTATOR_PROXY_TOKEN = 'placeholder-inbound-token-value-1234'
        ROTATOR_KEYS = 'placeholder-values'
        ROTATOR_TARGETS = 'placeholder-targets'
    }
    $pathHijackArguments = '/d /v:off /c ""{0}""' -f $keyRotatorLauncherPath
    try {
        $pathHijackResult = Invoke-CapturedProcess -FileName $env:ComSpec -Arguments $pathHijackArguments -Environment $pathHijackEnvironment
        if ($pathHijackResult.TimedOut) {
            Add-Failure 'launchers/key-rotator.cmd PATH-hijack probe did not return within 15 seconds.'
        } elseif ($pathHijackResult.ExitCode -ne 2) {
            Add-Failure "launchers/key-rotator.cmd trusted a PATH-discovered node.exe; expected exit 2, got $($pathHijackResult.ExitCode)."
        }
    } catch {
        Add-Failure "launchers/key-rotator.cmd PATH-hijack probe failed: $($_.Exception.Message)"
    }

    $asyncCases = @(
        [pscustomobject]@{
            Name = 'pixelcat.cmd'
            Environment = @{
                PIXELCAT_EXE = (Join-Path $tempRoot 'missing-pixelcat.exe')
            }
        },
        [pscustomobject]@{
            Name = 'key-rotator.cmd'
            Environment = @{
                KEY_ROTATOR_LOCAL_CMD = (Join-Path $tempRoot 'missing-key-rotator.local.cmd')
                KEY_ROTATOR_SCRIPT = $emptyScriptPath
                NODE_EXE = (Join-Path $tempRoot 'missing-node.exe')
                ROTATOR_PROXY_TOKEN = 'placeholder-inbound-token-value-1234'
                ROTATOR_KEYS = 'placeholder-values'
                ROTATOR_TARGETS = 'placeholder-targets'
            }
        }
    )

    foreach ($case in $asyncCases) {
        $marker = 'launcher-invalid-path-' + [guid]::NewGuid().ToString('N')
        $launcherPath = Join-Path $launcherRoot $case.Name
        $environment = @{
            DEVTOOLS_ROOT = $repoRoot
            DEVTOOLS_LOCAL_CMD = (Join-Path $tempRoot 'missing-devtools.local.cmd')
        }
        foreach ($key in $case.Environment.Keys) {
            $environment[$key] = $case.Environment[$key]
        }
        $arguments = '/d /v:off /c ""{0}" "{1}""' -f $launcherPath, $marker

        try {
            $result = Invoke-CapturedProcess -FileName $env:ComSpec -Arguments $arguments -Environment $environment -TimeoutMs 15000
            if ($result.TimedOut) {
                Add-Failure "launchers/$($case.Name) did not reject an invalid absolute executable path within 15 seconds."
            } elseif ($result.ExitCode -ne 2) {
                Add-Failure "launchers/$($case.Name) returned $($result.ExitCode) for an invalid executable path; expected 2."
            }

            Start-Sleep -Milliseconds 150
            $residualProcesses = @(Get-MarkerProcesses -Marker $marker)
            if ($residualProcesses.Count -gt 0) {
                foreach ($residualProcess in $residualProcesses) {
                    $null = Stop-AgentTestProcessTree `
                        -TargetProcessId $residualProcess.ProcessId `
                        -ExpectedStartTime $residualProcess.CreationDate `
                        -ExpectedCommandMarker $marker
                }
                $residualIds = @($residualProcesses | Select-Object -ExpandProperty ProcessId)
                Add-Failure "launchers/$($case.Name) left process(es) behind after invalid-path rejection: $($residualIds -join ', ')."
            }
        } catch {
            Add-Failure "launchers/$($case.Name) invalid-path probe failed: $($_.Exception.Message)"
        }
    }
} finally {
    if ($tempRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Launcher template validation failed with $($failures.Count) finding(s)."
}

Write-Output "Launcher template validation passed for $($expectedLaunchers.Count) required launchers and $($cmdFiles.Count) CMD files."
