# Saved Recipes trusted transport activation plan

Date: 2026-11-18 (Asia/Kuala_Lumpur).
Status: PLANNING ONLY. Real-user activation BLOCKED.
Milestone: P6.6E8B.2. This document authorizes no subsequent implementation,
hosting registration, credentials, deployment, data access or billing changes.

## 1. Approved direction and evidence boundary

Retain Option C (disabled real-user access). Prepare Option B (trusted HTTPS).
Do not implement Option A (direct Firestore client reads). Preserve
[the canonical contract](saved-recipes-contract.md) without weakening its
account-freshness, transactional authority or membership-episode requirements.

User-reported accepted offline baseline: E8A.1 targeted 30/30, E7 regression
198/198, E8A integration 37/37, six-file analysis/formatting and diff checks clean.
Those results were not rerun for this document. They establish offline behavior,
not operational credentials, deployed authorization, native startup or hosting.
No backend deployment or successful real-user Saved Recipes transport is proven.

Current Home/Dashboard nullable forwarding and Discover lifecycle fixes stay in
place. Authenticated entry points still do not supply a live Saved Recipes
repository. Missing dependencies must continue to disable access.

## 2. Existing source inventory

Paths below are repository-relative. Factories and comments are not live acceptance.

| Component | Source | Implemented behavior / remaining proof |
| --- | --- | --- |
| Domain | `functions/src/saved-recipe-service.js` and `saved-recipe-model.js` | Exact request/record validation; trusted identity; authority/data in one transaction; expected cafe/generation checks; list/get and mutation domains. TEST project only. |
| HTTPS | `functions/https/saved-recipes-http.mjs` | Injected verifier/store/timestamp; request deadline/cancellation; response cap; no credential or hosting defaults. Exposes save/list/get/lifecycle/reconcile if used wholesale: NOT a read-only activation root. |
| Admission | `functions/https/authenticated-json-http.mjs` | Bearer admission, bounded JSON, normalized errors, `cache-control: no-store`, `nosniff`. Runtime server bridge remains to be composed. |
| Identity | `functions/backend/firebase-identity.mjs` | Certificate-based RS256 verification and current account lookup; issuer/audience/time/email/UID checks; no positive account-status cache. Operational API permissions unverified. |
| OAuth / HTTP | `functions/backend/google-oauth.mjs`, `google-http.mjs` | Injected project-bound credential and bounded Google HTTP capabilities. Real token acquisition, rotation and egress compatibility unverified. |
| Store / codec | `functions/backend/firestore-store.mjs`, `firestore-codec.mjs` | Firestore REST transactions, native timestamp encoding, scoped query/cursor validation, definite-abort retry classification and uncertain commit handling. No live transactional acceptance established. |
| Flutter domain | `lib/repositories/workspace_saved_recipe_repository.dart`, `lib/models/saved_recipe.dart` | Read/observation ports, strict envelopes, session-bound cursors, timeout and late-result checks. Save/lifecycle unavailable. Session currently accepts only `velora-spark-test`. |
| UI / forwarding | `lib/screens/suggestions/saved_recipes_page.dart`, `suggestions_page.dart`; `lib/screens/home/home_page.dart`; `lib/screens/dashboard/dashboard_page.dart` | Borrowed nullable repository, protected library/detail navigation, session/replacement guards, scoped Dashboard Navigator. No production read adapter. |
| Authority lifetime | `lib/services/workspace_resolver.dart`, `workspace_session_monitor.dart`; `lib/screens/auth/workspace_session_boundary.dart` | Canonical actor/owner links; generation consistency; invalidation and authenticated stack removal. UI monitoring does not replace server authorization. |
| Rules | `docs/firebase/workspace.firestore.rules`, referenced by `firebase.json` | No Saved Recipes client read grant; catch-all denial. Do not add grants for the trusted backend route. Deployed state unverified. |

The package currently declares Node 22, firebase-admin and firebase-functions.
The selected factories also require ESM/CommonJS interoperability, Web Request/
Response, Buffer, timers, AbortSignal, Node crypto/X509/WebCrypto, fetch-compatible
bounded transport and modern string APIs. An external runtime must prove these
capabilities; package declarations alone do not establish edge compatibility.
Do not deploy `functions/src/index.js` or install dependencies as part of this plan.

