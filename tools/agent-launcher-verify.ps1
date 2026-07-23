[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoRoot,
    [string]$LauncherRoot,
    [string]$ProfilePath,
    [string]$CmdAutorunPath,
    [switch]$Apply,
    [switch]$RegisterTask,
    [string]$TaskName = "DevtoolsAgentLauncherVerify",
    [ValidatePattern('^(?:[01]\d|2[0-3]):[0-5]\d$')][string]$TaskTime = "09:20",
    [string]$PowerShellExecutable,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Resolve-AgentLauncherVerificationPath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Cannot resolve an empty launcher verification path."
    }
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BasePath $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-AgentLauncherVerificationSettings {
    param(
        [string]$RepoRoot,
        [string]$LauncherRoot,
        [string]$ProfilePath,
        [string]$CmdAutorunPath,
        [string]$TaskName = "DevtoolsAgentLauncherVerify",
        [string]$TaskTime = "09:20",
        [string]$PowerShellExecutable,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $defaultRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot ".."))
    $root = $RepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_REPO_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $defaultRoot }
    $root = Resolve-AgentLauncherVerificationPath -Path $root -BasePath (Get-Location).Path

    $launchers = $LauncherRoot
    if ([string]::IsNullOrWhiteSpace($launchers)) { $launchers = $env:DEVTOOLS_LAUNCHER_ROOT }
    if ([string]::IsNullOrWhiteSpace($launchers)) { $launchers = "launchers" }
    $launchers = Resolve-AgentLauncherVerificationPath -Path $launchers -BasePath $root

    $profile = $ProfilePath
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = $env:DEVTOOLS_PROFILE_PATH }
    if ([string]::IsNullOrWhiteSpace($profile)) {
        $profile = [string]$PROFILE.CurrentUserAllHosts
    }
    if ([string]::IsNullOrWhiteSpace($profile)) {
        $documents = [Environment]::GetFolderPath("MyDocuments")
        $profile = Join-Path $documents "PowerShell\profile.ps1"
    }
    $profile = Resolve-AgentLauncherVerificationPath -Path $profile -BasePath $root

    $cmdAutorun = $CmdAutorunPath
    if ([string]::IsNullOrWhiteSpace($cmdAutorun)) { $cmdAutorun = $env:DEVTOOLS_CMD_AUTORUN_PATH }
    if ([string]::IsNullOrWhiteSpace($cmdAutorun)) {
        $userProfile = [Environment]::GetFolderPath("UserProfile")
        if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $env:USERPROFILE }
        $cmdAutorun = Join-Path $userProfile ".devtools-agent-autorun.cmd"
    }
    $cmdAutorun = Resolve-AgentLauncherVerificationPath -Path $cmdAutorun -BasePath $root

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) {
        try {
            $shell = (Get-Process -Id $PID -ErrorAction Stop).Path
        } catch {
            $shell = "powershell.exe"
        }
    }
    if ([System.IO.Path]::IsPathRooted($shell)) {
        $shell = [System.IO.Path]::GetFullPath($shell)
    }

    return [pscustomobject]@{
        RepoRoot = $root
        LauncherRoot = $launchers
        ProfilePath = $profile
        CmdAutorunPath = $cmdAutorun
        PowerShellInit = Join-Path $root "tools\agent-shell-init.ps1"
        CmdInit = Join-Path $root "tools\agent-shell-init.cmd"
        VerifierPath = Join-Path $root "tools\agent-launcher-verify.ps1"
        TaskRunner = Join-Path $root "tools\agent-launcher-verify-run.cmd"
        TaskRunnerScript = Join-Path $root "tools\agent-launcher-verify-run.ps1"
        TaskSettingsBase = Join-Path $root "logs\agent-launcher-verify.settings.json"
        UserEnvironmentKey = "HKCU:\Environment"
        CmdProcessorKey = "HKCU:\Software\Microsoft\Command Processor"
        TaskName = $TaskName
        TaskTime = $TaskTime
        PowerShellExecutable = $shell
    }
}

function ConvertTo-AgentPowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-AgentPowerShellProfileBlock {
    param([Parameter(Mandatory = $true)]$Settings)

    $init = ConvertTo-AgentPowerShellLiteral $Settings.PowerShellInit
    $root = ConvertTo-AgentPowerShellLiteral $Settings.RepoRoot
    $launchers = ConvertTo-AgentPowerShellLiteral $Settings.LauncherRoot
    return @(
        "# devtools launcher reachability: begin",
        "if (Test-Path -LiteralPath $init) {",
        "    & $init -RepoRoot $root -LauncherRoot $launchers",
        "}",
        "# devtools launcher reachability: end"
    ) -join "`r`n"
}

function ConvertTo-AgentCmdBatchLiteral([string]$Value) {
    return $Value.Replace('%', '%%')
}

