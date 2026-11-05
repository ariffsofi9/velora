# Phase 2A: secure callable contract gate

Phase 2B supersedes this blocker: the user approved payloadDigest and fresh-only
responses. See [Phase 2B implementation](groq-secure-handler-phase-2b.md). The
isolated handler is implemented locally and remains absent from index.js exports.
Historical requirements/findings below remain context, not the current gate status.

2026-11-06, Asia/Kuala_Lumpur. BLOCKED before handler implementation, as required
by the attached Phase 2A instruction to stop before essential persistent changes.
This document is the only change. No callable, provider, Flutter or quota code added.

## Verified blocker

functions/src/ai-quota.js issue() creates tickets containing schemaVersion,
ticketId, UID/cafe, actor/Owner generations, issuedAt/expiresAt/retainUntil and state.
admit() creates a receipt with identity, fence, admission/lease/retention times and
state. Neither stores a payload digest. Existing sameAuthority() pins identities and
membership episodes, not recipe request content. A same-ticket replay currently
returns admitted:false/state without comparing any recipe payload. No result storage
or result retrieval operation exists. Phase 1D explicitly identified these gaps.

An in-memory digest map cannot bind across instances/restarts. Treating a client
digest as authoritative cannot prove what was originally issued. Reusing fence,
identity or state fields for payload data would silently change existing semantics.
Do not alter ticket generation into a novel cryptographic commitment protocol just
to avoid the persistent-schema review gate. The smallest transparent extension
under the current random-ticket design is a persistent immutable payloadDigest.

Phase 2A says: 'If new persistent fields or indexes are essential, document them
and STOP before implementation.' No approval for that field is inferred here.

## Minimal schema change proposed, NOT IMPLEMENTED

Add payloadDigest to ai_generation_tickets/{ticketId}: exactly 64 lowercase hex
characters, SHA-256 of a server-normalized, versioned recipe request specification.
Compute server-side before issuance, store atomically with ticket/counters, and
compare transactionally on every fresh or duplicate admission and dispatch before
returning any state or dispatch authorization. Never permit update of the digest.
Keep existing membership schemaVersion:1 unchanged. No new collection/index needed
for direct ticket lookups. No migration or blanket acceptance of missing digests.

Fail closed for an older unbound ticket in the future recipe handler; do not silently
attach a digest on redemption. Existing isolated quota APIs/tests can remain their
foundation contract until a separately approved recipe-specific binding extension
defines compatibility. Generic legacy foundation tickets must not be redeemable by
the future secure recipe endpoint. No production tickets/data are assumed to exist.

Proposed normalized specification: fixed recipe protocol version and fixed model
configuration version plus maxRecipes integer 1-3 (default 1). Canonical serialization
uses explicit ordered fields and server defaults; reject unknown fields. Do not
accept caller model, endpoint, actor, role, counters, key, inventory or system prompt.
UID/workspace/actor generation/Owner generation are already separately pinned.

Inventory input is a separate required integration decision: derive it only from
trusted, bounded workspace reads at dispatch, recheck after generation, and state
that tickets bind recipe options rather than a caller-supplied inventory snapshot.
If the product requires inventory-at-issuance semantics instead, approve a further
inventory snapshot digest/version contract before code. Do not claim payloadDigest
alone authorizes inventory data or a provider result.

## Proposed request lifecycle, pending approval

Two operations, strict exact field sets and serialized request <=2KiB:
- issue: expectedCafeId, expectedMembershipGeneration, maxRecipes.
- generate: those exact normalized recipe options plus ticketId.

Future handler must derive auth from verified callable context, require
email_verified===true, and inject an authoritative Admin getUser(identity.uid)
lookup. Reject UID mismatch, missing/disabled/unverified account, failed lookup and
revoked-session evidence (compare valid auth_time against tokensValidAfterTime
where applicable). Recheck current account before dispatch and result release.
Do not repurpose the demo-only request-identity verifier without preserving its
isolation constraints. No Auth SDK lookup can be in an atomic Firestore transaction;
document the residual race and recheck at trusted boundaries.

Quota authority must keep active canonical, cafe, self member and Owner pair,
schema/role and both generation checks. Admission and payload comparison belong in
the same transaction; dispatch must compare again. No provider call inside a
transaction callback. Only a confirmed first dispatch transition permits a single
attempt. Unknown admission/dispatch commit response must not lead to another remote
attempt. Quarantine outcome classification stays conservative, with no reset or
refund path introduced by the callable.

## Result policy decision, NOT IMPLEMENTED

Recommend Phase 2A return a freshly generated sanitized result only, after current
account + canonical/Owner/episode + inventory revalidation. Duplicate requests return
a fixed already-processed/in-progress state and never regenerate. Explicitly reject
stored-result retrieval because no stored results exist. This needs agreement in
the client contract: a lost successful response cannot be retrieved under this
policy. Do not pretend state-only receipts contain retrievable recipes.

If stored-result retrieval is required, approve additional receipt fields first:
bounded sanitized result plus result schema/provenance/inventory snapshot binding,
expiry and terminal outcome. Reauthorize account, actor/Owner episode and workspace
before every retrieval; never return cached data to revoked users. Decide storage
limits, lifecycle, cleanup eligibility and costs. This is beyond the one digest
field proposal, not silently implemented.

## Provider boundary and compatibility

functions/ai1/groq-provider.js currently requires isolated demo configuration; do
not remove its guards to make production work. Reuse pure validation through a
separately reviewed extraction, leaving demo behavior intact. Inspected defaults:
openai/gpt-oss-20b, 15-second bounded timeout, 2048 completion tokens, redirect:error,
request/response size checks, no automatic retry and fixed error categories.
Timeout/abort is not evidence of remote termination. Treat uncertain transport,
timeout, malformed/incomplete responses and unknown termination conservatively.
No live provider capability/model availability is verified here.

Use injected mocked transport for all new tests once the gate is approved. Never
read a real secret or fall back to live fetch in a test. No secret binding/export
or provider request is added now. Existing createWorkspace options and all exports
remain untouched. Billing, Secret Manager, maintenance and quarantine reconciliation
remain separate NO-GO gates.

## Required next local batch

Approve the ticket payloadDigest extension and fail-closed handling of old unbound
tickets; confirm whether fresh-only results suffice or approve bounded persisted
results. Then implement the isolated quota-binding extension and its tests before
the handler. Required tests: same-ticket changed payload before/after admission;
digest default/canonicalization; missing/malformed digest; concurrent conflicting
payloads; account state/revocation; inventory/Owner/episode revalidation; quota and
dispatch ambiguity; sanitized errors; lost-response policy; and unchanged exports.

## Verification executed at the blocked gate

From functions: node --test test/ai-quota.test.js test/firestore-rules-contract.test.js
test/workspace-resource-config.test.js: 61 passed, zero failed/cancelled/skipped/todo.
npm.cmd test: 367 passed, zero failed/cancelled/skipped/todo. Suites overlap.
From root: node --check functions/src/ai-quota.js and node --check
functions/ai1/groq-provider.js passed; git diff --check passed with existing
LF/CRLF warnings. All executed verification commands exited 0. Existing suites
were rerun; no new handler/binding implementation or tests exist to verify yet.
Firestore/provider/production runtime, Auth network checks and emulator NOT RUN.

DATABASE CHANGE REPORT: proposed new ticket payloadDigest field only, not applied.
Optional result fields are an additional proposal, not schema changes. Production
schema, local/production Rules, indexes, documents and Auth users unchanged.
Production reads/writes NONE; deployments NONE. No emulator, provider, billing,
IAM/API, Secret Manager or Git stage/commit/push/history changes.
