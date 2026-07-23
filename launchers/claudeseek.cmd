@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"

if defined CLAUDESEEK_EXE goto :run_executable

if not defined CLAUDESEEK_ENTRY set "CLAUDESEEK_ENTRY=%DEVTOOLS_ROOT%\claudeseek\bin\claudeseek.js"
if not exist "%CLAUDESEEK_ENTRY%" (
  >&2 echo [claudeseek.cmd] Entry point not found. Set CLAUDESEEK_EXE or CLAUDESEEK_ENTRY.
  endlocal & exit /b 2
)

set "NODE_BIN="
if defined NODE_EXE set "NODE_BIN=%NODE_EXE%"
if not defined NODE_BIN if exist "%DEVTOOLS_ROOT%\node\node.exe" set "NODE_BIN=%DEVTOOLS_ROOT%\node\node.exe"
if not defined NODE_BIN for /f "delims=" %%F in ('where node.exe 2^>nul') do if not defined NODE_BIN set "NODE_BIN=%%F"
if not defined NODE_BIN (
  >&2 echo [claudeseek.cmd] Node.js was not found. Set NODE_EXE.
  endlocal & exit /b 2
)

"%NODE_BIN%" "%CLAUDESEEK_ENTRY%" %*
exit /b %ERRORLEVEL%

:run_executable
"%CLAUDESEEK_EXE%" %*
