Set-StrictMode -Version 2.0

function Get-SafetyProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-SafetyPropertyExists {
    param([object]$InputObject, [string]$Name)
    return ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name])
}

function Invoke-SafetyGitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$GitArguments,
        [switch]$AllowFailure
    )

    $previous = $ErrorActionPreference
    $previousNoReplace = $env:GIT_NO_REPLACE_OBJECTS
    $ErrorActionPreference = 'Continue'
    $env:GIT_NO_REPLACE_OBJECTS = '1'
    try {
        $output = @(& git -C $Root -c core.quotePath=false @GitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        if ($null -eq $previousNoReplace) { Remove-Item Env:GIT_NO_REPLACE_OBJECTS -ErrorAction SilentlyContinue }
        else { $env:GIT_NO_REPLACE_OBJECTS = $previousNoReplace }
    }
    $lines = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw 'Git safety inspection failed'
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function ConvertTo-SafetyCommandArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    # CommandLineToArgvW-compatible quoting. Backslashes immediately before a
    # quote (and at the end of a quoted argument) must be doubled.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-SafetyGitBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$GitArguments,
        [switch]$AllowFailure
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git.exe'
    $allArguments = @('-C', $Root, '-c', 'core.quotePath=false') + $GitArguments
    $startInfo.Arguments = (@($allArguments | ForEach-Object { ConvertTo-SafetyCommandArgument -Value ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Unable to start Git safety inspection' }
    try {
        $memory = New-Object System.IO.MemoryStream
        try {
            $process.StandardOutput.BaseStream.CopyTo($memory)
            $null = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if (-not $AllowFailure -and $process.ExitCode -ne 0) {
                throw 'Git safety inspection failed'
            }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $memory.ToArray() }
        } finally {
            $memory.Dispose()
        }
    } finally {
        $process.Dispose()
    }
}

function New-SafetyOrdinalMap {
    return New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
}

function New-SafetyOrdinalIgnoreCaseMap {
    return New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function ConvertTo-SafetyRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [string]::Equals($Path, $Path.Trim(), [System.StringComparison]::Ordinal) -or
        $Path.Contains('\') -or $Path.Contains('//') -or
        $Path.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $Path.EndsWith('/', [System.StringComparison]::Ordinal) -or
        $Path -match '^[A-Za-z]:' -or $Path -match '[\x00-\x1f\x7f]' -or
        -not [string]::Equals($Path, $Path.Normalize([System.Text.NormalizationForm]::FormC), [System.StringComparison]::Ordinal)) {
        throw 'Path is not an exact canonical repository-relative path'
    }
    foreach ($segment in @($Path -split '/')) {
        if (-not $segment -or $segment -in @('.', '..') -or $segment.EndsWith('.', [System.StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [System.StringComparison]::Ordinal) -or $segment.Contains(':')) {
            throw 'Path is not an exact canonical repository-relative path'
        }
        $stem = ($segment -split '\.', 2)[0]
        if ($stem -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
            throw 'Path uses a reserved cross-platform name'
        }
    }
    return $Path
}

function Get-SafetyBlobBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId
    )

    if ($ObjectId -notmatch '^[0-9a-fA-F]{40,64}$') {
        throw 'Invalid Git object identifier during safety inspection'
    }
    $result = Invoke-SafetyGitBytes -Root $Root -GitArguments @('cat-file', 'blob', $ObjectId)
    return $result.Bytes
}

function Get-SafetyObjectBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][ValidateSet('commit', 'tag')][string]$Type
    )
    if ($ObjectId -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'Invalid Git object identifier during safety inspection' }
    $result = Invoke-SafetyGitBytes -Root $Root -GitArguments @('cat-file', $Type, $ObjectId)
    return $result.Bytes
}

function ConvertFrom-SafetyNulRecords {
    param([byte[]]$Bytes)
    $records = New-Object System.Collections.Generic.List[string]
    $start = 0
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    for ($index = 0; $index -le $Bytes.Length; $index++) {
        if ($index -lt $Bytes.Length -and $Bytes[$index] -ne 0) { continue }
        if ($index -gt $start) {
            try { $records.Add($encoding.GetString($Bytes, $start, $index - $start)) }
            catch { throw 'Git returned a non-UTF-8 path during safety inspection' }
        }
        $start = $index + 1
    }
    return $records.ToArray()
}

function Get-SafetyBlobSize {
    param([string]$Root, [string]$ObjectId)
    $result = Invoke-SafetyGitLines -Root $Root -GitArguments @('cat-file', '-s', $ObjectId)
    $size = 0L
    if ($result.Lines.Count -ne 1 -or -not [long]::TryParse($result.Lines[0], [ref]$size)) {
        throw 'Unable to determine Git blob size during safety inspection'
    }
    return $size
}

function Get-SafetyIndexEntries {
    param([Parameter(Mandatory = $true)][string]$Root)

    $entries = New-Object System.Collections.Generic.List[object]
    $result = Invoke-SafetyGitBytes -Root $Root -GitArguments @('ls-files', '-s', '-z')
    foreach ($line in (ConvertFrom-SafetyNulRecords -Bytes $result.Bytes)) {
        if ($line -notmatch '(?s)^(\d{6}) ([0-9a-fA-F]{40,64}) (\d+)\t(.+)$') {
            throw 'Git returned an invalid index entry during safety inspection'
        }
        if ($matches[3] -ne '0') { throw 'Git index contains unresolved merge stages' }
        $relative = ConvertTo-SafetyRelativePath -Path $matches[4]
        $entries.Add([pscustomobject]@{
            Path = $relative
            Mode = $matches[1]
            ObjectId = $matches[2].ToLowerInvariant()
            Source = 'index'
        })
    }
    return $entries.ToArray()
}

function Get-SafetyTreeEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit
    )
    if ($Commit -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'Invalid commit identifier during safety inspection' }
    $entries = New-Object System.Collections.Generic.List[object]
    $result = Invoke-SafetyGitBytes -Root $Root -GitArguments @('ls-tree', '-r', '-z', '--full-tree', $Commit)
    foreach ($line in (ConvertFrom-SafetyNulRecords -Bytes $result.Bytes)) {
        if ($line -notmatch '(?s)^(\d{6}) (blob|commit) ([0-9a-fA-F]{40,64})\t(.+)$') {
            throw 'Git returned an invalid tree entry during safety inspection'
        }
        $relative = ConvertTo-SafetyRelativePath -Path $matches[4]
        $entries.Add([pscustomobject]@{
            Path = $relative; Mode = $matches[1]; ObjectId = $matches[3].ToLowerInvariant(); Source = 'tree'
        })
    }
    return $entries.ToArray()
}

function Get-SafetyWorkingEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeUntracked
    )

    $byPath = New-SafetyOrdinalMap
    foreach ($entry in (Get-SafetyIndexEntries -Root $Root)) {
        $byPath[$entry.Path] = $entry
    }
    if ($IncludeUntracked) {
        $result = Invoke-SafetyGitBytes -Root $Root -GitArguments @('ls-files', '--others', '--exclude-standard', '-z')
        foreach ($line in (ConvertFrom-SafetyNulRecords -Bytes $result.Bytes)) {
            if (-not $line) { continue }
            $relative = ConvertTo-SafetyRelativePath -Path $line
            if (-not $byPath.ContainsKey($relative)) {
                $byPath[$relative] = [pscustomobject]@{
                    Path = $relative
                    Mode = '100644'
                    ObjectId = $null
                    Source = 'worktree'
                }
            }
        }
    }
    return @($byPath.Values | Sort-Object Path)
}

function Get-SafetyEntryBytes {
    param(
        [string]$Root,
        [object]$Entry,
        [switch]$PreferWorkTree
    )

    $full = Join-Path $Root ($Entry.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (($PreferWorkTree -or $Entry.Source -eq 'worktree') -and (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [System.IO.File]::ReadAllBytes($full)
    }
    if ($Entry.Mode -eq '160000') { return $null }
    if ($Entry.ObjectId) { return Get-SafetyBlobBytes -Root $Root -ObjectId $Entry.ObjectId }
    return $null
}

function Get-SafetyEntrySize {
    param(
        [string]$Root,
        [object]$Entry,
        [switch]$PreferWorkTree
    )

    $full = Join-Path $Root ($Entry.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (($PreferWorkTree -or $Entry.Source -eq 'worktree') -and (Test-Path -LiteralPath $full -PathType Leaf)) {
        return (Get-Item -LiteralPath $full).Length
    }
    if ($Entry.Mode -eq '160000') { return 0L }
    if ($Entry.ObjectId) { return Get-SafetyBlobSize -Root $Root -ObjectId $Entry.ObjectId }
    return 0L
}

function Get-SafetySha256FromBytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SafetyStringFingerprint {
    param([string]$Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $hash = Get-SafetySha256FromBytes -Bytes $encoding.GetBytes($Value)
    return $hash.Substring(0, 12)
}

function Get-SafetyRedactedLabel {
    param([string]$Kind, [string]$Value)
    $fingerprint = Get-SafetyStringFingerprint -Value ([string]$Value)
    return "[$Kind sha256:$fingerprint length:$(([string]$Value).Length)]"
}

function ConvertFrom-SafetyUtf8 {
    param([byte[]]$Bytes)
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        return $encoding.GetString($Bytes)
    } catch {
        return $null
    }
}

function ConvertFrom-SafetyManifestBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [string]$Source = 'public-surface.json')
    $json = ConvertFrom-SafetyUtf8 -Bytes $Bytes
    if ($null -eq $json) { throw "$Source is not UTF-8 text" }
    try { $manifest = $json | ConvertFrom-Json }
    catch { throw "$Source is not valid JSON" }
    if ($null -eq $manifest -or $manifest.schemaVersion -ne 1) {
        throw "$Source has an unsupported schemaVersion"
    }
    return $manifest
}

function Get-PublicSurfaceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$PreferIndex
    )

    $path = Join-Path $Root 'public-surface.json'
    if ($PreferIndex) {
        $indexEntry = @(Get-SafetyIndexEntries -Root $Root | Where-Object { $_.Path -ceq 'public-surface.json' } | Select-Object -First 1)
        if ($indexEntry.Count -eq 1) {
            $bytes = Get-SafetyEntryBytes -Root $Root -Entry $indexEntry[0]
            return ConvertFrom-SafetyManifestBytes -Bytes $bytes -Source 'Indexed public-surface.json'
        }
        throw 'Indexed public-surface.json is missing or staged for deletion'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Missing required public-surface.json manifest'
    }
    return ConvertFrom-SafetyManifestBytes -Bytes ([System.IO.File]::ReadAllBytes($path)) -Source 'public-surface.json'
}

function Get-PublicSurfaceManifestFromTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )
    $matches = @($Entries | Where-Object { $_.Path -ceq 'public-surface.json' })
    if ($matches.Count -ne 1 -or $matches[0].Mode -notin @('100644', '100755')) {
        throw 'Reachable tree is missing exactly one regular public-surface.json'
    }
    return ConvertFrom-SafetyManifestBytes -Bytes (Get-SafetyEntryBytes -Root $Root -Entry $matches[0]) -Source 'Tree public-surface.json'
}

