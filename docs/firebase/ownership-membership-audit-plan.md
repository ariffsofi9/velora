# Bounded ownership and membership integrity audit approval package

Prepared 2026-11-06 (Asia/Kuala_Lumpur). Status: APPROVED BOUNDED AUDIT COMPLETED.
Historical preparation statements below describe the pre-approval stage; actual
results and coverage appear in the final section.
No prior approval for Rules inspection or compilation authorizes these reads.
This deliberately smaller initial scope supersedes the larger proposed budget in
firestore-emergency-remediation-review.md for this particular approval request.

## Exact approval scope

Project `velora-73222`, database `(default)` only. Existing Firebase CLI global
account fingerprint (SHA-256 of normalized account email):
`92bb9acf57b8a718ff7829e761c018feec99801d96d9b5737110e45a607ac2f4`.
No account switch/login/new credentials. Stop if the fingerprint changes.
Use authenticated Firestore REST through the existing installed CLI API client;
no Firebase Admin initialization, application launch or callable invocation.

Projected fields only:
- `/cafes/{cafeId}`: ownerUid, status, schemaVersion; document ID.
- `/user_cafe_memberships/{uid}`: uid, cafeId, status, schemaVersion,
  membershipGeneration; document ID.
- `/cafes/{cafeId}/members/{uid}`: uid, cafeId, role, status, schemaVersion,
  membershipGeneration; document ID.

Initial queries: one page of at most 10 cafes and one page of at most 10 canonical
mappings, ordered by document name. For each of those cafes, one member query of
at most 5 records, with a GLOBAL total of at most 20 returned member records.
No pagination beyond these approved first pages. Reaching a page limit means
coverage is incomplete, never that the collection has exactly that size.

Then at most 10 projected individual GETs to resolve missing references from those
results, only cafe, canonical or member paths within the path families above.
No new cafe member enumeration from references. At most 22 document API requests
(2 root queries + at most 10 member queries + at most 10 GETs); at most 50 document
results (10 + 10 + 20 + 10). Missing GETs count against the request budget.
Actual sizes are unknown. Stop on limit, target mismatch, unexpected path/response,
permission error, malformed identifier or unexpected field; never expand scope.

Required existing IAM: datastore.entities.get and datastore.entities.list (or an
existing role supplying these). No request to grant privileges. IAM is not verified
by this plan. OAuth token refresh, if needed, uses existing CLI authentication only.

UIDs and document IDs are pseudonymous personal data; processing them in memory is
necessary to join records. Projection excludes names, emails, phone numbers, profile,
inventory/menu data, receipts and activities. REST returns record names/timestamps;
do not print or persist them. Output only aggregates, coverage and randomly salted
hashed references. Do not log API response bodies, raw errors, credentials or headers.
No raw production data files or exports. Ordinary Firestore query/document read
charges may apply, including minimum charges for empty queries and applicable index
entry reads; 50 returned records is not a guaranteed billing ceiling.

Only runQuery (read-only despite HTTP POST) and masked document GET are permitted.
No transaction begin/commit, writes/deletes, Rules/API/IAM/billing modifications,
Functions, staging access or deployment. No production requests before Option 2.

## Read request templates

```text
POST https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents:runQuery
{structuredQuery:{from:[{collectionId:"cafes"}],select:{fields:[{fieldPath:"ownerUid"},{fieldPath:"status"},{fieldPath:"schemaVersion"}]},orderBy:[{field:{fieldPath:"__name__"},direction:"ASCENDING"}],limit:10}}

POST https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents:runQuery
{structuredQuery:{from:[{collectionId:"user_cafe_memberships"}],select:{fields:[{fieldPath:"uid"},{fieldPath:"cafeId"},{fieldPath:"status"},{fieldPath:"schemaVersion"},{fieldPath:"membershipGeneration"}]},orderBy:[{field:{fieldPath:"__name__"},direction:"ASCENDING"}],limit:10}}

POST https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/cafes/{approvedCafeId}:runQuery
{structuredQuery:{from:[{collectionId:"members"}],select:{fields:[{fieldPath:"uid"},{fieldPath:"cafeId"},{fieldPath:"role"},{fieldPath:"status"},{fieldPath:"schemaVersion"},{fieldPath:"membershipGeneration"}]},orderBy:[{field:{fieldPath:"__name__"},direction:"ASCENDING"}],limit:<min(5,20-memberResultsSoFar)>}}

GET https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/{approvedAuthorityPath}?mask.fieldPaths=<each permitted field for that record category>
```

