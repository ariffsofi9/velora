# Create Workspace unexpected-result diagnosis

2026-11-06, Asia/Kuala_Lumpur. LOCAL DIAGNOSIS ONLY. Live root cause INCONCLUSIVE.
No source changes, production requests, Auth operations or deployment in this phase.

## Exact message and classification trace

`lib/screens/business_setup/business_setup_page.dart:168-169` maps
WorkspaceProvisioningFailure.internal to:
"The workspace service returned an unexpected result. Creation may have completed.
Recheck Workspace or contact support."

It is a conservative uncertainty warning, NOT evidence that a workspace exists.
Under the current implementation this classification can arise from:
1. `workspace_provisioning_service.dart:143-146`: a returned map whose `created` is
   not bool or whose `cafeId` is not String.
2. `workspace_provisioning_service.dart:149-150,183`: FirebaseFunctionsException
   code `internal`, or ANY unrecognized callable error code falling through default.

The message alone cannot distinguish these paths. A non-map response rejected by the
SDK generic cast can instead reach catch-all -> unavailable. Thus "malformed response"
is not always classified internal; it depends on where parsing fails. A generic
network error becomes unavailable, while SDK-generated internal errors may produce
this exact message. Do not infer actual backend execution from the wording.

## Actual request and response contracts

Client transport: workspace_provisioning_service.dart:79-82;
FirebaseFunctions.instanceFor(region: 'asia-southeast1').httpsCallable('createWorkspace').
Default initialized Firebase app is used. Startup/profile validation permits only
explicit approved Web/unflavored Android cloud selection or explicit local profiles;
provisioner rechecks initialized app identity before dispatch. Cloud target here is
velora-73222; known URL matches the regional endpoint. No emulator fallback.

Request keys match backend allowlist exactly:
businessName, businessType, address, inventoryUnit, lowStockAlerts, expiryReminders,
reminderDays. No caller role/UID/cafe authority is supplied. Backend additionally
validates lengths, allowed business types/units/reminders and rejects authority fields.

Backend workspace-creation.js returns {cafeId: <string>, created: true} on creation,
or {cafeId: <existing string>, created: false} for an identical valid Owner retry.
The callable SDK protocol wraps this in its callable wire result; Flutter reads
response.data, not the raw HTTP envelope. Client requires bool created and String
cafeId, then deliberately resolves authority independently; it does not trust cafeId
as authorization. No static request/response mismatch was found.

Potential hardening, not implemented: parser checks cafeId type but not nonempty/safe
ID, and collapses malformed map vs internal/unknown callable errors into one enum.
Because a separate resolver validates authority before Home, this does not by itself
grant access. A separate approved patch could add precise non-sensitive failure
reasons and malformed-response tests if runtime evidence makes that useful. Never
log request payload, tokens, raw response data or arbitrary server errors to diagnose.

## Error-path matrix

| Callable/client outcome | Local failure / feedback | Can it establish a write? |
| --- | --- | --- |
| not-found | callableNotFound; service name/region/project guidance | No; diagnose deployment separately |
| unavailable or opaque network exception | unavailable; uncertainty + recheck | No; outcome unknown |
| permission-denied | permissionDenied | No |
| unauthenticated or UID changes during request | unauthenticated | No; late response rejected |
| failed-precondition with exact backend email message | emailUnverified | No; backend rejects before transaction |
| other failed-precondition / already-exists | existingMembership | No; not evidence of this request creating a new workspace |
| internal or unknown SDK error code | internal; observed message | No; could be pre-handler or backend error |
| map missing/wrong created/cafeId types | internal; observed message | No; backend could have committed before invalid response |
| non-map SDK response/type conversion failure | generally unavailable catch-all | No; path depends on thrown exception type |
| valid accepted response, resolver then fails | distinct accepted-but-unverified message | Valid response accepted, but records/session still need authorized verification |

The observed internal warning is NOT the resolver failure message. It means current
submission did not pass through normal successful-result handling; it does not prove
response parsing specifically failed. A stale/different build remains possible until
current loaded source/error code is identified; no live browser check was performed.

## Creation, retry, resolver and Dashboard

business_setup_page.dart:89 only invokes provisioning when neither _creationAccepted
nor _creationUncertain is set. On an accepted result it sets _creationAccepted=true.
Unavailable/timeout/internal set _creationUncertain=true. Button becomes Recheck
Workspace, disables edit controls and skips the callable on subsequent page rechecks.
This state is per page instance, not persistent across reload/sign-out/navigation.

Recheck calls WorkspaceResolver.resolve(), whose FirestoreWorkspaceStore performs a
READ-ONLY server transaction (individual document gets; no create/set/update/delete).
It reads self mapping, cafe/member, and Owner links as necessary, checking active
schema/role/generation/UID consistency. Missing mapping throws missingMembership;
it does not create a mapping or invoke createWorkspace. A manual Recheck would be a
production read and was not performed or newly authorized by this diagnosis.

