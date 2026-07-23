param(
    [string]$TestName,
    [string]$ExcludeTestName,
    [string]$GateHost = 'powershell.exe'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$prePushGate = Join-Path $repoRoot 'tools\Test-PrePushSafety.ps1'
$historyGate = Join-Path $repoRoot 'tools\Test-HistorySafety.ps1'
$failures = New-Object System.Collections.Generic.List[string]
$temporaryRoots = New-Object System.Collections.Generic.List[string]

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$GitArguments,
        [switch]$AllowFailure
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Root @GitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($GitArguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-TestManifest {
    param(
        [object[]]$Artifacts = @(),
        [object[]]$Submodules = @(),
        [string[]]$LocalOnlyTrees = @()
    )

    return [ordered]@{
        schemaVersion = 1
        archivePolicy = 'deny'
        allowedRootFiles = @('.gitignore', '.gitmodules', 'LICENSE', 'README.md', 'public-surface.json')
        allowedTrees = @(
            [ordered]@{ path = 'docs'; extensions = @('.md'); maxDepth = 4 },
            [ordered]@{ path = 'artifacts'; extensions = @('.bin', '.dat', '.png', '.txt', '.zip'); maxDepth = 2 },
            [ordered]@{ path = 'tools'; extensions = @('.ps1'); maxDepth = 2 },
            [ordered]@{ path = 'tests/security'; extensions = @('.ps1'); maxDepth = 2 }
        )
        blockedPathAllowlist = @()
        maxBlobBytes = 4096
        artifactAllowlist = @($Artifacts)
        historicalAllowedFiles = @()
        historicalArtifacts = @()
        historicalSubmodules = @()
        submodules = @($Submodules)
        localOnlyTrees = @($LocalOnlyTrees)
        projectLicense = [ordered]@{ path = 'LICENSE'; spdx = 'Apache-2.0' }
    }
}

function Set-TestManifest {
    param(
        [string]$Root,
        [object[]]$Artifacts = @(),
        [object[]]$Submodules = @(),
        [string[]]$LocalOnlyTrees = @()
    )

    $json = (New-TestManifest -Artifacts $Artifacts -Submodules $Submodules -LocalOnlyTrees $LocalOnlyTrees) | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path (Join-Path $Root 'public-surface.json') -Content ($json + "`n")
}

function Set-TestLocalSurfaceOverride {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$LocalOnlyTrees,
        [hashtable]$ExtraProperties = @{}
    )

    $document = [ordered]@{
        schemaVersion = 1
        localOnlyTrees = @($LocalOnlyTrees)
    }
    foreach ($key in $ExtraProperties.Keys) { $document[$key] = $ExtraProperties[$key] }
    $gitPath = (Invoke-TestGit -Root $Root -GitArguments @('rev-parse', '--git-path', 'info/devtools-local-surface.json')).Output.Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitPath)) { $gitPath = Join-Path $Root $gitPath }
    Write-Utf8NoBom -Path $gitPath -Content (($document | ConvertTo-Json -Depth 10) + "`n")
}

function New-TestRepository {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('devtools-public-safety-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    [void]$temporaryRoots.Add($root)
    Invoke-TestGit -Root $root -GitArguments @('init', '-q') | Out-Null
    Invoke-TestGit -Root $root -GitArguments @('config', 'user.name', 'Safety Test') | Out-Null
    Invoke-TestGit -Root $root -GitArguments @('config', 'user.email', 'safety@example.invalid') | Out-Null
    Invoke-TestGit -Root $root -GitArguments @('config', 'core.autocrlf', 'false') | Out-Null
    Write-Utf8NoBom -Path (Join-Path $root 'README.md') -Content "fixture`n"
    Write-Utf8NoBom -Path (Join-Path $root 'LICENSE') -Content "Apache License`nVersion 2.0, January 2004`n"
    Write-Utf8NoBom -Path (Join-Path $root 'docs\guide.md') -Content "safe fixture`n"
    Set-TestManifest -Root $root
    Invoke-TestGit -Root $root -GitArguments @('add', '--', '.') | Out-Null
    Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'fixture baseline') | Out-Null
    return $root
}

