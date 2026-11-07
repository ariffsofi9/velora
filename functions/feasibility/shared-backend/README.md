# S4.2 shared backend: offline feasibility only

No deployed entrypoint, live credential source, SDK initialization, global network call,
UI integration or configuration changes. AI and Staff remain mandatory v1.0 features.

From repository root:

```powershell
node --test functions/test/shared-backend-identity.test.mjs functions/test/shared-backend-feasibility.test.mjs
```

The fetch-style factory requires an identity verifier and backend. Identity verification
uses real RSA/SHA-256 verification with synthetic locally generated keys and a fake
account directory. It is NOT authoritative Firebase verification. No key discovery,
OAuth, IAM, REST persistence or live provider adapter is implemented.

The bridge reuses the existing pure quota, Groq handler, invitation, roster, removal,
generation and validation modules. It never imports the Functions entrypoint or callable
SDK adapter. Prototype removal invokes pure logic without activating production removal.
Rejoin remains subject to its existing disabled-by-default semantics.

The fake store serializes transactions, clones state and publishes only on success.
It checks create/update existence and read-after-write ordering. It models atomicity,
not Firestore optimistic contention, retries, IAM, timestamps or uncertain commit behavior.
Provider timeout/invalid outcomes reuse existing quarantine semantics; no automatic resend.

Workers compatibility is NOT proven: CommonJS bundling, node:crypto, Buffer, Intl,
Admin SDK replacement, Web Crypto CPU cost and REST adapters require later review.
Node execution is not workerd execution. No Wrangler/workerd installation is authorized.

Production gaps include authoritative account-state access, credential rotation,
short-window/application-wide abuse budgets beyond existing daily AI/invitation limits,
request read deadlines, CORS, key refresh, durable persistence, result lookup/cache,
retention/cleanup, deployment eligibility and measured free-tier capacity. Never use
this prototype as a public server or substitute mock PASS for production acceptance.

Verification on local Node v24.15.0 (Functions target Node 22): new suite 34 passed;
selected existing quota/Groq/generation/removal/rejoin/mutation suites 357 passed.
No Workers, browser, Android, real Firebase or Groq execution. Tests replace global
fetch with a throwing guard; injected provider responses are synthetic. This is not
an operating-system network sandbox or a complete compiled-artifact secret audit.

## S4.3 local workerd verification

From `functions/feasibility/shared-backend/runtime`, run `node --test runtime.test.mjs`.
Isolated installed pins: Wrangler 4.100.0, Miniflare 4.20260611.0,
workerd 1.20260611.1 (transitive), esbuild 0.27.3. Host Node 24.15.0,
npm 11.12.1, Windows build 26100/24H2. Compatibility date 2026-06-11 with
nodejs_compat: this proves the pinned runtime only, not the latest runtime.

The Node runner bundles and dispatches to Miniflare's real local workerd process.
JWT verification, request handling and reused AI/Staff logic execute inside workerd.
The bundle explicitly maps CommonJS `require('node:crypto')` to a native ESM crypto
import; no business module changes or generic module fallback. The entrypoint is
a synthetic scenario controller, not a production API. Never deploy it.

Final local suite: 15 passed, zero failed. Node regressions: 391 passed
(34 S4.2 plus 357 selected existing). Initial attempts hit filesystem sandbox
restrictions, then a missing crypto bundler bridge; both were corrected in the
authorized harness. Blocked outbound fetch returns a synthetic error response in
this pinned runtime, rather than necessarily throwing. Miniflare fetch mocks have
net-connect disabled. Package installation used registry downloads; runtime tests
did not use live Firebase, Cloudflare or Groq services.

No CPU/memory capacity or latency SLA was established. Per-request RSA fixture
generation is test overhead. Fake persistence remains nondurable. No authoritative
Firebase account directory, production credentials, OAuth/REST adapter, cloud
deployment, Android/Chrome integration or production release is certified.
