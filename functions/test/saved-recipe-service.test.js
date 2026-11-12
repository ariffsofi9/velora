'use strict';

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const m = require('../src/saved-recipe-model');
const {createSavedRecipeService} = require('../src/saved-recipe-service');

globalThis.fetch = () => { throw Error('Unexpected network'); };
const projectId = 'velora-spark-test';
const E = {expectedCafeId: 'a', expectedMembershipGeneration: 0};
const copy = x => structuredClone(x);
const recipe = () => ({title: 'Milk', ingredients: [{itemId: 'milk', quantity: 0.125, unit: 'L'}],
  steps: ['Stir.'], whyRecommended: 'Uses stock.'});
const attribution = () => ({kind: 'claimed-ai', provider: 'groq', ticketId: 'a'.repeat(64)});
const save = (key = 'save-request-0001', r = recipe()) => ({idempotencyKey: key, recipe: r, attribution: attribution()});
const lifecycle = (item, action = 'archive', key = 'lifecycle-request-0001') =>
  ({idempotencyKey: key, recipeId: item.recipeId, expectedVersion: item.version, action});
const error = (code, unknown = false) => e => e instanceof m.SavedRecipeError && e.code === code &&
  e.outcomeUnknown === unknown && e.message === 'Saved recipes are unavailable.' &&
  e.reason === (unknown ? 'outcome-unknown' : undefined);

// Optimistic whole-snapshot fake, including query phantom detection. Atomic
// staged writes, create preconditions and callback reruns are a model of the E3
// dependency contract, NOT evidence about native Firestore or deployed Rules.
class Store {
  constructor() {
    this.projectId = projectId; this.docs = new Map(); this.revision = 0;
    this.calls = 0; this.attempts = 0; this.commits = 0; this.writes = [];
    this.reads = []; this.queries = []; this.beforeCommit = null; this.unknown = null;
    for (const [uid, cafe, role, owner] of [['owner', 'a', 'owner', 'owner'], ['staff', 'a', 'staff', 'owner'],
      ['outsider', 'b', 'owner', 'outsider']]) {
      const link = {uid, cafeId: cafe, status: 'active', schemaVersion: 1};
      this.put(`user_cafe_memberships/${uid}`, link);
      this.put(`cafes/${cafe}/members/${uid}`, {...link, role});
      if (uid === owner) this.put(`cafes/${cafe}`, {ownerUid: uid, status: 'active', schemaVersion: 1});
    }
  }
  put(path, data) { this.docs.set(path, copy(data)); this.revision++; }
  async runTransaction(callback) {
    this.calls++;
    for (let attempt = 0; attempt < 8; attempt++) {
      this.attempts++;
      const revision = this.revision, snapshot = new Map([...this.docs].map(([p, v]) => [p, copy(v)]));
      const writes = [];
      const read = () => assert.equal(writes.length, 0, 'reads precede writes');
      const tx = {
        get: async path => { read(); this.reads.push(path); return copy(snapshot.get(path) ?? null); },
        savedRecipes: async (cafe, input) => {
          read(); this.queries.push({cafe, ...input});
          const prefix = `cafes/${cafe}/saved_recipes/`;
          const rows = [...snapshot].filter(([p]) => p.startsWith(prefix)).map(([p, data]) => ({id: p.slice(prefix.length), data}));
          const selected = rows.filter(row => (input.mode === 'all' || row.data.isArchived === (input.mode === 'archived')) &&
            (!input.afterId || row.id > input.afterId)).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0).slice(0, input.limit);
          return this.queryOverride ? this.queryOverride(selected) : selected;
        },
        create: (path, data) => {
          assert.equal(snapshot.has(path), false, 'create must be absent');
          if (this.failReceipt && path.includes('/saved_recipe_requests/')) throw Error('staging failed');
          writes.push([path, copy(data)]);
        },
        update: (path, data) => { assert.equal(snapshot.has(path), true, 'update must exist'); writes.push([path, {...snapshot.get(path), ...copy(data)}]); },
      };
      const result = await callback(tx);
      if (this.beforeCommit) { const hook = this.beforeCommit; this.beforeCommit = null; await hook(); }
      if (revision !== this.revision) continue;
      if (this.unknown === 'before') { this.unknown = null; throw Error('private precommit transport detail'); }
      if (writes.length) {
        for (const [path, data] of writes) this.docs.set(path, data);
        this.writes.push(...writes); this.revision++; this.commits++;
      }
      if (this.unknown === 'after') {
        this.unknown = null;
        // Even a dependency exception masquerading as a domain rejection must
        // not erase commit uncertainty or cause another transaction call.
        throw new m.SavedRecipeError('permission-denied');
      }
      return result;
    }
    throw Error('definite abort budget exhausted');
  }
}
function fixture() {
  const store = new Store(), accounts = new Map();
  for (const uid of ['owner', 'staff', 'outsider']) accounts.set(uid, {uid, token: {sub: uid,
    aud: projectId, iss: `https://securetoken.google.com/${projectId}`, email_verified: true}});
  let verifies = 0;
  const verifyIdentity = Object.assign(async token => {
    verifies++;
    const account = accounts.get(token);
    if (!account || account.disabled || account.revoked) throw Error('private account detail');
    return copy(account);
  }, {projectId});
  const timestamp = () => new Date('2026-11-12T00:00:00.000Z');
  const service = createSavedRecipeService({projectId, store, verifyIdentity, timestamp});
  const call = (operation, data, token = 'owner') => service({operation, token,
    data: operation === 'reconcile' ? data : {...E, ...data}});
  return {store, accounts, verifyIdentity, timestamp, service, call, verifies: () => verifies};
}
const itemPath = item => `cafes/a/saved_recipes/${item.recipeId}`;
const receiptPath = item => `cafes/a/saved_recipe_requests/${item.requestHash}`;

