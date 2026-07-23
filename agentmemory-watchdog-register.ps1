[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DevToolsRoot,
    [string]$DataRoot,
    [string]$BaseUrl,
    [string]$Config,
    [string]$InstallRoot,
    [string]$NodeExecutable,
    [string]$IiiExecutable,
    [string]$EmbeddingProvider,
    [string]$LogDir,
    [string]$SelfHealScript,
    [string]$ServerScript,
    [string]$RunnerScript,
    [string]$SettingsPath,
    [string]$PowerShellExecutable,
    [string]$TaskName = 'AgentmemoryWatchdog',
    [ValidateRange(1, 1439)][int]$IntervalMinutes = 5
)

$ErrorActionPreference = 'Stop'

$secretStoreScript = Join-Path $PSScriptRoot 'agentmemory-secret-store.ps1'
if (-not (Test-Path -LiteralPath $secretStoreScript -PathType Leaf)) {
    throw 'Agentmemory watchdog secret-store support is unavailable.'
}
. $secretStoreScript

function Get-AgentMemoryWatchdogRequiredSecret {
    $secret = [Environment]::GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')
    if ([string]::IsNullOrWhiteSpace($secret) -or
        $secret -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'AGENTMEMORY_SECRET must be a 32-256 character URL-safe secret.'
    }
    return $secret
}

function Resolve-AgentMemoryWatchdogPath {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DefaultRelativePath
    )
    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Join-Path $Root $DefaultRelativePath
    } elseif (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $Root $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Test-AgentMemoryWatchdogPathWithin {
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

function ConvertTo-AgentMemoryWatchdogArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\x00-\x1f\x7f\u0085\u2028\u2029%!&|<>^]' -or $Value.Contains('"')) {
        throw 'A scheduled-task argument contains characters that cannot be represented safely.'
    }
    return '"' + $Value + '"'
}

function New-AgentMemoryWatchdogAction {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerCommand,
        [Parameter(Mandatory = $true)][string]$SettingsPath
    )
    $action = @(
        (ConvertTo-AgentMemoryWatchdogArgument $RunnerCommand),
        (ConvertTo-AgentMemoryWatchdogArgument $SettingsPath)
    ) -join ' '
    if ($action.Length -gt 262) {
        throw 'The scheduled-task action exceeds the schtasks.exe /TR 262-character limit.'
    }
    return $action
}

function Write-AgentMemoryWatchdogSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Settings
    )
    $bytes = $null
    try {
        $json = $Settings | ConvertTo-Json -Depth 4
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $bytes = $encoding.GetBytes($json)
        Write-AgentMemoryWatchdogAtomicBytes -Path ([System.IO.Path]::GetFullPath($Path)) -Bytes $bytes
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $bytes
    }
}

function ConvertTo-AgentMemoryWatchdogXmlText {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-AgentMemoryWatchdogTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerCommand,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$CurrentSid,
        [ValidateRange(1, 1439)][int]$IntervalMinutes = 5
    )
    if ($IntervalMinutes -ne 5) {
        throw 'The scheduled watchdog cadence must be exactly five minutes.'
    }
    foreach ($path in @($RunnerCommand, $SettingsPath)) {
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            throw 'Scheduled watchdog action paths must be absolute.'
        }
        [void](ConvertTo-AgentMemoryWatchdogArgument -Value $path)
    }
    if ($CurrentSid -notmatch '^S-\d(?:-\d+)+$') {
        throw 'The scheduled watchdog principal is invalid.'
    }

    $commandXml = ConvertTo-AgentMemoryWatchdogXmlText -Value $RunnerCommand
    $argumentXml = ConvertTo-AgentMemoryWatchdogXmlText -Value (
        ConvertTo-AgentMemoryWatchdogArgument -Value $SettingsPath
    )
    $sidXml = ConvertTo-AgentMemoryWatchdogXmlText -Value $CurrentSid
    return (@(
        # RegisterTask receives this XML as a UTF-16 BSTR. An encoding
        # declaration would describe a byte stream and makes Task Scheduler
        # reject the in-memory document as an encoding switch.
        '<?xml version="1.0"?>',
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
        '  <RegistrationInfo>',
        '    <Description>AgentMemory self-heal watchdog</Description>',
        '  </RegistrationInfo>',
        '  <Triggers>',
        '    <TimeTrigger>',
        '      <Repetition>',
        '        <Interval>PT5M</Interval>',
        '        <StopAtDurationEnd>false</StopAtDurationEnd>',
        '      </Repetition>',
        '      <StartBoundary>2000-01-01T00:00:00</StartBoundary>',
        '      <Enabled>true</Enabled>',
        '    </TimeTrigger>',
        '  </Triggers>',
        '  <Principals>',
        '    <Principal id="WatchdogPrincipal">',
        "      <UserId>$sidXml</UserId>",
        '      <LogonType>InteractiveToken</LogonType>',
        '      <RunLevel>LeastPrivilege</RunLevel>',
        '    </Principal>',
        '  </Principals>',
        '  <Settings>',
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
        '    <AllowHardTerminate>true</AllowHardTerminate>',
        '    <StartWhenAvailable>true</StartWhenAvailable>',
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>',
        '    <Enabled>true</Enabled>',
        '    <Hidden>false</Hidden>',
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>',
        '    <WakeToRun>false</WakeToRun>',
        '    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>',
        '    <Priority>7</Priority>',
        '  </Settings>',
        '  <Actions Context="WatchdogPrincipal">',
        '    <Exec>',
        "      <Command>$commandXml</Command>",
        "      <Arguments>$argumentXml</Arguments>",
        '    </Exec>',
        '  </Actions>',
        '</Task>'
    ) -join "`r`n")
}

