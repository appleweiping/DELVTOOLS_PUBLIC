$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$powerShellInit = Join-Path $repoRoot "tools\agent-shell-init.ps1"
$cmdInit = Join-Path $repoRoot "tools\agent-shell-init.cmd"
$verifier = Join-Path $repoRoot "tools\agent-launcher-verify.ps1"
$taskRunner = Join-Path $repoRoot "tools\agent-launcher-verify-run.cmd"
$taskRunnerScript = Join-Path $repoRoot "tools\agent-launcher-verify-run.ps1"
$launcherTemplateTests = Join-Path $repoRoot "tests\launchers\Test-LauncherTemplates.ps1"

function Write-TestCommandFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (($Lines -join "`r`n") + "`r`n"),
        [System.Text.Encoding]::ASCII
    )
}

function Start-TestProcessWithBomlessStandardInput {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    # Windows PowerShell 5.1 captures Console.InputEncoding when Process.Start
    # creates the redirected stdin writer. Its default UTF-8 encoding emits a
    # BOM, which cmd.exe treats as part of the first command name.
    $previousInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        return $Process.Start()
    } finally {
        [Console]::InputEncoding = $previousInputEncoding
    }
}

function Remove-TestFunction([string]$Name) {
    Remove-Item -LiteralPath ("Function:\global:" + $Name) -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $verifier -PathType Leaf) {
    . $verifier
}
if (Test-Path -LiteralPath $taskRunnerScript -PathType Leaf) {
    . $taskRunnerScript
}
# Dot-sourcing a parameterized script creates its parameter variables in the
# caller's scope. Re-resolve this test fixture value after importing helpers.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

Describe "Portable shell reachability surface" {
    It "ships the shell initializers, read-only verifier, and short task runner" {
        $powerShellInit | Should Exist
        $cmdInit | Should Exist
        $verifier | Should Exist
        $taskRunner | Should Exist
        $taskRunnerScript | Should Exist
    }

    It "keeps every shipped CMD helper CRLF and BOM-free" {
        foreach ($path in @($cmdInit, $taskRunner)) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $hasUtf8Bom = $bytes.Length -ge 3 -and
                $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf
            $hasUtf16Bom = $bytes.Length -ge 2 -and (
                ($bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) -or
                ($bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff)
            )
            ($hasUtf8Bom -or $hasUtf16Bom) | Should Be $false

            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $text | Should Match "`r`n"
            ($text -match '(?<!\r)\n') | Should Be $false
        }
    }

    It "contains no fixed drive checkout path" {
        foreach ($path in @($powerShellInit, $cmdInit, $verifier, $taskRunner, $taskRunnerScript)) {
            (Get-Content -LiteralPath $path -Raw) | Should Not Match '(?i)D:\\devtools'
        }
    }

    It "gives launcher probes a load-tolerant timeout and race-safe process cleanup" {
        $text = Get-Content -LiteralPath $launcherTemplateTests -Raw
        $text | Should Match '\[int\]\$TimeoutMs\s*=\s*(?:1[5-9]\d{3}|[2-9]\d{4,})'
        $text | Should Match 'function Stop-AgentTestProcessTree'
        $text | Should Match '(?s)function Stop-AgentTestProcessTree.*ExpectedStartTime'
        $text | Should Match '(?s)function Stop-AgentTestProcessTree.*ExpectedCommandMarker'
        $text | Should Match 'function Get-MarkerProcesses'
    }

    It "loads in Windows PowerShell 5.1 and PowerShell 7 without changing persistent state" {
        $fixture = Join-Path $TestDrive "host compatibility fixture"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"
        $hosts = @(
            Get-Command powershell.exe, pwsh.exe -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Source -Unique
        )
        $hosts.Count | Should BeGreaterThan 0

        foreach ($hostPath in $hosts) {
            & $hostPath -NoProfile -ExecutionPolicy Bypass -File $powerShellInit `
                -RepoRoot $repoRoot `
                -LauncherRoot (Join-Path $repoRoot "launchers") `
                -WhatIf *> $null
            $LASTEXITCODE | Should Be 0

            & $hostPath -NoProfile -ExecutionPolicy Bypass -File $verifier `
                -RepoRoot $repoRoot `
                -LauncherRoot (Join-Path $repoRoot "launchers") `
                -ProfilePath $profilePath `
                -CmdAutorunPath $autorunPath `
                -Quiet *> $null
            $LASTEXITCODE | Should Be 1
            Test-Path -LiteralPath $profilePath | Should Be $false
            Test-Path -LiteralPath $autorunPath | Should Be $false
        }
    }
}

