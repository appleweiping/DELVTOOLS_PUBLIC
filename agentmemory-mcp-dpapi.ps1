param(
    [string]$SettingsPath
)

$script:AgentMemoryMcpInvokedDirectly = ($MyInvocation.InvocationName -ne '.')
$script:AgentMemoryMcpRequestedSettingsPath = $SettingsPath
$script:AgentMemoryMcpSupportAvailable = $false
$script:AgentMemoryMcpVersion = '0.9.27'
$script:AgentMemoryMcpStreamPumpType = $null
$ErrorActionPreference = 'Stop'

# Stream.CopyToAsync does not promise to flush a redirected Process pipe after
# each small MCP frame. Keep the async loop in managed code so all three pumps
# can run concurrently without PowerShell runspace callbacks, and flush every
# chunk before reading the next one.
try {
    $script:AgentMemoryMcpStreamPumpType =
        'Devtools.AgentMemoryMcpStreamPump' -as [type]
    if ($null -eq $script:AgentMemoryMcpStreamPumpType) {
        $pumpTypes = @(Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;

namespace Devtools
{
    public static class AgentMemoryMcpStreamPump
    {
        public static async Task CopyAndFlushAsync(Stream source, Stream destination)
        {
            if (source == null)
            {
                throw new ArgumentNullException("source");
            }
            if (destination == null)
            {
                throw new ArgumentNullException("destination");
            }

            byte[] buffer = new byte[4096];
            try
            {
                while (true)
                {
                    int bytesRead = await source.ReadAsync(
                        buffer, 0, buffer.Length
                    ).ConfigureAwait(false);
                    if (bytesRead == 0)
                    {
                        break;
                    }
                    await destination.WriteAsync(
                        buffer, 0, bytesRead
                    ).ConfigureAwait(false);
                    await destination.FlushAsync().ConfigureAwait(false);
                }
            }
            finally
            {
                Array.Clear(buffer, 0, buffer.Length);
            }
        }
    }
}
'@ -Language CSharp -PassThru -ErrorAction Stop)
        $script:AgentMemoryMcpStreamPumpType = @(
            $pumpTypes | Where-Object {
                $_.FullName -ceq 'Devtools.AgentMemoryMcpStreamPump'
            }
        ) | Select-Object -First 1
    }
} catch {
    $script:AgentMemoryMcpStreamPumpType = $null
}

# Reuse the watchdog's closed settings schema and DPAPI secret-store implementation
# instead of maintaining a second parser or ciphertext format. Loading failures are
# retained as a boolean so direct invocation can emit one path-free error.
try {
    $watchdogRunnerScript = Join-Path $PSScriptRoot 'agentmemory-watchdog-run.ps1'
    if (Test-Path -LiteralPath $watchdogRunnerScript -PathType Leaf) {
        . $watchdogRunnerScript
        $script:AgentMemoryMcpSupportAvailable =
            ($null -ne (Get-Command Read-AgentMemoryWatchdogSettings -ErrorAction SilentlyContinue)) -and
            ($null -ne (Get-Command Read-AgentMemoryWatchdogSecret -ErrorAction SilentlyContinue)) -and
            ($null -ne (Get-Command Assert-AgentMemoryWatchdogSecret -ErrorAction SilentlyContinue)) -and
            ($null -ne $script:AgentMemoryMcpStreamPumpType)
    }
} catch {
    $script:AgentMemoryMcpSupportAvailable = $false
}

function Test-AgentMemoryMcpPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    try {
        $candidate = [System.IO.Path]::GetFullPath($Path)
        $boundary = [System.IO.Path]::GetFullPath($Root).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar
        return $candidate.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Assert-AgentMemoryMcpOrdinaryItem {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Leaf', 'Container')][string]$Kind
    )
    $pathType = if ($Kind -eq 'Leaf') { 'Leaf' } else { 'Container' }
    if (-not (Test-Path -LiteralPath $Path -PathType $pathType)) {
        throw 'Agentmemory MCP runtime validation failed.'
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'reparse point'
        }
    } catch {
        throw 'Agentmemory MCP runtime validation failed.'
    }
}

