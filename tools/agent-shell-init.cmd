@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Explicit arguments win, then environment overrides, then repository-relative defaults.
set "_agentRepoRoot=%~1"
if not defined _agentRepoRoot set "_agentRepoRoot=%DEVTOOLS_REPO_ROOT%"
if not defined _agentRepoRoot for %%I in ("%~dp0..") do set "_agentRepoRoot=%%~fI"

set "_agentLauncherRoot=%~2"
if not defined _agentLauncherRoot set "_agentLauncherRoot=%DEVTOOLS_LAUNCHER_ROOT%"
if not defined _agentLauncherRoot set "_agentLauncherRoot=%_agentRepoRoot%\launchers"

if not exist "%_agentLauncherRoot%\" endlocal & exit /b 0

rem Macro expansion occurs in the interactive shell. Avoid CALL so forwarded
rem arguments and percent signs are not parsed a second time.
for %%F in ("%_agentLauncherRoot%\*.cmd") do (
    if exist "%%~fF" (
        set "_agentMacroName=%%~nF"
        set "_agentMacroPath=%%~fF"
        setlocal EnableDelayedExpansion
        set "_agentMacroPath=!_agentMacroPath:$=$$!"
        doskey !_agentMacroName!="!_agentMacroPath!" $*
        endlocal
    )
)

endlocal & exit /b 0
