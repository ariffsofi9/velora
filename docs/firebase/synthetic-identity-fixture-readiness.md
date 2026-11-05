# Synthetic identity and fixture readiness review

Prepared 2026-11-06 (Asia/Kuala_Lumpur). LOCAL PLANNING ONLY.
The supplied request ends at "Whether verified email"; no missing authorization
was inferred. No accounts, login, credential lookup or production requests performed.
Decision: BLOCKED for authenticated execution pending exact identity/fixture manifest,
setup method and separate approvals. This document is a proposed manifest, not a seed
script or an assertion that production accounts/data exist.

## Evidence boundary

Prior verified Rules B ruleset: ea892759-ad8e-4442-8e61-d10117d0324f.
Expected candidate raw SHA-256:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.
Previous two credential-free runtime GETs each returned 403/PERMISSION_DENIED; those
only verify anonymous denial. Prior root cafes/mappings queries returned zero, not
a global database inventory. No new cloud metadata/data/Auth inspection here.

## Minimum identity matrix

UIDs below are PROPOSED identifiers, not verified Firebase Auth users. Prefix is
ASCII and avoids the reserved Firestore `__.*__` form. If existing accounts are used,
substitute their real UID consistently in a privately approved manifest; never alter
an existing real user to fit a fixture. No passwords/tokens/emails belong in this doc.

| Alias | Proposed UID | State / membership | Authentication properties / verified email |
| --- | --- | --- | --- |
| OA | velora-rules-test-20261106-owner-a | Active Owner of A only | Approved synthetic email/password account; disabled=false; verified email recommended and mandatory if createWorkspace is used |
| SA | velora-rules-test-20261106-staff-a | Active Staff of A only | Synthetic account, disabled=false; verified email recommended; required by invitation workflow where enforced |
| OB | velora-rules-test-20261106-owner-b | Active Owner of B only | Same as OA; distinct UID and controlled mailbox |
| UC | velora-rules-test-20261106-unrelated-c | No canonical/member record in A or B | Valid synthetic signed-in account, disabled=false; verified email recommended to isolate membership denial |
| RA (optional) | velora-rules-test-20261106-revoked-a | Separate inactive Staff pair in A; never concurrent active SA mutation | Valid signed-in synthetic account, disabled=false; Auth-disabled/expired token must NOT substitute for Rules revocation denial |

Core Owner/Staff/cross-workspace matrix requires FOUR identities, not the previous
broader five-identity acceptance plan. Optional fixed-state RA makes FIVE. An invalid
generation identity G would be a SIXTH optional account/pair and separate approval;
it is not required for the minimum core. Do not silently reuse UC as invalid or revoked
Staff: UC's no-membership denial is a distinct test. A fully stateful revocation test
can use SA only in a separately approved later phase, with before/after observations.

Rules B reads use request.auth.uid, not email_verified or users.role. Backend
createWorkspace explicitly requires trusted email_verified=true. Login currently
has no equivalent verified-email gate. Email verification must come from a legitimate
approved verification method, not custom client claims, UI metadata or token forgery.
Do not create fabricated verified users or mark real accounts verified automatically.
Controlled non-customer mailboxes must be chosen privately; do not use invented
reserved-domain inboxes as if they could complete email verification. No account
creation, verification email, sign-in/token refresh or token extraction is authorized.

## Exact minimum document manifest

Cafe IDs: A = velora-rules-test-20261106-cafe-a;
B = velora-rules-test-20261106-cafe-b. Item/menu IDs: item-01 and menu-01, under each
synthetic cafe. All identifiers are placeholders pending collision/provenance approval.

Core: 8 authority documents + 4 nonempty read fixtures = **12 Firestore documents**.
UC has NO membership docs. Profiles are OPTIONAL; absent own-profile get can still
verify read authorization (exists=false), but not profile contents. Do not invent an
owner/staff role profile as authority.

