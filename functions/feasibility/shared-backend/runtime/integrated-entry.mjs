// Synthetic scenario controller: never deploy.
import {scenario} from '../integration/scenarios.mjs';
import {syntheticIdentity} from '../integration/synthetic-identity.mjs';
import {X509Certificate} from 'node:crypto';
export default{async fetch(request){
  const {name}=await request.json();
  if(name==='crypto-diagnostic'){
    const stages=[];
    try{const identity=syntheticIdentity(()=>Date.UTC(2026,10,7));stages.push('generated');
      identity.verifyAssertion(new URLSearchParams({assertion:identity.token()}).toString());stages.push('verified');
      const cert=new X509Certificate(identity.certificate);stages.push('parsed');
      cert.publicKey.export({format:'jwk'});stages.push('exported');
      return Response.json({stages});
    }catch{return Response.json({stages,failed:true});}
  }
  if(name==='egress'){
    try{const r=await fetch('https://unexpected.invalid/');return Response.json({blocked:r.status>=500});}
    catch{return Response.json({blocked:true});}
  }
  try{return Response.json(await scenario(name));}
  catch(error){return Response.json({error:String(error.message)},{status:500});}
}};
