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
const pageSize = 20;
const validAnchor = id => validId(id) && id.isWellFormed() && !id.includes('%');
const invalid = () => { throw new TeamMembersError('invalid-argument'); };
// The cursor is a position hint. Only a freshly verified Owner scope can use
// it, and it is never used to select a workspace or grant authorization.
const scopeKey = (scope, uid) => [uid, scope.cafeId, scope.generation, scope.ownerGeneration];

function decodeCursor(value) {
  if (typeof value !== 'string' || value.length > 1900 || !/^[A-Za-z0-9_-]+$/.test(value)) invalid();
  try {
    const bytes = Buffer.from(value, 'base64url');
    if (bytes.toString('base64url') !== value) invalid();
    const parts = JSON.parse(bytes.toString('utf8'));
    if (!Array.isArray(parts) || parts.length !== 5 || !validAnchor(parts[4])) invalid();
    return {scope: parts.slice(0, 4), after: parts[4]};
  } catch { invalid(); }
}

async function readDocuments(tx, paths) {
  const unique = [...new Set(paths)];
  if (!unique.length) return [];
  if (typeof tx.getMany !== 'function') {
    const values = [];
    for (const path of paths) values.push(await tx.get(path));
    return values;
  }
  const values = await tx.getMany(unique);
  const documents = new Map(unique.map((path, index) => [path, values[index]]));
  return paths.map(path => documents.get(path));
}

async function context(tx, uid) {
  const mapping = await tx.get(`user_cafe_memberships/${uid}`);
  const cafeId = mapping?.cafeId;
  if (!validId(cafeId) || !link(mapping, uid, cafeId)) deny();
  const cafe = await tx.get(`cafes/${cafeId}`);
  const ownerUid = cafe?.ownerUid;
  if (!validId(ownerUid) || cafe.status !== 'active' || cafe.schemaVersion !== 1) deny();
  const [member, owner, ownerMap] = await readDocuments(tx, [
    `cafes/${cafeId}/members/${uid}`, `cafes/${cafeId}/members/${ownerUid}`, `user_cafe_memberships/${ownerUid}`,
  ]);
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
async function readTeam(tx, uid, cursor, expected) {
  const scope = await context(tx, uid);
  if (expected && (scope.cafeId !== expected.cafeId || scope.generation !== expected.generation)) deny();
  if (cursor && (scope.role !== 'owner' || JSON.stringify(cursor.scope) !== JSON.stringify(scopeKey(scope, uid)))) deny();
  let candidates, nextCursor;
  if (scope.role === 'owner') {
    const rows = await tx.members(scope.cafeId, pageSize + 1, cursor?.after ?? null);
    const before = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)) < 0;
    if (!Array.isArray(rows) || rows.length > pageSize + 1 || rows.some(({id}, index) =>
      !validAnchor(id) || (index > 0 ? !before(rows[index - 1].id, id) : cursor && !before(cursor.after, id)))) deny();
    candidates = rows.slice(0, pageSize);
    if (!cursor) {
      const data = await tx.get(`cafes/${scope.cafeId}/members/${scope.ownerUid}`);
      candidates.unshift({id: scope.ownerUid, data});
    }
    if (rows.length > pageSize) nextCursor = Buffer.from(JSON.stringify([
      ...scopeKey(scope, uid), rows[pageSize - 1].id,
    ])).toString('base64url');
  } else {
    const ids = [scope.ownerUid, uid];
    const docs = await readDocuments(tx, ids.map(id => `cafes/${scope.cafeId}/members/${id}`));
    candidates = ids.map((id, index) => ({id, data: docs[index]}));
  }
  const eligible = candidates.filter(({id, data}) => validId(id) && link(data, id, scope.cafeId) &&
    ['owner', 'staff'].includes(data.role) && (data.role === 'owner') === (id === scope.ownerUid));
  const mappings = await readDocuments(tx, eligible.map(({id}) => `user_cafe_memberships/${id}`));
  const members = [];
  for (const [index, {id, data}] of eligible.entries()) {
    const mapping = mappings[index];
    const generation = activeMembershipGeneration(mapping, data, id, scope.cafeId, scope.ownerUid);
    if (link(mapping, id, scope.cafeId) && generation !== null) {
      members.push({uid: id, role: data.role, generation});
    }
  }
  const profiles = await readDocuments(tx, members.map(member => `users/${member.uid}`));
  return {...scope, members: members.map((member, index) => ({...member, profile: profiles[index]})), nextCursor};
}

