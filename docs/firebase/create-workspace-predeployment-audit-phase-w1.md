# W1: Create Workspace -> Dashboard pre-deployment audit

2026-11-06, Asia/Kuala_Lumpur. P0 onboarding priority; AI/Groq work paused. Local
read-only source audit plus this document only. No fixes, emulator, Firebase/GCP
access, deployment, billing changes, Auth or Firestore operations. Prior cloud
evidence is attributed as prior, not refreshed or treated as current certification.

## Decision

NO-GO for real first-time onboarding/deployment approval now. The first-time Owner
path lacks an email-verification action/refresh flow required by the backend, and
prior evidence says billing disabled/unlinked and createWorkspace absent. Local
backend authorization/atomicity and mocked routing tests pass; they do not remove
these source and external prerequisites. This audit cannot enumerate all runtime
blockers without separately approved runtime evidence.

## Actual source workflow and evidence

1. Startup: lib/main.dart:32 resolves an explicit startup profile; :51 initializes
   Firebase, then emulator routing only if explicitly selected and local notification
   initialization. Unconfigured startup fails closed. :68 SplashPage; :69 named
   routes include /login, /home -> WorkspaceGate and /business-setup. A direct
   /business-setup route has no separate Auth/verified-email route gate; submitting
   still requires a UID and trusted backend authorization, so this is not a bypass.
2. Registration: signup_page.dart:40-82 trims/validates name/email/password, includes
   name <=80, then AuthService.register. auth_service.dart:53 sets a persisted manual-
   login guard BEFORE createUserWithEmailAndPassword (:62). It awaits display-name
   update (:73), creates self profile (:74), signs out (:76). Explicit login is
   required after registration, including reload. Failed post-create profile/sign-out
   does not delete/recreate accounts; user receives a recovery/login message.
3. Profile: user_profile_service.dart:34 reads users/{uid}; existing documents are
   never overwritten. It immediately reads the same User.displayName after SDK
   update, falling back to 'Velora User' when absent, then creates username/email/
   photoUrl/role:'owner'/server timestamps. No reload/currentUser reacquisition or
   submitted-name parameter exists. SDK cache lag can therefore store fallback.
   This is a verified code dependency and runtime risk, not proof every registration
   loses its name. Existing fallback profiles are not automatically repaired.
4. Rules profile contract: docs/firebase/workspace.firestore.rules:49-62 requires
   initial role:'owner', own UID, Auth email and server timestamps. Do NOT remove
   users.role blindly. This is profile metadata, not workspace Owner authorization.
   Profile-write failure can stop register/login completion, but fallback username
   itself is valid and does not block workspace creation or determine authority.
5. Login: AuthService.signIn (:109) signs in, recovers a missing profile, clears the
   pending-registration guard after successful explicit login. :130 explicitly has
   no emailVerified gate. LoginPage:72 routes to WorkspaceGate. SplashPage:36-49
   restores only sessions allowed by the registration guard, otherwise Welcome/Login.
6. EMAIL VERIFICATION GAP: there is no sendEmailVerification, user reload plus
   verified-email check, or forced getIdToken(true) in registration/login/setup/
   workspace provisioning. The only sending UI found is staff_invitation_page.dart:156;
   staff_invitation_service.dart:179-190 reloads/verifies/refreshes for that separate
   invitation workflow. It is not the Owner creation flow and is not a safe assumed
   onboarding workaround. Current setup only displays 'verify email, then sign in
   again' after backend rejection, without an Owner send/resend/confirmation action.
7. WorkspaceGate (_resolve at workspace_gate.dart:50): transactionally resolves
   canonical membership. Only missingMembership routes to BusinessSetupPage (:73).
   Inconsistent/unauthenticated/unavailable states display errors, never fall back
   to a global workspace or grant home access. Successful resolution creates a
   WorkspaceSession and wraps default HomePage in WorkspaceSessionBoundary.
8. Business Setup: business_setup_page.dart:45 stores in-memory draft/controllers;
   three steps are business details -> inventory preferences -> summary/create.
   business_information_step.dart:32 rejects empty business name; type must be one
   of Restaurant/Cafe/Bakery from business_setup_draft.dart. Address optional. Unit
   kg/g/L/ml/pcs, reminder days 1/3/7, booleans and defaults match backend choices.
