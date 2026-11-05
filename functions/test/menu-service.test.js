'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {menuOperation} = require('../src/menu-service');
const {menuDocument} = require('../src/menu-model');

class Store {
  constructor() {
    this.docs = new Map(); this.queue = Promise.resolve(); this.fail = false;
    for (const [uid, cafeId, role] of [['owner','a','owner'],['staff','a','staff'],['foreign','b','owner']]) {
      const link = {uid,cafeId,status:'active',schemaVersion:1};
      this.docs.set(`user_cafe_memberships/${uid}`, {...link});
      this.docs.set(`cafes/${cafeId}/members/${uid}`, {...link,role});
      if (role === 'owner') this.docs.set(`cafes/${cafeId}`, {ownerUid:uid,status:'active',schemaVersion:1});
    }
  }
  runTransaction(operation) {
    const run = async () => {
      const pending = new Map();
      const result = await operation({
        get: async path => this.docs.get(path) ?? null,
        create: (path, data) => { if (this.docs.has(path) || pending.has(path)) throw Error('exists'); pending.set(path,data); },
        update: (path, data) => pending.set(path,{...this.docs.get(path),...data}),
        menuItems: async (cafeId,input) => [...this.docs].filter(([p,d]) =>
          p.startsWith(`cafes/${cafeId}/menu_items/`) && (input.includeArchived || d.isArchived === false))
          .map(([p,data])=>({id:p.split('/').at(-1),data})).sort((a,b)=>a.id.localeCompare(b.id))
          .filter(row=>!input.cursor || row.id > input.cursor).slice(0,input.limit+1),
      });
      if (this.fail) throw Error('Synthetic commit failure');
      for (const [p,d] of pending) this.docs.set(p,d);
      return result;
    };
    const result=this.queue.then(run);this.queue=result.catch(()=>{});return result;
  }
}
const input = (extra={}) => ({idempotencyKey:'menu-request-00001',name:'Flat White',category:'Coffee',priceMinor:1200,isAvailable:true,...extra});
const fixture = () => {
  const store=new Store();
  const invoke=(operation,data,uid='owner')=>menuOperation({operation,data: !['get','list'].includes(operation) && data && !Array.isArray(data) && typeof data === 'object' ? {expectedCafeId:uid === 'foreign' ? 'b' : 'a',expectedMembershipGeneration:0,...data} : data,auth:uid?{uid}:null,store,
    timestamp:()=>new Date('2030-01-01T00:00:00Z')});
  return {store,invoke};
};
test('Owner creates normalized, integer-priced server-audited menu; Staff reads it',async()=>{
  const f=fixture();const created=await f.invoke('create',input({name:' Flat   White '}));
  const item=(await f.invoke('get',{itemId:created.itemId},'staff')).item;
  assert.equal(item.name,'Flat White');assert.equal(item.priceMinor,1200);assert.equal(item.currency,'MYR');
  assert.equal(item.createdBy,'owner');assert.equal(item.updatedAt,'2030-01-01T00:00:00.000Z');
  assert.equal(item.isArchived,false);assert.equal(item.isAvailable,true);
  assert.equal((await f.invoke('list',{},'staff')).items.length,1);
});
test('update/archive/restore use versions, block archived edits and preserve availability',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  await f.invoke('update',{itemId,expectedVersion:1,idempotencyKey:'menu-update-00001',priceMinor:0,isAvailable:false});
  await f.invoke('lifecycle',{itemId,expectedVersion:2,idempotencyKey:'menu-archive-0001',action:'archive'});
  assert.equal((await f.invoke('list',{})).items.length,0);
  assert.equal((await f.invoke('list',{includeArchived:true})).items.length,1);
  await assert.rejects(f.invoke('update',{itemId,expectedVersion:3,idempotencyKey:'menu-update-00002',name:'Blocked'}),{code:'failed-precondition'});
  await assert.rejects(f.invoke('lifecycle',{itemId,expectedVersion:3,idempotencyKey:'menu-archive-0002',action:'archive'}),{code:'failed-precondition'});
  await f.invoke('lifecycle',{itemId,expectedVersion:3,idempotencyKey:'menu-restore-0001',action:'restore'});
  const item=(await f.invoke('get',{itemId})).item;
  assert.equal(item.version,4);assert.equal(item.isArchived,false);assert.equal(item.isAvailable,false);
});
for (const [field,value] of [['name',''],['name','x'.repeat(101)],['name','bad\ntext'],['category',''],
  ['priceMinor',-1],['priceMinor',1.5],['priceMinor','1200'],['priceMinor',1000001],['priceMinor',NaN],
  ['priceMinor',Infinity],['isAvailable','true'],['isAvailable',null]]) {
  test(`invalid create field ${field}: ${String(value).slice(0,15)}`,async()=>{
    const f=fixture();await assert.rejects(f.invoke('create',input({[field]:value})),{code:'invalid-argument'});
    assert.equal(f.store.docs.size,8);
  });
}
for (const extra of [{cafeId:'b'},{ownerUid:'foreign'},{actorUid:'owner'},{role:'owner'},
  {isArchived:true},{version:10},{createdAt:'forged'},{currency:'USD'}]) {
  test(`forged or unsupported field ${Object.keys(extra)[0]} rejected`,async()=>{
    const f=fixture();await assert.rejects(f.invoke('create',input(extra)),{code:'invalid-argument'});
  });
}
test('missing fields, malformed IDs, empty edits and invalid list bounds rejected',async()=>{
  const f=fixture();
  for(const data of [null,[],{},input({idempotencyKey:'short'})])
    await assert.rejects(f.invoke('create',data),{code:'invalid-argument'});
  for(const data of [{limit:0},{limit:51},{limit:1.5},{includeArchived:'true'},{cursor:'a/b'},{cafeId:'b'}])
    await assert.rejects(f.invoke('list',data),{code:'invalid-argument'});
  await assert.rejects(f.invoke('get',{itemId:'../b'}),{code:'invalid-argument'});
  await assert.rejects(f.invoke('update',{itemId:'a',expectedVersion:1,idempotencyKey:'menu-update-00001'}),{code:'invalid-argument'});
  await assert.rejects(f.invoke('lifecycle',{itemId:'a',expectedVersion:1,idempotencyKey:'menu-update-00001',action:'delete'}),{code:'invalid-argument'});
});
test('Staff and anonymous mutation attempts cannot write or use Owner receipts',async()=>{
  const f=fixture();const data=input();const {itemId}=await f.invoke('create',data);
  for(const uid of ['staff',null]) {
    for(const [operation,payload] of [['create',data],['update',{itemId,expectedVersion:1,idempotencyKey:'menu-update-00001',name:'Bad'}],
      ['lifecycle',{itemId,expectedVersion:1,idempotencyKey:'menu-archive-0001',action:'archive'}]]) {
      const before=structuredClone([...f.store.docs]);
      await assert.rejects(f.invoke(operation,payload,uid),{code:uid?'permission-denied':'unauthenticated'});
      assert.deepEqual([...f.store.docs],before);
    }
  }
});
for(const defect of ['missing-map','revoked-map','revoked-member','wrong-cafe','forged-role','bad-schema','inactive-cafe','owner-map']) {
  test(`membership fails closed: ${defect}`,async()=>{
    const f=fixture();
    if(defect==='missing-map')f.store.docs.delete('user_cafe_memberships/staff');
    if(defect==='revoked-map')f.store.docs.get('user_cafe_memberships/staff').status='revoked';
    if(defect==='revoked-member')f.store.docs.get('cafes/a/members/staff').status='revoked';
    if(defect==='wrong-cafe')f.store.docs.get('user_cafe_memberships/staff').cafeId='b';
    if(defect==='forged-role')f.store.docs.get('cafes/a/members/staff').role='owner';
    if(defect==='bad-schema')f.store.docs.get('cafes/a/members/staff').schemaVersion=2;
    if(defect==='inactive-cafe')f.store.docs.get('cafes/a').status='inactive';
    if(defect==='owner-map')f.store.docs.get('user_cafe_memberships/owner').cafeId='b';
    await assert.rejects(f.invoke('list',{},'staff'),{code:'permission-denied'});
  });
}
test('foreign IDs cannot be read or mutated; lists never fall back to another cafe',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input(),'foreign');
  await assert.rejects(f.invoke('get',{itemId}),{code:'not-found'});
  await assert.rejects(f.invoke('update',{itemId,expectedVersion:1,idempotencyKey:'menu-update-00001',name:'Bad'}),{code:'not-found'});
  await assert.rejects(f.invoke('lifecycle',{itemId,expectedVersion:1,idempotencyKey:'menu-archive-0001',action:'archive'}),{code:'not-found'});
  assert.deepEqual((await f.invoke('list',{})).items,[]);
});
test('identical concurrent creates have one item and receipt; conflicts are rejected',async()=>{
  const f=fixture();const result=await Promise.all([1,2].map(()=>f.invoke('create',input())));
  assert.equal(result.filter(r=>r.changed).length,1);assert.equal(result[0].itemId,result[1].itemId);
  await assert.rejects(f.invoke('create',input({priceMinor:1300})),{code:'already-exists'});
  assert.equal([...f.store.docs.keys()].filter(p=>p.includes('/menu_items/')).length,1);
  assert.equal([...f.store.docs.keys()].filter(p=>p.includes('/menu_requests/')).length,1);
});
test('update/lifecycle retries are stable, payload conflicts and stale writes rejected',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const update={itemId,expectedVersion:1,idempotencyKey:'menu-update-00001',name:'Updated'};
  await f.invoke('update',update);assert.equal((await f.invoke('update',update)).changed,false);
  await assert.rejects(f.invoke('update',{...update,name:'Conflict'}),{code:'already-exists'});
  await assert.rejects(f.invoke('update',{...update,idempotencyKey:'menu-update-00002'}),{code:'aborted'});
  const lifecycle={itemId,expectedVersion:2,idempotencyKey:'menu-archive-0001',action:'archive'};
  await f.invoke('lifecycle',lifecycle);assert.equal((await f.invoke('lifecycle',lifecycle)).changed,false);
  await assert.rejects(f.invoke('lifecycle',{...lifecycle,action:'restore'}),{code:'already-exists'});
});
test('concurrent versions have one winner',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const results=await Promise.allSettled([1,2].map(n=>f.invoke('update',{
    itemId,expectedVersion:1,idempotencyKey:`menu-update-0000${n}`,name:`Name ${n}`})));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal(results.find(r=>r.status==='rejected').reason.code,'aborted');
});
test('bounded pagination is deterministic and empty lists are explicit',async()=>{
  const f=fixture();for(let n=0;n<3;n++)await f.invoke('create',input({idempotencyKey:`menu-create-0000${n}`}));
  const first=await f.invoke('list',{limit:2});const last=await f.invoke('list',{limit:2,cursor:first.nextCursor});
  assert.equal(first.items.length,2);assert.equal(last.items.length,1);assert.equal(last.nextCursor,null);
  assert.equal(new Set([...first.items,...last.items].map(m=>m.id)).size,3);
});
test('invalid stored records and malformed receipts fail closed',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const doc=f.store.docs.get(`cafes/a/menu_items/${itemId}`);
  for(const extra of [{schemaVersion:2},{priceMinor:1.5},{currency:'USD'},{isAvailable:'true'},
    {isArchived:'false'},{createdAt:null},{cafeId:'b'},{updatedBy:''}]) {
    assert.throws(()=>menuDocument(itemId,{...doc,...extra},'a'),{code:'failed-precondition'});
  }
  const receipt=[...f.store.docs.values()].find(d=>d.resultVersion===1);receipt.resultVersion='1';
  await assert.rejects(f.invoke('create',input()),{code:'failed-precondition'});
});
test('failed commits do not leave menu items, edits or receipts',async()=>{
  const f=fixture();f.store.fail=true;const before=structuredClone([...f.store.docs]);
  await assert.rejects(f.invoke('create',input()));assert.deepEqual([...f.store.docs],before);
  f.store.fail=false;const {itemId}=await f.invoke('create',input());
  for(const operation of ['update','lifecycle']) {
    const before=structuredClone([...f.store.docs]);f.store.fail=true;
    await assert.rejects(f.invoke(operation,{itemId,expectedVersion:1,idempotencyKey:'menu-failure-0001',
      ...(operation==='update'?{name:'Failed'}:{action:'archive'})}));
    assert.deepEqual([...f.store.docs],before);f.store.fail=false;
  }
});

