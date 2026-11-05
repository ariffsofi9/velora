# Spark-only workspace provisioning feasibility

2026-11-06 (Asia/Kuala_Lumpur). FEASIBILITY ONLY; no implementation/cloud operations.
Decision: **CONDITIONALLY FEASIBLE** for first-Owner bootstrap and small-scale
admin-assisted Staff admission. A fully self-service replacement of VELORA's current
Functions-backed workflows is NOT established by this study.

## Verified current source

Signup/Login -> WorkspaceGate -> missingMembership -> BusinessSetupPage ->
FirebaseWorkspaceProvisioner -> createWorkspace in asia-southeast1 -> Firestore
transaction -> WorkspaceResolver -> WorkspaceSessionBoundary -> Home/Dashboard.
Provisioner matches initialized Firebase app to explicit velora-73222 profile,
requires UID and checks identity after response. It currently calls a Function;
changing billing choice alone cannot make it create data.

Authority schema:
- cafes/{cafeId}: ownerUid, name, businessType, address, inventoryPreferences (unit,
  lowStockAlerts, expiryReminders, reminderDays), status active, schemaVersion 1,
  createdAt/updatedAt server times.
- cafes/{cafeId}/members/{uid}: uid, cafeId, role owner/staff, status, schemaVersion 1,
  createdAt/updatedAt, optional membershipGeneration.
- user_cafe_memberships/{uid}: uid, cafeId, status, schemaVersion 1,
  createdAt/updatedAt, optional membershipGeneration. Document ID is the account UID.
Both generation fields absent means legacy zero; otherwise both must be equal,
nonnegative safe integers <=9007199254740991. Caller AND Owner links must validate.
The existing backend creates a legitimate Owner's three documents atomically, rejects
forged input authority, requires verified email and protects identical Owner retries.

Production Rules B currently DENY all client cafe/member/canonical writes. Thus the
current app cannot perform a Spark bootstrap. A future exception must be a tiny
reviewed create-only pathway, not removal of these general write denials.
Profile role owner is legacy display metadata; it must never authorize bootstrap.
Its create requirement and the username stale-wrapper defect remain separate work.

Prior approved evidence: billing disabled/unlinked; function absent; Rules deployed;
anonymous denial 2/2 PASS. No current cloud state is inspected by this phase. Earlier
empty root audit is not evidence that all historical ownership/memberships are clean.

## Public documentation basis (not production access)

