$ErrorActionPreference = 'SilentlyContinue'
$existing = Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -eq 3111 }
if ($existing) { exit 0 }
$env:PATH = 'D:\devtools;D:\devtools\node;D:\devtools\pwsh;D:\devtools\dotnet;D:\devtools\aris-code;C:\Users\admin\AppData\Roaming\npm;' + $env:PATH
$env:AGENTMEMORY_TOOLS = 'all'
$env:AGENTMEMORY_SLOTS = 'true'
$env:AGENTMEMORY_URL = 'http://localhost:3111'
$stdout = 'D:\devtools\logs\agentmemory.out.log'
$stderr = 'D:\devtools\logs\agentmemory.err.log'
Start-Process -FilePath 'C:\Users\admin\AppData\Roaming\npm\agentmemory.cmd' -ArgumentList @('--tools','all') -WorkingDirectory 'C:\Users\admin' -WindowStyle Minimized -RedirectStandardOutput $stdout -RedirectStandardError $stderr
