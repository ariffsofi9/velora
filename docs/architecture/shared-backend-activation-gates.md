# S5.40 - Shared backend activation gates and platform durability handoff

Date: 2026-11-12 (Asia/Kuala_Lumpur). **OFFLINE HANDOFF COMPLETE; LIVE ACTIVATION NO-GO.**

This record implements only S5.40 in [the controlling manifest](s5-30-shared-firebase-adapter-plan.md). Scope: ADD this file; MODIFY none; DELETE none; all other files unchanged. No host, credentials, storage implementation, client integration, deployment or data creation is authorized by this record. No network, device, emulator, simulator, Miniflare/workerd or `.wrangler/` inspection occurred.

## 1. Evidence boundary and milestone reconciliation

Working-tree evidence, not committed release provenance: branch `main`, HEAD `6cfae84dfbd9ca11ceb4a99e2585cc5d9ae97c98`. Existing tracked edits and untracked work remain preserved. [PROJECT_STATUS](../PROJECT_STATUS.md) and [ROADMAP](../ROADMAP.md) describe the older `03e853a` checkpoint and remain unchanged; their historic feature inventory does not supersede current source.

| Milestone | Current source evidence | Qualification limit |
| --- | --- | --- |
| S5.30 | Controlling architecture/sequence manifest | Planning baseline; its earlier progress table is historical. |
| S5.31 | [Inventory HTTP](../../functions/https/inventory-http.mjs), canonical acknowledgement tests | Offline acknowledgement hardening; no browser/host proof. |
| S5.32 | [Google HTTP](../../functions/backend/google-http.mjs), [OAuth](../../functions/backend/google-oauth.mjs), [identity/accounts](../../functions/backend/firebase-identity.mjs) | Injected TEST-only transport/signer; synthetic certificate/account evidence. |
| S5.33 | [Store](../../functions/backend/firestore-store.mjs), [codec](../../functions/backend/firestore-codec.mjs) | Offline native-wire fake proves supported contracts, not real Firestore/IAM. |
| S5.34 | [Application](../../functions/backend/application.mjs), [HTTP policy](../../functions/backend/http-policy.mjs) | Factory with no listener/default credentials/network. Admission is process-local, not distributed. |
| S5.35 | [Inventory observer](../../functions/src/inventory-recovery.js) | Read-only, historically bound receipt/audit observation. Absence remains unknown. |
| S5.36 | [Mutation journal](../../lib/services/mutation_recovery_service.dart), [inventory transport](../../lib/services/workspace_inventory_https_transport.dart) | Injected CAS/digest foundation; journal optional on transport; no OS persistence provider or production wiring. |
| S5.37 | [Workspace](../../functions/https/workspace-http.mjs), [Staff](../../functions/https/staff-http.mjs), [invitations](../../functions/https/invitation-http.mjs) | Canonical onboarding, roster/removal and private rejoin wiring tested offline. Rejoin defaults off. |
| S5.38 | [Menu HTTP](../../functions/https/menu-http.mjs) | Five canonical menu routes, query isolation and receipt/version behavior offline. |
| S5.39 | [AI HTTP](../../functions/https/ai-http.mjs), [canonical handler](../../functions/src/secure-groq-handler.js), [quota](../../functions/src/ai-quota.js) | Two routes only with explicit trusted `ai` injection. No live Groq; no saved result or consumption workflow. |
| S5.40 | This record | Evidence, decisions, conditional scopes and gates only. |

S5.31-S5.39 source foundations are present; S5.32-S5.39 were reported complete offline in the preceding milestones. This milestone reran the Node suites below. Earlier Flutter counts are historical and are not included in this milestone's test total.

## 2. Route coverage versus privileged callers

All 19 declared routes are POST JSON with verified Bearer identity. `OPTIONS` applies only to configured routes; CORS is not authorization. AI's two routes are absent unless trusted dependencies are explicitly supplied. No endpoint is hosted by these factories.

