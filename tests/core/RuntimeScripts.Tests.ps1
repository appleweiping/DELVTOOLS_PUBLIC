$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$runtimeScripts = @(
    "agentmemory-server.ps1",
    "agentmemory-selfheal.ps1",
    "agentmemory-health-daily.ps1",
    "agentmemory-watchdog-loop.ps1",
    "agentmemory-watchdog-register.ps1",
    "agentmemory-watchdog-run.ps1",
    "health-check.ps1",
    "codex-health.ps1",
    "codex-agent-report.ps1"
)

function Get-RuntimeScriptPath([string]$Name) {
    return Join-Path $repoRoot $Name
}

function Import-RuntimeScript([string]$Name) {
    $path = Get-RuntimeScriptPath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Runtime script is missing: $Name"
    }

    $text = Get-Content -LiteralPath $path -Raw
    if ($text -notmatch [regex]::Escape("`$MyInvocation.InvocationName -ne '.'")) {
        throw "Runtime script cannot be imported safely for behavior tests: $Name"
    }

    . $path
}

# Pester 3 executes setup blocks in child scopes. Import the guarded scripts at
# file scope so their pure helper functions remain visible to every test.
foreach ($name in $runtimeScripts) {
    $path = Get-RuntimeScriptPath $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = Get-Content -LiteralPath $path -Raw
        if ($text -match [regex]::Escape("`$MyInvocation.InvocationName -ne '.'")) {
            . $path
        }
    }
}

function New-AgentMemoryRuntimeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$Port = 4111
    )
    $config = Join-Path $Root 'agentmemory-iii.yaml'
    $data = Join-Path $Root 'memory-data'
    $logs = Join-Path $Root 'logs'
    $install = Join-Path $Root 'npm-global'
    $node = Join-Path $Root 'node\node.exe'
    $iii = Join-Path $install 'iii.exe'
    $manifest = Join-Path $install 'node_modules\@agentmemory\agentmemory\package.json'
    $entry = Join-Path $install 'node_modules\@agentmemory\agentmemory\dist\index.mjs'
    $server = Join-Path $Root 'agentmemory-server.ps1'
    $guard = Join-Path $Root 'agentmemory-host-guard.mjs'
    $supervisor = Join-Path $Root 'agentmemory-runtime-supervisor.mjs'
    foreach ($path in @($config, $node, $iii, $manifest, $entry, $server, $guard, $supervisor)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'agentmemory-iii.yaml') -Destination $config -Force
    Set-Content -LiteralPath $node -Value 'node-fixture' -Encoding ASCII
    Set-Content -LiteralPath $iii -Value 'iii-fixture' -Encoding ASCII
    Set-Content -LiteralPath $manifest -Value '{"name":"@agentmemory/agentmemory","version":"0.9.27"}' -Encoding ASCII
    Set-Content -LiteralPath $entry -Value '// agentmemory entry fixture' -Encoding ASCII
    Set-Content -LiteralPath $server -Value '# server fixture' -Encoding ASCII
    Set-Content -LiteralPath $guard -Value '// guard fixture' -Encoding ASCII
    Set-Content -LiteralPath $supervisor -Value '// supervisor fixture' -Encoding ASCII
    [pscustomobject]@{
        Root = $Root
        Config = $config
        DataRoot = $data
        LogDir = $logs
        InstallRoot = $install
        NodeExecutable = $node
        IiiExecutable = $iii
        ServerScript = $server
        GuardScript = $guard
        SupervisorScript = $supervisor
        AgentMemoryEntry = $entry
        RuntimeConfig = Join-Path $logs ("agentmemory-iii.active.$Port.yaml")
    }
}

function Get-AgentMemoryFixtureSupervisorCommand {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [int]$Port = 4111
    )
    return (
        "`"$($Fixture.NodeExecutable)`" `"$($Fixture.SupervisorScript)`" " +
        "--iii-executable `"$($Fixture.IiiExecutable)`" " +
        "--iii-config `"$($Fixture.RuntimeConfig)`" " +
        "--agentmemory-entry `"$($Fixture.AgentMemoryEntry)`" " +
        "--guard-script `"$($Fixture.GuardScript)`" " +
        "--listen-port $Port --upstream-port 6000 --stream-port 6667 --engine-port 10080"
    )
}

function Test-RuntimeThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $false
    } catch {
        return $true
    }
}

Describe "Public runtime script surface" {
    # Pester 3 can publish its Windows temp root through an 8.3 alias such as
    # RUNNER~1. Match the runtime's existing-path normalization without changing
    # Pester's global drive or weakening production identity comparisons.
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    It "ships the daily health and watchdog scripts" {
        foreach ($name in @(
            "agentmemory-health-daily.ps1",
            "agentmemory-watchdog-loop.ps1",
            "agentmemory-watchdog-register.ps1",
            "agentmemory-watchdog-run.ps1",
            "agentmemory-watchdog-run.cmd"
        )) {
            (Get-RuntimeScriptPath $name) | Should Exist
        }
    }

    It "parses every PowerShell runtime script" {
        foreach ($name in $runtimeScripts) {
            $path = Get-RuntimeScriptPath $name
            $path | Should Exist
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should Be 0
        }
    }

    It "contains no hard-coded private devtools root" {
        foreach ($name in $runtimeScripts) {
            $path = Get-RuntimeScriptPath $name
            if (Test-Path -LiteralPath $path) {
                (Get-Content -LiteralPath $path -Raw) | Should Not Match '(?i)D:\\devtools'
            }
        }
    }

    It "makes executable scripts safe to dot-source" {
        $guardPattern = [regex]::Escape("`$MyInvocation.InvocationName -ne '.'")
        foreach ($name in $runtimeScripts) {
            $path = Get-RuntimeScriptPath $name
            if (Test-Path -LiteralPath $path) {
                (Get-Content -LiteralPath $path -Raw) | Should Match $guardPattern
            }
        }
    }

    It "pins DPAPI-backed local agentmemory MCP clients without npx or plaintext credentials" {
        $claudePath = Join-Path $repoRoot "examples\claude-mcp.agentmemory.example.json"
        $codexPath = Join-Path $repoRoot "examples\codex-config.agentmemory.example.toml"
        $claudeText = Get-Content -LiteralPath $claudePath -Raw
        $codexText = Get-Content -LiteralPath $codexPath -Raw
        $claude = $claudeText | ConvertFrom-Json

        $claudeText | Should Not Match '(?i)\bnpx(?:\.cmd)?\b'
        $codexText | Should Not Match '(?i)\bnpx(?:\.cmd)?\b'
        $claude.mcpServers.agentmemory.command | Should Be 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        @($claude.mcpServers.agentmemory.args).Count | Should Be 7
        (@($claude.mcpServers.agentmemory.args) -join '|') | Should Be '-NoProfile|-ExecutionPolicy|Bypass|-File|D:\devtools\agentmemory-mcp-dpapi.ps1|-SettingsPath|D:\devtools\logs\agentmemory-watchdog.settings.port3111.taskREPLACE_WITH_TASK_KEY.json'
        $codexText | Should Match "command\s*=\s*'C:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'"
        $codexText | Should Match "args\s*=\s*\['-NoProfile',\s*'-ExecutionPolicy',\s*'Bypass',\s*'-File',\s*'D:\\devtools\\agentmemory-mcp-dpapi\.ps1',\s*'-SettingsPath',\s*'D:\\devtools\\logs\\agentmemory-watchdog\.settings\.port3111\.taskREPLACE_WITH_TASK_KEY\.json'\]"
        $codexText | Should Not Match '(?m)^\s*type\s*='
        $codexText | Should Not Match '(?m)^\s*env_vars\s*='
        $codexText | Should Match 'env\s*=\s*\{\s*AGENTMEMORY_TOOLS\s*=\s*"all"\s*\}'
        $claude.mcpServers.agentmemory.env.AGENTMEMORY_TOOLS | Should Be 'all'
        $claudeText | Should Not Match '(?i)AGENTMEMORY_(?:SECRET|URL)'
        $codexText | Should Not Match '(?i)AGENTMEMORY_(?:SECRET|URL)\s*='
        $codexText | Should Match 'startup_timeout_sec\s*=\s*(?:6[0-9]|[7-9][0-9]|[1-9][0-9]{2,})'
    }

    It "pins the documented agentmemory package pair and engine version" {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $map = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\upstream-memory-systems-map.md') -Raw

        $readme | Should Match '@agentmemory/agentmemory@0\.9\.27'
        $readme | Should Match '@agentmemory/mcp@0\.9\.27'
        $readme | Should Match 'iii/v0\.11\.2/iii-x86_64-pc-windows-msvc\.zip'
        $readme | Should Match '6b1a624be64367aadcbcf5654543fc3029ebb73f3092f4de0d85c3e2e7fac402'
        $readme | Should Match '2447bc21906a6b5be270868da7e74a1c744a4644cf3bd4b37a228ba4e55478ca'
        $readme | Should Match '10336536'
        $readme | Should Match 'Node `22\.21\.1`'
        $readme | Should Match '3c624e9fbe07e3217552ec52a0f84e2bdc2e6ffa7348f3fdfb9fbf8f42e23fcf'
        $readme | Should Match '471961cb355311c9a9dd8ba417eca8269ead32a2231653084112554cda52e8b3'
        $map | Should Match '@agentmemory/agentmemory` version `0\.9\.27`'
        $map | Should Match '@agentmemory/mcp` version `0\.9\.27`'
        $map | Should Match '`iii\.exe` version `0\.11\.2`'
    }

    It "ships a CRLF no-BOM agentmemory command wrapper that forwards arguments and exit codes" {
        $source = Join-Path $repoRoot "agentmemory-server.cmd"
        $bytes = [System.IO.File]::ReadAllBytes($source)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) | Should Be $false
        $sourceText = [System.Text.Encoding]::ASCII.GetString($bytes)
        $sourceText | Should Match "`r`n"
        ([regex]::Matches($sourceText, '(?<!\r)\n').Count) | Should Be 0
        $sourceText | Should Match '%\*'
        $sourceText | Should Match 'setlocal DisableDelayedExpansion'

        $wrapper = Join-Path $TestDrive "agentmemory-server.cmd"
        $probe = Join-Path $TestDrive "agentmemory-selfheal.ps1"
        $output = Join-Path $TestDrive "agentmemory-wrapper-args.txt"
        Copy-Item -LiteralPath $source -Destination $wrapper
        @'
param([string]$BaseUrl, [string]$Marker)
[System.IO.File]::WriteAllText($env:AGENTMEMORY_WRAPPER_OUTPUT, "$BaseUrl|$Marker")
exit 37
'@ | Set-Content -LiteralPath $probe -Encoding ASCII

        $previousOutput = $env:AGENTMEMORY_WRAPPER_OUTPUT
        try {
            $env:AGENTMEMORY_WRAPPER_OUTPUT = $output
            & $wrapper -BaseUrl "http://127.0.0.1:4111" -Marker "space value"
            $exitCode = $LASTEXITCODE
        } finally {
            $env:AGENTMEMORY_WRAPPER_OUTPUT = $previousOutput
        }

        $exitCode | Should Be 37
        (Get-Content -LiteralPath $output -Raw) | Should Be "http://127.0.0.1:4111|space value"
    }
}

