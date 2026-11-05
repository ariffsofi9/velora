# Phase 1C: recovery gate and bounded retention

Phase 2B adds an immutable ticket payloadDigest field; cleanup validates its format
when present. Eligibility, seven-day retention, quota counters and indefinite
quarantine remain unchanged. See [Phase 2B](groq-secure-handler-phase-2b.md).

2026-11-06, local-only. Implemented cleanup primitives and offline tests; quarantine
reconciliation remains intentionally unsupported. No provider, callable, scheduler,
Flutter, Rules, index, TTL, cloud or dependency changes.

## Recovery feasibility decision

The current foundation never sends Groq requests and stores no provider operation
identifier or authenticated termination evidence. The existing demo provider has
bounded local timeout/abort handling, not proof that remote execution stops when
the local timeout expires. No available inspected contract establishes a reliable
provider cancellation/status reconciliation guarantee. No live verification done.

Therefore an operator cannot safely unlock based on elapsed time, local timeout,
quota rollover, absence of a response, a client assertion or a new fencing token.
Quarantine remains indefinitely. No recovery/unlock/reset interface is implemented,
even for an asserted administrator. Reserved-but-undispatched expiry recovery is
unchanged; it never redispatches work and never refunds quota. A quarantined request
rejects subsequent recovery/completion attempts and retains its lock.

Future recovery would require a separately reviewed evidence producer proving the
exact remote operation is terminal or never dispatched. A hypothetical future
operator action must use trusted identity, a narrow allowlisted recovery capability
scoped to workspace, ticket, fence and operation; independent approval of evidence;
an expiring one-use command ID; transactional compare-and-set; and an immutable
sanitized audit linking command, operator, evidence reference and before/after state.
Receipt/command lookup must reject replays or stale fences. Never refund counters
or redispatch old work. These are prerequisites, not new paths or implemented
guarantees. If sufficient evidence cannot be obtained, no unlock is permissible.

## Implemented cleanup contract

createAiQuota(...).cleanupExpired({ticketIds}) is a trusted backend maintenance
primitive, not an exported callable or client API. The store/clock dependencies
remain trusted. It accepts 1-10 unique valid server-issued-format IDs and reads
time solely from its backend clock. Caller timestamp/expiry fields have no effect.
No candidate discovery query, cloud job, operator entry point or cleanup trigger
is included. Future wiring must authenticate/authorize the maintenance principal;
do not expose this method directly to request.data.

Each candidate executes in its own native Admin transaction through adminQuotaStore:

1. Read ticket and receipt. Missing both returns missing (idempotent no-op). A
   receipt without its ticket returns orphan-preserved; do not infer missing data.
2. Validate existing ticket schema and fixed retention arithmetic. Only issued,
   completed or abandoned states are eligible. Admitted, dispatched and quarantined
   states return protected without deletion regardless of age.
3. Check ticket retainUntil against trusted time. Issued tickets must have no
   receipt. Terminal tickets must have a consistent receipt and both retention
   deadlines reached. Missing/malformed terminal evidence fails closed.
4. Read/validate workspace counter and lock. Missing/malformed counter fails closed.
   Any lock referencing this ticket protects it even if its state is inconsistent.
   A different request's lock is neither removed nor rewritten.
5. Atomically delete the eligible ticket and its optional terminal receipt. No
   counters, membership records, locks or other documents are modified. Native
   transaction retry rechecks all eligibility against current records.

Batch processing is sequential, at most 10 transactions, 30 logical document reads
and 20 deletes before SDK retries. Different candidates are not one global atomic
batch. A later candidate failure can follow earlier committed deletes; repeating
the batch is safe. Errors remain fixed/sanitized. SDK retries can exceed nominal
operation counts; require a future bounded job time/attempt budget and a reviewed
Admin transaction maxAttempts setting when wiring real maintenance. No retry loop
or network calls are added by this library beyond native transaction behavior.

## Retention and replay safety

- Unused issued tickets: retain at least five-minute validity plus seven days.
- Completed/abandoned pairs: retain until BOTH the ticket deadline and receipt's
  admission-plus-seven-days deadline have passed.
