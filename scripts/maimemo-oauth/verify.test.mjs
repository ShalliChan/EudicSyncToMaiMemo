import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseCredentials, targetFromWorkflow, verify } from './verify.mjs';

const rt = 'private-refresh-fixture';
const at = 'private-access-fixture';
const target = 'np-private-fixture';
const credentials = JSON.stringify({ rt: { token: rt, expireAt: 4102444800 } });
const body = { data: { notepad: { id: target, title: '欧路词典同步（严格）', content: '# 欧路词典同步\nPRIVATE-BODY' } } };

async function scenario({ tokens = { access_token: at }, refreshError, fetchError,
  responseBody = body, status = 200, input = credentials } = {}) {
  const logs = [], masks = [], calls = [];
  let failure;
  try {
    await verify({ credentials: input, target, log: line => logs.push(line), mask: value => masks.push(value),
      refresh: async value => {
        assert.equal(value, rt);
        calls.push('refresh');
        if (refreshError) throw refreshError;
        return tokens;
      },
      fetchResource: async (url, options) => {
        calls.push('get');
        assert.equal(url, `https://open.maimemo.com/open/api/v1/memo/notepads/${target}`);
        assert.equal(options.method, 'GET');
        assert.equal(options.redirect, 'error');
        assert.equal(options.headers.Authorization, `Bearer ${at}`);
        assert.equal(options.body, undefined);
        if (fetchError) throw fetchError;
        return { ok: status === 200, status, json: async () => responseBody };
      }
    });
  } catch (error) { failure = error; }
  for (const secret of [rt, at, target, 'PRIVATE-BODY', 'raw-secret-in-error']) {
    assert.ok(!logs.join('\n').includes(secret));
  }
  return { logs, masks, calls, failure };
}

test('two independent invocations refresh the same original credential and GET only', async () => {
  for (let i = 0; i < 2; i++) {
    const result = await scenario();
    assert.equal(result.failure, undefined);
    assert.deepEqual(result.calls, ['refresh', 'get']);
    assert.deepEqual(result.masks, [rt, at]);
    assert.ok(result.logs.includes('verification_passed=1 sync_executed=0 credentials_persisted=0'));
  }
});
test('unchanged refresh token in response is allowed', async () => {
  assert.equal((await scenario({ tokens: { access_token: at, refresh_token: rt } })).failure, undefined);
});
test('rotated refresh token stops before any resource request', async () => {
  const result = await scenario({ tokens: { access_token: at, refresh_token: 'rotated-private-fixture' } });
  assert.equal(result.failure.message, 'refresh_rotated_stop');
  assert.deepEqual(result.calls, ['refresh']);
  assert.ok(result.masks.includes('rotated-private-fixture'));
});
test('invalid grant requires reauthorization without exposing response', async () => {
  const result = await scenario({ refreshError: { error: 'invalid_grant', error_description: 'raw-secret-in-error' } });
  assert.equal(result.failure.message, 'refresh_rejected_reauthorization_required');
  assert.deepEqual(result.calls, ['refresh']);
});
test('network errors are not labeled expired', async () => {
  const result = await scenario({ refreshError: new Error('raw-secret-in-error') });
  assert.equal(result.failure.message, 'refresh_failed_network_or_provider');
});
test('client rejection is separate from user expiry', async () => {
  assert.equal((await scenario({ refreshError: { error: 'invalid_client' } })).failure.message, 'oauth_client_rejected');
});
test('expired and malformed credentials never reach network', async () => {
  for (const input of ['{', '{}', JSON.stringify({ rt: { token: rt, expireAt: 1 } }), JSON.stringify({ rt: { token: rt, expireAt: '4102444800' } })]) {
    const result = await scenario({ input });
    assert.ok(result.failure);
    assert.deepEqual(result.calls, []);
  }
});
test('import shape drops fixed token and access token', () => {
  const value = parseCredentials(JSON.stringify({ rt: { token: rt, expireAt: 4102444800 }, apiToken: 'old', at: { token: at } }));
  assert.deepEqual(Object.keys(value), ['rt']);
});
test('missing/invalid access token or malformed refresh token stops', async () => {
  for (const tokens of [{}, { access_token: 'bad\nheader' }, { access_token: at, refresh_token: '' }]) {
    const result = await scenario({ tokens });
    assert.ok(result.failure);
    assert.deepEqual(result.calls, ['refresh']);
  }
});
test('401 and API business errors fail verification', async () => {
  assert.equal((await scenario({ status: 401 })).failure.message, 'target_unauthorized');
  assert.equal((await scenario({ responseBody: { success: false } })).failure.message, 'target_api_rejected');
  assert.equal((await scenario({ responseBody: { errors: [{}] } })).failure.message, 'target_api_rejected');
});
test('wrong identity/title or missing content cannot pass', async () => {
  for (const notepad of [{ ...body.data.notepad, id: 'np-wrong' }, { ...body.data.notepad, title: 'old notebook' }, { id: target, title: body.data.notepad.title }]) {
    assert.equal((await scenario({ responseBody: { data: { notepad } } })).failure.message, 'target_identity_or_shape_mismatch');
  }
});
test('resource network errors are sanitized', async () => {
  assert.equal((await scenario({ fetchError: new Error('raw-secret-in-error') })).failure.message, 'target_request_failed');
});
test('target uses existing sync configuration; ambiguity fails closed', () => {
  assert.equal(targetFromWorkflow(`env:\n  MaiMemo__DefaultNotepadId: '${target}'\n`), target);
  assert.throws(() => targetFromWorkflow('MaiMemo__DefaultNotepadId: ${{ secrets.ID }}'));
  assert.throws(() => targetFromWorkflow(`MaiMemo__DefaultNotepadId: ${target}\nMaiMemo__DefaultNotepadId: ${target}`));
  assert.ok(targetFromWorkflow(readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8')).startsWith('np-'));
});
test('verification workflow requires two sequential jobs without credential outputs/artifacts', () => {
  const yaml = readFileSync(new URL('../../.github/workflows/maimemo-oauth-verify.yml', import.meta.url), 'utf8');
  assert.match(yaml, /needs: first-runner/);
  assert.equal((yaml.match(/runs-on: ubuntu-latest/g) ?? []).length, 2);
  assert.equal((yaml.match(/secrets\.MAIMEMO_OIDC_CREDENTIALS/g) ?? []).length, 2);
  assert.ok(!/upload-artifact|GITHUB_OUTPUT|GITHUB_ENV|sync-once|schedule:/.test(yaml));
  for (const file of ['sync.yml', 'maimemo-diagnostics.yml', 'prepare-strict-notepad.yml', 'maimemo-oauth-verify.yml']) {
    const value = readFileSync(new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8');
    assert.match(value, /group: maimemo-user-authorization/);
    assert.match(value, /cancel-in-progress: false/);
  }
});