function Get-ManifestValidationFindings {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $findings = New-Object System.Collections.Generic.List[string]
    $requiredProperties = @('allowedRootFiles', 'allowedTrees', 'maxBlobBytes', 'artifactAllowlist', 'submodules',
        'localOnlyTrees', 'historicalAllowedFiles', 'historicalArtifacts', 'historicalSubmodules', 'projectLicense', 'archivePolicy')
    if (@($requiredProperties | Where-Object { -not (Test-SafetyPropertyExists -InputObject $Manifest -Name $_) }).Count -gt 0 -or
        $null -eq $Manifest.allowedRootFiles -or $null -eq $Manifest.maxBlobBytes -or $null -eq $Manifest.projectLicense) {
        $findings.Add('Manifest is missing required policy fields')
        return $findings.ToArray()
    }
    if ([string](Get-SafetyProperty -InputObject $Manifest -Name 'archivePolicy') -cne 'deny') {
        $findings.Add('Manifest archivePolicy must be exactly deny')
    }
    $surfacePaths = New-SafetyOrdinalMap
    $surfaceCollisionPaths = New-SafetyOrdinalIgnoreCaseMap
    foreach ($rootFile in @($Manifest.allowedRootFiles)) {
        try { $normalized = ConvertTo-SafetyRelativePath -Path ([string]$rootFile) }
        catch { $findings.Add('Manifest contains a non-canonical root-file allowlist entry'); continue }
        if ($normalized -match '/') { $findings.Add('Root-file allowlist entry is nested') }
        if ($surfacePaths.ContainsKey($normalized)) { $findings.Add('Duplicate public surface entry') }
        elseif ($surfaceCollisionPaths.ContainsKey($normalized)) { $findings.Add('Manifest contains case-colliding public surface paths') }
        else { [void]$surfacePaths.Add($normalized, $true); [void]$surfaceCollisionPaths.Add($normalized, $normalized) }
    }
    $allowedFiles = Get-SafetyProperty -InputObject $Manifest -Name 'allowedFiles'
    if ($null -ne $allowedFiles) {
        foreach ($allowedFile in @($allowedFiles)) {
            try { $normalized = ConvertTo-SafetyRelativePath -Path ([string]$allowedFile) }
            catch { $findings.Add('Manifest contains a non-canonical file allowlist entry'); continue }
            if ($surfacePaths.ContainsKey($normalized)) { $findings.Add('Duplicate public surface entry') }
            elseif ($surfaceCollisionPaths.ContainsKey($normalized)) { $findings.Add('Manifest contains case-colliding public surface paths') }
            else { [void]$surfacePaths.Add($normalized, $true); [void]$surfaceCollisionPaths.Add($normalized, $normalized) }
        }
    }
    $treePaths = New-SafetyOrdinalMap
    $treeCollisionPaths = New-SafetyOrdinalIgnoreCaseMap
    foreach ($tree in @($Manifest.allowedTrees)) {
        try { $treePath = ConvertTo-SafetyRelativePath -Path ([string]$tree.path) }
        catch { $findings.Add('Manifest contains a non-canonical allowed-tree path'); continue }
        if ($treePaths.ContainsKey($treePath)) { $findings.Add('Duplicate allowed-tree path') }
        elseif ($treeCollisionPaths.ContainsKey($treePath) -or $surfaceCollisionPaths.ContainsKey($treePath)) {
            $findings.Add('Manifest contains case-colliding public surface paths')
        } else { [void]$treePaths.Add($treePath, $true); [void]$treeCollisionPaths.Add($treePath, $treePath) }
        $treeDepth = 0
        if (-not [int]::TryParse([string]$tree.maxDepth, [ref]$treeDepth) -or $treeDepth -lt 1 -or @($tree.extensions).Count -eq 0) {
            $findings.Add('Allowed-tree policy is incomplete')
        }
        foreach ($extension in @($tree.extensions)) {
            if ([string]$extension -notmatch '^\.[A-Za-z0-9]+$') { $findings.Add('Unsafe allowed-tree extension') }
        }
    }
    $localOnlyNames = New-SafetyOrdinalMap
    $localCollisionNames = New-SafetyOrdinalIgnoreCaseMap
    foreach ($localTree in @($Manifest.localOnlyTrees)) {
        $localName = $null
        try { $localName = ConvertTo-SafetyRelativePath -Path ([string]$localTree) }
        catch { $findings.Add('Manifest contains a non-canonical local-only tree'); continue }
        if ($localName -match '/' -or $localName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $findings.Add('Manifest contains an unsafe local-only tree')
            continue
        }
        if ($localOnlyNames.ContainsKey($localName)) {
            $findings.Add('Duplicate local-only tree')
            continue
        }
        if ($localCollisionNames.ContainsKey($localName)) {
            $findings.Add('Manifest contains case-colliding local-only trees')
            continue
        }
        [void]$localOnlyNames.Add($localName, $true)
        [void]$localCollisionNames.Add($localName, $localName)
        $overlap = $false
        foreach ($publicPath in $surfacePaths.Keys) {
            if ($publicPath -ceq $localName -or $publicPath.StartsWith($localName + '/', [System.StringComparison]::Ordinal)) {
                $overlap = $true
                break
            }
        }
        if (-not $overlap) {
            foreach ($tree in @($Manifest.allowedTrees)) {
                try { $publicTree = ConvertTo-SafetyRelativePath -Path ([string]$tree.path) }
                catch { continue }
                if ($publicTree -ceq $localName -or $publicTree.StartsWith($localName + '/', [System.StringComparison]::Ordinal) -or
                    $localName.StartsWith($publicTree + '/', [System.StringComparison]::Ordinal)) {
                    $overlap = $true
                    break
                }
            }
        }
        if (-not $overlap) {
            foreach ($submodule in @($Manifest.submodules)) {
                $submodulePath = [string](Get-SafetyProperty -InputObject $submodule -Name 'path')
                if ($submodulePath -ceq $localName -or $submodulePath.StartsWith($localName + '/', [System.StringComparison]::Ordinal)) {
                    $overlap = $true
                    break
                }
            }
        }
        if ($overlap) { $findings.Add('Local-only tree overlaps public surface') }
    }
    $blockedExceptions = Get-SafetyProperty -InputObject $Manifest -Name 'blockedPathAllowlist'
    if ($null -ne $blockedExceptions -and @($blockedExceptions).Count -gt 0) {
        $findings.Add('blockedPathAllowlist must remain empty; private-state paths cannot be excepted')
    }
    $maxBlob = 0L
    if (-not [long]::TryParse([string]$Manifest.maxBlobBytes, [ref]$maxBlob) -or $maxBlob -lt 1) {
        $findings.Add('Manifest maxBlobBytes must be a positive integer')
    }
    $maxAllowed = 0L
    $configuredMaxAllowed = Get-SafetyProperty -InputObject $Manifest -Name 'maxAllowlistedArtifactBytes'
    if ($null -eq $configuredMaxAllowed) {
        $maxAllowed = 16MB
    } elseif (-not [long]::TryParse([string]$configuredMaxAllowed, [ref]$maxAllowed) -or $maxAllowed -lt $maxBlob -or $maxAllowed -gt 16MB) {
        $findings.Add('Manifest maxAllowlistedArtifactBytes must be at least maxBlobBytes and no more than 16 MiB')
    }
    $knownKinds = @('binary', 'large', 'lfs', 'symlink')
    $artifactPaths = New-SafetyOrdinalMap
    $artifactCollisionPaths = New-SafetyOrdinalIgnoreCaseMap
    foreach ($artifact in @($Manifest.artifactAllowlist)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$artifact.path) }
        catch { $findings.Add('Artifact provenance contains a non-canonical path'); continue }
        if ($artifactPaths.ContainsKey($path)) {
            $findings.Add('Duplicate artifact provenance entry')
        }
        elseif ($artifactCollisionPaths.ContainsKey($path)) { $findings.Add('Artifact provenance contains case-colliding paths') }
        else { [void]$artifactPaths.Add($path, $true); [void]$artifactCollisionPaths.Add($path, $path) }
        $kinds = @(Get-SafetyProperty -InputObject $artifact -Name 'kinds')
        if (@($kinds) -contains 'archive') { $findings.Add('Archives are forbidden by archivePolicy=deny') }
        if ($kinds.Count -eq 0 -or @($kinds | Where-Object { $knownKinds -notcontains [string]$_ }).Count -gt 0 -or
            [string](Get-SafetyProperty -InputObject $artifact -Name 'sha256') -notmatch '^[0-9a-fA-F]{64}$' -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $artifact -Name 'source')) -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $artifact -Name 'license'))) {
            $findings.Add('Artifact provenance is incomplete')
        }
    }
    $historicalFilePaths = New-SafetyOrdinalMap
    $historicalFileCollisions = New-SafetyOrdinalIgnoreCaseMap
    foreach ($historicalFile in @($Manifest.historicalAllowedFiles)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$historicalFile) }
        catch { $findings.Add('Historical file tombstone contains a non-canonical path'); continue }
        if ($historicalFilePaths.ContainsKey($path)) { $findings.Add('Duplicate historical file tombstone') }
        elseif ($historicalFileCollisions.ContainsKey($path)) { $findings.Add('Historical file tombstones contain case-colliding paths') }
        else { [void]$historicalFilePaths.Add($path, $true); [void]$historicalFileCollisions.Add($path, $path) }
        if (Test-SafetyPathBlocked -Relative $path -Manifest $Manifest) {
            $findings.Add('Historical file tombstone targets a blocked private-state path')
        }
    }
    $historicalArtifactKeys = New-SafetyOrdinalMap
    $historicalArtifactPathCollisions = New-SafetyOrdinalIgnoreCaseMap
    foreach ($artifact in @($Manifest.historicalArtifacts)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$artifact.path) }
        catch { $findings.Add('Historical artifact provenance contains a non-canonical path'); continue }
        $sha = [string](Get-SafetyProperty -InputObject $artifact -Name 'sha256')
        $key = $path + "`n" + $sha.ToLowerInvariant()
        if ($historicalArtifactKeys.ContainsKey($key)) { $findings.Add('Duplicate historical artifact provenance entry') }
        else { [void]$historicalArtifactKeys.Add($key, $true) }
        if ($historicalArtifactPathCollisions.ContainsKey($path) -and
            [string]$historicalArtifactPathCollisions[$path] -cne $path) { $findings.Add('Historical artifact provenance contains case-colliding paths') }
        elseif (-not $historicalArtifactPathCollisions.ContainsKey($path)) { [void]$historicalArtifactPathCollisions.Add($path, $path) }
        $kinds = @(Get-SafetyProperty -InputObject $artifact -Name 'kinds')
        if (@($kinds) -contains 'archive') { $findings.Add('Archives are forbidden in historical artifact provenance') }
        if ($kinds.Count -eq 0 -or @($kinds | Where-Object { $knownKinds -notcontains [string]$_ }).Count -gt 0 -or
            $sha -notmatch '^[0-9a-fA-F]{64}$' -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $artifact -Name 'source')) -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $artifact -Name 'license'))) {
            $findings.Add('Historical artifact provenance is incomplete')
        }
    }
    $submodulePaths = New-SafetyOrdinalMap
    $submoduleCollisionPaths = New-SafetyOrdinalIgnoreCaseMap
    foreach ($submodule in @($Manifest.submodules)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$submodule.path) }
        catch { $findings.Add('Submodule provenance contains a non-canonical path'); continue }
        if ($submodulePaths.ContainsKey($path)) {
            $findings.Add('Duplicate submodule provenance entry')
        }
        elseif ($submoduleCollisionPaths.ContainsKey($path)) { $findings.Add('Submodule provenance contains case-colliding paths') }
        else { [void]$submodulePaths.Add($path, $true); [void]$submoduleCollisionPaths.Add($path, $path) }
        if ([string](Get-SafetyProperty -InputObject $submodule -Name 'url') -notmatch '^https://[^\s]+$' -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $submodule -Name 'ref')) -or
            [string](Get-SafetyProperty -InputObject $submodule -Name 'commit') -notmatch '^[0-9a-fA-F]{40,64}$' -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $submodule -Name 'license')) -or
            [string](Get-SafetyProperty -InputObject $submodule -Name 'licenseSource') -notmatch '^https://[^\s]+$') {
            $findings.Add('Submodule provenance is incomplete')
        }
    }
    $historicalSubmoduleKeys = New-SafetyOrdinalMap
    foreach ($submodule in @($Manifest.historicalSubmodules)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$submodule.path) }
        catch { $findings.Add('Historical submodule provenance contains a non-canonical path'); continue }
        $commit = [string](Get-SafetyProperty -InputObject $submodule -Name 'commit')
        $key = $path + "`n" + $commit.ToLowerInvariant()
        if ($historicalSubmoduleKeys.ContainsKey($key)) { $findings.Add('Duplicate historical submodule provenance entry') }
        else { [void]$historicalSubmoduleKeys.Add($key, $true) }
        if ([string](Get-SafetyProperty -InputObject $submodule -Name 'url') -notmatch '^https://[^\s]+$' -or
            $commit -notmatch '^[0-9a-fA-F]{40,64}$' -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $submodule -Name 'ref')) -or
            [string]::IsNullOrWhiteSpace([string](Get-SafetyProperty -InputObject $submodule -Name 'license')) -or
            [string](Get-SafetyProperty -InputObject $submodule -Name 'licenseSource') -notmatch '^https://[^\s]+$') {
            $findings.Add('Historical submodule provenance is incomplete')
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.projectLicense.path) -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.projectLicense.spdx)) {
        $findings.Add('Project license policy is incomplete')
    }
    return $findings.ToArray()
}

