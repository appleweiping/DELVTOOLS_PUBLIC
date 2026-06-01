@echo off
rem Optional PixelCat launcher with WebView2 GPU disabled.
set "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu --disable-gpu-compositing --disable-gpu-sandbox"
if defined PIXELCAT_EXE (
  start "" "%PIXELCAT_EXE%"
) else (
  start "" "D:\devtools\pixelcat-app.exe"
)
