# Registration username persistence and default role audit

2026-11-06 (Asia/Kuala_Lumpur). OFFLINE AUDIT ONLY. No app/backend/Rules changes.

## Findings and confidence

Confirmed: signup forwards the trimmed submitted name; AuthService awaits Auth
updateDisplayName, but profile creation then reads displayName from the original
credential.user wrapper. The installed Flutter Web SDK captures displayName in
InternalUserDetails when UserWeb is created. Its updateProfile updates/reloads the
underlying JS user and sends auth.currentUser through an event; it does not replace
the original UserWeb's stored _user snapshot. The public Dart User delegates its
getter to that platform snapshot. This is a concrete stale-wrapper data path that
can supply null/blank displayName after a successful update. It explains how the
registration profile can receive the fallback without the form losing staff1.

It is NOT a live reproduction of the reported account. That account could also
already contain a fallback profile or have taken interrupted/login/settings recovery;
no production Auth/profile inspection occurred. Do not declare its exact historical
call sequence proven. The source defect is relying on mutable freshness of the old
wrapper, not a missing await: updateDisplayName IS awaited.

Confirmed: profile service writes literal role owner for new profiles. This is legacy
non-authoritative metadata and required by current Rules profile-create condition.
No reviewed privileged consumer derives workspace authority from users.role. No actual
Owner/Staff entitlement or workspace creation is established by the profile field.

## Source trace and assignments

1. lib/screens/auth/signup_page.dart: createAccount reads nameController.text.trim,
   validates required fields/name length and calls AuthService.register(name:name).
   No role is selected/inferred from the name staff1.
2. lib/services/auth_service.dart:62 creates Firebase Auth user; :73 awaits
   user.updateDisplayName(name); :74 passes THAT user to createUserProfileIfNeeded;
   then signs out. No second Auth create is used for recovery. Auth/profile writes
   are not one atomic transaction; failures can leave an incomplete account safely
   requiring manual login, not automatic deletion/recreation.
3. lib/services/user_profile_service.dart:34 reads users/{uid}; :36 exits for any
   existing profile. :38-41 uses Velora User if supplied displayName null/blank;
   :52-59 writes username, Auth-owned email/photo, role owner and server timestamps.
4. AuthService.signIn :122 and SettingsPage._createUserProfile call the same helper
   if a signed-in account lacks a profile. Neither overwrites a profile it sees
   already present, so a stored fallback is not automatically corrected later.
5. UserProfile.fromMap in lib/models/user_profile.dart defaults a missing username
   to Velora User and missing role to owner. Those are parsing fallbacks, not writes.
6. ProfileHeaderCard in lib/screens/settings/widgets_settings/profile_header_card.dart
   uses Firebase Auth displayName (not Firestore username), displaying Velora User if
   absent. UI-only fallback is distinct from a value confirmed stored in Firestore.

Installed SDK inspected because wrapper freshness matters:
- firebase_auth-6.7.1/lib/src/user.dart: getter delegates displayName; updateDisplayName
  forwards to delegate.updateProfile.
- firebase_auth_web-6.3.0/lib/src/firebase_auth_web_user.dart: UserWeb constructor
  snapshots JS displayName, updateProfile around :281 updates/reloads JS user and
  emits auth changes, without rebuilding that wrapper's InternalUserDetails.
- firebase_auth_platform_interface-9.1.0/lib/src/platform_interface/platform_interface_user.dart:
  final InternalUserDetails _user and displayName getter reading its userInfo.
These paths are installed local dependencies selected by .dart_tool/package_config;
no SDK or dependency changes/downloads were made. No Web browser test occurred.

## Async duplicate profile writes

Current get-then-set is NOT an atomic create-if-absent operation. Registration,
login recovery and settings can each call it; concurrent callers may both observe
absence then set different fallback/explicit values. Existing source orders the
registration operations, but does not globally serialize every profile initializer.
This is a local concurrency risk, not proof of the observed race. Once a document
is observed present it is preserved; later displayName changes do not sync username.
Client updateUserProfile changes only username/photoUrl/updatedAt after validation.
Rules constrain updates, but concurrent allowed username writes can still last-win.

## Role authority and security review

UserProfile declares role plus isOwner/isStaff convenience getters, and fromMap
silently defaults missing role to owner. A repository-wide local search found no
privileged use of these profile getters/role in the reviewed current flows. Keep
these misleading defaults on the deprecation list: future consumers could misuse
those names even though current backend validation is independent.

Current workspace authority is WorkspaceResolver's server transaction over canonical
mapping, cafe, self member and Owner mapping/member. It requires schema 1/active
state, cafe Owner UID agreement, role-vs-UID consistency and matching bounded
membership generations. Backend createWorkspace derives UID from trusted Auth,
requires email_verified true, rejects supplied authority fields and creates the
cafe/Owner member/canonical mapping atomically. Existing Staff/malformed mapping
cannot bootstrap ownership; verified identical Owner retry does not duplicate it.
Inventory/menu backend handlers independently validate active membership/roles and
request episode at write boundaries. Admin SDK bypasses Rules; profiles do not
supply authority to these checks. A missing mapping leads to setup, not Owner access.