## 3. Trusted dependency and request contract

Future read-only composition must explicitly bind one project, database, verifier,
account lookup, OAuth provider, store, clock, transport, deadlines and endpoint.
All project identities must match; reject missing/inconsistent configuration at
startup. No client project selector, implicit cloud fallback or anonymous route.

Required flow:

1. Flutter captures the exact active workspace/session revision, obtains the
   current user's Firebase ID token, and dispatches only list/get with canonical
   expectedCafeId and expectedMembershipGeneration. Check session before/after
   token acquisition, dispatch, response decoding and publication.
2. HTTPS admits only the exact approved methods/routes, Bearer token and bounded
   JSON. Reject redirects, unknown fields, oversized bodies and unapproved origins
   for any Web acceptance build. CORS is not authorization.
3. Trusted verification checks signature, issuer, audience, time claims, verified
   email and UID consistency. `getAccount` checks current disabled status,
   emailVerified/email consistency and tokensValidAfterTime against auth_time.
   Certificate caching may follow validated expiry; positive account-status
   caching must not replace fresh checks.
4. Repeat required freshness verification at the canonical dispatch boundary.
   Existing HTTP admission and domain verification invoke the verifier, but
   acceptance must prove ordering relative to native transaction start/retries;
   do not infer every boundary is covered from a dependency comment.
5. Within one isolated native Firestore transaction, derive cafe from the actor
   mapping; validate cafe, actor mapping/member and owner mapping/member; compare
   expected cafe and actor membership generation. Read recipe/list in that same
   transaction. Do not perform account/provider network lookups inside retryable
   transaction callbacks.
6. Return validated list/get envelopes with sanitized errors and no-store
   headers. Never expose tokens, raw Google responses, credentials or private
   receipts. Client rejects every late result after episode replacement.

Auth revocation and Firestore are separate systems: fresh checks reduce the
window but do not promise instantaneous, atomic revocation across both. A valid
ID token, verified-email claim, active membership, disabled account and revoked
refresh tokens are distinct conditions. Preserve every canonical check.

### Credentials and IAM

The current REST factories consume a trusted OAuth accessToken provider; they do
not require embedding a Firebase Admin SDK in Flutter or universally mandate a
downloaded service-account JSON key. Establish least-privilege Google IAM for
account lookup and Firestore transaction/query operations, then prove it against
the chosen runtime. The store may need transaction commit permissions even when
the application stages no writes. Do not assume a generic viewer role suffices.

Prefer supported short-lived workload identity/federation where feasible. If a
service-account private key is necessary, obtain separate authorization; store it
only in the host's secret facility, with rotation, revocation, incident ownership
and access auditing. Never place it in source, build artifacts, Flutter/APK/IPA,
logs, screenshots or browser code. Project-specific credentials must not cross
environments. Public Firebase app options are not privileged backend credentials.

Server credentials bypass Firestore Rules; domain authorization remains mandatory.
Initial read-only hosting must block save/lifecycle/reconcile before service
dispatch and provide a store facade that cannot stage business writes. Preserve
native empty/read transaction completion if required by the store protocol.

### Budgets and failures

Existing Saved Recipes HTTPS defaults: 32,768-byte request, 65,536-byte success
response, 5-second identity/body budgets, 30-second request budget and 100ms
cleanup. Store defaults: 20-second total, 5-second RPC, at most three definite-abort
attempts. Flutter repository defaults to 15 seconds (maximum 30). Review the
end-to-end budget explicitly; current defaults are not automatically aligned.
Cold starts must fit the approved client timeout or fail safely, never relax auth.

Lists are limited to 1-20 records with at most 21 look-ahead records, lifecycle
filter before limit, document-ID ordering and scoped cursor validation. Verify
indexes without widening query scope. Whole response caps still apply to large
pages. Missing authorized detail is not-found, not a fabricated record.

Preserve normalized 401/403/404/409/429/503 outcomes and HTTP deadline handling.
No raw exception leakage, automatic transport retries or callable fallback.
Underlying store retries are limited to proven native aborts. Mutation uncertainty
semantics must remain preserved in existing code even though routes stay closed.
Log only sanitized correlation/error information; exclude recipe bodies and IDs
unless a separately reviewed privacy policy requires them.

