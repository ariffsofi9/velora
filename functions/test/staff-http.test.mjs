import test from 'node:test';
import assert from 'node:assert/strict';
import {createStaffHttp} from '../https/staff-http.mjs';
import {createGoogleHttp} from '../backend/google-http.mjs';
import {createFirestoreStore} from '../backend/firestore-store.mjs';
import {createRestFake} from './helpers/shared-firestore-rest-fake.cjs';
import {createIdentity} from '../feasibility/shared-backend/identity.mjs';
import fakes from './helpers/shared-backend-fakes.cjs';

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
function fixture({actorGeneration = 0, targetGeneration = 0, ...overrides} = {}) {
  const identity = fakes.fixture(), seed = identity.store.snapshot();
  for (const uid of ['owner', 'staff']) {
    for (const path of [`user_cafe_memberships/${uid}`, `cafes/cafe/members/${uid}`]) {
      seed[path].membershipGeneration = uid === 'owner' ? actorGeneration : targetGeneration;
      seed[path].createdAt = new Date(identity.now());
    }
  }
  const fake = createRestFake(seed), http = createGoogleHttp({projectId, transport: fake.transport});
  const store = createFirestoreStore({projectId, http, sleep: async () => {},
    accessToken: Object.assign(async () => 'synthetic-access', {projectId})});
  const lookups = [], hooks = {};
  const getAccount = Object.assign(async uid => {
    lookups.push(uid);
    if (hooks.account) return hooks.account(uid);
    return {...identity.accounts[uid], PRIVATE: 'SECRET'};
  }, {projectId});
  const options = {projectId, storeProjectId: projectId, verifyIdentity: createIdentity(identity.identity), store,
    timestamp: store.timestamp, getAccount, ...overrides};
  const handler = createStaffHttp(options);
  const call = async (path = '/staff/list', data = {}, {uid = 'owner', token = identity.token(uid), method = 'POST'} = {}) => {
    const response = await handler(new Request('https://offline.invalid' + path, {method,
      headers: {'content-type': 'application/json', ...(token === null ? {} : {authorization: `Bearer ${token}`})},
      ...(method === 'POST' ? {body: JSON.stringify(data)} : {})}));
    const body = await response.json();
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(JSON.stringify(body).includes('SECRET'), false);
    assert.equal(JSON.stringify(body).includes('tokensValidAfterTime'), false);
    return {status: response.status, body};
  };
  const removal = {targetUid: 'staff', expectedCafeId: 'cafe', expectedGeneration: targetGeneration,
    expectedActorGeneration: actorGeneration, idempotencyKey: 'remove-request-0001'};
  return {identity, fake, options, call, removal, lookups, hooks};
}
const commits = f => f.fake.calls.filter(call => call.method === 'commit');

test('requires project-bound accounts and compatible store without I/O', () => {
  const f = fixture(); assert.equal(f.fake.calls.length, 0);
  for (const patch of [{storeProjectId: 'velora-73222'}, {store: {...f.options.store, projectId: 'velora-73222'}},
    {getAccount: async () => {}}, {accountTimeoutMs: 0}, {timestamp: null}]) {
    assert.throws(() => createStaffHttp({...f.options, ...patch}));
  }
});

for (const uid of ['owner', 'staff']) test(`canonical ${uid} roster is scoped, minimal and read-only`, async () => {
  const f = fixture(), before = f.fake.snapshot(), result = await f.call('/staff/list', {}, {uid});
  assert.equal(result.status, 200); assert.equal(result.body.viewerRole, uid);
  assert.deepEqual(result.body.members.map(member => member.uid), ['owner', 'staff']);
  assert.deepEqual(Object.keys(result.body.members[0]).sort(), ['email', 'name', 'role', 'uid']);
  assert.deepEqual(f.fake.snapshot(), before);
  assert.equal(commits(f).length, 2); assert.ok(commits(f).every(call => !call.body.writes.length));
  if (uid === 'staff') assert.equal(f.fake.calls.some(call => call.method === 'runQuery'), false);
});

