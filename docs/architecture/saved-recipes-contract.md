# P6.6E1 - Canonical Saved Recipes contract

Status: **PROPOSED DOMAIN CONTRACT; NOT IMPLEMENTED; NO ACTIVATION AUTHORIZATION.**
Date: 2026-11-12 (Asia/Kuala_Lumpur). Scope: ADD this document only.

## 1. Scope and evidence

This contract specifies a cafe-shared library of immutable recipe-content snapshots with Owner-managed archive/restore. Firestore is the sole authoritative business database. It creates no records, routes, Rules, indexes, packages or runtime wiring.

Current source has validated `SecureAiRecipe` results and read-only `RecipePresentationDetails`. `functions/backend/application.mjs` declares AI issue/generate and independent Menu routes, but no saved-recipe routes. `functions/src/secure-groq-handler.js` returns recipe bodies without retaining them. AI tickets and usage receipts are not recoverable recipe records. Legacy `lib/logic/ai_recipe_save_service.dart` accesses global `ai_recipe_suggestions` directly; it and legacy cache/quota paths MUST remain disconnected.

Reference patterns, not equivalent implementations:

- `functions/src/menu-service.js`: transactionally resolved workspace authority, version checks and atomic receipts.
- `functions/src/mutation-episode.js` and `membership-generation.js`: client expectations and active-pair validation.
- `functions/src/inventory-recovery.js`: historically bound read-only observation; missing evidence is not noncommit.
- `functions/src/workspace-invitations.js`: invitation-specific receipts/reconciliation, not a generic recipe service.
- `functions/https/authenticated-json-http.mjs`: injected verified identity and bounded JSON admission.
- `functions/backend/firestore-store.mjs`: explicit transaction/query capabilities and uncertain-commit classification.
- `docs/architecture/shared-backend-activation-gates.md`: offline evidence versus live gates. Its older platform-storage proposals do not override the current SQLite pause.

The preceding inspection reported 294 Flutter and 603 Node tests passing offline. Those are historical inspection results, not tests executed by this documentation milestone or acceptance of a Saved Recipes implementation.

## 2. Library ownership and permission matrix

Every record belongs to one verified cafe, shared by that cafe's active members. Creator attribution does not create personal ownership, private bookmarks or extra permissions.

| Operation | Active Owner | Active Staff | Outsider, revoked or invalid membership |
| --- | --- | --- | --- |
| List/get active or archived recipes | Allow | Allow | Deny |
| Save a validated snapshot, including duplicate save | Allow | Allow | Deny |
| Archive/restore | Allow | Deny | Deny |
| Edit saved content or hard delete | Unsupported | Unsupported | Deny |

These are future enforcement requirements, not claims about deployed protections. Archived records remain readable; Staff cannot restore one by saving its content again. No operation changes inventory, movements, stock, Menu, AI quota or Cook Now.

## 3. Verified identity, workspace and project authority

Every route MUST use the existing trusted Firebase verifier for token signature, issuer/audience, expiry, intended project, verified email, current account disabled/revoked status and UID consistency. The configured verifier/store project MUST match. Initial HTTP composition is TEST-only (`velora-spark-test`); production `velora-73222` must not be an implicit fallback. There is no client-selected project or credential.

Inside each domain transaction, derive UID from verified Auth and cafe from `user_cafe_memberships/{uid}`. Read and validate the active, schema-valid mapping, `cafes/{cafeId}`, actor membership, owner membership and owner mapping. Validate Owner-role/owner-UID consistency and both membership generations with the existing active-pair contract. Absent generations are legacy zero only when both corresponding links omit the field; partial upgrades fail closed.

All save/get/list/lifecycle/reconcile requests require `expectedCafeId` and `expectedMembershipGeneration`. Compare them with resolved authority; mismatch aborts. They are preconditions, never authority. Ignore no unknown fields: reject client actor/role/project selectors, document paths, digests, versions or timestamps outside the exact request schemas below. Owner-only lifecycle permission is checked transactionally even for receipt replay.

