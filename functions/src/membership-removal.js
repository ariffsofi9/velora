'use strict';

const {createHash} = require('node:crypto');
const {activeMembershipGeneration} = require('./membership-generation');
class MembershipRemovalError extends Error {
  constructor(code, message = 'Staff removal could not be completed.') { super(message); this.code = code; }
}
const fail = code => { throw new MembershipRemovalError(code); };
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  value.trim() === value && !['.', '..'].includes(value) && !/[\\/\p{Cc}]/u.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
const hash = value => createHash('sha256').update(value).digest('hex');

async function removeStaffMember({auth, data, store, timestamp}) {
  const uid = auth?.uid;
  if (!id(uid)) fail('unauthenticated');
  if (auth.token?.email_verified !== true) fail('failed-precondition');
  const fields = ['targetUid', 'expectedCafeId', 'expectedGeneration', 'expectedActorGeneration', 'idempotencyKey'];
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      Object.keys(data).length !== fields.length || Object.keys(data).some(key => !fields.includes(key)) ||
      !id(data.targetUid) || !id(data.expectedCafeId) || !integer(data.expectedGeneration) ||
      !integer(data.expectedActorGeneration) || typeof data.idempotencyKey !== 'string' ||
      !/^[A-Za-z0-9_-]{16,128}$/.test(data.idempotencyKey)) fail('invalid-argument');
  if (uid === data.targetUid) fail('permission-denied');
  const payloadHash = hash(JSON.stringify(fields.map(field => data[field])));

  return store.runTransaction(async tx => {
    const actorMapping = await tx.get(`user_cafe_memberships/${uid}`);
    const cafeId = actorMapping?.cafeId;
    if (!id(cafeId)) fail('permission-denied');
    const cafe = await tx.get(`cafes/${cafeId}`);
    const actorMember = await tx.get(`cafes/${cafeId}/members/${uid}`);
    if (!cafe || cafe.ownerUid !== uid || cafe.status !== 'active' || cafe.schemaVersion !== 1 ||
        actorMember?.role !== 'owner') fail('permission-denied');
    const actorGeneration = activeMembershipGeneration(actorMapping, actorMember, uid, cafeId, uid);
    if (actorGeneration === null) fail('permission-denied');
    if (data.expectedCafeId !== cafeId || data.expectedActorGeneration !== actorGeneration) fail('aborted');

    const requestHash = hash(JSON.stringify([uid, cafeId, data.idempotencyKey]));
    const eventId = `remove_${requestHash}`;
    const receiptPath = `cafes/${cafeId}/membership_requests/${requestHash}`;
    const eventPath = `cafes/${cafeId}/membership_events/${eventId}`;
    const receipt = await tx.get(receiptPath);
    const event = await tx.get(eventPath);
    if (receipt || event) {
      if (!receipt || !event) fail('failed-precondition');
      for (const record of [receipt, event]) {
        if (record.payloadHash !== payloadHash) fail('already-exists');
        if (record.schemaVersion !== 1 || record.type !== 'staff_removed' ||
            record.requestHash !== requestHash || record.actorUid !== uid || record.cafeId !== cafeId ||
            record.targetUid !== data.targetUid || record.fromGeneration !== data.expectedGeneration ||
            !integer(record.resultGeneration) || record.resultGeneration !== data.expectedGeneration + 1 ||
            record.actorGeneration !== actorGeneration || record.eventId !== eventId) fail('failed-precondition');
      }
      // Historical acknowledgement only. Never inspect/reactivate/remove a later
      // target episode or return a claim about its current membership status.
      return {cafeId, targetUid: data.targetUid, eventId,
        resultGeneration: receipt.resultGeneration, changed: false};
    }

    const mappingPath = `user_cafe_memberships/${data.targetUid}`;
    const memberPath = `cafes/${cafeId}/members/${data.targetUid}`;
    const mapping = await tx.get(mappingPath);
    const member = await tx.get(memberPath);
    const generation = activeMembershipGeneration(mapping, member, data.targetUid, cafeId, uid);
    if (generation === null || member.role !== 'staff') fail('permission-denied');
    if (generation !== data.expectedGeneration) fail('aborted');
    if (generation === Number.MAX_SAFE_INTEGER) fail('failed-precondition');
    const resultGeneration = generation + 1;
    const time = timestamp();
    const transition = {status: 'inactive', membershipGeneration: resultGeneration,
      removedAt: time, removedBy: uid, updatedAt: time, removalEventId: eventId};
    const record = {schemaVersion: 1, type: 'staff_removed', cafeId, actorUid: uid,
      actorGeneration, targetUid: data.targetUid, fromGeneration: generation,
      resultGeneration, eventId, requestHash, payloadHash, createdAt: time};
    // No deletes. Preserve all prior fields plus immutable pre-transition snapshots.
    tx.update(mappingPath, transition);
    tx.update(memberPath, transition);
    tx.create(eventPath, {...record, previousMapping: mapping, previousMember: member});
    tx.create(receiptPath, record);
    return {cafeId, targetUid: data.targetUid, eventId, resultGeneration, changed: true};
  });
}

// Index registers this with enabled:false. No environment variable can activate
// it; activation requires a separately reviewed source change. Tests inject fakes.
function createStaffRemovalHandler({enabled = false, store, account, timestamp}) {
  return async request => {
    if (!enabled) fail('failed-precondition');
    if (!id(request.auth?.uid)) fail('unauthenticated');
    if (request.auth.token?.email_verified !== true) fail('failed-precondition');
    const user = await account(request.auth.uid);
    if (!user || user.uid !== request.auth.uid || user.disabled) fail('unauthenticated');
    if (!user.emailVerified || typeof user.email !== 'string' || typeof request.auth.token.email !== 'string' ||
        user.email.trim().toLowerCase() !== request.auth.token.email.trim().toLowerCase()) fail('failed-precondition');
    return removeStaffMember({auth: request.auth, data: request.data, store, timestamp});
  };
}

module.exports = {removeStaffMember, MembershipRemovalError, createStaffRemovalHandler};