function Get-AgentMemoryMcpRuntimeContract {
    param([Parameter(Mandatory = $true)]$Settings)

    try {
        $installRoot = [System.IO.Path]::GetFullPath([string]$Settings.InstallRoot)
        $nodeExecutable = [System.IO.Path]::GetFullPath([string]$Settings.NodeExecutable)
        $nodeModulesRoot = Join-Path $installRoot 'node_modules'
        $scopeRoot = Join-Path $nodeModulesRoot '@agentmemory'
        $packageRoot = Join-Path $scopeRoot 'mcp'
        $manifestPath = Join-Path $packageRoot 'package.json'
        $entryPoint = Join-Path $packageRoot 'bin.mjs'

        if (-not (Test-AgentMemoryMcpPathWithin -Path $packageRoot -Root $installRoot) -or
            -not (Test-AgentMemoryMcpPathWithin -Path $manifestPath -Root $installRoot) -or
            -not (Test-AgentMemoryMcpPathWithin -Path $entryPoint -Root $installRoot) -or
            [System.IO.Path]::GetFileName($nodeExecutable) -ine 'node.exe') {
            throw 'contract mismatch'
        }

        Assert-AgentMemoryMcpOrdinaryItem -Path $installRoot -Kind Container
        Assert-AgentMemoryMcpOrdinaryItem -Path $nodeModulesRoot -Kind Container
        Assert-AgentMemoryMcpOrdinaryItem -Path $scopeRoot -Kind Container
        Assert-AgentMemoryMcpOrdinaryItem -Path $packageRoot -Kind Container
        Assert-AgentMemoryMcpOrdinaryItem -Path $manifestPath -Kind Leaf
        Assert-AgentMemoryMcpOrdinaryItem -Path $entryPoint -Kind Leaf
        Assert-AgentMemoryMcpOrdinaryItem -Path $nodeExecutable -Kind Leaf

        $manifestLength = (Get-Item -LiteralPath $manifestPath -Force).Length
        if ($manifestLength -le 0 -or $manifestLength -gt 65536) {
            throw 'manifest size'
        }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $manifestBytes = $null
        try {
            $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
            $manifestText = $strictUtf8.GetString($manifestBytes)
            $manifest = $manifestText | ConvertFrom-Json
        } finally {
            if ($null -ne $manifestBytes -and $manifestBytes.Length -gt 0) {
                [Array]::Clear($manifestBytes, 0, $manifestBytes.Length)
            }
            $manifestText = $null
        }
        if ($null -eq $manifest -or $manifest -is [array] -or
            [string]$manifest.name -cne '@agentmemory/mcp' -or
            [string]$manifest.version -cne $script:AgentMemoryMcpVersion -or
            [string]$manifest.type -cne 'module') {
            throw 'manifest identity'
        }
        $binProperty = $manifest.PSObject.Properties['bin']
        if ($null -eq $binProperty -or $null -eq $binProperty.Value -or
            $binProperty.Value -is [array]) {
            throw 'manifest bin'
        }
        $entryProperty = $binProperty.Value.PSObject.Properties['agentmemory-mcp']
        if ($null -eq $entryProperty -or [string]$entryProperty.Value -cne './bin.mjs') {
            throw 'manifest entry point'
        }

        return [pscustomobject]@{
            InstallRoot = $installRoot
            NodeExecutable = $nodeExecutable
            PackageRoot = $packageRoot
            EntryPoint = $entryPoint
            Version = $script:AgentMemoryMcpVersion
        }
    } catch {
        throw 'Agentmemory MCP runtime validation failed.'
    }
}

function New-AgentMemoryMcpProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    try {
        foreach ($value in @($NodeExecutable, $EntryPoint, $WorkingDirectory)) {
            if ($value -match '[\x00-\x1f\x7f\u0085\u2028\u2029"]') {
                throw 'unsafe process argument'
            }
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $NodeExecutable
        $startInfo.Arguments = '"' + $EntryPoint + '"'
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        return $startInfo
    } catch {
        throw 'Agentmemory MCP process configuration failed.'
    }
}

