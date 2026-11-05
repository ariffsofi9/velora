# Firebase staging — S2.1 local safety preparation

Target supplied by the user: **velora-fyp-staging**, display name **VELORA FYP
Staging**, Spark plan. Web/Android apps are not yet registered. These are
user-confirmed facts, not independently inspected cloud state. Deployment,
billing, Auth/Firestore setup and cloud connections are not authorized.

**velora-73222 is protected and off-limits.** Its existing generated Dart/native
options and Firebase CLI metadata remain unchanged; they are not startup defaults.
No `.firebaserc`, CLI selection or deployment manifest was created/changed.

## Local startup selection

`FirebaseStartupConfig` validates the entire selection before `main` calls
Firebase.initializeApp or notification/plugin initialization. Invalid selection
renders a local configuration error and returns. An ordinary launch with no
profile now stops; it cannot use DefaultFirebaseOptions. The compatibility
`FirebaseEmulatorConfig.optionsFor` entry point deliberately ignores its legacy
options argument, so an old caller cannot restore that fallback.

Staging requires **VELORA_STAGING=true** and exact project **velora-fyp-staging**.
It rejects any emulator/demo/live-AI define, including false-valued definitions
or FIREBASE_EMULATOR_HOST. Never combine staging with USE_FIREBASE_EMULATORS,
STAFF_DEMO, AI1_MOCK_RECIPES, RECIPE_CONNECTIVITY_DEMO or AI1_LIVE_RECIPES.

`lib/firebase_staging_options.dart` contains separate nullable Web/Android slots.
Both are intentionally null. No key, App ID, sender ID, fingerprint or registered
Firebase value is invented. Web configuration validation checks exact project,
required fields, matching Web App ID/sender, auth domain and optional bucket.
These are local structural checks, not proof that a key belongs to a registered
app; S2.2 must copy and cross-check one complete Console configuration.

The staging VS Code entry is labelled BLOCKED. Do not launch it during S2.1.
Staging Web startup remains blocked until real app configuration is supplied in
a separately approved batch. No cloud services are enabled by these local files.

## Emulator regression boundary

Existing emulator ports are unchanged:

| Explicit selection | Project | Auth / Firestore / Functions |
| --- | --- | --- |
| STAFF_DEMO + USE_FIREBASE_EMULATORS | demo-velora-staff | 29099 / 28080 / 25001 |
| AI1_MOCK_RECIPES + USE_FIREBASE_EMULATORS | demo-velora-ai1 | 19099 / 19080 / 15001 |
| RECIPE_CONNECTIVITY_DEMO + USE_FIREBASE_EMULATORS | demo-velora-ai-connectivity | 49099 / 48080 / 45001 |
| USE_FIREBASE_EMULATORS alone | demo-velora-workspaces | 9099 / 8080 / 5001 |

Named profiles require exact 127.0.0.1; generic workspace routing allows localhost
or 127.0.0.1. Generic selection now explicitly uses the existing disposable
workspace test project, never an arbitrary legacy/default cloud options value.
Backend emulator launchers/configs, the Team test project demo-velora-team and
their lifecycle/ports remain unchanged. No running emulator is stopped or read.

## Android staging is blocked

The checked-in google-services.json targets the protected project. It is retained
unchanged. Dart validation alone cannot protect against native startup providers.
The main manifest therefore removes FirebaseInitProvider auto-initialization;
explicit Dart selection must occur first. Installed FlutterFire native source
was inspected: core discovery enumerates existing apps, while explicit app
initialization receives options from Dart.

Additionally, Gradle rejects VELORA_STAGING=true builds before an Android staging
artifact can be launched, and the Dart selector rejects Android staging even if
options are supplied. This block must not be removed merely after registration.
S2.2/follow-up must introduce matching native staging configuration and verify
the merged manifest/build before permitting startup. Android builds, manifest
merge and device execution were NOT RUN in S2.1; static checks are not device
proof. Previously installed binaries are not altered by this source change.

## Next manual Console steps — S2.2, after user approval

