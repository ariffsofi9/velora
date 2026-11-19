// Offline workerd qualification only. No deployment, credentials or real Google I/O.
import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {Miniflare, createFetchMock} from 'miniflare';
import {mkdtemp, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

let runtime, directory, cacheBefore;
const originalCwd = process.cwd();
const rootCache = new URL('../../../../.wrangler/cache/cf.json', import.meta.url);
const readCache = () => readFile(rootCache).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
before(async () => {
  cacheBefore = await readCache();
  directory = await mkdtemp(join(tmpdir(), 'velora-saved-recipes-offline-'));
  process.chdir(directory);
  const bundle = await build({entryPoints: [fileURLToPath(new URL('saved-recipes-entry.mjs', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'browser', external: ['node:*'],
    banner: {js: 'import * as cryptoModule from "node:crypto"; import assertModule from "node:assert/strict"; const require = name => { if(name === "node:crypto") return cryptoModule; if(name === "node:assert/strict") return assertModule; throw Error("Unexpected module"); };'}});
  const fetchMock = createFetchMock();
  fetchMock.disableNetConnect(); // No network allowlist or live fallback.
  fetchMock.get('https://velora-egress-must-fail.invalid')
    .intercept({path: '/', method: 'GET'}).reply(599, 'OFFLINE_EGRESS_DENIED').persist();
  runtime = new Miniflare({rootPath: directory, cf: false, cachePersist: false, modules: true,
    script: bundle.outputFiles[0].text, compatibilityDate: '2026-06-11',
    compatibilityFlags: ['nodejs_compat'], fetchMock});
  await runtime.ready;
  const preflight = await runtime.dispatchFetch('https://offline.invalid/', {method: 'POST',
    body: JSON.stringify({scenario: 'egress'})});
  assert.equal(preflight.status, 200, 'isolation preflight must pass before any domain scenario');
  assert.equal((await preflight.json()).blocked, true);
});
after(async () => {
  try {
    await runtime?.dispose();
    assert.deepEqual(await readCache(), cacheBefore, 'repository cache unchanged');
  } finally { process.chdir(originalCwd); }
  // Deliberately no cache deletion or recursive cleanup. Temp runtime artifacts
  // remain outside the repository; the JS bundle itself was never written.
});

const scenarios = ['egress', 'construction', 'admission', 'owner-staff-pagination',
  'signature', 'project', 'unverified', 'disabled', 'revoked', 'account-unverified',
  'generation', 'cross-workspace', 'inactive', 'outsider', 'transaction-conflict',
  'limits', 'upstream-stream', 'warm-revocation', 'stream-abort', 'deadline-abort'];
for (const scenario of scenarios) test(`workerd Saved Recipes: ${scenario}`, {timeout: 30000}, async () => {
  const response = await runtime.dispatchFetch('https://offline.invalid/', {method: 'POST',
    headers: {'content-type': 'application/json'}, body: JSON.stringify({scenario})});
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  if (scenario === 'egress') assert.equal(result.blocked, true);
  else { assert.equal(result.ok, true, JSON.stringify(result)); assert.equal(result.mutations, 0); }
});
