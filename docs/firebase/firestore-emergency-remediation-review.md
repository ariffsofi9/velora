# Firestore emergency remediation review package

Prepared 2026-11-05 (Asia/Kuala_Lumpur). LOCAL ONLY; no deployment authorized.
Decision as of 2026-11-06: BLOCKED for production-ready approval pending runtime
authorization evidence, release freshness, and an explicit integrity/availability risk
decision. Rules B source compilation passed after separate approval; see below. The package
is ready for human review, not proof that production is secure.

## Evidence and artifact identity

Prior authorized read-only audit, not refreshed during this preparation:
- Project: `velora-73222`; default Firestore release:
  `projects/velora-73222/releases/cloud.firestore`.
- Active ruleset at that audit:
  `projects/velora-73222/rulesets/a8d26274-8a05-4784-aef0-16ec572b540c`.
- Release create time: `2026-04-30T12:15:59.143100Z`.
- Release update time: `2026-05-25T14:09:33.584094Z`.
- Ruleset create time: `2026-05-25T14:09:31.725407Z`.
- The production source below is copied exactly from the earlier retrieved content.
  The comparison adds a terminal newline only. No database records were inspected.
- Historical Rules exposure is CRITICAL: any authenticated account could read/write
  any document. No evidence of exploitation was collected; absence of evidence is
  not evidence of clean data. Do not continue ordinary production testing under it.

```javascript
rules_version = '2';

service cloud.firestore {
  match /databases/{database}/documents {

    match /{document=**} {
      allow read, write: if request.auth != null;
    }
  }
}
```

Candidate: existing `docs/firebase/workspace.firestore.rules`, unchanged by this task.
Canonical UTF-8/LF candidate SHA-256: `d428f5edd224f3b07f93a89560da0aebbcfd99c771806c0ebdb2e7583508ac1f`.
The digest covers normalized LF text, not platform-dependent checkout bytes.
`firebase.json` references this path. Recheck the digest and release before approval;
any source change requires renewed review. No rules changes were necessary locally.

## Exact production-to-candidate diff

```diff
--- production/a8d26274-8a05-4784-aef0-16ec572b540c/firestore.rules
+++ docs/firebase/workspace.firestore.rules
@@ -1,10 +1,121 @@
+// DRAFT ONLY. Referenced by firebase.json; do not deploy until authorization is verified.
+// Admin SDK bypasses these rules: trusted provisioning must validate every write.
 rules_version = '2';
-
 service cloud.firestore {
   match /databases/{database}/documents {
-
-    match /{document=**} {
-      allow read, write: if request.auth != null;
+    function signedIn() { return request.auth != null; }
+    function link(data, uid, cafeId) {
+      return data.uid == uid && data.cafeId == cafeId &&
+        data.status == 'active' && data.schemaVersion == 1;
     }
+    // Active-link and role checks remain mandatory in member(); this helper
+    // checks generation consistency only, never authorizes inactive history.
+    function matchingGeneration(mapping, membership) {
+      return (!('membershipGeneration' in mapping) &&
+              !('membershipGeneration' in membership)) ||
+        (('membershipGeneration' in mapping) &&
+         ('membershipGeneration' in membership) &&
+         mapping.membershipGeneration is int &&
+         membership.membershipGeneration is int &&
+         mapping.membershipGeneration >= 0 &&
+         mapping.membershipGeneration <= 9007199254740991 &&
+         membership.membershipGeneration >= 0 &&
+         membership.membershipGeneration <= 9007199254740991 &&
+         mapping.membershipGeneration == membership.membershipGeneration);
+    }
+    function member(cafeId) {
+      let uid = request.auth.uid;
+      let mapping = get(/databases/$(database)/documents/user_cafe_memberships/$(uid)).data;
+      let membership = get(/databases/$(database)/documents/cafes/$(cafeId)/members/$(uid)).data;
+      let cafe = get(/databases/$(database)/documents/cafes/$(cafeId)).data;
+      let owner = cafe.ownerUid;
+      let ownerMember = get(/databases/$(database)/documents/cafes/$(cafeId)/members/$(owner)).data;
+      let ownerMapping = get(/databases/$(database)/documents/user_cafe_memberships/$(owner)).data;
+      return link(mapping, uid, cafeId) && link(membership, uid, cafeId) &&
+        matchingGeneration(mapping, membership) &&
+        cafe.status == 'active' && cafe.schemaVersion == 1 && owner is string &&
+        membership.role in ['owner', 'staff'] &&
+        ((membership.role == 'owner' && uid == owner) ||
+         (membership.role == 'staff' && uid != owner)) &&
+        link(ownerMember, owner, cafeId) && ownerMember.role == 'owner' &&
+        link(ownerMapping, owner, cafeId) &&
+        matchingGeneration(ownerMapping, ownerMember);
+    }
+    function isMember(cafeId) { return signedIn() && member(cafeId); }
+    function isOwner(cafeId) {
+      return isMember(cafeId) &&
+        get(/databases/$(database)/documents/cafes/$(cafeId)).data.ownerUid == request.auth.uid;
+    }
+    function validProfileCreate(uid) {
+      let data = request.resource.data;
+      return signedIn() && request.auth.uid == uid &&
+        data.keys().hasOnly([
+          'username', 'email', 'photoUrl', 'role', 'createdAt', 'updatedAt'
+        ]) &&
+        data.username is string && data.username.size() > 0 &&
+        data.username.size() <= 80 &&
+        data.email is string && data.email == request.auth.token.email &&
+        data.photoUrl is string && data.photoUrl.size() <= 2048 &&
+        data.role == 'owner' &&
+        data.createdAt == request.time && data.updatedAt == request.time;
+    }
+    function validProfileUpdate(uid) {
+      let data = request.resource.data;
+      return signedIn() && request.auth.uid == uid &&
+        data.diff(resource.data).affectedKeys().hasOnly([
+          'username', 'photoUrl', 'updatedAt'
+        ]) &&
+        data.username is string && data.username.size() > 0 &&
+        data.username.size() <= 80 &&
+        data.photoUrl is string && data.photoUrl.size() <= 2048 &&
+        data.updatedAt == request.time;
+    }
+    match /users/{uid} {
+      allow get: if signedIn() && request.auth.uid == uid;
+      allow create: if validProfileCreate(uid);
+      allow update: if validProfileUpdate(uid);
+      allow list, delete: if false;
+    }
+    match /user_cafe_memberships/{uid} {
+      // Same-cafe staff can read the owner's mapping for resolver consistency.
+      allow get: if signedIn() && (request.auth.uid == uid ||
+        (isMember(resource.data.cafeId) &&
+         get(/databases/$(database)/documents/cafes/$(resource.data.cafeId)).data.ownerUid == uid));
+      allow list, write: if false;
+    }
+    match /cafes/{cafeId} {
+      allow get: if isMember(cafeId);
+      allow list, write: if false;
+      match /members/{uid} {
+        allow get: if isMember(cafeId) && (request.auth.uid == uid ||
+          isOwner(cafeId) ||
+          get(/databases/$(database)/documents/cafes/$(cafeId)).data.ownerUid == uid);
+        allow list: if isOwner(cafeId);
+        allow write: if false;
+      }
+      match /inventory/{itemId} {
+        allow get, list: if isMember(cafeId);
+        allow create, update, delete: if false;
+      }
+      match /inventory_movements/{movementId} {
+        allow get, list: if isMember(cafeId);
+        allow create, update, delete: if false;
+      }
+      match /activities/{activityId} {
+        allow get, list: if isMember(cafeId);
+        allow create, update, delete: if false;
+      }
+      // Future AI paths intentionally have no grants yet.
+      match /menu_items/{itemId} {
+        allow get, list: if isMember(cafeId);
+        allow create, update, delete: if false;
+      }
+      match /menu_requests/{requestId} { allow read, write: if false; }
+    }
+    // Invitation secrets, receipts and admission limits are trusted-backend only.
+    match /workspace_invitations/{id} { allow read, write: if false; }
+    match /workspace_invite_requests/{id} { allow read, write: if false; }
+    match /workspace_invite_limits/{id} { allow read, write: if false; }
+    match /{document=**} { allow read, write: if false; }
   }
 }
```

