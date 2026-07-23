@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"
if exist "%DEVTOOLS_ROOT%\npm-global" set "PATH=%DEVTOOLS_ROOT%\npm-global;%PATH%"
if exist "%DEVTOOLS_ROOT%\npm-global\node_modules\.bin" set "PATH=%DEVTOOLS_ROOT%\npm-global\node_modules\.bin;%PATH%"

set "OPENCODE_BIN="
if defined OPENCODE_EXE set "OPENCODE_BIN=%OPENCODE_EXE%"
if not defined OPENCODE_BIN if exist "%DEVTOOLS_ROOT%\npm-global\opencode.cmd" set "OPENCODE_BIN=%DEVTOOLS_ROOT%\npm-global\opencode.cmd"
if not defined OPENCODE_BIN if exist "%DEVTOOLS_ROOT%\bin\opencode.exe" set "OPENCODE_BIN=%DEVTOOLS_ROOT%\bin\opencode.exe"
if not defined OPENCODE_BIN for /f "delims=" %%F in ('where opencode.exe 2^>nul') do if not defined OPENCODE_BIN set "OPENCODE_BIN=%%F"

if not defined OPENCODE_BIN (
  >&2 echo [opencode.cmd] OpenCode was not found. Set OPENCODE_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%OPENCODE_BIN%" %*
