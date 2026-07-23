@echo off
setlocal DisableDelayedExpansion
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0agentmemory-selfheal.ps1" %*
set "AGENTMEMORY_SERVER_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AGENTMEMORY_SERVER_EXIT%
