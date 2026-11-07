import {fixture} from './fixture.mjs';
import {SERVER_TIME} from '../adapters/firestore-codec.mjs';
function check(condition,message){if(!condition)throw Error(message);}
const expected={expectedCafeId:'cafe',expectedMembershipGeneration:0,maxRecipes:1};
const issue=async f=>{const r=await f.call('/ai/issue',expected);check(r.status===200,'ticket issuance');return r.body.ticketId;};
const generate=(f,ticketId)=>f.call('/ai/generate',{...expected,ticketId});
const invite=async f=>{const r=await f.call('/staff/create',{email:'joiner@example.test',requestId:'request_123456789'});check(r.status===200,'invite issuance');return r.body;};
const writeTo=(path)=>body=>body.writes.some(w=>(w.update?.name??w.delete)?.endsWith('/'+path));
export const names=['authorized AI through REST','identity denials','workspace generation denials','AI concurrent replay',
  'AI quota issuance race','provider uncertainty','Staff admission and removal','Staff invitation revoke and theft',
  'conflict retries','atomic rollback and preconditions','applied lost commit recovery','unresolved receipt outcome',
  'unknown AI dispatch commit','request and response bounds','wire masks and transforms','query fingerprint contention'];
export async function scenario(name){
  const f=fixture(); const results=[]; const logs=[];const previous=console.error;
  console.error=(...args)=>logs.push(args.map(String));
  try {
    switch(name){
      case 'authorized AI through REST': {
        const ticket=await issue(f);const r=await generate(f,ticket);results.push(r);
        check(r.status===200&&r.body.recipes[0].ingredients[0].itemId==='item','scoped recipe');
        check(f.calls.length===1,'single dispatch');check(f.simulator.snapshot()['cafes/cafe/inventory/item'].quantity===5,'stock unchanged');break;
      }
      case 'identity denials': {
        for(const claims of [{exp:1},{aud:'other'},{email_verified:false}])check((await f.call('/ai/issue',expected,'owner',claims)).status===401,'claims denied');
        for(const change of [{disabled:true},{validSince:String(f.now()/1000+1)},{emailVerified:false}]){
          Object.assign(f.accounts.owner,change);check((await f.call('/ai/issue',expected)).status===401,'account denied');
          Object.assign(f.accounts.owner,{disabled:false,validSince:'0',emailVerified:true});
        }check(f.calls.length===0,'no dispatch');break;
      }
      case 'workspace generation denials': {
        for(const data of [{...expected,expectedCafeId:'other'},{...expected,expectedMembershipGeneration:1}])check((await f.call('/ai/issue',data)).status!==200,'workspace denied');
        const auth={uid:'owner',token:{email_verified:true}};check((await f.authority(auth,{expectedCafeId:'cafe',expectedMembershipGeneration:0})).role==='owner','authority adapter');
        await f.store.runTransaction(async tx=>tx.update('cafes/cafe/members/owner',{status:'inactive'}));
        check((await f.call('/ai/issue',expected)).status!==200,'inactive denied');break;
      }
      case 'AI concurrent replay': {
        const t=await issue(f);const r=await Promise.all([generate(f,t),generate(f,t)]);results.push(...r);
        check(r.filter(x=>x.status===200).length===1&&f.calls.length===1,'duplicate dispatch');break;
      }
      case 'AI quota issuance race': {
        const tickets=[];for(let i=0;i<19;i++)tickets.push(await issue(f));
        const r=await Promise.all([f.call('/ai/issue',expected),f.call('/ai/issue',expected)]);
        check(r.filter(x=>x.status===200).length===1,'issuance cap');check(f.simulator.snapshot()['ai_usage_users/owner'].issued===20,'quota atomic');break;
      }
      case 'provider uncertainty': {
        f.mode('timeout');const t=await issue(f);results.push(await generate(f,t),await generate(f,t));
        check(results.every(r=>r.status!==200)&&f.calls.length===1,'no retry');
        check(f.simulator.snapshot()['ai_generation_tickets/'+t].state==='quarantined','quarantine');break;
      }
      case 'Staff admission and removal': {
        const inv=await invite(f);check(!JSON.stringify(f.simulator.snapshot()).includes(inv.code),'private invitation');
        const r=await Promise.all([f.call('/staff/redeem',{code:inv.code},'joiner'),f.call('/staff/redeem',{code:inv.code},'joiner')]);
        check(r.filter(x=>x.status===200).length===1,'single redemption');
        check((await f.call('/staff/list')).status===200,'roster');
        const removal={targetUid:'joiner',expectedCafeId:'cafe',expectedGeneration:0,expectedActorGeneration:0,idempotencyKey:'remove_1234567890'};
        check((await f.call('/staff/remove',removal)).status===200,'remove');
        check((await f.call('/staff/remove',removal)).body.changed===false,'historical replay');
        const state=f.simulator.snapshot();check(state['user_cafe_memberships/joiner'].membershipGeneration===1&&state['cafes/cafe/members/joiner'].status==='inactive','linked removal');
        check((await f.call('/staff/list',{},'joiner')).status===403,'stale session');break;
      }
      case 'Staff invitation revoke and theft': {
        check((await f.call('/staff/create',{email:'joiner@example.test',requestId:'request_123456789'},'staff')).status===403,'owner only');
        const inv=await invite(f);check((await f.call('/staff/redeem',{code:inv.code},'outsider')).status!==200,'email bound');
        check((await f.call('/staff/revoke',{invitationId:inv.invitationId})).status===200,'revoke');
        check((await f.call('/staff/redeem',{code:inv.code},'joiner')).status!==200,'revoked');check(!f.simulator.snapshot()['user_cafe_memberships/joiner'],'no partial membership');break;
      }
      case 'conflict retries': {
        f.simulator.faults.push({type:'conflict',when:writeTo('checks/a')});let count=0;
        await f.store.runTransaction(async tx=>{count++;tx.create('checks/a',{ok:true});});check(count===2,'full callback retried');break;
      }
      case 'atomic rollback and preconditions': {
        await f.store.runTransaction(async tx=>tx.create('checks/existing',{value:1}));
        try{await f.store.runTransaction(async tx=>{tx.create('checks/first',{ok:true});tx.create('checks/existing',{value:2});});throw Error('expected failure');}catch(e){check(e.message!=='expected failure','precondition rejection');}
        check(!f.simulator.snapshot()['checks/first']&&f.simulator.snapshot()['checks/existing'].value===1,'atomic rejection');
        try{await f.store.runTransaction(async tx=>{tx.create('checks/rollback',{ok:true});throw Error('callback');});}catch{}
        check(!f.simulator.snapshot()['checks/rollback'],'rollback');break;
      }
      case 'applied lost commit recovery': {
        f.simulator.faults.push({type:'applied-lost',when:writeTo('receipts/a')});let uncertain=false;
        try{await f.store.runTransaction(async tx=>{tx.create('receipts/a',{uid:'owner'});tx.create('checks/link',{uid:'owner'});});}catch(e){uncertain=e.uncertain;}
        check(uncertain,'unknown commit');
        const recovered=await f.store.recover({receiptPath:'receipts/a',matches:async(r,tx)=>r.uid===(await tx.get('checks/link'))?.uid});
        check(recovered.state==='acknowledged','linked recovery');break;
      }
      case 'unresolved receipt outcome': {
        f.simulator.faults.push({type:'unresolved',when:writeTo('receipts/a')});
        try{await f.store.runTransaction(async tx=>tx.create('receipts/a',{uid:'owner'}));}catch(e){check(e.uncertain,'uncertain');}
        check((await f.store.recover({receiptPath:'receipts/a',matches:()=>true})).state==='unknown','absence is unknown');break;
      }
      case 'unknown AI dispatch commit': {
        const t=await issue(f);
        f.simulator.faults.push({type:'applied-lost',when:body=>body.writes.some(w=>w.update?.fields?.state?.stringValue==='dispatched')});
        check((await generate(f,t)).status!==200&&f.calls.length===0,'no uncertain dispatch');
        check((await generate(f,t)).status!==200&&f.calls.length===0,'no blind retry');
        check(f.simulator.snapshot()['ai_generation_tickets/'+t].state==='quarantined','unknown quarantine');break;
      }
      case 'request and response bounds': {
        check((await f.call('/ai/issue','x'.repeat(2049))).status===413,'request bytes');
        f.simulator.faults.push({type:'oversized'});check((await f.call('/ai/issue',expected)).status!==200,'response bytes');break;
      }
      case 'wire masks and transforms': {
        await f.store.runTransaction(async tx=>tx.create('checks/mask',{a:1,b:2}));
        await f.store.runTransaction(async tx=>{await tx.get('checks/mask');tx.update('checks/mask',{a:3,at:SERVER_TIME});});
        const row=f.simulator.snapshot()['checks/mask'];check(row.a===3&&row.b===2&&row.at.getTime()===f.now(),'masks/transforms');break;
      }
      case 'query fingerprint contention': {
        let first=true;let count=0;
        await f.store.runTransaction(async tx=>{count++;await tx.members('cafe',101);
          if(first){first=false;await f.store.runTransaction(async other=>other.create('cafes/cafe/members/phantom',{uid:'phantom'}));}
          tx.create('checks/query',{ok:true});});check(count===2,'query phantom retry');break;
      }
      default:throw Error('unknown scenario');
    }
    check(!JSON.stringify({results,logs,calls:f.calls}).includes(f.secret),'secret leak');
    const trace=f.simulator.trace;
    if(!['identity denials'].includes(name))check(trace.some(r=>r.method==='beginTransaction'),'actual REST adapter trace');
    return {name,ok:true,providerDispatches:f.calls.length,transactions:trace.filter(r=>r.method==='beginTransaction').length,
      commits:trace.filter(r=>r.method==='commit').length,preconditionWrites:trace.flatMap(r=>r.writes??[]).filter(w=>w.currentDocument).length,
      queries:trace.filter(r=>r.method==='runQuery').length};
  }finally{console.error=previous;}
}