1. Open the explicitly selected **VELORA FYP Staging** project and verify Project
   Settings → General shows exact project ID **velora-fyp-staging**. Stop on any
   mismatch; never choose velora-73222. No Firebase CLI login/use is needed here.
2. Register a Web app in that project. Choose a staging app nickname, leave
   Hosting/Analytics setup out of this registration-only scope, and obtain the
   Firebase config object from the registered app's settings.
3. Cross-check projectId, Web appId, messagingSenderId, apiKey and authDomain as
   one configuration from that staging app. Record storageBucket only if actually
   supplied/needed; do not fabricate it or enable Storage merely to fill a field.
   Integrate it only into the staging-specific slot in an approved local batch.
4. Before Android registration, confirm the intended staging applicationId and
   coexistence/flavor strategy. Current source uses **com.example.velora**; do not
   invent or silently change a package ID. If retaining that ID, explicitly agree
   that staging and the existing app cannot be treated as independently installed
   packages. A distinct staging package requires a separately approved change.
5. Register the Android app using the exact approved package ID. Download its
   actual google-services.json; cross-check project_info.project_id and package
   identity without printing API-key values. Do not replace the legacy file or
   remove the Android staging gate. Prepare a separate flavor/config location in
   the next approved native-isolation batch.
6. Add SHA-1/SHA-256 only where the chosen providers/App Check require them, using
   the actual approved signing certificate. No fingerprints are provided by S2.1.
7. Stop after registration/configuration review. Do not enable billing, Auth,
   Firestore, App Check or other cloud services; do not deploy or launch staging.
   Spark is retained. Cloud Functions deployment remains a separate billing and
   authorization gate. Never copy emulator users/passwords/data into cloud.

**GO recommendation:** S2.2 manual Firebase app registration only, in the exact
staging project after confirming the Android package decision. This recommendation
does not authorize this agent to perform it. **NO-GO:** Android staging startup,
cloud connection/deployment and live Groq.

## Offline verification

From C:\Users\23000\velora (use the installed Flutter path if not on PATH):

```powershell
flutter test --no-pub test/firebase_startup_config_test.dart --reporter expanded
flutter analyze --no-pub lib/main.dart lib/firebase_staging_options.dart lib/services/firebase_startup_config.dart lib/services/firebase_emulator_config.dart test/firebase_startup_config_test.dart
git diff --check
```

All test Firebase options are explicitly synthetic in-memory fixtures; no Firebase
initialization/cloud connection occurs. The unconfigured-main widget test verifies
the local error route without Firebase/plugin initialization. Initial test compile
and brace-style issues were corrected before passing results.

DATABASE CHANGE REPORT: none. No cloud/emulator reads/writes, imports, migrations,
account registration or existing session interference. MANUAL TESTING: staging
was not launched; Console state, Android runtime and cloud behavior are unverified.
GITHUB STATUS: main/a998741; all prior local Week 3 work preserved, no commit/push,
branch, CLI project selection or deployment.

S2.1 actual results (2026-11-05):

| Offline check | Result |
| --- | --- |
| Default startup safety suite | 31 passed, 0 skipped/failed |
| Recipe-connectivity + existing fake UI regressions | 150 passed, 1 intended skip, 0 failed |
| AI1 Mock + v2 regressions | 89 passed, 1 intended skip, 0 failed |
| STAFF_DEMO + invitation/team regressions | 63 passed, 1 intended skip, 0 failed |
| Generic workspace emulator selection regressions | 43 passed, 38 profile skips, 0 failed |
| Staging missing-config and six conflicting-define runs | Each 30 passed, 1 intended skip, 0 failed |
| Focused Dart analysis | No issues found |
| Android manifest XML / VS Code launch JSON parsing | PASS |
| git diff --check | PASS |

Profile builds intentionally skip the unconfigured-main widget test; other skips
are suites requiring a different emulator profile. The staging matrix includes
USE_FIREBASE_EMULATORS=false to verify that mere presence is rejected. No staging
app or Android artifact was launched and no emulator data was accessed.