function Invoke-AgentMemoryMcpProcess {
    param(
        [Parameter(Mandatory = $true)][string]$NodeExecutable,
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][ref]$ExitCode
    )

    $process = $null
    $inputCopyTask = $null
    $outputCopyTask = $null
    $errorCopyTask = $null
    $parentInputStream = $null
    $parentOutputStream = $null
    $parentErrorStream = $null
    $childInputWriter = $null
    $childInputStream = $null
    $childOutputStream = $null
    $childErrorStream = $null
    $childExited = $false
    $previousConsoleInputEncoding = $null
    try {
        $startInfo = New-AgentMemoryMcpProcessStartInfo `
            -NodeExecutable $NodeExecutable `
            -EntryPoint $EntryPoint `
            -WorkingDirectory $WorkingDirectory
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            # WinPS 5.1 creates Process.StandardInput with Console.InputEncoding
            # and otherwise selects a UTF-8 writer whose preamble is injected
            # ahead of the first raw BaseStream byte. Pin a BOM-free encoding
            # only while Process.Start and the writer getter construct it.
            $previousConsoleInputEncoding = [Console]::InputEncoding
            [Console]::InputEncoding =
                New-Object System.Text.UTF8Encoding($false, $true)
            if (-not $process.Start()) {
                throw 'start failed'
            }
            $childInputWriter = $process.StandardInput
        } finally {
            if ($null -ne $previousConsoleInputEncoding) {
                [Console]::InputEncoding = $previousConsoleInputEncoding
            }
        }

        # MCP stdio is a byte stream. Pump the redirected BaseStream handles so
        # PowerShell never applies text decoding, newline conversion, or object
        # formatting to protocol frames. Standard output and error must begin
        # draining before input is copied to avoid filling either child pipe.
        $parentOutputStream = [Console]::OpenStandardOutput()
        $parentErrorStream = [Console]::OpenStandardError()
        $childOutputStream = $process.StandardOutput.BaseStream
        $childErrorStream = $process.StandardError.BaseStream
        $outputCopyTask = [Devtools.AgentMemoryMcpStreamPump]::CopyAndFlushAsync(
            $childOutputStream,
            $parentOutputStream
        )
        $errorCopyTask = [Devtools.AgentMemoryMcpStreamPump]::CopyAndFlushAsync(
            $childErrorStream,
            $parentErrorStream
        )

        $childInputStream = $childInputWriter.BaseStream
        $parentInputStream = [Console]::OpenStandardInput()
        $inputCopyTask = [Devtools.AgentMemoryMcpStreamPump]::CopyAndFlushAsync(
            $parentInputStream,
            $childInputStream
        )

        # Race client EOF against child exit. Normal MCP shutdown observes EOF,
        # closes the child's input pipe, and then waits for the server. A child
        # that fails early must not leave the wrapper blocked forever reading an
        # MCP client pipe that is intentionally still open.
        while ($true) {
            if ($process.WaitForExit(25)) {
                $childExited = $true
                break
            }
            if ($inputCopyTask.IsCompleted) {
                break
            }
        }
        if ($childExited -and -not $inputCopyTask.IsCompleted) {
            try {
                # This wrapper is returning because its child is already gone.
                # Closing our read side cancels the outstanding pipe read
                # without waiting for the MCP client to close its write side.
                $parentInputStream.Close()
            } catch {
                # Child exit remains authoritative.
            }
        }
        try {
            # Close only the raw pipe. Disposing Process.StandardInput's
            # StreamWriter can inject an encoding preamble on Windows
            # PowerShell and may block behind the still-pending input copy.
            $childInputStream.Close()
        } catch {
            if (-not $childExited) {
                throw
            }
        }
        try {
            # Mark the text wrapper disposed only after its raw stream is
            # closed. WinPS 5.1 may try to flush a UTF-8 preamble here; any
            # resulting closed-stream exception is intentionally ignored.
            $childInputWriter.Close()
        } catch {
            # The raw byte-stream EOF above is authoritative.
        }
        if (-not $childExited) {
            $process.WaitForExit()
            $childExited = $true
        }

        # WaitForExit alone does not guarantee redirected async output copies
        # have delivered their final bytes. Never wait for a still-pending stdin
        # read after early child exit; closing the destination above is enough to
        # terminate any write that resumes before this wrapper itself exits.
        $outputDrained = [System.Threading.Tasks.Task]::WaitAll(
            [System.Threading.Tasks.Task[]]@(
                $outputCopyTask,
                $errorCopyTask
            ),
            15000
        )
        if (-not $outputDrained) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $null = $process.WaitForExit(5000)
                }
            } catch {
                # The fixed wrapper error below remains authoritative.
            }
            try { $childOutputStream.Close() } catch {}
            try { $childErrorStream.Close() } catch {}
            throw 'stdio drain timeout'
        }
        $parentOutputStream.Flush()
        $parentErrorStream.Flush()

        # Observe an already-completed input copy without ever waiting for a
        # client pipe that remained open after child exit. Broken-pipe input
        # faults are child-owned once its exit has been observed.
        if ($inputCopyTask.IsCompleted) {
            try {
                $null = $inputCopyTask.GetAwaiter().GetResult()
            } catch {
                # Preserve the already-observed child exit code.
            }
        }
        $ExitCode.Value = [int]$process.ExitCode
    } catch {
        if ($null -ne $parentInputStream) {
            try { $parentInputStream.Close() } catch {}
        }
        if ($null -ne $childInputStream) {
            try { $childInputStream.Close() } catch {}
        }
        if ($null -ne $childInputWriter) {
            try { $childInputWriter.Close() } catch {}
        }
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $null = $process.WaitForExit(5000)
                }
            } catch {
                # Only the exact child created above is considered here.
            }
        }
        if ($null -ne $childOutputStream) {
            try { $childOutputStream.Close() } catch {}
        }
        if ($null -ne $childErrorStream) {
            try { $childErrorStream.Close() } catch {}
        }
        throw 'Agentmemory MCP child invocation failed.'
    } finally {
        if ($null -ne $process) {
            try {
                $process.Dispose()
            } catch {
                # Child completion and drained raw streams are authoritative.
            }
        }
    }
}

function Invoke-AgentMemoryMcpDpapiLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][ref]$ExitCode
    )

    if (-not $script:AgentMemoryMcpSupportAvailable) {
        throw 'Agentmemory MCP security support is unavailable.'
    }

    $secret = $null
    $previousSecret = $null
    $previousUrl = $null
    try {
        $loaded = Read-AgentMemoryWatchdogSettings -SettingsPath $SettingsPath
        $settings = $loaded.Value
        $runtime = Get-AgentMemoryMcpRuntimeContract -Settings $settings
        $secret = Read-AgentMemoryWatchdogSecret `
            -Path ([string]$settings.SecretBlobPath) `
            -ExpectedSha256 ([string]$settings.SecretCiphertextSha256)
        Assert-AgentMemoryWatchdogSecret -Secret $secret

        $previousSecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
        $previousUrl = [Environment]::GetEnvironmentVariable('AGENTMEMORY_URL', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $secret, 'Process')
            [Environment]::SetEnvironmentVariable(
                'AGENTMEMORY_URL', [string]$settings.BaseUrl, 'Process'
            )
            Invoke-AgentMemoryMcpProcess `
                -NodeExecutable $runtime.NodeExecutable `
                -EntryPoint $runtime.EntryPoint `
                -WorkingDirectory $runtime.InstallRoot `
                -ExitCode $ExitCode
        } catch {
            throw 'Agentmemory MCP child invocation failed.'
        } finally {
            [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previousSecret, 'Process')
            [Environment]::SetEnvironmentVariable('AGENTMEMORY_URL', $previousUrl, 'Process')
        }
    } finally {
        $secret = $null
        $previousSecret = $null
        $previousUrl = $null
    }
}

if ($script:AgentMemoryMcpInvokedDirectly) {
    $launcherExitCode = 127
    try {
        if ([string]::IsNullOrWhiteSpace($script:AgentMemoryMcpRequestedSettingsPath)) {
            throw 'settings required'
        }
        Invoke-AgentMemoryMcpDpapiLauncher `
            -SettingsPath $script:AgentMemoryMcpRequestedSettingsPath `
            -ExitCode ([ref]$launcherExitCode)
    } catch {
        [Console]::Error.WriteLine('Agentmemory MCP launcher failed.')
        $launcherExitCode = 127
    }
    exit $launcherExitCode
}