| Existing caller / operation | Shared HTTPS coverage | Remaining client/recovery work |
| --- | --- | --- |
| [Create service](../../lib/services/workspace_inventory_create_service.dart): `createInventoryItem` | `/inventory/create` | Inject existing `HttpsWorkspaceInventory`; require durable journal before enabling mutations. |
| [Update service](../../lib/services/workspace_inventory_update_service.dart): `updateInventoryItem` | `/inventory/update` | Preserve metadata-only edits, captured episode/version and stable key. |
| [Stock service](../../lib/services/workspace_inventory_stock_service.dart): `adjustInventoryStock` | `/inventory/adjust-stock` | Preserve positive integer adjustment, nonnegative result and atomic audits. |
| [Lifecycle service](../../lib/services/workspace_inventory_lifecycle_service.dart): `setInventoryLifecycle` | `/inventory/lifecycle` | Preserve archive/restore deletion transforms; never use hard deletion. |
| Inventory recovery | `/inventory/reconcile` | Explicit read-only observation using original operation/request; no automatic resend or inference of noncommit. |
| [Provisioner](../../lib/services/workspace_provisioning_service.dart), [business setup](../../lib/screens/business_setup/business_setup_page.dart) | `/workspace/create` | Current default is `FirebaseWorkspaceProvisioner` with a client Firestore bootstrap transaction, not HTTPS. Migrate the existing interface explicitly; avoid a universal membership prerequisite. Review stale production-specific failure copy when wiring. |
| [Invitation service](../../lib/services/staff_invitation_service.dart) | `/staff/create`, `/staff/revoke`, `/staff/redeem`, `/staff/reconcile` | [HTTPS transport](../../lib/services/staff_invitation_https_transport.dart) and [journal interface](../../lib/services/invitation_recovery_service.dart) exist but need durable provider/session integration. Reconciliation never reconstructs a lost code. Rejoin requires trusted internal opt-in and private account lookup, not a new route. |
| [Roster service](../../lib/services/team_members_service.dart): `listTeamMembers` | `/staff/list` | Default remains callable-backed. Retain canonical Owner/Staff visibility and account lookup outside transaction callbacks. |
| Canonical `removeStaffMember`; [team page](../../lib/screens/team/team_management_page.dart) | `/staff/remove` | Backend coverage is not a complete client removal workflow. Preserve independent `expectedActorGeneration` and target `expectedGeneration`; old replay cannot remove a later episode. Existing callable removal remains disabled. |
| [Menu repository](../../lib/repositories/workspace_menu_repository.dart): `createMenuItem`, `getMenuItem`, `listMenuItems`, `updateMenuItem`, `setMenuItemLifecycle` | `/menu/create`, `/menu/get`, `/menu/list`, `/menu/update`, `/menu/lifecycle` | Default remains callable-backed. Build explicit HTTPS adapter, strict acknowledgements, stable retry keys and uncertainty UX; current inventory journal is not a universal menu journal. Staff may mutate availability only. |
| [Secure AI service](../../lib/services/secure_ai_service.dart), [callable adapter](../../lib/services/firebase_secure_ai_transport.dart): `issueWorkspaceAiTicket`, `generateWorkspaceAiRecipes` | `/ai/issue`, `/ai/generate` | Build HTTPS adapter; remove the client operation selector at the route boundary. Preserve ticket digest, fences, quota and session checks. Callable adapter is opt-in/disabled by default. No retry after uncertain provider dispatch. |
| [Demo recipe clients](../../lib/services/fake_recipe_client.dart), [mock client](../../lib/services/ai1_mock_recipe_client.dart) | No replacement production route for `suggestRecipes` / `suggestMockRecipesV2` | Demo-only interfaces are not secure AI fallbacks. Do not activate or port emulator routing. |
| Firebase Auth sign-in/verification/reset; [profile service](../../lib/services/user_profile_service.dart); scoped inventory/history reads | Auth SDK / existing scoped repositories, not new privileged routes | Preserve project selection and Rules. Profile fields never confer role/cafe authority. Inspect actual Rules before TEST acceptance. |
| Account deletion, cafe closure, ownership transfer | **MISSING: no approved HTTPS contracts** | Separate authority, retention, invalidation and recoverable receipt design required; do not infer coverage from workspace creation/removal. |
| Recipe saving, recipe/menu linkage and Cook Now | **MISSING: no approved scoped persistence/consumption routes** | [Legacy recipe saving](../../lib/logic/ai_recipe_save_service.dart) accesses global `ai_recipe_suggestions`; [Cook Now](../../lib/logic/cook_now_service.dart) throws unavailable. Define separate scoped recipes and atomic stock/movement/activity contracts before enabling either. |
| Legacy global inventory/records, activities, notifications, AI cache/quota | **EXCLUDED** | [Legacy inventory](../../lib/logic/firestore_service.dart), [activity service](../../lib/services/activity_service.dart), notification services and legacy AI helpers are not security-approved replacements. No global fallback, cleanup endpoint or quota reset. |

