'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {listTeamMembers} = require('../src/team-members');

const verifiedAuth = uid => ({uid, token: {email_verified: true}});

function fixture() {
  const docs = new Map();
  const users = new Map();
  for (const [uid, cafeId, role] of [['owner','a','owner'],['staff','a','staff'],['other-staff','a','staff'],['foreign','b','owner']]) {
    const link = {uid,cafeId,status:'active',schemaVersion:1};
    docs.set(`user_cafe_memberships/${uid}`, {...link});
    docs.set(`cafes/${cafeId}/members/${uid}`, {...link,role});
    if (role === 'owner') docs.set(`cafes/${cafeId}`, {ownerUid:uid,status:'active',schemaVersion:1});
    users.set(uid, {uid,email:`${uid}@example.test`,displayName:uid,emailVerified:true,disabled:false});
    docs.set(`users/${uid}`, {username: uid, email: `${uid}@example.test`, role: 'owner', photoUrl: '',
      createdAt: new Date(0), updatedAt: new Date(0)});
  }
  const store = {runTransaction: fn => fn({get: async p => docs.get(p), members: async (id, limit, after) =>
    [...docs].filter(([p, data]) => p.startsWith(`cafes/${id}/members/`) && data.role === 'staff')
      .map(([p,data])=>({id:p.split('/').at(-1),data})).filter(row => !after || row.id > after)
      .sort((a, b) => Buffer.compare(Buffer.from(a.id), Buffer.from(b.id))).slice(0,limit)})};
  const args = {auth:verifiedAuth('owner'),data:{},store,accounts:async ids=>ids.map(id=>users.get(id)).filter(Boolean)};
  return {docs,users,args};
}
test('owner lists all verified same-cafe members and only public display fields',async()=>{
  const f=fixture();const result=await listTeamMembers(f.args);
  assert.deepEqual(result.members.map(m=>m.uid),['owner','other-staff','staff']);
  assert.deepEqual(Object.keys(result.members[0]).sort(),['email','name','role','uid']);
});
test('staff visibility preserves existing Rules: owner and self only',async()=>{
  const f=fixture();const result=await listTeamMembers({...f.args,auth:verifiedAuth('staff')});
  assert.deepEqual(result.members.map(m=>m.uid),['owner','staff']);
});

