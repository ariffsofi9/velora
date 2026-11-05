# Durable Groq quota foundation: Phase 1B

Phase 2B adds the approved immutable payloadDigest ticket field and binding-required
mode for the isolated secure handler. See [Phase 2B](groq-secure-handler-phase-2b.md).
Generic legacy quota behavior remains for existing tests; bound tickets cannot
bypass digest checks. No AI result storage or deployed callable added.

Phase 1C supersedes the earlier statement that deletion is not implemented:
the isolated library now includes bounded transactional cleanup, with no trigger
or cloud execution. Quarantine still cannot be unlocked. See
[Phase 1C recovery/retention](groq-quota-recovery-retention-phase-1c.md) for exact
eligibility, limits, safe replay behavior and operational prerequisites. Remaining
Phase 1B verification results below are historical, not current Phase 1C counts.

Local implementation, 2026-11-06. No callable export, provider, Flutter wiring,
Secret Manager integration or network operation is included. No dependency added.

## Feasibility decisions

Tickets use 32 cryptographically random bytes encoded as 64 lowercase hex characters.
Only issue() can create a ticket; it accepts no caller-selected ticket/request ID.
Admission requires that issued record, matching trusted identity/episode and an
unexpired five-minute lifetime. Missing tickets ALWAYS reject; admission never
upserts them, including after cleanup. Receipts alone cannot authorize work.
This resolves the deleted-receipt replay ambiguity without signing keys or a new
secret. Repeated issuance intentionally produces different tickets and consumes
the separate issuance allowance. A lost issuance response is not free to retry.

There is no generic reset/reconciliation endpoint or library unlock for quarantined
work. Strict quarantine is safe even if it blocks a workspace indefinitely. Normal
reserved recovery is implemented; reconciliation of unknown dispatched work is
design-only and requires a separate evidence-backed operational approval.

## Proposed backend-only Firestore paths

| Path | Schema version 1 fields |
| --- | --- |
| ai_usage_users/{uid} | subject=UID, UTC numeric day, issued, admitted, lock=null |
| ai_usage_workspaces/{cafeId} | subject=cafeId, UTC numeric day, issued, admitted, lock=null or {ticketId,fence,until} |
| ai_generation_tickets/{randomTicketId} | ticketId, uid, cafeId, generation, ownerUid, ownerGeneration, issuedAt, expiresAt, retainUntil, state |
| ai_generation_requests/{ticketId} | ticketId, uid, cafeId, fence, admittedAt, leaseUntil, retainUntil, state; terminal updatedAt and optional fixed outcome |

Time fields are safe-integer epoch milliseconds derived from the trusted backend
clock, not client timestamps. Day is floor(epochMillis/86400000), UTC. No membership
schema or writes change. Owner and Staff share existing active authority rules and
generation validation; legacy absent/absent generation remains zero. Owner identity
and generation are pinned in each ticket as well as the actor episode.

## Library API and trust boundary

functions/src/ai-quota.js exports createAiQuota, adminQuotaStore and AiQuotaError.
adminQuotaStore(db) adapts an already-created Admin Firestore instance to native
db.runTransaction; it does not initialize Firebase. No current export imports it.
All persistent mutations occur inside a transaction, with reads before writes.

- issue({auth,expected}) derives actor and workspace from trusted callable Auth and
  canonical/member/cafe/Owner records; expected has only expectedCafeId and
  expectedMembershipGeneration. Future caller must obtain auth from Firebase,
  never request.data. No caller role, UID, counter, clock or ownership input.
- admit({auth,expected,ticketId}) rechecks authority and pinned ticket episode,
  atomically charges user 10/day and workspace 30/day limits, creates receipt and
  reserves workspace. Only the first admission returns a fence. Duplicates return
  admitted:false and state, never a fence or dispatch grant. The future payload is
  deliberately absent: provider input must be derived by a separately reviewed
  backend, or the ticket protocol extended to bind any future variable payload.
- dispatch({auth,expected,ticketId,fence}) rechecks current membership and ownership
  before the admitted-to-dispatched transaction. It returns dispatch:true exactly
  for that transition. It is NOT a Groq call. Duplicate dispatch rejects. Provider
  work must only follow a confirmed successful transition, never occur in a
  transaction callback, and never retry an ambiguous dispatch commit.
- complete({ticketId,fence,outcome}) is an internal worker-only primitive, NOT a
  client method. Allowed outcomes: success, provider-rejected, unknown, timeout.
  Only a definitely finished provider response may use the first two. Network
  failure/cancellation/uncertain transport must use unknown or timeout. Results are
  not stored/returned here; future result release must revalidate authority.
- recoverExpired({ticketId,fence}) is also backend-only. It can abandon an expired
  admitted reservation, never redispatch it. A dispatched request quarantines.

The factory's store/clock/random are trusted dependencies, injectable for tests,
never callable data. Fence values must stay in trusted worker code. No provider
credentials, raw errors, logs, prompts or results exist in this module. Known errors
have fixed text/code; unexpected storage errors are mapped to unavailable.

## Accounting and issuance abuse controls

Approved admitted quotas: 10/user/day and 30/workspace/day. Workspace locking begins
at admission, stricter than locking only during provider dispatch. It persists
across users, service instances, revisions and midnight through shared state.

