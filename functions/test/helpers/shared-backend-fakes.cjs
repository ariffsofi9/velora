'use strict';
const {generateKeyPairSync, sign} = require('node:crypto');
const {createBackend} = require('../../feasibility/shared-backend/backend.cjs');
function createStore(seed = {}) {
  let records = new Map(Object.entries(structuredClone(seed))), tail = Promise.resolve();
  const store = {failCommit: false, snapshot: () => structuredClone(Object.fromEntries(records)),
    async runTransaction(action) {
      const previous = tail; let release; tail = new Promise(resolve => { release = resolve; });
      await previous;
      try {
        const draft = structuredClone(records); let writing = false;
        const tx = {
          async get(path) { if (writing) throw Error('read after write'); return structuredClone(draft.get(path) ?? null); },
          create(path, data) { writing = true; if (draft.has(path)) throw Error('exists'); draft.set(path, structuredClone(data)); },
          update(path, data) { writing = true; if (!draft.has(path)) throw Error('missing'); draft.set(path, {...draft.get(path), ...structuredClone(data)}); },
          delete(path) { writing = true; draft.delete(path); },
          async inventory(cafe, limit) { return [...draft].filter(([p]) => p.startsWith(`cafes/${cafe}/inventory/`)).slice(0, limit).map(([p, data]) => ({id: p.split('/').at(-1), data: structuredClone(data)})); },
          async members(cafe, limit) { return [...draft].filter(([p]) => p.startsWith(`cafes/${cafe}/members/`)).slice(0, limit).map(([p, data]) => ({id: p.split('/').at(-1), data: structuredClone(data)})); },
        };
        const result = await action(tx);
        if (store.failCommit) { store.failCommit = false; throw Error('synthetic commit failure'); }
        records = draft; return result;
      } finally { release(); }
    }};
  return store;
}
function fixture() {
  const time = Date.UTC(2026, 10, 7, 0); let clock = time;
  const {publicKey, privateKey} = generateKeyPairSync('rsa', {modulusLength: 2048});
  const accounts = Object.fromEntries(['owner', 'staff', 'joiner', 'outsider'].map(uid => [uid,
    {uid, disabled: false, emailVerified: true, email: `${uid}@example.test`, displayName: uid,
      tokensValidAfterTime: new Date(time - 100000).toISOString()}]));
  const claims = uid => ({sub: uid, aud: 'velora-spark-test', iss: 'https://securetoken.google.com/velora-spark-test',
    iat: time / 1000, auth_time: time / 1000, exp: time / 1000 + 3600,
    email_verified: true, email: accounts[uid].email});
  function token(uid = 'owner', changes = {}, headerChanges = {}) {
    const head = Buffer.from(JSON.stringify({alg: 'RS256', kid: 'synthetic', ...headerChanges})).toString('base64url');
    const body = Buffer.from(JSON.stringify({...claims(uid), ...changes})).toString('base64url');
    return `${head}.${body}.${sign('RSA-SHA256', Buffer.from(`${head}.${body}`), privateKey).toString('base64url')}`;
  }
  const seed = {'cafes/cafe': {ownerUid: 'owner', status: 'active', schemaVersion: 1}};
  for (const uid of ['owner', 'staff']) {
    const link = {uid, cafeId: 'cafe', status: 'active', schemaVersion: 1, membershipGeneration: 0};
    seed[`user_cafe_memberships/${uid}`] = link;
    seed[`cafes/cafe/members/${uid}`] = {...link, role: uid};
  }
  seed['cafes/cafe/inventory/item'] = {cafeId: 'cafe', schemaVersion: 1, name: 'Rice', category: 'Dry', quantity: 5,
    unit: 'pcs', version: 1, expiryDate: new Date(time + 86400000)};
  const store = createStore(seed); const calls = []; const secret = 'SYNTHETIC_SECRET_SENTINEL';
  let providerMode = 'valid';
  const transport = async (url, options) => {
    calls.push({url, body: options.body});
    if (providerMode === 'timeout') return new Promise(() => {});
    if (providerMode === 'throw') throw Error(secret);
    const content = providerMode === 'valid' ? {recipes: [{title: 'Rice meal', ingredients: [{itemId: 'i1', quantity: 1, unit: 'pcs'}],
      steps: ['Cook rice'], whyRecommended: 'Use available rice'}]} : {recipes: [{title: secret}]};
    return Response.json({choices: [{finish_reason: 'stop', message: {content: JSON.stringify(content)}}]});
  };
  const getAccount = async uid => structuredClone(accounts[uid]);
  return {store, accounts, token, claims, calls, secret, now: () => clock,
    advance: ms => { clock += ms; }, mode: mode => { providerMode = mode; },
    identity: {projectId: 'velora-spark-test', keys: {synthetic: publicKey.export({format: 'jwk'})}, getAccount, now: () => clock},
    backend: createBackend({store, getAccount, transport, getSecret: () => secret, now: () => clock}),
  };
}
module.exports = {createStore, fixture};
