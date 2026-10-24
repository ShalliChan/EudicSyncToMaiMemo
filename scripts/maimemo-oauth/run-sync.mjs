// Refresh in memory, GET-verify target identity, then launch the original program.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { authorize, safeFailureCode, targetFromWorkflow } from './verify.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const project = fileURLToPath(new URL('../../src/EudicSyncToMaiMemo/EudicSyncToMaiMemo.csproj', import.meta.url));
async function authorizedEnvironment(env, getToken) {
  const token = await getToken(env);
  if (typeof token !== 'string' || !token || /\s/.test(token)) throw new Error('access_token_invalid');
  const childEnv = { ...env, MaiMemo__Provider: 'OpenApi', MaiMemo__Token: token };
  for (const key of ['MAIMEMO_OIDC_CREDENTIALS', 'MAIMEMO_TOKEN', 'MAIMEMO_API_TOKEN', 'MAIMEMO_OAUTH_SYNC_CONFIRMED']) delete childEnv[key];
  return childEnv;
}
function exitStatus(result) {
  if (result.error || !Number.isInteger(result.status)) throw new Error('sync_process_failed');
  return result.status;
}
export async function runSync({ env = process.env, getToken = authorize,
  launch = spawnSync, configuredTarget = () => targetFromWorkflow(readFileSync(new URL('../../.github/workflows/sync.yml', import.meta.url), 'utf8')) } = {}) {
  if (env.MAIMEMO_OAUTH_SYNC_CONFIRMED !== 'true') throw new Error('rollout_not_confirmed');
  if (env.MaiMemo__DefaultNotepadId !== configuredTarget()) throw new Error('target_configuration_mismatch');
  const childEnv = await authorizedEnvironment(env, getToken);
  const result = launch('dotnet', ['run', '--project', project, '--configuration', 'Release', '--', '--sync-once'], {
    cwd: root, env: childEnv, stdio: 'inherit', windowsHide: true
  });
  return exitStatus(result);
}

export async function runDiagnostics({ env = process.env, getToken = authorize, launch = spawnSync } = {}) {
  const childEnv = await authorizedEnvironment(env, getToken);
  childEnv.MAIMEMO_TOKEN = childEnv.MaiMemo__Token;
  delete childEnv.MaiMemo__Token;
  return exitStatus(launch('pwsh', ['-NoProfile', '-File', fileURLToPath(new URL('../diagnose-maimemo.ps1', import.meta.url))], {
    cwd: root, env: childEnv, stdio: 'inherit', windowsHide: true
  }));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const execute = process.argv.length === 2 ? runSync
    : process.argv.length === 3 && process.argv[2] === '--diagnose' ? runDiagnostics
    : async () => { throw new Error('mode_invalid'); };
  execute().then(code => { process.exitCode = code; }).catch(error => {
    // Never echo untrusted runtime exception details, credentials, or environments.
    console.error(`oauth_sync_failed=${safeFailureCode(error)}`);
    process.exitCode = 1;
  });
}
