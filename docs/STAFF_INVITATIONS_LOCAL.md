# Phase 1B disposable staff invitation demo

This is a local-only workflow. No deployment or production verification has been
performed. Existing default Firebase settings are unchanged; invitation UI and
client calls require the explicit isolated staff-demo build.

## Run from the repository root (PowerShell)

Installed Node.js, Firebase CLI, Java, Flutter and existing dependencies are
required. Do not install dependencies as part of these commands.

```powershell
node functions/scripts/run-staff-emulators.js test
```

If the staff-demo ports are already in use, leave that session untouched and run
the separate disposable regression profile instead:

```powershell
node functions/scripts/run-staff-emulators.js test-team
```

This uses `demo-velora-team`, Auth 39099, Firestore 38080, Functions 35001,
websocket 38150, hub 34400, logging 34500, Eventarc 39299 and tasks 39499.
Both profiles run the invitation, scoped team-list and Rules integration checks.

This starts disposable `demo-velora-staff` Auth, Firestore and Functions, runs
synthetic integration tests, then shuts down the emulators. It does not clear,
import or export emulator data. Occupied ports cause refusal rather than reuse.

For manual testing, keep this running in one terminal:

```powershell
node functions/scripts/run-staff-emulators.js start
```

In another terminal, from the same repository root:

```powershell
flutter run --no-pub -d chrome --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=STAFF_DEMO=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1
```

The staff-demo build replaces Firebase options with the disposable demo project
and rejects missing emulator opt-in or a different host. Do not use this command
against the working emulator. Ports are Auth 29099, Firestore 28080, Functions
25001, UI 24001, hub 24400, logging 24500, websocket 28150, Eventarc 29299 and
tasks 29499. AI-1/AI-2 have a different project/ports and remain unchanged.

## Manual workflow

1. Register a disposable owner and create a workspace (Cafe, Restaurant or Bakery).
2. Open Team Management, create an invitation for the staff email, and privately
   copy the one-time code. The code is shown only in memory; explicitly copying
   places it on the OS clipboard. Clear the clipboard after transfer.
3. Sign out and register/sign in with that staff account. Verify its email using
   the local Auth emulator verification workflow (UI at http://127.0.0.1:24001).
   No invitation-email delivery integration is included.
4. In business setup, use the Join with invite header action. Paste and redeem
   the code. The existing WorkspaceGate resolves the new staff membership.
5. Owner can revoke a pending invitation using its invitation ID. No invitation
   listing or recovery of a lost plaintext code is provided.

Expected: only the bound verified email can join; existing members cannot join
another workspace; staff cannot invite, assign roles or access another cafe.
Expired, revoked, used and invalid codes fail safely. Manual browser verification
is separate from automated widget/integration tests.

## Security contract and limitations

`user_cafe_memberships/{uid}` remains canonical. Redemption atomically creates
that mapping and `cafes/{cafeId}/members/{uid}` with staff role, and consumes the
invitation. Existing or inconsistent membership records block redemption; there
is no migration or repair. New workspace creation permits only cafe, restaurant
and bakery; historical unsupported business types are preserved.

Only a currently verified owner chain can create/revoke invitations. The backend
uses authenticated identity, never profile role or client owner/cafe fields.
`workspace_invitations/{id}` stores SHA-256 hashes of cryptographically random
codes, normalized email, trusted cafe/owner, 24-hour expiry and lifecycle status.
Raw codes are returned once and never stored/logged by the backend. Duplicate
issuance request IDs fail rather than reveal the code again.

`workspace_invite_requests` stores issuance receipts; `workspace_invite_limits`
stores transactional rate counters (10 invitations/owner/hour and 10 redemption
attempts/user/10 minutes). All three collections deny client reads/writes.
No automatic cleanup, invitation delivery, member removal, ownership transfer or
multi-workspace switching is implemented. Auth verification and Firestore
transactions are separate services; verification is checked immediately before
the transaction, not atomically with Firebase Auth changes.

## Team member visibility

`listTeamMembers` is a read-only authenticated callable. It derives the cafe from
the canonical caller mapping and verifies active cafe/member/owner links.
Owners can list all verified members of that cafe; staff can see only themselves
and the owner, preserving the existing Rules visibility. Direct Rules grants
are unchanged. Every returned member must have a consistent active mapping and
membership plus an enabled, email-verified Firebase Auth account. The displayed
name and email come from Auth; profile role and client cafe IDs are not trusted.
Only UID, display name, email and membership role are returned.

Membership authorization is rechecked after fetching Auth display fields. More
than 100 membership records causes an explicit error (pagination is not yet
implemented); errors never fall back to a self-only card. Refresh reloads the
list, and Auth changes invalidate pending UI results. There is no live team
subscription or new role-change/removal operation. Management menus are hidden
because those operations remain unavailable.

Manual acceptance: in the staff-demo build, sign in as a verified owner and
confirm owner plus redeemed verified staff appear under Verified Members. Sign
in as staff and confirm only self and owner are visible and Invite Staff remains
disabled. Refresh the list/page, then sign out during a pending load. Verify
errors show retry without stale member cards. Existing unverified Auth accounts
are excluded from this list without modifying their membership or account.

Normal builds call the new read-only callable as well; they require a separately
approved Functions deployment before the full list can work there. This source
change does not deploy anything and does not establish production readiness.

Repository Rules and callable registration are not evidence of deployment.
Production activation requires a separately approved deployment/billing and
security review. Existing inventory authorization and AI-disabled UI remain in
place. No Groq credentials or calls are involved.
