'use strict';

const MAX_PRICE_MINOR = 1000000; // MYR sen: RM 10,000.00; never floating-point money.
class MenuError extends Error {
  constructor(code, message = 'Menu request could not be completed.') {
    super(message); this.code = code;
  }
}
const invalid = () => { throw new MenuError('invalid-argument', 'Invalid menu request.'); };
function validId(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !['.', '..'].includes(value) && !/[\\/\p{Cc}]/u.test(value);
}
function fields(data, allowed, required = []) {
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      Object.keys(data).some(key => !allowed.includes(key)) ||
      required.some(key => !Object.hasOwn(data, key))) invalid();
}
function text(value, max) {
  if (typeof value !== 'string' || /\p{Cc}/u.test(value)) invalid();
  const result = value.trim().replace(/\s+/g, ' ');
  if (!result || result.length > max) invalid();
  return result;
}
function editable(data) {
  const result = {};
  if (Object.hasOwn(data, 'name')) result.name = text(data.name, 100);
  if (Object.hasOwn(data, 'category')) result.category = text(data.category, 60);
  if (Object.hasOwn(data, 'priceMinor')) {
    if (!Number.isSafeInteger(data.priceMinor) || data.priceMinor < 0 || data.priceMinor > MAX_PRICE_MINOR) invalid();
    result.priceMinor = data.priceMinor;
  }
  if (Object.hasOwn(data, 'isAvailable')) {
    if (typeof data.isAvailable !== 'boolean') invalid();
    result.isAvailable = data.isAvailable;
  }
  return result;
}
function parseRequest(operation, data) {
  const edits = ['name', 'category', 'priceMinor', 'isAvailable'];
  if (operation === 'list') {
    fields(data, ['includeArchived', 'limit', 'cursor']);
    if (data.includeArchived !== undefined && typeof data.includeArchived !== 'boolean') invalid();
    if (data.cursor !== undefined && !validId(data.cursor)) invalid();
    const limit = data.limit === undefined ? 20 : data.limit;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) invalid();
    return {includeArchived: data.includeArchived === true, limit, cursor: data.cursor ?? null};
  }
  if (operation === 'get') {
    fields(data, ['itemId'], ['itemId']);
    if (!validId(data.itemId)) invalid();
    return {itemId: data.itemId};
  }
  const required = operation === 'create' ? ['idempotencyKey', ...edits] :
    ['idempotencyKey', 'itemId', 'expectedVersion'];
  const allowed = operation === 'create' ? required :
    [...required, ...(operation === 'update' ? edits : ['action'])];
  if (!['create', 'update', 'lifecycle'].includes(operation)) invalid();
  fields(data, allowed, required);
  if (typeof data.idempotencyKey !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(data.idempotencyKey)) invalid();
  const result = {idempotencyKey: data.idempotencyKey};
  if (operation !== 'create') {
    if (!validId(data.itemId) || !Number.isSafeInteger(data.expectedVersion) || data.expectedVersion < 1) invalid();
    result.itemId = data.itemId; result.expectedVersion = data.expectedVersion;
  }
  if (operation === 'lifecycle') {
    if (!['archive', 'restore'].includes(data.action)) invalid();
    result.action = data.action;
  } else {
    result.changes = editable(data);
    if (!Object.keys(result.changes).length) invalid();
  }
  return result;
}
function date(value) {
  const result = value instanceof Date ? value : value?.toDate?.();
  if (!(result instanceof Date) || !Number.isFinite(result.getTime())) throw Error('Invalid timestamp');
  return result.toISOString();
}
function menuDocument(id, data, cafeId) {
  try {
    if (!validId(id) || !data || data.cafeId !== cafeId || data.schemaVersion !== 1 ||
        data.currency !== 'MYR' || !Number.isSafeInteger(data.version) || data.version < 1 ||
        typeof data.isArchived !== 'boolean' || !validId(data.createdBy) || !validId(data.updatedBy)) throw Error('Invalid menu');
    const changes = editable(data);
    if (Object.keys(changes).length !== 4 || changes.name !== data.name || changes.category !== data.category) throw Error('Invalid menu');
    return {id, cafeId, ...changes, currency: 'MYR', isArchived: data.isArchived,
      version: data.version, createdAt: date(data.createdAt), updatedAt: date(data.updatedAt),
      createdBy: data.createdBy, updatedBy: data.updatedBy};
  } catch (_) {
    throw new MenuError('failed-precondition', 'Stored menu data could not be verified.');
  }
}
module.exports = {MenuError, MAX_PRICE_MINOR, validId, parseRequest, menuDocument};
