# S3: isolated Spark Owner acceptance readiness

## Checkpoint update through S4.11 (2026-11-07)

This update separates later evidence from the historical S3 record below. No
cloud access, test execution or deployment was performed for this documentation
correction. Prior results were not rerun during documentation setup.

- Current source has populated Web options for `velora-spark-test` (project number
  `91746034332`), with explicit selection and no production fallback. The S3 null
  scaffold/configuration blocker described below is historical, not current.
- Earlier S4.9C evidence records scoped test-project Rules deployment. This is
  prior evidence, not a fresh inspection of live Rules or a cloud-state backup.
- S4.10 Register -> Login -> Email Verification -> seven-field Business Setup ->
  Dashboard: **USER-OBSERVED PASS** in Chrome against Spark Test. This does not
  independently prove every canonical graph document, negative authorization,
  revocation, reload/re-login or concurrent bootstrap case below.
- S4.11 full-name correction: prior offline report **20/20 PASS**. Current source
  preserves the trimmed full name. Corrected full-name display in Chrome remains
  **NOT TESTED**.
- GitHub Gate A offline Node verification: **90/90 PASS** previously reported
  (23 Rules source/host-model checks plus 67 synthetic backend/adapter/integration
  tests). These do not compile/execute Rules or verify real backend services.
- S4.5.1 integrated local workerd: prior **18/18 PASS** after secure SPKI conversion;
  existing workerd regression: prior **15/15 PASS**. Synthetic runtime results are
  not live Firebase/Groq acceptance or Workers Free production capacity evidence.

AI and Staff remain mandatory v1.0 features: KEEP WITH SECURE IMPLEMENTATION;
live release remains BLOCKED PENDING SECURE BACKEND and separate security acceptance.
Authoritative Firebase backend access, Groq integration, durable quotas/persistence,
credential handling, Workers Free limits/reliability/privacy and production
availability remain release gates. Chrome Owner acceptance does not close them.
Physical Android test-profile acceptance and APK readiness remain unverified.
No live session is authorized or extended by this document; new operations require
separate bounded approval. Protected project `velora-73222` remains excluded.

## Historical S3 record (2026-11-07, before S4.3-S4.11 evidence)

Everything below records S3-time findings, proposed budgets and commands. Words
such as "current", "NOT RUN" and "NOT EXECUTED" refer to S3, not the checkpoint
update above. Historical proposals are not authorization to execute or expand the
later bounded session. Historical quota figures require fresh verification before
future acceptance; they are not current service guarantees.

2026-11-07, Asia/Kuala_Lumpur. LOCAL ONLY at S3. No Firebase/GCP project operation in S3.
User proposed `velora-spark-test`, subject to availability. It is not known to exist.
Protected project `velora-73222` is explicitly excluded from all S3 live tests.

## Current decision and configuration gates

Real acceptance is BLOCKED until an approved separate project and registered apps
exist and their configuration is locally verified. No values were fabricated.
`lib/firebase_spark_test_options.dart` is a null Web-options scaffold. Selecting
VELORA_FIREBASE_PROJECT=velora-spark-test currently fails before initialization.
The selector accepts only that exact separate project, Web platform, nonproduction
sender/key, valid sender-linked Web app ID, expected Auth domain/bucket, and no
staging/emulator/demo/AI flags. Missing options never fall back to production.
Dart mock options are synthetic fixtures and never initialize Firebase.

Production options and retired staging behavior are unchanged. Native Android
selection of the test profile remains blocked, including existing Gradle guards.
Do not copy android/app/google-services.json to make the test profile build.

Before live approval:
1. Obtain approval for the exact separate project setup; verify ID availability.
   No fallback to a different ID or protected project. No billing instrument/Blaze.
2. In the separate project only: register a Web app, enable email/password Auth,
   configure/verify approved local authorized domain and hosted email action flow,
   and create a Standard Firestore (default) database in a selected reviewed region.
   Start with deny-all Rules, never public test-mode access. No Functions/Storage.
3. Obtain actual Web FirebaseOptions; locally populate the existing S3 scaffold,
   pin/review actual identity, rerun offline profile tests. Client API identifiers
   are not server secrets, but do not print them unnecessarily.
