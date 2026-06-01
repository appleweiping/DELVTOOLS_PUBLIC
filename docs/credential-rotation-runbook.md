# Credential Rotation Runbook

Use this when a secret-like value is found in tracked files, staged files, generated docs, screenshots, or Git history.

## Rule

Removing a key from the repository is not enough. If the value was ever committed, generated into a public artifact, or shown in a public channel, rotate it at the provider.

## Procedure

1. Identify the provider and scope without pasting the raw key into logs.
2. Revoke or rotate the key in the provider dashboard.
3. Put the replacement only in an environment variable or ignored local file.
4. Remove the key from current files and generated indexes.
5. Run current-tree and staged scans.
6. If the repository is public or will become public, run a history scan and decide whether history rewrite is required.
7. Record the rotation date and provider name in private notes only; do not record the new value.

## Scan Commands

```powershell
$pattern = 'sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'
rg -n -I --pcre2 --with-filename --no-heading $pattern .
git log --all -G $pattern --name-only --pretty=format:"commit %H"
```

Treat placeholder examples as findings until reviewed. Prefer placeholder strings that do not match real provider token formats.
