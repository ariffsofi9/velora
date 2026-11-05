'use strict';
const {onCall,HttpsError}=require('firebase-functions/v2/https');
const {initializeApp}=require('firebase-admin/app');
const {getAuth}=require('firebase-admin/auth');
const {getFirestore}=require('firebase-admin/firestore');
const {CONNECTIVITY_PROJECT:PROJECT,assertConnectivity,createRecipeService,RecipeError}=require('../ai1/recipe-service');
const {fakeProvider}=require('../ai1/fake-provider');
// No Groq adapter, provider selection, relay or key access exists in this source.
let service,auth;
function localService(){
  assertConnectivity();
  if(!service){
    const app=initializeApp({projectId:PROJECT},'fake-recipe-connectivity');
    const db=getFirestore(app);auth=getAuth(app);
    service=createRecipeService({isolation:'connectivity',providerName:'fake',provider:fakeProvider,
      verifyIdentity:async uid=>{const user=await auth.getUser(uid);
        if(user.disabled)throw new RecipeError('unauthenticated','Disposable identity disabled.');},
      store:{runTransaction:operation=>db.runTransaction(async tx=>operation({
        get:async path=>{const row=await tx.get(db.doc(path));return row.exists?row.data():null;},
        inventory:async(path,limit)=>{
          const rows=await tx.get(db.collection(path).limit(limit));
          return rows.docs.map(row=>({id:row.id,data:row.data()}));
        },
      }),{readOnly:true})},
    });
  }
  return service;
}
exports.suggestRecipes=onCall({region:'asia-southeast1',timeoutSeconds:30,maxInstances:1,
  cors:[/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/]},async request=>{
  try{
    const invoke=localService();
    const header=request.rawRequest.headers.authorization;
    if(!request.auth||typeof header!=='string'||!header.startsWith('Bearer '))
      throw new RecipeError('unauthenticated','Authentication required.');
    const token=await auth.verifyIdToken(header.slice(7));
    if(token.uid!==request.auth.uid||token.aud!==PROJECT||token.iss!==`https://securetoken.google.com/${PROJECT}`)
      throw new RecipeError('unauthenticated','Invalid disposable identity.');
    return await invoke({auth:{uid:token.uid},data:request.data});
  }catch(error){
    if(error instanceof RecipeError)throw new HttpsError(error.code,error.message);
    throw new HttpsError('unavailable','Fake recipe request could not be completed.');
  }
});