Only public Firebase docs were retrieved; no account/project endpoint or credentials.
- Atomic Rules can inspect post-commit candidate document state via getAfter before
  an atomic operation commits. Transactions/batches have an aggregate 20 Rules lookup
  limit plus the per-operation 10 limit. [Atomic operations](https://firebase.google.com/docs/firestore/manage-data/transactions)
- Documented free Firestore quota: one eligible free database, 1 GiB storage, 50,000
  reads/day, 20,000 writes/day, 20,000 deletes/day, 10 GiB outbound/month. Cached Rules
  lookups may not count toward access-call limits; runtime accounting still needs
  testing. [Quotas](https://firebase.google.com/docs/firestore/quotas)
- Spark supports no-cost Auth options and limited Firestore use; deploying Functions
  requires the billing-enabled offering. Blaze is pay-as-you-go with allowances, not
  a promise of zero cost. [Plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans)

These product facts do not certify this project's provider configuration or usage.
No quota/billing/API changes are proposed. Auth providers, verification email sends,
rate/abuse limits and quotas need review for the chosen setup; exclude phone/SMS,
paid extensions, Storage uploads and external compute from a no-cost baseline unless
independently verified. No service is unlimited merely because it has a free tier.

## Alternatives

| Alternative | Spark / trust model | Security and compatibility | Assessment |
| --- | --- | --- | --- |
| A: client atomic bootstrap + strict Rules | Auth + Firestore client; no trusted server for first Owner | Can bind self Owner to new cafe only, require reciprocal three-document create; existing Rules must change; legacy graph/global history needs reconciliation | Preferred future self-service first-Owner candidate, CONDITIONALLY FEASIBLE |
| B: immutable pending request + promotion | Request create can be client/Rules; promotion needs trusted admin/server | A pending doc alone is not membership. No automatic trusted promoter exists in this Spark deployment | Automatic promotion NOT ESTABLISHED; with human admin reduces to C; request collection is PROPOSED schema |
| C: manual/admin-assisted provisioning | Approved administrator with existing trusted credentials; no deployed Functions needed | Preserve canonical schema; human validates identity, one-workspace constraints, transaction writes; Admin bypasses Rules, operational error and historical scans remain risks | Viable small-FYP fallback, not zero human effort or self-service |
| D: external server / different backend | External trusted service may offer free quotas | Requires hosting/auth/IAM/secrets/cost review; is not Firebase-only and has no verified available environment | NOT ESTABLISHED here; no hidden free-server assumption |

Recommended scope is A for carefully limited new Owner creation plus C for first-time
Staff admission/lifecycle until a separate client-only invitation protocol is proven.
If every Owner/Staff action must be automatic and no admin/server is allowed, no full
Spark-only substitute for the current invitation/removal/rejoin system is established.

## Concrete Option A design candidate (NOT Rules code)

Use the existing three authority paths and schema 1. Proposed NEW bootstrap cafe ID:
request.auth.uid, with a fixed documented derivation (here direct UID) and validated
safe identifier shape. This is a NEW ID convention, not a change to existing cafe IDs.
Existing random-ID cafes remain readable; no automatic re-key or adoption occurs.
Predictability does not authorize reads/writes: Rules always validate Auth/graph.
Rules must never accept a client-chosen Owner or claim an existing cafe by ID.

For a verified-email signed-in account with NO canonical mapping and no existing
UID-keyed cafe or Owner-member record, client submits exactly the initial create
bundle using a transaction/batch:
1. cafes/{uid}, ownerUid=request.auth.uid, allowed validated business fields.
2. cafes/{uid}/members/{uid}, uid/cafeId=self, role owner.
3. user_cafe_memberships/{uid}, uid/cafeId=self, active.
Use schema 1, active state, server-created/updated times == request.time; choose BOTH
explicit initial generations 0 for clarity. No client generation increment/update.

The three allow-create predicates must EACH establish reciprocal full consistency
using request.resource.data, before-state absence and getAfter for the other records.
Do not validate only one record and assume the others are in the batch. Require
before-state absence of canonical mapping, cafe and membership, plus after-state
matching Owner UID/cafe/role/schema/status/generation/server time and exact allowed
keys/types/bounds. The create-only context and absent pre-state force missing peer
records to be included in the same atomic commit; a pre-existing matching graph is
not a substitute. No update/delete exception and no Staff/member-other-UID grant.
An unauthenticated or unverified user cannot create ANY component alone.

All business values (name length/type/address/preferences) must be constrained in
Rules, not merely Flutter validation. Rules syntax differs from Node; exact equivalent
normalization/allowed string policies require a dedicated design and compiler/runtime
test. No complete implementation/security proof is claimed by this conceptual design.
Any broader wildcard match allowing writes would invalidate the narrow restrictions.

Access-call estimate for a straightforward implementation: per document up to three
before-state exists checks plus two peer getAfter calls = 5; three documents = up to
15 calls, each <=10 and aggregate <=20, without relying on caching. Target-record
create semantics can reduce redundant checks but must not weaken invariants. This
is a conservative design budget, NOT compiled/evaluated Rules. Expression/function
limits, getAfter behavior and transaction retries must be tested. The existing read
member() helper must not be reused to justify writes if it adds extra lookup work.

## Uniqueness, adversaries and replay

| Actor/attempt | Required rejection/invariant |
| --- | --- |
| Unauthenticated / unverified | Auth UID and trusted email_verified true required on every bootstrap path |
| Legitimate first Owner | Can become Owner ONLY of new self-UID cafe in complete atomic bundle |
| Existing Owner / Staff / revoked user | ANY existing canonical mapping, active or tombstone, blocks bootstrap |
| Other-workspace user | Existing canonical conflict; cannot write another UID's map/member or change ownerUid |
| Claim existing cafe | Create-only + no preexisting target + immutable ownership; no update/delete grant |
| Two concurrent creations | Same self-UID cafe and canonical document; pre-state/create contention allows one valid commit |
| Partial/out-of-batch creates | Every component's after-state checks require all three matching peers |
| Replay/uncertain result | Do not mutate again; read verified own graph and compare normalized setup; same episode is a no-op result |
| Client timestamp/generation forgery | request.time equality and fixed generation 0; no arbitrary increment/update |
| Profile role owner / App Check token | Neither grants workspace authorization |

Canonical uniqueness gives one active membership for post-change accounts whose
mapping cannot be client-deleted/reassigned. Rules cannot globally query every cafe
for an owner UID to discover historical orphan ownership. A historical random-ID
owned cafe with no canonical mapping could coexist with a new self-UID cafe unless
reconciled. Therefore global historical uniqueness is NOT proven. Freeze/reconcile
eligible accounts through separately approved trusted review before onboarding them;
never infer trust from an empty historical sample. Keep tombstones to prevent reset.

Read-only idempotency: on known committed same graph, resolver returns the existing
workspace; a retry should not rewrite createdAt or generate a new cafe ID. Mismatched
setup or invalid graph is a conflict. Client transactions must capture UID and profile,
recheck after asynchronous operations, and keep membership generation/session guards.
A create exception must not become a general metadata edit/update permission.

## Staff, removal and generation lifecycle

Keep all client-created Staff memberships DENIED in this first-owner exception.
For small FYP use, a separately approved administrator can verify the target account,
current Owner authority, no canonical/active conflict, and create Staff canonical/member
links atomically with schema 1/matching generations. Record actual provisioning
provenance without fabricating removal history. No broad batch seeded by client role.

A future Owner-mediated UID-bound admission protocol is possible as a separate study,
but the current invitation implementation relies on server randomness, secret hashing,
email checks, expiry, request/rate records and trusted transactions. No secure Rules-only
port was established. Storing a secret in readable Firestore data or trusting a code,
role/email supplied by the joining client is not an acceptable replacement. Proposed
admission/consent documents would change schema and need independent tests/review.

Removal/rejoin remain blocked/manual-trusted rather than allowing arbitrary client
status/generation changes. A correct transition must update BOTH links atomically,
advance generation, preserve history and protect stale mutation episodes. No client
Owner deletion or role transfer is authorized by bootstrap. Rejoin must not reuse old
email-only invitation or silently reactivate tombstones. Do not enable disabled code.

## Dashboard versus full application

After correct authority bootstrap the existing resolver can recognize schema 1 with
matching zero generations. Current Rules read helpers can remain unchanged; boundary
verifies Owner/caller links before Home. Dashboard inventory metrics can show empty
scoped inventory. No profile role change or direct Home route bypass is necessary.

But inventory create/edit/stock/lifecycle and menu/team/invitation workflows currently
use Functions. A Spark-only bootstrap DOES NOT restore these features. Restoring
client mutations would require independent Rules/transaction redesign of optimistic
versions, request episode, receipts, movement/activity consistency and RBAC, far beyond
this study. Keep them fail-closed, or accept a read-only/manual-managed demonstration.
Manual administration also bypasses Rules and is not proof of client security.

## Required future files and compatibility work

No changes made now. Potential implementation paths verified in this repository:
- lib/services/workspace_provisioning_service.dart: selectable reviewed Firestore
  bootstrap transport/response semantics, explicit app/Auth checks; no silent fallback
  from failed callable to client writes.
- docs/firebase/workspace.firestore.rules: narrowly scoped three-record CREATE
  exceptions only, verified email, typed/allowlisted fields and getAfter reciprocity.
- test/workspace_provisioning_service_test.dart, test/business_setup_test.dart,
  test/workspace_resolver_test.dart: new transport, retry/concurrency/session coverage.
- functions/test/firestore-rules-contract.test.js and existing firestore.rules.test.js:
  review/update source contracts deliberately; emulator suite remains prohibited.
- Existing profile/username issue stays a separate patch; retain current Rules-required
  profile metadata until coordinated deprecation, never use it as a bootstrap role.

No new authority collection/schemaVersion needed for Option A; self-UID cafe IDs are
an explicit proposed new-record convention. Existing cafe IDs/generations remain
compatible with reads. Pending requests/admission receipts would be PROPOSED new
paths, not approved changes. Before implementation define a protocol version/feature
selection to prevent old clients expecting callable behavior from silently changing.

Migration: no automatic production migration. Separately identify/reconcile eligible
historical accounts; preserve existing random cafes and canonical records. Deploy
reviewed Rules support before explicitly enabled compatible clients, with source/hash
pinning and account risk decisions. Existing clients stay blocked if no Functions.
Rollback: stop new bootstrap creates via reviewed Rules while retaining existing
scoped reads and denying authority deletes/updates. Do not erase newly created graphs,
remove canonical tombstones or restore permissive authenticated catch-all. Data repair
and app/config rollout each need separate approval. Rules updates do not erase caches.

## Cost/plan comparison and limits

Auth email/password and Firestore within quota can support a small setup without a
Functions deployment. Daily budgets must include lookup reads, listeners/reconnects,
failed tests and retries; three bootstrap writes alone do not describe all usage.
Quota exhaustion can block availability; Spark is not unlimited free compute/storage.
One eligible free database and feature restrictions apply. External/manual operations
may introduce administrator labor, hosting, secret management or other costs even
without a Firebase Functions bill. App Check helps app attestation, not membership
or ownership authorization, and cannot solve quota abuse or identity trust alone.

Retaining Blaze + existing callable preserves the already-tested trusted provisioning
transaction and current broader Functions architecture, at the cost of billing/build/
artifact/runtime prerequisites and cost controls. It remains the smaller application
change if billing is acceptable. The Spark route avoids that deployment dependency
but moves significant security validation into Rules and leaves other callables
unavailable. No billing upgrade or cost guarantee is recommended as an automatic step.

## Tests, gaps and decision gates

Actual offline commands from repository root:

```powershell
node --test functions/test/workspace-creation.test.js functions/test/single-workspace-security.test.js functions/test/membership-generation.test.js functions/test/firestore-rules-contract.test.js
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/workspace_resolver_test.dart test/workspace_provisioning_service_test.dart test/business_setup_test.dart --reporter expanded
```

PASS: backend 114 tests and Flutter 94 tests, each 0 failures/skips. These test CURRENT
backend/client contracts, not the proposed bootstrap Rules. No new design is proven
secure by those passes. Static source/config review completed. No Rules compiler/API
call, emulator, production access or new security test implementation occurred.

Missing implementation tests: every partial three-record combination; forged Owner,
UID/cafe/schema/role/prefs/time/generation; existing Owner/Staff/tombstone; predictable-ID
collision; existing malformed/complete graph; concurrent self bootstrap; duplicate and
uncertain retry; cross-workspace get/list; no Staff create/update/delete; quota budgets;
verified-email refreshed claims; existing legacy/random-ID compatibility; resolver
Owner/Staff/permission failure; listener revocation; rollback preserving history.
Compile and run appropriate reviewed authorization tests under separate approval;
no emulator workaround or production fixture probing is authorized here.

CONDITIONALLY FEASIBLE, not implementation-ready: settle self-service vs admin Staff
scope, exact protocol/ID eligibility, historical reconciliation, complete narrow Rules
predicate and data validation, conservative call budget, independent compilation and
runtime security evidence, staged client compatibility and secure rollback. If fully
automated Staff invitations/removal/rejoin are mandatory with no trusted operator,
that wider Spark-only design is NOT ESTABLISHED.

Database/Git report: schema/local Rules/production Rules/documents/Auth users UNCHANGED.
Production Firebase/GCP/Firestore/Auth requests NONE; writes/deployments NONE. Only
this local feasibility report added. Public documentation browsing only, no provider
account access. No source/test/dependency/config changes, Git add/commit/push, staging,
emulator, billing/API/IAM change or automatic next phase. Existing work preserved.
