# Blaze RM5 cost-control readiness audit

Date: 2026-11-06 (Asia/Kuala_Lumpur). Audit only. No resource settings implemented.

## Decision and evidence boundary

CONDITIONAL local readiness; NO-GO for billing activation or deployment in this batch.
RM5 is a monitoring target, not a guaranteed maximum invoice. Traffic, account
currency, taxes, location-specific prices and cloud settings are not established
by this offline audit, so a reliable monthly cost estimate is not possible.

Existing local evidence in `create-workspace-production-prerequisites.md` records
HTTP 200 with billingEnabled=false and billingLinked=false. The availability check
records a successful empty Functions list. These are prior inspections, not cloud
checks rerun here. Rules B deployment and anonymous denial evidence are likewise
prior evidence; authenticated Rules/query compatibility remains unverified.

Reviewed: firebase.json, functions/package.json, functions/src/index.js,
workspace-creation.js, workspace-invitations.js, inventory mutation modules,
workspace repositories, workspace_resolver.dart, workspace_session_boundary.dart,
draft indexes and existing deployment/prerequisite documentation.

## Functions controls proposed for separately reviewed implementation

Codebase `workspace`, region `asia-southeast1`, Node 22. Current callables specify
30-second timeout, but no explicit CPU, memory, scaling or concurrency controls.
There is no explicit App Check enforcement in index.js. Authentication and
membership checks limit authority; they do not prevent invocation/abuse costs.

Initial proposal applies ONLY to createWorkspace, not global defaults:

| Setting | Proposed value | Tradeoff / validation gate |
| --- | --- | --- |
| memory | 256MiB | Starting allocation, not measured sufficient; Admin SDK cold start and peak memory must be measured before rollout expansion. OOM requires review, not blind retries. |
| cpu | 1 | Explicit full CPU; avoid changing to fractional CPU without latency tests. |
| timeoutSeconds | 30 | Preserve current contract; shortening may cause ambiguous committed results on cold start or contention. |
| minInstances | 0 | No deliberately warm idle instance; cold-start latency remains. |
| maxInstances | 1 | Limits scaling exposure; sustained traffic still costs money and overload can reject requests. Not a financial cap. |
| concurrency | 1 | Conservative initial admission limit; serializes requests and can increase queues/429s. Not necessarily cheapest per request; benchmark before considering 4. |
| retries | No new automatic client/application retry loop | HTTP callable is not an event trigger: do not add an unsupported event retry option. Firestore transaction retries remain necessary for atomicity. |