Account freshness checks remain outside retryable Firestore callbacks and are repeated at the established transaction-dispatch boundary. Transaction callbacks perform no provider/network/account lookup. Firebase Auth revocation and Firestore commits are separate systems; this contract does not promise instantaneous atomic revocation across them.

## 4. Immutable content and validation

`recipe` has exactly these required fields; no omitted-field defaults or additional fields:

| Field | Required validation |
| --- | --- |
| `title` | Nonempty string, at most 100 UTF-16 code units |
| `ingredients` | Ordered array, 1-10 entries, unique `itemId` values |
| Each ingredient | Exactly `{itemId, quantity, unit}` |
| `itemId` | String, 1-128 UTF-16 code units; trimmed; not `.` or `..`; no slash, backslash or Unicode control characters |
| `quantity` | JSON number represented as finite IEEE-754 binary64; `0 < quantity <= 1000000`; integer-valued for `pcs` |
| `unit` | Exactly one of `kg`, `g`, `L`, `ml`, `pcs` |
| `steps` | Ordered array, 1-8 nonempty strings, each at most 300 UTF-16 code units |
| `whyRecommended` | Nonempty string, at most 300 UTF-16 code units |

All strings MUST contain valid Unicode scalar sequences: reject unpaired surrogates. Content text must already be trimmed and contain no Unicode control characters; reject rather than silently rewriting it. Preserve interior whitespace, case, Unicode normalization form and array ordering. Do not sort/deduplicate ingredient or step arrays, round quantities, convert units or coerce numeric strings. JSON numeric spellings such as `1` and `1.0` denote the same canonical value. Original provider lexical decimal formatting is not available from the existing binary64 model; do not claim to preserve it.

The compact JSON content object in the field order above MUST be at most 16384 UTF-8 bytes. Whole requests MUST be at most 32768 UTF-8 bytes, including envelopes. The canonical JSON wire representation of a complete stored record MUST be at most 32768 bytes, using ISO timestamps for this size check. Validate both individual field limits and aggregate limits. Oversized or malformed stored records fail closed, including pagination look-ahead records.

No ingredient names, preparation, servings, timings, images, stock availability or consumption instructions are inferred. Ingredient IDs are historical references within the resolved cafe, not evidence that inventory still exists or has adequate stock. Saving never requires or authorizes stock deduction. At this stage missing/archived inventory references do not prevent preserving an otherwise valid snapshot. Future availability checks must be explicit, separately authorized reads and must not alter saved content.

## 5. Provenance and attribution

The initial source is always server-assigned `workspace-submitted`, with evidence `unverified-attribution`. Schema validation proves content shape, not AI/provider origin.

The request's required `attribution` object has exactly `kind`, `provider`, `ticketId`:

- `kind`: `unspecified`, `claimed-ai`, `sample` or `mock`.
- `provider`: `null` or `groq`; a non-null value is allowed only for `claimed-ai`.
- `ticketId`: `null` or 64 lowercase hexadecimal characters; non-null only for `claimed-ai`.
- All three fields are required, including explicit nulls. `unspecified`, `sample` and `mock` require both remaining fields to be null.

Store this as submitted attribution, never as trusted proof. A supplied ticket ID does not prove which recipe body was returned, and checking a completed quota receipt does not fix that. Source metadata cannot assign another actor, claim server timestamps or assert `verified=true`.

Future explicit saves may preserve sample/mock snapshots with those labels; never silently relabel them as generated content. No automatic saving of samples, mocks or generated results. Until save UI is separately approved, existing sample/mock controls remain unchanged. Display `Workspace-submitted recipe; AI origin not verified` for unspecified/claimed-AI content, and retain an explicit sample/mock label for the corresponding attribution.

First accepted attribution remains attached to the record. A later duplicate save with different attribution does not overwrite it. The duplicate acknowledgement refers to the existing shared record, not a new attribution claim.

Future alternative, NOT an E1 requirement: retain validated generated bodies server-side, bind result IDs/digests to authenticated project/cafe/actor/generation and save by that server reference. This requires separate schema, retention/privacy, AI completion/uncertainty and route approval. Do not retrofit that guarantee onto client-submitted snapshots.

## 6. Canonical serialization and deterministic content identity

