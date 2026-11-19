// Bounded offline observations, never a hosted Cloudflare compliance test.
import test from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {Miniflare, createFetchMock} from 'miniflare';
import {mkdtemp, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

function inspectorClient(url) {
  assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(new URL(url).hostname));
  const socket = new WebSocket(url), pending = new Map();
  let serial = 0;
  const ready = new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once: true});
    socket.addEventListener('error', () => reject(Error('loopback inspector connection failed')), {once: true});
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const item = pending.get(message.id);
    if (item) {
      pending.delete(message.id); clearTimeout(item.timer);
      if (message.error) item.reject(Error(message.error.message));
      else item.resolve(message.result);
    }
  });
  return {ready, close() {
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(Error('inspector closed')); }
    pending.clear(); socket.close();
  }, async call(method) {
    await ready;
    return new Promise((resolve, reject) => {
      const id = ++serial;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Inspector unavailable: ${method}`)); }, 3000);
      pending.set(id, {resolve, reject, timer});
      socket.send(JSON.stringify({id, method, params: {}}));
    });
  }};
}

test('bounded offline Saved Recipes resource observations', {timeout: 120000}, async () => {
  const originalCwd = process.cwd();
  const cache = new URL('../../../../.wrangler/cache/cf.json', import.meta.url);
  const readCache = () => readFile(cache).catch(e => { if (e.code === 'ENOENT') return null; throw e; });
  const cacheBefore = await readCache();
  const directory = await mkdtemp(join(tmpdir(), 'velora-saved-resource-'));
  let runtime, inspector;
  const report = {boundary: 'Node monotonic dispatch through full response consumption; fixture preparation excluded',
    overhead: 'Includes local dispatch, synthetic REST serialization/assertions, HTTP control envelope and host scheduling. No CPU-time equivalence.',
    runtime: {node: process.version, compatibilityDate: '2026-06-11'}, latency: [], cpu: {}, heap: {}};
  const stopAt = performance.now() + 90000;
  const guard = () => assert.ok(performance.now() < stopAt, 'overall measurement deadline');
  try {
    process.chdir(directory);
    const bundle = await build({entryPoints: [fileURLToPath(new URL('saved-recipes-entry.mjs', import.meta.url))],
      write: false, bundle: true, format: 'esm', platform: 'browser', external: ['node:*'],
      banner: {js: 'import * as c from "node:crypto"; import a from "node:assert/strict"; const require = n => { if(n === "node:crypto") return c; if(n === "node:assert/strict") return a; throw Error("Unexpected module"); };'}});
    const fetchMock = createFetchMock(); fetchMock.disableNetConnect();
    fetchMock.get('https://velora-egress-must-fail.invalid').intercept({path: '/', method: 'GET'})
      .reply(599, 'OFFLINE_EGRESS_DENIED').persist();
    runtime = new Miniflare({rootPath: directory, cf: false, cachePersist: false, modules: true,
      script: bundle.outputFiles[0].text, compatibilityFlags: ['nodejs_compat'], compatibilityDate: '2026-06-11',
      inspectorHost: '127.0.0.1', inspectorPort: 0, fetchMock});
    await runtime.ready;
    const dispatch = input => runtime.dispatchFetch('https://offline.invalid/', {method: 'POST',
      headers: {'content-type': 'application/json'}, body: JSON.stringify(input)});
    const control = async input => {
      guard(); const response = await dispatch(input); const data = await response.json();
      assert.equal(response.status, 200, JSON.stringify(data)); return data;
    };
    assert.equal((await control({scenario: 'egress'})).blocked, true);
    // Admission regression is outside all measured intervals.
    assert.equal((await control({scenario: 'admission'})).ok, true);
    try {
      const url = await runtime.getInspectorURL();
      assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname));
      const discovery = new URL('/json/list', url); discovery.protocol = 'http:';
      const targets = await (await fetch(discovery)).json();
      const target = targets.find(t => t.webSocketDebuggerUrl && t.type === 'node') ?? targets.find(t => t.webSocketDebuggerUrl);
      assert.ok(target, 'inspector target unavailable');
      inspector = inspectorClient(target.webSocketDebuggerUrl); await inspector.ready;
    } catch (error) { report.inspectorUnavailable = error.message; }
    report.heap.observations = [];
    const observeHeap = async label => {
      if (!inspector || report.heap.unavailable) return;
      try { report.heap.observations.push({label, ...await inspector.call('Runtime.getHeapUsage')}); }
      catch (error) { report.heap.unavailable = error.message; }
    };
    const measure = async (index, expected) => {
      guard(); const start = performance.now();
      const response = await dispatch({action: 'run', index});
      const bytes = new Uint8Array(await response.arrayBuffer());
      const ms = performance.now() - start;
      assert.equal(response.status, expected, new TextDecoder().decode(bytes));
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.ok(bytes.length <= 65536);
      assert.ok(!new TextDecoder().decode(bytes).includes('SYNTHETIC_PRIVATE_UPSTREAM_DETAIL'));
      return {ms, bytes: bytes.length};
    };
    // Cold means empty dependency caches, not key generation or isolate startup.
    for (const name of ['list', 'get']) {
      const p = await control({action: 'prepare', name, warm: false});
      await observeHeap(`cold ${name} baseline`);
      const sample = await measure(0, p.expectedStatus);
      await observeHeap(`cold ${name} after request`);
      report.latency.push({scenario: name, mode: 'cold dependency caches', concurrency: 1, n: 1, ...sample});
    }
    const groups = [
      [1, ['list', 'get', 'signature', 'project', 'refresh']],
      [2, ['disabled', 'revoked', 'large-list', 'large-get', 'response-cap']],
      [4, ['oversized', 'retry', 'upstream', 'deadline', 'abort']],
    ];
    for (const [concurrency, names] of groups) {
      let count = 0;
      await observeHeap(`before concurrency ${concurrency}`);
      for (const name of names) {
        const p = await control({action: 'prepare', name});
        const observations = [];
        // Count the two cold requests toward concurrency 1's total cap of 20.
        const sampleCount = concurrency === 1 && ['list', 'get'].includes(name) ? 3 : 4;
        for (let index = 0; index < sampleCount; index += concurrency) {
          observations.push(...await Promise.all(Array.from({length: Math.min(concurrency, sampleCount - index)},
            (_, offset) => measure(index + offset, p.expectedStatus))));
        }
        count += observations.length;
        const stats = await control({action: 'inspect'});
        if (['list', 'get', 'refresh', 'large-list', 'large-get', 'retry', 'response-cap', 'oversized'].includes(name)) {
          assert.equal(stats.accountLookups, sampleCount * 2, 'fresh account lookup at admission and domain boundary');
        }
        if (name === 'refresh') assert.equal(stats.certificates, 1);
        if (name === 'retry') assert.equal(stats.commits, 5, 'one bounded aborted commit plus four successes');
        const sorted = observations.map(o => o.ms).sort((a, b) => a - b);
        report.latency.push({scenario: name, mode: 'warm (refresh explicitly expired)', concurrency,
          n: sorted.length, minMs: sorted[0], medianMs: sorted.length % 2 ? sorted[Math.floor(sorted.length / 2)] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2,
          maxMs: sorted.at(-1), maxBytes: Math.max(...observations.map(o => o.bytes)), warmupRequests: p.warmupRequests, stats});
      }
      assert.equal(count + (concurrency === 1 ? 2 : 0), 20, 'bounded measured requests per concurrency level including cold probes');
      await observeHeap(`after concurrency ${concurrency}`);
    }
    // Profiling is separate from the unprofiled latency observations above.
    try {
      assert.ok(inspector, 'inspector connection unavailable');
      const p = await control({action: 'prepare', name: 'list'});
      try {
        report.heap.baseline = await inspector.call('Runtime.getHeapUsage');
      } catch (error) { report.heap.unavailable = error.message; }
      try {
        await inspector.call('Profiler.enable');
        await inspector.call('Profiler.start');
        await measure(0, p.expectedStatus);
        const {profile} = await inspector.call('Profiler.stop');
        assert.ok(profile && Array.isArray(profile.nodes), 'invalid CPU profile');
        report.cpu = {supported: true, profileIntervalUs: profile.endTime - profile.startTime,
          samples: profile.samples?.length ?? 0, nodes: profile.nodes.length,
          frames: [...new Set(profile.nodes.map(n => n.callFrame.functionName))].slice(0, 30),
          limitation: 'Sampled inspector interval, includes harness; not exact billed CPU. Native/off-thread attribution may be incomplete.'};
      } catch (error) { report.cpu = {supported: false, reason: error.message}; }
      try { report.heap.afterRequest = await inspector.call('Runtime.getHeapUsage'); }
      catch (error) { report.heap.unavailable = error.message; }
      report.heap.limitation = 'Point-in-time JS heap observation, no forced GC, not transient peak or total isolate memory.';
    } catch (error) { report.inspectorUnavailable = error.message; }
    console.log('SAVED_RECIPES_RESOURCE_REPORT ' + JSON.stringify(report));
  } finally {
    inspector?.close();
    await runtime?.dispose();
    process.chdir(originalCwd);
    assert.deepEqual(await readCache(), cacheBefore, 'repository cache unchanged');
    // No cache deletion; any runtime artifacts remain in the OS temp directory.
  }
});
