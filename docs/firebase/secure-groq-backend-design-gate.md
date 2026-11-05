# Secure Groq backend: local design gate

## Phase 1B outcome (supersedes the earlier preflight blocker)

The approved server-issued ticket and strict-quarantine design is now implemented
as an isolated, unexported backend foundation. See
[Phase 1B schema/protocol](groq-durable-quota-phase-1b.md),
functions/src/ai-quota.js and functions/test/ai-quota.test.js. Missing/deleted ticket
IDs never create admission records; post-cleanup replay is rejected. Expired
undispatched reservations can close; uncertain dispatched outcomes remain locked.
No automatic quarantine unlock, Groq call, secret binding or Flutter integration
exists. Evidence-backed operator reconciliation remains design-only and must be
approved before activation. Earlier sections below are historical design proposals.

## Phase 1 preflight: approved limits and remaining blockers

2026-11-06: user approved local durable-quota foundation with 10 admitted requests
per authenticated UID per UTC day, 30 per trusted workspace per UTC day, and at most
one active request per workspace. These supersede the earlier limits-for-review
paragraph below. The proposed minute limits, user lease, seven-day retention and
120-second automatic reclaim remain unapproved design candidates, not requirements
or implemented controls. No quota module or callable has been added.

Phase 1 explicitly says to stop when essential retention/recovery semantics remain
ambiguous. Two decisions are needed before safely implementing admission:

1. **Replay after cleanup.** Arbitrary client request IDs plus deleted receipts
   cannot distinguish a very old replay from a new request. Recommend a separate
   server-issued, expiring request-ticket protocol: only existing valid issued
   tickets may transition to admitted; missing/expired tickets cannot be admitted.
   Ticket issuance itself needs bounded durable admission/rate controls to avoid
   an unlimited receipt-creation endpoint. Define ticket lifetime, issuance limits,
   retry window and receipt retention before implementing. Alternative: explicitly
   accept that reuse after retention is a new charged operation. That alternative
   weakens the unconditional duplicate guarantee and is not silently adopted.
2. **Unknown external outcome.** Expiry is not proof that Groq has stopped processing
   a dispatched request. A new database fence only blocks stale completion writes.
   Recommend automatic recovery only for work provably not dispatched, using an
   atomic reserved-to-dispatched transition. An expired dispatched/unknown request
   should stay quarantined and keep the workspace blocked until an approved
   resolution protocol establishes safety. A crash between dispatch intent and
   actual HTTP send must also be treated as unknown. This favors safety but can
   block the workspace indefinitely; accepting it requires an explicit operational
   recovery policy. Alternatively approve bounded local leases with the stated
   residual possibility of overlapping remote work; that does not satisfy a strict
   no-overlap guarantee. Neither policy is implemented here.

Accounting proposal pending protocol approval: only a successful admission charges
both counters, exactly once transactionally. Provider failure, timeout or rejection
after admission remains charged; authorization/quota rejection before admission
does not increment counters. UTC rollover does not release an unresolved lock.
Existing memberships and schemaVersion:1 stay unchanged.

Result: BLOCKED at the requested preflight gate, not a failed implementation test.
No backend/Flutter/Rules/configuration edits, cloud access, TTL or data writes.
The rest of this document records the earlier proposal, not deployed guarantees.

2026-11-06, Asia/Kuala_Lumpur. BLOCKED on approval of durable usage-control schema.
This document is the only change in this batch. No new handler, export, secret
binding, client wiring, quota writes or deployment is implemented.

## Inspected contracts and blocker

- functions/src/index.js is the workspace v2 entry point. firebase-functions 7.4.0
  supports defineSecret and callable secrets binding. Resource option names and
  256MiB units are supported by installed SDK declarations. No new dependency is
  needed to declare a secret or use Node 22 fetch/AbortController.
- functions/src/menu-service.js authorizes active canonical, member, cafe and Owner
  links, schemaVersion 1 and membership generations. Its authorization function is
  private to that module; importing a nonexistent shared resolver is unsafe.
  mutation-episode.js validates client expectations but is not authorization.
- functions/ai1/recipe-service.js explicitly implements per-process busy/seen
  protection. It requires isolated demo environments. Restarts, deployments and
  multiple instances would reset/split counters. Do not repurpose it as production
  quota enforcement or remove its isolation guards.
- functions/ai1/groq-provider.js obtains an environment key, has a fixed endpoint,
  bounded prompt/output/timeout, injected fetch, structured validation and safe
  errors. createGroqProvider is also demo-isolated. A future provider extraction
  must preserve those demo guards and tests, not weaken them to accept production.
