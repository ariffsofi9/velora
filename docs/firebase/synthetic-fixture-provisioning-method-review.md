# Synthetic fixture provisioning method review

2026-11-06, Asia/Kuala_Lumpur. OFFLINE REVIEW ONLY. No live approvals requested.
Recommendation: Option C is CONDITIONALLY preferred for the narrow production Rules
acceptance objective, only after a later bounded Option A reuse/collision preflight.
Provisioning execution is BLOCKED until a concrete mechanism, identities, collision
checks, permissions, verification and cleanup are separately reviewed and approved.
No privileged provisioner or executable mutation commands are implemented here.

## Baseline and evidence boundaries

Prior deployed ruleset ea892759-ad8e-4442-8e61-d10117d0324f; raw candidate SHA-256
 d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.
Prior two unauthenticated 403s confirm anonymous denial only. Authenticated isolation,
production synthetic identities, fixtures and indexes remain unverified. Earlier
empty cafes/mappings queries were bounded historical reads, not an existence check
for this setup. No cloud operations, Auth lookups or account login occurred now.

## Manifest validation against actual source

The identity/path/field templates in synthetic-identity-fixture-readiness.md are a
Rules-only baseline, not a complete business ledger or a production seed script.
Aliases OA/SA/OB/UC, cafes A/B use its proposed non-reserved ASCII IDs. Exact private
UID/email ownership and real provider-assigned UIDs remain approval prerequisites.

Arithmetic: 2 cafes + 3 canonical mappings + 3 member documents + 2 inventory +
2 menu documents = **12 docs** for **4 Auth identities**. UC has no membership.
OA owns A only, OB owns B only; SA is Staff A only. Each Owner cafe/mapping/member
agrees, active schema 1, role owner, matching generation. SA pair active role staff,
UID not Owner; both Owner links must also validate. Explicit matching generation 0
is supported; createWorkspace's omission of BOTH fields is legacy 0. Never partially
upgrade fields or use profile role/custom client input as authority.

Firestore field types matter: cafe/member/mapping strings/integers must match source;
menu timestamps are Date/Timestamp values at rest, serialized ISO strings only in
callable responses. Inventory active fixture has quantity 0, version 1, valid UTC
expiry Timestamp and no archive fields. Menu has cafeId, MYR priceMinor integer,
version, availability/archive booleans, creator/updater UIDs and schema 1. Future
execution must resolve time placeholders without writing placeholder strings.

Backend createWorkspace validates verified email and all authority before creating
its three documents transactionally; retry accepts only the identical valid Owner
workspace. It does not create Staff, inventory or menu. The manifest matches relevant
authorization contracts; setting fixtures with Admin does not exercise that backend.
Staff can join through createStaffInvitation + redeemStaffInvitation; issuance writes
an invitation, receipt and rate-limit state, and redemption checks trusted verified
email/account identity before atomic membership admission. Rejoin/removal activation
remains disabled and must not be used as a provisioning shortcut.

Missing scope if the ORDINARY APP is used: AuthService.signIn calls
UserProfileService.createUserProfileIfNeeded. Missing profiles may be written on
login, so 12 documents is NOT a cap for app login. Four accounts could add up to four
profiles (16 total), subject to Rules/email/server-time requirements. A dedicated
reviewed client Auth-only harness can avoid those writes and preserve the 12-doc cap.
Use in-memory persistence; no profile recovery, callables or incidental app listeners.
Optional revoked identity + two inactive links increases to 5 accounts/14 docs; this
is a static denial fixture, not forged historical removal evidence. Profile, malformed
generation, stock history/activity, pagination or full app tests need expanded caps.

Inventory/menu direct Rules reads need no movement/activity receipts. Operational
backend item/menu creation DOES generate audits/receipts; do not bypass business
contracts or pretend those paths fit the direct-fixture 12-doc budget. Synthetic
records must remain clearly labeled in names and a private manifest, not in unknown
schema fields. No claim of customer business activity should be generated.

## Provisioning alternatives

