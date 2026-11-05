'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {CONNECTIVITY_PROJECT,CONNECTIVITY_HOSTS,assertConnectivity,assertIsolated,createRecipeService}=require('../ai1/recipe-service');
const env={GCLOUD_PROJECT:CONNECTIVITY_PROJECT,FUNCTIONS_EMULATOR:'true',...CONNECTIVITY_HOSTS,AI_RECIPE_PROVIDER:'fake'};
test('new profile is exact, explicit and cannot substitute for AI1',()=>{
  assert.doesNotThrow(()=>assertConnectivity(env));
  assert.throws(()=>assertIsolated(env),{code:'failed-precondition'});
  assert.throws(()=>assertConnectivity({...env,GCLOUD_PROJECT:'demo-velora-ai1'}),{code:'failed-precondition'});
});
for(const extra of [{GCLOUD_PROJECT:'velora-73222'},{FUNCTIONS_EMULATOR:'false'},
  {FIRESTORE_EMULATOR_HOST:'localhost:48080'},{FIREBASE_AUTH_EMULATOR_HOST:'127.0.0.1:29099'},
  {AI_RECIPE_PROVIDER:'groq'},{AI_RECIPE_PROVIDER:undefined},{AI2_PROVIDER_PIPE:'anything'},
  {GOOGLE_CLOUD_PROJECT:'other'},{FIREBASE_CONFIG:'invalid'},{FIREBASE_CONFIG:'{"projectId":"other"}'}]){
  test(`reject invalid fake target before I/O: ${Object.keys(extra)[0]}`,async()=>{
    let calls=0;
    const invoke=createRecipeService({isolation:'connectivity',env:{...env,...extra},providerName:'fake',
      provider:async()=>{calls++;},verifyIdentity:async()=>{calls++;},store:{runTransaction:async()=>{calls++;}}});
    await assert.rejects(invoke({auth:{uid:'test-user'},data:{requestId:'request-0000000001'}}),{code:'failed-precondition'});
    assert.equal(calls,0);
  });
}
test('connectivity profile cannot select a live provider or inspect credentials',()=>{
  assert.throws(()=>createRecipeService({isolation:'connectivity',providerName:'groq'}),{code:'failed-precondition'});
  assert.throws(()=>createRecipeService({isolation:'other'}),{code:'failed-precondition'});
  const guarded={...env};Object.defineProperty(guarded,'GROQ_API_KEY',{get(){throw Error('Must not access credentials');}});
  assert.doesNotThrow(()=>assertConnectivity(guarded));
});
