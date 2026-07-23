[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DevToolsRoot,
    [string]$PendingRoot,
    [string]$IngestedRoot,
    [string]$ClientModule,
    [string]$AgentMemoryUrl,
    [int]$TimeoutMs,
    [string]$ResolvePrepared,
    [string]$BreakStaleLock,
    [string]$NodeExe
)

$ErrorActionPreference = 'Stop'

function Resolve-NodeExecutable {
    param(
        [string]$Requested,
        [string]$RuntimeRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) {
            throw "Configured Node executable was not found."
        }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DEVTOOLS_NODE_EXE)) {
        if (-not (Test-Path -LiteralPath $env:DEVTOOLS_NODE_EXE -PathType Leaf)) {
            throw "DEVTOOLS_NODE_EXE does not identify an existing file."
        }
        return (Resolve-Path -LiteralPath $env:DEVTOOLS_NODE_EXE).Path
    }

    $rootNode = Join-Path $RuntimeRoot 'node\node.exe'
    if (Test-Path -LiteralPath $rootNode -PathType Leaf) {
        return (Resolve-Path -LiteralPath $rootNode).Path
    }

    $command = Get-Command node.exe, node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Node.js was not found. Set -NodeExe or DEVTOOLS_NODE_EXE."
    }
    return $command.Source
}

function Invoke-LessonIngest {
    [CmdletBinding()]
    param(
        [switch]$Preview,
        [string]$RuntimeRoot,
        [string]$Pending,
        [string]$Ingested,
        [string]$Client,
        [string]$Url,
        [int]$Timeout,
        [string]$Resolution,
        [string]$BreakLock,
        [string]$Node,
        [System.Management.Automation.PSReference]$ExitCode
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($env:DEVTOOLS_ROOT)) {
            $RuntimeRoot = $env:DEVTOOLS_ROOT
        } else {
            $RuntimeRoot = Split-Path -Parent $PSScriptRoot
        }
    }
    $RuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)

    $nodePath = Resolve-NodeExecutable -Requested $Node -RuntimeRoot $RuntimeRoot
    $gate = Join-Path $PSScriptRoot 'ingest-lessons.mjs'
    if (-not (Test-Path -LiteralPath $gate -PathType Leaf)) {
        throw "The canonical lesson promotion gate is missing."
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add($gate)
    if ($Preview) { $arguments.Add('--dry-run') }
    if (-not [string]::IsNullOrWhiteSpace($Pending)) {
        $arguments.Add('--pending-root')
        $arguments.Add($Pending)
    }
    if (-not [string]::IsNullOrWhiteSpace($Ingested)) {
        $arguments.Add('--ingested-root')
        $arguments.Add($Ingested)
    }
    if (-not [string]::IsNullOrWhiteSpace($Client)) {
        $arguments.Add('--client')
        $arguments.Add($Client)
    }
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $arguments.Add('--agentmemory-url')
        $arguments.Add($Url)
    }
    if ($Timeout -gt 0) {
        $arguments.Add('--timeout-ms')
        $arguments.Add([string]$Timeout)
    }
    if (-not [string]::IsNullOrWhiteSpace($Resolution)) {
        $arguments.Add('--resolve-prepared')
        $arguments.Add($Resolution)
    }
    if (-not [string]::IsNullOrWhiteSpace($BreakLock)) {
        $arguments.Add('--break-stale-lock')
        $arguments.Add($BreakLock)
    }

    $previousRoot = $env:DEVTOOLS_ROOT
    try {
        $env:DEVTOOLS_ROOT = $RuntimeRoot
        & $nodePath @arguments
        $childExitCode = [int]$LASTEXITCODE
        if ($null -ne $ExitCode) {
            $ExitCode.Value = $childExitCode
        }
    } finally {
        $env:DEVTOOLS_ROOT = $previousRoot
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    Invoke-LessonIngest `
        -Preview:$DryRun `
        -RuntimeRoot $DevToolsRoot `
        -Pending $PendingRoot `
        -Ingested $IngestedRoot `
        -Client $ClientModule `
        -Url $AgentMemoryUrl `
        -Timeout $TimeoutMs `
        -Resolution $ResolvePrepared `
        -BreakLock $BreakStaleLock `
        -Node $NodeExe `
        -ExitCode ([ref]$exitCode)
    exit $exitCode
}