Platform default concurrency is 80 where supported. Concurrency requires a full
CPU; changing CPU and concurrency independently can produce incompatible settings.
See [Functions resource controls](https://firebase.google.com/docs/functions/manage-functions).

createWorkspace rejects unauthenticated/unverified input before its transaction.
First creation reads canonical membership and atomically creates cafe, Owner member
and canonical mapping (three writes). Same-owner/same-payload retry reads the
existing authority records and returns existing cafe; it still consumes resources.
Single-workspace transactions prevent duplicate ownership, not paid request spam.
Never retry an unknown outcome with altered business data. No per-account creation
rate limiter or App Check enforcement was found here; review abuse controls before
public rollout. App Check enforcement without verified Web/Android setup would
block legitimate clients and requires a separate integration batch.

Other exports include inventory mutations/lifecycle, menu get/list/mutations,
team listing and invitation operations. Their costs are not approved by deploying
createWorkspace. Removal handler remains disabled; rejoin remains disabled.
Do not use a broad Functions deploy or global resource refactor in the first batch.

## Firestore demand and query efficiency

| Local path/pattern | Exposure | Proposed follow-up, not implemented |
| --- | --- | --- |
| workspace_inventory_repository.dart collection snapshots and server get | No server limit; active/archive filtering is local. Reads scale with the entire workspace inventory, including archived items. Separate consumers may subscribe repeatedly. | Measure subscription count; design shared scoped streams and server-side pagination/filtering with explicit completeness tests. Never add a silent limit that truncates dashboard totals or CSV export. |
| workspace_resolver.dart | Successful Owner resolution reads 3 unique authority docs; Staff reads 5; transactions may retry. | Count resolutions per user action; preserve every security check. |
| workspace_session_boundary.dart | 3 Owner / 5 Staff authority document listeners plus revalidation; reconnects add demand. | Review duplicate subscriptions/lifecycle disposal. Never remove revocation listeners just to reduce costs. |
| workspace_menu_repository.dart | Calls resolve before and after each callable; list page size 20. Backend reads up to limit+1 for cursor lookahead plus authorization. | Budget authority overhead as well as item reads; preserve episode validation. |
| activity/movement repositories | Cursor pages with limit; movement filters itemId and sorts createdAt. | Retain bounded pagination. Local draft index itemId ASC + createdAt DESC exists; deployment/index availability and actual query compatibility are NOT VERIFIED. |
| stock/create/lifecycle operations | Transactional authority reads plus business writes and movement/activity/receipt records; contention retries add reads. | Keep audit and idempotency writes atomic; no cost-saving deletion or bypass. |
| invitations/team | Bounded listing and invitation validation/rate-control work; Auth lookups also occur in some handlers. | Review costs per rejected attempt as well as successful operation before deployment. |

For a planning example only, 500 inventory documents across 10 fresh independent
query executions means roughly 5,000 document results before changes, authorization
reads, transaction retries or index-entry charges. This is not measured traffic
and SDK sharing can affect billing. Filters on received snapshots do not make the
original query bounded. Metadata-only callbacks do not each imply a billed read.

Listeners can incur reads on document changes and reconnection. Rules-dependent
document reads may be billed, including denied requests; free quotas do not turn
Blaze into a hard daily cap. Index storage, index-entry reads where applicable,
network egress and optional backup/PITR/TTL features also need separate accounting.
See [Firestore billing](https://firebase.google.com/docs/firestore/pricing).

## Logging, deployment and retained artifacts

index.js logs unexpected errors with console.error, including raw Error objects.
No request-body logging was found in these handlers, but the fixed prefix alone
does not prove error contents are sanitized. Recommend a separate redacted,
bounded structured-error review; never log tokens, email, payloads or whole docs.
Avoid success-per-document debug logging and high-cardinality custom metrics.
Retain security/error visibility; blanket log exclusion could hide incidents.

Logging ingestion/storage, optional longer retention, log exports and custom
monitoring can cost money. Recommend reviewing ordinary application-log retention
at 30 days; do not alter required audit retention. Existing buckets/sinks/retention
were NOT inspected. [Logging pricing](https://cloud.google.com/products/observability/pricing).

Builds and stored deployment images can cost money even with zero user requests.
No Artifact Registry cleanup policy is declared in inspected configuration; this
does not prove there is no cloud policy. Recommend separately approved Firebase
deployment-artifact cleanup after 1 day, or 7 days if inspection/rollback evidence
needs it. Confirm repository/location and evidence retention before authorizing
automatic deletion. Do not apply policies to unrelated repositories or delete
existing artifacts in this audit. Firebase documents that these retained deployment
images are not required for the running function; deleting them loses inspection
material and does not refund prior costs.
[Artifact guidance](https://firebase.google.com/docs/functions/manage-functions#clean_up_deployment_artifacts).

Avoid repeated exploratory deployments. Review Cloud Build, Artifact Registry,
Cloud Run/Functions, Logging and any build-source storage charges together.

## Proposed monthly alerts-only budget

Scope: project velora-73222, all services, calendar month. Do not filter only
Functions: Firestore, builds, artifacts, logging and other project services count.
Use an actual-spend basis; explicitly review credit/discount treatment and whether
the chosen basis represents expected payable cost. An optional gross-cost view
helps expose consumption hidden by credits. Do not assume taxes/FX fees included.

| Threshold | MYR-equivalent | Human response |
| --- | --- | --- |
| 50% | RM2.50 | Review usage attribution and anomalous traffic; pause discretionary deployments. |
| 90% | RM4.50 | Freeze rollout expansion; investigate with separately approved metadata access. |
| 100% | RM5.00 | Escalate immediately; use a separately approved containment plan, not automatic billing disablement. |

If the billing currency is MYR, proposed budget is 5.00 MYR. Otherwise use
`5 / (MYR per one unit of billing currency)` at a dated, approved exchange rate,
rounded conservatively to supported currency precision. No exchange rate or billing
currency was fetched or assumed. Recheck conversion monthly. Ensure responsible
recipients can receive every alert; optional forecast-100% alert is additional.

**Budget alerts are NOT hard spending caps.** Reporting and notification delays
allow charges to exceed RM5 before action. Resource limits also cannot guarantee
this ceiling. [Budget behavior](https://docs.cloud.google.com/billing/docs/how-to/budgets).
Current Firebase documentation also describes preview service-specific spend caps,
including Functions, with delayed enforcement and chargeable overshoot. These are
not a complete project-wide RM5 ceiling and are outside this proposal; disabling
services can interrupt onboarding. Do not assume Firestore/build/storage coverage.
[Spend-cap limitations](https://firebase.google.com/docs/projects/billing/spend-caps).

## Approval-gated rollout and blockers

1. Review this audit and accept that RM5 cannot be guaranteed. Billing-disabled
   prior evidence is a deployment blocker, not permission to link an account.
2. Separately authorize any metadata inspection: currency, project billing, API
   prerequisites, IAM/runtime service identity, database location, quotas, budgets,
   logging/artifact policies and exact reported AUP warning. None checked live here.
3. Approve a local createWorkspace-only resource-control patch and tests; verify
   Node 22 behavior (current offline tests used Node 24.15.0), memory expectations,
   overload handling, callable contract and retry-safe unknown outcomes.
4. Separately approve billing linkage, project-wide budget/recipients and any
   artifact retention policy. Do not silently accept API/IAM/billing prerequisites.
5. Review exact deployment diff and separately approve only the following command;
   it is documentation, NOT executed:

   ```powershell
   & C:\Users\23000\AppData\Roaming\npm\firebase.cmd deploy --only functions:workspace:createWorkspace --project velora-73222
   ```

   Stop for unexpected API/IAM changes, cleanup prompts or scope expansion. Rules B
   must remain unchanged. Keep all other callables, AI and lifecycle activation out.
6. Separately approve bounded synthetic runtime acceptance and observation of
   memory, latency, retries, errors and service-attributed costs before expanding.
   createWorkspace-only deployment will not enable inventory/menu callables;
   onboarding success does not certify the rest of the app or affordable scale.

## Offline verification performed

Directory: C:\Users\23000\velora (npm commands in functions).

- `npm.cmd test`: 367 passed, 0 failed/cancelled/skipped/todo.
- `node --test test/workspace-creation.test.js test/single-workspace-security.test.js`:
  30 passed, 0 failed/cancelled/skipped/todo; overlapping tests, not 397 unique tests.
- `node --check` for each of 14 functions/src/*.js: PASS, zero syntax failures.
- `git diff --check`: PASS; existing LF/CRLF conversion warnings only.
- Flutter/browser/device performance tests, Node 22 runtime, live traffic/costs,
  production metadata, authenticated Rules and indexes: NOT RUN / NOT VERIFIED.
- Emulator: NOT RUN. No dependency installation, deployment or callable invocation.

Reproduce backend checks with `cd functions; npm.cmd test`, the focused command
above, and from root `Get-ChildItem functions/src/*.js | ForEach-Object {
node --check $_.FullName }`; run `git diff --check` from root. Expect the stated
counts for this checkout; tests validate authorization, transaction and regression
behavior, not actual billing or resource sufficiency.

## Change control

ADD: this document only. MODIFY/DELETE: none by this audit. Existing dirty source,
configuration, Rules and tests preserved; main at eeca574, no Git add/commit/push.
Rules source SHA-256 remains
d8a4db6665547cebc781af2b032223a3e987a31398dd39ee26bea05a9162c5af.

DATABASE CHANGE REPORT: schema, Rules, documents and Auth users UNCHANGED.
Production resource/document reads and writes: NONE. Deployments: NONE.
No billing/API/IAM/budget/retention changes. Public documentation browsing only.

MANUAL TESTING: NOT RUN. Progress: local audit complete; implementation and cloud
rollout await separate review and approvals. STOP.
