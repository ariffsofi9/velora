import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {Miniflare,createFetchMock} from 'miniflare';
import {mkdir,readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {names} from '../integration/scenarios.mjs';
let runtime;
const originalCwd=process.cwd();
const rootCache=new URL('../../../../.wrangler/cache/cf.json',import.meta.url);
let cacheBefore;
before(async()=>{
  cacheBefore=await readFile(rootCache).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
  await mkdir(new URL('.tmp/',import.meta.url),{recursive:true});
  const rootPath=fileURLToPath(new URL('.tmp/',import.meta.url));
  process.chdir(rootPath);
  const path=fileURLToPath(new URL('.tmp/integrated-worker.mjs',import.meta.url));
  await build({entryPoints:[fileURLToPath(new URL('integrated-entry.mjs',import.meta.url))],outfile:path,bundle:true,
    format:'esm',platform:'browser',external:['node:*'],banner:{js:'import * as cryptoModule from "node:crypto"; const require = name => { if(name === "node:crypto") return cryptoModule; throw Error("Unexpected module"); };'}});
  const fetchMock=createFetchMock();fetchMock.disableNetConnect();
  runtime=new Miniflare({rootPath,cf:false,cachePersist:false,modules:true,scriptPath:path,compatibilityDate:'2026-06-11',compatibilityFlags:['nodejs_compat'],fetchMock});
  await runtime.ready;
});
after(async()=>{try{await runtime?.dispose();
  const cacheAfter=await readFile(rootCache).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
  assert.deepEqual(cacheAfter,cacheBefore,'repository-root cache must stay untouched');
}finally{process.chdir(originalCwd);}});
test('workerd: legacy direct JWK diagnostic remains unsupported; integrated tests use secure SPKI conversion',async()=>{
  const r=await runtime.dispatchFetch('http://localhost/',{method:'POST',body:JSON.stringify({name:'crypto-diagnostic'})});
  const evidence=await r.json();assert.deepEqual(evidence.stages,['generated','verified','parsed'],JSON.stringify(evidence));
  assert.equal(evidence.failed,true);
});
for(const name of names)test('workerd: '+name,async()=>{
  const response=await runtime.dispatchFetch('http://localhost/',{method:'POST',body:JSON.stringify({name})});
  const evidence=await response.json();assert.equal(response.status,200,JSON.stringify(evidence));assert.equal(evidence.ok,true);
});
test('workerd: outbound network denied',async()=>{
  const r=await runtime.dispatchFetch('http://localhost/',{method:'POST',body:JSON.stringify({name:'egress'})});
  assert.equal((await r.json()).blocked,true);
});
