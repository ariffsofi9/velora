# Menu Backend MVP — Batch 1

Backend only: no Flutter UI, POS, sales, inventory deduction, recipe generation
or ingredient links. No production deployment or migration has been performed.

## Contract

Menu documents: `cafes/{cafeId}/menu_items/{itemId}`.

| Field | Type / constraint |
| --- | --- |
| name | Nonempty normalized text, maximum 100 characters |
| category | Nonempty normalized text, maximum 60 characters |
| priceMinor | Integer MYR sen, 0 through 1,000,000 (RM 10,000.00) |
| currency | Server-set `MYR`; no currency conversion |
| isAvailable | Required boolean configured availability |
| isArchived | Server-managed boolean, initially false |
| version / schemaVersion | Positive integer version / schema version 1 |
| createdAt / updatedAt | Server Firestore timestamps |
| createdBy / updatedBy | Server-derived authenticated UID |

Prices never accept floating-point major currency amounts. Archiving preserves
configured availability but excludes the item from default listings and blocks
updates. Restore preserves configured availability. Effective availability must
always require `!isArchived && isAvailable` in a later UI.

All callables use `asia-southeast1` and derive the cafe from the authenticated
user's active canonical mapping, membership, cafe and owner links. Profile roles,
client cafe/owner/actor IDs, schema fields and timestamps are never authority.
Current Auth account state is checked; disabled/deleted accounts fail closed.
Email verification is enforced by the existing staff-invitation flow, rather
than introducing a different Owner email-verification policy here.

| Callable | Request | Permission |
| --- | --- | --- |
| createMenuItem | idempotencyKey, name, category, priceMinor, isAvailable | Owner |
| getMenuItem | itemId | Owner / Staff |
| listMenuItems | Optional includeArchived (false), limit (20; 1–50), cursor | Owner / Staff |
| updateMenuItem | idempotencyKey, itemId, expectedVersion, one or more editable fields | Owner; Staff only when the sole edit is isAvailable |
| setMenuItemLifecycle | idempotencyKey, itemId, expectedVersion, action: archive / restore | Owner |

Option B: Owner and Staff can set `isAvailable` to a boolean through
`updateMenuItem` with `itemId`, `expectedVersion` and `idempotencyKey`. Staff may
not include name, category or price even when the submitted value is unchanged.
Mixed fields are rejected, not silently stripped. Create, detail/price edits,
archive and restore remain Owner-only. Availability updates on archived items
are rejected. The existing version, idempotency and membership checks apply to
both roles, including retry receipts after revocation. Direct client writes
remain denied. No new callable or schema change is introduced.

Unlisted request fields are rejected. Mutation keys are 16–128 ASCII letters,
digits, underscores or hyphens. Use a fresh key per user operation and retain the
same key/payload for an unchanged retry. Mutations return cafeId, itemId, version
and changed; replay returns changed=false. The same key with a changed payload
or operation is rejected. Stale versions fail; reload before submitting a new
operation. No permanent delete exists.

`getMenuItem` returns `{item}`; list returns `{cafeId, items, nextCursor}`.
Item timestamps are ISO strings in callable responses. Lists use document-ID
ordering and a maximum 51-document bounded scan including look-ahead; pass the
opaque nextCursor to continue until null. Pagination is not a frozen snapshot
across requests. Both roles may read archived items when explicitly requested.

Backend-only receipts: `cafes/{cafeId}/menu_requests/{sha256(uid,cafeId,key)}`.
They contain payload hashes, trusted actor, operation, resulting ID/version and
server creation time. Receipt and menu writes commit atomically. Client menu
writes and all client receipt access are denied by the repository Rules draft.
Existing activity parsers and inventory collections are untouched; menu audit
metadata is in menu documents and receipts, not the inventory activity feed.

## Verification (repository root, Windows PowerShell)

Requires already-installed dependencies, Node, Java and Firebase CLI. No install
or Firebase credentials are needed for disposable demo testing.