9. Back control: setup :65 checks submitting/leaving, moves step 3->2->1 using the
   existing draft/controllers. Step 1 pops an available route, otherwise replaces
   stack with existing LoginPage to avoid gate->setup loops. PopScope and toolbar
   use this handler. In-page step values survive; leaving/recreating the page does
   not persist the draft. Back is not a Create Workspace operation.
10. Submit (:108): synchronous _submitting guard and disabled button prevent repeat
    taps. Constructs the seven-field request from draft. No direct workspace client
    writes. Successful callable is followed by CANONICAL resolution, not trust of
    returned role/cafeId. Accepted/uncertain outcome suppresses further provisioning
    in that page instance and changes action to Recheck Workspace (:263).
11. Client transport: workspace_provisioning_service.dart:75-81 invokes
    createWorkspace in asia-southeast1 and unwraps SDK response.data. :110 validates
    explicitly resolved options against initialized Firebase app; :135 checks UID
    before/after transport. It accepts a boolean created and string cafeId, then
    returns only created. Discarding cafeId is intentional: resolver derives trusted
    context. Client does not persist cafeId as authority or grant a session directly.
12. Backend: index.js:99 exports createWorkspace as v2 onCall; current resource
    settings memory256MiB, cpu1, timeout30, min0, max1, concurrency1. Domain function
    workspace-creation.js:118 validates Auth UID, requires trusted email_verified
    ===true (:128) before input/ID allocation/transaction, rejects caller identity/
    role/workspace fields and unknown input. Admin SDK bypasses Rules; domain checks
    and transaction are therefore mandatory. No Groq dependency in this callable.
13. Atomic creation: :142 transaction reads user_cafe_memberships/{uid}; new Owner
    creation uses THREE create writes: cafes/{cafeId} (:187), its members/{uid}
    (:203), canonical mapping (:212). Active status/schemaVersion:1 and Owner link
    agree; both membershipGeneration fields omitted intentionally = legacy pair 0.
    No inventory/menu docs are required or auto-created. Server timestamps used.
14. Retry/idempotency: existing valid Owner/cafe/member plus normalized identical
    business/preferences returns {cafeId,created:false}. Staff membership, inactive/
    conflicting canonical data, role/generation inconsistency or changed existing
    workspace payload fails. Concurrent same-account creates conflict on canonical
    mapping, not just UI state. No separate client idempotency key is required by
    this actual contract. Returned new case is {cafeId,created:true} (:220).
15. Errors: expected WorkspaceCreationError maps to HttpsError. Client has exact
    email-error-message matching for emailUnverified; other failed-precondition
    becomes existingMembership. Generic client-safe messages do not forward raw
    server exception text. index.js:122 still logs the raw unexpected Error object:
    fixed log prefix is not proof error contents cannot contain sensitive details.
16. Resolution/routing: workspace_resolver.dart:36-77 server transaction reads self
    mapping, cafe/member and Owner links (3 unique records for Owner, 5 Staff).
    Validates active/schema/identity/role and paired generations, including Owner.
    UID is rechecked after reads; no users.role authorization or offline global
    fallback. Setup :124 creates session only from resolver result, replaces route
    with /workspace-home inside WorkspaceSessionBoundary (:128), child HomePage.
17. Session boundary: authoritative identity and 3/5 server document listeners,
    no cache-only/pending proof, initial 15s guard, resolver revalidation. Failure
    invalidates session/removes protected route stack. Slow/offline/denied state
    must not become a cached-success dashboard. Rules dependency read budgets and
    actual listener behavior remain runtime-unverified.
18. Home/dashboard: home_page.dart:33 creates a shared scoped inventory repository;
    Dashboard receives it and the verified session (:37). Home renders only selected
    page (:104), not every tab's State. dashboard_page.dart:53 listens to inventory;
    empty server results calculate zero metrics and render DashboardContent, no stock
    or menu seed required. RecentActivityCard is not supplied an activityStream and
    shows its disabled/placeholder branch rather than a global activity query;
    NotificationBell is callback-driven, not a hidden notification write/listener.