## Authorization and compatibility matrix

All candidate outcomes below are SOURCE REVIEW expectations, not evaluated Rules.

| Operation | Expected candidate behavior | Compatibility / negative case |
| --- | --- | --- |
| `/users/{uid}` get | Authenticated self only | Other profiles/list/delete denied |
| Profile create | Self; allowlisted six fields, bounded name/photo, Auth email, role `owner`, server times | UID/cafe/authority extras denied; role is display metadata only |
| Profile update | Self; only username/photoUrl/updatedAt changed, validated types/length/time | Email, role, membership and timestamps other than updatedAt cannot be changed |
| Own canonical mapping get | Authenticated self, even absent/inactive mapping | Needed to route missing membership; not a grant to workspace data |
| Owner mapping get by Staff | Only verified same-cafe member reading cafe Owner mapping | Unrelated mappings/list denied |
| Cafe get | Active schema-valid caller and Owner links with consistent roles/generations | Missing/malformed/inactive links deny; cafe list/write denied |
| Member get/list | Self/Owner record reads within membership; Owner may read/list their cafe members | Staff cannot enumerate or read unrelated Staff member records |
| Inventory/menu get/list | Active membership in path's cafe | Cross-cafe/unauthenticated/inactive access denied |
| Movement/activity get/list | Same active membership | All direct audit writes denied |
| Inventory/menu/stock/lifecycle mutations | All direct client create/update/delete denied | Trusted callables remain the only approved mutation path |
| Membership/ownership changes | Client writes denied | Forged member, canonical mapping and cafe ownership writes denied |
| Invitations, receipts, admission limits | Client read/write denied | Backend-only invitation secrets and lifecycle metadata |
| Unmatched/global paths | Denied by final recursive match | Legacy global inventory/activity/notification/AI helpers are not approved fallbacks |

Profile service fields and server timestamps match the draft. Existing malformed or
non-email profiles may fail writes; no silent repair is proposed. Existing profile
role values can remain historical metadata but are never used as authority.
Generation contract: BOTH fields absent means legacy 0; otherwise BOTH must be
matching integers in [0, 9007199254740991]. One-sided 0, null, strings, negatives,
fractional, overflow, mismatches and inactive records must fail closed.