The [callable entrypoint](../../functions/src/index.js) initializes Firebase Admin; it is not a suitable external runtime entrypoint and must not be imported there. Existing callable exports, direct bootstrap code and legacy files being present do not establish deployed behavior or authorize their removal.

## 3. Runtime, host, cost and IAM decisions

**Qualification target:** a compatible external Node runtime, initially the package-declared Node 22 target. This selects a compatibility target, not a hosting provider. Cloudflare Workers remains an alternative candidate inherited from S5.30, not a selected/verified deployment. No eligible no-billing host has been demonstrated. Do not fabricate an endpoint, account, region, plan, service principal or deploy configuration.

| Fact | Direct evidence / status | Required next evidence |
| --- | --- | --- |
| Local runtime | `node --version`: v24.15.0; PATH resolves `C:\Program Files\nodejs\node.exe` | Node 22 **NOT VERIFIED**: not found in PATH or conventional local nvm/fnm directories. No installation attempted. |
| Runtime APIs | Node offline suites exercise ESM/CJS, `node:crypto`, X509/RSA, WebCrypto, Fetch/Request/Response, streams and AbortController | Hosted equivalents, bundling/CPU/memory/time ceilings and Node 22 execution remain untested. Local Node success is not Workers compatibility. |
| Firebase projects | Source pins backend to TEST `velora-spark-test`; PRODUCTION `velora-73222` is protected | Verify actual TEST project, Auth APIs, Firestore database, service enablement and Spark eligibility only after separate approval. No PRODUCTION access. |
| Host capacity/cost | **BLOCKED / UNVERIFIED** | Dated authoritative provider terms plus account state: no billing/card/prepayment, request/CPU/duration/memory/subrequest/egress limits, secret storage, logs, privacy/region and hard-failure behavior at exhaustion. No current numeric free-tier claim is made. |
| Firebase/Groq limits | **BLOCKED / UNVERIFIED** | Dated Firebase Spark API/read/write/storage limits and Groq model/free-tier/region/retention/rate eligibility. Never use Blaze, Cloud Functions deployment or billing as a workaround. |
| Credential trust | OAuth accepts an injected project-bound signer; no live credential is supplied | Prefer eligible short-lived federation if verified; key-based signer remains a separately reviewed alternative, not authorized key creation. Demonstrate rotation/revocation and secret facility before use. |
| IAM permissions | **BLOCKED / NOT INSPECTED** | Dedicated TEST principal: only necessary Firestore transactions/queries and Firebase account lookup. Verify exact permission names/roles against current provider material and actual grant, including private email lookup if rejoin is approved. No Owner/Editor, IAM/billing/deploy/account-deletion rights. Do not grant maintenance delete merely because the store supports it. |
| Authorization | Canonical domains recheck membership/cafe/Owner links inside transactions | Admin/IAM access bypasses client Rules. IAM is not per-cafe authority. Auth revocation and Firestore commit are separate systems; fresh checks do not promise instantaneous cross-system atomic revocation. |
| Abuse controls | HTTP policy has a local concurrent cap (default 8); canonical AI has durable usage/locks | Host/distributed admission, invalid-token/key-refresh abuse, proxy limits and cross-instance behavior remain blocked. An in-memory counter is not a distributed quota. |

Any candidate requiring billing, deposit, paid API eligibility or unavailable trust capabilities is rejected for this constrained release. Unknown feasibility is not proof that all Spark-compatible architectures are impossible; continue offline with integrations disabled until a candidate is proven.

## 4. Durable platform storage selection and contract

**Provisional implementation design:** transactional IndexedDB for Web; transactional SQLite for Android/iOS. These are selected storage mechanisms to qualify, not approved packages, installed adapters or verified durable implementations. There is currently **no eligible, tested platform provider**. Provider/library selection, installed-tool feasibility and device/browser proofs remain release blockers. `pubspec.yaml` contains `shared_preferences` but no explicit SQLite journal dependency; no dependency change is made or authorized here.

