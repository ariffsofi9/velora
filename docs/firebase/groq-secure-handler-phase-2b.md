# Phase 2B: bound tickets and fresh-only handler

2026-11-06. Local implementation only. No callable export, Flutter change, default
live transport, Firebase initialization, network tests, credentials or cloud changes.

## Actual files and approved schema

Modified functions/src/ai-quota.js and functions/test/ai-quota.test.js. Added
functions/src/secure-groq-handler.js, functions/test/secure-groq-handler.test.js and
test/helpers/ai-transaction-store.js under functions/. Historical design documents
have supersession notices; no existing business callable is modified.

The sole new persistent field is payloadDigest on ai_generation_tickets/{ticketId}:
64 lowercase hex characters, computed server-side as SHA-256 UTF-8 of ordered JSON:
{schemaVersion:2,modelVersion:1,maxRecipes:N}. N defaults to 1 only when absent and
must be an integer 1-3. Null, unknown keys and client digest/model/inventory/identity
are rejected. ModelVersion covers fixed model/prompt/provider policy; increment it
when changing that policy. Identity and actor/Owner generations are separately
pinned by existing ticket fields. No AI result or prompt is persisted.

createAiQuota requirePayloadDigest:true rejects missing/malformed bound input and
legacy unbound tickets. Admission (including replay), dispatch and authorized reads
compare digest to the immutable created ticket inside their transactions. State
updates never write the digest. Generic foundation mode retains legacy tickets for
existing tests, but cannot bypass a digest on an already-bound ticket. No migration
or attaching digests to old tickets occurs. Cleanup still validates and preserves
protected records. New inspectTicket read callback is trusted backend code only.

## Handler request/response

createSecureGroqHandler is a CommonJS library export, NOT an index.js callable.
It requires injected getAccount(uid), transport(url,options), getSecret() and a
transaction store; clock and quota may also be injected. Default quota requires
binding. No default fetch/transport or real secret source exists. Future DI must
use trusted backend dependencies, never request.data.

Request data <=2KiB JSON, exact fields:
- issue: operation:'issue', expectedCafeId, expectedMembershipGeneration,
  optional maxRecipes. Returns schemaVersion:2, ticketId and expiresAt.
- generate: operation:'generate', the same expected context/recipe options,
  ticketId. Returns schemaVersion:2, provider:'groq', ticketId, status:'ok' or
  'no_suggestions', validated recipes and inventorySelection counts.

No result retrieval operation. A valid unchanged duplicate returns a fixed
already-exists error, not recipes or another dispatch. A changed payload fails
binding even on replay. Lost successful responses cannot be recovered, retried as
provider work on that ticket, or refunded. A new separately admitted ticket is a
new charged operation. No front-end changes imply users can invoke this yet.

## Identity, inventory and release boundaries

Require trusted callable Auth UID, email_verified:true and nonnegative safe integer
auth_time. Current getAccount record must match UID, disabled:false, emailVerified:true;
lookup failure denies. If tokensValidAfterTime exists it must parse and not postdate
the token's auth_time. Check current account at entry, again before dispatch and
after successful provider completion. Future wrapper MUST provide verified callable
Auth; this library cannot authenticate an arbitrary caller-created JavaScript object.

Canonical authority is checked transactionally on issue/admit/dispatch and both
inventory snapshots: active schema-valid canonical/self member/cafe/Owner pair,
role/ownership consistency, actor and Owner generations and caller expected context.
Read snapshots combine those checks with a limit-101 inventory query. Reject over
100 documents. Require scoped schemaVersion:1/cafeId, valid names/category, safe
integer nonnegative quantity, supported unit, valid expiry/lifecycle/version.
Existing absent version defaults to 1; absent unit defaults pcs and lifecycle active.

Tickets bind recipe options, NOT inventory-at-issuance. Derive inventory at execution,
exclude archived/zero/expired items using Asia/Kuala_Lumpur calendar date, sort IDs,
select first 20 eligible records deterministically and report eligible/used counts.
This is a disclosed bounded selection, not a full-inventory optimization promise.
Provider receives opaque aliases, name, capped quantity and unit, not UID/cafe or
real item IDs. Pure existing validateRecipes validates structure/quantities/units;
aliases map back only to selected authorized items. Demo provider isolation stays
unchanged. AI does not mutate inventory, stock, cache or saved recipes.

After a definite valid provider response, finalize quota with known success and
then recheck account and transactionally re-read authority/full normalized inventory.
Withhold result on any difference or revocation. No refund. Finishing quota before
release avoids leaving known-finished work locked when access was revoked. Post-
provider account checks and Firestore checks cannot be one atomic Auth/Firestore
transaction; a subsequent revocation can always race response delivery. No absolute
cross-service linearizability or erasure of already-delivered results is claimed.