19. Inventory: workspace_inventory_repository.dart:87 scopes to
    cafes/{verifiedCafeId}/inventory, requires active session before mapping results.
    Snapshot metadata filters exclude cache/pending snapshots. Empty collection is
    valid. Active/archive filtering is client-side and collection subscription is
    unbounded, a growth/cost issue rather than empty-workspace blocker.

## Exact cross-layer contract

| Field | Flutter | Backend |
| --- | --- | --- |
| businessName | trimmed draft String | normalized whitespace, length 2-80, no control chars |
| businessType | Restaurant, Cafe (accented), Bakery | accepted/normalized to those 3 for new creation |
| address | optional trimmed String | default empty, maximum 200, no control chars |
| inventoryUnit | kg/g/L/ml/pcs, default kg | same allowed set/default |
| lowStockAlerts | bool, default true | bool/default true |
| expiryReminders | bool, default true | bool/default true |
| reminderDays | int1/3/7, default3 | same set/default |
| success | SDK .data with created bool/cafeId string | exactly {cafeId,created} |

Mismatch: Flutter step validation is only nonempty name/type and has no matching
2-80 name bound, control-character validation or address length bound. A one-letter
name or >80-name/>200-address reaches final create then fails invalid-argument.
Server rejection is secure; local UX is incomplete for inputs it currently accepts.

## Lost response, restart and failure behavior

- Not-found callable: specific service-not-found message; no claim of creation.
- Timeout/unavailable/internal/invalid response: creation may have committed;
  setup records uncertainty, allows resolution only, never auto-resubmits.
- Known accepted but denied/slow resolver: Recheck Workspace, no new create.
- Unknown outcome with no canonical membership: recheck can remain stuck without
  an in-page verified no-commit retry path; restart/login reconstructs the flow.
  Do not blindly clear uncertainty on one failed/slow read. A separately reviewed
  recovery action needs authoritative absence and request identity semantics.
- Cold restart: manual-login guard and current Auth -> WorkspaceGate -> canonical
  resolver. Existing workspace goes home; missing mapping goes setup. Draft and
  local uncertainty flags do not persist, but server single-workspace checks still
  prevent duplicate ownership. Same normalized payload retry is idempotent;
  changed payload after a real creation rejects rather than overwrites history.
- Resource-exhausted (capacity/429) lacks a dedicated client mapping and falls to
  internal, which becomes uncertainty/recheck-only. Runtime overload impact needs
  reviewed classification, not weakened transaction safety.

## Dashboard vs inventory read vs mutation gates

Dashboard ENTRY needs explicit profile, signed-in identity, valid canonical graph,
successful server authority snapshots and readable scoped inventory (even empty).
Rules B local source grants these reads for a consistent Owner; new backend writes
match that schema. This is static compatibility, NOT deployed/runtime verification.
Profile creation also matches local self-profile Rules; users.role must stay owner
for the current initial-profile contract.

Inventory READ needs the same active graph and scoped collection query; no mutation
callable or pre-existing item is necessary. Direct /add-item,/suggestions,/alerts
routes without context are not authorization shortcuts; their missing-session
behavior should remain fail-closed. Some dashboard shortcut routes lack passed
session (e.g. suggestions); defer unrelated AI navigation while AI work is paused.

Later inventory MUTATIONS need separately deployed createInventoryItem,
updateInventoryItem, adjustInventoryStock and setInventoryLifecycle and current
episode/version/idempotency contracts. Deploying only createWorkspace does not
enable them. Rules deny direct client scoped inventory/movement writes, correctly.
Stock-history/activity queries have pagination/index prerequisites; current draft
inventory_movements itemId/createdAt index is not referenced as a deployed index by
root firebase.json. Cloud existence/compatibility NOT VERIFIED. Do not restore
legacy global inventory/activity/notification services to work around unavailable
Functions or indexes. Dashboard empty read path needs no such seed/index.

## Prioritized blocker matrix

