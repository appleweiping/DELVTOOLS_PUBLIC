[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoRoot,
    [string]$LauncherRoot,
    [switch]$PrependPath,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

function Resolve-AgentShellPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BasePath $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-AgentShellSettings {
    param(
        [string]$RepoRoot,
        [string]$LauncherRoot,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $defaultRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot ".."))
    $root = $RepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $env:DEVTOOLS_REPO_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $defaultRoot
    }
    $root = Resolve-AgentShellPath -Path $root -BasePath (Get-Location).Path

    $launchers = $LauncherRoot
    if ([string]::IsNullOrWhiteSpace($launchers)) {
        $launchers = $env:DEVTOOLS_LAUNCHER_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($launchers)) {
        $launchers = "launchers"
    }
    $launchers = Resolve-AgentShellPath -Path $launchers -BasePath $root

    return [pscustomobject]@{
        RepoRoot = $root
        LauncherRoot = $launchers
    }
}

function Test-AgentShellPathEqual {
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

function Register-AgentPowerShellLaunchers {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RepoRoot,
        [string]$LauncherRoot,
        [switch]$PrependPath,
        [switch]$PassThru,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $settings = Get-AgentShellSettings `
        -RepoRoot $RepoRoot `
        -LauncherRoot $LauncherRoot `
        -ScriptRoot $ScriptRoot

    if (-not (Test-Path -LiteralPath $settings.LauncherRoot -PathType Container)) {
        throw "Launcher directory does not exist: $($settings.LauncherRoot)"
    }

    $registered = New-Object System.Collections.Generic.List[string]
    $launchers = @(Get-ChildItem -LiteralPath $settings.LauncherRoot -Filter "*.cmd" -File |
        Sort-Object -Property Name)
    $batchInvoker = {
        param(
            [Parameter(Mandatory = $true)][string]$LauncherPath,
            [object[]]$ArgumentList = @()
        )

        $comSpec = $env:ComSpec
        if ([string]::IsNullOrWhiteSpace($comSpec)) {
            $comSpec = Join-Path $env:SystemRoot "System32\cmd.exe"
        }

        # Delayed environment expansion happens after cmd.exe's percent-expansion
        # pass. Values such as %NAME% therefore arrive at the launcher literally
        # instead of being interpreted a second time.
        $prefix = "DEVTOOLS_LAUNCH_ARG_" + [guid]::NewGuid().ToString("N") + "_"
        $tokens = New-Object System.Collections.Generic.List[string]
        $names = New-Object System.Collections.Generic.List[string]
        try {
            $launcherVariable = $prefix + "LAUNCHER"
            $names.Add($launcherVariable)
            [Environment]::SetEnvironmentVariable(
                $launcherVariable,
                $LauncherPath,
                [EnvironmentVariableTarget]::Process
            )
            for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
                $name = $prefix + $index
                $names.Add($name)
                [Environment]::SetEnvironmentVariable(
                    $name,
                    [string]$ArgumentList[$index],
                    [EnvironmentVariableTarget]::Process
                )
                $tokens.Add(('"!{0}!"' -f $name))
            }

            $command = '"!{0}!"' -f $launcherVariable
            if ($tokens.Count -gt 0) {
                $command += " " + ($tokens -join " ")
            }
            & $comSpec /d /v:on /s /c $command
            $launcherExitCode = $LASTEXITCODE
        } finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    $null,
                    [EnvironmentVariableTarget]::Process
                )
            }
        }
        $global:LASTEXITCODE = $launcherExitCode
    }

    foreach ($launcher in $launchers) {
        $name = $launcher.BaseName
        $launcherPathForFunction = $launcher.FullName
        $batchInvokerForFunction = $batchInvoker
        $functionBody = {
            & $batchInvokerForFunction `
                -LauncherPath $launcherPathForFunction `
                -ArgumentList @($args)
        }.GetNewClosure()
        $functionPath = "Function:\global:$name"

        if ($PSCmdlet.ShouldProcess($functionPath, "register launcher function")) {
            Set-Item -LiteralPath $functionPath -Value $functionBody -Force
            $registered.Add($name)
        }
    }

    $pathChanged = $false
    if ($PrependPath) {
        $separator = [System.IO.Path]::PathSeparator
        $existingParts = @(
            ([string]$env:PATH).Split([char]$separator) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $remainingParts = @(
            $existingParts | Where-Object {
                -not (Test-AgentShellPathEqual -Left $_ -Right $settings.LauncherRoot)
            }
        )
        $newPath = (@($settings.LauncherRoot) + $remainingParts) -join [string]$separator

        if ($newPath -cne [string]$env:PATH -and
            $PSCmdlet.ShouldProcess("process PATH", "prepend launcher directory")) {
            $env:PATH = $newPath
            $pathChanged = $true
        }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            RepoRoot = $settings.RepoRoot
            LauncherRoot = $settings.LauncherRoot
            Registered = @($registered)
            PathChanged = $pathChanged
        }
    }
}

Register-AgentPowerShellLaunchers `
    -RepoRoot $RepoRoot `
    -LauncherRoot $LauncherRoot `
    -PrependPath:$PrependPath `
    -PassThru:$PassThru `
    -WhatIf:$WhatIfPreference
