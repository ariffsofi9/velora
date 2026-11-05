# D3B membership lifecycle proposal

2026-11-05. D3B.1C implements local atomic Staff removal with offline coverage.
The callable is registered DISABLED in source; NOT ACTIVATED or DEPLOYED.
D3B.1D implements an internal, default-disabled rejoin foundation with offline tests.
No rejoin callable or cloud activation is added. Earlier proposal sections below
remain future design unless superseded by the implemented contracts here.
No migration authorized.

## D3B.1E implemented mutation episode protection

All sensitive inventory/menu mutations now require `expectedCafeId` and
`expectedMembershipGeneration` in the request. There is no internal bypass and
no default generation for requests: even valid legacy memberships require an
explicit expected generation 0. Malformed or absent expectations are
`invalid-argument`; a valid expectation differing from trusted current workspace
or generation is `aborted`. These fields are preconditions, never authority.

Protected callable entry points: `createInventoryItem`, `updateInventoryItem`,
`adjustInventoryStock` (in/out), `setInventoryLifecycle` (archive/restore),
`createMenuItem`, `updateMenuItem` (metadata and Staff availability), and
`setMenuItemLifecycle` (archive/restore). All route through the existing domain
transactions. The new pure `mutation-episode.js` parses expectations, and each
transaction compares them against the generation returned by its fully validated
active canonical/member/Owner resolver before receipt lookup or business writes.
The authorization documents remain transaction reads, so concurrent removal
invalidates/retries a pending transaction; a mutation committed before removal
is not retroactively undone. Menu get/list remain unchanged.

Payload hashes now include the validated expected episode. Unchanged retries in
the same episode retain stable keys. Stale requests fail before receipt replay;
changing the expected episode on a previously used key produces a payload
conflict rather than replaying or re-executing an old mutation. Existing receipts
written under the older hash contract may conflict with new-format retries: no
automatic migration or compatibility bypass is added. Item/stock version checks,
RBAC and atomic inventory movement/activity writes remain intact.

Database schema/collections and Rules are unchanged in this batch. Existing
inventory item create hashes, inventory activity/movement payload hashes and
menu receipt payload hashes now cover the episode; no live records are changed.
No lifecycle activation occurs. First-time invitation flows are unchanged.

CLIENT INTEGRATION BLOCKER: current Flutter adapters do not send these fields.
Their protected mutations will fail until a separately approved client batch
captures a verified session's cafe/generation and retains those original values
through unchanged retries. Do not fetch the latest generation merely to refresh
an old request. The client resolver/session also needs generation support.
Legacy test/emulator harness requests without fields are incompatible; no emulator
was run or modified here. Direct client Firestore writes remain denied.

Focused offline tests: `node --test test/mutation-episode.test.js` from `functions/`.
They are also included in default `npm test`. Models cover actual removal/rejoin,
receipt reuse across episodes and both removal/mutation commit orderings.
Rules runtime and cloud/Android behavior remain NOT VERIFIED; Emulator NOT RUN.

## D3B.1D implemented rejoin contract

`functions/src/membership-rejoin.js` validates inactive Staff removal evidence and
performs rejoin writes inside the existing redemption transaction. Invitation
creation/redemption accept an INTERNAL `allowRejoin` dependency, default false.
It is not accepted in client request data; current callable wiring never supplies
it. Removal stays explicitly disabled. Tests opt in against fake stores only.

With internal opt-in, issuance requires an injected trusted email-account lookup,
not a client UID. A found target must have matching email, verified account and
not be disabled. If it has a mapping, issuance validates its inactive Staff pair,
removal event and receipt inside the owner-authorized transaction, then stores
`bindingVersion: 1`, `targetUid`, `targetGeneration`, `previousCafeId` and
`removalEventId` on the invitation. Active membership cannot obtain rejoin binding.
Unknown/unmapped accounts retain the existing first-time email invitation flow.
Binding is based on the removal generation/event, never timestamp ordering.

