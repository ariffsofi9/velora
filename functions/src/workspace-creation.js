'use strict';

const BUSINESS_TYPES = new Set([
  'Restaurant',
  'Café',
  'Bakery',
  'Catering',
  'Cloud Kitchen',
  'Other',
]);
const INVENTORY_UNITS = new Set(['kg', 'g', 'L', 'ml', 'pcs']);
const REMINDER_DAYS = new Set([1, 3, 7]);
const ALLOWED_FIELDS = new Set([
  'businessName',
  'businessType',
  'address',
  'inventoryUnit',
  'lowStockAlerts',
  'expiryReminders',
  'reminderDays',
]);
const FORBIDDEN_AUTHORITY_FIELDS = new Set([
  'uid',
  'ownerUid',
  'role',
  'cafeId',
  'businessId',
]);

class WorkspaceCreationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'WorkspaceCreationError';
    this.code = code;
  }
}

function invalid(message) {
  throw new WorkspaceCreationError('invalid-argument', message);
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
    invalid('Workspace setup data is required.');
  }
  for (const key of Object.keys(raw)) {
    if (FORBIDDEN_AUTHORITY_FIELDS.has(key)) {
      invalid(`${key} cannot be supplied by the client.`);
    }
    if (!ALLOWED_FIELDS.has(key)) invalid(`Unsupported field: ${key}.`);
  }

  const businessName = cleanText(raw.businessName, 'Business name', {
    min: 2,
    max: 80,
  });
  const businessType = cleanText(raw.businessType, 'Business type', {
    min: 2,
    max: 40,
  });
  if (!BUSINESS_TYPES.has(businessType)) invalid('Unsupported business type.');

  const address = raw.address == null
    ? ''
    : cleanText(raw.address, 'Business address', {max: 200});
  const inventoryUnit = raw.inventoryUnit ?? 'kg';
  if (!INVENTORY_UNITS.has(inventoryUnit)) invalid('Unsupported inventory unit.');

  const lowStockAlerts = raw.lowStockAlerts ?? true;
  const expiryReminders = raw.expiryReminders ?? true;
  const reminderDays = raw.reminderDays ?? 3;
  if (typeof lowStockAlerts !== 'boolean') invalid('Invalid low-stock setting.');
  if (typeof expiryReminders !== 'boolean') invalid('Invalid expiry setting.');
  if (!REMINDER_DAYS.has(reminderDays)) invalid('Invalid reminder timing.');

  return {
    businessName,
    businessType,
    address,
    inventoryUnit,
    lowStockAlerts,
    expiryReminders,
    reminderDays,
  };
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

function activeLink(data, uid, cafeId) {
  return data &&
    data.uid === uid &&
    data.cafeId === cafeId &&
    data.status === 'active' &&
    data.schemaVersion === 1;
}

async function createWorkspace({auth, data, store, idFactory, timestamp}) {
  const uid = auth && auth.uid;
  if (!validId(uid)) {
    throw new WorkspaceCreationError(
      'unauthenticated',
      'Authentication is required.',
    );
  }
  const input = validateInput(data);
  const proposedCafeId = idFactory();
  if (!validId(proposedCafeId)) {
    throw new WorkspaceCreationError('internal', 'Workspace ID generation failed.');
  }

  return store.runTransaction(async (transaction) => {
    const mappingPath = `user_cafe_memberships/${uid}`;
    const mapping = await transaction.get(mappingPath);
    if (mapping) {
      const existingCafeId = mapping.cafeId;
      if (!validId(existingCafeId) || !activeLink(mapping, uid, existingCafeId)) {
        throw new WorkspaceCreationError(
          'failed-precondition',
          'Existing workspace membership is inconsistent.',
        );
      }
      const cafe = await transaction.get(`cafes/${existingCafeId}`);
      const member = await transaction.get(
        `cafes/${existingCafeId}/members/${uid}`,
      );
      if (
        !cafe ||
        cafe.ownerUid !== uid ||
        cafe.status !== 'active' ||
        cafe.schemaVersion !== 1 ||
        !activeLink(member, uid, existingCafeId) ||
        member.role !== 'owner'
      ) {
        throw new WorkspaceCreationError(
          'already-exists',
          'This account already belongs to a workspace.',
        );
      }
      return {cafeId: existingCafeId, created: false};
    }

    const cafeId = proposedCafeId;
    const now = timestamp();
    transaction.create(`cafes/${cafeId}`, {
      ownerUid: uid,
      name: input.businessName,
      businessType: input.businessType,
      address: input.address,
      inventoryPreferences: {
        unit: input.inventoryUnit,
        lowStockAlerts: input.lowStockAlerts,
        expiryReminders: input.expiryReminders,
        reminderDays: input.reminderDays,
      },
      status: 'active',
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
    transaction.create(`cafes/${cafeId}/members/${uid}`, {
      uid,
      cafeId,
      role: 'owner',
      status: 'active',
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
    transaction.create(mappingPath, {
      uid,
      cafeId,
      status: 'active',
      schemaVersion: 1,
      createdAt: now,
      updatedAt: now,
    });
    return {cafeId, created: true};
  });
}

module.exports = {
  WorkspaceCreationError,
  createWorkspace,
  validateInput,
};
