# Week 3 Batch 1 — fake recipe connectivity

This profile is an opt-in test path. Batch 2 enables Generate Recipes only for
the explicit isolated recipe-connectivity emulator profile and verified session.
Default, STAFF_DEMO and other emulator/production modes remain disabled. No live
Groq, legacy transport, cache, quota or save service is activated. There is no
production deployment or migration.

## Isolation and compatibility

Project: `demo-velora-ai-connectivity`. Loopback ports: Auth 49099, Firestore
48080, Functions 45001, UI 44001, websocket 48150, hub 44400, logging 44500,
Eventarc 49299, tasks 49499. The launcher refuses occupied ports rather than
connecting to or stopping another session. No data clear/import/export is used.

The profile loads unchanged workspace callables and a separate fake-only
`suggestRecipes` source. It reuses the AI1 read-only recipe service with an
explicit, separately validated isolation profile. AI1's original guard, project,
ports and default provider selection are unchanged. STAFF_DEMO options/ports
remain unchanged. Simultaneous STAFF_DEMO and recipe-profile flags are rejected.

The fake entry point imports only the fake provider and has no Groq selection,
relay or credential access. Its guard rejects non-fake provider mode and a live
relay setting. The launcher strips secrets/debug flags using the existing safe
environment helper, forces fake mode and rejects environment files in its two
Functions source directories. Existing installed Firebase packages are reused;
no dependencies are added or installed.

## Run from the repository root (Windows PowerShell)

Backend integration, including authentication, Owner/Staff membership,
cross-cafe denial, revoked membership, replay rejection and unchanged inventory:

```powershell
node functions/scripts/run-recipe-connectivity.js test
```

Real Flutter SDK/headless Chrome connectivity test (disposable Owner and Staff
fixtures, then authenticated schema-v1 fake responses):

```powershell
node functions/scripts/run-recipe-connectivity.js test-browser
```

The browser runner uses the installed Flutter SDK at
`%USERPROFILE%\flutter\flutter\bin\flutter.bat` and already-installed Chrome.
Flutter uses `--no-pub`; do not install packages to run this profile. Fixture
accounts/password are intentionally public, disposable test constants in the
test files, never real credentials. No Auth token or invitation code is printed.
The browser test is skipped by default and must run through this fresh launcher.

### Current Windows Chrome blocker

The installed Flutter SDK's `flutter_web_platform.dart` converts request URLs
with the Windows filesystem path context, then checks for the literal prefix
`canvaskit/`. The resulting backslashes fail that check, producing CanvasKit
JS/WASM 404s before the test body. Its bootstrap explicitly sets
`canvasKitBaseUrl: "/canvaskit/"`, overriding the Dart environment URL option.
The matching JS/WASM files already exist in the SDK cache. No SDK files were
changed and no replacement assets were downloaded. Browser connectivity remains
BLOCKED, not PASS. The runner now terminates only its own Flutter process tree
after 120 seconds if bootstrap stalls, allowing normal emulator shutdown.

Recovery attempt (2026-11-05): inspected Flutter 3.41.7 / Dart 3.11.5 and tried
one temporary Chrome launcher with a loopback PAC proxy serving only the cached
CanvasKit files. The single `test-browser` run timed out at 120 seconds before
the test body; zero cached assets reached the proxy. Browser bootstrap and
authenticated Flutter callable execution therefore remain BLOCKED. This does
not establish why Chrome did not use the proxy. The ineffective workaround was
removed, its temporary launcher/server cleaned up, and no SDK files changed.
The disposable emulators shut down normally. Previous backend/client PASS
results were not rerun during this recovery task.

### Test-only compiled Web smoke (2026-11-05)

From `C:\Users\23000\velora`:

```powershell
node functions/scripts/run-recipe-connectivity.js test-web-smoke
```

This separate mode compiles `test/recipe_connectivity_web_smoke.dart` using
`--no-pub --no-web-resources-cdn`, serves the ignored
`build/recipe-connectivity-smoke` output on an ephemeral loopback port, and
launches installed headless Chrome with its own profile in that build folder.
Build timeout is 180 seconds; browser timeout is 90 seconds. Only that Chrome
process tree is stopped; the existing launcher shuts down its own emulators.

