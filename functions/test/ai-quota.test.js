'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createAiQuota, adminQuotaStore, AiQuotaError} = require('../src/ai-quota');

// Optimistic, versioned snapshots: no callback serialization, reads precede writes,
// commit validates read versions, conflicts rerun callback, failed commits are atomic.
// Model only; this is not Firestore runtime verification.
class Store {
  constructor() { this.docs = new Map(); this.versions = new Map(); this.conflicts = 0; }
  put(p, d) { this.docs.set(p, structuredClone(d)); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
  remove(p) { this.docs.delete(p); this.versions.set(p, (this.versions.get(p) ?? 0) + 1); }
  async runTransaction(operation) {
    for (let retry = 0; retry < 100; retry++) {
      const snapshot = structuredClone(this.docs); const versions = new Map(this.versions);
      const reads = new Set(); const writes = new Map(); let writing = false;
      const write = (p, d, create) => {
        writing = true; assert.equal(writes.has(p), false, 'duplicate write');
        assert.equal(snapshot.has(p), !create, 'create/update precondition');
        reads.add(p); writes.set(p, create ? structuredClone(d) : {...snapshot.get(p), ...structuredClone(d)});
      };
      const result = await operation({get: async p => {
        assert.equal(writing, false, 'read after write'); reads.add(p); await Promise.resolve();
        return structuredClone(snapshot.get(p) ?? null);
      }, create: (p, d) => write(p, d, true), update: (p, d) => write(p, d, false),
      delete: p => {
        writing = true; assert.equal(writes.has(p), false); reads.add(p); writes.set(p, null);
      }});
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; hook(); }
      if ([...reads].some(p => this.versions.get(p) !== versions.get(p))) { this.conflicts++; continue; }
      if (this.failCommit) throw Error('simulated transaction failure');
      for (const [p, d] of writes) { if (d === null) this.remove(p); else this.put(p, d); }
      return result;
    }
    throw Error('model retry limit');
  }
}
const expected = {expectedCafeId: 'a', expectedMembershipGeneration: 0};
const auth = uid => ({uid, token: {email_verified: true}});
const code = value => error => error instanceof AiQuotaError && error.code === value;
function fixture() {
  const store = new Store(); let time = Date.UTC(2026, 10, 6, 12);
  for (const cafeId of ['a', 'b']) {
    const ownerUid = 'owner-' + cafeId;
    store.put(`cafes/${cafeId}`, {schemaVersion: 1, status: 'active', ownerUid});
    for (const uid of [ownerUid, ...Array.from({length: 6}, (_, i) => `${cafeId}-staff-${i}`)]) {
      const link = {uid, cafeId, status: 'active', schemaVersion: 1};
      store.put(`user_cafe_memberships/${uid}`, link);
      store.put(`cafes/${cafeId}/members/${uid}`, {...link, role: uid === ownerUid ? 'owner' : 'staff'});
    }
  }
  const service = () => createAiQuota({store, now: () => time});
  const q = service();
  const issue = (uid = 'a-staff-0', exp = expected) => q.issue({auth: auth(uid), expected: exp});
  const admit = (ticketId, uid = 'a-staff-0', exp = expected) => q.admit({auth: auth(uid), expected: exp, ticketId});
  const dispatch = (lease, uid = 'a-staff-0') => q.dispatch({...lease, auth: auth(uid), expected});
  async function cycle(uid = 'a-staff-0', outcome = 'success') {
    const ticket = await issue(uid); const lease = await admit(ticket.ticketId, uid);
    await dispatch(lease, uid); await q.complete({...lease, outcome}); return lease;
  }
  return {store, q, service, issue, admit, dispatch, cycle, advance: ms => { time += ms; }};
}

