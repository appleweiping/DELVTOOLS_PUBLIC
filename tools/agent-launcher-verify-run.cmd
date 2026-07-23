@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0agent-launcher-verify-run.ps1" -SettingsPath "%~1"
set "AGENT_LAUNCHER_VERIFY_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AGENT_LAUNCHER_VERIFY_EXIT%