On success, a verified WorkspaceSession enters WorkspaceSessionBoundary, which may
perform additional authority reads/listens and verification before rendering Home.
These are security checks, not duplicate provisioning. Failures remain closed.
No direct Dashboard bypass or client authority write is an acceptable workaround.

Backend atomic transaction creates cafe + member + canonical mapping. Canonical
mapping read/create preconditions serialize competing requests. Identical valid
Owner payload retries return created:false; conflicting payload/Staff/invalid mapping
is rejected. There is no client-supplied idempotency key for this operation: retry
safety is based on Auth UID, existing canonical ownership and matching normalized
setup. Do not describe it as a durable client receipt or assume every changed retry
is interchangeable. Unknown outcome should not trigger blind re-submission.

## Deployment evidence vs inference

The user reports the earlier production listing had no deployed Functions; no fresh
listing or API inspection is authorized here. The local export exists at index.js:99,
uses v2 onCall in asia-southeast1, timeoutSeconds 30, package main src/index.js,
Node 22, codebase workspace from firebase.json. Local export is not deployment proof.
Rules B deployment did NOT deploy Functions. Anonymous Rules smoke tests do NOT
exercise callable routing/Auth/Firestore Admin transactions.

If createWorkspace is still absent, successful onboarding through it cannot occur.
A missing HTTP endpoint can surface through SDK/network/transport errors rather than
one guaranteed callable code, so it can plausibly explain this symptom. But an earlier
empty list plus this UI text is insufficient to confirm the current live cause.
No production write can be inferred. Previous empty cafes/mappings audit is historical,
not a current account-specific check or evidence of this request's outcome.

Backend verified email is required from trusted auth.token.email_verified===true
before input handling/transaction. A verified email UI alone is not a refreshed Auth
claim. Existing membership conflicts and malformed historical state deny. No attempt
to verify email, obtain tokens or inspect accounts was made. Admin SDK bypasses Rules;
runtime service IAM and backend authorization both matter independently.

## Safest corrective path and approval gates

1. First obtain a separately approved READ-ONLY existence/health check limited to
   createWorkspace in velora-73222/asia-southeast1 (no Firestore documents, invocation,
   deployment or Auth operations), or inspect already-captured sanitized failed
   Network entry: method/status/browser error/callable code only. Do not click again
   merely for evidence or share headers, tokens, payload or raw personal response data.
2. If missing deployment is confirmed, review Node 22 lock/dependencies, APIs/billing,
   deployer/runtime IAM, AUP warning, verified-email flow and exact function source.
   Scope any later approval ONLY to functions:workspace:createWorkspace, never broad
   deployment because firebase.json also references Rules. No deploy command is
   executed here. Unknown current prerequisite status must not be assumed PASS.
3. If deployment exists, use separately approved sanitized existing function logs/
   transport metadata to distinguish handler internal error vs parsing vs infrastructure.
   Only implement a local fix after concrete evidence; no speculative CORS changes.
4. For an ambiguous outcome, separately approve a bounded current-user resolver/read
   before another provisioning attempt. Do not infer prior creation or create a second
   workspace. Account must meet trusted verified-email requirement.
5. Only after an independent invocation approval may one controlled Create Workspace
   attempt make real data writes; then resolve authoritative links and observe protected
   Home. Listener/read/account operations need their own stated scope. No promise that
   function deployment alone resolves email, IAM, Rules compatibility or session issues.

Primary next action: scoped read-only createWorkspace deployment verification, not
another source patch or another Create Workspace click. All live gates remain CLOSED
until explicitly approved. This task requests no cloud operation.

## Actual local verification

Executed from C:\Users\23000\velora:

```powershell
node --test functions/test/workspace-creation.test.js functions/test/single-workspace-security.test.js
node --check functions/src/index.js
node --check functions/src/workspace-creation.js
```

Backend PASS: 30 tests, 0 failures, 0 skips; both JS syntax checks PASS.

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/workspace_provisioning_service_test.dart test/business_setup_test.dart test/workspace_resolver_test.dart test/workspace_episode_integration_test.dart --reporter expanded
```

Flutter PASS: 103 tests, 0 failures, 0 skips. Existing coverage includes internal and
other callable error mappings, uncertain resolution-only rechecks, accepted-resolution
retry, duplicate clicks, UID changes, resolver invalid links and boundary revocation.
No dedicated missing/wrong response-field regression was found in the provisioning
suite; that branch was inspected, NOT separately runtime-tested in this phase.
A passing mocked success does not establish deployed contract equivalence.

Local source/error/contract/config/idempotency/resolver review completed; precise live
cause INCONCLUSIVE; production runtime and database access NOT RUN. Final document
checks and git diff --check recorded in task report. No app/source/test modification.

Database report: schema, local/production Rules, documents, Auth users UNCHANGED.
Production reads/writes/Auth operations/Functions invocation/deployment NONE. Only
this diagnosis document added; no emulator/staging, IAM/API/billing, credentials or
Git add/commit/push. Existing uncommitted work preserved. STOP after this report.