Describe "agentmemory self-heal behavior" {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        Mock Get-AgentMemorySelfHealRequiredSecret { return ('A1b2C3d4_' * 4) }
    }

    It "canonicalizes the endpoint and tracks a port-specific active config" {
        $root = Join-Path $TestDrive 'SelfHealSettings'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $settings = Get-AgentMemorySelfHealSettings `
            -DevToolsRoot $root `
            -BaseUrl 'http://localhost:4111' `
            -Config $fixture.Config `
            -LogDir $fixture.LogDir

        $settings.BaseUrl | Should Be 'http://127.0.0.1:4111'
        $settings.RuntimeConfig | Should Be $fixture.RuntimeConfig
        $settings.NodeExecutable | Should Be $fixture.NodeExecutable
    }

    It "requires consecutive exact-version identity probes" {
        $script:selfHealProbeCount = 0
        Mock Invoke-RestMethod {
            if ($Headers.Authorization -ne ('Bearer ' + ('A1b2C3d4_' * 4))) {
                throw 'missing authenticated request header'
            }
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                $script:selfHealProbeCount++
                if ($script:selfHealProbeCount -lt 3) { throw 'simulated slow probe' }
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=3111; upstreamPort=6000
                }
            }
            [pscustomobject]@{
                service='agentmemory'; status='healthy'; version='0.9.27'
                viewerPort=6002; viewerSkipped=$false
            }
        }

        $healthy = Test-AgentMemoryHealth `
            -BaseUrl 'http://127.0.0.1:3111' `
            -ExpectedVersion '0.9.27' `
            -Attempts 3 `
            -GapSeconds 0 `
            -TimeoutSeconds 25

        $healthy | Should Be $true
        $script:selfHealProbeCount | Should Be 3
    }

    It "rejects foreign, stale, unhealthy, fallback-viewer, or skipped-viewer health" {
        foreach ($response in @(
                [pscustomobject]@{ service = 'other'; status = 'healthy'; version = '0.9.27' },
                [pscustomobject]@{ service = 'agentmemory'; status = 'healthy'; version = '0.9.26' },
                [pscustomobject]@{ service = 'agentmemory'; status = 'degraded'; version = '0.9.27' },
                [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6003; viewerSkipped=$false
                },
                [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6002; viewerSkipped=$true
                }
            )) {
            $script:healthFixture = $response
            Mock Invoke-RestMethod {
                if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                    return [pscustomobject]@{
                        service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                        listenPort=4111; upstreamPort=6000
                    }
                }
                return $script:healthFixture
            }
            (Test-AgentMemoryHealthOnce `
                -BaseUrl 'http://127.0.0.1:4111' `
                -ExpectedVersion '0.9.27' `
                -TimeoutSeconds 1) | Should Be $false
        }
    }

    It "stops exact-config descendants children-first even when REST is absent" {
        $root = Join-Path $TestDrive 'ProcessTree'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $entry = $fixture.AgentMemoryEntry
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        $otherConfig = Join-Path $root 'other.yaml'
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name='node.exe'; ProcessId=100; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=104; ParentProcessId=100; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=101; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=102; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand },
                [pscustomobject]@{ Name='node.exe'; ProcessId=107; ParentProcessId=101; ExecutablePath=$fixture.NodeExecutable; CommandLine='viewer child' },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=105; ParentProcessId=1; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$otherConfig`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=106; ParentProcessId=105; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$entry`"" }
            )
        }
        $script:stoppedIds = @()
        Mock Stop-Process {
            foreach ($processId in @($Id)) { $script:stoppedIds += [int]$processId }
        }

        $evidence = Get-AgentMemoryInstanceEvidence `
            -ConfigPath $fixture.RuntimeConfig `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -IiiExecutable $fixture.IiiExecutable `
            -Port 4111
        @($evidence.ValidListenerOwnerIds) -contains 101 | Should Be $true
        @($evidence.ValidListenerOwnerIds) -contains 102 | Should Be $true
        @($evidence.ValidListenerOwnerIds) -contains 104 | Should Be $true
        @($evidence.ValidListenerOwnerIds) -contains 107 | Should Be $false

        Stop-AgentMemoryProcessGroup `
            -ConfigPath $fixture.RuntimeConfig `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -IiiExecutable $fixture.IiiExecutable `
            -Port 4111

        $script:stoppedIds[0] | Should Be 107
        $script:stoppedIds[-1] | Should Be 100
        @($script:stoppedIds | Sort-Object) -join ',' | Should Be '100,101,102,104,107'
        ($script:stoppedIds -contains 105) | Should Be $false
        ($script:stoppedIds -contains 106) | Should Be $false
    }

    It "fails closed for an exact config launched by a different iii executable" {
        $root = Join-Path $TestDrive 'WrongEngine'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-CimInstance {
            @([pscustomobject]@{ Name='iii.exe'; ProcessId=201; ParentProcessId=1; ExecutablePath='C:\foreign\iii.exe'; CommandLine="`"C:\foreign\iii.exe`" --config `"$($fixture.RuntimeConfig)`"" })
        }
        Mock Stop-Process { }

        Stop-AgentMemoryProcessGroup `
            -ConfigPath $fixture.RuntimeConfig `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -IiiExecutable $fixture.IiiExecutable `
            -Port 4111

        Assert-MockCalled Stop-Process -Times 0 -Scope It
    }

    It "recognizes only a sole exact iii command without extra arguments" {
        $root = Join-Path $TestDrive 'ExactIiiCommand'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $exact = "`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`""
        (Test-AgentMemoryIiiUsesConfig `
            -CommandLine $exact `
            -IiiExecutable $fixture.IiiExecutable `
            -ConfigPath $fixture.RuntimeConfig) | Should Be $true
        (Test-AgentMemoryIiiCommandLine `
            -CommandLine $exact `
            -IiiExecutable $fixture.IiiExecutable `
            -ConfigPath $fixture.RuntimeConfig) | Should Be $true
        foreach ($invalid in @(
                ($exact + ' --extra'),
                ("`"$($fixture.IiiExecutable)`" --verbose --config `"$($fixture.RuntimeConfig)`""),
                ("`"C:\foreign\iii.exe`" --config `"$($fixture.RuntimeConfig)`"")
            )) {
            (Test-AgentMemoryIiiUsesConfig `
                -CommandLine $invalid `
                -IiiExecutable $fixture.IiiExecutable `
                -ConfigPath $fixture.RuntimeConfig) | Should Be $false
            (Test-AgentMemoryIiiCommandLine `
                -CommandLine $invalid `
                -IiiExecutable $fixture.IiiExecutable `
                -ConfigPath $fixture.RuntimeConfig) | Should Be $false
        }
    }

    It "proves a complete supervisor orphan only from exact identities and listeners" {
        $root = Join-Path $TestDrive 'CompleteOrphanEvidence'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name='iii.exe'; ProcessId=101; ParentProcessId=900; CreationDate='20260723010101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=102; ParentProcessId=900; CreationDate='20260723010102.000000+000'; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$($fixture.AgentMemoryEntry)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=103; ParentProcessId=900; CreationDate='20260723010103.000000+000'; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand }
            )
        }
        Mock Get-NetTCPConnection {
            $port = [int](@($LocalPort)[0])
            if ($port -in @(4112, 4113, 50134)) { return @() }
            $owner = if ($port -eq 4111) { 103 } elseif ($port -eq 6002) { 102 } else { 101 }
            $address = if ($port -eq 6002) { '127.0.0.2' } else { '127.0.0.1' }
            [pscustomobject]@{ LocalPort=$port; LocalAddress=$address; OwningProcess=$owner }
        }

        $evidence = Get-AgentMemoryStrictOrphanEvidence `
            -ConfigPath $fixture.RuntimeConfig `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript `
            -IiiExecutable $fixture.IiiExecutable `
            -Port 4111
        $evidence.CandidateDetected | Should Be $true
        $evidence.RecoverySafe | Should Be $true
        @($evidence.TargetIds) -join ',' | Should Be '103,102,101'
    }

    It "fails a bounded orphan cleanup when termination leaves the original identity alive" {
        $root = Join-Path $TestDrive 'OrphanKillFailure'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $script:stuckOrphan = @(
            [pscustomobject]@{ Name='iii.exe'; ProcessId=301; ParentProcessId=900; CreationDate='20260723030101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" }
        )
        Mock Get-CimInstance { return @($script:stuckOrphan) }
        Mock Get-NetTCPConnection { return @() }
        Mock Stop-Process { }
        Mock Start-Sleep { }

        $stopResult = Stop-AgentMemoryStrictOrphanGroup `
            -ConfigPath $fixture.RuntimeConfig -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript -IiiExecutable $fixture.IiiExecutable `
            -Port 4111
        $stopResult.CandidateDetected | Should Be $true
        $stopResult.Stopped | Should Be $false
        Assert-MockCalled Stop-Process -Times 1 -Scope It
    }

    It "never stops an orphan candidate when a fixed listener is foreign" {
        $root = Join-Path $TestDrive 'OrphanForeignListener'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-CimInstance {
            @([pscustomobject]@{ Name='iii.exe'; ProcessId=401; ParentProcessId=900; CreationDate='20260723040101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" })
        }
        Mock Get-NetTCPConnection {
            $port = [int](@($LocalPort)[0])
            if ($port -eq 6000) {
                return [pscustomobject]@{ LocalPort=6000; LocalAddress='127.0.0.1'; OwningProcess=999 }
            }
            return @()
        }
        Mock Stop-Process { }

        $stopResult = Stop-AgentMemoryStrictOrphanGroup `
            -ConfigPath $fixture.RuntimeConfig -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript -IiiExecutable $fixture.IiiExecutable `
            -Port 4111
        $stopResult.CandidateDetected | Should Be $true
        $stopResult.Stopped | Should Be $false
        Assert-MockCalled Stop-Process -Times 0 -Scope It
    }

    It "never stops a PID reused after orphan evidence was captured" {
        $root = Join-Path $TestDrive 'OrphanPidReuse'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $script:orphanReuseProbe = 0
        Mock Get-CimInstance {
            $script:orphanReuseProbe++
            if ($script:orphanReuseProbe -eq 1) {
                return @([pscustomobject]@{ Name='iii.exe'; ProcessId=501; ParentProcessId=900; CreationDate='20260723050101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" })
            }
            return @([pscustomobject]@{ Name='foreign.exe'; ProcessId=501; ParentProcessId=42; CreationDate='20260723050102.000000+000'; ExecutablePath='C:\foreign\foreign.exe'; CommandLine='foreign.exe' })
        }
        Mock Get-NetTCPConnection { return @() }
        Mock Stop-Process { }

        $stopResult = Stop-AgentMemoryStrictOrphanGroup `
            -ConfigPath $fixture.RuntimeConfig -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript -IiiExecutable $fixture.IiiExecutable `
            -Port 4111
        $stopResult.CandidateDetected | Should Be $true
        $stopResult.Stopped | Should Be $false
        Assert-MockCalled Stop-Process -Times 0 -Scope It
    }

    It "fails closed for Node-only, reused-parent, duplicate, peer, and descendant orphan ambiguity" {
        $root = Join-Path $TestDrive 'OrphanAmbiguity'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $exactIii = [pscustomobject]@{ Name='iii.exe'; ProcessId=601; ParentProcessId=900; CreationDate='20260723060101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" }
        $exactAgent = [pscustomobject]@{ Name='node.exe'; ProcessId=602; ParentProcessId=900; CreationDate='20260723060102.000000+000'; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$($fixture.AgentMemoryEntry)`"" }
        $script:orphanAmbiguityMode = ''
        Mock Get-CimInstance {
            switch ($script:orphanAmbiguityMode) {
                'node-only' { return @($exactAgent) }
                'parent-reused' { return @($exactIii, [pscustomobject]@{ Name='other.exe'; ProcessId=900; ParentProcessId=1; CreationDate='x'; ExecutablePath='C:\other.exe'; CommandLine='other.exe' }) }
                'duplicate' { return @($exactIii, [pscustomobject]@{ Name='iii.exe'; ProcessId=603; ParentProcessId=900; CreationDate='20260723060103.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine=$exactIii.CommandLine }) }
                'peer' { return @($exactIii, [pscustomobject]@{ Name='other.exe'; ProcessId=604; ParentProcessId=900; CreationDate='x'; ExecutablePath='C:\other.exe'; CommandLine='other.exe' }) }
                'descendant' { return @($exactIii, [pscustomobject]@{ Name='other.exe'; ProcessId=605; ParentProcessId=601; CreationDate='x'; ExecutablePath='C:\other.exe'; CommandLine='other.exe' }) }
            }
        }
        Mock Get-NetTCPConnection { return @() }
        foreach ($mode in @('node-only', 'parent-reused', 'duplicate', 'peer', 'descendant')) {
            $script:orphanAmbiguityMode = $mode
            $evidence = Get-AgentMemoryStrictOrphanEvidence `
                -ConfigPath $fixture.RuntimeConfig -InstallRoot $fixture.InstallRoot `
                -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript `
                -SupervisorScript $fixture.SupervisorScript -IiiExecutable $fixture.IiiExecutable `
                -Port 4111
            $evidence.RecoverySafe | Should Be $false
        }
    }

    It "returns the real Windows PowerShell child exit while its inherited-handle descendant remains alive" {
        $root = Join-Path $TestDrive 'Real Controller With Spaces'
        $logs = Join-Path $root 'Controller Logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $serverScript = Join-Path $root 'synthetic server.ps1'
        $descendantPidPath = Join-Path $logs 'descendant.pid'
        @'
param(
    [string]$DevToolsRoot, [string]$DataRoot, [string]$BaseUrl,
    [string]$Config, [string]$InstallRoot, [string]$NodeExecutable,
    [string]$IiiExecutable, [string]$LogDir,
    [string]$EmbeddingProvider, [switch]$ValidateOnly
)
$descendant = Start-Process `
    -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') `
    -ArgumentList @('-n', '301', '127.0.0.1') `
    -NoNewWindow -PassThru
$outChunk = 'O' * 65536
$errChunk = 'E' * 65536
for ($index = 0; $index -lt 16; $index++) {
    [Console]::Out.Write($outChunk)
    [Console]::Error.Write($errChunk)
}
[Console]::Out.Flush()
[Console]::Error.Flush()
[System.IO.File]::WriteAllText(
    (Join-Path $LogDir 'descendant.pid'),
    [string]$descendant.Id
)
Start-Sleep -Milliseconds 500
exit 23
'@ | Set-Content -LiteralPath $serverScript -Encoding UTF8

        $descendantPid = $null
        $descendantProcess = $null
        try {
            $windowsPowerShell = Join-Path `
                $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $exitCode = Invoke-AgentMemoryServerProcess `
                -PowerShellExecutable $windowsPowerShell `
                -ServerScript $serverScript -DevToolsRoot $root `
                -DataRoot (Join-Path $root 'Memory Data') `
                -BaseUrl 'http://127.0.0.1:4111' `
                -Config (Join-Path $root 'agentmemory config.yaml') `
                -InstallRoot (Join-Path $root 'Runtime Root') `
                -NodeExecutable (Join-Path $root 'node.exe') `
                -IiiExecutable (Join-Path $root 'iii.exe') `
                -LogDir $logs -EmbeddingProvider 'local' -ValidateOnly
            if ($exitCode -ne 23) {
                $controllerOut = Join-Path $logs 'agentmemory-controller.out.4111.log'
                $controllerErr = Join-Path $logs 'agentmemory-controller.err.4111.log'
                $outText = if (Test-Path -LiteralPath $controllerOut) {
                    [System.IO.File]::ReadAllText($controllerOut)
                } else { '<missing>' }
                $errText = if (Test-Path -LiteralPath $controllerErr) {
                    [System.IO.File]::ReadAllText($controllerErr)
                } else { '<missing>' }
                throw "Synthetic controller returned $exitCode. stdout=[$outText] stderr=[$errText]"
            }
            $exitCode | Should Be 23
            $descendantPidPath | Should Exist
            $descendantPid = [int][System.IO.File]::ReadAllText($descendantPidPath)
            $descendantProcess = Get-Process -Id $descendantPid -ErrorAction Stop
            $descendantProcess.HasExited | Should Be $false
            $controllerOut = Join-Path $logs 'agentmemory-controller.out.4111.log'
            $controllerErr = Join-Path $logs 'agentmemory-controller.err.4111.log'
            $controllerOut | Should Exist
            $controllerErr | Should Exist
            (Get-Item -LiteralPath $controllerOut).Length | Should BeGreaterThan 1048575
            (Get-Item -LiteralPath $controllerErr).Length | Should BeGreaterThan 1048575
        } finally {
            if ($null -eq $descendantPid -and (Test-Path -LiteralPath $descendantPidPath)) {
                $recordedPid = [System.IO.File]::ReadAllText($descendantPidPath)
                if ($recordedPid -match '^\d+$') {
                    $descendantPid = [int]$recordedPid
                }
            }
            if ($null -ne $descendantPid) {
                if ($null -eq $descendantProcess) {
                    $descendantProcess = Get-Process -Id $descendantPid -ErrorAction SilentlyContinue
                }
                if ($null -ne $descendantProcess) {
                    $descendantProcess.Kill()
                    if (-not $descendantProcess.WaitForExit(30000)) {
                        throw 'Synthetic inherited-handle descendant did not terminate during cleanup.'
                    }
                    $descendantProcess.Dispose()
                }
            }
        }
    }

    It "waits only for the exact server child and never binds its output to the native pipeline" {
        $script:serverChildProcess = [pscustomobject]@{
            ExitCode = 23
            Handle = 123
            WaitCount = 0
            SimulatedDescendantStillRunning = $true
        }
        $script:serverChildProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            $this.WaitCount++
        }
        $script:serverChildProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        Mock Start-Process { return $script:serverChildProcess }
        Mock powershell.exe { throw 'the native pipeline must not be used' }

        $exitCode = Invoke-AgentMemoryServerProcess `
            -PowerShellExecutable 'powershell.exe' `
            -ServerScript 'C:\Tools\agentmemory-server.ps1' `
            -DevToolsRoot 'C:\Tools' `
            -DataRoot 'D:\Memory Data' `
            -BaseUrl 'http://127.0.0.1:4111' `
            -Config 'C:\Tools\agentmemory-iii.yaml' `
            -InstallRoot 'E:\runtime' `
            -NodeExecutable 'C:\Tools\node\node.exe' `
            -IiiExecutable 'E:\runtime\iii.exe' `
            -LogDir 'C:\Tools\logs' `
            -EmbeddingProvider 'local' `
            -ValidateOnly

        $expectedArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '"C:\Tools\agentmemory-server.ps1"',
            '-DevToolsRoot', '"C:\Tools"',
            '-DataRoot', '"D:\Memory Data"',
            '-BaseUrl', '"http://127.0.0.1:4111"',
            '-Config', '"C:\Tools\agentmemory-iii.yaml"',
            '-InstallRoot', '"E:\runtime"',
            '-NodeExecutable', '"C:\Tools\node\node.exe"',
            '-IiiExecutable', '"E:\runtime\iii.exe"',
            '-LogDir', '"C:\Tools\logs"',
            '-EmbeddingProvider', '"local"',
            '-ValidateOnly'
        )
        $exitCode | Should Be 23
        $script:serverChildProcess.WaitCount | Should Be 1
        $script:serverChildProcess.SimulatedDescendantStillRunning | Should Be $true
        Assert-MockCalled Start-Process -Times 1 -Scope It -ParameterFilter {
            $FilePath -eq 'powershell.exe' -and
            $WorkingDirectory -eq 'C:\Tools' -and
            $NoNewWindow -eq $true -and
            $PassThru -eq $true -and
            -not $PSBoundParameters.ContainsKey('Wait') -and
            -not $PSBoundParameters.ContainsKey('WindowStyle') -and
            $RedirectStandardOutput -eq 'C:\Tools\logs\agentmemory-controller.out.4111.log' -and
            $RedirectStandardError -eq 'C:\Tools\logs\agentmemory-controller.err.4111.log' -and
            ($ArgumentList -join '|') -eq ($expectedArguments -join '|')
        }
        Assert-MockCalled powershell.exe -Times 0 -Scope It
        (Get-Command Invoke-AgentMemoryServerProcess).Definition | Should Not Match '\|\s*Out-Null'
    }

    It "returns 127 when the server controller cannot launch or exact-process wait fails" {
        $script:serverControllerFailure = 'launch'
        $script:waitFailureProcess = [pscustomobject]@{ ExitCode=0; Handle=123 }
        $script:waitFailureProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            throw 'synthetic exact wait failure'
        }
        $script:waitFailureProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        Mock Start-Process {
            if ($script:serverControllerFailure -eq 'launch') {
                throw 'synthetic controller launch failure'
            }
            return $script:waitFailureProcess
        }
        $invoke = {
            Invoke-AgentMemoryServerProcess `
                -PowerShellExecutable 'powershell.exe' `
                -ServerScript 'C:\Tools\agentmemory-server.ps1' `
                -DevToolsRoot 'C:\Tools' -DataRoot 'D:\Memory Data' `
                -BaseUrl 'http://127.0.0.1:4111' `
                -Config 'C:\Tools\agentmemory-iii.yaml' `
                -InstallRoot 'E:\runtime' `
                -NodeExecutable 'C:\Tools\node\node.exe' `
                -IiiExecutable 'E:\runtime\iii.exe' `
                -LogDir 'C:\Tools\logs' -EmbeddingProvider 'local'
        }
        (& $invoke) | Should Be 127
        $script:serverControllerFailure = 'wait'
        (& $invoke) | Should Be 127
        Assert-MockCalled Start-Process -Times 2 -Scope It
    }

    It "removes an iii-only startup orphan before restarting and sends no bearer to it" {
        $root = Join-Path $TestDrive 'PartialStartupOrphan'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $script:partialOrphanProcesses = @(
            [pscustomobject]@{ Name='iii.exe'; ProcessId=201; ParentProcessId=900; CreationDate='20260723020101.000000+000'; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" }
        )
        Mock Get-CimInstance { return @($script:partialOrphanProcesses) }
        Mock Get-NetTCPConnection { return @() }
        Mock Stop-Process { $script:partialOrphanProcesses = @() }
        Mock Start-Sleep { }
        Mock Invoke-AgentMemoryServerProcess { return 0 }
        Mock Wait-AgentMemoryHealthy { return $true }
        Mock Invoke-RestMethod { throw 'Bearer request must not reach an orphan' }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript `
            -RestartWaitSeconds 1 -PollSeconds 1)

        $result[-1] | Should Be 0
        ($result -join ' ') | Should Match 'strict-orphan-group-stopped'
        Assert-MockCalled Stop-Process -Times 1 -Scope It -ParameterFilter { $Id -eq 201 }
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 1 -Scope It
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }

    It "does not restart a healthy exact-owned instance" {
        $root = Join-Path $TestDrive 'HealthyExact'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        $entry = $fixture.AgentMemoryEntry
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort=4111; OwningProcess=104 } }
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name='node.exe'; ProcessId=100; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=101; ParentProcessId=100; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=102; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=104; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand }
            )
        }
        Mock Test-AgentMemoryHealth { return $true }
        Mock Invoke-AgentMemoryServerProcess { return 0 }
        Mock Stop-AgentMemoryProcessGroup { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://localhost:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript -HealthGapSeconds 0)

        $result[-1] | Should Be 0
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 3 -Scope It
        Assert-MockCalled Stop-AgentMemoryProcessGroup -Times 0 -Scope It
    }

    It "restarts an exact-owned instance when its listener contract is unhealthy" {
        $root = Join-Path $TestDrive 'ListenerContractFailure'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        $entry = $fixture.AgentMemoryEntry
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort=4111; OwningProcess=104 } }
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name='node.exe'; ProcessId=100; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=101; ParentProcessId=100; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=102; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=104; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand }
            )
        }
        Mock Test-AgentMemoryHealth { return $true }
        $script:listenerContractInvocation = 0
        Mock Invoke-AgentMemoryServerProcess {
            if ($ValidateOnly) { return 0 }
            $script:listenerContractInvocation++
            if ($script:listenerContractInvocation -eq 1) { return 1 }
            return 0
        }
        $script:listenerContractWait = 0
        Mock Wait-AgentMemoryHealthy {
            $script:listenerContractWait++
            return ($script:listenerContractWait -ge 2)
        }
        Mock Stop-AgentMemoryProcessGroup { }
        Mock Start-Sleep { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript `
            -HealthGapSeconds 0 -ReloadWaitSeconds 1 -RestartWaitSeconds 1 `
            -PollSeconds 1 -RestartAttempts 1)

        $result[-1] | Should Be 0
        Assert-MockCalled Stop-AgentMemoryProcessGroup -Times 1 -Scope It
    }

    It "fails closed without reloading or stopping a substantively drifted active config" {
        $root = Join-Path $TestDrive 'DriftedActive'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-Item -ItemType Directory -Path $fixture.LogDir -Force | Out-Null
        Set-Content -LiteralPath $fixture.RuntimeConfig -Value 'workers: [] # drift' -Encoding ASCII
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort=4111; OwningProcess=104 } }
        Mock Invoke-AgentMemoryServerProcess { return 1 }
        Mock Get-CimInstance { return @() }
        Mock Stop-AgentMemoryProcessGroup { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript)

        $result[-1] | Should Be 1
        Assert-MockCalled Stop-AgentMemoryProcessGroup -Times 0 -Scope It
    }

    It "forwards all resolved settings when starting a stopped service" {
        $root = Join-Path $TestDrive 'StoppedService'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-NetTCPConnection { return @() }
        Mock Invoke-AgentMemoryServerProcess { return 0 }
        Mock Wait-AgentMemoryHealthy { return $true }
        Mock Stop-AgentMemoryProcessGroup { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://localhost:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -EmbeddingProvider 'local' -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript)

        $result[-1] | Should Be 0
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 1 -Scope It -ParameterFilter {
            $DataRoot -eq $fixture.DataRoot -and $InstallRoot -eq $fixture.InstallRoot -and
            $NodeExecutable -eq $fixture.NodeExecutable -and $IiiExecutable -eq $fixture.IiiExecutable -and
            $EmbeddingProvider -eq 'local' -and $BaseUrl -eq 'http://127.0.0.1:4111'
        }
    }

    It "restarts within the same run when a hot reload exits the exact service" {
        $root = Join-Path $TestDrive 'ReloadExit'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        $script:reloadExitListenerProbe = 0
        Mock Get-NetTCPConnection {
            $script:reloadExitListenerProbe++
            if ($script:reloadExitListenerProbe -eq 1) {
                return [pscustomobject]@{ LocalPort=4111; OwningProcess=104 }
            }
            return @()
        }
        $script:reloadExitEvidenceProbe = 0
        Mock Get-AgentMemoryInstanceEvidence {
            $script:reloadExitEvidenceProbe++
            if ($script:reloadExitEvidenceProbe -eq 1) {
                return [pscustomobject]@{
                    MatchingSupervisorIds=@(100)
                    MatchingIiiIds=@(104)
                    TargetIds=@(104)
                    ValidListenerOwnerIds=@(104)
                }
            }
            return [pscustomobject]@{
                MatchingSupervisorIds=@()
                MatchingIiiIds=@()
                TargetIds=@()
                ValidListenerOwnerIds=@()
            }
        }
        Mock Get-RunningAgentMemoryIiiConfig { return $fixture.RuntimeConfig }
        Mock Test-AgentMemoryHealth { return $false }
        $script:reloadExitWaitProbe = 0
        Mock Wait-AgentMemoryHealthy {
            $script:reloadExitWaitProbe++
            return ($script:reloadExitWaitProbe -ge 2)
        }
        Mock Invoke-AgentMemoryServerProcess { return 0 }
        Mock Stop-AgentMemoryProcessGroup { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript `
            -HealthGapSeconds 0 -ReloadWaitSeconds 1 -RestartWaitSeconds 1 -PollSeconds 1)

        $result[-1] | Should Be 0
        ($result -join ' ') | Should Match 'reload-exit-restarted\(healthy=True\)'
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 3 -Scope It
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 2 -Scope It -ParameterFilter {
            -not $ValidateOnly
        }
        Assert-MockCalled Stop-AgentMemoryProcessGroup -Times 0 -Scope It
    }

    It "fails before probing when the canonical template is incomplete" {
        $root = Join-Path $TestDrive 'InvalidTemplate'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Set-Content -LiteralPath $fixture.Config -Value 'workers: []' -Encoding ASCII
        Mock Get-NetTCPConnection { throw 'must not probe' }
        Mock Invoke-AgentMemoryServerProcess { return 0 }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript)

        $result[-1] | Should Be 1
        Assert-MockCalled Get-NetTCPConnection -Times 0 -Scope It
        Assert-MockCalled Invoke-AgentMemoryServerProcess -Times 0 -Scope It
    }

    It "atomically updates the reload marker without temporary-file residue" {
        $config = Join-Path $TestDrive 'reload-marker.yaml'
        Set-Content -LiteralPath $config -Value "workers:`r`n  - name: fixture" -Encoding UTF8
        Set-AgentMemoryReloadMarker -ConfigPath $config -Timestamp '2026-07-22 20:00:00'
        Set-AgentMemoryReloadMarker -ConfigPath $config -Timestamp '2026-07-22 20:01:00'
        $text = [System.IO.File]::ReadAllText($config)
        @([regex]::Matches($text, '(?m)^# selfheal-reload:')).Count | Should Be 1
        $text | Should Match 'selfheal-reload: 2026-07-22 20:01:00'
        @(Get-ChildItem -LiteralPath $TestDrive -File -Filter '.agentmemory-reload.*').Count | Should Be 0
    }

    It "serializes self-heal by canonical port across endpoint aliases" {
        $lock = Open-AgentMemorySelfHealLock -Port 4111 -TimeoutSeconds 1
        try {
            $threw = $false
            try { [void](Open-AgentMemorySelfHealLock -Port 4111 -TimeoutSeconds 1) } catch { $threw = $true }
            $threw | Should Be $true
        } finally {
            $lock.Dispose()
        }
        $second = Open-AgentMemorySelfHealLock -Port 4111 -TimeoutSeconds 1
        $second.Dispose()
    }

    It "runs the full runtime proof before any self-heal bearer probe" {
        $root = Join-Path $TestDrive 'SelfHealOwnershipFirst'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalPort=4111; LocalAddress='127.0.0.1'; OwningProcess=102 }
        }
        # Exact process-tree classification has dedicated tests above. This
        # ordering test supplies already-proven ownership so it stays focused
        # on the rule that no bearer probe may precede the full inspector.
        Mock Get-AgentMemoryInstanceEvidence {
            [pscustomobject]@{
                Processes = @()
                ProcessMap = @{}
                MatchingSupervisorIds = @(100)
                MatchingIiiIds = @(104)
                TargetIds = @(102, 101, 104)
                ValidListenerOwnerIds = @(102, 101, 104)
            }
        }
        $script:selfHealFullContractAttempts = 0
        Mock Invoke-AgentMemoryServerProcess {
            if ($ValidateOnly) { return 0 }
            $script:selfHealFullContractAttempts++
            return 1
        }
        Mock Test-AgentMemoryHealth { throw 'Bearer health probe must not run' }
        Mock Invoke-RestMethod { throw 'Bearer request must not run' }
        Mock Stop-AgentMemoryProcessGroup { }
        Mock Start-Sleep { }

        $result = @(Invoke-AgentMemorySelfHeal `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ServerScript $fixture.ServerScript `
            -HealthGapSeconds 0 -ReloadWaitSeconds 1 -RestartWaitSeconds 1 `
            -PollSeconds 1 -RestartAttempts 1)

        $result[-1] | Should Be 1
        $script:selfHealFullContractAttempts | Should BeGreaterThan 0
        Assert-MockCalled Test-AgentMemoryHealth -Times 0 -Scope It
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }
}

Describe "agentmemory daily health behavior" {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        Mock Get-AgentMemoryDailyRequiredSecret { return ('A1b2C3d4_' * 4) }
    }

    It "passes explicit settings to the self-heal child command" {
        $script:selfHealChildArguments = @()
        Mock powershell.exe { $script:selfHealChildArguments = @($args) }

        [void](Invoke-AgentMemorySelfHealProcess `
            -PowerShellExecutable "powershell.exe" `
            -SelfHealScript (Get-RuntimeScriptPath "agentmemory-selfheal.ps1") `
            -DevToolsRoot "C:\Portable Tools" `
            -BaseUrl "http://127.0.0.1:4111")

        ($script:selfHealChildArguments -join "|") | Should Be (
            "-NoProfile|-ExecutionPolicy|Bypass|-File|" +
            (Get-RuntimeScriptPath "agentmemory-selfheal.ps1") +
            "|-DevToolsRoot|C:\Portable Tools|-BaseUrl|http://127.0.0.1:4111" +
            "|-PowerShellExecutable|powershell.exe"
        )
    }

    It "forwards explicit lifecycle overrides to daily recovery" {
        $script:selfHealChildArguments = @()
        Mock powershell.exe { $script:selfHealChildArguments = @($args) }

        [void](Invoke-AgentMemorySelfHealProcess `
            -PowerShellExecutable 'powershell.exe' `
            -SelfHealScript (Get-RuntimeScriptPath 'agentmemory-selfheal.ps1') `
            -DevToolsRoot 'C:\Tools' `
            -DataRoot 'D:\Memory Data' `
            -BaseUrl 'http://127.0.0.1:4111' `
            -Config 'C:\Tools\agentmemory-iii.yaml' `
            -InstallRoot 'E:\runtime' `
            -NodeExecutable 'C:\Tools\node\node.exe' `
            -IiiExecutable 'E:\runtime\iii.exe' `
            -EmbeddingProvider 'local' `
            -LogDir 'C:\Tools\logs' `
            -ServerScript 'C:\Tools\agentmemory-server.ps1')

        $joined = $script:selfHealChildArguments -join '|'
        foreach ($fragment in @(
                '-DataRoot|D:\Memory Data', '-Config|C:\Tools\agentmemory-iii.yaml',
                '-InstallRoot|E:\runtime', '-NodeExecutable|C:\Tools\node\node.exe',
                '-IiiExecutable|E:\runtime\iii.exe', '-EmbeddingProvider|local',
                '-LogDir|C:\Tools\logs', '-ServerScript|C:\Tools\agentmemory-server.ps1'
            )) {
            $joined | Should Match ([regex]::Escape($fragment))
        }
    }

    It "runs read-only full listener inspection with the same lifecycle overrides" {
        $script:inspectionChildArguments = @()
        Mock powershell.exe {
            $script:inspectionChildArguments = @($args)
            $global:LASTEXITCODE = 0
        }
        (Invoke-AgentMemoryInspectionProcess `
            -PowerShellExecutable 'powershell.exe' `
            -ServerScript (Get-RuntimeScriptPath 'agentmemory-server.ps1') `
            -DevToolsRoot 'C:\Tools' `
            -DataRoot 'D:\Memory Data' `
            -BaseUrl 'http://127.0.0.1:4111' `
            -Config 'C:\Tools\agentmemory-iii.yaml' `
            -InstallRoot 'E:\runtime' `
            -NodeExecutable 'C:\Tools\node\node.exe' `
            -IiiExecutable 'E:\runtime\iii.exe' `
            -EmbeddingProvider 'local' `
            -LogDir 'C:\Tools\logs') | Should Be 0
        $joined = $script:inspectionChildArguments -join '|'
        $joined | Should Match ([regex]::Escape('-NodeExecutable|C:\Tools\node\node.exe'))
        $joined | Should Match ([regex]::Escape('-IiiExecutable|E:\runtime\iii.exe'))
        $joined | Should Match ([regex]::Escape('-LogDir|C:\Tools\logs|-InspectOnly'))
    }

    It "uses the configured timeout and base URL for endpoint probes" {
        $script:dailyProbeUri = $null
        $script:dailyProbeTimeout = $null
        $script:dailyProbeAuthorization = $null
        Mock Invoke-WebRequest {
            param(
                $Uri,
                $Headers,
                [switch]$UseBasicParsing,
                [Alias('ConnectionTimeoutSeconds')][int]$TimeoutSec
            )
            $script:dailyProbeUri = $Uri
            # PowerShell 7.4 renamed TimeoutSec to ConnectionTimeoutSeconds and
            # retained TimeoutSec as an alias. Pester 3 exposes the canonical
            # parameter name inside a mock. Bind either name explicitly while
            # continuing to call the production-compatible alias.
            $script:dailyProbeTimeout = $TimeoutSec
            $script:dailyProbeAuthorization = $Headers.Authorization
            [pscustomobject]@{ StatusCode = 200 }
        }

        $failure = Test-AgentMemoryEndpoint `
            -Name "health" `
            -Path "/agentmemory/health" `
            -BaseUrl "http://127.0.0.1:4111/" `
            -TimeoutSeconds 31

        $failure | Should BeNullOrEmpty
        $script:dailyProbeUri | Should Be "http://127.0.0.1:4111/agentmemory/health"
        $script:dailyProbeTimeout | Should Be 31
        $script:dailyProbeAuthorization | Should Be ('Bearer ' + ('A1b2C3d4_' * 4))
    }

    It "accepts only a canonical local loopback root" {
        (Get-AgentMemoryDailySettings `
            -DevToolsRoot $TestDrive `
            -BaseUrl 'http://localhost:4111/').BaseUrl | Should Be 'http://127.0.0.1:4111'

        foreach ($url in @(
                'https://127.0.0.1:4111',
                'http://192.0.2.10:4111',
                'http://user:pass@127.0.0.1:4111',
                'http://127.0.0.1:4111/path',
                'http://127.0.0.1:4111/?query=1',
                'http://127.0.0.1:4111/#fragment',
                'http://[::1]:4111',
                'http://127.0.0.1:5998',
                'http://127.0.0.1:19513'
            )) {
            (Test-RuntimeThrows {
                    Get-AgentMemoryDailySettings -DevToolsRoot $TestDrive -BaseUrl $url
                }) | Should Be $true
        }
    }

    It "validates exact health, flags, tools, and slots schemas" {
        Mock Invoke-RestMethod {
            if ($Headers.Authorization -ne ('Bearer ' + ('A1b2C3d4_' * 4))) {
                throw 'missing authenticated request header'
            }
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6000
                }
            }
            if ($Uri -like '*/agentmemory/health') {
                return [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6002; viewerSkipped=$false
                }
            }
            if ($Uri -like '*/agentmemory/config/flags') {
                return [pscustomobject]@{
                    version='0.9.27'
                    flags=@([pscustomobject]@{ key='CONSOLIDATION_ENABLED'; enabled=$true })
                }
            }
            if ($Uri -like '*/agentmemory/mcp/tools') {
                return [pscustomobject]@{
                    tools=@(1..40 | ForEach-Object {
                            [pscustomobject]@{ name="tool$_"; inputSchema=[pscustomobject]@{ type='object' } }
                        })
                }
            }
            if ($Uri -like '*/agentmemory/slots') {
                return [pscustomobject]@{ success=$true; slots=@() }
            }
            throw 'unexpected endpoint'
        }

        $failures = @(Get-AgentMemoryCheckFailures `
            -BaseUrl 'http://localhost:4111' `
            -TimeoutSeconds 25 `
            -MinimumMcpTools 40)
        ($failures -join '; ') | Should BeNullOrEmpty
    }

    It "reports a degraded but structurally valid MCP tool surface" {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=3111; upstreamPort=6000
                }
            }
            if ($Uri -like '*/agentmemory/health') {
                return [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6002; viewerSkipped=$false
                }
            }
            if ($Uri -like '*/agentmemory/config/flags') {
                return [pscustomobject]@{
                    version='0.9.27'
                    flags=@([pscustomobject]@{ key='FLAG'; enabled=$true })
                }
            }
            if ($Uri -like '*/agentmemory/mcp/tools') {
                return [pscustomobject]@{
                    tools=@(1..3 | ForEach-Object {
                            [pscustomobject]@{ name="tool$_"; inputSchema=[pscustomobject]@{ type='object' } }
                        })
                }
            }
            if ($Uri -like '*/agentmemory/slots') {
                return [pscustomobject]@{ success=$true; slots=@() }
            }
        }

        $failures = @(Get-AgentMemoryCheckFailures `
            -BaseUrl "http://127.0.0.1:3111" `
            -TimeoutSeconds 25 `
            -MinimumMcpTools 40)

        ($failures -join " ") | Should Match 'DEGRADED MCP proxy'
    }

    It "fails closed for spoofed identity, stale flags, malformed tools, or disabled slots" {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                if ($script:dailyFailureMode -eq 'guard') {
                    return [pscustomobject]@{
                        service='foreign'; status='healthy'; version='1'
                        listenPort=3111; upstreamPort=6000
                    }
                }
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=3111; upstreamPort=6000
                }
            }
            if ($Uri -like '*/agentmemory/health') {
                if ($script:dailyFailureMode -eq 'health') {
                    return [pscustomobject]@{ service='other'; status='healthy'; version='0.9.27' }
                }
                if ($script:dailyFailureMode -eq 'health-numeric-string') {
                    return [pscustomobject]@{
                        service='agentmemory'; status='healthy'; version='0.9.27'
                        viewerPort='6002'; viewerSkipped=$false
                    }
                }
                $viewerPort = if ($script:dailyFailureMode -eq 'viewer-fallback') { 6003 } else { 6002 }
                $viewerSkipped = ($script:dailyFailureMode -eq 'viewer-skipped')
                return [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=$viewerPort; viewerSkipped=$viewerSkipped
                }
            }
            if ($Uri -like '*/agentmemory/config/flags') {
                if ($script:dailyFailureMode -eq 'flags') {
                    return [pscustomobject]@{ version='0.9.26'; flags=@() }
                }
                if ($script:dailyFailureMode -eq 'flags-numeric-key') {
                    return [pscustomobject]@{
                        version='0.9.27'
                        flags=@([pscustomobject]@{ key=123; enabled=$true })
                    }
                }
                return [pscustomobject]@{
                    version='0.9.27'
                    flags=@([pscustomobject]@{ key='FLAG'; enabled=$true })
                }
            }
            if ($Uri -like '*/agentmemory/mcp/tools') {
                if ($script:dailyFailureMode -eq 'tools') {
                    return [pscustomobject]@{ tools=@([pscustomobject]@{ name=''; inputSchema=$null }) }
                }
                if ($script:dailyFailureMode -eq 'tools-scalar') {
                    return [pscustomobject]@{
                        tools=[pscustomobject]@{
                            name='tool'; inputSchema=[pscustomobject]@{ type='object' }
                        }
                    }
                }
                return [pscustomobject]@{
                    tools=@(1..40 | ForEach-Object {
                            [pscustomobject]@{ name="tool$_"; inputSchema=[pscustomobject]@{ type='object' } }
                        })
                }
            }
            if ($Uri -like '*/agentmemory/slots') {
                if ($script:dailyFailureMode -eq 'slots') {
                    return [pscustomobject]@{ success=$false; slots=@() }
                }
                if ($script:dailyFailureMode -eq 'slots-scalar') {
                    return [pscustomobject]@{ success=$true; slots='anything' }
                }
                return [pscustomobject]@{ success=$true; slots=@() }
            }
        }

        $expectations = @{
            guard = 'FAIL authenticated Host guard identity mismatch'
            health = 'FAIL health identity'
            'viewer-fallback' = 'FAIL health identity'
            'viewer-skipped' = 'FAIL health identity'
            'health-numeric-string' = 'FAIL health identity'
            flags = 'FAIL config flags schema or version mismatch'
            'flags-numeric-key' = 'FAIL config flags schema or version mismatch'
            tools = 'FAIL MCP proxy tools schema mismatch'
            'tools-scalar' = 'FAIL MCP proxy tools schema mismatch'
            slots = 'FAIL slots schema or enabled-state mismatch'
            'slots-scalar' = 'FAIL slots schema or enabled-state mismatch'
        }
        foreach ($mode in @(
                'guard', 'health', 'viewer-fallback', 'viewer-skipped', 'health-numeric-string',
                'flags', 'flags-numeric-key', 'tools', 'tools-scalar', 'slots', 'slots-scalar'
            )) {
            $script:dailyFailureMode = $mode
            $failures = @(Get-AgentMemoryCheckFailures `
                -BaseUrl "http://127.0.0.1:3111" `
                -TimeoutSeconds 25 `
                -MinimumMcpTools 40)
            ($failures -join ' ') | Should Match ([regex]::Escape($expectations[$mode]))
        }
    }

    It "runs self-heal once and accepts a successful recheck" {
        $script:dailyCheckCount = 0
        Mock Get-AgentMemoryCheckFailures {
            $script:dailyCheckCount++
            if ($script:dailyCheckCount -eq 1) { return @("FAIL simulated") }
            return @()
        }
        Mock Invoke-AgentMemorySelfHealProcess { return 0 }
        Mock Invoke-AgentMemoryInspectionProcess { return 0 }

        $exitCode = Invoke-AgentMemoryDailyCheck `
            -DevToolsRoot $TestDrive `
            -BaseUrl "http://127.0.0.1:3111" `
            -LogPath (Join-Path $TestDrive "daily.log") `
            -SelfHealScript (Join-Path $TestDrive "agentmemory-selfheal.ps1") `
            -RecoveryDelaySeconds 0

        $exitCode | Should Be 0
        $script:dailyCheckCount | Should Be 2
        Assert-MockCalled Invoke-AgentMemorySelfHealProcess -Times 1 -Scope It -ParameterFilter {
            $DevToolsRoot -eq $TestDrive -and
            $BaseUrl -eq "http://127.0.0.1:3111"
        }
    }

    It "does not run daily bearer probes when the listener ownership inspection fails" {
        $script:dailyOwnershipProbeCount = 0
        Mock Invoke-AgentMemoryInspectionProcess { return 1 }
        Mock Get-AgentMemoryCheckFailures {
            $script:dailyOwnershipProbeCount++
            return @()
        }
        Mock Invoke-AgentMemorySelfHealProcess { return 1 }
        Mock Invoke-RestMethod { throw 'Bearer request must not run' }
        Mock Invoke-WebRequest { throw 'Bearer request must not run' }

        (Invoke-AgentMemoryDailyCheck `
            -DevToolsRoot $TestDrive `
            -BaseUrl 'http://127.0.0.1:4111' `
            -LogPath (Join-Path $TestDrive 'daily-ownership.log') `
            -SelfHealScript (Get-RuntimeScriptPath 'agentmemory-selfheal.ps1') `
            -ServerScript (Get-RuntimeScriptPath 'agentmemory-server.ps1') `
            -RecoveryDelaySeconds 0) | Should Be 1

        $script:dailyOwnershipProbeCount | Should Be 0
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Scope It
    }

    It "revokes daily ownership proof before recovery and never signals after recovery throws" {
        Mock Invoke-AgentMemoryInspectionProcess { return 0 }
        Mock Get-AgentMemoryCheckFailures { return @('FAIL simulated') }
        Mock Invoke-AgentMemorySelfHealProcess { throw 'simulated recovery failure' }
        Mock Invoke-RestMethod { throw 'failure signal must not be sent' }

        (Invoke-AgentMemoryDailyCheck `
            -DevToolsRoot $TestDrive `
            -BaseUrl 'http://127.0.0.1:4111' `
            -LogPath (Join-Path $TestDrive 'daily-recovery-throw.log') `
            -SelfHealScript (Get-RuntimeScriptPath 'agentmemory-selfheal.ps1') `
            -ServerScript (Get-RuntimeScriptPath 'agentmemory-server.ps1') `
            -RecoveryDelaySeconds 0) | Should Be 1

        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }
}