| Option | Prerequisites and production operations | Advantages | Risks / complexity / cleanup | Decision |
| --- | --- | --- | --- | --- |
| A: approved existing synthetic accounts | Exact user-owned UID/mailbox list; later bounded getUser/getUserByEmail, no account enumeration; separately check exact fixture paths | Avoid new Auth identities; no backend deployment | Existence does not prove synthetic ownership; prior roles/sessions may contaminate tests. Reuse only independently attested accounts; do not disable/delete unrelated accounts. Low/medium complexity; fixture setup still separate | CONDITIONAL first preflight; cannot assume available |
| B: legitimate backend onboarding | Scoped deployments and Auth setup first; 2 Owner calls, 1 invitation create + 1 redeem; separate operational item/menu calls if needed | Exercises real validation, atomic authority and audit generation | Currently blocked by undeployed backend. More deployed endpoints, verified-email flows, secret invitation handling, additional audit/receipt/rate-limit docs. Highest end-to-end scope. Cleanup retains genuine lifecycle/audits | BLOCKED now; prefer later for functional onboarding, not minimum Rules-only setup |
| C: one-time privileged fixture provisioner | Reviewed manifest and dry-run script; scoped ephemeral operator identity; 4 account creates only if needed; 12 create-only docs atomically; bounded readback | Smallest explicit resource surface to test deployed Rules; no new callable deployment; deterministic graph | Admin bypasses Rules; script errors can forge authority. No true document-path IAM sandbox assumed. Auth+Firestore not atomic. Requires strict local allowlist, stop controls and separate cleanup | CONDITIONALLY preferred for narrow production Rules tests; mechanism not built/approved |
| D: isolated Firebase test environment | Separate explicit project/database/config/IAM/billing/Rules/account/index approvals | Strongest isolation from customer data; accommodates destructive/negative/lifecycle tests | New operational surface, setup cost, possible config drift; does not independently prove deployed production behavior. Environment must not be assumed to exist; cleanup needs separate project/resource approval | ACCEPT as safest isolation alternative if authorized; unavailable now |

No option is an authorization to operate. The recommendation favors tightly bounded
C only because testing THIS deployed production release is the stated objective.
If production risk tolerance is insufficient, select D rather than weakening C's
safeguards. A reuse check can reduce Auth changes but cannot skip synthetic-ownership
attestation or fixture collision checks. No new project/staging access is performed.

## Minimum privileges and bounded setup proposal (not executable)

C must use an approved short-lived operator/ADC/workload identity where available;
no downloaded service-account key, password in Git/env output or persistent production
credentials. Identity scope, billing project, default database and token audience
must be checked explicitly. Existing least privilege availability is NOT VERIFIED.
Any IAM change requires a separate task, not automatic escalation.

Candidate permission families to validate against the eventual supported APIs:
Auth account get/create (delete/update ONLY under cleanup approval), Firestore
entities get/create and any transaction/list permissions required by chosen SDK.
Do not assume app-level document allowlists limit Admin privileges. IAM generally
cannot enforce this arbitrary 12-path manifest; code review and operator controls
are mandatory. Production Admin SDK bypasses Rules including deny-all.

Proposed caps to finalize with the concrete script: four UID checks plus at most four
exact controlled-email checks, twelve masked collision GETs, at most four account
creates, one all-or-nothing create-only Firestore transaction/batch with twelve creates,
and twelve masked verification GETs plus four Auth verification lookups. Reads and
missing lookups may incur charges; no production-wide list/query/collection-group scan.
Retries default OFF: ambiguous response triggers read-only reconciliation requiring
its approved scope, not blind recreation. Transaction retries require explicit attempt
caps and counted reads if selected. These are planning caps, not live approval.

Idempotency without an extra receipt document: pin a manifest digest, assert create
preconditions, retain sanitized run evidence, reconcile only exact owned paths. First
execution refuses ALL collisions; do not accept a matching-looking existing record
as created by this tool. On a known interrupted run, provenance plus exact UID/email
ownership and full approved manifest comparison is required before skipping completed
steps. If provenance is missing or data differ, STOP. Never set/merge, overwrite or
rename existing accounts/documents. A separate receipt would change the 12-doc count
and require a new manifest/approval.

## Threat model: prevention and verification