function Get-AgentCmdAutorunContent {
    param([Parameter(Mandatory = $true)]$Settings)

    $init = ConvertTo-AgentCmdBatchLiteral $Settings.CmdInit
    $root = ConvertTo-AgentCmdBatchLiteral $Settings.RepoRoot
    $launchers = ConvertTo-AgentCmdBatchLiteral $Settings.LauncherRoot
    return (@(
        "@echo off",
        "setlocal EnableExtensions DisableDelayedExpansion",
        "if not exist `"$init`" exit /b 0",
        "`"$init`" `"$root`" `"$launchers`""
    ) -join "`r`n") + "`r`n"
}

function Get-AgentCmdAutorunCommand([string]$CmdAutorunPath) {
    return 'call "{0}"' -f $CmdAutorunPath
}

function Merge-AgentCmdAutorunCommand {
    param(
        [AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$Required
    )

    if ([string]::IsNullOrWhiteSpace($Current)) {
        return $Required
    }

    $existing = $Current.Trim()
    if (Test-AgentCmdAutorunConfigured -Current $existing -Required $Required) {
        return $existing
    }

    # Migrate the legacy layout that appended our wrapper. A preceding false IF
    # can absorb every command to its right, so the managed wrapper must lead.
    $legacySuffix = " & " + $Required
    if ($existing.EndsWith($legacySuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $existing = $existing.Substring(0, $existing.Length - $legacySuffix.Length).TrimEnd()
    }
    if ([string]::IsNullOrWhiteSpace($existing)) {
        return $Required
    }
    return $Required + " & " + $existing
}

function Test-AgentCmdAutorunConfigured {
    param(
        [AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$Required
    )

    if ([string]::IsNullOrWhiteSpace($Current)) {
        return $false
    }
    $configured = $Current.Trim()
    if ($configured.Equals($Required, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $configured.StartsWith(
        $Required + " & ",
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-AgentLauncherPathEqual {
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        $leftPath = [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
        $rightPath = [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
        return $leftPath.Equals($rightPath, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $Left.TrimEnd('\', '/').Equals(
            $Right.TrimEnd('\', '/'),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Test-AgentPersistentShellSettings {
    param([Parameter(Mandatory = $true)]$Settings)

    foreach ($value in @(
        $Settings.RepoRoot,
        $Settings.LauncherRoot,
        $Settings.ProfilePath,
        $Settings.CmdAutorunPath,
        $Settings.PowerShellExecutable,
        $Settings.TaskRunner,
        $Settings.TaskRunnerScript,
        $Settings.TaskSettingsBase
    )) {
        if ([string]$value -match '[%!]') {
            return $false
        }
    }
    return $true
}

function Assert-AgentPersistentShellSettings {
    param([Parameter(Mandatory = $true)]$Settings)

    if (-not (Test-AgentPersistentShellSettings -Settings $Settings)) {
        throw [System.ArgumentException]::new(
            "Persistent launcher wiring does not support percent or exclamation marks in configured paths."
        )
    }
}

function Test-AgentUserPathContains {
    param(
        [AllowEmptyString()][string]$UserPath,
        [Parameter(Mandatory = $true)][string]$RequiredPath
    )

    foreach ($entry in @(([string]$UserPath).Split([char][System.IO.Path]::PathSeparator))) {
        if (Test-AgentLauncherPathEqual -Left $entry -Right $RequiredPath) {
            return $true
        }
    }
    return $false
}

function Merge-AgentUserPath {
    param(
        [AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$RequiredPath
    )

    $parts = @(
        ([string]$Current).Split([char][System.IO.Path]::PathSeparator) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                -not (Test-AgentLauncherPathEqual -Left $_ -Right $RequiredPath)
            }
    )
    return (@($RequiredPath) + $parts) -join [string][System.IO.Path]::PathSeparator
}

function Get-AgentRegistryString {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [scriptblock]$Reader
    )

    try {
        if ($null -ne $Reader) {
            $item = & $Reader $LiteralPath $Name
            $property = $item.PSObject.Properties[$Name]
            if ($null -eq $property) {
                return ""
            }
            return [string]$property.Value
        }

        # Registry provider property reads expand REG_EXPAND_SZ values. Read
        # through RegistryKey so health and merge logic observe literal text.
        $key = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
        try {
            $value = $key.GetValue(
                $Name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        } finally {
            if ($key -is [System.IDisposable]) {
                $key.Dispose()
            }
        }
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException]) {
            return ""
        }
        throw
    }
}

function Set-AgentRegistryString {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if (-not $PSCmdlet.ShouldProcess("$LiteralPath\$Name", "set current-user registry value")) {
        return
    }
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        New-Item -Path $LiteralPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $LiteralPath -Name $Name -Value $Value
}

function Invoke-AgentFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    [System.IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath, $true)
}

function Invoke-AgentFileMove {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    [System.IO.File]::Move($SourcePath, $DestinationPath)
}

function Set-AgentAtomicEncodedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "An atomic file update requires a parent directory."
    }
    [void][System.IO.Directory]::CreateDirectory($parent)
    $token = [Guid]::NewGuid().ToString('N')
    $staged = Join-Path $parent ('.agent-launcher.' + $token + '.tmp')
    $backup = Join-Path $parent ('.agent-launcher.' + $token + '.bak')
    $recovery = Join-Path $parent ('.agent-launcher.' + $token + '.recovery')
    $retainRecoveryArtifacts = $false
    try {
        [System.IO.File]::WriteAllText($staged, $Content, $Encoding)
        if ([System.IO.File]::Exists($resolved)) {
            try {
                Invoke-AgentFileReplace `
                    -SourcePath $staged `
                    -DestinationPath $resolved `
                    -BackupPath $backup
            } catch {
                $replacementError = $_
                if ([System.IO.File]::Exists($backup)) {
                    $retainRecoveryArtifacts = $true
                    try {
                        if ([System.IO.File]::Exists($resolved)) {
                            [System.IO.File]::Replace(
                                $backup,
                                $resolved,
                                $recovery,
                                $true
                            )
                        } else {
                            Invoke-AgentFileMove -SourcePath $backup -DestinationPath $resolved
                        }
                        $retainRecoveryArtifacts = $false
                    } catch {
                        throw [System.IO.IOException]::new(
                            "Atomic replacement failed; recovery artifacts remain beside '$resolved'.",
                            $_.Exception
                        )
                    }
                }
                throw $replacementError
            }
        } else {
            Invoke-AgentFileMove -SourcePath $staged -DestinationPath $resolved
        }
    } finally {
        if ([System.IO.File]::Exists($staged)) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        }
        if (-not $retainRecoveryArtifacts) {
            foreach ($artifact in @($backup, $recovery)) {
                if ([System.IO.File]::Exists($artifact)) {
                    Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

function Set-AgentUtf8File {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$EmitBom
    )

    if (-not $PSCmdlet.ShouldProcess($Path, $Description)) {
        return
    }
    $encoding = New-Object System.Text.UTF8Encoding([bool]$EmitBom)
    Set-AgentAtomicEncodedFile -Path $Path -Content $Content -Encoding $encoding
}

function Get-AgentStrictEncoding([int]$CodePage) {
    return [System.Text.Encoding]::GetEncoding(
        $CodePage,
        (New-Object System.Text.EncoderExceptionFallback),
        (New-Object System.Text.DecoderExceptionFallback)
    )
}

function Get-AgentAnsiEncoding {
    return Get-AgentStrictEncoding `
        -CodePage ([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
}

function Get-AgentCmdEncoding {
    return Get-AgentStrictEncoding `
        -CodePage ([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
}

function Set-AgentEncodedFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not $PSCmdlet.ShouldProcess($Path, $Description)) {
        return
    }
    Set-AgentAtomicEncodedFile -Path $Path -Content $Content -Encoding $Encoding
}

function Get-AgentEncodedFileText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    return $Encoding.GetString([System.IO.File]::ReadAllBytes($Path))
}

function Get-AgentDecodedFileText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return ""
    }

    $offset = 0
    $encoding = $null
    if ($bytes.Length -ge 4 -and
        $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and
        $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff) {
        $encoding = New-Object System.Text.UTF32Encoding($true, $true, $true)
        $offset = 4
    } elseif ($bytes.Length -ge 4 -and
        $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe -and
        $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = New-Object System.Text.UTF32Encoding($false, $true, $true)
        $offset = 4
    } elseif ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
        $offset = 2
    } else {
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            return $strictUtf8.GetString($bytes)
        } catch [System.Text.DecoderFallbackException] {
            return (Get-AgentAnsiEncoding).GetString($bytes)
        }
    }
    return $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Merge-AgentPowerShellProfile {
    param(
        [AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$RequiredBlock
    )

    if ($Current.IndexOf($RequiredBlock, [System.StringComparison]::Ordinal) -ge 0) {
        return $Current
    }

    $start = [regex]::Escape("# devtools launcher reachability: begin")
    $end = [regex]::Escape("# devtools launcher reachability: end")
    $managedPattern = "(?ms)^$start\r?\n.*?^$end(?:\r?\n)?"
    if ([regex]::IsMatch($Current, $managedPattern)) {
        $literalReplacement = $RequiredBlock + "`r`n"
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param($Match)
            return $literalReplacement
        }
        return [regex]::Replace($Current, $managedPattern, $evaluator, 1)
    }

    if ([string]::IsNullOrEmpty($Current)) {
        return $RequiredBlock + "`r`n"
    }
    $separator = if ($Current.EndsWith("`r`n")) {
        ""
    } elseif ($Current.EndsWith("`n")) {
        ""
    } else {
        "`r`n"
    }
    return $Current + $separator + $RequiredBlock + "`r`n"
}