- All active/dispatched/quarantined records: preserve indefinitely until a safe
  state transition is separately authorized. Indefinite exception is intentional.
- Usage counters: never deleted by this primitive, including at UTC midnight.
  Existing quota code rotates day counters in place, preserving unresolved locks.
- Orphan/malformed authority metadata: preserve and flag through a future sanitized
  maintenance report; no speculative repair or deletion.

No special replay tombstone must survive deletion of an eligible unused/terminal
pair: issue() alone creates fresh cryptographically random IDs; admission never
creates tickets and rejects missing tickets. Deleting a receipt alone does not
reactivate a retained terminal ticket. Ticket/receipt deletion is atomic here.
Counters and any newer reservation remain untouched. Rejected replay never charges
quota. Historical incident evidence may need longer retention; an actual future
investigation-hold mechanism must be reviewed before enabling cleanup of such
records. No quarantined evidence is eligible now.

## Operational prerequisites and cost limits

This method does not by itself bound total storage: running cleanup reliably is
a future operational prerequisite, and unresolved quarantines remain exceptions.
Use a separately approved trusted maintenance entry point with one page of at most
10 candidates, a maximum number of pages per run, frequency, execution deadline,
max attempts, budget and sanitized counts. Candidate IDs are hints only: every
eligibility condition is rechecked transactionally. Avoid repeatedly querying old
protected records; query strategy and starvation handling require explicit review.

Prefer reviewed transactional scheduled cleanup over independent TTL on tickets
and receipts: generic TTL cannot preserve pairs, check current locks or exempt
unknown outcomes by this code's predicates. No TTL policy is enabled or recommended
directly on current retainUntil fields. TTL deletion timing is not a safety boundary.
Future query indexes, TTL/exemption fields, Cloud Scheduler/job APIs, runtime IAM
delete/list permissions and billing must be separately approved. No index is needed
for cleanup's current direct document GETs; discovery-query indexes are not defined.

Costs include candidate query reads, three GETs per eligible candidate, up to two
deletes, storage and transaction retries. Protected/missing candidates still cost
reads. No free/zero-cost cleanup or hard RM5 cap is claimed.

## Offline validation scope

Tests use versioned optimistic transactions and atomic write/delete application.
They cover cleanup eligibility boundaries, terminal/unused records, replay after
cleanup, lock/quarantine protection, no refunds, missing/malformed pairs, UTC
boundary, conflicts, commit failure and repeated cleanup. Tests also verify there
is NO quarantine reconciliation API: untrusted/evidence/stale/duplicate claims
cannot produce an unlock. They do not validate a nonexistent operator IAM/audit
implementation or prove actual Firestore isolation/provider termination.

Commands from functions:

```powershell
node --test test/ai-quota.test.js
node --test test/ai-quota.test.js test/firestore-rules-contract.test.js test/workspace-resource-config.test.js
npm.cmd test
```

From root: node --check functions/src/ai-quota.js,
node --check functions/test/ai-quota.test.js, git diff --check.

Observed Phase 1C results: quota suite 54 passed; combined focused suite 61 passed;
default backend regression 367 passed. Every suite had zero failed, cancelled,
skipped or todo tests; suites overlap. All command exits 0. Both JavaScript syntax
checks and git diff --check passed (existing LF/CRLF warnings only). Local Rules
SHA-256 remains d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.
Node used: 24.15.0, not the configured deployment runtime 22. Emulator, actual
Firestore transactions, operator authorization, provider termination and deployed
Rules runtime were NOT RUN / NOT VERIFIED.

DATABASE CHANGE REPORT: no new fields or collections beyond Phase 1B; local Admin
adapter now supports native transactional delete. Proposed future cleanup deletes
eligible ai_generation_tickets/{id} and ai_generation_requests/{id} only. This batch
deleted modeled documents in tests, not files or live documents. Production schema,
local/production Rules, indexes, documents, Auth and billing unchanged. Production
reads/writes NONE; deployments NONE. No secret/IAM/API changes, emulator, Git save
or history rewrite. Existing dirty work preserved.

NO-GO for provider activation or automated cloud maintenance. Quarantine cannot be
unlocked safely using evidence currently available in this repository.