test('Owner and Staff toggle only availability with trusted audit identity and stable retries',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  let version=1;
  for(const uid of ['staff','owner']) {
    for(const isAvailable of [false,true]) {
      const before=(await f.invoke('get',{itemId})).item;
      const data={itemId,expectedVersion:version,idempotencyKey:`availability-${uid}-${version}`,isAvailable};
      const result=await f.invoke('update',data,uid);
      assert.equal(result.version,++version);
      assert.equal((await f.invoke('update',data,uid)).changed,false);
      const after=(await f.invoke('get',{itemId})).item;
      assert.equal(after.isAvailable,isAvailable);assert.equal(after.updatedBy,uid);
      for(const key of ['name','category','priceMinor','currency','isArchived','createdAt','createdBy','cafeId'])
        assert.deepEqual(after[key],before[key]);
      await assert.rejects(f.invoke('update',{...data,isAvailable:!isAvailable},uid),{code:'already-exists'});
    }
  }
  assert.equal(f.store.docs.get('cafes/a').ownerUid,'owner');
});
for(const extra of [{name:'Flat White'},{category:'Coffee'},{priceMinor:1200},
  {isArchived:false},{cafeId:'b'},{ownerUid:'staff'},{role:'owner'},{createdBy:'staff'}]) {
  test(`Staff availability payload cannot smuggle ${Object.keys(extra)[0]}`,async()=>{
    const f=fixture();const {itemId}=await f.invoke('create',input());
    const before=structuredClone([...f.store.docs]);
    const recognized=['name','category','priceMinor'].includes(Object.keys(extra)[0]);
    await assert.rejects(f.invoke('update',{itemId,expectedVersion:1,idempotencyKey:'availability-staff-1',
      isAvailable:false,...extra},'staff'),{code:recognized?'permission-denied':'invalid-argument'});
    assert.deepEqual([...f.store.docs],before);
  });
}
test('Staff availability validation, foreign IDs, archived items and stale versions fail closed',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const data={itemId,expectedVersion:1,idempotencyKey:'availability-staff-1',isAvailable:false};
  for(const isAvailable of [null,0,'false',{},[]])
    await assert.rejects(f.invoke('update',{...data,isAvailable},'staff'),{code:'invalid-argument'});
  await assert.rejects(f.invoke('update',data,null),{code:'unauthenticated'});
  const foreign=await f.invoke('create',input(),'foreign');
  await assert.rejects(f.invoke('update',{...data,itemId:foreign.itemId},'staff'),{code:'not-found'});
  await f.invoke('lifecycle',{itemId,expectedVersion:1,idempotencyKey:'archive-owner-0001',action:'archive'});
  await assert.rejects(f.invoke('update',{...data,expectedVersion:2},'staff'),{code:'failed-precondition'});
  await f.invoke('lifecycle',{itemId,expectedVersion:2,idempotencyKey:'restore-owner-0001',action:'restore'});
  await assert.rejects(f.invoke('update',data,'staff'),{code:'aborted'});
});
test('revocation blocks availability and its retry receipts',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const data={itemId,expectedVersion:1,idempotencyKey:'availability-staff-1',isAvailable:false};
  await f.invoke('update',data,'staff');
  f.store.docs.get('cafes/a/members/staff').status='revoked';
  await assert.rejects(f.invoke('update',data,'staff'),{code:'permission-denied'});
});
test('Owner/Staff concurrent availability versions have one winner and cannot overwrite details',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const results=await Promise.allSettled(['owner','staff'].map(uid=>f.invoke('update',{
    itemId,expectedVersion:1,idempotencyKey:`availability-${uid}-1`,isAvailable:false},uid)));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal(results.find(r=>r.status==='rejected').reason.code,'aborted');
  const item=(await f.invoke('get',{itemId})).item;
  assert.equal(item.version,2);assert.equal(item.name,'Flat White');assert.equal(item.priceMinor,1200);
});
test('failed Staff availability commit leaves item and receipts unchanged',async()=>{
  const f=fixture();const {itemId}=await f.invoke('create',input());
  const before=structuredClone([...f.store.docs]);f.store.fail=true;
  await assert.rejects(f.invoke('update',{itemId,expectedVersion:1,idempotencyKey:'availability-staff-1',isAvailable:false},'staff'));
  assert.deepEqual([...f.store.docs],before);
});
