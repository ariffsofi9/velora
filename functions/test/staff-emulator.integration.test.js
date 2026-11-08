'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getAuth}=require('firebase-admin/auth');const {getFirestore,Timestamp,FieldValue}=require('firebase-admin/firestore');
const {initializeTestEnvironment,assertFails,assertSucceeds}=require('@firebase/rules-unit-testing');
const {doc,getDoc,setDoc,updateDoc}=require('firebase/firestore');
const PROJECT=process.env.GCLOUD_PROJECT;
const TEAM=PROJECT==='demo-velora-team';
const AUTH_PORT=TEAM?39099:29099, FIRESTORE_PORT=TEAM?38080:28080, FUNCTIONS_PORT=TEAM?35001:25001;
if(!['demo-velora-staff','demo-velora-team'].includes(PROJECT)||
 process.env.FIRESTORE_EMULATOR_HOST!==`127.0.0.1:${FIRESTORE_PORT}`||
 process.env.FIREBASE_AUTH_EMULATOR_HOST!==`127.0.0.1:${AUTH_PORT}`)throw Error('Disposable staff emulators required.');

test('isolated Owner/Staff inventory, invitation workflow and Rules', {timeout:180000},async t=>{
 const app=initializeApp({projectId:PROJECT},'staff-tests');t.after(()=>deleteApp(app));
 const db=getFirestore(app);const auth=getAuth(app);
 async function account(verified=false){
  const email=`staff-${randomUUID()}@example.test`;const password='disposable-test-password';
  const signup=await fetch(`http://127.0.0.1:${AUTH_PORT}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo`,{
   method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});
  assert.equal(signup.status,200);const user=await signup.json();
  async function refresh(){
   const r=await fetch(`http://127.0.0.1:${AUTH_PORT}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo`,{
    method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});
   assert.equal(r.status,200);user.idToken=(await r.json()).idToken;
  }
  if(verified){await auth.updateUser(user.localId,{emailVerified:true});await refresh();}
  return {user,email,refresh};
 }
 async function call(name,who,data){
  const r=await fetch(`http://127.0.0.1:${FUNCTIONS_PORT}/${PROJECT}/asia-southeast1/${name}`,{
   method:'POST',headers:{'Content-Type':'application/json',...(who?{Authorization:`Bearer ${who.user.idToken}`}:{})},
   body:JSON.stringify({data})});return r.json();
 }
 // account(true) verifies the synthetic account and refreshes its token before bootstrap.
 // Keep Staff unverified until the explicit redemption-denial test below.
 const owner=await account(true);const second=await account(true);const staff=await account();const wrong=await account(true);
 const setup={businessName:'Disposable Staff Cafe',businessType:'cafe',address:'',inventoryUnit:'kg',lowStockAlerts:true,expiryReminders:true,reminderDays:3};
 const workspace=(await call('createWorkspace',owner,setup)).result;assert.ok(workspace?.cafeId);
 const other=(await call('createWorkspace',second,setup)).result;assert.ok(other?.cafeId);
 await t.test('second workspace rejected and new unsupported business types rejected',async()=>{
  assert.equal((await call('createWorkspace',owner,{...setup,businessName:'Second Workspace'})).error.status,'ALREADY_EXISTS');
  assert.equal((await call('createWorkspace',wrong,{...setup,businessType:'Catering'})).error.status,'INVALID_ARGUMENT');
 });
 let number=0;
 const create=(who=owner,email=staff.email)=>call('createStaffInvitation',who,{email,requestId:`staff-integration-${++number}-${randomUUID()}`});
 await t.test('unauthorized and forged invitation creation rejected',async()=>{
  assert.equal((await create(wrong)).error.status,'PERMISSION_DENIED');
  assert.equal((await call('createStaffInvitation',owner,{email:staff.email,requestId:randomUUID(),role:'owner'})).error.status,'INVALID_ARGUMENT');
  assert.equal((await call('createStaffInvitation',null,{email:staff.email,requestId:randomUUID()})).error.status,'UNAUTHENTICATED');
 });
 await t.test('revoked and expired invitations cannot be redeemed',async()=>{
  const verified=await account(true);
  const revoked=(await create(owner,verified.email)).result;assert.ok(revoked?.invitationId);
  assert.equal((await call('revokeStaffInvitation',second,{invitationId:revoked.invitationId})).error.status,'PERMISSION_DENIED');
  assert.equal((await call('revokeStaffInvitation',owner,{invitationId:revoked.invitationId})).result.revoked,true);
  assert.equal((await call('redeemStaffInvitation',verified,{code:revoked.code})).error.status,'FAILED_PRECONDITION');
  const expired=(await create(owner,verified.email)).result;
  await db.doc(`workspace_invitations/${expired.invitationId}`).update({expiresAt:Timestamp.fromDate(new Date('2000-01-01Z'))});
  assert.equal((await call('redeemStaffInvitation',verified,{code:expired.code})).error.status,'FAILED_PRECONDITION');
 });
 const invitation=(await create()).result;assert.ok(invitation?.invitationId);
 await t.test('unverified email and verified email mismatch denied',async()=>{
  assert.equal((await call('redeemStaffInvitation',staff,{code:invitation.code})).error.status,'FAILED_PRECONDITION');
  assert.equal((await call('redeemStaffInvitation',wrong,{code:invitation.code})).error.status,'PERMISSION_DENIED');
  await auth.updateUser(staff.user.localId,{emailVerified:true});await staff.refresh();
 });
 await t.test('concurrent redemption commits once; replay and second membership rejected',async()=>{
  const outcomes=await Promise.all([1,2].map(()=>call('redeemStaffInvitation',staff,{code:invitation.code})));
  assert.equal(outcomes.filter(x=>x.result?.joined).length,1);
  assert.equal((await call('redeemStaffInvitation',staff,{code:invitation.code})).error.status,'FAILED_PRECONDITION');
  const next=(await create(second)).result;
  assert.equal((await call('redeemStaffInvitation',staff,{code:next.code})).error.status,'ALREADY_EXISTS');
  assert.equal((await db.doc(`user_cafe_memberships/${staff.user.localId}`).get()).data().cafeId,workspace.cafeId);
  assert.equal((await db.doc(`cafes/${workspace.cafeId}/members/${staff.user.localId}`).get()).data().role,'staff');
  assert.equal((await create(staff)).error.status,'PERMISSION_DENIED');
 });
 // Inventory regression uses only these disposable accounts and existing callables.
 const inventoryData=()=>({idempotencyKey:randomUUID(),name:'Synthetic Milk',category:'Dairy',
  quantity:4,unit:'L',expiryDate:'2030-01-02T00:00:00.000Z',imageUrl:''});
 const inventoryRef=id=>db.doc(`cafes/${workspace.cafeId}/inventory/${id}`);
 async function ok(name,who,data){
  const response=await call(name,who,data);
  assert.ok(response.result,`${name} failed: ${response.error?.status??'invalid response'}`);
  return response.result;
 }
 async function itemState(id){
  const item=await inventoryRef(id).get();
  const movements=await db.collection(`cafes/${workspace.cafeId}/inventory_movements`).where('itemId','==',id).get();
  const activities=await db.collection(`cafes/${workspace.cafeId}/activities`).where('itemId','==',id).get();
  return {item:item.data(),movements:movements.docs.map(d=>({id:d.id,...d.data()})).sort((a,b)=>a.id.localeCompare(b.id)),
   activities:activities.docs.map(d=>({id:d.id,...d.data()})).sort((a,b)=>a.id.localeCompare(b.id))};
 }
 async function denied(name,who,data,status,id){
  const before=id?await itemState(id):null;
  assert.equal((await call(name,who,data)).error?.status,status);
  if(id)assert.deepEqual(await itemState(id),before,'Rejected operation changed item or audits');
 }
 const workflowItems=[];
 for(const [role,who] of [['Owner',owner],['Staff',staff]]){
  await t.test(`${role} inventory create/edit/stock/archive/restore is atomic and idempotent`,async()=>{
   const data=inventoryData();const created=await ok('createInventoryItem',who,data);
   const id=created.itemId;workflowItems.push(id);
   assert.equal(created.cafeId,workspace.cafeId);
   assert.equal((await ok('createInventoryItem',who,data)).created,false);
   await denied('createInventoryItem',who,{...data,quantity:8},'ALREADY_EXISTS',id);
   const edit={idempotencyKey:randomUUID(),itemId:id,expectedVersion:1,name:'Synthetic Whole Milk'};
   await ok('updateInventoryItem',who,edit);await ok('updateInventoryItem',who,edit);
   await denied('updateInventoryItem',who,{...edit,name:'Changed retry'},'ALREADY_EXISTS',id);
   const stock={idempotencyKey:randomUUID(),itemId:id,expectedVersion:2,direction:'in',quantity:3,reason:'Synthetic delivery'};
   assert.equal((await ok('adjustInventoryStock',who,stock)).resultingQuantity,7);
   assert.equal((await ok('adjustInventoryStock',who,stock)).adjusted,false);
   await denied('adjustInventoryStock',who,{...stock,quantity:4},'ALREADY_EXISTS',id);
   await denied('adjustInventoryStock',who,{...stock,idempotencyKey:randomUUID()},'ABORTED',id);
   const out={...stock,idempotencyKey:randomUUID(),expectedVersion:3,direction:'out',quantity:2};
   assert.equal((await ok('adjustInventoryStock',who,out)).resultingQuantity,5);
   const archive={idempotencyKey:randomUUID(),itemId:id,expectedVersion:4,action:'archive'};
   await ok('setInventoryLifecycle',who,archive);
   assert.equal((await ok('setInventoryLifecycle',who,archive)).changed,false);
   await denied('setInventoryLifecycle',who,{...archive,action:'restore'},'ALREADY_EXISTS',id);
   await denied('setInventoryLifecycle',who,{...archive,idempotencyKey:randomUUID(),expectedVersion:5},'FAILED_PRECONDITION',id);
   await denied('updateInventoryItem',who,{...edit,idempotencyKey:randomUUID(),expectedVersion:5},'FAILED_PRECONDITION',id);
   await denied('adjustInventoryStock',who,{...stock,idempotencyKey:randomUUID(),expectedVersion:5},'FAILED_PRECONDITION',id);
   const restore={...archive,idempotencyKey:randomUUID(),expectedVersion:5,action:'restore'};
   await ok('setInventoryLifecycle',who,restore);
   assert.equal((await ok('setInventoryLifecycle',who,restore)).changed,false);
   await denied('setInventoryLifecycle',who,{...restore,idempotencyKey:randomUUID(),expectedVersion:6},'FAILED_PRECONDITION',id);
   await denied('adjustInventoryStock',who,{...out,idempotencyKey:randomUUID(),expectedVersion:6,quantity:6},'FAILED_PRECONDITION',id);
   for(const quantity of [0,-1,1.5])await denied('adjustInventoryStock',who,
    {...stock,idempotencyKey:randomUUID(),expectedVersion:6,quantity},'INVALID_ARGUMENT',id);
   const state=await itemState(id);
   assert.equal(state.item.quantity,5);assert.equal(state.item.unit,'L');assert.equal(state.item.version,6);
   assert.equal(state.item.lifecycleState,'active');assert.equal(state.item.name,edit.name);
   assert.equal(state.item.archivedAt,undefined);assert.equal(state.item.archivedBy,undefined);
   assert.equal(state.movements.length,3);assert.equal(state.activities.length,6);
   assert.equal(state.item.createdBy,who.user.localId);assert.equal(state.item.updatedBy,who.user.localId);
   assert.ok(state.item.updatedAt instanceof Timestamp);
   for(const audit of [...state.movements,...state.activities]){
    assert.equal(audit.actorUid,who.user.localId);assert.equal(audit.cafeId,workspace.cafeId);
    assert.ok(audit.createdAt instanceof Timestamp);
   }
  });
 }
 await t.test('Owner and Staff cannot mutate foreign items or supply authority fields',async()=>{
  const foreign=await ok('createInventoryItem',second,inventoryData());
  const foreignRef=db.doc(`cafes/${other.cafeId}/inventory/${foreign.itemId}`);
  const before=(await foreignRef.get()).data();
  for(const who of [owner,staff]){
   for(const [name,data] of [
    ['updateInventoryItem',{itemId:foreign.itemId,expectedVersion:1,name:'Forbidden'}],
    ['adjustInventoryStock',{itemId:foreign.itemId,expectedVersion:1,direction:'out',quantity:1,reason:'Synthetic'}],
    ['setInventoryLifecycle',{itemId:foreign.itemId,expectedVersion:1,action:'archive'}],
    ['setInventoryLifecycle',{itemId:foreign.itemId,expectedVersion:1,action:'restore'}],
   ])await denied(name,who,{idempotencyKey:randomUUID(),...data},'NOT_FOUND');
   for(const [name,data] of [
    ['createInventoryItem',inventoryData()],
    ['updateInventoryItem',{idempotencyKey:randomUUID(),itemId:workflowItems[0],expectedVersion:6,name:'Forbidden'}],
    ['adjustInventoryStock',{idempotencyKey:randomUUID(),itemId:workflowItems[0],expectedVersion:6,direction:'in',quantity:1,reason:'Synthetic'}],
    ['setInventoryLifecycle',{idempotencyKey:randomUUID(),itemId:workflowItems[0],expectedVersion:6,action:'archive'}],
   ])for(const extra of [{cafeId:other.cafeId},{role:'owner'},{actorUid:owner.user.localId}])
    await denied(name,who,{...data,...extra},'INVALID_ARGUMENT',workflowItems[0]);
  }
  assert.deepEqual((await foreignRef.get()).data(),before);
 });
 await t.test('anonymous and revoked Staff cannot use inventory callables',async()=>{
  const id=workflowItems[1];const member=db.doc(`cafes/${workspace.cafeId}/members/${staff.user.localId}`);
  const requests=[['createInventoryItem',inventoryData()],
   ['updateInventoryItem',{idempotencyKey:randomUUID(),itemId:id,expectedVersion:6,name:'Forbidden'}],
   ['adjustInventoryStock',{idempotencyKey:randomUUID(),itemId:id,expectedVersion:6,direction:'in',quantity:1,reason:'Synthetic'}],
   ['setInventoryLifecycle',{idempotencyKey:randomUUID(),itemId:id,expectedVersion:6,action:'archive'}]];
  for(const [name,data] of requests)await denied(name,null,data,'UNAUTHENTICATED',id);
  await member.update({status:'revoked'});
  try{for(const [name,data] of requests)await denied(name,staff,data,'PERMISSION_DENIED',id);}
  finally{await member.update({status:'active'});}
 });
 await t.test('concurrent Owner/Staff archive requests have one winner and one audit',async()=>{
  const created=await ok('createInventoryItem',owner,inventoryData());
  const outcomes=await Promise.all([owner,staff].map(who=>call('setInventoryLifecycle',who,
   {idempotencyKey:randomUUID(),itemId:created.itemId,expectedVersion:1,action:'archive'})));
  assert.equal(outcomes.filter(r=>r.result?.changed).length,1);
  assert.equal(outcomes.filter(r=>r.error?.status==='ABORTED').length,1);
  const state=await itemState(created.itemId);
  assert.equal(state.item.quantity,4);assert.equal(state.item.version,2);
  assert.equal(state.activities.length,2);assert.equal(state.movements.length,1);
 });
 for(const [role,who] of [['Owner',owner],['Staff',staff]]){
  await t.test(`${role} lifecycle commit failure rolls back item and audit together`,async()=>{
   const {setInventoryLifecycle}=require('../src/inventory-lifecycle');
   const created=await ok('createInventoryItem',who,inventoryData());
   const before=await itemState(created.itemId);
   // Inject a failing write precondition into a real Admin transaction, not production code.
   const blocker=db.doc(`test_faults/${randomUUID()}`);await blocker.create({synthetic:true});
   const store={runTransaction:operation=>db.runTransaction(tx=>operation({
    get:async p=>{const d=await tx.get(db.doc(p));return d.exists?d.data():null;},
    update:(p,d)=>tx.update(db.doc(p),d),
    create:(p,d)=>{tx.create(db.doc(p),d);tx.create(blocker,{synthetic:true});},
   }))};
   await assert.rejects(setInventoryLifecycle({auth:{uid:who.user.localId},
    data:{idempotencyKey:randomUUID(),itemId:created.itemId,expectedVersion:1,action:'archive'},store,
    timestamp:()=>FieldValue.serverTimestamp(),deleteValue:()=>FieldValue.delete()}),e=>e.code===6);
   assert.deepEqual(await itemState(created.itemId),before);
  });
 }
 if(TEAM)await require('./menu-emulator.integration')({t,db,call,owner,staff,second,workspace,other});
 await t.test('Rules enforce scoped reads and deny membership/invitation writes and secret reads',async()=>{
  const rules=await initializeTestEnvironment({projectId:PROJECT,firestore:{host:'127.0.0.1',port:FIRESTORE_PORT}});
  t.after(()=>rules.cleanup());
  const staffDb=rules.authenticatedContext(staff.user.localId).firestore();
  const ownerDb=rules.authenticatedContext(owner.user.localId).firestore();
  await assertSucceeds(getDoc(doc(staffDb,`cafes/${workspace.cafeId}`)));
  await assertFails(getDoc(doc(staffDb,`cafes/${other.cafeId}`)));
  await db.doc(`cafes/${workspace.cafeId}/inventory/item`).set({name:'Synthetic'});
  await db.doc(`cafes/${other.cafeId}/inventory/item`).set({name:'Synthetic Other'});
  await assertSucceeds(getDoc(doc(staffDb,`cafes/${workspace.cafeId}/inventory/item`)));
  await assertFails(getDoc(doc(staffDb,`cafes/${other.cafeId}/inventory/item`)));
  await assertFails(setDoc(doc(staffDb,`cafes/${other.cafeId}/inventory/item`),{quantity:999}));
  await assertFails(updateDoc(doc(staffDb,`cafes/${workspace.cafeId}/members/${staff.user.localId}`),{role:'owner'}));
  await assertFails(setDoc(doc(staffDb,`user_cafe_memberships/${staff.user.localId}`),{cafeId:other.cafeId}));
  for(const client of [staffDb,ownerDb]){
   await assertSucceeds(getDoc(doc(client,`cafes/${workspace.cafeId}/inventory/${workflowItems[0]}`)));
   await assertFails(getDoc(doc(client,`cafes/${other.cafeId}/inventory/item`)));
   await assertFails(updateDoc(doc(client,`cafes/${workspace.cafeId}/inventory/${workflowItems[0]}`),{quantity:999}));
   await assertFails(updateDoc(doc(client,`cafes/${other.cafeId}/inventory/item`),{quantity:999}));
   await assertFails(getDoc(doc(client,`workspace_invitations/${invitation.invitationId}`)));
   await assertFails(setDoc(doc(client,'workspace_invitations/forged'),{role:'owner'}));
  }
 });
 await t.test('team callable returns verified same-cafe members with existing staff visibility',async()=>{
  await auth.updateUser(owner.user.localId,{emailVerified:true,displayName:'Synthetic Owner'});
  await owner.refresh();
  const extra=await account(true);
  const link={uid:extra.user.localId,cafeId:workspace.cafeId,status:'active',schemaVersion:1};
  await db.doc(`user_cafe_memberships/${extra.user.localId}`).set(link);
  await db.doc(`cafes/${workspace.cafeId}/members/${extra.user.localId}`).set({...link,role:'staff'});
  const unverified=await account();
  const unverifiedLink={...link,uid:unverified.user.localId};
  await db.doc(`user_cafe_memberships/${unverified.user.localId}`).set(unverifiedLink);
  await db.doc(`cafes/${workspace.cafeId}/members/${unverified.user.localId}`).set({...unverifiedLink,role:'staff'});
  const result=(await call('listTeamMembers',owner,{})).result;
  assert.equal(result.cafeId,workspace.cafeId);
  assert.deepEqual(result.members.map(m=>m.uid).sort(),[owner.user.localId,staff.user.localId,extra.user.localId].sort());
  assert.ok(result.members.every(m=>Object.keys(m).sort().join(',')==='email,name,role,uid'));
  const staffResult=(await call('listTeamMembers',staff,{})).result;
  assert.deepEqual(staffResult.members.map(m=>m.uid).sort(),[owner.user.localId,staff.user.localId].sort());
  assert.equal((await call('listTeamMembers',null,{})).error.status,'UNAUTHENTICATED');
  assert.equal((await call('listTeamMembers',staff,{cafeId:other.cafeId,role:'owner'})).error.status,'INVALID_ARGUMENT');
  assert.equal((await call('listTeamMembers',owner,{})).result.members.length,3);
  await db.doc(`user_cafe_memberships/${staff.user.localId}`).update({status:'revoked'});
  assert.equal((await call('listTeamMembers',staff,{})).error.status,'PERMISSION_DENIED');
  assert.ok(!(await call('listTeamMembers',owner,{})).result.members.some(m=>m.uid===staff.user.localId));
 });
});
