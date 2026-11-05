'use strict';
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const {PROJECT, assertIsolated} = require('../ai1/recipe-service');
const {initializeApp, deleteApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore, Timestamp} = require('firebase-admin/firestore');
async function main() {
  assertIsolated({...process.env, FUNCTIONS_EMULATOR:'true'});
  assert.equal(process.env.AI1_MOCK_RECIPES,'true'); assert.equal(process.env.AI_RECIPE_PROVIDER,'fake');
  const hub = await fetch('http://127.0.0.1:14400/emulators',{signal:AbortSignal.timeout(4000)}).then(r=>r.json());
  for(const [name,port] of [['auth',19099],['firestore',19080],['functions',15001]]) { assert.equal(hub[name].host,'127.0.0.1'); assert.equal(hub[name].port,port); }
  const app = initializeApp({projectId:PROJECT},'ai1-mock-fixtures'), auth = getAuth(app), db = getFirestore(app);
  try {
    const users = [];
    for(const role of ['owner','staff','outsider']) {
      const uid = `ai1-mock-${role}`;
      await auth.createUser({uid,email:`${uid}@example.test`,password:'disposable-test-password',emailVerified:true});
      const response = await fetch('http://127.0.0.1:19099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only', {
        method:'POST',redirect:'error',signal:AbortSignal.timeout(8000),headers:{'Content-Type':'application/json'},
        body:JSON.stringify({email:`${uid}@example.test`,password:'disposable-test-password',returnSecureToken:true})});
      assert.equal(response.status,200); users.push({uid,role,token:(await response.json()).idToken});
    }
    // Exercise the unchanged workspace callable, rather than fabricating Owner links.
    const invoke = async (user, name, data) => {
      const r = await fetch(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/${name}`, {method:'POST',redirect:'error',signal:AbortSignal.timeout(15000),
        headers:{'Content-Type':'application/json',Authorization:`Bearer ${user.token}`},body:JSON.stringify({data})}); return r.json();
    };
    // Exact workspace input is verified separately in the source before execution.
    const owner = users[0], staff = users[1];
    const workspace = await invoke(owner,'createWorkspace',{businessName:'AI1 Mock Cafe',businessType:'cafe',address:'Local fixture',inventoryUnit:'pcs',lowStockAlerts:true,expiryReminders:true,reminderDays:3});
    assert.ok(workspace.result?.cafeId, 'Workspace callable must provision canonical Owner session');
    const cafeId = workspace.result.cafeId;
    console.log('PASS: unchanged createWorkspace callable provisioned Owner membership.');
    const otherWorkspace = await invoke(users[2],'createWorkspace',{businessName:'Other Mock Cafe',businessType:'cafe',address:'Local fixture',inventoryUnit:'pcs',lowStockAlerts:true,expiryReminders:true,reminderDays:3});
    assert.ok(otherWorkspace.result?.cafeId);
    const link = {uid:staff.uid,cafeId,status:'active',schemaVersion:1};
    const batch = db.batch(); batch.create(db.doc(`user_cafe_memberships/${staff.uid}`),link);
    batch.create(db.doc(`cafes/${cafeId}/members/${staff.uid}`),{...link,role:'staff'});
    for(const [id,name,unit] of [['banana','Banana','pcs'],['milk','Milk','L']]) batch.create(db.doc(`cafes/${cafeId}/inventory/${id}`),{
      name,category:'Food',quantity:2,unit,version:1,schemaVersion:1,createdAt:Timestamp.now(),expiryDate:Timestamp.fromDate(new Date('2099-01-01Z'))});
    await batch.commit();
    const snapshot = async () => JSON.stringify((await db.collection(`cafes/${cafeId}/inventory`).get()).docs.map(row=>[row.id,row.data(),row.updateTime]));
    const before = await snapshot();
    for(const user of [owner,staff]) {
      const response = await invoke(user,'suggestMockRecipesV2',{requestId:randomUUID(),maxRecipes:1});
      assert.equal(response.result?.schemaVersion,2); assert.equal(response.result.provider,'groq');
      assert.equal(response.result.recipes[0].title,'Mock Banana Milk Smoothie');
      assert.deepEqual(response.result.recipes[0].ingredients,[{itemId:'banana',quantity:1,unit:'pcs'},{itemId:'milk',quantity:0.25,unit:'L'}]);
    }
    assert.equal((await invoke(users[2],'suggestMockRecipesV2',{requestId:randomUUID()})).result?.status,'no_suggestions');
    assert.equal((await invoke(staff,'suggestMockRecipesV2',{requestId:randomUUID(),cafeId:'other'})).error?.status,'INVALID_ARGUMENT');
    await db.doc(`cafes/${cafeId}/members/${staff.uid}`).update({cafeId:otherWorkspace.result.cafeId});
    assert.equal((await invoke(staff,'suggestMockRecipesV2',{requestId:randomUUID()})).error?.status,'PERMISSION_DENIED');
    await db.doc(`cafes/${cafeId}/members/${staff.uid}`).update({cafeId});
    assert.equal(await snapshot(),before);
    console.log('PASS: workspace provisioning, Owner/Staff mock-v2, cross-cafe isolation/denial, unchanged inventory (7 checks).');
    if(process.argv.includes('--browser')) {
      await require('./recipe-connectivity-web-smoke').run({ai1Mock:true});
      assert.equal(await snapshot(),before);
    }
  } finally { await deleteApp(app); }
}
main().catch(()=>{console.error('FAIL: isolated AI1 mock integration. No raw Auth/provider data logged.');process.exitCode=1;});
