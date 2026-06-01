@echo off
rem PixelCat launcher for Claude-family tools.
rem Keep this service available while using Claude Code.
set "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu --disable-gpu-compositing --disable-gpu-sandbox"
if defined PIXELCAT_EXE (
  start "" "%PIXELCAT_EXE%"
) else (
  start "" "D:\devtools\pixelcat-app.exe"
)