Describe "agentmemory server configuration" {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        Mock Get-AgentMemoryRequiredSecret { return ('A1b2C3d4_' * 4) }
    }

    It "resolves a canonical endpoint and port-specific runtime paths" {
        $settings = Get-AgentMemoryServerSettings `
            -DevToolsRoot 'C:\Portable Tools' `
            -DataRoot 'memory-data' `
            -BaseUrl 'http://localhost:4111/' `
            -Config 'config\agentmemory.yaml' `
            -InstallRoot 'runtime' `
            -NodeExecutable 'node\node.exe' `
            -IiiExecutable 'runtime\iii.exe' `
            -LogDir 'local-logs' `
            -EmbeddingProvider 'local'

        $settings.BaseUrl | Should Be 'http://127.0.0.1:4111'
        $settings.Port | Should Be 4111
        $settings.StreamPort | Should Be 6667
        $settings.ViewerHost | Should Be '127.0.0.2'
        $settings.ViewerPort | Should Be 6002
        $settings.EnginePort | Should Be 10080
        $settings.InternalRestPort | Should Be 6000
        $settings.LegacyStreamPort | Should Be 4112
        $settings.LegacyEnginePort | Should Be 50134
        $settings.GuardScript | Should Match '^C:\\Portable Tools\\agentmemory-host-guard\.mjs$'
        $settings.SupervisorScript | Should Match '^C:\\Portable Tools\\agentmemory-runtime-supervisor\.mjs$'
        $settings.Config | Should Match '^C:\\Portable Tools\\config\\agentmemory\.yaml$'
        $settings.RuntimeConfig | Should Match 'local-logs\\agentmemory-iii\.active\.4111\.yaml$'
        $settings.NodeExecutable | Should Match '^C:\\Portable Tools\\node\\node\.exe$'
        $settings.EmbeddingProvider | Should Be 'local'
    }

    It "materializes every required path and port token without widening listeners" {
        $root = Join-Path $TestDrive 'Materialized'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $fixture.DataRoot = Join-Path $root 'memory data'
        New-AgentMemoryActiveConfig `
            -TemplatePath $fixture.Config `
            -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -HttpPort 4111

        $text = [System.IO.File]::ReadAllText($fixture.RuntimeConfig)
        $dataPosix = $fixture.DataRoot.Replace('\', '/')
        $text | Should Match ([regex]::Escape($dataPosix + '/state_store.db'))
        $text | Should Match '(?ms)name:\s*iii-worker-manager.*?port:\s*10080.*?host:\s*127\.0\.0\.1'
        $text | Should Match '(?ms)name:\s*iii-http.*?port:\s*6000.*?host:\s*127\.0\.0\.1'
        $text | Should Match '(?ms)name:\s*iii-stream.*?port:\s*6667.*?host:\s*127\.0\.0\.1'
        $text | Should Match 'http://agentmemory-viewer\.invalid:6002'
        $text | Should Not Match 'http://(?:localhost|127\.0\.0\.1):4113'
        $text | Should Not Match '(?mi)^\s*(?:-\s*)?name\s*:\s*["'']?iii-exec'
        $text | Should Not Match '(?mi)^\s*(?:-\s*)?(?:exec|watch)\s*:'
        $text | Should Not Match '__AGENTMEMORY_(?:INSTALL_ROOT|NODE_EXE|GUARD_SCRIPT|SUPERVISOR_SCRIPT)_POSIX__'
        $text | Should Not Match '__AGENTMEMORY_[A-Z0-9_]+__'
    }

    It "rejects unsafe data and every external process directive before writing" {
        $root = Join-Path $TestDrive 'UnsafePaths'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $canonical = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'agentmemory-iii.yaml'))
        foreach ($directive in @(
                '- name : "iii-exec"', "- name: 'iii-exec' # forbidden",
                'exec: cmd /c node app.mjs', 'exec : [node, app.mjs]',
                'watch: ./dist', 'watch : [./dist]',
                '__AGENTMEMORY_NODE_EXE_POSIX__'
            )) {
            [System.IO.File]::WriteAllText($fixture.Config, $canonical + "`r`n" + $directive)
            (Test-RuntimeThrows { Get-AgentMemoryMaterializedConfig `
                -TemplatePath $fixture.Config -DataRoot $fixture.DataRoot `
                -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                -GuardScript $fixture.GuardScript -HttpPort 4111 }) | Should Be $true
        }
        [System.IO.File]::WriteAllText($fixture.Config, $canonical)
        foreach ($dataSuffix in @(
                '$meta', '"meta', '__AGENTMEMORY_HTTP_PORT__',
                ([string][char]0x85), ([string][char]0x2028), ([string][char]0x2029),
                ([string][char]0xfffe), ([string][char]0xffff), ([string][char]0xd800)
            )) {
            $unsafeData = $fixture.DataRoot + $dataSuffix
            (Test-RuntimeThrows { Get-AgentMemoryMaterializedConfig `
                -TemplatePath $fixture.Config -DataRoot $unsafeData `
                -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                -GuardScript $fixture.GuardScript -HttpPort 4111 }) |
                Should Be $true
        }
        $fixture.RuntimeConfig | Should Not Exist
    }

    It "requires the full canonical token contract and forbids resolved config input" {
        $root = Join-Path $TestDrive 'TemplateContract'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $tokens = @(
            '__AGENTMEMORY_DATA_ROOT_POSIX__',
            '__AGENTMEMORY_HTTP_PORT__', '__AGENTMEMORY_INTERNAL_REST_PORT__',
            '__AGENTMEMORY_STREAM_PORT__',
            '__AGENTMEMORY_VIEWER_PORT__', '__AGENTMEMORY_ENGINE_PORT__'
        )
        foreach ($token in $tokens) {
            $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'agentmemory-iii.yaml'))
            [System.IO.File]::WriteAllText($fixture.Config, $text.Replace($token, 'resolved'))
            (Test-RuntimeThrows { Get-AgentMemoryMaterializedConfig `
                -TemplatePath $fixture.Config -DataRoot $fixture.DataRoot `
                -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                -GuardScript $fixture.GuardScript -HttpPort 4111 }) |
                Should Be $true
        }
        $canonicalText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'agentmemory-iii.yaml'))
        $canonicalText | Should Not Match '__AGENTMEMORY_(?:INSTALL_ROOT|NODE_EXE|GUARD_SCRIPT|SUPERVISOR_SCRIPT)_POSIX__'
        $canonicalText | Should Not Match '(?mi)^\s*(?:-\s*)?(?:exec|watch)\s*:'
    }

    It "atomically replaces an active config without temporary residue" {
        $root = Join-Path $TestDrive 'AtomicConfig'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Set-Content -LiteralPath $fixture.RuntimeConfig -Value 'stale-config' -Encoding ASCII

        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111

        [System.IO.File]::ReadAllText($fixture.RuntimeConfig) | Should Not Match 'stale-config|__AGENTMEMORY_'
        @(Get-ChildItem -LiteralPath $fixture.LogDir -File -Filter '.agentmemory-iii.*').Count | Should Be 0
    }

    It "accepts only an explicit loopback HTTP root at or below the public-port ceiling" {
        (Get-AgentMemoryServerSettings -DevToolsRoot $TestDrive -BaseUrl 'http://localhost:4111/').BaseUrl |
            Should Be 'http://127.0.0.1:4111'
        (Get-AgentMemoryServerSettings -DevToolsRoot $TestDrive -BaseUrl 'http://127.0.0.1:5997').Port |
            Should Be 5997
        foreach ($url in @(
                'https://127.0.0.1:4111', 'http://192.0.2.10:4111',
                'http://user:pass@127.0.0.1:4111', 'http://127.0.0.1:4111/path',
                'http://127.0.0.1:4111/?query=1', 'http://127.0.0.1:4111/#fragment',
                'http://[::1]:4111', 'http://127.0.0.1:5998', 'http://127.0.0.1:19513'
            )) {
            (Test-RuntimeThrows {
                    Get-AgentMemoryServerSettings -DevToolsRoot $TestDrive -BaseUrl $url
                }) | Should Be $true
        }
    }

    It "starts only the pinned Node supervisor with the complete child contract" {
        $root = Join-Path $TestDrive 'PinnedStart'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-NetTCPConnection { return @() }
        Mock Get-CimInstance { return @() }
        Mock Start-Process { return [pscustomobject]@{ Id=104 } }
        Mock Wait-AgentMemoryServerReady { return $true }
        $environmentNames = @(
            'PATH', 'AGENTMEMORY_TOOLS', 'AGENTMEMORY_SLOTS', 'AGENTMEMORY_URL',
            'AGENTMEMORY_DATA_ROOT', 'AGENTMEMORY_INSTALL_ROOT', 'NODE_EXE',
            'NODE_OPTIONS', 'NODE_PATH',
            'NoDefaultCurrentDirectoryInExePath', 'EMBEDDING_PROVIDER', 'III_REST_PORT',
            'III_STREAM_PORT', 'III_ENGINE_PORT', 'III_ENGINE_URL',
            'AGENTMEMORY_VIEWER_HOST', 'VIEWER_ALLOWED_HOSTS', 'VIEWER_ALLOWED_ORIGINS',
            'AGENTMEMORY_III_CONFIG'
        )
        $savedEnvironment = @{}
        foreach ($name in $environmentNames) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        try {
            $env:AGENTMEMORY_TOOLS = 'restricted'
            $env:AGENTMEMORY_SLOTS = 'false'
            $env:III_ENGINE_URL = 'ws://0.0.0.0:1'
            $env:AGENTMEMORY_VIEWER_HOST = '0.0.0.0'
            $env:VIEWER_ALLOWED_HOSTS = 'evil.example:6002,*'
            $env:NODE_OPTIONS = '--require C:\hostile\preload.cjs --inspect=0.0.0.0:9229'
            $env:NODE_PATH = 'C:\hostile\modules'
            $result = Invoke-AgentMemoryServer `
                -DevToolsRoot $root -DataRoot $fixture.DataRoot `
                -BaseUrl 'http://localhost:4111' -Config $fixture.Config `
                -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                -IiiExecutable $fixture.IiiExecutable -LogDir $fixture.LogDir `
                -EmbeddingProvider 'local' -StartupWaitSeconds 1

            $result | Should Be 0
            $env:AGENTMEMORY_TOOLS | Should Be 'all'
            $env:AGENTMEMORY_SLOTS | Should Be 'true'
            $env:AGENTMEMORY_URL | Should Be 'http://127.0.0.1:4111'
            $env:NODE_EXE | Should Be $fixture.NodeExecutable
            $env:NODE_OPTIONS | Should BeNullOrEmpty
            $env:NODE_PATH | Should BeNullOrEmpty
            $env:III_REST_PORT | Should Be '6000'
            $env:III_STREAM_PORT | Should Be '6667'
            $env:III_ENGINE_PORT | Should Be '10080'
            $env:III_ENGINE_URL | Should Be 'ws://127.0.0.1:10080'
            $env:AGENTMEMORY_VIEWER_HOST | Should Be '127.0.0.2'
            $env:VIEWER_ALLOWED_HOSTS | Should Be 'agentmemory-viewer.invalid:6002'
            $env:VIEWER_ALLOWED_ORIGINS | Should Be 'http://agentmemory-viewer.invalid:6002'
            $env:AGENTMEMORY_III_CONFIG | Should Be $fixture.RuntimeConfig
        } finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
            }
        }
        $fixture.RuntimeConfig | Should Exist
        Assert-MockCalled Start-Process -Times 1 -Scope It -ParameterFilter {
            $FilePath -eq $fixture.NodeExecutable -and
            $NoNewWindow -eq $true -and
            -not $PSBoundParameters.ContainsKey('WindowStyle') -and
            $ArgumentList[0] -eq ('"' + $fixture.SupervisorScript + '"') -and
            ($ArgumentList -join '|') -eq (
                ('"' + $fixture.SupervisorScript + '"') +
                '|--iii-executable|"' + $fixture.IiiExecutable + '"' +
                '|--iii-config|"' + $fixture.RuntimeConfig + '"' +
                '|--agentmemory-entry|"' + $fixture.AgentMemoryEntry + '"' +
                '|--guard-script|"' + $fixture.GuardScript + '"' +
                '|--listen-port|4111|--upstream-port|6000' +
                '|--stream-port|6667|--engine-port|10080')
        }
    }

    It "proves the fixed viewer rejects invalid bearer tokens and isolates the exact secret with 502" {
        $script:expectedViewerSecret = ('A1b2C3d4_' * 4)
        $script:viewerProbeRequests = @()
        Mock Invoke-AgentMemoryViewerRequest {
            $script:viewerProbeRequests += [pscustomobject]@{
                Uri=$Uri; HostHeader=$HostHeader
                Authorization=$Authorization; TimeoutSeconds=$TimeoutSeconds
            }
            if ([string]::IsNullOrEmpty($Authorization) -or
                $Authorization -ne ('Bearer ' + $script:expectedViewerSecret)) {
                return [pscustomobject]@{ StatusCode=401; Body='unauthorized' }
            }
            return [pscustomobject]@{
                StatusCode=502
                Body='bad-port isolation'
            }
        }

        (Test-AgentMemoryViewerIsolation `
            -Secret $script:expectedViewerSecret `
            -TimeoutSeconds 7) | Should Be $true

        $script:viewerProbeRequests.Count | Should Be 3
        @($script:viewerProbeRequests | Select-Object -ExpandProperty Uri -Unique) -join ',' |
            Should Be 'http://127.0.0.2:6002/agentmemory/health'
        @($script:viewerProbeRequests | Select-Object -ExpandProperty HostHeader -Unique) -join ',' |
            Should Be 'agentmemory-viewer.invalid:6002'
        $script:viewerProbeRequests[0].Authorization | Should BeNullOrEmpty
        $script:viewerProbeRequests[1].Authorization | Should Match '^Bearer '
        $script:viewerProbeRequests[1].Authorization | Should Not Be ('Bearer ' + $script:expectedViewerSecret)
        $script:viewerProbeRequests[2].Authorization | Should Be ('Bearer ' + $script:expectedViewerSecret)
        @($script:viewerProbeRequests | Select-Object -ExpandProperty TimeoutSeconds -Unique) -join ',' |
            Should Be '7'
    }

    It "fails before launch when a pinned dependency or canonical template is missing" {
        $root = Join-Path $TestDrive 'MissingDependency'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-NetTCPConnection { throw 'network probing must not occur' }
        Mock Start-Process { throw 'launch must not occur' }

        foreach ($case in @(
                @{ Config=(Join-Path $root 'missing.yaml'); Node=$fixture.NodeExecutable; Iii=$fixture.IiiExecutable; Install=$fixture.InstallRoot },
                @{ Config=$fixture.Config; Node=(Join-Path $root 'missing-node.exe'); Iii=$fixture.IiiExecutable; Install=$fixture.InstallRoot },
                @{ Config=$fixture.Config; Node=$fixture.NodeExecutable; Iii=(Join-Path $root 'missing-iii.exe'); Install=$fixture.InstallRoot },
                @{ Config=$fixture.Config; Node=$fixture.NodeExecutable; Iii=$fixture.IiiExecutable; Install=(Join-Path $root 'empty-install') }
            )) {
            (Test-RuntimeThrows { Invoke-AgentMemoryServer `
                -DevToolsRoot $root -BaseUrl 'http://127.0.0.1:4111' `
                -Config $case.Config -InstallRoot $case.Install `
                -NodeExecutable $case.Node -IiiExecutable $case.Iii `
                -LogDir $fixture.LogDir }) | Should Be $true
        }
        Remove-Item -LiteralPath $fixture.GuardScript -Force
        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir }) | Should Be $true
        Set-Content -LiteralPath $fixture.GuardScript -Value '// guard fixture' -Encoding ASCII
        Remove-Item -LiteralPath $fixture.SupervisorScript -Force
        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir }) | Should Be $true
        Set-Content -LiteralPath $fixture.SupervisorScript -Value '// supervisor fixture' -Encoding ASCII
        $manifest = Join-Path $fixture.InstallRoot 'node_modules\@agentmemory\agentmemory\package.json'
        Set-Content -LiteralPath $manifest -Value '{"version":"0.9.26"}' -Encoding ASCII
        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir }) | Should Be $true
        Assert-MockCalled Start-Process -Times 0 -Scope It
        Assert-MockCalled Get-NetTCPConnection -Times 0 -Scope It
    }

    It "adopts only one exact-version listener owned by the pinned process tree" {
        $root = Join-Path $TestDrive 'ExactExisting'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Set-AgentMemoryReloadMarker -ConfigPath $fixture.RuntimeConfig -Timestamp '2026-07-22 20:00:00'
        $entry = $fixture.AgentMemoryEntry
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        Mock Get-NetTCPConnection {
            $port = [int](@($LocalPort)[0])
            if ($port -in @(4112, 4113, 50134)) { return @() }
            $owner = if ($port -eq 4111) { 106 } elseif ($port -eq 6002) { 105 } else { 104 }
            $address = if ($port -eq 6002) { '127.0.0.2' } else { '127.0.0.1' }
            return [pscustomobject]@{
                LocalPort=$port; LocalAddress=$address; OwningProcess=$owner
            }
        }
        Mock Invoke-RestMethod {
            if ($Headers.Authorization -ne ('Bearer ' + ('A1b2C3d4_' * 4))) {
                throw 'missing authenticated request header'
            }
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6000
                }
            }
            return [pscustomobject]@{
                service='agentmemory'; status='healthy'; version='0.9.27'
                viewerPort=6002; viewerSkipped=$false
            }
        }
        Mock Invoke-AgentMemoryViewerRequest {
            if ($Authorization -eq ('Bearer ' + ('A1b2C3d4_' * 4))) {
                return [pscustomobject]@{
                    StatusCode=502
                    Body='bad-port isolation'
                }
            }
            return [pscustomobject]@{ StatusCode=401; Body='unauthorized' }
        }
        Mock Get-CimInstance {
            return @(
                [pscustomobject]@{ Name='node.exe'; ProcessId=103; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=104; ParentProcessId=103; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=105; ParentProcessId=103; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=106; ParentProcessId=103; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand }
            )
        }
        Mock Start-Process { }

        (Test-AgentMemoryNodeUsesEntry `
            -CommandLine "`"$($fixture.NodeExecutable)`" `"$entry`"" `
            -NodeExecutable $fixture.NodeExecutable `
            -InstallRoot $fixture.InstallRoot) | Should Be $true
        (Test-AgentMemoryNodeUsesGuard `
            -CommandLine $guardCommand `
            -NodeExecutable $fixture.NodeExecutable `
            -GuardScript $fixture.GuardScript `
            -HttpPort 4111) | Should Be $true
        (Test-AgentMemoryNodeUsesSupervisor `
            -CommandLine $supervisorCommand `
            -NodeExecutable $fixture.NodeExecutable `
            -InstallRoot $fixture.InstallRoot `
            -IiiExecutable $fixture.IiiExecutable `
            -ConfigPath $fixture.RuntimeConfig `
            -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript `
            -HttpPort 4111) | Should Be $true
        (Test-AgentMemoryIiiUsesConfig `
            -CommandLine "`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" `
            -IiiExecutable $fixture.IiiExecutable `
            -ConfigPath $fixture.RuntimeConfig) | Should Be $true
        $runtimeProcesses = @(Get-CimInstance Win32_Process)
        $runtimeProcesses.Count | Should Be 4
        $runtimeProcessMap = @{}
        foreach ($runtimeProcess in $runtimeProcesses) {
            $runtimeProcessMap[[string][int]$runtimeProcess.ProcessId] = $runtimeProcess
        }
        (Test-AgentMemoryServerProcessDescendsFrom `
            -ProcessId 105 -RootProcessId 103 -ProcessMap $runtimeProcessMap) | Should Be $true
        (Test-AgentMemoryServerProcessDescendsFrom `
            -ProcessId 106 -RootProcessId 103 -ProcessMap $runtimeProcessMap) | Should Be $true
        [int]$runtimeProcessMap['105'].ParentProcessId | Should Be 103
        [int]$runtimeProcessMap['106'].ParentProcessId | Should Be 103
        foreach ($portContract in @(
                @{ Port=4111; Owner=106; Address='127.0.0.1' },
                @{ Port=6002; Owner=105; Address='127.0.0.2' },
                @{ Port=6000; Owner=104 }, @{ Port=6667; Owner=104 }, @{ Port=10080; Owner=104 }
            )) {
            $portListeners = @(Get-NetTCPConnection -State Listen -LocalPort $portContract.Port)
            $portListeners.Count | Should Be 1
            $expectedAddress = if ($portContract.ContainsKey('Address')) {
                $portContract.Address
            } else { '127.0.0.1' }
            $portListeners[0].LocalAddress | Should Be $expectedAddress
            [int]$portListeners[0].OwningProcess | Should Be $portContract.Owner
        }
        foreach ($retiredPort in @(4112, 4113, 50134)) {
            @(Get-NetTCPConnection -State Listen -LocalPort $retiredPort).Count | Should Be 0
        }
        (Test-AgentMemoryRuntimeListeners `
            -ConfigPath $fixture.RuntimeConfig `
            -IiiExecutable $fixture.IiiExecutable `
            -NodeExecutable $fixture.NodeExecutable `
            -InstallRoot $fixture.InstallRoot `
            -GuardScript $fixture.GuardScript `
            -SupervisorScript $fixture.SupervisorScript `
            -HttpPort 4111) | Should Be $true

        (Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir) | Should Be 0
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It "rejects stale health, drifted active bytes, wrong binaries, and arbitrary listener descendants" {
        $root = Join-Path $TestDrive 'RejectExisting'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        $entry = $fixture.AgentMemoryEntry
        $guardCommand = "`"$($fixture.NodeExecutable)`" `"$($fixture.GuardScript)`" --listen-port 4111 --upstream-port 6000"
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        Mock Get-NetTCPConnection {
            if ($script:existingFailureMode -eq 'missing-viewer' -and $LocalPort -eq 6002) {
                return @()
            }
            if ([int]$LocalPort -in @(4112, 4113, 50134)) {
                if ($script:existingFailureMode -eq 'legacy-listener' -or
                    ($script:existingFailureMode -eq 'public-r-plus-two-listener' -and
                        [int]$LocalPort -eq 4113)) {
                    return [pscustomobject]@{ LocalPort=$LocalPort; LocalAddress='127.0.0.1'; OwningProcess=104 }
                }
                return @()
            }
            $owner = if ($script:existingFailureMode -eq 'split-root' -and $LocalPort -in @(6000, 10080)) {
                204
            } elseif ($LocalPort -eq 4111) {
                106
            } elseif ($LocalPort -eq 6002) {
                if ($script:existingFailureMode -eq 'viewer-wrong-owner') { 104 } else { 105 }
            } else {
                104
            }
            $address = if ($script:existingFailureMode -eq 'external-bind' -and $LocalPort -eq 6667) {
                '0.0.0.0'
            } elseif ($LocalPort -eq 6002) {
                if ($script:existingFailureMode -eq 'viewer-wrong-address') {
                    '127.0.0.1'
                } else { '127.0.0.2' }
            } else {
                '127.0.0.1'
            }
            return [pscustomobject]@{
                LocalPort=$LocalPort; LocalAddress=$address; OwningProcess=$owner
            }
        }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/__devtools/agentmemory-host-guard/health') {
                if ($script:existingFailureMode -eq 'guard-health') {
                    return [pscustomobject]@{
                        service='foreign'; status='healthy'; version='1'; listenPort=4111; upstreamPort=6000
                    }
                }
                return [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6000
                }
            }
            if ($script:existingFailureMode -eq 'health') {
                return [pscustomobject]@{
                    service='agentmemory'; status='degraded'; version='0.9.26'
                    viewerPort=6002; viewerSkipped=$false
                }
            }
            $viewerPort = if ($script:existingFailureMode -eq 'viewer-fallback') { 6003 } else { 6002 }
            $viewerSkipped = ($script:existingFailureMode -eq 'viewer-skipped')
            return [pscustomobject]@{
                service='agentmemory'; status='healthy'; version='0.9.27'
                viewerPort=$viewerPort; viewerSkipped=$viewerSkipped
            }
        }
        Mock Invoke-AgentMemoryViewerRequest {
            $correctAuthorization = ('Bearer ' + ('A1b2C3d4_' * 4))
            if ([string]::IsNullOrEmpty($Authorization)) {
                $statusCode = if ($script:existingFailureMode -eq 'viewer-missing-auth-accepted') { 200 } else { 401 }
                return [pscustomobject]@{ StatusCode=$statusCode; Body='unauthorized' }
            }
            if ($Authorization -ne $correctAuthorization) {
                $statusCode = if ($script:existingFailureMode -eq 'viewer-wrong-auth-accepted') { 200 } else { 401 }
                return [pscustomobject]@{ StatusCode=$statusCode; Body='unauthorized' }
            }
            $statusCode = if ($script:existingFailureMode -eq 'viewer-correct-auth-not-isolated') { 200 } else { 502 }
            return [pscustomobject]@{
                StatusCode=$statusCode
                Body='bad-port isolation'
            }
        }
        Mock Get-CimInstance {
            $iiiPath = if ($script:existingFailureMode -eq 'engine') { 'C:\foreign\iii.exe' } else { $fixture.IiiExecutable }
            $nodePath = if ($script:existingFailureMode -eq 'node') { 'C:\foreign\node.exe' } else { $fixture.NodeExecutable }
            $ownerName = if ($script:existingFailureMode -eq 'descendant') { 'helper.exe' } else { 'iii.exe' }
            $iiiCommand = "`"$iiiPath`" --config `"$($fixture.RuntimeConfig)`""
            if ($script:existingFailureMode -eq 'iii-command') { $iiiCommand += ' --extra' }
            $processes = @(
                [pscustomobject]@{
                    Name='node.exe'; ProcessId=103; ParentProcessId=1
                    ExecutablePath=$fixture.NodeExecutable
                    CommandLine=if ($script:existingFailureMode -eq 'supervisor-command') {
                        $supervisorCommand + ' --extra'
                    } else { $supervisorCommand }
                },
                [pscustomobject]@{ Name=$ownerName; ProcessId=104; ParentProcessId=103; ExecutablePath=$iiiPath; CommandLine=$iiiCommand },
                [pscustomobject]@{
                    Name='node.exe'; ProcessId=105
                    ParentProcessId=if ($script:existingFailureMode -eq 'child-parent-bypass') { 1 } else { 103 }
                    ExecutablePath=$nodePath; CommandLine="`"$nodePath`" `"$entry`""
                },
                [pscustomobject]@{
                    Name='node.exe'; ProcessId=106; ParentProcessId=103; ExecutablePath=$fixture.NodeExecutable
                    CommandLine=if ($script:existingFailureMode -eq 'guard-command') {
                        $guardCommand + ' --extra'
                    } else { $guardCommand }
                }
            )
            if ($script:existingFailureMode -eq 'split-root') {
                $processes += @(
                    [pscustomobject]@{ Name='node.exe'; ProcessId=203; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                    [pscustomobject]@{ Name='iii.exe'; ProcessId=204; ParentProcessId=203; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                    [pscustomobject]@{ Name='node.exe'; ProcessId=205; ParentProcessId=203; ExecutablePath=$fixture.NodeExecutable; CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`"" },
                    [pscustomobject]@{ Name='node.exe'; ProcessId=206; ParentProcessId=203; ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand }
                )
            }
            if ($script:existingFailureMode -eq 'duplicate-node') {
                $processes += [pscustomobject]@{
                    Name='node.exe'; ProcessId=107; ParentProcessId=103
                    ExecutablePath=$fixture.NodeExecutable
                    CommandLine="`"$($fixture.NodeExecutable)`" `"$entry`""
                }
            }
            if ($script:existingFailureMode -eq 'duplicate-guard') {
                $processes += [pscustomobject]@{
                    Name='node.exe'; ProcessId=108; ParentProcessId=103
                    ExecutablePath=$fixture.NodeExecutable; CommandLine=$guardCommand
                }
            }
            if ($script:existingFailureMode -eq 'duplicate-supervisor') {
                $processes += [pscustomobject]@{
                    Name='node.exe'; ProcessId=109; ParentProcessId=1
                    ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand
                }
            }
            if ($script:existingFailureMode -eq 'extra-direct-child') {
                $processes += [pscustomobject]@{
                    Name='helper.exe'; ProcessId=110; ParentProcessId=103
                    ExecutablePath='C:\fixture\helper.exe'; CommandLine='helper.exe'
                }
            }
            return $processes
        }
        Mock Start-Process { }

        foreach ($mode in @(
                'guard-health', 'health', 'viewer-fallback', 'viewer-skipped', 'engine', 'node',
                'descendant', 'external-bind', 'missing-viewer', 'split-root', 'duplicate-node',
                'duplicate-guard', 'duplicate-supervisor', 'guard-command',
                'supervisor-command', 'iii-command', 'child-parent-bypass',
                'extra-direct-child', 'legacy-listener',
                'public-r-plus-two-listener', 'viewer-wrong-owner', 'viewer-wrong-address',
                'viewer-missing-auth-accepted', 'viewer-wrong-auth-accepted',
                'viewer-correct-auth-not-isolated'
            )) {
            $script:existingFailureMode = $mode
            $rejected = Test-RuntimeThrows { Invoke-AgentMemoryServer `
                -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
                -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
                -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
                -LogDir $fixture.LogDir }
            if (-not $rejected) { throw "Existing runtime mode was accepted unexpectedly: $mode" }
        }
        $script:existingFailureMode = 'drift'
        Set-Content -LiteralPath $fixture.RuntimeConfig -Value 'workers: [] # drift' -Encoding ASCII
        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir }) | Should Be $true
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It "rejects multiple REST listeners and every occupied derived port" {
        $root = Join-Path $TestDrive 'PortCollision'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock Get-CimInstance { return @() }
        Mock Start-Process { }

        $script:collisionMode = 'multiple'
        Mock Get-NetTCPConnection {
            if ($script:collisionMode -eq 'multiple' -and $LocalPort -eq 4111) {
                return @(
                    [pscustomobject]@{ LocalPort=4111; OwningProcess=1 },
                    [pscustomobject]@{ LocalPort=4111; OwningProcess=2 }
                )
            }
            if ($script:collisionMode -ne 'multiple' -and $LocalPort -eq [int]$script:collisionMode) {
                return [pscustomobject]@{ LocalPort=$LocalPort; OwningProcess=2 }
            }
            return @()
        }
        foreach ($mode in @('multiple', '4112', '4113', '50134', '6000', '6002', '6667', '10080')) {
            $script:collisionMode = $mode
            (Test-RuntimeThrows { Invoke-AgentMemoryServer `
                -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
                -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
                -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
                -LogDir $fixture.LogDir }) | Should Be $true
        }
        $fixture.RuntimeConfig | Should Not Exist
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It "validates active bytes without probing or launching" {
        $root = Join-Path $TestDrive 'ValidateOnly'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Mock Get-NetTCPConnection { throw 'validate-only must not probe listeners' }
        Mock Start-Process { throw 'validate-only must not launch' }

        (Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ValidateOnly) | Should Be 0
        Set-Content -LiteralPath $fixture.RuntimeConfig -Value 'workers: [] # drift' -Encoding ASCII
        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -ValidateOnly }) | Should Be $true
        Assert-MockCalled Get-NetTCPConnection -Times 0 -Scope It
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It "never starts a missing service during read-only inspection" {
        $root = Join-Path $TestDrive 'InspectOnlyStopped'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Mock Get-NetTCPConnection { return @() }
        Mock Get-CimInstance { return @() }
        Mock Start-Process { }

        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -InspectOnly }) | Should Be $true
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It "cleans up only the exact started tree when readiness times out" {
        $root = Join-Path $TestDrive 'ReadinessTimeout'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $supervisorCommand = Get-AgentMemoryFixtureSupervisorCommand -Fixture $fixture
        $script:timeoutCimProbe = 0
        Mock Get-NetTCPConnection { return @() }
        Mock Get-CimInstance {
            $script:timeoutCimProbe++
            if ($script:timeoutCimProbe -le 2) { return @() }
            return @(
                [pscustomobject]@{ Name='node.exe'; ProcessId=100; ParentProcessId=1; ExecutablePath=$fixture.NodeExecutable; CommandLine=$supervisorCommand },
                [pscustomobject]@{ Name='iii.exe'; ProcessId=104; ParentProcessId=100; ExecutablePath=$fixture.IiiExecutable; CommandLine="`"$($fixture.IiiExecutable)`" --config `"$($fixture.RuntimeConfig)`"" },
                [pscustomobject]@{ Name='node.exe'; ProcessId=105; ParentProcessId=100; ExecutablePath=$fixture.NodeExecutable; CommandLine='node child' },
                [pscustomobject]@{ Name='helper.exe'; ProcessId=106; ParentProcessId=105; ExecutablePath='C:\fixture\helper.exe'; CommandLine='helper child' }
            )
        }
        Mock Start-Process { return [pscustomobject]@{ Id=100 } }
        Mock Wait-AgentMemoryServerReady { return $false }
        $script:timeoutStopped = @()
        Mock Stop-Process {
            foreach ($processId in @($Id)) { $script:timeoutStopped += [int]$processId }
        }

        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir -StartupWaitSeconds 1 }) | Should Be $true
        $script:timeoutStopped[0] | Should Be 106
        $script:timeoutStopped[-1] | Should Be 100
        @($script:timeoutStopped | Sort-Object) -join ',' | Should Be '100,104,105,106'
    }

    It "serializes startup by port across different roots" {
        $lock = Open-AgentMemoryInstanceLock -Port 5197 -TimeoutSeconds 1
        try {
            (Test-RuntimeThrows {
                    Open-AgentMemoryInstanceLock -Port 5197 -TimeoutSeconds 1
                }) | Should Be $true
        } finally {
            $lock.Dispose()
        }
        $next = Open-AgentMemoryInstanceLock -Port 5197 -TimeoutSeconds 1
        $next.Dispose()
    }

    It "contains no package-launcher or package-config fallback" {
        $source = Get-Content -LiteralPath (Get-RuntimeScriptPath 'agentmemory-server.ps1') -Raw
        $source | Should Not Match 'AgentMemoryLauncher|agentmemory\.cmd|dist\\iii-config\.yaml'
    }

    It "sends no bearer request when exact listener and process ownership cannot be proven" {
        $root = Join-Path $TestDrive 'OwnershipBeforeBearer'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        New-AgentMemoryActiveConfig -TemplatePath $fixture.Config -ActivePath $fixture.RuntimeConfig `
            -DataRoot $fixture.DataRoot -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -GuardScript $fixture.GuardScript -HttpPort 4111
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalPort=4111; LocalAddress='127.0.0.1'; OwningProcess=999 }
        }
        Mock Test-AgentMemoryRuntimeListeners { return $false }
        Mock Invoke-RestMethod { throw 'Bearer request must not run' }
        Mock Invoke-AgentMemoryViewerRequest { throw 'Viewer bearer request must not run' }
        Mock Start-Process { throw 'Adoption failure must not launch' }

        (Test-RuntimeThrows { Invoke-AgentMemoryServer `
            -DevToolsRoot $root -DataRoot $fixture.DataRoot -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir }) | Should Be $true

        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
        Assert-MockCalled Invoke-AgentMemoryViewerRequest -Times 0 -Scope It
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }
}

