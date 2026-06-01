@echo off
setlocal
set "PATH=D:\devtools\node;%PATH%"

rem Lightweight Codex launcher. Keeps agentmemory available and disables optional heavy integrations for this invocation.

if defined CODEX_EXE (
  set "CODEX_BIN=%CODEX_EXE%"
) else (
  set "CODEX_BIN=codex"
)

"%CODEX_BIN%" ^
  -c mcp_servers.claude_review.enabled=false ^
  -c mcp_servers.deepseek.enabled=false ^
  -c mcp_servers.windows_mcp.enabled=false ^
  -c model_reasoning_effort="medium" ^
  %*

endlocal