The test page preloads Firebase browser modules from the already-installed
`functions/node_modules/firebase` package (12.19.0, matching FlutterFire).
The server rewrites their Firebase app imports to loopback in memory; installed
packages and SDK files are unchanged. Page CSP blocks external connections and
scripts. CanvasKit comes from the Flutter cache; no downloads are required.

The entry point uses real Firebase Auth, workspace resolution and
`FakeRecipeClient`, asserting Owner and Staff identity/role/cafe, fake schema-v1
response, Banana/Milk ingredient IDs and nonempty steps. The fixture runner also
compares disposable inventory before and after successful smoke execution.
Batch 1 changed no application entry point or generation UI. Batch 2 now passes
the verified SuggestionsPage session into the existing recipe widget.

Verification on 2026-11-05: **PASS**. The build completed in 44.0 seconds;
headless Chrome completed real authenticated Owner and Staff callable execution,
and the inventory comparison passed. Both callable requests logged valid Auth.
The script and launcher exited 0; disposable emulators shut down normally.
Node syntax checks for the three affected runners and `git diff --check` passed.
No previous Node/client/backend-integration suite results were rerun or extended.
Manual browser/UI acceptance was NOT RUN. The older `flutter test` Chrome path
remains historically BLOCKED and was not retried.

Build limitations: the JavaScript build succeeds; its Wasm dry run warns that
the test-only `dart:html` entry point does not support Wasm. The emulator used
installed Node 24 although Functions declares Node 22. This smoke establishes
local fake connectivity only, not production security or live provider readiness.

Offline typed-client tests:

```powershell
flutter test --no-pub test/fake_recipe_client_test.dart --dart-define=RECIPE_CONNECTIVITY_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1
node --test functions/test/recipe-connectivity.test.js functions/test/ai1-recipes.test.js functions/test/ai2-groq-provider.test.js
flutter analyze --no-pub
git diff --check
```

For isolated interactive setup only (requires separate disposable fixture setup;
`start` does not seed accounts):

```powershell
node functions/scripts/run-recipe-connectivity.js start
flutter run --no-pub -d chrome --dart-define=RECIPE_CONNECTIVITY_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1
```

## Client and response contract

Construct `FakeRecipeClient(session: verifiedWorkspaceSession)` using the existing
verified workspace routing context. It checks the current identity, membership,
cafe, owner and role before and after the callable. Auth transitions, including
away-and-back, invalidate pending results. Wrong build flags, host or project
fail before dispatch; the Firebase transport explicitly selects the local
Functions host and `asia-southeast1`. It has no production fallback.

Request: `{requestId, maxRecipes}` only. IDs are 16–64 ASCII letters/digits,
underscores/hyphens; recipe count is 1–3. There are no client cafe/actor/role or
inventory authority fields. There is no automatic retry; duplicate request IDs
are rejected by the backend's existing process-local replay protection.

Only `schemaVersion:1`, `provider:fake` responses with matching request IDs are
accepted. Recipes contain title, ingredientItemIds, steps and whyRecommended.
No quantities or units are invented or represented in the v1 type. Empty
`no_suggestions` responses remain empty; schema v2/live results are rejected.
Ingredient IDs are validated against authorized inventory by the backend.

## Database, security and limits

Recipe calls read the existing canonical mapping, cafe/member/owner links and
scoped inventory. Archived, expired and zero-stock records are excluded; the
service rechecks identity, authorization and inventory before returning. No
inventory, menu, membership, cache, quota or saved-recipe writes occur during a
recipe request. Test setup creates only disposable Auth/membership/inventory
fixtures. Existing workspace records require no changes.

The fake provider produces its explicit Banana/Milk fixture only when those
eligible ingredients exist. This proves connectivity, not AI quality or live
Groq readiness. Replay/capacity limits remain process-local. Browser SDK loading
may require access to the public Firebase SDK CDN, but this profile cannot call
an external AI provider. Only the Batch 2 isolated fake UI described below is
enabled; no live AI business workflow is approved here.

GITHUB STATUS: local changes only; no commit/push/deployment.
DATABASE CHANGE REPORT: no schema migration or production/STAFF_DEMO data changes;
only disposable test fixtures and read-only recipe requests.
MANUAL TESTING: manual UI acceptance has not been performed.

## Week 3 Batch 2 — guarded fake UI

