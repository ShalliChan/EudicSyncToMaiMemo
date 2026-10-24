# MaiMemo OAuth authentication

`Sync Words` defaults to OAuth for daily and manual runs. The read-only diagnostics
also refresh OAuth credentials. The separate verification workflow never runs sync.
No Secrets are updated automatically.

## Windows initial authorization

Use Node.js 22+ and GitHub CLI (`gh`). If GitHub CLI is absent, install it with
`winget install --id GitHub.cli --exact`, then reopen PowerShell.

```powershell
Set-Location C:\Users\888\EudicSyncToMaiMemo
npx --yes --package=@maimemo/memo-api@1.3.1 memo-api auth login
gh auth login --hostname github.com --web --git-protocol https
pwsh -File .\scripts\import-maimemo-oauth.ps1
```

The first command opens the official consent flow. Log in to the MaiMemo account
owning the strict notebook. Do not use `--verbose`. The CLI stores credentials in
the Windows user's `.config/memo-api.json`; protect it with the user's Windows ACL.
Never paste, print, commit, or upload this file as an artifact.

The import reads that file locally, strips the fixed `apiToken` and access token,
and sends only `rt.token` and `rt.expireAt` through GitHub CLI standard input to
`MAIMEMO_OIDC_CREDENTIALS` in `ShalliChan/EudicSyncToMaiMemo`. The original
`MAIMEMO_TOKEN` is untouched. An existing authorized GitHub CLI login can be reused.

## Manual cloud verification

Existing imported credentials are reused; upgrading does not require logging in again.
Open Actions -> **MaiMemo OAuth Verification (preflight + two runners)** -> Run workflow -> main.
A preflight refresh and GET must succeed before two further fresh GitHub-hosted
runners execute sequentially. All three refresh the same original Secret, then GET the exact target from
`sync.yml`; identity, strict notebook name, and content shape must match.
Success in all three jobs must include:

```text
phase=refresh success=1 refresh_rotated=0
phase=target_get http_status=200
phase=target_get target_match=1 strict_target=1
verification_passed=1 sync_executed=0 credentials_persisted=0
```

The OAuth token endpoint receives the required refresh grant POST. Resource API
access is GET only: no notepad create/update/delete, no .NET sync invocation,
no credentials written to disk or artifacts, and no Secret write permission.
The published official CLI is locked to version 1.3.1; compatibility tests compare
its actual OIDC client, refresh call, resource URL and Bearer headers with the
memory-only verifier. The pinned `openid-client` library performs that same refresh.
The CLI's refresh helper is intentionally not invoked: it writes credentials to
disk and discards any new refresh token, whereas this verifier must stop on rotation.

## Stop conditions and next stage

- `refresh_rotated_stop`: a different refresh token was returned. Stop rollout;
  do not try the original credential again or add insecure persistence.
- `refresh_rejected_reauthorization_required`: the grant was rejected. Stop rollout.
- `refresh_expired_local`: the CLI's original local expiry was reached. Reauthorize.
- `refresh_failed_network_or_provider`: not proof of expiry; preserve the Secret.
- Any target access or identity error: stop rollout; do not run sync.

The official CLI records a 90-day local refresh expiry and currently retains the
same refresh token. Do not reset that expiry on daily refresh. Real server policy
and cross-runner reuse must be verified, not inferred from mocked tests.

After three successful independent checks and explicit user confirmation, the
workflow passes refreshed access tokens through the .NET child process environment.
Never use command-line tokens, `$GITHUB_OUTPUT`, caches, or artifacts for credentials.
All workflows that use this authorization share one concurrency group and do not
cancel active runs. Local use of the same grant should not overlap cloud tests.
No automatic token persistence is implemented: rotation deliberately stops rollout.

## Enabled workflow and manual fallback

Run 40079120393 on commit 4eb5d33 passed preflight and two further independent
runners. All three refreshed the original Secret, reported no rotation and GET
200 with the strict target identity matching. No sync or credential writes ran.

`run-sync.mjs` is covered by unit tests with mocked process launchers. The formal
workflow invokes it with `MAIMEMO_OAUTH_SYNC_CONFIRMED=true`. It verifies
the configured target, refreshes and GET-verifies the notebook before starting
the same existing .NET command. Access tokens travel only through the child
environment; refresh credentials are excluded. OAuth failures stop the run rather
than silently using the fixed token.

The workflow installs the locked CLI 1.3.1 and OAuth dependencies and uses the
existing `MAIMEMO_OIDC_CREDENTIALS`. Business logic, target ID and the 09:05 Beijing
daily schedule remain unchanged. In Actions -> Sync Words -> Run workflow,
`authentication=oauth` is the default; choose `fixed` explicitly only for manual
fallback. That branch alone receives the existing `MAIMEMO_TOKEN`. OAuth failure
never starts the fallback branch. Secrets remain unchanged.

The diagnostics workflow uses `run-sync.mjs --diagnose`, which launches only the
existing PowerShell GET audit with its refreshed access token in the child
environment. It never invokes .NET sync. Both workflows share the authorization
concurrency group. No diagnostics or sync run writes new refresh credentials.

When the refresh grant expires or is revoked, repeat the Windows login and import.
The current local expiry remains 90 days from initial login, not from each refresh.
If no titles are new, sync intentionally sends no update request: success then
verifies read access and idempotence, but is not a real write-permission test.

Official references:
- https://github.com/maimemo/memo-api-cli/blob/main/src/lib/oidc.ts
- https://github.com/maimemo/memo-api-cli/blob/main/src/lib/auth.ts
- https://github.com/maimemo/memo-api-cli/blob/main/docs/plans/auth.md