All hashes are server-recomputed lowercase hexadecimal SHA-256 over UTF-8 bytes. Clients may compute previews, but API requests accept no authoritative digest.

Define `J(value)` as ECMAScript `JSON.stringify` on the validated fixed-position arrays below, no replacer, indentation, BOM or trailing newline. Numbers use ECMAScript's finite binary64 JSON serialization, including exponent notation where applicable; strings use JSON escaping. No Unicode normalization or sorting is performed. Backend tests MUST include shared golden byte/digest vectors for decimals, exponent-form numbers, Unicode, escaping and array ordering. Flutter cannot substitute its default JSON numeric formatting for this server contract when verifying recovery evidence.

Let `I = recipe.ingredients.map(i => [i.itemId, i.quantity, i.unit])`.

```text
C = ["velora.saved-recipe.content.v1", title, I, steps, whyRecommended]
contentDigest = SHA256(J(C))
recipeId = "recipe_" + SHA256(J([
  "velora.saved-recipe.id.v1", trustedProjectId, resolvedCafeId, contentDigest
]))
```

Exactly title, ordered ingredient IDs/quantities/units, ordered steps and recommendation participate in content identity. Attribution, actor, request key, timestamps and lifecycle state do not. Consequently changing recommendation or order creates different content; changing only attribution does not. Identical content in different cafes or projects has different IDs.

On an existing `recipeId`, validate the entire stored record and compare both digest and canonical content bytes. Any inconsistency/collision fails `failed-precondition`; do not overwrite it or quietly generate another ID.

## 7. Proposed Firestore documents

These paths and schemas are proposals only; no database changes occur in E1.

`cafes/{cafeId}/saved_recipes/{recipeId}` has exactly:

```text
schemaVersion: 1
projectId: trustedProjectId
cafeId: resolvedCafeId
recipeId: deterministic ID matching the document path
contentDigest: server-computed digest
recipe: validated immutable object from section 4
source: "workspace-submitted"
provenanceEvidence: "unverified-attribution"
submittedAttribution: validated attribution from the first accepted save
createdBy, updatedBy: server-derived UIDs
createdAt, updatedAt: server timestamps
version: positive safe integer
isArchived: boolean
archivedBy: UID or null
archivedAt: server timestamp or null
```

Initial version is 1, active, with null archive fields. Archive sets both archive fields; restore sets both to null. Validate active/null and archived/non-null consistency, valid UID metadata and finite timestamps with updatedAt not earlier than createdAt. An archived record's archivedAt equals its latest updatedAt and archivedBy equals updatedBy. Content, initial provenance and creation attribution never change. Only approved lifecycle fields, version, updatedBy and updatedAt may change. No content-edit endpoint exists.

Private receipts live at `cafes/{cafeId}/saved_recipe_requests/{requestHash}`. Receipt fields are exactly `schemaVersion`, `projectId`, `cafeId`, `actorUid`, `actorGeneration`, `requestHash`, `payloadHash`, `operation`, `recipeId`, `contentDigest`, `resultVersion`, `resultIsArchived`, `outcome`, `changed`, `createdAt`. Version is 1; identity fields are server-derived; result fields record the historical outcome below. Receipts are immutable and written only by the trusted backend.

Every document parser must verify scope, schema, field sets, IDs, digest/content agreement, metadata types and sizes. Native storage uses Firestore timestamps; JSON responses use canonical UTC ISO-8601 strings. Never default malformed persisted fields into plausible recipes.

## 8. Proposed API and strict envelopes

All operations use the existing authenticated POST-JSON pattern with `cache-control: no-store`. Routes are NOT currently implemented. Trusted E4 composition must configure a 32768-byte request limit explicitly: the shared HTTP helper's current 2048-byte default cannot carry this contract. Responses are bounded at 65536 UTF-8 bytes. No redirects, callable fallback, automatic mutation retry or live defaults.

Let `E` mean the two required expectation fields from section 3. Each request has exactly the following fields:

