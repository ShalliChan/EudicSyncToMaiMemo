import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

// Match @maimemo/memo-api 1.3.1's public OIDC client and resource requests.
// Keep refresh in memory: the CLI's own refresh writes a config file and drops
// returned refresh tokens, preventing our required rotation detection.
export const issuer = 'https://accounts.maimemo.com/oidc';
export const clientId = '6a2157c1fa31b7c875a8e4ba';
class SafeFailure extends Error {}
const fail = code => { throw new SafeFailure(code); };

export function parseCredentials(json, now = Date.now() / 1000) {
  let config;
  try { config = JSON.parse(json); } catch { fail('credentials_invalid'); }
  const rt = config?.rt;
  if (typeof rt?.token !== 'string' || !rt.token || /\s/.test(rt.token)
      || !Number.isFinite(rt.expireAt)) fail('credentials_invalid');
  if (rt.expireAt <= now + 60) fail('refresh_expired_local');
  return { rt: { token: rt.token, expireAt: rt.expireAt } };
}

export function targetFromWorkflow(text) {
  const matches = [...text.matchAll(/^\s*MaiMemo__DefaultNotepadId:\s*['"]?(np-[A-Za-z0-9_-]+)['"]?\s*$/gm)];
  if (matches.length !== 1) fail('target_configuration_invalid');
  return matches[0][1];
}

async function officialRefresh(rt) {
  const oidc = await import('openid-client');
  const config = await oidc.discovery(new URL(issuer), clientId);
  return oidc.refreshTokenGrant(config, rt);
}

// Only the OAuth token endpoint may receive POST (inside openid-client).
// Resource verification is a single GET. No notepad mutation or sync entry point exists.
export async function verify({ credentials, target, refresh = officialRefresh,
  fetchResource = fetch, log = console.log, mask = () => {} }) {
  const { rt } = parseCredentials(credentials);
  if (!/^np-[A-Za-z0-9_-]+$/.test(target)) fail('target_configuration_invalid');
  mask(rt.token);
  let tokens;
  try { tokens = await refresh(rt.token); }
  catch (error) {
    const code = error?.error;
    if (code === 'invalid_grant') fail('refresh_rejected_reauthorization_required');
    if (code === 'invalid_client' || code === 'unauthorized_client') fail('oauth_client_rejected');
    fail('refresh_failed_network_or_provider');
  }
  if (typeof tokens?.access_token !== 'string' || !tokens.access_token
      || /[\r\n]/.test(tokens.access_token)) fail('access_token_invalid');
  mask(tokens.access_token);
  if (tokens.refresh_token !== undefined) {
    if (typeof tokens.refresh_token !== 'string' || !tokens.refresh_token) fail('refresh_response_invalid');
    mask(tokens.refresh_token);
    if (tokens.refresh_token !== rt.token) fail('refresh_rotated_stop');
  }
  log('phase=refresh success=1 refresh_rotated=0');
  let response, body;
  try {
    response = await fetchResource(`https://open.maimemo.com/open/api/v1/memo/notepads/${encodeURIComponent(target)}`, {
      method: 'GET', redirect: 'error', signal: AbortSignal.timeout(30000),
      headers: { Authorization: `Bearer ${tokens.access_token}`, Accept: 'application/json', 'Content-Type': 'application/json' }
    });
    log(`phase=target_get http_status=${response.status}`);
    body = await response.json();
  } catch { fail('target_request_failed'); }
  if (!response.ok || body?.success === false || (body?.errors?.length ?? 0) > 0) {
    fail(response.status === 401 ? 'target_unauthorized' : 'target_api_rejected');
  }
  const notepad = body?.data?.notepad;
  if (notepad?.id !== target || notepad?.title !== '欧路词典同步（严格）'
      || typeof notepad?.content !== 'string') fail('target_identity_or_shape_mismatch');
  log('phase=target_get target_match=1 strict_target=1');
  log('verification_passed=1 sync_executed=0 credentials_persisted=0');
  return tokens.access_token;
}

export async function authorize(env = process.env, log = console.log) {
  const credentials = env.MAIMEMO_OIDC_CREDENTIALS;
  delete env.MAIMEMO_OIDC_CREDENTIALS;
  if (!credentials) fail('credentials_missing');
  const target = targetFromWorkflow(readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8'));
  const mask = value => {
    if (env.GITHUB_ACTIONS === 'true') {
      log(`::add-mask::${value.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')}`);
    }
  };
  return verify({ credentials, target, log, mask });
}

export function safeFailureCode(error) {
  return error instanceof SafeFailure ? error.message : 'internal_error';
}

// Preserve the read-only entry point: never expose the returned token as output.
export async function main(env = process.env, log = console.log) {
  await authorize(env, log);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(`oauth_verification_failed=${safeFailureCode(error)}`);
    process.exitCode = 1;
  });
}
