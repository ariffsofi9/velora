# W3: Create Workspace deployment readiness gate

2026-11-07, Asia/Kuala_Lumpur. Local review and offline verification only.
Priority: Create Workspace -> Dashboard. Groq remains paused.

## Decision

**NO-GO for deployment now; conditional GO for the reviewed local callable.**
W2 resolves W1's email-verification and setup-validation source blockers. No new
mandatory application-code fix was identified in this focused review. This is not
production readiness proof: target Node 22 execution and current cloud prerequisites
remain unverified. No production metadata was refreshed in W3.

Baseline: main at acba60e; working tree clean at entry. PROJECT_STATUS/ROADMAP
describe an older checkpoint, so current source and focused tests take precedence.
Prior W1/W2 findings were reviewed without repeating their full audits.

## Local gate checklist

| Gate | Evidence / result |
| --- | --- |
| Callable identity | PASS: functions/src/index.js exports createWorkspace via firebase-functions/v2/https onCall; region asia-southeast1. |
| Deployment scope | PASS locally: firebase.json uses source functions, codebase workspace; package main src/index.js. Exact selector below targets only this export. Other callables exist, including a disabled removal handler; do not deploy the whole codebase. No Groq import/export in index.js. CLI discovery loads the shared entrypoint and its imports, but should not invoke handlers. Actual deployment plan remains subject to review. |
| Backend email guard | PASS: workspace-creation.js requires valid Auth UID and trusted auth.token.email_verified === true before input processing, ID allocation or transaction, including retries. Client identity/role/cafe fields are rejected. No Admin getUser revocation check is added; callable token validation is the current security contract. |
| Flutter fresh verification | PASS locally: owner_email_verification.dart reloads User, reacquires currentUser, enforces same UID, forces getIdTokenResult(true), checks email_verified claim and current emailVerified. Provisioner repeats verification and checks UID before transport. Real token propagation remains unverified. |
| Payload | PASS: businessName, businessType, address, inventoryUnit, lowStockAlerts, expiryReminders, reminderDays only. Normalized supported new types Restaurant/Cafe accented/Bakery; name 2-80, address <=200, units kg/g/L/ml/pcs, reminderDays 1/3/7. No client authority fields. |
| Response | PASS: backend returns {cafeId: string, created: boolean}; Flutter unwraps callable .data and validates these types. Returned cafeId is not trusted for access; canonical resolver authorizes Home. |
| Resources | PASS with installed SDK metadata: 256MiB, cpu 1, timeoutSeconds 30, minInstances 0, maxInstances 1, concurrency 1. Applies only to createWorkspace. Scale controls are not spending caps; cold starts and overload remain possible. |
| Node / SDK | package engines.node = 22. Installed firebase-functions 7.4.0 requires >=18; firebase-admin 14.5.0 requires >=22. Compatible by declared engines; W3 executes on Node v24.15.0. Node 22 execution/build remains NOT VERIFIED, a release gate. No installation or upgrade performed. |
| Atomicity / duplicate safety | PASS in source/model tests: Admin runTransaction with native create preconditions writes cafe, member and canonical mapping together. Proposed ID allocated outside callback. Canonical read conflict forces concurrent creates/joins to serialize on commit. No provider/network side effect inside callback beyond Firestore. |
| Idempotency | Same authenticated UID + same normalized setup + valid existing Owner graph returns existing cafeId, created:false, without new writes. Changed payload, Staff membership or inactive/inconsistent links reject. This is canonical-membership idempotency, not a separate request-key receipt. |
| Uncertain outcome | UI blocks duplicate submission; accepted/unknown outcome only re-resolves access. No automatic create retry. Timeout/unavailable/internal does not prove rollback. Conservative recheck-only UX can strand a no-commit attempt, including a second verification failure; separate P1 recovery work, not an authorization bypass or mandatory first-deploy code fix. |
| Initial Rules B compatibility | PASS static contract: three schemaVersion:1 active records, cafe.ownerUid equals member UID, member.role owner. Both generation fields absent means legacy generation 0 in resolver/Rules. No generation migration or lifecycle activation. Admin bypasses Rules; backend checks remain essential. |
| Profile / reads | Initial self profile retains Rules-required role:'owner', Auth email and server timestamps; profile role is not authority. Resolver reads own mapping, cafe and member, validates graph/generation. Rules allow matching active Owner graph and scoped inventory reads, deny client authority writes. |
| Home / restart | PASS mocked routing: setup resolves canonical membership -> WorkspaceSessionBoundary -> Home; login and Splash restart use WorkspaceGate. Existing membership goes Home without setup; inconsistent links fail closed. Empty scoped inventory can render Dashboard without inventory mutation Functions. No index change needed for creation point reads or the initial unfiltered inventory stream. |

Rules source SHA-256, unchanged:
`d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af`.
Rules tests in this batch inspect a static contract; they do not execute Rules.
Prior reported deployment of Rules B and two anonymous 403 cases are historical
evidence only, not authenticated Owner/query acceptance or current release readback.

## Outstanding external gates and minimal next action

1. Validate focused backend suite under an existing/approved Node 22 toolchain.
   Installed SDK acceptance under Node 24 does not establish Node 22 execution.
2. Separately approve current read-only prerequisite checks: exact project identity,
   billing linkage/enabled status and eligible billing-account currency/status,
   required APIs and deployment/build/runtime service-account permissions. Prior
   evidence says billing disabled/unlinked and no Functions; it may be stale.
   Prior closed billing accounts are not approved/eligible accounts by assumption.
3. Human approval is required for any Blaze billing linkage/activation. RM5-equivalent
   budget currency, recipients and 50/90/100% alerts need separate review; alerts do
   not cap spending. No budget or billing action is authorized by this document.
