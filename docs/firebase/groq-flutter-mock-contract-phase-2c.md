# Phase 2C: Flutter secure AI contract, mock-only

2026-11-06. Local implementation; no backend edits, real callable/provider request,
credential, emulator, Firebase initialization or production operation in tests.

## Contract gate and changed files

Backend source verified: functions/src/secure-groq-handler.js and Phase 2B contract.
No deployed callable name exists; none is invented. SecureAiTransport.call(data)
defines the future adapter interface without implementing Firebase Functions.

Added lib/services/secure_ai_service.dart (typed requests/results, exceptions,
transport/service), secure_ai_suggestions.dart in the existing suggestions widgets
directory, two focused test files and this document. Modified suggestions_page.dart
to accept optional injected aiService and render the new panel when supplied.
Existing default sample/fake-profile paths are preserved; no emulator profile enabled.
Modified lib/logic/groq_service.dart to a disabled compatibility shim. It accepts no
key/client and contains no HTTP endpoint or network path. Legacy unused callers
receive a fixed unavailable result, never direct provider fallback.

Related groq_migration_test.dart and recipe_regression_test.dart retain parser,
formatter, skipped-history, empty-state and local inventory/restock checks. Obsolete
client-provider HTTP tests were removed/replaced with the disabled-path assertion
and new typed-boundary tests, rather than retaining a hidden test-only HTTP route.
Backend provider security tests remain unchanged from Phase 2B.

## Exact two-stage request

SecureAiRequest captures expectedCafeId and expectedMembershipGeneration from an
existing active WorkspaceSession plus maxRecipes (integer 1-3, default 1).
- issue: operation:'issue', expectedCafeId, expectedMembershipGeneration, maxRecipes.
- generate: identical values plus operation:'generate' and the returned ticketId.

No UID, Owner, role label, inventory, model, API key, payloadDigest, counters or
client timestamps are sent. The server computes the canonical digest. The client
cannot grant authority: backend canonical membership/current-account checks remain
mandatory. A session is routing context, never an authorization token.

Issue response is exactly schemaVersion:2, 64-hex ticketId and positive safe-integer
expiresAt. Client clock does not authorize ticket validity; server checks expiry.
Generate response is exactly schemaVersion:2, provider:'groq', matching ticketId,
status ok/no_suggestions, recipes and inventorySelection eligibleCount/usedCount.
Typed parsing bounds JSON size, counts, string lengths, IDs, duplicate ingredients,
positive finite quantities, pcs integers, units, steps and status/emptiness. It
rejects extra response metadata and obvious secret-shaped text. Client cannot verify
stock/expiry/authorization from this response alone; backend remains responsible.

Models: SecureAiRequest, SecureAiResult, SecureAiRecipe, SecureAiIngredient.
No secret is embedded or accepted by the service. Firebase client configuration
and unrelated HTTP integrations were not changed.

## Safe mock/unavailable separation

Default UnavailableSecureAiTransport has no connection implementation and never
invokes a plugin. MockSecureAiTransport only calls the supplied local responder,
declares isDemo:true, and passes immutable request maps. There is no real Firebase
or Groq adapter in this phase. Trusted test/demo dependency injection is required;
there is no production fallback or automatic demo/live selection.

SuggestionsPage's optional aiService selects SecureAiSuggestions within the existing
layout, leaving Inventory Insights/navigation/repository behavior intact. Without
injection, the existing unavailable/sample paths remain. Mock results always display
'Mock demo only' and 'Demo suggestions — sample data'; provider:'groq' in the mocked
wire payload does not turn the result into live AI. No launch/route configuration
was changed to enable a new mode. Widget tests demonstrate injection locally.

## Request lifecycle and UI states

Require an active verified-session context. Capture the exact session object; after
every awaited stage require that same object remains current and active. Even a new
session with equal fields rejects the old result. UI revision guards discard late
results on widget/service/session replacement or disposal. Existing session boundary
remains responsible for server-driven revocation/navigation; no new live listeners.

One service request at a time and disabled Generate while loading prevent duplicate
ticket issuance from taps. Each stage has a 30-second client deadline; no automatic
retry, polling, result retrieval or background regeneration. Timing out does not
prove backend/provider termination. A late ticket never triggers generate; a late
generation result is discarded. Another explicit Generate tap starts a NEW ticket,
not an unchanged retry; previous work may remain charged/quarantined. No refund or
recovery promise. Default unavailable transport never starts either stage.

UI: loading indicator; typed mock success; empty state; quota reached; unavailable;
timeout with no-retry notice; invalid response and workspace-change messages.
Backend details/exception text never render. transport exceptions use typed safe
codes; the future adapter must map SDK errors without copying raw messages.
resource-exhausted currently conflates quota and workspace lock at the backend;
client therefore says 'request limit reached', never promises midnight recovery or
quarantine unlock. Inventory remains independent.

## Offline verification

Commands from C:\Users\23000\velora, installed SDK via
C:\Users\23000\flutter\flutter\bin\flutter.bat:

```powershell
flutter.bat test --no-pub test/secure_ai_service_test.dart test/secure_ai_suggestions_test.dart --reporter expanded
flutter.bat test --no-pub test/secure_ai_service_test.dart test/secure_ai_suggestions_test.dart test/groq_migration_test.dart test/recipe_regression_test.dart test/recipe_suggestions_presentation_test.dart test/recipe_ui_test.dart test/fake_recipe_ui_test.dart test/groq_recipe_response_test.dart test/workspace_session_test.dart test/workspace_inventory_repository_test.dart --reporter expanded
flutter.bat analyze --no-pub lib/services/secure_ai_service.dart lib/screens/suggestions/widgets_suggestions/secure_ai_suggestions.dart lib/screens/suggestions/suggestions_page.dart lib/logic/groq_service.dart test/secure_ai_service_test.dart test/secure_ai_suggestions_test.dart test/groq_migration_test.dart test/recipe_regression_test.dart
git diff --check
```

Focused final run: 37 passed, zero failed/skipped, including SuggestionsPage injection
with fake inventory and no Firebase initialization. Prior broader run in this batch:
162 passed, 14 skipped, zero failed, before adding the final root-page wiring test.
Those skips are existing profile-gated fake-emulator UI tests; profile remains off.
Suites overlap. Scoped analysis passed after addressing style lints; no full-project
analysis or full default Flutter suite claimed. No browser/device execution.
Widget layout checks: 320/1280 widths with doubled text; these are not Chrome or
Android device measurements. Existing recipe presentation regressions also passed.

Source scan: no direct Groq hostname or GROQ_API_KEY reference in lib/web/Android
source files. Affected-file credential-pattern scan and diff checks performed without
printing values. No new exhaustive history scan; prior historical token exposure
and user-reported revocation remain separate concerns.

## Change control and next gate

DATABASE CHANGE REPORT: schema, Rules, indexes, documents, Auth users unchanged.
Production reads/writes and deployments NONE. Backend quota/handler/export and
Firebase configuration unchanged. No billing, secrets, keys, IAM, emulator, Git
stage/commit/push or history rewrite. Existing uncommitted work preserved.

GO for review of this mock-only contract. NO-GO for real adapter/Flutter cloud
wiring, secrets, billing or deployment. Later approval must establish callable name,
export/resource/secret/App Check policy, provider and maintenance readiness, real
Auth/Rules isolation and bounded runtime acceptance. STOP after local verification.