for (const uid of ['owner', 'staff']) {
  for (const [label, token] of [
    ['unverified claim', {email_verified: false}],
    ['missing claim', {}],
    ['malformed claim', {email_verified: 'true'}],
  ]) {
    test(`${uid} roster rejects ${label} before querying membership or accounts`, async () => {
      const f = fixture();
      const run = f.args.store.runTransaction;
      const accounts = f.args.accounts;
      let transactions = 0, lookups = 0;
      f.args.store.runTransaction = callback => { transactions++; return run(callback); };
      f.args.accounts = ids => { lookups++; return accounts(ids); };

      await assert.rejects(listTeamMembers({...f.args, auth: {uid, token}}), {
        code: 'unauthenticated', message: 'Team members could not be verified.',
      });
      assert.equal(transactions, 0);
      assert.equal(lookups, 0);
    });
  }

  for (const [label, patch] of [
    ['missing caller account', null],
    ['disabled caller account', {disabled: true}],
    ['unverified caller account despite verified claims', {emailVerified: false}],
    ['missing caller account verification state', {emailVerified: undefined}],
    ['malformed caller account verification state', {emailVerified: 'true'}],
    ['missing caller account enablement state', {disabled: undefined}],
    ['malformed caller account enablement state', {disabled: 0}],
  ]) {
    test(`${uid} roster rejects ${label}`, async () => {
      const f = fixture();
      if (patch === null) f.users.delete(uid);
      else Object.assign(f.users.get(uid), patch);
      const run = f.args.store.runTransaction;
      const accounts = f.args.accounts;
      let transactions = 0, lookups = 0;
      f.args.store.runTransaction = callback => { transactions++; return run(callback); };
      f.args.accounts = ids => { lookups++; return accounts(ids); };

      await assert.rejects(listTeamMembers({...f.args, auth: verifiedAuth(uid)}), {
        code: 'permission-denied', message: 'Team members could not be verified.',
      });
      assert.equal(transactions, 1);
      assert.equal(lookups, 1);
    });
  }
}
test('no unauthenticated or forged authority requests',async()=>{
  const f=fixture();
  await assert.rejects(listTeamMembers({...f.args,auth:null}),{code:'unauthenticated'});
  for(const data of [{cafeId:'b'},{role:'owner'},{uid:'foreign'},null]) {
    await assert.rejects(listTeamMembers({...f.args,data}),{code:'invalid-argument'});
  }
});
for(const defect of ['unverified','disabled','missing-account','inactive','wrong-map','forged-owner','bad-schema',
  'missing-profile','mismatched-profile','malformed-profile']) {
  test(`exclude member: ${defect}`,async()=>{
    const f=fixture();const user=f.users.get('staff');const member=f.docs.get('cafes/a/members/staff');
    if(defect==='unverified')user.emailVerified=false;
    if(defect==='disabled')user.disabled=true;
    if(defect==='missing-account')f.users.delete('staff');
    if(defect==='inactive')member.status='revoked';
    if(defect==='wrong-map')f.docs.get('user_cafe_memberships/staff').cafeId='b';
    if(defect==='forged-owner')member.role='owner';
    if(defect==='bad-schema')member.schemaVersion=2;
    if(defect==='missing-profile')f.docs.delete('users/staff');
    if(defect==='mismatched-profile')f.docs.get('users/staff').email='other@example.test';
    if(defect==='malformed-profile')f.docs.get('users/staff').createdAt='not-a-timestamp';
    assert.ok(!(await listTeamMembers(f.args)).members.some(m=>m.uid==='staff'));
  });
}
test('recheck rejects caller revocation while Auth profiles are pending',async()=>{
  const f=fixture();const accounts=f.args.accounts;
  f.args.accounts=async ids=>{const result=await accounts(ids);f.docs.get('user_cafe_memberships/owner').status='revoked';return result;};
  await assert.rejects(listTeamMembers(f.args),{code:'permission-denied'});
});
test('recheck omits members revoked while Auth profiles are pending',async()=>{
  const f=fixture();const accounts=f.args.accounts;
  f.args.accounts=async ids=>{const result=await accounts(ids);f.docs.get('cafes/a/members/staff').status='revoked';return result;};
  assert.ok(!(await listTeamMembers(f.args)).members.some(m=>m.uid==='staff'));
});
test('recheck omits a Staff profile deleted between snapshots', async () => {
  const f = fixture();
  const accounts = f.args.accounts;
  f.args.accounts = async ids => {
    f.docs.delete('users/staff');
    return accounts(ids);
  };
  assert.deepEqual((await listTeamMembers(f.args)).members.map(member => member.uid), ['owner', 'other-staff']);
});
test('reject stale ownership, forged caller role and disabled caller',async()=>{
  for(const defect of ['owner-map','role','disabled']) {
    const f=fixture();
    if(defect==='owner-map')f.docs.get('user_cafe_memberships/owner').cafeId='b';
    if(defect==='role')f.docs.get('cafes/a/members/staff').role='owner';
    if(defect==='disabled')f.users.get('staff').disabled=true;
    await assert.rejects(listTeamMembers({...f.args,auth:verifiedAuth('staff')}),{code:'permission-denied'});
  }
});
test('pages through more than 100 staff and rejects stale or cross-workspace cursors',async()=>{
  const f=fixture();
  for(let n=0;n<103;n++) {
    const uid = `extra-${String(n).padStart(3, '0')}`;
    const link = {uid, cafeId: 'a', status: 'active', schemaVersion: 1};
    f.docs.set(`cafes/a/members/${uid}`, {...link, role: 'staff'});
    f.docs.set(`user_cafe_memberships/${uid}`, link);
    f.docs.set(`users/${uid}`, {...f.docs.get('users/staff'), username: uid, email: `${uid}@example.test`});
    f.users.set(uid, {...f.users.get('staff'), uid, email: `${uid}@example.test`});
  }
  const first = await listTeamMembers(f.args);
  const seen = new Set();
  let page = first;
  do {
    assert.ok(page.members.filter(m => m.role === 'staff').length <= 20);
    for (const {uid} of page.members) { assert.ok(!seen.has(uid)); seen.add(uid); }
    if (!page.nextCursor) break;
    page = await listTeamMembers({...f.args, data: {cursor: page.nextCursor}});
  } while (true);
  assert.equal(seen.size, 106);
  for (const uid of ['foreign', 'staff']) await assert.rejects(listTeamMembers({...f.args,
    auth: verifiedAuth(uid), data: {cursor: first.nextCursor}}), {code:'permission-denied'});
  await assert.rejects(listTeamMembers({...f.args, data: {cursor: '../../foreign'}}), {code:'invalid-argument'});
  setGeneration(f, 'owner', 1);
  await assert.rejects(listTeamMembers({...f.args, data: {cursor: first.nextCursor}}), {code:'permission-denied'});
});
test('provider/store errors propagate to safe callable boundary; no self-only fallback',async()=>{
  const f=fixture();f.args.accounts=async()=>{throw Error('private internal failure');};
  await assert.rejects(listTeamMembers(f.args));
});

test('duplicate or unexpected account records fail closed', async () => {
  for (const uid of ['owner', 'foreign']) {
    const f = fixture();
    const accounts = f.args.accounts;
    f.args.accounts = async ids => [...await accounts(ids), f.users.get(uid)];
    await assert.rejects(listTeamMembers(f.args), {code: 'permission-denied'});
  }
});

function setGeneration(f, uid, generation) {
  for (const path of [`user_cafe_memberships/${uid}`, `cafes/a/members/${uid}`]) {
    f.docs.set(path, {...f.docs.get(path), membershipGeneration: generation});
  }
}