Redemption still requires verified trusted Auth email, valid hash, pending status,
expiry and active destination Owner/cafe authorization. Existing callable fresh
account verification remains unchanged. Rejoin additionally requires exact UID,
generation, prior-cafe and event binding to a schema-version-1 inactive canonical
mapping and Staff member. Both must point to the same removal event/remover/time.
The immutable removal event and receipt must match type, identities, hashes,
generations and timestamp; the event's pre-removal snapshots must validate as
an active Staff pair. Missing/ambiguous legacy tombstones are rejected, not migrated.
Legacy email-only invitations cannot reactivate tombstones, even with internal opt-in.

All reads precede writes. The single redemption transaction:

- Creates `cafes/{destination}/membership_events/rejoin_{invitationId}`, retaining
  snapshots of the canonical link, prior Staff member and any destination member.
- Replaces `user_cafe_memberships/{uid}` with an active destination link at the
  next safe generation, preserving original account-link creation time.
- Creates or explicitly replaces `cafes/{destination}/members/{uid}` as active
  Staff with the same generation. Obsolete removal metadata is cleared from the
  active link, with its full previous content retained in the audit snapshot.
- Consumes `workspace_invitations/{invitationId}`, recording authenticated UID,
  trusted server-side time, result generation and rejoin event ID.

For a different destination, the old inactive member remains untouched. Revisiting
a previous destination requires that destination member's own valid removal audit,
receipt and an older generation. No existing active destination record is overwritten.
No audit is updated/deleted. The consumed invitation is the one-time completion
record; no additional receipt collection is needed. Replay fails rather than
returning an idempotent success. Competing joins conflict on the canonical mapping
and only one consumes its invitation. Removal 0->1, rejoin 1->2, later removal
2->3 invalidates every still-pending invitation bound to generation 1.

`functions/src/index.js` adds only the transaction adapter's `set` primitive for
full link replacement; it does not pass the opt-in or register a new callable.
First-time legacy membership writes and existing invitation transport remain unchanged.
Rules and client behavior are unchanged. Default offline regression includes
`test/membership-rejoin.test.js`.

Removal/rejoin runtime activation: DISABLED. Rules runtime, cloud and Android:
NOT VERIFIED. Firebase Emulator: NOT RUN. Client generation preconditions,
session/cache revocation and full activation review remain outstanding.

## D3B.1C implemented removal foundation

`functions/src/membership-removal.js` implements `removeStaffMember` over the
existing transaction adapter. `functions/src/index.js` registers the callable in
`asia-southeast1` with `enabled: false`. The disabled handler rejects before account
lookup or transaction work; no environment flag enables it. Activation requires
separate source review after full lifecycle and client revocation acceptance.
Offline tests inject an enabled handler and fake account/store dependencies only.

Request fields are exactly `targetUid`, `expectedCafeId`, `expectedGeneration`,
`expectedActorGeneration`, `idempotencyKey`. UID comes from trusted Auth, never
request data. Expected cafe/generations are preconditions against server-derived
authority. The handler requires verified token and fresh matching verified,
non-disabled account; owner mapping/member and active cafe ownership are rechecked
inside the transaction before receipt handling. Legacy active pairs use generation 0.

All reads precede writes. An initial removal requires an active matching Staff
pair in that cafe and expected generation. Self/Owner/foreign removal, malformed
links, stale generations and generation overflow deny. A single transaction:

- Updates `user_cafe_memberships/{targetUid}` and
  `cafes/{cafeId}/members/{targetUid}` to inactive, increments generation once,
  and records authenticated `removedBy`, server `removedAt`/`updatedAt` and event ID.
- Creates `cafes/{cafeId}/membership_events/remove_{requestHash}` with immutable
  pre-transition mapping/member snapshots, actor/target, generations, hashes and time.
- Creates `cafes/{cafeId}/membership_requests/{requestHash}` with matching receipt.

The request hash covers actor/cafe/key; the payload hash covers all parsed request
fields in stable order. Same key and payload acknowledges historical completion
with `changed: false`, without touching the target's later episode. The response
is NOT a statement that the target is currently inactive. Different payloads
conflict; different-key repeated removal fails on the inactive links. Missing or
inconsistent event/receipt pairs fail closed. Audits are create-only, outside the
strict inventory activity collection. No deletion, reactivation or migration exists.

