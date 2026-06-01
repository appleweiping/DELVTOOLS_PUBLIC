# Agentmemory Coordination Examples

These examples show how local agents should coordinate without Agent Hub. They are intentionally small and public-safe.

## Send A Signal

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://localhost:3111/agentmemory/signals/send" `
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
  -Uri "http://localhost:3111/agentmemory/actions" `
  -ContentType "application/json" `
  -Body (@{
    title = "Review public README boundary"
    description = "Check that no private paths, keys, or logs are published."
    priority = 2
    project = "devtools-public"
  } | ConvertTo-Json)
```

## Resolve An Action

```powershell
Invoke-RestMethod -Method Post `
  -Uri "http://localhost:3111/agentmemory/actions/update" `
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
  -Uri "http://localhost:3111/agentmemory/checkpoints" `
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
- Do not revive Agent Hub queues or `hub_*` tools.