function Get-AgentLauncherStableHash {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [ValidateRange(8, 64)][int]$Length = 24
    )
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $hasher.Dispose()
    }
    return [System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant().Substring(0, $Length)
}

function New-AgentLauncherVerificationTaskAction {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerCommand,
        [Parameter(Mandatory = $true)][string]$SettingsPath
    )

    foreach ($value in @($RunnerCommand, $SettingsPath)) {
        if (-not [System.IO.Path]::IsPathRooted($value)) {
            throw [System.ArgumentException]::new('Scheduled-task runner paths must be absolute.')
        }
        if ($value -match '[\x00-\x1f\x7f\x85\u2028\u2029%!&|<>^]' -or
            $value.IndexOf('"') -ge 0) {
            throw [System.ArgumentException]::new(
                'A scheduled-task argument contains characters that cannot be represented safely.'
            )
        }
    }

    $action = ('"{0}" "{1}"' -f $RunnerCommand, $SettingsPath)
    if ($action.Length -gt 262) {
        throw [System.ArgumentException]::new(
            'The scheduled-task action exceeds the schtasks.exe /TR 262-character limit.'
        )
    }
    return $action
}

function Get-AgentLauncherVerificationTaskDefinition {
    param([Parameter(Mandatory = $true)]$Settings)

    if (-not [System.IO.Path]::IsPathRooted([string]$Settings.PowerShellExecutable)) {
        throw [System.ArgumentException]::new(
            'Scheduled verification requires an absolute PowerShell executable.'
        )
    }
    $payload = [ordered]@{
        schemaVersion = 1
        RepoRoot = [string]$Settings.RepoRoot
        LauncherRoot = [string]$Settings.LauncherRoot
        ProfilePath = [string]$Settings.ProfilePath
        CmdAutorunPath = [string]$Settings.CmdAutorunPath
        PowerShellExecutable = [string]$Settings.PowerShellExecutable
        VerifierPath = [string]$Settings.VerifierPath
    }
    $json = $payload | ConvertTo-Json -Compress
    $taskKey = Get-AgentLauncherStableHash -Value ([string]$Settings.TaskName).ToLowerInvariant() -Length 12
    $contentKey = Get-AgentLauncherStableHash -Value $json -Length 24
    $settingsDirectory = Split-Path -Parent $Settings.TaskSettingsBase
    $settingsStem = [System.IO.Path]::GetFileNameWithoutExtension($Settings.TaskSettingsBase) +
        '.task' + $taskKey
    $settingsPath = Join-Path $settingsDirectory ($settingsStem + '.' + $contentKey + '.json')
    $action = New-AgentLauncherVerificationTaskAction `
        -RunnerCommand $Settings.TaskRunner `
        -SettingsPath $settingsPath

    return [pscustomobject]@{
        Action = $action
        SettingsPath = $settingsPath
        SettingsContent = $json
        SettingsDirectory = $settingsDirectory
        SettingsStem = $settingsStem
    }
}