## Query and Rules access-call review

- Inventory queries target one cafe collection. Membership predicate is invariant
  over documents in that collection; no broad collection-group/global query grant.
- Movements query that cafe's collection by itemId, order createdAt descending and
  use bounded cursor pagination. The existing index draft is separate; Rules-only
  deployment does not publish indexes. Missing indexes remain a possible blocker.
- Activity uses cafe-scoped createdAt ordering and cursor pagination.
- Menu currently uses callable get/list (Admin authorization); direct scoped menu
  reads are allowed by the draft. No client mutation grant is needed.
- Cafe/member/mapping resolver uses individual document gets in a read-only
  transaction. Owner has three unique authority documents; Staff has five:
  caller mapping/member, cafe, Owner member/mapping. Boundary watches the same set.
- `member()` contains five get() expressions; Owner paths overlap. Some allow
  expressions also call isOwner() or repeat cafe gets. Maximum distinct dependencies
  for a consistent cafe remain five, but caching and aggregate transaction/list
  behavior MUST be evaluated, not assumed from that unique-path count.
- Firestore access-call budgets are 10 for a single document/query and 20 for
  multi-document reads/transactions/batches, with applicable per-operation limits.
  Repeated cached reads can reduce counted calls; verify actual resolver, Owner
  member list, Staff Owner-link reads, inventory query and listeners. Do not claim
  quota compliance from static inspection alone. Dependent reads can incur charges.
- Rule get() dependencies do not recursively require client read grants. They
  nevertheless need valid documents; absent fields/errors fail closed.
- Revocation checks depend on active caller/Owner/cafe documents and generation.
  Verify listener re-evaluation on dependency changes separately. Revocation cannot
  erase previously downloaded/exported client data.

## Onboarding and availability impact

- Signup own-profile creation and own-profile reads are structurally compatible.
- An account without canonical membership can read its missing mapping, reach setup,
  and cannot manufacture cafe/member/mapping records directly.
- Based on the user's latest report, no Cloud Functions are deployed. After Rules
  restriction, creation, inventory/menu mutations, invitations and callable menu/team
  reads remain unavailable until separately approved backend deployments exist.
  This is expected containment, not a reason to allow client writes.
- Existing valid workspaces may retain authorized direct reads. Inconsistent legacy
  records, revoked users and forged graphs must not be repaired by client fallback.
- The project account/AUP warning and Functions deployment prerequisites remain
  separate unresolved gates; this package does not enable APIs or resolve them.

## Data-integrity and Admin SDK limits

Old Rules allowed attackers to overwrite/delete profiles, cafes, ownership, mappings,
members, generations, inventory, invitations, receipts and audit history. A forged
BUT internally consistent Owner/membership graph can pass candidate Rules and backend
checks. Tightening Rules prevents new client forgery; it does not prove old records
are genuine, recover deletions, establish unique ownership across historical cafes,
or remove already copied information. Audit records themselves may be untrustworthy.

Do not certify existing authorization data without an independently approved,
read-only integrity investigation against trusted evidence/backups. No document
inspection, quarantine, repair or migration is authorized here. If authorization
integrity cannot be trusted, prefer an explicitly approved temporary deny-all client
containment rather than automatically trusting the restrictive draft's data graph.
Admin SDK bypasses ALL Rules, including deny-all; containment of Admin calls/IAM is
separate. Backend handlers must independently enforce Auth, roles, generation,
expected episode, idempotency and atomic writes. Verified email is mandatory for
workspace creation; email verification alone is not workspace authority.

## Offline verification and runtime gate

Existing `functions/test/firestore-rules-contract.test.js` performs textual/contract
checks and a modeled generation predicate; it is NOT a compiler or Rules evaluator.
Existing `functions/test/firestore.rules.test.js` requires an emulator and was NOT
run. No safe installed standalone Rules compiler/evaluator has been established.
No new tests duplicating the existing source assertions are added.

Required allow/deny acceptance: self profile safe create/update; Owner and Staff
scoped reads; Owner member enumeration; Staff resolver Owner reads; all unauthenticated
and cross-cafe reads/writes denied; role/mapping/ownership forgery denied; operational
and audit client writes denied; inactive/mismatched/malformed generations denied;
revocation closes listeners/routes; unsupported queries fail closed. Test actual
transaction budgets and legacy/first-time onboarding as well.
Compilation/runtime evidence requires separately approved verification outside this
batch. NO emulator, production test documents or cloud Rules compiler calls here.

## Approval-gated release procedure (DO NOT EXECUTE)

1. Review candidate hash, exact diff, workflow matrix and residual integrity risk.
2. Obtain runtime/compilation evidence or a documented explicit emergency risk
   acceptance identifying availability and integrity limits. This package alone is
   not production-ready certification.
3. Separately authorize Rules-metadata-only readback; confirm the active default
   release still matches this baseline and preserve its exact content/identifiers.
   Stop for re-review if changed. Do not read Firestore documents.
4. Verify CLI account and explicit project `velora-73222`; confirm only the approved
   file will be published. Review release permissions and any blocking AUP warning.
5. Obtain explicit approval for ONLY Firestore Rules publication, no indexes,
   Functions, database records, APIs, IAM or billing changes.