| Proposed route | Request fields in addition to E | Success result |
| --- | --- | --- |
| `/recipes/save` | `idempotencyKey`, `recipe`, `attribution` | Mutation acknowledgement |
| `/recipes/get` | `recipeId` | `{schemaVersion:1, cafeId, item:<complete record>}` |
| `/recipes/list` | `mode`, `limit`, `cursor` | `{schemaVersion:1, cafeId, items:<summaries>, nextCursor}` |
| `/recipes/lifecycle` | `idempotencyKey`, `recipeId`, `expectedVersion`, `action` | Mutation acknowledgement |
| `/recipes/reconcile` | `operation`, `request` instead of top-level E | Observation result; `request` is the exact original save/lifecycle request including E |

`action` is `archive` or `restore`. `mode` is `active`, `archived` or `all`. `limit` is an integer 1-20. `cursor` is null or the exact object in section 10. These fields are required; no pagination defaults. `recipeId` must match `recipe_[0-9a-f]{64}`. `expectedVersion` is a positive safe integer. `idempotencyKey` is 16-128 characters matching `[A-Za-z0-9_-]+`, generated once per explicit operation intent.

The reconcile envelope has exactly `{operation, request}`; `operation` is `save` or `lifecycle`. It performs no writes, ticket issuance or provider work. No caller-supplied receipt path, actor or receipt hash is accepted.

A mutation acknowledgement has exactly `schemaVersion:1`, `cafeId`, `recipeId`, `contentDigest`, `version`, `isArchived`, `outcome`, `changed`, `replayed`, `requestHash`, `payloadHash`. `outcome` is `created`, `existing-active`, `existing-archived`, `archived` or `restored`. `changed` describes the original operation's recipe mutation; `replayed` separately identifies delivery of an existing receipt. A replay MUST NOT rewrite historical `changed=true` to false or present the historical version as current state.

Errors are sanitized: `unauthenticated` 401; `permission-denied` 403; `invalid-argument` 400; `not-found` 404 for an authorized absent recipe; `already-exists` 409 for request-key conflict; `aborted` 409 for episode/version mismatch; `failed-precondition` 409 for stored corruption, invalid lifecycle or version overflow; `resource-exhausted` 429; `unavailable` 503. Oversized HTTP input is 413. Store failures that may follow commit remain explicitly `outcome-unknown`; a generic 5xx/timeout cannot imply rejection. Never expose raw Firestore, provider, token or internal receipt data in errors. Wrong-scope reads must not disclose another cafe's record existence.

## 9. Save, lifecycle, replay and reconciliation transactions

Use the transaction's trusted project and resolved authority, not client values, when computing:

```text
requestHash = SHA256(J([
  "velora.saved-recipe.request.v1", trustedProjectId,
  actorUid, resolvedCafeId, idempotencyKey
]))
save payload tuple = ["save", expectedCafeId, expectedMembershipGeneration,
                     contentDigest, attribution.kind,
                     attribution.provider, attribution.ticketId]
lifecycle payload tuple = ["lifecycle", expectedCafeId,
                          expectedMembershipGeneration, recipeId,
                          expectedVersion, action]
payloadHash = SHA256(J(["velora.saved-recipe.payload.v1", payload tuple]))
```

The receipt key excludes generation/operation so reusing a key for changed intent conflicts; the payload digest and receipt bind both. Different actors may use the same key without sharing a receipt. Trusted project binding prevents cross-project evidence reuse.

Processing order, inside a transaction with all reads before writes:

1. Validate resolved authority and E, including Owner permission for lifecycle.
2. Read the derived receipt and target recipe. Validate any existing data.
3. If receipt exists, require exact actor/project/cafe/generation/operation/hash/target consistency and valid historical result. Return that original outcome with `replayed=true`, without writing. Do not apply today's version precondition to a historical successful replay. Current authorization/E still apply.
4. A conflicting bound receipt returns `already-exists`; malformed evidence fails closed. Never replace a receipt or dispatch changed payload under its key.
5. Without a receipt, execute exactly one of the transitions below, then atomically create its receipt. No partial recipe-only or receipt-only commit is valid.