function pendingAccounts(f) {
  const accounts = f.args.accounts;
  let started, resume;
  const pending = new Promise(resolve => { resume = resolve; });
  const ready = new Promise(resolve => { started = resolve; });
  f.args.accounts = async ids => {
    const users = await accounts(ids);
    started();
    await pending;
    return users;
  };
  return {ready, resume};
}

function removeAndRejoin(f, uid) {
  setGeneration(f, uid, 1);
  for (const path of [`user_cafe_memberships/${uid}`, `cafes/a/members/${uid}`]) {
    f.docs.set(path, {...f.docs.get(path), status: 'inactive'});
  }
  // Replace both records as a new active episode, retaining the same UID/role.
  for (const path of [`user_cafe_memberships/${uid}`, `cafes/a/members/${uid}`]) {
    f.docs.set(path, {...f.docs.get(path), status: 'active', membershipGeneration: 2});
  }
}

for (const viewer of ['owner', 'staff']) {
  for (const generation of [undefined, 0, 7, Number.MAX_SAFE_INTEGER]) {
    test(`stable ${viewer} roster preserves public schema at generation ${generation ?? 'legacy'}`, async () => {
      const f = fixture();
      if (generation !== undefined) {
        for (const uid of ['owner', 'staff', 'other-staff']) setGeneration(f, uid, generation);
      }
      const result = await listTeamMembers({...f.args, auth: verifiedAuth(viewer)});
      assert.deepEqual(Object.keys(result).sort(), ['cafeId', 'members', 'viewerRole']);
      assert.deepEqual(result.members.map(member => member.uid),
        viewer === 'owner' ? ['owner', 'other-staff', 'staff'] : ['owner', 'staff']);
      for (const member of result.members) {
        assert.deepEqual(Object.keys(member).sort(), ['email', 'name', 'role', 'uid']);
      }
    });
  }
}

for (const [viewer, changed] of [['owner', 'owner'], ['staff', 'staff'], ['staff', 'owner']]) {
  test(`${viewer} request denies ${changed} removal/rejoin during account lookup`, async () => {
    const f = fixture(); const lookup = pendingAccounts(f);
    const result = listTeamMembers({...f.args, auth: verifiedAuth(viewer)});
    await lookup.ready;
    removeAndRejoin(f, changed);
    lookup.resume();
    await assert.rejects(result, {code: 'permission-denied'});
  });
}

test('owner roster excludes same-role Staff rejoined while account lookup is pending', async () => {
  const f = fixture(); const lookup = pendingAccounts(f);
  const result = listTeamMembers(f.args);
  await lookup.ready;
  removeAndRejoin(f, 'staff');
  lookup.resume();
  assert.deepEqual((await result).members.map(member => member.uid), ['owner', 'other-staff']);
});

for (const defect of ['one-sided', 'malformed', 'mismatched']) {
  for (const changed of ['owner', 'staff', 'other-staff']) {
    for (const duringLookup of [false, true]) {
      test(`${defect} ${changed} generation ${duringLookup ? 'during lookup' : 'initially'} fails closed`, async () => {
        const f = fixture();
        const corrupt = () => {
          setGeneration(f, changed, defect === 'malformed' ? -1 : 1);
          const member = f.docs.get(`cafes/a/members/${changed}`);
          if (defect === 'one-sided') delete member.membershipGeneration;
          if (defect === 'mismatched') member.membershipGeneration = 2;
        };
        let lookup;
        if (duringLookup) lookup = pendingAccounts(f); else corrupt();
        const result = listTeamMembers({...f.args, auth: verifiedAuth(changed === 'other-staff' ? 'owner' : 'staff')});
        if (duringLookup) { await lookup.ready; corrupt(); lookup.resume(); }
        if (changed === 'other-staff') {
          assert.deepEqual((await result).members.map(member => member.uid), ['owner', 'staff']);
        } else {
          await assert.rejects(result, {code: 'permission-denied'});
        }
      });
    }
  }
}

test('normalizing absent generations to explicit zero preserves the same legacy episode', async () => {
  const f = fixture(); const lookup = pendingAccounts(f);
  const result = listTeamMembers(f.args);
  await lookup.ready;
  for (const uid of ['owner', 'staff', 'other-staff']) setGeneration(f, uid, 0);
  lookup.resume();
  assert.equal((await result).members.length, 3);
});

for (const viewer of ['owner', 'staff']) {
  test(`${viewer} roster bounds reads and keeps Auth outside the transactions`, async () => {
    const f = fixture(); const run = f.args.store.runTransaction;
    const accounts = f.args.accounts;
    let reads = 0, queries = 0, lookups = 0;
    f.args.store.runTransaction = callback => run(tx => callback({
      get: async path => { reads++; return tx.get(path); },
      members: async (...args) => { queries++; return tx.members(...args); },
    }));
    f.args.accounts = ids => { lookups++; return accounts(ids); };
    await listTeamMembers({...f.args, auth: verifiedAuth(viewer)});
    assert.equal(reads, viewer === 'owner' ? 24 : 22);
    assert.equal(queries, viewer === 'owner' ? 2 : 0);
    assert.equal(lookups, 1);
  });
}
