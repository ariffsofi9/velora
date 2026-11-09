'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const invitations = require('../src/workspace-invitations');
const {createWorkspace} = require('../src/workspace-creation');
class Store {
  constructor(docs) {this.docs = new Map(Object.entries(docs));this.queue = Promise.resolve();}
  runTransaction(fn) {
    const execute = async () => {
      const pending = new Map();
      const tx = {get: async p => this.docs.get(p) ?? null,
        create: (p,d) => {if(this.docs.has(p))throw Error('conflict');pending.set(p,d);},
        update: (p,d) => pending.set(p,{...this.docs.get(p),...d})};
      const result = await fn(tx); for(const [p,d] of pending)this.docs.set(p,d);return result;
    };
    const result=this.queue.then(execute);this.queue=result.catch(()=>{});return result;
  }
}
function fixture() {
  const link=(uid,role)=>({uid,cafeId:'a',status:'active',schemaVersion:1,...(role?{role}:{})});
  const store=new Store({'user_cafe_memberships/owner':link('owner'),
    'cafes/a':{ownerUid:'owner',status:'active',schemaVersion:1},
    'cafes/a/members/owner':link('owner','owner'),
    'user_cafe_memberships/existing':link('existing'), 'cafes/a/members/existing':link('existing','staff')});
  let clock=new Date('2030-01-01T00:00:00Z'); let seq=0;
  const base={store,now:()=>clock,random:n=>Buffer.alloc(n,++seq)};
  const owner={uid:'owner'};const staff={uid:'new-staff',token:{email_verified:true,email:'staff@example.test'}};
  return {store,base,owner,staff,advance:()=>{clock=new Date('2030-01-03Z');},
    create: (data={email:' STAFF@example.test ',requestId:'invitation-request-01'},auth=owner)=>
      invitations.createStaffInvitation({...base,auth,data: {expectedCafeId: 'a', expectedMembershipGeneration: store.docs.get('user_cafe_memberships/owner').membershipGeneration ?? 0, ...data}})};
}
const code=c=>e=>e.code===c;
test('owner creates hashed, normalized, expiring staff-only invitation; duplicate issuance rejected',async()=>{
  const f=fixture();const created=await f.create();
  const invite=f.store.docs.get(`workspace_invitations/${created.invitationId}`);
  assert.equal(invite.email,'staff@example.test');assert.equal(invite.role,'staff');
  assert.equal(invite.issuerBindingVersion, 1);
  assert.equal(invite.issuerMembershipGeneration, 0);
  assert.equal(typeof invite.tokenHash,'string');assert.equal(Object.hasOwn(invite,'code'),false);
  assert.ok(!JSON.stringify([...f.store.docs.values()]).includes(created.code));
  await assert.rejects(f.create(),code('already-exists'));
});

const protectedDocs = store => [...store.docs].filter(([p]) => !p.startsWith('workspace_invite_limits/'));
function setOwnerGeneration(f, generation) {
  for (const p of ['user_cafe_memberships/owner', 'cafes/a/members/owner']) {
    f.store.docs.set(p, {...f.store.docs.get(p), membershipGeneration: generation});
  }
}
const redeem = (f, invite) => invitations.redeemStaffInvitation({...f.base, auth: f.staff, data: {code: invite.code}});

