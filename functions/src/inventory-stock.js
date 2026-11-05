'use strict';
const {mutationEpisode, assertMutationEpisode} = require('./mutation-episode');
const {activeMembershipGeneration} = require('./membership-generation');

const {createHash} = require('node:crypto');

const ALLOWED_FIELDS = new Set([
  'idempotencyKey',
  'itemId',
  'direction',
  'quantity',
  'expectedVersion',
  'reason',
]);
const FORBIDDEN_FIELDS = new Set([
  'cafeId',
  'uid',
  'actorUid',
  'ownerUid',
  'role',
  'currentQuantity',
  'previousQuantity',
  'resultingQuantity',
  'unit',
  'timestamp',
  'createdAt',
  'updatedAt',
  'movementId',
  'activityId',
  'requestHash',
  'payloadHash',
  'schemaVersion',
]);

class InventoryStockError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'InventoryStockError';
    this.code = code;
  }
}

function invalid(message) {
  throw new InventoryStockError('invalid-argument', message);
}

function validId(value) {
  return typeof value === 'string' &&
    value.length > 0 &&
    value.length <= 128 &&
    value.trim() === value &&
    value !== '.' &&
    value !== '..' &&
    !value.includes('/') &&
    !/[\x00-\x1f]/.test(value);
}

function cleanText(value, field, {min = 0, max}) {
  if (typeof value !== 'string') invalid(`${field} must be text.`);
  const cleaned = value.trim().replace(/\s+/g, ' ');
  if (cleaned.length < min || cleaned.length > max) {
    invalid(`${field} must be between ${min} and ${max} characters.`);
  }
  if (/\p{Cc}/u.test(cleaned)) invalid(`${field} contains invalid characters.`);
  return cleaned;
}

function validateInput(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    invalid('Stock adjustment data is required.');
  }
  for (const key of Object.keys(raw)) {
    if (FORBIDDEN_FIELDS.has(key)) invalid(`${key} cannot be supplied.`);
    if (!ALLOWED_FIELDS.has(key)) invalid(`Unsupported field: ${key}.`);
  }
  const idempotencyKey = cleanText(raw.idempotencyKey, 'Idempotency key', {
    min: 16,
    max: 128,
  });
  if (!validId(raw.itemId)) invalid('Invalid inventory item ID.');
  if (!['in', 'out'].includes(raw.direction)) invalid('Invalid stock direction.');
  if (!Number.isSafeInteger(raw.quantity) || raw.quantity <= 0) {
    invalid('Quantity must be a positive safe integer.');
  }
  if (!Number.isSafeInteger(raw.expectedVersion) || raw.expectedVersion < 1) {
    invalid('Expected version must be a positive integer.');
  }
  const reason = raw.reason == null
    ? ''
    : cleanText(raw.reason, 'Reason', {max: 200});
  return {
    idempotencyKey,
    itemId: raw.itemId,
    direction: raw.direction,
    quantity: raw.quantity,
    expectedVersion: raw.expectedVersion,
    reason,
  };
}

function activeLink(data, uid, cafeId) {
  return data &&
    data.uid === uid &&
    data.cafeId === cafeId &&
    data.status === 'active' &&
    data.schemaVersion === 1;
}

async function resolveActiveMembership(transaction, uid) {
  const mapping = await transaction.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping && mapping.cafeId;
  if (!validId(cafeId) || !activeLink(mapping, uid, cafeId)) {
    throw new InventoryStockError(
      'permission-denied',
      'An active workspace membership is required.',
    );
  }
  const cafe = await transaction.get(`cafes/${cafeId}`);
  const member = await transaction.get(`cafes/${cafeId}/members/${uid}`);
  const ownerUid = cafe && cafe.ownerUid;
  if (
    !validId(ownerUid) ||
    !cafe ||
    cafe.status !== 'active' ||
    cafe.schemaVersion !== 1 ||
    !activeLink(member, uid, cafeId) ||
    !['owner', 'staff'].includes(member.role) ||
    (member.role === 'owner') !== (uid === ownerUid) ||
    activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid) === null
  ) {
    throw new InventoryStockError(
      'permission-denied',
      'Workspace membership could not be verified.',
    );
  }
  const ownerMember = await transaction.get(
    `cafes/${cafeId}/members/${ownerUid}`,
  );
  const ownerMapping = await transaction.get(
    `user_cafe_memberships/${ownerUid}`,
  );
  if (
    !activeLink(ownerMember, ownerUid, cafeId) ||
    ownerMember.role !== 'owner' ||
    !activeLink(ownerMapping, ownerUid, cafeId) ||
    activeMembershipGeneration(ownerMapping, ownerMember, ownerUid, cafeId, ownerUid) === null
  ) {
    throw new InventoryStockError(
      'failed-precondition',
      'Workspace ownership is inconsistent.',
    );
  }
  return {cafeId, generation: activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid)};
}