Staff joins via verified-email redemption of an Owner-issued invitation with canonical
single-workspace checks. Registering a username staff1 does not enroll Staff or choose
a role. No invitation issuance/redemption, membership creation or account status is
inferred from the observed profile. Prior production listing found no Functions;
this audit did not repeat it. No deployment is performed by changing metadata.

Rules B validProfileCreate currently REQUIRES data.role == owner, an allowlisted
shape, self UID, Auth email and server timestamps. validProfileUpdate permits only
username/photoUrl/updatedAt changes, excluding role/email/authority fields. Thus a
naive role->staff/member/pending/null/omitted change would fail profile creation under
the deployed contract. Do not silently choose a new role string or weaken Rules.

## Minimal backward-compatible fix proposal (NOT IMPLEMENTED)

Batch 1: username persistence only, no Rules/schema/role migration.
- Have registration pass its validated intended username explicitly to a narrow
  create-profile operation, bound to the authenticated UID. Do not derive a known
  submitted value from the stale User wrapper. Reject malformed explicit values;
  fallback ONLY when no intended name exists in genuine legacy recovery.
- Validate service inputs before Auth mutation where feasible; keep 80-character,
  nonblank constraints and Auth-owned email. Never accept UID/role authority from UI.
- Make create-if-absent atomic (e.g. read-only check then create inside a client
  transaction), preserving existing legitimate profile data on races. Review retry,
  server timestamp, Rules budget and UID-before/after requirements. Do not use an
  unconditional merge/set that overwrites concurrent profile creation.
- Optionally refresh/reacquire Auth currentUser and verify SAME UID for UI freshness,
  but merely calling reload on the old wrapper is not sufficient proof that its
  getter changed. Prefer explicit validated name for new registration persistence.
- Existing profiles, including fallback entries, remain unchanged automatically.
  Repair a user's existing name only through separately authorized own-profile update
  or a reviewed user-confirmed repair flow. Do not scan/migrate production.

Batch 2: remove misleading global role semantics, separately reviewed across all
consumers and Rules. Preserve legacy stored owner/staff metadata for compatibility,
never interpret it as authority. New profile creation should omit deprecated role
only AFTER Rules is reviewed/compiled/deployed to accept that shape while continuing
strict field/update controls. The parser should represent absent/unassigned role
neutrally rather than fabricate owner; remove/deprecate profile isOwner/isStaff or
rename as non-authoritative metadata. UI role badges should use verified workspace
session only, and show no assigned role before that exists. No particular new stored
role value is selected by this audit. Old clients may still send owner, so design a
reviewed overlap window or explicit minimum-client policy before disallowing it.

No deployment/migration is bundled with either proposal. Batch 1 can proceed within
existing Rules; Batch 2 cannot be an isolated Flutter-only change. Profile metadata
must never substitute for membership during either phase.

## Regression tests required before implementation approval

- Registration staff1 with a fake old user whose displayName stays null after
  updateDisplayName; fresh currentUser has staff1, same UID: created username must
  be staff1, not fallback. Current auth_flow_test fake mutates name immediately and
  profile dependency is a test double, so that suite masks the old-wrapper behavior.
- Explicit nonblank name persisted even if Auth event/reload is delayed; blank/absent
  legacy name alone gets fallback; invalid explicit input rejects before write.
- Two concurrent profile create callers, explicit vs recovery: no overwrite of an
  already committed valid profile. Document chosen winner/repair behavior explicitly.
- Existing profile name/role/email/timestamps are not overwritten by login/settings;
  Auth failure/profile failure/sign-out failure maintain current safe recovery.
- UID changes during creation/reload cannot create a profile for a different user.
- Username staff1 or users.role owner/staff never changes membership/cafe privileges.
- Coordinated optional-role schema: legacy profiles/old clients remain compatible,
  new missing-role data has neutral UI semantics, unauthorized role updates denied,
  resolver continues to reject missing/inactive/mismatched canonical/member links.
- Display header test must distinguish Auth displayName from stored profile username.

No missing regression tests were added in this audit; app/test source changes are
not authorized. Mock coverage below is not a reproduction of the actual account.

## Actual offline commands/results

From C:\Users\23000\velora:

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/auth_flow_test.dart test/profile_validation_test.dart test/profile_appearance_test.dart test/workspace_resolver_test.dart --reporter expanded
node --test functions/test/workspace-creation.test.js functions/test/single-workspace-security.test.js
```

PASS: Flutter 75 tests, 0 failed/skipped; backend 30 tests, 0 failed/skipped.
Existing tests cover sequencing/failures, profile boundaries and fallback, existing
profile preservation, resolver authority and backend verified-email/single-workspace.
They do not cover stale Web wrapper + real profile persistence together. No emulator,
real Auth operation, account creation or production request. No full-suite claim.
Source/reference review completed; final git/document checks recorded in task report.

## Database/Git and stopping point

Only this local audit document added. Schema, local/production Rules, documents and
Auth users UNCHANGED; production reads/writes/deployments NONE. No Firebase metadata,
credentials, logs or accounts fetched. No application/backend/test/config/dependency
changes, Git add/commit/push, staging/emulator access or automatic fix implementation.
Root source mechanisms confirmed; reported account's exact historical path unverified.
Next step: review and separately authorize Batch 1 with the missing stale-wrapper and
concurrency tests. Keep role-contract deprecation independent and approval-gated.