- Web: one IndexedDB read-write transaction must check expected revision/absence and atomically store the complete next record. Await transaction completion, not request success alone. Exercise competing tabs, aborted transactions, quota/private-mode/unavailable storage, eviction/cleared data and browser restart. If persistence cannot be acknowledged, deny dispatch. Storage loss never proves server noncommit; do not silently create replacement operations.
- Native: one SQLite transaction with a unique journal key and conditional revision update/insert; compare affected-row count and acknowledge durable commit. Qualify locking across isolates/processes, crash points, disk-full/corruption, write synchronization, backup/privacy and app upgrade. Select the native provider/plugin only after its supported platforms, installed dependencies and transactional guarantees are reviewed. No Preferences read-then-write or in-memory mutex substitutes.
- Implement both existing interfaces: `MutationJournalPersistence.read(key)` / revision-based `compareAndSet`, and `InvitationJournalPersistence.read(projectId, uid)` / expected-value `compareAndSet`. Their CAS signatures differ; share storage only through tested adapters, not a renamed generic expectation field. Supply a reviewed SHA-256 implementation for inventory journal integrity without conflating it with server receipt digests.
- Key by project/UID/operation/stable key and retain original cafe/generation/version/payload binding. Persist prepared and dispatched state before network dispatch. A prepared crash survivor is potentially dispatched. Do not refresh expectations, change keys or replay POSTs on restart/reconnect/token refresh.
- Logout/session replacement stops dispatch and hides prior-session results but does not delete uncertainty. Keep partitions isolated, bounded and private; retain prior evidence when later attempts are definitely rejected. Explicit reconciliation remains read-only. An invitation secret, token or Groq credential must never enter the journal.
- Require durable journal injection for live inventory and invitation mutations. The optional inventory journal constructor parameter is not an activation policy. Unsupported platforms/storage failures keep mutation controls disabled. Menu, removal, onboarding and AI need operation-specific recovery decisions rather than an assumed extension of inventory records.

## 5. Bounded follow-on manifests (proposals only)

These paths identify reviewable future work, not S5.40 edits or approval to implement. Each phase must first publish a final ADD/MODIFY/DELETE/UNCHANGED allowlist and obtain its own scope authorization. DELETE defaults to none. If a chosen provider requires another file, revise that phase's manifest before editing.

| Phase | Exact proposed paths / boundary | Prerequisites and stop condition |
| --- | --- | --- |
| R1 - offline Node entrypoint qualification | ADD `functions/runtime/node-entry.mjs`, `functions/test/node-runtime.test.mjs`; UNCHANGED canonical domains, `functions/src/index.js`, Flutter and deployment files | Select Node host/runtime interface first. Adapter injects Google/provider transport, signer and secret; validates immutable bindings; no auto-listen/import side effects or default credentials. Prove Node 22 with existing local runtime only, or remain blocked. No network activation in this phase. |
| P1 - shared/Web journal qualification | ADD `lib/services/platform_journal_store.dart`, `lib/services/platform_journal_store_web.dart`, `lib/services/platform_journal_store_stub.dart`, `test/platform_journal_store_test.dart`; UNCHANGED current journal/domain interfaces | Qualify IndexedDB interop/library and test tooling first. Both CAS adapters must pass concurrent-writer/rollback tests. Real multi-tab/restart evidence requires separately approved browser work; mocks cannot close durability gate. |
| P2 - native journal qualification | ADD `lib/services/platform_journal_store_native.dart`, `test/platform_journal_store_native_test.dart`; MODIFY `lib/services/platform_journal_store.dart`; provider-specific files **UNRESOLVED** | SQLite package vs native bridge is not selected. Thus this is not an executable final file manifest. Package/lockfiles or Android/iOS bridge changes must be enumerated after selection; no installation/build/device execution implied. |
| C1 - inventory composition | ADD `lib/services/shared_backend_client_config.dart`, `lib/services/shared_backend_client_scope.dart`, `test/shared_backend_client_scope_test.dart`; MODIFY `lib/main.dart`, `lib/screens/auth/workspace_session_boundary.dart`, `lib/services/workspace_inventory_https_transport.dart` | After storage and host contracts pass, choose a single explicit transport at the verified session boundary; inspect every inventory service construction before finalizing scope. No callable fallback, retrying client or fresh key after uncertainty. No live startup opt-in until TEST gates pass. |
| C2 - onboarding/Staff clients | ADD `lib/services/workspace_https_provisioner.dart`, `lib/services/staff_https_service.dart`, `test/workspace_https_provisioner_test.dart`, `test/staff_https_service_test.dart`; MODIFY `lib/services/shared_backend_client_scope.dart`, `lib/screens/business_setup/business_setup_page.dart`, `lib/screens/team/staff_invitation_page.dart`, `lib/screens/team/team_management_page.dart` | C1 composition file is proposed, not present. Reuse current provisioner/roster interfaces and invitation HTTPS journal; finalize removal UI/uncertainty and actor/target generation contracts before implementation. |
| C3 - menu/AI clients | ADD `lib/services/menu_https_transport.dart`, `lib/services/secure_ai_https_transport.dart`, `test/menu_https_transport_test.dart`, `test/secure_ai_https_transport_test.dart`; MODIFY `lib/services/shared_backend_client_scope.dart`, `lib/screens/menu/menu_page.dart`, `lib/screens/suggestions/suggestions_page.dart` | Preserve existing repository/service interfaces and strict outputs; menu recovery contract must be reviewed. AI lost result remains unavailable; no result retrieval or replacement ticket to bypass quarantined claims. |
| D1 - actual deployment/configuration | **BLOCKED: no final path allowlist** | Host/product/account/region, runtime, credential facility, endpoint and origin choices are unknown. After authoritative no-billing qualification, enumerate exact host config/entrypoint/secret-binding/client-config files and TEST-only actions. No guessed `wrangler` file, deployment command or `.wrangler/` inspection. |