Describe "PowerShell launcher registration" {
    It "registers every launcher as a global function and preserves arguments and exit codes" {
        $fixtureRoot = Join-Path $TestDrive "portable repo with spaces"
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        $commandName = "shell-probe-" + [guid]::NewGuid().ToString("N")
        $probePath = Join-Path $launcherRoot ($commandName + ".cmd")
        $outputPath = Join-Path $fixtureRoot "probe output.txt"
        Write-TestCommandFile -Path $probePath -Lines @(
            '@echo off',
            'setlocal DisableDelayedExpansion',
            '> "%SHELL_REACHABILITY_OUTPUT%" echo(%~1',
            '>> "%SHELL_REACHABILITY_OUTPUT%" echo(%~2',
            'endlocal & exit /b 37'
        )

        $oldOutput = $env:SHELL_REACHABILITY_OUTPUT
        $oldSentinel = $env:SENTINEL
        try {
            $env:SHELL_REACHABILITY_OUTPUT = $outputPath
            $env:SENTINEL = "must-not-expand"

            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot
            (Get-Command $commandName -ErrorAction Stop).CommandType | Should Be "Function"

            & $commandName '%SENTINEL%' 'space value'
            $LASTEXITCODE | Should Be 37
            @(Get-Content -LiteralPath $outputPath) | Should Be @('%SENTINEL%', 'space value')

            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot
            @(Get-Command $commandName -All | Where-Object CommandType -eq "Function").Count | Should Be 1
        } finally {
            $env:SHELL_REACHABILITY_OUTPUT = $oldOutput
            $env:SENTINEL = $oldSentinel
            Remove-TestFunction -Name $commandName
        }
    }

    It "does not change PATH by default or during WhatIf, and prepends it once when requested" {
        $fixtureRoot = Join-Path $TestDrive "path fixture with spaces"
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        $commandName = "path-probe-" + [guid]::NewGuid().ToString("N")
        Write-TestCommandFile -Path (Join-Path $launcherRoot ($commandName + ".cmd")) -Lines @(
            '@echo off',
            'exit /b 0'
        )

        $oldPath = $env:PATH
        try {
            $env:PATH = "C:\Existing Bin;C:\Other Bin"
            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot
            $env:PATH | Should Be "C:\Existing Bin;C:\Other Bin"

            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot -PrependPath -WhatIf
            $env:PATH | Should Be "C:\Existing Bin;C:\Other Bin"

            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot -PrependPath
            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot -PrependPath
            $parts = @($env:PATH -split ';')
            $parts[0] | Should Be $launcherRoot
            @($parts | Where-Object { $_ -ieq $launcherRoot }).Count | Should Be 1
        } finally {
            $env:PATH = $oldPath
            Remove-TestFunction -Name $commandName
        }
    }

    It "does not register functions during WhatIf" {
        $fixtureRoot = Join-Path $TestDrive "whatif fixture"
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        $commandName = "whatif-probe-" + [guid]::NewGuid().ToString("N")
        Write-TestCommandFile -Path (Join-Path $launcherRoot ($commandName + ".cmd")) -Lines @(
            '@echo off',
            'exit /b 0'
        )

        try {
            & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot -WhatIf
            (Get-Command $commandName -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        } finally {
            Remove-TestFunction -Name $commandName
        }
    }

    It "preserves percent and exclamation marks in launcher paths literally" {
        $oldSentinel = $env:SHELL_PATH_SENTINEL
        $oldOutput = $env:SHELL_REACHABILITY_OUTPUT
        $commandNames = New-Object System.Collections.Generic.List[string]
        try {
            $env:SHELL_PATH_SENTINEL = "expanded-away"
            foreach ($pathFragment in @('%SHELL_PATH_SENTINEL%', '!SHELL_PATH_SENTINEL!')) {
                $fixtureRoot = Join-Path $TestDrive ("repo " + $pathFragment + " with spaces")
                $launcherRoot = Join-Path $fixtureRoot "launchers"
                New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
                $commandName = "literal-path-probe-" + [guid]::NewGuid().ToString("N")
                $commandNames.Add($commandName)
                $outputPath = Join-Path $TestDrive ($commandName + ".txt")
                Write-TestCommandFile `
                    -Path (Join-Path $launcherRoot ($commandName + ".cmd")) `
                    -Lines @(
                        '@echo off',
                        '> "%SHELL_REACHABILITY_OUTPUT%" echo(ok',
                        'exit /b 47'
                    )

                $env:SHELL_REACHABILITY_OUTPUT = $outputPath
                & $powerShellInit -RepoRoot $fixtureRoot -LauncherRoot $launcherRoot
                & $commandName

                $LASTEXITCODE | Should Be 47
                (Get-Content -LiteralPath $outputPath -Raw).Trim() | Should Be "ok"
            }
        } finally {
            $env:SHELL_PATH_SENTINEL = $oldSentinel
            $env:SHELL_REACHABILITY_OUTPUT = $oldOutput
            foreach ($commandName in $commandNames) {
                Remove-TestFunction -Name $commandName
            }
        }
    }
}

Describe "CMD launcher registration" {
    It "registers doskey macros dynamically with a single-pass launcher expansion" {
        $fixtureRoot = Join-Path $TestDrive "cmd repo with spaces"
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        $commandName = "cmd-probe-" + [guid]::NewGuid().ToString("N")
        $probePath = Join-Path $launcherRoot ($commandName + ".cmd")
        $macroPath = Join-Path $fixtureRoot "cmd macro output.txt"
        Write-TestCommandFile -Path $probePath -Lines @(
            '@echo off',
            'setlocal DisableDelayedExpansion',
            '> "%SHELL_REACHABILITY_OUTPUT%" echo(%~1',
            '>> "%SHELL_REACHABILITY_OUTPUT%" echo(%~2',
            'endlocal & exit /b 43'
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /q /v:on /k ""{0}" "{1}" "{2}""' -f `
            $cmdInit, $fixtureRoot, $launcherRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['SHELL_REACHABILITY_MACRO_OUTPUT'] = $macroPath

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            (Start-TestProcessWithBomlessStandardInput -Process $process) | Should Be $true
            $process.StandardInput.WriteLine('doskey /macros > "!SHELL_REACHABILITY_MACRO_OUTPUT!"')
            $process.StandardInput.WriteLine('exit')
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                throw "Interactive cmd probe timed out."
            }
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
        } finally {
            $process.Dispose()
        }

        $macroText = Get-Content -LiteralPath $macroPath -Raw
        $expectedMacro = '{0}="{1}" $*' -f $commandName, $probePath
        $macroText | Should Match ([regex]::Escape($expectedMacro))
        $macroText | Should Not Match ('(?im)^{0}=.*\bcall\b' -f [regex]::Escape($commandName))
    }

    It "keeps percent and exclamation marks literal in the generated CMD AutoRun wrapper" {
        $fixtureRoot = Join-Path $TestDrive "repo %SHELL_PATH_SENTINEL% !SHELL_PATH_SENTINEL!"
        $fixtureTools = Join-Path $fixtureRoot "tools"
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $fixtureTools, $launcherRoot -Force | Out-Null
        Copy-Item -LiteralPath $cmdInit -Destination $fixtureTools
        $commandName = "cmd-literal-path-" + [guid]::NewGuid().ToString("N")
        $probePath = Join-Path $launcherRoot ($commandName + ".cmd")
        Write-TestCommandFile -Path $probePath -Lines @('@echo off', 'exit /b 0')

        $autorunPath = Join-Path $TestDrive "generated autorun.cmd"
        $macroPath = Join-Path $TestDrive "literal macro output.txt"
        $settings = Get-AgentLauncherVerificationSettings `
            -RepoRoot $fixtureRoot `
            -LauncherRoot $launcherRoot `
            -ProfilePath (Join-Path $TestDrive "profile.ps1") `
            -CmdAutorunPath $autorunPath
        [System.IO.File]::WriteAllText(
            $autorunPath,
            (Get-AgentCmdAutorunContent -Settings $settings),
            [System.Text.Encoding]::ASCII
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /q /v:on /k ""{0}""' -f $autorunPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['SHELL_PATH_SENTINEL'] = 'expanded-away'
        $startInfo.EnvironmentVariables['SHELL_REACHABILITY_MACRO_OUTPUT'] = $macroPath

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            (Start-TestProcessWithBomlessStandardInput -Process $process) | Should Be $true
            $process.StandardInput.WriteLine('doskey /macros > "!SHELL_REACHABILITY_MACRO_OUTPUT!"')
            $process.StandardInput.WriteLine('exit')
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                throw "Generated CMD AutoRun probe timed out."
            }
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
        } finally {
            $process.Dispose()
        }

        $macroText = Get-Content -LiteralPath $macroPath -Raw
        $macroText | Should Match ([regex]::Escape(('{0}="{1}" $*' -f $commandName, $probePath)))
    }

    It "escapes DOSKEY dollar metacharacters in literal launcher paths" {
        $fixtureRoot = Join-Path $TestDrive 'cmd repo $T $G $L $B $$ with spaces'
        $launcherRoot = Join-Path $fixtureRoot "launchers"
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        $commandName = "cmd-dollar-probe-" + [guid]::NewGuid().ToString("N")
        $probePath = Join-Path $launcherRoot ($commandName + ".cmd")
        $macroPath = Join-Path $TestDrive "dollar macro output.txt"
        Write-TestCommandFile -Path $probePath -Lines @('@echo off', 'exit /b 0')

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /q /v:off /k ""{0}" "{1}" "{2}""' -f `
            $cmdInit, $fixtureRoot, $launcherRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['SHELL_REACHABILITY_MACRO_OUTPUT'] = $macroPath

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            (Start-TestProcessWithBomlessStandardInput -Process $process) | Should Be $true
            $process.StandardInput.WriteLine('doskey /macros > "%SHELL_REACHABILITY_MACRO_OUTPUT%"')
            $process.StandardInput.WriteLine('exit')
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(15000)) {
                $process.Kill()
                throw "Dollar-metacharacter CMD probe timed out."
            }
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
        } finally {
            $process.Dispose()
        }

        $macroText = Get-Content -LiteralPath $macroPath -Raw
        $escapedProbePath = $probePath.Replace('$', '$$')
        $expectedMacro = '{0}="{1}" $*' -f $commandName, $escapedProbePath
        $macroText | Should Match ([regex]::Escape($expectedMacro))
    }
}