test('user daily quota accepts 10, rejects 11 without another charge', async () => {
  const f = fixture();
  // Pre-issued tickets allow admission itself (rather than issuance) to hit limit.
  const tickets = await Promise.all(Array.from({length: 11}, () => f.issue()));
  for (const ticket of tickets.slice(0, 10)) {
    const lease = await f.admit(ticket.ticketId); await f.dispatch(lease);
    await f.q.complete({...lease, outcome: 'success'});
  }
  await assert.rejects(f.admit(tickets[10].ticketId), code('resource-exhausted'));
  assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 10);
});
test('workspace quota accepts 30 across users, rejects 31', async () => {
  const f = fixture(); const extra = await f.issue('a-staff-5');
  for (let i = 0; i < 30; i++) await f.cycle(`a-staff-${i % 5}`);
  await assert.rejects(f.admit(extra.ticketId, 'a-staff-5'), code('resource-exhausted'));
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 30);
});
test('ticket issuance caps user at 20 without consuming admitted quota', async () => {
  const f = fixture(); for (let i = 0; i < 20; i++) await f.issue();
  await assert.rejects(f.issue(), code('resource-exhausted'));
  assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 0);
});
test('ticket issuance caps workspace at 60 across users', async () => {
  const f = fixture(); for (let i = 0; i < 60; i++) await f.issue(`a-staff-${i % 6}`);
  await assert.rejects(f.issue('owner-a'), code('resource-exhausted'));
});
test('parallel admissions on independent service instances allow only one workspace lease', async () => {
  const f = fixture(); const a = await f.issue(); const b = await f.issue('a-staff-1');
  const results = await Promise.allSettled([
    f.admit(a.ticketId), f.service().admit({auth: auth('a-staff-1'), expected, ticketId: b.ticketId}),
  ]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(results.find(r => r.status === 'rejected').reason.code, 'resource-exhausted');
  assert.ok(f.store.conflicts > 0);
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
test('duplicates before/after dispatch never double-charge or return dispatch permission', async () => {
  const f = fixture(); const {ticketId} = await f.issue();
  const results = await Promise.all([f.admit(ticketId), f.admit(ticketId)]);
  const lease = results.find(r => r.admitted); const duplicate = results.find(r => !r.admitted);
  assert.equal(duplicate.fence, undefined); await f.dispatch(lease);
  await assert.rejects(f.dispatch(lease), code('failed-precondition'));
  assert.equal((await f.admit(ticketId)).admitted, false);
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
test('ticket expires at exactly five minutes, no charge', async () => {
  const f = fixture(); const {ticketId} = await f.issue(); f.advance(300000);
  await assert.rejects(f.admit(ticketId), code('failed-precondition'));
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 0);
});
test('receipt cleanup cannot make a ticket replay dispatchable', async () => {
  const f = fixture(); const lease = await f.cycle();
  f.store.remove(`ai_generation_requests/${lease.ticketId}`);
  await assert.rejects(f.admit(lease.ticketId), code('failed-precondition'));
  f.store.remove(`ai_generation_tickets/${lease.ticketId}`); f.advance(8 * 86400000);
  await assert.rejects(f.admit(lease.ticketId), code('failed-precondition'));
  const next = await f.issue(); assert.notEqual(next.ticketId, lease.ticketId);
});
for (const [label, options] of [
  ['missing Auth', {auth: null, expected}],
  ['unverified Auth', {auth: {uid: 'a-staff-0', token: {}}, expected}],
  ['forged workspace', {auth: auth('a-staff-0'), expected: {...expected, expectedCafeId: 'b'}}],
  ['stale generation', {auth: auth('a-staff-0'), expected: {...expected, expectedMembershipGeneration: 1}}],
  ['client quota fields', {auth: auth('a-staff-0'), expected: {...expected, quota: 100}}],
]) test(label + ' rejected before issuance writes', async () => {
  const f = fixture(); const before = structuredClone(f.store.docs);
  await assert.rejects(f.q.issue(options), AiQuotaError); assert.deepEqual(f.store.docs, before);
});
test('cross-user and cross-workspace ticket reuse denied', async () => {
  const f = fixture(); const {ticketId} = await f.issue();
  await assert.rejects(f.admit(ticketId, 'a-staff-1'), code('permission-denied'));
  await assert.rejects(f.admit(ticketId, 'b-staff-0', {...expected, expectedCafeId: 'b'}), code('permission-denied'));
});
for (const [label, change] of [
  ['revoked', store => store.put('user_cafe_memberships/a-staff-0', {...store.docs.get('user_cafe_memberships/a-staff-0'), status: 'inactive'})],
  ['generation changed', store => { for (const p of ['user_cafe_memberships/a-staff-0', 'cafes/a/members/a-staff-0']) store.put(p, {...store.docs.get(p), membershipGeneration: 1}); }],
  ['Owner generation changed', store => { for (const p of ['user_cafe_memberships/owner-a', 'cafes/a/members/owner-a']) store.put(p, {...store.docs.get(p), membershipGeneration: 1}); }],
  ['role conflict', store => store.put('cafes/a/members/a-staff-0', {...store.docs.get('cafes/a/members/a-staff-0'), role: 'owner'})],
]) test(label + ' invalidates issued ticket and dispatch authority', async () => {
  const f = fixture(); const {ticketId} = await f.issue(); change(f.store);
  await assert.rejects(f.admit(ticketId), AiQuotaError);
  const g = fixture(); const ticket = await g.issue(); const lease = await g.admit(ticket.ticketId); change(g.store);
  await assert.rejects(g.dispatch(lease), AiQuotaError);
});
test('expiry recovers admitted but undispatched work without refund or redispatch', async () => {
  const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
  await assert.rejects(f.q.recoverExpired(lease), code('failed-precondition'));
  f.advance(120000); assert.equal((await f.q.recoverExpired(lease)).state, 'abandoned');
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').lock, null);
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
  await assert.rejects(f.dispatch(lease), code('failed-precondition'));
  assert.equal((await f.admit(lease.ticketId)).admitted, false);
});
test('expired dispatched request quarantines, never automatically unlocks even after midnight', async () => {
  const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
  await f.dispatch(lease); f.advance(120000);
  assert.equal((await f.q.recoverExpired(lease)).state, 'quarantined');
  f.advance(86400000); await assert.rejects(f.issue(), code('resource-exhausted'));
  await assert.rejects(f.q.complete({...lease, outcome: 'success'}), code('failed-precondition'));
  assert.ok(f.store.docs.get('ai_usage_workspaces/a').lock);
});
for (const outcome of ['success', 'provider-rejected', 'unknown', 'timeout']) {
  test(outcome + ' consumes quota, uncertainty retains lock', async () => {
    const f = fixture(); const lease = await f.cycle('a-staff-0', outcome);
    assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 1);
    const quarantined = ['unknown', 'timeout'].includes(outcome);
    assert.equal(!!f.store.docs.get('ai_usage_workspaces/a').lock, quarantined);
    assert.equal(f.store.docs.get(`ai_generation_requests/${lease.ticketId}`).state, quarantined ? 'quarantined' : 'completed');
  });
}
test('late success is quarantined conservatively', async () => {
  const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
  await f.dispatch(lease); f.advance(120000);
  assert.equal((await f.q.complete({...lease, outcome: 'success'})).state, 'quarantined');
});
test('stale fence cannot complete or release a successor reservation', async () => {
  const f = fixture(); const first = await f.cycle(); const next = await f.issue(); const lease = await f.admit(next.ticketId);
  await assert.rejects(f.q.complete({...lease, fence: first.fence, outcome: 'success'}), code('failed-precondition'));
  await assert.rejects(f.q.complete({...first, outcome: 'success'}), code('failed-precondition'));
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').lock.fence, lease.fence);
});
test('UTC rollover resets daily counters but cannot replay previous dispatch', async () => {
  const f = fixture(); const first = await f.cycle(); f.advance(86400000);
  const second = await f.cycle(); assert.notEqual(first.ticketId, second.ticketId);
  assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 1);
  assert.equal((await f.admit(first.ticketId)).admitted, false);
});
test('membership change in transaction conflict aborts admission without partial charge', async () => {
  const f = fixture(); const {ticketId} = await f.issue();
  f.store.beforeCommit = () => f.store.put('user_cafe_memberships/a-staff-0', {...f.store.docs.get('user_cafe_memberships/a-staff-0'), status: 'inactive'});
  await assert.rejects(f.admit(ticketId), code('permission-denied'));
  assert.ok(f.store.conflicts > 0); assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 0);
  assert.equal(f.store.docs.has(`ai_generation_requests/${ticketId}`), false);
});
test('commit failure leaves ticket and both counters unchanged', async () => {
  const f = fixture(); const {ticketId} = await f.issue(); const before = structuredClone(f.store.docs);
  f.store.failCommit = true; await assert.rejects(f.admit(ticketId)); assert.deepEqual(f.store.docs, before);
});
test('malformed stored counters and locks fail closed', async () => {
  for (const override of [{admitted: -1}, {issued: '0'}, {lock: {}}, {day: Number.MAX_SAFE_INTEGER}]) {
    const f = fixture(); await f.issue();
    f.store.put('ai_usage_workspaces/a', {...f.store.docs.get('ai_usage_workspaces/a'), ...override});
    await assert.rejects(f.issue(), code('failed-precondition'));
  }
});
test('unknown ticket cannot create a receipt, error is fixed and has no payload', async () => {
  const f = fixture(); const before = structuredClone(f.store.docs);
  await assert.rejects(f.admit('a'.repeat(64)), error => error.message === 'AI request cannot proceed.');
  assert.deepEqual(f.store.docs, before);
});
test('unexpected storage exceptions are redacted', async () => {
  const q = createAiQuota({store: {runTransaction() { throw Error('sensitive storage detail'); }}});
  await assert.rejects(q.issue({auth: auth('a-staff-0'), expected}), error =>
    error.code === 'unavailable' && error.message === 'AI request cannot proceed.' &&
    !error.stack.includes('sensitive storage detail'));
});
test('UTC midnight refreshes counters while a still-valid ticket remains usable', async () => {
  const f = fixture(); f.advance(12 * 3600000 - 60000);
  await f.cycle(); const ticket = await f.issue(); f.advance(60000);
  const lease = await f.admit(ticket.ticketId);
  assert.equal(lease.admitted, true);
  assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 1);
});
test('dispatch racing expired-reservation recovery cannot authorize a provider call', async () => {
  const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
  f.advance(120000);
  const results = await Promise.allSettled([f.dispatch(lease), f.q.recoverExpired(lease)]);
  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].value.state, 'abandoned');
});
test('Admin adapter uses native transactions and never writes outside callback', async () => {
  const ops = []; const adapter = adminQuotaStore({doc: path => path, runTransaction: async fn => fn({
    get: async p => ({exists: true, data: () => ({p})}),
    create: (...args) => ops.push(['create', ...args]), update: (...args) => ops.push(['update', ...args]),
    delete: (...args) => ops.push(['delete', ...args]),
  })});
  await adapter.runTransaction(async tx => { assert.deepEqual(await tx.get('x/y'), {p: 'x/y'}); tx.create('x/z', {n: 1}); tx.update('x/y', {n: 2}); });
  assert.equal(ops.length, 2);
  await adapter.runTransaction(tx => tx.delete('x/z'));
  assert.deepEqual(ops[2], ['delete', 'x/z']);
});
test('cleanup deletes unused tickets only after five-minute lifetime plus seven days', async () => {
  const f = fixture(); const ticket = await f.issue();
  const cleanup = () => f.q.cleanupExpired({ticketIds: [ticket.ticketId]});
  f.advance(7 * 86400000 + 299999);
  assert.equal((await cleanup())[0].state, 'retained');
  f.advance(1); assert.equal((await cleanup())[0].state, 'deleted');
  assert.equal(f.store.docs.has(`ai_generation_tickets/${ticket.ticketId}`), false);
  await assert.rejects(f.admit(ticket.ticketId), code('failed-precondition'));
});
test('cleanup deletes completed pair atomically without changing counters', async () => {
  const f = fixture(); const lease = await f.cycle();
  const user = structuredClone(f.store.docs.get('ai_usage_users/a-staff-0'));
  const workspace = structuredClone(f.store.docs.get('ai_usage_workspaces/a'));
  f.advance(8 * 86400000);
  assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId]}))[0].state, 'deleted');
  assert.equal(f.store.docs.has(`ai_generation_requests/${lease.ticketId}`), false);
  assert.deepEqual(f.store.docs.get('ai_usage_users/a-staff-0'), user);
  assert.deepEqual(f.store.docs.get('ai_usage_workspaces/a'), workspace);
  await assert.rejects(f.admit(lease.ticketId), code('failed-precondition'));
});
test('cleanup of abandoned reservation retains charged quota', async () => {
  const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
  f.advance(120000); await f.q.recoverExpired(lease); f.advance(8 * 86400000);
  await f.q.cleanupExpired({ticketIds: [lease.ticketId]});
  assert.equal(f.store.docs.get('ai_usage_users/a-staff-0').admitted, 1);
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
});
for (const state of ['admitted', 'dispatched', 'quarantined']) {
  test('cleanup protects ' + state + ' indefinitely', async () => {
    const f = fixture(); const ticket = await f.issue(); const lease = await f.admit(ticket.ticketId);
    if (state !== 'admitted') await f.dispatch(lease);
    if (state === 'quarantined') await f.q.complete({...lease, outcome: 'unknown'});
    f.advance(365 * 86400000); const before = structuredClone(f.store.docs);
    assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId]}))[0].state, 'protected');
    assert.deepEqual(f.store.docs, before);
  });
}
test('cleanup protects a terminal record still referenced by a workspace lock', async () => {
  const f = fixture(); const lease = await f.cycle();
  const receipt = f.store.docs.get(`ai_generation_requests/${lease.ticketId}`);
  f.store.put('ai_usage_workspaces/a', {...f.store.docs.get('ai_usage_workspaces/a'),
    lock: {ticketId: lease.ticketId, fence: receipt.fence, until: receipt.leaseUntil}});
  f.advance(8 * 86400000);
  assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId]}))[0].state, 'protected');
});
test('cleanup retry is idempotent and does not recreate receipts or tickets', async () => {
  const f = fixture(); const lease = await f.cycle(); f.advance(8 * 86400000);
  await f.q.cleanupExpired({ticketIds: [lease.ticketId]}); const before = structuredClone(f.store.docs);
  assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId]}))[0].state, 'missing');
  assert.deepEqual(f.store.docs, before);
});
test('cleanup commit failure cannot delete half a pair', async () => {
  const f = fixture(); const lease = await f.cycle(); f.advance(8 * 86400000);
  const before = structuredClone(f.store.docs); f.store.failCommit = true;
  await assert.rejects(f.q.cleanupExpired({ticketIds: [lease.ticketId]}), code('unavailable'));
  assert.deepEqual(f.store.docs, before);
});
test('cleanup/admission conflict retries against fresh ticket state', async () => {
  const f = fixture(); const ticket = await f.issue(); f.advance(8 * 86400000);
  f.store.beforeCommit = () => {
    // Models an in-flight admission committed after cleanup's stale snapshot.
    // Cleanup must re-read and preserve the now-active record.
    f.store.put(`ai_generation_tickets/${ticket.ticketId}`, {
      ...f.store.docs.get(`ai_generation_tickets/${ticket.ticketId}`), state: 'admitted'});
  };
  assert.equal((await f.q.cleanupExpired({ticketIds: [ticket.ticketId]}))[0].state, 'protected');
  assert.ok(f.store.conflicts > 0);
});
test('real parallel expired-ticket cleanup/admission never admits expired work', async () => {
  const f = fixture(); const ticket = await f.issue(); f.advance(8 * 86400000);
  const results = await Promise.allSettled([
    f.q.cleanupExpired({ticketIds: [ticket.ticketId]}), f.admit(ticket.ticketId),
  ]);
  assert.equal(results[0].value[0].state, 'deleted'); assert.equal(results[1].status, 'rejected');
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 0);
});
test('cleanup ignores caller timestamps and preserves quota at UTC boundary', async () => {
  const f = fixture(); const lease = await f.cycle(); f.advance(12 * 3600000);
  const before = structuredClone(f.store.docs);
  assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId], now: Number.MAX_SAFE_INTEGER}))[0].state, 'retained');
  assert.deepEqual(f.store.docs, before);
});
test('cleanup batch bounded to 10 unique valid IDs before any transaction', async () => {
  const f = fixture();
  for (const ticketIds of [[], Array(11).fill('a'.repeat(64)), ['bad'], ['a'.repeat(64), 'a'.repeat(64)]]) {
    await assert.rejects(f.q.cleanupExpired({ticketIds}), code('invalid-argument'));
  }
});
test('orphan receipt and malformed terminal pair preserved for investigation', async () => {
  const f = fixture(); const lease = await f.cycle(); f.advance(8 * 86400000);
  f.store.remove(`ai_generation_tickets/${lease.ticketId}`);
  assert.equal((await f.q.cleanupExpired({ticketIds: [lease.ticketId]}))[0].state, 'orphan-preserved');
  const g = fixture(); const next = await g.cycle(); g.advance(8 * 86400000);
  g.store.remove(`ai_generation_requests/${next.ticketId}`);
  await assert.rejects(g.q.cleanupExpired({ticketIds: [next.ticketId]}), code('failed-precondition'));
  assert.ok(g.store.docs.has(`ai_generation_tickets/${next.ticketId}`));
});
for (const attempt of ['no evidence', 'untrusted actor', 'stale fence', 'duplicate recovery']) {
  test('no quarantine unlock for ' + attempt, async () => {
    const f = fixture(); const lease = await f.cycle('a-staff-0', 'unknown');
    const before = structuredClone(f.store.docs); f.advance(8 * 86400000);
    // There is no reconciliation/reset API accepting caller/operator claims.
    assert.equal(f.q.reconcileQuarantine, undefined);
    await assert.rejects(f.q.recoverExpired({...lease, auth: auth('outsider'), evidence: attempt}), code('failed-precondition'));
    await assert.rejects(f.q.complete({...lease, outcome: 'success'}), code('failed-precondition'));
    assert.deepEqual(f.store.docs, before);
  });
}
test('new roots are default-denied by static Rules contract; module is unexported and network-free', () => {
  const rules = fs.readFileSync(path.join(__dirname, '../../docs/firebase/workspace.firestore.rules'), 'utf8');
  assert.match(rules, /match \/\{document=\*\*\} \{ allow read, write: if false; \}/);
  for (const root of ['ai_usage_users', 'ai_usage_workspaces', 'ai_generation_tickets', 'ai_generation_requests']) {
    assert.equal(rules.includes(`match /${root}/`), false);
  }
  const index = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  assert.equal(index.includes("require('./ai-quota')"), false);
  const source = fs.readFileSync(path.join(__dirname, '../src/ai-quota.js'), 'utf8');
  assert.doesNotMatch(source, /console\.|fetch\(|GROQ_API_KEY|onCall\(/);
});
test('bound tickets require matching digest transactionally at admission and dispatch', async () => {
  const f = fixture(); const q = createAiQuota({store: f.store, requirePayloadDigest: true});
  const bound = {auth: auth('a-staff-0'), expected, payloadDigest: 'a'.repeat(64)};
  const ticket = await q.issue(bound);
  const mismatch = {...bound, ticketId: ticket.ticketId, payloadDigest: 'b'.repeat(64)};
  await assert.rejects(q.admit(mismatch), code('failed-precondition'));
  const lease = await q.admit({...bound, ticketId: ticket.ticketId});
  await assert.rejects(q.dispatch({...mismatch, ...lease}), code('failed-precondition'));
  await q.dispatch({...bound, ...lease});
  await assert.rejects(q.admit(mismatch), code('failed-precondition'));
  assert.equal(f.store.docs.get('ai_usage_workspaces/a').admitted, 1);
  assert.equal(f.store.docs.get(`ai_generation_tickets/${ticket.ticketId}`).payloadDigest, bound.payloadDigest);
});
test('binding mode rejects absent/malformed digests and unbound legacy tickets', async () => {
  const f = fixture(); const q = createAiQuota({store: f.store, requirePayloadDigest: true});
  await assert.rejects(q.issue({auth: auth('a-staff-0'), expected}), code('invalid-argument'));
  await assert.rejects(q.issue({auth: auth('a-staff-0'), expected, payloadDigest: 'bad'}), code('invalid-argument'));
  const legacy = await f.issue();
  await assert.rejects(q.admit({auth: auth('a-staff-0'), expected, ticketId: legacy.ticketId,
    payloadDigest: 'a'.repeat(64)}), code('failed-precondition'));
});
test('generic quota instance cannot bypass an existing ticket digest', async () => {
  const f = fixture(); const ticket = await f.q.issue({auth: auth('a-staff-0'), expected, payloadDigest: 'a'.repeat(64)});
  await assert.rejects(f.admit(ticket.ticketId), code('failed-precondition'));
});
