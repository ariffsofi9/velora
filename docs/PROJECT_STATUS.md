# VELORA project status

Repository inspection date: **2026-11-02 (Asia/Kuala_Lumpur)**. This is a source/history snapshot, not production certification.

## Checkpoint

- Branch: `main`.
- HEAD: `03e853ad54960e022568d3e8647d34f73ff06d18` (`03e853a`), `fix: improve inventory integrity and expiry consistency` (Phase 2.4C).
- Locally recorded `origin/main` matches HEAD; no remote fetch was performed.
- Working tree was clean before this documentation task. Current next phase: **2.4D**, not started by this task.

## Implemented in source

### Workspace and trusted backend

Firebase Auth feeds `WorkspaceGate` and a read-only transactional resolver. Missing membership routes to business setup; invalid or unavailable membership fails closed. `createWorkspace` atomically creates cafe, owner membership and account-to-cafe mapping, with verified retry behavior. Mapping, member, cafe and owner consistency determine access; a personal profile role is not authority. Owner and staff inventory operations are supported for valid memberships.

Four callable exports in `functions/src/index.js` run in `asia-southeast1`: `createWorkspace`, `createInventoryItem`, `updateInventoryItem`, `adjustInventoryStock`. Backend transactions derive the actor from Auth and resolve the cafe server-side rather than accepting client authority fields.

### Inventory and stock

- Scoped reads use `cafes/{cafeId}/inventory`. Home passes a verified session/repository to Inventory, Dashboard, Alerts and AI Insights.
- Add Item supports name, category, integer quantity, unit and expiry date through the create callable. Creation atomically writes the item, an `initial_stock` movement and an activity event, with request/payload-based idempotency.
- Item Details supports metadata editing, Stock In, Stock Out and Stock History. Metadata updates reject quantity changes, check expected version and atomically record activity, including no-op outcomes.
- Stock adjustments require positive safe-integer amounts, reject insufficient stock/overflow and stale versions, and atomically update quantity/version plus movement and activity. Unchanged retries reuse idempotency keys; conflicting payloads are rejected. The UI provides explicit Confirm Stock In/Out submission, prevents duplicate submission and provides stale-stock reload handling.
- Stock History is read-only and item/cafe scoped. It validates movement data and arithmetic, orders newest first, pages 20 records using document cursors, and supports loading, empty, retry and load-more error states. The emulator index draft includes `itemId` plus descending `createdAt` for movements.
- Low-stock presentation currently uses the shared fallback threshold **quantity <= 5**.

History evidence: `b956b00` introduced secure cafe inventory operations; `9fa2456` fixed stock confirmation; `f1606b2` added Stock History; `531ce1d` hardened history validation/pagination. This does not imply secure deletion/archive is implemented.

### Phase 2.4B: containment (`d5308c8`)

Removed legacy Cook Now stock mutation paths. The older `CookNowService` throws before mutation; `CookNowDeductionService.isSupported` is false and returns an unavailable result. Recipe detail handling guards the workflow. Containment tests cover these entry points.

### Phase 2.4C: inventory integrity (`03e853a`)

- Strict required-field/schema parsing replaces fabricated defaults for malformed inventory; repository parsing failures become safe errors. Supported absent legacy unit/version fields default to `pcs`/`1`; schema version may be absent, but unsupported explicit versions fail.
- Firestore expiry timestamps preserve canonical UTC date components. Shared calendar-day classification/labels apply across Inventory, Dashboard, Alerts and relevant suggestion helpers: near expiry is **today through day 3 inclusive**, excluding expired items.
- Add Item photo and purchase-price inputs were removed because they were not supported by that UI's create workflow.
- Added integrity and safe-error tests and updated presentation fixtures/expectations.

## Verification record

| Evidence | Status as of 2026-11-02 |
| --- | --- |
| Phase 2.4C automated result | **303 passed, 5 skipped, 0 failed**, based on the previous Codex report, as confirmed by the user. Not rerun during documentation setup. Original execution date, exact command and full output were not independently checked in this task. Do not extend this result to backend/rules/integration suites. |
| Test source inspected | Flutter workspace, inventory, stock/history, integrity, AI-scoping and Cook Now containment coverage; backend unit, rules and callable emulator integration tests exist. Five visual test files have opt-in screenshot skip flags; the historical skip reasons were not independently verified. |
| Phase 2.4C manual Chrome acceptance | **User-reported PASS** across all eight previously agreed checklist sections: Inventory; Near Expiry; Dashboard & Alerts; AI Insights; Item Details; Add Item; Stock In/Out; Reload. The user confirms this was reported before commit `03e853a`. Codex did not independently verify the browser results during documentation setup. |
| Documentation checks | Run `git diff --check` and inspect final status for this task; no app or emulator execution required. |

## Limits, risks and review gaps

- AI Insights displays scoped near-expiry items (up to four) and local restock suggestions. AI generation, quota, cache and saved recipes remain unavailable; secure Recipe Details and Cook Now deduction are not complete.
- Inventory list search is case-insensitive **prefix** search on name/category, with All Items/Low Stock/Near Expiry filters and fixed expiry ordering. Contains-search, a dedicated category filter, user-selectable sorting and list error retry are Phase 2.4D work; current list errors show a generic message.
- Backend cafe activity events exist, but a secure cafe activity feed is not implemented. Legacy `ActivityService` still targets global `activities`; do not treat it as a scoped feed. Archive/delete lifecycle, invitations, member removal and ownership transfer are not implemented secure backend workflows.
- `docs/firebase/workspace.firestore.rules` is an emulator-wired deny-by-default draft: members can read scoped inventory/movements, client writes are denied, and ungranted paths (including activities/AI and legacy global collections) are denied. `firebase.json` configures Functions but no Firestore deployment. **Production Firebase deployment state is unverified**: deployed rules, indexes, Functions and production state were not inspected. Do not assume deployed code matches the repository.
- Emulator ports: Auth 9099, Firestore 8080, Functions 5001, UI 4000. Flutter needs `USE_FIREBASE_EMULATORS=true`; `.vscode/launch.json` omits this flag. Without it the app uses its configured Firebase target. Never assume an IDE Chrome launch is isolated.
- Rules tests call `clearFirestore()` before each test; integration tests create emulator records. Neither may run against working emulator data. No emulator suites were run for this task.
- README is Flutter boilerplate. Older foundation documentation may contain stale claims: `docs/firebase/workspace-foundation.md` and the resolver's integration comment contain historical claims contradicted by current routing, rules and indexes. Treat the current implementation and verified Git history as authoritative for repository status; preserve the older document as historical context pending a separate update.
- User-reported Chrome acceptance does not establish production readiness or independently verify complete auth-token/revocation UI lifecycle behavior. Deployment status and that lifecycle behavior require separate verification. Do not migrate/repair legacy ownership from this snapshot.