function Get-SafetyArtifactMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($artifact in @($Manifest.artifactAllowlist)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$artifact.path) }
        catch { continue }
        if (-not $map.ContainsKey($path)) { [void]$map.Add($path, $artifact) }
    }
    return $map
}

function Get-SafetySubmoduleMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($submodule in @($Manifest.submodules)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$submodule.path) }
        catch { continue }
        if (-not $map.ContainsKey($path)) { [void]$map.Add($path, $submodule) }
    }
    return $map
}

function Get-SafetyLocalOnlyMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($localTree in @($Manifest.localOnlyTrees)) {
        try { $localName = ConvertTo-SafetyRelativePath -Path ([string]$localTree) }
        catch { continue }
        if ($localName -notmatch '/' -and $localName -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            if (-not $map.ContainsKey($localName)) { [void]$map.Add($localName, $true) }
        }
    }
    return $map
}

function Get-SafetyGitLocalSurfaceOverride {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $map = New-SafetyOrdinalMap
    $findings = New-Object System.Collections.Generic.List[string]
    $pathResult = Invoke-SafetyGitLines `
        -Root $Root `
        -GitArguments @('rev-parse', '--git-path', 'info/devtools-local-surface.json') `
        -AllowFailure
    if ($pathResult.ExitCode -ne 0 -or $pathResult.Lines.Count -ne 1) {
        $findings.Add('Git-local surface override path cannot be resolved')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    $overridePath = [string]$pathResult.Lines[0]
    if (-not [System.IO.Path]::IsPathRooted($overridePath)) {
        $overridePath = Join-Path $Root $overridePath
    }
    try { $overridePath = [System.IO.Path]::GetFullPath($overridePath) }
    catch {
        $findings.Add('Git-local surface override path is invalid')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    if (-not (Test-Path -LiteralPath $overridePath)) {
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }

    try { $item = Get-Item -Force -LiteralPath $overridePath -ErrorAction Stop }
    catch {
        $findings.Add('Git-local surface override cannot be inspected')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    if ($item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt 65536) {
        $findings.Add('Git-local surface override must be a small ordinary file')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }

    try { $bytes = [System.IO.File]::ReadAllBytes($overridePath) }
    catch {
        $findings.Add('Git-local surface override cannot be read')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    $text = ConvertFrom-SafetyUtf8 -Bytes $bytes
    if ($null -eq $text) {
        $findings.Add('Git-local surface override must be strict UTF-8')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    try { $document = $text | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $findings.Add('Git-local surface override is not valid JSON')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    if ($null -eq $document -or $document -is [System.Array]) {
        $findings.Add('Git-local surface override root must be an object')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    $properties = @($document.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
    $propertyNames = @($properties | ForEach-Object { [string]$_.Name })
    if ($propertyNames.Count -ne 2 -or
        $propertyNames -notcontains 'schemaVersion' -or
        $propertyNames -notcontains 'localOnlyTrees') {
        $findings.Add('Git-local surface override has an unsupported schema')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }
    $schemaVersion = $document.PSObject.Properties['schemaVersion'].Value
    $localValues = $document.PSObject.Properties['localOnlyTrees'].Value
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or
        [long]$schemaVersion -ne 1 -or
        $localValues -isnot [System.Array] -or
        @($localValues).Count -gt 256) {
        $findings.Add('Git-local surface override has an unsupported schema')
        return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
    }

    $publicRoots = New-SafetyOrdinalIgnoreCaseMap
    foreach ($candidate in @((Get-SafetyProperty -InputObject $Manifest -Name 'allowedRootFiles' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'allowedFiles' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'historicalAllowedFiles' -Default @()))) {
        try { $canonical = ConvertTo-SafetyRelativePath -Path ([string]$candidate) }
        catch { continue }
        $top = @($canonical -split '/')[0]
        if (-not $publicRoots.ContainsKey($top)) { [void]$publicRoots.Add($top, $true) }
    }
    foreach ($candidateObject in @((Get-SafetyProperty -InputObject $Manifest -Name 'allowedTrees' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'submodules' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'historicalArtifacts' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'historicalSubmodules' -Default @())) +
        @((Get-SafetyProperty -InputObject $Manifest -Name 'artifactAllowlist' -Default @()))) {
        $candidate = Get-SafetyProperty -InputObject $candidateObject -Name 'path'
        try { $canonical = ConvertTo-SafetyRelativePath -Path ([string]$candidate) }
        catch { continue }
        $top = @($canonical -split '/')[0]
        if (-not $publicRoots.ContainsKey($top)) { [void]$publicRoots.Add($top, $true) }
    }
    foreach ($candidate in @((Get-SafetyProperty -InputObject $Manifest -Name 'localOnlyTrees' -Default @()))) {
        try { $canonical = ConvertTo-SafetyRelativePath -Path ([string]$candidate) }
        catch { continue }
        $top = @($canonical -split '/')[0]
        if (-not $publicRoots.ContainsKey($top)) { [void]$publicRoots.Add($top, $true) }
    }

    $collisions = New-SafetyOrdinalIgnoreCaseMap
    foreach ($value in @($localValues)) {
        if ($value -isnot [string]) {
            $findings.Add('Git-local surface override contains a non-string tree')
            continue
        }
        try { $localName = ConvertTo-SafetyRelativePath -Path ([string]$value) }
        catch {
            $findings.Add('Git-local surface override contains a non-canonical tree')
            continue
        }
        if ($localName -match '/' -or
            $localName -match '[<>:"/\\|?*]' -or
            $localName -match '^[#!]' -or
            $localName -ieq '.git') {
            $findings.Add('Git-local surface override contains an unsafe tree')
            continue
        }
        if ($map.ContainsKey($localName)) {
            $findings.Add('Git-local surface override contains a duplicate tree')
            continue
        }
        if ($collisions.ContainsKey($localName)) {
            $findings.Add('Git-local surface override contains case-colliding trees')
            continue
        }
        if ($publicRoots.ContainsKey($localName)) {
            $findings.Add('Git-local surface override overlaps the public or manifest-declared surface')
            continue
        }
        $ignored = Invoke-SafetyGitLines `
            -Root $Root `
            -GitArguments @('check-ignore', '--no-index', '-q', '--', ($localName + '/')) `
            -AllowFailure
        if ($ignored.ExitCode -ne 0) {
            $findings.Add('Git-local surface override tree is not ignored by Git')
            continue
        }
        [void]$map.Add($localName, $true)
        [void]$collisions.Add($localName, $true)
    }
    return [pscustomobject]@{ Map=$map; Findings=$findings.ToArray() }
}

function Get-SafetyHistoricalFileMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($value in @($Manifest.historicalAllowedFiles)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$value) }
        catch { continue }
        if (-not $map.ContainsKey($path)) { [void]$map.Add($path, $true) }
    }
    return $map
}

function Get-SafetyHistoricalArtifactMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($artifact in @($Manifest.historicalArtifacts)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$artifact.path) }
        catch { continue }
        $sha = [string](Get-SafetyProperty -InputObject $artifact -Name 'sha256')
        if ($sha -match '^[0-9a-fA-F]{64}$') {
            $key = $path + "`n" + $sha.ToLowerInvariant()
            if (-not $map.ContainsKey($key)) { [void]$map.Add($key, $artifact) }
        }
    }
    return $map
}

function Get-SafetyHistoricalSubmoduleMap {
    param([object]$Manifest)
    $map = New-SafetyOrdinalMap
    foreach ($submodule in @($Manifest.historicalSubmodules)) {
        try { $path = ConvertTo-SafetyRelativePath -Path ([string]$submodule.path) }
        catch { continue }
        $commit = [string](Get-SafetyProperty -InputObject $submodule -Name 'commit')
        if ($commit -match '^[0-9a-fA-F]{40,64}$') {
            $key = $path + "`n" + $commit.ToLowerInvariant()
            if (-not $map.ContainsKey($key)) { [void]$map.Add($key, $submodule) }
        }
    }
    return $map
}