Existing Rules deny these new paths through the catch-all and deny membership
client writes. Rules runtime, deployed protections and Android/client revocation
remain NOT VERIFIED. Offline models show commit-order behavior, not SDK runtime
certification. Existing redemption still rejects every canonical tombstone.

Run `node --test test/membership-removal.test.js` or `npm.cmd test` from `functions/`.
Both are offline; never run Firebase Emulator for this batch.

## D3B.1A active membership generation contract

`functions/src/membership-generation.js` exports the pure validator
`activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid)`.
It returns the validated generation (including zero) or `null` to deny. Callers
must compare against `null`, never use truthiness. It performs no reads or writes.

- Both documents must be active schema-version-1 links for exactly the same UID
  and cafe. The member role must be owner/staff and agree with the cafe owner UID.
- When BOTH documents lack their own `membershipGeneration` field, the active
  pair is legacy generation 0. No field is materialized or persisted.
- When BOTH fields exist, each must be a nonnegative JavaScript safe integer
  (`0` through `Number.MAX_SAFE_INTEGER`) and they must match.
- A one-sided field is denied even if it is explicit zero. Null, undefined,
  strings, negatives, fractions, nonfinite and unsafe values are denied. An
  explicit undefined field is not an absent field.
- Missing, inactive, cross-cafe, role-conflicting or schema-invalid links deny.
  This helper never validates inactive history for reactivation.

Existing backend authorization checks apply it to actor and owner pairs in
inventory create/update/stock/archive, menu, team context and roster candidates,
invitation owner authorization and existing-owner workspace retries. Existing
cafe/owner validation and transaction read boundaries remain in their callers.
This is pair validation, not an authority source or complete workspace resolver.

Creation and first invitation redemption still write the original legacy link
shape with no generation field. Tombstones still block both creation and joining.
There are no new collections, generation writes, transitions or request fields.
`schemaVersion: 1` is preserved. Rules, Flutter resolver/session and local AI
tooling are unchanged and do not yet enforce generation consistency. Therefore
this batch does NOT establish end-to-end generation enforcement or stale-request
protection; lifecycle activation remains blocked pending those later batches.

Run the focused offline coverage explicitly from `functions/`:

```powershell
node --test test/membership-generation.test.js
```

The existing `npm test` list is unchanged; run this focused file separately.

## D3A boundary

Workspace creation now requires the trusted callable Auth claim
`email_verified === true`, including identical retries. A stale unverified token
must be refreshed after email verification. Request data cannot grant verification.
`functions/src/index.js` passes `request.auth` directly to the domain operation.
This is a token-claim check, not a fresh Admin Auth account lookup.

Creation and invitation redemption share the transaction read/create boundary
`user_cafe_memberships/{uid}`. Creation atomically creates that mapping, the cafe
and its owner member. Redemption atomically creates the mapping and staff member
and consumes the invitation. A competing commit must cause a retry, which then
rejects the existing mapping. Same-payload owner creation may return the existing
workspace; changed-payload creation rejects. Any existing mapping, including an
inactive or malformed one, blocks new membership today. Redemption admission
counters commit separately even when redemption fails.

The local Rules draft and resolver require active, schema-valid mapping/member,
cafe and owner links; user profile role is not authority. No single-workspace
guarantee is asserted for orphaned historical records outside canonical links.
Admin SDK bypasses Rules; deployment review must account for all privileged writers.
Offline optimistic conflict tests verify domain behavior, not the deployed SDK.

## Why removal/rejoin is a separate batch

The current resolver treats inactive mappings as inconsistent membership. There
is no trusted removal workflow or defined membership generation for retried
operations after a remove/rejoin cycle. Allowing redemption to overwrite inactive
records now would change historical semantics without audit and retry safeguards.
D3A therefore preserves the existing rejection behavior and all historical data.

## Proposed D3B contract and affected paths

- `user_cafe_memberships/{uid}`: retain the canonical document on removal as an
  inactive tombstone; do not delete it. Add a monotonically increasing membership
  generation to distinguish membership episodes. Only validated inactive STAFF
  tombstones may become eligible for a new staff invitation. Inactive owners and
  unknown/malformed legacy records remain blocked pending separate disposition.
