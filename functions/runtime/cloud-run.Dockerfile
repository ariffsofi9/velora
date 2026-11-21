# Build context: functions/. Synthetic-only runtime.
FROM --platform=linux/amd64 node:22.23.4-bookworm-slim
WORKDIR /app

COPY runtime/cloud-run-entry.mjs \
    runtime/node-entry.mjs ./runtime/
COPY backend/application.mjs \
    backend/backend-errors.mjs \
    backend/firebase-identity.mjs \
    backend/firestore-codec.mjs \
    backend/firestore-store.mjs \
    backend/google-http.mjs \
    backend/google-oauth.mjs \
    backend/http-policy.mjs ./backend/
COPY https/ai-http.mjs \
    https/authenticated-json-http.mjs \
    https/inventory-http.mjs \
    https/invitation-http.mjs \
    https/menu-http.mjs \
    https/saved-recipes-http.mjs \
    https/staff-http.mjs \
    https/workspace-http.mjs ./https/
COPY src/ai-quota.js \
    src/inventory-create.js \
    src/inventory-lifecycle.js \
    src/inventory-recovery.js \
    src/inventory-stock.js \
    src/inventory-update.js \
    src/membership-generation.js \
    src/membership-rejoin.js \
    src/membership-removal.js \
    src/menu-model.js \
    src/menu-service.js \
    src/mutation-episode.js \
    src/saved-recipe-model.js \
    src/saved-recipe-service.js \
    src/secure-ai-callable-contract.js \
    src/secure-groq-handler.js \
    src/team-members.js \
    src/workspace-creation.js \
    src/workspace-invitations.js ./src/
COPY ai1/recipe-service.js ./ai1/

USER node
ENTRYPOINT ["node", "runtime/cloud-run-entry.mjs"]