4. Register separate Android app only if physical acceptance is approved. Its
   native Google Services file and Dart options must be reviewed in a later narrow
   test-profile/native-config patch. Current app package is com.example.velora;
   use a separately reviewed test package/build variant before native testing.
5. Confirm billing disabled/unlinked/Spark via approved evidence, exact CLI identity,
   project ID/number, Auth domains/template and Firestore location/database. No
   production metadata read is part of this plan. Stop on permission/API errors.

The app's existing main flow needs no Functions for register/profile/login,
verification, Owner bootstrap, canonical resolution or empty Dashboard. Staff
roster/invites, Inventory mutations and Menu still require separate migrations.

## Local corrections

WorkspaceProvisioningException now carries outcomeUncertain (default true).
A definite pre-transaction failure can report false. Business Setup keeps Create
available for an explicit retry and says creation was not started. Once the
transaction has been entered, ambiguous failures remain conservative/recheck-only.
No automatic retry is introduced; SDK transaction callback retries remain native.

The shared fake defaults to SDK-like set overwrite behavior. A separately named
optional create-only model protects only its explicit modeled collision test.
An added negative demonstration confirms SDK set alone is not overwrite protection.
Lost-response injection can commit all records then throw; subsequent unchanged
explicit service retry returns created:false. UI never auto-reissues this retry.

## Rules source and deployment boundary

Local draft is docs/firebase/workspace.firestore.rules, including S2.2 positive
control-free predicates. No Rules changes were required in S3. Three create grants
require verified Auth, caller UID/Owner role, schemaVersion 1, exact keys and types,
active status, matching cafe IDs, request.time timestamps, prior absence of all
three records, and final getAfter graph. Exact keys exclude generation fields.
Authority update/delete and unrelated privileged writes stay denied.

Budget without cache assumptions: each create has 3 exists + 3 getAfter = 6;
three creates = 18, under 10 per write and 20 per atomic request. Canonical self
read adds no dependent lookup. This is static counting, not executed Rules evidence.
Regex policy does not prove arbitrary Unicode normalization/length equivalence.

`firebase.spark-acceptance.json` contains Firestore Rules only, with no Functions,
indexes, Hosting or emulator configuration. Future approved command from repo root:

```powershell
$acceptanceProject = 'velora-spark-test'
if ($acceptanceProject -ne 'velora-spark-test' -or $acceptanceProject -eq 'velora-73222') { throw 'Wrong target' }
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --config firebase.spark-acceptance.json --only firestore:rules --project $acceptanceProject --non-interactive
```

NOT EXECUTED. Before deployment: verify exact current Rules hash, compilation
results and approved project identity. Save any prior test Rules release metadata
for a separately approved restrictive rollback; never restore permissive Rules.
Compilation-only Rules API submission also requires explicit approval. Neither
compilation nor metadata readback establishes authorization behavior.

## Bounded proposed acceptance scope (not authorized)

Five controlled identities, user-supplied mailboxes/passwords held outside source:
Owner A, Owner B, Staff A, Unverified C, Inconsistent D. Use actual Firebase-generated
UIDs, referenced by aliases in sanitized results. Verify A/B/Staff/D through real
mail/token refresh; keep C unverified. No customer accounts or data.

All synthetic cafe names start S3 ACCEPTANCE. Cafe IDs remain SDK-generated.
Scope only users/{five UIDs}, two created cafes and their Owner member records,
Staff A's member under Cafe A, those users' canonical links, plus named denied
synthetic targets. No collection enumeration or customer paths. Dashboard may query only the empty
inventory collections under those two approved cafes; no inventory writes. Denied
targets: cafes/{Cafe A}/inventory/s3-denied-item, cafes/{Cafe A}/menu_items/s3-denied-menu,
ai_usage_users/{Owner A UID}, and cafes/s3-acceptance-missing-cafe (must remain absent).

Privileged fixture manifest, after resolved IDs are reviewed:
- user_cafe_memberships/{Staff A UID}: uid=Staff A, cafeId=Cafe A, status=active,
  schemaVersion=1, createdAt/updatedAt=server timestamp; no generation field.
- cafes/{Cafe A}/members/{Staff A UID}: same fields plus role=staff.
- user_cafe_memberships/{Inconsistent D UID}: uid=D,
  cafeId=s3-acceptance-missing-cafe, status=active, schemaVersion=1,
  createdAt/updatedAt=server timestamp; no member/cafe companions, no generation.
