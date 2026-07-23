@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"

set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
if not defined NO_COLOR set "NO_COLOR=1"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"

set "ARIS_BIN="
if defined ARIS_EXE set "ARIS_BIN=%ARIS_EXE%"
if not defined ARIS_BIN if exist "%DEVTOOLS_ROOT%\aris-code\aris.exe" set "ARIS_BIN=%DEVTOOLS_ROOT%\aris-code\aris.exe"
if not defined ARIS_BIN if exist "%DEVTOOLS_ROOT%\bin\aris.exe" set "ARIS_BIN=%DEVTOOLS_ROOT%\bin\aris.exe"
if not defined ARIS_BIN for /f "delims=" %%F in ('where aris.exe 2^>nul') do if not defined ARIS_BIN set "ARIS_BIN=%%F"

if not defined ARIS_BIN (
  >&2 echo [aris.cmd] ARIS was not found. Set ARIS_EXE or place its executable below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%ARIS_BIN%" %*
