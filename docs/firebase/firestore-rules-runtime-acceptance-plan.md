# Rules B runtime acceptance plan

Prepared 2026-11-06 (Asia/Kuala_Lumpur). PLANNING ONLY; no live tests authorized.
The supplied request ends at the final safety bullet `API`; no missing text was
assumed to grant permission. All existing no-deployment/no-mutation boundaries apply.

## Baseline and decision

Prior verified default release: `projects/velora-73222/releases/cloud.firestore`.
Prior active ruleset: `ea892759-ad8e-4442-8e61-d10117d0324f`.
Current local raw SHA-256 rechecked:
`d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af`.
`firebase.json` references `docs/firebase/workspace.firestore.rules`.
No cloud release was read during this planning phase; baseline is prior evidence.
Prior source compilation PASS, backend 367 PASS and Flutter 94 PASS are not rerun.

Decision: BLOCKED for the full runtime suite pending identified non-sensitive test
identities/fixtures and exact per-phase approvals. Plan is ready for scope review.
Prior root queries returned no cafes or canonical mappings; this is neither a fresh
inventory nor proof that no suitable account/fixture can exist now. Identity and
fixture availability are NOT VERIFIED, not presumed present or absent globally.

## Test method and alternatives

Use a separately reviewed, purpose-built Firebase Web client harness or tightly scoped
REST requests authenticated with a Firebase Auth ID token. Client identities MUST be
validated as approved test identities. Never request tokens/passwords in chat or logs.
Use in-memory Auth persistence, disable Firestore persistent cache for the test harness,
and separate it from the ordinary app to avoid incidental profile writes, listeners,
Functions calls or local-storage sessions. Harness implementation is a separate
approved step; no harness or new dependency is added here.

IAM-authenticated CLI/REST and Admin SDK bypass Rules: DO NOT use them as authorization
assertions. The previous audit used IAM and therefore was not a Rules runtime test.
Unauthenticated requests carry no Authorization or cached Auth context. Authenticated
REST uses Firebase ID tokens, not Google OAuth access tokens/service-account credentials.

Supported-tooling review: installed CLI compilation submits source to Rules API
projects.test. Previous source-only response had no testResults. Existing
functions/test/firestore.rules.test.js needs an emulator, which remains prohibited.
No validated non-emulator Rules mock evaluator has been established here. Console
Playground/source simulation, if separately approved and supported, is supplemental;
it is not proof of deployed client query/listener behavior and may need real lookup
documents. No cloud evaluation occurs in this plan.

Best options: approved existing synthetic accounts/fixtures; otherwise separately
approve minimal fixture provisioning, or a dedicated isolated test environment.
No project/database/account/workspace creation is authorized or performed now.
A different test environment would validate its own Rules, not automatically certify
this production release; preserve exact source and report that distinction.

## Identities and fixture manifest required BEFORE execution

Aliases only: Oa Owner of cafe A; Ob Owner of cafe B; S active Staff of A; R inactive
Staff of A; G Staff with a deliberately invalid generation pair in A; U unauthenticated.
Five approved synthetic identities are sufficient for the fixed-state matrix.
Existing real customer accounts/data are forbidden. Exact UIDs/document IDs must be
approved privately in an execution manifest, not guessed or discovered by broad scans.
No identity availability was checked; no authentication/login is performed now.

Minimum proposed immutable synthetic fixture set for later approval:
- Cafes A/B with active schema-1 cafe records and distinct Owner UIDs.
- Five canonical/member pairs for Oa, Ob, S, R, G (12 authority documents including
  cafes); R both inactive, G one-sided/mismatched explicit generation, valid Owner
  pairs, S matching generation. These are testing fixtures, not real history.
- Two inventory and two menu documents in A for nonempty first/second pages; one
  synthetic movement and one activity in A. Total 18 documents for this proposal.
- Own-profile tests may read an absent own profile (exists false is an authorized
  read), or use a separately approved synthetic profile. Profile create/update
  tests require a dedicated approved synthetic profile and extra write approval.
- Production data minimization: no customer content. Alias fixtures must contain
  enough valid domain fields for separate app-parser tests; that schema is reviewed
  before provisioning. A zero-row ALLOW query alone is insufficient positive coverage.

