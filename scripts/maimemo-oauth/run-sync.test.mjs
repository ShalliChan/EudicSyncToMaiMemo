import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runSync } from './run-sync.mjs';

const env = () => ({ MAIMEMO_OAUTH_SYNC_CONFIRMED: 'true', MaiMemo__DefaultNotepadId: 'np-fixture',
  MAIMEMO_OIDC_CREDENTIALS: 'private-refresh', MaiMemo__Token: 'old-fixed', MAIMEMO_API_TOKEN: 'old-alias',
  MAIMEMO_TOKEN: 'old-token', Eudic__Authorization: 'eudic-fixture' });
const configuredTarget = () => 'np-fixture';
test('refresh and verify before launching the unchanged .NET sync command', async () => {
  const events = [];
  const code = await runSync({ env: env(), configuredTarget,
    getToken: async () => { events.push('authorized'); return 'new-private-access'; },
    launch: (command, args, options) => {
      events.push('launch');
      assert.equal(command, 'dotnet');
      assert.equal(args.at(-1), '--sync-once');
      assert.ok(args.includes('Release'));
      assert.ok(!args.join(' ').includes('private'));
      assert.equal(options.env.MaiMemo__Token, 'new-private-access');
      assert.equal(options.env.MaiMemo__DefaultNotepadId, 'np-fixture');
      assert.equal(options.env.Eudic__Authorization, 'eudic-fixture');
      assert.equal(options.env.MaiMemo__Provider, 'OpenApi');
      for (const key of ['MAIMEMO_OIDC_CREDENTIALS', 'MAIMEMO_TOKEN', 'MAIMEMO_API_TOKEN']) assert.equal(options.env[key], undefined);
      return { status: 0 };
    } });
  assert.equal(code, 0);
  assert.deepEqual(events, ['authorized', 'launch']);
});
test('no activation without explicit rollout flag', async () => {
  await assert.rejects(runSync({ env: {}, getToken: () => assert.fail(), launch: () => assert.fail() }), /rollout_not_confirmed/);
});
test('target mismatch stops before refresh', async () => {
  await assert.rejects(runSync({ env: env(), configuredTarget: () => 'np-other', getToken: () => assert.fail() }), /target_configuration_mismatch/);
});
test('authorization or rotation failure cannot fall back to fixed token or launch sync', async () => {
  await assert.rejects(runSync({ env: env(), configuredTarget, getToken: async () => { throw new Error('refresh_rotated_stop'); }, launch: () => assert.fail() }), /refresh_rotated_stop/);
});
test('invalid access token cannot reach .NET', async () => {
  await assert.rejects(runSync({ env: env(), configuredTarget, getToken: async () => 'bad\nheader', launch: () => assert.fail() }), /access_token_invalid/);
});
test('nonzero sync exit status propagates', async () => {
  assert.equal(await runSync({ env: env(), configuredTarget, getToken: async () => 'fixture', launch: () => ({ status: 7 }) }), 7);
});
test('launch failure is sanitized', async () => {
  await assert.rejects(runSync({ env: env(), configuredTarget, getToken: async () => 'fixture', launch: () => ({ error: new Error('private'), status: null }) }), /sync_process_failed/);
});
test('formal workflow is still fixed-token; no workflow activates prepared wrapper', () => {
  const sync = readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8');
  assert.ok(sync.includes('MaiMemo__Token: ${{ secrets.MAIMEMO_TOKEN }}'));
  assert.ok(!sync.includes('run-sync.mjs'));
  assert.ok(!sync.includes('MAIMEMO_OAUTH_SYNC_CONFIRMED'));
});
