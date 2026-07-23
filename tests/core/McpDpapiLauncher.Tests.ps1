$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

. (Join-Path $repoRoot 'agentmemory-mcp-dpapi.ps1')

function Test-McpLauncherActionThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $false
    } catch {
        return $true
    }
}

function Get-McpLauncherErrorMessage {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $null
    } catch {
        return [string]$_.Exception.Message
    }
}

function Write-McpLauncherPackageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name = '@agentmemory/mcp',
        [string]$Version = '0.9.27',
        [string]$Type = 'module',
        [string]$EntryPoint = './bin.mjs'
    )
    $manifest = [ordered]@{
        name = $Name
        version = $Version
        type = $Type
        bin = [ordered]@{ 'agentmemory-mcp' = $EntryPoint }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    [System.IO.File]::WriteAllText(
        $Path,
        ($manifest | ConvertTo-Json -Depth 4),
        $encoding
    )
}

function Write-McpLauncherSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Settings
    )
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $bytes = $null
    try {
        $bytes = $encoding.GetBytes(($Settings | ConvertTo-Json -Depth 4))
        Write-AgentMemoryWatchdogAtomicBytes -Path $Path -Bytes $bytes
    } finally {
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function New-McpLauncherFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    $paths = [ordered]@{
        Root = $Root
        DataRoot = Join-Path $Root 'data'
        LogDir = Join-Path $Root 'logs'
        Config = Join-Path $Root 'agentmemory-iii.yaml'
        InstallRoot = Join-Path $Root 'npm-global\agentmemory-runtime'
        NodeExecutable = Join-Path $Root 'node\node.exe'
        IiiExecutable = Join-Path $Root 'npm-global\agentmemory-runtime\iii.exe'
        SelfHealScript = Join-Path $Root 'agentmemory-selfheal.ps1'
        ServerScript = Join-Path $Root 'agentmemory-server.ps1'
        PackageRoot = Join-Path $Root 'npm-global\agentmemory-runtime\node_modules\@agentmemory\mcp'
        PowerShellExecutable = (Get-Command powershell.exe -CommandType Application).Source
    }
    $paths.Manifest = Join-Path $paths.PackageRoot 'package.json'
    $paths.EntryPoint = Join-Path $paths.PackageRoot 'bin.mjs'
    foreach ($path in @(
            $paths.Config, $paths.NodeExecutable, $paths.IiiExecutable,
            $paths.SelfHealScript, $paths.ServerScript, $paths.EntryPoint
        )) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, 'fixture')
    }
    Write-McpLauncherPackageManifest -Path $paths.Manifest
    New-Item -ItemType Directory -Path $paths.LogDir -Force | Out-Null

    $runRoot = Join-Path $paths.DataRoot 'run'
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $blobBytes = Protect-AgentMemoryWatchdogSecret -Secret $Secret
    try {
        $blobHash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blobBytes
        $blobPath = Join-Path $runRoot ("agentmemory-watchdog.secret.$blobHash.dpapi")
        Write-AgentMemoryWatchdogAtomicBytes -Path $blobPath -Bytes $blobBytes
    } finally {
        if ($null -ne $blobBytes) {
            [Array]::Clear($blobBytes, 0, $blobBytes.Length)
        }
    }

    $settingsPath = Join-Path $paths.LogDir 'agentmemory-watchdog.settings.json'
    $settings = [pscustomobject][ordered]@{
        SchemaVersion = 1
        DevToolsRoot = $paths.Root
        DataRoot = $paths.DataRoot
        BaseUrl = 'http://127.0.0.1:4111'
        Config = $paths.Config
        InstallRoot = $paths.InstallRoot
        NodeExecutable = $paths.NodeExecutable
        IiiExecutable = $paths.IiiExecutable
        EmbeddingProvider = 'local'
        LogDir = $paths.LogDir
        SelfHealScript = $paths.SelfHealScript
        ServerScript = $paths.ServerScript
        PowerShellExecutable = $paths.PowerShellExecutable
        SecretBlobPath = $blobPath
        SecretCiphertextSha256 = $blobHash
    }
    Write-McpLauncherSettings -Path $settingsPath -Settings $settings

    return [pscustomobject]@{
        Paths = [pscustomobject]$paths
        Settings = $settings
        SettingsPath = $settingsPath
        BlobPath = $blobPath
    }
}