function Test-SafetyArtifactProvenanceMatches {
    param([object]$Candidate, [object]$Historical, [string[]]$RequiredKinds)
    if ($null -eq $Candidate) { return $false }
    foreach ($kind in $RequiredKinds) {
        if (@($Candidate.kinds) -cnotcontains $kind) { return $false }
    }
    if ($null -ne $Historical) {
        if (-not [string]::Equals([string]$Candidate.source, [string]$Historical.source, [System.StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$Candidate.license, [string]$Historical.license, [System.StringComparison]::Ordinal)) { return $false }
        $candidateKinds = @($Candidate.kinds | Sort-Object)
        $historicalKinds = @($Historical.kinds | Sort-Object)
        if (($candidateKinds -join "`n") -cne ($historicalKinds -join "`n")) { return $false }
    }
    return $true
}

function Test-SafetySubmoduleProvenanceMatches {
    param([object]$Candidate, [object]$Historical)
    if ($null -eq $Candidate -or $null -eq $Historical) { return $false }
    foreach ($field in @('path', 'url', 'ref', 'commit', 'license', 'licenseSource')) {
        $comparison = if ($field -ceq 'commit') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not [string]::Equals(
            [string](Get-SafetyProperty -InputObject $Candidate -Name $field),
            [string](Get-SafetyProperty -InputObject $Historical -Name $field),
            $comparison)) { return $false }
    }
    return $true
}

function Test-SafetyEntryAuthorizedByPublicationManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [object]$HistoricalManifest
    )
    $relative = [string]$Entry.Path
    if (Test-SafetyPathBlocked -Relative $relative -Manifest $Manifest) { return $false }
    if (Get-SafetyLocalOnlyRoot -Relative $relative -LocalOnlyTrees (Get-SafetyLocalOnlyMap -Manifest $Manifest)) { return $false }
    if ($Entry.Mode -ceq '160000') {
        $historicalPolicy = $null
        if ($null -ne $HistoricalManifest) {
            $historicalPolicies = Get-SafetySubmoduleMap -Manifest $HistoricalManifest
            if ($historicalPolicies.ContainsKey($relative)) { $historicalPolicy = $historicalPolicies[$relative] }
        }
        if ($null -eq $historicalPolicy) { return $false }
        $current = Get-SafetySubmoduleMap -Manifest $Manifest
        if ($current.ContainsKey($relative) -and [string]$current[$relative].commit -ceq [string]$Entry.ObjectId -and
            (Test-SafetySubmoduleProvenanceMatches -Candidate $current[$relative] -Historical $historicalPolicy)) { return $true }
        $historicalMap = Get-SafetyHistoricalSubmoduleMap -Manifest $Manifest
        $key = $relative + "`n" + ([string]$Entry.ObjectId).ToLowerInvariant()
        return ($historicalMap.ContainsKey($key) -and
            (Test-SafetySubmoduleProvenanceMatches -Candidate $historicalMap[$key] -Historical $historicalPolicy))
    }
    $bytes = Get-SafetyEntryBytes -Root $Root -Entry $Entry
    if ($null -eq $bytes) { return $false }
    $kind = Get-SafetyPrimaryKind -Relative $relative -Mode ([string]$Entry.Mode) -Bytes $bytes
    if ($kind -ceq 'archive') { return $false }
    $sha = Get-SafetySha256FromBytes -Bytes $bytes
    $needsArtifactProvenance = ($null -ne $kind -or $bytes.Length -gt [long]$Manifest.maxBlobBytes)
    if ($needsArtifactProvenance) {
        $requiredKinds = New-Object System.Collections.Generic.List[string]
        if ($null -ne $kind) { $requiredKinds.Add([string]$kind) }
        if ($bytes.Length -gt [long]$Manifest.maxBlobBytes) { $requiredKinds.Add('large') }
        $historicalPolicy = $null
        if ($null -ne $HistoricalManifest) {
            $historicalPolicies = Get-SafetyArtifactMap -Manifest $HistoricalManifest
            if ($historicalPolicies.ContainsKey($relative) -and [string]$historicalPolicies[$relative].sha256 -ceq $sha) {
                $historicalPolicy = $historicalPolicies[$relative]
            }
        }
        if ($null -eq $historicalPolicy) { return $false }
        $current = Get-SafetyArtifactMap -Manifest $Manifest
        if ($current.ContainsKey($relative) -and [string]$current[$relative].sha256 -ceq $sha -and
            (Test-SafetyArtifactProvenanceMatches -Candidate $current[$relative] -Historical $historicalPolicy -RequiredKinds $requiredKinds.ToArray())) { return $true }
        $historicalMap = Get-SafetyHistoricalArtifactMap -Manifest $Manifest
        $key = $relative + "`n" + $sha
        return ($historicalMap.ContainsKey($key) -and
            (Test-SafetyArtifactProvenanceMatches -Candidate $historicalMap[$key] -Historical $historicalPolicy -RequiredKinds $requiredKinds.ToArray()))
    }
    if (Test-SafetyPathAllowed -Relative $relative -Manifest $Manifest) { return $true }
    return (Get-SafetyHistoricalFileMap -Manifest $Manifest).ContainsKey($relative)
}

function Get-SafetyLocalOnlyRoot {
    param([string]$Relative, [hashtable]$LocalOnlyTrees)
    if (-not $Relative) { return $null }
    $first = @($Relative -split '/', 2)[0]
    if ($LocalOnlyTrees.ContainsKey($first) -and
        ($Relative -ceq $first -or $Relative.StartsWith($first + '/', [System.StringComparison]::Ordinal))) {
        return $first
    }
    return $null
}

function Test-SafetyPathBlocked {
    param([string]$Relative, [object]$Manifest)

    foreach ($allowed in @(Get-SafetyProperty -InputObject $Manifest -Name 'blockedPathAllowlist')) {
        if ($Relative -ceq [string]$allowed) { return $false }
    }
    $segments = @($Relative -split '/')
    if ($segments.Count -gt 1) {
        foreach ($segment in $segments[0..($segments.Count - 2)]) {
            if ($segment -match '^(?i:\.?cache|caches|state|auth|authentication|authorization|credentials?|backups?|sessions?|logs?|runtime|runtimes|tmp|temp|browser-profiles?|model-cache|node_modules|npm-cache|pip-cache|uv-cache|uv-venv)(?:[-_.].*)?$') {
                return $true
            }
        }
    }
    $name = $segments[-1]
    if ($name -match '^(?i:\.env(?:\..*)?|.*\.(?:jsonl|sqlite|sqlite-shm|sqlite-wal|db|log|pem|p12|pfx|key|keystore|jks|bak|backup))$') {
        return $true
    }
    if ($name -match '^(?i:auth|authentication|credentials?|secrets?|session|state|backup)(?:[-_.].*)?\.(?:json|toml|ya?ml|ini|cfg|conf|txt)$') {
        return $true
    }
    return $false
}

function Test-SafetyPathAllowed {
    param([string]$Relative, [object]$Manifest)

    foreach ($rootFile in @($Manifest.allowedRootFiles)) {
        if ($Relative -ceq [string]$rootFile) { return $true }
    }
    foreach ($allowedFile in @(Get-SafetyProperty -InputObject $Manifest -Name 'allowedFiles')) {
        if ($Relative -ceq [string]$allowedFile) { return $true }
    }
    foreach ($tree in @($Manifest.allowedTrees)) {
        try { $treePath = ConvertTo-SafetyRelativePath -Path ([string]$tree.path) }
        catch { continue }
        $prefix = $treePath + '/'
        if (-not $Relative.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        $remainder = $Relative.Substring($prefix.Length)
        $depth = @($remainder -split '/').Count
        $maxDepth = 1
        [void][int]::TryParse([string]$tree.maxDepth, [ref]$maxDepth)
        if ($depth -gt $maxDepth) { continue }
        $extension = [System.IO.Path]::GetExtension($Relative)
        foreach ($allowedExtension in @($tree.extensions)) {
            if ($extension -ceq [string]$allowedExtension) { return $true }
        }
    }
    return $false
}

function Get-SafetyPrimaryKind {
    param([string]$Relative, [string]$Mode, [byte[]]$Bytes)

    if ($Mode -eq '120000') { return 'symlink' }
    if ($null -eq $Bytes) { return $null }
    $text = ConvertFrom-SafetyUtf8 -Bytes $Bytes
    if ($null -ne $text -and $text -match '^version https://git-lfs\.github\.com/spec/v1\r?\n') {
        return 'lfs'
    }
    $extension = [System.IO.Path]::GetExtension($Relative).ToLowerInvariant()
    if (@('.7z', '.apk', '.bz2', '.cab', '.deb', '.ear', '.gz', '.ipa', '.jar', '.nupkg', '.rar', '.rpm', '.tar', '.tgz', '.unitypackage', '.war', '.xz', '.zip', '.zst') -contains $extension) {
        return 'archive'
    }
    if ($Bytes.Length -ge 4 -and
        (($Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x4b -and $Bytes[2] -in @(0x03, 0x05, 0x07) -and $Bytes[3] -in @(0x04, 0x06, 0x08)) -or
         ($Bytes[0] -eq 0x1f -and $Bytes[1] -eq 0x8b) -or
         ($Bytes[0] -eq 0x42 -and $Bytes[1] -eq 0x5a -and $Bytes[2] -eq 0x68) -or
         ($Bytes[0] -eq 0x28 -and $Bytes[1] -eq 0xb5 -and $Bytes[2] -eq 0x2f -and $Bytes[3] -eq 0xfd) -or
         ($Bytes[0] -eq 0x4d -and $Bytes[1] -eq 0x53 -and $Bytes[2] -eq 0x43 -and $Bytes[3] -eq 0x46))) {
        return 'archive'
    }
    if ($Bytes.Length -ge 6 -and
        (($Bytes[0] -eq 0x37 -and $Bytes[1] -eq 0x7a -and $Bytes[2] -eq 0xbc -and $Bytes[3] -eq 0xaf -and $Bytes[4] -eq 0x27 -and $Bytes[5] -eq 0x1c) -or
         ($Bytes[0] -eq 0xfd -and $Bytes[1] -eq 0x37 -and $Bytes[2] -eq 0x7a -and $Bytes[3] -eq 0x58 -and $Bytes[4] -eq 0x5a -and $Bytes[5] -eq 0x00))) {
        return 'archive'
    }
    if ($Bytes.Length -ge 7 -and $Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x61 -and $Bytes[2] -eq 0x72 -and
        $Bytes[3] -eq 0x21 -and $Bytes[4] -eq 0x1a -and $Bytes[5] -eq 0x07 -and $Bytes[6] -in @(0x00, 0x01)) {
        return 'archive'
    }
    if ($Bytes.Length -ge 262 -and $Bytes[257] -eq 0x75 -and $Bytes[258] -eq 0x73 -and $Bytes[259] -eq 0x74 -and
        $Bytes[260] -eq 0x61 -and $Bytes[261] -eq 0x72) {
        return 'archive'
    }
    if (@('.a', '.bin', '.class', '.dat', '.dll', '.dylib', '.exe', '.lib', '.msi', '.msix', '.o', '.obj', '.pdb', '.so', '.wasm') -contains $extension) {
        return 'binary'
    }
    if (@('.bmp', '.gif', '.ico', '.jpeg', '.jpg', '.pdf', '.png', '.webp', '.woff', '.woff2') -contains $extension) {
        return 'binary'
    }
    if ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0x4d -and $Bytes[1] -eq 0x5a) -or ($Bytes[0] -eq 0x7f -and $Bytes[1] -eq 0x45))) {
        return 'binary'
    }
    if ($Bytes -contains 0 -or $null -eq $text) { return 'binary' }
    return $null
}

