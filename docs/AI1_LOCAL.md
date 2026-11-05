# AI-1: disposable recipe callable foundation

Local only. Fake mode remains the default. AI-2 adds an explicit local Groq opt-in
(described below), without production deployment, Flutter generation, stock
mutation, saved recipes, cache or quota storage. Never deploy this codebase.

## Start / test (Windows PowerShell 5.1)

From `C:\Users\23000\velora`, with the existing Node, Java, Firebase CLI and
`functions/node_modules` dependencies already installed:

```powershell
node .\functions\ai1\run-emulators.js test
```

This starts a fresh `demo-velora-ai1` Auth/Firestore/Functions process, runs the
integration test, and shuts down only those processes. Tests create disposable
identities/membership/inventory fixtures. They never clear, delete, reset, import
or export data. Data is not persisted after shutdown. Never point this test at
the working emulator. The launcher refuses occupied ports and does not install
dependencies. It strips API keys, credential environment variables and debug
settings from the child environment. Do not bypass the launcher with `--debug`.

To leave the isolated environment running:

```powershell
node .\functions\ai1\run-emulators.js start
```

Ports (all loopback): Auth 19099, Firestore 19080, Firestore WebSocket 19150,
Functions 15001, UI 14001, hub 14400, logging 14500, Eventarc 19299, Tasks 19499.
No existing emulator configuration is changed. Existing rules/indexes are
referenced read-only; Admin reads still require explicit backend authorization.
The separate source loads only `suggestRecipes`, not inventory mutation callables.

Unit checks, no emulator or network:

```powershell
node --test .\functions\test\ai1-recipes.test.js
```

Existing backend regression: `npm.cmd test` from `functions`.

## Contract and invocation

Endpoint:
`http://127.0.0.1:15001/demo-velora-ai1/asia-southeast1/suggestRecipes`

Send a Firebase callable POST envelope with a disposable **demo Auth emulator**
ID token in `Authorization: Bearer ...`. No real credentials or API key are
needed. Do not print tokens. The integration test demonstrates disposable sign-up,
fixture creation and invocation without logging tokens. Flutter is not connected.

```json
{"data":{"requestId":"unique-local-request-0001","maxRecipes":1}}
```

Only these fields are accepted. `requestId`: 16-64 ASCII letters/digits/underscore/
hyphen; `maxRecipes`: optional integer 1-3. Authority, inventory and free-form
prompt fields are rejected. UID comes from the verified demo token, cafe/owner
from active schema-valid membership/owner links. Disabled/deleted demo identities
fail closed. Owner and staff use the same authorization chain.

Successful callable `result`:

```json
{
  "schemaVersion":1,
  "requestId":"unique-local-request-0001",
  "provider":"fake",
  "status":"ok",
  "recipes":[{
    "title":"Banana Milk Smoothie",
    "ingredientItemIds":["banana","milk"],
    "steps":["Peel the banana.","Blend the banana with milk.","Serve immediately."],
    "whyRecommended":"AI-1 test fixture using available banana and milk; not AI-generated."
  }]
}
```

The fixture is returned only for usable items named Banana and Milk. Otherwise
the fake returns an empty list, `status: no_suggestions`. Errors never synthesize
recipes. Recipe ingredient IDs must belong to the authorized usable snapshot.
Responses are bounded to requested recipe count (max 3), 10 ingredient IDs,
8 steps of 300 characters, title 100 and explanation 300 characters per recipe.

Inventory is read transactionally after authorization, maximum 100 records
(101st record rejects the request instead of silently truncating). Malformed
records fail closed. Archived/expired/zero-stock items never reach the provider.
Missing legacy lifecycle/unit/version fields retain the repository defaults;
explicit invalid values fail. Expiry uses canonical UTC date components and
today in Asia/Kuala_Lumpur. Provider receives no auth token, UID or cafe ID.

