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
relay shares the existing trusted-local-developer boundary: local processes with
access to the pipe can submit requests; it is not a public authorization boundary.
Callable membership checks remain mandatory and unchanged. Never expose the demo
emulators or relay to other machines. Closing the launcher closes the relay.

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