| Priority / class | Evidence | User impact | Minimal remediation / required category | Exact verification |
| --- | --- | --- | --- | --- |
| P0 confirmed source gap: Owner verification flow missing | AuthService:62-76/:130, provisioning:110-148; only staff flow sends/verifies/refreshes | New unverified Owner cannot satisfy backend :128 | Local code: reviewed send/resend + confirmation/reload/current-user + forced token refresh, account-change and no-auto-create guards; retain backend verified-email gate | Mock send/reload/token tests, unverified create denied, verified refreshed UID reaches provisioning once; real mail/Auth only after separate approval |
| P0 external: createWorkspace absent in prior successful list | production-availability-check.md, local index.js:99 is not deployment | Service cannot reach intended callable | Deployment after prerequisites; exact function only | Separately approved metadata list/readback and later bounded authenticated invocation; no cloud check this batch |
| P0 external: billing disabled/unlinked in prior approved GET | production-prerequisites.md Command2 evidence | Intended Gen2 deployment cannot proceed | Billing/account approval after current eligibility/currency/cost review | Separately approved read-only prerequisites first; no linking/activation inferred |
| P1 security/runtime prerequisite | local Rules source and prior deployment, resolver/authority listeners | Denied profile/authority/inventory reads could stop login/home despite local schema alignment | Configuration/runtime evidence, no permissive Rule patch | Offline static contract now; later bounded synthetic authenticated profile/Owner/isolation acceptance |
| P1 source UX mismatch: setup bounds | business_information_step.dart:32-90 vs workspace-creation.js:65-87 | One-letter/long/control input fails only on final call | Local frontend validation matching server; no backend relaxation | 1/2/80/81 name, 200/201 address, controls and valid types/defaults tests |
| P1 recovery/capacity risk | setup:144-161, provisioner _mapError | Uncertain/no-commit or overload can leave recheck-only UI | Separately reviewed recovery/classification code; do not auto-retry unknown write outcomes | Mock 429/unavailable/timeout, absent/late canonical commit, restart, changed payload; never duplicate create |
| P1 later mutation deployment | Home add path, inventory callable services, Rules deny writes | Empty dashboard works but Add/stock/edit cannot succeed without their backends | Separate scoped security/deployment batch, outside W1 first create scope | Offline contracts now; later approved individual mutation acceptance with audit/version checks |
| P1 release/runtime readiness | package Node22/localNode24, Android debug release signing, API/IAM/AUP unverified | Build/deployment or real device access may fail | Toolchain/configuration/prerequisite review, approval before cloud changes | Node22 offline tests; signed build/manifest review and separately approved cloud metadata |
| P2 display-name cache risk | auth_service.dart:73-74 and user_profile_service.dart:40-44 | Fallback username/profile name; not workspace ownership | Local submitted-name/current-user strategy + tests; existing-profile repair would be separate data task | Mock stale User after update, verify entered username persists without replacing existing profile |
| P2 observability/logging hardening | index.js:122 raw Error logging; no App Check/rate admission | Possible diagnostic leakage/abuse-cost exposure | Separate redacted logging and App Check/rate policy review | Synthetic errors never emit secret/raw request; client compatibility tests before enforcement |
| P2 cost/secondary UI | unbounded scoped inventory stream; placeholder recent activity | Growth in reads; recent activity not fully wired | Later scoped performance/activity work | Subscription/query measurement and pagination tests, no global fallback |

## Deployment and cost readiness

Project config targets velora-73222; functions source functions, codebase workspace;
package main src/index.js, Node22, installed firebase-functions7.4.0/Admin14.5.0.
Current local tests run Node24.15.0, not Node22. Versions satisfy declared package
engines by inspection; actual Node22 execution/build is NOT VERIFIED this batch.
createWorkspace does not require a Groq key/secret or any new AI quota schema.

Proposed command ONLY, NOT EXECUTED, from repository root after separate approval:

```powershell
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only functions:workspace:createWorkspace --project velora-73222
```