The existing Generate Recipes button uses `FakeRecipeClient` only when
RECIPE_CONNECTIVITY_DEMO and USE_FIREBASE_EMULATORS are true, STAFF_DEMO is false,
the host is exactly 127.0.0.1, the Firebase project is exactly
demo-velora-ai-connectivity, and the current identity matches the supplied
workspace session. These UI checks are conveniences, not authority: the client
resolves membership before and after each request and the callable independently
authorizes Auth and canonical membership/inventory. No role/cafe overrides are
sent to the callable.

The UI provides loading (duplicate submit disabled), fake results, empty results,
safe errors and explicit retry with a fresh request ID. Auth changes clear results
and invalidate the current request, including away-and-back. Widget session
replacement/disposal invalidates pending UI completions. Changed or revoked
membership/cafe/role is rejected by the client's response-time resolution; no
continuous membership listener or polling is introduced. There is a 40-second UI
timeout and no automatic retry.

Fake cards open the existing read-only presentation details route. Ingredient
IDs are labelled as IDs; quantities and units are explicitly unavailable.
Instructions and explanation are copied only from the validated fake response.
The sample preview stays separately labelled. Cook Now, Save Recipe and AI
Restock are unavailable. No legacy generation, persistence or quota/cache method
is invoked by this workflow.

Focused local tests, from the repository root (use the installed Flutter path if
`flutter` is not on PATH):

```powershell
flutter test --no-pub test/fake_recipe_ui_test.dart test/fake_recipe_client_test.dart test/recipe_suggestions_presentation_test.dart test/recipe_regression_test.dart test/recipe_ui_test.dart test/cook_now_containment_test.dart --dart-define=RECIPE_CONNECTIVITY_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --reporter expanded
node functions/scripts/run-recipe-connectivity.js test-web-smoke
```

The Web smoke now mounts the real RecipeSuggestionsContent widget for each role,
invokes its enabled Generate button callback, waits for the real fake result
card, invokes its details callback, and checks honest schema-v1 presentation.
This is widget-callback-driven automation, not manual mouse/keyboard acceptance.
The existing build/browser bounds, local-only assets and fixture inventory
comparison are retained.

Batch 2 DATABASE CHANGE REPORT: no schema/backend migration or application
writes; browser setup creates only the existing disposable fixture records.
No production or STAFF_DEMO data access is authorized.

Batch 2 GITHUB STATUS: local work only; no commit, push, branch or deployment.

### Batch 2 verification — 2026-11-05

- PASS: focused six-file Flutter suite, 120 passed, 0 failed, 0 skipped.
  Includes 16 new UI cases, 20 existing client cases and 84 regression cases.
  Conditional negative-profile assertions run in the separate matrix below.
- PASS: default, STAFF_DEMO, generic-emulator-without-recipe-profile,
  conflicting STAFF_DEMO/recipe flags, and wrong-host offline test runs.
  Each run: 7 passed, 29 intentionally skipped, 0 failed.
- PASS: focused analysis of the five changed Dart files, no issues found.
- PASS: one bounded compiled Web UI smoke for Owner and Staff; 37.5-second
  JavaScript build, valid Auth logged for both recipe calls, honest details
  assertions and unchanged fixture inventory. Script/launcher exit 0, normal
  emulator shutdown. Existing 180-second build and 90-second browser limits apply.
- PASS: `git diff --check`.
- NOT RUN: manual browser acceptance, full Flutter/backend/Rules suites,
  production checks, live provider calls and the historically blocked
  `flutter test --platform chrome` path.

Initial new widget tests failed because stream-cancellation completion needed a
real microtask turn in the offline harness and details needed scrolling into
view. Both were corrected before the passing suite; no unresolved test failure
remains. The first sandboxed Flutter invocation stalled before tests and was
stopped; successful verification used the installed SDK outside that restriction.
The browser still reports the known test-only dart:html Wasm dry-run warning;
JavaScript succeeds. Installed Node 24 differs from declared Node 22.

MANUAL TESTING: NOT RUN. Manual acceptance should cover Owner and Staff Generate,
fake labels/ingredient IDs and supplied instructions, loading/empty/error/retry,
sign-out during a request, disabled default/STAFF_DEMO profiles, and mobile
scrolling. Automated widget checks cover 320px at doubled text; browser smoke
uses widget callbacks rather than pointer input or a full login/navigation tour.