test('factory requires explicit matching TEST dependencies and construction is inert', () => {
  const f = fixture();
  assert.equal(f.store.calls, 0); assert.equal(f.verifies(), 0);
  for (const overrides of [{projectId: 'velora-73222'}, {projectId: undefined}, {store: {}},
    {verifyIdentity: async () => ({})}, {timestamp: undefined}]) {
    assert.throws(() => createSavedRecipeService({projectId, store: f.store, verifyIdentity: f.verifyIdentity,
      timestamp: f.timestamp, ...overrides}), error('failed-precondition'));
  }
});

test('canonical decimal and exponent golden bytes/digests match E1 exactly', () => {
  const r = recipe();
  assert.equal(m.canonicalContent(r), '["velora.saved-recipe.content.v1","Milk",[["milk",0.125,"L"]],["Stir."],"Uses stock."]');
  assert.equal(m.identity(projectId, 'a', r).contentDigest, '0644d7554d7a27b690a1de90d5ebebd570b3698677e2adc38c722612bdeee2c7');
  r.title = 'Tiny'; r.ingredients[0].quantity = 1e-7;
  assert.equal(m.canonicalContent(r), '["velora.saved-recipe.content.v1","Tiny",[["milk",1e-7,"L"]],["Stir."],"Uses stock."]');
  assert.equal(m.identity(projectId, 'a', r).contentDigest, '01faf9a626ec5b53218e54bb87833e1b29810830b3430712f0827c52ce0e0aac');
});
test('Unicode, escaping and array-order golden serialization is not normalized', () => {
  const r = recipe(); r.title = 'Café 😀 "tea" \\';
  r.ingredients.push({itemId: 'egg', quantity: 1, unit: 'pcs'}); r.steps.push('Serve.');
  const bytes = '["velora.saved-recipe.content.v1","Café 😀 \\"tea\\" \\\\",[["milk",0.125,"L"],["egg",1,"pcs"]],["Stir.","Serve."],"Uses stock."]';
  assert.equal(m.canonicalContent(r), bytes);
  assert.equal(m.identity(projectId, 'a', r).contentDigest, createHash('sha256').update(bytes, 'utf8').digest('hex'));
  const original = m.identity(projectId, 'a', r);
  assert.equal(original.recipeId, 'recipe_' + createHash('sha256').update(JSON.stringify([
    'velora.saved-recipe.id.v1', projectId, 'a', original.contentDigest])).digest('hex'));
  for (const edit of [v => { v.title = v.title.normalize('NFD'); }, v => { v.ingredients.reverse(); },
    v => { v.steps.reverse(); }, v => { v.whyRecommended += '!'; }, v => { v.ingredients[0].quantity = 0.126; },
    v => { v.ingredients[0].unit = 'kg'; }, v => { v.ingredients[0].itemId = 'other'; }]) {
    const changed = copy(r); edit(changed);
    assert.notEqual(m.identity(projectId, 'a', changed).recipeId, original.recipeId);
  }
  assert.notEqual(m.identity(projectId, 'b', r).recipeId, original.recipeId);
  assert.notEqual(m.identity('velora-73222', 'a', r).recipeId, original.recipeId);
  assert.equal(m.canonicalContent({...recipe(), ingredients: [{itemId: 'milk', quantity: 1.0, unit: 'L'}]}),
    m.canonicalContent({...recipe(), ingredients: [{itemId: 'milk', quantity: 1, unit: 'L'}]}));
});