6. From `C:\Users\23000\velora`, proposed exact command:

```powershell
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only firestore:rules --project velora-73222
```

7. The deployment command has NOT been executed. Never use broad `firebase deploy`.
   After approval/execution, separately verify active release/ruleset/hash readback;
   any application/document test needs its own authorization. Do not create accounts
   or workspaces or interpret successful CLI upload as authorization-test success.

## Secure rollback / containment

Preserve the known insecure Rules as EVIDENCE ONLY, not an acceptable rollback target.
For compatibility failures, prefer repair-forward of the smallest validated restrictive
rule, or explicitly approved temporary deny-all client access. Do not loosen the
recursive catch-all, grant global reads, or temporarily allow authenticated writes.

Emergency fallback source, for review only (not a deployed or separate config file):

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} { allow read, write: if false; }
  }
}
```

Deny-all stops signup profile writes and all client reads; Admin SDK still bypasses
it. Before publishing fallback, obtain separate approval, stage its exact diff/hash,
use Rules-only targeting and verify release readback. Do not edit the reviewed
candidate silently. Keep the currently secure release until a reviewed secure
replacement is ready. No rollback may delete or restore database records. Rules
rollback cannot undo prior exposure or malicious historical mutations.

## Change control and database report

Added only this local review document. No modification of the candidate Rules,
Firebase config, app/backend/test source or dependency files. No deletion.
Schema: unchanged. Rules: unchanged locally and in cloud during this preparation.
Records: unchanged; no database access. Deployment: NOT PERFORMED.
Potential future affected paths: users, cafes, members, inventory, menu_items,
inventory_movements, activities, canonical mappings, invitations, receipts and
unmatched legacy collections. Existing uncommitted work preserved. No commit/push.

## Prior preparation verification (2026-11-05; compilation status superseded below)

- PASS: `npm.cmd test` from `functions`: 367 tests, 0 failed, 0 skipped.
  Includes existing Rules source-contract tests; no Rules runtime evaluation.
- PASS: the Flutter command below: 94 tests, 0 failed, 0 skipped.
- Rules source/security review: completed; no additional local Rules patch justified.
- Rules syntax/compilation: BLOCKED / NOT RUN (no safe offline compiler established).
- Rules runtime authorization: NOT RUN (strict no-emulator boundary).
- Production metadata/data/deployment: NOT RUN in this task.
- `git diff --check`: run after final documentation update; see task report.
- These results do not establish production readiness or historical data integrity.

Exact executed Flutter command from repository root:

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/profile_validation_test.dart test/workspace_resolver_test.dart test/workspace_session_test.dart test/workspace_inventory_repository_test.dart test/menu_repository_test.dart test/workspace_episode_integration_test.dart --reporter expanded
```


## Option B validation update (2026-11-06, Asia/Kuala_Lumpur)

Selected approach: restrictive workspace-scoped Rules B. Candidate source remains
UNCHANGED. No compatibility defect was demonstrated that warrants changing Rules.
The exact production-to-candidate diff and SHA-256 above remain valid.

### Compiler tooling and separately approved operation

Installed Firebase CLI `deploy` supports `--dry-run`, but Rules compilation is NOT
local: `lib/rulesDeploy.js:compileRuleset` calls `lib/gcp/rules.js:testRuleset`.
No reliable non-emulator OFFLINE compiler was identified. No deploy/dry-run command
was executed; a deployment pipeline is broader than the required compilation check.

The user separately approved submitting only candidate source to the Rules API.
Using existing CLI authentication, an inline Node script invoked exactly:

```text
POST https://firebaserules.googleapis.com/v1/projects/velora-73222:test
source.files = [{ name: "firestore.rules", content: <unchanged candidate> }]
```

The installed CLI `gcp/rules.testRuleset(project, files)` helper made this request.
It created no Rules release/ruleset, performed no Firestore document request and
changed no API, IAM, billing or credential configuration. Existing authentication
was used without initiating login or switching accounts.

Sanitized response:

```json
{"project":"velora-73222","operation":"Rules source compilation only","httpStatus":200,"sha256":"d428f5edd224f3b07f93a89560da0aebbcfd99c771806c0ebdb2e7583508ac1f","issues":[],"testResults":[]}
```

PASS: compiler diagnostics contained no errors or warnings. Empty `testResults`
means NO runtime allow/deny assertions were executed. Compilation does not prove
query compatibility, listener revocation, Rules read-call budgets or data integrity.
Earlier statements that compilation was not run describe the prior preparation only.
The active production release was NOT read back or changed during this phase.

### Repeated offline verification

- `npm.cmd test` in `functions`: PASS, 367 tests, 0 failures, 0 skips.
  Includes existing source-contract, membership and mutation security tests.
- Exact six-file Flutter command above: PASS, 94 tests, 0 failures, 0 skips.
- Rules static source review: PASS against intended contract, not runtime proof.
- Rules compilation: PASS, approved remote source-only operation described above.
- Rules runtime authorization: NOT RUN; Firebase Emulator NOT RUN.
- Production integrity audit: NOT RUN; plan only below.
- Final `git diff --check` and local artifact consistency checks are recorded in
  the task report. No test or application source/dependency changes were made.

### Remaining compatibility/read-budget gates

