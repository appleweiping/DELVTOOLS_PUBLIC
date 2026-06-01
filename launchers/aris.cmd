@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "NO_COLOR=1"
if exist "D:\devtools\devtools.local.cmd" call "D:\devtools\devtools.local.cmd"
if not defined OPENAI_API_KEY (
  echo [aris.cmd] OPENAI_API_KEY is not set.
  echo Create D:\devtools\devtools.local.cmd or set it in the environment.
  exit /b 2
)
if not defined OPENAI_BASE_URL set "OPENAI_BASE_URL=https://api.openai.com/v1"
if defined ARIS_EXE (
  "%ARIS_EXE%" %*
) else (
  aris %*
)
exit /b %ERRORLEVEL%