function Test-AgentLauncherTaskSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedContent
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { return $false }
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $actual = [System.IO.File]::ReadAllText($Path, $encoding)
        return $actual.Equals($ExpectedContent, [System.StringComparison]::Ordinal)
    } catch {
        return $false
    }
}

function Set-AgentLauncherTaskSettings {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'write versioned launcher-verifier task settings')) {
        return
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    Set-AgentAtomicEncodedFile -Path $Path -Content $Content -Encoding $encoding
}

function ConvertTo-AgentNativeArgument {
    param([AllowNull()][AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
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

function Invoke-AgentNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$ArgumentList = @()
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = (@(
        $ArgumentList | ForEach-Object { ConvertTo-AgentNativeArgument -Argument $_ }
    ) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start native process: $FileName"
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
        }
    } finally {
        $process.Dispose()
    }
}

function Split-AgentLauncherTaskAction([string]$TaskAction) {
    if ([string]::IsNullOrWhiteSpace($TaskAction)) {
        return $null
    }
    if ($TaskAction[0] -eq '"') {
        $closingQuote = $TaskAction.IndexOf('"', 1)
        if ($closingQuote -lt 2) { return $null }
        return [pscustomobject]@{
            Command = $TaskAction.Substring(1, $closingQuote - 1)
            Arguments = $TaskAction.Substring($closingQuote + 1).TrimStart()
        }
    }
    $firstSpace = $TaskAction.IndexOf(' ')
    if ($firstSpace -lt 0) {
        return [pscustomobject]@{ Command = $TaskAction; Arguments = "" }
    }
    return [pscustomobject]@{
        Command = $TaskAction.Substring(0, $firstSpace)
        Arguments = $TaskAction.Substring($firstSpace + 1)
    }
}

function Test-AgentLauncherTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$TaskXml,
        [Parameter(Mandatory = $true)][string]$ExpectedTaskAction,
        [Parameter(Mandatory = $true)][string]$ExpectedTaskTime,
        [string]$ExpectedUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    try {
        [xml]$document = $TaskXml
    } catch {
        return $false
    }
    $expected = Split-AgentLauncherTaskAction -TaskAction $ExpectedTaskAction
    if ($null -eq $expected) { return $false }

    $execNodes = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Actions']/*[local-name()='Exec']"
    )
    $actionsContainers = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Actions']"
    )
    $calendarNodes = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Triggers']/*[local-name()='CalendarTrigger']"
    )
    $triggerContainers = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Triggers']"
    )
    $principalNodes = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Principals']/*[local-name()='Principal']"
    )
    if ($actionsContainers.Count -ne 1 -or
        $triggerContainers.Count -ne 1 -or
        $execNodes.Count -ne 1 -or
        $calendarNodes.Count -ne 1 -or
        $principalNodes.Count -ne 1) {
        return $false
    }
    $actionChildren = $actionsContainers[0].SelectNodes('./*')
    $triggerChildren = $triggerContainers[0].SelectNodes('./*')
    $execChildren = $execNodes[0].SelectNodes('./*')
    $commandNodes = $execNodes[0].SelectNodes("./*[local-name()='Command']")
    $argumentsNodes = $execNodes[0].SelectNodes("./*[local-name()='Arguments']")
    $calendarChildren = $calendarNodes[0].SelectNodes('./*')
    $boundaryNodes = $calendarNodes[0].SelectNodes("./*[local-name()='StartBoundary']")
    $scheduleNodes = $calendarNodes[0].SelectNodes("./*[local-name()='ScheduleByDay']")
    $repetitionNodes = $calendarNodes[0].SelectNodes("./*[local-name()='Repetition']")
    if ($actionChildren.Count -ne 1 -or
        $actionChildren[0].LocalName -ne 'Exec' -or
        $triggerChildren.Count -ne 1 -or
        $triggerChildren[0].LocalName -ne 'CalendarTrigger' -or
        $commandNodes.Count -ne 1 -or
        $argumentsNodes.Count -ne 1 -or
        $execChildren.Count -ne 2 -or
        @($execChildren | Where-Object { $_.LocalName -cnotin @('Command', 'Arguments') }).Count -ne 0 -or
        $boundaryNodes.Count -ne 1 -or
        $scheduleNodes.Count -ne 1 -or
        $repetitionNodes.Count -ne 0) {
        return $false
    }
    $allowedCalendarChildren = @('StartBoundary', 'EndBoundary', 'Enabled', 'ScheduleByDay')
    if (@($calendarChildren | Where-Object {
                $_.LocalName -cnotin $allowedCalendarChildren
            }).Count -ne 0) {
        return $false
    }
    $scheduleChildren = $scheduleNodes[0].SelectNodes('./*')
    $daysNodes = $scheduleNodes[0].SelectNodes("./*[local-name()='DaysInterval']")
    if ($scheduleChildren.Count -ne 1 -or
        $daysNodes.Count -ne 1 -or
        $scheduleChildren[0].LocalName -ne 'DaysInterval') {
        return $false
    }
    $commandNode = $commandNodes[0]
    $argumentsNode = $argumentsNodes[0]
    $boundaryNode = $boundaryNodes[0]
    $daysNode = $daysNodes[0]
    $userIdNodes = $principalNodes[0].SelectNodes("./*[local-name()='UserId']")
    $logonTypeNodes = $principalNodes[0].SelectNodes("./*[local-name()='LogonType']")
    $runLevelNodes = $principalNodes[0].SelectNodes("./*[local-name()='RunLevel']")
    $taskEnabledNodes = $document.SelectNodes(
        "/*[local-name()='Task']/*[local-name()='Settings']/*[local-name()='Enabled']"
    )
    $triggerEnabledNodes = $calendarNodes[0].SelectNodes("./*[local-name()='Enabled']")
    $endBoundaryNodes = $calendarNodes[0].SelectNodes("./*[local-name()='EndBoundary']")
    if ($null -eq $commandNode -or
        $null -eq $boundaryNode -or
        $null -eq $daysNode -or
        $userIdNodes.Count -ne 1 -or
        $logonTypeNodes.Count -ne 1 -or
        $runLevelNodes.Count -gt 1 -or
        $taskEnabledNodes.Count -gt 1 -or
        $triggerEnabledNodes.Count -gt 1 -or
        $endBoundaryNodes.Count -gt 1) {
        return $false
    }

    $actualArguments = if ($null -eq $argumentsNode) { "" } else { $argumentsNode.InnerText }
    if (-not $commandNode.InnerText.Equals(
        $expected.Command,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $false
    }
    if (-not $actualArguments.Equals(
        $expected.Arguments,
        [System.StringComparison]::Ordinal
    )) {
        return $false
    }
    if ($daysNode.InnerText.Trim() -ne "1") {
        return $false
    }
    if (-not $userIdNodes[0].InnerText.Trim().Equals(
        $ExpectedUserSid,
        [System.StringComparison]::Ordinal
    )) {
        return $false
    }
    if (-not $logonTypeNodes[0].InnerText.Trim().Equals(
        "InteractiveToken",
        [System.StringComparison]::Ordinal
    )) {
        return $false
    }
    if ($runLevelNodes.Count -eq 1 -and -not $runLevelNodes[0].InnerText.Trim().Equals(
        "LeastPrivilege",
        [System.StringComparison]::Ordinal
    )) {
        return $false
    }
    foreach ($enabledNode in @($taskEnabledNodes) + @($triggerEnabledNodes)) {
        if (-not $enabledNode.InnerText.Trim().Equals(
            "true",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }
    }

    try {
        $boundary = [System.Xml.XmlConvert]::ToDateTimeOffset($boundaryNode.InnerText)
    } catch [System.FormatException] {
        return $false
    }
    # A freshly registered daily task can legitimately point at its next
    # occurrence. Allow one cadence plus daylight-saving offset changes, while
    # rejecting dormant or arbitrarily future schedules.
    if ($boundary -gt $Now.AddHours(26)) {
        return $false
    }
    if ($boundary.ToString(
        "HH:mm",
        [System.Globalization.CultureInfo]::InvariantCulture
    ) -ne $ExpectedTaskTime) {
        return $false
    }

    if ($endBoundaryNodes.Count -eq 1) {
        try {
            $endBoundary = [System.Xml.XmlConvert]::ToDateTimeOffset(
                $endBoundaryNodes[0].InnerText
            )
        } catch [System.FormatException] {
            return $false
        }
        if ($endBoundary -le $Now) {
            return $false
        }
    }
    return $true
}

function Test-AgentLauncherVerificationTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$TaskAction,
        [Parameter(Mandatory = $true)][string]$TaskTime,
        [string]$TaskSettingsPath,
        [AllowEmptyString()][string]$TaskSettingsContent,
        [string]$SchtasksExecutable = "schtasks.exe",
        [string[]]$SchtasksArgumentPrefix = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($TaskSettingsPath) -and
        -not (Test-AgentLauncherTaskSettings `
            -Path $TaskSettingsPath `
            -ExpectedContent $TaskSettingsContent)) {
        return $false
    }

    $arguments = @($SchtasksArgumentPrefix) + @('/query', '/tn', $TaskName, '/xml', 'ONE')
    $result = Invoke-AgentNativeProcess `
        -FileName $SchtasksExecutable `
        -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        return $false
    }
    return Test-AgentLauncherTaskXml `
        -TaskXml $result.StdOut `
        -ExpectedTaskAction $TaskAction `
        -ExpectedTaskTime $TaskTime
}

function Register-AgentLauncherVerificationTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$TaskAction,
        [ValidatePattern('^(?:[01]\d|2[0-3]):[0-5]\d$')][string]$TaskTime = "09:20",
        [string]$SchtasksExecutable = "schtasks.exe",
        [string[]]$SchtasksArgumentPrefix = @()
    )

    if (-not $PSCmdlet.ShouldProcess($TaskName, "register daily launcher verification task")) {
        return
    }
    if ($TaskAction.Length -gt 262) {
        throw [System.ArgumentException]::new(
            'The scheduled-task action exceeds the schtasks.exe /TR 262-character limit.'
        )
    }

    $arguments = @($SchtasksArgumentPrefix) + @(
        '/create', '/tn', $TaskName, '/tr', $TaskAction,
        '/sc', 'DAILY', '/st', $TaskTime, '/f'
    )
    $result = Invoke-AgentNativeProcess `
        -FileName $SchtasksExecutable `
        -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        $detail = ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            throw "schtasks.exe could not register launcher verification task '$TaskName'."
        }
        throw "schtasks.exe could not register launcher verification task '$TaskName': $detail"
    }
}

function Get-AgentLauncherVerificationState {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [switch]$RegisterTask,
        [scriptblock]$RegistryReader
    )

    $profileBlock = Get-AgentPowerShellProfileBlock -Settings $Settings
    $profileText = if (Test-Path -LiteralPath $Settings.ProfilePath -PathType Leaf) {
        Get-AgentDecodedFileText -Path $Settings.ProfilePath
    } else {
        ""
    }
    $wrapperContent = Get-AgentCmdAutorunContent -Settings $Settings
    $wrapperText = if (Test-Path -LiteralPath $Settings.CmdAutorunPath -PathType Leaf) {
        try {
            Get-AgentEncodedFileText `
                -Path $Settings.CmdAutorunPath `
                -Encoding (Get-AgentCmdEncoding)
        } catch [System.Text.DecoderFallbackException] {
            $null
        }
    } else {
        ""
    }
    $userPath = Get-AgentRegistryString `
        -LiteralPath $Settings.UserEnvironmentKey `
        -Name "Path" `
        -Reader $RegistryReader
    $cmdAutoRun = Get-AgentRegistryString `
        -LiteralPath $Settings.CmdProcessorKey `
        -Name "AutoRun" `
        -Reader $RegistryReader
    $cmdAutoRunCommand = Get-AgentCmdAutorunCommand -CmdAutorunPath $Settings.CmdAutorunPath
    $taskDefinition = if ($RegisterTask) {
        Get-AgentLauncherVerificationTaskDefinition -Settings $Settings
    } else {
        $null
    }
    $taskAction = if ($null -ne $taskDefinition) { $taskDefinition.Action } else { '' }
    $taskConfigured = if ($RegisterTask) {
        Test-AgentLauncherVerificationTask `
            -TaskName $Settings.TaskName `
            -TaskAction $taskAction `
            -TaskTime $Settings.TaskTime `
            -TaskSettingsPath $taskDefinition.SettingsPath `
            -TaskSettingsContent $taskDefinition.SettingsContent
    } else {
        $true
    }
    $launcherCount = if (Test-Path -LiteralPath $Settings.LauncherRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $Settings.LauncherRoot -Filter "*.cmd" -File).Count
    } else {
        0
    }

    $state = [ordered]@{
        PersistentPathsSafe = Test-AgentPersistentShellSettings -Settings $Settings
        PowerShellInitPresent = Test-Path -LiteralPath $Settings.PowerShellInit -PathType Leaf
        CmdInitPresent = Test-Path -LiteralPath $Settings.CmdInit -PathType Leaf
        VerifierPresent = Test-Path -LiteralPath $Settings.VerifierPath -PathType Leaf
        LauncherCount = $launcherCount
        ProfileConfigured = $profileText.IndexOf(
            $profileBlock,
            [System.StringComparison]::Ordinal
        ) -ge 0
        CmdWrapperConfigured = $wrapperText -ceq $wrapperContent
        CmdAutoRunConfigured = Test-AgentCmdAutorunConfigured `
            -Current $cmdAutoRun `
            -Required $cmdAutoRunCommand
        UserPathConfigured = Test-AgentUserPathContains `
            -UserPath $userPath `
            -RequiredPath $Settings.LauncherRoot
        TaskRequested = [bool]$RegisterTask
        TaskConfigured = [bool]$taskConfigured
        TaskAction = $taskAction
        TaskSettingsPath = if ($null -ne $taskDefinition) { $taskDefinition.SettingsPath } else { '' }
    }
    $state.Healthy = [bool](
        $state.PersistentPathsSafe -and
        $state.PowerShellInitPresent -and
        $state.CmdInitPresent -and
        $state.VerifierPresent -and
        $state.LauncherCount -gt 0 -and
        $state.ProfileConfigured -and
        $state.CmdWrapperConfigured -and
        $state.CmdAutoRunConfigured -and
        $state.UserPathConfigured -and
        $state.TaskConfigured
    )
    return [pscustomobject]$state
}

