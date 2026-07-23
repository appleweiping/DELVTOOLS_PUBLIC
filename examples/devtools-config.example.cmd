@echo off
rem Copy this file to devtools.local.cmd in DEVTOOLS_ROOT and keep that copy ignored.
rem Uncomment only values needed on the local machine. Never commit the populated copy.

rem set "DEVTOOLS_ROOT=<portable-workspace-root>"
rem set "NODE_EXE=<node-executable-path>"
rem set "CODEX_EXE=<codex-executable-path>"
rem set "CLAUDE_EXE=<claude-executable-path>"
rem set "OPENCODE_EXE=<opencode-executable-path>"
rem set "ARIS_EXE=<aris-executable-path>"
rem set "GEMINI_EXE=<gemini-executable-path>"
rem set "CLAUDESEEK_EXE=<claudeseek-executable-path>"
rem set "CLAUDESEEK_ENTRY=<claudeseek-entry-path>"
rem set "HERMES_HOME=<hermes-home-path>"
rem set "HERMES_EXE=<hermes-executable-path>"
rem set "PIXELCAT_EXE=<pixelcat-executable-path>"
rem set "UV_EXE=<uv-executable-path>"
rem set "UVX_EXE=<uvx-executable-path>"
rem set "BUN_EXE=<bun-executable-path>"

rem Provider configuration passes through unchanged; no endpoint is selected here.
rem set "ANTHROPIC_AUTH_TOKEN=<local-value>"
rem set "ANTHROPIC_API_KEY=<local-value>"
rem set "ANTHROPIC_BASE_URL=<provider-endpoint>"
rem set "OPENAI_API_KEY=<local-value>"
rem set "OPENAI_BASE_URL=<provider-endpoint>"
rem set "OPENROUTER_API_KEY=<local-value>"
rem set "OPENROUTER_BASE_URL=<provider-endpoint>"
rem set "DEEPSEEK_API_KEY=<local-value>"
rem set "DEEPSEEK_BASE_URL=<provider-endpoint>"
rem set "DEEPSEEK_MODEL=<model-name>"
rem Agentmemory runtime overrides are intentionally not loaded from this launcher-only file.
rem Pass them as PowerShell parameters or real process/user environment variables.
