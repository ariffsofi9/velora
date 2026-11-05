'use strict';

const {createHash} = require('node:crypto');
const PROJECT = 'demo-velora-ai1';
const HOSTS = {FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:19099',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:19080'};
const CONNECTIVITY_PROJECT = 'demo-velora-ai-connectivity';
const CONNECTIVITY_HOSTS = {FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:49099',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:48080'};

class RecipeError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
function reject(code, message) { throw new RecipeError(code, message); }
function assertIsolated(env = process.env) {
  if (env.FUNCTIONS_EMULATOR !== 'true' || env.GCLOUD_PROJECT !== PROJECT ||
      Object.entries(HOSTS).some(([key, value]) => env[key] !== value) ||
      (env.GOOGLE_CLOUD_PROJECT && env.GOOGLE_CLOUD_PROJECT !== PROJECT)) {
    reject('failed-precondition', 'AI-1 requires the isolated demo emulators.');
  }
  if (env.FIREBASE_CONFIG) {
    let config;
    try { config = JSON.parse(env.FIREBASE_CONFIG); } catch (_) {
      reject('failed-precondition', 'Invalid demo configuration.');
    }
    if (config.projectId !== PROJECT) reject('failed-precondition', 'Wrong demo project.');
  }
}
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
function assertConnectivity(env = process.env) {
  if (env.FUNCTIONS_EMULATOR !== 'true' || env.GCLOUD_PROJECT !== CONNECTIVITY_PROJECT ||
      (env.GOOGLE_CLOUD_PROJECT && env.GOOGLE_CLOUD_PROJECT !== CONNECTIVITY_PROJECT) ||
      Object.entries(CONNECTIVITY_HOSTS).some(([key,value]) => env[key] !== value) ||
      env.AI_RECIPE_PROVIDER !== 'fake' || env.AI2_PROVIDER_PIPE) {
    reject('failed-precondition', 'Fake connectivity requires its isolated demo emulators.');
  }
  if (env.FIREBASE_CONFIG) {
    let config;
    try {config = JSON.parse(env.FIREBASE_CONFIG);} catch (_) {reject('failed-precondition','Invalid demo configuration.');}
    if (config.projectId !== CONNECTIVITY_PROJECT) reject('failed-precondition','Wrong demo project.');
  }
}
const id = (value) => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  value.trim() === value && !/[\/\p{Cc}]/u.test(value) && !['.', '..'].includes(value);
const text = (value, max) => typeof value === 'string' && value.trim() === value &&
  value.length > 0 && value.length <= max && !/\p{Cc}/u.test(value);
const exact = (value, fields) => object(value) &&
  Object.keys(value).every((key) => fields.includes(key));
function input(raw) {
  if (!exact(raw, ['requestId', 'maxRecipes']) ||
      typeof raw.requestId !== 'string' || !/^[A-Za-z0-9_-]{16,64}$/.test(raw.requestId) ||
      (raw.maxRecipes !== undefined &&
       (!Number.isInteger(raw.maxRecipes) || raw.maxRecipes < 1 || raw.maxRecipes > 3))) {
    reject('invalid-argument', 'Expected requestId and optional maxRecipes (1-3) only.');
  }
  return {requestId: raw.requestId, maxRecipes: raw.maxRecipes ?? 1};
}
const link = (data, uid, cafeId) => object(data) && data.uid === uid &&
  data.cafeId === cafeId && data.status === 'active' && data.schemaVersion === 1;