| Risk | Preventive control | Required verification |
| --- | --- | --- |
| UID collision | Exact UID checks; provider semantics reviewed; never update existing user | Authorized getUser exact IDs + independent ownership attestation |
| Cafe/document collision | All 12 exact-path checks; atomic create-only preconditions | Zero pre-existing target docs; failed create rolls back entire batch |
| Wrong canonical cafe | Generate paths and values from one pinned manifest | Bidirectional map/member/cafe graph validator |
| Forged Owner | Two distinct Owners, one cafe each; independent manifest ownership approval | Cafe Owner UID/member role/canonical checks, not users.role |
| Staff gets Owner | Role allowlist and SA != cafe.ownerUid | Local negative cases and masked post-setup role verification |
| Generation mismatch | Both explicit 0 or both absent, not mixed | Safe-integer pair validator on caller AND Owner |
| Partial Auth/DB setup | Create identities then one atomic DB group; no cross-service atomicity claim | Simulated failpoints, bounded reconciliation, no automatic deletes |
| Rules block setup | Trusted approved setup only; never relax Rules | Confirm Admin scope and source reviews; client tests remain independent |
| Admin bypass | Fixed project/database/path/UID allowlist and reviewed source | Dry-run operation manifest + independent review; never use it as Rules proof |
| Wrong project | Hard-pin project/database/account and manifest digest | Fail closed before each request; no active-project fallback |
| Overwrite customer data | create-only, no merge/set/update; collision STOP | Exact-path preflight and atomic commit preconditions |
| Credential leak | Short-lived auth, no keys/token output; memory-only test sessions | Review logs/config/Git diff; redact raw API errors and personal data |
| Synthetic looks real | Clear fixture names and private provenance manifest | Reviewer verifies aliases/ownership and constrained data fields |
| Cleanup reactivates | No reset-to-active/reuse-old-generation cleanup | Cleanup deny-first plan, no tombstone rewrites |
| Audit erasure | Do not seed fake lifecycle/audits; preserve real backend receipts | Enumerated retained vs removable paths reviewed separately |
| Privileged identity left active | Retention deadline, signed-in session disposal; separately approved disable/revoke | Cleanup verification of account states, with token validity caveat |
| Index incompatibility | Review exact collection query/index shape, no speculative deployment | Runtime distinguish missing index from denial under separate read approval |
| Harness incidental writes | Dedicated Auth-only/client-read harness, no app login recovery | Static/mocked request allowlist; cap HTTP verbs, retries, listeners |
| Cost/quota | Explicit account/read/write caps, small fixtures, no recursive scans | Count attempts, include minimum/read-index/Auth quota costs |
| Historical malicious data | Do not trust matching graphs as provenance or prior empty scans as current | Independent ownership attestation, exact collisions, stop unknown history |

## Safe order and partial-failure handling

1. Review exact private identities, project, database, paths, fields, manifest hash and
   operation caps. Resolve AUP/account/permission blockers only through separate tasks.
2. Gate 1 checks only approved synthetic identities; do not inspect arbitrary users.
3. Prepare and approve exact document collision preflight as part of Gate 3; do not
   infer absence from stale root scans. Validate every field/type/graph locally.
4. Review the eventual provisioner source and no-network dry-run; enumerate all Auth
   and Firestore methods, retries, logs, side effects, limits and stop behavior.
5. Gate 2 creates at most four required accounts, no role custom claims. Privately
   controlled verification method; never silently set real user emailVerified=true.
6. Gate 3 atomically creates twelve allowlisted docs with exists=false preconditions.
   Fail closed on any collision/invalid identity or concurrent customer interference.
7. Masked readback verifies the full manifest, field types, generations and role graph;
   compare Auth identity metadata privately, log only counts and salted references.
8. Gate 4 uses end-user Firebase ID tokens/Client SDK and bounded read-only requests,
   not Admin/IAM tokens. Dispose sessions; no token values in output.
9. Gates 5/6 separately approve denied writes and revocation/listener changes. Denied
   write success is a critical incident: STOP; no automatic compensating writes.
10. Gate 7 cleanup/deactivation is separately approved, followed by bounded readback.

If Auth creation partially succeeds, no Firestore graph is created yet. Record only
sanitized completion evidence; keep unknown status BLOCKED, no account recreation.
If DB commit fails, expected outcome is zero docs; timeout does not prove rollback.
Reconcile exact paths only under approved reads. If DB succeeds and verification
fails, do not delete or grant broader access; stop and inspect approved resources.
Never destructive rollback across services. Existing customer data is untouched.

## Independent approval gates

Each row requires a concrete reviewed command/script/request manifest BEFORE approval.
All counts are planning bounds to refine, never execution authorization.

| Gate | Resource scope / operation count | Mutation / mechanism | Verification, stop conditions and residual risk |
| --- | --- | --- | --- |
| 1: identity reuse check | Four exact UIDs + max four exact controlled emails | Read-only privileged Auth metadata; no listUsers | Ownership attestation, hash references; stop unknown identity/permissions; synthetic provenance not proven by existence |
| 2: new Auth users | Max four manifest users, only missing ones after approved collision check | Auth create via short-lived trusted identity | No collision/adoption, private provider/email verification review; partial success possible; no cleanup implicitly approved |
| 3: fixtures | Twelve exact preflight GETs, one 12-create atomic commit, twelve masked readbacks | Privileged create-only Firestore operations; never Rules bypass for testing | Manifest/hash/type graph exact; any collision/error STOP; residual Admin privilege and race risks |
| 4: client authenticated reads | Four approved logins + 12 core client reads/queries; exact query limits/IDs pinned | Auth session/token issuance plus Firebase ID-token reads; no DB writes | Valid token identity, no incidental profile create; unexpected ALLOW/transport errors STOP; not full app proof |
| 5: attempted denied writes | Separate exact synthetic paths/payloads, e.g. max 8 attempts from acceptance plan | Client mutation requests could COMMIT if defective | Stop first unexpected success; no implicit repair/cleanup; approval must acknowledge write risk |
| 6: revocation/listeners | Separate full lifecycle manifest including canonical/member/audit/receipt counts; cap required before approval | Trusted atomic removal plus bounded listeners and client readback | Disabled callable not activated automatically; no generic cap can be approved before implementation/path review; cached data not erased |
| 7: cleanup/deactivation | Max four created accounts and twelve created docs ONLY if no expanded side effects; exact actions/readback separately enumerated | Account disable/revoke and/or approved fixture cleanup; deletes only if explicitly approved | Provenance/preconditions, preserve lifecycle/audits; concurrent token/data risks; no customer IDs or silent reactivation |
| 8: backend deployment | Only explicitly selected functions/codebase/project after separate review | Deployment, never broad firebase deploy | API/IAM/billing changes separately gated; readback only; deployment does not authorize invocation |