const invalidRecipes = {
  missing: r => { delete r.title; }, extra: r => { r.preparation = ['Invented']; },
  titleType: r => { r.title = 1; }, empty: r => { r.title = ''; }, trim: r => { r.title = ' Milk'; },
  controls: r => { r.title = 'Milk\n'; }, surrogate: r => { r.title = '\ud800'; },
  longTitle: r => { r.title = 'x'.repeat(101); }, longStep: r => { r.steps[0] = 'x'.repeat(301); },
  longRecommendation: r => { r.whyRecommended = 'x'.repeat(301); },
  missingIngredients: r => { r.ingredients = []; }, tooManyIngredients: r => { r.ingredients = Array.from({length: 11}, (_, i) => ({itemId: `i${i}`, quantity: 1, unit: 'pcs'})); },
  duplicate: r => { r.ingredients.push(copy(r.ingredients[0])); },
  unsafeId: r => { r.ingredients[0].itemId = '../other'; }, longId: r => { r.ingredients[0].itemId = 'x'.repeat(129); },
  idSurrogate: r => { r.ingredients[0].itemId = '\udfff'; },
  ingredientExtra: r => { r.ingredients[0].name = 'Invented'; }, ingredientMissing: r => { delete r.ingredients[0].unit; },
  stringQuantity: r => { r.ingredients[0].quantity = '0.125'; }, zero: r => { r.ingredients[0].quantity = 0; },
  negative: r => { r.ingredients[0].quantity = -1; }, nan: r => { r.ingredients[0].quantity = NaN; },
  infinite: r => { r.ingredients[0].quantity = Infinity; }, excessiveQuantity: r => { r.ingredients[0].quantity = 1000001; },
  fractionalCount: r => { r.ingredients[0].unit = 'pcs'; }, unsupportedUnit: r => { r.ingredients[0].unit = 'cup'; },
  missingSteps: r => { r.steps = []; }, tooManySteps: r => { r.steps = Array(9).fill('Stir.'); },
  sparseSteps: r => { r.steps = Array(1); }, extraArrayProperty: r => { r.steps.extra = true; },
  recommendationType: r => { r.whyRecommended = null; },
};
for (const [label, edit] of Object.entries(invalidRecipes)) {
  test(`rejects canonical recipe: ${label}`, async () => {
    const f = fixture(), r = recipe(); edit(r);
    await assert.rejects(f.call('save', save('save-request-0001', r)), error('invalid-argument'));
    assert.equal(f.store.calls, 0); assert.equal(f.store.commits, 0);
  });
}
test('maximum canonical fields and every unit are accepted without conversion', () => {
  const r = {title: 'x'.repeat(100), ingredients: Array.from({length: 10}, (_, i) => ({
    itemId: `${i}${'x'.repeat(127)}`, quantity: 1000000, unit: ['kg', 'g', 'L', 'ml', 'pcs'][i % 5]})),
  steps: Array(8).fill('x'.repeat(300)), whyRecommended: 'x'.repeat(300)};
  assert.deepEqual(m.parseRecipe(r), r);
  assert.deepEqual(m.parseRecipe({...recipe(), title: '😀'.repeat(50)}).title, '😀'.repeat(50));
  assert.throws(() => m.parseRecipe({...recipe(), title: '😀'.repeat(51)}), error('invalid-argument'));
  assert.throws(() => m.boundedJson('x'.repeat(32769), 32768), error('invalid-argument'));
  assert.throws(() => m.parseRecipe(Object.assign(Object.create({}), recipe())), error('invalid-argument'));
  const accessor = recipe(); Object.defineProperty(accessor, 'title', {get() { throw Error('must not run'); }});
  assert.throws(() => m.parseRecipe(accessor), error('invalid-argument'));
});
for (const bad of [{kind: 'claimed-ai', provider: 'other', ticketId: null},
  {kind: 'mock', provider: 'groq', ticketId: null}, {kind: 'verified', provider: null, ticketId: null},
  {kind: 'claimed-ai', provider: 'groq'}, {...attribution(), verified: true}, {...attribution(), ticketId: 'bad'}]) {
  test(`rejects unsupported provenance ${JSON.stringify(bad)}`, async () => {
    const f = fixture(); await assert.rejects(f.call('save', {...save(), attribution: bad}), error('invalid-argument'));
    assert.equal(f.store.commits, 0);
  });
}
for (const kind of ['unspecified', 'sample', 'mock', 'claimed-ai']) {
  test(`accepted ${kind} attribution is never promoted to verified AI`, async () => {
    const f = fixture(); const input = {...save(), attribution: {kind, provider: null, ticketId: null}};
    const ack = await f.call('save', input);
    const record = f.store.docs.get(itemPath(ack));
    assert.equal(record.source, 'workspace-submitted'); assert.equal(record.provenanceEvidence, 'unverified-attribution');
    assert.deepEqual(record.submittedAttribution, input.attribution);
  });
}