function Get-SafetyGitmodules {
    param([byte[]]$Bytes)

    $modules = New-SafetyOrdinalMap
    $findings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Bytes) { return [pscustomobject]@{ Modules = $modules; Findings = $findings.ToArray() } }
    $text = ConvertFrom-SafetyUtf8 -Bytes $Bytes
    if ($null -eq $text) {
        $findings.Add('.gitmodules must be strict UTF-8 text')
        return [pscustomobject]@{ Modules = $modules; Findings = $findings.ToArray() }
    }
    $current = $null
    $lineNumber = 0
    foreach ($line in ($text -split "`r?`n")) {
        $lineNumber++
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#', [System.StringComparison]::Ordinal) -or
            $line.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal)) { continue }
        if ($line -match '^\s*\[submodule\s+"([^"]+)"\]\s*$') {
            try { $name = ConvertTo-SafetyRelativePath -Path $matches[1] }
            catch { $findings.Add(".gitmodules contains a non-canonical section name at line $lineNumber"); $current = $null; continue }
            if ($modules.ContainsKey($name)) {
                $findings.Add(".gitmodules contains a duplicate submodule section at line $lineNumber")
                $current = $null
                continue
            }
            $current = [ordered]@{ name = $name; path = $null; url = $null }
            [void]$modules.Add($name, $current)
            continue
        }
        if ($line -match '^\s*([^=\s]+)\s*=\s*(.*?)\s*$') {
            if ($null -eq $current) {
                $findings.Add(".gitmodules contains a key outside a submodule section at line $lineNumber")
                continue
            }
            $key = $matches[1]
            $value = $matches[2]
            if ($key -cnotin @('path', 'url')) {
                $findings.Add(".gitmodules contains a forbidden key at line $lineNumber")
                continue
            }
            if ($null -ne $current[$key]) {
                $findings.Add(".gitmodules contains a duplicate key at line $lineNumber")
                continue
            }
            if ([string]::IsNullOrWhiteSpace($value) -or $value -cne $value.Trim()) {
                $findings.Add(".gitmodules contains an invalid $key value at line $lineNumber")
                continue
            }
            if ($key -ceq 'path') {
                try { $value = ConvertTo-SafetyRelativePath -Path $value }
                catch { $findings.Add(".gitmodules contains a non-canonical path at line $lineNumber"); continue }
            }
            $current[$key] = $value
            continue
        }
        $findings.Add(".gitmodules contains unsupported syntax at line $lineNumber")
    }
    $paths = New-SafetyOrdinalMap
    $pathCollisions = New-SafetyOrdinalIgnoreCaseMap
    foreach ($module in $modules.Values) {
        if ($null -eq $module.path -or $null -eq $module.url) {
            $findings.Add('.gitmodules submodule sections require exactly one path and one url')
            continue
        }
        if ([string]$module.name -cne [string]$module.path) {
            $findings.Add('.gitmodules section name must exactly equal its path')
        }
        if ($paths.ContainsKey([string]$module.path)) { $findings.Add('.gitmodules contains duplicate submodule paths') }
        elseif ($pathCollisions.ContainsKey([string]$module.path)) { $findings.Add('.gitmodules contains case-colliding submodule paths') }
        else { [void]$paths.Add([string]$module.path, $true); [void]$pathCollisions.Add([string]$module.path, $true) }
    }
    return [pscustomobject]@{ Modules = $modules; Findings = $findings.ToArray() }
}

function Get-SafetyIgnoredRootMap {
    param([byte[]]$Bytes)
    $result = New-SafetyOrdinalMap
    if ($null -eq $Bytes) { return $result }
    $text = ConvertFrom-SafetyUtf8 -Bytes $Bytes
    if ($null -eq $text) { return $result }
    foreach ($rawLine in ($text -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#', [System.StringComparison]::Ordinal) -or
            $line.StartsWith('!', [System.StringComparison]::Ordinal)) { continue }
        if ($line -match '^/?([A-Za-z0-9][A-Za-z0-9._-]*)/$') {
            if (-not $result.ContainsKey($matches[1])) { [void]$result.Add($matches[1], $true) }
        }
    }
    return $result
}

function Get-NestedRepositoryFindings {
    param(
        [string]$Root,
        [hashtable]$DeclaredSubmodules,
        [hashtable]$LocalOnlyTrees
    )

    $findings = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $Root))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try { $children = @(Get-ChildItem -Force -LiteralPath $directory.FullName -ErrorAction Stop) }
        catch { $findings.Add('Unable to inspect a directory for nested Git metadata'); continue }
        foreach ($child in $children) {
            if ($directory.FullName -eq $Root -and $child.Name -eq '.git') { continue }
            $relative = $child.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($child.Name -eq '.git') {
                $parentRelative = (Split-Path -Parent $relative) -replace '\\', '/'
                if (-not $DeclaredSubmodules.ContainsKey($parentRelative)) {
                    $findings.Add("Undeclared nested .git metadata: $(Get-SafetyRedactedLabel -Kind 'path' -Value $parentRelative)")
                }
                continue
            }
            if (-not $child.PSIsContainer) { continue }
            if ($relative -notmatch '/' -and $LocalOnlyTrees.ContainsKey($relative)) { continue }
            if ($DeclaredSubmodules.ContainsKey($relative)) {
                $nestedGit = Join-Path $child.FullName '.git'
                if (Test-Path -LiteralPath $nestedGit) {
                    $head = Invoke-SafetyGitLines -Root $child.FullName -GitArguments @('rev-parse', 'HEAD') -AllowFailure
                    if ($head.ExitCode -eq 0 -and $head.Lines.Count -eq 1 -and
                        $head.Lines[0] -ine [string]$DeclaredSubmodules[$relative].commit) {
                        $findings.Add("Submodule working tree does not match manifest pin: $(Get-SafetyRedactedLabel -Kind 'path' -Value $relative)")
                    }
                }
                continue
            }
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $findings.Add("Undeclared filesystem link/junction: $(Get-SafetyRedactedLabel -Kind 'path' -Value $relative)")
                continue
            }
            $stack.Push($child)
        }
    }
    return $findings.ToArray()
}

function Test-SafetyPlaceholder {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $lower = $Value.ToLowerInvariant()
    return ($lower -match '^(?:placeholder|example|redacted|change[-_]?me|your|dummy|not[-_]?a[-_]?real)(?:[-_a-z0-9]*)$' -or
        $lower -match '^(?:x|0){40,}$')
}

function Test-SafetyProviderPlaceholder {
    param([string]$Value)
    return (@(
        'ghp_your_github_token',
        'ghp_your_new_github_token',
        'github_pat_your_github_token',
        'github_pat_your_new_github_token'
    ) -contains $Value.ToLowerInvariant() -or $Value -match '^sk-x{32,}$')
}

function Test-SafetyProfilePlaceholder {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.ToLowerInvariant() -match '^(?:user|username|your[-_]?user(?:name)?|example[-_]?user(?:name)?|sample[-_]?user(?:name)?|demo[-_]?user(?:name)?|placeholder|redacted)$'
}

function Test-SafetySystemProfileName {
    param([string]$Value, [string]$ProfileKind)
    $lower = $Value.ToLowerInvariant()
    if ($ProfileKind -ceq 'windows') { return @('public', 'default', 'default user', 'all users') -contains $lower }
    if ($ProfileKind -ceq 'mac') { return $lower -ceq 'shared' }
    return $false
}

function Get-SafetyEntropy {
    param([string]$Value)
    if (-not $Value) { return 0.0 }
    $counts = @{}
    foreach ($character in $Value.ToCharArray()) {
        $key = [string]$character
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
    }
    $entropy = 0.0
    foreach ($count in $counts.Values) {
        $probability = [double]$count / [double]$Value.Length
        $entropy -= $probability * ([Math]::Log($probability, 2))
    }
    return $entropy
}

function Test-SafetyHighEntropyToken {
    param([string]$Value)
    if ($Value.Length -lt 40 -or $Value.Length -gt 512 -or (Test-SafetyPlaceholder -Value $Value)) { return $false }
    if ($Value -match '^[0-9a-fA-F]{40,128}$') { return $false }
    $classes = 0
    if ($Value -cmatch '[a-z]') { $classes++ }
    if ($Value -cmatch '[A-Z]') { $classes++ }
    if ($Value -match '[0-9]') { $classes++ }
    if ($Value -match '[+/_=-]') { $classes++ }
    if ($classes -lt 3) { return $false }
    return ((Get-SafetyEntropy -Value $Value) -ge 4.35)
}

function Get-SafetyLineNumber {
    param([string]$Text, [int]$Index)
    if ($Index -le 0) { return 1 }
    return 1 + ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count
}

function Test-SafetyJsonSyntax {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    # Windows PowerShell's ConvertFrom-Json rejects the empty-string property
    # that npm lockfile v2/v3 legitimately uses for the root package. Prefer a
    # real JSON parser that accepts that syntax in each supported shell.
    $jsonDocumentType = 'System.Text.Json.JsonDocument' -as [type]
    if ($null -ne $jsonDocumentType) {
        $document = $null
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($Text)
            return $true
        } catch {
            return $false
        } finally {
            if ($null -ne $document) { $document.Dispose() }
        }
    }

    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = 16MB
        $serializer.RecursionLimit = 512
        $null = $serializer.DeserializeObject($Text)
        return $true
    } catch {
        return $false
    }
}

function Get-SafetyPackageLockIntegritySpanMap {
    param([string]$Relative, [string]$Text)

    $spans = New-SafetyOrdinalMap
    if ([string]::IsNullOrEmpty($Text) -or
        (Split-Path -Leaf ([string]$Relative)) -cne 'package-lock.json') {
        return $spans
    }
    if (-not (Test-SafetyJsonSyntax -Text $Text)) { return $spans }

    $pattern = '"integrity"\s*:\s*"(sha(256|384|512)-([A-Za-z0-9+/]+={0,2}))"'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $valueCapture = $match.Groups[1]
        $algorithm = $match.Groups[2].Value
        $payload = $match.Groups[3].Value
        try { $digest = [Convert]::FromBase64String($payload) }
        catch { continue }
        $expectedLength = switch ($algorithm) {
            '256' { 32 }
            '384' { 48 }
            '512' { 64 }
            default { 0 }
        }
        if ($digest.Length -ne $expectedLength -or
            [Convert]::ToBase64String($digest) -cne $payload) {
            continue
        }
        $span = "{0}:{1}" -f $valueCapture.Index, $valueCapture.Length
        if (-not $spans.ContainsKey($span)) { [void]$spans.Add($span, $true) }
    }
    return $spans
}