test('Staff sees only self and Owner while Owner sees other current Staff', async () => {
  const f = fixture(), link = {uid: 'joiner', cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 0};
  f.fake.replace('user_cafe_memberships/joiner', link);
  f.fake.replace('cafes/cafe/members/joiner', {...link, role: 'staff'});
  assert.deepEqual((await f.call('/staff/list', {}, {uid: 'staff'})).body.members.map(member => member.uid), ['owner', 'staff']);
  assert.equal(f.lookups.includes('joiner'), false);
  assert.equal((await f.call()).body.members.length, 3);
});

test('roster enrichment occurs between read transactions and membership changes are revalidated', async () => {
  const f = fixture(); let once = false;
  f.hooks.account = uid => {
    assert.equal(commits(f).length, 1, 'first snapshot committed before account I/O');
    if (!once) { once = true; f.fake.replace('cafes/cafe/members/owner', {...f.fake.snapshot()['cafes/cafe/members/owner'], status: 'inactive'}); }
    return f.identity.accounts[uid];
  };
  assert.deepEqual(await f.call(), {status: 403, body: {error: 'permission-denied'}});
  assert.equal(commits(f).length, 1);
});

test('target generation change during enrichment omits the stale profile', async () => {
  const f = fixture(); let once = false;
  f.hooks.account = uid => {
    if (!once) {
      once = true;
      for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
        f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
      }
    }
    return f.identity.accounts[uid];
  };
  const result = await f.call(); assert.equal(result.status, 200);
  assert.deepEqual(result.body.members.map(member => member.uid), ['owner']);
});

