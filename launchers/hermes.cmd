@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if not defined HERMES_HOME set "HERMES_HOME=%DEVTOOLS_ROOT%\hermes"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"

set "HERMES_BIN="
if defined HERMES_EXE set "HERMES_BIN=%HERMES_EXE%"
if not defined HERMES_BIN if exist "%HERMES_HOME%\.venv\Scripts\hermes.exe" set "HERMES_BIN=%HERMES_HOME%\.venv\Scripts\hermes.exe"
if not defined HERMES_BIN if exist "%DEVTOOLS_ROOT%\bin\hermes.exe" set "HERMES_BIN=%DEVTOOLS_ROOT%\bin\hermes.exe"
if not defined HERMES_BIN for /f "delims=" %%F in ('where hermes.exe 2^>nul') do if not defined HERMES_BIN set "HERMES_BIN=%%F"

if not defined HERMES_BIN (
  >&2 echo [hermes.cmd] Hermes was not found. Set HERMES_EXE or install its environment below HERMES_HOME.
  endlocal & exit /b 2
)

"%HERMES_BIN%" %*
