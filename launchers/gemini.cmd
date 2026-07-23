@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"
if exist "%DEVTOOLS_ROOT%\npm-global" set "PATH=%DEVTOOLS_ROOT%\npm-global;%PATH%"

set "GEMINI_BIN="
if defined GEMINI_EXE set "GEMINI_BIN=%GEMINI_EXE%"
if not defined GEMINI_BIN if exist "%DEVTOOLS_ROOT%\npm-global\gemini.cmd" set "GEMINI_BIN=%DEVTOOLS_ROOT%\npm-global\gemini.cmd"
if not defined GEMINI_BIN if exist "%DEVTOOLS_ROOT%\bin\gemini.exe" set "GEMINI_BIN=%DEVTOOLS_ROOT%\bin\gemini.exe"
if not defined GEMINI_BIN for /f "delims=" %%F in ('where gemini.exe 2^>nul') do if not defined GEMINI_BIN set "GEMINI_BIN=%%F"

if not defined GEMINI_BIN (
  >&2 echo [gemini.cmd] Gemini CLI was not found. Set GEMINI_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%GEMINI_BIN%" %*
