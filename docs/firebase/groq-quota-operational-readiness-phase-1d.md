# Phase 1D: Groq quota operational readiness

2026-11-06, Asia/Kuala_Lumpur. Local read-only source audit plus this document only.
No provider, callable, client, maintenance entry point, scheduler or cloud changes.
Source: functions/src/ai-quota.js, its tests, Phase 1B/1C/design-gate documents,
membership-generation.js, mutation-episode.js, existing business modules,
functions/src/index.js, package.json and local Rules B. Current source overrides
historical documentation. Billing OFF/no deployed Functions are prior/user-provided
state, not cloud metadata refreshed by this audit.

## Decision

GO to separately scoped local callable development and mock-only client contract
work, subject to the implementation gates below. NO-GO to activation, deployment,
secret creation, maintenance automation or production AI. Mock passing is not
production atomicity, provider termination or cost evidence.

## Concrete candidate-discovery proposal (not implemented)

Use a ROOT ai_generation_tickets collection query, not collection-group queries or
a full collection scan:

```
where state in ['issued', 'completed', 'abandoned']
where retainUntil <= trustedRunCutoffMillis
orderBy retainUntil ASC
orderBy documentId ASC
limit 10
startAfter(lastRetainUntil, lastDocumentId) when resuming
```

Pass candidate document IDs to cleanupExpired. Candidates are hints; the transaction
rechecks state, both retention deadlines, schemas and current workspace lock. Ticket
retention may be earlier than receipt retention: a candidate can legitimately be
retained again. Quarantine/admitted/dispatched are excluded by discovery AND
protected independently inside cleanup. Workspaces with a newer active request do
not prevent safe deletion of old terminal pairs; only matching-ticket locks protect
that pair. Counter docs are never deleted or rewritten by maintenance.

Propose a reviewed composite index on state + retainUntil (and document-name cursor
ordering as required by Firestore), root collection scope. Exact index definition
and query acceptance are NOT runtime-verified; do not assume current draft inventory
index covers this. Optional per-workspace discovery adds cafeId to filters/index
and needs separate review. There is no new index file or production index here.

Initial maintenance: manually approved BACKEND-only one page, 10 unique IDs,
10 candidate transactions, fixed trusted cutoff, no automatic reruns. Use an
authenticated narrow maintenance principal, reviewed runner and exact target
check; no public/admin-client endpoint. These safeguards do not exist yet.
Preserve a trusted continuation cursor in a sanitized approved run record; advance
only after processing/classifying that candidate. Restarting from the first page
can starve later records behind protected/orphan/retained candidates. A reviewed
runner must record/report skips, resume after them, then revisit on a later sweep;
never solve a poisoned candidate by force-deleting or unlocking it. Bound sweep
pages, total candidates, retries and wall-clock time. New entries behind the cursor
can wait for the next sweep; this is a retention delay, not an admission bypass.

cleanupExpired currently stops on the first exception, possibly after earlier
candidate commits. Preserve the original batch on error and retry idempotently;
do not claim the whole batch rolled back. A future runner's per-candidate failure
isolation must be explicitly designed to avoid blind retry loops/starvation.

For v1 low volume, manual maintenance is preferable to a recurring scheduler until
actual demand justifies one. Do not claim manual one-page/day keeps up with full
capacity. At 60 new tickets/workspace/day, six pages/day/workspace are needed just
to match ticket growth, plus backlog and skipped candidates. A scheduler could
offer consistency but adds recurring execution, IAM, index, job failure and cost
obligations. Future approval must specify run frequency, page/candidate cap and
capacity across N workspaces, not merely reuse the library's per-call 10-ID limit.

## Actual logical operation model

Counts below are successful no-retry paths, per module invocation. They exclude
future inventory queries, Auth-account verification, Secret Manager, provider work,
index-entry billing, RPC overhead and any client-side workspace resolution. A
missing-document GET is still an operation; these are source-level counts, not a
verified invoice or necessarily distinct backend RPCs.

| Operation | Owner GETs | Staff GETs | Writes/deletes |
| --- | ---: | ---: | --- |
| issue ticket | 5 | 7 | 2 usage writes + 1 ticket create = 3 |
| fresh admit | 7 | 9 | 2 usage writes + ticket update + receipt create = 4 |
| duplicate admitted/terminal ticket | 5 | 7 | 0; no dispatch permission |
| dispatch | 6 | 8 | ticket + receipt + workspace updates = 3 |
| complete / recoverExpired | 3 | 3 | ticket + receipt + workspace updates = 3 |
| full issue/admit/dispatch/complete | 21 | 27 | 13 writes |
| cleanup old unused ticket | 3 | 3 | 1 delete |
| cleanup old completed/abandoned pair | 3 | 3 | 2 deletes |
| cleanup missing/protected/not-old-enough candidate | usually 2 | usually 2 | 0; matching terminal lock may require a third GET |