No broad deploy, Rules, indexes or AI exports. Deployment analysis may load other
existing modules; build API/runtime IAM, Cloud Build/Artifact Registry/Cloud Run
prerequisites and any AUP warning need separately approved review. Stop rather than
silently enable APIs/change IAM or accept new billing/cleanup prerequisites.

Current local limits are explicitly 256MiB/CPU1/timeout30/min0/max1/concurrency1.
They bound scale, not total spend; cold starts, SDK transaction retries, sustained
traffic and queue/capacity errors remain. New creation normally reads one canonical
document and writes three authority records; same-payload existing Owner retry reads
three records. Client profile/resolver/authority listeners/inventory add reads;
builds, artifacts and logs add separate costs. No min warm instance proposed.

RM5 alerts are a proposal, not verified configured budgets. No account or budget
metadata read here. Alerts at 50/90/100% do not impose a hard cap; account currency,
recipients, delayed reporting and separate billing approval still matter. Prior
billing-account discovery showed closed accounts; status/suitability may be stale.
Do not select/reopen/link any account in this phase.

## Minimal dependency-ordered plan and separate gates

1. GO to propose a small local Owner verification/reload/token-refresh batch and
   matching boundary validations, with tests. This audit itself does not authorize
   edits. Keep backend guards/profile role unchanged. Username is secondary.
2. GO to expand offline onboarding tests, especially full verified flow, stale Auth
   user/name and capacity/unknown outcome recovery. Isolated fakes only, no emulator.
3. NO-GO billing activation: require explicit account eligibility/linkage/currency/
   cost acceptance and prerequisite approval. RM5 budget status not established.
4. NO-GO scoped createWorkspace deployment now: first source remediation review,
   Node22 validation, cloud/API/IAM/AUP/billing readiness and exact deployment approval.
5. NO-GO first real create test: verified synthetic identity + exact bounded writes/
   invocation approval, deployed callable metadata and Rules/profile compatibility
   acceptance; define safe evidence handling, no auto retries or data cleanup.
6. CONDITIONAL GO dashboard/inventory OFFLINE functional testing (done below), but
   NO-GO claimed real first-user dashboard/read acceptance until steps above and
   authenticated bounded runtime approval. Later mutation tests need their own
   deployments/approvals; do not make those a hidden prerequisite for empty home.

## Offline verification executed

Backend, functions directory:
- node --test test/workspace-creation.test.js test/single-workspace-security.test.js
  test/workspace-resource-config.test.js test/firestore-rules-contract.test.js:
  37 passed, zero failed/cancelled/skipped/todo, exit0.
- npm.cmd test: 367 passed, zero failed/cancelled/skipped/todo, exit0. Coverage overlaps.

Flutter, root, installed flutter.bat with --no-pub:
test/auth_flow_test.dart test/business_setup_test.dart
test/workspace_provisioning_service_test.dart test/workspace_resolver_test.dart
test/workspace_session_test.dart test/dashboard_page_test.dart
test/workspace_inventory_repository_test.dart test/profile_validation_test.dart
--reporter expanded: 141 passed, zero failed/skipped, exit0.

Scoped flutter analyze --no-pub on AuthService, UserProfileService, provisioner,
resolver, BusinessSetupPage, WorkspaceGate, session boundary, HomePage, DashboardPage
and inventory repository: no issues, exit0. Full-project/default Flutter suite and
visual/browser/Android runtime NOT RUN. Tests check mocks/static contract and source
routing, not mail delivery, real Firebase tokens, deployed Rules/Functions or costs.
No new tests/source added. Groq development/tests/invocation not performed.
node --check functions/src/index.js and functions/src/workspace-creation.js: PASS,
exit0. git diff --check and report whitespace: PASS (existing LF/CRLF warnings).
Local Rules SHA-256 unchanged:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

DATABASE CHANGE REPORT: proposed and production schema UNCHANGED. Local/production
Rules, indexes, documents and Auth users UNCHANGED. Production reads/writes NONE;
deployments NONE; billing unchanged. ADD this report only, MODIFY/DELETE none.
Existing uncommitted work preserved; no Git add/commit/push/history operations.
STOP for review before remediation, billing, deployment or any live E2E test.
