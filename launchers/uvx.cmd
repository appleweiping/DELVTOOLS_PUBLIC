@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"

set "UVX_BIN="
if defined UVX_EXE set "UVX_BIN=%UVX_EXE%"
if not defined UVX_BIN if exist "%DEVTOOLS_ROOT%\bin\uvx.exe" set "UVX_BIN=%DEVTOOLS_ROOT%\bin\uvx.exe"
if not defined UVX_BIN if exist "%DEVTOOLS_ROOT%\uv\uvx.exe" set "UVX_BIN=%DEVTOOLS_ROOT%\uv\uvx.exe"
if not defined UVX_BIN for /f "delims=" %%F in ('where uvx.exe 2^>nul') do if not defined UVX_BIN set "UVX_BIN=%%F"

if not defined UVX_BIN (
  >&2 echo [uvx.cmd] uvx was not found. Set UVX_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%UVX_BIN%" %*