Own-profile service uses the six permitted creation fields and server timestamps;
updates change only username/photoUrl/updatedAt. Canonical self get permits the
missing-mapping setup path. Owner/Staff resolver reads match the explicit mapping,
member and cafe grants. Missing/inactive/malformed authority fails closed.
Inventory, movement and activity queries remain cafe-scoped. Menu calls Admin
handlers, which must authorize independently. Operational writes remain denied.

No broad authenticated fallback exists in Rules B. Member role and cafe Owner links
are checked, with generation checks on caller AND Owner. Two absent generation
fields are legacy zero; partial explicit fields are denied. Profile `role` remains
non-authoritative. The source's catch-all denies invitations/lifecycle metadata and
all ungranted paths, even when no dedicated match is present.

Required runtime gate remains the exact source acceptance matrix above, especially
Staff reads of Owner records, Owner member listing, the multi-get resolver, cached
lookup accounting, paged queries and authority-listener revocation. Five distinct
lookup paths are a static estimate, not measured Rules evaluation counts. No limit
or authorization check was weakened to accommodate unverified behavior.

### Narrow production integrity audit plan (NOT EXECUTED)

Separate explicit approval is required for database reads; the compilation approval
does not cover them. Proposed initial scope is ONLY the default Firestore database
in `velora-73222`, and these authority paths/fields:

| Path | Permitted projected fields |
| --- | --- |
| `/cafes/{cafeId}` | document ID, ownerUid, status, schemaVersion |
| `/user_cafe_memberships/{uid}` | document ID, uid, cafeId, status, schemaVersion, membershipGeneration |
| `/cafes/{cafeId}/members/{uid}` | document ID, uid, cafeId, role, status, schemaVersion, membershipGeneration |

Use read-only paginated document queries/gets with projection. No `/users` profiles,
Auth account lookup, emails, names, inventory, menus, invitations, receipts or raw
audit payloads. No writes, exports, repairs, transactions that write, callable
invocations, security probes, API/IAM changes or persistent record dumps. Existing
credentials only; check exact project/database before every request. Stop on target
mismatch or insufficient permissions; do not change accounts or permissions.

Initial budget: at most 200 cafe documents, 200 canonical mappings and 1,000 member
documents, including referenced-document lookups; pages at most 50. This is an
approval boundary, NOT permission to run now. Count duplicate fetches against the
budget; cache locally in memory to avoid repeats. Stop when any budget is reached
and report incomplete coverage rather than expanding automatically. Enumeration
and missing-reference reads may incur normal Firestore read charges.

Checks:
1. Enumerate cafes and mappings within the approved bounds; for each approved cafe,
   read its member records and referenced canonical/Owner records within budget.
2. Validate document ID/uid agreement, safe IDs, cafe identity, schema 1, known
   active/inactive state, role consistency and BOTH generation pairs.
3. Active cafe must have exactly one active Owner matching cafe.ownerUid; Owner must
   map back to that cafe with matching generation. Active Staff must have consistent
   canonical/member records; no Owner/Staff overlap across observed cafes.
4. Build reverse indexes in memory by UID to detect multiple owned cafes, duplicate
   active episodes and orphan/missing mappings/members. Flag inactive history without
   altering it; do not count historical inactive Staff as active overlap.
5. Do not treat a consistent graph as proof of legitimate ownership. Independent
   trusted provenance/backups/administrator confirmation is needed for suspicious
   authority. Reading that additional evidence requires separate authorization.
6. Do not infer global uniqueness or absence of orphan subcollections from bounded
   results: members under deleted/non-enumerated cafes, unseen pages or unknown paths
   may remain undiscovered. Any expansion needs a new explicit scope/budget.

Report only aggregate counts, failure categories and salted/hashed pseudonymous
record references. Do not print raw UIDs, business names or document bodies. Keep
working joins in memory; no evidence file containing record data without additional
approval. State coverage, concurrent-change limitations and observed collection
ranges. A read-only audit does not freeze data while permissive Rules remain active;
findings can become stale. Do not promise a clean graph stays clean before lockdown.

Expected outputs: confirmed inconsistencies, unproven provenance, or no inconsistency
observed WITH explicit bounded coverage. None alone certifies historical integrity.
If records are inconsistent, stop and propose a separate reviewed remediation; never
silently migrate, delete, reactivate or rewrite them.

### Rules-only deployment checklist and secure rollback reaffirmed

- Rules B compilation is now PASS for the pinned hash; runtime and integrity gates
  remain unresolved. No automatic deployment or integrity audit follows this result.
- Before deployment approval, review the exact diff/hash, acceptance coverage,
  existing AUP/account warning, availability impact, and residual forged-graph risk.
- Separately approve active Rules metadata readback to confirm release freshness;
  preserve its exact Rules/version before any publication.
- Obtain runtime evidence under separately approved non-emulator evaluation, or an
  explicit documented emergency risk acceptance; do not label compilation as runtime.
- Database integrity inspection and Rules deployment each need their own explicit
  approval. A decision to prioritize containment must state the residual data risk
  and must not be presented as a completed audit.
- Use only the exact `deploy --only firestore:rules --project velora-73222` command
  above after publication approval. No Functions, indexes or other resources.