| New request | Recipe transition | Receipt outcome / changed |
| --- | --- | --- |
| Save absent content | Create active v1 with trusted identity/time | `created` / true |
| Save existing active content | No recipe/attribution/version update | `existing-active` / false |
| Save existing archived content | No recipe change; never implicitly restore | `existing-archived` / false |
| Owner archive active record at expected version | Set archived fields; increment version once | `archived` / true |
| Owner restore archived record at expected version | Null archived fields; increment version once | `restored` / true |

For new lifecycle requests, check exact current version before transition; same-state requests fail `failed-precondition` and create no receipt. Reject safe-integer version overflow. Two concurrent lifecycle requests from one version cannot both mutate it. Concurrent identical saves produce one content record, with a separate correctly bound receipt for each accepted request. Transaction contention may retry only under the existing store's definite-abort policy; never rerun an uncertain commit as a new operation.

Receipt validation must enforce the table's outcome/changed/state combinations: created is active v1; existing outcomes have changed=false and their corresponding active/archived state; archived/restored have changed=true, the action's target state and resultVersion exactly original expectedVersion + 1. Reject operation/outcome disagreement or invalid integers/timestamps. A receipt's createdAt is its transaction's server time, not a client time; later recipe updates must not be confused with that historical timestamp.

Receipts for duplicates are still required: duplicate content is not idempotent request replay. Failed validation/authorization/conflict creates no recipe or receipt. No separate activity event is added by this initial contract; private immutable operation receipts provide operation evidence. A public activity-feed extension requires separate approval.

Read-only reconcile reauthorizes the current actor against the original E and reconstructs both hashes from the full original request. For lifecycle, retain Owner-only authorization. Read the receipt and target recipe in one transaction:

- Valid matching receipt plus matching immutable recipe identity/content proves `committed`; return its original acknowledgement with `replayed=true`.
- Later legitimate lifecycle changes do not invalidate historical success: verify the current version is at least the receipt's resultVersion, but do not demand its current lifecycle equals the receipt's historical resultIsArchived.
- A conflicting receipt reports conflict, never someone else's result.
- No receipt reports `unknown`, even if equivalent content exists. That content may have been saved by another request.
- Missing/malformed target or malformed receipt, unavailable reads, revoked membership and changed generation do not prove noncommit. Return a safe failure/unknown, not permission to resend.

Observation result shape is `{schemaVersion:1, status:"committed", result:<acknowledgement>}` or `{schemaVersion:1, status:"unknown"}`. There is no initial `definitely-not-committed` result. No cleanup, TTL, receipt deletion or hard deletion is authorized. Any future retention policy must preserve reconciliation guarantees and prevent request-key reuse after evidence expires.

## 10. Scoped list, cursors, summaries and index proposals

Use only the resolved cafe's `saved_recipes` collection. Order by document ID (`__name__`) ascending, not creation time. This is deterministic content-ID order, not newest-first. Apply `isArchived == false` for active, `true` for archived, and no lifecycle filter for all. Fetch `limit + 1` (at most 21), validate every returned complete record including look-ahead, publish at most limit summaries. If more exist, cursor after the last published record, not the look-ahead record.

A summary has exactly `recipeId`, `title`, `source`, `provenanceEvidence`, `submittedAttribution`, `version`, `isArchived`, `createdAt`, `updatedAt`. Get returns full content; list must not return all bodies. Bound the serialized page to 65536 bytes; fail rather than silently truncate a record or change pagination.

Cursor is exactly `{schemaVersion:1, projectId, cafeId, uid, membershipGeneration, mode, limit, afterId}`. All scope fields must equal current trusted project/resolved actor/E/query; validate `afterId` as a recipe ID. The adapter constructs the fully qualified document reference under the resolved parent. Reject foreign-project/cafe/actor/generation/query cursors, nested paths, duplicate/unsorted/over-limit/foreign rows and invalid look-ahead records.

Cursors are untrusted positioning hints, not authorization tokens. Fabricating another syntactically valid `afterId` within an already authorized query grants no additional read scope. No signing secret is needed for this v1 semantics. They are not reusable across Flutter session identity changes even when server-visible fields match: the client repository must bind each cursor to its captured `WorkspaceSession` object and discard it on replacement.