R1/P1 names are bounded proposals, not guarantees that those paths alone suffice. C1-C3 require a new construction-site audit after prior phases; additional UI/test/dependency files must appear in the later final manifest. A provider-specific deployment or native-persistence manifest cannot truthfully be finalized before those choices are known. This unresolved state is part of the handoff, not permission to broaden scope.

Account lifecycle, scoped saved recipes, recipe/menu linkage and atomic Cook Now each require a separate canonical contract and later exact file manifest. They are not included in R1-D1 and are not satisfied by AI generation or menu CRUD.

## 6. Activation gate ledger

No live gate is PASS. Every closure requires dated direct evidence, exact project/endpoint/principal/runtime and the responsible verification run. A historical claim or offline fake cannot substitute.

| Gate | Current status | Closure evidence |
| --- | --- | --- |
| G1 - eligible host, Spark and IAM | **BLOCKED** | Authoritative terms plus actual no-billing TEST account/API/trust/least-privilege state; all unknown facts in section 3 resolved. |
| G2 - real Firebase identity/account checks | **NOT TESTED / BLOCKED** | Real TEST token signature/aud/iss/time, rotation, disabled/unverified/revoked account rejection and wrong-project denial before dispatch. No PRODUCTION credentials. |
| G3 - real Firestore transactional behavior | **NOT TESTED / BLOCKED** | Actual contention/read isolation, create/update preconditions, definite abort limits, uncertain commit observation, server timestamps, both archive-field deletions and linked stock/activity audits. Query cursor/filter/look-ahead and malformed/foreign results remain bounded. |
| G4 - deployed security/host boundary | **NOT TESTED / BLOCKED** | Actual Rules/indexes, endpoint/project/principal binding, exact origins, TLS, redirect rejection, secret isolation/redacted logs, cross-instance admission and no host/proxy/client mutation retries. Repository drafts are not deployed evidence. |
| G5 - durable journal and session recovery | **NOT TESTED / BLOCKED** | Real tab/process competition, acknowledged durable CAS, crash/restart at every dispatch boundary, logout/account/workspace switch, disk/storage failure and pending evidence retention. Both journal interfaces qualified. |
| G6 - explicit client coverage and missing workflows | **BLOCKED** | Approved final client manifests, single transport selection, disabled unsupported controls and no callable/global fallback. Account lifecycle, recipes and consumption need separate contracts and tests. |
| G7 - browser/physical devices | **NOT RUN / BLOCKED** | Chrome preflight/TLS/error/redirect behavior; physical Android APK build/install with recorded project/endpoint, network loss/stale session/process death/recovery. Physical iOS and tablet evidence required for corresponding support claims; no simulator substitute. |
| G8 - F&B UAT | **NOT RUN / BLOCKED** | Cafe/bakery/restaurant Owner onboarding; Staff invite/remove/rejoin; inventory create/edit/in/out/history/archive/restore; menu availability/recipes; AI quota/error behavior; reconnect/uncertainty and atomic consumption consistency; tablet layouts, defects and unresolved operations recorded. |

## 7. Safe rollout, disable and evidence retention

After separate approval only: qualify isolated TEST backend -> explicitly opt in TEST clients on physical devices -> F&B UAT -> separately approve PRODUCTION binding/configuration and rollout. Current shared backend is TEST-only; no production fallback or production-enabling edit is implied.

