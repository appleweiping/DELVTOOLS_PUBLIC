param(
    [Parameter(Position = 0)][string]$RemoteName,
    [Parameter(Position = 1)][string]$RemoteLocation,
    [string]$Path,
    [switch]$SkipHistory,
    [switch]$ScanUntracked
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PublicSafety.Common.ps1')

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $PSScriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
Invoke-SafetyGitLines -Root $root -GitArguments @('rev-parse', '--is-inside-work-tree') | Out-Null
$findings = New-Object System.Collections.Generic.List[string]
$inputRedirected = $false
try { $inputRedirected = [Console]::IsInputRedirected } catch { $inputRedirected = $false }
$prePushInput = if ($inputRedirected) { [Console]::In.ReadToEnd() } else { $null }
$hookMode = $null -ne $prePushInput -and ($prePushInput.Length -gt 0 -or $RemoteName -or $RemoteLocation)

if ($hookMode) {
    foreach ($finding in (Get-SafetyRepositoryIntegrityFindings -Root $root)) { $findings.Add($finding) }
    foreach ($metadata in @(
        [pscustomobject]@{ Label = 'Git remote name'; Value = $RemoteName },
        [pscustomobject]@{ Label = 'Git remote location'; Value = $RemoteLocation }
    )) {
        if ($metadata.Value) {
            foreach ($finding in (Get-SafetyStringSecretFindings -Label $metadata.Label -Value $metadata.Value)) {
                $findings.Add("$($metadata.Label): $finding")
            }
        }
    }
    $formatResult = Invoke-SafetyGitLines -Root $root -GitArguments @('rev-parse', '--show-object-format')
    $objectLength = if ($formatResult.Lines.Count -eq 1 -and $formatResult.Lines[0] -ceq 'sha256') { 64 } else { 40 }
    $zeroObject = '0' * $objectLength
    $lineNumber = 0
    foreach ($rawLine in ($prePushInput -split "`r?`n")) {
        if (-not $rawLine) { continue }
        $lineNumber++
        if ($rawLine -notmatch '^(\S+)\s+([0-9a-fA-F]+)\s+(\S+)\s+([0-9a-fA-F]+)$') {
            $findings.Add("Malformed pre-push ref update at input line $lineNumber")
            continue
        }
        $localRef = $matches[1]; $localObject = $matches[2].ToLowerInvariant()
        $remoteRef = $matches[3]; $remoteObject = $matches[4].ToLowerInvariant()
        foreach ($refRecord in @(
            [pscustomobject]@{ Label = 'pre-push local ref'; Value = $localRef },
            [pscustomobject]@{ Label = 'pre-push remote ref'; Value = $remoteRef }
        )) {
            foreach ($finding in (Get-SafetyStringSecretFindings -Label $refRecord.Label -Value $refRecord.Value)) {
                $findings.Add("Git ref name: $finding")
            }
        }
        if ($localObject.Length -ne $objectLength -or $remoteObject.Length -ne $objectLength) {
            $findings.Add("Malformed pre-push object identifier at input line $lineNumber")
            continue
        }
        $remoteRefCheck = Invoke-SafetyGitLines -Root $root -GitArguments @('check-ref-format', $remoteRef) -AllowFailure
        if ($remoteRefCheck.ExitCode -ne 0) {
            $findings.Add("Malformed pre-push remote ref at input line $lineNumber")
            continue
        }
        if ($localObject -ceq $zeroObject) {
            if ($localRef -cne '(delete)') { $findings.Add("Delete update has an invalid local ref at input line $lineNumber") }
            continue
        }
        $localRefCheck = Invoke-SafetyGitLines -Root $root -GitArguments @('check-ref-format', $localRef) -AllowFailure
        if ($localRefCheck.ExitCode -ne 0) {
            $findings.Add("Malformed pre-push local ref at input line $lineNumber")
            continue
        }
        $localType = Invoke-SafetyGitLines -Root $root -GitArguments @('cat-file', '-t', $localObject) -AllowFailure
        if ($localType.ExitCode -ne 0 -or $localType.Lines.Count -ne 1 -or $localType.Lines[0] -cnotin @('commit', 'tag')) {
            $findings.Add("Pre-push object is missing or does not resolve from a commit/tag at input line $lineNumber")
            continue
        }
        if (-not $SkipHistory) {
            # The final tip manifest authorizes the complete history that the
            # remote ref will expose. A remote..local optimization would miss
            # removal of an existing tombstone or an old artifact/submodule pin.
            $revision = @($localObject)
            foreach ($finding in (Invoke-HistorySafetyInspection -Root $root -RevisionArguments $revision -TipObjects @($localObject) -PolicyTip $localObject)) {
                $findings.Add($finding)
            }
        }
    }
} else {
    $manifest = Get-PublicSurfaceManifest -Root $root -PreferIndex
    $entries = if ($ScanUntracked) { @(Get-SafetyWorkingEntries -Root $root -IncludeUntracked) } else { @(Get-SafetyIndexEntries -Root $root) }
    foreach ($finding in (Get-SafetyRepositoryIntegrityFindings -Root $root)) { $findings.Add($finding) }
    foreach ($finding in (Invoke-PublicSurfaceInspection -Root $root -Manifest $manifest -Entries $entries -CheckNestedRepositories)) {
        $findings.Add($finding)
    }
    if (-not $SkipHistory) {
        foreach ($finding in (Invoke-HistorySafetyInspection -Root $root -RevisionArguments @('--all') -ScanAllRefNames -SkipRepositoryChecks)) { $findings.Add($finding) }
    }
}

if ($findings.Count -gt 0) {
    $findings | Select-Object -First 100
    throw 'Pre-push safety gate failed'
}

Write-Host 'Pre-push safety gate passed.' -ForegroundColor Green
