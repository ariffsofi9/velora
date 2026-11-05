# W2: Owner email verification and Business Setup validation

2026-11-06, Asia/Kuala_Lumpur. Local implementation and offline tests only.
No backend, Groq, Firebase configuration, Rules, index, billing or deployment edits.

## Resulting flow

REGISTER -> account/profile created -> explicit manual LOGIN (existing registration
guard/sign-out preserved) -> WorkspaceGate canonical resolution:
- existing active Owner/Staff -> existing protected home path, no new verification
  gate or duplicate workspace creation;
- no membership -> Owner email-verification page -> explicit send/resend -> open
  hosted verification link -> check -> reload current Auth user + forced token
  refresh -> canonical resolution AGAIN -> existing home if another session created
  membership, otherwise Business Setup.

The extra manual login is intentional compatibility with the existing registration
policy. Registration does not send mail automatically or become a completed login.
Subsequent unverified login resumes the same prospective-Owner verification path.
Inactive/inconsistent existing membership remains denied; it is not converted into
a new Owner. users.role is unchanged and is never used as workspace authority.

## Actual files

ADD:
- lib/services/owner_email_verification.dart: injectable Auth verification boundary.
- lib/screens/auth/owner_email_verification_page.dart: pending/send/check/sign-out UI.
- test/owner_email_verification_test.dart and test/helpers/owner_verification_fake.dart.
- this document.

MODIFY:
- workspace_gate.dart: verification only after canonical missing-membership result;
  verified continuation re-resolves before setup, avoiding duplicate-owner routing.
- workspace_provisioning_service.dart: fresh verified-user/token preflight and
  backend-aligned request normalization/validation, same callable and fields.
- business_information_step.dart and business_setup_page.dart: local field errors,
  submission verification guard and verification round trip preserving draft.
- auth_service.dart/user_profile_service.dart: explicit initial username for newly
  created profile, independent of cached displayName; existing profiles untouched.
- related Auth/setup/provisioner/gate/profile tests, injecting offline verification.

DELETE none. No LoginPage/SignupPage route changes needed: their shared gate now
provides the new flow. No backend or paused Groq work included.

## Verification boundary

FirebaseOwnerEmailVerification lazily uses the existing FirebaseAuth instance or
an injected fake. refreshVerified captures UID, awaits User.reload(), reacquires
currentUser, checks SAME UID and emailVerified, forces getIdTokenResult(true), then
checks SAME current UID, emailVerified and token.claims.email_verified===true.
No token is logged/displayed/persisted. No Firestore profile field marks verification.
Backend createWorkspace's trusted email_verified check remains unchanged/mandatory.

Explicit sendVerification calls SDK sendEmailVerification once, no custom action
URL, no key, no automatic emails/retries. Busy guard and a 30-second cooldown apply
to attempts, including failures. Cooldown is local UX protection, not distributed
abuse control; Firebase's own restrictions remain authoritative. New screen/service
instances can reset local cooldown. The screen shows ceil-rounded remaining seconds.

Auth operations have a 15-second client wait bound. Timeout cannot prove a mail
was not sent or cancel the SDK operation; UI advises checking the inbox and waiting.
No late refresh automatically sends mail, enters setup or creates workspace. Offline,
expired/disabled/signed-out/session-changed errors are sanitized and fail closed.
Back/Sign Out signs out first, confirms no current user, then clears navigation to
the existing LoginPage. No forced profile or workspace writes.

Already verified users are not trapped: refresh/claim check continues without mail.
Normal existing-membership Owner/Staff routing bypasses this prospective-Owner
screen. New Staff without membership may verify before invitation flow; existing
active Staff login/session policy is not changed.

## Business Setup and callable safety

UI checks verification before invoking even an injected provisioner. A known
unverified result disables Create and offers Verify email. That page is pushed over
the draft; successful verification returns to the SAME form without automatic
creation. User explicitly taps Create again. Duplicate-submit busy guard remains.
No create after an unmounted preflight. Real FirebaseWorkspaceProvisioner also
independently reloads/refreshes verification and compares current UID before the
unchanged callable invocation; UI checks are not the security authority.