## 4. Hosting and cost feasibility (public documentation checked 2026-11-18)

No account was registered or inspected. Public free-tier descriptions are not
proof of account eligibility, production suitability or a zero-charge guarantee.

| Approach | Verified public terms | Credentials, HTTPS and runtime assessment | Decision |
| --- | --- | --- | --- |
| Cloudflare Workers Free | 100,000 requests/day; 10ms CPU/invocation; 128MB memory; 50 subrequests/request. Account-specific card requirement not established by the reviewed pages. | HTTPS Workers endpoint and secret bindings available. Node crypto/X509, mixed modules, OAuth signing, verification CPU and transaction subrequests need compatibility tests. Secret storage alone does not prove IAM safety. Maintain compatibility date, rotation, monitoring and hard quotas. Paid plan/add-on selection introduces cost exposure. | Feasibility candidate only; no approved zero-billing production solution. |
| Render Free Node service | 750 workspace instance hours/month; sleeps after 15 minutes idle. Docs advise against production use. Without payment method, exhausted bandwidth suspends services and exhausted build minutes stop builds; with payment method overages can be billed. Signup eligibility remains unverified. | Managed HTTPS and server secret/environment facilities need account-level review. Native Node is a closer source fit; supply an HTTP bridge. Cold starts, ephemeral disk, patching, limits and outages need acceptance. Do not store records on its filesystem. | Possible isolated feasibility host; not accepted for real users. |
| Koyeb Free instance | Free instance advertised: 512MB RAM, 0.1 vCPU, 2GB SSD. Current pricing FAQ requires a card and a $29 pre-authorization; it also describes signup plan charging. | Node/container hosting, managed HTTPS and secrets require configuration review. Operator owns patching, credential rotation, usage and service availability. Additional usage/selected plan can incur charges. | Incompatible with current no-billing/prepayment direction unless terms and authorization change. |
| Existing privately operated server | No free tier is assumed. Existing capacity, TLS/domain, power, backups, patching and bandwidth all require evidence. | Node 22 and protected credentials may fit; operator must prove uptime, HTTPS, firewall, monitoring and incident response. | Not established as available or free. |

