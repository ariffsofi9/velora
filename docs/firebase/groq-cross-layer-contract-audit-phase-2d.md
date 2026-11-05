# Phase 2D: Flutter/backend Groq contract audit

2026-11-06, Asia/Kuala_Lumpur. Read-only local source review and this document only.
No application edits, callable export, SDK invocation against cloud, provider call,
emulator, credentials or deployment. Production status in earlier documents is
prior/user-reported evidence, not refreshed here. main HEAD eeca574; existing dirty
work preserved. This is readiness analysis, not production certification.

## Evidence key

Paths/line numbers refer to this checkout:
- H = functions/src/secure-groq-handler.js:19 request parser, :31 digest,
  :62 current-account checks, :73 authorized snapshot, :153 lifecycle,
  :171 dispatch ambiguity, :186 completion/release, :191 response.
- Q = functions/src/ai-quota.js:24 authority, :115 digest check, :121 issue,
  :145 admit, :184 dispatch binding, :213 cleanup, :250 authorized inspection.
- F = lib/services/secure_ai_service.dart:60 typed request, :80 exact map parser,
  :157 result parsing, :271 session check, :280 generation, :322 error mapping.
- W = lib/screens/suggestions/widgets_suggestions/secure_ai_suggestions.dart:43
  request/revision guard, :66 messages, :83 context/availability, :98 banner.
- P = lib/screens/suggestions/suggestions_page.dart:222 optional service wiring.

Reviewed Phase 2B/2C/1D docs, handler/quota tests, Auth/session/resolver code,
index.js, firebase.json, package.json and Rules B. Documentation historical counts
are not substituted for this audit's actual verification.

## Field-by-field request matrix

| Field | Backend requirement | Flutter emission | Assessment |
| --- | --- | --- | --- |
| operation | issue or generate, exact allowed fields (H:19-30) | explicit issue then generate (F:67-77) | Match |
| expectedCafeId | validated existing ID; compared to trusted canonical workspace | active session cafeId | Match; client value is precondition, not authority |
| expectedMembershipGeneration | nonnegative JS safe integer, compared transactionally | safe integer session generation | Match, including valid legacy generation 0 |
| maxRecipes | integer 1-3; absent defaults 1; null rejects | always explicit integer, default 1 | Match; avoids default ambiguity |
| ticketId | only generate; valid server ticket, pinned to UID/cafe/actor+Owner episode | returned 64-hex ticket, exact same options | Match |
| payloadDigest | client field rejected; server SHA-256 of ordered schemaVersion:2/modelVersion:1/maxRecipes | never sent or computed | Match; digest comparison is server-side |
| request schemaVersion / modelVersion | not public request fields | not sent | Match; these version the internal digest, not client negotiation |
| UID, Owner, role, quota, key, model, inventory | forbidden extra data | none sent | Match |
| inventory snapshot/revision | no public request field; derive at execution, compare after provider | none sent | Match; no inventory-at-ticket-issuance promise |
| body size | <=2048 UTF-8 JSON bytes | bounded context and fields; no bulk inventory | Normal generated request fits; backend remains size authority |

No endpoint/callable name is specified or implemented. Future adapter must receive
an explicitly reviewed callable reference/name; do not infer one from the library
factory name. Future server wrapper must unwrap verified request.auth/data, not
trust a caller-supplied auth object embedded in data.

## Field-by-field response matrix

| Field | Backend output | Flutter requirement | Assessment |
| --- | --- | --- | --- |
| issue schemaVersion | 2 | 2 | Match |
| issue ticketId | fresh 64-hex random ID | string length 64 + hex | Match |
| issue expiresAt | positive safe-integer backend epoch milliseconds | positive safe integer | Match; client does not authorize with its clock |
| generate schemaVersion/provider | 2 / groq | 2 / groq | Match; mock flag is local transport metadata |
| ticketId | request ticketId | exact issued ID | Match |
| status | ok when recipes nonempty; no_suggestions otherwise | same status/emptiness relation | Match |
| recipes | bounded array <=maxRecipes | same | Match |
| title/whyRecommended | validated strings <=100/300 chars | same limits | Match for ordinary accepted text |
| ingredients | 1-10, unique authorized item IDs, quantity >0 <=1e6/stock, supported units; whole pcs | same shape/count/finite quantity/unit/whole pcs | Shape match; client cannot prove stock/authorization |
| steps | 1-8 bounded strings <=300 | same | Match |
| inventorySelection | eligibleCount <=100, usedCount <=20, selected first 20 eligible | bounded integer counts, used <=eligible | Match |
| prompts/results in receipt | no persisted recipe payload | no retrieval operation | Match |
| raw metadata/error bodies | not returned | extra result fields rejected | Match/fail closed |