4. Verify required Cloud Functions, Cloud Run, Cloud Build, Artifact Registry and
   supporting service prerequisites for the actual CLI deployment plan. Do not
   silently enable APIs, grant IAM, create resources or accept cleanup policies.
   Deployment identity needs existing function create/update and service-account
   actAs capability; build/service agents and runtime identity need appropriate
   existing permissions. Runtime Admin requires Firestore transaction read/write
   access. Exact project IAM state is NOT VERIFIED; do not grant broad roles blindly.
5. Resolve the previously reported Google Cloud AUP warning with exact warning and
   owner review; its text/status is not verified here. Do not dismiss it.
6. Review scoped deployment preview/output before approving changes: only
   createWorkspace, expected region/runtime/resources, callable reachability and
   runtime identity. Callable transport must be reachable by Firebase clients;
   trusted Auth checks remain mandatory. CORS is SDK-managed (no custom option),
   and explicit App Check enforcement is absent. Any new enforcement/IAM policy
   needs separate client-compatible review, not an improvised deployment fix.

Known non-blocking source risks requiring explicit acceptance: raw unexpected Error
objects are logged by index.js; limits do not prevent sustained invocation cost;
no new App Check/rate-admission policy; conservative uncertain-response recovery.
Unrelated inventory/menu Functions are not deployed by the proposed command, so
Add/Edit/Stock/Menu mutation acceptance is outside this initial empty-Dashboard gate.
Android release signing/toolchain status is not verified; no release-readiness claim.

## Proposed deployment command — NOT EXECUTED

Directory: C:\Users\23000\velora. Only after separate explicit approval and all
gates above are satisfied:

```powershell
& C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only functions:workspace:createWorkspace --project velora-73222
```

No broad firebase deploy, codebase-wide deployment, Rules/index publishing, AI,
invocation or fixture writes. If CLI requests an unexpected prerequisite change,
deletion, API enablement, IAM adjustment or billing action: stop for review.
Later metadata readback must separately confirm v2, Node22, asia-southeast1, ACTIVE
and all six resource values. Do not invoke as a deployment health check.

## Manual Android / Web acceptance — NOT RUN

Separate bounded runtime approval is required, identifying synthetic Auth identity,
allowed mail/account operations, one invocation and three authority writes, and
scoped read budget. No automatic retries, real customer data or cleanup.

1. Verify explicit velora-73222 profile/build, authorized Web domain and existing
   email/password provider/template. Android app/package and network configuration
   must match the reviewed Firebase profile. Do not launch until runtime approval.
2. Register/sign in using approved synthetic identity. Registration intentionally
   signs out; explicit login leads a missing-member Owner to verification.
3. Verify no automatic mail on page load. Explicit Send once; check cooldown and
   sanitized offline/expired-link errors. Open hosted verification link on Android
   and Web; return to original app and tap check. No custom deep-link guarantee.
4. Confirm refreshed verification reaches setup, retains draft on verification
   round trip and still requires explicit Create. Unverified/signed-out or changed
   user must not invoke creation. No UID/token/email content in evidence.
5. Submit approved valid seven-field setup once. Confirm one canonical workspace,
   active Owner graph and empty Dashboard via authorized reads; no stock/menu writes.
6. Reload Web and cold-restart Android: canonical Gate opens same workspace, no
   extra create. Back navigation must not loop or lose the setup draft prematurely.
7. Test duplicate tap and simulated lost response locally first. Any approved live
   timeout must use Recheck access, not blind resubmission or changed payload. If
   mapping absent or outcome unknown, stop for review; do not delete/recreate records.
8. Authenticated Rules/listener/profile and cross-workspace acceptance require their
   own bounded plan. Anonymous 403 and offline mocks do not prove these cases.

## W3 offline evidence

From functions:
```powershell
node --test test/workspace-creation.test.js test/single-workspace-security.test.js test/workspace-resource-config.test.js test/firestore-rules-contract.test.js
node --check src/index.js
node --check src/workspace-creation.js
```
Backend: **37 passed, 0 failed/cancelled/skipped/todo, exit 0**. Covers authenticated
creation, verified claim, forged authority, duplicate/conflicting ownership, modeled
concurrency, active links, resource metadata and static Rules contract. Atomicity is
reviewed through native transaction structure and offline stores; no injected real
Firestore commit-failure or runtime rollback test was executed.

From repository root, existing SDK (no dependency resolution):
```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/owner_email_verification_test.dart test/business_setup_test.dart test/workspace_provisioning_service_test.dart test/workspace_gate_test.dart test/workspace_resolver_test.dart test/workspace_session_test.dart test/dashboard_page_test.dart test/workspace_inventory_repository_test.dart --reporter expanded
git diff --check
```
Flutter: **142 passed, 0 failed/skipped, exit 0**. The first sandboxed invocation
stalled without output and was stopped; the offline SDK/cache-access rerun passed.
JavaScript syntax checks and git diff --check: PASS, exit 0. New document whitespace
checked separately because git diff does not include untracked files.
W2's earlier 170-pass suite is historical, overlapping evidence, not a new W3 result.
Full suites, emulator,
production, actual email/token delivery, browser/device acceptance and Node22
runtime are NOT RUN. No Groq development or tests.

## DATABASE CHANGE REPORT / GitHub checkpoint

Schema, local/production Rules, indexes, documents and Auth users: UNCHANGED.
Production reads/writes: NONE. Deployments: NONE. Billing/IAM/APIs: UNCHANGED.
ADD this document only; MODIFY/DELETE none. Existing repository work preserved.
No staging, commit, push or history change. Checkpoint remains REVIEW; any save or
deployment needs explicit approval. STOP after local W3 report.
