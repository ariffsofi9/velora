# createWorkspace deployment readiness review

2026-11-06, Asia/Kuala_Lumpur. LOCAL REVIEW ONLY.
Decision: **CONDITIONALLY READY**, not production-ready certification or deployment
approval. No confirmed local authorization/contract defect requires a source change
for this narrow deployment. Cloud prerequisites, risk acceptance and exact release
approval remain separate gates. No production operation was performed in this phase.

## Evidence and target

Local source: functions/src/index.js:99-118 exports v2 HTTPS onCall createWorkspace,
region asia-southeast1, timeoutSeconds 30. functions/package.json main src/index.js,
engines.node 22. firebase.json source functions/codebase workspace; no .firebaserc.
Last separately approved listing confirmed no Gen 1/Gen 2 functions in velora-73222;
see create-workspace-production-availability-check.md. Not repeated here.
Rules B publication and two anonymous denial tests are prior evidence, not current
callable/end-to-end verification. No Rules release or Firestore/Auth metadata refreshed.

Prepared exact future deployment command, NOT EXECUTED:

```powershell
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only functions:workspace:createWorkspace --project velora-73222
```

Installed CLI functionsDeployHelper.parseFunctionSelector accepts codebase:function
filters. This scopes publication to createWorkspace, not inventory/menu/invitations,
Rules or indexes. Source packaging/discovery still loads the complete functions
entry point and its local imports; it is not a one-file source upload. All imported
modules/dependencies must remain loadable. No function invocation occurs merely
because a function is listed/exported; initializeApp/getFirestore acquisition is not
a provisioning transaction. The entry's other exports must NOT be broadly deployed.
No deploy/dry-run command was run; dry-run can perform cloud operations.

## Runtime/dependency readiness

package-lock v3 present; root dependency declarations match package.json; installed
versions match locked versions. firebase-admin 14.5.0 requires Node >=22;
firebase-functions 7.4.0 requires Node >=18. Declared Node 22 satisfies both.
Offline tests ran on local Node 24.15.0, NOT Node 22. A Node 22 offline/Cloud Build
verification remains unperformed. Runtime support/region availability must be checked
from authorized current provider metadata/documentation before release, not assumed
from engine compatibility alone. No install, upgrade or online advisory audit occurred.
Build/lock integrity and source/dependency artifacts should be pinned at approval.
Current working tree contains intentional uncommitted changes; approve the actual
reviewed source snapshot, not just historical HEAD eeca574.

## Authorization and data-integrity review

- Trusted request.auth.uid is the actor; client uid/ownerUid/role/cafeId/businessId
  fields and all non-allowlisted fields are rejected. No users.role authority.
- auth.token.email_verified must be exactly true BEFORE ID allocation/transaction.
  Client display or stale token state cannot bypass it. No request to authenticate
  or verify an account occurs in this review.
- Name/type/address normalization and bounds, allowed business types/units, boolean
  settings and reminder-day allowlist match the Flutter contract. New workspace
  types are narrowed to Cafe/Restaurant/Bakery (including supported canonical aliases).
- Canonical user_cafe_memberships/{uid} is read inside the transaction. Existing
  inactive/malformed links fail closed; Staff cannot create ownership. Existing
  Owner cafe/member/map must be active schema 1, role/Owner UID consistent and have
  matching supported generations.
- No mapping: atomic create of cafes/{id}, cafes/{id}/members/{uid} and canonical
  mapping. Auth UID owns the cafe; serverTimestamp createdAt/updatedAt, schema 1.
  No client-supplied Owner UID or profile role is trusted.
- Both generation fields omitted on creation are valid legacy generation 0; Rules B
  and Flutter resolver accept this pair. One-sided/malformed values deny existing
  authorization. No schema or migration is needed for legitimate new Owner records.
- Simultaneous requests contend on the same canonical document; create preconditions
  and transaction retries prevent duplicate committed ownership. Identical normalized
  Owner retry returns created:false with existing cafeId; changed setup conflicts.
  There is no separate idempotency receipt/client key for this operation.
- Three writes commit or fail together through Admin Firestore transaction adapter.
  Auth account state is not part of that Firestore transaction. Transaction timeout
  or lost HTTP response cannot establish rollback; reconcile before re-invocation.
- Metadata includes trusted Owner UID and server times. No separate immutable
  workspace-creation event/receipt is written; that absence is a recorded audit
  limitation, not invented evidence of audit coverage.
- Admin SDK bypasses Rules. Runtime identity must have sufficient approved Firestore
  permissions, but Rules cannot constrain Admin writes or fix poisoned authority.
  Historical forged-but-consistent graphs remain a risk. Missing canonical records
  cannot reveal all historical orphan ownership; do not claim global legacy integrity.

