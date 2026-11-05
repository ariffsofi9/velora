'use strict';
// Standalone, bounded test against an already-running verified AI1 mock session.
// Unique fixtures only: no lifecycle management, clears, imports or deletes.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {randomUUID} = require('node:crypto');
const PROJECT = 'demo-velora-ai1';
async function json(url, options = {}) {
  const target = new URL(url);
  assert.equal(target.hostname,'127.0.0.1'); assert.ok(['14400','19099','15001'].includes(target.port));
  const response = await fetch(url,{...options,redirect:'error',signal:AbortSignal.timeout(12000)});
  return {status:response.status,body:await response.json()};
}
function command(pid) {
  assert.ok(Number.isInteger(pid) && pid>0);
  return execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',
    `(Get-CimInstance Win32_Process -Filter 'ProcessId = ${pid}').CommandLine`],
    {encoding:'utf8',windowsHide:true,timeout:5000}).trim();
}
async function main() {
  assert.equal(process.argv.length,2);
  const hub = await json('http://127.0.0.1:14400/');
  const services = (await json('http://127.0.0.1:14400/emulators')).body;
  for(const [name,port] of [['hub',14400],['auth',19099],['firestore',19080],['functions',15001]]) {
    assert.equal(services[name].host,'127.0.0.1'); assert.equal(services[name].port,port);
  }
  const launcher = command(hub.body.pid);
  assert.ok(launcher.includes('run-ai1-mock.js --cli ') && launcher.includes('--config firebase.ai1-mock-emulator.json --project '+PROJECT+' '));
  const firestore = command(services.firestore.pid);
  assert.ok(firestore.includes('--project_id '+PROJECT+' ') && firestore.includes('--host 127.0.0.1 --port 19080 '));
  for(const [name,value] of Object.entries({GCLOUD_PROJECT:PROJECT,GOOGLE_CLOUD_PROJECT:PROJECT,
    FIREBASE_AUTH_EMULATOR_HOST:'127.0.0.1:19099',FIRESTORE_EMULATOR_HOST:'127.0.0.1:19080'})) {
    assert.ok(!process.env[name] || process.env[name]===value); process.env[name]=value;
  }
  for(const name of ['HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy']) delete process.env[name];
  process.env.NO_PROXY='127.0.0.1,localhost';
  console.log('PASS: running AI1 mock project, configuration and exact loopback ports verified before writes.');
  const {initializeApp,deleteApp}=require('firebase-admin/app');
  const {getAuth}=require('firebase-admin/auth');
  const {getFirestore}=require('firebase-admin/firestore');
  const app=initializeApp({projectId:PROJECT},'ai1-invitation-compatibility');
  const auth=getAuth(app), db=getFirestore(app);
  let checks=0, accounts=0;
  async function check(name, action) { await action(); checks++; console.log('PASS: '+name); }
  try {
    async function account(verified=true) {
      const uid='ai1-invite-'+randomUUID(),email=uid+'@example.test';
      await auth.createUser({uid,email,password:'disposable-test-password',emailVerified:verified}); accounts++;
      const user={uid,email};
      user.refresh=async()=>{
        const response=await json('http://127.0.0.1:19099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only',{
          method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password:'disposable-test-password',returnSecureToken:true})});
        assert.equal(response.status,200); user.token=response.body.idToken;
        const token=await auth.verifyIdToken(user.token,true); assert.equal(token.aud,PROJECT); assert.equal(token.uid,uid);
      }; await user.refresh(); return user;
    }
    const owner=await account(),other=await account(),staff=await account(false),wrong=await account();
    async function call(name,user,data) {
      return (await json(`http://127.0.0.1:15001/${PROJECT}/asia-southeast1/${name}`,{
        method:'POST',headers:{'Content-Type':'application/json',...(user?{Authorization:`Bearer ${user.token}`}:{})},body:JSON.stringify({data})})).body;
    }
    const setup={businessName:'Disposable AI1 Invitation Cafe',businessType:'cafe',address:'Local test fixture',inventoryUnit:'pcs',lowStockAlerts:true,expiryReminders:true,reminderDays:3};
    const workspace=(await call('createWorkspace',owner,setup)).result;
    const foreign=(await call('createWorkspace',other,setup)).result;
    assert.ok(workspace?.cafeId && foreign?.cafeId && workspace.cafeId!==foreign.cafeId);
    const issue=async(user=owner)=>call('createStaffInvitation',user,{email:staff.email,requestId:randomUUID()});
    const invite=(await issue()).result;
    await check('Owner creates invitation through unchanged callable',async()=>assert.ok(invite?.code && invite.invitationId));
    await check('unauthenticated caller cannot create invitation',async()=>assert.equal((await issue(null)).error?.status,'UNAUTHENTICATED'));
    await check('other cafe Owner cannot revoke foreign invitation',async()=>assert.equal((await call('revokeStaffInvitation',other,{invitationId:invite.invitationId})).error?.status,'PERMISSION_DENIED'));
    await check('wrong email cannot redeem',async()=>assert.equal((await call('redeemStaffInvitation',wrong,{code:invite.code})).error?.status,'PERMISSION_DENIED'));
    await check('unverified Staff cannot redeem',async()=>assert.equal((await call('redeemStaffInvitation',staff,{code:invite.code})).error?.status,'FAILED_PRECONDITION'));
    await auth.updateUser(staff.uid,{emailVerified:true}); await staff.refresh();
    await check('verified Staff redeems into Owner cafe',async()=>{
      const result=(await call('redeemStaffInvitation',staff,{code:invite.code})).result;
      assert.equal(result?.joined,true); assert.equal(result.cafeId,workspace.cafeId);
    });
    const mappingRef=db.doc(`user_cafe_memberships/${staff.uid}`);
    await check('canonical Staff mapping and membership are active and schema-valid',async()=>{
      const mapping=(await mappingRef.get()).data(),member=(await db.doc(`cafes/${workspace.cafeId}/members/${staff.uid}`).get()).data();
      for(const row of [mapping,member]) { assert.equal(row.uid,staff.uid);assert.equal(row.cafeId,workspace.cafeId);assert.equal(row.status,'active');assert.equal(row.schemaVersion,1); }
      assert.equal(member.role,'staff');
    });
    await check('Staff cannot create invitations',async()=>assert.equal((await issue(staff)).error?.status,'PERMISSION_DENIED'));
    await check('redeemed code cannot replay',async()=>assert.equal((await call('redeemStaffInvitation',staff,{code:invite.code})).error?.status,'FAILED_PRECONDITION'));
    await check('another cafe invitation cannot replace Staff membership',async()=>{
      const before=(await mappingRef.get()).data(),second=(await issue(other)).result;
      assert.ok(second?.code);
      assert.equal((await call('redeemStaffInvitation',staff,{code:second.code})).error?.status,'ALREADY_EXISTS');
      assert.deepEqual((await mappingRef.get()).data(),before);
    });
    await check('Owner/Staff roster is cafe scoped with verified email accounts',async()=>{
      for(const user of [owner,staff]) {
        const result=(await call('listTeamMembers',user,{})).result;
        assert.equal(result?.cafeId,workspace.cafeId);
        assert.deepEqual(result.members.map(member=>member.uid).sort(),[owner.uid,staff.uid].sort());
      }
      const otherTeam=(await call('listTeamMembers',other,{})).result;
      assert.equal(otherTeam.cafeId,foreign.cafeId); assert.equal(otherTeam.members.some(member=>member.uid===staff.uid),false);
    });
    await check('client cafe/role authority overrides are rejected',async()=>{
      assert.equal((await call('createStaffInvitation',owner,{email:staff.email,requestId:randomUUID(),role:'owner'})).error?.status,'INVALID_ARGUMENT');
      assert.equal((await call('redeemStaffInvitation',staff,{code:invite.code,cafeId:foreign.cafeId})).error?.status,'INVALID_ARGUMENT');
    });
    console.log(`PASS: ${checks} AI1 invitation checks. ${accounts} uniquely named disposable Auth fixtures; no existing fixtures changed; emulator remains running.`);
  } catch(_) { console.error(`FAIL: isolated invitation verification; ${accounts} disposable accounts created. No cleanup/deletes attempted.`); process.exitCode=1; }
  finally { await db.terminate(); await deleteApp(app); }
}
const timer=setTimeout(()=>{console.error('BLOCKED: AI1 invitation verification exceeded 90 seconds. No emulator process stopped.');process.exit(1);},90000);
main().then(()=>clearTimeout(timer)).catch(()=>{clearTimeout(timer);console.error('BLOCKED: AI1 target/process verification or local test unavailable. No raw tokens/codes logged.');process.exitCode=1;});