Describe "Native scheduled-task argv transport" {
    It "passes a spaced task action as one native /tr argument" {
        $fixture = Join-Path $TestDrive "native argv fixture with spaces"
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $probePath = Join-Path $fixture "argv probe.ps1"
        $outputPath = Join-Path $fixture "captured argv.txt"
        [System.IO.File]::WriteAllText(
            $probePath,
            @'
param([string]$OutputPath)
[System.IO.File]::WriteAllLines($OutputPath, [string[]]$args)
exit 0
'@,
            [System.Text.Encoding]::ASCII
        )
        $action = New-AgentLauncherVerificationTaskAction `
            -RunnerCommand "C:\Portable Repo\tools\agent-launcher-verify-run.cmd" `
            -SettingsPath "C:\Portable Repo\logs\launcher settings.json"

        Register-AgentLauncherVerificationTask `
            -TaskName "Devtools Launcher Verify Test" `
            -TaskAction $action `
            -SchtasksExecutable (Get-Command powershell.exe).Source `
            -SchtasksArgumentPrefix @('-NoProfile', '-File', $probePath, $outputPath)

        $captured = @(Get-Content -LiteralPath $outputPath)
        $trIndex = [Array]::IndexOf($captured, "/tr")
        $trIndex | Should BeGreaterThan 0
        $captured[$trIndex + 1] | Should Be $action
        @($captured | Where-Object { $_ -eq $action }).Count | Should Be 1
    }

    It "builds deterministic content-versioned settings and stays below the schtasks limit" {
        $settings = Get-AgentLauncherVerificationSettings `
            -RepoRoot 'C:\Portable Repo' `
            -LauncherRoot 'C:\Portable Repo\launchers' `
            -ProfilePath 'C:\User Profiles\profile.ps1' `
            -CmdAutorunPath 'C:\User Profiles\autorun.cmd' `
            -PowerShellExecutable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $first = Get-AgentLauncherVerificationTaskDefinition -Settings $settings
        $second = Get-AgentLauncherVerificationTaskDefinition -Settings $settings

        $first.SettingsPath | Should Be $second.SettingsPath
        $first.SettingsContent | Should Be $second.SettingsContent
        ($first.Action.Length -le 262) | Should Be $true
        $first.SettingsPath | Should Match 'agent-launcher-verify\.settings\.task[0-9a-f]{12}\.[0-9a-f]{24}\.json$'

        $settings.ProfilePath = 'C:\User Profiles\different-profile.ps1'
        $changed = Get-AgentLauncherVerificationTaskDefinition -Settings $settings
        $changed.SettingsPath | Should Not Be $first.SettingsPath
    }

    It "runs only the exact verifier described by strict versioned settings" {
        $fixture = Join-Path $TestDrive 'task runner fixture'
        $tools = Join-Path $fixture 'tools'
        $launchers = Join-Path $fixture 'launchers'
        $settingsPath = Join-Path $fixture 'launcher.settings.json'
        $capturePath = Join-Path $fixture 'runner-argv.txt'
        New-Item -ItemType Directory -Path $tools, $launchers -Force | Out-Null
        $fixtureVerifier = Join-Path $tools 'agent-launcher-verify.ps1'
        [System.IO.File]::WriteAllText(
            $fixtureVerifier,
            @'
param(
    [string]$RepoRoot,
    [string]$LauncherRoot,
    [string]$ProfilePath,
    [string]$CmdAutorunPath,
    [switch]$Apply,
    [switch]$Quiet
)
[System.IO.File]::WriteAllLines(
    $env:AGENT_LAUNCHER_RUNNER_CAPTURE,
    @($RepoRoot, $LauncherRoot, $ProfilePath, $CmdAutorunPath, [string]$Apply, [string]$Quiet)
)
exit 0
'@,
            [System.Text.Encoding]::ASCII
        )
        $payload = [ordered]@{
            schemaVersion = 1
            RepoRoot = $fixture
            LauncherRoot = $launchers
            ProfilePath = Join-Path $fixture 'profile.ps1'
            CmdAutorunPath = Join-Path $fixture 'autorun.cmd'
            PowerShellExecutable = (Get-Command powershell.exe).Source
            VerifierPath = $fixtureVerifier
        }
        [System.IO.File]::WriteAllText(
            $settingsPath,
            ($payload | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
        $savedCapture = $env:AGENT_LAUNCHER_RUNNER_CAPTURE
        try {
            $env:AGENT_LAUNCHER_RUNNER_CAPTURE = $capturePath
            & $taskRunner $settingsPath
            $LASTEXITCODE | Should Be 0
        } finally {
            $env:AGENT_LAUNCHER_RUNNER_CAPTURE = $savedCapture
        }
        $captured = @(Get-Content -LiteralPath $capturePath)
        $captured[0] | Should Be $fixture
        $captured[1] | Should Be $launchers
        $captured[4] | Should Be 'True'
        $captured[5] | Should Be 'True'

        $payload.Unexpected = 'value'
        [System.IO.File]::WriteAllText(
            $settingsPath,
            ($payload | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
        $threw = $false
        try {
            Invoke-AgentLauncherVerificationRunner -SettingsPath $settingsPath | Out-Null
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}

Describe "Raw registry value transport" {
    It "reads expandable strings without expanding environment references" {
        $script:rawRegistryOptions = $null
        $script:rawRegistryKey = New-Object psobject
        $script:rawRegistryKey | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
            param($Name, $DefaultValue, $Options)
            $script:rawRegistryOptions = $Options
            return '%USERPROFILE%\portable-launchers'
        }
        $script:rawRegistryKey | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        Mock Get-Item { return $script:rawRegistryKey } `
            -ParameterFilter { $LiteralPath -eq 'HKCU:\RawRegistryFixture' }

        $actual = Get-AgentRegistryString `
            -LiteralPath 'HKCU:\RawRegistryFixture' `
            -Name 'Path'

        $actual | Should Be '%USERPROFILE%\portable-launchers'
        $script:rawRegistryOptions | Should Be (
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        Assert-MockCalled Get-Item -Times 1 -Scope It
    }
}

Describe "Launcher reachability verification" {
    BeforeEach {
        $script:testUserPath = "C:\Existing Bin"
        $script:testAutoRun = ""
        $script:testRegistryKeys = @(
            "HKCU:\Environment",
            "HKCU:\Software\Microsoft\Command Processor"
        )
        $script:testRegistryReader = {
            param($LiteralPath, $Name)
            if ($LiteralPath -eq "HKCU:\Environment") {
                return [pscustomobject]@{ Path = $script:testUserPath }
            }
            if ($LiteralPath -eq "HKCU:\Software\Microsoft\Command Processor") {
                return [pscustomobject]@{ AutoRun = $script:testAutoRun }
            }
            throw [System.Management.Automation.ItemNotFoundException]::new("missing")
        }
        Mock Test-Path {
            return @($script:testRegistryKeys | Where-Object { $_ -ieq $LiteralPath }).Count -gt 0
        } -ParameterFilter { [string]$LiteralPath -like "HKCU:*" }
        Mock New-Item {
            $script:testRegistryKeys += [string]$Path
            return [pscustomobject]@{ Name = $Path }
        } -ParameterFilter { [string]$Path -like "HKCU:*" }
        Mock Get-ItemProperty {
            if ($LiteralPath -eq "HKCU:\Environment") {
                return [pscustomobject]@{ Path = $script:testUserPath }
            }
            if ($LiteralPath -eq "HKCU:\Software\Microsoft\Command Processor") {
                return [pscustomobject]@{ AutoRun = $script:testAutoRun }
            }
            return $null
        }
        Mock Set-ItemProperty {
            if ($Name -eq "Path") { $script:testUserPath = [string]$Value }
            if ($Name -eq "AutoRun") { $script:testAutoRun = [string]$Value }
        }
        Mock schtasks.exe {
            $global:LASTEXITCODE = 1
            return "task not found"
        }
    }

    It "is read-only by default" {
        $fixture = Join-Path $TestDrive "read only fixture"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"

        $result = Invoke-AgentLauncherVerification `
            -RepoRoot $repoRoot `
            -LauncherRoot (Join-Path $repoRoot "launchers") `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -RegistryReader $script:testRegistryReader

        $result.Before.Healthy | Should Be $false
        Test-Path -LiteralPath $profilePath | Should Be $false
        Test-Path -LiteralPath $autorunPath | Should Be $false
        Assert-MockCalled Set-ItemProperty -Times 0 -Scope It
        Assert-MockCalled New-Item -Times 0 -Scope It -ParameterFilter { [string]$Path -like "HKCU:*" }
        Assert-MockCalled schtasks.exe -Times 0 -Scope It
    }

    It "does not write files, registry values, or a task during WhatIf" {
        $fixture = Join-Path $TestDrive "whatif verify fixture"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"
        $script:taskCalls = @()
        Mock Invoke-AgentNativeProcess {
            $script:taskCalls += ,@($ArgumentList)
            return [pscustomobject]@{ ExitCode = 1; StdOut = ""; StdErr = "task not found" }
        }

        $null = Invoke-AgentLauncherVerification `
            -RepoRoot $repoRoot `
            -LauncherRoot (Join-Path $repoRoot "launchers") `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -RegistryReader $script:testRegistryReader `
            -Apply `
            -RegisterTask `
            -WhatIf

        Test-Path -LiteralPath $profilePath | Should Be $false
        Test-Path -LiteralPath $autorunPath | Should Be $false
        Assert-MockCalled Set-ItemProperty -Times 0 -Scope It
        Assert-MockCalled New-Item -Times 0 -Scope It -ParameterFilter { [string]$Path -like "HKCU:*" }
        @($script:taskCalls | Where-Object { $_ -contains '/create' }).Count | Should Be 0
    }

    It "applies parameterized repairs once while preserving unrelated profile and AutoRun content" {
        $fixture = Join-Path $TestDrive "apply fixture with spaces"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        [System.IO.File]::WriteAllText($profilePath, "# keep-profile`r`n", [System.Text.Encoding]::ASCII)
        $script:testAutoRun = 'echo keep-autorun'

        $first = Invoke-AgentLauncherVerification `
            -RepoRoot $repoRoot `
            -LauncherRoot (Join-Path $repoRoot "launchers") `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -RegistryReader $script:testRegistryReader `
            -Apply
        $profileAfterFirst = [System.IO.File]::ReadAllText($profilePath)
        $autorunAfterFirst = [System.IO.File]::ReadAllBytes($autorunPath)

        $second = Invoke-AgentLauncherVerification `
            -RepoRoot $repoRoot `
            -LauncherRoot (Join-Path $repoRoot "launchers") `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -RegistryReader $script:testRegistryReader `
            -Apply

        $first.After.Healthy | Should Be $true
        $second.Before.Healthy | Should Be $true
        $profileAfterFirst | Should Match '# keep-profile'
        $profileAfterFirst | Should Match 'devtools launcher reachability: begin'
        $profileAfterFirst | Should Match ([regex]::Escape($repoRoot))
        [System.IO.File]::ReadAllText($profilePath) | Should Be $profileAfterFirst

        $wrapperText = [System.Text.Encoding]::UTF8.GetString($autorunAfterFirst)
        $wrapperText | Should Match ([regex]::Escape((Join-Path $repoRoot "tools\agent-shell-init.cmd")))
        $wrapperText | Should Match "`r`n"
        ($wrapperText -match '(?<!\r)\n') | Should Be $false
        ($autorunAfterFirst.Length -ge 3 -and $autorunAfterFirst[0] -eq 0xef -and `
            $autorunAfterFirst[1] -eq 0xbb -and $autorunAfterFirst[2] -eq 0xbf) | Should Be $false

        $script:testAutoRun | Should Match 'echo keep-autorun'
        $script:testAutoRun | Should Match ([regex]::Escape($autorunPath))
        $script:testAutoRun.StartsWith(
            (Get-AgentCmdAutorunCommand -CmdAutorunPath $autorunPath),
            [System.StringComparison]::OrdinalIgnoreCase
        ) | Should Be $true
        @($script:testUserPath -split ';' | Where-Object { $_ -ieq (Join-Path $repoRoot "launchers") }).Count |
            Should Be 1
        Assert-MockCalled Set-ItemProperty -Times 1 -Scope It -ParameterFilter { $Name -eq "Path" }
        Assert-MockCalled Set-ItemProperty -Times 1 -Scope It -ParameterFilter { $Name -eq "AutoRun" }
    }

    It "places its AutoRun wrapper first so an unrelated false IF cannot swallow it" {
        $fixture = Join-Path $TestDrive "autorun precedence fixture"
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $wrapperPath = Join-Path $fixture "managed wrapper.cmd"
        $markerPath = Join-Path $fixture "managed marker.txt"
        Write-TestCommandFile -Path $wrapperPath -Lines @(
            '@echo off',
            '> "%SHELL_REACHABILITY_MARKER%" echo(ok'
        )
        $oldMarker = $env:SHELL_REACHABILITY_MARKER
        try {
            $env:SHELL_REACHABILITY_MARKER = $markerPath
            $required = Get-AgentCmdAutorunCommand -CmdAutorunPath $wrapperPath
            $prior = 'if exist "Z:\definitely-missing-devtools-path" echo(old'
            $merged = Merge-AgentCmdAutorunCommand -Current $prior -Required $required

            $merged.StartsWith($required, [System.StringComparison]::OrdinalIgnoreCase) |
                Should Be $true
            & $env:ComSpec /d /v:off /c $merged *> $null
            Test-Path -LiteralPath $markerPath -PathType Leaf | Should Be $true

            (Test-AgentCmdAutorunConfigured -Current $merged -Required $required) | Should Be $true
            (Test-AgentCmdAutorunConfigured -Current ("echo " + $required) -Required $required) |
                Should Be $false
        } finally {
            $env:SHELL_REACHABILITY_MARKER = $oldMarker
        }
    }

    It "does not expand environment references while comparing persistent PATH entries" {
        $oldSentinel = $env:SHELL_PATH_SENTINEL
        try {
            $env:SHELL_PATH_SENTINEL = "C:\expanded-path"
            (Test-AgentLauncherPathEqual `
                -Left '%SHELL_PATH_SENTINEL%' `
                -Right "C:\expanded-path") | Should Be $false
        } finally {
            $env:SHELL_PATH_SENTINEL = $oldSentinel
        }
    }

    It "fails closed before persistent writes when configured paths contain CMD expansion tokens" {
        $oldSentinel = $env:SHELL_PATH_SENTINEL
        try {
            $env:SHELL_PATH_SENTINEL = "expanded-away"
            foreach ($fragment in @('%SHELL_PATH_SENTINEL%', '!SHELL_PATH_SENTINEL!')) {
                $fixture = Join-Path $TestDrive ("persistent repo " + $fragment)
                $fixtureTools = Join-Path $fixture "tools"
                $fixtureLaunchers = Join-Path $fixture "launchers"
                New-Item -ItemType Directory -Path $fixtureTools, $fixtureLaunchers -Force | Out-Null
                Copy-Item -LiteralPath $powerShellInit -Destination $fixtureTools
                Copy-Item -LiteralPath $cmdInit -Destination $fixtureTools
                Copy-Item -LiteralPath $verifier -Destination $fixtureTools
                Copy-Item -LiteralPath (Join-Path $repoRoot "launchers\uv.cmd") -Destination $fixtureLaunchers
                $profilePath = Join-Path $fixture "profile.ps1"
                $autorunPath = Join-Path $fixture "autorun.cmd"

                $threw = $false
                try {
                    Invoke-AgentLauncherVerification `
                        -RepoRoot $fixture `
                        -LauncherRoot $fixtureLaunchers `
                        -ProfilePath $profilePath `
                        -CmdAutorunPath $autorunPath `
                        -Apply | Out-Null
                } catch {
                    $threw = $true
                }
                $threw | Should Be $true
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $profilePath | Should Be $false
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $autorunPath | Should Be $false
            }
            Assert-MockCalled Set-ItemProperty -Times 0 -Scope It
        } finally {
            $env:SHELL_PATH_SENTINEL = $oldSentinel
        }
    }

    It "decodes legacy ANSI profiles with the current culture ANSI code page" {
        $profilePath = Join-Path $TestDrive "legacy-ansi-profile.ps1"
        $content = "# ANSI " +
            [char]0x4fdd + [char]0x7559 + [char]0x5185 + [char]0x5bb9 +
            "`r`n"
        $ansiCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        $ansi = [System.Text.Encoding]::GetEncoding(
            $ansiCodePage,
            [System.Text.EncoderExceptionFallback]::new(),
            [System.Text.DecoderExceptionFallback]::new()
        )
        [System.IO.File]::WriteAllBytes($profilePath, $ansi.GetBytes($content))

        (Get-AgentDecodedFileText -Path $profilePath) | Should Be $content
    }

    It "writes a BOM-safe profile that Windows PowerShell 5.1 can read with non-ASCII content" {
        $portableName = ([string][char]0x4fbf) + [char]0x643a + " repo with spaces"
        $configPrefix = ([string][char]0x914d) + [char]0x7f6e
        $preservedContent =
            ([string][char]0x4fdd) + [char]0x7559 + [char]0x5185 + [char]0x5bb9
        $fixture = Join-Path $TestDrive $portableName
        $fixtureTools = Join-Path $fixture "tools"
        $fixtureLaunchers = Join-Path $fixture "launchers"
        New-Item -ItemType Directory -Path $fixtureTools, $fixtureLaunchers -Force | Out-Null
        Copy-Item -LiteralPath $powerShellInit -Destination $fixtureTools
        Copy-Item -LiteralPath $cmdInit -Destination $fixtureTools
        Copy-Item -LiteralPath $verifier -Destination $fixtureTools
        Copy-Item -LiteralPath (Join-Path $repoRoot "launchers\uv.cmd") -Destination $fixtureLaunchers

        $profilePath = Join-Path $TestDrive ($configPrefix + " profiles\profile.ps1")
        $autorunPath = Join-Path $TestDrive ($configPrefix + " cmd\autorun.cmd")
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            $profilePath,
            "`$global:ShellProfileProbe = '$preservedContent'`r`n",
            $utf8NoBom
        )

        $result = Invoke-AgentLauncherVerification `
            -RepoRoot $fixture `
            -LauncherRoot $fixtureLaunchers `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -RegistryReader $script:testRegistryReader `
            -Apply

        $result.After.Healthy | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes($profilePath)
        ($bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) | Should Be $true
        [System.IO.File]::ReadAllText($profilePath) |
            Should Match ([regex]::Escape($preservedContent))

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $profilePath *> $null
        $LASTEXITCODE | Should Be 0

        $wrapperBytes = [System.IO.File]::ReadAllBytes($autorunPath)
        $oem = [System.Text.Encoding]::GetEncoding(
            [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage,
            [System.Text.EncoderExceptionFallback]::new(),
            [System.Text.DecoderExceptionFallback]::new()
        )
        $wrapperText = $oem.GetString($wrapperBytes)
        $wrapperText | Should Be (Get-AgentCmdAutorunContent -Settings $result.Settings)

        $macroPath = Join-Path $TestDrive "non-ascii macro output.txt"
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /q /v:off /k ""{0}""' -f $autorunPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['SHELL_REACHABILITY_MACRO_OUTPUT'] = $macroPath
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            (Start-TestProcessWithBomlessStandardInput -Process $process) | Should Be $true
            $process.StandardInput.WriteLine('doskey /macros > "%SHELL_REACHABILITY_MACRO_OUTPUT%"')
            $process.StandardInput.WriteLine('exit')
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(15000)) {
                $process.Kill()
                throw "Non-ASCII generated CMD AutoRun probe timed out."
            }
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
        } finally {
            $process.Dispose()
        }
        $macroText = $oem.GetString([System.IO.File]::ReadAllBytes($macroPath))
        $macroText | Should Match ([regex]::Escape(('uv="{0}" $*' -f (Join-Path $fixtureLaunchers 'uv.cmd'))))
    }

    It "fails closed before any writes when the generated CMD wrapper is not OEM-encodable" {
        $emoji = [string]([char]0xd83e) + [char]0xddea
        $fixture = Join-Path $TestDrive ("portable repo emoji " + $emoji)
        $fixtureTools = Join-Path $fixture "tools"
        $fixtureLaunchers = Join-Path $fixture "launchers"
        New-Item -ItemType Directory -Path $fixtureTools, $fixtureLaunchers -Force | Out-Null
        Copy-Item -LiteralPath $powerShellInit -Destination $fixtureTools
        Copy-Item -LiteralPath $cmdInit -Destination $fixtureTools
        Copy-Item -LiteralPath $verifier -Destination $fixtureTools
        Copy-Item -LiteralPath (Join-Path $repoRoot "launchers\uv.cmd") -Destination $fixtureLaunchers
        $profilePath = Join-Path $TestDrive "emoji profile.ps1"
        $autorunPath = Join-Path $TestDrive "emoji autorun.cmd"

        $threw = $false
        try {
            Invoke-AgentLauncherVerification `
                -RepoRoot $fixture `
                -LauncherRoot $fixtureLaunchers `
                -ProfilePath $profilePath `
                -CmdAutorunPath $autorunPath `
                -Apply | Out-Null
        } catch [System.Text.EncoderFallbackException] {
            $threw = $true
        }
        $threw | Should Be $true
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $profilePath | Should Be $false
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $autorunPath | Should Be $false
        Assert-MockCalled Set-ItemProperty -Times 0 -Scope It
    }

    It "fails closed on registry access errors before Apply writes anything" {
        $fixture = Join-Path $TestDrive "registry denied fixture"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"
        $deniedReader = {
            param($LiteralPath, $Name)
            throw [System.UnauthorizedAccessException]::new("denied")
        }

        $denied = $false
        try {
            Invoke-AgentLauncherVerification `
                -RepoRoot $repoRoot `
                -LauncherRoot (Join-Path $repoRoot "launchers") `
                -ProfilePath $profilePath `
                -CmdAutorunPath $autorunPath `
                -RegistryReader $deniedReader `
                -Apply
        } catch [System.UnauthorizedAccessException] {
            $denied = $true
        }
        $denied | Should Be $true

        Microsoft.PowerShell.Management\Test-Path -LiteralPath $profilePath | Should Be $false
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $autorunPath | Should Be $false
        Assert-MockCalled Set-ItemProperty -Times 0 -Scope It
        Assert-MockCalled New-Item -Times 0 -Scope It -ParameterFilter { [string]$Path -like "HKCU:*" }
    }

    It "treats only missing registry values as empty" {
        $missingReader = {
            param($LiteralPath, $Name)
            throw [System.Management.Automation.ItemNotFoundException]::new("missing")
        }
        (Get-AgentRegistryString `
            -LiteralPath "HKCU:\Missing" `
            -Name "Path" `
            -Reader $missingReader) | Should Be ""

        $deniedReader = {
            param($LiteralPath, $Name)
            throw [System.UnauthorizedAccessException]::new("denied")
        }
        $denied = $false
        try {
            Get-AgentRegistryString `
                -LiteralPath "HKCU:\Denied" `
                -Name "Path" `
                -Reader $deniedReader
        } catch [System.UnauthorizedAccessException] {
            $denied = $true
        }
        $denied | Should Be $true
    }

    It "replaces managed profile blocks literally when paths contain regex replacement tokens" {
        $current = @(
            "# keep-before",
            "# devtools launcher reachability: begin",
            "old managed content",
            "# devtools launcher reachability: end",
            "# keep-after"
        ) -join "`r`n"
        $required = @(
            "# devtools launcher reachability: begin",
            "& 'C:\portable `$& literal\agent-shell-init.ps1'",
            "# devtools launcher reachability: end"
        ) -join "`r`n"

        $merged = Merge-AgentPowerShellProfile -Current $current -RequiredBlock $required

        $merged | Should Match ([regex]::Escape("C:\portable `$& literal"))
        $merged | Should Not Match "old managed content"
        @([regex]::Matches($merged, "devtools launcher reachability: begin")).Count | Should Be 1
    }

    It "preserves original profile bytes and cleans staging files when atomic replacement fails" {
        $fixture = Join-Path $TestDrive "atomic profile fixture"
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $profilePath = Join-Path $fixture "profile.ps1"
        $original = [System.Text.Encoding]::ASCII.GetBytes("# original profile`r`n")
        [System.IO.File]::WriteAllBytes($profilePath, $original)

        Mock Invoke-AgentFileReplace {
            [System.IO.File]::Move($DestinationPath, $BackupPath)
            throw [System.IO.IOException]::new("simulated replace failure")
        }

        $threw = $false
        try {
            Set-AgentUtf8File `
                -Path $profilePath `
                -Content "# replacement`r`n" `
                -Description "test atomic profile update" `
                -EmitBom
        } catch [System.IO.IOException] {
            $threw = $true
        }

        $threw | Should Be $true
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($profilePath)) |
            Should Be ([Convert]::ToBase64String($original))
        @(Get-ChildItem -LiteralPath $fixture -Force -File | Where-Object {
                $_.Name -like '.agent-launcher.*.tmp' -or $_.Name -like '.agent-launcher.*.bak'
            }).Count | Should Be 0
    }

    It "restores original bytes when replacement reports failure after changing the destination" {
        $fixture = Join-Path $TestDrive 'late atomic failure fixture'
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $profilePath = Join-Path $fixture 'profile.ps1'
        $original = [System.Text.Encoding]::ASCII.GetBytes("# late original`r`n")
        [System.IO.File]::WriteAllBytes($profilePath, $original)

        Mock Invoke-AgentFileReplace {
            [System.IO.File]::Copy($DestinationPath, $BackupPath, $true)
            [System.IO.File]::Copy($SourcePath, $DestinationPath, $true)
            throw [System.IO.IOException]::new('simulated late replace failure')
        }

        $threw = $false
        try {
            Set-AgentUtf8File `
                -Path $profilePath `
                -Content "# late replacement`r`n" `
                -Description 'test late atomic profile failure' `
                -EmitBom
        } catch [System.IO.IOException] {
            $threw = $true
        }

        $threw | Should Be $true
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($profilePath)) |
            Should Be ([Convert]::ToBase64String($original))
        @(Get-ChildItem -LiteralPath $fixture -Force -File | Where-Object {
                $_.Name -like '.agent-launcher.*.tmp' -or
                $_.Name -like '.agent-launcher.*.bak' -or
                $_.Name -like '.agent-launcher.*.recovery'
            }).Count | Should Be 0
    }

    It "switches the task only after writing new settings and removes old settings only after exact validation" {
        # Keep this fixture intentionally short so the content-addressed task
        # action exercises handoff ordering rather than the separate /TR limit.
        $fixture = Join-Path $TestDrive 'v'
        $fixtureTools = Join-Path $fixture 'tools'
        $fixtureLaunchers = Join-Path $fixture 'launchers'
        New-Item -ItemType Directory -Path $fixtureTools, $fixtureLaunchers -Force | Out-Null
        foreach ($source in @(
                $powerShellInit,
                $cmdInit,
                $verifier,
                $taskRunner,
                $taskRunnerScript
            )) {
            Copy-Item -LiteralPath $source -Destination $fixtureTools
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'launchers\uv.cmd') -Destination $fixtureLaunchers

        $profilePath = Join-Path $fixture 'profiles\profile.ps1'
        $autorunPath = Join-Path $fixture 'cmd\autorun.cmd'
        $taskName = 'DevtoolsLauncherVerify-VersionedTest'
        $shell = (Get-Command powershell.exe).Source
        $settings = Get-AgentLauncherVerificationSettings `
            -RepoRoot $fixture `
            -LauncherRoot $fixtureLaunchers `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -TaskName $taskName `
            -PowerShellExecutable $shell `
            -ScriptRoot $fixtureTools
        $definition = Get-AgentLauncherVerificationTaskDefinition -Settings $settings
        New-Item -ItemType Directory -Path $definition.SettingsDirectory -Force | Out-Null
        $oldSettings = Join-Path $definition.SettingsDirectory ($definition.SettingsStem + '.old.json')
        [System.IO.File]::WriteAllText($oldSettings, '{"schemaVersion":0}', [System.Text.Encoding]::ASCII)

        $script:taskRegistered = $false
        Mock Test-AgentLauncherVerificationTask { return [bool]$script:taskRegistered }
        Mock Invoke-AgentNativeProcess {
            if ($ArgumentList -notcontains '/create') {
                throw 'Only task creation is expected during this handoff test.'
            }
            (Test-Path -LiteralPath $definition.SettingsPath -PathType Leaf) | Should Be $true
            (Test-AgentLauncherTaskSettings `
                -Path $definition.SettingsPath `
                -ExpectedContent $definition.SettingsContent) | Should Be $true
            (Test-Path -LiteralPath $oldSettings -PathType Leaf) | Should Be $true
            $trIndex = [Array]::IndexOf([object[]]$ArgumentList, '/tr')
            ($trIndex -gt 0) | Should Be $true
            (([string]$ArgumentList[$trIndex + 1]).Length -le 262) | Should Be $true
            $script:taskRegistered = $true
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }

        $result = Invoke-AgentLauncherVerification `
            -RepoRoot $fixture `
            -LauncherRoot $fixtureLaunchers `
            -ProfilePath $profilePath `
            -CmdAutorunPath $autorunPath `
            -TaskName $taskName `
            -PowerShellExecutable $shell `
            -ScriptRoot $fixtureTools `
            -RegistryReader $script:testRegistryReader `
            -Apply `
            -RegisterTask

        $result.After.Healthy | Should Be $true
        (Test-Path -LiteralPath $definition.SettingsPath -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $oldSettings -PathType Leaf) | Should Be $false
        Assert-MockCalled Invoke-AgentNativeProcess -Times 1 -Scope It `
            -ParameterFilter { $ArgumentList -contains '/create' }
    }

    It "validates scheduled-task action, cadence, identity, enabled state, and lifetime from XML" {
        $command = "C:\Program Files\PowerShell\7\pwsh.exe"
        $action = New-AgentLauncherVerificationTaskAction `
            -RunnerCommand $command `
            -SettingsPath "C:\Portable Repo\logs\launcher settings.json"
        $arguments = $action.Substring($command.Length + 3)
        $escapedCommand = [System.Security.SecurityElement]::Escape($command)
        $escapedArguments = [System.Security.SecurityElement]::Escape($arguments)
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $now = [DateTimeOffset]::Parse("2026-01-01T10:00:00+08:00")
        $xml = @"
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals><Principal><UserId>$userSid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><Enabled>true</Enabled></Settings>
  <Triggers><CalendarTrigger><Enabled>true</Enabled><StartBoundary>2026-01-01T09:20:00+08:00</StartBoundary><EndBoundary>2026-12-31T23:59:00+08:00</EndBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger></Triggers>
  <Actions><Exec><Command>$escapedCommand</Command><Arguments>$escapedArguments</Arguments></Exec></Actions>
</Task>
"@

        (Test-AgentLauncherTaskXml `
            -TaskXml $xml `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $true
        $defaultEnabledXml = $xml `
            -replace '<Settings><Enabled>true</Enabled></Settings>', '<Settings />' `
            -replace '<Enabled>true</Enabled><StartBoundary>', '<StartBoundary>'
        (Test-AgentLauncherTaskXml `
            -TaskXml $defaultEnabledXml `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $true
        $nextOccurrenceXml = $xml -replace (
            '2026-01-01T09:20:00\+08:00',
            '2026-01-02T09:20:00+08:00'
        )
        (Test-AgentLauncherTaskXml `
            -TaskXml $nextOccurrenceXml `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $true
        $dstFallbackXml = $xml `
            -replace '2026-01-01T09:20:00\+08:00', '2026-11-01T09:20:00-05:00' `
            -replace '2026-12-31T23:59:00\+08:00', '2027-01-01T23:59:00-05:00'
        (Test-AgentLauncherTaskXml `
            -TaskXml $dstFallbackXml `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now ([DateTimeOffset]::Parse("2026-10-31T09:20:00-04:00"))) | Should Be $true
        (Test-AgentLauncherTaskXml `
            -TaskXml $xml `
            -ExpectedTaskAction ($action + ' unexpected') `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $false
        (Test-AgentLauncherTaskXml `
            -TaskXml $xml `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "08:00" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $false
        (Test-AgentLauncherTaskXml `
            -TaskXml ($xml -replace '<DaysInterval>1</DaysInterval>', '<DaysInterval>2</DaysInterval>') `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $false
        $duplicateExec = $xml -replace '</Actions>', (
            "<Exec><Command>$escapedCommand</Command><Arguments>$escapedArguments</Arguments></Exec></Actions>"
        )
        (Test-AgentLauncherTaskXml `
            -TaskXml $duplicateExec `
            -ExpectedTaskAction $action `
            -ExpectedTaskTime "09:20" `
            -ExpectedUserSid $userSid `
            -Now $now) | Should Be $false

        $unexpectedStructureCases = @(
            ($xml -replace '</Actions>', '<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler></Actions>'),
            ($xml -replace '</Triggers>', '<LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>'),
            ($xml -replace '<ScheduleByDay>', '<Repetition><Interval>PT5M</Interval></Repetition><ScheduleByDay>'),
            ($xml -replace '</Exec>', '<WorkingDirectory>C:\</WorkingDirectory></Exec>'),
            ($xml -replace '<ScheduleByDay>', '<RandomDelay>PT1H</RandomDelay><ScheduleByDay>'),
            ($xml -replace '</StartBoundary>', '</StartBoundary><StartBoundary>2026-01-01T09:20:00+08:00</StartBoundary>'),
            ($xml -replace '</DaysInterval>', '</DaysInterval><DaysInterval>1</DaysInterval>')
        )
        foreach ($unexpectedXml in $unexpectedStructureCases) {
            (Test-AgentLauncherTaskXml `
                -TaskXml $unexpectedXml `
                -ExpectedTaskAction $action `
                -ExpectedTaskTime "09:20" `
                -ExpectedUserSid $userSid `
                -Now $now) | Should Be $false
        }

        $invalidXmlCases = @(
            ($xml -replace [regex]::Escape("<UserId>$userSid</UserId>"), '<UserId>S-1-5-18</UserId>'),
            ($xml -replace '<LogonType>InteractiveToken</LogonType>', '<LogonType>Password</LogonType>'),
            ($xml -replace '<RunLevel>LeastPrivilege</RunLevel>', '<RunLevel>HighestAvailable</RunLevel>'),
            ($xml -replace '<Settings><Enabled>true</Enabled>', '<Settings><Enabled>false</Enabled>'),
            ($xml -replace '<CalendarTrigger><Enabled>true</Enabled>', '<CalendarTrigger><Enabled>false</Enabled>'),
            ($xml -replace '2026-12-31T23:59:00\+08:00', '2025-12-31T23:59:00+08:00'),
            ($xml -replace '2026-01-01T09:20:00\+08:00', '2026-01-03T09:20:00+08:00')
        )
        foreach ($invalidXml in $invalidXmlCases) {
            (Test-AgentLauncherTaskXml `
                -TaskXml $invalidXml `
                -ExpectedTaskAction $action `
                -ExpectedTaskTime "09:20" `
                -ExpectedUserSid $userSid `
                -Now $now) | Should Be $false
        }
    }

    It "uses a short bounded task action and previews without invoking schtasks" {
        $fixture = Join-Path $TestDrive "task fixture with spaces"
        $verifyPath = Join-Path $fixture "tools\agent-launcher-verify.ps1"
        $profilePath = Join-Path $fixture "profiles\profile.ps1"
        $autorunPath = Join-Path $fixture "cmd\autorun.cmd"
        $launcherRoot = Join-Path $fixture "launchers"
        New-Item -ItemType Directory -Path (Split-Path -Parent $verifyPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($verifyPath, "# fixture", [System.Text.Encoding]::ASCII)

        $action = New-AgentLauncherVerificationTaskAction `
            -RunnerCommand (Join-Path $fixture 'tools\agent-launcher-verify-run.cmd') `
            -SettingsPath (Join-Path $fixture 'logs\launcher settings.json')

        $action | Should Match ([regex]::Escape('agent-launcher-verify-run.cmd'))
        $action | Should Match ([regex]::Escape('launcher settings.json'))
        ($action.Length -le 262) | Should Be $true

        $tooLong = 'C:\' + ('x' * 250) + '\settings.json'
        $threw = $false
        try {
            New-AgentLauncherVerificationTaskAction `
                -RunnerCommand 'C:\tools\runner.cmd' `
                -SettingsPath $tooLong | Out-Null
        } catch [System.ArgumentException] {
            $threw = $true
        }
        $threw | Should Be $true

        foreach ($unsafe in @(
                @{ Runner = 'relative\runner.cmd'; Settings = 'C:\settings.json' },
                @{ Runner = 'C:\tools\runner.cmd'; Settings = 'relative\settings.json' },
                @{ Runner = 'C:\unsafe%name\runner.cmd'; Settings = 'C:\settings.json' },
                @{ Runner = 'C:\tools\runner.cmd'; Settings = 'C:\unsafe&name\settings.json' },
                @{ Runner = 'C:\tools\"runner.cmd'; Settings = 'C:\settings.json' }
            )) {
            $unsafeThrew = $false
            try {
                New-AgentLauncherVerificationTaskAction `
                    -RunnerCommand $unsafe.Runner `
                    -SettingsPath $unsafe.Settings | Out-Null
            } catch [System.ArgumentException] {
                $unsafeThrew = $true
            }
            $unsafeThrew | Should Be $true
        }

        Mock Invoke-AgentNativeProcess { throw "native process must not run during WhatIf" }
        Register-AgentLauncherVerificationTask `
            -TaskName "DevtoolsLauncherVerify-Test" `
            -TaskAction $action `
            -WhatIf
        Assert-MockCalled Invoke-AgentNativeProcess -Times 0 -Scope It
    }
}