Owner authority uses three records; Staff uses five, including Owner pair. Raw
input/Auth rejection can occur before database reads; other denied attempts may
consume partial/all reads without any quota increment. Work not admitted is not
free of compute or read charges. Cancellation, timeout and provider rejection after
admission remain charged. Complete/recovery are trusted worker-only methods and
do not independently authorize a user or return recipe results.

One successful full page: up to 10 discovery document results, 30 transactional
GETs, 20 deletes, 10 transactions. An empty discovery query can still carry query
charges. The installed Firestore SDK defaults to 5 transaction attempts; the
adapter does not override maxAttempts. Nominal worst-case callback GET count is
150 for 10 candidates at five attempts, plus discovery/repeated RPC work. Successful
deletes commit once per candidate, not five times. Transport retries, failed
operations and query/index charges mean this is NOT a hard billable-operation cap.
The test model retries up to 100 conflicts for stress; that is not production SDK
configuration. Future maintenance needs explicit SDK attempt options, an invocation
deadline, finite query/RPC policies and a runner-wide attempt budget.

Cost formula for planning: documentReads*regionalReadPrice + writes*writePrice +
deletes*deletePrice + indexReads + storedBytesTime + compute + artifacts/logging +
secret access + network. No cloud region/database edition, live prices, credits or
usage were fetched. No MYR total or guaranteed free quota is inferred. Groq token
usage/provider billing is separate. RM5 Google Cloud alerts are NOT a hard cap or
a Groq spending limit.

## Storage and retention

Per workspace accepted issuance is at most 60/day and receipts at most 30/day:
up to 90 new ticket/receipt docs/day, excluding two reusable usage-counter roots.
Without cleanup: up to 90*D docs per workspace over D days at sustained maxima,
plus user counters; user creation/workspace count is not globally capped here.
At seven-day retention, approximately 630 ticket/receipt docs/workspace are live
at steady-state maxima, plus ticket five-minute offset, cleanup lag, quarantine,
malformed/orphan records and counters. This is an illustration, not a byte-size or
strict global bound. Daily rollover does not delete counters or reservations.

Quarantined data is intentionally retained indefinitely. At most one lock exists
per workspace under this protocol, but the number of workspaces is not bounded.
Actual storage is bounded only if a sufficiently provisioned maintenance process
runs; retention fields alone cannot achieve it. Incident holds are not implemented.

Do NOT enable TTL directly on retainUntil: independent deletion cannot preserve
active/quarantined pairs or check workspace locks. No TTL required for this direct-
ID cleanup primitive. TTL/new eligibility metadata, index changes and scheduled
maintenance are separate schema/operations reviews. Cleanup read/delete/storage,
Cloud Scheduler, Functions and logs can all add costs; no always-on warm instance
is justified by this audit.

## Quarantine impact and user/operator behavior

No existing exported callable imports ai-quota. Searches of workspace creation,
inventory mutations, stock and menu show no quota-root/quarantine dependency.
Consequently the isolated code changes none of these workflows. A future integration
must scope AI unavailability to suggestions, never gate inventory/menu/session access
on an AI lock. Test this boundary when the callable/client is actually wired.

One uncertain dispatch can block workspace AI indefinitely; expired admitted work
can also block it until trusted recovery is run. No trigger currently performs
either recovery or operator notification. Strict quarantine is safer than claiming
remote work stopped on local timeout. Fences prevent stale database completion,
not continued remote execution. No provider cancellation proof, recovery operator
authorization, one-use command audit or unlock exists.

Future UI: safe 'AI suggestions are unavailable; inventory remains available' state,
no raw provider errors, no misleading promise of automatic recovery. Existing
resource-exhausted covers quota/lock together; a separately reviewed sanitized
reason contract is needed to distinguish quota wait from quarantine support flow.
Use explicit demo labels; never substitute demo results as genuine generation.
Future operator alert should fire once on transition to quarantine, with bounded
sanitized identifiers/status, deduplication and an assigned owner. No alert should
expose keys/prompts or automatically reset a lock. Implementation is absent.

## Security findings and documentation/test mismatches

- PASS locally: active canonical/cafe/member/Owner validation, verified-email Auth
  claim check, legacy paired generation 0, actor/Owner episode pinning, random tickets,
  one-way dispatch, receipt fencing, conservative quarantine and cleanup checks.
