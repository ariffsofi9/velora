import assert from 'node:assert/strict';
import {setImmediate} from 'node:timers/promises';
import test, {after, before} from 'node:test';
import {BackendError} from '../backend/backend-errors.mjs';
import {createWorkloadAccessToken} from '../backend/workload-access-token.mjs';

const projectId = 'velora-spark-test';
const response = (access_token = 'synthetic-token', expires_in = 120) =>
  ({access_token, token_type: 'Bearer', expires_in});
const isUnavailable = error => error instanceof BackendError &&
  error.kind === 'oauth' && error.code === 'unavailable' && error.message === 'unavailable' &&
  error.cause === undefined && error.outcomeUnknown === false;
const invalidConfig = error => error instanceof BackendError &&
  error.kind === 'configuration' && error.code === 'invalid-configuration';
const provider = (acquire, options = {}) => createWorkloadAccessToken({projectId, acquire, ...options});
const originalFetch = globalThis.fetch;
let globalCalls = 0;

before(() => {
  globalThis.fetch = () => { globalCalls++; throw new Error('Network forbidden.'); };
});
after(() => {
  globalThis.fetch = originalFetch;
  assert.equal(globalCalls, 0);
});

test('requires explicit TEST binding, acquisition and valid clock and deadline options', () => {
  const acquire = () => assert.fail('Construction must not acquire.');
  for (const patch of [
    {projectId: undefined}, {projectId: ''}, {projectId: ' velora-spark-test'},
    {projectId: 'velora-73222'}, {projectId: {}}, {acquire: undefined},
    {acquire: null}, {now: 0}, {timeoutMs: 0}, {timeoutMs: 15001}, {timeoutMs: 0.5},
  ]) {
    assert.throws(() => provider(acquire, patch), invalidConfig);
  }
  const get = provider(acquire);
  assert.equal(get.projectId, projectId);
  assert.ok(Object.isFrozen(get));
  assert.throws(() => { get.projectId = 'velora-73222'; }, TypeError);
});

test('coalesces initial acquisition and refreshes at the exact 60-second reserve', async () => {
  let now = 100_000, calls = 0;
  const acquisition = Promise.withResolvers();
  const get = provider(() => ++calls === 1 ? acquisition.promise : response('refreshed-token'), {now: () => now});
  const concurrent = Promise.all([get(), get(), get()]);
  await setImmediate();
  assert.equal(calls, 1);
  // The acquisition's relative TTL starts before acquisition delay.
  now += 1500;
  acquisition.resolve(response());
  assert.deepEqual(await concurrent, Array(3).fill('synthetic-token'));
  now = 159_999;
  assert.equal(await get(), 'synthetic-token');
  assert.equal(calls, 1);
  now = 160_000;
  assert.deepEqual(await Promise.all([get(), get()]), ['refreshed-token', 'refreshed-token']);
  assert.equal(calls, 2);
});

test('isolates caches and in-flight acquisitions between instances', async () => {
  let a = 0, b = 0;
  const one = provider(() => response(`one-${++a}`));
  const two = provider(() => response(`two-${++b}`));
  assert.deepEqual(await Promise.all([one(), two(), one()]), ['one-1', 'two-1', 'one-1']);
  assert.equal(await two(), 'two-1');
  assert.equal(a, 1);
  assert.equal(b, 1);
});

for (const [label, value] of [
  ['missing response', undefined],
  ['missing token', {token_type: 'Bearer', expires_in: 120}],
  ['empty token', response('')],
  ['malformed token', response('invalid token')],
  ['token with line break', response('token\n')],
  ['oversized token', response('a'.repeat(8193))],
  ['wrong type', {...response(), token_type: 'Basic'}],
  ['string lifetime', response('token', '120')],
  ['fractional lifetime', response('token', 61.5)],
  ['excessive lifetime', response('token', 3601)],
  ['expired token', response('token', -1)],
  ['lifetime inside reserve', response('token', 60)],
]) {
  test(`rejects ${label}`, async () => {
    await assert.rejects(provider(() => value)(), isUnavailable);
  });
}

test('rejects a token whose remaining lifetime reached the reserve during acquisition', async () => {
  let time = 100_000;
  const get = provider(() => {
    time += 1000;
    return response('too-close', 61);
  }, {now: () => time});
  await assert.rejects(get(), isUnavailable);
});