| Exact path template | Required record |
| --- | --- |
| cafes/A | cafe(A, OA) |
| cafes/B | cafe(B, OB) |
| user_cafe_memberships/OA | mapping(OA, A, active, 0) |
| user_cafe_memberships/SA | mapping(SA, A, active, 0) |
| user_cafe_memberships/OB | mapping(OB, B, active, 0) |
| cafes/A/members/OA | member(OA, A, owner, active, 0) |
| cafes/A/members/SA | member(SA, A, staff, active, 0) |
| cafes/B/members/OB | member(OB, B, owner, active, 0) |
| cafes/A/inventory/item-01 | inventory(A, OA) |
| cafes/B/inventory/item-01 | inventory(B, OB) |
| cafes/A/menu_items/menu-01 | menu(A, OA) |
| cafes/B/menu_items/menu-01 | menu(B, OB) |

Templates below are field manifests, NOT executable requests. Replace aliases only
through the approved manifest. T is a trusted Firestore Timestamp from setup commit;
E is canonical UTC date Timestamp for a reviewed non-expired synthetic date. No
literal placeholder strings should be written into timestamp fields.

```text
cafe(C, O) = {
  ownerUid: O, name: "Synthetic Rules Test Cafe", businessType: "Bakery",
  address: "", inventoryPreferences: {
    unit: "pcs", lowStockAlerts: true, expiryReminders: true, reminderDays: 3
  }, status: "active", schemaVersion: 1, createdAt: T, updatedAt: T
}
mapping(U, C, S, G) = {
  uid: U, cafeId: C, status: S, schemaVersion: 1,
  membershipGeneration: G, createdAt: T, updatedAt: T
}
member(U, C, R, S, G) = {
  uid: U, cafeId: C, role: R, status: S, schemaVersion: 1,
  membershipGeneration: G, createdAt: T, updatedAt: T
}
inventory(C, O) = {
  name: "Synthetic Ingredient", category: "Synthetic", quantity: 0, unit: "pcs",
  expiryDate: E, imageUrl: "", version: 1, lifecycleState: "active",
  schemaVersion: 1, createdAt: T, updatedAt: T, createdBy: O, updatedBy: O
}
menu(C, O) = {
  cafeId: C, name: "Synthetic Menu", category: "Synthetic", priceMinor: 100,
  currency: "MYR", version: 1, isAvailable: true, isArchived: false,
  createdAt: T, updatedAt: T, createdBy: O, updatedBy: O, schemaVersion: 1
}
```

Each cafe has exactly one active Owner. Cafe ownerUid == Owner member UID == Owner
canonical document ID; all cafe references agree. SA differs from OA; both Owner
pairs must remain active and generation-consistent for SA access. No active role
conflicts or second membership. Explicit generation 0 on BOTH links is valid;
existing createWorkspace instead omits BOTH, which is legacy 0. Do not partially add
one side or confuse schemaVersion with generation. No schema migration is proposed.

Storage menu timestamps are Firestore Timestamps; backend menuDocument serializes
UTC ISO strings for Flutter MenuItem.fromMap. Do not write callable-response strings
as database timestamps. Inventory active rows omit archivedAt/archivedBy entirely.
Core zero stock avoids claiming a stock adjustment; adding fixtures via operational
callables may create movement/activity/receipt side effects, separately enumerated
before approval. These 12 docs are a Rules-only minimum, not a complete business
ledger or permission to skip backend audit contracts.

## Optional expansions, separately scoped

- RA fixed-state denial: add inactive mapping(RA,A,1) and inactive Staff member pair
  (2 documents); core+RA = 14 docs, 5 accounts. It simulates inactive state, NOT proof
  of an actual historical removal. No removal event/evidence should be fabricated.
- Optional profile: users/U with username "Synthetic Tester", exact Auth-owned email,
  photoUrl "", role "owner" (display metadata only), createdAt/updatedAt trusted T.
  One document per approved account needing profile contents/update tests, not a
  requirement for workspace authority. Profile email must not appear in reports.