function Get-McpLauncherTestShell {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return (Join-Path $PSHOME 'pwsh.exe')
    }
    return (Join-Path $PSHOME 'powershell.exe')
}

function Invoke-McpLauncherExternalBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Shell,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$InputBytes,
        [switch]$KeepStandardInputOpen,
        [int]$ExpectedOutputBytesBeforeEof = 0,
        [int]$TimeoutMilliseconds = 15000
    )

    foreach ($value in @($LauncherPath, $SettingsPath)) {
        if ($value -match '[\x00-\x1f\x7f\u0085\u2028\u2029"]') {
            throw 'Unsafe external launcher test argument.'
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Shell
    $startInfo.Arguments =
        '-NoProfile -ExecutionPolicy Bypass -File "' + $LauncherPath +
        '" -SettingsPath "' + $SettingsPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $stdout = New-Object System.IO.MemoryStream
    $stderr = New-Object System.IO.MemoryStream
    $stdoutTask = $null
    $stderrTask = $null
    $stdinWriter = $null
    $stdinStream = $null
    $previousConsoleInputEncoding = $null
    $runningAfterResponse = $false
    try {
        $process.StartInfo = $startInfo
        try {
            $previousConsoleInputEncoding = [Console]::InputEncoding
            [Console]::InputEncoding =
                New-Object System.Text.UTF8Encoding($false, $true)
            if (-not $process.Start()) {
                throw 'External launcher test process did not start.'
            }
            $stdinWriter = $process.StandardInput
        } finally {
            if ($null -ne $previousConsoleInputEncoding) {
                [Console]::InputEncoding = $previousConsoleInputEncoding
            }
        }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $stdinStream = $stdinWriter.BaseStream

        if ($InputBytes.Length -gt 0) {
            $stdinStream.Write($InputBytes, 0, $InputBytes.Length)
            $stdinStream.Flush()
        }
        if ($ExpectedOutputBytesBeforeEof -gt 0) {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($stdout.Length -lt $ExpectedOutputBytesBeforeEof -and
                -not $process.HasExited -and
                $stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                [System.Threading.Thread]::Sleep(10)
            }
            $stopwatch.Stop()
            if ($stdout.Length -lt $ExpectedOutputBytesBeforeEof) {
                try { $process.Kill() } catch {}
                throw 'External launcher did not flush an interactive response before stdin EOF.'
            }
            $runningAfterResponse = -not $process.HasExited
            $stdinStream.Close()
        } elseif (-not $KeepStandardInputOpen) {
            $stdinStream.Close()
        }

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill()
            } catch {
                # The timeout remains the primary test failure.
            }
            throw 'External launcher test process timed out waiting for stdin EOF.'
        }
        [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        )

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StandardOutput = $stdout.ToArray()
            StandardError = $stderr.ToArray()
            RunningAfterResponse = $runningAfterResponse
        }
    } finally {
        try {
            if ($null -ne $stdinStream) {
                $stdinStream.Close()
            }
        } catch {
            # The process may have failed before creating redirected streams.
        }
        try {
            if ($null -ne $stdinWriter) {
                $stdinWriter.Close()
            }
        } catch {
            # The raw pipe was already closed deliberately.
        }
        $stdout.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
}