## Dispatch, provider bounds and uncertainty

Quota limits/issuance budgets unchanged: 10/30 admitted/day, 20/60 issued/day, one
workspace reservation. Confirm first admission and first transactional dispatch;
never invoke transport in a transaction. Duplicate admission does not return a
fence; only a confirmed dispatch transition proceeds. On ambiguous dispatch commit,
do not retry or send provider work. Attempt fenced unknown completion once; if it
fails, retain existing state for conservative recovery/quarantine.

getSecret must return a server-only key; absent/invalid secret fails before admission.
No Secret Manager binding or key is created. Fixed Groq endpoint/model
openai/gpt-oss-20b, temperature 0.2, model policy version 1, max_completion_tokens 2048,
JSON-object output, <=32KiB request, <=64KiB response, <=24KiB content/validated result,
<=3 recipes/10 ingredients/8 steps and validator string limits. Exact output shape
is validated server-side. Redirects error; zero automatic retries. Whole transport/
body-read deadline <=15s, AbortController and reader cancellation; local abort is
not proof of remote termination. Model availability/provider compatibility NOT VERIFIED.

HTTP 400/401/403/404/413/422/429 are classified as explicit provider rejections,
charged with terminal completion. HTTP 5xx/unknown transport, timeout, malformed,
oversized/incomplete/secret-bearing response remain uncertain and quarantine.
Transport-thrown arbitrary error properties/text do not establish termination.
Only handler-generated classified rejection errors can use that completion outcome.
Future provider activation must validate these classifications against provider
guarantees; mocks are not proof. No exactly-once remote execution is claimed.

Failure before dispatch after admission can leave an admitted reservation until
the existing 120s trusted expiry-recovery protocol runs; it is still charged.
Maintenance is not automated. Quarantine cannot be unlocked here. Completion failure
withholds response and never causes a repeat provider call. Unknown outcomes block
workspace AI but no existing business workflow imports this handler.

Errors expose only fixed text/code. No logging/raw provider body/headers or SDK
errors returned. Validate key leakage both before and after JSON decoding; no
provider metadata/reasoning/tool calls returned. This is not an exhaustive detector
for arbitrary unknown external secrets. No result storage/retrieval endpoint exists.

## Offline verification and limits

Focused handler/quota suites use optimistic versioned transactions and mocked
transport, never Admin initialization/network. Query model detects changed document
versions AND query phantom changes. Tests validate digest/replay, current account,
quota/concurrency, unknown commit, timeout/accounting, authorization changes, bounded
selection/outputs, secret redaction, empty inventory and fresh-only behavior.
Mocks do not prove native Firestore/Auth isolation, provider execution or production
costs. Node 22 deployment behavior needs separate verification (local Node 24.15.0).

Commands from functions:
node --test test/ai-quota.test.js test/secure-groq-handler.test.js
node --test test/ai-quota.test.js test/secure-groq-handler.test.js test/firestore-rules-contract.test.js test/workspace-resource-config.test.js
npm.cmd test

New suites remain separately invoked: package.json default explicit discovery is
unchanged. Before integration, separately approve including them in default CI.
From root: node --check on the new handler, quota, helper and test files;
git diff --check. Rules runtime, provider, emulator, Flutter and cloud tests NOT RUN.

Observed results: 57 quota tests and 56 handler tests; combined with five Rules
contract and two unchanged-resource tests, 120 focused tests passed. Default npm
regression: 367 passed. All suites zero failed/cancelled/skipped/todo; coverage
overlaps, not 487 unique new tests. Five affected JavaScript files passed node
--check; git diff --check passed with existing LF/CRLF warnings only. All verification
commands exited 0. The initial handler run exposed an error-category mapping issue
for inventory bounds; normalization was moved outside the quota error wrapper and
the regression now checks the intended resource-exhausted result.
Local Rules SHA-256 unchanged:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

DATABASE CHANGE REPORT: proposed local ticket payloadDigest only; membership
schemaVersion:1 and receipt fields unchanged. Production schema, local/production
Rules, indexes, documents and Auth users unchanged. No new index (bounded direct
workspace inventory query). Production reads/writes NONE; deployments NONE. No
billing, secret, IAM/API, Git stage/commit/push/history changes. Dirty work preserved.

NO-GO for deployment or real AI usage. Require wrapper/resource/secret/App Check
review, provider outcome validation, cost/maintenance/quarantine acceptance,
runtime and client-contract approval before activation. No follow-on is automatic.
