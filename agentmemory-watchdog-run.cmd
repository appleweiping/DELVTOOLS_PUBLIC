@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0agentmemory-watchdog-run.ps1" -SettingsPath "%~1"
set "AGENTMEMORY_WATCHDOG_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AGENTMEMORY_WATCHDOG_EXIT%
