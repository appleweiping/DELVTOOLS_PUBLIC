$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

. (Join-Path $repoRoot 'agentmemory-secret-store.ps1')
. (Join-Path $repoRoot 'agentmemory-watchdog-register.ps1')
. (Join-Path $repoRoot 'agentmemory-watchdog-run.ps1')

function Test-WatchdogActionThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $false
    } catch {
        return $true
    }
}

function Get-WatchdogActionError {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return $null
    } catch {
        return [string]$_
    }
}

function New-WatchdogPersistenceFixture {
    param([Parameter(Mandatory = $true)][string]$Root)

    $paths = [ordered]@{
        Root = $Root
        DataRoot = Join-Path $Root 'data'
        LogDir = Join-Path $Root 'logs'
        Config = Join-Path $Root 'agentmemory-iii.yaml'
        InstallRoot = Join-Path $Root 'runtime'
        NodeExecutable = Join-Path $Root 'node\node.exe'
        IiiExecutable = Join-Path $Root 'runtime\iii.exe'
        SelfHealScript = Join-Path $Root 'agentmemory-selfheal.ps1'
        ServerScript = Join-Path $Root 'agentmemory-server.ps1'
        GuardScript = Join-Path $Root 'agentmemory-host-guard.mjs'
        RunnerScript = Join-Path $repoRoot 'agentmemory-watchdog-run.cmd'
        PowerShellExecutable = (Get-Command powershell.exe -CommandType Application).Source
    }
    foreach ($path in @(
            $paths.Config, $paths.NodeExecutable, $paths.IiiExecutable,
            $paths.SelfHealScript, $paths.ServerScript, $paths.GuardScript
        )) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, 'fixture')
    }
    return [pscustomobject]$paths
}

function Get-WatchdogStableSettingsPath {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [int]$Port = 4111
    )
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($TaskName.ToLowerInvariant())
        $digest = $hasher.ComputeHash($bytes)
        $taskKey = [System.BitConverter]::ToString($digest).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($null -ne $digest) { [Array]::Clear($digest, 0, $digest.Length) }
        $hasher.Dispose()
    }
    return Join-Path $LogDir ("watchdog.port$Port.task$taskKey.json")
}

function New-WatchdogRunnerFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Secret
    )
    $fixture = New-WatchdogPersistenceFixture -Root $Root
    $runRoot = Join-Path $fixture.DataRoot 'run'
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $blobBytes = Protect-AgentMemoryWatchdogSecret -Secret $Secret
    try {
        $hash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blobBytes
        $blobPath = Join-Path $runRoot ("watchdog-secret.$hash.dpapi")
        Write-AgentMemoryWatchdogAtomicBytes -Path $blobPath -Bytes $blobBytes
    } finally {
        if ($null -ne $blobBytes) { [Array]::Clear($blobBytes, 0, $blobBytes.Length) }
    }
    $settingsPath = Join-Path $fixture.LogDir 'watchdog.settings.json'
    $settings = [ordered]@{
        SchemaVersion = 1
        DevToolsRoot = $fixture.Root
        DataRoot = $fixture.DataRoot
        BaseUrl = 'http://127.0.0.1:4111'
        Config = $fixture.Config
        InstallRoot = $fixture.InstallRoot
        NodeExecutable = $fixture.NodeExecutable
        IiiExecutable = $fixture.IiiExecutable
        EmbeddingProvider = 'local'
        LogDir = $fixture.LogDir
        SelfHealScript = $fixture.SelfHealScript
        ServerScript = $fixture.ServerScript
        PowerShellExecutable = $fixture.PowerShellExecutable
        SecretBlobPath = $blobPath
        SecretCiphertextSha256 = $hash
    }
    Write-AgentMemoryWatchdogSettings -Path $settingsPath -Settings $settings
    return [pscustomobject]@{
        Fixture = $fixture
        Settings = $settings
        SettingsPath = $settingsPath
        BlobPath = $blobPath
    }
}