for (const action of ['create', 'revoke']) {
  const invoke = (f, data) => invitations[action === 'create' ? 'createStaffInvitation' : 'revokeStaffInvitation'](
    {...f.base, auth: f.owner, data});
  for (const defect of ['missing', 'partial', 'negative', 'fraction', 'string', 'unsafe', 'bad-cafe', 'extra']) {
    test(`${action} malformed expected context ${defect} rejects before transaction`, async () => {
      const f = fixture(); const invite = await f.create();
      const data = {expectedCafeId: 'a', expectedMembershipGeneration: 0,
        ...(action === 'create' ? {email: 'staff@example.test', requestId: 'new-request-preconditions'} : {invitationId: invite.invitationId})};
      if (defect === 'missing') { delete data.expectedCafeId; delete data.expectedMembershipGeneration; }
      if (defect === 'partial') delete data.expectedMembershipGeneration;
      if (defect === 'negative') data.expectedMembershipGeneration = -1;
      if (defect === 'fraction') data.expectedMembershipGeneration = 0.5;
      if (defect === 'string') data.expectedMembershipGeneration = '0';
      if (defect === 'unsafe') data.expectedMembershipGeneration = Number.MAX_SAFE_INTEGER + 1;
      if (defect === 'bad-cafe') data.expectedCafeId = '../a';
      if (defect === 'extra') data.ownerUid = 'owner';
      const before = structuredClone(f.store.docs);
      f.store.runTransaction = () => { throw Error('transaction forbidden'); };
      await assert.rejects(invoke(f, data), {code: 'invalid-argument'});
      assert.deepEqual(f.store.docs, before);
    });
  }
  for (const defect of ['wrong-cafe', 'stale-generation', 'owner-changed']) {
    test(`${action} stale expected context ${defect} rejects before business reads and writes`, async () => {
      const f = fixture(); const invite = await f.create();
      const data = {expectedCafeId: defect === 'wrong-cafe' ? 'b' : 'a',
        expectedMembershipGeneration: defect === 'stale-generation' ? 7 : 0,
        ...(action === 'create' ? {email: 'staff@example.test', requestId: 'invitation-request-01'} : {invitationId: invite.invitationId})};
      if (defect === 'owner-changed') setOwnerGeneration(f, 2);
      const before = structuredClone(f.store.docs);
      const reads = [];
      f.store.runTransaction = op => op({get: async p => {
        reads.push(p);
        assert.ok(!p.startsWith('workspace_invite') && !p.startsWith('workspace_invitations/'));
        return f.store.docs.get(p);
      }, create: () => assert.fail('no create'), update: () => assert.fail('no update')});
      await assert.rejects(invoke(f, data), {code: 'failed-precondition'});
      assert.equal(reads.length, 3);
      assert.deepEqual(f.store.docs, before);
    });
  }
}

for (const generation of [undefined, 0, 7, Number.MAX_SAFE_INTEGER]) {
  test(`issuer binding captures and redeems generation ${generation ?? 'legacy zero'}`, async () => {
    const f = fixture();
    if (generation !== undefined) setOwnerGeneration(f, generation);
    const invite = await f.create();
    const stored = f.store.docs.get(`workspace_invitations/${invite.invitationId}`);
    assert.equal(stored.issuerBindingVersion, 1);
    assert.equal(stored.issuerMembershipGeneration, generation ?? 0);
    assert.equal((await redeem(f, invite)).joined, true);
    await assert.rejects(redeem(f, invite), {code: 'failed-precondition'});
  });
}

for (const defect of ['missing-version', 'missing-generation', 'both-missing',
  'version-null', 'version-string', 'version-new', 'generation-null', 'generation-string',
  'generation-negative', 'generation-fraction', 'generation-unsafe', 'generation-nan', 'generation-infinity']) {
  test(`issuer binding rejects ${defect} without membership writes or backfill`, async () => {
    const f = fixture(); const invite = await f.create();
    const stored = f.store.docs.get(`workspace_invitations/${invite.invitationId}`);
    if (['missing-version', 'both-missing'].includes(defect)) delete stored.issuerBindingVersion;
    if (['missing-generation', 'both-missing'].includes(defect)) delete stored.issuerMembershipGeneration;
    const versions = {'version-null': null, 'version-string': '1', 'version-new': 2};
    const generations = {'generation-null': null, 'generation-string': '0', 'generation-negative': -1,
      'generation-fraction': 0.5, 'generation-unsafe': Number.MAX_SAFE_INTEGER + 1,
      'generation-nan': NaN, 'generation-infinity': Infinity};
    if (Object.hasOwn(versions, defect)) stored.issuerBindingVersion = versions[defect];
    if (Object.hasOwn(generations, defect)) stored.issuerMembershipGeneration = generations[defect];
    const before = structuredClone(protectedDocs(f.store));
    await assert.rejects(redeem(f, invite), {code: 'permission-denied'});
    assert.deepEqual(protectedDocs(f.store), before);
  });
}