for (const invalid of [null, {uid: 'other'}, {uid: 'staff', disabled: true}, {uid: 'staff', emailVerified: false}]) {
  test(`malformed/unavailable enrichment ${JSON.stringify(invalid)} has no data leakage`, async () => {
    const f = fixture(); f.hooks.account = async () => invalid;
    assert.deepEqual(await f.call(), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
    assert.equal(commits(f).length, 1);
  });
}

test('bounded account concurrency and timeout start no new lookups after deadline', async () => {
  const f = fixture({accountTimeoutMs: 15});
  for (let i = 0; i < 12; i++) {
    const uid = `member${i}`, link = {uid, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 0};
    f.fake.replace(`user_cafe_memberships/${uid}`, link); f.fake.replace(`cafes/cafe/members/${uid}`, {...link, role: 'staff'});
  }
  let release, active = 0, peak = 0;
  const gate = new Promise(resolve => { release = resolve; });
  f.hooks.account = async uid => { peak = Math.max(peak, ++active); await gate; active--;
    return {uid, disabled: false, emailVerified: true, email: `${uid}@example.test`}; };
  assert.equal((await f.call()).status, 503); assert.equal(peak, 4);
  const count = f.lookups.length; release(); await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(f.lookups.length, count); assert.equal(commits(f).length, 1);
});

test('101-row roster overflow rejects before any account lookup', async () => {
  const f = fixture();
  for (let i = 0; i < 101; i++) f.fake.replace(`cafes/cafe/members/member${i}`, {});
  assert.deepEqual(await f.call(), {status: 429, body: {error: 'resource-exhausted'}});
  assert.equal(f.lookups.length, 0);
});

for (const [actorGeneration, targetGeneration] of [[0, 0], [7, 3]]) {
  test(`removal actor=${actorGeneration} target=${targetGeneration} is atomic and historically replayable`, async () => {
    const f = fixture({actorGeneration, targetGeneration});
    const first = await f.call('/staff/remove', f.removal); assert.equal(first.status, 200);
    assert.equal(first.body.resultGeneration, targetGeneration + 1); assert.equal(first.body.changed, true);
    const state = f.fake.snapshot();
    assert.equal(state['user_cafe_memberships/staff'].status, 'inactive');
    assert.equal(state['cafes/cafe/members/staff'].membershipGeneration, targetGeneration + 1);
    const events = Object.entries(state).filter(([path]) => path.includes('/membership_events/'));
    assert.equal(events.length, 1); assert.equal(events[0][1].previousMember.role, 'staff');
    assert.equal(commits(f)[0].body.writes.length, 4);
    assert.ok(commits(f)[0].body.writes.every(write => !write.delete));
    assert.deepEqual(await f.call('/staff/remove', f.removal), {status: 200, body: {...first.body, changed: false}});
    assert.deepEqual(commits(f).at(-1).body.writes, []);
  });
}

for (const [name, patch, uid, status] of [
  ['Staff actor', {}, 'staff', 403], ['self', {targetUid: 'owner'}, 'owner', 403],
  ['wrong workspace', {expectedCafeId: 'other'}, 'owner', 409], ['stale actor', {expectedActorGeneration: 1}, 'owner', 409],
  ['stale target', {expectedGeneration: 1}, 'owner', 409],
  ['renamed generation', {expectedMembershipGeneration: 0}, 'owner', 400],
]) test(`removal rejects ${name} without writes`, async () => {
  const f = fixture(), before = f.fake.snapshot();
  assert.equal((await f.call('/staff/remove', {...f.removal, ...patch}, {uid})).status, status);
  assert.deepEqual(f.fake.snapshot(), before); assert.equal(commits(f).length, 0);
});

test('removing a different Owner is denied rather than converted into Staff removal', async () => {
  const f = fixture(); f.fake.replace('cafes/cafe/members/staff', {...f.fake.snapshot()['cafes/cafe/members/staff'], role: 'owner'});
  assert.equal((await f.call('/staff/remove', f.removal)).status, 403); assert.equal(commits(f).length, 0);
});

test('historical replay cannot remove a later active target episode', async () => {
  const f = fixture(), first = await f.call('/staff/remove', f.removal);
  for (const path of ['user_cafe_memberships/staff', 'cafes/cafe/members/staff']) {
    f.fake.replace(path, {...f.fake.snapshot()[path], status: 'active', membershipGeneration: 2});
  }
  const before = f.fake.snapshot();
  assert.deepEqual(await f.call('/staff/remove', f.removal), {status: 200, body: {...first.body, changed: false}});
  assert.deepEqual(f.fake.snapshot(), before);
  assert.equal((await f.call('/staff/remove', {...f.removal, expectedGeneration: 2})).status, 409);
});

test('contention rereads actor generation and preserves canonical aborted error', async () => {
  const f = fixture(); let first = true;
  f.fake.hooks.commit = () => {
    if (!first) return;
    first = false;
    for (const path of ['user_cafe_memberships/owner', 'cafes/cafe/members/owner']) {
      f.fake.replace(path, {...f.fake.snapshot()[path], membershipGeneration: 1});
    }
    return f.fake.nativeError(409, 'ABORTED');
  };
  assert.deepEqual(await f.call('/staff/remove', f.removal), {status: 409, body: {error: 'aborted'}});
  assert.equal(commits(f).length, 1); assert.equal(f.fake.snapshot()['user_cafe_memberships/staff'].status, 'active');
});

for (const mode of ['lost', 'applied-lost', 'malformed']) test(`removal ${mode} acknowledgement remains unknown without retry`, async () => {
  const f = fixture(); f.fake.commitModes.push(mode);
  assert.deepEqual(await f.call('/staff/remove', f.removal), {status: 503, body: {error: 'unavailable', outcomeUnknown: true}});
  assert.equal(commits(f).length, 1);
});

test('missing identity, outsider and public account selector fail closed', async () => {
  const f = fixture();
  assert.equal((await f.call('/staff/list', {}, {token: null})).status, 401);
  assert.equal((await f.call('/staff/list', {}, {uid: 'outsider'})).status, 403);
  assert.equal((await f.call('/staff/list', {email: 'outsider@example.test'})).status, 400);
  assert.equal((await f.call('/staff/accounts', {})).status, 404);
  assert.equal(f.lookups.length, 0);
});
