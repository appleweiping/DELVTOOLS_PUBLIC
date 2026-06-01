@echo off
setlocal
if exist "D:\devtools\devtools.local.cmd" call "D:\devtools\devtools.local.cmd"
set "PATH=D:\devtools\node;%PATH%"
if defined CODEX_EXE (
  "%CODEX_EXE%" %*
) else (
  codex %*
)
endlocal