Callable SDK handles CORS; no manual wildcard headers needed. HTTP transport IAM
must be compatible with Firebase callable end-user tokens; application request.auth
checks remain mandatory. Do not blindly grant allUsers or broad IAM roles to bypass
a 403. Any platform invoker IAM change needs review/approval separate from the code.
The wrapper does not configure App Check enforcement, maxInstances or a dedicated
serviceAccount. Default identity/limits and abuse/cost exposure require explicit
preflight/risk review; no automatic hardening patch or permission change here.

Expected WorkspaceCreationError codes/messages pass to HttpsError; unexpected errors
return generic internal to the client. index.js:114 logs the raw unexpected error
object despite its safe-sounding prefix. No request payload is explicitly logged,
but this does not guarantee error-object redaction. Review log access/retention and
consider a separately approved allowlisted diagnostic patch before exposure. No
confirmed secret leak was observed; no runtime logs were fetched.

## Flutter and Rules B integration

Client uses createWorkspace/asia-southeast1 on the selected app. Seven payload fields
match backend input; bool created/string cafeId response matches parser. Client
revalidates configured vs initialized project/app and captures UID before/after call.
Known callable failures map to fixed public feedback; malformed map/unknown/internal
errors remain conservative uncertainty messages. No response contract mismatch found.

Business setup remembers accepted/uncertain creation in page state and rechecks via
read-only resolver rather than creating again. State is lost across reloads; backend
idempotency and current-user reconciliation remain essential. Resolver validates
cafe/member/canonical and Owner links before constructing session; Home is wrapped in
WorkspaceSessionBoundary and waits for authority verification. No direct membership
write or Dashboard bypass is required. Boundary/resolver may add multiple read-only
checks, not duplicate creation.

Rules B permit self canonical get, matching cafe/member/Owner reads, with active
schema/generation constraints. This is source compatibility, not runtime proof for
Firestore transaction lookup limits or listeners. Admin creation can succeed while
client Rules queries fail; preserve resolution-only retry and diagnose separately.
The anonymous 2/2 PASS tests do not certify authenticated Owner/Staff access.

## Registration anomaly: separate bounded issue

Observed: entered staff1 but profile showed Velora User/owner. Confirmed sources:
- signup_page.dart:81-83 forwards entered name into AuthService.register.
- auth_service.dart:73-74 awaits user.updateDisplayName(name), then passes that User
  instance to createUserProfileIfNeeded. Registration then signs out.
- user_profile_service.dart:36 returns immediately if a profile already exists;
  lines 38-41 use Velora User only if supplied user.displayName is null/blank;
  lines 52-59 create the profile with that username and literal role owner.
- auth_service.dart:122 and settings_page.dart:_createUserProfile also recover a
  missing profile through this same helper. user_profile.dart:28 and ProfileHeaderCard
  have display fallbacks, but those do not themselves explain a stored Firestore value.

Therefore a stored role owner is expected current metadata, not proof of actual
workspace ownership and not a Staff membership assignment. Username text staff1 is
just a name; no legitimate code infers a Staff role from it. Backend and resolver
use canonical/member/cafe authority independently. No privilege escalation is proven
from these profile fields alone.

The observed stored fallback can be produced by the profile helper when its input
has no displayName, or preserved from an existing profile because helper never updates
it. Why that happened for THIS registration is NOT CONFIRMED: candidate causes include
User/displayName freshness, earlier interrupted/missing-profile recovery, existing
fallback data or a different running build. No race, SDK caching issue or exact live
path is declared proven. No production Auth/profile inspection occurred.

Independent fix proposal: capture the intended display name explicitly in the profile
creation contract after UID/session verification, or re-read/refresh the Auth user
before profile creation; add a registration-specific missing/stale-displayName test.
Reconcile an existing profile only with explicit safe update semantics and approval,
not an overwrite during login. No change now. This presentation/data-quality issue
is NOT a blocker for secure createWorkspace authorization or deployment; it should
be tracked separately and must never be repaired by granting client role authority.
Also note ordinary app login can create a profile, so future test approvals must
include those writes or use a dedicated read-only harness.

## Production prerequisite checklist (NOT verified this phase)

- Exact project velora-73222, region asia-southeast1, default database and approved
  account/source snapshot; .firebaserc absent so retain explicit --project.
- Cloud Functions API availability/listing previously succeeded. Current Cloud Run,
  Cloud Build, Artifact Registry and required service-agent status unknown. Eventarc
  is not a trigger requirement for this HTTPS callable; do not enable unrelated APIs.
