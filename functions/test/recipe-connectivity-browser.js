'use strict';
const {spawn}=require('node:child_process');
const {existsSync}=require('node:fs');const path=require('node:path');
const {initializeApp,deleteApp}=require('firebase-admin/app');const {getAuth}=require('firebase-admin/auth');
const {getFirestore,Timestamp}=require('firebase-admin/firestore');
const {CONNECTIVITY_PROJECT:PROJECT,assertConnectivity}=require('../ai1/recipe-service');
async function main(){
  assertConnectivity({...process.env,FUNCTIONS_EMULATOR:'true'});
  const app=initializeApp({projectId:PROJECT},'browser-fixtures');const auth=getAuth(app);const db=getFirestore(app);
  try {
  const cafeId='connectivity-cafe';
  for(const [uid,email,role] of [['connectivity-owner','connectivity-owner@example.test','owner'],
    ['connectivity-staff','connectivity-staff@example.test','staff']]){
    await auth.createUser({uid,email,emailVerified:true,password:'disposable-test-password'});
    const link={uid,cafeId,status:'active',schemaVersion:1};
    await db.doc(`user_cafe_memberships/${uid}`).create(link);
    await db.doc(`cafes/${cafeId}/members/${uid}`).create({...link,role});
  }
  await db.doc(`cafes/${cafeId}`).create({ownerUid:'connectivity-owner',status:'active',schemaVersion:1});
  for(const [id,name] of [['banana','Banana'],['milk','Milk']]){
    await db.doc(`cafes/${cafeId}/inventory/${id}`).create({name,category:'Food',quantity:2,unit:'pcs',version:1,schemaVersion:1,
      createdAt:Timestamp.now(),expiryDate:Timestamp.fromDate(new Date('2099-01-01T00:00:00Z'))});
  }
  if(process.argv.includes('--web-smoke')){
    const before=JSON.stringify((await db.collection(`cafes/${cafeId}/inventory`).get()).docs.map(doc=>[doc.id,doc.data()]));
    await require('./recipe-connectivity-web-smoke').run();
    const after=JSON.stringify((await db.collection(`cafes/${cafeId}/inventory`).get()).docs.map(doc=>[doc.id,doc.data()]));
    if(before!==after)throw Error('Inventory changed');
    console.log('PASS: disposable inventory unchanged after Web smoke.');
    return;
  }
  const flutter=path.join(process.env.USERPROFILE,'flutter/flutter/bin/flutter.bat');
  if(!existsSync(flutter))throw Error('Installed Flutter SDK required.');
  const command=`& '${flutter.replaceAll("'","''")}' test --no-pub --platform chrome --timeout 90s test/recipe_connectivity_emulator_test.dart `+
    '--dart-define=RECIPE_CONNECTIVITY_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true '+
    '--dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --dart-define=RUN_RECIPE_EMULATOR_TEST=true';
  console.log('Starting Flutter SDK fake-only Chrome connectivity verification.');
  const code=await new Promise((resolve,reject)=>{
    const child=spawn('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],{stdio:'inherit',windowsHide:true});
    let timedOut=false;
    // Flutter's test timeout does not cover a stalled browser bootstrap.
    // Terminate only this runner's own process tree, then let emulators:exec
    // shut down its disposable emulators normally.
    const timer=setTimeout(()=>{
      timedOut=true;
      console.error('BLOCKED: Flutter Chrome bootstrap/test exceeded 120 seconds.');
      if(child.pid)spawn('taskkill.exe',['/PID',String(child.pid),'/T','/F'],
        {stdio:'ignore',windowsHide:true}).on('error',()=>{});
    },120000);
    child.on('error',error=>{clearTimeout(timer);reject(error);});
    child.on('exit',code=>{clearTimeout(timer);resolve(timedOut?1:code);});
  });
  process.exitCode=code??1;
  } finally {await deleteApp(app);}
}
main().catch(()=>{console.error('FAIL: Disposable Flutter recipe connectivity test could not complete.');process.exitCode=1;});