- Invalid generation G: separate identity + 2 links with a deliberately mismatched
  pair; clearly tagged scenario in the test manifest, no mutation of valid SA.
- Pagination: add a second valid item/menu fixture per cafe only if needed. Do not
  reduce app limits silently; actual movement/activity repository pages are 20.
- Activity/history compatibility: add explicitly approved, mathematically consistent
  movement and activity fixtures, or generate them through separately deployed and
  approved trusted operations. No audit path is needed for core inventory/menu Rules
  reads. Full audit manifests must include schema/cafe/item/actor IDs, requestHash,
  Firestore time and type-specific quantity/version fields validated by the models.
  Do not seed arbitrary fake history just to make a page look populated.

## Supported runtime matrix using this manifest

| Identity | A reads | B reads | Own profile get | Other profile get |
| --- | --- | --- | --- | --- |
| OA | ALLOW | DENY | ALLOW (possibly absent) | DENY |
| SA | ALLOW while Owner graph valid | DENY | ALLOW (possibly absent) | DENY |
| OB | DENY | ALLOW | ALLOW (possibly absent) | DENY |
| UC | DENY | DENY | ALLOW (possibly absent) | DENY |
| RA optional | DENY inactive | DENY | ALLOW (possibly absent) | DENY |

Within each workspace read means cafe get, nonempty inventory/menu get/list and
required authority gets as permitted. Staff cannot list all members or read other
Staff records; it can read own and Owner records needed by resolver. Owners can
read/list own workspace members, never unrelated cafe members. Canonical self-get
is allowed even for absent/inactive mappings; it does NOT grant workspace access.
Use explicit read paths from the approved manifest, not global/collection-group scans.
Direct client inventory/menu/stock/member/cafe/audit writes remain DENY; attempting
such writes requires its own approval because a defect could let them commit.

## Actual client query and session dependencies

- Inventory repository watches the cafe collection with includeMetadataChanges,
  ignores cache/pending-write snapshots; active/archive filtering is local. The core
  synthetic cafe is small, but the real listener has no server limit. Stop on
  unexpected extra records; absence of an initial server snapshot is not PASS.
- Resolver runs a read-only server transaction: Owner 3 unique docs; Staff 5 including
  Owner mapping/member. Boundary monitors that authority set and removes protected
  routes on invalidation; pause/detach also invalidates. Rules dependencies are
  independent of client guard enforcement. Admin/IAM clients bypass Rules and cannot
  be used as positive authorization proof.
- Menu repository currently uses regional callable get/list with includeArchived,
  limit 20, cursor; mutations include expectedCafeId/expectedMembershipGeneration.
  Direct menu query tests verify Rules only, NOT menu app workflow; no menu Functions
  are deployed by this task.
- Movement query: scoped inventory_movements, itemId equality + createdAt DESC,
  limit/cursor; existing composite index draft is required as applicable. Production
  index existence is not verified. Activity query: scoped activities, createdAt DESC,
  limit/cursor. Single-field exemptions can affect it. No indexes are created here.
- Five distinct Staff lookup paths is not a measurement of Rules call counts. Runtime
  get/query/transaction/listener budget behavior remains unverified. Preserve the
  10 per-operation/20 multi-document limits and test the actual request shapes.

## Setup options and barriers

Existing compatible synthetic identities/fixtures may be reused ONLY after exact
scope/provenance confirmation. Neither source fixtures nor earlier empty root reads
prove their current production existence. Do not list Auth/users to discover them
without new read approval. Do not use real customer accounts as convenient fixtures.

Option A: separately approve a bounded trusted synthetic-fixture provisioning tool.
Prepare its exact script, collision preconditions, Auth identity handling, Firestore
transaction writes and cleanup/retention first. Use create-only preconditions; never
set/merge over existing data. Auth creation and Firestore writes are not one atomic
operation: document partial-failure recovery, never auto-delete/overwrite accounts.
Admin bypasses Rules; review synthetic writes independently. UID reservation must
match the provider's capabilities; ordinary client sign-up assigns UIDs rather than
letting the harness choose them. No passwords or reusable tokens in source/docs/env
output; privately provision and use in-memory client sessions after approval.