function Get-SecretFindings {
    param([string]$Relative, [byte[]]$Bytes, [switch]$DisableEntropy)

    $findings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Bytes) { return $findings.ToArray() }
    $views = New-Object System.Collections.Generic.List[object]
    $utf8 = ConvertFrom-SafetyUtf8 -Bytes $Bytes
    if ($null -ne $utf8) { $views.Add([pscustomobject]@{ Name = 'UTF-8'; Text = $utf8; Entropy = $true }) }
    $singleByte = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    $views.Add([pscustomobject]@{ Name = 'byte-preserving'; Text = $singleByte; Entropy = ($null -ne $utf8) })
    if ($Bytes.Length -ge 2 -and $Bytes.Length % 2 -eq 0) {
        $littleEndianHint = ($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe)
        $bigEndianHint = ($Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff)
        if (-not $littleEndianHint -and -not $bigEndianHint) {
            $samplePairs = [Math]::Min([int]($Bytes.Length / 2), 256)
            $oddZeros = 0; $evenZeros = 0
            for ($pair = 0; $pair -lt $samplePairs; $pair++) {
                if ($Bytes[$pair * 2] -eq 0) { $evenZeros++ }
                if ($Bytes[($pair * 2) + 1] -eq 0) { $oddZeros++ }
            }
            $littleEndianHint = $oddZeros -ge [Math]::Max(2, [int]($samplePairs / 4))
            $bigEndianHint = $evenZeros -ge [Math]::Max(2, [int]($samplePairs / 4))
        }
        if ($littleEndianHint) {
            try {
                $encoding = New-Object System.Text.UnicodeEncoding($false, $false, $true)
                $views.Add([pscustomobject]@{ Name = 'UTF-16LE'; Text = $encoding.GetString($Bytes); Entropy = $true })
            } catch {}
        }
        if ($bigEndianHint) {
            try {
                $encoding = New-Object System.Text.UnicodeEncoding($true, $false, $true)
                $views.Add([pscustomobject]@{ Name = 'UTF-16BE'; Text = $encoding.GetString($Bytes); Entropy = $true })
            } catch {}
        }
    }
    if ($Bytes.Length -ge 4 -and $Bytes.Length % 4 -eq 0) {
        $littleUtf32Hint = ($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00)
        $bigUtf32Hint = ($Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xfe -and $Bytes[3] -eq 0xff)
        if (-not $littleUtf32Hint -and -not $bigUtf32Hint) {
            $sampleQuads = [Math]::Min([int]($Bytes.Length / 4), 128)
            $littleZeroQuads = 0; $bigZeroQuads = 0
            for ($quad = 0; $quad -lt $sampleQuads; $quad++) {
                $offset = $quad * 4
                if ($Bytes[$offset + 1] -eq 0 -and $Bytes[$offset + 2] -eq 0 -and $Bytes[$offset + 3] -eq 0) { $littleZeroQuads++ }
                if ($Bytes[$offset] -eq 0 -and $Bytes[$offset + 1] -eq 0 -and $Bytes[$offset + 2] -eq 0) { $bigZeroQuads++ }
            }
            $littleUtf32Hint = $littleZeroQuads -ge [Math]::Max(2, [int]($sampleQuads / 3))
            $bigUtf32Hint = $bigZeroQuads -ge [Math]::Max(2, [int]($sampleQuads / 3))
        }
        if ($littleUtf32Hint) {
            try {
                $encoding = New-Object System.Text.UTF32Encoding($false, $false, $true)
                $views.Add([pscustomobject]@{ Name = 'UTF-32LE'; Text = $encoding.GetString($Bytes); Entropy = $true })
            } catch {}
        }
        if ($bigUtf32Hint) {
            try {
                $encoding = New-Object System.Text.UTF32Encoding($true, $false, $true)
                $views.Add([pscustomobject]@{ Name = 'UTF-32BE'; Text = $encoding.GetString($Bytes); Entropy = $true })
            } catch {}
        }
    }
    $rules = @(
        [pscustomobject]@{ Name = 'OpenAI token'; Pattern = '(?<![A-Za-z0-9_-])sk-(?:proj|svcacct)-[A-Za-z0-9_-]{16,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Anthropic token'; Pattern = '(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{16,}'; Group = 0 },
        [pscustomobject]@{ Name = 'OpenAI-style token'; Pattern = '(?<![A-Za-z0-9_-])sk-[A-Za-z0-9]{32,}'; Group = 0 },
        [pscustomobject]@{ Name = 'GitHub token'; Pattern = '(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'; Group = 0 },
        [pscustomobject]@{ Name = 'GitLab token'; Pattern = '(?<![A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Google API key'; Pattern = '(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}'; Group = 0 },
        [pscustomobject]@{ Name = 'AWS access key'; Pattern = '(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])'; Group = 0 },
        [pscustomobject]@{ Name = 'Slack token'; Pattern = '(?<![A-Za-z0-9-])xox[baprs]-[A-Za-z0-9-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Stripe live key'; Pattern = '(?<![A-Za-z0-9_])(?:sk|rk)_live_[A-Za-z0-9]{16,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Hugging Face token'; Pattern = '(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{24,}'; Group = 0 },
        [pscustomobject]@{ Name = 'npm token'; Pattern = '(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{24,}'; Group = 0 },
        [pscustomobject]@{ Name = 'PyPI token'; Pattern = '(?<![A-Za-z0-9_-])pypi-AgEIcH[A-Za-z0-9_-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Google OAuth token'; Pattern = '(?<![A-Za-z0-9_.-])ya29\.[A-Za-z0-9_-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'SendGrid token'; Pattern = '(?<![A-Za-z0-9_.-])SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Docker token'; Pattern = '(?<![A-Za-z0-9_-])dckr_pat_[A-Za-z0-9_-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'DigitalOcean token'; Pattern = '(?<![A-Za-z0-9_-])dop_v1_[A-Fa-f0-9]{32,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Vault token'; Pattern = '(?<![A-Za-z0-9_.-])hvs\.[A-Za-z0-9_-]{20,}'; Group = 0 },
        [pscustomobject]@{ Name = 'JWT'; Pattern = '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'; Group = 0 },
        [pscustomobject]@{ Name = 'Private key'; Pattern = '-----BEGIN (?:(?:PGP )?(?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----'; Group = 0 },
        [pscustomobject]@{ Name = 'Azure account key'; Pattern = '(?i)AccountKey\s*=\s*([A-Za-z0-9+/=]{32,})'; Group = 1 },
        [pscustomobject]@{ Name = 'Embedded URI credential'; Pattern = '(?i)://[^\s/:@]{1,64}:([A-Za-z0-9+_.~%=-]{8,})@'; Group = 1 },
        [pscustomobject]@{ Name = 'Sensitive assignment'; Pattern = '(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|secret[_-]?key|aws[_-]?secret[_-]?access[_-]?key)\s*[:=]\s*["'']?([A-Za-z0-9+/_=.-]{16,})'; Group = 1 },
        [pscustomobject]@{ Name = 'Windows user profile path'; Pattern = '(?i)(?<![A-Za-z0-9])[A-Za-z]:[\\/]+(?:Users|Documents[ ]and[ ]Settings)[\\/]+([^\\/\s"''<>:|?*%]+)'; Group = 1; ProfileKind = 'windows' },
        [pscustomobject]@{ Name = 'POSIX user home path'; Pattern = ('(?i)(?<![A-Za-z0-9._~-])/' + 'Users' + '/([^/\s"''<>:|?*%]+)'); Group = 1; ProfileKind = 'mac' },
        [pscustomobject]@{ Name = 'POSIX user home path'; Pattern = ('(?i)(?<![A-Za-z0-9._~-])/' + 'home' + '/([^/\s"''<>:|?*%]+)'); Group = 1; ProfileKind = 'posix' },
        [pscustomobject]@{ Name = 'POSIX root home path'; Pattern = ('(?i)(?<![A-Za-z0-9._~-])(/' + 'root' + ')(?=[/\\\s"''<>:|?*%]|$)'); Group = 1 }
    )
    $seen = @{}
    $locationFingerprint = Get-SafetyStringFingerprint -Value ([string]$Relative)
    $location = "[location sha256:$locationFingerprint length:$(([string]$Relative).Length)]"
    foreach ($view in $views) {
        $text = [string]$view.Text
        $packageIntegritySpans = Get-SafetyPackageLockIntegritySpanMap `
            -Relative $Relative `
            -Text $text
        foreach ($rule in $rules) {
            foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
                $capture = if ($rule.Group -eq 0) { $match } else { $match.Groups[$rule.Group] }
                $value = $capture.Value
                if (Test-SafetyProviderPlaceholder -Value $value) { continue }
                $profileKind = Get-SafetyProperty -InputObject $rule -Name 'ProfileKind'
                if ($profileKind -and ((Test-SafetyProfilePlaceholder -Value $value) -or
                    (Test-SafetySystemProfileName -Value $value -ProfileKind $profileKind))) { continue }
                $fingerprint = Get-SafetyStringFingerprint -Value $value
                if ($seen.ContainsKey($fingerprint)) { continue }
                $seen[$fingerprint] = $true
                $line = Get-SafetyLineNumber -Text $text -Index $capture.Index
                $findings.Add("$($rule.Name) in $location line $line`: [redacted sha256:$fingerprint length:$($value.Length)]")
            }
        }
        if ($view.Entropy -and -not $DisableEntropy) {
            foreach ($match in [regex]::Matches($text, '(?<![A-Za-z0-9+/_=-])([A-Za-z0-9+/_=-]{40,})(?![A-Za-z0-9+/_=-])')) {
                $value = $match.Groups[1].Value
                $span = "{0}:{1}" -f $match.Groups[1].Index, $match.Groups[1].Length
                if ($packageIntegritySpans.ContainsKey($span)) { continue }
                if (-not (Test-SafetyHighEntropyToken -Value $value)) { continue }
                $fingerprint = Get-SafetyStringFingerprint -Value $value
                if ($seen.ContainsKey($fingerprint)) { continue }
                $seen[$fingerprint] = $true
                $line = Get-SafetyLineNumber -Text $text -Index $match.Groups[1].Index
                $findings.Add("High entropy token in $location line $line`: [redacted sha256:$fingerprint length:$($value.Length)]")
            }
        }
    }
    return $findings.ToArray()
}

function Get-SafetyStringSecretFindings {
    param([string]$Label, [string]$Value, [switch]$DisableEntropy)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return @(Get-SecretFindings -Relative $Label -Bytes $encoding.GetBytes([string]$Value) -DisableEntropy:$DisableEntropy)
}

