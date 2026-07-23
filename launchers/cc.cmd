@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"

rem Short alias. CLAUDE_EXE and local configuration are consumed by claude.cmd.
"%~dp0claude.cmd" %*