const text = (value, max) => typeof value === 'string' && value.length <= max &&
  !/\p{Cc}/u.test(value) ? value.trim() : '';
const timestamp = value => value instanceof Date ? Number.isFinite(value.getTime()) :
  typeof value?.toMillis === 'function' && Number.isFinite(value.toMillis());
const profileName = (profile, email) => profile?.email === email &&
  ['owner', 'staff'].includes(profile.role) &&
  typeof profile.photoUrl === 'string' && profile.photoUrl.length <= 2048 &&
  timestamp(profile.createdAt) && timestamp(profile.updatedAt) ? text(profile.username, 80) : '';

async function listTeamMembers({auth, data, store, accounts, requireWorkspaceBinding = false}) {
  const uid = auth?.uid;
  if (!validId(uid) || auth.token?.email_verified !== true) {
    throw new TeamMembersError('unauthenticated');
  }
  const allowed = requireWorkspaceBinding ? ['cursor', 'expectedCafeId', 'expectedMembershipGeneration'] : ['cursor'];
  if (!data || typeof data !== 'object' || Array.isArray(data) || Object.keys(data).some(key => !allowed.includes(key))) invalid();
  let expected;
  if (requireWorkspaceBinding) {
    const {expectedCafeId: cafeId, expectedMembershipGeneration: generation} = data;
    if (!validId(cafeId) || !Number.isSafeInteger(generation) || generation < 0) invalid();
    expected = {cafeId, generation};
  }
  const cursor = Object.hasOwn(data, 'cursor') ? decodeCursor(data.cursor) : undefined;
  const initial = await store.runTransaction(tx => readTeam(tx, uid, cursor, expected));
  const requested = new Set([uid, ...initial.members.map(m => m.uid)]);
  const users = await accounts([...requested]);
  const profiles = new Map();
  for (const user of users) {
    if (!requested.delete(user?.uid)) deny();
    profiles.set(user.uid, user);
  }
  const caller = profiles.get(uid);
  if (!caller || caller.disabled !== false || caller.emailVerified !== true) deny();
  // No Auth I/O inside Firestore transactions. Revalidate all returned links.
  const current = await store.runTransaction(tx => readTeam(tx, uid, cursor, expected));
  if (current.cafeId !== initial.cafeId || current.ownerUid !== initial.ownerUid ||
      current.role !== initial.role || current.generation !== initial.generation ||
      current.ownerGeneration !== initial.ownerGeneration) deny();
  const permitted = new Map(current.members.map(member => [member.uid, member]));
  const members = initial.members.flatMap(member => {
    const user = profiles.get(member.uid);
    const email = text(user?.email, 254);
    const finalMember = permitted.get(member.uid);
    const name = profileName(finalMember?.profile, email) ||
      (requireWorkspaceBinding ? text(user?.displayName, 80) || email : '');
    if (!finalMember || finalMember.role !== member.role ||
        finalMember.generation !== member.generation || !user || user.disabled !== false ||
        user.emailVerified !== true || email !== user.email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
        !name || (!requireWorkspaceBinding && !profileName(member.profile, email))) return [];
    return [{uid: member.uid, role: member.role, name, email,
      ...(requireWorkspaceBinding && current.role === 'owner' && member.role === 'staff'
        ? {membershipGeneration: finalMember.generation} : {})}];
  });
  members.sort((a, b) => (a.role === 'owner' ? 0 : 1) - (b.role === 'owner' ? 0 : 1) ||
    a.name.localeCompare(b.name) || a.uid.localeCompare(b.uid));
  return {cafeId: current.cafeId, viewerRole: current.role, members,
    ...(initial.nextCursor ? {nextCursor: initial.nextCursor} : {})};
}

module.exports = {listTeamMembers, TeamMembersError};