- lib/logic/ai_quota_service.dart uses global ai_quota/date documents and increments
  usage from the client after work. This is neither admission control nor a secure
  per-user/workspace quota. Existing Rules B default-deny these legacy paths.
- lib/logic/groq_service.dart still contains direct-provider HTTP support with an
  empty default key. suggestions_foundation.dart supplies no key; legacy generation
  internals and fake/demo presentation are not a production AI implementation.
- Existing workspace invitation counters have invitation-specific semantics;
  reusing their paths/fields for AI would silently change the data contract.

Distributed rate, daily and concurrent-request enforcement requires durable shared
state. maxInstances:1 and concurrency:1 are admission/scaling controls, not durable
quotas across restarts or revisions. The user requires a stop before new quota
schema implementation. Phase C therefore does not pass; no integration is claimed.

## Proposed API contract (not exported)

Proposed callable name: generateWorkspaceRecipes; region asia-southeast1.
Only request fields: requestId (16-64 ASCII alphanumeric, underscore or hyphen),
expectedCafeId (existing ID validation), expectedMembershipGeneration (nonnegative
safe integer), maxRecipes (integer 1-3, default 1). Reject extra fields. Do not accept
actorUid, role, quota, model, prompt, endpoint, API key or client inventory as authority.
Reject overly large serialized requests before database work; proposed cap 2KiB.

Derive UID from callable Auth; require email_verified === true and recheck current
Auth account disabled/verified state before admission and before result release.
Read canonical mapping, cafe, self member and Owner links transactionally; validate
active/schema/role/ownership/generation using the existing contract. Compare expected
workspace/generation only after deriving them from trusted records. Both roles may
request suggestions, neither may mutate inventory through this operation.

Server reads at most 101 inventory docs, fails explicitly above 100 rather than
silently treating an arbitrary subset as complete. Validate document scope/shape;
exclude archived, expired, nonpositive or unsafe stock; expose at most 20 items with
opaque aliases. Return no provider request for an empty eligible set. Any bounded
selection policy must be documented in the client; do not invent hidden ordering.

Response proposal: schemaVersion:2, requestId, provider:'groq', status:'ok' or
'no_suggestions', structured recipes with bounded title/steps/reason and ingredients
containing trusted itemId, positive quantity and matching unit. No raw completion,
provider metadata, quota internals or free-form provider error strings.

Use existing fixed safe failure categories: unauthenticated, failed-precondition
(verification/configuration), permission-denied (authority), invalid-argument,
aborted (changed episode/inventory), already-exists (request conflict),
resource-exhausted (rate/quota/inflight), unavailable and deadline-exceeded.

## Minimum proposed durable state: NOT APPROVED / NOT CREATED

These are proposed new backend-only paths, NOT existing collections:

- ai_usage_users/{uid}: version, UTC day/minute bucket identifiers and counters,
  active lease/request reference, lease expiry and server updatedAt.
- ai_usage_workspaces/{cafeId}: corresponding workspace counters and lease.
- ai_generation_requests/{sha256(uid, requestId)}: schemaVersion, UID, trusted cafe,
  actor/Owner generations, normalized-payload hash, operation fence, admittedAt,
  status, lease deadline, retention deadline and bounded terminal result/error.

Store UID/cafe only after trusted resolution. Counter keys span membership episodes:
rejoining or changing workspace must not reset the user's daily allowance. An Owner
adding Staff must not bypass the workspace allowance. Retain schemaVersion:1 on
existing membership records; no modification of authority collections is proposed.

Initial LIMITS FOR REVIEW ONLY: user 2 attempts/minute and 10/day; workspace 5/minute
and 30/day; one inflight attempt per user and per workspace. Use trusted UTC time;
strictly validate stored safe-integer counters and timestamps and fail closed on
malformed state. Limits count admitted provider attempts, including timeout/failure;
automatic refunds enable repeated-cost abuse and are not proposed.

Rules/Admin: existing catch-all denies clients at these proposed roots. Verify static
deny contract now and separately reviewed runtime authorization later; no Rules
change or deployment is proposed. Admin bypasses Rules, so every server read/write
must retain authorization. No client counter/result collection access.

## Proposed atomic protocol

1. Validate Auth/input. Read trusted authority, inventory and both usage docs plus
   deterministic request receipt within admission transaction. Deduplicate repeated
   document reads where identities overlap. All reads precede writes.
2. Reject stale episode, role/Owner conflicts, malformed counters, exhausted limits,
   or live leases. Same-key/different normalized payload fails; same-key/same-payload
   returns a validated terminal result or fixed in-progress response, never dispatches
   another provider call. Bind receipt to original membership episode.
