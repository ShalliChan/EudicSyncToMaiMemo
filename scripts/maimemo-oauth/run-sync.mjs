// Prepared only. No workflow invokes this until the user confirms rollout.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { authorize, safeFailureCode, targetFromWorkflow } from './verify.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const project = fileURLToPath(new URL('../../src/EudicSyncToMaiMemo/EudicSyncToMaiMemo.csproj', import.meta.url));
export async function runSync({ env = process.env, getToken = authorize,
  launch = spawnSync, configuredTarget = () => targetFromWorkflow(readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8')) } = {}) {
  if (env.MAIMEMO_OAUTH_SYNC_CONFIRMED !== 'true') throw new Error('rollout_not_confirmed');
  if (env.MaiMemo__DefaultNotepadId !== configuredTarget()) throw new Error('target_configuration_mismatch');
  const token = await getToken(env);
  if (typeof token !== 'string' || !token || /\s/.test(token)) throw new Error('access_token_invalid');
  const childEnv = { ...env, MaiMemo__Provider: 'OpenApi', MaiMemo__Token: token };
  // Refresh credentials and old fixed-token aliases do not belong in the .NET process.
  for (const key of ['MAIMEMO_OIDC_CREDENTIALS', 'MAIMEMO_TOKEN', 'MAIMEMO_API_TOKEN', 'MAIMEMO_OAUTH_SYNC_CONFIRMED']) delete childEnv[key];
  const result = launch('dotnet', ['run', '--project', project, '--configuration', 'Release', '--', '--sync-once'], {
    cwd: root, env: childEnv, stdio: 'inherit', windowsHide: true
  });
  if (result.error || !Number.isInteger(result.status)) throw new Error('sync_process_failed');
  return result.status;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runSync().then(code => { process.exitCode = code; }).catch(error => {
    // Never echo untrusted runtime exception details, credentials, or environments.
    console.error(`oauth_sync_failed=${safeFailureCode(error)}`);
    process.exitCode = 1;
  });
}