async function membership(tx, uid) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping?.cafeId;
  if (!id(cafeId) || !link(mapping, uid, cafeId)) {
    reject('permission-denied', 'Active workspace membership required.');
  }
  const cafe = await tx.get(`cafes/${cafeId}`);
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const ownerUid = cafe?.ownerUid;
  if (!id(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1 ||
      !link(member, uid, cafeId) || !['owner', 'staff'].includes(member.role) ||
      ((member.role === 'owner') !== (uid === ownerUid))) {
    reject('permission-denied', 'Workspace membership could not be verified.');
  }
  const owner = await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMapping = await tx.get(`user_cafe_memberships/${ownerUid}`);
  if (!link(owner, ownerUid, cafeId) || owner.role !== 'owner' ||
      !link(ownerMapping, ownerUid, cafeId)) {
    reject('permission-denied', 'Workspace ownership could not be verified.');
  }
  return {cafeId, ownerUid, role: member.role};
}
function date(value) {
  const result = value instanceof Date ? value : value?.toDate?.();
  return result instanceof Date && Number.isFinite(result.getTime()) ? result : null;
}
function inventory(documents, cafeId, now) {
  if (!Array.isArray(documents) || documents.length > 100) {
    reject('resource-exhausted', 'AI-1 supports at most 100 inventory records.');
  }
  const today = new Intl.DateTimeFormat('en-CA', {timeZone: 'Asia/Kuala_Lumpur',
    year: 'numeric', month: '2-digit', day: '2-digit'}).format(now);
  const ids = new Set();
  const result = [];
  for (const {id: itemId, data: d} of documents) {
    const expiry = date(d?.expiryDate);
    const state = Object.hasOwn(d ?? {}, 'lifecycleState') ? d.lifecycleState : 'active';
    const unit = Object.hasOwn(d ?? {}, 'unit') ? d.unit : 'pcs';
    const version = Object.hasOwn(d ?? {}, 'version') ? d.version : 1;
    if (!id(itemId) || ids.has(itemId) || !object(d) ||
        (Object.hasOwn(d, 'schemaVersion') && d.schemaVersion !== 1) ||
        (Object.hasOwn(d, 'cafeId') && d.cafeId !== cafeId) ||
        !text(d.name, 100) || !text(d.category, 60) ||
        !Number.isSafeInteger(d.quantity) || d.quantity < 0 ||
        !['kg', 'g', 'L', 'ml', 'pcs'].includes(unit) ||
        !Number.isSafeInteger(version) || version < 1 || !expiry || !date(d.createdAt) ||
        (d.imageUrl != null && typeof d.imageUrl !== 'string') ||
        !['active', 'archived'].includes(state) ||
        (state === 'archived' && (!date(d.archivedAt) || !id(d.archivedBy))) ||
        (state === 'active' && (d.archivedAt != null || d.archivedBy != null))) {
      reject('failed-precondition', 'Inventory validation failed.');
    }
    ids.add(itemId);
    const expiryDate = expiry.toISOString().slice(0, 10);
    if (state === 'active' && d.quantity > 0 && expiryDate >= today) {
      result.push({id: itemId, name: d.name, category: d.category,
        quantity: d.quantity, unit, expiryDate, version});
    }
  }
  return result.sort((a, b) => a.id.localeCompare(b.id));
}
function validateRecipes(value, items, max, providerName = 'fake') {
  if (!Array.isArray(value) || value.length > max) {
    reject('internal', 'Invalid recipe provider response.');
  }
  const ids = new Set(items.map((item) => item.id));
  return value.map((recipe) => {
    const live = providerName === 'groq';
    const ingredientIds = live && Array.isArray(recipe?.ingredients) ?
      recipe.ingredients.map((i) => i?.itemId) : recipe?.ingredientItemIds;
    if (!exact(recipe, ['title', live ? 'ingredients' : 'ingredientItemIds', 'steps', 'whyRecommended']) ||
        !text(recipe.title, 100) || !text(recipe.whyRecommended, 300) ||
        !Array.isArray(ingredientIds) || ingredientIds.length < 1 ||
        ingredientIds.length > 10 ||
        new Set(ingredientIds).size !== ingredientIds.length ||
        ingredientIds.some((itemId) => !ids.has(itemId)) ||
        !Array.isArray(recipe.steps) || recipe.steps.length < 1 || recipe.steps.length > 8 ||
        recipe.steps.some((step) => !text(step, 300))) {
      reject('internal', 'Invalid recipe provider response.');
    }
    if (live) {
      const stock = new Map(items.map((i) => [i.id, i]));
      const ingredients = recipe.ingredients.map((i) => {
        const item = stock.get(i.itemId);
        if (!exact(i, ['itemId', 'quantity', 'unit']) ||
            !Number.isFinite(i.quantity) || i.quantity <= 0 || i.quantity > 1000000 ||
            i.quantity > item.quantity || i.unit !== item.unit ||
            (i.unit === 'pcs' && !Number.isInteger(i.quantity))) {
          reject('internal', 'Invalid recipe ingredient quantities or units.');
        }
        return {itemId: i.itemId, quantity: i.quantity, unit: i.unit};
      });
      return {title: recipe.title, ingredients, steps: [...recipe.steps],
        whyRecommended: recipe.whyRecommended};
    }
    return {title: recipe.title, ingredientItemIds: [...ingredientIds],
      steps: [...recipe.steps], whyRecommended: recipe.whyRecommended};
  });
}