Use only IDs derived from bounded results, validate IDs before path interpolation
and URL-encode each segment. Missing references are UNKNOWN until an approved GET
returns 404. Missing records outside the cap remain NOT VERIFIED. A query with zero
remaining budget must not be issued. No retrieval of unrelated profile information.

## Reviewable execution design before approval

No executable production script has been run or added. Execute read requests
individually using the templates and inspected existing CLI REST client; maintain
request/result counters and joins in process memory, not a disk dump. If automation
is needed beyond these request templates, prepare and review its exact script
before any document request; this approval does not authorize extra operations.
Do not execute a deploy/import/export or generic write-capable tool command as a
shortcut. Only GET and the explicitly read-only runQuery POST are allowed.

## Invariants and finding classification

- Cafe active/schema 1, safe Owner reference; exactly one active Owner in observed
  membership records, consistent with cafe.ownerUid, canonical and Owner member.
- Canonical ID == uid, member ID == uid, path cafe == cafeId; schema 1 and known
  active/inactive state. Contradictory statuses are flagged, not normalized.
- Staff cannot be Owner of that cafe or hold a second observed active membership.
  An Owner cannot be observed as Staff elsewhere; multiple cafe Owner references
  for one account are a single-workspace violation.
- Matching active generation pairs: both fields absent means legacy 0; otherwise
  both bounded nonnegative safe integers with equal values. Partial/malformed,
  negative, fractional, overflow and mismatched generations fail closed.
- Parse Firestore integer strings without unsafe Number coercion before range
  checking; distinguish absent fields, null, integers and double values.
- Inactive history is retained; do not silently reactivate or label it malformed
  solely for being inactive. Owner removal/rejoin is not an approved transition.
- Orphan reference is confirmed only by 404 or proven contradictory returned data.
  Non-enumerated pages, missing parents and member-only subcollections can be missed.

Each finding: severity, category, salted reference, expected invariant, observed
contradiction, confidence, proposed next investigation/remediation. No repairs.
Confirmed contradictory active authority may be FAIL - CRITICAL; merely malformed
or unusual records need accurate confidence and availability-vs-access analysis.
No inconsistency observed is PASS WITH LIMITATIONS, not a clean-database guarantee.
Insufficient references/approval/access means INCONCLUSIVE or BLOCKED.

## Limits and remaining gates

Small first-page sampling is biased and cannot establish global uniqueness or find
all orphaned/deleted-parent subcollections. A read-only audit does not freeze data:
permissive Rules can permit mutations during/after inspection. Cross-request races
can produce apparent contradictions; mark them provisional without unapproved retries.
Even a consistent graph may be forged. Provenance/backups/Auth inspection require
separate approval; do not label records malicious without evidence.

Admin/IAM-authenticated REST bypasses client Rules and cannot prove Rules B runtime
behavior. Prior compiler PASS and prior 367 backend/94 Flutter tests are not rerun
by this preparation. No runtime Rules evaluation or production metadata readback.

## Approval and current result

Option 1 - Keep audit local-only.
Option 2 - Approve ONLY the exact bounded read-only production audit above.
Without explicit Option 2, STOP before any document request. Do not interpret elapsed
time or a tool escalation approval as approval to expand this scope.

Local authority schema review completed; current production project/resource
identity NOT VERIFIED (target fixed in request templates only); production reads,
ownership/canonical/member/generation consistency and audit coverage NOT RUN.
Schema/local Rules/cloud Rules/documents unchanged. Writes/deployment NONE.
No Rules B deployment, source changes, credentials change or Git save authorized.