function Invoke-AgentLauncherVerification {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RepoRoot,
        [string]$LauncherRoot,
        [string]$ProfilePath,
        [string]$CmdAutorunPath,
        [switch]$Apply,
        [switch]$RegisterTask,
        [string]$TaskName = "DevtoolsAgentLauncherVerify",
        [string]$TaskTime = "09:20",
        [string]$PowerShellExecutable,
        [string]$ScriptRoot = $PSScriptRoot,
        [scriptblock]$RegistryReader
    )

    $settings = Get-AgentLauncherVerificationSettings `
        -RepoRoot $RepoRoot `
        -LauncherRoot $LauncherRoot `
        -ProfilePath $ProfilePath `
        -CmdAutorunPath $CmdAutorunPath `
        -TaskName $TaskName `
        -TaskTime $TaskTime `
        -PowerShellExecutable $PowerShellExecutable `
        -ScriptRoot $ScriptRoot
    $taskDefinition = if ($RegisterTask) {
        Get-AgentLauncherVerificationTaskDefinition -Settings $settings
    } else {
        $null
    }
    if ($Apply) {
        Assert-AgentPersistentShellSettings -Settings $settings

        # Validate the complete wrapper before any profile, registry, or task
        # mutation so an unrepresentable path cannot leave partial wiring.
        $cmdEncoding = Get-AgentCmdEncoding
        $cmdWrapperContent = Get-AgentCmdAutorunContent -Settings $settings
        [void]$cmdEncoding.GetBytes($cmdWrapperContent)
        if ($RegisterTask) {
            foreach ($requiredTaskFile in @(
                    $settings.TaskRunner,
                    $settings.TaskRunnerScript,
                    $settings.VerifierPath,
                    $settings.PowerShellExecutable
                )) {
                if (-not [System.IO.Path]::IsPathRooted($requiredTaskFile) -or
                    -not (Test-Path -LiteralPath $requiredTaskFile -PathType Leaf)) {
                    throw "Cannot register launcher verification: a required absolute task dependency is missing."
                }
            }
        }
    }
    $before = Get-AgentLauncherVerificationState `
        -Settings $settings `
        -RegisterTask:$RegisterTask `
        -RegistryReader $RegistryReader

    if ($Apply) {
        if (-not $before.PowerShellInitPresent -or
            -not $before.CmdInitPresent -or
            -not $before.VerifierPresent -or
            $before.LauncherCount -lt 1) {
            throw "Cannot apply launcher reachability: required scripts or launchers are missing."
        }

        if (-not $before.ProfileConfigured) {
            $requiredBlock = Get-AgentPowerShellProfileBlock -Settings $settings
            $currentProfile = if (Test-Path -LiteralPath $settings.ProfilePath -PathType Leaf) {
                Get-AgentDecodedFileText -Path $settings.ProfilePath
            } else {
                ""
            }
            $newProfile = Merge-AgentPowerShellProfile `
                -Current $currentProfile `
                -RequiredBlock $requiredBlock
            Set-AgentUtf8File `
                -Path $settings.ProfilePath `
                -Content $newProfile `
                -Description "wire portable launcher initialization" `
                -EmitBom `
                -WhatIf:$WhatIfPreference
        }

        if (-not $before.CmdWrapperConfigured) {
            Set-AgentEncodedFile `
                -Path $settings.CmdAutorunPath `
                -Content $cmdWrapperContent `
                -Encoding $cmdEncoding `
                -Description "write CMD AutoRun wrapper" `
                -WhatIf:$WhatIfPreference
        }

        if (-not $before.CmdAutoRunConfigured) {
            $currentAutoRun = Get-AgentRegistryString `
                -LiteralPath $settings.CmdProcessorKey `
                -Name "AutoRun" `
                -Reader $RegistryReader
            $requiredAutoRun = Get-AgentCmdAutorunCommand -CmdAutorunPath $settings.CmdAutorunPath
            $newAutoRun = Merge-AgentCmdAutorunCommand `
                -Current $currentAutoRun `
                -Required $requiredAutoRun
            Set-AgentRegistryString `
                -LiteralPath $settings.CmdProcessorKey `
                -Name "AutoRun" `
                -Value $newAutoRun `
                -WhatIf:$WhatIfPreference
        }

        if (-not $before.UserPathConfigured) {
            $currentUserPath = Get-AgentRegistryString `
                -LiteralPath $settings.UserEnvironmentKey `
                -Name "Path" `
                -Reader $RegistryReader
            $newUserPath = Merge-AgentUserPath `
                -Current $currentUserPath `
                -RequiredPath $settings.LauncherRoot
            Set-AgentRegistryString `
                -LiteralPath $settings.UserEnvironmentKey `
                -Name "Path" `
                -Value $newUserPath `
                -WhatIf:$WhatIfPreference
        }

        if ($RegisterTask -and -not $before.TaskConfigured) {
            Set-AgentLauncherTaskSettings `
                -Path $taskDefinition.SettingsPath `
                -Content $taskDefinition.SettingsContent `
                -WhatIf:$WhatIfPreference
            Register-AgentLauncherVerificationTask `
                -TaskName $settings.TaskName `
                -TaskAction $taskDefinition.Action `
                -TaskTime $settings.TaskTime `
                -WhatIf:$WhatIfPreference
            if (-not $WhatIfPreference) {
                $registered = Test-AgentLauncherVerificationTask `
                    -TaskName $settings.TaskName `
                    -TaskAction $taskDefinition.Action `
                    -TaskTime $settings.TaskTime `
                    -TaskSettingsPath $taskDefinition.SettingsPath `
                    -TaskSettingsContent $taskDefinition.SettingsContent
                if (-not $registered) {
                    throw 'The launcher verification task did not match the requested definition after registration.'
                }
                Get-ChildItem `
                    -LiteralPath $taskDefinition.SettingsDirectory `
                    -File `
                    -Filter ($taskDefinition.SettingsStem + '.*.json') `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -ne $taskDefinition.SettingsPath } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $after = if ($Apply -and -not $WhatIfPreference) {
        Get-AgentLauncherVerificationState `
            -Settings $settings `
            -RegisterTask:$RegisterTask `
            -RegistryReader $RegistryReader
    } else {
        $before
    }
    return [pscustomobject]@{
        Settings = $settings
        ApplyRequested = [bool]$Apply
        Preview = [bool]$WhatIfPreference
        Before = $before
        After = $after
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-AgentLauncherVerification `
        -RepoRoot $RepoRoot `
        -LauncherRoot $LauncherRoot `
        -ProfilePath $ProfilePath `
        -CmdAutorunPath $CmdAutorunPath `
        -Apply:$Apply `
        -RegisterTask:$RegisterTask `
        -TaskName $TaskName `
        -TaskTime $TaskTime `
        -PowerShellExecutable $PowerShellExecutable `
        -WhatIf:$WhatIfPreference

    if (-not $Quiet) {
        $state = $result.After
        $label = if ($state.Healthy) { "healthy" } else { "drift" }
        Write-Output (
            "Launcher reachability: {0}; launchers={1}; profile={2}; cmd={3}; path={4}; task={5}" -f `
            $label,
            $state.LauncherCount,
            $state.ProfileConfigured,
            ($state.CmdWrapperConfigured -and $state.CmdAutoRunConfigured),
            $state.UserPathConfigured,
            $state.TaskConfigured
        )
    }
    if ($result.After.Healthy) { exit 0 }
    exit 1
}