- Secure rollback remains a reviewed restrictive repair-forward or approved deny-all
  containment. NEVER re-release the preserved authenticated catch-all. Admin access
  still bypasses deny-all. No rollback of records is authorized or implied.

### Database and Git report for this phase

Schema, records and cloud Rules UNCHANGED. Local Rules UNCHANGED. Only this review
Markdown file updated. Production deployment NOT PERFORMED. Firestore document
access NOT PERFORMED. Only the separately approved Rules source-compilation API was
called. No production integrity audit, staging access, emulator, commit or push.

## Bounded integrity audit outcome (2026-11-06)

After a separate explicit Option 2 approval, the smaller scope documented in
`ownership-membership-audit-plan.md` was executed. Two read-only projected root
queries targeted `velora-73222/(default)`: cafes limit 10 and canonical mappings
limit 10. Both returned zero documents. No member query, reference GET, raw record
export or production mutation occurred. No retries/pagination/scope expansion.

PASS WITH LIMITATIONS applies only to the completed empty-root checks. No actual
ownership/member/generation links could be assessed. Missing-parent subcollection
members and unrelated historical paths remain unverified. This does not establish
global integrity or Rules runtime enforcement, and does not authorize publication.
The earlier larger-budget plan above was NOT executed. Full approval scope,
credential fingerprint, reviewed code, limits and sanitized results are preserved
in the linked audit plan. Separate orphan-scan and Rules deployment gates remain.

## Final deployment-readiness review (2026-11-06)

Current artifact decision: NO-GO under the requested exact-byte hash gate. This is
an artifact-identity failure, NOT a demonstrated authorization defect. No Rules
candidate edits, cloud requests, deployments or source changes occurred in this phase.

### Exact artifact identity

`firebase.json` points to `docs/firebase/workspace.firestore.rules` as intended.
The explicit future deployment target remains `velora-73222`; no active cloud target
or release was refreshed during this local review.

- FAIL: raw checkout SHA-256 is
  `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af`.
- Previously compiled source SHA-256 was
  `d428f5edd224f3b07f93a89560da0aebbcfd99c771806c0ebdb2e7583508ac1f`.
- Normalizing ONLY the current file's 121 CRLF endings to LF reproduces the compiled
  hash exactly. No other content difference was found. The earlier request explicitly
  normalized source before submitting it. Both identities must be reported; do not
  describe the raw checkout hash as identical to the compiled artifact.
- No silent line-ending correction or hash-policy exception was made. Resolve the
  gate by separately approving source-only compilation of the exact current bytes,
  recording its raw hash and reviewing the diagnostics, OR explicitly approve a
  canonical-LF identity policy with a reviewed publish-artifact procedure. A candidate
  file change requires its own review and renewed compilation authorization.

### Orphan-member predicate trace and risk decision

Every scoped cafe, member, inventory, menu, movement and activity read requires
`isMember(cafeId)` (or `isOwner`, which calls isMember). `member()` retrieves:
caller canonical mapping, caller member, cafe, Owner member and Owner canonical mapping.
It then conjunctively requires active schema-1 links, cafe active/schema 1, role vs
Owner UID consistency, and matching caller AND Owner generations.

Thus an orphan member with missing parent cafe cannot satisfy cafe.status,
cafe.schemaVersion or cafe.ownerUid. A missing canonical mapping cannot satisfy
link(mapping,uid,cafeId). Missing get().data or field errors cannot turn these
requirements into true. There is no alternate broad allow: catch-all denies.
An orphan record ALONE is structurally insufficient for scoped client access.
This is a source-logic conclusion, not an executed runtime Rules assertion.

Own-profile access is intentionally independent and cannot manufacture cafe or
mapping authority. Self-canonical get allows reading one's own mapping, including
inactive history; that read alone grants no workspace access. Staff reading an
Owner mapping requires isMember of that same cafe as well.

The prior two root queries returned zero cafes/mappings; they were not a common
snapshot and are not refreshed here. Unscanned orphan subcollections are residual
coverage limits, not a demonstrated blocking authorization bypass when required
parents/mappings are absent. Do not require an unbounded orphan scan merely to
prove this predicate. A pre-existing or subsequently forged COMPLETE consistent
graph remains possible while permissive production Rules stay active. No current
exploitation, complete emptiness or historical integrity is established.

### Compatibility and runtime assessment

- Own profiles: self-get, allowlisted creation with Auth email and server times;
  updates only username/photoUrl/updatedAt. Malformed historical fields can deny.
- Owner/Staff resolver and boundary: explicit cafe/canonical/member/Owner document
  reads are covered; dependencies must be active and valid, otherwise fail closed.
- Inventory: cafe-scoped snapshots and server reads; active/archive filtering occurs
  client-side. No collection-group/global access is granted.
- Movements: itemId equality + createdAt descending + bounded cursor. Existing
  inventory_movements composite index draft is a separate deployment dependency;
  production index existence NOT VERIFIED and not published by Rules-only command.
- Activity: cafe-scoped createdAt ordering with limit and document cursor.
- Menu currently uses callable get/list/mutations; no deployed Functions means these
  workflows remain unavailable regardless of client read grants.
- Onboarding profile write is structurally compatible; workspace creation requires
  the undeployed createWorkspace callable. No direct-write fallback is acceptable.
