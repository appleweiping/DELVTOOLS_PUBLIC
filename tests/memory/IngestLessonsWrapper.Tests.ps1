$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$wrapper = Join-Path $repoRoot 'scripts\ingest-lessons.ps1'

Describe 'lesson ingest PowerShell wrapper' {
    It 'parses and contains no hard-coded private workstation root' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $wrapper,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should Be 0
        (Get-Content -LiteralPath $wrapper -Raw) | Should Not Match 'D:\\devtools'
    }

    It 'forwards explicit paths, dry-run, and the child exit code' {
        $fakeNode = Join-Path $TestDrive 'fake-node.cmd'
        $capture = Join-Path $TestDrive 'captured-arguments.txt'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $batch = @(
            '@echo off',
            '>"%LESSON_WRAPPER_CAPTURE%" echo %*',
            'echo wrapper-summary',
            'exit /b 37'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText(
            $fakeNode,
            ($batch + "`r`n"),
            $utf8
        )

        $previousCapture = $env:LESSON_WRAPPER_CAPTURE
        try {
            $env:LESSON_WRAPPER_CAPTURE = $capture
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper `
                -DryRun `
                -DevToolsRoot (Join-Path $TestDrive 'runtime root') `
                -PendingRoot (Join-Path $TestDrive 'pending lessons') `
                -IngestedRoot (Join-Path $TestDrive 'ingested lessons') `
                -ClientModule (Join-Path $TestDrive 'client module.mjs') `
                -AgentMemoryUrl 'http://127.0.0.1:4111' `
                -TimeoutMs 1234 `
                -ResolvePrepared (('a' * 64) + '=retry') `
                -BreakStaleLock ((('b' * 64) + '=00000000-0000-4000-8000-000000000000')) `
                -NodeExe $fakeNode 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $env:LESSON_WRAPPER_CAPTURE = $previousCapture
        }

        $exitCode | Should Be 37
        ($output -join "`n") | Should Match 'wrapper-summary'
        $arguments = Get-Content -LiteralPath $capture -Raw
        $arguments | Should Match '--dry-run'
        $arguments | Should Match '--pending-root'
        $arguments | Should Match '--ingested-root'
        $arguments | Should Match '--client'
        $arguments | Should Match '--agentmemory-url'
        $arguments | Should Match '--timeout-ms'
        $arguments | Should Match '--resolve-prepared'
        $arguments | Should Match '--break-stale-lock'
        $arguments | Should Match '127\.0\.0\.1:4111'
    }
}
