import generation from '../../../src/membership-generation.js';
import {failure} from './http.mjs';
export async function workspaceAuthority(tx, auth, expected = {}) {
  const uid = auth?.uid;
  const id = value => typeof value === 'string' && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !/[\\/\p{Cc}]/u.test(value) && !['.', '..'].includes(value);
  if (!id(uid) || auth.token?.email_verified !== true ||
      Object.keys(expected).some(k => !['expectedCafeId', 'expectedMembershipGeneration'].includes(k))) throw failure('permission-denied');
  const map = await tx.get(`user_cafe_memberships/${uid}`); const cafeId = map?.cafeId;
  if (!id(cafeId)) throw failure('permission-denied');
  const cafe = await tx.get(`cafes/${cafeId}`); const owner = cafe?.ownerUid;
  if (!id(owner) || cafe.status !== 'active' || cafe.schemaVersion !== 1) throw failure('permission-denied');
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const ownerMap = owner === uid ? map : await tx.get(`user_cafe_memberships/${owner}`);
  const ownerMember = owner === uid ? member : await tx.get(`cafes/${cafeId}/members/${owner}`);
  const value = generation.activeMembershipGeneration(map, member, uid, cafeId, owner);
  if (value === null || generation.activeMembershipGeneration(ownerMap, ownerMember, owner, cafeId, owner) === null) throw failure('permission-denied');
  if ((expected.expectedCafeId !== undefined && expected.expectedCafeId !== cafeId) ||
      (expected.expectedMembershipGeneration !== undefined && expected.expectedMembershipGeneration !== value)) throw failure('aborted');
  return {uid, cafeId, ownerUid: owner, role: member.role, membershipGeneration: value};
}
