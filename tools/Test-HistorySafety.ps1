param(
    [string]$Path = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PublicSafety.Common.ps1')

$root = (Resolve-Path -LiteralPath $Path).Path
Invoke-SafetyGitLines -Root $root -GitArguments @('rev-parse', '--is-inside-work-tree') | Out-Null
$findings = @(Invoke-HistorySafetyInspection -Root $root -RevisionArguments @('--all') -ScanAllRefNames)

if ($findings.Count -gt 0) {
    $findings | Select-Object -First 100
    throw 'History safety scan failed'
}

Write-Host 'History safety scan passed.' -ForegroundColor Green