function Invoke-Gate {
    param(
        [string]$Script,
        [string]$Root,
        [string[]]$ExtraArguments = @(),
        [AllowNull()][string]$StandardInput = $null
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-Path', $Root) + $ExtraArguments
    $inputEncoding = New-Object System.Text.UTF8Encoding($false, $true)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GateHost
    $quoted = @($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $previousInputEncoding = [Console]::InputEncoding
    $stdinWriter = $null
    try {
        [Console]::InputEncoding = $inputEncoding
        if (-not $process.Start()) { throw 'Unable to start safety gate fixture process' }
        $stdinWriter = $process.StandardInput
    } finally {
        [Console]::InputEncoding = $previousInputEncoding
    }
    try {
        $stdinStream = $stdinWriter.BaseStream
        if ($null -ne $StandardInput) {
            $inputBytes = $inputEncoding.GetBytes($StandardInput)
            if ($inputBytes.Length -gt 0) {
                $stdinStream.Write($inputBytes, 0, $inputBytes.Length)
                $stdinStream.Flush()
            }
        }
        $stdinStream.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = (($stdout, $stderr | Where-Object { $_ }) -join [Environment]::NewLine)
        }
    } finally {
        if ($null -ne $stdinWriter) {
            try { $stdinWriter.Close() } catch {}
        }
        $process.Dispose()
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-GatePasses {
    param([object]$Result)
    Assert-True ($Result.ExitCode -eq 0) "Expected gate to pass, but it failed:`n$($Result.Output)"
}

function Assert-GateFails {
    param([object]$Result, [string]$ExpectedText)
    Assert-True ($Result.ExitCode -ne 0) "Expected gate to fail, but it passed:`n$($Result.Output)"
    if ($ExpectedText) {
        Assert-True ($Result.Output -match [regex]::Escape($ExpectedText)) "Failure did not mention '$ExpectedText':`n$($Result.Output)"
    }
}

function Invoke-SecurityTest {
    param([string]$Name, [scriptblock]$Body)
    if ($TestName -and $Name -notlike "*$TestName*") { return }
    if ($ExcludeTestName -and $Name -like "*$ExcludeTestName*") { return }
    try {
        & $Body
        Write-Host "PASS $Name" -ForegroundColor Green
    } catch {
        [void]$failures.Add("FAIL $Name`n$($_.Exception.Message)")
        Write-Host "FAIL $Name" -ForegroundColor Red
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

try {
    Invoke-SecurityTest 'safe manifest-driven fixture passes' {
        $root = New-TestRepository
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory'))
    }

    Invoke-SecurityTest 'tracked paths outside the manifest fail' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root 'private-notes.txt') -Content "must not publish`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'private-notes.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'Tracked path outside public surface'
    }

    Invoke-SecurityTest 'unstaged manifest edits cannot weaken the index policy' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root 'private-notes.txt') -Content "must not publish`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'private-notes.txt') | Out-Null
        $workTreeManifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $workTreeManifest.allowedRootFiles += 'private-notes.txt'
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($workTreeManifest | ConvertTo-Json -Depth 10) + "`n")
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'Tracked path outside public surface'
    }

    Invoke-SecurityTest 'nested cache state auth credential and backup paths fail' {
        foreach ($blocked in @('cache', 'state', 'auth', 'credential', 'backup')) {
            $root = New-TestRepository
            $relative = "docs/$blocked/item.md"
            Write-Utf8NoBom -Path (Join-Path $root ($relative -replace '/', '\')) -Content "blocked state`n"
            Invoke-TestGit -Root $root -GitArguments @('add', '--', $relative) | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'blocked path'
        }
    }

    Invoke-SecurityTest 'jsonl state files fail at any depth' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root 'docs\events.jsonl') -Content "{}`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/events.jsonl') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'blocked path'
    }

    Invoke-SecurityTest 'large blobs fail unless explicitly allowlisted' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root 'artifacts\large.txt') -Content ('A' * 8192)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/large.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'large blob'
    }

    Invoke-SecurityTest 'pinned provenance allows an intentional large binary' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\intentional.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        $intentionalBytes = New-Object byte[] 8192
        for ($index = 0; $index -lt $intentionalBytes.Length; $index++) { $intentionalBytes[$index] = $index % 256 }
        [System.IO.File]::WriteAllBytes($path, $intentionalBytes)
        $artifact = [ordered]@{
            path = 'artifacts/intentional.bin'
            kinds = @('binary', 'large')
            sha256 = Get-Sha256 -Path $path
            source = 'Generated deterministic safety-test fixture'
            license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/intentional.bin', 'public-surface.json') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory'))
    }

    Invoke-SecurityTest 'archives and unapproved binary blobs fail' {
        foreach ($case in @(
            [pscustomobject]@{ Path = 'artifacts/payload.zip'; Bytes = [byte[]](0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 3); Expected = 'archive' },
            [pscustomobject]@{ Path = 'artifacts/payload.bin'; Bytes = [byte[]](0x4d, 0x5a, 0, 1, 2, 3); Expected = 'binary' }
        )) {
            $root = New-TestRepository
            $full = Join-Path $root ($case.Path -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [System.IO.File]::WriteAllBytes($full, $case.Bytes)
            Invoke-TestGit -Root $root -GitArguments @('add', '--', $case.Path) | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) $case.Expected
        }
    }

    Invoke-SecurityTest 'Git LFS pointers fail unless explicitly allowlisted' {
        $root = New-TestRepository
        $pointer = "version https://git-lfs.github.com/spec/v1`noid sha256:$('a' * 64)`nsize 9999999`n"
        Write-Utf8NoBom -Path (Join-Path $root 'artifacts\model.dat') -Content $pointer
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/model.dat') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'LFS pointer'
    }

    Invoke-SecurityTest 'symlinks fail unless explicitly allowlisted' {
        $root = New-TestRepository
        $blob = (Invoke-TestGit -Root $root -GitArguments @('hash-object', '-w', '--', 'docs/guide.md')).Output.Trim()
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '120000', $blob, 'artifacts/link.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'symlink'
    }

    Invoke-SecurityTest 'undeclared gitlinks fail' {
        $root = New-TestRepository
        $tree = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD^{tree}')).Output.Trim()
        $commit = (& git -C $root commit-tree $tree -m 'fake dependency').Trim()
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $commit, 'third_party/Unity-MCP') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'undeclared submodule'
    }

    Invoke-SecurityTest 'ignored nested Git repositories still fail' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "docs/cache/`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'ignore local cache') | Out-Null
        $nested = Join-Path $root 'docs\cache\nested-repository'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        Invoke-TestGit -Root $nested -GitArguments @('init', '-q') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'nested .git metadata'
    }

    Invoke-SecurityTest 'manifest-declared ignored local runtime trees may contain nested repositories' {
        $root = New-TestRepository
        Set-TestManifest -Root $root -LocalOnlyTrees @('vendor')
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "vendor/`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore', 'public-surface.json') | Out-Null
        $nested = Join-Path $root 'vendor\upstream-tool'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        Invoke-TestGit -Root $nested -GitArguments @('init', '-q') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory'))
    }

    Invoke-SecurityTest 'local runtime trees require safe exact top-level names' {
        foreach ($unsafe in @('../vendor', 'vendor/tool', 'D:\vendor')) {
            $root = New-TestRepository
            Set-TestManifest -Root $root -LocalOnlyTrees @($unsafe)
            Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'local-only tree'
        }
    }

    Invoke-SecurityTest 'local runtime tree names cannot overlap the public surface' {
        $root = New-TestRepository
        Set-TestManifest -Root $root -LocalOnlyTrees @('docs')
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "docs/`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'overlaps public surface'
    }

    Invoke-SecurityTest 'local runtime tree prefixes do not exempt sibling paths' {
        $root = New-TestRepository
        Set-TestManifest -Root $root -LocalOnlyTrees @('vendor')
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "vendor/`nvendor-cache/`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore', 'public-surface.json') | Out-Null
        $nested = Join-Path $root 'vendor-cache\undeclared-repository'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        Invoke-TestGit -Root $nested -GitArguments @('init', '-q') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'nested .git metadata'
    }

    Invoke-SecurityTest 'force-adding local runtime files cannot bypass the tracked surface' {
        $root = New-TestRepository
        Set-TestManifest -Root $root -LocalOnlyTrees @('vendor')
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "vendor/`n"
        Write-Utf8NoBom -Path (Join-Path $root 'vendor\private.txt') -Content "local only`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('add', '-f', '--', 'vendor/private.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'local-only runtime tree is tracked'
    }

    Invoke-SecurityTest 'historical local runtime blobs remain forbidden' {
        $root = New-TestRepository
        Set-TestManifest -Root $root -LocalOnlyTrees @('vendor')
        Write-Utf8NoBom -Path (Join-Path $root '.gitignore') -Content "vendor/`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitignore', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'declare local runtime tree') | Out-Null
        Write-Utf8NoBom -Path (Join-Path $root 'vendor\historical.txt') -Content "local historical state`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '-f', '--', 'vendor/historical.txt') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'forbidden local state') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '-f', '--', 'vendor/historical.txt') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'remove local state') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $root) 'local-only runtime tree is tracked/staged'
    }

    Invoke-SecurityTest 'git-local surface override skips only exact ignored top-level runtime trees' {
        $root = New-TestRepository
        Set-TestLocalSurfaceOverride -Root $root -LocalOnlyTrees @('.popup cache', '_archive', 'TRAE SOLO')
        Write-Utf8NoBom -Path (Join-Path $root '.git\info\exclude') -Content "/.popup cache/`n/_archive/`n/TRAE SOLO/`n"
        foreach ($name in @('.popup cache', '_archive', 'TRAE SOLO')) {
            $nested = Join-Path (Join-Path $root $name) 'nested'
            New-Item -ItemType Directory -Force -Path $nested | Out-Null
            Invoke-TestGit -Root $nested -GitArguments @('init', '-q') | Out-Null
        }
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory', '-ScanUntracked'))

        $sibling = Join-Path $root '_archive-cache\nested'
        New-Item -ItemType Directory -Force -Path $sibling | Out-Null
        Invoke-TestGit -Root $sibling -GitArguments @('init', '-q') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'nested .git metadata'
    }

    Invoke-SecurityTest 'git-local surface override never authorizes index or history content' {
        $root = New-TestRepository
        Set-TestLocalSurfaceOverride -Root $root -LocalOnlyTrees @('private-runtime')
        Write-Utf8NoBom -Path (Join-Path $root '.git\info\exclude') -Content "/private-runtime/`n"
        Write-Utf8NoBom -Path (Join-Path $root 'private-runtime\state.txt') -Content "local only`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '-f', '--', 'private-runtime/state.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'Blocked path'

        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'forbidden local override content') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '-f', '--', 'private-runtime/state.txt') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'remove forbidden content') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $root) 'Blocked path'
    }

    Invoke-SecurityTest 'git-local surface override fails closed for invalid unignored or overlapping entries' {
        foreach ($case in @(
                @{ Name='extra-property'; RootName='private-runtime'; Ignore=$true; Extra=@{ unexpected=$true } },
                @{ Name='git-metadata'; RootName='.git'; Ignore=$true; Extra=@{} },
                @{ Name='public-overlap'; RootName='docs'; Ignore=$true; Extra=@{} },
                @{ Name='unignored'; RootName='private-runtime'; Ignore=$false; Extra=@{} }
            )) {
            $root = New-TestRepository
            Set-TestLocalSurfaceOverride -Root $root -LocalOnlyTrees @($case.RootName) -ExtraProperties $case.Extra
            if ($case.Ignore) {
                Write-Utf8NoBom -Path (Join-Path $root '.git\info\exclude') -Content ("/{0}/`n" -f $case.RootName)
            }
            if ($case.RootName -ne '.git' -and $case.RootName -ne 'docs') {
                New-Item -ItemType Directory -Force -Path (Join-Path $root $case.RootName) | Out-Null
            }
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory', '-ScanUntracked')) 'local surface override'
        }
    }

    Invoke-SecurityTest 'the one manifest-declared pinned submodule passes' {
        $root = New-TestRepository
        $tree = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD^{tree}')).Output.Trim()
        $commit = (& git -C $root commit-tree $tree -m 'fake dependency').Trim()
        $submodule = [ordered]@{
            path = 'third_party/Unity-MCP'
            url = 'https://github.com/IvanMurzak/Unity-MCP.git'
            ref = '0.86.1'
            commit = $commit
            license = 'MIT'
            licenseSource = 'https://github.com/IvanMurzak/Unity-MCP/blob/0.86.1/LICENSE.md'
        }
        Set-TestManifest -Root $root -Submodules @($submodule)
        Write-Utf8NoBom -Path (Join-Path $root '.gitmodules') -Content "[submodule `"third_party/Unity-MCP`"]`n`tpath = third_party/Unity-MCP`n`turl = https://github.com/IvanMurzak/Unity-MCP.git`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitmodules', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $commit, 'third_party/Unity-MCP') | Out-Null
        $submoduleWorkTree = Join-Path $root 'third_party\Unity-MCP'
        New-Item -ItemType Directory -Force -Path $submoduleWorkTree | Out-Null
        Write-Utf8NoBom -Path (Join-Path $submoduleWorkTree '.git') -Content "gitdir: ../../.git/modules/third_party/Unity-MCP`n"
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory'))
    }

    Invoke-SecurityTest 'artifact exceptions require license and source provenance' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\opaque.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllBytes($path, [byte[]](0, 1, 2, 3))
        $artifact = [ordered]@{
            path = 'artifacts/opaque.bin'
            kinds = @('binary')
            sha256 = Get-Sha256 -Path $path
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/opaque.bin', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'provenance'
    }

    Invoke-SecurityTest 'provider secrets are detected without disclosure' {
        $root = New-TestRepository
        $secret = ('AI' + 'za' + ('Q' * 35))
        Write-Utf8NoBom -Path (Join-Path $root 'docs\provider.md') -Content ("value=" + $secret + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/provider.md') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'Google API key'
        Assert-True (-not $result.Output.Contains($secret)) 'Gate output disclosed the matched provider secret'
        Assert-True ($result.Output -match 'sha256:[0-9a-f]{12}') 'Gate output did not include a safe fingerprint'
    }

    Invoke-SecurityTest 'personal home paths are detected without disclosing the account name' {
        $root = New-TestRepository
        $account = 'fixture-' + 'person'
        $privatePath = 'C:' + '\Users\' + $account + '\private\tool.exe'
        Write-Utf8NoBom -Path (Join-Path $root 'docs\machine-path.md') -Content ("path=$privatePath`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/machine-path.md') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'Windows user profile path'
        Assert-True (-not $result.Output.Contains($account)) 'Gate output disclosed the profile account name'
        Assert-True ($result.Output -match 'sha256:[0-9a-f]{12}') 'Gate output did not fingerprint the profile account name'
    }

    Invoke-SecurityTest '[hardening] invalid manifest locations are never echoed' {
        $root = New-TestRepository
        $account = 'manifest-' + 'person'
        $privatePath = 'C:' + '\Users\' + $account + '\private.txt'
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $manifest.allowedRootFiles += $privatePath
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'non-canonical'
        Assert-True (-not $result.Output.Contains($account)) 'Manifest validation echoed a private account name'
        Assert-True (-not $result.Output.Contains($privatePath)) 'Manifest validation echoed a private path'
    }

    Invoke-SecurityTest 'generic high-entropy material is detected without disclosure' {
        $root = New-TestRepository
        $bytes = New-Object byte[] 48
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = [Convert]::ToBase64String($bytes)
        Write-Utf8NoBom -Path (Join-Path $root 'docs\entropy.md') -Content ("opaque_material=" + $secret + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/entropy.md') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'High entropy token'
        Assert-True (-not $result.Output.Contains($secret)) 'Gate output disclosed high-entropy material'
    }

    Invoke-SecurityTest 'package-lock integrity digests are allowed only in exact integrity properties' {
        $digestBytes = New-Object byte[] 64
        for ($index = 0; $index -lt $digestBytes.Length; $index++) {
            $digestBytes[$index] = ($index * 29 + 17) % 256
        }
        $integrity = 'sha512-' + [Convert]::ToBase64String($digestBytes)

        $safeRoot = New-TestRepository
        $safeManifest = Get-Content -Raw -LiteralPath (Join-Path $safeRoot 'public-surface.json') | ConvertFrom-Json
        $safeManifest.allowedRootFiles += 'package-lock.json'
        Write-Utf8NoBom -Path (Join-Path $safeRoot 'public-surface.json') -Content (($safeManifest | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $safeRoot 'package-lock.json') -Content (([ordered]@{
                    name = 'fixture-lock'
                    lockfileVersion = 3
                    packages = [ordered]@{
                        '' = [ordered]@{
                            name = 'fixture-lock'
                            version = '1.0.0'
                        }
                        'node_modules/example' = [ordered]@{
                            version = '1.0.0'
                            integrity = $integrity
                        }
                    }
                } | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $safeRoot -GitArguments @('add', '--', 'package-lock.json', 'public-surface.json') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $safeRoot -ExtraArguments @('-SkipHistory'))

        $unsafeRoot = New-TestRepository
        $unsafeManifest = Get-Content -Raw -LiteralPath (Join-Path $unsafeRoot 'public-surface.json') | ConvertFrom-Json
        $unsafeManifest.allowedRootFiles += 'package-lock.json'
        Write-Utf8NoBom -Path (Join-Path $unsafeRoot 'public-surface.json') -Content (($unsafeManifest | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $unsafeRoot 'package-lock.json') -Content (([ordered]@{
                    name = 'fixture-lock'
                    lockfileVersion = 3
                    token = $integrity
                } | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $unsafeRoot -GitArguments @('add', '--', 'package-lock.json', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $unsafeRoot -ExtraArguments @('-SkipHistory')) 'High entropy token'

        $malformedRoot = New-TestRepository
        $malformedManifest = Get-Content -Raw -LiteralPath (Join-Path $malformedRoot 'public-surface.json') | ConvertFrom-Json
        $malformedManifest.allowedRootFiles += 'package-lock.json'
        Write-Utf8NoBom -Path (Join-Path $malformedRoot 'public-surface.json') -Content (($malformedManifest | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $malformedRoot 'package-lock.json') `
            -Content ("{`n  `"integrity`": `"$integrity`"`n")
        Invoke-TestGit -Root $malformedRoot -GitArguments @('add', '--', 'package-lock.json', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $malformedRoot -ExtraArguments @('-SkipHistory')) 'High entropy token'
    }

    Invoke-SecurityTest 'URI credential scanning ignores source interpolation but redacts real values' {
        $safeRoot = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $safeRoot 'docs\uri-template.md') -Content ('http://${username}:${password}@127.0.0.1/v1' + "`n")
        Invoke-TestGit -Root $safeRoot -GitArguments @('add', '--', 'docs/uri-template.md') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $safeRoot -ExtraArguments @('-SkipHistory'))

        $secretRoot = New-TestRepository
        $random = New-Object byte[] 24
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($random) } finally { $rng.Dispose() }
        $secret = ([Convert]::ToBase64String($random) -replace '\+', '-' -replace '/', '_').TrimEnd('=')
        Write-Utf8NoBom -Path (Join-Path $secretRoot 'docs\uri-secret.md') -Content ("http://fixture-user:$secret@127.0.0.1/v1`n")
        Invoke-TestGit -Root $secretRoot -GitArguments @('add', '--', 'docs/uri-secret.md') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $secretRoot -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'Embedded URI credential'
        Assert-True (-not $result.Output.Contains($secret)) 'Gate output disclosed the embedded URI credential'
    }

    Invoke-SecurityTest 'full history scan catches a removed provider secret' {
        $root = New-TestRepository
        $secret = ('gl' + 'pat-' + ('Z9' * 14))
        Write-Utf8NoBom -Path (Join-Path $root 'docs\transient.md') -Content ("value=" + $secret + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/transient.md') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'temporary value') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '--', 'docs/transient.md') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'remove temporary value') | Out-Null
        $result = Invoke-Gate -Script $historyGate -Root $root
        Assert-GateFails $result 'GitLab token'
        Assert-True (-not $result.Output.Contains($secret)) 'History gate output disclosed a historical secret'
    }

    Invoke-SecurityTest 'full history scan catches a removed personal home path' {
        $root = New-TestRepository
        $account = 'historical-' + 'person'
        $privatePath = 'C:' + '\Users\' + $account + '\private\runtime.exe'
        Write-Utf8NoBom -Path (Join-Path $root 'docs\machine-path.md') -Content ("path=$privatePath`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/machine-path.md') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'temporary machine path') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '--', 'docs/machine-path.md') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'remove machine path') | Out-Null
        $result = Invoke-Gate -Script $historyGate -Root $root
        Assert-GateFails $result 'Windows user profile path'
        Assert-True (-not $result.Output.Contains($account)) 'History gate output disclosed the profile account name'
    }

    Invoke-SecurityTest '[hardening] each reachable tree is checked against its own manifest' {
        $root = New-TestRepository
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $manifest.allowedRootFiles += 'temporary-private.txt'
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $root 'temporary-private.txt') -Content "not a public engineering surface`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json', 'temporary-private.txt') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'temporary expanded surface') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '--', 'temporary-private.txt') | Out-Null
        Set-TestManifest -Root $root
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'restore narrow surface') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $root) 'not authorized by the publication-tip manifest'

        $authorizedRoot = New-TestRepository
        $authorizedManifest = Get-Content -Raw -LiteralPath (Join-Path $authorizedRoot 'public-surface.json') | ConvertFrom-Json
        $authorizedManifest.allowedRootFiles += 'retired-public-note.txt'
        Write-Utf8NoBom -Path (Join-Path $authorizedRoot 'public-surface.json') -Content (($authorizedManifest | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $authorizedRoot 'retired-public-note.txt') -Content "reviewed public note`n"
        Invoke-TestGit -Root $authorizedRoot -GitArguments @('add', '--', 'public-surface.json', 'retired-public-note.txt') | Out-Null
        Invoke-TestGit -Root $authorizedRoot -GitArguments @('commit', '-q', '-m', 'publish note') | Out-Null
        Invoke-TestGit -Root $authorizedRoot -GitArguments @('rm', '-q', '--', 'retired-public-note.txt') | Out-Null
        Set-TestManifest -Root $authorizedRoot
        $tipManifest = Get-Content -Raw -LiteralPath (Join-Path $authorizedRoot 'public-surface.json') | ConvertFrom-Json
        $tipManifest.historicalAllowedFiles += 'retired-public-note.txt'
        Write-Utf8NoBom -Path (Join-Path $authorizedRoot 'public-surface.json') -Content (($tipManifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $authorizedRoot -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $authorizedRoot -GitArguments @('commit', '-q', '-m', 'retain explicit historical tombstone') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $historyGate -Root $authorizedRoot)

        # A commit-then-delete file which was never authorized by that commit's
        # own manifest must fail even though its bytes contain no secret.
        $unauthorizedRoot = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $unauthorizedRoot 'never-authorized.txt') -Content "ordinary text`n"
        Invoke-TestGit -Root $unauthorizedRoot -GitArguments @('add', '--', 'never-authorized.txt') | Out-Null
        Invoke-TestGit -Root $unauthorizedRoot -GitArguments @('commit', '-q', '-m', 'unauthorized historical path') | Out-Null
        Invoke-TestGit -Root $unauthorizedRoot -GitArguments @('rm', '-q', '--', 'never-authorized.txt') | Out-Null
        Invoke-TestGit -Root $unauthorizedRoot -GitArguments @('commit', '-q', '-m', 'remove unauthorized path') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $unauthorizedRoot) 'outside public surface'
    }

    Invoke-SecurityTest '[hardening] archive policy cannot be bypassed by exact artifact provenance' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\payload.zip'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 3))
        $artifact = [ordered]@{
            path = 'artifacts/payload.zip'; kinds = @('archive'); sha256 = Get-Sha256 -Path $path
            source = 'Deterministic regression fixture'; license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/payload.zip', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'Archives are forbidden'
    }

    Invoke-SecurityTest '[hardening] archive magic is denied even with an innocent extension' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\payload.txt'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllBytes($path, [byte[]](0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1, 2))
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/payload.txt') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'archive'
    }

    Invoke-SecurityTest '[hardening] allowlisted binary bytes are still scanned for ASCII credentials' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\opaque.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        $secret = 'gh' + 'p_' + ('A7' * 14)
        $payload = New-Object System.Collections.Generic.List[byte]
        $payload.Add(0) ; $payload.AddRange([System.Text.Encoding]::ASCII.GetBytes("prefix=$secret")) ; $payload.Add(0)
        [System.IO.File]::WriteAllBytes($path, $payload.ToArray())
        $artifact = [ordered]@{
            path = 'artifacts/opaque.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $path
            source = 'Deterministic regression fixture'; license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/opaque.bin', 'public-surface.json') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'GitHub token'
        Assert-True (-not $result.Output.Contains($secret)) 'Binary scan disclosed a credential'
    }

    Invoke-SecurityTest '[hardening] allowlisted UTF-16 binary bytes are scanned for credentials' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\utf16.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        $secret = 'AI' + 'za' + ('R' * 35)
        $utf16 = New-Object System.Text.UnicodeEncoding($false, $true)
        [System.IO.File]::WriteAllBytes($path, $utf16.GetPreamble() + $utf16.GetBytes("value=$secret"))
        $artifact = [ordered]@{
            path = 'artifacts/utf16.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $path
            source = 'Deterministic regression fixture'; license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/utf16.bin', 'public-surface.json') | Out-Null
        $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
        Assert-GateFails $result 'Google API key'
        Assert-True (-not $result.Output.Contains($secret)) 'UTF-16 scan disclosed a credential'
    }

    Invoke-SecurityTest '[hardening] allowlisted UTF-32 binary bytes are scanned for credentials' {
        foreach ($bigEndian in @($false, $true)) {
            $root = New-TestRepository
            $path = Join-Path $root 'artifacts\utf32.bin'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            $secret = 'AI' + 'za' + ('S' * 35)
            $utf32 = New-Object System.Text.UTF32Encoding($bigEndian, $true, $true)
            [System.IO.File]::WriteAllBytes($path, $utf32.GetPreamble() + $utf32.GetBytes("value=$secret"))
            $artifact = [ordered]@{
                path = 'artifacts/utf32.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $path
                source = 'Deterministic regression fixture'; license = 'Apache-2.0'
            }
            Set-TestManifest -Root $root -Artifacts @($artifact)
            Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/utf32.bin', 'public-surface.json') | Out-Null
            $result = Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')
            Assert-GateFails $result 'Google API key'
            Assert-True (-not $result.Output.Contains($secret)) 'UTF-32 scan disclosed a credential'
        }
    }

    Invoke-SecurityTest '[hardening] retired binary history needs exact final provenance and kinds' {
        $root = New-TestRepository
        $path = Join-Path $root 'artifacts\retired.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x4d, 0x5a, 0x00, 0x01, 0x02, 0x03))
        $artifact = [ordered]@{
            path = 'artifacts/retired.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $path
            source = 'Deterministic retired fixture'; license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact)
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'artifacts/retired.bin', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'publish reviewed binary') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '--', 'artifacts/retired.bin') | Out-Null
        Set-TestManifest -Root $root
        $tipManifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $tipManifest.historicalArtifacts = @($artifact)
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($tipManifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'retain retired binary provenance') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $historyGate -Root $root)

        $tipManifest.historicalArtifacts[0].kinds = @('large')
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($tipManifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'misstate retired binary kind') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $root) 'not authorized by the publication-tip manifest'
    }

    Invoke-SecurityTest '[hardening] commit and annotated tag messages are secret-scanned' {
        $commitRoot = New-TestRepository
        $commitSecret = 'gl' + 'pat-' + ('C8' * 14)
        Write-Utf8NoBom -Path (Join-Path $commitRoot 'docs\second.md') -Content "safe`n"
        Invoke-TestGit -Root $commitRoot -GitArguments @('add', '--', 'docs/second.md') | Out-Null
        Invoke-TestGit -Root $commitRoot -GitArguments @('commit', '-q', '-m', "message $commitSecret") | Out-Null
        $commitResult = Invoke-Gate -Script $historyGate -Root $commitRoot
        Assert-GateFails $commitResult 'commit message'
        Assert-True (-not $commitResult.Output.Contains($commitSecret)) 'Commit scan disclosed a credential'

        $tagRoot = New-TestRepository
        $tagSecret = 'npm_' + ('D9' * 16)
        Invoke-TestGit -Root $tagRoot -GitArguments @('tag', '-a', 'unsafe-message', '-m', "release $tagSecret") | Out-Null
        $tagResult = Invoke-Gate -Script $historyGate -Root $tagRoot
        Assert-GateFails $tagResult 'annotated tag message'
        Assert-True (-not $tagResult.Output.Contains($tagSecret)) 'Tag scan disclosed a credential'
    }

    Invoke-SecurityTest '[hardening] signed tag payloads are excluded but surrounding text is scanned' {
        $signatureBytes = New-Object byte[] 96
        for ($index = 0; $index -lt $signatureBytes.Length; $index++) { $signatureBytes[$index] = ($index * 37 + 11) % 256 }
        $signaturePayload = [Convert]::ToBase64String($signatureBytes)
        $signatureBlock = ('-----BEGIN ' + 'PGP SIGNATURE-----' + "`n" + $signaturePayload + "`n" + '-----END ' + 'PGP SIGNATURE-----')
        $safeRoot = New-TestRepository
        Invoke-TestGit -Root $safeRoot -GitArguments @('tag', '-a', 'signed-like', '-m', ("reviewed release`n$signatureBlock")) | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $historyGate -Root $safeRoot)

        $fakeRoot = New-TestRepository
        $embeddedSecret = 'gl' + 'pat-' + ('J8' * 14)
        $fakeBlock = ('-----BEGIN ' + 'PGP SIGNATURE-----' + "`n" + $embeddedSecret + "`n" + '-----END ' + 'PGP SIGNATURE-----')
        Invoke-TestGit -Root $fakeRoot -GitArguments @('tag', '-a', 'fake-signature', '-m', $fakeBlock) | Out-Null
        $fakeResult = Invoke-Gate -Script $historyGate -Root $fakeRoot
        Assert-GateFails $fakeResult 'GitLab token'
        Assert-True (-not $fakeResult.Output.Contains($embeddedSecret)) 'Fake signature block disclosed an embedded credential'

        $armoredRoot = New-TestRepository
        $armoredSecret = 'AKIA' + ('Z9' * 8)
        $armoredBlock = ('-----BEGIN ' + 'PGP SIGNATURE-----' + "`n" + $armoredSecret + "`n" + 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=' + "`n" + '-----END ' + 'PGP SIGNATURE-----')
        Invoke-TestGit -Root $armoredRoot -GitArguments @('tag', '-a', 'armored-secret', '-m', $armoredBlock) | Out-Null
        $armoredResult = Invoke-Gate -Script $historyGate -Root $armoredRoot
        Assert-GateFails $armoredResult 'AWS access key'
        Assert-True (-not $armoredResult.Output.Contains($armoredSecret)) 'Valid armor disclosed an embedded credential'

        foreach ($position in @('before', 'after')) {
            $root = New-TestRepository
            $secret = 'npm_' + ('K9' * 16)
            $message = if ($position -eq 'before') { "$secret`n$signatureBlock" } else { "$signatureBlock`n$secret" }
            Invoke-TestGit -Root $root -GitArguments @('tag', '-a', "secret-$position", '-m', $message) | Out-Null
            $result = Invoke-Gate -Script $historyGate -Root $root
            Assert-GateFails $result 'annotated tag message'
            Assert-True (-not $result.Output.Contains($secret)) 'Signed-tag scan disclosed surrounding text'
            Assert-True (-not $result.Output.Contains($signaturePayload)) 'Signed-tag scan disclosed signature payload'
        }
    }

    Invoke-SecurityTest '[hardening] paths refs and structured identity metadata are secret-scanned' {
        $pathRoot = New-TestRepository
        $pathSecret = 'gl' + 'pat-' + ('E4' * 14)
        $relative = "docs/$pathSecret.md"
        Write-Utf8NoBom -Path (Join-Path $pathRoot ($relative -replace '/', '\')) -Content "benign body`n"
        Invoke-TestGit -Root $pathRoot -GitArguments @('add', '--', $relative) | Out-Null
        $pathResult = Invoke-Gate -Script $prePushGate -Root $pathRoot -ExtraArguments @('-SkipHistory')
        Assert-GateFails $pathResult 'Git path'
        Assert-True (-not $pathResult.Output.Contains($pathSecret)) 'Path scan disclosed a credential'

        $refRoot = New-TestRepository
        $refSecret = 'gl' + 'pat-' + ('F5' * 14)
        Invoke-TestGit -Root $refRoot -GitArguments @('branch', "leak/$refSecret") | Out-Null
        $refResult = Invoke-Gate -Script $historyGate -Root $refRoot
        Assert-GateFails $refResult 'Git ref name'
        Assert-True (-not $refResult.Output.Contains($refSecret)) 'Ref scan disclosed a credential'

        $identityRoot = New-TestRepository
        $identitySecret = 'npm_' + ('G6' * 16)
        Write-Utf8NoBom -Path (Join-Path $identityRoot 'docs\identity.md') -Content "benign body`n"
        Invoke-TestGit -Root $identityRoot -GitArguments @('add', '--', 'docs/identity.md') | Out-Null
        Invoke-TestGit -Root $identityRoot -GitArguments @('-c', "user.name=$identitySecret", 'commit', '-q', '-m', 'safe message') | Out-Null
        $identityResult = Invoke-Gate -Script $historyGate -Root $identityRoot
        Assert-GateFails $identityResult 'commit metadata'
        Assert-True (-not $identityResult.Output.Contains($identitySecret)) 'Commit metadata scan disclosed a credential'
    }

    Invoke-SecurityTest '[hardening] profile placeholder exceptions are exact and system paths are narrow' {
        foreach ($account in @('examplecorp', 'yourteam', 'Sharedness')) {
            $root = New-TestRepository
            $privatePath = if ($account -eq 'Sharedness') {
                ('/' + 'Users' + "/$account/private/tool")
            } else {
                ('C:' + '\Users' + "\$account\private\tool.exe")
            }
            Write-Utf8NoBom -Path (Join-Path $root 'docs\machine.md') -Content ("path=$privatePath`n")
            Invoke-TestGit -Root $root -GitArguments @('add', '--', 'docs/machine.md') | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'user'
        }
        $safeRoot = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $safeRoot 'docs\portable.md') -Content ("C:\Users\Public\tool`nC:\Users\your-user\tool`n/Users/Shared/tool`n./home/examplecorp/project`n")
        Invoke-TestGit -Root $safeRoot -GitArguments @('add', '--', 'docs/portable.md') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $safeRoot -ExtraArguments @('-SkipHistory'))

        foreach ($absoluteCase in @(
            [pscustomobject]@{ Value = ('/' + 'root' + '/private/config'); Expected = 'POSIX root home path' },
            [pscustomobject]@{ Value = ('file://' + '/' + 'home' + '/privateuser/config'); Expected = 'POSIX user home path' },
            [pscustomobject]@{ Value = ('file://' + '/' + 'Users' + '/privateuser/config'); Expected = 'POSIX user home path' }
        )) {
            $absoluteRoot = New-TestRepository
            Write-Utf8NoBom -Path (Join-Path $absoluteRoot 'docs\absolute-home.md') -Content ("path=$($absoluteCase.Value)`n")
            Invoke-TestGit -Root $absoluteRoot -GitArguments @('add', '--', 'docs/absolute-home.md') | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $absoluteRoot -ExtraArguments @('-SkipHistory')) $absoluteCase.Expected
        }
    }

    Invoke-SecurityTest '[hardening] manifest paths must be canonical' {
        $root = New-TestRepository
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $manifest.allowedRootFiles += ([string]([char]0x0065) + [char]0x0301 + '.txt')
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'canonical'
    }

    Invoke-SecurityTest '[hardening] index path case collisions fail closed' {
        $collisionRoot = New-TestRepository
        # Use an existing safe blob so only the two index path spellings differ.
        Invoke-TestGit -Root $collisionRoot -GitArguments @('config', 'core.ignorecase', 'false') | Out-Null
        $blob = (Invoke-TestGit -Root $collisionRoot -GitArguments @('rev-parse', 'HEAD:docs/guide.md')).Output.Trim()
        Invoke-TestGit -Root $collisionRoot -GitArguments @('update-index', '--add', '--cacheinfo', '100644', $blob, 'docs/Case.md') | Out-Null
        Invoke-TestGit -Root $collisionRoot -GitArguments @('update-index', '--add', '--cacheinfo', '100644', $blob, 'docs/case.md') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $collisionRoot -ExtraArguments @('-SkipHistory')) 'case-colliding'
    }

    Invoke-SecurityTest '[hardening] public tree matching is exact case-sensitive' {
        $root = New-TestRepository
        $blob = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD:docs/guide.md')).Output.Trim()
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '100644', $blob, 'Docs/case.md') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'outside public surface'
    }

    Invoke-SecurityTest '[hardening] gitmodules accepts only exact path url declarations' {
        foreach ($line in @('update = !echo unsafe', 'url = https://github.com/IvanMurzak/Unity-MCP.git')) {
            $root = New-TestRepository
            $tree = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD^{tree}')).Output.Trim()
            $commit = (& git -C $root commit-tree $tree -m 'fake dependency').Trim()
            $submodule = [ordered]@{
                path = 'third_party/Unity-MCP'; url = 'https://github.com/IvanMurzak/Unity-MCP.git'; ref = '0.86.1'
                commit = $commit; license = 'MIT'; licenseSource = 'https://example.invalid/LICENSE'
            }
            Set-TestManifest -Root $root -Submodules @($submodule)
            $content = "[submodule `"third_party/Unity-MCP`"]`npath = third_party/Unity-MCP`nurl = https://github.com/IvanMurzak/Unity-MCP.git`n$line`n"
            Write-Utf8NoBom -Path (Join-Path $root '.gitmodules') -Content $content
            Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitmodules', 'public-surface.json') | Out-Null
            Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $commit, 'third_party/Unity-MCP') | Out-Null
            Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) '.gitmodules'
        }
    }

    Invoke-SecurityTest '[hardening] retired submodule history needs matching final provenance' {
        $root = New-TestRepository
        $tree = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD^{tree}')).Output.Trim()
        $commit = (& git -C $root commit-tree $tree -m 'fake dependency').Trim()
        $submodule = [ordered]@{
            path = 'third_party/Unity-MCP'; url = 'https://github.com/IvanMurzak/Unity-MCP.git'; ref = '0.86.1'
            commit = $commit; license = 'MIT'; licenseSource = 'https://example.invalid/LICENSE'
        }
        Set-TestManifest -Root $root -Submodules @($submodule)
        Write-Utf8NoBom -Path (Join-Path $root '.gitmodules') -Content "[submodule `"third_party/Unity-MCP`"]`npath = third_party/Unity-MCP`nurl = https://github.com/IvanMurzak/Unity-MCP.git`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', '.gitmodules', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $commit, 'third_party/Unity-MCP') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'publish reviewed submodule') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '-f', '--', '.gitmodules', 'third_party/Unity-MCP') | Out-Null
        Set-TestManifest -Root $root
        $tipManifest = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $tipManifest.historicalSubmodules = @($submodule)
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($tipManifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'retain retired submodule provenance') | Out-Null
        Assert-GatePasses (Invoke-Gate -Script $historyGate -Root $root)

        $tipManifest.historicalSubmodules[0].url = 'https://example.invalid/different.git'
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($tipManifest | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'misstate retired submodule source') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $root) 'not authorized by the publication-tip manifest'
    }

    Invoke-SecurityTest '[hardening] replace refs and graft files are rejected' {
        $replaceRoot = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $replaceRoot 'docs\second.md') -Content "safe`n"
        Invoke-TestGit -Root $replaceRoot -GitArguments @('add', '--', 'docs/second.md') | Out-Null
        Invoke-TestGit -Root $replaceRoot -GitArguments @('commit', '-q', '-m', 'second') | Out-Null
        $tip = (Invoke-TestGit -Root $replaceRoot -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        $parent = (Invoke-TestGit -Root $replaceRoot -GitArguments @('rev-parse', 'HEAD^')).Output.Trim()
        Invoke-TestGit -Root $replaceRoot -GitArguments @('replace', $tip, $parent) | Out-Null
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $replaceRoot) 'replace refs'

        $graftRoot = New-TestRepository
        $graftGit = (Invoke-TestGit -Root $graftRoot -GitArguments @('rev-parse', '--git-dir')).Output.Trim()
        if (-not [System.IO.Path]::IsPathRooted($graftGit)) { $graftGit = Join-Path $graftRoot $graftGit }
        New-Item -ItemType Directory -Force -Path (Join-Path $graftGit 'info') | Out-Null
        Write-Utf8NoBom -Path (Join-Path $graftGit 'info\grafts') -Content ((Invoke-TestGit -Root $graftRoot -GitArguments @('rev-parse', 'HEAD')).Output.Trim() + "`n")
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $graftRoot) 'grafts'
    }

    Invoke-SecurityTest '[hardening] an unborn repository cannot use an unstaged manifest' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('devtools-public-unborn-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        [void]$temporaryRoots.Add($root)
        Invoke-TestGit -Root $root -GitArguments @('init', '-q') | Out-Null
        Write-Utf8NoBom -Path (Join-Path $root 'README.md') -Content "fixture`n"
        Write-Utf8NoBom -Path (Join-Path $root 'LICENSE') -Content "Apache License`nVersion 2.0, January 2004`n"
        Set-TestManifest -Root $root
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'README.md', 'LICENSE') | Out-Null
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory')) 'Indexed public-surface.json is missing'
    }

    Invoke-SecurityTest '[hardening] pre-push scans dangling tips supplied on stdin' {
        $root = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $root 'never-authorized.txt') -Content "ordinary text`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'never-authorized.txt') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'dangling unsafe tip') | Out-Null
        $tip = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        Invoke-TestGit -Root $root -GitArguments @('reset', '-q', '--hard', 'HEAD^') | Out-Null
        $zeros = '0' * $tip.Length
        $stdin = "refs/heads/feature $tip refs/heads/feature $zeros`n"
        Assert-GateFails (Invoke-Gate -Script $prePushGate -Root $root -StandardInput $stdin) 'outside public surface'
    }

    Invoke-SecurityTest '[hardening] pre-push permits delete-only ref updates despite an unsafe index' {
        $root = New-TestRepository
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -ExtraArguments @('-SkipHistory'))
        Write-Utf8NoBom -Path (Join-Path $root 'never-authorized.txt') -Content "ordinary text`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'never-authorized.txt') | Out-Null
        $remote = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        $zeros = '0' * $remote.Length
        $stdin = "(delete) $zeros refs/heads/obsolete $remote`r`n"
        Assert-GatePasses (Invoke-Gate -Script $prePushGate -Root $root -StandardInput $stdin)
    }

    Invoke-SecurityTest '[hardening] pre-push ref names are scanned without disclosure' {
        $root = New-TestRepository
        $tip = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        $zeros = '0' * $tip.Length
        $secret = 'gl' + 'pat-' + ('H7' * 14)
        $stdin = "refs/heads/main $tip refs/heads/leak/$secret $zeros`n"
        $result = Invoke-Gate -Script $prePushGate -Root $root -StandardInput $stdin
        Assert-GateFails $result 'Git ref name'
        Assert-True (-not $result.Output.Contains($secret)) 'Pre-push ref scan disclosed a credential'
    }

    Invoke-SecurityTest '[hardening] pre-push revalidates final tombstones across full ancestry' {
        $root = New-TestRepository
        $baseTree = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD^{tree}')).Output.Trim()
        $subCommit1 = (& git -C $root commit-tree $baseTree -m 'dependency one').Trim()
        $subCommit2 = (& git -C $root commit-tree $baseTree -m 'dependency two').Trim()
        $submodule1 = [ordered]@{
            path = 'third_party/Unity-MCP'; url = 'https://github.com/IvanMurzak/Unity-MCP.git'; ref = '1.0.0'
            commit = $subCommit1; license = 'MIT'; licenseSource = 'https://example.invalid/LICENSE'
        }
        $submodule2 = [ordered]@{
            path = 'third_party/Unity-MCP'; url = 'https://github.com/IvanMurzak/Unity-MCP.git'; ref = '2.0.0'
            commit = $subCommit2; license = 'MIT'; licenseSource = 'https://example.invalid/LICENSE'
        }
        $binaryPath = Join-Path $root 'artifacts\versioned.bin'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $binaryPath) | Out-Null
        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]](0x4d, 0x5a, 0x00, 0x01))
        $artifact1 = [ordered]@{
            path = 'artifacts/versioned.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $binaryPath
            source = 'Reviewed binary version one'; license = 'Apache-2.0'
        }
        Set-TestManifest -Root $root -Artifacts @($artifact1) -Submodules @($submodule1)
        $manifest1 = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $manifest1.maxBlobBytes = 16384
        $manifest1.allowedRootFiles += 'retired-note.txt'
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest1 | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path (Join-Path $root 'retired-note.txt') -Content "reviewed historical note`n"
        Write-Utf8NoBom -Path (Join-Path $root '.gitmodules') -Content "[submodule `"third_party/Unity-MCP`"]`npath = third_party/Unity-MCP`nurl = https://github.com/IvanMurzak/Unity-MCP.git`n"
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json', 'retired-note.txt', '.gitmodules', 'artifacts/versioned.bin') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $subCommit1, 'third_party/Unity-MCP') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'publish version one') | Out-Null

        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]](0x4d, 0x5a, 0x00, 0x02))
        $artifact2 = [ordered]@{
            path = 'artifacts/versioned.bin'; kinds = @('binary'); sha256 = Get-Sha256 -Path $binaryPath
            source = 'Reviewed binary version two'; license = 'Apache-2.0'
        }
        Invoke-TestGit -Root $root -GitArguments @('rm', '-q', '--', 'retired-note.txt') | Out-Null
        Set-TestManifest -Root $root -Artifacts @($artifact2) -Submodules @($submodule2)
        $manifest2 = Get-Content -Raw -LiteralPath (Join-Path $root 'public-surface.json') | ConvertFrom-Json
        $manifest2.maxBlobBytes = 16384
        $manifest2.historicalAllowedFiles = @('retired-note.txt')
        $manifest2.historicalArtifacts = @($artifact1)
        $manifest2.historicalSubmodules = @($submodule1)
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest2 | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json', 'artifacts/versioned.bin') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('update-index', '--add', '--cacheinfo', '160000', $subCommit2, 'third_party/Unity-MCP') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'publish version two with tombstones') | Out-Null
        $remoteTip = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        Assert-GatePasses (Invoke-Gate -Script $historyGate -Root $root)

        $manifest2.historicalAllowedFiles = @()
        $manifest2.historicalArtifacts = @()
        $manifest2.historicalSubmodules = @()
        Write-Utf8NoBom -Path (Join-Path $root 'public-surface.json') -Content (($manifest2 | ConvertTo-Json -Depth 10) + "`n")
        Invoke-TestGit -Root $root -GitArguments @('add', '--', 'public-surface.json') | Out-Null
        Invoke-TestGit -Root $root -GitArguments @('commit', '-q', '-m', 'incorrectly drop old tombstones') | Out-Null
        $localTip = (Invoke-TestGit -Root $root -GitArguments @('rev-parse', 'HEAD')).Output.Trim()
        $stdin = "refs/heads/main $localTip refs/heads/main $remoteTip`n"
        $result = Invoke-Gate -Script $prePushGate -Root $root -StandardInput $stdin
        Assert-GateFails $result 'not authorized by the publication-tip manifest'
        Assert-True (([regex]::Matches($result.Output, 'not authorized by the publication-tip manifest')).Count -ge 3) 'Pre-push did not reject all three removed history contracts'
    }

    Invoke-SecurityTest 'history gate rejects shallow clones' {
        $source = New-TestRepository
        Write-Utf8NoBom -Path (Join-Path $source 'docs\second.md') -Content "second commit`n"
        Invoke-TestGit -Root $source -GitArguments @('add', '--', 'docs/second.md') | Out-Null
        Invoke-TestGit -Root $source -GitArguments @('commit', '-q', '-m', 'second commit') | Out-Null
        $clone = Join-Path ([System.IO.Path]::GetTempPath()) ('devtools-public-shallow-' + [Guid]::NewGuid().ToString('N'))
        [void]$temporaryRoots.Add($clone)
        $parent = Split-Path -Parent $clone
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $cloneOutput = @(& git clone -q --depth 1 --no-local -- $source $clone 2>&1)
            $cloneExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        Assert-True ($cloneExit -eq 0) "Unable to create shallow fixture clone: $($cloneOutput -join [Environment]::NewLine)"
        Assert-GateFails (Invoke-Gate -Script $historyGate -Root $clone) 'history is shallow'
    }

    Invoke-SecurityTest 'reviewed AgentMemory additions use an exact file allowlist' {
        $manifestPath = Join-Path $repoRoot 'public-surface.json'
        Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'Missing public-surface.json'
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

        foreach ($path in @(
            'agentmemory-host-guard.mjs',
            'agentmemory-runtime-supervisor.mjs'
        )) {
            $matches = @($manifest.allowedRootFiles | Where-Object { [string]$_ -ceq $path })
            Assert-True ($matches.Count -eq 1) "Root publication entry must appear exactly once with exact case: $path"
        }
        foreach ($path in @(
            'dependencies/agentmemory-runtime/package-lock.json',
            'dependencies/agentmemory-runtime/package.json',
            'tests/agentmemory-host-guard.test.mjs',
            'tests/agentmemory-runtime-supervisor.test.mjs',
            'tests/security/agentmemory-dependency-lock.test.mjs',
            'tests/shell/ShellReachability.Tests.ps1',
            'tools/agent-launcher-verify-run.cmd',
            'tools/agent-launcher-verify-run.ps1'
        )) {
            $matches = @($manifest.allowedFiles | Where-Object { [string]$_ -ceq $path })
            Assert-True ($matches.Count -eq 1) "Publication entry must appear exactly once with exact case: $path"
        }
        Assert-True (@($manifest.allowedTrees).Count -eq 0) 'Reviewed additions must not be authorized through a broad public tree'
    }

    Invoke-SecurityTest 'AgentMemory dependency closure and Host guard are present' {
        foreach ($path in @(
            'agentmemory-host-guard.mjs',
            'agentmemory-runtime-supervisor.mjs',
            'dependencies/agentmemory-runtime/package.json',
            'dependencies/agentmemory-runtime/package-lock.json',
            'tests/agentmemory-host-guard.test.mjs',
            'tests/agentmemory-runtime-supervisor.test.mjs',
            'tests/security/agentmemory-dependency-lock.test.mjs'
        )) {
            Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot ($path -replace '/', '\')) -PathType Leaf) "Missing reviewed AgentMemory file: $path"
        }

        $packageManifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'dependencies\agentmemory-runtime\package.json') | ConvertFrom-Json
        Assert-True ($packageManifest.private -eq $true) 'AgentMemory dependency-lock manifest must remain private/non-publishable to npm'
        Assert-True ([string]$packageManifest.packageManager -ceq 'npm@10.9.4') 'AgentMemory dependency-lock manifest must pin npm 10.9.4'
        Assert-True ([string]$packageManifest.engines.node -ceq '22.21.1') 'AgentMemory dependency-lock manifest must pin Node 22.21.1'
        Assert-True ([string]$packageManifest.dependencies.'@agentmemory/agentmemory' -ceq '0.9.27') 'AgentMemory runtime package must be exactly pinned'
        Assert-True ([string]$packageManifest.dependencies.'@agentmemory/mcp' -ceq '0.9.27') 'AgentMemory MCP package must be exactly pinned'
        $lockText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'dependencies\agentmemory-runtime\package-lock.json')
        Assert-True ($lockText -match '"lockfileVersion"\s*:\s*3') 'AgentMemory dependency closure must use lockfileVersion 3'
    }

    Invoke-SecurityTest 'AgentMemory runtime requires an inherited secret and a dedicated install prefix' {
        $runtimeScripts = @(
            'agentmemory-server.ps1',
            'agentmemory-selfheal.ps1',
            'agentmemory-health-daily.ps1',
            'agentmemory-watchdog-register.ps1',
            'health-check.ps1'
        )
        $runtimeText = New-Object System.Collections.Generic.List[string]
        foreach ($path in $runtimeScripts) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $path)
            [void]$runtimeText.Add($text)
            Assert-True ($text.Contains("GetEnvironmentVariable('AGENTMEMORY_SECRET', 'Process')")) "$path must read AGENTMEMORY_SECRET from the inherited process environment"
            Assert-True ($text.Contains('^[A-Za-z0-9_-]{32,256}$')) "$path must enforce the exact URL-safe AgentMemory secret contract"
            Assert-True ($text -match '(?:ValidateRange\(1,\s*5997\)|\.Port\s*-gt\s*5997)') "$path must reject a public AgentMemory port above 5997"
        }

        foreach ($path in @(
            'agentmemory-server.ps1',
            'agentmemory-selfheal.ps1',
            'agentmemory-watchdog-register.ps1',
            'health-check.ps1'
        )) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $path)
            Assert-True ($text.Contains("DefaultRelativePath 'npm-global\agentmemory-runtime'")) "$path must default to the dedicated AgentMemory install prefix"
            Assert-True (-not ($text -match 'DefaultRelativePath\s+[''"]npm-global[''"]')) "$path must not default to the shared npm-global prefix"
        }

        $guardText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-host-guard.mjs')
        Assert-True ($guardText.Contains('process.env.AGENTMEMORY_SECRET')) 'Host guard must require AGENTMEMORY_SECRET from the environment'
        Assert-True ($guardText.Contains('^[A-Za-z0-9_-]{32,256}$')) 'Host guard must enforce the exact URL-safe AgentMemory secret contract'
        Assert-True ($guardText -match 'timingSafeEqual\s*\(') 'Host guard must compare bearer credentials in constant time'

        $supervisorText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-runtime-supervisor.mjs')
        Assert-True ($supervisorText.Contains("shell: false")) 'Runtime supervisor must spawn children without a shell'
        Assert-True ($supervisorText.Contains("stdio: 'inherit'")) 'Runtime supervisor must inherit child stdio'
        Assert-True ($supervisorText.Contains('createIiiEnvironment(inheritedEnvironment)')) 'Runtime supervisor must derive an allowlisted iii environment'
        Assert-True ($supervisorText.Contains('options.iiiExecutable, iiiEnvironment')) 'Runtime supervisor must pass only the allowlisted environment to iii'
        Assert-True (
            $supervisorText -match 'startChild\(\s*[''"]agentmemory[''"]\s*,\s*\[\s*options\.agentmemoryEntry\s*\]\s*\)'
        ) 'Runtime supervisor must directly start the pinned AgentMemory entry'
        Assert-True ($supervisorText.Contains('nodeExecutable ?? process.execPath')) 'Runtime supervisor must reuse the pinned Node executable that launched it'

        $templateText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-iii.yaml')
        Assert-True (-not ($templateText -match '(?mi)^\s*(?:-\s*)?(?:exec|watch)\s*:')) 'Canonical iii config must never launch or watch an external process'
        Assert-True (-not ($templateText -match '__AGENTMEMORY_(?:INSTALL_ROOT|NODE_EXE|GUARD_SCRIPT|SUPERVISOR_SCRIPT)_POSIX__')) 'Canonical iii config must not carry external runtime path tokens'
        $templateDigest = Get-Sha256 -Path (Join-Path $repoRoot 'agentmemory-iii.yaml')
        $serverText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-server.ps1')
        $selfHealText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-selfheal.ps1')
        Assert-True ($serverText.Contains($templateDigest)) 'Server must pin the reviewed canonical iii template digest'
        Assert-True ($selfHealText.Contains($templateDigest)) 'Self-heal must pin the reviewed canonical iii template digest'
        Assert-True ($selfHealText.Contains('Get-AgentMemoryStrictOrphanEvidence')) 'Self-heal must retain strict supervisor-orphan recovery'
        Assert-True ($selfHealText.Contains('CreationDate')) 'Strict orphan recovery must bind process identity to creation time'

        $productionText = (@($runtimeText) + @(
            $guardText,
            $supervisorText,
            (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-iii.yaml')),
            (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-server.cmd'))
        )) -join "`n"
        Assert-True (-not ($productionText -match '(?im)\bAGENTMEMORY_SECRET\s*=\s*["''][A-Za-z0-9_-]{32,256}["'']')) 'Tracked production files must not assign a literal AGENTMEMORY_SECRET'
    }

    Invoke-SecurityTest 'AgentMemory internal listeners use the fixed browser-blocked ports' {
        $serverText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-server.ps1')
        Assert-True ($serverText -match '(?m)^\$script:AgentMemoryInternalRestPort\s*=\s*6000\s*$') 'Internal REST port must remain fixed at 6000'
        Assert-True ($serverText -match '(?m)^\$script:AgentMemoryInternalStreamPort\s*=\s*6667\s*$') 'Internal stream port must remain fixed at 6667'
        Assert-True ($serverText -match '(?m)^\$script:AgentMemoryInternalEnginePort\s*=\s*10080\s*$') 'Internal engine port must remain fixed at 10080'

        $guardText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-host-guard.mjs')
        Assert-True ($guardText -match '(?m)^export const INTERNAL_REST_HOST\s*=\s*''127\.0\.0\.1'';\s*$') 'Host guard upstream must remain loopback-only'
        Assert-True ($guardText -match '(?m)^export const INTERNAL_REST_PORT\s*=\s*6000;\s*$') 'Host guard upstream must remain fixed at port 6000'

        $yamlText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'agentmemory-iii.yaml')
        foreach ($token in @(
            '__AGENTMEMORY_INTERNAL_REST_PORT__',
            '__AGENTMEMORY_STREAM_PORT__',
            '__AGENTMEMORY_ENGINE_PORT__'
        )) {
            Assert-True ($yamlText.Contains($token)) "Canonical AgentMemory template is missing fixed-port token: $token"
        }
    }

    Invoke-SecurityTest 'CI fetches and scans complete history' {
        $workflow = Join-Path $repoRoot '.github\workflows\public-safety.yml'
        Assert-True (Test-Path -LiteralPath $workflow -PathType Leaf) 'Missing public-safety CI workflow'
        $text = Get-Content -Raw -LiteralPath $workflow
        $timeoutMatch = [regex]::Match($text, '(?ms)^  full-history-safety:\s*$.*?^    timeout-minutes:\s*(\d+)\s*$')
        Assert-True $timeoutMatch.Success 'The full-history-safety CI job must declare timeout-minutes'
        if ($timeoutMatch.Success) {
            Assert-True ([int]$timeoutMatch.Groups[1].Value -ge 60) 'The full-history-safety CI job needs at least 60 minutes for dual-host regression and complete-history scans'
        }
        Assert-True ($text -match 'fetch-depth:\s*0') 'CI checkout must use fetch-depth: 0'
        Assert-True ($text -match 'tests\\key-rotator\.test\.mjs') 'CI must run key-rotator behavior tests'
        Assert-True ($text -match 'tests\\agentmemory-host-guard\.test\.mjs') 'CI must run AgentMemory Host guard behavior tests'
        Assert-True ($text -match 'tests\\agentmemory-runtime-supervisor\.test\.mjs') 'CI must run AgentMemory runtime supervisor behavior tests'
        Assert-True ($text -match 'tests\\security\\agentmemory-dependency-lock\.test\.mjs') 'CI must validate the locked AgentMemory dependency closure'
        Assert-True ($text -match 'tests\\core\\RuntimeScripts\.Tests\.ps1') 'CI must run runtime behavior tests'
        Assert-True (([regex]::Matches($text, 'tests\\core\\RuntimeScripts\.Tests\.ps1')).Count -eq 2) 'CI must run runtime behavior tests in both Windows PowerShell 5.1 and PowerShell 7'
        $stepBlocks = @([regex]::Matches($text, '(?ms)^      - name:.*?(?=^      - name:|\z)'))
        $pesterSteps = @($stepBlocks | Where-Object {
                $_.Value -match '(?m)^\s+\$result = Invoke-Pester\b'
            })
        Assert-True ($pesterSteps.Count -eq 8) 'CI must retain exactly eight explicit Invoke-Pester steps'
        foreach ($step in $pesterSteps) {
            Assert-True (
                $step.Value -match '(?m)^\s+\$pester = @\(Import-Module Pester -RequiredVersion 3\.4\.0 -Force -PassThru\)\s*$'
            ) 'Every Invoke-Pester step must explicitly import Pester 3.4.0'
            Assert-True (
                $step.Value -match '(?m)^\s+if \(\$pester\.Count -ne 1 -or \$pester\[0\]\.Version\.ToString\(\) -ne ''3\.4\.0''\) \{ throw ''Unexpected Pester version'' \}\s*$'
            ) 'Every Invoke-Pester step must verify the loaded Pester version'
        }
        Assert-True ($text -match 'tests\\launchers\\Test-LauncherTemplates\.ps1') 'CI must run launcher behavior tests'
        Assert-True ($text -match 'tests\\shell\\ShellReachability\.Tests\.ps1') 'CI must run shell reachability tests'
        Assert-True ($text -match 'tests\\memory\\ingest-lessons\.test\.mjs') 'CI must run memory promotion tests'
        Assert-True ($text -match 'tests\\memory\\IngestLessonsWrapper\.Tests\.ps1') 'CI must run the memory wrapper tests'
        Assert-True ($text -match 'Test-HistorySafety\.ps1') 'CI must run the history safety gate'
        Assert-True ($text -match 'Test-PrePushSafety\.ps1') 'CI must run the pre-push safety gate'
    }
} finally {
    foreach ($root in $temporaryRoots) {
        if ($root -and $root.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "$($failures.Count) public-safety regression test(s) failed"
}

Write-Host 'All public-safety regression tests passed.' -ForegroundColor Green
