@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"
if not defined DEVTOOLS_LOCAL_CMD set "DEVTOOLS_LOCAL_CMD=%DEVTOOLS_ROOT%\devtools.local.cmd"
if exist "%DEVTOOLS_LOCAL_CMD%" call "%DEVTOOLS_LOCAL_CMD%"

if not defined WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS set "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu --disable-gpu-compositing --disable-gpu-sandbox"
set "PIXELCAT_BIN="
if defined PIXELCAT_EXE set "PIXELCAT_BIN=%PIXELCAT_EXE%"
if not defined PIXELCAT_BIN if exist "%DEVTOOLS_ROOT%\pixelcat-app.exe" set "PIXELCAT_BIN=%DEVTOOLS_ROOT%\pixelcat-app.exe"
if not defined PIXELCAT_BIN if exist "%DEVTOOLS_ROOT%\pixelcat\PixelCat.exe" set "PIXELCAT_BIN=%DEVTOOLS_ROOT%\pixelcat\PixelCat.exe"

if not defined PIXELCAT_BIN (
  >&2 echo [pixelcat.cmd] PixelCat was not found. Set PIXELCAT_EXE or install it below DEVTOOLS_ROOT.
  endlocal & exit /b 2
)

if exist "%PIXELCAT_BIN%" goto :pixelcat_ready
set "PIXELCAT_RESOLVED="
for /f "delims=" %%F in ('where "%PIXELCAT_BIN%" 2^>nul') do if not defined PIXELCAT_RESOLVED set "PIXELCAT_RESOLVED=%%F"
if defined PIXELCAT_RESOLVED set "PIXELCAT_BIN=%PIXELCAT_RESOLVED%"
if not defined PIXELCAT_RESOLVED (
  >&2 echo [pixelcat.cmd] PixelCat command was not found: %PIXELCAT_BIN%
  endlocal & exit /b 2
)

:pixelcat_ready
start "" "%PIXELCAT_BIN%" %*
set "LAUNCH_EXIT=%ERRORLEVEL%"
endlocal & exit /b %LAUNCH_EXIT%
