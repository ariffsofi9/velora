// Independent, bounded Firestore wire simulator. No production codec or network.
const root = 'projects/velora-spark-test/databases/(default)/documents';
function value(v) {
  if (!v || Object.keys(v).length !== 1) throw Error('wire value');
  if ('nullValue' in v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) { const n = Number(v.integerValue); if (!Number.isSafeInteger(n)) throw Error('integer'); return n; }
  if ('doubleValue' in v && Number.isFinite(v.doubleValue)) return v.doubleValue;
  if ('timestampValue' in v) return new Date(v.timestampValue);
  if ('arrayValue' in v) return (v.arrayValue.values ?? []).map(value);
  if ('mapValue' in v) return fields(v.mapValue.fields ?? {});
  throw Error('unsupported wire value');
}
function fields(f) { return Object.fromEntries(Object.entries(f).map(([k,v]) => [k,value(v)])); }
function wire(v) {
  if (v === null) return {nullValue:null};
  if (v instanceof Date) return {timestampValue:v.toISOString()};
  if (Array.isArray(v)) return {arrayValue:{values:v.map(wire)}};
  if (typeof v === 'string') return {stringValue:v};
  if (typeof v === 'boolean') return {booleanValue:v};
  if (typeof v === 'number') return Number.isInteger(v) ? {integerValue:String(v)} : {doubleValue:v};
  return {mapValue:{fields:wireFields(v)}};
}
function wireFields(v) { return Object.fromEntries(Object.entries(v).map(([k,v])=>[k,wire(v)])); }
function unquote(p) {
  if (!/^`(?:[^`\\]|\\[\\`])+`$/.test(p)) throw Error('field mask');
  return p.slice(1,-1).replace(/\\([\\`])/g,'$1');
}
export function createSimulator({seed, accounts, certificate, now, onOAuth}) {
  let records = new Map(Object.entries(structuredClone(seed)).map(([p,data]) => [root+'/'+p,{data,rev:1}]));
  let revision=1, sequence=0; const transactions=new Map(); const trace=[]; const faults=[];
  const response = (status,data) => Response.json(data,{status});
  const error = (status,code) => response(status,{error:{status:code}});
  const collection = (map,prefix,limit) => [...map].filter(([p])=>p.startsWith(prefix)&&!p.slice(prefix.length).includes('/')).sort(([a],[b])=>a.localeCompare(b)).slice(0,limit);
  const fingerprint = (map,prefix,limit) => JSON.stringify(collection(map,prefix,limit).map(([p,r])=>[p,r.rev]));
  function path(full) {
    if (typeof full !== 'string'||!full.startsWith(root+'/')||full.slice(root.length+1).split('/').some(x=>!x||x==='..')) throw Error('name');
    return full;
  }
  return {trace, faults,
    snapshot:()=>Object.fromEntries([...records].map(([p,r])=>[p.slice(root.length+1),structuredClone(r.data)])),
    async transport(url,options) {
      if(options.method!=='POST' && !url.includes('/metadata/x509/')) throw Error('unexpected method');
      if(url==='https://oauth2.googleapis.com/token') { onOAuth?.(options.body); return response(200,{access_token:'synthetic-access',token_type:'Bearer',expires_in:3600}); }
      if(url==='https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com') return new Response(JSON.stringify({synthetic:certificate}),{headers:{'cache-control':'max-age=3600'}});
      if(options.headers?.authorization!=='Bearer synthetic-access') throw Error('unauthorized simulator transport');
      const body=JSON.parse(options.body);
      if(url==='https://identitytoolkit.googleapis.com/v1/projects/velora-spark-test/accounts:lookup') return response(200,{users:body.localId.flatMap(uid=>accounts[uid]?[accounts[uid]]:[])});
      if(!url.startsWith('https://firestore.googleapis.com/v1/'+root)) throw Error('unexpected endpoint');
      const method=url.slice(url.lastIndexOf(':')+1);
      trace.push({method,transaction:body.transaction??null,writes:body.writes?structuredClone(body.writes):undefined});
      if(method==='beginTransaction') {
        const id='tx-'+(++sequence); transactions.set(id,{snapshot:structuredClone(records),reads:new Map(),queries:[],created:now()});
        return response(200,{transaction:id});
      }
      const tx=transactions.get(body.transaction);
      if(!tx||now()-tx.created>60000) return error(409,'ABORTED');
      if(method==='rollback') { transactions.delete(body.transaction); return response(200,{}); }
      if(method==='batchGet') return response(200,body.documents.map(p=>{
        path(p); const r=tx.snapshot.get(p); tx.reads.set(p,r?.rev??0);
        return r?{found:{name:p,fields:wireFields(r.data)}}:{missing:p};
      }));
      if(method==='runQuery') {
        const q=body.structuredQuery;
        if(!['inventory','members'].includes(q.from?.[0]?.collectionId)||q.from.length!==1||q.from[0].allDescendants||!Number.isInteger(q.limit)||q.limit<1||q.limit>101) return error(400,'INVALID_ARGUMENT');
        const parent=decodeURIComponent(url.slice(('https://firestore.googleapis.com/v1/').length,url.lastIndexOf(':')));
        const prefix=path(parent)+'/'+q.from[0].collectionId+'/';
        tx.queries.push({prefix,limit:q.limit,fingerprint:fingerprint(tx.snapshot,prefix,q.limit)});
        return response(200,collection(tx.snapshot,prefix,q.limit).map(([p,r])=>({document:{name:p,fields:wireFields(r.data)}})));
      }
      if(method!=='commit') throw Error('unexpected RPC');
      const faultIndex=faults.findIndex(f=>!f.when||f.when(body));
      const fault=faultIndex<0?null:faults.splice(faultIndex,1)[0];
      if(fault?.type==='conflict') return error(409,'ABORTED');
      if(fault?.type==='reject') return error(400,'FAILED_PRECONDITION');
      if(fault?.type==='unresolved') throw Error('synthetic unresolved commit');
      if(fault?.type==='unavailable') return error(503,'UNAVAILABLE');
      if(fault?.type==='malformed') return new Response('{');
      if(fault?.type==='oversized') return new Response('x'.repeat(270000));
      if([...tx.reads].some(([p,v])=>(records.get(p)?.rev??0)!==v)||tx.queries.some(q=>fingerprint(records,q.prefix,q.limit)!==q.fingerprint)) return error(409,'ABORTED');
      const draft=structuredClone(records);
      try {
        for(const w of body.writes) {
          const p=path(w.update?.name??w.delete); const prior=draft.get(p);
          if(typeof w.currentDocument?.exists!=='boolean'||Boolean(prior)!==w.currentDocument.exists) throw Error('precondition');
          if(w.delete) { draft.delete(p); continue; }
          const decoded=fields(w.update.fields); let data;
          if(w.updateMask) {
            if(!prior) throw Error('missing update'); data=structuredClone(prior.data);
            for(const mask of w.updateMask.fieldPaths) { const key=unquote(mask); if(Object.hasOwn(decoded,key)) data[key]=decoded[key]; else delete data[key]; }
          } else data=decoded;
          for(const transform of w.updateTransforms??[]) {
            if(transform.setToServerValue!=='REQUEST_TIME') throw Error('transform'); data[unquote(transform.fieldPath)]=new Date(now());
          }
          draft.set(p,{data,rev:revision+1});
        }
      } catch { return error(400,'FAILED_PRECONDITION'); }
      records=draft; revision++; transactions.delete(body.transaction);
      if(fault?.type==='applied-lost') throw Error('synthetic response lost');
      return response(200,{commitTime:new Date(now()).toISOString(),writeResults:body.writes.map(()=>({updateTime:new Date(now()).toISOString()}))});
    },
  };
}