function Invoke-PublicSurfaceInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [switch]$PreferWorkTree,
        [switch]$CheckNestedRepositories
    )

    $findings = New-Object System.Collections.Generic.List[string]
    foreach ($finding in (Get-ManifestValidationFindings -Manifest $Manifest)) { $findings.Add($finding) }
    $artifactMap = Get-SafetyArtifactMap -Manifest $Manifest
    $submoduleMap = Get-SafetySubmoduleMap -Manifest $Manifest
    $localOnlyMap = Get-SafetyLocalOnlyMap -Manifest $Manifest
    $nestedLocalOnlyMap = $localOnlyMap
    if ($CheckNestedRepositories) {
        $nestedLocalOnlyMap = New-SafetyOrdinalMap
        foreach ($localRoot in $localOnlyMap.Keys) {
            [void]$nestedLocalOnlyMap.Add($localRoot, $true)
        }
        $localOverride = Get-SafetyGitLocalSurfaceOverride -Root $Root -Manifest $Manifest
        foreach ($finding in @($localOverride.Findings)) { $findings.Add([string]$finding) }
        foreach ($localRoot in $localOverride.Map.Keys) {
            if (-not $nestedLocalOnlyMap.ContainsKey($localRoot)) {
                [void]$nestedLocalOnlyMap.Add($localRoot, $true)
            }
        }
    }
    $entryMap = New-SafetyOrdinalMap
    $entryCollisionMap = New-SafetyOrdinalIgnoreCaseMap
    foreach ($entry in $Entries) {
        try { $canonicalPath = ConvertTo-SafetyRelativePath -Path ([string]$entry.Path) }
        catch { $findings.Add('Git tree/index contains a non-canonical path'); continue }
        foreach ($pathFinding in (Get-SafetyStringSecretFindings -Label 'Git path' -Value $canonicalPath)) {
            $findings.Add("Git path: $pathFinding")
        }
        if ($entryMap.ContainsKey($canonicalPath)) { $findings.Add('Git tree/index contains duplicate exact paths'); continue }
        if ($entryCollisionMap.ContainsKey($canonicalPath)) { $findings.Add('Git tree/index contains case-colliding paths'); continue }
        if ([string]$entry.Mode -cnotin @('100644', '100755', '120000', '160000')) {
            $findings.Add('Git tree/index contains an unsupported file mode')
        }
        [void]$entryMap.Add($canonicalPath, $entry)
        [void]$entryCollisionMap.Add($canonicalPath, $canonicalPath)
    }
    $gitmodulesBytes = $null
    if ($entryMap.ContainsKey('.gitmodules')) {
        $gitmodulesBytes = Get-SafetyEntryBytes -Root $Root -Entry $entryMap['.gitmodules'] -PreferWorkTree:$PreferWorkTree
    }
    $gitmodulesResult = Get-SafetyGitmodules -Bytes $gitmodulesBytes
    foreach ($finding in @($gitmodulesResult.Findings)) { $findings.Add([string]$finding) }
    $gitmodules = $gitmodulesResult.Modules
    $gitignoreBytes = $null
    if ($entryMap.ContainsKey('.gitignore')) {
        $gitignoreBytes = Get-SafetyEntryBytes -Root $Root -Entry $entryMap['.gitignore'] -PreferWorkTree:$PreferWorkTree
    }
    $ignoredRootMap = Get-SafetyIgnoredRootMap -Bytes $gitignoreBytes
    foreach ($localRoot in $localOnlyMap.Keys) {
        if (-not $ignoredRootMap.ContainsKey($localRoot)) {
            $findings.Add("Local-only tree is not explicitly ignored at repository root: $(Get-SafetyRedactedLabel -Kind 'path' -Value $localRoot)")
        }
    }
    $observedArtifacts = New-SafetyOrdinalMap
    $observedSubmodules = New-SafetyOrdinalMap
    $maxBlob = [Math]::Min([long]$Manifest.maxBlobBytes, 16MB)
    $configuredMaxAllowed = Get-SafetyProperty -InputObject $Manifest -Name 'maxAllowlistedArtifactBytes'
    $maxAllowed = if ($null -eq $configuredMaxAllowed) { 16MB } else { [Math]::Min([long]$configuredMaxAllowed, 16MB) }

    foreach ($entry in $entryMap.Values) {
        $relative = $entry.Path
        $pathLabel = Get-SafetyRedactedLabel -Kind 'path' -Value $relative
        $localRoot = Get-SafetyLocalOnlyRoot -Relative $relative -LocalOnlyTrees $localOnlyMap
        if ($localRoot) {
            $findings.Add("Local-only runtime tree is tracked/staged: $pathLabel")
            continue
        }
        if ($relative -match '(^|/)\.git(/|$)') {
            $findings.Add("Tracked nested .git metadata: $pathLabel")
            continue
        }
        if (Test-SafetyPathBlocked -Relative $relative -Manifest $Manifest) {
            $findings.Add("Blocked path: $pathLabel")
            continue
        }
        if ($entry.Mode -eq '160000') {
            if (-not $submoduleMap.ContainsKey($relative)) {
                $findings.Add("Undeclared submodule gitlink: $pathLabel")
                continue
            }
            if (-not $observedSubmodules.ContainsKey($relative)) { [void]$observedSubmodules.Add($relative, $true) }
            $policy = $submoduleMap[$relative]
            if ($entry.ObjectId -ine [string]$policy.commit) {
                $findings.Add("Submodule commit does not match manifest pin: $pathLabel")
            }
            $module = $null
            foreach ($moduleName in $gitmodules.Keys) {
                if ([string]$gitmodules[$moduleName]['path'] -ceq $relative) { $module = $gitmodules[$moduleName]; break }
            }
            if ($null -eq $module) {
                $findings.Add("Declared submodule is missing from .gitmodules: $pathLabel")
            } elseif ([string]$module['url'] -cne [string]$policy.url) {
                $findings.Add("Submodule URL does not match manifest: $pathLabel")
            }
            continue
        }
        if (-not (Test-SafetyPathAllowed -Relative $relative -Manifest $Manifest)) {
            $findings.Add("Tracked path outside public surface: $pathLabel")
            continue
        }
        $size = Get-SafetyEntrySize -Root $Root -Entry $entry -PreferWorkTree:$PreferWorkTree
        $artifact = if ($artifactMap.ContainsKey($relative)) { $artifactMap[$relative] } else { $null }
        if ($size -gt $maxAllowed) {
            $findings.Add("Blob exceeds absolute public artifact limit: $pathLabel ($size bytes)")
            continue
        }
        if ($size -gt $maxBlob -and ($null -eq $artifact -or @($artifact.kinds) -notcontains 'large')) {
            $findings.Add("Unapproved large blob: $pathLabel ($size bytes)")
            continue
        }
        $bytes = Get-SafetyEntryBytes -Root $Root -Entry $entry -PreferWorkTree:$PreferWorkTree
        if ($null -eq $bytes) { continue }
        foreach ($finding in (Get-SecretFindings -Relative $relative -Bytes $bytes)) { $findings.Add($finding) }
        $kind = Get-SafetyPrimaryKind -Relative $relative -Mode $entry.Mode -Bytes $bytes
        if ($kind -ceq 'archive') {
            $findings.Add("Archives are forbidden by archivePolicy=deny: $pathLabel")
            continue
        }
        if ($kind -and ($null -eq $artifact -or @($artifact.kinds) -notcontains $kind)) {
            $label = switch ($kind) {
                'lfs' { 'Git LFS pointer' }
                default { $kind }
            }
            $findings.Add("Unapproved $label`: $pathLabel")
            continue
        }
        if ($null -ne $artifact) {
            if (-not $observedArtifacts.ContainsKey($relative)) { [void]$observedArtifacts.Add($relative, $true) }
            $actualHash = Get-SafetySha256FromBytes -Bytes $bytes
            if ($actualHash -ine [string]$artifact.sha256) {
                $findings.Add("Artifact hash does not match manifest: $pathLabel")
                continue
            }
        }
    }

    foreach ($path in $artifactMap.Keys) {
        if (-not $entryMap.ContainsKey($path)) { $findings.Add("Manifest artifact is not present: $(Get-SafetyRedactedLabel -Kind 'path' -Value $path)") }
    }
    foreach ($path in $submoduleMap.Keys) {
        if (-not $observedSubmodules.ContainsKey($path)) { $findings.Add("Manifest submodule gitlink is not present: $(Get-SafetyRedactedLabel -Kind 'path' -Value $path)") }
    }
    foreach ($moduleName in $gitmodules.Keys) {
        $modulePath = [string]$gitmodules[$moduleName]['path']
        if ($modulePath -and -not $submoduleMap.ContainsKey($modulePath)) {
            $findings.Add(".gitmodules declares an unapproved submodule: $(Get-SafetyRedactedLabel -Kind 'path' -Value $modulePath)")
        }
    }

    try { $licensePath = ConvertTo-SafetyRelativePath -Path ([string]$Manifest.projectLicense.path) }
    catch { $licensePath = $null }
    if (-not $licensePath -or -not $entryMap.ContainsKey($licensePath)) {
        $findings.Add('Required project license file is not present')
    } else {
        $licenseBytes = Get-SafetyEntryBytes -Root $Root -Entry $entryMap[$licensePath] -PreferWorkTree:$PreferWorkTree
        $licenseText = ConvertFrom-SafetyUtf8 -Bytes $licenseBytes
        if ([string]$Manifest.projectLicense.spdx -eq 'Apache-2.0' -and $licenseText -notmatch '(?s)Apache License\s+Version 2\.0') {
            $findings.Add('Project LICENSE does not contain the declared Apache-2.0 license text')
        }
    }

    if ($CheckNestedRepositories) {
        foreach ($finding in (Get-NestedRepositoryFindings -Root $Root -DeclaredSubmodules $submoduleMap -LocalOnlyTrees $nestedLocalOnlyMap)) { $findings.Add($finding) }
    }
    return $findings.ToArray()
}

function Get-SafetyRepositoryIntegrityFindings {
    param([Parameter(Mandatory = $true)][string]$Root)
    $findings = New-Object System.Collections.Generic.List[string]
    $replaceRefs = Invoke-SafetyGitLines -Root $Root -GitArguments @('for-each-ref', '--format=%(refname)', 'refs/replace')
    if (@($replaceRefs.Lines | Where-Object { $_ }).Count -gt 0) {
        $findings.Add('Git replace refs are forbidden during public-safety inspection')
    }
    $graftsResult = Invoke-SafetyGitLines -Root $Root -GitArguments @('rev-parse', '--git-path', 'info/grafts')
    if ($graftsResult.Lines.Count -ne 1) {
        $findings.Add('Unable to resolve the Git grafts path')
    } else {
        $graftsPath = $graftsResult.Lines[0]
        if (-not [System.IO.Path]::IsPathRooted($graftsPath)) { $graftsPath = Join-Path $Root $graftsPath }
        if (Test-Path -LiteralPath $graftsPath -PathType Leaf) {
            $findings.Add('Git info/grafts files are forbidden during public-safety inspection')
        }
    }
    return $findings.ToArray()
}