Profiles are created only through registration's existing username/email/photoUrl/
role:owner/server-timestamp contract, not treated as workspace authority. A/B create
their own complete Owner graph through the reviewed client. Fixture writes never
serve as evidence that client Rules authorized a write.

Proposed first-run cap: 5 Auth accounts, 10 verification emails, 20 explicit login
attempts, 100 explicit document reads and 30 negative write attempts. Successful
fixture state: at most 14 documents (5 profiles + 6 Owner graph records + 2 Staff
links + 1 inconsistent mapping). Profile updates generated by login must be counted
and may not exceed 20 accepted write operations total. SDK callback retry/Rules
lookups can consume additional quota; operation caps are harness/user budgets,
not hard bounds on underlying billed reads. Monitor and stop rather than expand.
No infinite subscriptions: close clients after each scenario; total live session
maximum 30 minutes. Stop on first unexpected authorization success or unknown state.

Staff/inconsistent fixtures require explicitly approved privileged test-only writes
because current Rules correctly deny client membership mutation. Their exact paths,
fields and resolved UIDs must be reviewed before writing. Never use Admin credentials
for allow/deny assertions: Firebase Auth client requests must exercise Rules.

Order / action / expected result / current actual evidence:
1. Register each synthetic identity, explicit logout/login: own valid profile only;
   actual Auth/email NOT RUN. Existing manual-login registration policy is preserved.
2. Send verification explicitly for A/B/Staff/D; open Gmail hosted link, return,
   refresh/check: fresh email_verified token; NOT RUN live.
3. Owner B first-time bootstrap in two clients concurrently: one valid graph,
   one duplicate/conflict, no second cafe; offline model only, live BLOCKED.
4. Force proposed Owner A cafe target to existing Cafe B via a reviewed adversarial
   client: denied/no overwrite. Do not change app production ID allocation for this.
5. Owner A normal seven-field bootstrap: cafe/member/canonical atomic; resolve
   before Dashboard; then duplicate and conflicting setup: no new authority writes.
6. Logout/login and browser reload: same Cafe A via canonical resolver, no creation.
7. Create approved Staff A fixture (2 authority docs) and Inconsistent D mapping
   (1 doc pointing to a missing synthetic cafe). Staff bootstrap and D resolution
   must fail closed. In a separately enumerated fixture update, set only D mapping
   status to inactive and repeat the denial; this adds one accepted fixture update
   within the 20-write cap, not another document. Staff isolation tests: own Cafe A read allowed, Cafe B denied.
8. With Unverified C, attempt bootstrap: denied/no records. With verified identity
   lacking membership, attempt 1- and 2-doc bootstrap, wrong UID/role/cafe, extra
   fields, wrong timestamp/types/generation, length/control cases: all denied.
   Existing-member tests also need no-membership identity for predicate isolation;
   after C verifies, use C solely for negative bootstrap attempts and create no graph.
   This consumes at most 1 additional verification email within the cap above.
9. Direct authority update/delete; unrelated Inventory/Menu/AI writes: denied.
10. Offline/interrupted network: no false success. Restore network and explicitly
    recheck canonical state before any repeat. A lost response is not rollback proof.
    If no membership can be verified, stop for review, not cleanup/recreation.
11. Phone/tablet: repeat approved email-return/restart/layout checks only after
    actual native test profile readiness. APK build/install needs its own scope.

All live cases above are BLOCKED/NOT RUN, never PASS from mocks. Expand the negative
case matrix across separate runs if the 30-attempt cap would be exceeded; do not
silently enlarge a run. Do not activate removal/rejoin or rewrite other features.

## Platform status and safe commands