Because createWorkspace is not deployed, do not use the normal onboarding app to
manufacture fixtures. Setup needs separate approval for exact Auth accounts, fields,
paths, writes and trusted provisioning method, OR a separately approved scoped backend
deployment followed by explicit callable invocation approval. None is implied here.
Do not activate removal/rejoin callables merely to test a listener.

## Core matrix and per-phase request caps

Exact aliases resolve only through the approved manifest. `D` means
`projects/velora-73222/databases/(default)/documents`. Each row is one client operation
unless explicitly stated. All remote execution below is NOT RUN.

| ID | Identity / fixture | Exact path or query | Expected / assertion | Max operations | Mutation / cleanup / approval |
| --- | --- | --- | --- | --- | --- |
| N1 | U, reserved synthetic profile ID | GET D/users/Oa | DENY: permission-denied / HTTP 403 | 1 | No writes; no cleanup; unauthenticated production-read approval |
| N2 | Oa, own identity | GET D/users/Oa | ALLOW: server document or not-found/exists false | 1 | No writes; no cleanup; own-profile read approval; do not log fields |
| N3 | Oa, Ob approved profile alias | GET D/users/Ob | DENY: permission-denied / 403, even if absent | 1 | No writes; no cleanup; explicit negative-read approval |
| P1 | Oa, valid A graph | GET D/cafes/A | ALLOW: server data | 1 | Read approval; no cleanup |
| P2 | S, valid A graph | GET D/cafes/A | ALLOW: server data | 1 | Read approval; no cleanup |
| N4 | S, valid B owned by Ob | GET D/cafes/B | DENY | 1 | Negative-read approval; no cleanup |
| P3 | Oa and S, valid A | QUERY D/cafes/A/inventory, limit 2 | ALLOW: expected synthetic rows | 2 | Bounded query approval; no cleanup |
| P4 | Oa and S, valid A | QUERY D/cafes/A/menu_items, order __name__ asc, limit 2 | ALLOW: expected synthetic rows | 2 | Rules-only query, not current callable menu workflow; no cleanup |
| N5 | S, B valid but unrelated | QUERY D/cafes/B/inventory, limit 2 | DENY | 1 | Negative query approval; no cleanup |
| N6 | S, B valid but unrelated | QUERY D/cafes/B/menu_items, limit 2 | DENY | 1 | Negative query approval; no cleanup |
| N7 | R, valid inactive pair in A | GET D/cafes/A; GET D/cafes/A/inventory/item1 | DENY for both | 2 | Fixture/read approval; no cleanup |
| N8 | G, invalid generation in A | GET D/cafes/A; GET D/cafes/A/menu_items/menu1 | DENY for both | 2 | Fixture/read approval; no cleanup |
| D1 | Oa, exact synthetic inventory/menu targets | UPDATE D/cafes/A/inventory/item1; UPDATE D/cafes/A/menu_items/menu1 | DENY | 2 | WRITE approval REQUIRED; writes could succeed if protection is defective |
| D2 | S, exact synthetic authority targets | UPDATE D/user_cafe_memberships/S; UPDATE D/cafes/A/members/S; UPDATE D/cafes/A ownerUid | DENY | 3 | WRITE approval REQUIRED; stop on unexpected success; repair separately approved |
| D3 | Oa, existing synthetic own profile | UPDATE D/users/Oa role/cafeId authority fields | DENY | 1 | WRITE approval REQUIRED; no real profile target |
| D4 | Oa, synthetic audits | UPDATE D/cafes/A/activities/activity1; UPDATE D/cafes/A/inventory_movements/movement1 | DENY | 2 | WRITE approval REQUIRED; stop on unexpected success |
| P5 | Oa, synthetic own profile | CREATE six allowlisted fields; UPDATE username/photoUrl/updatedAt only, with server times | ALLOW | 2 | Separate successful-write approval and cleanup manifest REQUIRED |

Phase N/P read-only core: at most 16 client operations and at most 20 returned
fixture documents. No automatic retries; stop on first unexpected result, target or
identity mismatch. A missing identity/fixture blocks that row; do not substitute a
real user/workspace. Dependent Rules lookups may add billable reads. The operation
cap counts SDK calls, not a guarantee of backend request/billed-read totals.
Phase D: at most 8 attempted denied writes; never run under read-only approval.
P5: at most 2 intended writes; not covered by Phase D approval.