## Reviewed bounded execution script (prepared after Option 2, before requests)

The following source is stored without production data. Only the allowlisted query
POSTs and masked GETs are issued; retries are disabled. Raw API logs are suppressed.

```javascript
// Reviewed read-only audit. No production record or credential is written to disk.
const fs = require('node:fs');
const crypto = require('node:crypto');
const root = 'C:/Users/23000/AppData/Roaming/npm/node_modules/firebase-tools/lib/';
const project = 'velora-73222';
const base = `projects/${project}/databases/(default)/documents`;
const expectedIdentity = '92bb9acf57b8a718ff7829e761c018feec99801d96d9b5737110e45a607ac2f4';
const fields = {
  cafe: ['ownerUid','status','schemaVersion'],
  mapping: ['uid','cafeId','status','schemaVersion','membershipGeneration'],
  member: ['uid','cafeId','role','status','schemaVersion','membershipGeneration'],
};
const salt = crypto.randomBytes(32);
const ref = path => crypto.createHmac('sha256', salt).update(path).digest('hex').slice(0,20);
const records = new Map(), missing = new Set(), findings = [], coverage = [];
let requests = 0, returned = 0, memberReturned = 0, referenceGets = 0;
let client;
const safeId = v => typeof v === 'string' && v.length > 0 && v.length <= 128 &&
  v.trim() === v && !['.','..'].includes(v) && !v.includes('/') && !v.includes(String.fromCharCode(92)) && !/\p{Cc}/u.test(v);
function category(path) {
  const p = path.split('/');
  if (p.length === 2 && p[0] === 'cafes' && safeId(p[1])) return 'cafe';
  if (p.length === 2 && p[0] === 'user_cafe_memberships' && safeId(p[1])) return 'mapping';
  if (p.length === 4 && p[0] === 'cafes' && p[2] === 'members' && safeId(p[1]) && safeId(p[3])) return 'member';
  throw Error('UNEXPECTED_PATH_STOP');
}
const text = (d,k) => d.fields?.[k]?.stringValue;
const eqInt = (d,k,n) => d.fields?.[k]?.integerValue === String(n);
function addFinding(path,code,severity='REVIEW',confidence='high') {
  findings.push({reference:ref(path),category:category(path),code,severity,confidence});
}
function accept(doc) {
  if (!doc?.name?.startsWith(base + '/')) throw Error('TARGET_MISMATCH_STOP');
  const path = doc.name.slice(base.length+1), kind = category(path);
  if (Object.keys(doc.fields??{}).some(k=>!fields[kind].includes(k))) throw Error('UNEXPECTED_FIELDS_STOP');
  if (++returned > 50) throw Error('DOCUMENT_CAP_STOP');
  records.set(path,doc);
  for (const k of ['uid','cafeId','ownerUid']) {
    if (doc.fields?.[k] && !safeId(text(doc,k))) throw Error('MALFORMED_IDENTIFIER_STOP');
  }
  return path;
}
function generation(d) {
  if (!Object.hasOwn(d.fields??{},'membershipGeneration')) return {absent:true};
  const v=d.fields.membershipGeneration.integerValue;
  if (typeof v!=='string' || !/^(0|[1-9][0-9]*)$/.test(v)) return {invalid:true};
  const n=BigInt(v);
  return n<=9007199254740991n ? {value:v} : {invalid:true};
}
function generationMatch(a,b) {
  const x=generation(a),y=generation(b);
  return !x.invalid && !y.invalid && ((x.absent&&y.absent) || (!x.absent&&!y.absent&&x.value===y.value));
}
function requestBudget() {if(project!=='velora-73222'||++requests>22)throw Error('REQUEST_CAP_OR_TARGET_STOP');}
async function query(parent,collection,kind,limit) {
  if(limit<=0) return [];
  const expectedParent=parent ? `cafes/${parent}` : '';
  if(parent && !safeId(parent))throw Error('MALFORMED_IDENTIFIER_STOP');
  if(!((!parent&&collection==='cafes'&&kind==='cafe')||(!parent&&collection==='user_cafe_memberships'&&kind==='mapping')||(parent&&collection==='members'&&kind==='member')))throw Error('QUERY_SCOPE_STOP');
  requestBudget();
  const parentPath=parent?`${base}/cafes/${encodeURIComponent(parent)}`:base;
  const response=await client.post('/'+parentPath+':runQuery',{structuredQuery:{
    from:[{collectionId:collection}],select:{fields:fields[kind].map(fieldPath=>({fieldPath}))},
    orderBy:[{field:{fieldPath:'__name__'},direction:'ASCENDING'}],limit,
  }},{retries:0,skipLog:{body:true,resBody:true,queryParams:true}});
  if(!Array.isArray(response.body))throw Error('UNEXPECTED_RESPONSE_STOP');
  const docs=response.body.filter(row=>row.document).map(row=>row.document);
  if(docs.length>limit)throw Error('QUERY_LIMIT_STOP');
  const paths=[];
  for(const doc of docs) {
    const path=doc.name?.slice(base.length+1);
    const parts=path?.split('/');
    if(!(kind==='member'?parts?.length===4&&parts[1]===parent&&parts[2]==='members':parts?.length===2&&parts[0]===collection)) throw Error('QUERY_SCOPE_STOP');
    paths.push(accept(doc));
  }
  if(kind==='member')memberReturned+=docs.length;
  coverage.push({category:kind,parent:parent?ref(expectedParent):'root',returned:docs.length,limit,possiblyTruncated:docs.length===limit});
  return paths;
}
async function getReference(path) {
  if(records.has(path)||missing.has(path))return;
  if(referenceGets>=10)return;
  const kind=category(path);
  referenceGets++;requestBudget();
  try {
    const encoded=path.split('/').map(encodeURIComponent).join('/');
    const r=await client.get('/'+base+'/'+encoded,{queryParams:{'mask.fieldPaths':fields[kind]},retries:0,skipLog:{resBody:true,queryParams:true}});
    if(r.body?.name!==base+'/'+path)throw Error('TARGET_MISMATCH_STOP');
    accept(r.body);
  } catch(e) {
    const status=e.status??e.context?.response?.status??e.context?.response?.statusCode;
    if(status===404){missing.add(path);return;}
    throw e;
  }
}
function inspect() {
  const need = path => {
    if(records.has(path))return records.get(path);
    addFinding(path,missing.has(path)?'REFERENCED_RECORD_MISSING':'REFERENCE_NOT_VERIFIED',missing.has(path)?'INCONSISTENT':'UNKNOWN');
    return null;
  };
  const activeByUid=new Map(), ownedByUid=new Map();
  for(const [path,d] of records) {
    const kind=category(path),p=path.split('/'),status=text(d,'status');
    if(!eqInt(d,'schemaVersion',1))addFinding(path,'INVALID_SCHEMA');
    if(!['active','inactive'].includes(status))addFinding(path,'UNKNOWN_OR_INVALID_LIFECYCLE');
    if(kind!=='cafe') {
      if(generation(d).invalid)addFinding(path,'INVALID_GENERATION');
      const uid=text(d,'uid'),cafe=text(d,'cafeId');
      if(uid!==p[p.length-1] || (kind==='member'&&cafe!==p[1]))addFinding(path,'DOCUMENT_IDENTITY_MISMATCH','CRITICAL');
      if(!safeId(uid)||!safeId(cafe)){addFinding(path,'MISSING_IDENTITY_FIELD');continue;}
      const workspace=need(`cafes/${cafe}`);
      if(kind==='mapping') {
        const member=need(`cafes/${cafe}/members/${uid}`);
        if(member && (!generationMatch(d,member)||text(member,'status')!==status))addFinding(path,'CANONICAL_MEMBER_STATE_OR_GENERATION_MISMATCH','INCONSISTENT');
      } else {
        const role=text(d,'role');
        if(!['owner','staff'].includes(role))addFinding(path,'INVALID_MEMBER_ROLE');
        if(status==='active') {
          const list=activeByUid.get(uid)??[];list.push(path);activeByUid.set(uid,list);
          const mapping=need(`user_cafe_memberships/${uid}`);
          if(mapping&&(text(mapping,'cafeId')!==cafe||text(mapping,'uid')!==uid||text(mapping,'status')!=='active'||!generationMatch(mapping,d)))addFinding(path,'ACTIVE_MEMBER_CANONICAL_CONFLICT','CRITICAL');
          if(workspace&&(text(workspace,'status')!=='active'||(role==='owner')!==(text(workspace,'ownerUid')===uid)))addFinding(path,'ACTIVE_MEMBER_OWNER_OR_CAFE_CONFLICT','CRITICAL');
        }
      }
    } else {
      const owner=text(d,'ownerUid');
      if(!safeId(owner)){addFinding(path,'MISSING_OWNER_REFERENCE','CRITICAL');continue;}
      const list=ownedByUid.get(owner)??[];list.push(path);ownedByUid.set(owner,list);
      if(status==='active') {
        const m=need(`cafes/${p[1]}/members/${owner}`),c=need(`user_cafe_memberships/${owner}`);
        if(m&&c&&(text(m,'role')!=='owner'||text(m,'uid')!==owner||text(m,'cafeId')!==p[1]||text(c,'uid')!==owner||text(c,'cafeId')!==p[1]||text(m,'status')!=='active'||text(c,'status')!=='active'||!generationMatch(c,m)))addFinding(path,'OWNER_AUTHORITY_GRAPH_CONFLICT','CRITICAL');
      }
    }
  }
  for(const paths of activeByUid.values())if(paths.length>1)for(const path of paths)addFinding(path,'MULTIPLE_OBSERVED_ACTIVE_MEMBERSHIPS','CRITICAL');
  for(const paths of ownedByUid.values())if(paths.length>1)for(const path of paths)addFinding(path,'MULTIPLE_OBSERVED_OWNED_CAFES','CRITICAL');
}
(async()=>{
 const logger=require(root+'logger').logger;
 logger.debug=()=>{}; // Do not log request paths, response bodies or auth metadata.
 const account=require(root+'auth').getGlobalDefaultAccount();
 const fp=account?.user?.email&&crypto.createHash('sha256').update(account.user.email.trim().toLowerCase()).digest('hex');
 if(fp!==expectedIdentity)throw Error('ACCOUNT_MISMATCH_STOP');
 await require(root+'requireAuth').requireAuth({project,nonInteractive:true,user:account.user,tokens:account.tokens},true);
 client=new (require(root+'apiv2').Client)({urlPrefix:'https://firestore.googleapis.com',apiVersion:'v1'});
 const cafes=await query(null,'cafes','cafe',10);
 await query(null,'user_cafe_memberships','mapping',10);
 for(const path of cafes)if(memberReturned<20)await query(path.split('/')[1],'members','member',Math.min(5,20-memberReturned));
 const references=[];
 for(const [path,d] of records) {
   const kind=category(path),p=path.split('/');
   if(kind==='cafe') {const owner=text(d,'ownerUid');if(safeId(owner))references.push(`cafes/${p[1]}/members/${owner}`,`user_cafe_memberships/${owner}`);}
   else {const uid=text(d,'uid'),cafe=text(d,'cafeId');if(safeId(uid)&&safeId(cafe))references.push(`cafes/${cafe}`,`cafes/${cafe}/members/${uid}`,`user_cafe_memberships/${uid}`);}
 }
 for(const path of [...new Set(references)])if(referenceGets<10)await getReference(path);
 inspect();
 console.log(JSON.stringify({project,database:'(default)',requests,returnedDocuments:returned,uniqueDocuments:records.size,referenceGets,missingReferences:missing.size,coverage,findings,rootResult:findings.some(f=>f.severity==='CRITICAL')?'FAIL_CRITICAL':findings.length?'INCONCLUSIVE':'PASS_WITH_LIMITATIONS',limitations:['bounded first-page sample','cross-request data may change','no provenance assurance','no Rules runtime verification','unlisted orphans may remain']}));
})().catch(e=>{console.log(JSON.stringify({project,database:'(default)',status:'STOPPED',requests,returnedDocuments:returned,referenceGets,reason:/^[A-Z_]+$/.test(e.message??'')?e.message:'REQUEST_OR_PERMISSION_FAILURE',httpStatus:e.status??e.context?.response?.status??null}));process.exitCode=1;});
```