Provider runs outside transactions. Identity, authorization and usable inventory
are rechecked before return; changed context/snapshot rejects the result. No
service transaction exposes write methods. Fixtures are the only database writes,
and only in the disposable integration test environment.

## Limits

Runtime rejects missing/wrong emulator hosts, project and emulator marker before
Admin initialization. Production `firebase.json` and `functions/src/index.js` do
not reference this codebase. The launcher does not persist/import/export emulator
data and cannot be used for deployment. It depends on the installed Windows CLI
location; no new dependencies are added. Runtime declares Node 22; this machine
may emulate using its installed Node 24 (reported by the CLI).

Emulator Auth tokens are unsigned development tokens, not production-grade
authentication. Loopback and CORS reduce accidental exposure; local processes
can create/alter demo identities and data. This is not a secure public service.
No real inventory should be placed in this disposable environment.

Replay/in-flight protection is per process: one request per UID at a time,
8 concurrent UIDs, at most 128 remembered request IDs for 5 minutes. Reusing a
request ID is rejected, including changed payloads; failed requests require a new
ID. Restart clears protection. This is not durable quota/idempotency accounting.
Authorization is a point-in-time check; later revocation cannot retract results.

Flutter integration, matching development Firebase configuration and client
session invalidation still require separate approval. Flutter UI, AI cache/quota/
saved recipes and Cook Now remain disabled. AI-2 opt-in is described below.


## AI-2: optional Groq provider (manual smoke test requires separate approval)

`start` and `test` always select fake mode and do not read/pass GROQ_API_KEY.
Automated tests use mocked fetch and synthetic credentials only:

```powershell
node --test .\functions\test\ai2-groq-provider.test.js .\functions\test\ai1-recipes.test.js
```

After separately approving a manual live smoke test, set GROQ_API_KEY in the
PowerShell process using a masked prompt (never put a literal key in history),
then explicitly launch:

```powershell
node .\functions\ai1\run-emulators.js start-groq
```

This command alone starts the environment; a subsequent authenticated callable
request invokes Groq. Missing key, unknown mode, missing relay or incorrect demo
hosts fail closed. No automatic fallback and no automatic retries. The default
`test` command cannot select Groq, even if parent provider/key variables are set.
No live smoke test has been run during AI-2 implementation.

The installed Firebase CLI can log child environment values to firebase-debug.log.
Therefore the key is retained only in launcher memory. It is NEVER passed to
Firebase CLI/Functions environment, command arguments, files or browser. A private
randomly named Windows named pipe relays bounded recipe requests from the callable
worker to the launcher's Groq adapter, returning only validated recipes or fixed
error codes. No TCP relay or browser-accessible relay endpoint is created. The
relay authenticates both peers using fresh client/server nonces and HMAC-SHA256
before transmitting inventory. Requests and responses are authenticated; a
captured request cannot replay on another connection. The launcher generates a
separate ephemeral 256-bit relay secret; it is not the Groq key. Only a Windows
DPAPI CurrentUser-protected envelope (`AI2_RELAY_CREDENTIAL`) enters the child
environment, avoiding plaintext relay secrets in Firebase debug environment
logging. Protection/decryption uses installed PowerShell/.NET with captured
stdio, a minimal environment and an 8-second bound. Missing/corrupt credentials
or protection failures fail closed. No plaintext secret is written to a file or
command argument. Non-Windows platforms fail closed for this launcher path.

A synthetic pipe ACL probe on 2026-11-05 found Everyone/Anonymous read access,
and full access for the current user, SYSTEM and Administrators. Random names
are not authentication. The authenticated protocol does not change that ACL or
prevent local denial of service. DPAPI scopes the credential to the current
Windows user; processes capable of reading that user's memory or decrypting
its envelope remain trusted. Administrator compromise is outside this local
boundary. A separate-user process test was not performed. This is not a public
or production authorization boundary.
Callable membership checks remain mandatory and unchanged. Never expose the demo
emulators or relay to other machines. Closing the launcher closes the relay.

