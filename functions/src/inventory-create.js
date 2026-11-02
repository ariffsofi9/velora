'use strict';

const {createHash} = require('node:crypto');

const SUPPORTED_UNITS = new Set(['kg', 'g', 'L', 'ml', 'pcs']);
const ALLOWED_FIELDS = new Set([
  'idempotencyKey',
  'name',
  'category',
  'quantity',
  'unit',
  'expiryDate',
  'imageUrl',
]);
const FORBIDDEN_AUTHORITY_FIELDS = new Set([
  'uid',
  'actorUid',
  'ownerUid',
  'role',
  'cafeId',
  'businessId',
  'itemId',
]);

class InventoryCreationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'InventoryCreationError';
    this.code = code;
  }
}

function invalid(message) {
  throw new InventoryCreationError('invalid-argument', message);
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

function validateInput(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    invalid('Inventory item data is required.');
  }
  for (const key of Object.keys(raw)) {
    if (FORBIDDEN_AUTHORITY_FIELDS.has(key)) {
      invalid(`${key} cannot be supplied by the client.`);
    }
    if (!ALLOWED_FIELDS.has(key)) invalid(`Unsupported field: ${key}.`);
  }

  const idempotencyKey = cleanText(raw.idempotencyKey, 'Idempotency key', {
    min: 16,
    max: 128,
  });
  const name = cleanText(raw.name, 'Item name', {min: 1, max: 100});
  const category = cleanText(raw.category, 'Category', {min: 1, max: 60});
  if (!Number.isSafeInteger(raw.quantity) || raw.quantity < 0) {
    invalid('Quantity must be a non-negative integer.');
  }
  if (!SUPPORTED_UNITS.has(raw.unit)) invalid('Unsupported inventory unit.');
  const expiryDate = parseExpiryDate(raw.expiryDate);
  const imageUrl = raw.imageUrl == null
    ? ''
    : cleanText(raw.imageUrl, 'Image URL', {max: 2048});

  return {
    idempotencyKey,
    name,
    category,
    quantity: raw.quantity,
    unit: raw.unit,
    expiryDate,
    imageUrl,
  };
}

function activeLink(data, uid, cafeId) {
  return data &&
    data.uid === uid &&
    data.cafeId === cafeId &&
    data.status === 'active' &&
    data.schemaVersion === 1;
}

function requestHash(uid, cafeId, idempotencyKey) {
  return createHash('sha256')
    .update(`${uid}\u0000${cafeId}\u0000${idempotencyKey}`, 'utf8')
    .digest('hex');
}

function payloadHash(input) {
  return createHash('sha256')
    .update(JSON.stringify({
      name: input.name,
      category: input.category,
      quantity: input.quantity,
      unit: input.unit,
      expiryDate: input.expiryDate.toISOString(),
      imageUrl: input.imageUrl,
    }), 'utf8')
    .digest('hex');
}

async function resolveActiveMembership(transaction, uid) {
  const mapping = await transaction.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping && mapping.cafeId;
  if (!validId(cafeId) || !activeLink(mapping, uid, cafeId)) {
    throw new InventoryCreationError(
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
    (member.role === 'owner') !== (uid === ownerUid)
  ) {
    throw new InventoryCreationError(
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
    !activeLink(ownerMapping, ownerUid, cafeId)
  ) {
    throw new InventoryCreationError(
      'failed-precondition',
      'Workspace ownership is inconsistent.',
    );
  }

  return {cafeId, role: member.role};
}

async function createInventoryItem({auth, data, store, timestamp, toTimestamp}) {
  const uid = auth && auth.uid;
  if (!validId(uid)) {
    throw new InventoryCreationError(
      'unauthenticated',
      'Authentication is required.',
    );
  }
  const input = validateInput(data);

  return store.runTransaction(async (transaction) => {
    const {cafeId} = await resolveActiveMembership(transaction, uid);
    const hash = requestHash(uid, cafeId, input.idempotencyKey);
    const inputHash = payloadHash(input);
    const itemId = `item_${hash}`;
    const movementId = `create_${hash}`;
    const activityId = `inventory_create_${hash}`;
    const itemPath = `cafes/${cafeId}/inventory/${itemId}`;
    const existing = await transaction.get(itemPath);
    if (existing) {
      if (
        existing.createRequestHash !== hash ||
        existing.createPayloadHash !== inputHash ||
        existing.createdBy !== uid
      ) {
        throw new InventoryCreationError(
          'already-exists',
          'The idempotency key conflicts with an existing item.',
        );
      }
      return {cafeId, itemId, created: false};
    }

    const now = timestamp();
    const expiryDate = toTimestamp(input.expiryDate);
    transaction.create(itemPath, {
      cafeId,
      name: input.name,
      category: input.category,
      quantity: input.quantity,
      unit: input.unit,
      expiryDate,
      imageUrl: input.imageUrl,
      createdBy: uid,
      createRequestHash: hash,
      createPayloadHash: inputHash,
      lifecycleState: 'active',
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
    transaction.create(
      `cafes/${cafeId}/inventory_movements/${movementId}`,
      {
        cafeId,
        itemId,
        type: 'initial_stock',
        quantity: input.quantity,
        unit: input.unit,
        actorUid: uid,
        requestHash: hash,
        schemaVersion: 1,
        createdAt: now,
      },
    );
    transaction.create(`cafes/${cafeId}/activities/${activityId}`, {
      cafeId,
      itemId,
      type: 'inventory_created',
      itemName: input.name,
      quantity: input.quantity,
      unit: input.unit,
      actorUid: uid,
      requestHash: hash,
      schemaVersion: 1,
      createdAt: now,
    });
    return {cafeId, itemId, created: true};
  });
}

module.exports = {
  InventoryCreationError,
  createInventoryItem,
  validateInput,
};