## Approved execution results (2026-11-06, Asia/Kuala_Lumpur)

The user explicitly selected Option 2 for the exact bounded scope above. No scope
expansion occurred. The existing local CLI account fingerprint matched before the
requests. Every document endpoint explicitly targeted `velora-73222/(default)`;
returned content contained no records requiring identity joins or raw output.
No project-wide metadata enumeration or Rules release readback was performed.

Executed the reviewed JavaScript using an inline Node loader, with existing saved
CLI authentication. Local loader-variable collision was corrected before network
execution. Final loader normalized line endings, extracted this document's reviewed
code block and executed it with a scoped Function; it made ONLY the two read-only
runQuery requests described above. No production read was retried or repeated.

| Operation | Query limit | Returned documents | Result |
| --- | --- | --- | --- |
| Projected root `cafes` query | 10 | 0 | PASS: completed |
| Projected root `user_cafe_memberships` query | 10 | 0 | PASS: completed |
| Cafe member queries | Global cap 20 | 0 | NOT RUN: no cafes returned |
| Reference GETs | Cap 10 | 0 | NOT RUN: no references returned |

Actual document API requests: **2**. Returned/unique documents: **0/0**.
Reference GETs: **0**. Findings: **0** because no authority records were returned.
Empty queries may still incur minimum Firestore read charges; no billed-read total
or invoice was inspected. No pagination, collection-group query or additional scan.