Option B: separately approve scoped backend deployment(s), then separately approve
legitimate verified-email Owner creation and invitation/member admission. Merely
createWorkspace does not provision Staff or deploy menu operations. Backend flows
produce additional documents/side effects, so the 12-doc direct Rules fixture cap
cannot be applied to them without a new exact manifest. No automated setup command
is provided as if it were safe to execute now. No emulator or new Firebase project.

## Required approval gates and caps to prepare next

1. Choose exact synthetic identities and controlled non-customer mailboxes privately.
   Confirm whether existing accounts may be read; no credentials in chat/logs.
2. Approve a concrete setup script after review: up to four account creations (or
   separately verified reuse), exactly the 12 core documents, create-only collisions,
   operation caps, partial-failure and cleanup plan. RA/profile/other expansions need
   their own explicit additional counts; none is implicitly included.
3. Separately approve user-authenticated test logins/token issuance and bounded client
   read tests. Never use privileged CLI/Admin credentials to claim Rules ALLOW/DENY.
   Start with a reviewed 12-operation core: each of OA, SA, OB, UC GETs cafes/A and
   cafes/B (8), then SA queries A inventory/menu and B inventory/menu (4), limit 2.
   This is a proposal; fixture setup approval does not authorize these reads/logins.
4. Profile get/update, resolver transactions, listeners and revocation are separately
   bounded acceptance phases per the broader plan. A logged-in ordinary app may
   auto-write a profile/call Functions; use an isolated reviewed harness with memory
   Auth persistence and no incidental app startup operations instead.
5. Authenticated denied writes, state transitions, cleanup deletes/account disable,
   backend deployment and Rules publication each require their own explicit approval.

Cleanup is not automatic: read tests require only client disposal/sign-out; seeded
records/accounts require a reviewed cleanup/retention manifest and explicit changes
approval. Never silently reactivate RA, rewrite membership generations, delete audit
history or roll Rules back to permissive. If an unexpected ALLOW or successful
protected write occurs, stop and prepare secure mitigation; do not repair as a test.
No successful test can erase previously downloaded data or certify historical graphs.

## Reusable local fixtures and readiness evidence

Existing reusable definitions inspected: functions/test/firestore.rules.test.js
link() and generation cases (emulator-only, NOT RUN); workspace-creation.test.js
MemoryStore and validData; menu-service.test.js in-memory membership/menu setup;
Flutter workspace_resolver_test.dart and workspace_episode_integration_test.dart
verified workspace/session fixtures. Adapt field shapes only; do not run emulator
seeders or copy real-looking sample emails/IDs into production. Existing tests are
not provisioning tools, and fake SDK Auth contexts are not production identities.

Source paths reviewed include Rules, user_profile_service, auth_service, workspace
resolver/store/boundary, inventory/menu/activity/movement repositories and models,
workspace-creation.js, membership-generation.js and menu-model.js. Local inspection
only; no new full-suite run is claimed. No source or dependency changes are needed
for this planning document. Exact fixture templates should undergo parser and graph
validation locally in the separately approved setup preparation before any write.

Current status: local manifest/design review COMPLETE; local hash/config checks
recorded in task report; identity existence NOT VERIFIED; fixture existence NOT
VERIFIED; setup/login/client runtime BLOCKED pending separate approvals. Prior
anonymous smoke PASS is not authenticated authorization or query compatibility.

Database report: schema/local Rules/production Rules/documents/Auth users UNCHANGED.
Production reads/writes/Auth operations/deployments NONE this phase. Only this local
planning document added. No emulator/staging, API/IAM/billing changes, Git add/commit/
push, deletion, cleanup or automatic next phase. Existing uncommitted work preserved.
