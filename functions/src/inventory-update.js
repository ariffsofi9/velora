'use strict';
const {mutationEpisode, assertMutationEpisode} = require('./mutation-episode');
const {activeMembershipGeneration} = require('./membership-generation');

const {createHash} = require('node:crypto');

const SUPPORTED_UNITS = new Set(['kg', 'g', 'L', 'ml', 'pcs']);
const EDITABLE_FIELDS = new Set([
  'name',
  'category',
  'unit',
  'expiryDate',
  'imageUrl',
]);
const REQUIRED_FIELDS = new Set([
  'idempotencyKey',
  'itemId',
  'expectedVersion',
]);
const FORBIDDEN_FIELDS = new Set([
  'quantity',
  'cafeId',
  'uid',
  'actorUid',
  'ownerUid',
  'role',
  'createdBy',
  'createdAt',
  'updatedBy',
  'updatedAt',
  'schemaVersion',
  'requestHash',
  'createRequestHash',
  'createPayloadHash',
  'lastUpdateRequestHash',
  'version',
]);

class InventoryUpdateError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'InventoryUpdateError';
    this.code = code;
  }
}

function invalid(message) {
  throw new InventoryUpdateError('invalid-argument', message);
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

function parseExpiryDate(value) {
  if (typeof value !== 'string' || value.length > 40) {
    invalid('Expiry date must be an ISO-8601 date string.');
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value) {
    invalid('Expiry date must be an exact ISO-8601 date string.');
  }
  return date;
}

function cleanImageUrl(value) {
  const cleaned = cleanText(value, 'Image URL', {max: 2048});
  if (cleaned === '') return '';
  let url;
  try {
    url = new URL(cleaned);
  } catch (_) {
    invalid('Image URL must be empty or a valid HTTPS URL.');
  }
  if (url.protocol !== 'https:' || url.username || url.password) {
    invalid('Image URL must be empty or a valid HTTPS URL.');
  }
  return url.toString();
}

function validateInput(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    invalid('Inventory update data is required.');
  }
  for (const key of Object.keys(raw)) {
    if (FORBIDDEN_FIELDS.has(key)) invalid(`${key} cannot be edited.`);
    if (!REQUIRED_FIELDS.has(key) && !EDITABLE_FIELDS.has(key)) {
      invalid(`Unsupported field: ${key}.`);
    }
  }

  const idempotencyKey = cleanText(raw.idempotencyKey, 'Idempotency key', {
    min: 16,
    max: 128,
  });
  if (!validId(raw.itemId)) invalid('Invalid inventory item ID.');
  if (!Number.isSafeInteger(raw.expectedVersion) || raw.expectedVersion < 1) {
    invalid('Expected version must be a positive integer.');
  }

  const changes = {};
  if (Object.hasOwn(raw, 'name')) {
    changes.name = cleanText(raw.name, 'Item name', {min: 1, max: 100});
  }
  if (Object.hasOwn(raw, 'category')) {
    changes.category = cleanText(raw.category, 'Category', {min: 1, max: 60});
  }
  if (Object.hasOwn(raw, 'unit')) {
    if (!SUPPORTED_UNITS.has(raw.unit)) invalid('Unsupported inventory unit.');
    changes.unit = raw.unit;
  }
  if (Object.hasOwn(raw, 'expiryDate')) {
    changes.expiryDate = parseExpiryDate(raw.expiryDate);
  }
  if (Object.hasOwn(raw, 'imageUrl')) {
    changes.imageUrl = cleanImageUrl(raw.imageUrl);
  }
  if (Object.keys(changes).length === 0) {
    invalid('At least one editable field is required.');
  }

  return {
    idempotencyKey,
    itemId: raw.itemId,
    expectedVersion: raw.expectedVersion,
    changes,
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
    throw new InventoryUpdateError(
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
    throw new InventoryUpdateError(
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
    throw new InventoryUpdateError(
      'failed-precondition',
      'Workspace ownership is inconsistent.',
    );
  }
  return {cafeId, generation: activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid)};
}

function hash(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function normalizedChanges(changes) {
  const result = {};
  for (const key of [...Object.keys(changes)].sort()) {
    result[key] = key === 'expiryDate'
      ? changes[key].toISOString()
      : changes[key];
  }
  return result;
}

function comparable(value) {
  if (value instanceof Date) return value.toISOString();
  if (value && typeof value.toDate === 'function') {
    return value.toDate().toISOString();
  }
  return value;
}

async function updateInventoryItem({auth, data, store, timestamp, toTimestamp}) {
  const uid = auth && auth.uid;
  if (!validId(uid)) {
    throw new InventoryUpdateError(
      'unauthenticated',
      'Authentication is required.',
    );
  }
  const {episode, payload} = mutationEpisode(data, InventoryUpdateError);
  const input = validateInput(payload);

  return store.runTransaction(async (transaction) => {
    const {cafeId, generation} = await resolveActiveMembership(transaction, uid);
    assertMutationEpisode(episode, cafeId, generation, InventoryUpdateError);
    const requestHash = hash(`${uid}\u0000${cafeId}\u0000${input.idempotencyKey}`);
    const inputHash = hash(JSON.stringify({
      episode,
      itemId: input.itemId,
      expectedVersion: input.expectedVersion,
      changes: normalizedChanges(input.changes),
    }));
    const activityId = `inventory_update_${requestHash}`;
    const activityPath = `cafes/${cafeId}/activities/${activityId}`;
    const previousAttempt = await transaction.get(activityPath);
    if (previousAttempt) {
      if (
        previousAttempt.requestHash !== requestHash ||
        previousAttempt.payloadHash !== inputHash ||
        previousAttempt.actorUid !== uid ||
        previousAttempt.itemId !== input.itemId
      ) {
        throw new InventoryUpdateError(
          'already-exists',
          'The idempotency key conflicts with an earlier update.',
        );
      }
      return {
        cafeId,
        itemId: input.itemId,
        updated: previousAttempt.updated,
        version: previousAttempt.resultVersion,
      };
    }

    const itemPath = `cafes/${cafeId}/inventory/${input.itemId}`;
    const item = await transaction.get(itemPath);
    if (!item) {
      throw new InventoryUpdateError('not-found', 'Inventory item not found.');
    }
    const currentVersion = item.version == null ? 1 : item.version;
    const lifecycleState = item.lifecycleState == null ? 'active' : item.lifecycleState;
    if (lifecycleState !== 'active') {
      throw new InventoryUpdateError(
        'failed-precondition',
        lifecycleState === 'archived'
          ? 'Archived inventory items cannot be edited.'
          : 'Inventory lifecycle data is invalid.',
      );
    }
    if (!Number.isSafeInteger(currentVersion) || currentVersion < 1) {
      throw new InventoryUpdateError(
        'failed-precondition',
        'Inventory item version is invalid.',
      );
    }
    if (currentVersion !== input.expectedVersion) {
      throw new InventoryUpdateError(
        'aborted',
        'Inventory item changed. Refresh it before retrying.',
      );
    }

    const changes = {};
    for (const [key, value] of Object.entries(input.changes)) {
      if (comparable(item[key]) !== comparable(value)) changes[key] = value;
    }
    const updated = Object.keys(changes).length > 0;
    const resultVersion = updated ? currentVersion + 1 : currentVersion;
    const now = timestamp();
    if (updated) {
      const persistedChanges = {...changes};
      if (changes.expiryDate) {
        persistedChanges.expiryDate = toTimestamp(changes.expiryDate);
      }
      transaction.update(itemPath, {
        ...persistedChanges,
        version: resultVersion,
        updatedAt: now,
        updatedBy: uid,
        lastUpdateRequestHash: requestHash,
      });
    }
    transaction.create(activityPath, {
      cafeId,
      itemId: input.itemId,
      type: updated ? 'inventory_updated' : 'inventory_update_noop',
      actorUid: uid,
      changedFields: Object.keys(changes).sort(),
      fromVersion: currentVersion,
      resultVersion,
      updated,
      requestHash,
      payloadHash: inputHash,
      schemaVersion: 1,
      createdAt: now,
    });
    return {cafeId, itemId: input.itemId, updated, version: resultVersion};
  });
}

module.exports = {
  InventoryUpdateError,
  updateInventoryItem,
  validateInput,
};
