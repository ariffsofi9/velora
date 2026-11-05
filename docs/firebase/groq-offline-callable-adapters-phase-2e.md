# Phase 2E: offline callable adapters and error contract

2026-11-06, Asia/Kuala_Lumpur. Local implementation + offline tests. No index.js
callable export, initialization/selection of a Firebase app, live invocation,
provider request, key/secret, deployment, billing or production access.

## Verified SDKs and actual file changes

Installed firebase-functions 7.4.0 provides v2/https HttpsError. Flutter lockfile
cloud_functions 6.5.1 and platform interface 6.0.7 provide HttpsCallable.call<T>(),
HttpsCallableResult<T>.data and FirebaseFunctionsException.code/details. The result
constructor is private: tests implement the public result interface and use fake
FirebaseFunctions/HttpsCallable implementations, not an invented {data:...} Map.

ADD:
- functions/src/secure-ai-callable-contract.js: names, finite safe reasons, JSON limit.
- functions/src/secure-ai-callable-adapter.js: isolated callback factory/HttpsError mapping.
- functions/test/secure-ai-callable-adapter.test.js.
- lib/services/firebase_secure_ai_transport.dart: explicitly opt-in SDK adapter.
- test/firebase_secure_ai_transport_test.dart.
- test/fixtures/secure_ai_callable_contract.json: shared deterministic success/error/limit fixtures.
- this document.

MODIFY: isolated handler (safe runtime reasons/final response cap), quota helper
(runtime reasons only), Flutter service/error mapping, suggestions panel copy and
related service/widget tests. No schema fields, collections or new persisted state.
No unrelated business callable, index.js, Firebase config, Rules or Flutter startup
changes. No files deleted; existing dirty work preserved.

## Stable names and exact envelopes

Proposed future v2 callable names, codebase workspace, intended region asia-southeast1:
- issueWorkspaceAiTicket: accepts ONLY the existing issue operation.
- generateWorkspaceAiRecipes: accepts ONLY the existing generate operation.

No onCall registration is performed. createSecureAiCallableAdapters({handler})
returns isolated callbacks with these names, for separately reviewed future wiring.
The handler dependency MUST be the secure authenticated handler with authoritative
account/Firestore dependencies, not a generic unauthenticated function. No default
provider/secret or auth bypass is supplied. Each callback preserves request.auth
from the future verified callable context, and does not take identity from data.
Wrong operation/name pairing rejects without entering the handler.

Public request data is unchanged:
- issue: operation, expectedCafeId, expectedMembershipGeneration, maxRecipes (1-3).
- generate: the same values and server-issued ticketId.

Flutter's typed service always sends normalized maxRecipes, though the domain
handler still supports omission/default=1. The adapter validates its typed outgoing
shape, identifier/number bounds and <=2048 UTF-8 JSON bytes. No role, UID, key,
digest, inventory or client timestamp field is introduced. Existing atomic digest
admission/dispatch checks and quota lifecycle remain authoritative.

Callbacks return the existing raw response DATA object, not {data:...} or
{result:...}. Firebase callable infrastructure owns the HTTP protocol envelope.
Flutter's injected invoker returns HttpsCallableResult and the adapter unwraps .data
exactly once; the typed service then verifies every field and nested recipe.

Success data:
- issue: schemaVersion:2, ticketId (64 hex), expiresAt (positive safe integer).
- generate: schemaVersion:2, provider:groq, ticketId, status ok/no_suggestions,
  recipes, inventorySelection {eligibleCount,usedCount}.

Unknown request fields reject. Unknown response fields reject in the backend adapter
top-level guard and Flutter typed parser; nested recipe/quantity validation remains
in the secure handler and Flutter model. Wrapper DI assumes trusted domain output,
not a new recipe-authority validator. Malformed JSON types/nonfinite numbers and
ill-formed Unicode are rejected by byte guards. No AI result persistence/retrieval.

## Shared response byte contract

Maximum = 65,536 bytes of serialized UTF-8 JSON RESPONSE DATA (the SDK .data object),
not HTTP headers, callable protocol wrapper, error stack, Unicode character count
or raw provider stream alone. JS and Dart tests read the same maxResponseBytes
fixture. Dart normalizes safe integral SDK doubles to integers before JSON byte
measurement; nonfinite values and lone UTF-16 surrogates reject. Ordinary multibyte
and surrogate-pair text is supported. This avoids treating 1.0 metadata as a larger
representation than server integer 1.

Domain handler now caps the FINAL mapped/enveloped data after authority rechecks,
including longer real inventory IDs. The backend adapter independently guards
success data; Flutter guards unwrapped data before parsing. A too-large final
result is withheld as data-loss/invalid-response, without refund or regeneration.
Provider raw 64KiB/validated-content limits remain additional protections, not a
substitute for final envelope measurement. Exact-limit, +1 byte and multibyte tests
use matching deterministic JSON padding; shape validation remains a separate test.
This is a data-budget contract, not proof of actual HTTP transport byte sizes.

## Finite sanitized error mapping

Only actual SecureGroqError/AiQuotaError instances with allowlisted codes may choose
public HttpsError codes. A plain Error with forged code/reason maps to internal.
All messages are fixed 'AI suggestions are unavailable.'; details is ONLY
{reason: reviewedLiteral}. Unknown reasons fall back by code. No raw messages,
stack traces, headers, SDK error bodies, keys or document paths are serialized.

Flutter catches the installed FirebaseFunctionsException, accepts only a matching
allowlisted code/reason pair in a one-field details Map, and discards all other
details/message text. Unknown SDK codes map unavailable. Invoker TimeoutException
maps deadline-exceeded without retry. The service maps typed codes/reasons to UI:

