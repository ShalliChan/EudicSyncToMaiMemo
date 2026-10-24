import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runSync, runDiagnostics } from './run-sync.mjs';

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
test('formal workflow defaults to OAuth with explicit fixed-token fallback, never on failure', () => {
  const sync = readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8');
  assert.ok(sync.includes('default: oauth'));
  assert.ok(sync.includes("inputs.authentication || 'oauth'"));
  assert.ok(sync.includes("inputs.authentication == 'fixed' && secrets.MAIMEMO_TOKEN || ''"));
  assert.ok(sync.includes('MAIMEMO_OAUTH_SYNC_CONFIRMED:'));
  assert.ok(sync.includes('node scripts/maimemo-oauth/run-sync.mjs'));
  assert.ok(!sync.includes('continue-on-error') && !/\|\|\s*dotnet/.test(sync));
  assert.ok(sync.includes("cron: '5 1 * * *'"));
  assert.ok(sync.includes('group: maimemo-user-authorization'));
});
test('OAuth read-only diagnostics pass access token via private child environment only', async () => {
  const code = await runDiagnostics({ env: { ...env(), MAIMEMO_STRICT_PREVIEW: 'true' }, getToken: async () => 'new-access',
    launch: (command, args, options) => {
      assert.equal(command, 'pwsh');
      assert.ok(args.at(-1).endsWith('diagnose-maimemo.ps1'));
      assert.ok(!args.join(' ').includes('new-access'));
      assert.equal(options.env.MAIMEMO_TOKEN, 'new-access');
      assert.equal(options.env.MAIMEMO_OIDC_CREDENTIALS, undefined);
      assert.equal(options.env.MaiMemo__Token, undefined);
      assert.equal(options.env.MAIMEMO_STRICT_PREVIEW, 'true');
      return { status: 0 };
    } });
  assert.equal(code, 0);
});
test('diagnostics do not launch after OAuth failure', async () => {
  await assert.rejects(runDiagnostics({ env: {}, getToken: async () => { throw new Error('invalid_grant'); }, launch: () => assert.fail() }), /invalid_grant/);
});
test('diagnostic workflow uses OAuth while retaining read-only script', () => {
  const yaml = readFileSync(new URL('../../.github/workflows/maimemo-diagnostics.yml', import.meta.url), 'utf8');
  assert.ok(yaml.includes('run-sync.mjs --diagnose'));
  assert.ok(yaml.includes('secrets.MAIMEMO_OIDC_CREDENTIALS'));
  assert.ok(!yaml.includes('secrets.MAIMEMO_TOKEN'));
});