- Client writes: four root paths have no grants and fall under local catch-all
  deny. Admin bypasses Rules; every future entry point must supply trusted identity.
  Cloud Rules and runtime authorization were not read or exercised in this audit.
- issue/admit/dispatch accept a trusted Auth object, not an SDK identity check.
  They do not fetch current disabled/revoked/verified Auth state. Existing tokens
  can be stale. Future callable must derive identity from verified callable context
  and perform current-account checks before admission/dispatch/result release.
- No payload hash/model/inventory snapshot or completion result-authority recheck
  exists. The quota module deliberately has no provider payload/result. Bind future
  input to ticket or derive it server-side and recheck membership/inventory before
  releasing results; do not mistake quota success for generation authorization.
- Worker complete/recovery and cleanup have no actor IAM checks inside the library.
  They are unexported trusted primitives. Do not expose them directly. Operator
  recovery tests assert ABSENCE of an unlock API; they do not prove operator IAM,
  evidence validation or audited successful reconciliation exists.
- The named cleanup/admission conflict test injects a synthetic state change; a
  separate parallel test verifies expired admission rejection. Neither demonstrates
  actual Firestore scheduling. Candidate discovery, pagination starvation, native
  attempt limits and cloud execution budgets have no tests or implementation yet.
- Default npm test explicitly lists suites and omits ai-quota.test.js. A future
  local test-discovery patch should include it before integration; no package edit
  is made in this documentation-only phase.
- Phase 1B body still contains historical 'no deletion implementation' wording;
  its Phase 1C supersession notice and Phase 1C document govern current behavior.
  Old design-gate unresolved sections are similarly historical. No source defect
  was silently fixed or older document edited during this audit.
- No key, secret read, provider request, console logging or network operation exists
  in ai-quota.js. This scoped inspection is not a new exhaustive historical secret
  scan; the prior historical Groq credential finding remains a separate containment
  concern. User-reported revocation is not proof all historical tokens are contained.

## Separate next-phase gates

| Action | Decision | Exact prerequisites / scope |
| --- | --- | --- |
| Continue local secure callable development | GO, local-only | Separately approve implementation scope; keep non-deployed/disabled; add current-Auth checks, provider/input/result bounds, ticket-payload semantics, conservative outcome classification and default regression discovery. Resolve unknown commit handling without redispatch. |
| Connect Flutter locally with mocks | GO, mocks only | Approve typed ticket/callable contract and mock injection, active session/late-result guards, safe error/demo states; no production target, credential or direct Groq fallback. No runtime integration implied. |
| Activate Blaze | NO-GO | Explicit billing approval, suitable open billing account/currency, cost acceptance, budget recipients/alerts, project/API/IAM/AUP prerequisite review. No previous account metadata assumed current. |
| Create backend Groq secret | NO-GO | Approved least-privilege secret/runtime identity and secret binding plan; historical-key containment review; valid separately approved backend key handling and spend policy. Secret creation not needed for mocks. |
| Deploy Functions | NO-GO | Separate exact-function deployment approval, Node 22 verification, full callable/resource/security review, billing/API/IAM readiness, bound secret and accepted maintenance/quarantine plan. |
| Enable maintenance automation | NO-GO | Reviewed trusted runner, scoped IAM, candidate query/index, cursor/error/starvation tests, finite retries/pages/deadline/frequency, reporting/alerts and separately approved deployment/billing. |
| Production AI usage | NO-GO | All above plus separately approved bounded authenticated runtime acceptance, Auth/Rules isolation evidence, provider outcome handling, monitoring and explicit acceptance of indefinite AI quarantine; no claimed automatic recovery. |

## Verification executed

From functions: node --test test/ai-quota.test.js test/firestore-rules-contract.test.js
=> 59 passed (54 quota + 5 Rules), zero failures/cancelled/skipped/todo, exit 0.
From root: node --check functions/src/ai-quota.js and
node --check functions/test/ai-quota.test.js => exit 0. git diff --check => exit 0,
existing LF/CRLF warnings only. No full backend/Flutter/browser/production tests
rerun for this documentation-only change. Node 24.15.0 used; deployment targets 22.
Rules raw SHA-256 unchanged:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

DATABASE CHANGE REPORT: proposed schema unchanged from Phase 1B; discovery query/
index are planning only. Production schema, local/production Rules, indexes,
documents and Auth users UNCHANGED. Production reads/writes NONE; deployments NONE.
Billing unchanged. ADD this document only; MODIFY/DELETE none. Existing dirty work
preserved. No Git stage/commit/push or history changes. Manual/runtime testing NOT RUN.