test('new consistent issuer generation rejects old invitation but can revoke it', async () => {
  const f = fixture(); const invite = await f.create(); setOwnerGeneration(f, 2);
  const before = structuredClone(protectedDocs(f.store));
  await assert.rejects(redeem(f, invite), {code: 'permission-denied'});
  assert.deepEqual(protectedDocs(f.store), before);
  const args = {...f.base, auth: f.owner, data: {expectedCafeId: 'a', expectedMembershipGeneration: f.store.docs.get('user_cafe_memberships/owner').membershipGeneration ?? 0, invitationId: invite.invitationId}};
  assert.deepEqual(await invitations.revokeStaffInvitation(args), {revoked: true});
  const revoked = structuredClone(protectedDocs(f.store));
  assert.deepEqual(await invitations.revokeStaffInvitation(args), {revoked: true});
  assert.deepEqual(protectedDocs(f.store), revoked);
  await assert.rejects(redeem(f, invite), {code: 'failed-precondition'});
  await assert.rejects(f.create(), {code: 'already-exists'});
});

test('current Owner can revoke legacy unbound invitation without backfilling it', async () => {
  const f = fixture(); const invite = await f.create();
  const stored = f.store.docs.get(`workspace_invitations/${invite.invitationId}`);
  delete stored.issuerBindingVersion; delete stored.issuerMembershipGeneration;
  await invitations.revokeStaffInvitation({...f.base, auth: f.owner, data: {expectedCafeId: 'a', expectedMembershipGeneration: f.store.docs.get('user_cafe_memberships/owner').membershipGeneration ?? 0, invitationId: invite.invitationId}});
  assert.equal(stored.issuerBindingVersion, undefined);
  const revoked = f.store.docs.get(`workspace_invitations/${invite.invitationId}`);
  assert.equal(revoked.status, 'revoked');
  assert.equal(Object.hasOwn(revoked, 'issuerMembershipGeneration'), false);
});

for (const field of ['issuerBindingVersion', 'issuerMembershipGeneration']) {
  test(`client cannot select ${field}`, async () => {
    const f = fixture(); const before = structuredClone(f.store.docs);
    await assert.rejects(f.create({email: 'staff@example.test', requestId: 'issuer-forgery-request', [field]: 1}),
      {code: 'invalid-argument'});
    assert.deepEqual(f.store.docs, before);
  });
}

