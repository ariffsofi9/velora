'use strict';

const {createHash} = require('node:crypto');
const {mutationEpisode} = require('./mutation-episode');

class SavedRecipeError extends Error {
  constructor(code, outcomeUnknown = false) {
    super('Saved recipes are unavailable.');
    this.code = code;
    // Shared episode helpers pass an optional message as the second argument.
    // Only this domain's explicit boolean can classify uncertainty.
    this.outcomeUnknown = outcomeUnknown === true;
    this.reason = this.outcomeUnknown ? 'outcome-unknown' : undefined;
  }
}
const fail = code => { throw new SavedRecipeError(code); };
const integer = (n, min = 0) => Number.isSafeInteger(n) && n >= min;
const digest = s => typeof s === 'string' && /^[a-f0-9]{64}$/.test(s);
const recipeId = s => typeof s === 'string' && /^recipe_[a-f0-9]{64}$/.test(s);
function fields(value, names) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
      Reflect.ownKeys(value).length !== names.length ||
      names.some(key => !Object.hasOwn(value, key) ||
        !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) fail('invalid-argument');
}
function text(value, max) {
  if (typeof value !== 'string' || !value.length || value.length > max ||
      value.trim() !== value || /\p{Cc}|[\uD800-\uDFFF]/u.test(value)) fail('invalid-argument');
  return value;
}
function validId(s) {
  try { text(s, 128); return !['.', '..'].includes(s) && !/[\\/]/u.test(s); }
  catch { return false; }
}
function array(value, max) {
  if (!Array.isArray(value) || value.length < 1 || value.length > max ||
      Reflect.ownKeys(value).length !== value.length + 1 ||
      Array.from({length: value.length}, (_, i) => String(i)).some(key =>
        !Object.hasOwn(value, key) || !Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value'))) fail('invalid-argument');
}
function boundedJson(value, max, code = 'invalid-argument') {
  try {
    const json = JSON.stringify(value);
    if (typeof json !== 'string' || Buffer.byteLength(json, 'utf8') > max) fail(code);
    return json;
  } catch { fail(code); }
}
function parseRecipe(value) {
  fields(value, ['title', 'ingredients', 'steps', 'whyRecommended']);
  array(value.ingredients, 10); array(value.steps, 8);
  const seen = new Set();
  const result = {
    title: text(value.title, 100),
    ingredients: value.ingredients.map(i => {
      fields(i, ['itemId', 'quantity', 'unit']);
      if (!validId(i.itemId) || seen.has(i.itemId) || typeof i.quantity !== 'number' ||
          !Number.isFinite(i.quantity) || i.quantity <= 0 || i.quantity > 1000000 ||
          !['kg', 'g', 'L', 'ml', 'pcs'].includes(i.unit) ||
          (i.unit === 'pcs' && !Number.isInteger(i.quantity))) fail('invalid-argument');
      seen.add(i.itemId);
      return {itemId: i.itemId, quantity: i.quantity, unit: i.unit};
    }),
    steps: value.steps.map(s => text(s, 300)),
    whyRecommended: text(value.whyRecommended, 300),
  };
  boundedJson(result, 16384);
  return result;
}
function parseAttribution(value) {
  fields(value, ['kind', 'provider', 'ticketId']);
  if (!['unspecified', 'claimed-ai', 'sample', 'mock'].includes(value.kind) ||
      ![null, 'groq'].includes(value.provider) ||
      (value.ticketId !== null && !digest(value.ticketId)) ||
      (value.kind !== 'claimed-ai' && (value.provider !== null || value.ticketId !== null))) fail('invalid-argument');
  return {kind: value.kind, provider: value.provider, ticketId: value.ticketId};
}
const hash = s => createHash('sha256').update(s, 'utf8').digest('hex');
function canonicalContent(value) {
  const r = parseRecipe(value);
  return JSON.stringify(['velora.saved-recipe.content.v1', r.title,
    r.ingredients.map(i => [i.itemId, i.quantity, i.unit]), r.steps, r.whyRecommended]);
}
function identity(projectId, cafeId, value) {
  if (!validId(projectId) || !validId(cafeId)) fail('invalid-argument');
  const content = canonicalContent(value), contentDigest = hash(content);
  return {content, contentDigest, recipeId: 'recipe_' + hash(JSON.stringify([
    'velora.saved-recipe.id.v1', projectId, cafeId, contentDigest]))};
}
const expectationKeys = ['expectedCafeId', 'expectedMembershipGeneration'];
const cursorKeys = ['schemaVersion', 'projectId', 'cafeId', 'uid', 'membershipGeneration', 'mode', 'limit', 'afterId'];
function parseCursor(value) {
  if (value === null) return null;
  fields(value, cursorKeys);
  if (value.schemaVersion !== 1 || !validId(value.projectId) || !validId(value.cafeId) ||
      !validId(value.uid) || !integer(value.membershipGeneration) ||
      !['active', 'archived', 'all'].includes(value.mode) || !integer(value.limit, 1) ||
      value.limit > 20 || !recipeId(value.afterId)) fail('invalid-argument');
  return Object.fromEntries(cursorKeys.map(k => [k, value[k]]));
}
function parseRequest(operation, data) {
  if (operation === 'reconcile') {
    fields(data, ['operation', 'request']);
    if (!['save', 'lifecycle'].includes(data.operation)) fail('invalid-argument');
    const original = parseRequest(data.operation, data.request);
    boundedJson(data, 32768);
    return {operation: data.operation, original};
  }
  const operations = {save: ['idempotencyKey', 'recipe', 'attribution'], get: ['recipeId'],
    list: ['mode', 'limit', 'cursor'], lifecycle: ['idempotencyKey', 'recipeId', 'expectedVersion', 'action']};
  if (typeof operation !== 'string' || !Object.hasOwn(operations, operation)) fail('invalid-argument');
  const keys = operations[operation];
  fields(data, [...expectationKeys, ...keys]);
  const {episode} = mutationEpisode(data, SavedRecipeError);
  if (!validId(episode.expectedCafeId)) fail('invalid-argument');
  const input = {};
  if (['save', 'lifecycle'].includes(operation)) {
    if (typeof data.idempotencyKey !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(data.idempotencyKey)) fail('invalid-argument');
    input.idempotencyKey = data.idempotencyKey;
  }
  if (operation === 'save') {
    input.recipe = parseRecipe(data.recipe); input.attribution = parseAttribution(data.attribution);
  } else if (operation === 'get' || operation === 'lifecycle') {
    if (!recipeId(data.recipeId)) fail('invalid-argument');
    input.recipeId = data.recipeId;
    if (operation === 'lifecycle') {
      if (!integer(data.expectedVersion, 1) || !['archive', 'restore'].includes(data.action)) fail('invalid-argument');
      input.expectedVersion = data.expectedVersion; input.action = data.action;
    }
  } else {
    if (!['active', 'archived', 'all'].includes(data.mode) || !integer(data.limit, 1) || data.limit > 20) fail('invalid-argument');
    input.mode = data.mode; input.limit = data.limit; input.cursor = parseCursor(data.cursor);
  }
  boundedJson(data, 32768);
  return {episode, input};
}
function requestBinding(projectId, uid, cafeId, operation, parsed) {
  const {episode, input} = parsed;
  const requestHash = hash(JSON.stringify(['velora.saved-recipe.request.v1', projectId, uid, cafeId, input.idempotencyKey]));
  const content = operation === 'save' ? identity(projectId, cafeId, input.recipe) : null;
  const payload = operation === 'save'
    ? ['save', episode.expectedCafeId, episode.expectedMembershipGeneration, content.contentDigest,
      input.attribution.kind, input.attribution.provider, input.attribution.ticketId]
    : ['lifecycle', episode.expectedCafeId, episode.expectedMembershipGeneration, input.recipeId, input.expectedVersion, input.action];
  return {requestHash, payloadHash: hash(JSON.stringify(['velora.saved-recipe.payload.v1', payload])),
    recipeId: content?.recipeId ?? input.recipeId, content};
}
function date(value) {
  // The injected store must expose persisted timestamps as Date/toDate values.
  const d = value instanceof Date ? value : value?.toDate?.();
  if (!(d instanceof Date) || !Number.isFinite(d.getTime())) fail('failed-precondition');
  return d.toISOString();
}
const recordKeys = ['schemaVersion', 'projectId', 'cafeId', 'recipeId', 'contentDigest', 'recipe',
  'source', 'provenanceEvidence', 'submittedAttribution', 'createdBy', 'updatedBy', 'createdAt',
  'updatedAt', 'version', 'isArchived', 'archivedBy', 'archivedAt'];
function recipeDocument(id, data, projectId, cafeId) {
  try {
    fields(data, recordKeys);
    const value = parseRecipe(data.recipe), content = identity(projectId, cafeId, value);
    if (!recipeId(id) || id !== content.recipeId || data.recipeId !== id || data.schemaVersion !== 1 ||
        data.projectId !== projectId || data.cafeId !== cafeId || data.contentDigest !== content.contentDigest ||
        data.source !== 'workspace-submitted' || data.provenanceEvidence !== 'unverified-attribution' ||
        !validId(data.createdBy) || !validId(data.updatedBy) || !integer(data.version, 1) ||
        typeof data.isArchived !== 'boolean') fail('failed-precondition');
    const createdAt = date(data.createdAt), updatedAt = date(data.updatedAt);
    if (Date.parse(updatedAt) < Date.parse(createdAt)) fail('failed-precondition');
    const archivedAt = data.isArchived ? date(data.archivedAt) : null;
    if (data.isArchived ? !validId(data.archivedBy) || data.archivedBy !== data.updatedBy || archivedAt !== updatedAt
      : data.archivedAt !== null || data.archivedBy !== null) fail('failed-precondition');
    if (data.version === 1 && (data.isArchived || createdAt !== updatedAt || data.createdBy !== data.updatedBy)) fail('failed-precondition');
    const result = {...data, recipe: value, submittedAttribution: parseAttribution(data.submittedAttribution),
      createdAt, updatedAt, archivedAt};
    boundedJson(result, 32768, 'failed-precondition');
    return result;
  } catch { fail('failed-precondition'); }
}
const receiptKeys = ['schemaVersion', 'projectId', 'cafeId', 'actorUid', 'actorGeneration', 'requestHash',
  'payloadHash', 'operation', 'recipeId', 'contentDigest', 'resultVersion', 'resultIsArchived', 'outcome', 'changed', 'createdAt'];
function receiptDocument(data) {
  try {
    fields(data, receiptKeys);
    if (data.schemaVersion !== 1 || !validId(data.projectId) || !validId(data.cafeId) || !validId(data.actorUid) ||
        !integer(data.actorGeneration) || !digest(data.requestHash) || !digest(data.payloadHash) ||
        !recipeId(data.recipeId) || !digest(data.contentDigest) || !integer(data.resultVersion, 1) ||
        typeof data.resultIsArchived !== 'boolean' || typeof data.changed !== 'boolean') fail('failed-precondition');
    const combinations = {created: ['save', true, false], 'existing-active': ['save', false, false],
      'existing-archived': ['save', false, true], archived: ['lifecycle', true, true], restored: ['lifecycle', true, false]};
    const expected = Object.hasOwn(combinations, data.outcome) ? combinations[data.outcome] : null;
    if (!expected || data.operation !== expected[0] || data.changed !== expected[1] || data.resultIsArchived !== expected[2] ||
        (data.outcome === 'created' && data.resultVersion !== 1)) fail('failed-precondition');
    const result = {...data, createdAt: date(data.createdAt)};
    boundedJson(result, 32768, 'failed-precondition');
    return result;
  } catch { fail('failed-precondition'); }
}
module.exports = {SavedRecipeError, fail, fields, integer, validId, boundedJson, parseRecipe, parseAttribution,
  canonicalContent, identity, parseRequest, requestBinding, date, recipeDocument, receiptDocument};
