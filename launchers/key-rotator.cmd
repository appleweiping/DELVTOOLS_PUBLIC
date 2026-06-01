@echo off
setlocal
if exist "D:\devtools\key-rotator.local.cmd" call "D:\devtools\key-rotator.local.cmd"
if not defined ROTATOR_PORT set "ROTATOR_PORT=9100"
if not defined ROTATOR_KEYS (
  echo [key-rotator.cmd] ROTATOR_KEYS is not set.
  echo Create D:\devtools\key-rotator.local.cmd or set ROTATOR_KEYS/ROTATOR_TARGETS in the environment.
  exit /b 2
)
if not defined ROTATOR_TARGETS (
  echo [key-rotator.cmd] ROTATOR_TARGETS is not set.
  echo Create D:\devtools\key-rotator.local.cmd or set ROTATOR_KEYS/ROTATOR_TARGETS in the environment.
  exit /b 2
)
if defined NODE_EXE (
  start /min "" "%NODE_EXE%" "D:\devtools\key-rotator.mjs"
) else (
  start /min "" node "D:\devtools\key-rotator.mjs"
)
endlocal