Describe 'AgentMemory MCP DPAPI launcher' {
    BeforeEach {
        $script:originalAgentMemorySecret =
            [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
        $script:originalAgentMemoryUrl =
            [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process')
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable(
            'AGENTMEMORY_SECRET', $script:originalAgentMemorySecret, 'Process'
        )
        [Environment]::SetEnvironmentVariable(
            'AGENTMEMORY_URL', $script:originalAgentMemoryUrl, 'Process'
        )
    }

    It 'pins the dedicated package identity and configures redirected standard streams' {
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'contract') `
            -Secret ('A1b2C3d4_' * 4)
        $loaded = Read-AgentMemoryWatchdogSettings -SettingsPath $fixture.SettingsPath
        $contract = Get-AgentMemoryMcpRuntimeContract -Settings $loaded.Value

        $contract.Version | Should Be '0.9.27'
        $script:AgentMemoryMcpStreamPumpType.FullName |
            Should Be 'Devtools.AgentMemoryMcpStreamPump'
        $contract.InstallRoot | Should Be $fixture.Paths.InstallRoot
        $contract.NodeExecutable | Should Be $fixture.Paths.NodeExecutable
        $contract.EntryPoint | Should Be $fixture.Paths.EntryPoint

        $startInfo = New-AgentMemoryMcpProcessStartInfo `
            -NodeExecutable $contract.NodeExecutable `
            -EntryPoint $contract.EntryPoint `
            -WorkingDirectory $contract.InstallRoot
        $startInfo.UseShellExecute | Should Be $false
        $startInfo.CreateNoWindow | Should Be $true
        $startInfo.RedirectStandardInput | Should Be $true
        $startInfo.RedirectStandardOutput | Should Be $true
        $startInfo.RedirectStandardError | Should Be $true
        $startInfo.FileName | Should Be $fixture.Paths.NodeExecutable
        $startInfo.WorkingDirectory | Should Be $fixture.Paths.InstallRoot
        $startInfo.Arguments | Should Be ('"' + $fixture.Paths.EntryPoint + '"')
    }

    It 'flushes one interactive request and response before parent stdin EOF' {
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'external-interactive') `
            -Secret ('A1b2C3d4_' * 4)
        $nodeExecutable = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
        $fixture.Settings.NodeExecutable = $nodeExecutable
        Write-McpLauncherSettings `
            -Path $fixture.SettingsPath `
            -Settings $fixture.Settings

        $childSource = @'
import process from 'node:process';

let pending = Buffer.alloc(0);
let replied = false;
process.stdin.on('data', (chunk) => {
  pending = Buffer.concat([pending, chunk]);
  if (!replied && pending.indexOf(0x0a) >= 0) {
    process.stdout.write(Buffer.from('{"jsonrpc":"2.0","id":7,"result":{"ready":true}}\n', 'utf8'));
    replied = true;
  }
});
process.stdin.on('end', () => {
  if (!replied) {
    process.stderr.write(Buffer.from('interactive-request-missing\n', 'utf8'));
    process.exitCode = 91;
    return;
  }
  process.stderr.write(Buffer.from('interactive-stderr\n', 'utf8'));
  process.exitCode = 43;
});
'@
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [System.IO.File]::WriteAllText(
            $fixture.Paths.EntryPoint,
            $childSource,
            $utf8
        )
        $requestBytes = $utf8.GetBytes(
            "{`"jsonrpc`":`"2.0`",`"id`":7,`"method`":`"initialize`"}`n"
        )
        $responseBytes = $utf8.GetBytes(
            "{`"jsonrpc`":`"2.0`",`"id`":7,`"result`":{`"ready`":true}}`n"
        )

        $result = Invoke-McpLauncherExternalBytes `
            -Shell (Get-McpLauncherTestShell) `
            -LauncherPath (Join-Path $repoRoot 'agentmemory-mcp-dpapi.ps1') `
            -SettingsPath $fixture.SettingsPath `
            -InputBytes $requestBytes `
            -ExpectedOutputBytesBeforeEof $responseBytes.Length `
            -TimeoutMilliseconds 10000

        $result.RunningAfterResponse | Should Be $true
        $result.ExitCode | Should Be 43
        [Convert]::ToBase64String($result.StandardOutput) |
            Should Be ([Convert]::ToBase64String($responseBytes))
        [Convert]::ToBase64String($result.StandardError) |
            Should Be ([Convert]::ToBase64String($utf8.GetBytes("interactive-stderr`n")))
    }

    It 'pumps raw JSONL bytes, stdin EOF, stderr, and exit code through a real child process' {
        $secret = ('A1b2C3d4_' * 4)
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'external-stdio') `
            -Secret $secret
        $nodeExecutable = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
        $fixture.Settings.NodeExecutable = $nodeExecutable
        Write-McpLauncherSettings `
            -Path $fixture.SettingsPath `
            -Settings $fixture.Settings

        $childSource = @'
import process from 'node:process';
import { once } from 'node:events';

for await (const chunk of process.stdin) {
  if (!process.stdout.write(chunk)) {
    await once(process.stdout, 'drain');
  }
}
process.stderr.write(Buffer.from('fixture-stderr:\r\n', 'utf8'));
process.exitCode = 37;
'@
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [System.IO.File]::WriteAllText(
            $fixture.Paths.EntryPoint,
            $childSource,
            $utf8
        )

        $unicodePayload =
            ([string][char]0x9010) + [char]0x5b57 + [char]0x8282 +
            [char]::ConvertFromUtf32(0x1f680)
        $inputText =
            '{"jsonrpc":"2.0","id":1,"method":"echo","params":{"text":"' +
            $unicodePayload + '"}}' +
            "`r`n" +
            '{"jsonrpc":"2.0","id":2,"method":"echo","params":{"text":"line two"}}' +
            "`n"
        $lineBytes = $utf8.GetBytes($inputText)
        $repeatCount = 8192
        $inputBytes = New-Object byte[] ($lineBytes.Length * $repeatCount)
        for ($index = 0; $index -lt $repeatCount; $index += 1) {
            [Array]::Copy(
                $lineBytes,
                0,
                $inputBytes,
                $index * $lineBytes.Length,
                $lineBytes.Length
            )
        }
        $expectedError = $utf8.GetBytes("fixture-stderr:`r`n")

        $result = Invoke-McpLauncherExternalBytes `
            -Shell (Get-McpLauncherTestShell) `
            -LauncherPath (Join-Path $repoRoot 'agentmemory-mcp-dpapi.ps1') `
            -SettingsPath $fixture.SettingsPath `
            -InputBytes $inputBytes

        $inputBytes.Length | Should BeGreaterThan 1048576
        $result.ExitCode | Should Be 37
        $result.StandardOutput[0] | Should Be $inputBytes[0]
        $result.StandardOutput[1] | Should Be $inputBytes[1]
        $result.StandardOutput[2] | Should Be $inputBytes[2]
        $result.StandardOutput[$result.StandardOutput.Length - 3] |
            Should Be $inputBytes[$inputBytes.Length - 3]
        $result.StandardOutput[$result.StandardOutput.Length - 2] |
            Should Be $inputBytes[$inputBytes.Length - 2]
        $result.StandardOutput[$result.StandardOutput.Length - 1] |
            Should Be $inputBytes[$inputBytes.Length - 1]
        $result.StandardOutput.Length | Should Be $inputBytes.Length
        [System.Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $result.StandardOutput,
            $inputBytes
        ) | Should Be $true
        [Convert]::ToBase64String($result.StandardError) |
            Should Be ([Convert]::ToBase64String($expectedError))
    }

    It 'returns an early child exit while the parent stdin pipe remains open' {
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'external-early-exit') `
            -Secret ('A1b2C3d4_' * 4)
        $nodeExecutable = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
        $fixture.Settings.NodeExecutable = $nodeExecutable
        Write-McpLauncherSettings `
            -Path $fixture.SettingsPath `
            -Settings $fixture.Settings

        $childSource = @'
import process from 'node:process';

process.stdout.write(Buffer.from('early-stdout\n', 'utf8'));
process.stderr.write(Buffer.from('early-stderr\n', 'utf8'));
process.exitCode = 29;
'@
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [System.IO.File]::WriteAllText(
            $fixture.Paths.EntryPoint,
            $childSource,
            $utf8
        )

        $result = Invoke-McpLauncherExternalBytes `
            -Shell (Get-McpLauncherTestShell) `
            -LauncherPath (Join-Path $repoRoot 'agentmemory-mcp-dpapi.ps1') `
            -SettingsPath $fixture.SettingsPath `
            -InputBytes ([byte[]]@()) `
            -KeepStandardInputOpen `
            -TimeoutMilliseconds 10000

        $result.ExitCode | Should Be 29
        [Convert]::ToBase64String($result.StandardOutput) |
            Should Be ([Convert]::ToBase64String($utf8.GetBytes("early-stdout`n")))
        [Convert]::ToBase64String($result.StandardError) |
            Should Be ([Convert]::ToBase64String($utf8.GetBytes("early-stderr`n")))
    }

    It 'injects the decrypted secret and exact URL only for the child and preserves its exit code' {
        $secret = ('A1b2C3d4_' * 4)
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'environment-success') `
            -Secret $secret
        $previousSecret = 'previous-secret-value'
        $previousUrl = 'http://127.0.0.1:4999'
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previousSecret, 'Process')
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_URL', $previousUrl, 'Process')
        $script:observedMcpSecret = $null
        $script:observedMcpUrl = $null
        $script:observedMcpInvocation = $null
        Mock Invoke-AgentMemoryMcpProcess {
            param($NodeExecutable, $EntryPoint, $WorkingDirectory, $ExitCode)
            $script:observedMcpSecret =
                [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
            $script:observedMcpUrl =
                [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process')
            $script:observedMcpInvocation = @($NodeExecutable, $EntryPoint, $WorkingDirectory)
            $ExitCode.Value = 23
        }

        $exitCode = 127
        Invoke-AgentMemoryMcpDpapiLauncher `
            -SettingsPath $fixture.SettingsPath `
            -ExitCode ([ref]$exitCode)

        $exitCode | Should Be 23
        $script:observedMcpSecret | Should Be $secret
        $script:observedMcpUrl | Should Be 'http://127.0.0.1:4111'
        $script:observedMcpInvocation[0] | Should Be $fixture.Paths.NodeExecutable
        $script:observedMcpInvocation[1] | Should Be $fixture.Paths.EntryPoint
        $script:observedMcpInvocation[2] | Should Be $fixture.Paths.InstallRoot
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') |
            Should Be $previousSecret
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process') |
            Should Be $previousUrl
    }

    It 'removes previously absent environment values after a successful child' {
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'environment-absent') `
            -Secret ('A1b2C3d4_' * 4)
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $null, 'Process')
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_URL', $null, 'Process')
        Mock Invoke-AgentMemoryMcpProcess {
            param($NodeExecutable, $EntryPoint, $WorkingDirectory, $ExitCode)
            $ExitCode.Value = 0
        }

        $exitCode = 127
        Invoke-AgentMemoryMcpDpapiLauncher `
            -SettingsPath $fixture.SettingsPath `
            -ExitCode ([ref]$exitCode)

        $exitCode | Should Be 0
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') |
            Should BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process') |
            Should BeNullOrEmpty
    }

    It 'restores both variables and replaces a child failure with a path-free fixed error' {
        $secret = ('A1b2C3d4_' * 4)
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'environment-failure') `
            -Secret $secret
        $previousSecret = 'previous-secret-value'
        $previousUrl = 'http://127.0.0.1:4999'
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previousSecret, 'Process')
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_URL', $previousUrl, 'Process')
        Mock Invoke-AgentMemoryMcpProcess {
            throw ("simulated $secret " + $fixture.Paths.Root)
        }

        $exitCode = 127
        $message = Get-McpLauncherErrorMessage {
            Invoke-AgentMemoryMcpDpapiLauncher `
                -SettingsPath $fixture.SettingsPath `
                -ExitCode ([ref]$exitCode)
        }
        $message | Should Be 'Agentmemory MCP child invocation failed.'
        $message | Should Not Match ([regex]::Escape($secret))
        $message | Should Not Match ([regex]::Escape($fixture.Paths.Root))
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') |
            Should Be $previousSecret
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process') |
            Should Be $previousUrl
    }

    It 'rejects package identity or entry-point drift before decrypting or launching' {
        $cases = @(
            @{ Name = '@agentmemory/other'; Version = '0.9.27'; Type = 'module'; Entry = './bin.mjs' },
            @{ Name = '@agentmemory/mcp'; Version = '0.9.26'; Type = 'module'; Entry = './bin.mjs' },
            @{ Name = '@agentmemory/mcp'; Version = '0.9.27'; Type = 'commonjs'; Entry = './bin.mjs' },
            @{ Name = '@agentmemory/mcp'; Version = '0.9.27'; Type = 'module'; Entry = './other.mjs' }
        )
        $index = 0
        foreach ($case in $cases) {
            $fixture = New-McpLauncherFixture `
                -Root (Join-Path $TestDrive ("package-drift-$index")) `
                -Secret ('A1b2C3d4_' * 4)
            Write-McpLauncherPackageManifest `
                -Path $fixture.Paths.Manifest `
                -Name $case.Name `
                -Version $case.Version `
                -Type $case.Type `
                -EntryPoint $case.Entry
            Mock Invoke-AgentMemoryMcpProcess { throw 'must not launch' }

            $exitCode = 127
            (Test-McpLauncherActionThrows {
                    Invoke-AgentMemoryMcpDpapiLauncher `
                        -SettingsPath $fixture.SettingsPath `
                        -ExitCode ([ref]$exitCode)
                }) | Should Be $true
            $index += 1
        }
        Assert-MockCalled Invoke-AgentMemoryMcpProcess -Times 0 -Scope It
    }

    It 'inherits the watchdog closed schema and ciphertext-integrity checks without leaking values' {
        $secret = ('A1b2C3d4_' * 4)
        $fixture = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'settings-drift') `
            -Secret $secret
        $fixture.Settings | Add-Member -NotePropertyName Unexpected -NotePropertyValue 'reject'
        Write-McpLauncherSettings `
            -Path $fixture.SettingsPath `
            -Settings $fixture.Settings
        Mock Invoke-AgentMemoryMcpProcess { throw 'must not launch' }

        $exitCode = 127
        $schemaMessage = Get-McpLauncherErrorMessage {
            Invoke-AgentMemoryMcpDpapiLauncher `
                -SettingsPath $fixture.SettingsPath `
                -ExitCode ([ref]$exitCode)
        }
        $schemaMessage | Should Not BeNullOrEmpty
        $schemaMessage | Should Not Match ([regex]::Escape($secret))
        $schemaMessage | Should Not Match ([regex]::Escape($fixture.Paths.Root))

        $tampered = New-McpLauncherFixture `
            -Root (Join-Path $TestDrive 'ciphertext-drift') `
            -Secret $secret
        $bytes = [System.IO.File]::ReadAllBytes($tampered.BlobPath)
        $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
        [System.IO.File]::WriteAllBytes($tampered.BlobPath, $bytes)
        [Array]::Clear($bytes, 0, $bytes.Length)
        $cipherMessage = Get-McpLauncherErrorMessage {
            Invoke-AgentMemoryMcpDpapiLauncher `
                -SettingsPath $tampered.SettingsPath `
                -ExitCode ([ref]$exitCode)
        }
        $cipherMessage | Should Not BeNullOrEmpty
        $cipherMessage | Should Not Match ([regex]::Escape($secret))
        $cipherMessage | Should Not Match ([regex]::Escape($tampered.Paths.Root))
        Assert-MockCalled Invoke-AgentMemoryMcpProcess -Times 0 -Scope It
    }

    It 'emits one fixed direct-invocation error and exit code without a machine path' {
        $shell = Get-McpLauncherTestShell
        $missingSettings = Join-Path $TestDrive 'private\missing-settings.json'
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& $shell -NoProfile -ExecutionPolicy Bypass -File `
                (Join-Path $repoRoot 'agentmemory-mcp-dpapi.ps1') `
                -SettingsPath $missingSettings 2>&1)
            $childExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"

        $childExitCode | Should Be 127
        $text.Trim() | Should Be 'Agentmemory MCP launcher failed.'
        $text | Should Not Match ([regex]::Escape($missingSettings))
    }
}