Future Firebase client adapter must unwrap HttpsCallableResult.data before parsing,
not pass the SDK result object. Tests currently use direct maps, not SDK envelopes.
Wire error responses are not result maps: the adapter must throw typed
SecureAiTransportException with a reviewed code and discard raw SDK/provider text.

Boundary discrepancy (fail-closed, not an authorization bypass): Flutter caps the
whole serialized result at 65536 bytes (F:314), whereas H bounds raw provider bytes
and validated recipe character length before mapping aliases to longer real IDs.
There is no final backend envelope byte check. A near-boundary valid provider result
can grow during ID mapping/enveloping and be rejected by Flutter. Agree a final UTF-8
envelope budget and shared boundary fixtures before live integration. This phase
does not change limits. No shared cross-language fixture/bridge currently proves
edge compatibility; tests validate independently authored maps.

## Exact lifecycle and authority analysis

START: Flutter captures current active session and blocks duplicate Generate.
AUTH: future wrapper must provide Firebase-verified callable context. H requires
email_verified and auth_time, then authoritative injected getAccount UID equality,
disabled:false, emailVerified:true and tokensValidAfterTime check.
WORKSPACE/TICKET: issue transaction validates active canonical/self/cafe/Owner links,
roles/schema and actor/Owner generations, checks issuance budget, creates bound ticket.
ADMISSION: generate repeats account check; missing secret fails before admission;
ticket binding and current authority precede atomic 10/user +30/workspace daily charge
and workspace reservation. Duplicate same payload returns no dispatch capability;
changed payload fails even before duplicate state is returned.
DISPATCH: read authorized inventory snapshot (<=101 result query, reject >100),
select <=20 eligible items, repeat account lookup and transactionally check binding/
authority/fence. Confirm first dispatch before transport. No provider inside retries.
GROQ: bounded injected transport once; no default live fetch or retries.
AUTH RECHECK/RESULT: known valid response completes quota first, then checks current
account and transactionally re-reads pinned authority + normalized inventory. Any
change withholds result without refund. Fresh-only response then reaches Flutter,
which checks the SAME still-active session object after each stage and applies
strict parsing. W revision/dispose guards drop old page/service/session results.

Important limits:
- Verified callable Auth and authoritative getAccount are trusted dependencies,
  not implemented cloud authentication by this standalone JavaScript library.
- Auth and Firestore cannot form one atomic cross-service release check; subsequent
  revocation can race delivery. Already-delivered results cannot be remotely erased.
- No version/role label from Flutter grants authorization. Owner episode is pinned
  in the ticket even though no client Owner-generation field is required.
- Snapshot comparison covers normalized ID/name/category/stock/unit/expiry-day/
  lifecycle/version, not every stored inventory field. It is execution-time input,
  not a reservation or stock mutation; no cooking/quantity guarantee is introduced.
- Timing out the Flutter Future does not cancel backend work. Late issue response
  never causes generate. A late generation response is discarded. No silent retry.
- An explicit later Generate creates a NEW ticket/charge opportunity; it is not
  response recovery. Existing ticket replay neither refunds nor returns results.
- Ambiguous dispatch acknowledgement never triggers provider work/retry; an unknown
  completion attempt may leave admitted/dispatched state for trusted recovery.
- Unknown/timeout outcomes retain quarantine. Expiry alone cannot prove remote
  termination. No unlock/operator evidence implementation exists.
- No existing inventory/stock/menu/workspace callable imports these modules; only
  injected AI panel changes, preserving non-AI workflows. Real integration tests
  must reconfirm this boundary later.

## Complete backend -> Flutter -> UI error mapping

