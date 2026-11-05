'use strict';

const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
  value.trim() === value && !['.', '..'].includes(value) && !/[\\/\p{Cc}]/u.test(value);
const active = (value, uid, cafeId) => record(value) && value.uid === uid &&
  value.cafeId === cafeId && value.status === 'active' && value.schemaVersion === 1;

/** Pure active-pair validator. Returns generation (including 0), or null to deny.
 * Not a complete workspace resolver: callers must still validate the cafe and
 * its owner's canonical/member pair transactionally. Never validates tombstones.
 */
function activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid) {
  if (!id(uid) || !id(cafeId) || !id(ownerUid) ||
      !active(mapping, uid, cafeId) || !active(member, uid, cafeId) ||
      !['owner', 'staff'].includes(member.role) ||
      (member.role === 'owner') !== (uid === ownerUid)) return null;

  const mapped = Object.hasOwn(mapping, 'membershipGeneration');
  const joined = Object.hasOwn(member, 'membershipGeneration');
  if (!mapped && !joined) return 0;
  // A partial upgrade must not be normalized into a valid legacy pair.
  if (!mapped || !joined) return null;
  const generation = mapping.membershipGeneration;
  return Number.isSafeInteger(generation) && generation >= 0 &&
    Number.isSafeInteger(member.membershipGeneration) &&
    member.membershipGeneration === generation ? generation : null;
}

module.exports = {activeMembershipGeneration};