Describe 'AgentMemory watchdog DPAPI persistence' {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        $script:originalAgentMemorySecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $script:originalAgentMemorySecret, 'Process')
    }

    It 'round-trips only versioned CurrentUser DPAPI ciphertext and detects tampering' {
        $secret = ('A1b2C3d4_' * 4)
        $path = Join-Path $TestDrive 'data\run\watchdog-secret.dpapi'
        $blob = Protect-AgentMemoryWatchdogSecret -Secret $secret
        try {
            $hash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blob
            Write-AgentMemoryWatchdogAtomicBytes -Path $path -Bytes $blob
        } finally {
            if ($null -ne $blob) { [Array]::Clear($blob, 0, $blob.Length) }
        }

        $persisted = [System.IO.File]::ReadAllBytes($path)
        try {
            [System.Text.Encoding]::UTF8.GetString($persisted) | Should Not Match ([regex]::Escape($secret))
            [System.Text.Encoding]::ASCII.GetString($persisted, 0, 7) | Should Be 'AMWDSEC'
        } finally {
            [Array]::Clear($persisted, 0, $persisted.Length)
        }
        (Read-AgentMemoryWatchdogSecret -Path $path -ExpectedSha256 $hash) | Should Be $secret

        $tampered = [System.IO.File]::ReadAllBytes($path)
        $tampered[$tampered.Length - 1] = $tampered[$tampered.Length - 1] -bxor 1
        [System.IO.File]::WriteAllBytes($path, $tampered)
        [Array]::Clear($tampered, 0, $tampered.Length)
        (Test-WatchdogActionThrows {
                Read-AgentMemoryWatchdogSecret -Path $path -ExpectedSha256 $hash
            }) | Should Be $true
    }

    It 'leaves no blob, settings, transaction file, or task call under WhatIf' {
        $fixture = New-WatchdogPersistenceFixture -Root (Join-Path $TestDrive 'whatif')
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', ('A1b2C3d4_' * 4), 'Process')
        Mock Get-AgentMemoryWatchdogExistingTaskXml { throw 'task query must not run under WhatIf' }
        Mock Set-AgentMemoryWatchdogScheduledTask { throw 'task create must not run under WhatIf' }
        Mock Remove-AgentMemoryWatchdogScheduledTask { throw 'task delete must not run under WhatIf' }

        Register-AgentMemoryWatchdog `
            -DevToolsRoot $fixture.Root `
            -DataRoot $fixture.DataRoot `
            -BaseUrl 'http://localhost:4111' `
            -Config $fixture.Config `
            -InstallRoot $fixture.InstallRoot `
            -NodeExecutable $fixture.NodeExecutable `
            -IiiExecutable $fixture.IiiExecutable `
            -LogDir $fixture.LogDir `
            -SelfHealScript $fixture.SelfHealScript `
            -ServerScript $fixture.ServerScript `
            -RunnerScript $fixture.RunnerScript `
            -SettingsPath (Join-Path $fixture.LogDir 'watchdog.json') `
            -PowerShellExecutable $fixture.PowerShellExecutable `
            -TaskName 'Watchdog-WhatIf' `
            -WhatIf | Out-Null

        Assert-MockCalled Get-AgentMemoryWatchdogExistingTaskXml -Times 0 -Scope It
        Assert-MockCalled Set-AgentMemoryWatchdogScheduledTask -Times 0 -Scope It
        Assert-MockCalled Remove-AgentMemoryWatchdogScheduledTask -Times 0 -Scope It
        (Test-Path -LiteralPath (Join-Path $fixture.DataRoot 'run')) | Should Be $false
        @(Get-ChildItem -LiteralPath $fixture.LogDir -File -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'validates the exact settings schema and restores the process secret after success and failure' {
        $secret = ('A1b2C3d4_' * 4)
        $runner = New-WatchdogRunnerFixture -Root (Join-Path $TestDrive 'runner') -Secret $secret
        $previous = 'previous-process-value'
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previous, 'Process')
        $script:observedRunnerSecret = $null
        Mock Invoke-AgentMemoryWatchdogSelfHeal {
            $script:observedRunnerSecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
            return 0
        }

        (Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath) | Should Be 0
        $script:observedRunnerSecret | Should Be $secret
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') | Should Be $previous

        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $null, 'Process')
        (Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath) | Should Be 0
        $script:observedRunnerSecret | Should Be $secret
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') | Should BeNullOrEmpty

        $runner.Settings.Unexpected = 'reject-me'
        Write-AgentMemoryWatchdogSettings -Path $runner.SettingsPath -Settings $runner.Settings
        (Test-WatchdogActionThrows {
                Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath
            }) | Should Be $true
        Assert-MockCalled Invoke-AgentMemoryWatchdogSelfHeal -Times 2 -Scope It

        $runner.Settings.PSObject.Properties.Remove('Unexpected')
        Write-AgentMemoryWatchdogSettings -Path $runner.SettingsPath -Settings $runner.Settings
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $previous, 'Process')
        Mock Invoke-AgentMemoryWatchdogSelfHeal { throw 'simulated child failure' }
        $errorText = Get-WatchdogActionError {
            Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath
        }
        $errorText | Should Not BeNullOrEmpty
        $errorText | Should Not Match ([regex]::Escape($secret))
        [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process') | Should Be $previous
    }

    It 'rejects blob hash drift, DPAPI tampering, and non-canonical secret paths without leaking the secret' {
        $secret = ('A1b2C3d4_' * 4)
        $runner = New-WatchdogRunnerFixture -Root (Join-Path $TestDrive 'tamper') -Secret $secret
        $bytes = [System.IO.File]::ReadAllBytes($runner.BlobPath)
        $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
        [System.IO.File]::WriteAllBytes($runner.BlobPath, $bytes)
        $newHash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $bytes
        [Array]::Clear($bytes, 0, $bytes.Length)

        $hashError = Get-WatchdogActionError {
            Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath
        }
        $hashError | Should Not BeNullOrEmpty
        $hashError | Should Not Match ([regex]::Escape($secret))

        $runner.Settings.SecretCiphertextSha256 = $newHash
        Write-AgentMemoryWatchdogSettings -Path $runner.SettingsPath -Settings $runner.Settings
        $dpapiError = Get-WatchdogActionError {
            Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath
        }
        $dpapiError | Should Not BeNullOrEmpty
        $dpapiError | Should Not Match ([regex]::Escape($secret))

        $runner.Settings.SecretBlobPath = '.\relative.dpapi'
        Write-AgentMemoryWatchdogSettings -Path $runner.SettingsPath -Settings $runner.Settings
        (Test-WatchdogActionThrows {
                Invoke-AgentMemoryWatchdogRunner -SettingsPath $runner.SettingsPath
            }) | Should Be $true
    }
}

Describe 'AgentMemory watchdog deterministic scheduled task transaction' {
    $TestDrive = [System.IO.Path]::GetFullPath([string]$TestDrive)

    BeforeEach {
        $script:originalAgentMemorySecret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', ('A1b2C3d4_' * 4), 'Process')
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $script:originalAgentMemorySecret, 'Process')
    }

    It 'emits deterministic XML and rejects action, principal, cadence, duration, or enabled drift' {
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $runner = 'C:\Portable Tools\agentmemory-watchdog-run.cmd'
        $settings = 'C:\Portable Tools\logs\watchdog.settings.json'
        $xml = New-AgentMemoryWatchdogTaskXml `
            -RunnerCommand $runner -SettingsPath $settings -CurrentSid $sid -IntervalMinutes 5
        $xml | Should Be (New-AgentMemoryWatchdogTaskXml `
            -RunnerCommand $runner -SettingsPath $settings -CurrentSid $sid -IntervalMinutes 5)
        $xml | Should Match '^<\?xml version="1\.0"\?>'
        $xml | Should Not Match '(?i)encoding\s*='
        (Assert-AgentMemoryWatchdogTaskXml `
            -Xml $xml -RunnerCommand $runner -SettingsPath $settings `
            -CurrentSid $sid -IntervalMinutes 5) | Should Be $true

        # Task Scheduler's XML export omits elements whose values equal the
        # schema defaults. The postcondition must accept that normalization
        # while still rejecting explicit unsafe values.
        $normalizedXml = $xml `
            -replace '(?m)^\s*<RunLevel>LeastPrivilege</RunLevel>\r?\n', '' `
            -replace '(?m)^\s*<StopAtDurationEnd>false</StopAtDurationEnd>\r?\n', '' `
            -replace '(?m)^\s*<Enabled>true</Enabled>\r?\n', ''
        (Assert-AgentMemoryWatchdogTaskXml `
            -Xml $normalizedXml -RunnerCommand $runner -SettingsPath $settings `
            -CurrentSid $sid -IntervalMinutes 5) | Should Be $true

        $drifts = @(
            $xml.Replace($runner, 'C:\Wrong\runner.cmd'),
            $xml.Replace('<UserId>' + $sid + '</UserId>', '<UserId>S-1-5-18</UserId>'),
            $xml.Replace('<LogonType>InteractiveToken</LogonType>', '<LogonType>Password</LogonType>'),
            $xml.Replace('<RunLevel>LeastPrivilege</RunLevel>', '<RunLevel>HighestAvailable</RunLevel>'),
            $xml.Replace('<Interval>PT5M</Interval>', '<Interval>PT10M</Interval>'),
            $xml.Replace('<StopAtDurationEnd>false</StopAtDurationEnd>', '<Duration>PT1H</Duration><StopAtDurationEnd>false</StopAtDurationEnd>'),
            $xml.Replace('<Enabled>true</Enabled>', '<Enabled>false</Enabled>'),
            $xml.Replace('</Exec>', '</Exec><Exec><Command>C:\Wrong\second.cmd</Command></Exec>')
        )
        foreach ($drift in $drifts) {
            (Test-WatchdogActionThrows {
                    Assert-AgentMemoryWatchdogTaskXml `
                        -Xml $drift -RunnerCommand $runner -SettingsPath $settings `
                        -CurrentSid $sid -IntervalMinutes 5
                }) | Should Be $true
        }
    }

    It 'recognizes Task Scheduler missing-task HRESULT across .NET exception projections' {
        (Test-AgentMemoryWatchdogTaskNotFoundException `
            -Exception ([System.IO.FileNotFoundException]::new())) | Should Be $true
        (Test-AgentMemoryWatchdogTaskNotFoundException `
            -Exception ([System.Runtime.InteropServices.COMException]::new(
                'missing', -2147024894))) | Should Be $true
        (Test-AgentMemoryWatchdogTaskNotFoundException `
            -Exception ([System.InvalidOperationException]::new())) | Should Be $false
    }

    It 'restores the exported task and prior settings and blob when postcondition verification drifts' {
        $fixture = New-WatchdogPersistenceFixture -Root (Join-Path $TestDrive 'rollback-existing')
        $taskName = 'Watchdog-Rollback-Existing'
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $settingsPath = Get-WatchdogStableSettingsPath -LogDir $fixture.LogDir -TaskName $taskName
        $oldBlobPath = Join-Path $fixture.DataRoot 'run\old-watchdog.dpapi'
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldBlobPath) -Force | Out-Null
        $oldBlob = [byte[]](65, 77, 87, 68, 83, 69, 67, 1, 9, 8, 7, 6)
        [System.IO.File]::WriteAllBytes($oldBlobPath, $oldBlob)
        $oldSettings = '{"SecretBlobPath":"' + ($oldBlobPath.Replace('\', '\\')) + '","Marker":"old"}'
        New-Item -ItemType Directory -Path $fixture.LogDir -Force | Out-Null
        [System.IO.File]::WriteAllText($settingsPath, $oldSettings)
        $oldTaskXml = New-AgentMemoryWatchdogTaskXml `
            -RunnerCommand $fixture.RunnerScript -SettingsPath $settingsPath `
            -CurrentSid $sid -IntervalMinutes 5
        $script:taskXmlState = $oldTaskXml
        $script:setTaskXmlCalls = @()
        Mock Get-AgentMemoryWatchdogCurrentSid { return $sid }
        Mock Get-AgentMemoryWatchdogExistingTaskXml { return $script:taskXmlState }
        Mock Set-AgentMemoryWatchdogScheduledTask {
            param($TaskName, $Xml, $RunDirectory, $CurrentSid)
            $script:setTaskXmlCalls += $Xml
            if ($script:setTaskXmlCalls.Count -eq 1) {
                $script:taskXmlState = $Xml.Replace('<Interval>PT5M</Interval>', '<Interval>PT10M</Interval>')
            } else {
                $script:taskXmlState = $Xml
            }
        }
        Mock Remove-AgentMemoryWatchdogScheduledTask { throw 'existing task must be restored, not deleted' }

        (Test-WatchdogActionThrows {
                Register-AgentMemoryWatchdog `
                    -DevToolsRoot $fixture.Root -DataRoot $fixture.DataRoot `
                    -BaseUrl 'http://127.0.0.1:4111' -Config $fixture.Config `
                    -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                    -IiiExecutable $fixture.IiiExecutable -LogDir $fixture.LogDir `
                    -SelfHealScript $fixture.SelfHealScript -ServerScript $fixture.ServerScript `
                    -RunnerScript $fixture.RunnerScript -SettingsPath (Join-Path $fixture.LogDir 'watchdog.json') `
                    -PowerShellExecutable $fixture.PowerShellExecutable -TaskName $taskName
            }) | Should Be $true

        $script:setTaskXmlCalls.Count | Should Be 2
        $script:setTaskXmlCalls[1] | Should Be $oldTaskXml
        [System.IO.File]::ReadAllText($settingsPath) | Should Be $oldSettings
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($oldBlobPath)) |
            Should Be ([Convert]::ToBase64String($oldBlob))
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.DataRoot 'run') -File -Filter '*.transaction.*' -ErrorAction SilentlyContinue).Count |
            Should Be 0
    }

    It 'commits verified task XML and settings without plaintext, then retires the old blob' {
        $fixture = New-WatchdogPersistenceFixture -Root (Join-Path $TestDrive 'commit-existing')
        $taskName = 'Watchdog-Commit-Existing'
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $secret = ('A1b2C3d4_' * 4)
        $settingsPath = Get-WatchdogStableSettingsPath -LogDir $fixture.LogDir -TaskName $taskName
        $oldBlobPath = Join-Path $fixture.DataRoot 'run\old-watchdog.dpapi'
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldBlobPath) -Force | Out-Null
        [System.IO.File]::WriteAllBytes(
            $oldBlobPath,
            [byte[]](65, 77, 87, 68, 83, 69, 67, 1, 9, 8, 7, 6)
        )
        New-Item -ItemType Directory -Path $fixture.LogDir -Force | Out-Null
        [System.IO.File]::WriteAllText(
            $settingsPath,
            ('{"SecretBlobPath":"' + ($oldBlobPath.Replace('\', '\\')) + '","Marker":"old"}')
        )
        $script:taskXmlState = New-AgentMemoryWatchdogTaskXml `
            -RunnerCommand $fixture.RunnerScript -SettingsPath $settingsPath `
            -CurrentSid $sid -IntervalMinutes 5
        Mock Get-AgentMemoryWatchdogCurrentSid { return $sid }
        Mock Get-AgentMemoryWatchdogExistingTaskXml { return $script:taskXmlState }
        Mock Set-AgentMemoryWatchdogScheduledTask {
            param($TaskName, $Xml, $RunDirectory, $CurrentSid)
            $script:taskXmlState = $Xml
        }
        Mock Remove-AgentMemoryWatchdogScheduledTask { throw 'verified existing task must not be deleted' }
        [Environment]::SetEnvironmentVariable('AGENTMEMORY_SECRET', $secret, 'Process')

        $output = @(Register-AgentMemoryWatchdog `
            -DevToolsRoot $fixture.Root -DataRoot $fixture.DataRoot `
            -BaseUrl 'http://127.0.0.1:4111' -Config $fixture.Config `
            -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
            -IiiExecutable $fixture.IiiExecutable -LogDir $fixture.LogDir `
            -SelfHealScript $fixture.SelfHealScript -ServerScript $fixture.ServerScript `
            -RunnerScript $fixture.RunnerScript -SettingsPath (Join-Path $fixture.LogDir 'watchdog.json') `
            -PowerShellExecutable $fixture.PowerShellExecutable -TaskName $taskName)

        ($output -join '|') | Should Match 'registration completed'
        (Assert-AgentMemoryWatchdogTaskXml `
            -Xml $script:taskXmlState -RunnerCommand $fixture.RunnerScript `
            -SettingsPath $settingsPath -CurrentSid $sid -IntervalMinutes 5) | Should Be $true
        $saved = [System.IO.File]::ReadAllText($settingsPath)
        $saved | Should Not Match ([regex]::Escape($secret))
        $settings = $saved | ConvertFrom-Json
        [System.IO.Path]::IsPathRooted([string]$settings.SecretBlobPath) | Should Be $true
        (Test-Path -LiteralPath ([string]$settings.SecretBlobPath) -PathType Leaf) | Should Be $true
        $ciphertext = [System.IO.File]::ReadAllBytes([string]$settings.SecretBlobPath)
        try {
            (Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $ciphertext) |
                Should Be ([string]$settings.SecretCiphertextSha256)
            [System.Text.Encoding]::ASCII.GetString($ciphertext, 0, 7) | Should Be 'AMWDSEC'
        } finally {
            [Array]::Clear($ciphertext, 0, $ciphertext.Length)
        }
        (Test-Path -LiteralPath $oldBlobPath) | Should Be $false
        Assert-MockCalled Set-AgentMemoryWatchdogScheduledTask -Times 1 -Scope It
    }

    It 'fails closed before mutation when a task-name collision needs unavailable credentials' {
        $fixture = New-WatchdogPersistenceFixture -Root (Join-Path $TestDrive 'collision')
        $taskName = 'Watchdog-Collision'
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $settingsPath = Get-WatchdogStableSettingsPath -LogDir $fixture.LogDir -TaskName $taskName
        New-Item -ItemType Directory -Path $fixture.LogDir -Force | Out-Null
        $oldSettings = '{"Marker":"unchanged"}'
        [System.IO.File]::WriteAllText($settingsPath, $oldSettings)
        $script:taskXmlState = (New-AgentMemoryWatchdogTaskXml `
            -RunnerCommand $fixture.RunnerScript -SettingsPath $settingsPath `
            -CurrentSid $sid -IntervalMinutes 5).Replace(
                '<LogonType>InteractiveToken</LogonType>',
                '<LogonType>Password</LogonType>'
            )
        Mock Get-AgentMemoryWatchdogCurrentSid { return $sid }
        Mock Get-AgentMemoryWatchdogExistingTaskXml { return $script:taskXmlState }
        Mock Set-AgentMemoryWatchdogScheduledTask { throw 'collision must not be overwritten' }
        Mock Remove-AgentMemoryWatchdogScheduledTask { throw 'collision must not be deleted' }

        (Test-WatchdogActionThrows {
                Register-AgentMemoryWatchdog `
                    -DevToolsRoot $fixture.Root -DataRoot $fixture.DataRoot `
                    -BaseUrl 'http://127.0.0.1:4111' -Config $fixture.Config `
                    -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                    -IiiExecutable $fixture.IiiExecutable -LogDir $fixture.LogDir `
                    -SelfHealScript $fixture.SelfHealScript -ServerScript $fixture.ServerScript `
                    -RunnerScript $fixture.RunnerScript -SettingsPath (Join-Path $fixture.LogDir 'watchdog.json') `
                    -PowerShellExecutable $fixture.PowerShellExecutable -TaskName $taskName
            }) | Should Be $true

        [System.IO.File]::ReadAllText($settingsPath) | Should Be $oldSettings
        Assert-MockCalled Set-AgentMemoryWatchdogScheduledTask -Times 0 -Scope It
        Assert-MockCalled Remove-AgentMemoryWatchdogScheduledTask -Times 0 -Scope It
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.DataRoot 'run') -File -ErrorAction SilentlyContinue).Count |
            Should Be 0
    }

    It 'deletes a newly created task and restores absence when no prior task existed' {
        $fixture = New-WatchdogPersistenceFixture -Root (Join-Path $TestDrive 'rollback-new')
        $taskName = 'Watchdog-Rollback-New'
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $script:taskXmlState = $null
        $script:removeCalls = 0
        Mock Get-AgentMemoryWatchdogCurrentSid { return $sid }
        Mock Get-AgentMemoryWatchdogExistingTaskXml { return $script:taskXmlState }
        Mock Set-AgentMemoryWatchdogScheduledTask {
            param($TaskName, $Xml, $RunDirectory, $CurrentSid)
            $script:taskXmlState = $Xml.Replace('<Enabled>true</Enabled>', '<Enabled>false</Enabled>')
        }
        Mock Remove-AgentMemoryWatchdogScheduledTask {
            $script:removeCalls += 1
            $script:taskXmlState = $null
        }

        (Test-WatchdogActionThrows {
                Register-AgentMemoryWatchdog `
                    -DevToolsRoot $fixture.Root -DataRoot $fixture.DataRoot `
                    -BaseUrl 'http://127.0.0.1:4111' -Config $fixture.Config `
                    -InstallRoot $fixture.InstallRoot -NodeExecutable $fixture.NodeExecutable `
                    -IiiExecutable $fixture.IiiExecutable -LogDir $fixture.LogDir `
                    -SelfHealScript $fixture.SelfHealScript -ServerScript $fixture.ServerScript `
                    -RunnerScript $fixture.RunnerScript -SettingsPath (Join-Path $fixture.LogDir 'watchdog.json') `
                    -PowerShellExecutable $fixture.PowerShellExecutable -TaskName $taskName
            }) | Should Be $true

        $script:removeCalls | Should Be 1
        $script:taskXmlState | Should BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $fixture.LogDir -File -ErrorAction SilentlyContinue).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.DataRoot 'run') -File -ErrorAction SilentlyContinue).Count |
            Should Be 0
    }
}