### Batch 3B.1 preparation (2026-11-05)

AI1 now carries the bearer token only in request-local identity context and
calls explicit `verifyIdToken(token, true)` before and after the provider. It
also rechecks disabled state and `tokensValidAfterTime` against `auth_time`.
Failures become a fixed unauthenticated error. No token enters provider input,
the relay or shared cached service state. The installed Admin SDK already
checks revocation in emulator mode; the new explicit checks cover the previously
weaker post-provider recheck as well. Membership/inventory validation is retained.

`lib/models/groq_recipe_response.dart` is a standalone, unwired schema-v2 parser:
exact fields, Groq provenance, matching bounded request ID, 1–3 caller recipe
limit, at most 10 distinct ingredient IDs, valid units, positive finite quantities
up to 1,000,000 and whole pcs; 1–8 bounded steps. Empty no_suggestions stays empty.
Immutable typed lists retain supplied quantities. Stock ownership/availability
remain backend authority. Fake schema-v1 and the fake UI/profile remain unchanged.

Offline verification commands (repository root):

```powershell
node --test functions/test/ai1-request-identity.test.js functions/test/ai2-relay-security.test.js functions/test/ai1-recipes.test.js functions/test/ai2-groq-provider.test.js functions/test/ai2-live-smoke.test.js functions/test/recipe-connectivity.test.js
flutter test --no-pub test/groq_recipe_response_test.dart test/fake_recipe_ui_test.dart test/fake_recipe_client_test.dart test/recipe_suggestions_presentation_test.dart test/recipe_regression_test.dart test/recipe_ui_test.dart test/cook_now_containment_test.dart --dart-define=RECIPE_CONNECTIVITY_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --reporter expanded
flutter analyze --no-pub lib/models/groq_recipe_response.dart test/groq_recipe_response_test.dart
```

These tests use synthetic credentials, mocked providers/in-memory data and
temporary test-owned pipes; none contacts an emulator or external service.
DPAPI tests require the normal current-user Windows security context; the
restricted sandbox denied protection, and the same suite passed outside it.
No live launcher, production access, UI activation or fixture seeding is approved
by this preparation batch.

Batch 3B.1 results: 87 Node tests passed (0 failed/skipped); 160 Flutter tests
passed (0 failed/skipped), including 40 new v2 parser cases and the 120 existing
focused fake/client/presentation/containment cases. Focused analysis reports no
issues, Node syntax checks and `git diff --check` pass. Real emulator token
revocation, cross-user pipe access, browser acceptance and live provider behavior
were NOT RUN; identity tests use offline Auth doubles, and relay tests use real
test-owned Windows pipes plus real CurrentUser DPAPI with synthetic secrets.
DATABASE CHANGE REPORT: no database access/writes/migration or fixture changes.
GITHUB STATUS: local changes only, no commit/push/deployment. MANUAL TESTING:
not performed in this batch; earlier Batch 2 Chrome acceptance is user-reported.

## Batch 3C — AI1 Flutter mock-v2 only

This is a separate opt-in **mock**, not live Groq. Flutter requires
`AI1_MOCK_RECIPES=true`, `USE_FIREBASE_EMULATORS=true` and
`FIREBASE_EMULATOR_HOST=127.0.0.1`. It selects demo-velora-ai1 and Auth 19099,
Firestore 19080, Functions 15001. STAFF_DEMO and RECIPE_CONNECTIVITY_DEMO are
mutually exclusive with it. Invalid combinations/hosts fail before connection;
the v1 client is also disabled when AI1 mock is selected.

`firebase.ai1-mock-emulator.json` loads the existing workspace callables unchanged
and a dedicated `functions/ai1-mock` codebase. The original AI1 config/entry point,
production config, Rules and workspace authorization are unchanged. The dedicated
`suggestMockRecipesV2` endpoint reuses canonical membership/inventory checks,
request identity/revocation checks and read-only transactions. Its guard requires
the exact AI1 environment, AI1_MOCK_RECIPES=true, AI_RECIPE_PROVIDER=fake and no
relay/credential. It imports no Groq provider and has no provider fallback.