- `cafes/{cafeId}/members/{uid}`: deactivate the matching staff member atomically
  with the mapping, recording server `removedAt` and authenticated `removedBy`.
  Preserve previous episodes in an append-only audit before same-cafe reactivation.
- `cafes/{cafeId}/activities/{eventId}` and proposed
  `cafes/{cafeId}/membership_requests/{requestId}`: atomic lifecycle audit and
  idempotency receipt, bound to actor, target, action, payload and generation.
  Client writes remain denied. Receipt IDs must avoid cross-workspace collision.
- `workspace_invitations/{id}`: retain email-bound, expiring, staff-only tokens.
  Require invitations used for rejoin to be issued after the removal event; old
  pending invitations must not undo removal. Preserve admission limits and replay
  rejection. Trusted timestamp/episode checks must define equal-time ordering.

### Removal transaction

Derive actor from trusted Auth; revalidate active owner mapping, owner member and
cafe links. Require target to be a different account, active staff in that same
cafe, with matching canonical mapping and expected generation. Reject staff
actors, self/owner removal, cross-cafe targets, inactive or malformed links.
Read receipt and every authority document before writes. Atomically deactivate
both links, increment generation and write audit/receipt with server time/actor.
Unchanged retries return the prior result only while their generation remains
applicable; payload conflicts fail. A stale retry must never remove a rejoined
member. Existing inventory and movement history must remain untouched.

### Rejoin transaction

Require verified email and existing fresh-account checks. Revalidate invitation,
target owner/cafe and canonical mapping inside the transaction. Accept either no
prior mapping or a schema-valid inactive staff episode with its old member link
also inactive and consistent. Reject active owner/staff mappings, orphaned links,
ambiguous schema, inactive owners and forged authority. For same-cafe rejoin,
archive the previous episode in append-only audit before updating the member;
for another cafe retain the old inactive member. Advance the generation, replace
the canonical target, activate the new staff episode, consume invitation and
write audit/receipt atomically. No historical record is silently overwritten.
Creation continues to reject inactive tombstones; no implicit staff-to-owner
conversion is proposed.

## Access revocation and compatibility

After removal commits, new server reads/callables must fail through active-link
checks even with a previously issued token. Rules and every Admin operation must
retain these checks. Token revocation alone is insufficient. Already downloaded
offline data cannot be recalled: D3B must define resolver/session invalidation,
listener teardown, navigation and in-memory/persisted cache handling. Do not claim
instant removal of data already on a device or rollback of prior committed work.

Generation fields affect mutation receipts and strict schema validation. D3B must
review inventory/menu retry compatibility and define an explicit legacy policy
before implementation; absent/unknown generations must not silently reactivate
historical records. No existing-data migration is included here. Rules, resolver
and UI changes require a separately reviewed file plan.

## Required D3B acceptance

Offline tests must cover owner-only removal; no owner/self/cross-cafe removal;
atomic failures; inactive access; same/other-cafe rejoin; verified email; old and
revoked invitations; duplicate removal; payload conflicts; stale retries after
rejoin; concurrent remove/join/create; competing invitations; corrupt links and
audit preservation. Test both winners at forced transaction barriers. Client
session/cache revocation and Rules/SDK transaction behavior need separate evidence;
this document does not establish runtime or deployed acceptance.

Existing `functions/test/workspace-emulator.integration.test.js` provisions an
unverified owner and requests new `Cloud Kitchen` creation. That older fixture
is incompatible with current verified-email and three-business-type policy.
It was not changed or run in D3A; do not cite its historical results as current
acceptance. Any later integration verification must review it in separate scope.

GO for D3B design review. NO-GO for activation, live mutations or deployment.

## D3A local verification

From `functions/`:

```powershell
node --test test/workspace-creation.test.js test/workspace-invitations.test.js test/single-workspace-security.test.js test/team-members.test.js
npm.cmd test
```

Focused result: 62 passed, zero failed/skipped. Existing backend regression
result: 108 passed, zero failed/skipped. The commands overlap in workspace-creation
coverage; counts must not be added as unique tests. The focused file is explicitly
invoked above and is not included in the existing `npm test` file list. No emulator,
Rules runtime, manual client or live cloud verification was performed.