Issuance uses a separate conservative daily budget of 20/user and 60/workspace
(twice admitted limits). This caps accepted ticket creation without decrementing
admitted quotas. Unauthorized, invalid, expired, exhausted and conflicting admission
attempts do not consume admitted quota. Denied calls still cost compute/reads.
Issuance is also refused while the workspace has an active or quarantined lock.
There is no per-minute throttle in Phase 1B; minute burst controls and App Check
remain future admission hardening, not falsely claimed implemented guarantees.

Once admitted, a request stays charged for provider rejection, timeout, crash or
unknown outcome. No refund operation exists. Counter changes and lock/receipt writes
are atomic. Daily rollover resets counters only, never releases a lock. Counter
records with malformed/future values fail closed. User accounting spans workspaces
and membership episodes; changing membership does not reset its current-day counter.

## Leases, fencing and crash recovery

Lease lifetime is 120 seconds from admission, measured by trusted server clock.
Dispatch is only allowed before this deadline. Each admission has an independent
random 256-bit fence and unique ticket. Completion validates both against the
current workspace lock and immutable receipt. Stale completions cannot release a
successor lock; terminal requests cannot transition back to dispatched.

Expired admitted reservations can become abandoned and release their lock: the
durable dispatch transition never occurred, so a compliant worker cannot have
sent provider work. Expired dispatched requests become quarantined and KEEP the
workspace lock. Timeout/unknown does the same immediately. Even a late success
after lease expiry quarantines conservatively. Expiry alone never unlocks dispatched
work. A lost response after dispatch commit is treated as unknown, not retried.

Quarantine reconciliation design: a future separately authorized backend/operator
must establish that remote work is definitely terminal or never dispatched, identify
the exact ticket/fence, retain sanitized evidence and finalize under a transaction
comparing that fence. If provider evidence cannot establish termination, keep the
lock. Never use client claims, elapsed time, billing reset or counter edits as
evidence. No evidence producer or reconciliation/unlock code is implemented here;
this is an operational blocker for activation, not an automated recovery promise.

No exactly-once external execution is claimed. Fencing controls Firestore state,
not a remote provider. This foundation contains no network dispatch and cannot
prove a future worker follows the dispatch protocol. Do not activate until that
worker and conservative outcome classification are reviewed and tested.

## Retention and costs

Tickets retainUntil = five-minute expiry + seven days; receipts retainUntil =
admission + seven days. These are eligibility metadata, not active TTL policies.
No cleanup job/deletion implementation is included. Cleanup must never remove
locked/admitted/dispatched/quarantined ticket/receipt pairs, even past retainUntil.
Unknown states can persist indefinitely, at most one locked request per workspace.
Terminal or unused expired records may be cleaned after the eligibility time in
a separately approved bounded retention batch. Replay remains denied even if both
ticket and receipt were removed: old IDs cannot create admission records.

Usage counters rotate in place. Do not delete current-day counters or locks: doing
so resets quota. An optional future inactive-counter purge must require an older
UTC day and no lock, transactionally. Normal storage is bounded per user/workspace
and accepted ticket issuance per day; without executing cleanup, historical ticket
storage continues growing. Retention metadata alone does not bound actual storage.

Issue: authority reads (3 Owner/5 Staff), two counter reads, two counter writes and
one ticket create. Admit adds ticket/receipt reads and atomically writes two
counters, ticket and receipt. Dispatch/completion/recovery read ticket, receipt and
workspace usage, with authority reads on dispatch, then write the three records.
Transaction retries add reads. Retained document storage, cleanup deletes, optional
TTL configuration and denied-request traffic add costs. RM5 alerts are not a cap;
Groq charges would be separate. No indexes or TTL policies are created locally or
in cloud. No collection queries require a new composite index in this module.

## Rules and offline verification

The four proposed root collections have no explicit grants in Rules B and are
covered by its catch-all read/write deny. No Rules edits required. Admin bypasses
Rules: the library's own authorization is mandatory. Tests inspect the local Rules
contract only, not runtime authorization or deployed content.

Focused command from functions: node --test test/ai-quota.test.js. Tests use
optimistic snapshot/version transactions with retries, atomic commit and read-before-
write enforcement, across independent factory instances sharing one modeled store.
They test admission/issuance limits, parallel attempts, duplicate dispatch, cleanup
replay, revoked/stale/forged authority, clocks, fences, quota accounting, unknown
quarantine, safe reservation recovery and commit failure. These do not prove actual
Firestore isolation, runtime behavior or provider termination.

Observed offline results on Node 24.15.0 (deployment package still targets Node 22):
- node --test test/ai-quota.test.js: 36 passed, zero failed/cancelled/skipped/todo.
- node --test test/ai-quota.test.js test/firestore-rules-contract.test.js
  test/workspace-resource-config.test.js: 43 passed, zero failed/cancelled/skipped/todo.
- npm.cmd test: 367 passed, zero failed/cancelled/skipped/todo; overlapping coverage,
  not an additional 367 unique new quota tests.
- node --check functions/src/ai-quota.js and functions/test/ai-quota.test.js from
  repository root: exit 0. git diff --check: exit 0; existing line-ending warnings.
- All commands exited 0. No new actual Firestore/Groq runtime behavior verified.
- Rules raw SHA-256 unchanged:
  d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

No provider/callable/Flutter code is added. Default npm test discovery is explicitly
listed and remains unchanged; run this focused suite separately in Phase 1B.

DATABASE CHANGE REPORT: proposed local schema only as above. Production schema,
local/production Rules, indexes, documents and Auth users unchanged. Production
reads/writes and deployments NONE. No emulator, secrets, IAM, APIs, billing, Git
stage/commit/push or history rewrite. Existing uncommitted work preserved.