Gate 3 includes production document READ approval independently of Gate 1 Auth reads.
Gate 4 login is a separate Auth operation, not inferred from fixture creation approval.
Gate 6 operation count is deliberately BLOCKED until every write path is known.
Optional RA/G/profile/audit expansions amend scopes/counts; earlier approvals do not
carry over. No live-operation approval is requested in this offline review.

## Cleanup, retention and revocation caveats

Prefer a synthetic-only retention window and separately approved deny-first cleanup:
invalidate/deactivate synthetic membership as an atomic reviewed lifecycle change,
then disable/revoke identities as explicitly approved; delete only narrowly owned
fixtures after provenance and retention review. Disabling Auth alone does not instantly
invalidate every already-issued Firebase ID token or erase client cache. Rules-level
membership revocation and fresh readback are separate evidence. Do not pretend a
create/delete-only fixture tool implements a legitimate removal audit contract.

If lifecycle tooling is unavailable, retain isolated test resources pending a secure
approved cleanup procedure rather than inventing unaudited transitions. No automatic
rollback to broad authenticated Rules. No cleanup can undo information already read.
Reused existing synthetic accounts are not owned by this run and cannot be disabled
or deleted without their own explicit scope. Final verification checks no active
unintended authority remains and records all retained resources with reasons privately.

## Validation and readiness

Source contracts reviewed: workspace-creation.js, membership-generation.js,
workspace-invitations.js and index.js callable wrappers; menu-model.js/menu-service.js;
Rules B; Flutter auth_service/user_profile_service, resolver/session boundary,
inventory/menu/activity/movement models/repositories and index draft. Existing source
fixtures reviewed in firestore.rules.test.js (NOT run), workspace-creation.test.js,
single-workspace-security.test.js and menu-service.test.js. Additional model reads
were necessary to distinguish Firestore timestamps from callable response strings.
No app/source/dependency/config file changed.

Readiness: static design CONDITIONALLY READY for a subsequent provisioner-design
review, live execution BLOCKED. Required missing evidence: approved identity/mailbox
ownership, bounded collision results, available least-privilege auth mechanism,
reviewed dry-run/creation/reconciliation implementation, and audit-safe cleanup.
An offline manifest validator is not enough to approve unimplemented privileged code.

Tests and final checks appear below after actual execution. Runtime authorization,
Auth existence, IAM/billing/API readiness and provisioning are NOT RUN/NOT VERIFIED.

Database report: schema/local Rules/cloud Rules/documents/Auth users UNCHANGED.
Production reads/writes/Auth operations/deployments NONE. Only this local method
review added. No live approvals requested, privileged script implemented/executed,
credentials generated, staging/emulator access, Git add/commit/push or automatic next
phase. All pre-existing uncommitted work preserved.

## Actual offline verification results

Executed from repository root:

```powershell
node --test functions/test/workspace-creation.test.js functions/test/single-workspace-security.test.js functions/test/membership-generation.test.js functions/test/menu-service.test.js
```

PASS: 161 tests, 0 failures, 0 skipped. No emulator/integration tests ran.
An inline Node in-memory manifest check also passed: 4 aliases, 12 unique paths,
3 valid active pairs, 3 mismatched-generation denials, 2 menuDocument serializers,
one observed Owner per synthetic cafe and no UC mapping. Source Rules raw hash
unchanged. These checks imported pure local validators, not Admin SDK/network setup.
Inventory shape was reviewed against InventoryItem.fromMap but was not run through
the Dart parser in this method-review phase; timestamp/provenance/setup code still
needs concrete local dry-run review. No full Flutter suite result is claimed.

Plan matrix/fences/whitespace and `git diff --check` checked after document update;
see task report. No runtime authorization or setup-failure implementation certification
is implied. The actual privileged provisioner remains unimplemented and untested.