| Firebase code / safe reason | Flutter state / UI intent |
| --- | --- |
| unauthenticated / sign-in-required | signInRequired; sign in again |
| unauthenticated / email-unverified | emailUnverified; verify email |
| unauthenticated / account-disabled | accountDisabled; account AI access unavailable |
| permission-denied / access-denied | denied; reopen workspace |
| aborted / workspace-changed | denied; reopen workspace |
| invalid-argument / invalid-request | invalidRequest; no automatic retry |
| resource-exhausted / quota-exhausted | quota; request limit reached |
| resource-exhausted / workspace-busy | workspaceBusy; busy OR paused, no midnight/unlock promise |
| resource-exhausted / inventory-capacity | inventoryLimit; public 100-record AI input bound |
| failed-precondition / ticket-expired | ticketExpired; no automatic replacement |
| failed-precondition / service-unavailable | unavailable; configuration/binding failure, not guessed expiry |
| already-exists / ticket-replayed | replayed; ticket already used, no retrieval |
| unavailable / service-unavailable | unavailable |
| unavailable / outcome-unknown | outcomeUnknown; no automatic retry |
| deadline-exceeded / provider-timeout | timeout; no automatic retry |
| internal / service-unavailable | unavailable; safe generic failure |
| data-loss / invalid-response | invalidResponse; display no suggestions |

resource-exhausted/invalid-response is also accepted for safe compatibility, though
final size guards emit data-loss. Codes without details use reviewed defaults;
legacy mocks may still exercise code-only mapping. Unknown phase/transport errors
never cause automatic reissue or provider execution. Current quarantine/expiry
classification and daily accounting remain unchanged except for safe reason text.

## Opt-in Flutter wiring and identity

FirebaseSecureAiTransport(invoke:...,enabled:false,isDemo:true) is disabled by
default. Tests explicitly enable it with fake invokers. fromFunctions receives an
existing explicitly selected FirebaseFunctions object; it never obtains a global
instance/project or initializes Firebase. It lazily builds SDK references with a
30-second callable timeout only when explicitly enabled and called. That path is
implemented but NEVER selected in application startup or exercised against Firebase.
Future wiring must verify project/region/auth/App Check, not blindly enable it.

SecureAiService's default remains UnavailableSecureAiTransport. The new adapter is
not imported/selected by main or SuggestionsPage. Existing injected mock UI remains
labelled demo; fromFunctions marks actual adapter mode non-demo. Future enabled
non-demo service copy now says 'AI suggestions from your workspace' rather than
the contradictory unavailable banner. No production state is claimed by this copy.

The service retains exact session-object identity, expected workspace/generation and
maxRecipes across issue/generate. Widget revisions and service checks drop late
responses after workspace change. Duplicate Generate blocking remains. An ambiguous
timeout sends no retry, polling, second ticket or redispatch. A subsequent explicit
user action is a NEW ticket, not recovery/refund of a lost response. Backend remains
authoritative for account status, canonical links, digest/fences, quotas and release.

## Verification commands and results

Backend, from functions:

```powershell
node --test test/ai-quota.test.js test/secure-groq-handler.test.js test/secure-ai-callable-adapter.test.js test/firestore-rules-contract.test.js test/workspace-resource-config.test.js
npm.cmd test
```

Flutter, repository root:

```powershell
flutter.bat test --no-pub test/firebase_secure_ai_transport_test.dart test/secure_ai_service_test.dart test/secure_ai_suggestions_test.dart test/groq_migration_test.dart test/recipe_regression_test.dart test/workspace_session_test.dart test/workspace_inventory_repository_test.dart --reporter expanded
flutter.bat analyze --no-pub lib/services/secure_ai_service.dart lib/services/firebase_secure_ai_transport.dart lib/screens/suggestions/widgets_suggestions/secure_ai_suggestions.dart test/firebase_secure_ai_transport_test.dart test/secure_ai_service_test.dart test/secure_ai_suggestions_test.dart
git diff --check
```

Backend focused: 148 passed, zero failures/skips/cancelled/todo. Default regression:
367 passed, zero failures/skips/cancelled/todo on the final checkout. Flutter final: 96 passed,
zero failures/skips. Suites overlap. Relevant syntax checks pass; final scoped
analysis passed with no issues; diff checks passed with existing LF/CRLF warnings.
All verification commands exited 0. Affected-file credential scan found zero
matches; entrypoint/default-selection checks passed. Rules SHA-256 unchanged:
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.
Tests cover shared
fixtures, real isolated handler output -> wrapper, public SDK-shaped fake envelopes,
all reviewed error reasons, limits/multibyte, unsupported types, auth/revocation,
quota/concurrency, expiry/replay, provider uncertainty and preserved defaults.

No claim of real Firebase HTTP envelope transport, token refresh, SDK network retry
behavior, App Check, native Firestore/Auth atomicity, Groq termination/model
availability or production cost verification. Node 24.15.0 tests, target 22 still
needs a separately approved check. Emulator, live callable/provider, browser/device
and production checks NOT RUN. No full default Flutter suite claimed.

## Change control and remaining gates

DATABASE CHANGE REPORT: proposed/production schema UNCHANGED from Phase 2B; runtime
error reasons and response guards add no persisted fields/collections. Local and
production Rules, indexes, documents, Auth users unchanged. Production reads/writes
NONE; deployments NONE. Firebase config, billing and default transport unchanged.
No secret/key/IAM/API, Git stage/commit/push/history changes. Existing dirty work
preserved. New suites are explicitly run; package.json test discovery unchanged.

GO for review of offline adapters. NO-GO for index.js export, enabling real client
wiring, secret creation, billing or deployment without separate approval. Require
Node22/resource/region/secret/App Check/IAM review, actual provider rejection
semantics, cost/maintenance/quarantine acceptance and bounded authenticated runtime
acceptance before production. No automatic next phase.
