# VELORA roadmap

VELORA is a cafe-scoped inventory management application built with Flutter and Firebase. The product direction is reliable stock visibility, accountable stock changes and safe operational assistance within each verified cafe workspace.

Read [PROJECT_STATUS.md](PROJECT_STATUS.md) for the implemented baseline at `03e853a`. All phases and workflows below are **proposed future functionality: NOT IMPLEMENTED** at that checkpoint, except where an existing baseline is explicitly described. No timelines or release commitments are assigned. Each phase needs scoped approval and verification before implementation.

## Phase 2.4D: Inventory List Usability — next

**NOT IMPLEMENTED:** contains-search on inventory names/categories, a dedicated category filter, selectable sorting and retryable list errors. Existing prefix search, status filters and fixed expiry sorting provide the starting point. Preserve workspace scoping, loading/empty distinctions and existing stock/security behavior; verify combined filters and Chrome presentation.

## Phase 2.4E: Cafe-scoped activity

**NOT IMPLEMENTED:** a securely readable cafe activity feed using `cafes/{cafeId}/activities`, with bounded pagination, validated events and explicit access rules. Trusted inventory operations already write activity audits, but that does not make the feed complete. Replace reliance on global activity reads only through a reviewed scoped integration; clients must not forge audit events.

## Phase 2.4F: Secure archive lifecycle

**NOT IMPLEMENTED:** server-authorized archive lifecycle with explicit state, permissions, confirmation and audit semantics. Define how archived items affect lists, history, stock operations and future restore behavior before implementation. Preserve audit records; do not introduce unaudited deletion or migrate legacy data implicitly.

## Future secure AI Suggestions and Recipe Details

**NOT IMPLEMENTED:** secure generation, cafe-scoped cache/quota/saved-recipe storage and trusted Recipe Details integration. Current local inventory insights and legacy recipe UI/helpers are not a secure generation workflow. Review backend identity, membership, credential handling, validation and data isolation before enabling any AI action. AI Suggestions generation remains disabled in the meantime.

## Future Cook Now

**NOT IMPLEMENTED:** server-authorized multi-item stock deduction. Require a reviewable ingredient/item mapping and quantities, explicit confirmation, current membership authorization, input and stock/version validation, idempotency and an atomic audit trail. Define all-or-nothing handling for insufficient stock and concurrent changes; never deduct through client writes or legacy global collections. Cook Now remains disabled until the secure workflow is implemented, tested and explicitly approved for activation.

## Cross-cutting decisions still required

Invitation/removal/ownership-transfer policy, auth/revocation UI lifecycle, deployed rules/index review, legacy-data disposition and any production cutover require separate design and authorization. Do not infer these from existing UI screens or draft rules. No commit, push, deployment, production mutation or migration is authorized by this roadmap.