The normal flow therefore can perform more than one fresh Auth check before create;
this is conservative and adds latency/network dependency. Current uncertainty policy
is preserved: accepted/unknown create outcomes only resolve access, never auto-create
again. A rare verification failure in the provisioner's second preflight may map
to unavailable and invoke the existing conservative recheck-only UX; W1's broader
recovery/capacity policy remains a separate P1 task, not silently weakened here.

All seven request fields remain exactly:
businessName, businessType, address, inventoryUnit, lowStockAlerts, expiryReminders,
reminderDays. No caller UID/role/cafe field. Name/type/address text use trim + collapse
whitespace like backend; controls are checked after normalization. Name 2-80 UTF-16
code units, optional address <=200, remaining C0/C1 controls rejected. Type UI is
Restaurant/Cafe accented/Bakery; request normalizer also preserves supported backend
lowercase aliases. Units kg/g/L/ml/pcs, booleans statically typed, reminder days 1/3/7.
Normalization does not overwrite controllers or discard form data on errors.

Callable remains createWorkspace in asia-southeast1, explicit selected Firebase
profile/initialized app identity check unchanged. No direct writes to cafes,
membership or inventory collections. On success, resolver/session boundary remain
the only path into home; returned cafeId is not trusted as authorization.

## Profile-name fix

Registration passes submitted trimmed name as initialUsername to profile creation.
The service uses it only if the profile does not already exist; it still validates
name/photo/email and creates the existing role:'owner'/timestamp shape required by
Rules B. Login without a submitted registration name retains legacy fallback logic.
No historical profile repair/migration or role removal. Tests model stale null
displayName, verify explicit submitted name, and assert existing profile untouched.

## Offline verification executed

Directory C:\Users\23000\velora. Existing Flutter SDK, no dependency install:

```powershell
flutter.bat test --no-pub test/owner_email_verification_test.dart test/business_setup_test.dart test/workspace_provisioning_service_test.dart test/workspace_gate_test.dart test/auth_flow_test.dart test/profile_validation_test.dart test/workspace_resolver_test.dart test/workspace_session_test.dart test/dashboard_page_test.dart test/workspace_inventory_repository_test.dart --reporter expanded
```

Result: 170 passed, zero failed/skipped, exit0. Earlier focused subsets passed and
overlap; do not add their counts. Covers send success/failure/cooldown/busy, reloaded
user and fresh claims, UID switches, expired/offline/sign-out, timeout/no late
continuation, already-verified bypass, missing-membership gate, existing Owner/Staff
routes, blocked unverified submission, verified round-trip/draft, field bounds and
all seven normalized values, duplicate submit and canonical home/session revocation.

Scoped flutter analyze --no-pub over the 15 affected service/UI/test files: no
issues, exit0. Dart format applied only to scoped files. Full default Flutter suite,
golden screenshots, browser/device and real email/runtime tests NOT RUN.

From functions:
node --test test/workspace-creation.test.js test/single-workspace-security.test.js
=> 30 passed, zero failed/cancelled/skipped/todo, exit0. Backend remains unchanged.
Local Rules static compatibility preserved: initial owner profile fields unchanged,
no new client authority writes. Rules runtime/emulator/production NOT VERIFIED.

Automated tests use Fake User/FirebaseAuth, IdTokenResult claims and fake provisioners/
repositories. No real Auth account, mail, Firebase Functions or Firestore operation.
Production email provider/template/authorized domains, SDK behavior on actual
Android/Web, cold restart/link round trip and refreshed callable token delivery
remain unverified; require separately approved runtime acceptance later.

## Database/Git/change control

Schema, local/production Rules, indexes, documents and Auth users UNCHANGED.
Production reads/writes NONE; deployments NONE. No billing, secret, IAM/API changes
or emulator. Rules SHA-256 remains
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.
Existing dirty work preserved; no Git stage/commit/push/history changes. No Groq edits.

GO for local review: W1's verification/validation source blockers addressed, with
explicit registration-login compatibility. NO-GO for billing/deployment or claims
of live first-user creation. Callable deployment and cloud prerequisites remain
separate blockers. STOP after report; no automatic next phase.
