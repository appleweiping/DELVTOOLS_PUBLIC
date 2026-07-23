@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"

set "BUN_BIN="
if defined BUN_EXE set "BUN_BIN=%BUN_EXE%"
if not defined BUN_BIN if exist "%DEVTOOLS_ROOT%\bin\bun.exe" set "BUN_BIN=%DEVTOOLS_ROOT%\bin\bun.exe"
if not defined BUN_BIN if exist "%DEVTOOLS_ROOT%\bun\bun.exe" set "BUN_BIN=%DEVTOOLS_ROOT%\bun\bun.exe"
if not defined BUN_BIN if exist "%DEVTOOLS_ROOT%\npm-global\bun.cmd" set "BUN_BIN=%DEVTOOLS_ROOT%\npm-global\bun.cmd"
if not defined BUN_BIN for /f "delims=" %%F in ('where bun.exe 2^>nul') do if not defined BUN_BIN set "BUN_BIN=%%F"

if not defined BUN_BIN (
  >&2 echo [bun.cmd] Bun was not found. Set BUN_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%BUN_BIN%" %*
