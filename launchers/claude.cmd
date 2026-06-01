@echo off
setlocal
set "PATH=D:\devtools\node;D:\devtools\npm-global;%PATH%"
if exist "D:\devtools\devtools.local.cmd" call "D:\devtools\devtools.local.cmd"
if not defined ANTHROPIC_BASE_URL set "ANTHROPIC_BASE_URL=http://127.0.0.1:8990"
if not defined ANTHROPIC_AUTH_TOKEN (
  echo [claude.cmd] ANTHROPIC_AUTH_TOKEN is not set.
  echo Create D:\devtools\devtools.local.cmd or set it in the environment.
  exit /b 2
)

if defined CLAUDE_EXE (
  "%CLAUDE_EXE%" %*
) else (
  claude %*
)

endlocal
