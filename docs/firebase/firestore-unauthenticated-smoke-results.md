# Minimal unauthenticated Rules smoke test

Prepared 2026-11-06 (Asia/Kuala_Lumpur). Execution: APPROVED; first request
INCONCLUSIVE and harness stopped. See actual results below. Original planning
statements describe the pre-execution phase.
The reviewed harness is firestore-unauthenticated-smoke.cjs in this directory.
Default invocation previews fixed targets only; --execute-approved permits network.
A flag is not itself user authorization: do not run until the user approves below.

Proposed project/database: velora-73222/(default).
Targets: users/__velora_rules_smoke_profile_20261106_no_fixture__ and
cafes/__velora_rules_smoke_cafe_20261106_no_fixture__.
These IDs are reserved synthetic targets, intended nonexistent; absence is NOT verified
and does not need to be tested with a privileged read. No fixture is created.

Only two HTTPS GETs, no Authorization/cookies/API keys, no CLI/Admin credentials.
No redirects/retries. Timeout 10 seconds per request, body cap 8 KiB, stop on first
unexpected/inconclusive result. No request body or write-capable Firebase API used.
No successful document content is retained or printed. Output only fixed targets,
status/error classification and counters. No response bodies/headers or credentials.

Expected: 403 + PERMISSION_DENIED + standard Firestore insufficient-permissions
message, without infrastructure error reasons. 404 is NOT proof of denial. Missing
credentials, service/API errors, transport failure and nonstandard responses are
INCONCLUSIVE; 200 is unexpected allowed access and stops the test. No test result
can establish all Rules B cases or prove nonexistent target provenance. A denial
for an unauthenticated target also does not distinguish old authenticated-only
Rules from Rules B: active source identity is prior readback evidence, not this test.

Local source hash must match deployed evidence before execution. Active release is
not refreshed by this phase. Prior active ruleset ea892759-ad8e-4442-8e61-d10117d0324f;
source SHA-256 d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

Required explicit approval: only these unauthenticated GETs, project/path/cap/auth
mode exactly as above. No authenticated tests, fixture reads, account operations,
writes, Functions, Rules/IAM/API/billing changes, emulator, staging or deployment.
Ordinary request/minimum read charges may apply; no billing lookup is authorized.

Local checks: node --check and default preview only; runtime results to be recorded
only after actual execution. Other-profile/authenticated/cross-workspace cases remain
DEFERRED/BLOCKED pending separate identities/fixtures and approval. Writes/listener
revocation NOT AUTHORIZED. No full-suite rerun is needed for this standalone harness.

Database report: schema/local Rules/cloud Rules/documents unchanged; production
reads NOT RUN, writes/deployment NONE. No Git add/commit/push. Existing work preserved.

## Actual approved execution (2026-11-06, Asia/Kuala_Lumpur)

The user explicitly approved only the two fixed unauthenticated GETs. Executed once:

```powershell
node docs/firebase/firestore-unauthenticated-smoke.cjs --execute-approved
```

| Scenario | Actual outcome |
| --- | --- |
| GET users/__velora_rules_smoke_profile_20261106_no_fixture__ | HTTP 400; Firebase INVALID_ARGUMENT; INCONCLUSIVE |
| GET cafes/__velora_rules_smoke_cafe_20261106_no_fixture__ | NOT RUN; harness stopped after first unexpected response |

Exact first request target:
`https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/users/__velora_rules_smoke_profile_20261106_no_fixture__`.
Auth: NONE. No Authorization/cookies/API key/CLI/Admin credentials.
Actual requests: 1; retries: 0; redirects followed: 0. CLI exit 1 indicates the smoke
assertions were not satisfied, not successful authorization denial. Standard
Firestore insufficient-permissions message was NOT observed. No raw body/headers
were printed or persisted. Exact INVALID_ARGUMENT message was not retained in the
sanitized output, so its cause is not established by this response alone.

Result: INCONCLUSIVE. This does not verify even the unauthenticated denial case and
is not evidence of a Rules B authorization bypass. No 403/PERMISSION_DENIED assertion
passed. No second request, changed target or repeated invocation is authorized by
this execution. Further diagnosis/any revised target requires separate approval.

Local review should check the chosen double-underscore synthetic IDs against
Firestore reserved identifier restrictions before preparing another request. Do
not assume a transport/API validation failure tests Security Rules. No harness or
endpoint changes were made during this execution phase.

Database report: schema/local Rules/cloud Rules/documents unchanged. One exact
approved read attempt, no document content returned. Writes/deployment NONE.
No accounts/fixtures, authenticated tests, emulator or configuration changes.
GitHub: not committed/not pushed; existing uncommitted work preserved.

## Local HTTP 400 review and harness correction (2026-11-06)

No new production request or authentication operation was performed. Both previous
synthetic IDs begin and end with double underscores, matching the reserved Firestore
document identifier form `__.*__`. They were invalid choices for this smoke test.
This is a confirmed request-construction defect. The original validation message was
not retained, so the exact server-side reason for that historical 400 cannot be
proven solely from its INVALID_ARGUMENT code. No Rules bypass is established.

Corrected fixed IDs (ASCII, under 1500 UTF-8 bytes, no slash, not dot/dot-dot and not
reserved form):
- `velora-rules-smoke-profile-20261106-no-fixture`
- `velora-rules-smoke-cafe-20261106-no-fixture`