// Per-process replay/concurrency protection only, deliberately no database writes.
function createRecipeService({store, provider, verifyIdentity, env = process.env,
  now = () => new Date(), providerName = 'fake', isolation = 'ai1'}) {
  if (!['ai1','connectivity'].includes(isolation) || (isolation === 'connectivity' && providerName !== 'fake')) {
    reject('failed-precondition', 'Invalid recipe isolation profile.');
  }
  const assertEnvironment = isolation === 'connectivity' ? assertConnectivity : assertIsolated;
  if (!['fake', 'groq'].includes(providerName)) reject('failed-precondition', 'Invalid provider mode.');
  const busy = new Set();
  const seen = new Map();
  return async ({auth, data}) => {
    assertEnvironment(env);
    const uid = auth?.uid;
    if (!id(uid)) reject('unauthenticated', 'Authentication required.');
    const request = input(data);
    await verifyIdentity(uid, auth);
    const clock = now();
    const time = clock.getTime();
    for (const [key, expires] of seen) if (expires <= time) seen.delete(key);
    const key = createHash('sha256').update(`${uid}\0${request.requestId}`).digest('hex');
    if (busy.has(uid) || busy.size >= 8) reject('resource-exhausted', 'Recipe request in progress.');
    if (seen.has(key)) reject('already-exists', 'Request ID was already used. Use a new ID.');
    if (seen.size >= 128) reject('resource-exhausted', 'Local request capacity reached.');
    busy.add(uid);
    seen.set(key, time + 300000);
    try {
      const snapshot = () => store.runTransaction(async (tx) => {
        const workspace = await membership(tx, uid);
        const documents = await tx.inventory(`cafes/${workspace.cafeId}/inventory`, 101);
        return {workspace, items: inventory(documents, workspace.cafeId, now())};
      });
      const before = await snapshot();
      // No provider calls inside a transaction: transaction retries cannot call it twice.
      const raw = before.items.length ? await provider({
        items: structuredClone(before.items), maxRecipes: request.maxRecipes,
      }) : [];
      const recipes = validateRecipes(raw, before.items, request.maxRecipes, providerName);
      assertEnvironment(env);
      await verifyIdentity(uid, auth);
      const after = await snapshot();
      if (JSON.stringify(before) !== JSON.stringify(after)) {
        reject('aborted', 'Workspace or inventory changed. Retry with a new request ID.');
      }
      return {schemaVersion: providerName === 'groq' ? 2 : 1, requestId: request.requestId, provider: providerName,
        status: recipes.length ? 'ok' : 'no_suggestions', recipes};
    } finally { busy.delete(uid); }
  };
}
module.exports = {PROJECT, HOSTS, CONNECTIVITY_PROJECT, CONNECTIVITY_HOSTS, RecipeError,
  assertIsolated, assertConnectivity, createRecipeService, validateRecipes};
