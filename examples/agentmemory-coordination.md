# Agentmemory Coordination Examples

These examples show how local agents should coordinate without Agent Hub. They are intentionally small and public-safe.

Every request goes through the authenticated Host guard. Supply the secret to
the invoking process through an operator-controlled environment and keep it out
of scripts, shell history, generated settings, logs, and memory content:

```powershell
if ($env:AGENTMEMORY_SECRET -notmatch '^[A-Za-z0-9_-]{32,256}$') {
  throw 'A valid inherited AGENTMEMORY_SECRET is required'
}
$agentMemoryHeaders = @{ Authorization = "Bearer $env:AGENTMEMORY_SECRET" }
```

## Send A Signal

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://127.0.0.1:3111/agentmemory/signals/send" `
  -Headers $agentMemoryHeaders `
  -ContentType "application/json" `
  -Body (@{
    from = "codex"
    to = "claude"
    type = "handoff"
    content = "Please review the scoped diff and reply with risks only."
  } | ConvertTo-Json)
```

## Create An Action

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://127.0.0.1:3111/agentmemory/actions" `
  -Headers $agentMemoryHeaders `
  -ContentType "application/json" `
  -Body (@{
    title = "Review public README boundary"
    description = "Check that no private paths, keys, or logs are published."
    priority = 2
    project = "devtools"
  } | ConvertTo-Json)
```

## Resolve An Action

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://127.0.0.1:3111/agentmemory/actions/update" `
  -Headers $agentMemoryHeaders `
  -ContentType "application/json" `
  -Body (@{
    actionId = "<action-id>"
    status = "done"
    result = "README boundary reviewed; no secret-bearing files are tracked."
  } | ConvertTo-Json)
```

## Create A Checkpoint

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://127.0.0.1:3111/agentmemory/checkpoints" `
  -Headers $agentMemoryHeaders `
  -ContentType "application/json" `
  -Body (@{
    name = "public-export-ready"
    description = "Current tree, staged diff, and history scan passed."
    type = "external"
  } | ConvertTo-Json)
```

## Rules

- Use signals for handoffs and review requests.
- Use actions for shared work queues.
- Use checkpoints for release gates and irreversible decisions. Valid checkpoint types include `ci`, `approval`, `deploy`, `external`, and `timer`.
- Use git status and explicit context packs as evidence.
- Use only public port `R` through the guard; never call internal iii ports `6000`, `6667`, or `10080` directly.
- Keep public examples independent of private `D:\devtools` configs, automation prompt bodies, logs, DBs, caches, and local memory files.
- Do not revive Agent Hub queues or `hub_*` tools.
