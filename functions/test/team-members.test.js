'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {listTeamMembers} = require('../src/team-members');

function fixture() {
  const docs = new Map();
  const users = new Map();
  for (const [uid, cafeId, role] of [['owner','a','owner'],['staff','a','staff'],['other-staff','a','staff'],['foreign','b','owner']]) {
    const link = {uid,cafeId,status:'active',schemaVersion:1};
    docs.set(`user_cafe_memberships/${uid}`, {...link});
    docs.set(`cafes/${cafeId}/members/${uid}`, {...link,role});
    if (role === 'owner') docs.set(`cafes/${cafeId}`, {ownerUid:uid,status:'active',schemaVersion:1});
    users.set(uid, {uid,email:`${uid}@example.test`,displayName:uid,emailVerified:true,disabled:false});
  }
  const store = {runTransaction: fn => fn({get: async p => docs.get(p), members: async (id, limit) =>
    [...docs].filter(([p]) => p.startsWith(`cafes/${id}/members/`)).slice(0,limit)
      .map(([p,data])=>({id:p.split('/').at(-1),data}))})};
  const args = {auth:{uid:'owner'},data:{},store,accounts:async ids=>ids.map(id=>users.get(id)).filter(Boolean)};
  return {docs,users,args};
}
test('owner lists all verified same-cafe members and only public display fields',async()=>{
  const f=fixture();const result=await listTeamMembers(f.args);
  assert.deepEqual(result.members.map(m=>m.uid),['owner','other-staff','staff']);
  assert.deepEqual(Object.keys(result.members[0]).sort(),['email','name','role','uid']);
});
test('staff visibility preserves existing Rules: owner and self only',async()=>{
  const f=fixture();const result=await listTeamMembers({...f.args,auth:{uid:'staff'}});
  assert.deepEqual(result.members.map(m=>m.uid),['owner','staff']);
});
test('no unauthenticated or forged authority requests',async()=>{
  const f=fixture();
  await assert.rejects(listTeamMembers({...f.args,auth:null}),{code:'unauthenticated'});
  for(const data of [{cafeId:'b'},{role:'owner'},{uid:'foreign'},null]) {
    await assert.rejects(listTeamMembers({...f.args,data}),{code:'invalid-argument'});
  }
});
for(const defect of ['unverified','disabled','missing-account','inactive','wrong-map','forged-owner','bad-schema']) {
  test(`exclude member: ${defect}`,async()=>{
    const f=fixture();const user=f.users.get('staff');const member=f.docs.get('cafes/a/members/staff');
    if(defect==='unverified')user.emailVerified=false;
    if(defect==='disabled')user.disabled=true;
    if(defect==='missing-account')f.users.delete('staff');
    if(defect==='inactive')member.status='revoked';
    if(defect==='wrong-map')f.docs.get('user_cafe_memberships/staff').cafeId='b';
    if(defect==='forged-owner')member.role='owner';
    if(defect==='bad-schema')member.schemaVersion=2;
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
test('reject stale ownership, forged caller role and disabled caller',async()=>{
  for(const defect of ['owner-map','role','disabled']) {
    const f=fixture();
    if(defect==='owner-map')f.docs.get('user_cafe_memberships/owner').cafeId='b';
    if(defect==='role')f.docs.get('cafes/a/members/staff').role='owner';
    if(defect==='disabled')f.users.get('staff').disabled=true;
    await assert.rejects(listTeamMembers({...f.args,auth:{uid:'staff'}}),{code:'permission-denied'});
  }
});
test('bounded query fails explicitly instead of silently truncating',async()=>{
  const f=fixture();
  for(let n=0;n<101;n++)f.docs.set(`cafes/a/members/extra-${n}`,{});
  await assert.rejects(listTeamMembers(f.args),{code:'resource-exhausted'});
});
test('provider/store errors propagate to safe callable boundary; no self-only fallback',async()=>{
  const f=fixture();f.args.accounts=async()=>{throw Error('private internal failure');};
  await assert.rejects(listTeamMembers(f.args));
});