## Exact query/request recipes and additional compatibility phase Q

Client get recipes must use `GetOptions(source: Source.server)`/getDocFromServer.
REST: GET `https://firestore.googleapis.com/v1/{D}/{approvedPath}` with approved
Firebase ID token, or no Authorization for U. Do not use IAM credentials.

Queries use POST `https://firestore.googleapis.com/v1/{D}/cafes/{A-or-B}:runQuery`,
which is a read despite POST. Structured query fields: `from.collectionId` as listed,
explicit `limit`, and listed filter/order/cursor. No collection-group queries.

Repository shapes (additional phase Q, separately approved):
- Inventory actual app watches the whole `cafes/A/inventory` collection with no
  Firestore predicate/limit; active/archive filtering occurs client-side. Production
  acceptance uses ONLY the approved synthetic cafe with a verified maximum 2 inventory
  fixtures. A bounded REST query is not proof that the unbounded app listener works.
- Movement: `cafes/A/inventory_movements`, where itemId == item1, orderBy createdAt
  descending, limit 20; next page startAfterDocument(last). Requires existing
  itemId ASC + createdAt DESC collection index. No index creation authorized.
- Activity: `cafes/A/activities`, orderBy createdAt descending, limit 20,
  next page startAfterDocument(last). Single-field index/exemption state unverified.
- Rules-only menu query is direct scoped get/list. Current actual menu repository
  calls listMenuItems(includeArchived, limit 20, cursor) and validates session before
  and after. No menu callable test is authorized by a Rules query approval.
- Read-only resolver transaction: Oa reads mapping/Oa, cafes/A, members/Oa (3 docs);
  S reads mapping/S, cafes/A, members/S, members/Oa, mapping/Oa (5 docs). Do not use
  cached reads to claim server transaction success. No writes in callback.
- Owner members list: `cafes/A/members` limit 5 ALLOW; S same query DENY. S GET Owner
  mapping/member ALLOW; S GET unrelated Staff member DENY with approved alias R/G.

Q cap: 2 read-only resolver transactions (3+5 document operations), 4 movement/activity
page requests (2 per collection), 5 member/mapping get/list requests = 11 top-level
SDK operations and at most 18 document results. This cap excludes listeners. Seed
fixtures as reviewed above; fewer rows can verify safe empty-page handling, not
nonempty page-2 behavior. Never generate extra data to fill pages without approval.
Stop immediately if SDK automatic transaction retry would exceed 2 attempts in total;
prefer disabling automatic retry where supported and log the configured bound.

Access-call review: member() references caller map/member, cafe and Owner member/map
(up to 5 unique paths for Staff, 3 for Owner). Repeated isMember/isOwner calls may
reuse cached lookups. Firestore limits include 10 calls for a single get/query and
20 for multi-document/transaction requests, with applicable per-operation limits.
Success of these exact operations is evidence they fit then; it does not reveal
exact cached call counts or prove arbitrary query/batch workloads. permission-denied
can reflect authorization or call-budget issues; do not weaken checks speculatively.

## Listener phase L (separate approval, NOT RUN)

L1: S uses actual scoped inventory snapshots(includeMetadataChanges:true); observe
only server-backed snapshots, no pending writes. Cap 1 listener, 30 seconds, max 5
callbacks. Initial synthetic rows must match; cache-only output is inconclusive.
Unsubscribe at cap, reconnect, error or timeout; disable automatic reconnection or
stop the harness on connection loss. No writes for L1. A listener is one logical
operation but can generate variable reads/metadata callbacks; no exact billed-read
ceiling claimed. Must approve the time and callbacks as well as fixture path.

L2: actual WorkspaceSessionBoundary + inventory listener for S. The boundary watches
5 authority docs (Oa duplicates reduce Owner case to 3) and resolves authority before
rendering protected content. Cap 6 listeners total, 60 seconds, max 20 callbacks;
resolver verify calls capped at 2 (5 reads each), stop harness if another would start.
If the app cannot enforce this instrumentation without modification, BLOCK this
phase and approve a scoped harness/instrumentation patch first; do not launch the
ordinary app hoping request totals remain bounded.

