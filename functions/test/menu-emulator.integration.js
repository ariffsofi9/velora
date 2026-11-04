'use strict';
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {FieldValue} = require('firebase-admin/firestore');
const {initializeTestEnvironment, assertFails, assertSucceeds} = require('@firebase/rules-unit-testing');
const {doc, collection, getDoc, getDocs, setDoc, updateDoc, deleteDoc} = require('firebase/firestore');
const {menuOperation} = require('../src/menu-service');

module.exports = async function menuIntegration({t, db, call, owner, staff, second, workspace, other}) {
  if (process.env.GCLOUD_PROJECT !== 'demo-velora-team' ||
      process.env.FIRESTORE_EMULATOR_HOST !== '127.0.0.1:38080' ||
      process.env.FIREBASE_AUTH_EMULATOR_HOST !== '127.0.0.1:39099') throw Error('Disposable team emulators required.');
  const payload = (extra={}) => ({idempotencyKey:randomUUID(),name:'Synthetic Latte',category:'Coffee',
    priceMinor:1200,isAvailable:true,...extra});
  async function ok(name, who, data) {
    const response=await call(name,who,data);
    assert.ok(response.result,`${name} failed: ${response.error?.status ?? 'invalid response'}`);
    return response.result;
  }
  async function denied(name,who,data,status) {
    assert.equal((await call(name,who,data)).error?.status,status);
  }
  let itemId;
  await t.test('Menu Owner creates and Staff reads bounded, audited MYR menu',async()=>{
    const data=payload();const created=await ok('createMenuItem',owner,data);itemId=created.itemId;
    assert.equal((await ok('createMenuItem',owner,data)).changed,false);
    await denied('createMenuItem',owner,{...data,priceMinor:1300},'ALREADY_EXISTS');
    const item=(await ok('getMenuItem',staff,{itemId})).item;
    assert.equal(item.cafeId,workspace.cafeId);assert.equal(item.priceMinor,1200);
    assert.equal(item.currency,'MYR');assert.equal(item.createdBy,owner.user.localId);
    assert.ok(Number.isFinite(Date.parse(item.createdAt)));
    assert.equal((await ok('listMenuItems',staff,{})).items.length,1);
  });
  await t.test('Menu update/archive/restore enforce versions, retries and archived restrictions',async()=>{
    const update={idempotencyKey:randomUUID(),itemId,expectedVersion:1,name:'Synthetic Flat White',isAvailable:false};
    await ok('updateMenuItem',owner,update);
    assert.equal((await ok('updateMenuItem',owner,update)).changed,false);
    await denied('updateMenuItem',owner,{...update,name:'Conflict'},'ALREADY_EXISTS');
    await denied('updateMenuItem',owner,{...update,idempotencyKey:randomUUID()},'ABORTED');
    const archive={idempotencyKey:randomUUID(),itemId,expectedVersion:2,action:'archive'};
    await ok('setMenuItemLifecycle',owner,archive);
    assert.equal((await ok('setMenuItemLifecycle',owner,archive)).changed,false);
    await denied('setMenuItemLifecycle',owner,{...archive,action:'restore'},'ALREADY_EXISTS');
    await denied('updateMenuItem',owner,{...update,idempotencyKey:randomUUID(),expectedVersion:3},'FAILED_PRECONDITION');
    await denied('setMenuItemLifecycle',owner,{...archive,idempotencyKey:randomUUID(),expectedVersion:3},'FAILED_PRECONDITION');
    assert.equal((await ok('listMenuItems',staff,{})).items.length,0);
    assert.equal((await ok('listMenuItems',staff,{includeArchived:true})).items.length,1);
    assert.equal((await ok('getMenuItem',staff,{itemId})).item.isArchived,true);
    const restore={...archive,idempotencyKey:randomUUID(),expectedVersion:3,action:'restore'};
    await ok('setMenuItemLifecycle',owner,restore);
    assert.equal((await ok('setMenuItemLifecycle',owner,restore)).changed,false);
    const item=(await ok('getMenuItem',staff,{itemId})).item;
    assert.equal(item.version,4);assert.equal(item.isArchived,false);assert.equal(item.isAvailable,false);
    await denied('setMenuItemLifecycle',owner,{...restore,idempotencyKey:randomUUID(),expectedVersion:4},'FAILED_PRECONDITION');
  });
  await t.test('Menu Staff mutations and anonymous calls are denied by trusted callables',async()=>{
    const requests=[['createMenuItem',payload()],['updateMenuItem',{
      itemId,expectedVersion:4,idempotencyKey:randomUUID(),name:'Forbidden'}],
    ['setMenuItemLifecycle',{itemId,expectedVersion:4,idempotencyKey:randomUUID(),action:'archive'}],
    ['setMenuItemLifecycle',{itemId,expectedVersion:4,idempotencyKey:randomUUID(),action:'restore'}]];
    const ref=db.doc(`cafes/${workspace.cafeId}/menu_items/${itemId}`);const before=(await ref.get()).data();
    for(const [name,data] of requests) {
      await denied(name,staff,data,'PERMISSION_DENIED');
      await denied(name,null,data,'UNAUTHENTICATED');
    }
    await denied('listMenuItems',null,{},'UNAUTHENTICATED');
    await denied('getMenuItem',null,{itemId},'UNAUTHENTICATED');
    assert.deepEqual((await ref.get()).data(),before);
  });
  await t.test('Menu cross-cafe IDs and client-supplied authority never authorize access',async()=>{
    const foreign=await ok('createMenuItem',second,payload());
    const foreignRef=db.doc(`cafes/${other.cafeId}/menu_items/${foreign.itemId}`);
    const before=(await foreignRef.get()).data();
    for(const who of [owner,staff])await denied('getMenuItem',who,{itemId:foreign.itemId},'NOT_FOUND');
    for(const [name,data] of [
      ['updateMenuItem',{itemId:foreign.itemId,expectedVersion:1,idempotencyKey:randomUUID(),name:'Forbidden'}],
      ['setMenuItemLifecycle',{itemId:foreign.itemId,expectedVersion:1,idempotencyKey:randomUUID(),action:'archive'}],
      ['setMenuItemLifecycle',{itemId:foreign.itemId,expectedVersion:1,idempotencyKey:randomUUID(),action:'restore'}],
    ])await denied(name,owner,data,'NOT_FOUND');
    for(const extra of [{cafeId:other.cafeId},{ownerUid:second.user.localId},{role:'owner'},{actorUid:owner.user.localId}]) {
      await denied('createMenuItem',staff,payload(extra),'INVALID_ARGUMENT');
      await denied('listMenuItems',staff,extra,'INVALID_ARGUMENT');
      await denied('getMenuItem',owner,{itemId,...extra},'INVALID_ARGUMENT');
      await denied('updateMenuItem',owner,{itemId,expectedVersion:4,idempotencyKey:randomUUID(),name:'Forbidden',...extra},'INVALID_ARGUMENT');
      await denied('setMenuItemLifecycle',owner,{itemId,expectedVersion:4,idempotencyKey:randomUUID(),action:'archive',...extra},'INVALID_ARGUMENT');
    }
    assert.deepEqual((await foreignRef.get()).data(),before);
  });
  await t.test('Menu Rules allow scoped Owner/Staff reads but deny every direct write and receipt access',async()=>{
    const rules=await initializeTestEnvironment({projectId:'demo-velora-team',firestore:{host:'127.0.0.1',port:38080}});
    try {
      for(const who of [owner,staff]) {
        const client=rules.authenticatedContext(who.user.localId).firestore();
        const own=doc(client,`cafes/${workspace.cafeId}/menu_items/${itemId}`);
        await assertSucceeds(getDoc(own));
        await assertSucceeds(getDocs(collection(client,`cafes/${workspace.cafeId}/menu_items`)));
        await assertFails(getDocs(collection(client,`cafes/${other.cafeId}/menu_items`)));
        await assertFails(setDoc(doc(client,`cafes/${workspace.cafeId}/menu_items/forged`),{name:'Forbidden'}));
        await assertFails(updateDoc(own,{priceMinor:1,isArchived:false}));
        await assertFails(updateDoc(own,{isAvailable:false}));
        await assertFails(deleteDoc(own));
        await assertFails(getDocs(collection(client,`cafes/${workspace.cafeId}/menu_requests`)));
        await assertFails(setDoc(doc(client,`cafes/${workspace.cafeId}/menu_requests/forged`),{actorUid:who.user.localId}));
      }
      const anonymous=rules.unauthenticatedContext().firestore();
      await assertFails(getDoc(doc(anonymous,`cafes/${workspace.cafeId}/menu_items/${itemId}`)));
    } finally {await rules.cleanup();}
  });
  await t.test('Menu callable rejects invalid prices, booleans, required fields and pagination bounds',async()=>{
    for(const extra of [{priceMinor:-1},{priceMinor:0.1},{priceMinor:'1200'},{priceMinor:1000001},
      {name:''},{category:''},{isAvailable:'true'},{isArchived:true},{currency:'USD'},{version:2}]) {
      await denied('createMenuItem',owner,payload(extra),'INVALID_ARGUMENT');
    }
    await denied('createMenuItem',owner,{idempotencyKey:randomUUID(),name:'Incomplete'},'INVALID_ARGUMENT');
    for(const data of [{limit:0},{limit:51},{includeArchived:1},{cursor:'other/item'}])
      await denied('listMenuItems',staff,data,'INVALID_ARGUMENT');
  });
  await t.test('Menu concurrent create, bounded pagination and optimistic update conflict',async()=>{
    const data=payload();const responses=await Promise.all([1,2].map(()=>ok('createMenuItem',owner,data)));
    assert.equal(responses.filter(r=>r.changed).length,1);
    assert.equal(responses[0].itemId,responses[1].itemId);
    for(let n=0;n<3;n++)await ok('createMenuItem',owner,payload({name:`Synthetic Menu ${n}`}));
    let cursor;const ids=[];
    for(let page=0;page<4;page++) {
      const result=await ok('listMenuItems',staff,{limit:2,...(cursor?{cursor}:{})});
      assert.ok(result.items.length<=2);ids.push(...result.items.map(item=>item.id));
      cursor=result.nextCursor;if(!cursor)break;
    }
    assert.equal(cursor,null);assert.equal(ids.length,5);assert.equal(new Set(ids).size,5);
    const edits=await Promise.all([1,2].map(n=>call('updateMenuItem',owner,{
      itemId,expectedVersion:4,idempotencyKey:randomUUID(),name:`Concurrent ${n}`})));
    assert.equal(edits.filter(r=>r.result?.changed).length,1);
    assert.equal(edits.filter(r=>r.error?.status==='ABORTED').length,1);
  });
  await t.test('Menu revocation and inconsistent owner links deny reads and mutations',async()=>{
    const ownerMap=db.doc(`user_cafe_memberships/${owner.user.localId}`);
    const staffMember=db.doc(`cafes/${workspace.cafeId}/members/${staff.user.localId}`);
    await staffMember.update({status:'revoked'});
    try {await denied('listMenuItems',staff,{},'PERMISSION_DENIED');}
    finally {await staffMember.update({status:'active'});}
    await ownerMap.update({status:'revoked'});
    try {
      await denied('listMenuItems',staff,{},'PERMISSION_DENIED');
      await denied('getMenuItem',owner,{itemId},'PERMISSION_DENIED');
      await denied('createMenuItem',owner,payload(),'PERMISSION_DENIED');
    } finally {await ownerMap.update({status:'active'});}
  });
  await t.test('Menu real failed commits roll back creates, updates, lifecycle and receipts',async()=>{
    async function snapshot() {
      const rows=[];
      for(const collectionName of ['menu_items','menu_requests']) {
        const result=await db.collection(`cafes/${workspace.cafeId}/${collectionName}`).get();
        rows.push(result.docs.map(doc=>({id:doc.id,data:doc.data()})).sort((a,b)=>a.id.localeCompare(b.id)));
      }
      return rows;
    }
    const blocker=db.doc(`test_faults/${randomUUID()}`);await blocker.create({synthetic:true});
    const store={runTransaction:operation=>db.runTransaction(tx=>{
      let injected=false;
      return operation({
      get:async p=>{const row=await tx.get(db.doc(p));return row.exists?row.data():null;},
      update:(p,d)=>tx.update(db.doc(p),d),
      create:(p,d)=>{
        tx.create(db.doc(p),d);
        if(!injected){injected=true;tx.create(blocker,{synthetic:true});}
      },
    });})};
    for(const [operation,data] of [['create',payload()],
      ['update',{itemId,expectedVersion:5,idempotencyKey:randomUUID(),name:'Failed'}],
      ['lifecycle',{itemId,expectedVersion:5,idempotencyKey:randomUUID(),action:'archive'}]]) {
      const before=await snapshot();
      await assert.rejects(menuOperation({operation,auth:{uid:owner.user.localId},data,store,
        timestamp:()=>FieldValue.serverTimestamp()}),e=>e.code===6);
      assert.deepEqual(await snapshot(),before);
    }
  });
  let availabilityId, staffAvailabilityRequest;
  await t.test('Menu Option B permits availability-only Owner/Staff updates with retries and trusted audits',async()=>{
    availabilityId=(await ok('createMenuItem',owner,payload())).itemId;
    const before=(await ok('getMenuItem',staff,{itemId:availabilityId})).item;
    staffAvailabilityRequest={itemId:availabilityId,expectedVersion:1,idempotencyKey:randomUUID(),isAvailable:false};
    await ok('updateMenuItem',staff,staffAvailabilityRequest);
    assert.equal((await ok('updateMenuItem',staff,staffAvailabilityRequest)).changed,false);
    await denied('updateMenuItem',staff,{...staffAvailabilityRequest,isAvailable:true},'ALREADY_EXISTS');
    let item=(await ok('getMenuItem',owner,{itemId:availabilityId})).item;
    assert.equal(item.version,2);assert.equal(item.isAvailable,false);assert.equal(item.updatedBy,staff.user.localId);
    await ok('updateMenuItem',owner,{itemId:availabilityId,expectedVersion:2,idempotencyKey:randomUUID(),isAvailable:true});
    await ok('updateMenuItem',staff,{itemId:availabilityId,expectedVersion:3,idempotencyKey:randomUUID(),isAvailable:false});
    item=(await ok('getMenuItem',owner,{itemId:availabilityId})).item;
    assert.equal(item.version,4);assert.equal(item.isAvailable,false);
    for(const key of ['name','category','priceMinor','currency','isArchived','createdAt','createdBy','cafeId'])
      assert.deepEqual(item[key],before[key]);
    assert.equal((await db.doc(`cafes/${workspace.cafeId}`).get()).data().ownerUid,owner.user.localId);
  });
  await t.test('Menu Option B rejects mixed fields, invalid values, foreign IDs, archived and revoked access',async()=>{
    const request={itemId:availabilityId,expectedVersion:4,idempotencyKey:randomUUID(),isAvailable:true};
    const ref=db.doc(`cafes/${workspace.cafeId}/menu_items/${availabilityId}`);
    const before=(await ref.get()).data();
    for(const extra of [{name:'Synthetic Latte'},{category:'Coffee'},{priceMinor:1200}])
      await denied('updateMenuItem',staff,{...request,...extra},'PERMISSION_DENIED');
    for(const extra of [{isArchived:false},{cafeId:other.cafeId},{ownerUid:staff.user.localId},
      {role:'owner'},{createdBy:staff.user.localId}])
      await denied('updateMenuItem',staff,{...request,...extra},'INVALID_ARGUMENT');
    for(const isAvailable of [null,0,'false',{},[]])
      await denied('updateMenuItem',staff,{...request,isAvailable},'INVALID_ARGUMENT');
    await denied('updateMenuItem',null,request,'UNAUTHENTICATED');
    const foreign=await ok('createMenuItem',second,payload());
    await denied('updateMenuItem',staff,{...request,itemId:foreign.itemId},'NOT_FOUND');
    assert.deepEqual((await ref.get()).data(),before);
    await ok('setMenuItemLifecycle',owner,{itemId:availabilityId,expectedVersion:4,idempotencyKey:randomUUID(),action:'archive'});
    await denied('updateMenuItem',staff,{...request,expectedVersion:5},'FAILED_PRECONDITION');
    await ok('setMenuItemLifecycle',owner,{itemId:availabilityId,expectedVersion:5,idempotencyKey:randomUUID(),action:'restore'});
    await denied('updateMenuItem',staff,request,'ABORTED');
    const member=db.doc(`cafes/${workspace.cafeId}/members/${staff.user.localId}`);
    await member.update({status:'revoked'});
    try {
      await denied('updateMenuItem',staff,{...request,expectedVersion:6},'PERMISSION_DENIED');
      await denied('updateMenuItem',staff,staffAvailabilityRequest,'PERMISSION_DENIED');
    } finally {await member.update({status:'active'});}
  });
  await t.test('Menu Option B concurrent writes and failed Staff commit preserve details and receipts',async()=>{
    const actors=[owner,staff];
    const outcomes=await Promise.all(actors.map(who=>call('updateMenuItem',who,{
      itemId:availabilityId,expectedVersion:6,idempotencyKey:randomUUID(),isAvailable:false})));
    const winner=outcomes.findIndex(r=>r.result?.changed);
    assert.ok(winner>=0);assert.equal(outcomes.filter(r=>r.result?.changed).length,1);
    assert.equal(outcomes.filter(r=>r.error?.status==='ABORTED').length,1);
    const ref=db.doc(`cafes/${workspace.cafeId}/menu_items/${availabilityId}`);
    const before=(await ref.get()).data();
    assert.equal(before.version,7);assert.equal(before.updatedBy,actors[winner].user.localId);
    assert.equal(before.name,'Synthetic Latte');assert.equal(before.priceMinor,1200);
    const key=randomUUID();
    const {createHash}=require('node:crypto');
    const requestHash=createHash('sha256').update(`${staff.user.localId}\0${workspace.cafeId}\0${key}`).digest('hex');
    const receipt=db.doc(`cafes/${workspace.cafeId}/menu_requests/${requestHash}`);
    const blocker=db.doc(`test_faults/${randomUUID()}`);await blocker.create({synthetic:true});
    const store={runTransaction:operation=>db.runTransaction(tx=>operation({
      get:async p=>{const row=await tx.get(db.doc(p));return row.exists?row.data():null;},
      update:(p,d)=>tx.update(db.doc(p),d),
      create:(p,d)=>{tx.create(db.doc(p),d);tx.create(blocker,{synthetic:true});},
    }))};
    await assert.rejects(menuOperation({operation:'update',auth:{uid:staff.user.localId},
      data:{itemId:availabilityId,expectedVersion:7,idempotencyKey:key,isAvailable:true},store,
      timestamp:()=>FieldValue.serverTimestamp()}),e=>e.code===6);
    assert.deepEqual((await ref.get()).data(),before);assert.equal((await receipt.get()).exists,false);
  });
};