- Billing/Blaze eligibility, quota/build capacity, organization policy and the prior
  reported Acceptable Use Policy warning remain unverified. Obtain exact warning/status
  through separately approved inspection; do not dismiss it or alter billing here.
- Deployer permissions: function create/get/list/update/source upload and operation
  inspection; build/artifact and Cloud Run operations as needed; iam.serviceAccounts.actAs
  on the approved runtime/build identities. Verify exact needed permissions against
  current platform behavior; do not automatically grant broad project roles.
- Runtime Firestore entity get/create/transaction access and service account identity;
  no assumption that provider default privileges or previous CLI access imply readiness.
- Cloud Build execution/build service identity, source upload/storage artifact,
  Artifact Registry image repository/storage and Cloud Run Gen 2 service/revision are
  expected deployment side effects. Review billing, artifact retention/cleanup policy
  and possible deployment prompts BEFORE approving. No automatic policy/repository/API/
  IAM change is authorized merely by this review.
- Build/startup logs may contain operational details; inspect only sanitized existing
  records with approval. Dependency engine ranges support Node 22 but build success
  and function health are unverified. No container/build or module discovery run here.

Publication can incur build, artifact storage, runtime and invocation costs. No price
or billing status claim is made. Exposure allows requests from signed-in verified-email
users; no App Check/rate-limit/maxInstances policy is configured on this callable.
Budget, concurrency/instance controls and abuse risk need an explicit operator decision;
any new source setting needs a separately scoped patch/retest, not silent modification.

## Approval-gated deployment and recovery procedure

1. Resolve separately approved prerequisite inspection, account/AUP warning and any
   required source/logging hardening decision. Stop on unexpected IAM/API/billing needs.
2. Pin candidate code, lockfile and review evidence; rerun relevant checks after any
   change. Validate actual Node 22 toolchain if available, without dependency upgrades.
3. Present exact one-function command above, source hashes/snapshot, platform side
   effects and risks for explicit deployment approval. No Rules/index/other functions.
4. After approved publication, separately approved metadata get/list must verify exact
   name, region, generation, runtime and deployment state; metadata health is not
   invocation success or deployed source equivalence by name alone.
5. Reconcile any existing uncertain account outcome through explicitly bounded
   current-user reads before reusing that account. No blind Create Workspace retry.
6. Separately approve one controlled verified-email functional invocation with exact
   setup payload and potential three-document transaction; note profile creation/login
   side effects and post-creation resolver/listener reads. Stop on unexpected response.
   A successful backend response does not permit skipping client authority checks.
7. Recovery: disable further testing/exposure only via separately approved function
   removal/revision/traffic/IAM action. For first deployment no prior working revision
   exists; preserve deployed artifact/source for reviewed repair-forward. Do not restore
   permissive Rules, delete created workspaces or auto-rollback production documents.
   Database/schema migration or account repair always needs independent approval.

## Actual offline verification

From functions: `npm.cmd test` -> PASS 367 tests, 0 failed/skipped; separately
`node --test test/single-workspace-security.test.js` -> PASS 19, 0 failed/skipped.
The default suite does not include that separate file. npm output was rechecked with
`npm.cmd test | Select-Object -Last 9` to retain the actual default-suite totals.
`node --check src/index.js` and `node --check src/workspace-creation.js` -> PASS.

From repository root:

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/workspace_provisioning_service_test.dart test/business_setup_test.dart test/workspace_resolver_test.dart test/workspace_episode_integration_test.dart test/profile_validation_test.dart --reporter expanded
```

PASS 118 Flutter tests, 0 failed/skipped. Coverage includes verified email/forged
identity/backend input, duplicate/concurrent creation, generations, client callable
mapping, resolver/session transition, profile validation and fail-closed retries.
It does not reproduce the reported actual registration sequence or certify production
Auth freshness. Client response malformed-field path remains source-reviewed, not
newly covered by a dedicated regression test in this phase.

Dependency declarations/lock/installed consistency PASS via local Node assertions;
config/codebase selector PASS via local inspection. No online dependency audit or
provider documentation query. Existing tests use memory models; SDK runtime transaction
atomicity/build IAM/Rules runtime limits are not certified by them.

Readiness: CONDITIONALLY READY for separate prerequisite review and a later explicit
one-function deployment approval. Not READY to execute now. No confirmed critical
local defect was found; no source change is required/authorized in this phase.
Final git/document checks recorded in task report. Production/runtime testing NOT RUN.

Database report: schema/local Rules/production Rules/documents/Auth users UNCHANGED.
Production metadata/document reads/writes/Auth operations/deployments NONE. Only this
local review document added. No emulator/staging, API/IAM/billing changes, Git add/
commit/push or automatic next phase. All pre-existing uncommitted work preserved.