Mappings below assume the NOT-YET-IMPLEMENTED server/client adapters preserve codes.
H throws SecureGroqError (plain Error subclass), not Firebase HttpsError. Exporting
it directly would not establish this wire mapping; unknown callable errors may
collapse to internal. A reviewed server wrapper must map only an allowlisted domain
code to HttpsError with fixed text; no raw error text/details.

| Situation | Actual backend domain code/path | Flutter typed failure | Current UI |
| --- | --- | --- | --- |
| Missing Auth | unauthenticated, H:62 | denied | Workspace access changed |
| Email unverified (claim/current account) | unauthenticated, H:64/67; initial account gate precedes quota | denied | Workspace access changed; no distinct verify-email action |
| Disabled/invalid/revoked current account | unauthenticated | denied | Workspace access changed |
| Missing/inactive/inconsistent membership | permission-denied from quota | denied | Workspace access changed |
| Expected workspace/generation mismatch | aborted; ticket episode mismatch may permission-denied | denied | Workspace access changed |
| Stale authority during dispatch | H:171 catch converts dispatch failure to unavailable | unavailable | AI unavailable; may retain admitted reservation |
| Invalid request/extra fields | invalid-argument | unavailable (default branch F:322) | AI unavailable, no validation-specific state |
| Daily user/workspace quota | resource-exhausted | quota | Request limit reached; inventory available |
| Active/quarantined workspace lock | resource-exhausted | quota | Same message; no promised midnight reset |
| Inventory >100 records | resource-exhausted (H:37) | quota | Same message, semantically imprecise for inventory capacity |
| Expired/missing/unbound/digest-conflicting ticket | failed-precondition | unavailable | AI unavailable |
| Same-payload admitted/terminal replay | already-exists | unavailable | AI unavailable; no stored-result retrieval |
| Provider 429 | resource-exhausted | quota | Request limit reached; no provider detail |
| Provider unavailable/malformed/5xx/network | unavailable | unavailable | AI unavailable |
| Provider timeout / local client timeout | deadline-exceeded / TimeoutException | timeout | No automatic retry notice |
| Unknown dispatch/remote outcome | unavailable, or deadline-exceeded for timeout | unavailable/timeout | Safe generic message; cannot distinguish quarantine |
| Generic internal SDK/transport error | H unknown maps unavailable; future wrapper internal maps default | unavailable if adapter throws typed code | AI unavailable |
| Raw unmapped client exception or malformed result | client catch/validation | invalidResponse | Invalid response, no suggestions shown |
| Session switched/invalidated while awaiting | client workspaceChanged | workspaceChanged | Reopen suggestions; late result discarded |

These are safe but lossy UX mappings, not evidence the failures have identical
recovery actions. Do not show 'quota resets at midnight' or encourage blind retries.
Decide whether adapter-specific typed reasons are needed; any new public reason
contract requires review. No secret/provider message should fill that gap.

Another future UI mismatch: W:98 selects an 'unavailable until integration approved'
banner for any non-demo transport, even if a future real adapter reports available.
Today all supplied available transports are mocks, so no active live contradiction.
Approve suitable production-mode copy before real adapter activation. Samples and
mock results remain explicitly labelled in current code.

## Resources, costs and operational prerequisites

firebase.json uses workspace codebase/source functions. index.js has no Groq handler
import/export/defineSecret binding. Existing createWorkspace 256MiB/CPU1/30s/min0/
max1/concurrency1 settings do NOT apply automatically to this unexported handler.
A future v2 wrapper needs separately approved region asia-southeast1, the same
proposed low-scale settings, exact name, secret declaration/binding and IAM/CORS/
App Check/error policy. Do not broaden deploy scope. Node target is 22; local tests
use Node 24.15.0, so Node 22 execution still requires verification.

Auth lookups per full successful issue+generate: four (issue entry, generate entry,
pre-dispatch and post-provider), separate from Firestore. Quota-only lifecycle still
costs 21 Owner /27 Staff logical document GETs and 13 committed writes, without
retries. Full handler adds TWO authority+ticket+inventory snapshots: for N returned
inventory docs per snapshot, total approximately 29+2N Owner or 39+2N Staff logical
GET/results and the same 13 writes. For N=100: 229/239 reads, excluding query minimums,
index billing, retries, secret access and any future client resolver. Empty queries
can still incur query charges. Rejected requests can incur Auth/partial reads even
without admitted quota. These are source-level operation estimates, not an invoice.