Pages are fresh authorized reads, not a cross-page snapshot. Concurrent saves or lifecycle changes may affect subsequent pages; client deduplicates IDs, offers explicit refresh and does not claim an exhaustive stable snapshot. Empty is successful authorized absence; malformed/error data must not become an empty list.

Proposed query support: unfiltered ID order, plus filtered `isArchived` equality with ID ascending. `functions/backend/firestore-store.mjs` currently exposes bounded members/inventory/menu queries, not `savedRecipes`; E3 must add an explicit scoped query capability. Do not expose arbitrary collection names/filters from clients.

Repository index draft currently contains an inventory-movement index only. Candidate recipe index, if required by native query qualification: COLLECTION scope `saved_recipes`, `isArchived ASC`, `__name__ ASC`; Firestore's implicit document-name ordering and available automatic indexes must be checked before selecting an explicit manifest. No createdAt ordering/composite is part of v1. Index deployment and real TEST query acceptance are later gates, not E1 claims. Offline E2/E3 can proceed against the specified query contract without pretending to verify native index availability.

## 11. Client UI, session lifecycle and mutation recovery

Future UI entry: Saved Recipes in Discover; explicit Save Recipe on eligible recipe details. Display the shared-library nature, accurate attribution, existing archived-duplicate feedback and Owner-only archive/restore. Read-only details reuse `RecipePresentationDetails`; stored snapshots do not imply current stock eligibility. Include loading, authorized empty, sanitized error, explicit read Retry, bounded load-more and back/cancel behavior at mobile/tablet widths and enlarged text.

List/get/retry/cursors/details must capture project, UID, cafe, membership generation and exact local session identity. Cancel old subscriptions, suppress late responses and clear rows/cursors/child state before publishing replacement data. Recheck context before actions and results. Preserve the existing workspace boundary's verified logout/revocation route removal; `isActive` alone is not a notification mechanism. Open stored-recipe details need the same active lifecycle guards as secure generated details.

Cancellation before dispatch must not write. After dispatch, closing a dialog, logout, timeout or client cancellation does not cancel or roll back a committed server operation. Hide old-context results without deleting unresolved operation evidence. Do not adopt new generations, update expectedVersion or change keys to escape uncertainty.

Live save/lifecycle controls remain disabled until an operation-specific recovery implementation can durably preserve the exact intent and key before dispatch, classify uncertain outcomes and perform read-only reconciliation. Existing inventory/invitation journals are not generic recipe journals; do not broaden their allowed operations implicitly. A restart must not reconstruct dispatch permission or auto-resend. If prior evidence is lost, report recovery unavailable rather than creating a new key. Read retry is explicit and does not issue writes; mutation resubmission is never automatic.

Once a server proves a definitive pre-dispatch rejection, the user may explicitly create a corrected intent. After any dispatch uncertainty, retain the original request for observation; successful observation resolves that request without re-executing it. Absence leaves it unresolved. Native/Web durability, storage failure/privacy and no-billing hosting remain activation gates. SQLite is paused; this contract does not select or install another database or qualify a Firebase-only recovery replacement.

## 12. Future Menu linkage, Rules and containment

Future Menu linkage should reference stable cafe-scoped recipeId plus an explicitly chosen content version/digest. Recipe content is immutable in v1; lifecycle still changes the record version. Menu linkage must define behavior for archived recipes and missing inventory, role authority and reference integrity in its own contract. No Menu schema/route changes, hard deletion, ingredient deduction, automatic cooking or availability claim are included here.

Prefer backend-mediated list/get/save/lifecycle/reconcile throughout. Client Firestore access to saved recipes and private receipts remains denied by the existing catch-all Rules. No new allow rule is needed for this backend-only design; trusted server credentials bypass Rules and therefore require full domain authorization and least-privilege IAM. A later direct-read proposal would require separate Rules approval and runtime verification. Deployed Rules/indexes have not been inspected.

No global `ai_recipe_suggestions`, legacy AI cache/quota fallback, provider keys in Flutter, direct privileged client writes, callable activation, live HTTPS activation, stock mutation, migration or backfill. Firestore remains authoritative and TEST/PRODUCTION isolated. No Blaze, billing, Functions deployment, emulator/simulator or SQLite implementation is authorized.

