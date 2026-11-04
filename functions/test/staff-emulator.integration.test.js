'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getAuth}=require('firebase-admin/auth');const {getFirestore,Timestamp}=require('firebase-admin/firestore');
const {initializeTestEnvironment,assertFails,assertSucceeds}=require('@firebase/rules-unit-testing');
const {doc,getDoc,setDoc,updateDoc}=require('firebase/firestore');
const PROJECT=process.env.GCLOUD_PROJECT;
const TEAM=PROJECT==='demo-velora-team';
const AUTH_PORT=TEAM?39099:29099, FIRESTORE_PORT=TEAM?38080:28080, FUNCTIONS_PORT=TEAM?35001:25001;
if(!['demo-velora-staff','demo-velora-team'].includes(PROJECT)||
 process.env.FIRESTORE_EMULATOR_HOST!==`127.0.0.1:${FIRESTORE_PORT}`||
 process.env.FIREBASE_AUTH_EMULATOR_HOST!==`127.0.0.1:${AUTH_PORT}`)throw Error('Disposable staff emulators required.');

test('isolated Owner/Staff invitation workflow and Rules', {timeout:90000},async t=>{
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
 const owner=await account();const second=await account();const staff=await account();const wrong=await account(true);
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
