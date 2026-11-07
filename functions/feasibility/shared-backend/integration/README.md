# S4.5 integrated offline REST/workerd harness

Synthetic-only: no live transport, credentials, deployment or application wiring.
AI and Staff remain mandatory v1.0. Never deploy either scenario controller.

From repository root:

```
node --test functions/feasibility/shared-backend/integration/integration.test.mjs
node --test functions/feasibility/shared-backend/runtime/integrated-runtime.test.mjs
node --test functions/feasibility/shared-backend/runtime/runtime.test.mjs
```

The fixture wires real HTTP/OAuth/certificate/account/workspace/Firestore adapters
to the unchanged shared backend and pure AI/Staff modules. No original fake store
is imported. Signing keys/certificates are generated in memory. OAuth signatures
are checked by the injected simulator. Provider responses are synthetic.

The simulator independently interprets Firestore wire values, preconditions,
quoted top-level field masks and REQUEST_TIME transforms. Transaction snapshots,
document revisions and bounded query fingerprints detect modeled conflicts;
commits validate on a draft before publication. Faults can reject, abort, lose
an applied commit response, leave the outcome unresolved, or break response data.
Trace summaries expose transaction/RPC/write counts without credentials.

Node runs scenario assertions directly. Workerd runs the same scenarios and actual
adapter/application imports; Node only bundles, dispatches and checks evidence.
Existing pinned tooling and narrow crypto import bridge are reused, with outbound
Worker fetch denied. Generated bundles stay in runtime/.tmp (already ignored).

Limitations: not Firebase locking, network, IAM or quota proof. No production
durability, Auth/commit atomicity, CPU/memory/SLA or privacy certification. Rejoin
still lacks tx.set in the REST store and is not activated. Existing bridge audit
Dates remain unchanged; server transforms are exercised separately. No live
Firestore, Auth, OAuth, Cloudflare, Groq, Chrome or physical Android acceptance.

## Historical S4.5 failure (resolved in S4.5.1)

At S4.5, Node integration: 16/16 passed. Integrated workerd: FAIL, not accepted.
A focused runtime diagnostic generated/signed/verified synthetic keys and parsed
the X509 certificate, then failed exporting `cert.publicKey` as JWK. The pinned
workerd raises `expected keyAlgorithm.hash != nullptr`. The same conversion is
used by adapters/firebase-identity.mjs at that point. No adapter or existing business
logic was modified to bypass it during S4.5.

S4.5 stopped for separate approval of a narrow certificate-conversion fix and
regression coverage. Node PASS alone did not establish integrated Workers PASS.
The S4.5 scenario tests denied before successful identity
verification must not be interpreted as independently verified authorization.

## Checkpoint evidence through S4.11 (2026-11-07)

S4.5.1 resolved the adapter incompatibility using X509 SPKI export -> Web Crypto
RSASSA-PKCS1-v1_5/SHA-256 import -> JWK export, retaining signature and claim checks,
certificate validity and RSA strength checks. No runtime upgrade, trusted-identity
injection or fake-store fallback was used. Current test source asserts that the
legacy direct-export diagnostic fails as expected; this is a passing regression
assertion, not an unresolved integrated-suite failure.

Prior integrated local workerd: **18/18 PASS** (16 scenarios, legacy diagnostic and
outbound-network denial). Prior existing workerd regression: **15/15 PASS**.
GitHub Gate A later ran **67/67 Node tests PASS**, including 16 integrated scenarios,
plus **23/23 Rules source/host-model checks PASS**: **90/90 total**. S4.11 full-name
offline tests: prior **20/20 PASS**. None were rerun during this documentation correction.

S4.10 Spark Test Register -> Login -> Email Verification -> seven-field Business
Setup -> Dashboard is **USER-OBSERVED Chrome PASS**. It is separate from this
synthetic backend harness and does not independently verify all canonical documents
or negative security cases. Corrected S4.11 full-name display in Chrome remains
**NOT TESTED**.

Mandatory AI and Staff remain KEEP WITH SECURE IMPLEMENTATION and BLOCKED PENDING
SECURE BACKEND for live release. Real Firebase backend/OAuth/account-state and Groq
integration, credential provisioning/rotation, durable atomic persistence/quotas,
Workers Free capacity/reliability/privacy and security acceptance remain open.
No live AI/Staff deployment, physical Android acceptance, APK readiness or production
readiness is established. Earlier Chrome Owner acceptance is not backend acceptance.
No deployment, live session, installation or Git mutation is authorized here.
