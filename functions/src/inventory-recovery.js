'use strict';
const {createHash} = require('node:crypto');
const {mutationEpisode, assertMutationEpisode} = require('./mutation-episode');
const {activeMembershipGeneration} = require('./membership-generation');
const creation = require('./inventory-create');
const update = require('./inventory-update');
const stock = require('./inventory-stock');
const lifecycle = require('./inventory-lifecycle');

class InventoryRecoveryError extends Error {
  constructor(code) { super('Inventory observation unavailable.'); this.code = code; }
}
const fail = code => { throw new InventoryRecoveryError(code); };
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  value.trim() === value && !['.', '..'].includes(value) && !/[\\/\p{Cc}]/u.test(value);
const integer = (value, min = 0) => Number.isSafeInteger(value) && value >= min;
const hash = value => createHash('sha256').update(value, 'utf8').digest('hex');
const domains = Object.freeze({create: creation, update, 'adjust-stock': stock, lifecycle});
function millis(value) {
  try {
    const result = value instanceof Date ? value.getTime() : value?.toMillis?.();
    return Number.isSafeInteger(result) ? result : NaN;
  } catch { return NaN; }
}

// Client expectations remain preconditions, not authority. The shared canonical
// pair validator checks active schema-valid links, roles and generations for
// both actor and Owner; the cafe/Owner chain is resolved in this read transaction.
async function authorize(tx, uid, episode) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`), cafeId = mapping?.cafeId;
  if (!id(cafeId)) fail('permission-denied');
  const cafe = await tx.get(`cafes/${cafeId}`), ownerUid = cafe?.ownerUid;
  if (!record(cafe) || !id(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) fail('permission-denied');
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const owner = await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMap = await tx.get(`user_cafe_memberships/${ownerUid}`);
  const generation = activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid);
  if (generation === null || activeMembershipGeneration(ownerMap, owner, ownerUid, cafeId, ownerUid) === null) {
    fail('permission-denied');
  }
  assertMutationEpisode(episode, cafeId, generation, InventoryRecoveryError);
  return cafeId;
}

function payloadDigest(operation, input, episode) {
  // Match canonical JSON ordering after the exported normalizers. Digests are
  // recomputed on the server, never accepted as client claims or receipt paths.
  if (operation === 'create') return hash(JSON.stringify({episode, name: input.name,
    category: input.category, quantity: input.quantity, unit: input.unit,
    expiryDate: input.expiryDate.toISOString(), imageUrl: input.imageUrl}));
  if (operation === 'update') {
    const changes = Object.fromEntries(Object.keys(input.changes).sort().map(key =>
      [key, key === 'expiryDate' ? input.changes[key].toISOString() : input.changes[key]]));
    return hash(JSON.stringify({episode, itemId: input.itemId, expectedVersion: input.expectedVersion, changes}));
  }
  if (operation === 'adjust-stock') return hash(JSON.stringify({episode, itemId: input.itemId,
    direction: input.direction, quantity: input.quantity, expectedVersion: input.expectedVersion, reason: input.reason}));
  return hash(JSON.stringify({episode, itemId: input.itemId, action: input.action, expectedVersion: input.expectedVersion}));
}

async function observe(tx, {operation, input, episode, uid, cafeId}) {
  const requestHash = hash(`${uid}\0${cafeId}\0${input.idempotencyKey}`);
  const digest = payloadDigest(operation, input, episode);
  const itemId = operation === 'create' ? `item_${requestHash}` : input.itemId;
  const prefix = `cafes/${cafeId}`;
  const base = row => record(row) && row.schemaVersion === 1 && row.cafeId === cafeId &&
    row.itemId === itemId && row.actorUid === uid && row.requestHash === requestHash && Number.isFinite(millis(row.createdAt));
  const bound = row => base(row) && row.payloadHash === digest;
  if (operation === 'create') {
    const item = await tx.get(`${prefix}/inventory/${itemId}`);
    const movement = await tx.get(`${prefix}/inventory_movements/create_${requestHash}`);
    const activity = await tx.get(`${prefix}/activities/inventory_create_${requestHash}`);
    if (!record(item) || item.schemaVersion !== 1 || item.cafeId !== cafeId || item.createdBy !== uid ||
        item.createRequestHash !== requestHash || item.createPayloadHash !== digest || !base(movement) || !base(activity) ||
        movement.type !== 'initial_stock' || activity.type !== 'inventory_created' ||
        movement.quantity !== input.quantity || activity.quantity !== input.quantity ||
        movement.unit !== input.unit || activity.unit !== input.unit || activity.itemName !== input.name ||
        !Number.isFinite(millis(item.createdAt)) || millis(item.createdAt) !== millis(movement.createdAt) ||
        millis(item.createdAt) !== millis(activity.createdAt)) return null;
    // Mutable item fields are intentionally not used as creation evidence.
    return {cafeId, itemId, created: true};
  }
  if (operation === 'update') {
    const activity = await tx.get(`${prefix}/activities/inventory_update_${requestHash}`);
    if (!bound(activity) || typeof activity.updated !== 'boolean' ||
        activity.type !== (activity.updated ? 'inventory_updated' : 'inventory_update_noop') ||
        activity.fromVersion !== input.expectedVersion || !integer(activity.resultVersion, 1) ||
        activity.resultVersion !== input.expectedVersion + (activity.updated ? 1 : 0) ||
        !Array.isArray(activity.changedFields) || activity.changedFields.length > Object.keys(input.changes).length ||
        activity.changedFields.some((field, index, fields) => typeof field !== 'string' || !Object.hasOwn(input.changes, field) ||
          (index > 0 && fields[index - 1] >= field)) ||
        (activity.updated ? activity.changedFields.length === 0 : activity.changedFields.length !== 0)) return null;
    return {cafeId, itemId, updated: activity.updated, version: activity.resultVersion};
  }
  if (operation === 'adjust-stock') {
    const movement = await tx.get(`${prefix}/inventory_movements/stock_${requestHash}`);
    const activity = await tx.get(`${prefix}/activities/inventory_stock_${requestHash}`);
    if (!bound(movement) || !bound(activity) || activity.type !== 'inventory_stock_adjusted' ||
        movement.type !== (input.direction === 'in' ? 'stock_in' : 'stock_out') ||
        movement.delta !== (input.direction === 'in' ? input.quantity : -input.quantity)) return null;
    const fields = ['direction', 'quantity', 'previousQuantity', 'resultingQuantity', 'unit', 'fromVersion', 'resultVersion', 'reason'];
    if (fields.some(field => movement[field] !== activity[field]) || millis(movement.createdAt) !== millis(activity.createdAt) ||
        movement.direction !== input.direction || movement.quantity !== input.quantity || movement.reason !== input.reason ||
        !integer(movement.previousQuantity) || !integer(movement.resultingQuantity) ||
        typeof movement.unit !== 'string' || !movement.unit ||
        movement.fromVersion !== input.expectedVersion || !integer(movement.resultVersion, 1) ||
        movement.resultVersion !== input.expectedVersion + 1) return null;
    const previous = movement.previousQuantity;
    if (input.direction === 'in' ? previous > Number.MAX_SAFE_INTEGER - input.quantity ||
        movement.resultingQuantity !== previous + input.quantity : previous < input.quantity ||
        movement.resultingQuantity !== previous - input.quantity) return null;
    return {cafeId, itemId, direction: input.direction, quantity: input.quantity,
      resultingQuantity: movement.resultingQuantity, version: movement.resultVersion, adjusted: true};
  }
  const activity = await tx.get(`${prefix}/activities/inventory_lifecycle_${requestHash}`);
  const state = input.action === 'archive' ? 'archived' : 'active';
  if (!bound(activity) || activity.type !== (state === 'archived' ? 'inventory_archived' : 'inventory_restored') ||
      activity.resultState !== state || activity.fromState !== (state === 'archived' ? 'active' : 'archived') ||
      !integer(activity.preservedQuantity) || activity.fromVersion !== input.expectedVersion ||
      !integer(activity.resultVersion, 1) || activity.resultVersion !== input.expectedVersion + 1) return null;
  return {cafeId, itemId, lifecycleState: state, version: activity.resultVersion, changed: true};
}

// Strict envelope: {operation, request: <the complete original mutation data>}.
// Result flags describe the historical operation, not a new mutation attempt.
// Missing, partial, conflicting or invalid evidence never proves noncommit.
async function reconcileInventory({auth, data, store}) {
  const uid = auth?.uid;
  if (!id(uid) || auth.token?.email_verified !== true) fail('unauthenticated');
  if (!record(data) || Object.keys(data).length !== 2 || !Object.hasOwn(data, 'operation') ||
      !Object.hasOwn(data, 'request') || typeof data.operation !== 'string' || !Object.hasOwn(domains, data.operation)) fail('invalid-argument');
  const {episode, payload} = mutationEpisode(data.request, InventoryRecoveryError);
  let input;
  try { input = domains[data.operation].validateInput(payload); }
  catch { fail('invalid-argument'); }
  return store.runTransaction(async tx => {
    const cafeId = await authorize(tx, uid, episode);
    const result = await observe(tx, {operation: data.operation, input, episode, uid, cafeId});
    return result ? {state: 'committed', result} : {state: 'unknown'};
  });
}
module.exports = {InventoryRecoveryError, reconcileInventory};