function Remove-SafetySignatureBlocks {
    param([string]$Text)
    $result = [string]$Text
    foreach ($label in @('PGP SIGNATURE', 'SSH SIGNATURE', 'SIGNED MESSAGE', 'CMS SIGNATURE')) {
        $escaped = [regex]::Escape($label)
        $pattern = "(?ms)^[ \t]*-----BEGIN $escaped-----[ \t]*\r?\n(.*?)^[ \t]*-----END $escaped-----[ \t]*(?:\r?\n|$)"
        $blocks = @([regex]::Matches($result, $pattern))
        for ($blockIndex = $blocks.Count - 1; $blockIndex -ge 0; $blockIndex--) {
            $block = $blocks[$blockIndex]
            $valid = $true; $sawPayload = $false; $payloadCharacters = 0
            foreach ($rawLine in ($block.Groups[1].Value -split "`r?`n")) {
                $line = $rawLine.Trim()
                if (-not $line) { continue }
                if (-not $sawPayload -and $label -ceq 'PGP SIGNATURE' -and
                    $line -match '^[A-Za-z][A-Za-z0-9-]*:\s+[^\r\n]+$') { continue }
                if ($sawPayload -and $label -ceq 'PGP SIGNATURE' -and $line -match '^=[A-Za-z0-9+/]{4}$') { continue }
                if ($line -match '^[A-Za-z0-9+/]{4,}={0,2}$' -and ($sawPayload -or $line.Length -ge 16)) {
                    $sawPayload = $true
                    $payloadCharacters += $line.TrimEnd('=').Length
                    continue
                }
                $valid = $false
                break
            }
            if ($valid -and $sawPayload -and $payloadCharacters -ge 32) {
                $result = $result.Remove($block.Index, $block.Length)
            }
        }
    }
    return $result
}

function Get-SafetyObjectMetadataAndMessageFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][ValidateSet('commit', 'tag')][string]$Type
    )
    $findings = New-Object System.Collections.Generic.List[string]
    $bytes = Get-SafetyObjectBytes -Root $Root -ObjectId $ObjectId -Type $Type
    $text = ConvertFrom-SafetyUtf8 -Bytes $bytes
    if ($null -eq $text) {
        $findings.Add("$Type metadata is not valid UTF-8")
        return $findings.ToArray()
    }
    $separator = $text.IndexOf("`n`n", [System.StringComparison]::Ordinal)
    if ($separator -lt 0) { $headers = $text; $message = '' }
    else { $headers = $text.Substring(0, $separator); $message = $text.Substring($separator + 2) }
    $metadataLines = New-Object System.Collections.Generic.List[string]
    $skipContinuation = $false
    foreach ($line in ($headers -split "`n")) {
        if ($line -match '^([^ ]+)\s') {
            $key = $matches[1]
            $skipContinuation = $key -cin @('gpgsig', 'gpgsig-sha256')
            if (-not $skipContinuation) { $metadataLines.Add($line) }
        } elseif ($line -match '^ ') {
            if (-not $skipContinuation) { $metadataLines.Add($line) }
        } else {
            $skipContinuation = $false
            $metadataLines.Add($line)
        }
    }
    foreach ($finding in (Get-SafetyStringSecretFindings -Label "$Type metadata" -Value $headers -DisableEntropy)) {
        $findings.Add("$Type metadata: $finding")
    }
    if ($metadataLines.Count -gt 0) {
        $metadataText = Remove-SafetySignatureBlocks -Text ($metadataLines -join "`n")
        foreach ($finding in (Get-SafetyStringSecretFindings -Label "$Type metadata" -Value $metadataText)) {
            $findings.Add("$Type metadata: $finding")
        }
    }
    if ($message) {
        foreach ($finding in (Get-SafetyStringSecretFindings -Label "$Type message" -Value $message -DisableEntropy)) {
            $findings.Add("$Type message: $finding")
        }
        $humanMessage = Remove-SafetySignatureBlocks -Text $message
        foreach ($finding in (Get-SafetyStringSecretFindings -Label "$Type message" -Value $humanMessage)) {
            $findings.Add("$Type message: $finding")
        }
    }
    return $findings.ToArray()
}

function Get-SafetyTagObjectChain {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$ObjectId)
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $current = $ObjectId
    while ($current -match '^[0-9a-fA-F]{40,64}$' -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $type = Invoke-SafetyGitLines -Root $Root -GitArguments @('cat-file', '-t', $current) -AllowFailure
        if ($type.ExitCode -ne 0 -or $type.Lines.Count -ne 1 -or $type.Lines[0] -cne 'tag') { break }
        $result.Add($current.ToLowerInvariant())
        $text = ConvertFrom-SafetyUtf8 -Bytes (Get-SafetyObjectBytes -Root $Root -ObjectId $current -Type tag)
        if ($null -eq $text -or $text -notmatch '(?m)^object ([0-9a-fA-F]{40,64})$') { break }
        $current = $matches[1]
    }
    return $result.ToArray()
}

function Invoke-HistorySafetyInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$RevisionArguments = @('--all'),
        [string[]]$TipObjects = @(),
        [string]$PolicyTip,
        [switch]$ScanAllRefNames,
        [switch]$SkipRepositoryChecks
    )
    $findings = New-Object System.Collections.Generic.List[string]
    if (-not $SkipRepositoryChecks) {
        foreach ($finding in (Get-SafetyRepositoryIntegrityFindings -Root $Root)) { $findings.Add($finding) }
        $shallow = Invoke-SafetyGitLines -Root $Root -GitArguments @('rev-parse', '--is-shallow-repository')
        if ($shallow.Lines.Count -ne 1 -or $shallow.Lines[0] -cne 'false') {
            $findings.Add('Git history is shallow; fetch complete history before scanning')
            return $findings.ToArray()
        }
    }

    $tagObjects = @{}
    $fullRefMode = (-not $PolicyTip -and $RevisionArguments.Count -eq 1 -and $RevisionArguments[0] -ceq '--all')
    $publicationTips = New-SafetyOrdinalMap
    if ($ScanAllRefNames -or $fullRefMode) {
        $refs = Invoke-SafetyGitLines -Root $Root -GitArguments @('for-each-ref', '--format=%(refname)%09%(objectname)%09%(objecttype)')
        foreach ($line in $refs.Lines) {
            if ($line -notmatch '^([^\t]+)\t([0-9a-fA-F]{40,64})\t(\w+)$') { continue }
            $refName = $matches[1]; $objectId = $matches[2]; $objectType = $matches[3]
            foreach ($finding in (Get-SafetyStringSecretFindings -Label 'Git ref name' -Value $refName)) {
                $findings.Add("Git ref name: $finding")
            }
            if ($objectType -ceq 'tag') {
                foreach ($tagObject in (Get-SafetyTagObjectChain -Root $Root -ObjectId $objectId)) { $tagObjects[$tagObject] = $true }
            }
            if ($fullRefMode) {
                $peeled = Invoke-SafetyGitLines -Root $Root -GitArguments @('rev-parse', "$objectId^{commit}") -AllowFailure
                if ($peeled.ExitCode -ne 0 -or $peeled.Lines.Count -ne 1 -or $peeled.Lines[0] -notmatch '^[0-9a-fA-F]{40,64}$') {
                    $findings.Add('A published Git ref does not resolve to a commit')
                } elseif (-not $publicationTips.ContainsKey($peeled.Lines[0])) {
                    [void]$publicationTips.Add($peeled.Lines[0], $objectId)
                }
            }
        }
    }
    foreach ($tip in $TipObjects) {
        foreach ($tagObject in (Get-SafetyTagObjectChain -Root $Root -ObjectId $tip)) { $tagObjects[$tagObject] = $true }
    }

    foreach ($tagObject in $tagObjects.Keys) {
        foreach ($finding in (Get-SafetyObjectMetadataAndMessageFindings -Root $Root -ObjectId $tagObject -Type tag)) {
            $findings.Add("Annotated tag message/metadata: $finding")
        }
    }

    if ($fullRefMode) {
        foreach ($tipCommit in $publicationTips.Keys) {
            foreach ($finding in (Invoke-HistorySafetyInspection -Root $Root -RevisionArguments @([string]$publicationTips[$tipCommit]) -TipObjects @([string]$publicationTips[$tipCommit]) -PolicyTip $tipCommit -SkipRepositoryChecks)) {
                $findings.Add($finding)
            }
        }
        return $findings.ToArray()
    }

    $publicationManifest = $null
    if ($PolicyTip) {
        $peeledPolicy = Invoke-SafetyGitLines -Root $Root -GitArguments @('rev-parse', "$PolicyTip^{commit}") -AllowFailure
        if ($peeledPolicy.ExitCode -ne 0 -or $peeledPolicy.Lines.Count -ne 1 -or $peeledPolicy.Lines[0] -notmatch '^[0-9a-fA-F]{40,64}$') {
            $findings.Add('Publication policy tip does not resolve to a commit')
            return $findings.ToArray()
        }
        try {
            $publicationEntries = @(Get-SafetyTreeEntries -Root $Root -Commit $peeledPolicy.Lines[0])
            $publicationManifest = Get-PublicSurfaceManifestFromTree -Root $Root -Commit $peeledPolicy.Lines[0] -Entries $publicationEntries
        } catch {
            $findings.Add('Publication policy tip has no valid public-surface manifest')
            return $findings.ToArray()
        }
    }

    $arguments = @('rev-list', '--topo-order', '--reverse') + @($RevisionArguments)
    $commitsResult = Invoke-SafetyGitLines -Root $Root -GitArguments $arguments -AllowFailure
    if ($commitsResult.ExitCode -ne 0) {
        $findings.Add('Unable to enumerate the requested Git commit range')
        return $findings.ToArray()
    }
    $seenCommits = @{}
    foreach ($commit in $commitsResult.Lines) {
        if ($commit -notmatch '^[0-9a-fA-F]{40,64}$' -or $seenCommits.ContainsKey($commit)) { continue }
        $seenCommits[$commit] = $true
        foreach ($finding in (Get-SafetyObjectMetadataAndMessageFindings -Root $Root -ObjectId $commit -Type commit)) {
            $findings.Add("Git history commit message/metadata: $finding")
        }
        try {
            $entries = @(Get-SafetyTreeEntries -Root $Root -Commit $commit)
            $manifest = Get-PublicSurfaceManifestFromTree -Root $Root -Commit $commit -Entries $entries
            foreach ($finding in (Invoke-PublicSurfaceInspection -Root $Root -Manifest $manifest -Entries $entries)) {
                $findings.Add("Git history tree policy: $finding")
            }
            if ($null -ne $publicationManifest) {
                foreach ($entry in $entries) {
                    if (-not (Test-SafetyEntryAuthorizedByPublicationManifest -Root $Root -Entry $entry -Manifest $publicationManifest -HistoricalManifest $manifest)) {
                        $findings.Add("Historical path/object is not authorized by the publication-tip manifest: $(Get-SafetyRedactedLabel -Kind 'path' -Value ([string]$entry.Path))")
                    }
                }
            }
        } catch {
            $findings.Add('A reachable Git tree has no valid self-contained public-surface policy')
        }
    }
    return $findings.ToArray()
}

function Invoke-HistorySecretInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [object]$Manifest
    )
    return @(Invoke-HistorySafetyInspection -Root $Root -RevisionArguments @('--all') -ScanAllRefNames)
}
