'use strict';
const {activeMembershipGeneration} = require('./membership-generation');

class TeamMembersError extends Error {
  constructor(code) { super('Team members could not be verified.'); this.code = code; }
}
const deny = () => { throw new TeamMembersError('permission-denied'); };
const validId = s => typeof s === 'string' && s.length > 0 && s.length <= 128 &&
  s.trim() === s && !/[\\/\p{Cc}]/u.test(s) && !['.', '..'].includes(s);
const link = (d, uid, cafeId) => d?.uid === uid && d.cafeId === cafeId &&
  d.status === 'active' && d.schemaVersion === 1;

async function context(tx, uid) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping?.cafeId;
  if (!validId(cafeId) || !link(mapping, uid, cafeId)) deny();
  const cafe = await tx.get(`cafes/${cafeId}`);
  const ownerUid = cafe?.ownerUid;
  if (!validId(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) deny();
  const member = await tx.get(`cafes/${cafeId}/members/${uid}`);
  const owner = await tx.get(`cafes/${cafeId}/members/${ownerUid}`);
  const ownerMap = await tx.get(`user_cafe_memberships/${ownerUid}`);
  const generation = activeMembershipGeneration(mapping, member, uid, cafeId, ownerUid);
  const ownerGeneration = activeMembershipGeneration(ownerMap, owner, ownerUid, cafeId, ownerUid);
  if (!link(member, uid, cafeId) || !['owner', 'staff'].includes(member.role) ||
      (member.role === 'owner') !== (uid === ownerUid) ||
      !link(owner, ownerUid, cafeId) || owner.role !== 'owner' ||
      !link(ownerMap, ownerUid, cafeId) ||
      generation === null || ownerGeneration === null) deny();
  return {cafeId, ownerUid, role: member.role, generation, ownerGeneration};
}

// Uses the same owner-list / staff-self-and-owner visibility as repository Rules.
async function readTeam(tx, uid) {
  const scope = await context(tx, uid);
  let candidates;
  if (scope.role === 'owner') {
    candidates = await tx.members(scope.cafeId, 101);
    if (candidates.length > 100) throw new TeamMembersError('resource-exhausted');
  } else {
    candidates = await Promise.all([scope.ownerUid, uid].map(async id => ({
      id, data: await tx.get(`cafes/${scope.cafeId}/members/${id}`),
    })));
  }
  const members = [];
  for (const {id, data} of candidates) {
    if (!validId(id) || !link(data, id, scope.cafeId) ||
        !['owner', 'staff'].includes(data.role) ||
        (data.role === 'owner') !== (id === scope.ownerUid)) continue;
    const mapping = await tx.get(`user_cafe_memberships/${id}`);
    const generation = activeMembershipGeneration(mapping, data, id, scope.cafeId, scope.ownerUid);
    if (link(mapping, id, scope.cafeId) && generation !== null) {
      members.push({uid: id, role: data.role, generation});
    }
  }
  return {...scope, members};
}

const text = (value, max) => typeof value === 'string' && value.length <= max &&
  !/\p{Cc}/u.test(value) ? value.trim() : '';

async function listTeamMembers({auth, data, store, accounts}) {
  const uid = auth?.uid;
  if (!validId(uid)) throw new TeamMembersError('unauthenticated');
  if (!data || typeof data !== 'object' || Array.isArray(data) || Object.keys(data).length) {
    throw new TeamMembersError('invalid-argument');
  }
  const initial = await store.runTransaction(tx => readTeam(tx, uid));
  const users = await accounts([...new Set([uid, ...initial.members.map(m => m.uid)])]);
  const profiles = new Map(users.map(user => [user.uid, user]));
  if (!profiles.get(uid) || profiles.get(uid).disabled) deny();
  // No Auth I/O inside Firestore transactions. Revalidate all returned links.
  const current = await store.runTransaction(tx => readTeam(tx, uid));
  if (current.cafeId !== initial.cafeId || current.ownerUid !== initial.ownerUid ||
      current.role !== initial.role || current.generation !== initial.generation ||
      current.ownerGeneration !== initial.ownerGeneration) deny();
  const permitted = new Map(current.members.map(member => [member.uid, member]));
  const members = initial.members.flatMap(member => {
    const user = profiles.get(member.uid);
    const email = text(user?.email, 254);
    const finalMember = permitted.get(member.uid);
    if (!finalMember || finalMember.role !== member.role ||
        finalMember.generation !== member.generation || !user || user.disabled ||
        user.emailVerified !== true || !email) return [];
    // Generations are internal authorization snapshots, never roster fields.
    return [{uid: member.uid, role: member.role,
      name: text(user.displayName, 80) || email.split('@')[0], email}];
  });
  members.sort((a, b) => (a.role === 'owner' ? 0 : 1) - (b.role === 'owner' ? 0 : 1) ||
    a.name.localeCompare(b.name) || a.uid.localeCompare(b.uid));
  return {cafeId: current.cafeId, viewerRole: current.role, members};
}

module.exports = {listTeamMembers, TeamMembersError};