To observe revocation AFTER an initial ALLOW, separate exact mutation approval is
required: deactivate only S canonical/member records atomically with matching next
generation using the reviewed lifecycle contract (and required audit/receipt writes).
No disabled callable activation. Before approval enumerate ALL transaction paths,
fields, fixture-only audit/receipt records and write count. Current planning does
not authorize this mutation or assume an available trusted removal endpoint.
Observe raw Firestore listener behavior separately from boundary behavior: record
whether dependent-rule change produces terminal permission-denied and whether the
boundary immediately invalidates/removes protected routes. Do not require a stock
write just to force an event. Timeout/no terminal event is INCONCLUSIVE, not PASS.
After revocation, a separately approved server GET must be denied. Never silently
reactivate the tombstone for cleanup; any future test rejoin requires its own
reviewed transition and fresh generation. Previously downloaded data is not erased.

## Outcome rules, evidence and safety

For each case record alias, exact synthetic path alias, client kind, expected and
actual code, server/cache metadata, operation counts, stop reason and duration.
No document bodies, names, emails, Auth tokens, headers, API keys or credentials in
logs, HAR exports or chat. Retain aggregate/sanitized assertions only. Credentials
and full join manifest stay outside reports and are never persisted by a harness.
Network/CORS/timeout/unauthenticated/failed-precondition/index errors are INCONCLUSIVE
for an expected permission-denied assertion; transport failure is not a security PASS.
For ALLOW distinguish document absence from authorized get; a 404/exists false can
verify own-profile permission but cannot verify workspace/query fixture content.
A denied query must not be replaced by a client-side filter over global data.

Unexpected cross-workspace ALLOW or protected write success is CRITICAL: stop all
remaining tests, preserve only sanitized evidence, notify the user and propose a
separately approved secure containment/correction. No automatic Rules rollback.
Do not restore permissive Rules. A consistent synthetic graph test does not establish
historical production data integrity. Rules tests do not certify Admin SDK handlers,
which require independent transaction/authorization tests and deployment approval.

Fixture cleanup is NEVER implicit. Before any future fixture write, approve exact
cleanup paths/actions, retained membership/audit history and any account deactivation.
Read-only cases need only unsubscribe, sign out in-memory identities and dispose the
harness; no production deletes. A successful denied-write bug may require a separate
repair, not an unapproved compensating write. Intended profile writes may require
restoration/deletion of solely synthetic profile under explicit approval. Never reset
or delete real records, import data or erase audit history to restore a test baseline.

## Approval gates and current verification

1. Identify approved existing synthetic test identities and exact non-sensitive fixture
   manifest. If unavailable, approve minimal fixture/account provisioning separately.
2. Review a concrete bounded client harness/request manifest with target/identity,
   resource IDs, counters, retry settings and disposal. Approve production READS only
   for selected N/P/Q/L1 rows. No writes or account creation bundled into that grant.
3. Denied writes D1-D4, intended writes P5, fixture setup/cleanup and revocation L2 each
   require separate explicit operation/path/payload/count approvals. A deny expectation
   is not safety permission to attempt a production write.
4. Optional current Rules metadata readback also needs authorization; compilation or
   prior readback approvals do not automatically cover this new execution phase.
5. A dedicated environment is an alternative ONLY after its creation/configuration
   is separately approved. No emulator or project creation occurs now.

No runtime approval is requested as an executable test yet: identities/fixtures and
harness are not established. Asking for generic approval to all rows would not be a
concrete safe execution request. After those prerequisites, present the exact bounded
read scope for approval; until then STOP.

Current status: local candidate identity PASS; prior active release evidence inspected
locally, current cloud release NOT RECHECKED; query compatibility SOURCE REVIEW ONLY;
matrix completeness PASS for planning; test identities NOT VERIFIED; fixtures BLOCKED
for execution pending manifest; runtime NOT RUN; offline suites NOT RERUN in this
planning-only task. Existing emulator-based Rules test source was inspected, not run.

Database report: schema/local Rules/production Rules/documents UNCHANGED. No cloud
requests, document reads/writes, Auth operations, Functions invocation or deployment.
Added only this plan. Source/dependencies/cloud configuration unchanged. No Git
add/commit/push, data cleanup, staging access or automatic continuation authorized.