Reuse Phase 1D bounded root-query candidate plan (state/retainUntil cursor, <=10 IDs),
but query/index, principal, retries/pages/deadline/frequency and skip/starvation
handling remain unimplemented. 60 tickets/workspace/day needs capacity beyond one
10-ID daily batch. SDK adapter still uses default transaction attempt policy, no
runner-wide cost cap. No TTL on current retainUntil fields: preserve active/unknown
pairs and locks. Quarantine alerts, support owner and indefinite-lock acceptance
are prerequisites; operator unlock cannot be invented without remote evidence.

No price, exchange rate, account currency/current billing state or cloud metadata
fetched. Firebase compute/build/artifact/logging/Firestore/secret costs and separate
Groq token charges need review. RM5 alerts are NOT a hard cap or provider spend limit.

No App Check client initialization or explicit enforcement was found in reviewed
entrypoints/dependencies. Do not enable enforcement before Android/Web registration,
attestation providers, debug-token handling, metric observation and compatibility
approval. Android com.example.velora currently release-signs with debug config;
actual signing certificates and restriction compatibility need separate review.
Web origins/localhost ports must come from actual deployment/dev setup, not guesses.
Keep explicit cloud startup selection and existing session guards. No request/key
restriction or Firebase configuration changed here.

## Separate GO / NO-GO decisions

| Action | Decision | Prerequisites / allowed scope |
| --- | --- | --- |
| Local callable adapter implementation without invocation | CONDITIONAL GO, next approved local batch only | Agree exact callable reference/name, server HttpsError wrapper and client .data/code mapping; add injected SDK-envelope fixtures with no default network, reconcile final envelope-size budget and live-mode copy. Current audit does not implement it. |
| Flutter mock contract testing | GO, offline | Existing injection stays explicitly mock; add shared handler-produced cross-layer fixtures and boundary/error-wrapper tests before treating adapter compatibility as established. |
| Secret creation | NO-GO | Separate approval, historical-key containment review, scoped Secret Manager/runtime identity, secret binding/rotation plan and provider spend policy. Not needed for mocks. |
| Blaze activation | NO-GO | Explicit account/link approval, suitable open account/current currency, project/API/IAM/AUP prerequisites, accepted spend risk and budget recipients; earlier billing/account evidence may be stale. |
| Functions deployment | NO-GO | Approved exact export/name/wrapper, resource/region/secret policy, Node22 checks, billing/API/IAM readiness, accepted envelope/error contract, maintenance/quarantine plan and separate narrow deployment approval. |
| Production Groq usage | NO-GO | All above plus reviewed live client adapter, authenticated isolation/runtime acceptance, actual provider outcome/bounds evidence, App Check rollout decision, monitoring/support and indefinite-quarantine acceptance. |

## Verification executed

Backend (functions directory):
node --test test/ai-quota.test.js test/secure-groq-handler.test.js
test/firestore-rules-contract.test.js test/workspace-resource-config.test.js
=> 120 passed, zero failed/cancelled/skipped/todo, exit 0.

Flutter (repository root, existing Flutter SDK):
flutter.bat test --no-pub test/secure_ai_service_test.dart
test/secure_ai_suggestions_test.dart --reporter expanded
=> 37 passed, zero failed/skipped, exit 0.

node --check functions/src/ai-quota.js and functions/src/secure-groq-handler.js:
PASS. git diff --check: PASS, existing LF/CRLF warnings only. Source searches confirm
no new index.js AI export or real Flutter transport. Full regression, full analysis,
browser/device, native Firestore/provider/Auth/cloud and emulator NOT RUN this batch.
Mocks do not prove real Firebase wire error behavior or production atomicity.
Rules raw SHA-256 unchanged:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

DATABASE CHANGE REPORT: proposed local schema unchanged (payloadDigest ticket field
from Phase 2B only). Production schema, local/production Rules, indexes, documents
and Auth users UNCHANGED. Production reads/writes NONE; deployments NONE; billing
unchanged. ADD this audit only, MODIFY/DELETE none. No Git stage/commit/push/history
changes. STOP after audit; no automatic adapter, secret or production phase.
