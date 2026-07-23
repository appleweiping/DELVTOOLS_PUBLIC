$protectedDataType = 'System.Security.Cryptography.ProtectedData' -as [type]
if ($null -eq $protectedDataType) {
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    } catch {
        throw 'Windows DPAPI support is unavailable.'
    }
}

$script:AgentMemoryWatchdogSecretMagic = [byte[]](
    0x41, 0x4d, 0x57, 0x44, 0x53, 0x45, 0x43, 0x01
)
$script:AgentMemoryWatchdogEntropyContext = 'devtools-public/agentmemory-watchdog/secret-store/v1'

function Clear-AgentMemoryWatchdogBytes {
    param([byte[]]$Bytes)
    if ($null -ne $Bytes -and $Bytes.Length -gt 0) {
        [Array]::Clear($Bytes, 0, $Bytes.Length)
    }
}

function Get-AgentMemoryWatchdogCiphertextSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $digest = $null
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash($Bytes)
        return [System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $digest
        $hasher.Dispose()
    }
}

function Protect-AgentMemoryWatchdogSecret {
    param([Parameter(Mandatory = $true)][string]$Secret)

    if ($Secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'Agentmemory watchdog secret format is invalid.'
    }

    $plainBytes = $null
    $entropyBytes = $null
    $ciphertextBytes = $null
    $blobBytes = $null
    $completed = $false
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $plainBytes = $strictUtf8.GetBytes($Secret)
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($script:AgentMemoryWatchdogEntropyContext)
        $ciphertextBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $blobBytes = New-Object byte[] ($script:AgentMemoryWatchdogSecretMagic.Length + $ciphertextBytes.Length)
        [Buffer]::BlockCopy(
            $script:AgentMemoryWatchdogSecretMagic,
            0,
            $blobBytes,
            0,
            $script:AgentMemoryWatchdogSecretMagic.Length
        )
        [Buffer]::BlockCopy(
            $ciphertextBytes,
            0,
            $blobBytes,
            $script:AgentMemoryWatchdogSecretMagic.Length,
            $ciphertextBytes.Length
        )
        $completed = $true
        return ,$blobBytes
    } catch {
        throw 'Agentmemory watchdog secret protection failed.'
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $plainBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $entropyBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $ciphertextBytes
        if (-not $completed) {
            Clear-AgentMemoryWatchdogBytes -Bytes $blobBytes
        }
    }
}

function Write-AgentMemoryWatchdogAtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw 'Agentmemory watchdog persistence path must be absolute.'
    }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw 'Agentmemory watchdog persistence path is invalid.'
    }

    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $staged = Join-Path $parent ('.agentmemory-watchdog.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.agentmemory-watchdog.' + [Guid]::NewGuid().ToString('N') + '.bak')
    try {
        $stream = New-Object System.IO.FileStream(
            $staged,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            try {
                [System.IO.File]::Replace($staged, $resolved, $backup, $true)
            } catch {
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -and
                    (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    [System.IO.File]::Move($backup, $resolved)
                }
                throw
            }
        } else {
            [System.IO.File]::Move($staged, $resolved)
        }
    } catch {
        throw 'Agentmemory watchdog persistence write failed.'
    } finally {
        foreach ($temporaryPath in @($staged, $backup)) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-AgentMemoryWatchdogHashEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        $difference = $difference -bor (
            [int][char]$Expected[$index] -bxor [int][char]$Actual[$index]
        )
    }
    return ($difference -eq 0)
}

function Read-AgentMemoryWatchdogSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not [System.IO.Path]::IsPathRooted($Path) -or
        $ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Agentmemory watchdog secret reference is invalid.'
    }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw 'Agentmemory watchdog secret blob is unavailable.'
    }
    $length = (Get-Item -LiteralPath $resolved).Length
    if ($length -le $script:AgentMemoryWatchdogSecretMagic.Length -or $length -gt 65536) {
        throw 'Agentmemory watchdog secret blob is invalid.'
    }

    $blobBytes = $null
    $ciphertextBytes = $null
    $entropyBytes = $null
    $plainBytes = $null
    try {
        $blobBytes = [System.IO.File]::ReadAllBytes($resolved)
        $actualHash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blobBytes
        if (-not (Test-AgentMemoryWatchdogHashEqual -Expected $ExpectedSha256 -Actual $actualHash)) {
            throw 'hash mismatch'
        }
        for ($index = 0; $index -lt $script:AgentMemoryWatchdogSecretMagic.Length; $index++) {
            if ($blobBytes[$index] -ne $script:AgentMemoryWatchdogSecretMagic[$index]) {
                throw 'version mismatch'
            }
        }

        $ciphertextLength = $blobBytes.Length - $script:AgentMemoryWatchdogSecretMagic.Length
        $ciphertextBytes = New-Object byte[] $ciphertextLength
        [Buffer]::BlockCopy(
            $blobBytes,
            $script:AgentMemoryWatchdogSecretMagic.Length,
            $ciphertextBytes,
            0,
            $ciphertextLength
        )
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($script:AgentMemoryWatchdogEntropyContext)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $ciphertextBytes,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($plainBytes)
    } catch {
        throw 'Agentmemory watchdog secret blob validation failed.'
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $blobBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $ciphertextBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $entropyBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $plainBytes
    }
}