for (const failWrite of [1, 2, 3]) {
  test(`first-time redemption write failure ${failWrite} leaves links and invitation unchanged`, async () => {
    const f = fixture(); const invite = await f.create();
    const before = structuredClone(protectedDocs(f.store));
    const run = f.store.runTransaction.bind(f.store);
    f.store.runTransaction = operation => run(async tx => {
      let count = 0;
      const wrap = name => (p, d) => {
        if (!p.startsWith('workspace_invite_limits/') && ++count === failWrite) throw Error('synthetic rollback');
        return tx[name](p, d);
      };
      return operation({...tx, create: wrap('create'), update: wrap('update')});
    });
    await assert.rejects(redeem(f, invite), /synthetic rollback/);
    assert.deepEqual(protectedDocs(f.store), before);
  });
}
for(const uid of [null,'existing','outsider'])test(`unauthorized creator rejected: ${uid}`,async()=>{
  const f=fixture();await assert.rejects(f.create(undefined,uid?{uid}:null));
  assert.equal([...f.store.docs.keys()].some(p=>p.startsWith('workspace_invitations/')),false);
});
test('forged authority, workspace and role fields rejected',async()=>{
  for(const extra of [{role:'owner'},{ownerUid:'owner'},{cafeId:'other'}]){
    const f=fixture();await assert.rejects(f.create({email:'staff@example.test',requestId:'invitation-request-01',...extra}),code('invalid-argument'));
  }
});
test('redemption creates exact resolver-compatible staff membership atomically and prevents replay',async()=>{
  const f=fixture();const invite=await f.create();
  const run=()=>invitations.redeemStaffInvitation({...f.base,auth:f.staff,data:{code:invite.code}});
  assert.equal((await run()).cafeId,'a');
  assert.equal(f.store.docs.get('cafes/a/members/new-staff').role,'staff');
  assert.equal(f.store.docs.get('user_cafe_memberships/new-staff').cafeId,'a');
  await assert.rejects(run(),code('failed-precondition'));
});
for(const name of ['unverified','mismatch','expired','revoked','altered','existing','owner-invalid']){
  test(`redemption denies ${name}`,async()=>{
    const f=fixture();const invite=await f.create();let auth=f.staff;let value=invite.code;
    if(name==='unverified')auth={...auth,token:{...auth.token,email_verified:false}};
    if(name==='mismatch')auth={...auth,token:{...auth.token,email:'other@example.test'}};
    if(name==='expired')f.advance();
    if(name==='revoked')await invitations.revokeStaffInvitation({...f.base,auth:f.owner,data:{expectedCafeId:'a',expectedMembershipGeneration:0,invitationId:invite.invitationId}});
    if(name==='altered')value=value.slice(0,-1)+(value.endsWith('a')?'b':'a');
    if(name==='existing')auth={...auth,uid:'existing'};
    if(name==='owner-invalid')f.store.docs.get('user_cafe_memberships/owner').status='revoked';
    await assert.rejects(invitations.redeemStaffInvitation({...f.base,auth,data:{code:value}}));
    assert.equal(f.store.docs.has('user_cafe_memberships/new-staff'),false);
  });
}
test('concurrent redemption has one winner; revoke cannot target foreign workspace',async()=>{
  const f=fixture();const invite=await f.create();
  const result=await Promise.allSettled([1,2].map(()=>invitations.redeemStaffInvitation({...f.base,auth:f.staff,data:{code:invite.code}})));
  assert.equal(result.filter(r=>r.status==='fulfilled').length,1);
  const g=fixture();const foreign=await g.create();g.store.docs.get(`workspace_invitations/${foreign.invitationId}`).cafeId='other';
  await assert.rejects(invitations.revokeStaffInvitation({...g.base,auth:g.owner,data:{expectedCafeId:'a',expectedMembershipGeneration:0,invitationId:foreign.invitationId}}),code('permission-denied'));
});
test('redemption and revocation race cannot both succeed',async()=>{
  const f=fixture();const invite=await f.create();
  const r=await Promise.allSettled([
    invitations.revokeStaffInvitation({...f.base,auth:f.owner,data:{expectedCafeId:'a',expectedMembershipGeneration:0,invitationId:invite.invitationId}}),
    invitations.redeemStaffInvitation({...f.base,auth:f.staff,data:{code:invite.code}})]);
  assert.equal(r.filter(x=>x.status==='fulfilled').length,1);
});
test('rate limits enforce creation and failed redemption attempts',async()=>{
  const f=fixture();
  for(let n=0;n<10;n++)await f.create({email:'staff@example.test',requestId:`invitation-request-${n}`});
  await assert.rejects(f.create({email:'staff@example.test',requestId:'invitation-request-11'}),code('resource-exhausted'));
  const g=fixture();const invite=await g.create();
  for(let n=0;n<10;n++)await assert.rejects(invitations.redeemStaffInvitation({...g.base,auth:{...g.staff,token:{email_verified:true,email:'wrong@example.test'}},data:{code:invite.code}}));
  await assert.rejects(invitations.redeemStaffInvitation({...g.base,auth:g.staff,data:{code:invite.code}}),code('resource-exhausted'));
});
test('new business types constrained; historical records preserved; second creation rejected',async()=>{
  const data={businessName:'Cafe One',businessType:'Restaurant',address:'',inventoryUnit:'kg',lowStockAlerts:true,expiryReminders:true,reminderDays:3};
  for(const [type,expected] of [['cafe','Caf\u00e9'],['Caf\u00e9','Caf\u00e9'],['restaurant','Restaurant'],['bakery','Bakery']]){
    const store=new Store({});
    await createWorkspace({auth:{uid:'owner',token:{email_verified:true}},data:{...data,businessType:type},store,idFactory:()=> 'a',timestamp:()=>new Date()});
    assert.equal(store.docs.get('cafes/a').businessType,expected);
  }
  for(const type of ['Catering','Cloud Kitchen','Other']){
    const store=new Store({});await assert.rejects(createWorkspace({auth:{uid:'owner',token:{email_verified:true}},data:{...data,businessType:type},store,idFactory:()=> 'a',timestamp:()=>new Date()}),code('invalid-argument'));
    assert.equal(store.docs.size,0);
  }
  const store=new Store({});const args={auth:{uid:'owner',token:{email_verified:true}},data,store,idFactory:()=> 'a',timestamp:()=>new Date()};
  await createWorkspace(args);await assert.rejects(createWorkspace({...args,data:{...data,businessName:'Second'}}),code('already-exists'));
  store.docs.get('cafes/a').businessType='Catering';
  assert.equal((await createWorkspace({...args,data:{...data,businessType:'Catering'}})).created,false);
  assert.equal(store.docs.get('cafes/a').businessType,'Catering');
});
