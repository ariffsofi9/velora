'use strict';
const {mutationEpisode, assertMutationEpisode} = require('./mutation-episode');
const {activeMembershipGeneration} = require('./membership-generation');

const {createHash} = require('node:crypto');
const {MenuError, validId, parseRequest, menuDocument} = require('./menu-model');
const hash = value => createHash('sha256').update(value).digest('hex');
const deny = () => { throw new MenuError('permission-denied', 'Verified workspace permission required.'); };
const active = (d, uid, cafeId) => d && d.uid === uid && d.cafeId === cafeId &&
  d.status === 'active' && d.schemaVersion === 1;

async function authorize(tx, uid, ownerOnly) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping?.cafeId;
  if (!validId(cafeId) || !active(mapping, uid, cafeId)) deny();
  const cafe = await tx.get(`cafes/${cafeId}`);
  const ownerUid = cafe?.ownerUid;
  if (!validId(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) deny();
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const owner = await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMap = await tx.get(`user_cafe_memberships/${ownerUid}`);
  if (!active(member, uid, cafeId) || !['owner', 'staff'].includes(member.role) ||
      (member.role === 'owner') !== (uid === ownerUid) || !active(owner, ownerUid, cafeId) ||
      owner.role !== 'owner' || !active(ownerMap, ownerUid, cafeId) ||
      (ownerOnly && member.role !== 'owner') ||
      activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid) === null ||
      activeMembershipGeneration(ownerMap, owner, ownerUid, cafeId, ownerUid) === null) deny();
  return {cafeId, generation: activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid)};
}

async function menuOperation({operation, auth, data, store, timestamp}) {
  const uid = auth?.uid;
  if (!validId(uid)) throw new MenuError('unauthenticated', 'Sign in to continue.');
  const mutation = !['get', 'list'].includes(operation);
  const {episode, payload} = mutation ? mutationEpisode(data, MenuError) : {payload: data};
  const input = parseRequest(operation, payload);
  // Strict parsed field set, never a client role/flag or a comparison of values.
  const availabilityOnly = operation === 'update' &&
    Object.keys(input.changes).length === 1 && Object.hasOwn(input.changes, 'isAvailable');
  return store.runTransaction(async tx => {
    const {cafeId, generation} = await authorize(tx, uid, mutation && !availabilityOnly);
    if (mutation) assertMutationEpisode(episode, cafeId, generation, MenuError);
    if (operation === 'get') {
      const doc = await tx.get(`cafes/${cafeId}/menu_items/${input.itemId}`);
      if (!doc) throw new MenuError('not-found', 'Menu item not found.');
      return {item: menuDocument(input.itemId, doc, cafeId)};
    }
    if (operation === 'list') {
      const rows = await tx.menuItems(cafeId, input);
      if (!Array.isArray(rows) || rows.length > input.limit + 1) throw new MenuError('unavailable');
      // Validate the look-ahead document too; never hide malformed stored data.
      const items = rows.map(row => menuDocument(row.id, row.data, cafeId));
      if (!input.includeArchived && items.some(item => item.isArchived)) throw new MenuError('failed-precondition');
      const hasMore = items.length > input.limit;
      return {cafeId, items: items.slice(0, input.limit),
        nextCursor: hasMore ? rows[input.limit - 1].id : null};
    }
    const requestHash = hash(`${uid}\0${cafeId}\0${input.idempotencyKey}`);
    const payloadHash = hash(JSON.stringify({operation, input, episode}));
    const receiptPath = `cafes/${cafeId}/menu_requests/${requestHash}`;
    const receipt = await tx.get(receiptPath);
    if (receipt) {
      if (receipt.schemaVersion !== 1 || receipt.actorUid !== uid || receipt.operation !== operation ||
          receipt.payloadHash !== payloadHash || receipt.cafeId !== cafeId || receipt.requestHash !== requestHash) {
        throw new MenuError('already-exists', 'Request conflicts with an earlier menu operation.');
      }
      if (!validId(receipt.itemId) || !Number.isSafeInteger(receipt.resultVersion) || receipt.resultVersion < 1) {
        throw new MenuError('failed-precondition');
      }
      return {cafeId, itemId: receipt.itemId, version: receipt.resultVersion, changed: false};
    }
    const itemId = operation === 'create' ? `menu_${requestHash}` : input.itemId;
    const itemPath = `cafes/${cafeId}/menu_items/${itemId}`;
    const stored = await tx.get(itemPath);
    let version = 1;
    if (operation === 'create') {
      if (stored) throw new MenuError('already-exists');
    } else {
      if (!stored) throw new MenuError('not-found', 'Menu item not found.');
      const item = menuDocument(itemId, stored, cafeId);
      if (item.version !== input.expectedVersion) throw new MenuError('aborted', 'Menu item changed. Reload before retrying.');
      if (item.version >= Number.MAX_SAFE_INTEGER) throw new MenuError('failed-precondition');
      if (operation === 'update' && item.isArchived) throw new MenuError('failed-precondition', 'Restore this menu item before editing.');
      if (operation === 'lifecycle' && item.isArchived === (input.action === 'archive')) {
        throw new MenuError('failed-precondition', 'Invalid menu lifecycle transition.');
      }
      version = item.version + 1;
    }
    const now = timestamp();
    if (operation === 'create') {
      tx.create(itemPath, {...input.changes, cafeId, currency: 'MYR', isArchived: false,
        schemaVersion: 1, version, createdAt: now, updatedAt: now, createdBy: uid, updatedBy: uid});
    } else {
      tx.update(itemPath, {...(operation === 'update' ? input.changes : {isArchived: input.action === 'archive'}),
        version, updatedAt: now, updatedBy: uid});
    }
    tx.create(receiptPath, {schemaVersion: 1, cafeId, requestHash, payloadHash, actorUid: uid,
      operation, itemId, resultVersion: version, createdAt: now});
    return {cafeId, itemId, version, changed: true};
  });
}
module.exports = {menuOperation};