## 13. E2-E6 boundaries and acceptance gates

Each stage requires a new exact file approval; these are bounded proposals, not execution permission:

| Stage | Proposed files | Deliverable / gate |
| --- | --- | --- |
| E2 | ADD `functions/src/saved-recipe-model.js`, `functions/src/saved-recipe-service.js`, `functions/test/saved-recipe-service.test.js` | Pure validators, golden serialization vectors, transactional save/get/list/lifecycle/reconcile against injected fake storage. Permission, replay, duplicate, collision/corruption, concurrency and historical reconciliation tests. No HTTP/store/runtime activation. |
| E3 | MODIFY `functions/backend/firestore-store.mjs`, `functions/test/helpers/shared-firestore-rest-fake.cjs`, `functions/test/shared-firestore-store.test.mjs` | Explicit bounded savedRecipes query, scopes/filters/cursors/look-ahead, timestamps and atomic/unknown-commit evidence. Existing domain/store regressions remain passing. No live query/index claims. |
| E4 | ADD `functions/https/saved-recipes-http.mjs`, `functions/test/saved-recipes-http.test.mjs`; MODIFY `functions/backend/application.mjs`, `functions/test/shared-application.test.mjs` | Five routes, explicit project-bound identity, size limits, sanitized error/uncertainty envelopes and inert opt-in composition. No listener, credentials, deployment or enabled client. |
| E5 | ADD `lib/models/saved_recipe.dart`, `lib/repositories/workspace_saved_recipe_repository.dart`, `test/workspace_saved_recipe_repository_test.dart` | Strict stored-record/acknowledgement parsing, injected transport/reader contract, session-bound cursors and late-result rejection. No default HTTP client or write dispatch. |
| E6 | ADD `lib/screens/suggestions/saved_recipes_page.dart`, `test/saved_recipes_page_test.dart`; MODIFY `lib/screens/suggestions/suggestions_page.dart`, `test/ai_insights_scoped_test.dart` | Injected read-only list/get/detail flow, provenance, pagination, retry, accessibility/responsiveness and boundary tests. No production persistence activation. |

Separate later milestones must enumerate files for Save controls, archive/restore UI, HTTPS transport, recipe-specific durable recovery and final composition. Reuse existing detail styling without enabling legacy services. Reconcile E2-E6 dependency interfaces before each implementation; if another file is required, stop for scope approval rather than extending the table silently.

Required tests include Owner/Staff permissions; missing/unverified/wrong-project/disabled/revoked identity; foreign cafes and forged fields; generation replacement; content golden vectors; attribution spoof rejection as verified evidence; same-content/different-request and same-key/different-payload cases; concurrent saves/lifecycle; malformed receipts/records/look-ahead; unknown commit and missing evidence; read-only reconciliation; revoked sessions and open-detail removal; and absence of inventory/Menu/provider/global-collection side effects.

## 14. Resolved decisions, remaining qualifications and E1 acceptance

Resolved for v1: cafe-shared ownership; permissions in section 2; immutable validated workspace snapshots; unverified submitted attribution; field/byte limits; fixed serialization and scoped IDs; receipts distinct from content deduplication; explicit archive/restore versions; ID-ordered scope-bound pagination; backend-only access; read-only reconciliation with no absence-based resend.

No unresolved product decision prevents offline E2 implementation. Remaining qualifications are deliberately not guarantees: native Firestore query/index requirements, real transaction/IAM behavior, host admission/abuse and response-budget enforcement, durable operation-specific recovery, receipt retention/privacy policy before any cleanup, verified Firebase TEST integration and physical-device/browser acceptance. Server-retained AI provenance and Menu/Cook Now are separate future product contracts.

E1 acceptance: exactly this document added; no implementation, schema execution, Rules/index edits, migration, deployment, Git mutation or live access. Content review must check all permission rows, payload/identity distinction, historical replay semantics, absence-is-unknown behavior and stage boundaries. Stop after reporting; do not begin E2 automatically.