Classification: **PASS WITH LIMITATIONS for the two empty root-query results only**.
Ownership/canonical/member/generation consistency is **NOT ASSESSED / INCONCLUSIVE**
because no records were available. Do not report an empty result as tested valid
ownership or a global clean-database certificate. At each query time, no documents
were returned from these exact root collections. The two requests are not a common
snapshot and production data can change after/between requests.

Missing-parent member subcollections, unrelated or historical collection names,
unseen database instances and other records remain outside this approval. Firestore
subcollection documents can survive deletion/nonexistence of a parent. Therefore,
zero cafe documents does NOT prove zero member documents anywhere. No permission
to enumerate these additional paths or access Auth/user/business data is implied.

Verification:
- Local authority schema / read-script safety review: PASS.
- Explicit production audit approval: PASS (Option 2).
- Existing credential fingerprint / explicit project/database request targets: PASS.
- Bounded production queries: PASS, two successful requests, zero results.
- Ownership, canonical link, member and generation consistency: NOT ASSESSED.
- Rules B runtime authorization: NOT RUN. IAM-authenticated REST is not a Rules test.
- Existing backend/Flutter suites: NOT RERUN during this preparation/audit; prior
  367 and 94 results are historical, not new evidence.
- Raw records/UIDs/credentials persisted or printed: NONE.
- Schema, local Rules, cloud Rules and documents changed: NONE.
- Writes, deployments, API/IAM/billing changes, emulator or staging access: NONE.
- Final diff/document checks are recorded in the task report. No Git add/commit/push.

Next gate: review this empty-root coverage and decide whether a separately approved
orphan-member integrity scan is needed before Rules B deployment review. Any such
scan requires its own exact paths/fields/query/read cap. Rules publication requires
separate approval; this audit does not authorize it or imply runtime readiness.