Describe "agentmemory watchdog behavior" {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        Mock Get-AgentMemoryWatchdogRequiredSecret { return ('A1b2C3d4_' * 4) }
        Mock Assert-AgentMemoryWatchdogSecret { }
    }

    It "uses a short quoted runner action and rejects cmd metacharacters or overflow" {
        $action = New-AgentMemoryWatchdogAction `
            -RunnerCommand 'C:\Portable Tools\agentmemory-watchdog-run.cmd' `
            -SettingsPath 'C:\Portable Tools\logs\watchdog.settings.json'

        $action | Should Be '"C:\Portable Tools\agentmemory-watchdog-run.cmd" "C:\Portable Tools\logs\watchdog.settings.json"'
        $action.Length | Should BeLessThan 263
        foreach ($unsafe in @('%unsafe', '!unsafe', '&unsafe', '|unsafe', '<unsafe', '>unsafe', '^unsafe')) {
            (Test-RuntimeThrows { New-AgentMemoryWatchdogAction `
                -RunnerCommand ('C:\Tools\run' + $unsafe + '.cmd') `
                -SettingsPath 'C:\Tools\settings.json' }) | Should Be $true
        }
        $longPath = 'C:\' + ('a' * 250) + '.json'
        (Test-RuntimeThrows { New-AgentMemoryWatchdogAction `
            -RunnerCommand 'C:\Tools\run.cmd' `
            -SettingsPath $longPath }) | Should Be $true
    }

    It "atomically writes no-BOM watchdog settings without residue" {
        $path = Join-Path $TestDrive 'watchdog\settings.json'
        Write-AgentMemoryWatchdogSettings -Path $path -Settings ([ordered]@{ Alpha='one'; Beta='two' })
        Write-AgentMemoryWatchdogSettings -Path $path -Settings ([ordered]@{ Alpha='new'; Beta='two' })
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) |
            Should Be $false
        ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json).Alpha | Should Be 'new'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '.agentmemory-watchdog.*').Count |
            Should Be 0
    }

    It "validates a complete settings schema and forwards the exact lifecycle contract" {
        $root = Join-Path $TestDrive 'WatchdogRunner'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $selfHeal = Get-RuntimeScriptPath 'agentmemory-selfheal.ps1'
        New-Item -ItemType Directory -Path $fixture.DataRoot, $fixture.LogDir -Force | Out-Null
        $runRoot = Join-Path $fixture.DataRoot 'run'
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $secret = ('A1b2C3d4_' * 4)
        $blob = Protect-AgentMemoryWatchdogSecret -Secret $secret
        try {
            $blobHash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blob
            $blobPath = Join-Path $runRoot ("watchdog-secret.$blobHash.dpapi")
            Write-AgentMemoryWatchdogAtomicBytes -Path $blobPath -Bytes $blob
        } finally {
            if ($null -ne $blob) { [Array]::Clear($blob, 0, $blob.Length) }
        }
        $settingsPath = Join-Path $fixture.LogDir 'watchdog.settings.json'
        $powerShellExecutable = (Get-Command powershell.exe -CommandType Application).Source
        $settings = [ordered]@{
            SchemaVersion=1
            DevToolsRoot=$root
            DataRoot=$fixture.DataRoot
            BaseUrl='http://127.0.0.1:4111'
            Config=$fixture.Config
            InstallRoot=$fixture.InstallRoot
            NodeExecutable=$fixture.NodeExecutable
            IiiExecutable=$fixture.IiiExecutable
            EmbeddingProvider='local'
            LogDir=$fixture.LogDir
            SelfHealScript=$selfHeal
            ServerScript=$fixture.ServerScript
            PowerShellExecutable=$powerShellExecutable
            SecretBlobPath=$blobPath
            SecretCiphertextSha256=$blobHash
        }
        Write-AgentMemoryWatchdogSettings -Path $settingsPath -Settings $settings
        $script:watchdogRunnerArguments = @()
        $script:watchdogRunnerObservedSecret = $null
        Mock Invoke-AgentMemoryWatchdogSelfHeal {
            $script:watchdogRunnerArguments = @($Arguments)
            $script:watchdogRunnerObservedSecret =
                [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
            return 0
        }

        $previousSecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
        $preexistingSecret = ('Z9y8X7w6_' * 4)
        try {
            [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $preexistingSecret, 'Process')
            (Invoke-AgentMemoryWatchdogRunner -SettingsPath $settingsPath) | Should Be 0
            $script:watchdogRunnerObservedSecret | Should Be $secret
            [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') |
                Should Be $preexistingSecret
        } finally {
            [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previousSecret, 'Process')
        }
        $joined = $script:watchdogRunnerArguments -join '|'
        foreach ($fragment in @(
                '-ExecutionPolicy|Bypass', '-DevToolsRoot|' + $root,
                '-DataRoot|' + $fixture.DataRoot, '-BaseUrl|http://127.0.0.1:4111',
                '-Config|' + $fixture.Config, '-InstallRoot|' + $fixture.InstallRoot,
                '-NodeExecutable|' + $fixture.NodeExecutable, '-IiiExecutable|' + $fixture.IiiExecutable,
                '-EmbeddingProvider|local', '-LogDir|' + $fixture.LogDir,
                '-ServerScript|' + $fixture.ServerScript, '-PowerShellExecutable|' + $powerShellExecutable
            )) {
            $joined | Should Match ([regex]::Escape($fragment))
        }

        $settings.Unexpected = 'value'
        Write-AgentMemoryWatchdogSettings -Path $settingsPath -Settings $settings
        (Test-RuntimeThrows {
                Invoke-AgentMemoryWatchdogRunner -SettingsPath $settingsPath
            }) | Should Be $true
    }

    It "omits empty foreground-loop overrides instead of emitting named nulls" {
        $script:watchdogLoopArguments = @()
        Mock powershell.exe {
            $script:watchdogLoopArguments = @($args)
            $global:LASTEXITCODE = 0
        }
        (Invoke-AgentMemoryWatchdogOnce `
            -PowerShellExecutable 'powershell.exe' `
            -SelfHealScript (Get-RuntimeScriptPath 'agentmemory-selfheal.ps1') `
            -LogPath (Join-Path $TestDrive 'watchdog.log') `
            -DevToolsRoot 'C:\Tools' `
            -BaseUrl 'http://127.0.0.1:4111') | Should Be 0
        $joined = $script:watchdogLoopArguments -join '|'
        $joined | Should Match ([regex]::Escape('-DevToolsRoot|C:\Tools'))
        $joined | Should Match ([regex]::Escape('-BaseUrl|http://127.0.0.1:4111'))
        $joined | Should Not Match '-DataRoot|-Config|-InstallRoot|-NodeExecutable|-IiiExecutable|-EmbeddingProvider|-LogDir|-ServerScript'
    }

    It "keys the foreground singleton atomically by canonical service port" {
        $settings = Get-AgentMemoryWatchdogLoopSettings `
            -DevToolsRoot $TestDrive `
            -BaseUrl 'http://localhost:4111/' `
            -SelfHealScript (Get-RuntimeScriptPath 'agentmemory-selfheal.ps1') `
            -IntervalSeconds 30
        $settings.BaseUrl | Should Be 'http://127.0.0.1:4111'
        $settings.Port | Should Be 4111

        $first = Open-AgentMemoryWatchdogLoopLock -Port 5192
        try {
            $samePort = Open-AgentMemoryWatchdogLoopLock -Port 5192
            $differentPort = Open-AgentMemoryWatchdogLoopLock -Port 5193
            $samePort | Should BeNullOrEmpty
            ($null -ne $differentPort) | Should Be $true
            $differentPort.Dispose()
        } finally {
            $first.Dispose()
        }
        $afterRelease = Open-AgentMemoryWatchdogLoopLock -Port 5192
        $afterRelease.Dispose()
    }

    It "does not invoke schtasks when registration is previewed" {
        $root = Join-Path $TestDrive 'WatchdogWhatIf'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        Mock schtasks.exe { throw "schtasks.exe must not run during WhatIf" }

        $result = Register-AgentMemoryWatchdog `
            -DevToolsRoot $root `
            -DataRoot $fixture.DataRoot `
            -BaseUrl 'http://localhost:4111' `
            -Config $fixture.Config `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir `
            -SelfHealScript (Get-RuntimeScriptPath "agentmemory-selfheal.ps1") `
            -ServerScript $fixture.ServerScript `
            -RunnerScript (Join-Path $repoRoot 'agentmemory-watchdog-run.cmd') `
            -TaskName "AgentmemoryWatchdog-WhatIf-Test" `
            -WhatIf

        $result | Should Be 0
        Assert-MockCalled schtasks.exe -Times 0 -Scope It
        @(Get-ChildItem -LiteralPath $fixture.LogDir -File -Filter 'agentmemory-watchdog.settings.*.json' -ErrorAction SilentlyContinue).Count |
            Should Be 0
    }

    It "ships CRLF no-BOM wrappers with hidden absolute Windows PowerShell" {
        foreach ($name in @('agentmemory-server.cmd', 'agentmemory-watchdog-run.cmd')) {
            $path = Join-Path $repoRoot $name
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) |
                Should Be $false
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            $text | Should Match "`r`n"
            ([regex]::Matches($text, '(?<!\r)\n').Count) | Should Be 0
            $text | Should Match '%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
            $text | Should Match '-ExecutionPolicy Bypass -WindowStyle Hidden'
        }
        foreach ($name in @('agentmemory-server.cmd', 'agentmemory-watchdog-run.cmd')) {
            (Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw) |
                Should Match 'setlocal DisableDelayedExpansion'
        }
    }
}

Describe "health-check configuration" {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    It "builds launcher checks from the launchers directory under the configured root" {
        $settings = Get-DevToolsHealthSettings `
            -DevToolsRoot "C:\Portable Tools" `
            -AgentResourcesRoot "C:\Agent Resources" `
            -AgentMemoryBaseUrl "http://localhost:4111"

        $settings.AgentMemoryPort | Should Be 4111
        $settings.AgentMemoryBaseUrl | Should Be 'http://127.0.0.1:4111'
        $settings.AgentMemoryHost | Should Be '127.0.0.1'
        $settings.AgentMemoryViewerHost | Should Be '127.0.0.2'
        $settings.AgentMemoryViewerPort | Should Be 6002
        $settings.AgentMemoryRuntimeConfig | Should Match 'logs\\agentmemory-iii\.active\.4111\.yaml$'
        $settings.Launchers.Count | Should BeGreaterThan 2
        @($settings.Launchers | Where-Object { $_ -like "*agentmemory-server.cmd" }).Count | Should Be 1
        @($settings.Launchers | Where-Object { $_ -like "C:\Portable Tools\launchers\*.cmd" }).Count |
            Should Be ($settings.Launchers.Count - 1)
    }

    It "supports a single-root launcher layout through an explicit override" {
        $settings = Get-DevToolsHealthSettings `
            -DevToolsRoot "C:\Portable Tools" `
            -LauncherRoot "C:\Launcher Bin" `
            -AgentResourcesRoot "C:\Agent Resources" `
            -AgentMemoryBaseUrl "http://127.0.0.1:4111"

        foreach ($launcher in @($settings.Launchers | Where-Object { $_ -notlike "*agentmemory-server.cmd" })) {
            $launcher | Should Match '^C:\\Launcher Bin\\[^\\]+\.cmd$'
        }
    }

    It "resolves relative runtime environment overrides from the configured root from any CWD" {
        $root = Join-Path $TestDrive 'PortableHealthRoot'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $names = @('AGENTMEMORY_INSTALL_ROOT', 'AGENTMEMORY_III_EXE', 'DEVTOOLS_LOG_DIR')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $startingLocation = (Get-Location).Path
        try {
            $env:AGENTMEMORY_INSTALL_ROOT = 'runtime'
            $env:AGENTMEMORY_III_EXE = 'bin\iii.exe'
            $env:DEVTOOLS_LOG_DIR = 'runtime-logs'
            Set-Location -LiteralPath ([System.IO.Path]::GetPathRoot($root))
            $settings = Get-DevToolsHealthSettings `
                -DevToolsRoot $root `
                -AgentResourcesRoot 'resources' `
                -AgentMemoryBaseUrl 'http://127.0.0.1:4111'
        } finally {
            Set-Location -LiteralPath $startingLocation
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
            }
        }
        $settings.AgentMemoryIiiExecutable | Should Be (Join-Path $root 'runtime\bin\iii.exe')
        $settings.AgentMemoryRuntimeConfig | Should Be (Join-Path $root 'runtime-logs\agentmemory-iii.active.4111.yaml')
        $settings.AgentResourcesRoot | Should Be (Join-Path $root 'resources')
    }

    It "rejects spoofed, unhealthy, or stale agentmemory health responses" {
        (Test-DevToolsAgentMemoryGuardResponse -Response ([pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6000
                }) -ExpectedPort 4111) | Should Be $true
        foreach ($guardResponse in @(
                [pscustomobject]@{
                    service='foreign'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6000
                },
                [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='degraded'; version='1'
                    listenPort=4111; upstreamPort=6000
                },
                [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort='4111'; upstreamPort=6000
                },
                [pscustomobject]@{
                    service='devtools-agentmemory-host-guard'; status='healthy'; version='1'
                    listenPort=4111; upstreamPort=6001
                }
            )) {
            (Test-DevToolsAgentMemoryGuardResponse `
                -Response $guardResponse `
                -ExpectedPort 4111) | Should Be $false
        }
        (Test-DevToolsAgentMemoryHealthResponse -Response ([pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6002; viewerSkipped=$false
                }) -ExpectedViewerPort 6002) | Should Be $true
        foreach ($response in @(
                [pscustomobject]@{ service='other'; status='healthy'; version='0.9.27' },
                [pscustomobject]@{ service='agentmemory'; status='degraded'; version='0.9.27' },
                [pscustomobject]@{ service='agentmemory'; status='healthy'; version='0.9.26' },
                [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort='6002'; viewerSkipped=$false
                },
                [pscustomobject]@{ StatusCode=200 }
            )) {
            (Test-DevToolsAgentMemoryHealthResponse `
                -Response $response `
                -ExpectedViewerPort 6002) | Should Be $false
        }
        foreach ($response in @(
                [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6003; viewerSkipped=$false
                },
                [pscustomobject]@{
                    service='agentmemory'; status='healthy'; version='0.9.27'
                    viewerPort=6002; viewerSkipped=$true
                }
            )) {
            (Test-DevToolsAgentMemoryHealthResponse `
                -Response $response `
                -ExpectedViewerPort 6002) | Should Be $false
        }
    }

    It "requires native array and object schemas for slots and MCP tools" {
        (Test-DevToolsAgentMemorySlotsResponse -Response ([pscustomobject]@{
                    success=$true
                    slots=@([pscustomobject]@{
                            label='guidance'; scope='project'; pinned=$true
                            sizeLimit=1500; content='text'
                        })
                })) | Should Be $true
        foreach ($response in @(
                [pscustomobject]@{ success=$true; slots='anything' },
                [pscustomobject]@{ success='true'; slots=@() },
                [pscustomobject]@{
                    success=$true
                    slots=@([pscustomobject]@{
                            label=123; scope='project'; pinned=$true
                            sizeLimit=1500; content='text'
                        })
                }
            )) {
            (Test-DevToolsAgentMemorySlotsResponse -Response $response) | Should Be $false
        }

        $validTools = [pscustomobject]@{
            tools=@(1..2 | ForEach-Object {
                    [pscustomobject]@{
                        name="tool$_"; inputSchema=[pscustomobject]@{ type='object' }
                    }
                })
        }
        (Test-DevToolsAgentMemoryToolsResponse -Response $validTools -MinimumTools 2) |
            Should Be $true
        foreach ($response in @(
                [pscustomobject]@{
                    tools=[pscustomobject]@{
                        name='tool'; inputSchema=[pscustomobject]@{ type='object' }
                    }
                },
                [pscustomobject]@{
                    tools=@([pscustomobject]@{ name='tool'; inputSchema=$null })
                },
                [pscustomobject]@{
                    tools=@([pscustomobject]@{
                            name='tool'; inputSchema=[pscustomobject]@{ type='array' }
                        })
                }
            )) {
            (Test-DevToolsAgentMemoryToolsResponse -Response $response -MinimumTools 1) |
                Should Be $false
        }
    }

    It "delegates full runtime proof to the hardened server inspector" {
        $root = Join-Path $TestDrive 'HealthInspection'
        $fixture = New-AgentMemoryRuntimeFixture -Root $root
        $script:healthInspectionArguments = @()
        Mock powershell.exe {
            $script:healthInspectionArguments = @($args)
            $global:LASTEXITCODE = 0
        }

        (Invoke-DevToolsAgentMemoryInspection `
            -PowerShellExecutable 'powershell.exe' `
            -ServerScript (Get-RuntimeScriptPath 'agentmemory-server.ps1') `
            -DevToolsRoot $root `
            -DataRoot $fixture.DataRoot `
            -BaseUrl 'http://127.0.0.1:4111' `
            -Config $fixture.Config `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -IiiExecutable $fixture.IiiExecutable `
            -EmbeddingProvider 'local' `
            -LogDir $fixture.LogDir) | Should Be 0
        $joined = $script:healthInspectionArguments -join '|'
        $joined | Should Match ([regex]::Escape('-NodeExecutable|' + $fixture.NodeExecutable))
        $joined | Should Match ([regex]::Escape('-IiiExecutable|' + $fixture.IiiExecutable))
        $joined | Should Match ([regex]::Escape('-LogDir|' + $fixture.LogDir + '|-InspectOnly'))
    }

    It "rejects nonlocal health-check endpoints" {
        foreach ($url in @(
                'https://127.0.0.1:4111', 'http://192.0.2.10:4111',
                'http://user:pass@127.0.0.1:4111', 'http://127.0.0.1:4111/path',
                'http://127.0.0.1:4111/?query=1', 'http://127.0.0.1:4111/#fragment'
            )) {
            (Test-RuntimeThrows { Get-DevToolsHealthSettings `
                -DevToolsRoot $TestDrive -AgentResourcesRoot $TestDrive `
                -AgentMemoryBaseUrl $url }) | Should Be $true
        }
    }

    It "does not send health-check bearer requests before full runtime inspection succeeds" {
        Mock Get-DevToolsAgentMemoryRequiredSecret { return ('A1b2C3d4_' * 4) }
        Mock Invoke-DevToolsAgentMemoryInspection { return 1 }
        Mock Invoke-RestMethod { throw 'Bearer request must not run' }
        Mock Test-NetConnection { return [pscustomobject]@{ TcpTestSucceeded=$false } }

        $result = Invoke-DevToolsHealthCheck `
            -DevToolsRoot $repoRoot `
            -AgentResourcesRoot $TestDrive `
            -AgentMemoryBaseUrl 'http://127.0.0.1:4111' `
            -PowerShellExecutable 'powershell.exe'

        $result.ExitCode | Should Be 1
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }
}

Describe "process diagnostics" {
    It "recognizes current local agent families" {
        (Get-AgentFamily "node.exe" "node claudeseek server") | Should Be "claudeseek"
        (Get-AgentFamily "node.exe" "node opencode server") | Should Be "OpenCode"
        (Get-AgentFamily "gemini.exe" "gemini") | Should Be "Gemini"
        (Get-AgentFamily "python.exe" "python hermes gateway") | Should Be "hermes"
    }

    It "redacts option, assignment, and bearer credential forms" {
        $safe = Redact-CommandLine 'tool.exe --api-key example-value --token=another-value Authorization: Bearer sample-value'

        $safe | Should Not Match 'example-value|another-value|sample-value'
        $safe | Should Match 'REDACTED'
    }

    It "normalizes a configured diagnostic drive" {
        (Resolve-DiagnosticDrive "E:\") | Should Be "E:"
    }
}
