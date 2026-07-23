@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"
if exist "%DEVTOOLS_ROOT%\node" set "PATH=%DEVTOOLS_ROOT%\node;%PATH%"
if exist "%DEVTOOLS_ROOT%\npm-global" set "PATH=%DEVTOOLS_ROOT%\npm-global;%PATH%"

set "CLAUDE_BIN="
if defined CLAUDE_EXE set "CLAUDE_BIN=%CLAUDE_EXE%"
if not defined CLAUDE_BIN if exist "%DEVTOOLS_ROOT%\npm-global\node_modules\@anthropic-ai\claude-code\bin\claude.exe" set "CLAUDE_BIN=%DEVTOOLS_ROOT%\npm-global\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
if not defined CLAUDE_BIN if exist "%DEVTOOLS_ROOT%\npm-global\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe" set "CLAUDE_BIN=%DEVTOOLS_ROOT%\npm-global\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe"
if not defined CLAUDE_BIN if exist "%DEVTOOLS_ROOT%\npm-global\claude.cmd" set "CLAUDE_BIN=%DEVTOOLS_ROOT%\npm-global\claude.cmd"
if not defined CLAUDE_BIN for /f "delims=" %%F in ('where claude.exe 2^>nul') do if not defined CLAUDE_BIN set "CLAUDE_BIN=%%F"

if not defined CLAUDE_BIN (
  >&2 echo [claude.cmd] Claude Code was not found. Set CLAUDE_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

"%CLAUDE_BIN%" %*
