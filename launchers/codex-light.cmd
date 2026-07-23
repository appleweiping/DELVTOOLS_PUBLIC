@echo off
setlocal
for %%I in ("%~dp0..") do set "SCRIPT_DEVTOOLS_ROOT=%%~fI"
if not defined DEVTOOLS_ROOT set "DEVTOOLS_ROOT=%SCRIPT_DEVTOOLS_ROOT%"

rem CODEX_EXE and local configuration are consumed by codex.cmd.
"%~dp0codex.cmd" ^
  -c mcp_servers.claude_review.enabled=false ^
  -c mcp_servers.deepseek.enabled=false ^
  -c mcp_servers.windows_mcp.enabled=false ^
  -c model_reasoning_effort="medium" ^
  %*
