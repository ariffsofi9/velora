'use strict';

const {createHash} = require('node:crypto');

const ALLOWED_FIELDS = new Set([
  'idempotencyKey', 'itemId', 'action', 'expectedVersion',
]);

class InventoryLifecycleError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'InventoryLifecycleError';
    this.code = code;
  }
}

function invalid(message) {
  throw new InventoryLifecycleError('invalid-argument', message);
}

function validId(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 &&
    value.trim() === value && value !== '.' && value !== '..' &&
    !value.includes('/') && !/[\x00-\x1f]/.test(value);
}

function cleanKey(value) {
  if (typeof value !== 'string' || value.length < 16 || value.length > 128 ||
      value.trim() !== value || /\p{Cc}/u.test(value)) {
    invalid('Invalid idempotency key.');
  }
  return value;
}

function validateInput(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    invalid('Lifecycle request is required.');
  }
  for (const key of Object.keys(raw)) {
    if (!ALLOWED_FIELDS.has(key)) invalid(`Unsupported field: ${key}.`);
  }
  if (!validId(raw.itemId)) invalid('Invalid inventory item ID.');
  if (!['archive', 'restore'].includes(raw.action)) invalid('Invalid action.');
  if (!Number.isSafeInteger(raw.expectedVersion) || raw.expectedVersion < 1) {
    invalid('Expected version must be a positive integer.');
  }
  return {
    idempotencyKey: cleanKey(raw.idempotencyKey),
    itemId: raw.itemId,
    action: raw.action,
    expectedVersion: raw.expectedVersion,
  };
}

function activeLink(data, uid, cafeId) {
  return data && data.uid === uid && data.cafeId === cafeId &&
    data.status === 'active' && data.schemaVersion === 1;
}

async function resolveActiveMembership(transaction, uid) {
  const mapping = await transaction.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping && mapping.cafeId;
  if (!validId(cafeId) || !activeLink(mapping, uid, cafeId)) {
    throw new InventoryLifecycleError('permission-denied',
      'An active workspace membership is required.');
  }
  const cafe = await transaction.get(`cafes/${cafeId}`);
  const member = await transaction.get(`cafes/${cafeId}/members/${uid}`);
  const ownerUid = cafe && cafe.ownerUid;
  if (!validId(ownerUid) || !cafe || cafe.status !== 'active' ||
      cafe.schemaVersion !== 1 || !activeLink(member, uid, cafeId) ||
      !['owner', 'staff'].includes(member.role) ||
      (member.role === 'owner') !== (uid === ownerUid)) {
    throw new InventoryLifecycleError('permission-denied',
      'Workspace membership could not be verified.');
  }
  const ownerMember = await transaction.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMapping = await transaction.get(`user_cafe_memberships/${ownerUid}`);
  if (!activeLink(ownerMember, ownerUid, cafeId) || ownerMember.role !== 'owner' ||
      !activeLink(ownerMapping, ownerUid, cafeId)) {
    throw new InventoryLifecycleError('failed-precondition',
      'Workspace ownership is inconsistent.');
  }
  return cafeId;
}

function hash(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function lifecycleOf(item) {
  if (!Object.hasOwn(item, 'lifecycleState')) return 'active';
  if (item.lifecycleState === 'active' || item.lifecycleState === 'archived') {
    return item.lifecycleState;
  }
  throw new InventoryLifecycleError('failed-precondition',
    'Inventory lifecycle data is invalid.');
}

async function setInventoryLifecycle({
  auth, data, store, timestamp, deleteValue,
}) {
  const uid = auth && auth.uid;
  if (!validId(uid)) {
    throw new InventoryLifecycleError('unauthenticated', 'Authentication is required.');
  }
  const input = validateInput(data);
  return store.runTransaction(async (transaction) => {
    const cafeId = await resolveActiveMembership(transaction, uid);
    const requestHash = hash(`${uid}\u0000${cafeId}\u0000${input.idempotencyKey}`);
    const payloadHash = hash(JSON.stringify({
      itemId: input.itemId,
      action: input.action,
      expectedVersion: input.expectedVersion,
    }));
    const activityPath = `cafes/${cafeId}/activities/inventory_lifecycle_${requestHash}`;
    const previous = await transaction.get(activityPath);
    if (previous) {
      if (previous.requestHash !== requestHash || previous.payloadHash !== payloadHash ||
          previous.actorUid !== uid || previous.itemId !== input.itemId) {
        throw new InventoryLifecycleError('already-exists',
          'The idempotency key conflicts with an earlier request.');
      }
      return {
        cafeId, itemId: input.itemId, lifecycleState: previous.resultState,
        version: previous.resultVersion, changed: false,
      };
    }

    const itemPath = `cafes/${cafeId}/inventory/${input.itemId}`;
    const item = await transaction.get(itemPath);
    if (!item) throw new InventoryLifecycleError('not-found', 'Inventory item not found.');
    const currentVersion = item.version == null ? 1 : item.version;
    if (!Number.isSafeInteger(currentVersion) || currentVersion < 1 ||
        currentVersion !== input.expectedVersion) {
      throw new InventoryLifecycleError('aborted',
        'Inventory item changed. Refresh it before retrying.');
    }
    if (!Number.isSafeInteger(item.quantity) || item.quantity < 0) {
      throw new InventoryLifecycleError('failed-precondition',
        'Stored inventory quantity is invalid.');
    }
    const currentState = lifecycleOf(item);
    const resultState = input.action === 'archive' ? 'archived' : 'active';
    if (currentState === resultState) {
      throw new InventoryLifecycleError('failed-precondition',
        `Inventory item is already ${resultState}.`);
    }
    const resultVersion = currentVersion + 1;
    const now = timestamp();
    const changes = {
      lifecycleState: resultState,
      version: resultVersion,
      updatedAt: now,
      updatedBy: uid,
      lastLifecycleRequestHash: requestHash,
    };
    if (resultState === 'archived') {
      changes.archivedAt = now;
      changes.archivedBy = uid;
    } else {
      changes.archivedAt = deleteValue();
      changes.archivedBy = deleteValue();
    }
    transaction.update(itemPath, changes);
    transaction.create(activityPath, {
      cafeId,
      itemId: input.itemId,
      type: resultState === 'archived' ? 'inventory_archived' : 'inventory_restored',
      actorUid: uid,
      fromState: currentState,
      resultState,
      preservedQuantity: item.quantity,
      fromVersion: currentVersion,
      resultVersion,
      requestHash,
      payloadHash,
      schemaVersion: 1,
      createdAt: now,
    });
    return {cafeId, itemId: input.itemId, lifecycleState: resultState,
      version: resultVersion, changed: true};
  });
}

module.exports = {
  InventoryLifecycleError,
  setInventoryLifecycle,
  validateInput,
};