function ConvertFrom-AgentMemoryWatchdogTaskXml {
    param([Parameter(Mandatory = $true)][string]$Xml)
    try {
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $stringReader = New-Object System.IO.StringReader($Xml)
        try {
            $reader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
            try {
                $document = New-Object System.Xml.XmlDocument
                $document.XmlResolver = $null
                $document.Load($reader)
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stringReader.Dispose()
        }
        return ,$document
    } catch {
        throw 'Scheduled watchdog XML is invalid.'
    }
}

function Assert-AgentMemoryWatchdogTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)][string]$RunnerCommand,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$CurrentSid,
        [ValidateRange(1, 1439)][int]$IntervalMinutes = 5
    )
    if ($IntervalMinutes -ne 5) {
        throw 'Scheduled watchdog cadence drift was detected.'
    }
    $document = ConvertFrom-AgentMemoryWatchdogTaskXml -Xml $Xml
    $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $task = $document.SelectSingleNode('/t:Task', $namespace)
    if ($null -eq $task -or $document.DocumentElement.NamespaceURI -ne
        'http://schemas.microsoft.com/windows/2004/02/mit/task') {
        throw 'Scheduled watchdog task root drift was detected.'
    }

    $actionsContainers = @($document.SelectNodes('/t:Task/t:Actions', $namespace))
    $actionNodes = @($document.SelectNodes('/t:Task/t:Actions/*', $namespace))
    if ($actionsContainers.Count -ne 1 -or $actionNodes.Count -ne 1 -or
        $actionNodes[0].LocalName -cne 'Exec' -or
        $actionNodes[0].NamespaceURI -ne 'http://schemas.microsoft.com/windows/2004/02/mit/task') {
        throw 'Scheduled watchdog action drift was detected.'
    }
    if ([string]$actionsContainers[0].GetAttribute('Context') -cne 'WatchdogPrincipal') {
        throw 'Scheduled watchdog action context drift was detected.'
    }
    $execChildren = @($actionNodes[0].SelectNodes('./*'))
    $commands = @($actionNodes[0].SelectNodes('./t:Command', $namespace))
    $arguments = @($actionNodes[0].SelectNodes('./t:Arguments', $namespace))
    $expectedArguments = ConvertTo-AgentMemoryWatchdogArgument -Value $SettingsPath
    if ($execChildren.Count -ne 2 -or $commands.Count -ne 1 -or $arguments.Count -ne 1 -or
        [string]$commands[0].InnerText -cne $RunnerCommand -or
        [string]$arguments[0].InnerText -cne $expectedArguments) {
        throw 'Scheduled watchdog command drift was detected.'
    }

    $principals = @($document.SelectNodes('/t:Task/t:Principals/t:Principal', $namespace))
    if ($principals.Count -ne 1 -or [string]$principals[0].GetAttribute('id') -cne 'WatchdogPrincipal') {
        throw 'Scheduled watchdog principal drift was detected.'
    }
    $principalChildren = @($principals[0].SelectNodes('./*'))
    $userIds = @($principals[0].SelectNodes('./t:UserId', $namespace))
    $logonTypes = @($principals[0].SelectNodes('./t:LogonType', $namespace))
    $runLevels = @($principals[0].SelectNodes('./t:RunLevel', $namespace))
    $unexpectedPrincipalChildren = @($principalChildren | Where-Object {
            @('UserId', 'LogonType', 'RunLevel') -cnotcontains $_.LocalName
        })
    $runLevelValid = ($runLevels.Count -eq 0)
    if ($runLevels.Count -eq 1) {
        $runLevelValid = ([string]$runLevels[0].InnerText -ceq 'LeastPrivilege')
    }
    if ($principalChildren.Count -lt 2 -or $principalChildren.Count -gt 3 -or
        $unexpectedPrincipalChildren.Count -ne 0 -or $userIds.Count -ne 1 -or
        $logonTypes.Count -ne 1 -or $runLevels.Count -gt 1 -or
        [string]$userIds[0].InnerText -cne $CurrentSid -or
        [string]$logonTypes[0].InnerText -cne 'InteractiveToken' -or
        -not $runLevelValid) {
        throw 'Scheduled watchdog principal policy drift was detected.'
    }

    $triggers = @($document.SelectNodes('/t:Task/t:Triggers/*', $namespace))
    $timeTriggers = @($document.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger', $namespace))
    $repetitions = @($document.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger/t:Repetition', $namespace))
    $intervals = @($document.SelectNodes('//t:Repetition/t:Interval', $namespace))
    $durations = @($document.SelectNodes('//t:Repetition/t:Duration', $namespace))
    $stopAtDurationEnd = @($document.SelectNodes('//t:Repetition/t:StopAtDurationEnd', $namespace))
    $endBoundaries = @($document.SelectNodes('/t:Task/t:Triggers/*/t:EndBoundary', $namespace))
    $startBoundaries = @($document.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger/t:StartBoundary', $namespace))
    $triggerEnabled = @($document.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger/t:Enabled', $namespace))
    $triggerChildren = @(if ($timeTriggers.Count -eq 1) {
            $timeTriggers[0].SelectNodes('./*')
        })
    $repetitionChildren = @(if ($repetitions.Count -eq 1) {
            $repetitions[0].SelectNodes('./*')
        })
    $unexpectedTriggerChildren = @($triggerChildren | Where-Object {
            @('Repetition', 'StartBoundary', 'Enabled') -cnotcontains $_.LocalName
        })
    $unexpectedRepetitionChildren = @($repetitionChildren | Where-Object {
            @('Interval', 'StopAtDurationEnd') -cnotcontains $_.LocalName
        })
    $stopAtDurationEndValid = ($stopAtDurationEnd.Count -eq 0)
    if ($stopAtDurationEnd.Count -eq 1) {
        $stopAtDurationEndValid = ([string]$stopAtDurationEnd[0].InnerText -ceq 'false')
    }
    $triggerEnabledValid = ($triggerEnabled.Count -eq 0)
    if ($triggerEnabled.Count -eq 1) {
        $triggerEnabledValid = ([string]$triggerEnabled[0].InnerText -ceq 'true')
    }
    $repetitionValid = (
        $triggers.Count -eq 1 -and $timeTriggers.Count -eq 1 -and $repetitions.Count -eq 1 -and
        $triggerChildren.Count -ge 2 -and $triggerChildren.Count -le 3 -and
        $repetitionChildren.Count -ge 1 -and $repetitionChildren.Count -le 2 -and
        $unexpectedTriggerChildren.Count -eq 0 -and
        $unexpectedRepetitionChildren.Count -eq 0 -and
        $intervals.Count -eq 1 -and ([string]$intervals[0].InnerText -ceq 'PT5M') -and
        $durations.Count -eq 0 -and $endBoundaries.Count -eq 0 -and
        $stopAtDurationEnd.Count -le 1 -and $stopAtDurationEndValid -and
        $startBoundaries.Count -eq 1 -and
        ([string]$startBoundaries[0].InnerText -ceq '2000-01-01T00:00:00') -and
        $triggerEnabled.Count -le 1 -and $triggerEnabledValid
    )
    if (-not $repetitionValid) {
        throw 'Scheduled watchdog repetition drift was detected.'
    }

    $settingsNodes = @($document.SelectNodes('/t:Task/t:Settings', $namespace))
    $enabledNodes = @($document.SelectNodes('/t:Task/t:Settings/t:Enabled', $namespace))
    $settingsEnabledValid = ($enabledNodes.Count -eq 0)
    if ($enabledNodes.Count -eq 1) {
        $settingsEnabledValid = ([string]$enabledNodes[0].InnerText -ceq 'true')
    }
    if ($settingsNodes.Count -ne 1 -or $enabledNodes.Count -gt 1 -or
        -not $settingsEnabledValid) {
        throw 'Scheduled watchdog enabled-state drift was detected.'
    }
    return $true
}

function Assert-AgentMemoryWatchdogRestorableTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)][string]$RunnerCommand,
        [Parameter(Mandatory = $true)][string]$SettingsDirectory,
        [Parameter(Mandatory = $true)][string]$SettingsStem,
        [Parameter(Mandatory = $true)][string]$CurrentSid
    )
    $document = ConvertFrom-AgentMemoryWatchdogTaskXml -Xml $Xml
    $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

    $actions = @($document.SelectNodes('/t:Task/t:Actions/*', $namespace))
    $commands = @($document.SelectNodes('/t:Task/t:Actions/t:Exec/t:Command', $namespace))
    $arguments = @($document.SelectNodes('/t:Task/t:Actions/t:Exec/t:Arguments', $namespace))
    if ($actions.Count -ne 1 -or $actions[0].LocalName -cne 'Exec' -or
        $commands.Count -ne 1 -or $arguments.Count -ne 1 -or
        -not [string]::Equals(
            [string]$commands[0].InnerText,
            $RunnerCommand,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'An existing task-name collision is not a restorable AgentMemory watchdog.'
    }
    $argumentText = [string]$arguments[0].InnerText
    if ($argumentText -notmatch '^"([^"\r\n]+)"$') {
        throw 'An existing task-name collision is not a restorable AgentMemory watchdog.'
    }
    $previousSettingsPath = $matches[1]
    if (-not [System.IO.Path]::IsPathRooted($previousSettingsPath)) {
        throw 'An existing task-name collision is not a restorable AgentMemory watchdog.'
    }
    $previousSettingsPath = [System.IO.Path]::GetFullPath($previousSettingsPath)
    $expectedDirectory = [System.IO.Path]::GetFullPath($SettingsDirectory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $actualDirectory = [System.IO.Path]::GetFullPath(
        (Split-Path -Parent $previousSettingsPath)
    ).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $expectedLeafPattern = '^' + [regex]::Escape($SettingsStem) +
        '(?:\.[0-9a-f]{32})?\.json$'
    if (-not [string]::Equals(
            $expectedDirectory,
            $actualDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or [System.IO.Path]::GetFileName($previousSettingsPath) -notmatch $expectedLeafPattern -or
        -not (Test-Path -LiteralPath $previousSettingsPath -PathType Leaf)) {
        throw 'An existing task-name collision is not a restorable AgentMemory watchdog.'
    }

    $principals = @($document.SelectNodes('/t:Task/t:Principals/t:Principal', $namespace))
    $userIds = @($document.SelectNodes('/t:Task/t:Principals/t:Principal/t:UserId', $namespace))
    $logonTypes = @($document.SelectNodes('/t:Task/t:Principals/t:Principal/t:LogonType', $namespace))
    $runLevels = @($document.SelectNodes('/t:Task/t:Principals/t:Principal/t:RunLevel', $namespace))
    $enabled = @($document.SelectNodes('/t:Task/t:Settings/t:Enabled', $namespace))
    $restorableRunLevel = ($runLevels.Count -eq 0)
    if ($runLevels.Count -eq 1) {
        $restorableRunLevel = ([string]$runLevels[0].InnerText -ceq 'LeastPrivilege')
    }
    $restorableEnabled = ($enabled.Count -eq 0)
    if ($enabled.Count -eq 1) {
        $restorableEnabled = ([string]$enabled[0].InnerText -ceq 'true')
    }
    if ($principals.Count -ne 1 -or $userIds.Count -ne 1 -or
        $logonTypes.Count -ne 1 -or $runLevels.Count -gt 1 -or
        [string]$userIds[0].InnerText -cne $CurrentSid -or
        [string]$logonTypes[0].InnerText -cne 'InteractiveToken' -or
        -not $restorableRunLevel -or $enabled.Count -gt 1 -or -not $restorableEnabled) {
        throw 'An existing task-name collision is not safely restorable without credentials.'
    }
    [void](Assert-AgentMemoryWatchdogTaskXml `
        -Xml $Xml -RunnerCommand $RunnerCommand -SettingsPath $previousSettingsPath `
        -CurrentSid $CurrentSid -IntervalMinutes 5)
    return $previousSettingsPath
}

function Get-AgentMemoryWatchdogCurrentSid {
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($sid -notmatch '^S-\d(?:-\d+)+$') { throw 'invalid SID' }
        return $sid
    } catch {
        throw 'The current Windows task principal could not be resolved.'
    }
}

function Invoke-AgentMemoryWatchdogSchtasks {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $executable = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw 'Windows Task Scheduler tooling is unavailable.'
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output }
}