Before any later TEST mutation, enumerate exact disposable test identities, cafes/documents, operations and expected audit/receipt growth. This record authorizes none. No reset, import, bulk clear, implicit cleanup, migration or production data access. Quota retention/maintenance is trusted internal work requiring its own least-privilege review; it is not a public route.

Disable mutation routes and corresponding client controls if project binding, authority, versions/audits, acknowledgement integrity, CAS durability, secrets, quota fences or duplicate-dispatch safety regress. Fail closed on overload or unavailable dependencies. Do not switch an uncertain operation to a callable/another host or replay with a new key. Preserve original requests/keys, receipts, tombstones, generation evidence, quota tickets/fences and journals. Keep authorized observation available only when safe; otherwise retain unknown state. No destructive rollback or speculative cleanup.

## 8. Offline verification performed in S5.40

From repository root, focused first:

```powershell
node --test functions/test/ai-http.test.mjs functions/test/shared-application.test.mjs functions/test/secure-groq-handler.test.js functions/test/ai-quota.test.js functions/test/secure-ai-callable-adapter.test.js
```

Result: **324 passed, 0 failed, 0 skipped**.

Then backend/HTTP regressions from repository root:

```powershell
node --test functions/test/menu-http.test.mjs functions/test/workspace-http.test.mjs functions/test/staff-http.test.mjs functions/test/invitation-http.test.mjs functions/test/inventory-recovery.test.js functions/test/inventory-http.test.mjs functions/test/shared-firestore-codec.test.mjs functions/test/shared-firestore-store.test.mjs functions/test/shared-google-http.test.mjs functions/test/shared-google-oauth.test.mjs functions/test/shared-firebase-identity.test.mjs functions/test/shared-http-policy.test.mjs functions/test/invitation-recovery.test.js functions/test/shared-backend-identity.test.mjs
```

Result: **733 passed, 0 failed, 0 skipped**. From `functions`, `npm.cmd test`: **394 passed, 0 failed, 0 skipped**. Total **1,451 distinct offline Node tests passed**, with no skipped tests. These use installed dependencies and injected fakes; no emulator scripts were run. No new test entrypoint/file was added for this documentation-only milestone.

Runtime: local Node v24.15.0; Node 22 NOT VERIFIED. Node syntax/Dart analysis and Flutter tests NOT RUN in S5.40 because executable sources are unchanged. Documentation checks: local Markdown links resolve; route paths match composition; all eight live gates remain explicitly BLOCKED; `git diff --check` plus `git diff --no-index --check -- NUL docs/architecture/shared-backend-activation-gates.md` check whitespace (the latter includes this untracked file). No Markdown formatter/linter is configured or claimed. Final SHA-256 comparison must confirm all 621 pre-existing files unchanged and exactly this file added; `.wrangler/` excluded.

**MANUAL TESTING STATUS:** NOT RUN. No browser/device/build/install/live-service acceptance is claimed. Offline regression success cannot certify real Firebase, a chosen host or platform durability.

## 9. Database, Git and release decision

**DATABASE CHANGE REPORT:** no code-level contract, schema, Rules or index changes; no migrations/backfills. No collections/documents were touched live. Existing contracts referenced include `user_cafe_memberships/{uid}`, `cafes/{cafeId}` and scoped members/inventory/movements/activities/menu/receipt paths, plus `ai_usage_users`, `ai_usage_workspaces`, `ai_generation_tickets` and `ai_generation_requests`. Documentation does not add a database or permissions. Deployment status: none; billing unchanged.

**GITHUB STATUS:** no stage/commit/push/pull/reset/clean/stash/fetch. Branch/HEAD unchanged; existing modifications/untracked work preserved. This handoff itself is untracked/unsaved to Git until separately authorized.

**Acceptance decision:** S5.40 offline evidence/handoff complete, subject to final document/scope checks recorded in the delivery report. **NO-GO for activation or overall v1.0 acceptance.** S5.30's bounded S5.31-S5.40 sequence has an offline implementation/handoff outcome; it does not establish production completion or a completion percentage.

Recommended next phase, without starting it: provider/storage selection and a separately authorized, exact-scope feasibility review. Resolve host/no-billing/IAM and durable provider/tooling choices, then finalize R1/P1/P2/D1 manifests. External verification, dependency changes, device work, client wiring and every TEST mutation each need explicit subsequent authorization. Recipes, account lifecycle and consumption remain separate v1.0 work. Stop at S5.40.
