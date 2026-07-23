param(
    [string]$Path = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PublicSafety.Common.ps1')

$root = (Resolve-Path -LiteralPath $Path).Path
Invoke-SafetyGitLines -Root $root -GitArguments @('rev-parse', '--is-inside-work-tree') | Out-Null
$manifest = Get-PublicSurfaceManifest -Root $root
$entries = @(Get-SafetyWorkingEntries -Root $root -IncludeUntracked)
$findings = @(Invoke-PublicSurfaceInspection -Root $root -Manifest $manifest -Entries $entries -PreferWorkTree -CheckNestedRepositories)

if ($findings.Count -gt 0) {
    $findings | Select-Object -First 100
    throw 'Strict public-safety scan failed'
}

Write-Host 'Strict public-safety scan passed.' -ForegroundColor Green
