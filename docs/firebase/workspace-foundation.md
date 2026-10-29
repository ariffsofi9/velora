# Workspace foundation — isolated draft, not deployed

Existing production routing, registration, global queries and Firebase configuration
are unchanged. Nothing provisions a cafe or assigns legacy records. No deployed
rules/indexes have been inspected. Do not deploy the sibling rules as a replacement:
they intentionally deny all legacy paths and profile writes, which would break the
current application. A reviewed integration and emulator run are prerequisites.

## Schema (version 1)

All three workspace documents require `schemaVersion: 1` and `status: active`.

| Path | Required fields |
| --- | --- |
| `users/{uid}` | Existing personal profile; its legacy `role` is never authority |
| `cafes/{cafeId}` | `ownerUid`, name, server-created/updated timestamps |
| `cafes/{cafeId}/members/{uid}` | `uid`, `cafeId`, `role: owner or staff`, timestamps |
| `user_cafe_memberships/{uid}` | `uid`, `cafeId`, timestamps; no authoritative role |

Workspace IDs and UIDs must be single path segments, at most 128 characters.
The mapping document ID enforces one location per Firebase account. A map alone
is insufficient: trusted writes must keep mapping, membership and owner consistent.
No client write is permitted to workspace metadata, mappings or memberships.

The resolver obtains UID from Firebase Auth, performs read-only server transaction
reads, validates both links, owner/member consistency and active state, then checks
that the signed-in UID has not changed. Missing, malformed, denied or offline reads
throw typed failures. It does not cache, create, repair, list or switch workspaces.
Its result is presentation context, never authorization: Rules recheck each access.
Auth token/session changes for the same UID and revocation after resolution still
require future routing/listener invalidation plus server checks on every operation.

## Trusted-server lifecycle required before onboarding

Implement with an authenticated Cloud Function/Admin SDK service, not this client.
Admin SDK bypasses Rules; the server must perform these validations itself:

1. Bootstrap: authenticate the caller from a verified token; never accept an
   authoritative caller UID/role. In one transaction, require its mapping to be
   absent, generate the cafe ID, and create cafe, owner membership and mapping.
   Validate names and timestamps; make retries idempotent. Never auto-bootstrap
   existing users or use `users.role` as proof of ownership.
2. Invite: verify caller is the current active owner in the same transaction.
   Use expiring, one-use server-held invitations bound to the intended verified
   identity. Accept invitations only as the authenticated target; transactionally
   require no existing mapping, then create the staff membership and mapping.
   Do not allow an owner to silently assign arbitrary Firebase accounts.
3. Remove staff: recheck owner and target; atomically remove mapping/membership,
   invalidate invitations and terminate workspace access. Removed users resolve
   as missing. Exactly one *active* membership is allowed; zero means no access.
4. Transfer ownership: privileged transaction validates an existing staff member
   of the same cafe, changes cafe.ownerUid and both roles atomically. Never remove
   the last owner. No account may join a second cafe while its mapping exists.
5. Account deletion and recovery need a trusted policy preventing orphaned cafes.
   Keep audit events for lifecycle operations; do not infer legacy ownership.

Owners request these operations through the trusted server; staff cannot manage
members. The draft permits owner member-list reads; staff read only their own and
the owner's membership/mapping, needed for consistency. It grants no future stock,
notification, activity or AI writes until their schemas/permissions are reviewed.

## Rules, indexes and production boundaries

`workspace.firestore.rules` is an uncompiled, standalone deny-by-default draft.
Missing document fields deny access. Five distinct dependency documents are used
for membership checks; verify access-call limits for transactions and queries.
Broad allow rules in a future merged ruleset can override these denials: Firestore
grants are additive, so review the complete deployed ruleset before integration.

`workspace.firestore.indexes.json` is intentionally empty: resolution uses exact
document gets, requiring no composite index. Future cafe activity should use a
bounded query ordered by `createdAt` and document ID with a cursor, not offsets.
Add composite indexes only for actual approved filters. Do not deploy an empty
index draft over unknown production indexes. `firebase.json` remains unchanged.

Future paths: `cafes/{cafeId}/inventory`, `inventory_records`, `activities`,
`notifications`, `ai_recipe_suggestions`, `ai_cache`, `ai_quota`. Decide personal
notification acknowledgements and skipped-recipe preferences separately. Preserve
legacy thresholds and auth behavior during later, separately approved integration.

## Verification and exact emulator test matrix

Firebase CLI exists locally, but Java and `@firebase/rules-unit-testing` were not
found. No dependencies were installed, no emulator started and no Rules deployed.
Offline Dart tests do not prove Rules authorization or compilation.

When tooling is approved, use an isolated emulator config pointing only to these
drafts and a demo project (e.g. `demo-velora-workspaces`), never the production ID.
Use `initializeTestEnvironment`/`assertSucceeds`/`assertFails` and seed only through
the test environment's security-rules-disabled context. Required tests:

- Anonymous gets/list/writes denied everywhere; authenticated legacy paths denied.
- Valid owner/staff resolve their own cafe, own membership and owner links.
- Other cafe access, cafe enumeration and mapping enumeration denied.
- Staff listing peers denied; owner listing own members allowed, other cafe denied.
- All client membership/mapping/cafe writes denied, including atomic batches,
  forged UID/role, self-promotion, duplicate mappings and owner bootstrap attempts.
- Missing/mismatched/inactive mapping, member, cafe or owner link denies access;
  staff promoted to owner without matching cafe.ownerUid also denied.
- Profile reads limited to self; profile role changes cannot grant workspace access.
- Removing either link or disabling membership revokes reads on the next request.
- Read-only resolver transaction succeeds within document-access limits.
- Trusted backend tests: simultaneous invitations/bootstrap for one UID yield
  only one membership; retries, invitation expiry/replay, owner transfer, removal
  and failed transactions leave no partial mapping/membership/cafe writes.

Before cutover: inspect deployed security/indexes, test Auth and role revocation,
validate a backed-up legacy migration mapping with unresolved records quarantined,
add atomic stock/event writes, scope every AI/cache/quota/notification path, and
retain existing auth, Dashboard and recipe regression coverage.