- Five distinct authority lookup paths, repeated isMember/isOwner calls and complete
  resolver transaction budgets remain runtime-unverified. Missing dependencies,
  access-budget exhaustion and listener failures deny access; no weakening proposed.
- Boundary invalidation is tested offline. Actual listener dependency re-evaluation,
  server/cache transitions and Rules query acceptance are not runtime certified.

No safe validated non-emulator Firestore runtime authorization harness was established
under this task's no-deployment/no-document-access boundary. The prior Rules API
source-only call returned no testResults, so it is compilation evidence only.
No additional cloud test, compilation, Rules release or test fixture was created.

### Secure recovery by failure category

- Unexpected permission-denied/profile creation failure: preserve secure Rules;
  inspect sanitized operation/code and actual field/time constraints under separate
  authorization. Prepare a minimal restrictive correction; compile/review/approve it.
- Inventory/menu read failure: distinguish undeployed callable, missing index,
  invalid authority and Rules/query incompatibility before changing Rules.
- Listener failure: invalidate protected UI, require server re-verification; never
  fall back to global/cached authority or permanently reuse a revoked session.
- Budget failure: review duplicate dependencies/caching and reduce validated helper
  work in a separately reviewed patch; do not remove membership or Owner checks.
- Inconsistent authority: deny affected access and request an approved integrity
  investigation; do not auto-repair, reactivate or migrate historical records.
- If exposure remains or a secure correction is unavailable, separately approve
  temporary deny-all client containment. This disrupts profile writes and all client
  Firestore reads; Admin SDK still bypasses it. Never restore the old authenticated
  catch-all. Rules recovery cannot undo prior data mutations or copied data.

### Completed checks and approval conditions

Current reruns: backend `npm.cmd test` 367 PASS, 0 failed/skipped; six-file Flutter
command above 94 PASS, 0 failed/skipped. Source authorization review completed;
no new Rules defect found. Compilation PASS is PRIOR evidence for LF-normalized
source, not a new compilation or exact raw-byte verification. Runtime authorization
NOT VERIFIED. Historical integrity remains bounded/inconclusive as documented.

Before deployment: resolve exact-byte identity gate; explicitly accept or obtain
runtime evidence and residual historical/availability risks; verify the pinned
candidate/hash and exact target again; separately authorize active Rules readback
and preserve the release; confirm secure recovery ownership; review AUP/account and
billing/API prerequisites if relevant; obtain explicit RULES-ONLY publication approval.
The command above remains prepared only, never executed. No indexes/Functions.

Database report: schema/local Rules/cloud Rules unchanged; document reads/writes
NONE this phase; deployment NONE. Potential future affected collections are users,
cafes/members, inventory/menu_items, movements/activities, mappings, invitation and
receipt paths, plus default-denied legacy paths. Only this review document updated.
No Git add/commit/push; all pre-existing changes preserved. Final git/document checks
are reported in the task response.

## Exact-checkout CRLF compilation verification (2026-11-06)

This evidence supersedes the exact-byte compilation hold in the final review above.
The user gave fresh, explicit approval for ONLY this CRLF-preserving source test.
No deployment approval or Rules runtime authorization test was granted or performed.

Preflight read the Rules file as raw bytes, decoded UTF-8 without normalization and
verified lossless UTF-8 re-encoding. `firebase.json` still references the exact path
`docs/firebase/workspace.firestore.rules`. Existing CLI identity fingerprint matched
before authentication; no login/account change occurred. API operation:

```text
POST https://firebaserules.googleapis.com/v1/projects/velora-73222:test
source.files[0].name = "firestore.rules"
source.files[0].content = <UTF-8 source retaining every CRLF pair>
```

Used installed CLI `gcp/rules.testRuleset(project, files)` in an inline Node script.
`fs.readFileSync` returned a Buffer; `Buffer.toString('utf8')` supplied content
without replace(), newline conversion or file writes. Local JSON serialization and
decoding preserved the exact source text, including all CRLFs. The API accepts
JSON source TEXT, not an uploaded raw file. No byte-for-byte HTTP wire identity or
server-internal representation is claimed; local source identity and API acceptance
are the evidence available. JSON escapes CR and LF as required by serialization.

| Evidence | Actual result |
| --- | --- |
| Raw before SHA-256 | `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af` |
| Submitted text re-encoded as UTF-8 SHA-256 | `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af` |
| Raw after SHA-256 | `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af` |
| File bytes / CRLF pairs / lone LFs | 5905 / 121 / 0 |
| Buffer before.equals(after) | true |
| Local JSON source round-trip | true |
| HTTP status | 200 |
| Compilation issues | [] (no errors or warnings) |
| Runtime testResults | [] (no authorization tests executed) |

Result: PASS for exact-checkout source compilation and unchanged local identity.
Prior LF-normalized compiled hash remains historical:
`d428f5edd224f3b07f93a89560da0aebbcfd99c771806c0ebdb2e7583508ac1f`.
It is not the raw-checkout identity and does not replace the hash verified here.

