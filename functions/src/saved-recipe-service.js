'use strict';

const m = require('./saved-recipe-model');
const {activeMembershipGeneration} = require('./membership-generation');
const {assertMutationEpisode} = require('./mutation-episode');

async function authorize(tx, uid, episode, ownerOnly) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`), cafeId = mapping?.cafeId;
  if (!m.validId(cafeId)) m.fail('permission-denied');
  const cafe = await tx.get(`cafes/${cafeId}`), ownerUid = cafe?.ownerUid;
  if (!m.validId(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) m.fail('permission-denied');
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const owner = await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMap = await tx.get(`user_cafe_memberships/${ownerUid}`);
  const generation = activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid);
  if (generation === null || activeMembershipGeneration(ownerMap, owner, ownerUid, cafeId, ownerUid) === null ||
      owner.role !== 'owner' || (ownerOnly && member.role !== 'owner')) m.fail('permission-denied');
  assertMutationEpisode(episode, cafeId, generation, m.SavedRecipeError);
  return {cafeId, generation};
}
function acknowledgement(receipt, replayed) {
  return {schemaVersion: 1, cafeId: receipt.cafeId, recipeId: receipt.recipeId,
    contentDigest: receipt.contentDigest, version: receipt.resultVersion, isArchived: receipt.resultIsArchived,
    outcome: receipt.outcome, changed: receipt.changed, replayed,
    requestHash: receipt.requestHash, payloadHash: receipt.payloadHash};
}

/** Offline factory only: no Firebase imports, credentials, provider or I/O defaults.
 * verifyIdentity(token) is a trusted project-bound verifier: signature/time/aud/iss,
 * verified email AND fresh disabled/revocation checks. It returns {uid, token}.
 * Both verifyIdentity.projectId and store.projectId must match the TEST project.
 * store.runTransaction(callback) must preserve callback exception identity, read
 * authority and data in one isolated transaction, atomically commit create/update,
 * and retry ONLY definite transport aborts. Domain performs ONE invocation.
 * tx.get(path) -> persisted Date/toDate records or null; tx.create/update are staged.
 * tx.savedRecipes(cafeId,{mode,limit,afterId}) -> ordered [{id,data}], where limit is
 * the requested look-ahead bound (<=21), lifecycle filter applies BEFORE limiting,
 * and cursor/parent references are enforced. E3 must implement this capability.
 * timestamp() returns a native server-time write transform (Date in offline fakes).
 * JSON response timestamps are ISO; write transforms never appear in responses.
 * E4 must enforce request deadlines, cancellation/admission and no retry policies.
 */
function createSavedRecipeService({projectId, store, verifyIdentity, timestamp} = {}) {
  if (projectId !== 'velora-spark-test' || store?.projectId !== projectId || verifyIdentity?.projectId !== projectId ||
      typeof store?.runTransaction !== 'function' || typeof verifyIdentity !== 'function' || typeof timestamp !== 'function') {
    throw new m.SavedRecipeError('failed-precondition');
  }
  return async function savedRecipeOperation({operation, token, data} = {}) {
    // Capture/detach before any asynchronous dependency can yield to the caller.
    const parsed = m.parseRequest(operation, data);
    let auth;
    try { auth = await verifyIdentity(token); } catch { m.fail('unauthenticated'); }
    if (!m.validId(auth?.uid) || auth.token?.sub !== auth.uid || auth.token.aud !== projectId ||
        auth.token.iss !== `https://securetoken.google.com/${projectId}` || auth.token.email_verified !== true) m.fail('unauthenticated');
    const actualOperation = operation === 'reconcile' ? parsed.operation : operation;
    const original = operation === 'reconcile' ? parsed.original : parsed;
    const mutation = operation === 'save' || operation === 'lifecycle';
    const domainErrors = new WeakSet();
    try {
      return await store.runTransaction(async tx => {
        try {
          const {cafeId, generation} = await authorize(tx, auth.uid, original.episode, actualOperation === 'lifecycle');
          const prefix = `cafes/${cafeId}`, input = original.input;
          const document = (id, raw) => raw == null ? null : m.recipeDocument(id, raw, projectId, cafeId);
          if (operation === 'get') {
            const item = document(input.recipeId, await tx.get(`${prefix}/saved_recipes/${input.recipeId}`));
            if (!item) m.fail('not-found');
            return {schemaVersion: 1, cafeId, item};
          }
          if (operation === 'list') {
            const scope = {schemaVersion: 1, projectId, cafeId, uid: auth.uid,
              membershipGeneration: generation, mode: input.mode, limit: input.limit};
            if (input.cursor && Object.entries(scope).some(([k, v]) => input.cursor[k] !== v)) m.fail('invalid-argument');
            if (typeof tx.savedRecipes !== 'function') m.fail('failed-precondition');
            const rows = await tx.savedRecipes(cafeId, {mode: input.mode, limit: input.limit + 1, afterId: input.cursor?.afterId ?? null});
            if (!Array.isArray(rows) || rows.length > input.limit + 1) m.fail('failed-precondition');
            let previous = input.cursor?.afterId ?? '';
            const items = Array.from(rows).map(row => {
              try { m.fields(row, ['id', 'data']); } catch { m.fail('failed-precondition'); }
              const item = document(row.id, row.data);
              if (!item || row.id <= previous || (input.mode !== 'all' && item.isArchived !== (input.mode === 'archived'))) m.fail('failed-precondition');
              previous = row.id;
              return {recipeId: item.recipeId, title: item.recipe.title, source: item.source,
                provenanceEvidence: item.provenanceEvidence, submittedAttribution: item.submittedAttribution,
                version: item.version, isArchived: item.isArchived, createdAt: item.createdAt, updatedAt: item.updatedAt};
            });
            const result = {schemaVersion: 1, cafeId, items: items.slice(0, input.limit),
              nextCursor: rows.length > input.limit ? {...scope, afterId: rows[input.limit - 1].id} : null};
            m.boundedJson(result, 65536, 'failed-precondition');
            return result;
          }
          const binding = m.requestBinding(projectId, auth.uid, cafeId, actualOperation, original);
          const receiptPath = `${prefix}/saved_recipe_requests/${binding.requestHash}`;
          const path = `${prefix}/saved_recipes/${binding.recipeId}`;
          const rawReceipt = await tx.get(receiptPath);
          const item = document(binding.recipeId, await tx.get(path));
          if (item && binding.content && m.canonicalContent(item.recipe) !== binding.content.content) m.fail('failed-precondition');
          if (rawReceipt != null) {
            const receipt = m.receiptDocument(rawReceipt);
            if (receipt.projectId !== projectId || receipt.cafeId !== cafeId || receipt.actorUid !== auth.uid ||
                receipt.actorGeneration !== generation || receipt.operation !== actualOperation ||
                receipt.requestHash !== binding.requestHash || receipt.payloadHash !== binding.payloadHash ||
                receipt.recipeId !== binding.recipeId) m.fail('already-exists');
            if (!item || receipt.contentDigest !== item.contentDigest || item.version < receipt.resultVersion ||
                (item.version === receipt.resultVersion && item.isArchived !== receipt.resultIsArchived) ||
                (receipt.outcome === 'created' && (receipt.actorUid !== item.createdBy || receipt.createdAt !== item.createdAt ||
                  JSON.stringify(input.attribution) !== JSON.stringify(item.submittedAttribution))) ||
                (actualOperation === 'lifecycle' && (receipt.resultVersion !== input.expectedVersion + 1 ||
                  receipt.outcome !== (input.action === 'archive' ? 'archived' : 'restored')))) m.fail('failed-precondition');
            const result = acknowledgement(receipt, true);
            return operation === 'reconcile' ? {schemaVersion: 1, status: 'committed', result} : result;
          }
          if (operation === 'reconcile') return {schemaVersion: 1, status: 'unknown'};
          let version, isArchived, outcome, changed, next;
          const time = timestamp();
          if (operation === 'save') {
            if (item) {
              version = item.version; isArchived = item.isArchived; changed = false;
              outcome = isArchived ? 'existing-archived' : 'existing-active';
            } else {
              version = 1; isArchived = false; changed = true; outcome = 'created';
              next = {schemaVersion: 1, projectId, cafeId, recipeId: binding.recipeId,
                contentDigest: binding.content.contentDigest, recipe: input.recipe, source: 'workspace-submitted',
                provenanceEvidence: 'unverified-attribution', submittedAttribution: input.attribution,
                createdBy: auth.uid, updatedBy: auth.uid, createdAt: time, updatedAt: time,
                version, isArchived, archivedBy: null, archivedAt: null};
            }
          } else {
            if (!item) m.fail('not-found');
            if (item.version !== input.expectedVersion) m.fail('aborted');
            isArchived = input.action === 'archive';
            if (item.isArchived === isArchived || item.version === Number.MAX_SAFE_INTEGER) m.fail('failed-precondition');
            version = item.version + 1; changed = true; outcome = isArchived ? 'archived' : 'restored';
            next = {version, isArchived, updatedAt: time, updatedBy: auth.uid,
              archivedBy: isArchived ? auth.uid : null, archivedAt: isArchived ? time : null};
          }
          const receipt = {schemaVersion: 1, projectId, cafeId, actorUid: auth.uid, actorGeneration: generation,
            requestHash: binding.requestHash, payloadHash: binding.payloadHash, operation: actualOperation,
            recipeId: binding.recipeId, contentDigest: binding.content?.contentDigest ?? item.contentDigest,
            resultVersion: version, resultIsArchived: isArchived, outcome, changed, createdAt: time};
          // Size/shape check using the longest ISO Date representation before
          // staging native server-time transforms. Persisted timestamps are
          // validated on reads; no speculative timestamp is returned to callers.
          if (next) {
            const projected = operation === 'save' ? next : {...item, ...next};
            const maxDate = new Date(8640000000000000);
            m.recipeDocument(binding.recipeId, {...projected, createdAt: maxDate, updatedAt: maxDate,
              archivedAt: isArchived ? maxDate : null}, projectId, cafeId);
          }
          const result = acknowledgement(receipt, false);
          m.boundedJson(result, 65536, 'failed-precondition');
          if (next) {
            if (operation === 'save') tx.create(path, next); else tx.update(path, next);
          }
          tx.create(receiptPath, receipt);
          return result;
        } catch (error) {
          if (error instanceof m.SavedRecipeError) domainErrors.add(error);
          throw error;
        }
      });
    } catch (error) {
      if (error instanceof m.SavedRecipeError && domainErrors.has(error)) throw error;
      // Unknown dependency exceptions cannot prove noncommit. Do not trust
      // arbitrary .code/.outcomeUnknown properties or call runTransaction again.
      throw new m.SavedRecipeError('unavailable', mutation);
    }
  };
}
module.exports = {createSavedRecipeService};
