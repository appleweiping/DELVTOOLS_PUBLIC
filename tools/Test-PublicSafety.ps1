param(
    [string]$Path = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = "Stop"
$resolved = (Resolve-Path -LiteralPath $Path).Path
$pattern = 'sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'

Push-Location $resolved
try {
    $hits = @(rg -n -I --pcre2 --with-filename --no-heading $pattern . 2>$null)
    if ($hits.Count -gt 0) {
        $hits | ForEach-Object {
            [regex]::Replace($_, $pattern, {
                param($m)
                $value = $m.Value
                if ($value.Length -gt 12) {
                    $value.Substring(0, 8) + "..." + $value.Substring($value.Length - 4)
                } else {
                    "[redacted]"
                }
            })
        }
        throw "Strict public-safety scan failed in $resolved"
    }

    Write-Host "Strict public-safety scan passed: $resolved" -ForegroundColor Green
} finally {
    Pop-Location
}
