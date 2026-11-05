# D3B.2A client integration

Baseline: `eeca574d3d8a7654268330cda8004e819002de8b` on `main`.
Local implementation only. No deployment, cloud access, app launch or emulator.

## Implemented contract

The read-only workspace resolver validates active canonical/member and Owner
links, then their `membershipGeneration` pairs. Both fields absent is supported
legacy generation 0. Both present must be matching nonnegative safe integers.
One-sided fields, explicit null, fractional/string/negative/unsafe values and
inactive or inconsistent links fail closed. Workspace and session models retain
the validated generation alongside UID, cafe, Owner UID and role.

Inventory create/edit/stock/archive/restore adapters capture their verified page
session. Requests include `expectedCafeId` and `expectedMembershipGeneration`.
An Expando binds each immutable request object to its first dispatched episode:
another adapter cannot substitute a different episode on retry. Invalid sessions
cannot dispatch or return successful late results. Existing operation fingerprints,
keys, versions, payload validation and UI confirmation behavior are preserved.

Menu mutation requests use the repository's first verified episode, which cannot
change within its lifetime. Resolution before and after transport includes the
generation comparison; same-UID/same-cafe rejoin therefore fails old requests and
suppresses late responses. Read-only menu request payloads remain unchanged.

## Session lifetime and cached presentation

Production workspace routing mounts a persistent session boundary under all
pushed workspace routes. It watches Auth plus the canonical mapping, own member,
cafe, Owner mapping and Owner member. Workspace content is withheld until all
authority snapshots are server-backed and a server transaction revalidates the
exact captured session. Cached authority cannot grant access. Verification times
out after 15 seconds rather than exposing an unverified workspace.

An authority-field change, listener error, post-verification cache-only state,
Auth identity change or app pause invalidates the old session. The route stack,
including pushed detail/dialog routes, is removed; listeners are disposed and
late verification cannot revive the old session. Logout returns to login. Other
invalidations require explicit retry through the blocked gate; a new episode is
never silently adopted by the old monitor. This is deliberately fail-closed and
requires online re-verification after backgrounding.

Inventory streams ignore cache/pending-write snapshots. Inventory reads, stock
history and activity pages request server data and reject late results after
session invalidation. CSV export and team consistency checks now include generation.
The app does not delete Firestore's persisted cache: previously downloaded data
cannot be recalled, and device-level data erasure is not claimed. Old cached data
is not used to authorize or populate a newly verified episode through these paths.

## Boundaries and follow-up

Startup project options and guards, backend sources, Rules, indexes and mutation
contracts are unchanged. Existing disabled removal/rejoin gates remain disabled.
Invitation transport restrictions and AI/Groq boundaries remain unchanged. No
new menu/ingredient-mapping or AI feature is claimed by this integration.

Separate UI follow-up: rename `AI Tips` to `Discover`; no label/redesign change
is included here.

Database impact is client reads/listeners and required mutation expectations only;
no schema change, migration or live write. Real listener revocation, network/cache
behavior and Android against deployed Rules/Functions are NOT VERIFIED. Device
acceptance and cloud readiness still require separately approved testing.

## Offline verification

Run Flutter tests with `--no-pub`; exclude
`test/recipe_connectivity_emulator_test.dart` under the strict no-emulator policy.
Existing opt-in screenshot/mock conditions may skip other tests. No skip is a
manual acceptance result. New focused coverage is in
`test/workspace_episode_integration_test.dart`, resolver and service/menu tests.

Backend regression remains `npm.cmd test` from `functions/`. Android assembly uses
the installed Gradle 8.14 with `--offline --no-daemon :app:assembleRelease` and the
base64-encoded `VELORA_FIREBASE_PROJECT=velora-73222` Dart define. This invokes
Flutter compilation through the existing Gradle plugin without dependency downloads
or application launch. Existing debug release-signing configuration is unchanged.

Verified in this task: Flutter offline suite 569 passed, 66 skipped, zero failed;
the emulator integration file above was separately excluded. Default backend
suite 357 passed, zero failed/skipped. Changed-file analysis is clean. Full Flutter
analysis reports four pre-existing informational brace-style findings in
`lib/models/fake_recipe_response.dart`, with no errors/warnings. `git diff --check`
passed. The final offline release build succeeded and APK signature verification
confirmed the Android Debug certificate. Artifact:
`build/app/outputs/flutter-apk/app-release.apk` (75,599,099 bytes). Merged manifest
has package `com.example.velora`, INTERNET permission and no FirebaseInitProvider.
No manual/device testing, emulator, cloud access, deployment, commit or push occurred.
