@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if not defined KEY_ROTATOR_LOCAL_CMD set "KEY_ROTATOR_LOCAL_CMD=%DEVTOOLS_ROOT%\key-rotator.local.cmd"
if exist "%KEY_ROTATOR_LOCAL_CMD%" call "%KEY_ROTATOR_LOCAL_CMD%"

if not defined ROTATOR_KEYS (
  >&2 echo [key-rotator.cmd] ROTATOR_KEYS is not set. Use an ignored local file or the process environment.
  endlocal & exit /b 2
)
if not defined ROTATOR_TARGETS (
  >&2 echo [key-rotator.cmd] ROTATOR_TARGETS is not set. Use an ignored local file or the process environment.
  endlocal & exit /b 2
)
if not defined ROTATOR_PROXY_TOKEN (
  >&2 echo [key-rotator.cmd] ROTATOR_PROXY_TOKEN is not set. Use an ignored local file or the process environment.
  endlocal & exit /b 2
)

if not defined KEY_ROTATOR_SCRIPT set "KEY_ROTATOR_SCRIPT=%DEVTOOLS_ROOT%\key-rotator.mjs"
if not exist "%KEY_ROTATOR_SCRIPT%" (
  >&2 echo [key-rotator.cmd] Script not found. Set KEY_ROTATOR_SCRIPT.
  endlocal & exit /b 2
)

set "NODE_BIN="
if defined NODE_EXE goto :explicit_node
if not defined NODE_BIN if exist "%DEVTOOLS_ROOT%\node\node.exe" set "NODE_BIN=%DEVTOOLS_ROOT%\node\node.exe"
if not defined NODE_BIN (
  >&2 echo [key-rotator.cmd] Pinned Node.js was not found. Set NODE_EXE to an absolute path or install DEVTOOLS_ROOT\node\node.exe.
  endlocal & exit /b 2
)
goto :validate_node

:explicit_node
set "NODE_BIN=%NODE_EXE%"
if "%NODE_BIN:~1,2%"==":\" goto :validate_node
if "%NODE_BIN:~0,2%"=="\\" goto :validate_node
>&2 echo [key-rotator.cmd] NODE_EXE must be an absolute path.
endlocal & exit /b 2

:validate_node
if not exist "%NODE_BIN%" (
  >&2 echo [key-rotator.cmd] Node.js executable was not found at the configured path.
  endlocal & exit /b 2
)
for %%I in ("%NODE_BIN%") do set "NODE_BIN=%%~fI"

:node_ready
start "" /min "%NODE_BIN%" "%KEY_ROTATOR_SCRIPT%" %*
set "LAUNCH_EXIT=%ERRORLEVEL%"
endlocal & exit /b %LAUNCH_EXIT%