function Test-AgentMemoryWatchdogTaskNotFoundException {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)
    return ([int]$Exception.HResult -eq -2147024894)
}

function Test-AgentMemoryWatchdogScheduledTaskExists {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $service = $null
    $folder = $null
    $task = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder('\')
        try {
            $task = $folder.GetTask($TaskName)
            return ($null -ne $task)
        } catch {
            # Schedule.Service projects ERROR_FILE_NOT_FOUND as either a
            # COMException or FileNotFoundException depending on the host
            # PowerShell/.NET runtime. The HRESULT is the stable boundary.
            if (Test-AgentMemoryWatchdogTaskNotFoundException -Exception $_.Exception) {
                return $false
            }
            throw
        }
    } catch {
        throw 'Scheduled watchdog task state could not be inspected.'
    } finally {
        foreach ($instance in @($task, $folder, $service)) {
            if ($null -ne $instance -and [System.Runtime.InteropServices.Marshal]::IsComObject($instance)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($instance)
            }
        }
    }
}

function Get-AgentMemoryWatchdogExistingTaskXml {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    if (-not (Test-AgentMemoryWatchdogScheduledTaskExists -TaskName $TaskName)) {
        return $null
    }
    $result = Invoke-AgentMemoryWatchdogSchtasks -Arguments @('/Query', '/TN', $TaskName, '/XML')
    if ($result.ExitCode -ne 0) {
        throw 'The existing watchdog task could not be exported.'
    }
    $xml = (@($result.Output) | ForEach-Object { [string]$_ }) -join "`r`n"
    if ([string]::IsNullOrWhiteSpace($xml)) {
        throw 'The existing watchdog task export was empty.'
    }
    return $xml
}

function Set-AgentMemoryWatchdogScheduledTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$CurrentSid
    )
    $service = $null
    $folder = $null
    $registeredTask = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder('\')
        $registeredTask = $folder.RegisterTask(
            $TaskName,
            $Xml,
            6,
            $CurrentSid,
            $null,
            3,
            $null
        )
        if ($null -eq $registeredTask) {
            throw 'Scheduled watchdog task registration failed.'
        }
    } catch {
        throw 'Scheduled watchdog task registration failed.'
    } finally {
        foreach ($instance in @($registeredTask, $folder, $service)) {
            if ($null -ne $instance -and [System.Runtime.InteropServices.Marshal]::IsComObject($instance)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($instance)
            }
        }
    }
}

function Remove-AgentMemoryWatchdogScheduledTask {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    if (-not (Test-AgentMemoryWatchdogScheduledTaskExists -TaskName $TaskName)) { return }
    $result = Invoke-AgentMemoryWatchdogSchtasks -Arguments @('/Delete', '/TN', $TaskName, '/F')
    if ($result.ExitCode -ne 0 -or
        (Test-AgentMemoryWatchdogScheduledTaskExists -TaskName $TaskName)) {
        throw 'Scheduled watchdog task deletion failed.'
    }
}

function Get-AgentMemoryWatchdogSecretBlobReference {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RunDirectory
    )
    try {
        if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf) -or
            (Get-Item -LiteralPath $SettingsPath).Length -gt 65536) {
            return $null
        }
        $settings = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
        $property = $settings.PSObject.Properties['SecretBlobPath']
        if ($null -eq $property -or -not ($property.Value -is [string]) -or
            -not [System.IO.Path]::IsPathRooted([string]$property.Value)) {
            return $null
        }
        $path = [System.IO.Path]::GetFullPath([string]$property.Value)
        if (-not (Test-AgentMemoryWatchdogPathWithin -Path $path -Root $RunDirectory)) {
            return $null
        }
        return $path
    } catch {
        return $null
    }
}

function Restore-AgentMemoryWatchdogFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [byte[]]$BackupBytes,
        [Parameter(Mandatory = $true)][bool]$PreviouslyExisted
    )
    if (-not $PreviouslyExisted) {
        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            Remove-Item -LiteralPath $TargetPath -Force
        }
        return
    }
    if ($null -eq $BackupBytes) {
        throw 'A watchdog transaction backup is unavailable.'
    }
    Write-AgentMemoryWatchdogAtomicBytes -Path $TargetPath -Bytes $BackupBytes
}

function Register-AgentMemoryWatchdog {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$DevToolsRoot,
        [string]$DataRoot,
        [string]$BaseUrl,
        [string]$Config,
        [string]$InstallRoot,
        [string]$NodeExecutable,
        [string]$IiiExecutable,
        [string]$EmbeddingProvider,
        [string]$LogDir,
        [string]$SelfHealScript,
        [string]$ServerScript,
        [string]$RunnerScript,
        [string]$SettingsPath,
        [string]$PowerShellExecutable,
        [string]$TaskName = 'AgentmemoryWatchdog',
        [int]$IntervalMinutes = 5
    )

    if ($IntervalMinutes -ne 5) {
        throw 'The scheduled watchdog cadence must be exactly five minutes.'
    }
    $root = $DevToolsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:DEVTOOLS_ROOT }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
    $root = [System.IO.Path]::GetFullPath($root)

    $url = $BaseUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = $env:AGENTMEMORY_URL }
    if ([string]::IsNullOrWhiteSpace($url)) { $url = 'http://localhost:3111' }
    $url = $url.TrimEnd('/')
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost', '127.0.0.1') -or
        $uri.AbsolutePath -ne '/' -or -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.Port -lt 1 -or $uri.Port -gt 5997) {
        throw 'The watchdog can persist only an explicit local agentmemory endpoint.'
    }
    $url = "http://127.0.0.1:$($uri.Port)"

    $dataPath = $DataRoot
    if ([string]::IsNullOrWhiteSpace($dataPath)) { $dataPath = $env:AGENTMEMORY_DATA_ROOT }
    $dataPath = Resolve-AgentMemoryWatchdogPath -Path $dataPath -Root $root -DefaultRelativePath 'data'
    $configPath = $Config
    if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = $env:AGENTMEMORY_CONFIG }
    $configPath = Resolve-AgentMemoryWatchdogPath -Path $configPath -Root $root -DefaultRelativePath 'agentmemory-iii.yaml'
    $packageRoot = $InstallRoot
    if ([string]::IsNullOrWhiteSpace($packageRoot)) { $packageRoot = $env:AGENTMEMORY_INSTALL_ROOT }
    $packageRoot = Resolve-AgentMemoryWatchdogPath `
        -Path $packageRoot -Root $root -DefaultRelativePath 'npm-global\agentmemory-runtime'
    $nodePath = $NodeExecutable
    if ([string]::IsNullOrWhiteSpace($nodePath)) { $nodePath = $env:NODE_EXE }
    $nodePath = Resolve-AgentMemoryWatchdogPath -Path $nodePath -Root $root -DefaultRelativePath 'node\node.exe'
    $iiiPath = $IiiExecutable
    if ([string]::IsNullOrWhiteSpace($iiiPath)) { $iiiPath = $env:AGENTMEMORY_III_EXE }
    $iiiPath = Resolve-AgentMemoryWatchdogPath -Path $iiiPath -Root $packageRoot -DefaultRelativePath 'iii.exe'
    $logs = $LogDir
    if ([string]::IsNullOrWhiteSpace($logs)) { $logs = $env:DEVTOOLS_LOG_DIR }
    $logs = Resolve-AgentMemoryWatchdogPath -Path $logs -Root $root -DefaultRelativePath 'logs'
    $selfHealPath = $SelfHealScript
    if ([string]::IsNullOrWhiteSpace($selfHealPath)) { $selfHealPath = $env:AGENTMEMORY_SELFHEAL_SCRIPT }
    $selfHealPath = Resolve-AgentMemoryWatchdogPath -Path $selfHealPath -Root $root -DefaultRelativePath 'agentmemory-selfheal.ps1'
    $serverPath = $ServerScript
    if ([string]::IsNullOrWhiteSpace($serverPath)) { $serverPath = $env:AGENTMEMORY_SERVER_SCRIPT }
    $serverPath = Resolve-AgentMemoryWatchdogPath -Path $serverPath -Root $root -DefaultRelativePath 'agentmemory-server.ps1'
    $runnerPath = Resolve-AgentMemoryWatchdogPath `
        -Path $RunnerScript -Root $root -DefaultRelativePath 'agentmemory-watchdog-run.cmd'
    $guardPath = Resolve-AgentMemoryWatchdogPath `
        -Path $null -Root $root -DefaultRelativePath 'agentmemory-host-guard.mjs'
    $settingsBase = Resolve-AgentMemoryWatchdogPath `
        -Path $SettingsPath -Root $logs -DefaultRelativePath 'agentmemory-watchdog.settings.json'

    if ([string]::IsNullOrWhiteSpace($TaskName) -or
        $TaskName -match '[\x00-\x1f\x7f\\/:*?"<>|]') {
        throw 'Scheduled task name is invalid.'
    }
    $taskHasher = [System.Security.Cryptography.SHA256]::Create()
    $taskNameBytes = $null
    $taskDigest = $null
    try {
        $taskNameBytes = [System.Text.Encoding]::UTF8.GetBytes($TaskName.ToLowerInvariant())
        $taskDigest = $taskHasher.ComputeHash($taskNameBytes)
        $taskKey = [System.BitConverter]::ToString($taskDigest).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $taskNameBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $taskDigest
        $taskHasher.Dispose()
    }
    $settingsDirectory = Split-Path -Parent $settingsBase
    $settingsStem = [System.IO.Path]::GetFileNameWithoutExtension($settingsBase) +
        ".port$($uri.Port).task$taskKey"
    $settingsFile = Join-Path $settingsDirectory ($settingsStem + '.json')
    $runDirectory = Join-Path $dataPath 'run'

    foreach ($requiredFile in @(
            $configPath, $nodePath, $iiiPath, $selfHealPath, $serverPath, $runnerPath, $guardPath,
            (Join-Path (Split-Path -Parent $runnerPath) 'agentmemory-watchdog-run.ps1'),
            (Join-Path (Split-Path -Parent $runnerPath) 'agentmemory-secret-store.ps1')
        )) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw 'A required watchdog dependency is missing.'
        }
    }

    $shell = $PowerShellExecutable
    if ([string]::IsNullOrWhiteSpace($shell)) { $shell = $env:DEVTOOLS_POWERSHELL }
    if ([string]::IsNullOrWhiteSpace($shell)) {
        $shell = Join-Path ([Environment]::GetFolderPath('System')) `
            'WindowsPowerShell\v1.0\powershell.exe'
    }
    if (-not [System.IO.Path]::IsPathRooted($shell)) {
        throw 'The watchdog PowerShell executable must be an absolute path.'
    }
    $shell = [System.IO.Path]::GetFullPath($shell)
    if ([System.IO.Path]::GetExtension($shell) -ine '.exe' -or
        -not (Test-Path -LiteralPath $shell -PathType Leaf)) {
        throw 'The watchdog PowerShell executable is unavailable.'
    }
    $embedding = $EmbeddingProvider
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = $env:AGENTMEMORY_EMBEDDING_PROVIDER }
    if ([string]::IsNullOrWhiteSpace($embedding)) { $embedding = 'local' }
    if ($embedding -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Embedding provider identifier is invalid.'
    }

    $secret = Get-AgentMemoryWatchdogRequiredSecret
    $currentSid = Get-AgentMemoryWatchdogCurrentSid
    [void](New-AgentMemoryWatchdogAction -RunnerCommand $runnerPath -SettingsPath $settingsFile)
    $taskXml = New-AgentMemoryWatchdogTaskXml `
        -RunnerCommand $runnerPath -SettingsPath $settingsFile `
        -CurrentSid $currentSid -IntervalMinutes $IntervalMinutes
    [void](Assert-AgentMemoryWatchdogTaskXml `
        -Xml $taskXml -RunnerCommand $runnerPath -SettingsPath $settingsFile `
        -CurrentSid $currentSid -IntervalMinutes $IntervalMinutes)

    if (-not $PSCmdlet.ShouldProcess(
            $TaskName,
            'persist a CurrentUser-protected secret and transactionally register the watchdog task'
        )) {
        $secret = $null
        return 0
    }

    $oldTaskXml = $null
    $oldBlobPath = $null
    $newBlobPath = $null
    $newBlobPreviouslyExisted = $false
    $settingsPreviouslyExisted = $false
    $settingsMutated = $false
    $taskMutationAttempted = $false
    $rollbackSucceeded = $false
    $registrationSucceeded = $false
    $blobBytes = $null
    $settingsBackupBytes = $null
    $transactionStage = 'prepare-run-directory'
    try {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $transactionStage = 'inspect-existing-task'
        $oldTaskXml = Get-AgentMemoryWatchdogExistingTaskXml -TaskName $TaskName
        if (-not [string]::IsNullOrWhiteSpace($oldTaskXml)) {
            [void](Assert-AgentMemoryWatchdogRestorableTaskXml `
                -Xml $oldTaskXml -RunnerCommand $runnerPath `
                -SettingsDirectory $settingsDirectory -SettingsStem $settingsStem `
                -CurrentSid $currentSid)
        }

        $transactionStage = 'inspect-existing-settings'
        $settingsPreviouslyExisted = Test-Path -LiteralPath $settingsFile -PathType Leaf
        if ($settingsPreviouslyExisted) {
            if ((Get-Item -LiteralPath $settingsFile).Length -gt 65536) {
                throw 'Existing watchdog settings exceed the transaction limit.'
            }
            $oldBlobPath = Get-AgentMemoryWatchdogSecretBlobReference `
                -SettingsPath $settingsFile -RunDirectory $runDirectory
            $settingsBackupBytes = [System.IO.File]::ReadAllBytes($settingsFile)
        }
        $transactionStage = 'protect-secret'
        $blobBytes = Protect-AgentMemoryWatchdogSecret -Secret $secret
        $ciphertextHash = Get-AgentMemoryWatchdogCiphertextSha256 -Bytes $blobBytes
        $newBlobPath = Join-Path $runDirectory (
            "agentmemory-watchdog.secret.task$taskKey.$ciphertextHash.dpapi"
        )
        $newBlobPreviouslyExisted = Test-Path -LiteralPath $newBlobPath -PathType Leaf
        $transactionStage = 'write-secret-blob'
        Write-AgentMemoryWatchdogAtomicBytes -Path $newBlobPath -Bytes $blobBytes

        $settings = [ordered]@{
            SchemaVersion = 1
            DevToolsRoot = $root
            DataRoot = $dataPath
            BaseUrl = $url
            Config = $configPath
            InstallRoot = $packageRoot
            NodeExecutable = $nodePath
            IiiExecutable = $iiiPath
            EmbeddingProvider = $embedding
            LogDir = $logs
            SelfHealScript = $selfHealPath
            ServerScript = $serverPath
            PowerShellExecutable = $shell
            SecretBlobPath = $newBlobPath
            SecretCiphertextSha256 = $ciphertextHash
        }
        $transactionStage = 'write-settings'
        Write-AgentMemoryWatchdogSettings -Path $settingsFile -Settings $settings
        $settingsMutated = $true

        $taskMutationAttempted = $true
        $transactionStage = 'register-task'
        Set-AgentMemoryWatchdogScheduledTask `
            -TaskName $TaskName -Xml $taskXml -RunDirectory $runDirectory `
            -CurrentSid $currentSid
        $transactionStage = 'verify-task'
        $registeredXml = Get-AgentMemoryWatchdogExistingTaskXml -TaskName $TaskName
        if ([string]::IsNullOrWhiteSpace($registeredXml)) {
            throw 'Scheduled watchdog postcondition was unavailable.'
        }
        [void](Assert-AgentMemoryWatchdogTaskXml `
            -Xml $registeredXml -RunnerCommand $runnerPath -SettingsPath $settingsFile `
            -CurrentSid $currentSid -IntervalMinutes $IntervalMinutes)
        $registrationSucceeded = $true
        $transactionStage = 'retire-old-blob'

        if (-not [string]::IsNullOrWhiteSpace($oldBlobPath) -and
            -not [string]::Equals($oldBlobPath, $newBlobPath, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-AgentMemoryWatchdogPathWithin -Path $oldBlobPath -Root $runDirectory) -and
            (Test-Path -LiteralPath $oldBlobPath -PathType Leaf)) {
            Remove-Item -LiteralPath $oldBlobPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $rollbackSucceeded = $true
        try {
            if ($settingsMutated) {
                Restore-AgentMemoryWatchdogFile `
                    -TargetPath $settingsFile -BackupBytes $settingsBackupBytes `
                    -PreviouslyExisted $settingsPreviouslyExisted
            }
        } catch {
            $rollbackSucceeded = $false
        }
        try {
            if ($taskMutationAttempted) {
                if (-not [string]::IsNullOrWhiteSpace($oldTaskXml)) {
                    Set-AgentMemoryWatchdogScheduledTask `
                        -TaskName $TaskName -Xml $oldTaskXml -RunDirectory $runDirectory `
                        -CurrentSid $currentSid
                    if ([string]::IsNullOrWhiteSpace(
                            (Get-AgentMemoryWatchdogExistingTaskXml -TaskName $TaskName)
                        )) {
                        throw 'restored task is unavailable'
                    }
                } else {
                    Remove-AgentMemoryWatchdogScheduledTask -TaskName $TaskName
                    if (-not [string]::IsNullOrWhiteSpace(
                            (Get-AgentMemoryWatchdogExistingTaskXml -TaskName $TaskName)
                        )) {
                        throw 'new task still exists'
                    }
                }
            }
        } catch {
            $rollbackSucceeded = $false
        }
        try {
            if (-not [string]::IsNullOrWhiteSpace($newBlobPath) -and
                -not $newBlobPreviouslyExisted -and
                (Test-Path -LiteralPath $newBlobPath -PathType Leaf)) {
                Remove-Item -LiteralPath $newBlobPath -Force
            }
        } catch {
            $rollbackSucceeded = $false
        }

        if ($rollbackSucceeded) {
            throw "Scheduled watchdog registration failed at stage '$transactionStage'; the previous state was restored."
        }
        throw "Scheduled watchdog registration failed at stage '$transactionStage' and previous state restoration was incomplete."
    } finally {
        Clear-AgentMemoryWatchdogBytes -Bytes $blobBytes
        Clear-AgentMemoryWatchdogBytes -Bytes $settingsBackupBytes
        $secret = $null
        $oldTaskXml = $null
    }

    Write-Output 'Scheduled AgentMemory watchdog registration completed.'
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Register-AgentMemoryWatchdog `
        -DevToolsRoot $DevToolsRoot `
        -DataRoot $DataRoot `
        -BaseUrl $BaseUrl `
        -Config $Config `
        -InstallRoot $InstallRoot `
        -NodeExecutable $NodeExecutable `
        -IiiExecutable $IiiExecutable `
        -EmbeddingProvider $EmbeddingProvider `
        -LogDir $LogDir `
        -SelfHealScript $SelfHealScript `
        -ServerScript $ServerScript `
        -RunnerScript $RunnerScript `
        -SettingsPath $SettingsPath `
        -PowerShellExecutable $PowerShellExecutable `
        -TaskName $TaskName `
        -IntervalMinutes $IntervalMinutes `
        -WhatIf:$WhatIfPreference | Write-Output
    exit 0
}