Reference for the identifier constraint: Firebase Firestore quotas documentation,
Constraints on document IDs, https://firebase.google.com/docs/firestore/quotas .
No public documentation or production endpoint was fetched during these local checks.
The earlier targets/results above remain historical evidence; they are not rewritten.

New preview URLs:

```text
https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/users/velora-rules-smoke-profile-20261106-no-fixture
https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents/cafes/velora-rules-smoke-cafe-20261106-no-fixture
```

All ID characters are URL-safe ASCII; no percent-encoding transformation is needed.
URL validation checks fixed allowlist, HTTPS host, project, `(default)` database,
collection and decoded document ID. Query strings, URL credentials and other targets
are rejected. No Authorization, cookies, API keys, Admin SDK or privileged credential
source exists in the harness. No new credentials or configuration are needed for
the intended unauthenticated test, though actual API/gateway behavior remains
unverified until separately approved execution. 400/404/network/API prerequisites
remain INCONCLUSIVE, not authorization PASS. An infrastructure failure will stop,
not trigger retries, credential acquisition, API activation or configuration changes.

Harness changes: local ID/URL validation; safe import without execution; an offline
self-test using fake EventEmitter transport; sanitized message categories/text for
reserved IDs, malformed paths, authentication/API prerequisites and Rules denial.
Arbitrary error text/document contents are not printed. Firebase statuses and error
reasons are allowlisted or redacted rather than logging arbitrary server strings;
no response headers/details bodies, credentials or successful document contents
are logged. Unknown messages are explicitly redacted, preserving status/category.

Two-request maximum, zero retries/redirect following, ten-second socket timeout,
8 KiB response limit and stop-after-first-unexpected behavior are preserved. The
runtime flag remains approval-gated and was NOT executed. A changed target needs
fresh approval; earlier approval for the invalid paths does not cover these URLs.

Executed local commands:

```powershell
node --check docs/firebase/firestore-unauthenticated-smoke.cjs
node docs/firebase/firestore-unauthenticated-smoke.cjs --self-test
node docs/firebase/firestore-unauthenticated-smoke.cjs
 git diff --check
```

Self-test PASS: 19 assertion groups, zero network requests. Tests cover both target
IDs/paths, reserved/empty/slash/dot/oversize rejection, project/query-string rejection,
redacted messages, credential-free GET options, two successful mock denials, stopping
on mocked 400/404/302/200, no redirect/retry and network-error stopping. Mock 403 is
not a production observation. Syntax and no-network preview PASS. Final diff check
recorded in task report; existing unrelated line-ending warnings only.

Result: corrected harness ready for a NEW explicit production approval in a separate
step. Runtime authorization still NOT VERIFIED. No approval was requested here.
Schema, local/cloud Rules and documents unchanged; production reads/writes NONE
this phase; deployment NONE. Only the harness/results files modified. No dependency,
application/backend changes, emulator, staging access, Git add/commit/push or cleanup.

## Corrected runtime smoke execution (2026-11-06, Asia/Kuala_Lumpur)

The user freshly approved only the two corrected unauthenticated GETs after local
syntax/preflight and 19 offline assertion groups passed. Executed the reviewed
harness once from C:\Users\23000\velora:

```powershell
node docs/firebase/firestore-unauthenticated-smoke.cjs --execute-approved
```

Project/database: velora-73222/(default). Auth mode: NONE (no Authorization, cookies,
API keys, CLI/Admin credentials). Exactly 2 requests; 0 retries; 0 redirects.
Process exit: 0. Both requests received the standard Firestore denial message.

| Exact document path | HTTP | Firebase status | Sanitized diagnostic | Result |
| --- | --- | --- | --- | --- |
| /users/velora-rules-smoke-profile-20261106-no-fixture | 403 | PERMISSION_DENIED | Missing or insufficient permissions. | PASS |
| /cafes/velora-rules-smoke-cafe-20261106-no-fixture | 403 | PERMISSION_DENIED | Missing or insufficient permissions. | PASS |

Both targets used this base:
`https://firestore.googleapis.com/v1/projects/velora-73222/databases/(default)/documents`.
No errorReasons/infrastructure reason codes were returned in the sanitized results.
No documents, raw response bodies/headers or credentials were printed or persisted.
No additional request, metadata readback, authenticated test or automatic next phase.

Interpretation: PASS for these two actual unauthenticated denial cases only. These
results are not missing-document 404s, validation 400s or network failures. They do
not establish authenticated workspace isolation, valid Owner/Staff access, writes,
query budgets, listener behavior, existing fixture availability or complete Rules B
security. The old authenticated-only catch-all would also deny anonymous access;
therefore these two denials do not independently identify the active Rules version.
Active-source identity remains prior approved deployment/readback evidence.

Verification: fresh approval PASS; request cap PASS (2/2); profile denial PASS;
workspace denial PASS; production document writes NONE; Rules/Functions deployment
NONE. Final git diff check is recorded in task report. No full suite rerun because
no application/harness code changed in this execution phase.

Database report: schema, local Rules, production Rules and documents unchanged.
Reads: exactly these two approved unauthenticated GET attempts, both denied.
Writes/deletes/deployment/account/API/IAM/billing changes NONE. Only this sanitized
results document updated; GitHub not committed/not pushed, unrelated work preserved.
STOP. Further authenticated or fixture-based testing needs separate explicit scope
and approval; do not automatically rerun this harness.
