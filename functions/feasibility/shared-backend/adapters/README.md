# S4.4 offline REST adapter prototypes

No live network default, secrets, configuration changes or production wiring.
Every HTTP request uses an injected transport and fixed test-project destinations.
Never pass a live transport without separate approval. AI and Staff remain mandatory.

Run from repository root:

```
node --test functions/feasibility/shared-backend/adapters/adapter.test.mjs functions/feasibility/shared-backend/adapters/firestore-store.test.mjs
```

OAuth uses injected assertion signing, expiry-aware caching and single-flight refresh.
Identity parses Google-format X509 certificates with node:crypto, exports SPKI,
imports it through Web Crypto with RSASSA-PKCS1-v1_5/SHA-256, then exports JWK.
The S4.5.1 fix rejects invalid certificate dates, non-RSA keys and RSA below 2048
bits; it avoids the pinned workerd direct KeyObject-to-JWK export incompatibility.
It then reuses the
existing strict RS256 verifier (zero clock tolerance). Key refresh has a 30-second
cooldown and respects bounded cache max-age. Account lookup normalizes validSince
seconds and fails closed. Missing disabled is normalized false per the REST shape;
missing validSince is rejected conservatively. No real certificate endpoint is used.

Firestore buffers writes and uses begin/read/query/commit/rollback. Definite ABORTED
responses may retry the callback; unknown commits never retry. Receipt recovery
acknowledges only a caller-validated record; absence remains unknown. Recovery callers
receive the same transaction to validate linked records before acknowledgement.
No provider calls belong inside transaction callbacks. Fake tests cannot establish
Firestore atomicity, IAM, contention or commit visibility guarantees.

Limitations: no live Firebase backend acceptance, no credential
issuance or federation, no application wiring, no cross-service Auth/commit atomicity.
No production flooding protection or capacity assurance. Timestamps decode to Date
(millisecond precision); do not use decoded timestamps as nanosecond preconditions.
Current update existence preconditions rely on transaction reads for concurrency;
external version/updateTime preconditions are not a public adapter feature.

Historical S4.4 verification: 16 adapter tests passed and 391 selected existing Node regressions
passed. Synthetic certificates and RSA keys are generated in memory. Successful
rotation/signature verification is exercised with synthetic X509 certificates;
Google endpoint/account authenticity is not established. Existing quota and Staff
concurrency suites passed against their fake stores, not this REST adapter. Full
AI/Staff execution over scripted REST was a separate gap at S4.4; S4.5/S4.5.1 later
covered it with the independent simulator in Node and local workerd.

## Checkpoint evidence through S4.11 (2026-11-07)

Prior S4.5.1 integrated workerd result: **18/18 PASS** after the SPKI fix; existing
workerd regression: **15/15 PASS**. The legacy direct-export diagnostic still
demonstrates the unsupported operation, as an expected-failure assertion inside
the passing suite. No identity verification bypass was introduced.

GitHub Gate A subsequently ran **67/67 Node tests PASS** across identity, backend,
adapters (17), and integrated REST scenarios (16), plus **23/23 Rules source/host
checks PASS**: **90/90 total**. These results are prior evidence, not rerun during
this documentation correction. Synthetic identity verification is not authoritative
real Firebase verification; simulator persistence is not real Firestore acceptance.

S4.10 Spark Test Owner Setup -> Dashboard is **USER-OBSERVED Chrome PASS**, separate
from these backend prototypes. S4.11 full-name tests were previously **20/20 PASS**;
the corrected name in Chrome remains **NOT TESTED**. No live AI/Staff deployment,
Groq integration, Workers Free capacity/reliability/privacy acceptance, Android
acceptance, APK readiness or production readiness is established. Secure credentials,
durable quotas, real backend integration and security acceptance remain release
gates for mandatory AI and Staff.
