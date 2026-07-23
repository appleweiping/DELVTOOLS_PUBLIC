@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"

set "CODEX_BIN="
if defined CODEX_EXE set "CODEX_BIN=%CODEX_EXE%"
if not defined CODEX_BIN if exist "%DEVTOOLS_ROOT%\bin\codex.exe" set "CODEX_BIN=%DEVTOOLS_ROOT%\bin\codex.exe"

if not defined CODEX_BIN if defined LOCALAPPDATA (
  if exist "%LOCALAPPDATA%\OpenAI\Codex\bin" (
    for /f "delims=" %%D in ('dir /b /a:d /o:-d "%LOCALAPPDATA%\OpenAI\Codex\bin" 2^>nul') do (
      if not defined CODEX_BIN if exist "%LOCALAPPDATA%\OpenAI\Codex\bin\%%D\codex.exe" set "CODEX_BIN=%LOCALAPPDATA%\OpenAI\Codex\bin\%%D\codex.exe"
    )
  )
)

if not defined CODEX_BIN for /f "delims=" %%F in ('where codex.exe 2^>nul') do if not defined CODEX_BIN set "CODEX_BIN=%%F"
if not defined CODEX_BIN (
  >&2 echo [codex.cmd] Codex was not found. Set CODEX_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%CODEX_BIN%" %*
