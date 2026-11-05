'use strict';
const {activeMembershipGeneration} = require('./membership-generation');
const id = v => typeof v === 'string' && v.length > 0 && v.length <= 128 &&
  v.trim() === v && !['.', '..'].includes(v) && !/[\\/\p{Cc}]/u.test(v);
const integer = v => Number.isSafeInteger(v) && v >= 0;
const millis = v => v instanceof Date ? v.getTime() : v?.toMillis?.();

async function removalEvidence(tx, uid, cafeId, member, deny) {
  if (!id(cafeId) || !member || member.uid !== uid || member.cafeId !== cafeId ||
      member.role !== 'staff' || member.status !== 'inactive' || member.schemaVersion !== 1 ||
      !integer(member.membershipGeneration) || member.membershipGeneration < 1 ||
      !/^remove_[a-f0-9]{64}$/.test(member.removalEventId ?? '') || !id(member.removedBy)) deny('failed-precondition');
  const event = await tx.get(`cafes/${cafeId}/membership_events/${member.removalEventId}`);
  const requestHash = member.removalEventId.slice(7);
  const receipt = await tx.get(`cafes/${cafeId}/membership_requests/${requestHash}`);
  if (!event || !receipt) deny('failed-precondition');
  for (const record of [event, receipt]) {
    if (record.schemaVersion !== 1 || record.type !== 'staff_removed' || record.cafeId !== cafeId ||
        record.targetUid !== uid || record.actorUid !== member.removedBy ||
        record.eventId !== member.removalEventId || record.requestHash !== requestHash ||
        !/^[a-f0-9]{64}$/.test(record.payloadHash ?? '') || !integer(record.actorGeneration) ||
        !integer(record.fromGeneration) || record.resultGeneration !== member.membershipGeneration ||
        record.fromGeneration + 1 !== record.resultGeneration ||
        !Number.isFinite(millis(record.createdAt)) || millis(record.createdAt) !== millis(member.removedAt)) deny('failed-precondition');
  }
  if (receipt.payloadHash !== event.payloadHash || receipt.actorGeneration !== event.actorGeneration ||
      activeMembershipGeneration(event.previousMapping, event.previousMember, uid, cafeId, event.actorUid) !== event.fromGeneration ||
      event.previousMember.role !== 'staff') deny('failed-precondition');
  return event;
}

async function removedStaff(tx, uid, deny) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  if (!mapping || !id(mapping.cafeId) || mapping.uid !== uid || mapping.status !== 'inactive' ||
      mapping.schemaVersion !== 1 || !integer(mapping.membershipGeneration) || mapping.membershipGeneration < 1) deny('failed-precondition');
  const member = await tx.get(`cafes/${mapping.cafeId}/members/${uid}`);
  const evidence = await removalEvidence(tx, uid, mapping.cafeId, member, deny);
  if (mapping.membershipGeneration !== member.membershipGeneration ||
      !Number.isFinite(millis(mapping.createdAt)) || !Number.isFinite(millis(member.createdAt)) ||
      mapping.removalEventId !== member.removalEventId || mapping.removedBy !== member.removedBy ||
      millis(mapping.removedAt) !== millis(member.removedAt)) deny('failed-precondition');
  return {mapping, member, evidence};
}

async function applyStaffRejoin({tx, uid, invite, invitationId, mapping, destinationMember, time, deny}) {
  const old = await removedStaff(tx, uid, deny);
  if (invite.bindingVersion !== 1 || invite.targetUid !== uid ||
      invite.targetGeneration !== old.mapping.membershipGeneration ||
      invite.removalEventId !== old.mapping.removalEventId ||
      invite.previousCafeId !== old.mapping.cafeId) deny('permission-denied');
  if (old.mapping.membershipGeneration === Number.MAX_SAFE_INTEGER) deny('failed-precondition');
  if (destinationMember && invite.cafeId !== old.mapping.cafeId) {
    await removalEvidence(tx, uid, invite.cafeId, destinationMember, deny);
    if (destinationMember.membershipGeneration >= old.mapping.membershipGeneration) deny('failed-precondition');
  }
  const eventId = `rejoin_${invitationId}`;
  const eventPath = `cafes/${invite.cafeId}/membership_events/${eventId}`;
  if (await tx.get(eventPath)) deny('failed-precondition');
  const generation = old.mapping.membershipGeneration + 1;
  const link = {uid, cafeId: invite.cafeId, status: 'active', schemaVersion: 1,
    membershipGeneration: generation, createdAt: old.mapping.createdAt,
    updatedAt: time, joinedAt: time, joinedByInvitation: invitationId};
  // Preserve prior episode snapshots before explicitly replacing a same-cafe
  // member. Old removal evidence is immutable and never updated/deleted.
  tx.create(eventPath, {schemaVersion: 1, type: 'staff_rejoined', cafeId: invite.cafeId,
    actorUid: uid, targetUid: uid, ownerUid: invite.ownerUid, invitationId,
    previousCafeId: old.mapping.cafeId, fromGeneration: old.mapping.membershipGeneration,
    resultGeneration: generation, removalEventId: old.mapping.removalEventId,
    previousMapping: mapping, previousMember: old.member,
    previousDestinationMember: destinationMember ?? null, createdAt: time});
  // Full replacement of known link data clears obsolete removal metadata, with
  // all previous fields retained in the immutable event snapshots above.
  tx.set(`user_cafe_memberships/${uid}`, link);
  const member = {...link, role: 'staff', createdAt: destinationMember?.createdAt ?? time};
  if (destinationMember) tx.set(`cafes/${invite.cafeId}/members/${uid}`, member);
  else tx.create(`cafes/${invite.cafeId}/members/${uid}`, member);
  tx.update(`workspace_invitations/${invitationId}`, {status: 'redeemed', redeemedAt: time,
    redeemedBy: uid, resultGeneration: generation, rejoinEventId: eventId});
  return {joined: true, cafeId: invite.cafeId, generation};
}
module.exports = {removedStaff, applyStaffRejoin};