The `provider: groq` / schemaVersion=2 fields identify the existing v2 contract,
not a real provider execution. The separate client calls ONLY the mock endpoint.
Cards/details explicitly say mock/not real Groq output; quantities/units and
instructions come from validated v2 data. Cook Now, Save Recipe and AI Restock
remain unavailable. Missing fixture ingredients produce empty results.

The two clients share only the existing verified-session authorization wrapper.
Each enforces its own build/project/transport/schema guards. Auth transitions
invalidate pending results; membership/cafe/role are resolved before and after
requests. Widget session replacement/disposal invalidates UI completions. No
continuous membership watcher or production workflow is added.

From `C:\Users\23000\velora`, using installed dependencies only:

For manual acceptance, keep these in separate terminals in that directory.
Terminal 1 (no account seeding and no test watchdog):

```powershell
node functions/scripts/run-ai1-mock.js start
```

Terminal 2 (installed Flutter path, since Flutter may not be on PATH):

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat run --no-pub -d chrome --dart-define=AI1_MOCK_RECIPES=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1
```

Leave STAFF_DEMO and RECIPE_CONNECTIVITY_DEMO unset. `start` uses
`emulators:start` and stays alive until explicit Ctrl+C; its shutdown machinery
targets only its owned CLI/emulator tree. Quit Flutter with `q`, then stop the
emulators with Ctrl+C. No seed/reset/import/export is performed. Existing
recipe-connectivity credentials/fixtures are not AI1 fixtures; this command does
not prepare manual Owner/Staff accounts. Normal Flutter Chrome startup can load
public Firebase SDK assets; the commands were documented but Flutter was not
launched as part of this startup fix.

Startup-fix verification (2026-11-05): interactive `start` reached readiness on
the expected project/ports; explicit Ctrl+C logged clean shutdown and all nine
AI1 ports were released. The PTY reported exit 1 after Ctrl+C, so this is not a
zero-exit claim. An optional Auth-list probe failed and does not establish Auth
fixture counts; the start path contains no seed/test command. Focused offline
Node tests passed 89/89. The first automated-mode rerun ended unexpectedly during
startup and left a verified task-owned Firestore orphan; only that orphan was
stopped. IPC-disconnect cleanup was added so a CLI child also shuts down if its
launcher disappears. The bounded retry passed seven grouped integration checks
and exited 0 with normal emulator cleanup. Forced parent-disconnect behavior was
not separately exercised. Browser/Flutter tests were not rerun for this fix.
No UI, callable, authorization, Rules or schema files changed. Interactive start
performed no fixture seeding; test mode created its existing disposable AI1
fixtures only. No data clearing/import/export or production access occurred.

Automated modes retain `emulators:exec`, fixture setup and bounded cleanup:

```powershell
node functions/scripts/run-ai1-mock.js test
node functions/scripts/run-ai1-mock.js test-browser
flutter test --no-pub test/ai1_mock_recipe_test.dart test/groq_recipe_response_test.dart --dart-define=AI1_MOCK_RECIPES=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --reporter expanded
```

The launcher strips external credentials, forces fake/mock mode, refuses occupied
AI1 ports and environment files, and starts fresh disposable emulators. Runtime
fixtures use the unchanged createWorkspace callable for two Owner cafes plus a
synthetic Staff membership and Banana/Milk inventory. No working emulator is
reused/reset/imported. Outer timeout: 180 seconds for integration, 360 seconds
including browser; build: 180 seconds, browser: 90 seconds. Cleanup targets only
the task-owned processes.

The bounded browser harness reuses cached CanvasKit and locally installed
Firebase JS modules, with CSP blocking external scripts/connections. It invokes
real widget callbacks for Owner/Staff, generates mock-v2 results and opens the
existing read-only details view. It does not perform manual login/navigation or
visual screenshot acceptance. Normal recipe-connectivity harness defaults stay
unchanged.

2026-11-05 verification: 59 mock-v2 client/widget/parser tests PASS; 120 existing
fake-v1/client/presentation/containment tests PASS; 89 offline Node security/mock
tests PASS; focused analysis of eight Dart files reports no issues. The corrected
runtime run passed seven grouped workspace/authorization/inventory checks and
Owner/Staff Flutter Web mock UI/details checks; JavaScript build took 43.2 seconds.
Inventory remained unchanged after calls/browser, and owned emulators shut down
normally. An initial environment-conditional export was omitted during function
discovery; the dedicated mock codebase corrected that failure without relaxing
authorization. Initial style diagnostics were fixed.

DATABASE CHANGE REPORT: disposable AI1 fixture/provisioning and controlled
membership test updates only; recipe operations use read-only transactions.
No production, STAFF_DEMO or recipe-connectivity data access or migration.
GITHUB STATUS: main at a998741; local work preserved, no commit/push/deployment.
MANUAL TESTING: NOT RUN for Batch 3C. Existing Batch 2 acceptance is user-reported.
Cross-user Windows ACL remains NOT VERIFIED; this mock path does not use the
relay. Installed Node 24 differs from declared Node 22. The browser-only dart:html
entry point warns during Wasm dry run; the tested JavaScript build succeeds.
Live Groq and full production readiness remain unverified and unapproved.

Negative-profile matrix also PASS: default, STAFF_DEMO, missing emulator opt-in,
wrong host, AI1+STAFF_DEMO and AI1+recipe-connectivity each report 8 passed,
31 intentionally skipped, 0 failed. Recipe-connectivity alone reports 23 passed,
16 intentionally skipped, 0 failed; the mock path stays disabled while v1 works.

## AI1 Mock invitation compatibility

The existing Team/Staff Invitation UI and invitation transport now share
`FirebaseEmulatorConfig.invitationProfileAllows(projectId)` through the runtime
`invitationsAvailable` getter. It permits exactly STAFF_DEMO/demo-velora-staff
(Functions 25001, existing Auth 29099/Firestore 28080) or explicit
AI1_MOCK_RECIPES/demo-velora-ai1 (Functions 15001, Auth 19099/Firestore 19080).
Emulator opt-in, exact loopback host and mutually exclusive profile flags are
mandatory. Default, production, recipe-connectivity, wrong project/host and
conflicting flags fail closed. The transport verifies its app project and
explicitly selects the matching local Functions endpoint; no production fallback.

Owner-only UI access still derives from verified canonical membership. Backend
invitation functions/Rules are unchanged and remain authoritative. Redemption
still reloads Auth, requires verified email and refreshes the token. Auth changes
during refresh or callable execution invalidate the result, including away/back;
stale results do not route to WorkspaceGate or display an invitation code.

Manual onboarding in the existing AI1 Mock session:

1. Apply the updated Flutter build/hot restart using the AI1 Mock flags above;
   do not enable STAFF_DEMO simultaneously or stop a working emulator to do so.
2. Log in as the disposable Owner with a verified workspace. Open Settings →
   Team Management. Invite Staff should be enabled for Owner and disabled for
   Staff. Create an invitation for the exact intended Staff email; privately
   retain the displayed one-time code, which expires after 24 hours.
3. Sign out. Register/sign in with that Staff email in the same AI1 emulator.
   On Business Setup choose **Join with invite**; do not create a separate Staff
   workspace. Existing memberships cannot be replaced by redemption.
4. Make the disposable Staff account email-verified in the Auth Emulator, or
   use **Send verification email** and the emulator-local verification link.
   Never use a production verification service. Sign in again if needed; the
   redemption service also reloads the account and refreshes its token.
5. Enter the code and select **Redeem invitation**. Successful redemption
   re-enters WorkspaceGate, resolves the canonical Staff session in the Owner's
   cafe and exposes the same mock-recipe workflow with Staff permissions.
6. Verify Staff cannot invite others, recipes stay explicitly mock, and Cook
   Now/Save/AI Restock remain unavailable. Owner's roster should list eligible
   verified members. The roster filters unverified emails independently of the
   owner-membership banner; verify the disposable Owner email too when checking
   roster visibility.

Focused offline commands (root directory, installed Flutter SDK on PATH):

```powershell
flutter test --no-pub test/invitation_profile_service_test.dart test/staff_invitation_test.dart test/team_management_test.dart --dart-define=AI1_MOCK_RECIPES=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --reporter expanded
flutter test --no-pub test/invitation_profile_service_test.dart test/staff_invitation_test.dart test/team_management_test.dart --dart-define=STAFF_DEMO=true --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1 --reporter expanded
node --test functions/test/workspace-invitations.test.js functions/test/team-members.test.js
```

Real AI1 verification against an **already-running** mock session:

```powershell
node functions/test/ai1-invitations.integration.js
```

This Windows-only 90-second script verifies hub/Firestore process command lines,
project/config and exact loopback ports before writes. It creates four uniquely
named disposable Auth accounts and two cafes via unchanged workspace callables,
then tests the actual create/redeem/list/revoke boundaries. It never stops the
session or overwrites existing fixtures. Wrong-email/replay/cross-cafe failures
may create normal server-side invitation-attempt counters. Codes/tokens/passwords
are never printed. Fixtures intentionally remain until that disposable session
ends; the script performs no deletes or resets.

Verification on 2026-11-05: AI1 Flutter 33 PASS; STAFF_DEMO Flutter 33 PASS;
backend invitation/team unit tests 32 PASS; real AI1 invitation flow 12 checks
PASS, including verified Staff membership and cross-cafe denial. Initial test
matcher/Firebase-double issues were corrected before passing runs.
DATABASE CHANGE REPORT: only unique disposable AI1 Auth/workspace/invitation,
membership and attempt-counter records; no inventory writes, migration or
existing fixture changes. No production/STAFF_DEMO/recipe-connectivity data access.
GITHUB STATUS: local changes only on main/a998741, no commit/push/deployment.
MANUAL TESTING: Chrome onboarding has NOT been performed for this compatibility
fix. The real integration uses HTTP callables and Admin verification, while the
Flutter suites use offline Auth/Functions doubles. Live Groq remains disabled.

Compatibility negative-profile runs (default, recipe-connectivity, missing
emulator opt-in, wrong host, AI1+STAFF_DEMO and AI1+recipe-connectivity): each
17 passed, 16 intentionally skipped, 0 failed. Focused analysis of the eight Dart
files reports no issues; integration script syntax and `git diff --check` pass.
The original AI1 hub/session was retained throughout real invitation testing.

Groq endpoint/model: POST https://api.groq.com/openai/v1/chat/completions,
openai/gpt-oss-20b, strict JSON schema, low reasoning effort, include_reasoning=false,
2048 completion tokens. Only final content with finish_reason=stop is accepted.
Provider error bodies/reasoning are never forwarded or logged. 429 becomes a fixed
resource-exhausted error; provider/network errors become unavailable; total timeout
is 15 seconds (including body reading). No retries. Response stream is capped at
64 KiB, completion text 24,000 characters, outbound JSON 32 KiB. Pipe frames are
capped at 64 KiB with a 17-second timeout and 8 simultaneous local connections.

Only up to the first 20 eligible items from the stable ID-sorted authorized
snapshot reach Groq. External context includes opaque i1/i2 aliases, sanitized
names, quantities capped at 1,000,000 and exact units; no real item IDs, cafe/user
identity, categories, images, expiry timestamps or versions. Reject invalid labels
(including control/format characters). Inventory labels are data, not instructions.

Live responses use schemaVersion=2, provider=groq and recipe fields:
`title`, `ingredients: [{itemId, quantity, unit}]`, `steps`, `whyRecommended`.
Item aliases are mapped back to authorized real item IDs before return. Each
recipe is an independent alternative; quantities are NOT combined across recipes
and no stock is deducted. Reject fabricated IDs, duplicate ingredients, zero/
negative/nonfinite amounts, amounts above stock/cap, mismatched units and fractional
pcs. No unit conversion or ingredient-name guessing. The same validation runs in
the adapter, relay client and service before the existing authorization/inventory
recheck. Fake mode keeps its schemaVersion=1 fixture contract unchanged.

Structured fields can be checked against inventory; free-text cooking instructions
cannot establish food safety or prove that every ingredient mentioned in prose is
valid. Suggestions require human review, do not imply stock reservation, and cannot
authorize Cook Now. Persistent quotas/abuse controls and production deployment are
outside this phase. Official API references:
https://console.groq.com/docs/structured-outputs and
https://console.groq.com/docs/reasoning.


## One-command live AI-2 smoke test (user-operated only)

With GROQ_API_KEY already set in the current PowerShell terminal, from the
repository root run:

```powershell
node .\functions\ai1\run-emulators.js test-groq
```

This is an explicit opt-in to ONE live Groq request; it may consume Groq quota.
It is not run by automated fake-mode tests. No real key is requested, printed or
read during implementation. Only this live launch branch reads the terminal key
at runtime; the key stays in launcher memory and is not forwarded to Firebase CLI,
the callable worker or smoke runner. No .env files or credential files are used.

The command refuses occupied AI-1 ports, starts fresh demo-velora-ai1 emulators,
waits for the local callable to reject an unauthenticated readiness probe, then
creates two disposable Auth users, verified owner/staff membership links and
synthetic Banana/Milk/Oats inventory. It calls authenticated suggestRecipes exactly
once with maxRecipes=1. It requires schemaVersion=2, provider=groq, the matching
request ID, one recipe with valid instructions/ingredient IDs/quantities/units,
and an unchanged inventory snapshot. Empty results and fake-provider fallback
fail. The parent additionally requires exactly one invocation through its live
relay. There are no provider retries.

The live-test mode suppresses CLI/stdout/stderr details and emits only fixed
PASS/FAIL messages and validated printable recipe titles. No raw provider errors,
reasoning, Auth tokens, ingredients or instructions are printed. Safe failure
codes distinguish callable authorization, rate/capacity, timeout and validation
failures. Do not run Firebase CLI with debug settings or bypass the launcher.

On success/failure the parent requests graceful emulator shutdown via an IPC
wrapper around the installed Firebase CLI controller. Ctrl+C/SIGTERM cancels the
owned smoke runner and requests the same shutdown. A 120-second overall watchdog
and 60-second runner deadline bound waits. If the owned CLI does not shut down in
10 seconds, the launcher terminates only that spawned CLI process tree. It never
kills a process to free a port. Relay connections also have their existing bounded
timeouts. No reset, clear, delete, import or export commands are used; synthetic
fixtures disappear when these nonpersistent emulator processes exit. Production
and working-emulator data are never targeted. Hard termination of the launcher,
power loss or OS failure can bypass cleanup; do not claim guarantees for those.

CLI shutdown uses the installed firebase-tools controller API (verified against
15.16.0); CLI upgrades require rechecking this local wrapper. The Windows named
pipe/local-process trust limitations above still apply.

Offline smoke-runner tests (in-memory data and mocked local HTTP, no Groq):

```powershell
node --test .\functions\test\ai2-live-smoke.test.js .\functions\test\ai1-recipes.test.js .\functions\test\ai2-groq-provider.test.js
```

Existing fake-mode integration remains `node .\functions\ai1\run-emulators.js test`.
Live Groq smoke verification remains NOT RUN until the user explicitly executes
`test-groq`. A previous connectivity-probe PASS does not establish callable PASS.