Only this compilation-evidence section was added in this phase. Candidate Rules,
application/backend source, database schema/documents and production Rules unchanged.
No release creation/update, deployment, Firestore document operation, staging access,
emulator, API/IAM/billing modification or Git save occurred. This claim reflects the
performed operation; no separate production release readback was requested or run.
Final `git diff --check` and artifact identity are recorded in the task report.

Remaining runtime/availability/historical-integrity risks and explicit future release
readback/deployment approval gates still apply. Clearing this hash hold does not
certify live authorization or grant permission to deploy. STOP after verification.

## Controlled deployment: approved read-only preflight (2026-11-06)

The user explicitly approved the active Rules preflight only. Existing account
fingerprint and candidate raw hash were checked, then only the default Rules release
and referenced ruleset were retrieved. No Firestore document request or deployment.

- Project: `velora-73222`.
- Release: `projects/velora-73222/releases/cloud.firestore`.
- Ruleset: `projects/velora-73222/rulesets/a8d26274-8a05-4784-aef0-16ec572b540c`.
- Release create/update UTC: `2026-04-30T12:15:59.143100Z` /
  `2026-05-25T14:09:33.584094Z`.
- Ruleset created UTC: `2026-05-25T14:09:31.725407Z`.
- Active source matches the previously preserved permissive source exactly.
- Active source UTF-8 SHA-256:
  `0ab5eeda3a3cb77d443b9a4ca377b738978854d483a5f9a7848e6148bd992b3f`.
- Candidate raw SHA-256 unchanged:
  `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af`.
- No unexpected baseline change; preflight PASS. Exposure remains CRITICAL until
  secure Rules publication; metadata readback does not test runtime authorization.

Separate approval is now requested for ONLY publishing this exact candidate using
the documented Rules-only command and explicit project. Approval must acknowledge
runtime, historical integrity and availability limitations. The publishing approval
question also explicitly requests post-deployment release/ruleset GET readback,
without any document requests or runtime tests. Until explicit approval, deployment
is NOT AUTHORIZED and NOT RUN. No IAM/API/billing changes may be accepted implicitly.

## Controlled Rules B production publication and readback (2026-11-06 MYT)

The user explicitly selected: "Approve Rules B publication and metadata readback
only" after the exact project/path/raw hash/command, disruption and runtime/integrity
risks, and secure recovery limits were presented. This approval included release and
ruleset GET verification, NOT Firestore document operations or runtime tests.

Immediately before deployment, the candidate raw SHA-256 and firebase.json Rules
path were rechecked successfully. Exactly this command ran from the repository root:

```powershell
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only firestore:rules --project velora-73222
```

CLI result: exit 0, Rules compiled successfully, uploaded and released; Deploy complete.
Only Firestore Rules were published. No Functions, indexes, Hosting or Storage Rules.
The CLI checked existing IAM permissions (including index permissions) and existing
Firestore API/database metadata. These were read-only prerequisite checks, not IAM
or index changes. The API was already enabled; no activation or unexpected prerequisite
mutation was required. CLI emitted the existing unknown firebase.json `flutter`
property warning; deployment and independent readback succeeded despite it.

Independent approved post-deployment GETs retrieved the default release and its
referenced ruleset. Metadata evidence:

- Project: `velora-73222`.
- Release: `projects/velora-73222/releases/cloud.firestore`.
- NEW active ruleset:
  `projects/velora-73222/rulesets/ea892759-ad8e-4442-8e61-d10117d0324f`.
- Ruleset create time: `2026-11-05T16:41:01.136255Z`
  (2026-11-06 00:41:01.136255 Asia/Kuala_Lumpur).
- Release update time: `2026-11-05T16:41:02.510001Z`
  (2026-11-06 00:41:02.510001 Asia/Kuala_Lumpur).
- One source file, name `docs/firebase/workspace.firestore.rules`.
- Active source UTF-8 SHA-256 AND unchanged local raw SHA-256:
  `d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af`.
- Source readback re-encoded as UTF-8 equals the approved local Buffer exactly;
  121 CRLF pairs, 0 lone LF endings. No normalization was required. This verifies
  returned source identity, not HTTP wire encoding or internal server representation.
- Prior permissive ruleset `a8d26274-8a05-4784-aef0-16ec572b540c` is no longer referenced
  by the verified default release. Retain its evidence, NEVER restore it by default.

PASS: candidate/config, explicit approvals, Rules-only CLI result and active-source
metadata readback. Rules runtime authorization NOT VERIFIED and NOT RUN. No document
reads/writes, app launch, callable invocation, emulator, backend deployment or staging
access. Prior empty-root audit and missing Functions remain separate historical
context, not rechecked by this publication. No end-to-end Create Workspace claim.

Database report: schema and documents UNCHANGED; local Rules UNCHANGED; production
Rules CHANGED through the explicitly approved publication only. No API/IAM/billing
changes or document operations. Potential affected paths include users, cafes/members,
canonical mappings, inventory/menu, movements/activities, invitation/receipt metadata
and default-denied legacy paths. Availability/runtime and historical-integrity limits
remain as documented; Admin SDK bypasses Rules. No rollback was performed.

Only this remediation document was updated locally with sanitized publication
results. No application/backend/dependency/source changes, Git add/commit/push, or
automatic Create Workspace testing. Final git diff check is recorded in the report.
STOP after verified publication; further runtime testing requires separate approval.