for (const uid of ['owner', 'staff']) {
  test(`${uid} saves, reads and lists its cafe without other-domain writes`, async () => {
    const f = fixture(), input = save(), ack = await f.call('save', input, uid);
    assert.equal(ack.outcome, 'created'); assert.equal(ack.changed, true); assert.equal(ack.replayed, false);
    const doc = (await f.call('get', {recipeId: ack.recipeId}, uid)).item;
    assert.deepEqual(doc.recipe, input.recipe); assert.equal(doc.createdBy, uid); assert.equal(doc.version, 1);
    assert.equal(doc.createdAt, '2026-11-12T00:00:00.000Z');
    const page = await f.call('list', {mode: 'active', limit: 20, cursor: null}, uid);
    assert.equal(page.items.length, 1); assert.equal(page.nextCursor, null); assert.equal(page.items[0].recipe, undefined);
    assert.equal(f.store.writes.length, 2);
    assert.ok(f.store.writes.every(([path]) => /^cafes\/a\/saved_recipe(?:s|_requests)\//.test(path)));
  });
}
for (const change of ['email', 'aud', 'iss', 'sub', 'disabled', 'revoked', 'missing']) {
  test(`trusted identity rejects ${change} before transaction`, async () => {
    const f = fixture(), account = f.accounts.get('owner');
    if (change === 'email') account.token.email_verified = false;
    else if (['aud', 'iss', 'sub'].includes(change)) account.token[change] = 'wrong';
    else if (change === 'missing') f.accounts.delete('owner');
    else account[change] = true;
    await assert.rejects(f.call('save', save()), error('unauthenticated'));
    assert.equal(f.store.calls, 0);
  });
}
for (const change of ['revoked', 'cafe', 'member', 'owner-link', 'owner-role', 'partial-generation', 'bad-generation']) {
  test(`transactional authority rejects ${change}`, async () => {
    const f = fixture();
    const path = change === 'cafe' ? 'cafes/a' : change === 'member' || change === 'partial-generation' ? 'cafes/a/members/staff'
      : change === 'owner-link' ? 'user_cafe_memberships/owner' : change === 'owner-role' ? 'cafes/a/members/owner' : 'user_cafe_memberships/staff';
    const value = f.store.docs.get(path);
    if (change === 'partial-generation') value.membershipGeneration = 1;
    else if (change === 'bad-generation') value.membershipGeneration = -1;
    else if (change === 'owner-role') value.role = 'staff';
    else value.status = 'revoked';
    f.store.put(path, value);
    await assert.rejects(f.call('save', save(), 'staff'), error('permission-denied'));
    assert.equal(f.store.commits, 0);
  });
}
test('expected generations/cafes are preconditions, never authorization', async () => {
  const f = fixture();
  await assert.rejects(f.call('save', {...save(), expectedCafeId: 'b'}), error('aborted'));
  await assert.rejects(f.call('save', {...save(), expectedMembershipGeneration: 1}), error('aborted'));
  const own = await f.call('save', save());
  await assert.rejects(f.call('get', {recipeId: own.recipeId}, 'outsider'), error('aborted'));
  await assert.rejects(f.call('get', {recipeId: own.recipeId, expectedCafeId: 'b'}, 'outsider'), error('not-found'));
  for (const path of ['user_cafe_memberships/owner', 'cafes/a/members/owner']) {
    f.store.put(path, {...f.store.docs.get(path), membershipGeneration: 2});
  }
  await assert.rejects(f.call('save', save()), error('aborted'));
  const ack = await f.call('save', {...save('new-episode-key-0001'), expectedMembershipGeneration: 2});
  assert.equal(ack.outcome, 'existing-active');
});

for (const [name, mutate] of Object.entries({unknown: v => { v.role = 'owner'; }, missing: v => { delete v.expectedCafeId; },
  digest: v => { v.contentDigest = 'a'.repeat(64); }, shortKey: v => { v.idempotencyKey = 'short'; },
  negativeGeneration: v => { v.expectedMembershipGeneration = -1; }, badCafe: v => { v.expectedCafeId = '../a'; }})) {
  test(`strict request rejects ${name}`, async () => {
    const f = fixture(), data = {...E, ...save()}; mutate(data);
    await assert.rejects(f.service({operation: 'save', token: 'owner', data}), error('invalid-argument'));
    assert.equal(f.store.calls, 0);
  });
}
test('caller mutation during identity verification cannot change captured intent', async () => {
  const f = fixture(), input = {...E, ...save()};
  let release;
  const wait = new Promise(resolve => { release = resolve; });
  const verify = Object.assign(async token => { await wait; return f.verifyIdentity(token); }, {projectId});
  const service = createSavedRecipeService({projectId, store: f.store, verifyIdentity: verify, timestamp: f.timestamp});
  const pending = service({operation: 'save', token: 'owner', data: input});
  input.recipe.title = 'Changed'; input.attribution.kind = 'mock'; release();
  const ack = await pending;
  assert.equal(f.store.docs.get(itemPath(ack)).recipe.title, 'Milk');
  assert.equal(f.store.docs.get(itemPath(ack)).submittedAttribution.kind, 'claimed-ai');
});

test('duplicate content, request replay and changed payload are distinct', async () => {
  const f = fixture(), first = await f.call('save', save());
  const before = copy(f.store.docs.get(itemPath(first))), commits = f.store.commits;
  const replay = await f.call('save', save());
  assert.deepEqual(replay, {...first, replayed: true}); assert.equal(f.store.commits, commits);
  const duplicate = await f.call('save', {...save('second-request-0001'), attribution: {kind: 'sample', provider: null, ticketId: null}}, 'staff');
  assert.equal(duplicate.outcome, 'existing-active'); assert.equal(duplicate.changed, false); assert.equal(duplicate.replayed, false);
  assert.equal(duplicate.recipeId, first.recipeId); assert.deepEqual(f.store.docs.get(itemPath(first)), before);
  await assert.rejects(f.call('save', {...save(), recipe: {...recipe(), title: 'Other'}}), error('already-exists'));
  await assert.rejects(f.call('save', {...save(), attribution: {kind: 'mock', provider: null, ticketId: null}}), error('already-exists'));
  assert.equal(f.store.writes.filter(([p]) => p.includes('/saved_recipes/')).length, 1);
});
test('concurrent same-content saves atomically produce one record and separate receipts', async () => {
  const f = fixture();
  const values = await Promise.all([f.call('save', save()), f.call('save', save('second-request-0001'), 'staff')]);
  assert.deepEqual(new Set(values.map(v => v.recipeId)).size, 1);
  assert.deepEqual(values.map(v => v.outcome).sort(), ['created', 'existing-active']);
  assert.equal([...f.store.docs.keys()].filter(p => p.includes('/saved_recipes/')).length, 1);
  assert.equal([...f.store.docs.keys()].filter(p => p.includes('/saved_recipe_requests/')).length, 2);
  assert.ok(f.store.attempts > f.store.calls);
});
test('concurrent identical request replay writes only once', async () => {
  const f = fixture();
  const results = await Promise.all([f.call('save', save()), f.call('save', save())]);
  assert.equal(results.filter(r => r.replayed).length, 1); assert.equal(f.store.commits, 1);
});
test('authority is rechecked on a transaction retry after membership revocation', async () => {
  const f = fixture();
  f.store.beforeCommit = () => f.store.put('cafes/a/members/staff', {...f.store.docs.get('cafes/a/members/staff'), status: 'revoked'});
  await assert.rejects(f.call('save', save(), 'staff'), error('permission-denied'));
  assert.equal(f.store.commits, 0); assert.equal(f.store.attempts, 2);
});
test('Owner archive/restore versions, historic replay and duplicate-archived semantics', async () => {
  const f = fixture(), first = await f.call('save', save());
  const archived = await f.call('lifecycle', lifecycle(first));
  assert.equal(archived.version, 2); assert.equal(archived.outcome, 'archived');
  const stored = f.store.docs.get(itemPath(first));
  assert.equal(stored.archivedBy, 'owner'); assert.deepEqual(stored.archivedAt, stored.updatedAt);
  assert.equal((await f.call('get', {recipeId: first.recipeId}, 'staff')).item.isArchived, true);
  assert.equal((await f.call('list', {mode: 'archived', limit: 20, cursor: null}, 'staff')).items.length, 1);
  const duplicate = await f.call('save', save('staff-save-key-0001'), 'staff');
  assert.equal(duplicate.outcome, 'existing-archived'); assert.equal(duplicate.isArchived, true);
  for (const action of ['archive', 'restore']) {
    await assert.rejects(f.call('lifecycle', lifecycle(archived, action, `staff-${action}-key-0001`), 'staff'), error('permission-denied'));
  }
  await assert.rejects(f.call('lifecycle', lifecycle(first, 'restore', 'stale-version-key-0001')), error('aborted'));
  await assert.rejects(f.call('lifecycle', lifecycle(archived, 'archive', 'same-state-key-0001')), error('failed-precondition'));
  const restored = await f.call('lifecycle', lifecycle(archived, 'restore', 'restore-request-0001'));
  assert.equal(restored.version, 3); assert.equal(restored.isArchived, false);
  assert.equal(f.store.docs.get(itemPath(first)).archivedAt, null);
  assert.deepEqual(await f.call('lifecycle', lifecycle(first)), {...archived, replayed: true});
  const observation = await f.call('reconcile', {operation: 'lifecycle', request: {...E, ...lifecycle(first)}});
  assert.deepEqual(observation, {schemaVersion: 1, status: 'committed', result: {...archived, replayed: true}});
  assert.deepEqual(await f.call('save', save()), {...first, replayed: true});
});
test('concurrent lifecycle requests cannot both change the same version', async () => {
  const f = fixture(), first = await f.call('save', save());
  const settled = await Promise.allSettled([f.call('lifecycle', lifecycle(first)),
    f.call('lifecycle', lifecycle(first, 'archive', 'another-archive-key-0001'))]);
  assert.equal(settled.filter(r => r.status === 'fulfilled').length, 1);
  assert.ok(error('aborted')(settled.find(r => r.status === 'rejected').reason));
  assert.equal(f.store.docs.get(itemPath(first)).version, 2);
});
test('lifecycle overflow fails without recipe or receipt writes', async () => {
  const f = fixture(), first = await f.call('save', save());
  f.store.put(itemPath(first), {...f.store.docs.get(itemPath(first)), version: Number.MAX_SAFE_INTEGER});
  const writes = f.store.writes.length;
  await assert.rejects(f.call('lifecycle', lifecycle({...first, version: Number.MAX_SAFE_INTEGER})), error('failed-precondition'));
  assert.equal(f.store.writes.length, writes);
});

test('bounded ID pagination validates complete look-ahead and returns summaries only', async () => {
  const f = fixture(), records = [];
  for (let i = 0; i < 5; i++) records.push(await f.call('save', save(`request-number-${i}000`, {...recipe(), title: `Recipe ${i}`})));
  const ids = records.map(r => r.recipeId).sort();
  const first = await f.call('list', {mode: 'active', limit: 2, cursor: null});
  assert.deepEqual(first.items.map(r => r.recipeId), ids.slice(0, 2));
  assert.equal(first.nextCursor.afterId, ids[1]);
  assert.equal(f.store.queries.at(-1).limit, 3);
  const second = await f.call('list', {mode: 'active', limit: 2, cursor: first.nextCursor});
  assert.deepEqual(second.items.map(r => r.recipeId), ids.slice(2, 4));
  const last = await f.call('list', {mode: 'active', limit: 2, cursor: second.nextCursor});
  assert.equal(last.items[0].recipeId, ids[4]); assert.equal(last.nextCursor, null);
  const original = records[0]; await f.call('lifecycle', lifecycle(original));
  assert.equal((await f.call('list', {mode: 'archived', limit: 20, cursor: null})).items.length, 1);
  assert.equal((await f.call('list', {mode: 'all', limit: 20, cursor: null})).items.length, 5);
  assert.equal((await f.call('list', {mode: 'active', limit: 20, cursor: null})).items.length, 4);
  const lookAheadPath = `cafes/a/saved_recipes/${ids[2]}`;
  f.store.put(lookAheadPath, {...f.store.docs.get(lookAheadPath), source: 'verified-groq'});
  await assert.rejects(f.call('list', {mode: 'all', limit: 2, cursor: null}), error('failed-precondition'));
});
for (const field of ['projectId', 'cafeId', 'uid', 'membershipGeneration', 'mode', 'limit', 'schemaVersion', 'afterId']) {
  test(`rejects foreign/malformed cursor ${field}`, async () => {
    const f = fixture(), id = m.identity(projectId, 'a', recipe()).recipeId;
    const cursor = {schemaVersion: 1, projectId, cafeId: 'a', uid: 'owner', membershipGeneration: 0, mode: 'all', limit: 2, afterId: id};
    cursor[field] = typeof cursor[field] === 'number' ? 99 : 'other';
    await assert.rejects(f.call('list', {mode: 'all', limit: 2, cursor}), error('invalid-argument'));
    assert.equal(f.store.queries.length, 0);
  });
}
for (const limit of [0, 21, 1.5, '2', null]) {
  test(`rejects list limit ${JSON.stringify(limit)}`, async () => {
    const f = fixture(); await assert.rejects(f.call('list', {mode: 'active', limit, cursor: null}), error('invalid-argument'));
  });
}
for (const kind of ['duplicate', 'unsorted', 'overflow', 'foreign', 'wrong-filter', 'nested', 'extra-row-field', 'sparse']) {
  test(`rejects malformed adapter page ${kind}`, async () => {
    const f = fixture(), first = await f.call('save', save());
    await f.call('save', save('second-request-0001', {...recipe(), title: 'Other'}));
    f.store.queryOverride = rows => {
      if (kind === 'duplicate') return [rows[0], rows[0]];
      if (kind === 'unsorted') return rows.reverse();
      if (kind === 'overflow') return [rows[0], rows[0], rows[0]];
      if (kind === 'sparse') return Array(1);
      if (kind === 'foreign') rows[0].data.cafeId = 'b';
      if (kind === 'wrong-filter') { rows[0].data.version = 2; rows[0].data.isArchived = true; rows[0].data.archivedBy = 'owner'; rows[0].data.archivedAt = rows[0].data.updatedAt; }
      if (kind === 'nested') rows[0].id += '/nested';
      if (kind === 'extra-row-field') rows[0].other = true;
      return rows;
    };
    await assert.rejects(f.call('list', {mode: 'active', limit: 1, cursor: null}), error('failed-precondition'));
    assert.equal(f.store.docs.get(itemPath(first)).version, 1);
  });
}

for (const [label, edit] of Object.entries({extra: d => { d.secret = 'bad'; }, foreign: d => { d.cafeId = 'b'; },
  project: d => { d.projectId = 'velora-73222'; }, schema: d => { d.schemaVersion = 2; }, hash: d => { d.contentDigest = '0'.repeat(64); },
  content: d => { d.recipe.title = 'Changed'; }, time: d => { d.createdAt = '2026-01-01'; },
  backwards: d => { d.updatedAt = new Date('2020-01-01'); }, actor: d => { d.createdBy = '../other'; },
  provenance: d => { d.provenanceEvidence = 'verified'; }, attribution: d => { d.submittedAttribution.verified = true; },
  archive: d => { d.archivedBy = 'owner'; }, version: d => { d.version = 0; }})) {
  test(`stored recipe ${label} fails closed for get and duplicate save`, async () => {
    const f = fixture(), ack = await f.call('save', save()), value = copy(f.store.docs.get(itemPath(ack)));
    edit(value); f.store.put(itemPath(ack), value); const writes = f.store.writes.length;
    await assert.rejects(f.call('get', {recipeId: ack.recipeId}), error('failed-precondition'));
    await assert.rejects(f.call('save', save()), error('failed-precondition'));
    assert.equal(f.store.writes.length, writes);
  });
}
for (const [label, edit, code] of [
  ['extra', d => { d.extra = true; }, 'failed-precondition'], ['state', d => { d.resultIsArchived = true; }, 'failed-precondition'],
  ['changed', d => { d.changed = false; }, 'failed-precondition'], ['timestamp', d => { d.createdAt = null; }, 'failed-precondition'],
  ['actor', d => { d.actorUid = 'staff'; }, 'already-exists'], ['payload', d => { d.payloadHash = 'b'.repeat(64); }, 'already-exists'],
  ['generation', d => { d.actorGeneration = 1; }, 'already-exists'],
]) {
  test(`malformed/conflicting receipt ${label} cannot replay or reconcile`, async () => {
    const f = fixture(), ack = await f.call('save', save()), value = copy(f.store.docs.get(receiptPath(ack)));
    edit(value); f.store.put(receiptPath(ack), value); const writes = f.store.writes.length;
    await assert.rejects(f.call('save', save()), error(code));
    await assert.rejects(f.call('reconcile', {operation: 'save', request: {...E, ...save()}}), error(code));
    assert.equal(f.store.writes.length, writes);
  });
}
for (const phase of ['before', 'after']) {
  test(`${phase}-commit uncertainty never retries and read-only observation preserves evidence`, async () => {
    const f = fixture(); f.store.unknown = phase;
    await assert.rejects(f.call('save', save()), error('unavailable', true));
    assert.equal(f.store.calls, 1); assert.equal(f.store.attempts, 1);
    const writes = f.store.writes.length;
    const observation = await f.call('reconcile', {operation: 'save', request: {...E, ...save()}});
    assert.equal(observation.status, phase === 'after' ? 'committed' : 'unknown');
    assert.equal(f.store.writes.length, writes);
    if (phase === 'after') { assert.equal(observation.result.changed, true); assert.equal(observation.result.replayed, true); }
  });
}
test('equivalent content saved by another request cannot resolve an absent receipt', async () => {
  const f = fixture(); await f.call('save', save('different-save-key-0001'), 'staff');
  const writes = f.store.writes.length;
  assert.deepEqual(await f.call('reconcile', {operation: 'save', request: {...E, ...save()}}), {schemaVersion: 1, status: 'unknown'});
  assert.equal(f.store.writes.length, writes);
});
test('missing target, changed membership and unavailable reads never prove noncommit', async () => {
  const f = fixture(), ack = await f.call('save', save()); f.store.docs.delete(itemPath(ack));
  await assert.rejects(f.call('reconcile', {operation: 'save', request: {...E, ...save()}}), error('failed-precondition'));
  f.store.put('cafes/a/members/owner', {...f.store.docs.get('cafes/a/members/owner'), status: 'revoked'});
  await assert.rejects(f.call('reconcile', {operation: 'save', request: {...E, ...save()}}), error('permission-denied'));
  const g = fixture(); g.store.unknown = 'before';
  await assert.rejects(g.call('list', {mode: 'all', limit: 20, cursor: null}), error('unavailable'));
});
test('unsupported operations and reconcile envelopes never dispatch a mutation', async () => {
  const f = fixture();
  for (const operation of ['delete', 'update', 'cook', '__proto__', 'toString', undefined]) {
    await assert.rejects(f.call(operation, save()), error('invalid-argument'));
  }
  await assert.rejects(f.call('reconcile', {operation: 'save', request: {...E, ...save()}, receiptPath: 'forged'}), error('invalid-argument'));
  await assert.rejects(f.call('reconcile', {operation: 'get', request: {...E, recipeId: 'recipe_' + 'a'.repeat(64)}}), error('invalid-argument'));
  assert.equal(f.store.calls, 0);
});

test('receipt staging failure cannot leave a partial recipe or imply safe resend', async () => {
  const f = fixture(); f.store.failReceipt = true;
  await assert.rejects(f.call('save', save()), error('unavailable', true));
  assert.equal(f.store.commits, 0);
  assert.equal([...f.store.docs.keys()].filter(p => p.includes('/saved_recipe')).length, 0);
  assert.equal(f.store.calls, 1);
  const observed = await f.call('reconcile', {operation: 'save', request: {...E, ...save()}});
  assert.equal(observed.status, 'unknown'); assert.equal(f.store.calls, 2);
});
test('same key binds operation but not a different actor receipt', async () => {
  const f = fixture(), first = await f.call('save', save());
  await assert.rejects(f.call('lifecycle', lifecycle(first, 'archive', 'save-request-0001')), error('already-exists'));
  const staff = await f.call('save', save(), 'staff');
  assert.notEqual(staff.requestHash, first.requestHash);
  assert.equal(staff.recipeId, first.recipeId); assert.equal(staff.outcome, 'existing-active');
});
test('revoked or changed-generation membership cannot replay a completed request', async () => {
  const f = fixture(); await f.call('save', save(), 'staff');
  for (const path of ['user_cafe_memberships/staff', 'cafes/a/members/staff']) {
    f.store.put(path, {...f.store.docs.get(path), membershipGeneration: 1});
  }
  await assert.rejects(f.call('save', save(), 'staff'), error('aborted'));
  await assert.rejects(f.call('save', {...save(), expectedMembershipGeneration: 1}, 'staff'), error('already-exists'));
  f.store.put('cafes/a/members/staff', {...f.store.docs.get('cafes/a/members/staff'), status: 'revoked'});
  await assert.rejects(f.call('save', {...save(), expectedMembershipGeneration: 1}, 'staff'), error('permission-denied'));
});
test('missing E3 query capability is explicit, not a global collection fallback', async () => {
  const f = fixture();
  const store = {projectId, runTransaction: cb => f.store.runTransaction(tx => { delete tx.savedRecipes; return cb(tx); })};
  const service = createSavedRecipeService({projectId, store, verifyIdentity: f.verifyIdentity, timestamp: f.timestamp});
  await assert.rejects(service({operation: 'list', token: 'owner', data: {...E, mode: 'all', limit: 20, cursor: null}}), error('failed-precondition'));
  assert.equal(f.store.queries.length, 0); assert.equal(f.store.commits, 0);
});
test('stored active/archived state cannot disagree with a receipt at the same version', async () => {
  const f = fixture(), first = await f.call('save', save());
  const archived = await f.call('lifecycle', lifecycle(first));
  f.store.put(itemPath(first), {...f.store.docs.get(itemPath(first)), isArchived: false, archivedAt: null, archivedBy: null});
  await assert.rejects(f.call('lifecycle', lifecycle(first)), error('failed-precondition'));
  assert.equal(archived.version, 2);
});
for (const length of [16, 128, 129]) {
  test(`request key length boundary ${length}`, async () => {
    const f = fixture();
    if (length > 128) await assert.rejects(f.call('save', save('k'.repeat(length))), error('invalid-argument'));
    else assert.equal((await f.call('save', save('k'.repeat(length)))).outcome, 'created');
  });
}
test('authorized empty list is distinct from unavailable or malformed data', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('list', {mode: 'active', limit: 20, cursor: null}, 'staff'),
    {schemaVersion: 1, cafeId: 'a', items: [], nextCursor: null});
  assert.equal(f.store.commits, 0);
});
