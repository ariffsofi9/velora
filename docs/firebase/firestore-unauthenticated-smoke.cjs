"use strict";
// Explicitly approved production execution only. Default invocation is local preview.
const https = require('node:https');
const targets = Object.freeze([
  'https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/users/velora-rules-smoke-profile-20261106-no-fixture',
  'https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/cafes/velora-rules-smoke-cafe-20261106-no-fixture',
]);
function validDocumentId(value) {
  return typeof value === 'string' && value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= 1500 && !value.includes('/') &&
    value !== '.' && value !== '..' && !/^__.*__$/s.test(value);
}
function sanitizedMessage(message) {
  if (typeof message !== 'string') return {category:'missing', text:'No error message available.'};
  if (message === 'Missing or insufficient permissions.') return {category:'rules-denial', text:message};
  if (/reserved/i.test(message)) return {category:'reserved-identifier', text:'The server rejected a reserved identifier.'};
  if (/document.*(invalid|malformed)|(invalid|malformed).*document/i.test(message)) return {category:'invalid-document-path', text:'The server rejected the document path or identifier.'};
  if (/database.*(invalid|malformed)|(invalid|malformed).*database/i.test(message)) return {category:'invalid-database-path', text:'The server rejected the database path.'};
  if (/api key/i.test(message)) return {category:'api-key', text:'The server reported an API-key prerequisite or validation error.'};
  if (/credential|authentication/i.test(message)) return {category:'authentication', text:'The server reported an authentication prerequisite.'};
  return {category:'redacted', text:'Unrecognized server error message redacted.'};
}
function validateTarget(target) {
  const url = new URL(target);
  if (url.protocol !== 'https:' || url.hostname !== 'firestore.googleapis.com' ||
      !targets.includes(target) || url.search || url.username || url.password) {
    throw Error('Target validation failed');
  }
  const parts = url.pathname.split('/');
  if (parts.length !== 9 || parts[3] !== 'velora-73222' || parts[5] !== '(default)' ||
      !['users','cafes'].includes(parts[7]) || !validDocumentId(decodeURIComponent(parts[8]))) {
    throw Error('Invalid document target');
  }
  return url;
}
function getOnce(target, request = https.request) {
  const url = validateTarget(target);
  return new Promise(resolve => {
    let settled = false, size = 0, data = '';
    const done = value => { if (!settled) { settled = true; resolve(value); } };
    const req = request(url, {
      method: 'GET', agent: false, headers: {Accept: 'application/json'},
      // No Auth/CLI/Admin imports, tokens, cookies, API keys, redirects or retries.
    }, res => {
      res.setEncoding('utf8');
      res.on('data', chunk => {
        size += Buffer.byteLength(chunk);
        if (size > 8192) { done({target, result:'INCONCLUSIVE', httpStatus:res.statusCode, reason:'response-cap'}); req.destroy(); return; }
        // Never retain a successful document body.
        if (res.statusCode !== 200) data += chunk;
      });
      res.on('error', () => done({target,result:'INCONCLUSIVE',reason:'response-error'}));
      res.on('end', () => {
        let error;
        try { error = JSON.parse(data).error; } catch (_) {}
        const allowedCodes = new Set(['PERMISSION_DENIED','INVALID_ARGUMENT','NOT_FOUND','UNAUTHENTICATED','FAILED_PRECONDITION','UNAVAILABLE','DEADLINE_EXCEEDED','INTERNAL','RESOURCE_EXHAUSTED']);
        const code = allowedCodes.has(error?.status) ? error.status : null;
        const reasons = (Array.isArray(error?.details)?error.details:[])
          .map(d=>d.reason).filter(r=>typeof r==='string').map(r=>
            ['SERVICE_DISABLED','API_KEY_INVALID','API_KEY_SERVICE_BLOCKED','ACCESS_TOKEN_EXPIRED','IAM_PERMISSION_DENIED','CONSUMER_INVALID'].includes(r) ? r : 'OTHER_REASON_REDACTED').slice(0,8);
        const safeMessage = sanitizedMessage(error?.message);
        const rulesMessage = safeMessage.category === 'rules-denial';
        const pass = res.statusCode===403 && code==='PERMISSION_DENIED' && rulesMessage && reasons.length===0;
        done({target,authentication:'none',method:'GET',httpStatus:res.statusCode,
          firebaseErrorCode:code,errorReasons:reasons,sanitizedMessage:safeMessage.text,messageCategory:safeMessage.category,standardFirestoreDenialMessage:rulesMessage,
          result:pass?'PASS':res.statusCode===200?'FAIL':'INCONCLUSIVE'});
      });
    });
    req.setTimeout(10000, () => {done({target,result:'INCONCLUSIVE',reason:'timeout'});req.destroy();});
    req.on('error', () => done({target,result:'INCONCLUSIVE',reason:'network-error'}));
    req.end();
  });
}
async function run(request = https.request) {
  const results=[];
  for (const target of targets) {
    const result=await getOnce(target, request);results.push(result);
    if(result.result!=='PASS')break;
  }
  return {project:'velora-73222',authentication:'none',requests:results.length,retries:0,results};
}
async function selfTest() {
  const assert = require('node:assert/strict');
  const {EventEmitter} = require('node:events');
  let checks = 0;
  for (const target of targets) { validateTarget(target); checks++; }
  for (const id of ['', '.', '..', '__old_reserved__', 'a/b', 'a'.repeat(1501)]) {assert.equal(validDocumentId(id),false); checks++;}
  assert.equal(validDocumentId('velora-rules-smoke-profile-20261106-no-fixture'),true);checks++;
  assert.throws(()=>validateTarget(targets[0]+'?key=secret'));checks++;
  assert.throws(()=>validateTarget(targets[0].replace('velora-73222','other')));checks++;
  const secret='private@example.test Bearer secret-token document-secret';
  assert.equal(JSON.stringify(sanitizedMessage(secret)).includes(secret),false);checks++;
  assert.equal(sanitizedMessage('Resource id private-secret is invalid because it is reserved.').category,'reserved-identifier');checks++;
  function mock(status, code, message) {
    let calls=0;
    const request=(url, options, callback)=>{
      calls++;
      assert.equal(options.method,'GET'); assert.equal(options.agent,false);
      assert.deepEqual(options.headers,{Accept:'application/json'});
      const req=new EventEmitter();req.setTimeout=()=>{};req.destroy=()=>{};
      req.end=()=>queueMicrotask(()=>{
        const res=new EventEmitter();res.statusCode=status;res.setEncoding=()=>{};
        callback(res);
        res.emit('data',JSON.stringify(status===200?{fields:{secret}}:{error:{status:code,message}}));
        res.emit('end');
      });
      return req;
    };
    return {request,count:()=>calls};
  }
  const denied=mock(403,'PERMISSION_DENIED','Missing or insufficient permissions.');
  const good=await run(denied.request);assert.equal(good.requests,2);assert.equal(denied.count(),2);assert.ok(good.results.every(r=>r.result==='PASS'));checks++;
  for (const [status,code] of [[400,'INVALID_ARGUMENT'],[404,'NOT_FOUND'],[302,'REDIRECT'],[200,null]]) {
    const m=mock(status,code,secret);const result=await run(m.request);
    assert.equal(m.count(),1);assert.equal(result.requests,1);assert.notEqual(result.results[0].result,'PASS');
    assert.equal(JSON.stringify(result).includes(secret),false);checks++;
  }
  const failed=(url,options,cb)=>{const req=new EventEmitter();req.setTimeout=()=>{};req.destroy=()=>{};req.end=()=>queueMicrotask(()=>req.emit('error',Error(secret)));return req;};
  const network=await run(failed);assert.equal(network.requests,1);assert.equal(network.results[0].reason,'network-error');checks++;
  console.log(JSON.stringify({mode:'OFFLINE_SELF_TEST',assertionGroups:checks,networkRequests:0,result:'PASS'}));
}
module.exports = {targets, validDocumentId, validateTarget, sanitizedMessage, getOnce, run};
if (require.main === module) {
  (async()=>{
    if (process.argv.length===3 && process.argv[2]==='--self-test') return selfTest();
    if (process.argv.length!==3 || process.argv[2]!=='--execute-approved') {
      targets.forEach(validateTarget);
      console.log(JSON.stringify({mode:'LOCAL_PREVIEW_NO_NETWORK',project:'velora-73222',authentication:'none',method:'GET',maximumRequests:2,retries:0,targets}));
      return;
    }
    const result=await run();console.log(JSON.stringify(result));
    if(result.requests!==2 || result.results.some(r=>r.result!=='PASS'))process.exitCode=1;
  })().catch(()=>{console.error('Harness stopped; internal error details redacted.');process.exitCode=1;});
}