Chrome UI preview: PARTIALLY READY from widget/layout tests, not browser execution.
Chrome real Firebase: NOT READY until test project/options/Rules acceptance exist.
Physical Android: NOT READY for separate target; native config is absent/unapproved.
No current test-project run command is safe for real use while options are null.
After configuration and runtime approval only:

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat run --no-pub -d chrome --web-hostname localhost --web-port 7357 --dart-define=VELORA_FIREBASE_PROJECT=velora-spark-test
```

Authorize localhost (if required) only in the test project. This command does not
bypass local validation; it is currently expected to show configuration blocked.
Do not use VELORA_FIREBASE_PROJECT=velora-73222 in any S3 command. Android build/launch
commands remain withheld until actual separate native identity is reviewed. No iOS
build claim without macOS/Xcode. Existing Android INTERNET and FirebaseInitProvider
removal are present by source inspection; current release signs with debug key.

## Quota, rollback and cleanup

Spark supports email/password Auth and Firestore within quotas. Firebase currently
lists 50K reads/day, 20K writes/day and 1 GiB Firestore storage; address-verification
email allowance is separate from email-link sign-in. Rules-dependent reads and
transaction retries consume quota. No paid-service fallback or billing change.
Sources: https://firebase.google.com/pricing and https://firebase.google.com/docs/auth/limits.

On unexpected allow, stop clients immediately and request restrictive test-project
Rules rollback approval. Preserve sanitized status/count evidence, not tokens/raw
accounts. No automatic rollback/deletion. Later cleanup approval must enumerate
only the synthetic document IDs and the five test accounts; remove member/profile/
canonical documents explicitly (deleting parent cafes does not delete children).
Do not clear databases or touch saved emulator exports. No cleanup executed here.

DATABASE CHANGE REPORT: no real database/Auth operations or deployment; local Rules
unchanged in S3, schema/indexes unchanged, no migration. Config/document additions
are local only. All S2/S2.2 dirty work and untracked W3 report preserved. No Git save.

Approval checkpoint: first approve isolated test-project setup and actual config
review; only then can a final executable, bounded real-test approval be requested.
The proposed ID's availability is unknown. No executable live test is approved now.

## Verification evidence and source size

S3 final offline counts/status are reported in the chat's consolidated report;
no live case above has executed. Backend default: 385 pass; additional security/
resource suites: 21 pass, zero failures/skips. Eight changed Dart files analyze
clean. Full analysis earlier reports four existing curly-brace style notices in
untouched lib/models/fake_recipe_response.dart (48/51/68/78). No unrelated cleanup.

Production source remains compact: provisioning 393 lines, startup 196, Business
Setup 433. Existing business_setup_test.dart (839) and startup tests (634) exceed
the soft limit as cohesive regression suites; retain during this security batch,
then consider splitting setup navigation/recovery from responsive layout tests
only in separately approved test organization work. No production file needs split.

Consolidated remaining dependency plan: migrate Inventory create/update/stock/
lifecycle atomically with Rules-validated versions/receipts/audits; migrate Menu
reads/writes independently; design Staff invites/roster/privacy/removal/rejoin
without Admin Auth lookup assumptions; retain AI/Recipes but require a separately
reviewed trusted external secret-holding backend for Groq if Firebase stays Spark.
No migration or removal of those implementations is authorized by S3.

Exact offline commands, directory C:\Users\23000\velora:

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/workspace_provisioning_service_test.dart test/owner_email_verification_test.dart test/business_setup_test.dart test/workspace_gate_test.dart test/workspace_resolver_test.dart test/workspace_session_test.dart test/dashboard_page_test.dart test/workspace_inventory_repository_test.dart test/auth_flow_test.dart test/profile_validation_test.dart test/firebase_startup_config_test.dart --reporter expanded
& C:\Users\23000\flutter\flutter\bin\flutter.bat analyze --no-pub
& C:\Users\23000\flutter\flutter\bin\flutter.bat analyze --no-pub lib/firebase_spark_test_options.dart lib/services/firebase_startup_config.dart lib/services/workspace_provisioning_service.dart lib/screens/business_setup/business_setup_page.dart test/helpers/workspace_bootstrap_fake.dart test/workspace_provisioning_service_test.dart test/business_setup_test.dart test/firebase_startup_config_test.dart
node --check functions/test/firestore-rules-contract.test.js
git diff --check
```

From C:\Users\23000\velora\functions:

```powershell
npm.cmd test
node --test test/single-workspace-security.test.js test/workspace-resource-config.test.js
```

Final Flutter result: 246 passed, zero failed/skipped, exit 0. Earlier 240-test run
overlaps and is not added. Full analysis returned exit 1 for the four existing
style notices only; scoped analysis returned exit 0. Syntax/diff/JSON checks passed.
Current candidate Rules raw SHA-256: `c7e8eec3091f75c24f54926646ff9bd488e9e690d87ca3680363c15346e5c632`.