function hash(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function replayResult({movement, activity, requestHash, payloadHash, uid, input}) {
  if (!movement && !activity) return null;
  if (!movement || !activity) {
    throw new InventoryStockError(
      'failed-precondition',
      'Stock adjustment audit is inconsistent.',
    );
  }
  const valid = movement.requestHash === requestHash &&
    movement.payloadHash === payloadHash &&
    movement.actorUid === uid &&
    movement.itemId === input.itemId &&
    activity.requestHash === requestHash &&
    activity.payloadHash === payloadHash &&
    activity.actorUid === uid &&
    activity.itemId === input.itemId &&
    movement.resultingQuantity === activity.resultingQuantity &&
    movement.resultVersion === activity.resultVersion;
  if (!valid) {
    throw new InventoryStockError(
      'already-exists',
      'The idempotency key conflicts with an earlier stock adjustment.',
    );
  }
  return {
    cafeId: movement.cafeId,
    itemId: input.itemId,
    direction: movement.direction,
    quantity: movement.quantity,
    resultingQuantity: movement.resultingQuantity,
    version: movement.resultVersion,
    adjusted: false,
  };
}

async function adjustInventoryStock({auth, data, store, timestamp}) {
  const uid = auth && auth.uid;
  if (!validId(uid)) {
    throw new InventoryStockError('unauthenticated', 'Authentication is required.');
  }
  const {episode, payload} = mutationEpisode(data, InventoryStockError);
  const input = validateInput(payload);

  return store.runTransaction(async (transaction) => {
    const {cafeId, generation} = await resolveActiveMembership(transaction, uid);
    assertMutationEpisode(episode, cafeId, generation, InventoryStockError);
    const requestHash = hash(`${uid}\u0000${cafeId}\u0000${input.idempotencyKey}`);
    const payloadHash = hash(JSON.stringify({
      episode,
      itemId: input.itemId,
      direction: input.direction,
      quantity: input.quantity,
      expectedVersion: input.expectedVersion,
      reason: input.reason,
    }));
    const movementId = `stock_${requestHash}`;
    const activityId = `inventory_stock_${requestHash}`;
    const movementPath =
      `cafes/${cafeId}/inventory_movements/${movementId}`;
    const activityPath = `cafes/${cafeId}/activities/${activityId}`;
    const replay = replayResult({
      movement: await transaction.get(movementPath),
      activity: await transaction.get(activityPath),
      requestHash,
      payloadHash,
      uid,
      input,
    });
    if (replay) return replay;

    const itemPath = `cafes/${cafeId}/inventory/${input.itemId}`;
    const item = await transaction.get(itemPath);
    if (!item) {
      throw new InventoryStockError('not-found', 'Inventory item not found.');
    }
    if (!Number.isSafeInteger(item.quantity) || item.quantity < 0) {
      throw new InventoryStockError(
        'failed-precondition',
        'Stored inventory quantity is invalid.',
      );
    }
    if (typeof item.unit !== 'string' || item.unit.length === 0) {
      throw new InventoryStockError(
        'failed-precondition',
        'Stored inventory unit is invalid.',
      );
    }
    const currentVersion = item.version == null ? 1 : item.version;
    const lifecycleState = item.lifecycleState == null ? 'active' : item.lifecycleState;
    if (lifecycleState !== 'active') {
      throw new InventoryStockError(
        'failed-precondition',
        lifecycleState === 'archived'
          ? 'Archived inventory items cannot be adjusted.'
          : 'Inventory lifecycle data is invalid.',
      );
    }
    if (!Number.isSafeInteger(currentVersion) || currentVersion < 1) {
      throw new InventoryStockError(
        'failed-precondition',
        'Inventory item version is invalid.',
      );
    }
    if (currentVersion !== input.expectedVersion) {
      throw new InventoryStockError(
        'aborted',
        'Inventory item changed. Refresh it before retrying.',
      );
    }

    let resultingQuantity;
    if (input.direction === 'in') {
      if (item.quantity > Number.MAX_SAFE_INTEGER - input.quantity) {
        throw new InventoryStockError(
          'out-of-range',
          'Stock adjustment exceeds the supported quantity range.',
        );
      }
      resultingQuantity = item.quantity + input.quantity;
    } else {
      if (input.quantity > item.quantity) {
        throw new InventoryStockError(
          'failed-precondition',
          'Stock out quantity exceeds available stock.',
        );
      }
      resultingQuantity = item.quantity - input.quantity;
    }

    const resultVersion = currentVersion + 1;
    const now = timestamp();
    transaction.update(itemPath, {
      quantity: resultingQuantity,
      version: resultVersion,
      updatedAt: now,
      updatedBy: uid,
      lastStockRequestHash: requestHash,
    });
    const commonAudit = {
      cafeId,
      itemId: input.itemId,
      actorUid: uid,
      direction: input.direction,
      quantity: input.quantity,
      previousQuantity: item.quantity,
      resultingQuantity,
      unit: item.unit,
      fromVersion: currentVersion,
      resultVersion,
      reason: input.reason,
      requestHash,
      payloadHash,
      schemaVersion: 1,
      createdAt: now,
    };
    transaction.create(movementPath, {
      ...commonAudit,
      type: input.direction === 'in' ? 'stock_in' : 'stock_out',
      delta: input.direction === 'in' ? input.quantity : -input.quantity,
    });
    transaction.create(activityPath, {
      ...commonAudit,
      type: 'inventory_stock_adjusted',
    });
    return {
      cafeId,
      itemId: input.itemId,
      direction: input.direction,
      quantity: input.quantity,
      resultingQuantity,
      version: resultVersion,
      adjusted: true,
    };
  });
}

module.exports = {
  InventoryStockError,
  adjustInventoryStock,
  validateInput,
};
