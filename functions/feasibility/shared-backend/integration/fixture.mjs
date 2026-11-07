import {createSimulator} from './rest-simulator.mjs';
import {syntheticIdentity} from './synthetic-identity.mjs';
import {createHttp} from '../adapters/http.mjs';
import {createOAuth} from '../adapters/google-oauth.mjs';
import {createAccounts} from '../adapters/firebase-accounts.mjs';
import {createFirebaseIdentity} from '../adapters/firebase-identity.mjs';
import {workspaceAuthority} from '../adapters/workspace-authority.mjs';
import {createFirestoreStore} from '../adapters/firestore-store.mjs';
import {createWorker} from '../worker.mjs';
import backendModule from '../backend.cjs';
export function fixture() {
  let time=Date.UTC(2026,10,7); const now=()=>time; const identity=syntheticIdentity(now);
  const accounts=Object.fromEntries(['owner','staff','joiner','outsider'].map(uid=>[uid,{localId:uid,email:uid+'@example.test',emailVerified:true,disabled:false,validSince:'0'}]));
  const seed={'cafes/cafe':{ownerUid:'owner',status:'active',schemaVersion:1}};
  for(const uid of ['owner','staff']) {
    const link={uid,cafeId:'cafe',status:'active',schemaVersion:1,membershipGeneration:0};
    seed['user_cafe_memberships/'+uid]=link;seed[`cafes/cafe/members/${uid}`]={...link,role:uid};
  }
  seed['cafes/cafe/inventory/item']={cafeId:'cafe',schemaVersion:1,name:'Rice',category:'Dry',quantity:5,unit:'pcs',version:1,expiryDate:new Date(time+86400000)};
  const simulator=createSimulator({seed,accounts,certificate:identity.certificate,now,onOAuth:identity.verifyAssertion});
  const http=createHttp({transport:simulator.transport,timeoutMs:1000});
  const accessToken=createOAuth({email:'synthetic@velora-spark-test.iam.gserviceaccount.com',sign:identity.sign,http,now});
  const getAccount=createAccounts({http,accessToken});
  const verifyIdentity=createFirebaseIdentity({http,getAccount,now});
  const store=createFirestoreStore({http,accessToken,now,sleep:async()=>{},random:()=>0,attempts:5});
  const calls=[];const secret='INTEGRATION_SECRET_SENTINEL';let mode='valid';
  const transport=async(url,options)=>{
    calls.push({url,body:options.body});if(mode==='timeout')return new Promise(()=>{});if(mode==='throw')throw Error(secret);
    const recipes=mode==='valid'?[{title:'Rice dish',ingredients:[{itemId:'i1',quantity:1,unit:'pcs'}],steps:['Cook rice'],whyRecommended:'Use available rice'}]:[{title:secret}];
    return Response.json({choices:[{finish_reason:'stop',message:{content:JSON.stringify({recipes})}}]});
  };
  const backend=backendModule.createBackend({store,getAccount,transport,getSecret:()=>secret,now,timeoutMs:30});
  const worker=createWorker({verifyIdentity,backend});
  return {simulator,accounts,store,calls,secret,now,mode:v=>{mode=v;},advance:ms=>{time+=ms;},
    authority:(auth,expected)=>store.runTransaction(tx=>workspaceAuthority(tx,auth,expected)),
    call:async(path,data={},uid='owner',claims={})=>{
      const r=await worker.fetch(new Request('https://offline.invalid'+path,{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+identity.token(uid,claims)},body:typeof data==='string'?data:JSON.stringify(data)}));
      return {status:r.status,body:await r.json()};
    }};
}
