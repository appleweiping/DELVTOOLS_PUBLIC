@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"

set "UV_BIN="
if defined UV_EXE set "UV_BIN=%UV_EXE%"
if not defined UV_BIN if exist "%DEVTOOLS_ROOT%\bin\uv.exe" set "UV_BIN=%DEVTOOLS_ROOT%\bin\uv.exe"
if not defined UV_BIN if exist "%DEVTOOLS_ROOT%\uv\uv.exe" set "UV_BIN=%DEVTOOLS_ROOT%\uv\uv.exe"
if not defined UV_BIN for /f "delims=" %%F in ('where uv.exe 2^>nul') do if not defined UV_BIN set "UV_BIN=%%F"

if not defined UV_BIN (
  >&2 echo [uv.cmd] uv was not found. Set UV_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%UV_BIN%" %*