```powershell
node --test functions/test/menu-service.test.js
npm.cmd --prefix functions test
node functions/scripts/run-staff-emulators.js test-team
git diff --check
```

The existing launcher verifies free loopback ports and starts `demo-velora-team`:
Auth 39099, Firestore 38080, Functions 35001, websocket 38150, hub 34400,
logging 34500, Eventarc 39299, tasks 39499. It refuses occupied ports and shuts
down after tests. Do not point tests at active STAFF_DEMO or production. No
clearFirestore, data import/export or persistent data reset is used.

Menu integration checks reuse disposable Owner, Staff and second-cafe fixtures.
They exercise actual callables and Rules; real commit-failure injection invokes
the backend service with an Admin transaction adapter to verify atomic rollback.
No production fault-injection hook is added. The broader inventory/invitation
regressions run alongside the new Menu tests.

## Database and release limits

This is an additive new schema, not a migration. Existing unsupported business
types, inventory, membership and user records are not rewritten. Only disposable
test data is written by verification. Malformed menu records fail validation;
there are no legacy defaults or automatic repairs. No new index configuration
or emulator routing change is introduced.

Production activation requires separately approved Functions/Rules deployment
and verification; `firebase.json` does not configure Firestore deployment.
Receipt cleanup, rate limiting beyond existing platform limits, UI and ingredient
relationships are not implemented in this batch. Manual browser testing is not
applicable to this backend-only batch. Review this contract before UI work.

## Batch 2 Flutter UI — manual acceptance pending

Entry point: Profile → Account → Menu Management. The existing bottom navigation
and Inventory UI are unchanged. Menu pages use the default Auth/Functions app,
region `asia-southeast1`, and existing emulator configuration. They never write
Firestore directly or accept cafe/role fields as callable authority. The client
rechecks workspace/session context around requests; backend authorization remains
authoritative. No fixture menu data is shown in the application.

For manual STAFF_DEMO testing, use the already-running isolated staff emulators
and launch from the repository root (do not reset or import their data):

```powershell
flutter run --no-pub -d chrome --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=STAFF_DEMO=true --dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1
```

- Owner: create a menu item with RM 12.50; verify the list shows RM 12.50. Edit
  details/price, confirm availability changes, archive, enable Include archived,
  then restore. Verify archived availability/edit controls are disabled.
- Staff: verify no Add, Edit, Archive or Restore action is exposed; confirm an
  availability-only update. Backend tests independently enforce these limits.
- Confirm Cancel performs no write. Retry a failed unchanged save/toggle with
  the same idempotency key; changed form values receive a new key.
- Load more than 20 items to exercise pagination; test error/retry and empty
  states. Refresh retrieves current backend state; the list is not a live stream.
- Edit the same item in two sessions: stale saves must load current values and
  require another explicit review/save. A failed conflict reload disables Save
  until Reload Latest succeeds. List actions refresh after a conflict.
- Sign out/change account during a pending load or confirmation; old results and
  forms must not become actionable. Confirm no other cafe's records appear.

GITHUB STATUS: implementation remains local and uncommitted; no push/deployment.
DATABASE CHANGE REPORT: UI calls only the existing Menu callables and schema.
Manual mutations occur only when the tester explicitly confirms them. Automated
Flutter tests use offline doubles and do not touch the working STAFF_DEMO data.
MANUAL TESTING: not performed by the implementation agent; browser acceptance is
required before considering the UI batch accepted.

Automated Batch 2 verification commands (repository root, installed Flutter SDK):

```powershell
& C:\Users\23000\flutter\flutter\bin\flutter.bat test --no-pub test/menu_model_test.dart test/menu_repository_test.dart test/menu_page_test.dart test/inventory_scoped_read_test.dart test/inventory_lifecycle_test.dart test/team_management_test.dart test/workspace_gate_test.dart test/workspace_resolver_test.dart test/profile_appearance_test.dart
& C:\Users\23000\flutter\flutter\bin\flutter.bat analyze --no-pub
npm.cmd --prefix functions test
git diff --check
```