3. Atomically increment both counters, reserve both leases and create receipt with
   operation fence. A transaction retry must never invoke Groq. A concurrent join,
   removal or other request must conflict on the same authority/counter documents.
4. Read the bound Secret Manager value only inside the handler. Missing/empty secret
   fails closed without logs containing its value. Provider call occurs outside the
   transaction, once per successful admission, with fixed model and no retries.
5. Enforce 15-second whole-operation provider timeout, abort signal, redirect:error,
   request <=32KiB, response <=64KiB and max_completion_tokens <=2048. Bound and
   validate response content; cap recipes 3 and item aliases 20. Fixed model candidate
   openai/gpt-oss-20b comes from existing provider code; future availability/runtime
   compatibility is NOT VERIFIED and must be separately reviewed before activation.
6. Recheck Auth, authority, episode and inventory snapshot before returning any
   result. Finalization transaction validates request fence/status and releases
   only its own leases; atomically stores bounded terminal result/error. A stale
   worker cannot release a successor's lock. Never mutate inventory or mark cooked.
7. A crash after remote dispatch has an unknown outcome. Do not automatically retry
   provider work or claim exactly-once external execution. An abandoned request
   retains charged attempt count. Reclaim a lease only after a conservative deadline
   exceeding function lifetime and provider timeout (proposal: 120 seconds), using
   a new fence and marking the old receipt indeterminate. Remote cancellation is
   best effort: delayed provider execution may outlive local timeout. This residual
   concurrency/cost risk needs explicit acceptance before implementation/activation.
8. Cached results require fresh authorization and same episode; revoked users must
   not retrieve an old result. Do not store raw prompts, keys or provider bodies.

Proposed receipt retention 7 days, with requests older than the supported retry
window rejected before admission. Since client request IDs do not encode age,
retention alone cannot enforce this: approve either a server-issued expiring nonce
protocol or explicitly document key reuse after retention as a NEW charged request.
This choice is unresolved and must not silently weaken retry safety. TTL/cleanup
is not enabled, assumed free, or immediate; approve exact policy and billed deletes
separately. Usage docs can rotate buckets transactionally without new daily docs.

## Future secret/resource/client integration (not implemented)

After quota protocol approval, declare defineSecret('GROQ_API_KEY') and bind only
that SecretParam in the new callable's secrets option. Access .value() at invocation,
never module initialization, Flutter, assets, dart-define, logs or responses. No
secret value is supplied in this document; secret creation and IAM remain separate
explicit approvals. User-reported revocation does not identify all historical tokens.

Proposed callable options: region asia-southeast1, memory 256MiB, cpu 1, timeout 30,
minInstances 0, maxInstances 1, concurrency 1. Leave createWorkspace and all other
exports unchanged. App Check rollout requires actual Android/Web setup and review;
do not assume a missing token is acceptable after future enforcement is enabled.

Flutter phase only after backend gate: inject a typed callable client with active
WorkspaceSession; send expectedCafeId/generation and stable requestId for unchanged
retries. Discard late results after session change. Remove direct Groq networking
without reintroducing legacy client cache/quota writes. Preserve current visuals;
explicitly label samples, show loading and safe unavailable states. No direct HTTP
fallback. Until then production generation stays unavailable.

## Cost, failure and verification plan

Admission requires bounded authority/inventory reads, two counter reads/writes and
one receipt read/create; completion repeats authority checks and updates receipt/
leases. Transaction retries, denied attempts, revalidation and receipt storage add
cost. Persistent leases throttle work but do not bound all rejected-request billing.
Use no raw request/provider error logs; bounded categories only. Firebase build,
artifact and secret-access costs plus separate Groq billing must be reviewed. RM5
Google Cloud alerts are not a hard cap or a Groq spending limit.

Required new offline tests after approval: unauthenticated/unverified/disabled;
missing/inactive/malformed canonical/member/Owner; forged workspace, role conflicts,
negative/unsafe/mismatched generation; exact legacy-0 compatibility; stale episode
before admission and after provider; bounded inventory/input; missing secret;
user/workspace minute/day exhaustion; concurrent distinct requests; same/different
payload retries; admission transaction retries; provider failure/timeout/crash;
finalization failure; lease fencing/reclaim; UTC rollover; retention replay policy;
sanitized responses/logs; no direct Flutter HTTP/secret; session late-result discard;
other callable configs unchanged. Model tests cannot prove cloud runtime behavior.

Approval needed next: durable schema, numeric limits, lease/fencing protocol,
receipt replay/retention policy and isolated implementation batch. No billing,
secret, deployment, production or emulator action is authorized by this design.