Provider evidence: [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[limits](https://developers.cloudflare.com/workers/platform/limits/),
[secrets](https://developers.cloudflare.com/workers/configuration/secrets/),
[Render Free](https://render.com/docs/free),
[Render HTTPS](https://render.com/docs/your-first-deploy),
[Koyeb instances](https://www.koyeb.com/docs/reference/instances),
[Koyeb billing FAQ](https://www.koyeb.com/docs/faqs/pricing).

Refresh terms before choosing a host. Record eligibility, mandatory payment,
auto-upgrade/overage behavior, resource caps, secret controls, incident owner and
shutdown procedure. Never attach a payment method, add paid resources or upgrade
Firebase to resolve feasibility. No hosting option is approved by this document.
Firestore/Auth quotas and backend account lookups remain a separate capacity gate.

## 5. Project/platform isolation

- Keep `velora-spark-test` isolated: distinct endpoints, credentials, configuration,
  accounts and approved fixtures; no production fallback. Current Saved Recipes
  domain, HTTP/store/identity factories and Flutter session are TEST-bound.
- Real project is `velora-73222`; recognizing its name is not activation approval.
  Inventory every TEST-only guard before proposing narrowly explicit production
  support. Do not remove guards globally or widen unrelated backend capabilities.
- `lib/services/firebase_startup_config.dart` admits Spark TEST only on Web;
  explicit real-project startup admits Web/unflavored Android. Android package,
  Google Services identity, signing configuration and backend audience must agree.
- iOS options in `lib/firebase_options.dart` do not prove a supported startup path:
  current explicit cloud guard rejects iOS. Review bundle IDs, native registration,
  startup and TLS requirements separately before native acceptance.
- Tablets follow their OS security configuration; test layout, back gestures,
  focus, orientation and background/resume independently on Android/iPad devices.
- Backend configuration must bind exact project/database/Google API hosts and a
  reviewed HTTPS endpoint. Flutter must not send tokens to arbitrary configured
  URLs, redirects, logs or alternate projects. Unknown environment fails closed.

## 6. Authorization, cache and session policy

Keep verified-email enforcement specific to this canonical feature unless broader
Auth policy is separately approved; current general login does not enforce it.
Both Owner and Staff may list/get active and archived records in their own cafe.
Missing, inactive, malformed, mismatched or partially upgraded links deny access.
Expected generation is a server precondition, never client authority.

The future Flutter HTTPS adapter performs server-only reads: no Firestore client
SDK read fallback, HTTP cache, application disk cache, queued request replay or
offline protected library. Enforce no-store through origin/proxy/client layers.
Use in-memory session-local results only. Do not introduce persistence in this
milestone. Existing unrelated SDK caches need a separate policy review; never
globally change or clear them as an incidental adapter implementation step.

Logout, workspace/role/generation changes, account verification failure and
repository replacement invalidate the old episode, clear protected UI and discard
in-flight completions. A new login with the same UID still requires a new revision.
Only the actual composition owner disposes its repository/subscriptions. Home,
Dashboard, Discover and Saved Recipes continue to borrow dependencies.

Preventing future reads does not delete prior SDK/application caches, screenshots,
OS snapshots, backups or information already seen. UI clearing is not secure
erasure. If device/app-switcher snapshot controls or deletion guarantees are
required, specify and verify them in a separate platform policy. Permission errors
must never resurrect old content as a connection fallback.

## 7. Ordered implementation roadmap

Every row requires its own explicit approval and source inspection before edits.
Candidate ADD paths are proposals, not claims that those files already exist;
stop on path conflicts. Do not batch runtime activation with offline preparation.

| Phase | Prerequisites and candidate file allowlist | Acceptance | Stop conditions |
| --- | --- | --- | --- |
| 1. Hosting decision | This plan; public terms and owner choice. ADD `docs/architecture/saved-recipes-hosting-feasibility.md` only. | Evidence-backed host/runtime/IAM/cost matrix; no card, paid plan or production activation; named operator. | No approved zero-billing host, unavailable identity federation/secrets or unacceptable downtime. Remain disabled. |
| 2. Backend dependency/configuration verification, unwired | Phase 1 decision; ADD `functions/https/saved-recipes-read-composition.mjs`, `functions/test/saved-recipes-read-composition.test.mjs`. READ existing domain/identity/OAuth/store factories. | Explicit TEST-bound dependencies, list/get-only routing, no staging of business writes, sanitized errors, startup rejection, freshness ordering and deadline tests. Node/edge compatibility evidence. | Factory changes needed outside allowlist, missing IAM/runtime capability or account freshness gap. Propose a separate repair manifest before edits. |
| 3. Unwired Flutter HTTPS read adapter | Exact endpoint/token/session interface from phase 2. ADD `lib/services/saved_recipe_https_read_port.dart` only. | Implements existing read port; exact envelopes, current token, session fencing, redirects denied, byte/time bounds, safe missing/error mapping; no live defaults or dispatch at construction. | New dependency, schema change, source edit outside scope or unsupported platform transport. |
| 4. Offline adapter tests | Phase 3 reviewed; ADD `test/saved_recipe_https_read_port_test.dart` only. | Fake token/HTTP only: list/get, revoked/unverified/mismatched identity failures, generation replacement, cancellation/timeouts, late results, malformed/oversized data, zero mutation/reconcile/fallback. | Real I/O required or weak tests that bypass repository guards. |
| 5. Explicit project/platform compatibility | Hosting and security model accepted. Initial planning ADD `docs/architecture/saved-recipes-platform-compatibility.md` only. Later candidate MODIFY `lib/services/firebase_startup_config.dart`, `test/firebase_startup_config_test.dart`, `lib/repositories/workspace_saved_recipe_repository.dart`, `test/workspace_saved_recipe_repository_test.dart`. | Explicit approved project allowlist, no implicit fallback; native registration evidence and TEST separation. Inventory backend TEST guards and produce exact backend/native manifest before further edits. | Need broad guard removal, credential exposure, iOS/native changes outside approved manifest or unregistered app. |
| 6. Authenticated repository composition, initially disabled | Phases 2-5; ADD `lib/services/saved_recipe_session_composition.dart`, `test/saved_recipe_session_composition_test.dart`; candidate MODIFY `lib/screens/auth/workspace_gate.dart`, `lib/screens/business_setup/business_setup_page.dart`. | One repository per verified session episode; verified email/current identity; explicit revision change stream; owner-only disposal; default disabled; both entry paths covered. Existing nullable Home/Dashboard APIs suffice. | Session owner cannot fence logout/rejoin/account changes, unavailable credentials/endpoint or need changes outside manifest. |
| 7. Isolated real-service security acceptance | Separate authorization for hosting/deployment/IAM and any required fixtures; phases 1-6 ready. ADD `docs/architecture/saved-recipes-real-service-acceptance.md` as initial planning scope only. | TEST project only: real token verification/account lookup, disabled/revoked/expired/wrong-project denial, Owner/Staff/cross-cafe tests, rejoin-generation rejection, native transactions/query bounds, deadlines, no-store and no mutation routes. Verify transaction freshness ordering. | No approved identities/fixtures, data writes needed without approval, uncertain project or unproven authorization. Offline results cannot substitute. |
| 8. Real-device acceptance | Phase 7 passes; separately approved native build/install scope. ADD `docs/architecture/saved-recipes-device-acceptance.md` for evidence. | Android/iOS/tablet platform gates; list/detail/back/rapid taps, revoked access, logout/switch/background/resume, delayed response and offline rejection; no protected disk fallback; accessible layout. | iOS startup blocked, cache disclosure, broken back stack, stale result publication or no approved device. |
| 9. Controlled activation | All gates signed off; ADD `docs/architecture/saved-recipes-activation-record.md`. Any config/route/flag changes require a new exact manifest based on phase 6 source. | Explicit TEST enablement first; production project, endpoint and credentials separately approved; only list/get public; observed quotas/latency; reviewed rollback rehearsed. | Billing requirement, security evidence missing, production activation not authorized or rollback cannot disable new entry points safely. |

Stage 7 is not currently authorized. If suitable isolated fixtures do not exist,
stop: do not seed records, disable accounts, revoke tokens or edit memberships
without specific approval. Account-security tests are mutations even when recipe
reads are read-only. No emulator is part of any phase.

## 8. Verification evidence, operations and rollback

Offline source/fake tests prove code contracts only. The default functions npm test
script does not include every Saved Recipes module test; future verification must
name `functions/test/saved-recipe-service.test.js`,
`functions/test/saved-recipes-http.test.mjs`, and relevant identity/store/OAuth
tests explicitly. Review commands against installed dependencies before running.
No tests are run by this documentation milestone.

Do not equate source-string Rules checks with Rules compilation, deployed Rules
execution or Firebase authorization. With no emulator, equivalent offline Rules
runtime assurance is unavailable. For HTTPS service credentials, IAM and canonical
domain checks are the security boundary; test both. Direct Saved Recipes client
reads/writes must remain denied, verified later against an approved deployed Rules
snapshot using authorized isolated identities. No Rules grants are planned here.

Record command, exit code, project/endpoint identity, version/hash, date, test
counts/skips and evidence provenance for each gate; never record credentials.
Provider uptime, quotas, certificate refresh, account lookup failure, transaction
contention and excessive read costs need operational alerts and a named responder.
Fail closed when services/quota are unavailable; do not attach billing to recover.

Rollback: disable Saved Recipes injection/entry and list/get endpoints through
reviewed configuration, invalidate active application episodes, discard pending
results, and revoke compromised backend credentials through an authorized incident
procedure. Preserve business documents and existing Inventory/Menu/Staff/AI
behavior; no data rollback, cache wipe, migration or broad Git operation. No
client flag can replace server denial. Re-enable only after the failed gate passes.

## 9. Decision and immediate next step

GO WITH CONDITIONS for reviewing this plan and authorizing phase 1 only.
BLOCKED for hosting activation, real Firebase access, production credentials,
production project admission, transport wiring and real-user activation.

No zero-billing production hosting solution has been established. No canonical
security requirement is relaxed. The next approval must identify a concrete phase
and exact file manifest; this document does not authorize executing the roadmap.