test('failed early refresh is redacted, never serves the older token, and can recover', async () => {
  let now = 10_000, attempts = 0;
  const get = provider(() => {
    if (++attempts === 1) return response('previous-token');
    if (attempts === 2) throw new Error('credential-and-raw-upstream-sentinel');
    return response(attempts === 3 ? 'recovered-token' : 'after-expiry-token');
  }, {now: () => now});
  assert.equal(await get(), 'previous-token');
  now += 60_000;
  await assert.rejects(get(), error => {
    assert.doesNotMatch(error.stack, /credential-and-raw-upstream-sentinel|previous-token/);
    return isUnavailable(error);
  });
  assert.equal(await get(), 'recovered-token');
  now += 125_000;
  assert.equal(await get(), 'after-expiry-token');
  assert.equal(attempts, 4);
});

test('clock rollback invalidates a cache and fails before issuing a replacement', async () => {
  let now = 100_000, calls = 0;
  const get = provider(() => response(`token-${++calls}`), {now: () => now});
  assert.equal(await get(), 'token-1');
  now += 100;
  assert.equal(await get(), 'token-1');
  now -= 5; // Still above issuance, but behind the last observed clock.
  await assert.rejects(get(), isUnavailable);
  assert.equal(calls, 1);
  assert.equal(await get(), 'token-2');
});

test('acquisition deadline aborts a noncooperative source and never caches a late result', async () => {
  const first = Promise.withResolvers();
  let calls = 0, sourceSignal;
  const get = provider(({signal}) => {
    if (++calls !== 1) return response('replacement-token');
    sourceSignal = signal;
    return first.promise;
  }, {timeoutMs: 50});
  const results = await Promise.allSettled([get(), get()]);
  assert.ok(results.every(result => result.status === 'rejected' && isUnavailable(result.reason)));
  assert.equal(sourceSignal.aborted, true);
  await assert.rejects(get(), isUnavailable);
  assert.equal(calls, 1);
  first.resolve(response('late-token'));
  await setImmediate();
  assert.equal(await get(), 'replacement-token');
  assert.equal(calls, 2);
});

test('cancelled callers leave shared work active until no callers remain', async () => {
  const entered = Promise.withResolvers(), result = Promise.withResolvers();
  const one = new AbortController(), two = new AbortController();
  let calls = 0;
  const get = provider(({signal}) => {
    calls++;
    entered.resolve(signal);
    return result.promise;
  });
  const first = get({signal: one.signal}), second = get({signal: two.signal});
  const shared = await entered.promise;
  one.abort(new Error('private cancellation sentinel'));
  await assert.rejects(first, isUnavailable);
  assert.equal(shared.aborted, false);
  result.resolve(response());
  assert.equal(await second, 'synthetic-token');
  await assert.rejects(get({signal: one.signal}), isUnavailable);
  assert.equal(calls, 1);
});

test('last caller cancellation propagates immediately and a late token cannot enter the cache', async () => {
  const entered = Promise.withResolvers(), result = Promise.withResolvers();
  const caller = new AbortController();
  let calls = 0;
  const get = provider(({signal}) => {
    if (++calls > 1) return response('replacement-token');
    entered.resolve(signal);
    return result.promise;
  });
  const first = get({signal: caller.signal});
  const upstream = await entered.promise;
  caller.abort();
  assert.equal(upstream.aborted, true);
  result.resolve(response('cancelled-token'));
  await assert.rejects(first, isUnavailable);
  await setImmediate();
  assert.equal(await get(), 'replacement-token');
  assert.equal(calls, 2);
});

test('logs receive neither a token nor a raw source failure', async () => {
  const logs = [];
  const original = [console.log, console.warn, console.error];
  [console.log, console.warn, console.error] = Array(3).fill((...args) => logs.push(args));
  try {
    assert.equal(await provider(() => response('credential-log-sentinel'))(), 'credential-log-sentinel');
    await assert.rejects(provider(() => { throw new Error('upstream-log-sentinel'); })(), isUnavailable);
    assert.deepEqual(logs, []);
  } finally {
    [console.log, console.warn, console.error] = original;
  }
});
