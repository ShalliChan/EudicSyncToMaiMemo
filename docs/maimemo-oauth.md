# MaiMemo OAuth staged rollout

Stage 1 adds only credential import and a manual two-runner verification workflow.
`Sync Words` and the existing diagnostics still use `MAIMEMO_TOKEN` as before.
No automatic switch or real sync is performed by the verification workflow.

## Windows initial authorization

Use Node.js 22+ and GitHub CLI (`gh`). If GitHub CLI is absent, install it with
`winget install --id GitHub.cli --exact`, then reopen PowerShell.

```powershell
Set-Location C:\Users\888\EudicSyncToMaiMemo
npx --yes --package=@maimemo/memo-api@1.2.0 memo-api auth login
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

Open Actions -> **MaiMemo OAuth Verification (two runners)** -> Run workflow -> main.
The second job runs on another fresh GitHub-hosted runner only after the first
succeeds. Both refresh the same original Secret, then GET the exact target from
`sync.yml`; identity, strict notebook name, and content shape must match.
Success in both jobs must include:

```text
phase=refresh success=1 refresh_rotated=0
phase=target_get http_status=200
phase=target_get target_match=1 strict_target=1
verification_passed=1 sync_executed=0 credentials_persisted=0
```

The OAuth token endpoint receives the required refresh grant POST. Resource API
access is GET only: no notepad create/update/delete, no .NET sync invocation,
no credentials written to disk or artifacts, and no Secret write permission.
The pinned `openid-client` library matches the official CLI's OAuth mechanism.

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

Only after both real jobs pass should a later change connect refreshed access
tokens to the existing .NET process via its private `MaiMemo__Token` environment.
Never use command-line tokens, `$GITHUB_OUTPUT`, caches, or artifacts for credentials.
All workflows that use this authorization share one concurrency group and do not
cancel active runs. Local use of the same grant should not overlap cloud tests.
No automatic token persistence is implemented: rotation deliberately stops rollout.

Official references:
- https://github.com/maimemo/memo-api-cli/blob/main/src/lib/oidc.ts
- https://github.com/maimemo/memo-api-cli/blob/main/src/lib/auth.ts
- https://github.com/maimemo/memo-api-cli/blob/main/docs/plans/auth.md
